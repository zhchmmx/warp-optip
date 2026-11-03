#!/bin/bash
#
# warp-optip 通知模块
#
# 对外只有一个函数：
#   warp_notify <ok|fail> <一句话正文>
#
# 约定：
#   - 永远返回 0。发不出、没装 notify-send、没人登录，都不能影响主流程。
#   - 每条外部命令都带 timeout。verify 的时间预算很紧，通知不能拖住它。
#   - 本文件允许不存在：engine 先定义一个空的 warp_notify 兜底，
#     再判断 [[ -r ]] 后才 source。
#
# 为什么不能直接用 root 的 notify-send：
# 桌面通知发往「登录用户自己的 D-Bus session bus」（/run/user/<uid>/bus），
# 而 D-Bus 用 SO_PEERCRED 校验连接方的 uid。uid 对不上时连接会被 broker
# 立刻关闭，表现为 "The connection is closed" —— root 连用户总线正是这种
# 情况。所以发之前必须先变成那个用户本身；DISPLAY/XAUTHORITY/WAYLAND_DISPLAY
# 在这里完全不相关，通知只走 D-Bus。
#
# 另一个约束：不要为通知安装 <app_name>.desktop（当前 app_name 是 warp-optip）。
# GNOME 会按 app_name 反查 .desktop；一旦查到，通知就绑定到发送进程的 D-Bus
# 连接上，而 notify-send/gdbus 都是一次性进程，退出后 GNOME 会销毁整个 source，
# 通知在通知面板里也会被一起删掉。解析不到应用时走 generic source，通知才会留下。

# ---------- 可配置项（在 /etc/warp-optip.conf 里覆盖） ----------

WARP_NOTIFY="${WARP_NOTIFY:-1}"
WARP_NOTIFY_USER="${WARP_NOTIFY_USER:-}"
WARP_NOTIFY_DEDUPE="${WARP_NOTIFY_DEDUPE:-60}"
WARP_NOTIFY_TIMEOUT="${WARP_NOTIFY_TIMEOUT:-3}"
WARP_NOTIFY_TITLE_OK="${WARP_NOTIFY_TITLE_OK:-WARP 已连通}"
WARP_NOTIFY_TITLE_FAIL="${WARP_NOTIFY_TITLE_FAIL:-WARP 无法连通}"

NOTIFY_MARK_FILE="${RUN_DIR:-/run/warp-optip}/notify-last"

# ---------- 接收者 ----------

# 每行输出「uid user」。找不到接收者时不输出。
warp_notify_targets() {
    local uid user dir found=""

    if [[ -n "$WARP_NOTIFY_USER" ]]; then
        uid="$(id -u "$WARP_NOTIFY_USER" 2>/dev/null)" || return 1
        [[ -n "$uid" ]] || return 1
        printf '%s %s\n' "$uid" "$WARP_NOTIFY_USER"
        return 0
    fi

    # 有会话的用户优先
    if command -v loginctl >/dev/null 2>&1; then
        found="$(loginctl list-sessions --no-legend 2>/dev/null \
            | awk '$2 ~ /^[0-9]+$/ && $2 != "0" {print $2, $3}' \
            | sort -u)"
    fi

    # loginctl 不可用或没有会话时，才退回扫描 /run/user
    if [[ -z "$found" ]]; then
        found="$(
            for dir in /run/user/*; do
                [[ -S "$dir/bus" ]] || continue
                uid="${dir#/run/user/}"
                [[ "$uid" =~ ^[0-9]+$ ]] || continue
                [[ "$uid" != "0" ]] || continue
                user="$(id -un "$uid" 2>/dev/null)" || continue
                printf '%s %s\n' "$uid" "$user"
            done | sort -u -n
        )"
    fi

    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

# ---------- 发送 ----------

# warp_notify_send <uid> <user> <title> <body> <urgency>
warp_notify_send() {
    local uid="$1" user="$2" title="$3" body="$4" urg="$5"
    local dir="/run/user/$uid"
    local -a base
    local urg_byte=1

    [[ -S "$dir/bus" ]] || return 1

    if [[ "$(id -u)" -eq 0 ]]; then
        # 降权到目标用户，否则 uid 和总线主人不一致，连接会被直接关掉
        [[ -n "$user" ]] || return 1
        command -v runuser >/dev/null 2>&1 || return 1
        base=(runuser -u "$user" --
              env "XDG_RUNTIME_DIR=$dir" "DBUS_SESSION_BUS_ADDRESS=unix:path=$dir/bus")
    else
        # 非 root：只有目标是自己的时候发得出去
        [[ "$uid" == "$(id -u)" ]] || return 1
        base=(env "XDG_RUNTIME_DIR=$dir" "DBUS_SESSION_BUS_ADDRESS=unix:path=$dir/bus")
    fi

    # 正文里的引号会破坏 gdbus 的参数解析
    title="${title//\"/}"
    body="${body//\"/}"

    # gdbus 不会像 notify-send 那样从 -u 推导 urgency，必须显式写进 hints。
    # GNOME 对 urgency=low 的通知只收进列表、不弹横幅。
    case "$urg" in
        low)      urg_byte=0 ;;
        normal)   urg_byte=1 ;;
        critical) urg_byte=2 ;;
        *)        urg_byte=1 ;;
    esac

    if command -v notify-send >/dev/null 2>&1; then
        timeout "${WARP_NOTIFY_TIMEOUT}s" "${base[@]}" \
            notify-send -a warp-optip -i network-vpn -u "$urg" "$title" "$body" >/dev/null 2>&1 && return 0
    fi

    # 兜底：gdbus 属于 glib2，GNOME 上一定在；Silverblue 不能随手装 libnotify
    command -v gdbus >/dev/null 2>&1 || return 1
    timeout "${WARP_NOTIFY_TIMEOUT}s" "${base[@]}" \
        gdbus call --session \
            --dest org.freedesktop.Notifications \
            --object-path /org/freedesktop/Notifications \
            --method org.freedesktop.Notifications.Notify \
            "warp-optip" 0 "network-vpn" "$title" "$body" "[]" \
            "{'urgency': <byte $urg_byte>}" 5000 >/dev/null 2>&1
}

# ---------- 对外接口 ----------

warp_notify() {
    local state="${1:-}" detail="${2:-}"
    local title urg mark prev="" ts=0 now uid user sent=0

    [[ "$WARP_NOTIFY" == "1" ]] || return 0
    [[ -n "$state" ]] || return 0
    [[ "$WARP_NOTIFY_TIMEOUT" =~ ^[0-9]+$ ]] || WARP_NOTIFY_TIMEOUT=3
    [[ "$WARP_NOTIFY_DEDUPE" =~ ^[0-9]+$ ]] || WARP_NOTIFY_DEDUPE=60

    case "$state" in
        ok)   title="$WARP_NOTIFY_TITLE_OK";   urg=normal ;;
        fail) title="$WARP_NOTIFY_TITLE_FAIL"; urg=normal ;;
        *)    title="warp-optip";              urg=normal ;;
    esac

    # 同状态同正文在一个短窗口内只发一次：一次连接可能连续触发多次 verify
    mark="$state|$detail"
    if [[ -f "$NOTIFY_MARK_FILE" ]]; then
        prev="$(head -n1 "$NOTIFY_MARK_FILE" 2>/dev/null)" || prev=""
        ts="$(stat -c %Y "$NOTIFY_MARK_FILE" 2>/dev/null)" || ts=0
        [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
    fi
    now="$(date +%s)"
    if [[ "$prev" == "$mark" ]] && (( now - ts < WARP_NOTIFY_DEDUPE )); then
        return 0
    fi

    mkdir -p "${RUN_DIR:-/run/warp-optip}" 2>/dev/null || true
    printf '%s\n' "$mark" > "$NOTIFY_MARK_FILE" 2>/dev/null || true

    while read -r uid user; do
        [[ -n "$uid" ]] || continue
        if warp_notify_send "$uid" "$user" "$title" "$detail" "$urg"; then
            sent=1
        fi
    done < <(warp_notify_targets)

    if [[ "$sent" -eq 0 ]] && declare -f log >/dev/null 2>&1; then
        log "通知未送达（无人登录或缺少 notify-send/gdbus）: $mark"
    fi

    return 0
}
