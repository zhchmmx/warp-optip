#!/bin/bash
#
# warp-optip engine
#
# 模式：
#   pre-up          NetworkManager pre-up 阶段同步调用（不能调用 nmcli）。
#                   优选和实测都在这里完成：隧道在 pre-up 已经配好并在跑，
#                   每个候选先删掉 peer 再重建逼出一次冷握手，然后直接测
#                   warp=on。扫描的假阳性在激活完成前就被真实流量筛掉了。
#   verify          up 之后由 systemd 异步调用：
#                   pre-up 给了结论就只做持久化（写进 profile + 一次确认）；
#                   pre-up 没给结论或确认后隧道不通，退回 up 后逐个实测的
#                   老流程（modify + reapply + 实测），最后才考虑断开。
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
WARP_PREUP_TIMEOUT="${WARP_PREUP_TIMEOUT:-60}"

# pre-up 实测：候选数量不设单独上限，直接用 WARP_LIMIT（和 up 后修复循环同源），
# 时间预算装不下多少就自然截止。每个候选前先删掉 peer 再重建，逼出一次冷握手，
# 单轮预算必须罩住冷握手（这里实测 3~6 秒）+ TLS + 响应：curl 连接超时 5、总超时取预算值。
# 一个 VPN 连上要花掉 60 秒以上，说明当前网络本来就不适合连。
WARP_PREUP_ROUND_BUDGET="${WARP_PREUP_ROUND_BUDGET:-12}"

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

# ---------- 通知（可选模块） ----------
#
# 单独一个文件，并且允许它不存在：通知只是锦上添花，读不到、执行失败、
# 目标机器没装 notify-send，都不能影响连接和扫描。所以先定义空函数兜底，
# 再判断可读才 source。
warp_notify() { return 0; }
NOTIFY_LIB="${WARP_NOTIFY_LIB:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/warp-optip-notify.sh}"
if [[ -r "$NOTIFY_LIB" ]]; then
    # shellcheck disable=SC1090
    . "$NOTIFY_LIB"
fi

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

# 配置里的非数字值会让 $(( )) 直接终止脚本，pre-up 阶段那样等于什么都没做，
# 所以预算类参数一律钳制成正整数，无效时退回默认值。
# 单轮预算必须大于 curl 的 5 秒连接超时，否则每次都在握手完成前自己掐死，
# 所以它额外有一个 6 秒的下限。
for _var in WARP_SCAN_TIMEOUT WARP_PREUP_TIMEOUT WARP_PREUP_ROUND_BUDGET; do
    _val="${!_var}"
    if [[ ! "$_val" =~ ^[0-9]+$ ]] || (( 10#$_val < 1 )); then
        case "$_var" in
            WARP_SCAN_TIMEOUT)       _default=18 ;;
            WARP_PREUP_ROUND_BUDGET) _default=12 ;;
            *)                       _default=60 ;;
        esac
        log "配置 $_var=\"$_val\" 无效，改用 $_default"
        printf -v "$_var" '%s' "$_default"
    else
        _val=$(( 10#$_val ))
        if [[ "$_var" == "WARP_PREUP_ROUND_BUDGET" ]] && (( _val < 6 )); then
            log "配置 $_var=$_val 小于 curl 的 5 秒连接超时，改用 6"
            _val=6
        fi
        printf -v "$_var" '%s' "$_val"
    fi
done
unset _var _val _default

warp_is_active() {
    nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$WARP_CONN"
}

verify_warp() {
    local out
    out="$(curl -sS --connect-timeout "${1:-5}" --max-time "${2:-10}" "$WARP_CHECK_URL" 2>/dev/null)" || return 1
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

# 删掉 peer 再重建时需要原样恢复它的 allowed-ips，
# 否则隧道只剩下一个孤零零的 peer、什么都路由不进来。
# `wg show <iface> allowed-ips` 打出来的是**空格分隔**（真实机器上确认过：
# "0.0.0.0/0 ::/0"），`wg set` 要的是逗号分隔、不带空格。这里按逗号和空白切块
# 再重新拼，任何形式（"0.0.0.0/0, ::/0"、"0.0.0.0/0 ::/0"、逗号+空格）都能吃下。
# 曾经写成 gsub 去空格，把 "0.0.0.0/0 ::/0" 粘成了 "0.0.0.0/0::/0"——
# wg set 直接报 AllowedIP is not in the correct format，于是每次重建 peer 都失败。
wg_allowed_ips() {
    wg show "$1" allowed-ips 2>/dev/null \
        | awk -v p="$2" -F'\t' '
            $1 == p {
                n = split($2, tok, /[ \t,]+/)
                out = ""
                for (i = 1; i <= n; i++)
                    if (tok[i] != "") out = out (out == "" ? "" : ",") tok[i]
                print out
            }'
}

# wg set 只接受 "IP/前缀,IP/前缀"，拿到别的东西会把整个 peer 重建搞失败，
# 所以宁可不认这个值、走"只换 endpoint"的退化路径，也不要把怪字符串递给它。
wg_allowed_ips_valid() {
    [[ "$1" =~ ^[0-9A-Fa-f:.]+/[0-9]+(,[0-9A-Fa-f:.]+/[0-9]+)*$ ]]
}

# 最近一次成功握手的时刻（0 = 从来没有）。重建 peer 后必然是 0，
# 实测通过时它必须变成非 0，这一轮握手才归功于刚设上去的 endpoint。
wg_latest_handshake() {
    wg show "$1" latest-handshakes 2>/dev/null | awk -v p="$2" -F'\t' '$1 == p {print $2}'
}

# 每次 wg set 都带上它自己的报错。真实日志里出现过 20 个候选全部
# "重建 peer 失败"，而错误被 2>/dev/null 吞掉，根因排查无从下手。
wg_try() {
    local out rc
    out="$(wg set "$@" 2>&1)"
    rc=$?
    if (( rc != 0 )); then
        log "wg set $* 失败(退出码 $rc): ${out:-没有输出}"
        return "$rc"
    fi
    return 0
}

# 装回 peer 只失败一次不代表这条路不通：这次激活的 peer 是 NM 建的，
# 我们刚从外面把它删掉，NM 很可能正拿着同一份配置在改同一个设备。
# 等一秒再试一次，两次都不成才退回老流程。
wg_try_add() {
    wg_try "$@" && return 0
    sleep 1
    wg_try "$@"
}

# 接口是否存在，以及它的 ifindex。pre-up 里每轮实测前都要重新确认 ifindex，
# 因为用户在扫描期间断开连接的话，NM 会销毁并重建同名接口，
# 继续 wg set 就会作用到另一次激活的接口上。
iface_ifindex() {
    ip -o link show "$1" 2>/dev/null | awk -F': ' '{print $1}' | head -n1
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

# pre-up 实测用的候选序列：按延迟升序、排除当前正在用的 IP（它已经被
# 证明不够好，否则不用重新优选）、取前 count 个。
# 排除后一个都不剩时退回完整列表，至少试一次当前 IP，
# 这种情况一般是候选表里只剩当前 IP，试了也不亏。
candidate_list() {
    local cur="$1" count="$2" out
    local -a cur_parts
    IFS=: read -r -a cur_parts <<< "$cur"
    local cur_ip="${cur_parts[0]:-}"

    out="$(parse_candidates "$WARP_RESULT_CSV" 2>/dev/null \
        | awk -F'\t' -v cur="$cur_ip" 'cur == "" || index($1, cur ":") != 1' \
        | head -n "$count")"
    if [[ -z "$out" ]]; then
        parse_candidates "$WARP_RESULT_CSV" 2>/dev/null | head -n "$count"
        return
    fi
    printf '%s\n' "$out"
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
#
# NM 在 ip-check 结束、l3cfg（地址/路由/规则/fwmark）已经全部提交之后才派发
# pre-up，并且卡住激活等脚本返回。也就是说 pre-up 阶段隧道不只是"存在"，
# 而是已经在承载流量了：`wg show` 有值、`wg set` 生效、之后的流量会跟着
# 运行时 endpoint 走。所以真实的连通性实测可以、也应该放在这里做，
# 而不是等 up 之后由 verify 边试边换——后者会让用户在几十秒里用一条坏隧道。
#
# pre-up 唯一不能做的是 nmcli（和 NM 死锁），运行时改 endpoint 用 wg set 就够了。
# 把 endpoint 写进 profile 仍然要等 up 之后，但那只是持久化，不参与选路。
#
# 实测的判据必须是"这一轮真的和这个 endpoint 握过手，并且握手之后流量过得去"。
# 只看 curl warp=on 不行：会话按 peer 存、Cloudflare 的 IP 共用一把私钥，
# 一次成功握手会让后面所有 endpoint 都"通"。只看握手也不行：握手成功只说明
# 对端应答了密钥包，不说明这个 IP 能正常转发我们的流量。
#
# 这次激活的 peer 是 NM 建的，删它这件事本身就不是我们的权限：
# 所以先用激活时那个 endpoint 演练一次"删除 + 原样装回"，演练过了才在
# 候选循环里删；任何一次装不回去都立刻停止实测并把错误写进日志，
# 由 verify 的 reapply 把 peer 修回来——绝不让接口停在"没有 peer"的状态上。

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

    # 只让本次 pre-up 实测通过的 endpoint 进入 verify
    rm -f "$PENDING_ENDPOINT_FILE" 2>/dev/null || true

    local iface="${DEVICE_IFACE:-$IFACE}"
    local idx pub aips cur_ep ep lat hs0 hs1
    local tested=0 attempts=0 reset_ok=0 peer_touched=0
    local deadline=$(( $(date +%s) + 10#$WARP_PREUP_TIMEOUT ))
    local remain

    idx="$(iface_ifindex "$iface")"
    pub="$(wg_peer_pubkey "$iface")"
    cur_ep="$(wg_peer_endpoint "$iface")"

    [[ -n "$cur_ep" ]] && printf '%s\n' "$cur_ep" > "$OLD_ENDPOINT_FILE"

    if [[ -z "$idx" || -z "$pub" ]]; then
        log "pre-up: 接口 $iface 或它的 peer 还没就绪，本次不做实测"
        return 0
    fi

    aips="$(wg_allowed_ips "$iface" "$pub")"
    if [[ -n "$aips" ]] && ! wg_allowed_ips_valid "$aips"; then
        log "pre-up: allowed-ips 解析出 \"$aips\"，不是 wg set 接受的格式，按读不到处理"
        aips=""
    fi
    if [[ -z "$aips" ]]; then
        # 读不到 allowed-ips 就不敢删 peer：删了没法还原等于亲手拆掉隧道。
        # 这种情况下会话是继承来的，绝大多数候选都会因为"握手没更新"被判不算通过。
        log "pre-up: 读不到 peer $pub 的 allowed-ips，无法重建 peer 逼出冷握手，实测会漏掉假阳性"
    fi

    if ! scan_direct; then
        log "pre-up: 扫描失败，保持当前 endpoint ${cur_ep:-未知}"
        return 0
    fi

    # 实测前先拿激活时那个 endpoint 做一次"删了再原样装回去"的演练。
    # 这一步不能省：真实日志里出现过 20 个候选全部"重建 peer 失败"——
    # 删除成功、装回去失败，接口被删到没有 peer，而错误被 2>/dev/null 吞了。
    # 演练告诉我们本机的 NM 让不让动这次激活的 peer，据此决定走哪条实测路径。
    # 放在扫描之后：时间已经不够测任何东西的话就不该白手打掉 NM 刚建好的会话。
    if [[ -n "$aips" && -n "$cur_ep" ]] &&
       (( deadline - $(date +%s) > WARP_PREUP_ROUND_BUDGET )); then
        if wg_try "$iface" peer "$pub" remove; then
            peer_touched=1
            if wg_try_add "$iface" peer "$pub" allowed-ips "$aips" endpoint "$cur_ep"; then
                reset_ok=1
                log "pre-up: peer 重建可用（allowed-ips $aips，演练 endpoint $cur_ep）"
            else
                # peer 已经删掉了却装不回去，此时再怎么 wg set 都只是在残骸上操作，
                # 收手，让 verify 用 connection modify + reapply 把 peer 装回来。
                # 顺手把设备公钥一起记下来：报错是参数问题还是设备没配上私钥，
                # 靠这一行就能分开。
                log "pre-up: peer 删除成功但装不回去，本次不做实测，交给 verify 用 reapply 修复（设备公钥: $(wg show "$iface" public-key 2>&1)）"
                return 0
            fi
        else
            log "pre-up: 本机不允许删除这次激活的 peer，退化成只换 endpoint（握手闸门仍能挡住假阳性）"
        fi
    fi

    while IFS=$'\t' read -r ep lat; do
        [[ -n "$ep" ]] || continue

        # 用户在扫描期间断开的话，NM 会销毁并重建同名接口。ifindex 变了就说明
        # 这个 peer 已经不属于本次激活，再 wg set 会写到别的实例上。
        if [[ "$(iface_ifindex "$iface")" != "$idx" ]]; then
            log "pre-up: 接口 $iface 已消失或不是原来那个，停止实测"
            return 0
        fi

        remain=$(( deadline - $(date +%s) ))
        if (( remain <= WARP_PREUP_ROUND_BUDGET )); then
            log "pre-up: 剩余 ${remain}s 不够再测一轮（单轮 ${WARP_PREUP_ROUND_BUDGET}s，上限 ${WARP_PREUP_TIMEOUT}s），停止实测"
            break
        fi
        attempts=$((attempts + 1))

        # WireGuard 的会话是挂在 peer 上的，和 endpoint 无关；而 Cloudflare 这批
        # anycast IP 共用同一把私钥。所以只要之前有任何一次成功握手，
        # 内核不会仅因为换了 endpoint 就重新握手（REKEY_AFTER_TIME_USELESS ≈ 11s），
        # curl 会对任意 endpoint 都返回 warp=on —— 这就是扫描假阳性的来源。
        # 每个候选前先删掉 peer 再原样重建，逼出一次真正的冷握手。
        if [[ "$reset_ok" -eq 1 ]]; then
            wg_try "$iface" peer "$pub" remove
            if ! wg_try_add "$iface" peer "$pub" allowed-ips "$aips" endpoint "$ep"; then
                # 装不回去就不要再试下一个候选：接口现在没有 peer，
                # 继续循环只会把它删得更干净。
                log "pre-up: 重建 peer 失败，停止实测"
                if ! wg_try_add "$iface" peer "$pub" allowed-ips "$aips" endpoint "$cur_ep"; then
                    log "pre-up: 还原 peer 也失败，交给 verify 用 reapply 修复"
                fi
                break
            fi
        else
            # 重建不可用（读不到 allowed-ips，或上面的演练没过去），
            # 退化成只换 endpoint。此时握手闸门仍然有效：会话是继承来的，
            # 握手时刻不会因为换 endpoint 而前进，所以假的 warp=on 会被判不通过。
            if ! wg_try "$iface" peer "$pub" endpoint "$ep"; then
                log "pre-up: 换 endpoint 失败，停止实测"
                break
            fi
        fi
        tested=$((tested + 1))
        hs0="$(wg_latest_handshake "$iface" "$pub")"

        # curl 既是驱动握手的数据包，也是最终判据。冷握手在这里要 3~6 秒，
        # 内核这期间把包暂存在 staged-packets 队列里、握手完成才放行，
        # 所以连接超时必须给到 5 秒，否则每次都在包被释放前掐死自己（假阴性）。
        if verify_warp 5 "$WARP_PREUP_ROUND_BUDGET"; then
            hs1="$(wg_latest_handshake "$iface" "$pub")"
            if [[ "$hs1" == "$hs0" ]]; then
                # 握手时刻没前进 = 这一轮根本没和这个 endpoint 握过手，
                # warp=on 是继承来的会话给的，不能记在这个 endpoint 头上。
                log "pre-up: $ep 返回 warp=on 但握手没有更新（${hs0:-0}），不计通过，试下一个"
                continue
            fi
            printf '%s\n' "$ep" > "$PENDING_ENDPOINT_FILE"
            log "pre-up: 实测通过 $ep（扫描延迟 ${lat}ms，第 $tested 个候选，握手 ${hs0:-0}->${hs1:-0}）"
            return 0
        fi

        hs1="$(wg_latest_handshake "$iface" "$pub")"
        log "pre-up: 扫描 ${lat}ms 很好但实测不通 $ep（握手 ${hs0:-0}->${hs1:-0}），试下一个"
    done < <(candidate_list "$cur_ep" "$WARP_LIMIT")

    # 全部失败：把运行时 endpoint 还原成激活时的那个，宁可用一条已知的坏隧道，
    # 也不要把最后一次实测失败的 endpoint 留在上面。
    # verify 会看到"没有实测通过的 endpoint"，退回 up 后逐个实测的老流程。
    if [[ "$tested" -eq 0 ]]; then
        # 一轮都没实测（时间不够、peer 装不上）。演练做过的话 peer 已经被
        # 原样装回激活时的 endpoint；没做过就压根没碰它，两种情况都不用再动。
        if [[ "$peer_touched" -eq 1 ]]; then
            log "pre-up: 本轮没有实测任何候选，peer 已还原成激活时的 endpoint ${cur_ep:-未知}"
        else
            log "pre-up: 本轮没有实测任何候选，peer 未动，运行时 endpoint 保持 ${cur_ep:-未知}"
        fi
        return 0
    fi
    if [[ -n "$cur_ep" ]]; then
        if [[ "$reset_ok" -eq 1 ]]; then
            wg_try "$iface" peer "$pub" remove || true
            wg_try_add "$iface" peer "$pub" allowed-ips "$aips" endpoint "$cur_ep" || true
        else
            wg_try "$iface" peer "$pub" endpoint "$cur_ep" || true
        fi
        log "pre-up: $tested/$attempts 个候选实测均不通，运行时 endpoint 已回退到 ${cur_ep}"
    else
        log "pre-up: $tested/$attempts 个候选实测均不通，且没有可回退的旧 endpoint"
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

# up 之后优先信任 pre-up 的实测结论：候选已经在激活前用真实流量 + 全新会话
# 验过，这里只剩把 endpoint 写进 profile（profile 只能在 up 之后改）和一次确认。
# pre-up 没给结论、或确认后隧道又不通时，退回改动之前一直在用的老流程：
# 逐个候选 modify + reapply + 实测。reapply 会重建 peer，每个候选都是全新会话，
# 这个循环本身不会产生假阳性，实测下来也几乎没出过问题，所以留作兜底。
# 断开隧道是最后一步：所有候选加旧 endpoint 都实测不通才做。
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

    local cur_ep pending restore_ep ok_ep try_ep
    cur_ep="$(nmcli_endpoint)"
    pending=""
    [[ -f "$PENDING_ENDPOINT_FILE" ]] && pending="$(cat "$PENDING_ENDPOINT_FILE" 2>/dev/null || true)"
    restore_ep="$cur_ep"
    if [[ -n "$pending" && -s "$OLD_ENDPOINT_FILE" ]]; then
        restore_ep="$(cat "$OLD_ENDPOINT_FILE" 2>/dev/null || true)"
    fi

    log "verify: profile endpoint=${cur_ep:-未知} pre-up 实测通过=${pending:-无}"

    # 等激活彻底结束，否则 reapply 可能被 NM 拒绝
    sleep 2

    rm -f "$PENDING_ENDPOINT_FILE" 2>/dev/null || true

    if [[ -n "$pending" ]]; then
        # 运行时 endpoint 已经是 pre-up 用 wg set 设好的 $pending，隧道此刻就在用它，
        # 所以这里只写 profile、绝不 reapply：reapply 会重建 peer 丢掉会话，
        # 把一条刚验过的好隧道打断，这正是上一版实测失败的原因。
        if [[ "$pending" != "$cur_ep" ]]; then
            if set_endpoint_profile "$pending"; then
                log "verify: 已持久化 pre-up 选定的 $pending"
            else
                log "verify: 持久化失败，保持 pre-up 设好的运行时 endpoint"
            fi
        fi

        if verify_warp; then
            # 记的是"此刻真正在承载流量的 endpoint"。正常情况下就是 pre-up 设上去的
            # $pending；万一 NM 在激活收尾时用 profile 覆盖了运行时值，这里也会如实记下。
            ok_ep="$(wg_peer_endpoint "${DEVICE_IFACE:-$IFACE}")"
            [[ -n "$ok_ep" ]] || ok_ep="$pending"
            printf '%s\n' "$ok_ep" > "$LAST_ENDPOINT_FILE"
            log "verify: 连通正常，运行时 endpoint=$ok_ep，profile 已写入 $pending"
            warp_notify ok "endpoint $ok_ep"
            return 0
        fi

        log "verify: pre-up 实测通过过 $pending，但此刻隧道不通，改用 up 后逐个实测"
    elif verify_warp; then
        # pre-up 没做实测（扫描失败、没抢到锁、被 self-up 跳过、时间预算不够），
        # 隧道本身却是通的：保持现状，记下当前 endpoint 就够了。
        ok_ep="$(wg_peer_endpoint "${DEVICE_IFACE:-$IFACE}")"
        [[ -n "$ok_ep" ]] || ok_ep="$cur_ep"
        printf '%s\n' "$ok_ep" > "$LAST_ENDPOINT_FILE"
        log "verify: 连通正常，当前 endpoint=${ok_ep:-未知}"
        warp_notify ok "endpoint ${ok_ep:-未知}"
        return 0
    fi

    # 走到这里隧道确定不通。老流程兜底，排除掉刚才那个也不通的 endpoint。
    try_ep="$cur_ep"
    [[ -n "$pending" ]] && try_ep="$pending"

    if try_candidates "$try_ep"; then
        ok_ep="$(cat "$LAST_ENDPOINT_FILE" 2>/dev/null || true)"
        [[ -n "$ok_ep" ]] || ok_ep="$try_ep"
        log "verify: up 后实测已切换到 $ok_ep"
        warp_notify ok "endpoint $ok_ep"
        return 0
    fi

    if warp_is_active && [[ -n "$restore_ep" ]] && try_endpoint "$restore_ep"; then
        printf '%s\n' "$restore_ep" > "$LAST_ENDPOINT_FILE"
        log "verify: 所有候选都不通，已回退到 $restore_ep"
        warp_notify ok "候选均不通，已回退到 $restore_ep"
        return 1
    fi

    log "verify: 候选与旧 endpoint 均实测不通，断开 $WARP_CONN 以保留物理网络"
    warp_notify fail "所有 endpoint 都不通，已断开隧道走物理网络"
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
    echo "运行时EP   : $(wg_peer_endpoint "${DEVICE_IFACE:-$IFACE}" 2>/dev/null || echo 未知)"
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
