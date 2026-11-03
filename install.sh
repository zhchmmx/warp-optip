#!/bin/bash
#
# warp-optip installer
#
set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="/usr/local"
LIBDIR="$PREFIX/lib/warp-optip"
BINDIR="$PREFIX/bin"
CONF="/etc/warp-optip.conf"
STATE_DIR="/var/lib/warp-optip"
BACKUP_ROOT="/var/backups/warp-optip"
UNIT="/etc/systemd/system/warp-optip.service"
PREUP_DIR="/etc/NetworkManager/dispatcher.d/pre-up.d"
PREUP_SCRIPT="$PREUP_DIR/90-warp-optip"
VERIFY_SCRIPT="/etc/NetworkManager/dispatcher.d/90-warp-optip-verify"

WGCF_VERSION=""                 # 为空表示每次安装都查询 GitHub 最新版
WGCF_FALLBACK_VERSION="2.2.32"  # 仅当最新版获取和下载都失败时兜底
WGCF_NET_TIMEOUT="${WGCF_NET_TIMEOUT:-8}"  # 查询 GitHub 的单次超时（秒）
CONN=""
NAME=""
ACCOUNT=""
PROFILE=""
WGCF_BIN=""
WARP_BIN=""
WGCF_URL=""
WARP_URL=""
NO_DOWNLOAD=0
NO_REGISTER=0
AUTOCONNECT=0
PERMISSIONS_USER=""
NO_PERMISSIONS=0
ACTIVATE=0
NO_DISPATCHER=0
NO_SERVICE=0
DRY_RUN=0
REUSE=0

usage() {
    cat <<EOF
用法: sudo $0 [选项]

  --prefix DIR             安装前缀，默认 /usr/local
  --name NAME              新连接名，默认 warp-optip
  --state-dir DIR          状态目录，默认 /var/lib/warp-optip
  --wgcf-bin PATH          指定 wgcf 二进制（跳过下载）
  --warp-bin PATH          指定优选扫描器（跳过下载）
  --wgcf-version VERSION   固定 wgcf 版本（默认每次拉取 GitHub 最新版）
  --wgcf-url URL           覆盖 wgcf 下载地址（会跳过最新版查询）
  --warp-url URL           覆盖扫描器下载地址
  --no-download            只使用本地文件，缺失则报错
  --account FILE           使用现有 wgcf-account.toml
  --profile FILE           使用现有 WireGuard profile
  --register               强制重新注册 wgcf 账号
  --no-register            禁止注册；必须配合 --account 或 --profile
  --autoconnect            设置 connection.autoconnect yes
  --permissions USER       设置 connection.permissions user:USER
  --no-permissions         不设置 connection.permissions
  --no-dispatcher          不安装 Dispatcher
  --no-service             不安装 systemd service
  --activate               安装完成后立即 up 新连接
  --dry-run                只打印将执行的操作
  -h, --help               显示帮助
EOF
}

info() { printf '[install] %s\n' "$*"; }
warn() { printf '[install][警告] %s\n' "$*" >&2; }
die() { printf '[install][错误] %s\n' "$*" >&2; exit 1; }

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

arch_affix() {
    case "$(uname -m)" in
        i386 | i686) echo "386" ;;
        x86_64 | x64 | amd64) echo "amd64" ;;
        armv8 | armv8l | arm64 | aarch64) echo "arm64" ;;
        s390x) echo "s390x" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

user_home() {
    local u="$1"
    [[ -n "$u" ]] || return 1
    getent passwd "$u" | cut -d: -f6
}

conn_exists() {
    nmcli connection show "$1" >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift ;;
        --name) NAME="$2"; shift ;;
        --state-dir) STATE_DIR="$2"; shift ;;
        --wgcf-bin) WGCF_BIN="$2"; shift ;;
        --warp-bin) WARP_BIN="$2"; shift ;;
        --wgcf-version) WGCF_VERSION="$2"; shift ;;
        --wgcf-url) WGCF_URL="$2"; shift ;;
        --warp-url) WARP_URL="$2"; shift ;;
        --no-download) NO_DOWNLOAD=1 ;;
        --account) ACCOUNT="$2"; shift ;;
        --profile) PROFILE="$2"; shift ;;
        --register) NO_REGISTER=0 ;;
        --no-register) NO_REGISTER=1 ;;
        --autoconnect) AUTOCONNECT=1 ;;
        --permissions) PERMISSIONS_USER="$2"; shift ;;
        --no-permissions) NO_PERMISSIONS=1 ;;
        --no-dispatcher) NO_DISPATCHER=1 ;;
        --no-service) NO_SERVICE=1 ;;
        --activate) ACTIVATE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage; die "未知参数: $1" ;;
    esac
    shift
done

LIBDIR="$PREFIX/lib/warp-optip"
BINDIR="$PREFIX/bin"

if [[ "$DRY_RUN" -eq 0 && "$(id -u)" -ne 0 ]]; then
    die "请用 sudo 运行: sudo $0"
fi

for c in nmcli systemctl curl awk flock install timeout; do
    command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
done
command -v wg >/dev/null 2>&1 || die "缺少命令: wg（wireguard-tools）"

# 优选 endpoint 只通过 connection modify + device reapply 生效，
# 不再有 connection down/up 兜底，所以显式提示这一依赖。
if LC_ALL=C nmcli device reapply --help >/dev/null 2>&1; then
    info "nmcli device reapply 可用"
else
    warn "无法确认 nmcli device reapply 可用（需要 NetworkManager >= 1.12）。"
    warn "若后续日志出现 'reapply 失败'，说明优选 endpoint 无法生效，需升级 NetworkManager。"
fi

ARCH="$(arch_affix)"
SUDO_USER_NAME="${SUDO_USER:-}"
TARGET_HOME="$(user_home "$SUDO_USER_NAME" 2>/dev/null || true)"

# ---------- 选择连接名 ----------

if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    . "$CONF"
    if [[ -n "${WARP_CONN:-}" ]] && conn_exists "$WARP_CONN"; then
        CONN="$WARP_CONN"
        REUSE=1
        info "检测到已有安装，复用连接: $CONN"
    fi
fi

if [[ -z "$CONN" ]]; then
    base="${NAME:-warp-optip}"
    candidate="$base"
    i=2
    while conn_exists "$candidate"; do
        candidate="${base}-${i}"
        i=$((i + 1))
    done
    CONN="$candidate"
fi

if [[ ! "$CONN" =~ ^[A-Za-z0-9_-]{1,15}$ ]]; then
    die "连接名不合法（1~15 字符，字母/数字/_/-）: $CONN"
fi

info "连接名: $CONN"

if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF
[dry-run] 将执行：
  - 安装连接名: $CONN (已存在则复用: $REUSE)
  - 安装目录: $LIBDIR
  - 状态目录: $STATE_DIR
  - 配置文件: $CONF
  - systemd 单元: $UNIT
  - pre-up 脚本: $PREUP_SCRIPT
  - up 校验脚本: $VERIFY_SCRIPT
  - wgcf: ${WGCF_BIN:-将查询 GitHub 最新版并下载（--no-download 时只用本地）}
  - warp: ${WARP_BIN:-本地优先，缺失则下载}
[dry-run] 不做任何修改。
EOF
    exit 0
fi

# ---------- 查找二进制 ----------

try_bin() {
    local p="$1" flag="$2"
    [[ -f "$p" ]] || return 1
    [[ -x "$p" ]] || chmod +x "$p" 2>/dev/null || return 1
    "$p" "$flag" >/dev/null 2>&1
}

find_local() {
    local kind="$1" p
    case "$kind" in
        wgcf)
            for p in \
                "$SRC_DIR/wgcf" \
                "$SRC_DIR/vendor/wgcf" \
                "$SRC_DIR"/wgcf_*_linux_"${ARCH}" \
                "$SRC_DIR"/vendor/wgcf_*_linux_"${ARCH}" \
                "$LIBDIR/wgcf" \
                "${TARGET_HOME:-/nonexistent}/.local/state/warp-optip/wgcf"; do
                [[ -f "$p" ]] || continue
                if try_bin "$p" --help; then
                    printf '%s\n' "$p"
                    return 0
                fi
            done
            ;;
        warp)
            for p in \
                "$SRC_DIR/warp" \
                "$SRC_DIR/vendor/warp" \
                "$SRC_DIR/warp-linux-${ARCH}" \
                "$SRC_DIR/vendor/warp-linux-${ARCH}" \
                "$LIBDIR/warp" \
                "${TARGET_HOME:-/nonexistent}/.local/state/warp-optip/warp"; do
                [[ -f "$p" ]] || continue
                if try_bin "$p" -h; then
                    printf '%s\n' "$p"
                    return 0
                fi
            done
            ;;
    esac
    return 1
}

download_bin() {
    local url="$1" out="$2" what="$3"
    [[ "$NO_DOWNLOAD" -eq 0 ]] || return 1
    info "下载 $what: $url"
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 180 -o "$out" "$url"; then
        rm -f "$out"
        return 1
    fi
    chmod +x "$out"
    return 0
}

# 查询 GitHub 最新 wgcf Release，返回 "version<TAB>url"
resolve_wgcf_latest() {
    local json="" ver="" url="" effective=""
    local net_timeout="${WGCF_NET_TIMEOUT:-8}"
    json="$(curl -fsSL --connect-timeout "$net_timeout" --max-time "$net_timeout" \
        -H 'Accept: application/vnd.github+json' \
        'https://api.github.com/repos/ViRb3/wgcf/releases/latest' 2>/dev/null || true)"

    if [[ -n "$json" ]]; then
        ver="$(printf '%s\n' "$json" \
            | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' \
            | head -n1)"
        url="$(printf '%s\n' "$json" \
            | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed 's/.*"\(https[^"]*\)"/\1/' \
            | grep -E "_linux_${ARCH}$" \
            | head -n1)"
    fi

    if [[ -z "$ver" ]]; then
        effective="$(curl -fsSIL --connect-timeout "$net_timeout" --max-time "$net_timeout" \
            -o /dev/null -w '%{url_effective}' \
            'https://github.com/ViRb3/wgcf/releases/latest' 2>/dev/null || true)"
        ver="${effective##*/}"
        ver="${ver#v}"
    fi

    [[ "$ver" =~ ^[0-9]+([.][0-9]+)+$ ]] || return 1

    if [[ -z "$url" ]]; then
        url="https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${ARCH}"
    fi

    printf '%s\t%s\n' "$ver" "$url"
}

TMPDIR_INSTALL="$(mktemp -d /tmp/warp-optip-install.XXXXXX)"
trap 'rm -rf "$TMPDIR_INSTALL"' EXIT

if [[ -n "$WGCF_BIN" ]]; then
    [[ -f "$WGCF_BIN" ]] || die "wgcf 不存在: $WGCF_BIN"
    try_bin "$WGCF_BIN" --help || die "wgcf 无法运行: $WGCF_BIN"
    info "wgcf: 使用指定文件 $WGCF_BIN"
elif [[ "$NO_DOWNLOAD" -eq 1 ]]; then
    WGCF_BIN="$(find_local wgcf || true)"
    [[ -n "$WGCF_BIN" ]] || die "本地没有 wgcf，且指定了 --no-download"
    info "wgcf: 本地文件 $WGCF_BIN"
else
    WGCF_VER=""
    WGCF_DL_URL=""

    if [[ -n "$WGCF_URL" ]]; then
        WGCF_DL_URL="$WGCF_URL"
        info "wgcf: 使用自定义下载地址"
    elif [[ -n "$WGCF_VERSION" ]]; then
        WGCF_VER="$WGCF_VERSION"
        WGCF_DL_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${ARCH}"
        info "wgcf: 固定版本 $WGCF_VER"
    else
        WGCF_RESOLVED="$(resolve_wgcf_latest || true)"
        if [[ -n "$WGCF_RESOLVED" ]]; then
            IFS=$'\t' read -r WGCF_VER WGCF_DL_URL <<< "$WGCF_RESOLVED"
            info "wgcf: GitHub 最新版本 $WGCF_VER"
        else
            warn "无法查询 wgcf 最新版本，将尝试本地文件或兜底版本"
        fi
    fi

    if [[ -n "$WGCF_DL_URL" ]]; then
        WGCF_BIN="$TMPDIR_INSTALL/wgcf"
        if ! download_bin "$WGCF_DL_URL" "$WGCF_BIN" "wgcf"; then
            warn "wgcf 下载失败，尝试本地文件"
            WGCF_BIN="$(find_local wgcf || true)"
            if [[ -z "$WGCF_BIN" ]]; then
                warn "本地没有可用 wgcf，尝试兜底版本 $WGCF_FALLBACK_VERSION"
                WGCF_DL_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_FALLBACK_VERSION}/wgcf_${WGCF_FALLBACK_VERSION}_linux_${ARCH}"
                WGCF_BIN="$TMPDIR_INSTALL/wgcf"
                download_bin "$WGCF_DL_URL" "$WGCF_BIN" "wgcf" \
                    || die "下载 wgcf 失败；请把 wgcf 放到项目目录或用 --wgcf-bin 指定"
            fi
        fi
    else
        WGCF_BIN="$(find_local wgcf || true)"
        if [[ -z "$WGCF_BIN" ]]; then
            warn "本地没有 wgcf，尝试兜底版本 $WGCF_FALLBACK_VERSION"
            WGCF_DL_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_FALLBACK_VERSION}/wgcf_${WGCF_FALLBACK_VERSION}_linux_${ARCH}"
            WGCF_BIN="$TMPDIR_INSTALL/wgcf"
            download_bin "$WGCF_DL_URL" "$WGCF_BIN" "wgcf" \
                || die "下载 wgcf 失败；请把 wgcf 放到项目目录或用 --wgcf-bin 指定"
        fi
    fi

    if ! try_bin "$WGCF_BIN" --help; then
        warn "下载/选定的 wgcf 无法运行，尝试本地文件"
        WGCF_BIN="$(find_local wgcf || true)"
        [[ -n "$WGCF_BIN" ]] || die "wgcf 无法运行，且本地没有可用文件"
        try_bin "$WGCF_BIN" --help || die "wgcf 无法运行: $WGCF_BIN"
    fi
fi

if [[ -n "$WARP_BIN" ]]; then
    [[ -f "$WARP_BIN" ]] || die "扫描器不存在: $WARP_BIN"
    try_bin "$WARP_BIN" -h || die "扫描器无法运行: $WARP_BIN"
else
    WARP_BIN="$(find_local warp || true)"
    if [[ -z "$WARP_BIN" ]]; then
        [[ "$NO_DOWNLOAD" -eq 0 ]] || die "本地没有扫描器，且指定了 --no-download"
        WARP_URL="${WARP_URL:-https://gitlab.com/Misaka-blog/warp-script/-/raw/main/files/warp-yxip/warp-linux-${ARCH}}"
        WARP_BIN="$TMPDIR_INSTALL/warp"
        download_bin "$WARP_URL" "$WARP_BIN" "warp" \
            || die "下载扫描器失败；请把 warp 放到项目目录或用 --warp-bin 指定"
    fi
fi

info "wgcf: $WGCF_BIN"
info "warp: $WARP_BIN"

# ---------- 备份 ----------

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"
backup_file() {
    local src="$1"
    [[ -e "$src" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$src" "$BACKUP_DIR/" 2>/dev/null || warn "备份失败: $src"
}
backup_file "$CONF"
backup_file "$UNIT"
backup_file "$PREUP_SCRIPT"
backup_file "$VERIFY_SCRIPT"
if [[ -d "$STATE_DIR" ]]; then
    backup_file "$STATE_DIR/wgcf-account.toml"
    for f in "$STATE_DIR"/*.conf; do
        backup_file "$f"
    done
fi

# ---------- 安装程序文件 ----------

run install -d -m 0755 "$LIBDIR" "$BINDIR"
run install -d -m 0700 "$STATE_DIR"
run chmod 0700 "$STATE_DIR"
run install -d -m 0755 "$PREUP_DIR"
run install -d -m 0755 /run/warp-optip

if [[ "$WGCF_BIN" != "$LIBDIR/wgcf" ]]; then
    run install -m 0755 "$WGCF_BIN" "$LIBDIR/wgcf"
fi
if [[ "$WARP_BIN" != "$LIBDIR/warp" ]]; then
    run install -m 0755 "$WARP_BIN" "$LIBDIR/warp"
fi
run install -m 0755 "$SRC_DIR/lib/warp-optip-engine.sh" "$LIBDIR/warp-optip-engine.sh"
run install -m 0755 "$SRC_DIR/bin/warp-optip" "$BINDIR/warp-optip"

if [[ "$NO_SERVICE" -eq 0 ]]; then
    sed "s#/usr/local/bin/warp-optip#$BINDIR/warp-optip#g" \
        "$SRC_DIR/systemd/warp-optip.service" > "$TMPDIR_INSTALL/warp-optip.service"
    run install -m 0644 "$TMPDIR_INSTALL/warp-optip.service" "$UNIT"
fi

if [[ "$NO_DISPATCHER" -eq 0 ]]; then
    sed "s#/usr/local/bin/warp-optip#$BINDIR/warp-optip#g" \
        "$SRC_DIR/dispatcher/pre-up.d/90-warp-optip" > "$TMPDIR_INSTALL/90-warp-optip"
    run install -m 0755 -o root -g root "$TMPDIR_INSTALL/90-warp-optip" "$PREUP_SCRIPT"
    run install -m 0755 -o root -g root "$SRC_DIR/dispatcher/dispatcher.d/90-warp-optip-verify" "$VERIFY_SCRIPT"
fi

# ---------- 注册 / 生成 / 导入 ----------

import_connection() {
    local file="$1" before after new
    before="$(nmcli -t -f NAME connection show | sort)"
    if ! nmcli connection import type wireguard file "$file" >/dev/null 2>&1; then
        die "nmcli 导入 WireGuard profile 失败: $file"
    fi
    after="$(nmcli -t -f NAME connection show | sort)"
    new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -n1 || true)"
    if [[ -z "$new" ]] && conn_exists "$CONN"; then
        new="$CONN"
    fi
    [[ -n "$new" ]] || die "无法确定导入后的连接名"
    printf '%s\n' "$new"
}

if [[ "$REUSE" -eq 0 ]]; then
    info "生成新的 WARP 配置"
    umask 077
    if [[ "$NO_REGISTER" -eq 1 && -z "$ACCOUNT" && -z "$PROFILE" ]]; then
        die "指定了 --no-register，但没有提供 --account 或 --profile"
    fi
    if [[ -n "$ACCOUNT" ]]; then
        [[ -f "$ACCOUNT" ]] || die "account 不存在: $ACCOUNT"
        cp -f "$ACCOUNT" "$TMPDIR_INSTALL/wgcf-account.toml"
    else
        "$LIBDIR/wgcf" --config "$TMPDIR_INSTALL/wgcf-account.toml" register --accept-tos
    fi

    if [[ -n "$PROFILE" ]]; then
        [[ -f "$PROFILE" ]] || die "profile 不存在: $PROFILE"
        cp -f "$PROFILE" "$TMPDIR_INSTALL/$CONN.conf"
    else
        "$LIBDIR/wgcf" --config "$TMPDIR_INSTALL/wgcf-account.toml" \
            generate --profile "$TMPDIR_INSTALL/$CONN.conf"
    fi

    grep -q '^\[Interface\]' "$TMPDIR_INSTALL/$CONN.conf" || die "profile 缺少 [Interface]"
    grep -q '^\[Peer\]' "$TMPDIR_INSTALL/$CONN.conf" || die "profile 缺少 [Peer]"

    install -m 0600 "$TMPDIR_INSTALL/wgcf-account.toml" "$STATE_DIR/wgcf-account.toml"
    install -m 0600 "$TMPDIR_INSTALL/$CONN.conf" "$STATE_DIR/$CONN.conf"

    # 新连接：清掉旧连接留下的 last/pending，确保首次启动会优选
    rm -f "$STATE_DIR/last-endpoint" "$STATE_DIR/pending-endpoint" "$STATE_DIR/old-endpoint" 2>/dev/null || true

    info "导入 NetworkManager 连接"
    IMPORTED="$(import_connection "$TMPDIR_INSTALL/$CONN.conf")"
    if [[ "$IMPORTED" != "$CONN" ]]; then
        info "导入名为 $IMPORTED，重命名为 $CONN"
        nmcli connection modify "$IMPORTED" connection.id "$CONN"
    fi
    nmcli connection modify "$CONN" connection.interface-name "$CONN"
else
    info "复用现有连接，跳过注册/导入"
fi

# ---------- 连接属性 ----------

nmcli connection modify "$CONN" connection.autoconnect "$([[ "$AUTOCONNECT" -eq 1 ]] && echo yes || echo no)"
nmcli connection modify "$CONN" wireguard.mtu 1280

if [[ "$NO_PERMISSIONS" -eq 0 ]]; then
    if [[ -n "$PERMISSIONS_USER" ]]; then
        nmcli connection modify "$CONN" connection.permissions "user:$PERMISSIONS_USER"
        info "connection.permissions = user:$PERMISSIONS_USER"
    elif [[ -n "$SUDO_USER_NAME" ]]; then
        nmcli connection modify "$CONN" connection.permissions "user:$SUDO_USER_NAME"
        info "connection.permissions = user:$SUDO_USER_NAME"
    fi
fi

# ---------- 配置 ----------

CONF_CONTENT="$(cat <<EOF
# 由 install.sh 生成
WARP_CONN=$CONN
WARP_IFACE=$CONN
WARP_STATE_DIR=$STATE_DIR
WARP_RESULT_CSV=$STATE_DIR/result.csv
WARP_SCAN_BIN=$LIBDIR/warp

WARP_SCAN_RANGES=162.159.192.0/24,162.159.193.0/24,162.159.195.0/24,188.114.96.0/22
WARP_MAX_LOSS=20
WARP_MAX_LATENCY=200
WARP_LIMIT=20

WARP_ON_UP_POLICY=keep

WARP_CHECK_URL=https://1.1.1.1/cdn-cgi/trace

WARP_SCAN_TIMEOUT=18
WARP_PREUP_TIMEOUT=25
EOF
)"

if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] 写入 %s:\n%s\n' "$CONF" "$CONF_CONTENT"
else
    printf '%s\n' "$CONF_CONTENT" > "$CONF"
    chmod 0644 "$CONF"
fi

# ---------- 重载 ----------

if [[ "$DRY_RUN" -eq 0 ]]; then
    systemctl daemon-reload || true
    nmcli connection reload >/dev/null 2>&1 || true
fi

# ---------- 激活 ----------

if [[ "$ACTIVATE" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
    active_wg="$(nmcli -t -f NAME,TYPE connection show --active | awk -F: '$2=="wireguard" {print $1}')"
    if [[ -n "$active_wg" && "$active_wg" != "$CONN" ]]; then
        warn "以下 WireGuard 连接正在活动: $active_wg"
        warn "请先手动断开，再执行: nmcli connection up $CONN"
    else
        info "激活 $CONN（pre-up 阶段会同步优选，可能等待几秒）"
        nmcli connection up "$CONN" || warn "激活失败，请查看 journalctl -u NetworkManager"
    fi
fi

cat <<EOF

安装完成。

连接名: $CONN
配置:   $CONF
状态:   sudo warp-optip status
日志:   sudo journalctl -u warp-optip -f

下一步:
  nmcli connection up $CONN

首次 up 会在“正在连接”阶段扫描并应用优选 endpoint。
之后每次 up 如果当前 endpoint 健康，会直接保留。
EOF
