# traffic-logger：按设备与目标记录代理流量

`r3mini-traffic` 常驻在 BPI-R3 Mini 源机 `192.168.0.242` 上，按「小时 × 设备（IP + MAC）× 出口 × 目标」记录经过本路由器的流量。账单上出现不明上传时，用它查出是哪台设备、发往哪里、走了哪个节点。

- **数据起点**：2026-10-23 23:30 起有数据（当天做过卸载演练，演练时的数据已清除）。更早的日期查询结果是空的。
- **只读**：只读数据源，不改 OpenClash、防火墙和网络配置。

| kind | 数据源 | 记录什么 | `exit` 列 |
|---|---|---|---|
| `clash` | OpenClash 控制接口 `GET /connections` | 进 OpenClash 核心的每条连接，目标是域名（或 IP:端口） | `DIRECT`、`REJECT`，或出口链 |
| `socks` | `/proc/net/nf_conntrack` | 不经 OpenClash 的独立 SOCKS 端口（默认 10810），只能按设备记，看不到目标 | 端口标签，如 `ph-socks` |
| `forward` | `/proc/net/nf_conntrack` | 经本机转发、没进 OpenClash 的流量（回复方向 SNAT 到本机地址、未被 DNAT），目标是 `IP:端口` | `DIRECT@<出口网卡>`，如 `DIRECT@eth1` |
| `unattributed` | OpenClash 核心累计计数 | 核心计数里没能对应到具体连接的部分（轮询间隙里开关的短连接等），**不属于任何设备** | — |

- **出口链**：从左到右是「实际节点 < 选中它的策略组 < 上一级组 …」，例如 `<节点> < <机场组> < Final`；最左边就是实际走的节点。
- **字节口径**：`clash` 是 OpenClash 统计的载荷字节；`socks`、`forward` 的字节按「IP 层字节 − 包数 × 包头（TCP 52、UDP 28）」估算成载荷。所以只有 ACK 的方向会记成 0，不会把下载为主的设备显示成在大量上传。

## 安装了什么

| 路径 | 作用 |
|---|---|
| `/usr/sbin/r3mini-traffic` | ucode 脚本：`run` 常驻采集、`report` 查询、`status` 状态、`maintain` 手动压缩与清理、`replay` 离线重放（仅测试用） |
| `/etc/init.d/r3mini-traffic` | procd 服务：`START=99`，开机自启，崩溃自动拉起，`term_timeout 15`；`/etc/config/r3mini_traffic` 内容变化后的配置重载会重启它 |
| `/etc/config/r3mini_traffic` | 配置，见下表 |
| `/mnt/mmcblk0p6/r3mini-traffic/` | 数据与持久日志，目录 0700、文件 0600 |

不装任何软件包，只依赖固件自带的 ucode（fs/uci 模块）、curl、gzip。

| 配置项 | 默认 | 含义 |
|---|---|---|
| `enabled` | `1` | `0` 时服务启动后立即退出 |
| `data_dir` / `require_mount` | `/mnt/mmcblk0p6/r3mini-traffic` / `/mnt/mmcblk0p6` | `require_mount` 没挂载时不写盘；填 `-` 关闭该检查 |
| `poll_seconds` | `2` | 轮询 `/connections` 的**最短**间隔（1–10）；实际间隔按开销自适应，见「资源占用」 |
| `conntrack_seconds` | `15` | 读连接跟踪表的间隔（5–60） |
| `checkpoint_seconds` | `300` | 当前会话落盘间隔（30–3600） |
| `retention_days` / `max_mb` | `60` / `200` | 保留最近多少个有数据的日期 / 数据总量上限 |
| `fold_bytes` | `0` | `0`：只在某小时明细超过 5000 行时，把不足 64 KiB 的目标并入「(其他)」；大于 0：总按该阈值折叠 |
| `forward` | `1` | 是否记录 `forward` |
| `socks_port` | `10810:ph-socks` | `端口:标签`，可写多条 `list` |

- **生效方式**：越界或写错的值会改用默认值，并在日志里记 `CONFIG_OUT_OF_RANGE`。
- **改配置**：直接编辑文件（`uci commit` 会按标准格式重写文件，把注释冲掉），再执行 `ubus call service event '{"type":"config.change","data":{"package":"r3mini_traffic"}}'`，或者 `/etc/init.d/r3mini-traffic restart`。

## 查询

在路由器上执行，或在本机项目根目录执行 `python traffic-logger/manage.py report 192.168.0.242 <参数>`：

```
r3mini-traffic report [--date YYYY-MM-DD] [--from H] [--to H] [--by device|target|exit|hour|kind[,..]]
                      [--device S] [--target S] [--kind clash|socks|forward] [--proxy] [--top N]
                      [--sort up|down|total] [--tsv] [--data-dir D]
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `--date` | 今天 | 路由器本地时间（`CST-8`）的日期 |
| `--from` / `--to` | `0` / `24` | 小时范围 `[from, to)`，不含 `to` |
| `--by` | `device` | 分组维度，可组合，如 `device,target` |
| `--device` / `--target` | — | 子串匹配，不分大小写；`--device` 匹配「IP MAC (备注名)」整串，`--target` 匹配目标 |
| `--kind` | — | 只看某一类 |
| `--proxy` | — | 只看消耗订阅流量的部分，见下面的说明 |
| `--top` / `--sort` | `20` / `up` | 显示前 N 组；按上传、下载或合计排序 |
| `--tsv` | — | 每行输出「分组键 \t 上传 \t 下载 \t 连接」，最后两行是 `(合计)` 与 `(未归因)` |

`--proxy` 的取舍：

- **排除**：`DIRECT`、`REJECT` 出口和 `forward`。
- **例外**：目标命中当前 OpenClash 配置里节点服务器地址的直连或转发行，不排除，并标成 `订阅节点直连(DIRECT)`、`<目标> [订阅节点]`。这类行代表别的设备自带代理客户端、借道本机直连同一订阅的节点，正是账单上「不明消耗」的典型来源。
- **局限**：节点只按服务器地址字面匹配。当前订阅的 172 个节点全是域名，所以只能认出 `clash` 行（目标是域名）；`forward` 行只有 IP，认不出。节点按**当前**配置匹配，订阅换过节点后，历史数据可能对不上。
- **自带代理客户端的设备会显示成什么**：它连节点的 TCP 流量照样会被 OpenClash 透明代理接管，所以落在 `clash` 行。
  - 设备经本机 DNS 解析节点域名，或 OpenClash 嗅探到 TLS 的 SNI：目标是节点域名，会被标出。
  - 设备自己用 DoH 解析、协议又不带 SNI：目标只有 `IP:端口`，认不出。
  - 补查办法：`report --device <IP> --by target --sort up` 看有没有对单个陌生 `IP:端口` 的大量上传。被绕过 OpenClash 的转发（`forward`）也是同样的认法。

读结果的口径：

- 字节单位按 1024 进制（KB = 1024 B）。
- 「连接」是该组里新出现的连接数，持续中的连接在后续轮询里不重复计，所以有字节、连接为 0 的行是正常的。
- 表头里的「N 行明细」是参与汇总的原始行数，不是显示的组数。
- 「合计」不含「未归因」。

先看某天谁用了代理，再看那台设备发往哪里、走哪个节点：

```
r3mini-traffic report --date 2026-10-24 --proxy --by device
r3mini-traffic report --date 2026-10-24 --proxy --device 192.168.0.253 --by target,exit
```

真实输出（2026-10-23，安装后约 7 分钟；MAC 和节点名已打码）：

```
2026-10-23 00:00-24:00  按 device,exit  仅代理  （21 行明细）
      上传       下载  连接  device | exit
   499.43 MB      3.95 MB      40  192.168.0.253 xx:xx:xx:xx:xx:xx  |  <节点A> < <AI 策略组>
   681.76 KB     75.81 KB      20  192.168.0.253 xx:xx:xx:xx:xx:xx  |  <节点B> < <机场组> < Final
    12.39 KB     13.35 KB       2  192.168.0.253 xx:xx:xx:xx:xx:xx  |  <节点B> < <机场组> < 🔍 Google
     2.44 KB      5.63 KB       1  192.168.0.253 xx:xx:xx:xx:xx:xx  |  <节点B> < <机场组>
       922 B      2.52 KB       0  ?  |  <节点B> < <机场组>
   500.11 MB      4.05 MB      63  合计
     6.18 MB      9.40 MB          未归因：OpenClash 核心计数里没能对应到具体连接的部分（轮询间隙里开关的短连接等）
```

没有数据的日期，输出 `（0 行明细）` 且合计为 0，退出码 0（真实输出）：

```
2026-10-20 00:00-24:00  按 device  （0 行明细）
      上传       下载  连接  device
         0 B          0 B       0  合计
         0 B          0 B          未归因：OpenClash 核心计数里没能对应到具体连接的部分（轮询间隙里开关的短连接等）
```

- 设备显示为 `?`：连接的元数据里没有来源 IP。
- `(路由器本机)`：来源是路由器自己的地址。

**认出实物设备**：本路由器不发 DHCP，拿不到主机名。用 MAC 去上游路由器（`192.168.0.254`）的 DHCP 列表、或去设备自己的网络设置里对上号，然后在配置末尾追加：

```
config device
	option mac 'aa:bb:cc:dd:ee:ff'
	option name '书房电脑'
```

备注名在查询时才读，追加后对历史数据同样生效，不用重启服务。

## 运行状态

真实输出：

```
STATUS_OK 版本 1.3.0 pid 28576 run_id 1bb1163b 已运行 72 秒，状态更新于 2 秒前，当前轮询间隔 2.0 秒
控制接口 正常；当前连接 99；核心累计 上传 11.40 GB / 下载 1.04 GB；跟踪中的转发/SOCKS 流 30
本小时 2026-10-24T00：明细 65 行，轮询成功 36 / 失败 0，已归因上传 116.54 MB，未归因上传 249.73 KB，待补写 0 段
```

出问题时第一行是 `STATUS_DEGRADED problems=<码>[,<码>...]`，退出码 1：

| 问题码 | 含义 | 处置 |
|---|---|---|
| `STALE` | 状态文件超过 40 秒没更新，进程多半已停 | 依次执行 `/etc/init.d/r3mini-traffic status`、`logread -e r3mini-traffic \| tail`，然后 `/etc/init.d/r3mini-traffic restart` |
| `NOT_RECORDING` | 时钟还没核对通过，或数据分区未挂载 | 看日志里的 `CLOCK_BEHIND_DATA` / `DATA_MOUNT_MISSING`，处置见下方故障表 |
| `DATA_MOUNT_MISSING` | 数据分区未挂载 | 同上 |
| `PENDING_WRITES` | 有会话写盘失败，正在等待补写 | 看日志里的 `WRITE_SHORT` / `OPEN_FAILED` / `RENAME_FAILED` |
| `API_<原因>` | 控制接口读取失败，`<原因>` 是 `CURL_FAILED`、`TIMEOUT`、`HTTP_UNAUTHORIZED`、`HTTP_STATUS`、`BAD_JSON`、`POPEN_FAILED` 之一 | 见故障表 |

## 数据

- **文件**：`<data_dir>/<YYYY-MM-DD>/<HH>.<run_id>.<序号>.tsv`。
  - `run_id` 是进程每次启动时随机生成的 8 位十六进制数；`序号` 是该进程第几次进入一个新的小时。
  - 每段会话只写自己的文件，所以进程重启、时钟回拨都不会覆盖已有数据。同一小时有多个文件时，查询与压缩都按求和处理。
- **行格式**：`hour_epoch  src_ip  mac  kind  exit  target  up  down  conns`。
- **落盘**：
  - 当前会话每 `checkpoint_seconds` 原子重写一次，整点和停止时也写，断电最多丢 5 分钟。
  - 写盘失败的会话进补写队列（最多 24 段），之后每个检查点重试。
- **压缩与保留**：
  - **触发**：进程启动和每个整点各做一次；也可手动执行 `r3mini-traffic maintain`。
  - **压缩**：过完的日子压成一份新的 `<YYYY-MM-DD>.<令牌>.tsv.gz`，已有的 gz 不改写，查询时求和。
  - **可重入**：压缩前先在目录里放标记，gz 在 sync 之后原子改名，崩溃后再执行会自动重做或只删目录。
  - **保留**：只保留最近 `retention_days` 个**有数据的日期**（按条数算，不按当前时钟往回推，因为本机时钟会跳）；总量超过 `max_mb` 再从最旧的删。今天和最新的那个日期不删。
- **折叠**：被并入「(其他)」的目标，用 `--target` 查不到。排查低速、长期的外联时，把 `fold_bytes` 设成 0，同时注意每小时 5000 行的上限。
- **谁能看到**：数据分区 `/mnt/mmcblk0p6` 同时是 samba「Confidential」共享，配置了 `force_root '1'`（即 `force user = root`）且没有 `valid users` 限制。所以任何能登录 samba 的账号（目前配置了一个）都以 root 身份访问，0700/0600 权限挡不住。要收紧，就把 `data_dir` 改到共享之外，或调整 samba 配置。
- **暂停与删除**：
  - 临时停用：`/etc/init.d/r3mini-traffic stop`；不再开机自启：`/etc/init.d/r3mini-traffic disable`。
  - 删除某一天：先 stop，再 `rm -rf /mnt/mmcblk0p6/r3mini-traffic/<日期> /mnt/mmcblk0p6/r3mini-traffic/<日期>*.tsv.gz`，然后 start。

## 部署、升级、卸载

在本机项目根目录执行 `traffic-logger/manage.py`。前置条件：

- Windows（备份用 DPAPI 加密，只有同一 Windows 账户能解密）；
- Python 3，装有 `paramiko` 与 `pywin32`；
- 主机密钥已固定在 `~/.ssh/known_hosts`；
- root 口令沿用项目惯例，从 `docs/私密/商家交付信息.md` 读取。

| 命令 | 主机 | 作用 | 成功时最后一行 |
|---|---|---|---|
| `backup HOST...` | 可多台 | 改前备份：整个 `/etc`、`/usr/share/openclash`、opkg status、OpenClash 的 LuCI 文件，以及 `/usr/sbin/r3mini-*`、`/usr/sbin/adspower-ph-*`、`r3mini` 的 LuCI 菜单/ACL/页面；DPAPI 加密，附改前快照清单 | `BACKUP_PATH=...` |
| `check-backup FILE [--extract DIR]` | — | 在内存里解密备份，核对 SHA-256 与条目数；`--extract` 才写出明文 tar.gz（内含 `/etc/shadow` 与主机密钥，用完删除） | `BACKUP_CHECK_OK ...` |
| `selftest HOST` | 1 台 | 在设备 `/tmp` 里跑重放对照、维护、时钟、单实例锁、节点标注等测试，不安装；任一项失败退出码 1 | `SELFTEST_PASS` |
| `dryrun HOST [SECONDS]` | 1 台 | 不安装，从 `/tmp` 试跑，默认 60 秒；输出覆盖率、CPU、内存、OpenClash 核心 CPU，以及 SIGTERM 后的落盘与会话文件 | `STATUS {...}` |
| `install HOST...` | 可多台 | 核对身份与改前快照 → 安装 → 原有功能与快照验收 | `VERIFY_OK host=...` |
| `upgrade HOST...` | 可多台 | 替换脚本与服务定义（保留配置与数据）→ 重启 → 等到新版本、新 run_id 的状态 → 验收 | `VERIFY_OK host=...` |
| `verify HOST...` | 可多台 | 只做验收 | `VERIFY_OK host=...` |
| `uninstall HOST... [--purge-data]` | 可多台 | 卸载并证明快照回到改前 | `UNINSTALL_OK host=...` |
| `status HOST` / `report HOST ...` | 1 台 | 远程执行同名子命令 | — |

- **备份文件**：写进 `backups/router/`（该目录被 git 忽略），文件名为 `router-backup-<时间>-<主机>-before-traffic-logger.tar.gz.dpapi` 与 `.manifest.json`。明文从不落盘。
- **改前快照**：清单里记录 `/etc/config`、`/etc/init.d`、`/etc/rc.d`、`/usr/sbin`、`/etc/crontabs` 每一项的 sha256 或链接目标，以及数据分区的一级目录。
- **验收标准**：
  - 安装后，快照只能多出 6 项：3 个文件、`S99`/`K10` 两个开机链接、数据目录。
  - 卸载并加 `--purge-data` 后，快照必须与改前逐项相等。
  - 原有功能检查每次都要和装前一致：OpenClash 进程号、各服务运行实例数、LuCI、DNS、10810 端口监听、节点延迟测试、本机经透明代理访问外网。
- **卸载会删什么**：
  - 不加 `--purge-data`：数据目录和日志原样留在分区上。
  - 加 `--purge-data`：**删掉全部历史记录**。要留档，先把 `/mnt/mmcblk0p6/r3mini-traffic/` 拷走。

## 记录范围与已知盲区

- **不经过本机的流量看不到**：
  - 手机在移动网络上用 Clash 直连同一个订阅；
  - 走克隆机 `.246` 出去的流量（`.246` 没有安装记录器）。
  - 账单与报表的差额，就来自这类流量。
- **转发流量的盲区**：`forward` 只认 IPv4、只认 SNAT 到本机地址的 TCP/UDP 转发。没有 NAT 的 IPv6 转发、GRE/ESP 等其他协议、入站端口转发（UPnP/DNAT 到局域网主机，例如 P2P 上传）都看不到。入站这类不走代理，不消耗订阅。
- **SOCKS 的盲区**：`socks` 只统计配置的端口。mihomo 的 SOCKS5 UDP 走同一端口会被统计，走其他端口的不会。
- **连接跟踪表读取不完整**：读出来不是原子快照，一轮里会漏读、偶尔重复读到条目。处理方式：
  - 同一轮重复的条目只取第一条；
  - 没读到的流留「墓碑」（ESTABLISHED 与卸载中的流留 7500 秒，其余 300 秒），再出现时按增量计算；
  - 从没见过、而累计字节超过「运行时长 × 1 Gbit/s」的流只建基线；
  - 处于硬件/软件卸载状态的条目，格式不同（没有超时与状态两列），也能解析。
- **启动时的基线**：
  - `clash`：第一次轮询只建基线，此前已经传过的字节不计；之后的增量照常记，所以刚启动十几秒就能看到已归因上传。
  - `socks`/`forward`：启动后前 3 轮读表（约 45 秒）只建基线。
- **设备识别**：按 IP + MAC。ARP 每 60 秒刷新一次，IP 刚换给别的设备时，最长 60 秒会记到旧 MAC 上；IPv6 来源没有 MAC。
- **时钟**：
  - 本机没有 RTC。墙钟早于已有数据的最新修改时间时只维持基线、不记录，对时后才开始；数据分区未挂载时同样不记录。
  - 首次安装时没有已有数据，所以不做这项检查。
  - 两个已知边界：
    - 冷启动时 sysfixtime 把时钟拨到 `/etc` 里最新文件的时间。如果它晚于已有数据，检查会放行，对时前那一两分钟的流量会记到那个时间所在的小时。
    - 时钟曾经超前过（例如手工 `date -s` 打错）时，会留下修改时间在未来的文件，之后每次启动都会停在 `NOT_RECORDING`，见故障表。

## 资源占用（2026-10-23/24 在 .242 上实测）

- **轮询间隔**：按每轮实测开销自适应，占空比约 4%，范围是「`poll_seconds`–10 秒」。核心上 1354 条连接时，`/connections` 一次约 950 KB、解析约 0.2 秒，间隔自动拉到约 7 秒。录制样本里间隔放到 10 秒，上传覆盖率仍为 99.3%。
- **CPU 与内存**：
  - 99 条连接时（1.3.0）约占单核 2.35%，常驻内存 2.7 MB，间隔 2 秒；
  - 1354 条连接时（1.2.0，轮询逻辑与 1.3.0 相同）约 6.5%（整机四核约 1.6%），常驻内存约 10–14 MB。
- **OpenClash 核心**：连接很多时，开记录器的 30 秒窗口里核心 CPU 比不开时高 2.5–6 个百分点，但和流量本身的波动混在一起，分不清有多少来自多出来的序列化。
- **覆盖率**：60 秒试跑里，已归因上传占核心上传计数的 95.5–99.9%；实际运行时，23 点整小时为 99.6%。

## 日志与故障处置

- **日志位置**：持久日志在 `/mnt/mmcblk0p6/r3mini-traffic/r3mini-traffic.log`，超过 1 MiB 轮转一份；同时写 stderr，由 procd 转到 `logread`，重启即丢。
- **行格式**：`<ISO 时间> <级别> <run_id> <事件> "<说明>" k=v ...`。
- **限流**：同一原因 5 分钟内只记一条，被压下的次数记在 `suppressed=`。
- **汇总行**：每个检查点和整点各记一条 `traffic.flush`，带轮询成功/失败次数、已归因与未归因字节。

| reason | 含义 | 处置 |
|---|---|---|
| `CLOCK_BEHIND_DATA` | 墙钟早于已有数据，等对时 | 确认 `system.ntp.enabled=1` 且 NTP 可达，对时后自动开始。若日志里的 `expect=` 比真实时间还晚，说明有文件的修改时间在未来：`touch /tmp/now && find /mnt/mmcblk0p6/r3mini-traffic -newer /tmp/now` 找出来，逐个 `touch` 改成现在，再 restart |
| `DATA_MOUNT_MISSING` | 数据分区未挂载 | 检查 `/mnt/mmcblk0p6` 挂载；恢复后自动重新核对时钟并开始记录 |
| `CURL_FAILED` / `TIMEOUT` / `HTTP_STATUS` / `BAD_JSON` / `POPEN_FAILED` | 读不到 OpenClash 控制接口 | `/etc/init.d/openclash status`；核对 `openclash.config.cn_port` |
| `HTTP_UNAUTHORIZED` | 控制接口密钥不对 | 自动从 UCI 重读 `dashboard_password`；仍失败就核对该项 |
| `WRITE_SHORT` / `OPEN_FAILED` / `RENAME_FAILED` | 写会话文件失败（写满、只读等） | 保留旧文件，进补写队列；检查分区空间（`df -h /mnt/mmcblk0p6`）与读写状态 |
| `RETRY_QUEUE_FULL` / `PENDING_WRITES_LOST` | 补写队列溢出 / 停止时仍有未写出的会话 | 对应小时的数据已丢失；先修好写盘 |
| `NO_SUCCESSFUL_POLL` | 一整段会话一次轮询都没成功 | 同控制接口失败 |
| `HIGH_UNATTRIBUTED` | 未归因超过 20% 且超过 10 MiB | 短连接很多时出现；把 `poll_seconds` 调到 1 可以提高归因率 |
| `GZIP_FAILED` | 日压缩失败 | 会话文件保留，下次维护重试；看 `cmd=` 与 `exit=` |
| `CT_LINE_FORMAT` | 有连接跟踪候选行格式无法识别，已跳过 | 把该行（打码后）补进 `test_replay.py` 的构造场景，再修正则 |
| `CONNTRACK_ACCT_OFF` | 连接跟踪没有字节计数，此时 `socks`/`forward` 全都记不到 | `sysctl -w net.netfilter.nf_conntrack_acct=1` 会改内核设置，不在本模块的「只读」范围内，由设备主人决定；要持久化得写进 `/etc/sysctl.d/` |
| `CONFIG_OUT_OF_RANGE` | 配置值无效或越界，已改用默认值 | 按 `items=` 修正配置 |
| `EXCEPTION` | 某阶段抛异常，本轮跳过 | 看 `stage=`、`err=`、`stack=` |

以下几条是在设备上实际触发过的输出：

```
2026-10-23T23:37:33.376+08:00 WARN 15dac16a traffic.clock "墙钟早于已有数据，等对时后再记录" reason=CLOCK_BEHIND_DATA expect=>=1792769793 got=1775489853 impact=not_recording
```

```
$ r3mini-traffic run        # 服务已在运行时，第二个实例立即退出，退出码 254
r3mini-traffic 已在运行 pid=8742（/var/run/r3mini-traffic/pid）
```

```
$ r3mini-traffic report --data-dir /tmp/../x
data_dir 含不安全字符: /tmp/../x
```

`manage.py` 出错时打印原因码并以退出码 1 停止：

| 原因码 | 处置 |
|---|---|
| `PINNED_HOST_KEY_MISSING` | 先经可信链路核对主机密钥指纹，写进 `~/.ssh/known_hosts` |
| `SSH_LOGIN_FAILED` | 核对私密文档里的口令；设备不在线时会直接报连接超时 |
| `NO_BASELINE_BACKUP` | 先运行 `backup` |
| `IDENTITY_MISMATCH` | 主机名、LAN 地址或 eth0 MAC 与备份时不符，确认目标设备 |
| `BASELINE_DRIFT` | 备份之后设备有变化（输出里列出路径），重新 `backup` 再装 |
| `TARGET_EXISTS` | 要装的文件已经存在：已经装过就用 `upgrade`；是残留就先 `uninstall` |
| `NOT_IN_INSTALLED_STATE` | `upgrade` 时设备不处于「刚装好」的状态（输出里列出差异），先 `verify` 找原因 |
| `DATA_MOUNT_MISSING` / `DATA_DISK_LOW` | 挂上数据分区，或腾出空间到 500 MB 以上 |
| `UNEXPECTED_CHANGES` | 安装后的差异超出那 6 项：按输出的路径核对是不是别的改动，必要时 `uninstall` |
| `NOT_RESTORED` | 卸载后快照与改前不一致，输出里列出差异路径。<br>• 不加 `--purge-data` 时，留下的数据目录本来就允许，不算差异。<br>• 差异只涉及本模块的 3 个文件或开机链接时，原样重跑同一条命令（`--purge-data` 带不带与第一次一致），`uninstall` 可以重复执行。<br>• 出现其他路径，说明是别的改动：停下来人工核对，需要时用 `check-backup --extract` 解出改前文件逐个比对 |
| `PROCESS_STILL_RUNNING` | 卸载后进程还在：`/etc/init.d/r3mini-traffic stop` 后重试 |
| `HEALTH_REGRESSION` | 原有功能检查不通过，输出里列出哪一项。<br>• **对比基准**：`install` 和 `uninstall` 用安装前那一刻的检查结果，`upgrade` 用升级前现取的，这几种情况下每一项都必须相等。<br>• **单独 `verify`**：基准可能是几天前的，OpenClash 进程号、服务列表的变化只打印 `HEALTH_DIFF_WARN`，不判失败。节点延迟或本机外网不通仍判失败。<br>• **装/升级当次出现时回滚**：用不带 `--purge-data` 的 `uninstall`，数据保留；回到改前后再逐项核对 |
| `WAIT_TIMEOUT` | 等待状态或数据文件超时：看输出里的 `last=`，再看设备日志 |

## 测试

- **`python traffic-logger/test_replay.py`**：只自检 Python 参照实现，通过时输出一行 `ORACLE_SELF_CHECK_OK rows=<行数> files=<文件数>`。它生成构造场景，与手写的期望值（`EXPECTED_SYNTHETIC`、`EXPECTED_FILES`）逐行比对。构造场景覆盖：
  - 跨整点与午夜、连接关闭、核心重启、负差额结转、带策略组的 DIRECT/REJECT；
  - 墓碑、同轮重复行、超线速旧流、端口复用；
  - SNAT 转发、ACK 为主的转发、卸载状态切换；
  - 应当排除的形态：透明代理、DNAT、本机发起、SNAT 到非本机地址。
- **`manage.py selftest HOST`**：把真实录制的 `/connections` 快照、构造场景和设备上现抓的连接跟踪表交给设备上的 ucode 版重放，与参照实现逐行比对行内容和文件名。此外测维护（含两种崩溃恢复）、时钟落后、未运行状态、单实例锁、订阅节点标注。每项输出 `<名称>_OK` 或 `<名称>_FAIL`。
