#!/bin/bash
#
# warp-optip uninstaller
#
set -euo pipefail

PREFIX="/usr/local"
CONF="/etc/warp-optip.conf"
STATE_DIR="/var/lib/warp-optip"
BACKUP_ROOT="/var/backups/warp-optip"
UNIT="/etc/systemd/system/warp-optip.service"
PREUP_SCRIPT="/etc/NetworkManager/dispatcher.d/pre-up.d/90-warp-optip"
VERIFY_SCRIPT="/etc/NetworkManager/dispatcher.d/90-warp-optip-verify"

CONN=""
KEEP_CONNECTION=0
PURGE=0
DRY_RUN=0

usage() {
    cat <<EOF
用法: sudo $0 [选项]

  --prefix DIR         安装前缀，默认 /usr/local
  --name NAME          连接名，默认读取 /etc/warp-optip.conf
  --keep-connection    保留 NetworkManager 连接
  --remove-connection  删除安装器创建的连接（默认）
  --purge              同时删除状态、账号、日志、备份
  --dry-run            只打印操作
  -h, --help           显示帮助
EOF
}

info() { printf '[uninstall] %s\n' "$*"; }
warn() { printf '[uninstall][警告] %s\n' "$*" >&2; }

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift ;;
        --name) CONN="$2"; shift ;;
        --keep-connection) KEEP_CONNECTION=1 ;;
        --remove-connection) KEEP_CONNECTION=0 ;;
        --purge) PURGE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
    shift
done

LIBDIR="$PREFIX/lib/warp-optip"
BINDIR="$PREFIX/bin"

if [[ "$DRY_RUN" -eq 0 && "$(id -u)" -ne 0 ]]; then
    printf '请用 sudo 运行: sudo %s\n' "$0" >&2
    exit 1
fi

if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    . "$CONF"
    [[ -n "$CONN" ]] || CONN="${WARP_CONN:-warp-optip}"
    [[ -n "${WARP_STATE_DIR:-}" ]] && STATE_DIR="$WARP_STATE_DIR"
fi
[[ -n "$CONN" ]] || CONN="warp-optip"

info "连接名: $CONN"

# 停止并删除服务
if command -v systemctl >/dev/null 2>&1; then
    run systemctl stop warp-optip.service 2>/dev/null || true
    run systemctl disable warp-optip.service 2>/dev/null || true
fi

run rm -f "$UNIT"
run rm -f "$PREUP_SCRIPT"
run rm -f "$VERIFY_SCRIPT"
run rm -f "$BINDIR/warp-optip"
run rm -rf "$LIBDIR"
run rm -f "$CONF"
run rm -rf /run/warp-optip

if [[ "$DRY_RUN" -eq 0 ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi
if [[ "$DRY_RUN" -eq 0 ]] && command -v nmcli >/dev/null 2>&1; then
    nmcli connection reload >/dev/null 2>&1 || true
fi

# 连接处理：只删除安装器创建的连接
if [[ "$KEEP_CONNECTION" -eq 0 ]]; then
    if nmcli connection show "$CONN" >/dev/null 2>&1; then
        run nmcli connection delete "$CONN"
    else
        info "连接不存在，跳过删除: $CONN"
    fi
else
    info "保留连接: $CONN"
fi

if [[ "$PURGE" -eq 1 ]]; then
    run rm -rf "$STATE_DIR"
    run rm -rf "$BACKUP_ROOT"
    info "已清理状态、账号、日志、备份"
fi

cat <<EOF

卸载完成。

- 程序、Dispatcher、systemd 服务已删除
- 安装器创建的连接: $CONN $([[ "$KEEP_CONNECTION" -eq 1 ]] && echo '（已保留）' || echo '（已删除）')
- 其他 NetworkManager 连接（包括 wgcf-profile）未改动

如需恢复旧连接:
  nmcli connection up wgcf-profile
EOF
