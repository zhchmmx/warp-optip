# warp-optip

WARP Endpoint 自动优选工具。

- 在 NetworkManager **pre-up** 阶段（正在连接时）同步扫描并设置优选 endpoint。
- up 之后异步校验 `warp=on`，失败自动换下一个候选。
- 默认 `keep`：当前 endpoint 健康就不换 IP、不扫描、不断网。
- 首次安装会新建独立连接（默认 `warp-optip`），**不修改现有 `wgcf-profile`**。

## 原理

```text
nmcli connection up warp-optip
        │
        ▼
NetworkManager: 正在连接（pending）
        │
        ▼
pre-up.d/90-warp-optip   （同步，最多 25 秒）
        ├─ 首次/缓存缺失：直连扫描
        ├─ 选候选
        ├─ wg set <iface> peer <pub> endpoint IP:PORT
        └─ 返回
        │
        ▼
NetworkManager 完成激活
        │
        ▼
dispatcher.d/90-warp-optip-verify（异步）
        └─ warp-optip.service verify
             ├─ 持久化 endpoint 到 NM profile
             ├─ 连续 3 次检查 warp=on
             ├─ 失败：用结果候选修复
             └─ 全失败：恢复旧 endpoint；再失败则断开 WARP
```

pre-up 阶段**不能**调用 `nmcli connection up/down/modify`，否则可能和 NetworkManager
死锁。因此 pre-up 只用 `wg set` 改运行时 endpoint；`nmcli` 操作全部放在 up 后的
verify 阶段。

## 依赖

- Linux + NetworkManager（支持原生 WireGuard）
- `nmcli`、`systemctl`、`curl`、`awk`、`flock`、`timeout`、`wg`
- root/sudo
- 首次注册需要访问 Cloudflare API；下载二进制需要网络（或本地提供）

## 安装

```bash
cd warp-optip

# 预览
sudo ./install.sh --dry-run

# 安装（默认新建 warp-optip 连接，不激活）
sudo ./install.sh
```

安装器会：

1. 选择 `wgcf`：
   - 指定了 `--wgcf-bin`：直接使用。
   - 指定了 `--no-download`：只查找本地文件。
   - 否则**每次都查询 GitHub 最新 Release 并下载**：
     - 优先用 GitHub API 获取最新版本和对应 `linux_<arch>` 资源；
     - API 不可用时通过 `releases/latest` 重定向获取版本号；
     - 下载失败再回退到本地文件，最后才用兜底版本。
2. 选择扫描器 `warp`（本地优先）：
   - `./warp`、`./warp-linux-<arch>`、`vendor/`
   - `~/.local/state/warp-optip/warp`
   - `/usr/local/lib/warp-optip/warp`
   - 都没有才联网下载。
3. 新建独立连接名：
   - 默认 `warp-optip`
   - 已存在则尝试 `warp-optip-2`、`warp-optip-3`……
4. 调用：
   ```bash
   wgcf register --accept-tos
   wgcf generate --profile warp-optip.conf
   nmcli connection import type wireguard file warp-optip.conf
   ```
5. 设置 `connection.permissions user:$SUDO_USER`，之后手动 `nmcli` 不需要 sudo。
6. 安装 Dispatcher 和 systemd 服务。
7. 默认不激活、不开 autoconnect。

> `vendor/` 里的第三方二进制默认不提交到 git；`install.sh` 会优先复用本地文件，
> 缺失时再下载。离线安装可以手动把 `warp` / `wgcf` 放进 `vendor/`，它们不会被 git 跟踪。
> 如果要发布完全自包含的离线包，建议把 `vendor/` 一起打进 Release 压缩包。

### 常用安装选项

```bash
sudo ./install.sh --no-download                 # 只用本地二进制
sudo ./install.sh --wgcf-bin /path/to/wgcf      # 指定 wgcf，跳过下载
sudo ./install.sh --warp-bin /path/to/warp      # 指定扫描器，跳过下载
sudo ./install.sh --wgcf-version 2.3.1          # 固定 wgcf 版本（默认最新版）
sudo ./install.sh --wgcf-url URL                # 自定义 wgcf 下载地址
sudo ./install.sh --name my-warp                # 自定义连接名
sudo ./install.sh --account ./wgcf-account.toml # 复用账号
sudo ./install.sh --profile ./wgcf-profile.conf # 复用 profile
sudo ./install.sh --autoconnect                 # 开机自动连接
sudo ./install.sh --activate                    # 安装后立即 up
```

## 首次启用

如果当前 `wgcf-profile` 正在使用，先断开：

```bash
nmcli connection down wgcf-profile
```

启用新连接：

```bash
nmcli connection up warp-optip
```

首次会：

- 图标显示“正在连接”；
- pre-up 阶段直连扫描（约 5~30 秒）；
- 用 `wg set` 设置优选 endpoint；
- 激活后 verify 阶段连续检查 `warp=on`；
- 成功后写入 `last-endpoint`。

验证：

```bash
curl -sS https://1.1.1.1/cdn-cgi/trace | grep '^warp='
nmcli -g wireguard.peers connection show warp-optip | sed 's/\\:/:/g'
```

## 日常使用

```bash
nmcli connection up warp-optip
nmcli connection down warp-optip
```

每次 up：

- 当前 endpoint 健康：只检查，不换 IP、不扫描、不断网。
- 当前 endpoint 不健康：优先用缓存候选修复；缓存过期或全失败才全量扫描。
- 全部失败：恢复旧 endpoint；旧 endpoint 也不行则断开 WARP，保证物理网络可用。

### 手动命令

```bash
sudo warp-optip status
sudo warp-optip scan              # 强制断开 -> 直连扫描
sudo warp-optip apply             # 用现有 result.csv 逐个实测应用
sudo warp-optip --apply 162.159.193.92:2408
```

实际 CLI：

```text
warp-optip pre-up
warp-optip verify
warp-optip scan
warp-optip apply
warp-optip apply-one IP:PORT
warp-optip status
```

### 日志

```bash
sudo journalctl -u warp-optip -f
sudo tail -f /var/lib/warp-optip/warp-optip.log
tail -f /run/warp-optip/pre-up.log
```

## 配置

`/etc/warp-optip.conf`：

```bash
WARP_CONN=warp-optip
WARP_IFACE=warp-optip
WARP_STATE_DIR=/var/lib/warp-optip
WARP_RESULT_CSV=/var/lib/warp-optip/result.csv
WARP_SCAN_BIN=/usr/local/lib/warp-optip/warp

WARP_SCAN_RANGES=162.159.192.0/24,162.159.193.0/24,162.159.195.0/24,188.114.96.0/22
WARP_MAX_LOSS=20
WARP_MAX_LATENCY=200
WARP_LIMIT=20

WARP_ON_UP_POLICY=keep
WARP_CACHE_MAX_AGE=21600

WARP_PHYSICAL_CHECK_URL=https://www.baidu.com
WARP_CHECK_URL=https://1.1.1.1/cdn-cgi/trace

WARP_SCAN_TIMEOUT=18
WARP_PREUP_TIMEOUT=25
```

## 卸载

```bash
sudo ./uninstall.sh --dry-run
sudo ./uninstall.sh                  # 删除程序 + 安装器创建的连接
sudo ./uninstall.sh --keep-connection
sudo ./uninstall.sh --purge          # 同时删除状态/账号/日志/备份
```

不会删除或修改 `wgcf-profile` 等其他连接。

卸载后如需回到旧连接：

```bash
nmcli connection up wgcf-profile
```

## 故障排查

### pre-up 没触发

先看 Dispatcher 自己的日志（不需要 sudo）：

```bash
cat /run/warp-optip/dispatcher.log
```

正常应该看到类似：

```text
pre-up-hook action=pre-up id=warp-optip type= iface=warp-optip
verify-hook action=up id=warp-optip type= iface=warp-optip
```

注意：部分 NetworkManager 版本不会设置 `CONNECTION_TYPE`，所以 `type=` 为空是正常的。
本项目只用连接名 `warp-optip` 过滤，不再强制要求 `CONNECTION_TYPE=wireguard`。

如果这个文件不存在或没有内容，说明 Dispatcher 脚本根本没有执行，继续检查：

```bash
nmcli -f connection.id,connection.type connection show warp-optip
ls -l /etc/NetworkManager/dispatcher.d/pre-up.d/90-warp-optip
sudo journalctl -u NetworkManager -n 100 --no-pager
```

Dispatcher 必须是 `root:root`、`0755`。

注意：NetworkManager 不提供 `$ACTION` 变量，实际提供的是
`$NM_DISPATCHER_ACTION`（以及 `$1`）。本项目已经使用：

```sh
action="${NM_DISPATCHER_ACTION:-${1:-}}"
```

如果旧版本安装的脚本里写的是 `[ "$ACTION" = ... ]`，重新运行
`sudo ./install.sh` 更新 Dispatcher。

### 首次 up 卡很久

pre-up 最多等 25 秒；超过会放弃扫描并让连接正常起来。
看：

```bash
tail -n 100 /run/warp-optip/pre-up.log
```

### pre-up 时 `wg set` 不生效

先确认 pre-up 时接口存在：

```bash
sudo journalctl -u NetworkManager -n 100 --no-pager
```

若 NetworkManager 在 pre-up 后覆盖了运行时 endpoint，verify 阶段会再 `reapply` 一次；
仍然不行则回退到 `nmcli connection up`。

### 当前 IP 不健康但不换

默认策略是 `keep`，只在 verify 检测到 `warp=on` 失败时才修复。
强制重新优选：

```bash
sudo warp-optip scan
sudo warp-optip apply
```

### wgcf 最新版查询或下载失败

安装器会先尝试 GitHub API，再尝试 `releases/latest` 重定向；都失败时回退本地文件，
最后才用兜底版本。

如果 GitHub 网络不可用，可以直接使用本地文件：

```bash
sudo ./install.sh --no-download --wgcf-bin ./wgcf --warp-bin ./warp
```

默认查询超时为每次 8 秒（API + 重定向各一次，最多约 16 秒）。想更快回退本地：

```bash
sudo ./install.sh --no-download
# 或
sudo WGCF_NET_TIMEOUT=3 ./install.sh
```

或者固定一个已知版本：

```bash
sudo ./install.sh --wgcf-version 2.3.1
sudo ./install.sh --wgcf-url https://your-mirror/wgcf_2.3.1_linux_amd64
```

### 两个 WireGuard 连接冲突

两个连接都使用 `0.0.0.0/0`，只能同时激活一个：

```bash
nmcli connection down wgcf-profile
nmcli connection up warp-optip
```

## 安全

- `wgcf-account.toml`、`$WARP_CONN.conf` 含私钥，存放在
  `/var/lib/warp-optip`，权限 700/600，root 所有。
- 扫描器是第三方二进制，建议固定版本并校验来源。
- 不要把真实 WARP 私钥传给扫描器。
