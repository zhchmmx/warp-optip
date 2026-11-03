# warp-optip

WARP Endpoint 自动优选工具。

- 在 NetworkManager **pre-up** 阶段（正在连接时）同步扫描生成候选列表，并用真实流量
  逐个实测，把**扫描结果的假阳性**在激活完成之前筛掉。
- 每个候选实测前先把 peer 删掉再原样重建，逼出一次全新的握手；
  判据是「这一轮握手时刻确实前进了，并且 `warp=on`」，两者缺一都不算通过。
- 扫描期间用临时 `ip rule` 把探测流量压回物理网络，避免被 WireGuard 策略路由带进隧道。
- 实测通过的那个 endpoint 才写回 NM profile（up 之后），不通过就不换。
- pre-up 没给出结论、或写回 profile 后隧道又不通时，verify 退回「up 后逐个实测」的
  兜底流程；所有候选连旧 endpoint 都不通才断开隧道，保证物理网络可用。
- 程序全程不执行 `nmcli connection up`：隧道只可能由用户打开，因此一定关得掉。
- 首次安装会新建独立连接（默认 `warp-optip`），**不修改现有 `wgcf-profile`**。

## 原理

```text
nmcli connection up warp-optip
        │
        ▼
NetworkManager: 正在连接（pending）
        │   l3cfg（地址/路由/ip rule/fwmark）已提交，隧道已经在承载流量
        ▼
pre-up.d/90-warp-optip   （同步，最多 60 秒，NM 卡住激活等它返回）
        ├─ 临时 ip rule：扫描网段强制走物理表（main）
        ├─ 直连扫描，生成候选列表（只传 -ip/-o，并发用扫描器内置默认）
        ├─ 删除临时 ip rule
        ├─ peer 重建演练（用激活时那个 endpoint）：
        │    remove 成功、装回也成功 -> 后面走「删 peer 逼冷握手」这条路
        │    remove 被拒 -> 退化成只换 endpoint，靠握手闸门挡假阳性
        │    删得掉装不回 -> 立刻收手（附 wg 的原始报错 + 设备公钥状态），交给 verify 修复
        └─ 候选按延迟升序逐个实测（数量沿用 WARP_LIMIT，装不进预算就截止）：
             wg set <iface> peer <pub> remove
             wg set <iface> peer <pub> allowed-ips <原值> endpoint IP:PORT
             -> 全新 peer、握手清零，绝不继承上一次的成功会话
             -> curl 驱动握手并确认 warp=on（连接超时 5 秒，单轮 WARP_PREUP_ROUND_BUDGET 秒）
             -> 握手时刻有更新 且 warp=on：写 pending-endpoint，结束
             -> 否则试下一个；全部不通则重建 peer 回退旧 endpoint
             -> 任何一次 peer 装不回去就停止实测并把 peer 还原，不在没有 peer 的接口上继续试
        │
        ▼
NetworkManager 完成激活（此时隧道已经走在实测通过的 endpoint 上）
        │
        ▼
dispatcher.d/90-warp-optip-verify（异步）
        ├─ action=up   -> warp-optip.service verify
        │                    ├─ 有 pending：只 `connection modify` 写进 profile + 确认一次
        │                    │  （profile 只能在 up 之后改；绝不 reapply，reapply 会
        │                    │    重建 peer、把刚验过的好隧道打断）
        │                    ├─ 没 pending 而隧道本来就通：什么都不改
        │                    └─ 隧道不通：退回 up 后逐个实测（modify + reapply + curl），
        │                       仍全不通才恢复旧 endpoint，最后断开 WARP
        └─ action=down -> systemctl stop（用户主动断开时立即中止）
```

pre-up 阶段**不能**调用 `nmcli connection up/down/modify`，否则可能和 NetworkManager
死锁。因此 pre-up 只用 `wg set` 改运行时 endpoint；写 profile 的 `nmcli` 操作放在
up 后的 verify 阶段。优选本身不依赖 `nmcli`，所以完全放在 pre-up。

为什么实测能放进 pre-up：NetworkManager 在 `ip-check` 阶段末尾才派发 pre-up
（`ip_check_pre_up()`），此时 WireGuard 的地址、路由、`ip rule`、fwmark 都已生效，
激活只是卡住等脚本返回。实测过：`wg show` 在 pre-up 有值、`wg set` 生效、
随后的流量确实走刚设上去的 endpoint。既然隧道已经在跑，`curl .../cdn-cgi/trace`
就能直接给出答案，不必等到 up 之后。

扫描器给的延迟是 UDP 层的数字，会假阳性（实测中 0% 丢包、70ms 的 endpoint
可以完全不通）。以前由 up 后的 verify 逐个试错，用户会在几十秒里用一条坏隧道；
现在这一步挪到激活完成之前，代价只是"正在连接"多转几十秒。

**光测 `warp=on` 不够，必须同时看握手。** WireGuard 的会话是挂在 peer 上的，
和 endpoint 无关；Cloudflare 这批 anycast IP 又共用同一把私钥。所以只要隧道
之前握手成功过，仅仅 `wg set ... endpoint` 换一个 IP，内核并不会因此重新握手
（`REKEY_AFTER_TIME_USELESS` 约 11 秒），curl 照样返回 `warp=on`——这个结论
根本不属于刚设上去的那个 endpoint。这就是第一版 pre-up 实测的假阳性来源。
现在每个候选前先 `peer remove` 再原样重建（私钥在 device 上，不受影响），
会话被清零，握手必须重来；通过的条件是「`warp=on` 且握手时刻比本轮开始时新」。

**但这个 peer 是 NetworkManager 建的，删它不是我们天然就有的权限。**
真实日志里出现过删除全部成功、装回全部失败，接口被连着删了 20 次、停在
没有 peer 的状态，而 `wg` 的报错当时被 `2>/dev/null` 吞了。现在实测前先做一次
演练：用激活时那个 endpoint 删掉再装回。装不回就立刻停手，日志里带上 `wg set`
的原始报错和设备公钥状态，由 verify 的 `connection modify` + `device reapply`
把 peer 修回来。演练过了才在候选循环里重复这套删除重建；演练时被拒则退化成
只换 endpoint，此时握手闸门依然能挡住继承会话的假阳性，只是很难有候选能过关。

**`wg show` 的显示格式不能直接喂给 `wg set`。** `wg show <iface> allowed-ips`
打出来的是**空格**分隔的两个族（`0.0.0.0/0 ::/0`），而 `wg set` 要的是逗号分隔。
第一版用 `gsub` 去掉空格，把两个族粘成了 `0.0.0.0/0::/0`，`wg set` 直接报
`AllowedIP is not in the correct format`——这就是"每个候选都重建失败"的真正根因。
现在按逗号和空白一起切块再重新拼，并在递给 `wg set` 之前校验形状，
认不出来就按"读不到 allowed-ips"处理、走退化路径，绝不把怪字符串送进内核。

**反过来，只看握手也不能下结论。** 握手成功只说明对端应答了密钥包，
不代表这个 IP 会正常转发我们的流量。所以两步都要：新会话 + `warp=on`。

**单轮预算不能压得太小。** endpoint 不通时 WireGuard 只是静默丢包，不会漏到
物理网卡，所以 `warp=on` 为真一定走的是刚设上去的 endpoint；但反过来，一次冷握手
在这台机器上要 3~6 秒，这期间内核把包暂存在 staged-packets 队列里、握手完成才放行。
连接超时如果只给 3 秒，就会每次都卡在包被释放之前——这是第一版实测的假阴性来源。
现在沿用 up 后老流程的数值：连接超时 5 秒、单轮总超时 `WARP_PREUP_ROUND_BUDGET` 秒
（低于 6 秒会被自动抬到 6）。

另外，NetworkManager 会在激活开始后几百毫秒内装好 WireGuard 的自动默认路由
（`ip rule ... lookup 52289` + fwmark），此时扫描流量会被带进隧道，测到的就不是
物理网络的可达性。所以扫描前会临时插入一条优先级更高的 `ip rule`，把目标为
`WARP_SCAN_RANGES` 的流量压回 `main` 表（物理默认路由），扫描结束后立即删除。
这只会影响扫描网段，宿主其它流量仍走隧道。

## 依赖

- Linux + NetworkManager >= 1.12（支持原生 WireGuard 和 `nmcli device reapply`）
- `nmcli`、`ip`、`systemctl`、`curl`、`awk`、`flock`、`timeout`、`wg`
- root/sudo
- 桌面通知可选：优先 `notify-send`（libnotify），没有时退回 glib2 自带的 `gdbus`
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
- pre-up 阶段直连扫描（约 5~30 秒），再按延迟升序逐个实测；
- 用 `wg set` 把第一个实测通过的 endpoint 设成运行时 endpoint；
- 激活完成时隧道已经走在优选 endpoint 上；
- verify 把它持久化进 profile，写入 `last-endpoint`，发一条通知。

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

- pre-up 阶段无条件直连扫描，生成新的候选列表；扫描期间探测流量被临时规则压回
  物理网络，不会走当前隧道。
- 紧接着在 pre-up 里按延迟升序实测候选，数量沿用 `WARP_LIMIT`（和 up 后的兜底循环
  同源），单轮 `WARP_PREUP_ROUND_BUDGET` 秒，总预算 `WARP_PREUP_TIMEOUT` 秒，
  装不进预算就自然截止。第一个「新会话 + `warp=on`」通过的就被留下，
  激活完成时你用的已经是优选后的 endpoint。
- 当前 endpoint 本来就健康时，实测通常在头几轮内命中，verify 只做持久化，
  不换 IP、不断网。
- 全部候选实测都不通：运行时 endpoint 回退到激活时的那个；verify 随后退回
  up 后逐个实测的老流程，仍然全不通才恢复旧 endpoint、最后断开 WARP。
- 用户在 pre-up 期间主动断开：接口被 NM 销毁重建，`ifindex` 一变实测立即停止，
  不会把结论写到别的实例上。

> 扫描失败时 `result.csv` 保持上一次成功扫描的内容不变，pre-up 本轮不实测、
> 不换 endpoint，隧道照原样起来；verify 看到没有 pre-up 结论，会改用 up 后
> 逐个实测的兜底流程（前提是这张旧表里还有能用的候选）。

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

### 桌面通知

`verify` 走到最终结论时发一条系统通知，之后就可以不看日志：

- `warp=on` 通过：`WARP 已连通`，正文带当前 endpoint
- 候选全不通、但原来的 endpoint 又能连通：`WARP 已连通`，正文说明回退到了哪个 endpoint
- 所有候选和原 endpoint 都不通、已断开隧道退回物理网络：`WARP 无法连通`

通知由 root 的 systemd 服务发出，但**不是**以 root 身份发：桌面通知走登录用户
自己的 D-Bus session bus（`/run/user/<uid>/bus`），而 D-Bus 用 `SO_PEERCRED`
校验连接方的 uid，uid 对不上连接会被直接关掉。所以代码先 `runuser -u <用户>`
降权、再带上该用户的总线地址发送。`DISPLAY`/`XAUTHORITY`/`WAYLAND_DISPLAY`
在这条链路上都不需要。

接收者默认取「当前有登录会话的用户」（`loginctl`，取不到时扫 `/run/user/*/bus`），
多用户或自动登录场景可以在配置里写死 `WARP_NOTIFY_USER`。

安装器**不会**为通知安装同名 `.desktop`。GNOME 会按 `app_name` 反查应用；
一旦解析成功，通知就会绑定到 `notify-send`/`gdbus` 的临时 D-Bus 连接上，
进程退出后 GNOME 会销毁整个通知源，连通知面板里的记录都会消失。保持解析
不到应用（generic source）才能让通知留在面板里。

这是纯附加功能：没人登录、没装通知工具、GNOME 开了免打扰，都只会静默跳过，
每条外部命令都带超时，不会拖慢 `verify`。日志里出现 `通知未送达` 说明当时没发出去。

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

# 当前已不生效：pre-up 扫描 + 实测，up 后只做持久化，不通才退回逐个实测
WARP_ON_UP_POLICY=keep

WARP_CHECK_URL=https://1.1.1.1/cdn-cgi/trace

WARP_SCAN_TIMEOUT=18
WARP_PREUP_TIMEOUT=60

# pre-up 实测：候选数量沿用 WARP_LIMIT，装不进 WARP_PREUP_TIMEOUT 就自然截止。
# 扫描的延迟是 UDP 层的数字会假阳性，真正的判据是「重建 peer 逼出冷握手之后」
# warp=on，且握手时刻有更新。单轮预算要罩住冷握手（3~6 秒）+ TLS + 响应，
# 低于 6 秒会被自动抬到 6（curl 的连接超时是 5 秒）。
WARP_PREUP_ROUND_BUDGET=12

# 扫描时强制走物理网络（pre-up 阶段 NM 已装好 WG 策略路由）
# NM 的规则优先级由连接 UUID 派生，范围 30768~31766，这里必须更小
WARP_SCAN_FORCE_PHYSICAL=1
WARP_SCAN_RULE_PREF=30000
# 只用于日志：验证扫描流量实际走物理网关
WARP_SCAN_PROBE_IP=162.159.192.1

# 桌面通知：1 开启 / 0 关闭；留空用户名表示自动选当前登录会话的用户
WARP_NOTIFY=1
WARP_NOTIFY_USER=
WARP_NOTIFY_DEDUPE=60
WARP_NOTIFY_TIMEOUT=3
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
verify-hook action=down id=warp-optip type= iface=warp-optip
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

### up 时“正在连接”很久

pre-up 里要做完「扫描 + 逐个实测」，总预算 `WARP_PREUP_TIMEOUT`（默认 60 秒），
Dispatcher 外层再多给 10 秒兜底；到点就带着已有结论返回，让连接正常起来。
NetworkManager 对 dispatcher 脚本的调用上限是 10 分钟，60 秒很安全。

第一次连某个网络时慢是可以预期的：扫到 1792 个地址就要十几秒，如果排在前面
的候选全是假阳性，还得一轮轮实测下去。真觉得受不了，可以调小
`WARP_LIMIT`（它同时决定 pre-up 实测和 up 后兜底的候选数，比如 8）
或 `WARP_SCAN_RANGES`，代价是优选质量。
一个连上要 60 秒以上的网络，本来也不适合连 WARP。

看：

```bash
tail -n 100 /run/warp-optip/pre-up.log
```

日志里每个候选都有一行结论：「实测通过」「扫描 XXms 很好但实测不通」或
「返回 warp=on 但握手没有更新」，还带本轮的握手时刻变化（`握手 0->1793…`），
慢在哪一步、哪一轮是假阳性一眼就能看出来。
每次 `wg set` 失败都会把它自己的报错原样写进日志（`wg set ... 失败(退出码 1): ...`），
不需要再去猜是权限还是参数问题。

### 日志出现「peer 删除成功但装不回去」

这条是老流程能救、新流程故意不试的情况：这次激活的 peer 是 NetworkManager 建的，
我们从外面删它、再装回去，中间任何一步被拒都可能装不回（参数不合法、设备还没
配上私钥、NM 正在改同一个设备）。日志紧跟的两行会给出答案：`wg set` 的原始报错，
以及「设备公钥: …」——报 `AllowedIP is not in the correct format` 是参数问题，
报 `Operation not permitted` 且设备公钥那行是空的，才是私钥/权限问题。

处理方式是当场停手：不删第二遍、不进候选循环，verify 起来后用
`connection modify` + `device reapply` 让 NM 自己把 peer 装回来，再走 up 后逐个实测。
表现就是"连接慢一点、结论照样对"，不需要你做任何事。
如果这行日志频繁出现，说明这台机器的 pre-up 时机不适合重建 peer，
可以把 `WARP_LIMIT` 调小让兜底流程少试几个候选，或者直接把它当纯兜底用。

### pre-up 时 `wg set` 不生效

先确认 pre-up 时接口存在：

```bash
sudo journalctl -u NetworkManager -n 100 --no-pager
```

pre-up 派发时 l3cfg 已经提交，`wg show <iface> endpoints` 一定有值；如果日志出现
「接口 warp-optip 或它的 peer 还没就绪」，说明这个连接名和实际接口名不一致，
检查 `WARP_IFACE` 或 `DEVICE_IFACE`。

若 NetworkManager 在 pre-up 后覆盖了运行时 endpoint，verify 会用
`nmcli connection modify` 把 pre-up 实测通过的 endpoint 写进 profile。
verify 不会 `device reapply`：reapply 会重建 peer、丢掉刚验证过的会话，
而运行时 endpoint 本来就是对的。只有在隧道确实不通、需要逐个试候选时，
兜底流程才用 `modify` + `reapply`。程序本身不执行 `nmcli connection up`，
所以隧道只可能由用户打开。

### 当前 IP 不健康但不换

只有 pre-up 实测「新会话 + `warp=on`」都成立的候选才会被换上；
扫描延迟再低、实测不通就不换。如果 pre-up 被整个跳过（没抢到锁、被 self-up
标记抑制、扫描失败），verify 会退回 up 后逐个实测的兜底流程；要立刻重新优选，
手动来一次：

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
