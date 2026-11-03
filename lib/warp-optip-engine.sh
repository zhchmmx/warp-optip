#!/bin/bash
#
# warp-optip engine
#
# 模式：
#   pre-up          NetworkManager pre-up 阶段同步调用（不能调用 nmcli）
#   verify          up 之后由 systemd 异步调用，做 warp=on 校验和修复
#   scan            手动断开 -> 直连扫描 -> 生成 result.csv
#   apply           用现有 result.csv 逐个实测并应用
#   apply-one EP    只测试并应用指定 endpoint
#   status          显示状态
#
set -uo pipefail

CONF="${WARP_CONF:-/etc/warp-optip.conf}"
if [[ -r "$CONF" ]]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

WARP_CONN="${WARP_CONN:-warp-optip}"
WARP_IFACE="${WARP_IFACE:-$WARP_CONN}"
WARP_STATE_DIR="${WARP_STATE_DIR:-/var/lib/warp-optip}"
WARP_RESULT_CSV="${WARP_RESULT_CSV:-$WARP_STATE_DIR/result.csv}"
WARP_SCAN_BIN="${WARP_SCAN_BIN:-/usr/local/lib/warp-optip/warp}"
WARP_SCAN_RANGES="${WARP_SCAN_RANGES:-162.159.192.0/24,162.159.193.0/24,162.159.195.0/24,188.114.96.0/22}"
WARP_MAX_LOSS="${WARP_MAX_LOSS:-20}"
WARP_MAX_LATENCY="${WARP_MAX_LATENCY:-200}"
WARP_LIMIT="${WARP_LIMIT:-20}"
WARP_ON_UP_POLICY="${WARP_ON_UP_POLICY:-keep}"
WARP_CHECK_URL="${WARP_CHECK_URL:-https://1.1.1.1/cdn-cgi/trace}"
WARP_SCAN_TIMEOUT="${WARP_SCAN_TIMEOUT:-18}"
WARP_PREUP_TIMEOUT="${WARP_PREUP_TIMEOUT:-25}"

# 扫描时强制走物理网络：pre-up 阶段 NM 会很快装好 WireGuard 的策略路由，
# 不强制的话探测会进隧道。规则只匹配扫描网段，扫完即删。
WARP_SCAN_FORCE_PHYSICAL="${WARP_SCAN_FORCE_PHYSICAL:-1}"
WARP_SCAN_RULE_PREF="${WARP_SCAN_RULE_PREF:-30000}"
WARP_SCAN_PROBE_IP="${WARP_SCAN_PROBE_IP:-162.159.192.1}"

# NetworkManager 给 WireGuard 自动默认路由选的规则优先级由连接 UUID 派生，
# 范围是 30768~31766 的偶数。扫描规则必须比它更小才能先命中；
# 旧配置里的 31000 会随机失效，这里统一钳制到安全值。
SCAN_RULE_PREF_CLAMPED=""
if [[ ! "$WARP_SCAN_RULE_PREF" =~ ^[0-9]+$ ]] \
    || (( 10#$WARP_SCAN_RULE_PREF < 1 )) \
    || (( 10#$WARP_SCAN_RULE_PREF >= 30768 )); then
    SCAN_RULE_PREF_CLAMPED="$WARP_SCAN_RULE_PREF"
    WARP_SCAN_RULE_PREF=30000
fi

LOG_FILE="$WARP_STATE_DIR/warp-optip.log"
RUN_DIR="/run/warp-optip"
LAST_ENDPOINT_FILE="$WARP_STATE_DIR/last-endpoint"
OLD_ENDPOINT_FILE="$WARP_STATE_DIR/old-endpoint"
PENDING_ENDPOINT_FILE="$WARP_STATE_DIR/pending-endpoint"
DISABLED_FILE="$WARP_STATE_DIR/disabled"

IFACE="${DEVICE_IFACE:-$WARP_IFACE}"

SCAN_CHILD=""
SCAN_RULES_ACTIVE=0

# ---------- 基础工具 ----------

log() {
    local msg
    msg="[$(date '+%F %T')] $*"
    printf '%s\n' "$msg"
    mkdir -p "$WARP_STATE_DIR" 2>/dev/null || true
    printf '%s\n' "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    log "错误: $*"
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

ensure_dirs() {
    mkdir -p "$WARP_STATE_DIR" "$RUN_DIR" 2>/dev/null || true
}

acquire_lock() {
    local wait="${1:-10}"
    ensure_dirs
    exec 9>"$WARP_STATE_DIR/lock" || return 1
    flock -w "$wait" 9 || return 1
    return 0
}

is_disabled() {
    [[ -f "$DISABLED_FILE" ]]
}

self_up_fresh() {
    local f="$RUN_DIR/self-up" now ts
    [[ -f "$f" ]] || return 1
    now=$(date +%s)
    ts=$(cat "$f" 2>/dev/null || echo 0)
    [[ "$ts" =~ ^[0-9]+$ ]] || return 1
    (( now - ts < 60 ))
}

warp_is_active() {
    nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$WARP_CONN"
}

verify_warp() {
    local out
    out="$(curl -sS --connect-timeout 5 --max-time 10 "$WARP_CHECK_URL" 2>/dev/null)" || return 1
    grep -qx 'warp=on' <<<"$out" || return 1
    return 0
}

# ---------- endpoint / peer ----------

peer_string() {
    nmcli -g wireguard.peers connection show "$WARP_CONN" 2>/dev/null \
        | head -n1 \
        | sed 's/\\:/:/g'
}

endpoint_of_peer() {
    printf '%s\n' "$1" | sed -n 's/.*endpoint=\([^ ]*\).*/\1/p'
}

nmcli_endpoint() {
    local p
    p="$(peer_string)" || return 1
    endpoint_of_peer "$p"
}

build_peer() {
    local ep="$1" base new
    base="$(peer_string)" || return 1
    [[ -n "$base" ]] || return 1
    new="$(printf '%s\n' "$base" | sed -E "s#endpoint=[^ ]+#endpoint=${ep}#")"
    [[ "$new" == *"endpoint=${ep}"* ]] || return 1
    printf '%s\n' "$new"
}

wg_peer_pubkey() {
    wg show "$1" peers 2>/dev/null | head -n1
}

wg_peer_endpoint() {
    wg show "$1" endpoints 2>/dev/null | awk 'NR==1 {print $2}'
}

# ---------- 扫描结果解析 ----------

parse_candidates() {
    local file="${1:-$WARP_RESULT_CSV}"
    [[ -s "$file" ]] || return 1

    awk -v maxloss="$WARP_MAX_LOSS" -v maxlat="$WARP_MAX_LATENCY" -F',' '
        NR == 1 { next }
        {
            ep = $1
            gsub(/^[ \t]+|[ \t]+$/, "", ep)
            loss = $2
            gsub(/[% \t]/, "", loss)
            lat = $3
            gsub(/[a-zA-Z% \t]/, "", lat)

            if (ep !~ /:[0-9]+$/) next
            if (loss !~ /^[0-9.]+$/) next
            if (lat !~ /^[0-9.]+$/) next
            if (loss + 0 > maxloss) next
            if (lat + 0 <= 0 || lat + 0 > maxlat) next

            print ep "\t" lat
        }
    ' "$file" | sort -t $'\t' -k2,2n | awk -F'\t' '!seen[$1]++'
}

pick_candidate() {
    local cur="$1" cur_ip first fallback
    cur_ip=""
    [[ -n "$cur" ]] && cur_ip="${cur%:*}"

    if [[ -n "$cur_ip" ]]; then
        first="$(parse_candidates "$WARP_RESULT_CSV" 2>/dev/null \
            | awk -F'\t' -v cur="$cur_ip" 'index($1, cur ":") != 1' \
            | head -n1 | cut -f1)"
        [[ -n "$first" ]] && { printf '%s\n' "$first"; return 0; }
    fi

    fallback="$(parse_candidates "$WARP_RESULT_CSV" 2>/dev/null | head -n1 | cut -f1)"
    [[ -n "$fallback" ]] && printf '%s\n' "$fallback"
}

# ---------- 直连扫描 ----------

# 扫描期间把目标为扫描网段的流量压回 main 表（物理默认路由）。
#
# NetworkManager 给 WireGuard 自动装好的规则大致是：
#   31444: from all lookup main suppress_prefixlength 0
#   31445: not from all fwmark 0xcc41 lookup 52289
# 31444 对所有流量生效，所以只给探测包打 fwmark 不够；必须在它之前
# （更小的 pref）插一条只匹配扫描网段的规则，让探测查 main 表。
# 规则扫完即删，不影响宿主其它流量，也不影响 wg 自己的握手包。
scan_rules_flush() {
    command -v ip >/dev/null 2>&1 || return 0
    local -a ranges
    IFS=, read -r -a ranges <<< "$WARP_SCAN_RANGES"
    local r
    for r in "${ranges[@]}"; do
        r="${r//[[:space:]]/}"
        [[ -n "$r" ]] || continue
        while ip -4 rule del pref "$WARP_SCAN_RULE_PREF" to "$r" lookup main 2>/dev/null; do
            :
        done
    done
}

scan_rules_remove() {
    [[ "$SCAN_RULES_ACTIVE" -eq 1 ]] || return 0
    scan_rules_flush
    SCAN_RULES_ACTIVE=0
}

scan_rules_add() {
    [[ "$WARP_SCAN_FORCE_PHYSICAL" == "1" ]] || return 0

    if [[ "$(id -u)" -ne 0 ]]; then
        log "扫描出口: 非 root，无法强制物理网络（扫描继续）"
        return 1
    fi
    command -v ip >/dev/null 2>&1 || { log "扫描出口: 缺少 ip 命令"; return 1; }

    # 清掉上次异常退出可能残留的规则
    scan_rules_flush

    local -a ranges
    IFS=, read -r -a ranges <<< "$WARP_SCAN_RANGES"
    local r n=0
    for r in "${ranges[@]}"; do
        r="${r//[[:space:]]/}"
        [[ -n "$r" ]] || continue
        if ip -4 rule add pref "$WARP_SCAN_RULE_PREF" to "$r" lookup main 2>/dev/null; then
            n=$((n + 1))
        else
            log "扫描出口: 添加规则失败 to $r"
        fi
    done

    if [[ "$n" -gt 0 ]]; then
        SCAN_RULES_ACTIVE=1
        if [[ -n "$SCAN_RULE_PREF_CLAMPED" ]]; then
            log "扫描出口: 配置的 pref $SCAN_RULE_PREF_CLAMPED 不安全，改用 $WARP_SCAN_RULE_PREF（NM 的规则可能低到 30768）"
        fi
        log "扫描出口: 已强制 $n 个网段走物理网络 (pref $WARP_SCAN_RULE_PREF)"
        if [[ -n "$WARP_SCAN_PROBE_IP" ]]; then
            local route
            route="$(ip route get "$WARP_SCAN_PROBE_IP" 2>&1 | head -n1)"
            log "扫描出口: $route"
            if [[ "$route" == *" dev ${WARP_IFACE} "* || "$route" == *" table "* ]]; then
                log "扫描出口: 警告，探测仍可能走隧道；当前规则:"
                ip -4 rule show 2>/dev/null | while IFS= read -r line; do
                    log "  $line"
                done
            fi
        fi
        return 0
    fi

    log "扫描出口: 没有添加任何规则，探测可能仍走隧道"
    return 1
}

cleanup_all() {
    scan_rules_remove
    rm -f "$RUN_DIR/self-up" 2>/dev/null || true
    if [[ -n "$SCAN_CHILD" ]] && kill -0 "$SCAN_CHILD" 2>/dev/null; then
        kill "$SCAN_CHILD" 2>/dev/null || true
    fi
}

trap cleanup_all EXIT INT TERM

scan_direct() {
    local tmp rc

    [[ -x "$WARP_SCAN_BIN" ]] || { log "扫描器不存在: $WARP_SCAN_BIN"; return 1; }

    tmp="$WARP_RESULT_CSV.new.$$"
    rm -f "$tmp"

    log "开始扫描: $WARP_SCAN_RANGES"

    # 让探测流量绕过可能已经生效的 WireGuard 策略路由
    scan_rules_add || true

    # 与上游 warp-yxip.sh 保持一致：它除了 -ip/-o 之外不传任何参数，
    # 并发和筛选全用内置默认；并且先把 fd 上限抬到 102400。
    # 之前我们传的 -t 2 把并发压成 2，1792 个地址在 18 秒内根本测不完，
    # 结果全是 timeout 行，解析后候选数为 0。
    ulimit -n 102400 2>/dev/null || true

    timeout --signal=TERM --kill-after=2s "${WARP_SCAN_TIMEOUT}s" \
        "$WARP_SCAN_BIN" \
        -ip "$WARP_SCAN_RANGES" \
        -o "$tmp" &
    SCAN_CHILD=$!
    wait "$SCAN_CHILD"
    rc=$?
    SCAN_CHILD=""

    # 探测结束立刻恢复系统路由，不等脚本退出
    scan_rules_remove

    if [[ "$rc" -ne 0 ]]; then
        log "扫描器退出码: $rc"
        rm -f "$tmp"
        return 1
    fi

    if [[ ! -s "$tmp" ]]; then
        log "扫描没有产生结果"
        rm -f "$tmp"
        return 1
    fi

    if [[ -f "$WARP_RESULT_CSV" ]]; then
        cp -f "$WARP_RESULT_CSV" "$WARP_RESULT_CSV.bak" 2>/dev/null || true
    fi
    mv -f "$tmp" "$WARP_RESULT_CSV"
    log "扫描完成: $WARP_RESULT_CSV"
    return 0
}

# ---------- pre-up ----------

pre_up() {
    ensure_dirs

    if is_disabled; then
        log "pre-up: 已禁用，跳过"
        return 0
    fi

    if self_up_fresh; then
        log "pre-up: self-up 标记，跳过扫描"
        return 0
    fi

    if ! acquire_lock 2; then
        log "pre-up: 获取锁失败，跳过"
        return 0
    fi

    # 只让本次 pre-up 产生的候选进入 verify
    rm -f "$PENDING_ENDPOINT_FILE" 2>/dev/null || true

    local iface="${DEVICE_IFACE:-$IFACE}"
    local cur_ep pub ep

    cur_ep="$(wg_peer_endpoint "$iface")"
    pub="$(wg_peer_pubkey "$iface")"

    [[ -n "$cur_ep" ]] && printf '%s\n' "$cur_ep" > "$OLD_ENDPOINT_FILE"

    if ! scan_direct; then
        log "pre-up: 扫描失败，保持当前 endpoint"
        return 0
    fi

    ep="$(pick_candidate "$cur_ep")"

    if [[ -z "$ep" ]]; then
        log "pre-up: 没有可用候选"
        return 0
    fi

    # 无论 wg set 是否成功，都把候选留给 verify 阶段应用
    printf '%s\n' "$ep" > "$PENDING_ENDPOINT_FILE"

    if [[ -n "$pub" ]] && wg set "$iface" peer "$pub" endpoint "$ep" 2>/dev/null; then
        log "pre-up: 运行时 endpoint 已设置为 $ep"
    else
        log "pre-up: 接口/peer 暂不可用，候选 $ep 留给 verify 阶段应用"
    fi

    return 0
}

# ---------- 应用 / 修复 ----------

reapply_iface() {
    nmcli device reapply "$IFACE" >/dev/null 2>&1
}

set_endpoint_profile() {
    local ep="$1" peer
    peer="$(build_peer "$ep")" || return 1
    nmcli connection modify "$WARP_CONN" wireguard.peers "$peer" >/dev/null 2>&1
}

try_endpoint() {
    local ep="$1"

    log "尝试 endpoint: $ep"

    # connection modify 和 device reapply 都可能让 NetworkManager 重新激活设备，
    # 从一开始就写标记，告诉 dispatcher 这不是用户主动断开。
    # 全程不使用 connection down/up，因此本程序任何路径都不会主动打开隧道。
    date +%s > "$RUN_DIR/self-up" 2>/dev/null || true

    if ! set_endpoint_profile "$ep"; then
        log "  profile 修改失败"
        rm -f "$RUN_DIR/self-up" 2>/dev/null || true
        return 1
    fi

    if reapply_iface; then
        sleep 2
        if verify_warp; then
            log "  reapply 后连通正常"
            rm -f "$RUN_DIR/self-up" 2>/dev/null || true
            return 0
        fi
        log "  reapply 后仍不通"
    else
        log "  reapply 失败"
    fi

    rm -f "$RUN_DIR/self-up" 2>/dev/null || true
    return 1
}

try_candidates() {
    local exclude="$1"
    local ep lat
    while IFS=$'\t' read -r ep lat; do
        [[ -n "$ep" ]] || continue
        [[ -n "$exclude" && "$ep" == "$exclude" ]] && continue
        # 用户已主动断开时立即中止，不能把隧道重新打开
        if ! warp_is_active; then
            log "候选尝试中止：$WARP_CONN 已不再激活"
            return 1
        fi
        if try_endpoint "$ep"; then
            printf '%s\n' "$ep" > "$LAST_ENDPOINT_FILE"
            return 0
        fi
    done < <(parse_candidates "$WARP_RESULT_CSV" 2>/dev/null | head -n "$WARP_LIMIT")
    return 1
}

verify_mode() {
    ensure_dirs

    if is_disabled; then
        log "verify: 已禁用，跳过"
        return 0
    fi

    if ! acquire_lock 30; then
        log "verify: 获取锁失败"
        return 1
    fi

    if ! warp_is_active; then
        log "verify: $WARP_CONN 未激活，跳过"
        return 0
    fi

    local cur_ep pending restore_ep
    cur_ep="$(nmcli_endpoint)"
    pending=""
    [[ -f "$PENDING_ENDPOINT_FILE" ]] && pending="$(cat "$PENDING_ENDPOINT_FILE" 2>/dev/null || true)"
    restore_ep="$cur_ep"
    if [[ -n "$pending" && -s "$OLD_ENDPOINT_FILE" ]]; then
        restore_ep="$(cat "$OLD_ENDPOINT_FILE" 2>/dev/null || true)"
    fi

    log "verify: 当前 endpoint=${cur_ep:-未知} pending=${pending:-无}"

    sleep 2

    if [[ -n "$pending" ]]; then
        log "verify: 持久化 pending endpoint $pending"
        if set_endpoint_profile "$pending"; then
            reapply_iface || true
            sleep 2
        else
            log "verify: 持久化失败"
        fi
    fi

    local first_run=0
    [[ -s "$LAST_ENDPOINT_FILE" ]] || first_run=1

    if verify_warp; then
        if [[ "$first_run" -eq 0 || -n "$pending" ]]; then
            local ok_ep
            ok_ep="$(nmcli_endpoint)"
            printf '%s\n' "$ok_ep" > "$LAST_ENDPOINT_FILE"
            rm -f "$PENDING_ENDPOINT_FILE" 2>/dev/null || true
            log "verify: 连通正常，当前 endpoint=$ok_ep"
            return 0
        fi
        log "verify: 首次运行且 pre-up 未产生候选，继续执行优选"
    else
        log "verify: 当前 endpoint 不健康，开始尝试候选"
    fi

    if [[ -s "$WARP_RESULT_CSV" ]]; then
        if try_candidates "$cur_ep"; then
            rm -f "$PENDING_ENDPOINT_FILE" 2>/dev/null || true
            log "verify: 候选切换成功"
            return 0
        fi
    fi

    log "verify: 所有候选失败，恢复旧 endpoint ${restore_ep:-未知}"
    if [[ -n "$restore_ep" ]] && try_endpoint "$restore_ep"; then
        printf '%s\n' "$restore_ep" > "$LAST_ENDPOINT_FILE"
        rm -f "$PENDING_ENDPOINT_FILE" 2>/dev/null || true
        log "verify: 已恢复旧 endpoint"
        return 1
    fi

    log "verify: 旧 endpoint 也不可用，断开 $WARP_CONN 以保留物理网络"
    nmcli --wait 10 connection down "$WARP_CONN" >/dev/null 2>&1 || true
    return 2
}

# ---------- 手动命令 ----------

scan_cmd() {
    ensure_dirs
    acquire_lock 10 || die "另一个实例正在运行"

    if warp_is_active; then
        log "scan: 断开 $WARP_CONN"
        nmcli --wait 15 connection down "$WARP_CONN" >/dev/null 2>&1 || true
        sleep 1
    fi

    scan_direct || die "扫描失败"
    log "scan: 结果已写入 $WARP_RESULT_CSV"
    log "scan: 运行 '$0 apply' 逐个实测应用"
}

apply_cmd() {
    ensure_dirs
    acquire_lock 10 || die "另一个实例正在运行"

    [[ -s "$WARP_RESULT_CSV" ]] || die "没有 $WARP_RESULT_CSV，请先运行 scan"

    local cur
    cur="$(nmcli_endpoint)"
    log "apply: 当前 endpoint=${cur:-未知}"

    if try_candidates "$cur"; then
        rm -f "$PENDING_ENDPOINT_FILE" 2>/dev/null || true
        log "apply: 完成"
        return 0
    fi

    log "apply: 所有候选失败"
    if [[ -n "$cur" ]] && try_endpoint "$cur"; then
        log "apply: 已恢复旧 endpoint"
        return 1
    fi
    log "apply: 旧 endpoint 也不可用，断开 $WARP_CONN"
    nmcli --wait 10 connection down "$WARP_CONN" >/dev/null 2>&1 || true
    return 2
}

apply_one_cmd() {
    local ep="$1"
    [[ -n "$ep" ]] || die "缺少 IP:PORT"
    ensure_dirs
    acquire_lock 10 || die "另一个实例正在运行"
    if try_endpoint "$ep"; then
        printf '%s\n' "$ep" > "$LAST_ENDPOINT_FILE"
        rm -f "$PENDING_ENDPOINT_FILE" 2>/dev/null || true
        log "apply-one: 成功 $ep"
        return 0
    fi
    log "apply-one: 失败 $ep"
    return 1
}

status_cmd() {
    ensure_dirs
    echo "connection : $WARP_CONN"
    echo "iface      : $IFACE"
    echo "active     : $(warp_is_active && echo yes || echo no)"
    echo "endpoint   : $(nmcli_endpoint 2>/dev/null || echo 未知)"
    echo "last       : $(cat "$LAST_ENDPOINT_FILE" 2>/dev/null || echo 无)"
    echo "pending    : $(cat "$PENDING_ENDPOINT_FILE" 2>/dev/null || echo 无)"
    local n
    n=$(parse_candidates "$WARP_RESULT_CSV" 2>/dev/null | wc -l)
    echo "candidates : $n"
    if curl -sS --max-time 8 "$WARP_CHECK_URL" 2>/dev/null | grep -qx 'warp=on'; then
        echo "warp=on    : yes"
    else
        echo "warp=on    : no"
    fi
}

# ---------- 入口 ----------

case "${1:-}" in
    pre-up)
        pre_up
        ;;
    verify | cycle)
        verify_mode
        ;;
    scan)
        scan_cmd
        ;;
    apply)
        apply_cmd
        ;;
    apply-one | --apply)
        apply_one_cmd "${2:-}"
        ;;
    status)
        status_cmd
        ;;
    --help | -h | help)
        awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
        ;;
    *)
        echo "用法: $0 {pre-up|verify|scan|apply|apply-one IP:PORT|status}" >&2
        exit 1
        ;;
esac
