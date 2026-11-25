# 上网出口与 Wi-Fi 上网

更新时间：2026-11-25 +08:00。

适用范围：

- **源机 `192.168.0.242`**：已部署，见「2026-11-25 部署记录」。
- **克隆机 `.246`**：2026-11-25 22:19 经用户同意也部署了同一版，见「2026-11-25 克隆机 .246 部署记录」。
  - 它没有 5G 模块，蜂窝卡片显示未配置。
  - Wi-Fi 上网仍是关闭（`r3mini_hotspot.main.enabled=0`），由用户在页面上自己启用。
  - 启用前先确认 `.242` 不在同一个 LAN：两台连同一部手机时会被拉到同一信道，互相干扰（见「硬件约束」）。
  - 在本机连它用密钥 `~/.ssh/mingdaren_246_ed25519`，主机指纹已在 `~/.ssh/known_hosts`。

LuCI 位置：「网络 → 上网出口」，地址 `/cgi-bin/luci/admin/network/r3mini-hotspot`。2026-11-25 前这一页叫「手机热点 WAN / 网络接力控制台」。

## 页面能做什么

- **当前出口**：显示正在用哪条线路（有线 WAN、5G 蜂窝、Wi-Fi 上网）及 IP、网关。三张卡片各写状态：正在使用 / 可用 / 未连上 / 已暂停 / 未启用；不可用时写原因。
- **优先使用**：自动 / 有线 WAN / 5G 蜂窝 / Wi-Fi 上网。不在线的出口按钮不可点，按钮下方写明哪些不可选。
  - 自动：metric 有线 10、蜂窝 20、Wi-Fi 30。
  - 固定某条：那条 metric 5，其余 20/30；选中的断了仍会走其他在线线路。
  - 切换后核对内核默认路由，不对就恢复原路由和配置。
- **5G 蜂窝卡片**：
  - 拨号没连上时显示「暂停拨号」，即设 `network.<蜂窝接口>.auto=0` 再 `ifdown`。
  - 已暂停时显示「恢复拨号」：先经空闲的 AT 口（`/dev/ttyUSB2`、`/dev/ttyUSB3`）发 `AT+CPIN?` 查 SIM 卡。查到没卡就拒绝；查不出结果照常恢复。
- **Wi-Fi 上网**（连手机热点或附近任意 Wi-Fi）：
  1. 勾选「启用 Wi-Fi 上网」，选频段（2.4 GHz / 5 GHz）。这个频段的本机 Wi-Fi 必须开着，搜索和保存都要借用它。
  2. 点「搜索附近 Wi-Fi」：用该频段本机 AP 做 `iwinfo scan`，约 2 秒，**不停 AP、不断网**。列表里同名网络只留信号最强的，连不了的会写明原因。
  3. 点「选择」，或直接输入名称（最长 32 字节）。需要密码时输入 8–63 字节的密码（按字节算，中文一个字占 3 字节）。同一个网络留空则沿用已保存的密码；开放网络不显示密码框。
  4. 点「保存并连接」：只有设置有改动且合法时才可点，确认框写明会断哪个频段。保存在后台进行，页面显示进度：搜索 → 写入 → 切信道 → 连接 → 完成或失败。
  5. 取消勾选后，按钮变成「停用 Wi-Fi 上网」：停用 STA，并把该频段恢复到原信道。

刷新：

- 平时每 5 秒读一次状态。
- 标签页在后台时不读，切回来立即读一次。
- 保存任务进行中，以及切换出口、蜂窝开关后 8 秒内，每秒读一次。
- 连续两次读不到：页面写「读不到状态，正在重试」，并禁用出口按钮。保存任务进行中读不到时，改写「路由器正在重配 Wi-Fi」。

## 硬件约束

- `radio0`（2.4 GHz）和 `radio1`（5 GHz）各自只能同时用一个信道（`#channels <= 1`）。所以 Wi-Fi 上网用哪个频段，本机该频段的 AP 就必须改到对方所在信道：
  - 保存和停用时，该频段 AP 断开十几秒。
  - 从一个频段换到另一个频段时，原来那个频段也会恢复原信道并重配，同样断开十几秒。页面的提示和确认框会写明两个频段。
  - 第一次启用时，会把 `wwan` 加进防火墙 wan 区并重载一次防火墙。这一下对已有连接的影响没有实测过。
- **STA 没连上时，同频段的本机 AP 会暂停。** 这是 OpenWrt 的设计：wpa_supplicant 在 STA 处于断开、扫描、认证状态时，会通知 hostapd 停掉同一射频上的 AP，连上后再恢复（`/usr/share/hostap/wpa_supplicant.uc` 的 `iface_hostapd_notify`）。所以手机热点一关，本机这个频段的 Wi-Fi 也跟着停。
  - 看门狗在约 2 分钟后「停靠」，让本机 AP 恢复，见下一节。
  - 保存前的提示和确认框都写明了这一点；建议 Wi-Fi 上网用连接设备少的那个频段。
  - 页面顶部会标出「暂停中」的本机 Wi-Fi。判断依据是 hostapd 报告的状态（`ubus call hostapd.<网卡> get_status` 的 `status` 不是 `ENABLED`），不靠推断。
- 能跟过去的信道：
  - 2.4 GHz：1–13。
  - 5 GHz：只有 36、40、44、48、149、153、157、161。本机 5 GHz 用 HE80、不用 DFS；52–144 要先做雷达检测，165 只能用 20 MHz。
- 不支持：企业认证（802.1X）、WEP、隐藏名称的网络。保存时必须先搜到对方。
- 加密方式按搜索结果确定：

  | 搜到的加密 | 写入的 encryption |
  |---|---|
  | WPA2+WPA3 | `sae-mixed` |
  | 仅 WPA3 | `sae` |
  | WPA2 | `psk2` |
  | WPA/WPA2 | `psk-mixed` |
  | 开放 | `none` |
- 5 GHz 跟到 149–161 时，会和克隆机的 149 落在同一个 80 MHz 块里，两台互相干扰。办法是把克隆机的 `wireless.radio1.channel` 改到 36–48 里的一个；这要先取得用户同意并备份。

## 自动重连（看门狗）

`/etc/init.d/r3mini-hotspot` 常驻 `/usr/sbin/r3mini-hotspot-watchdog`，只在 Wi-Fi 上网启用时工作。它有两种状态：

- **连接中**（STA 开着）：
  - 每 `check_interval` 秒（默认 20）检查一次，连续 `failure_limit` 次（默认 3）没连上算一轮。每轮记下 STA 卡在哪一步（见「日志与调试面板」）。
  - 重连交给 wpa_supplicant 自己做，看门狗不重配射频。旧版每轮都 `ifup wwan`，而 `ifup` 会让这个频段重配一次，本机 AP 跟着闪断。现在只有 wwan 被手动关闭（`autostart=false`）时才 `ifup`。
  - 连续 2 轮（约 2 分钟）还没连上，就**停靠**：把 `wireless.r3mini_phone_sta.disabled` 设成 1（`r3mini_hotspot.main.enabled` 仍是 1），重载一次网络配置，本机 AP 随之恢复。不执行 `ifdown wwan`。
- **停靠中**（`enabled=1` 而 STA `disabled=1`；页面显示「等对方出现」）：
  - 每隔一段时间用本机 AP 做一次 `iwinfo scan`（不停 AP）。搜到对方，就把本机这个频段改到对方信道、打开 STA，再重载一次网络配置。
  - 间隔从 60 秒起。打开后 10 分钟内又停靠（搜得到却连不上，多半是密码或信号问题），间隔翻倍，最长 1800 秒；连上后恢复 60 秒。
- 连上之后对方换信道，由 wpa_supplicant 的信道切换（CSA）带着本机 AP 一起换，看门狗不管。
- 页面的保存任务在跑时，看门狗不动手。它和页面共用写锁 `/var/lock/r3mini-hotspot-write`。
- 每次重配前都会检查 `/tmp` 权限，重配后都会核对本机 AP 是否起来；没起来就把这个频段关了再开（`ubus call network.wireless down/up`）。见「本机 Wi-Fi 起不来」一节。
- 每小时清理一次超过保留期的旧日志。

## 受管文件与设置

| 文件 | 作用 |
|---|---|
| `/usr/sbin/r3mini-hotspot-web` | 后端：`status`、`debug`、`scan <radio>`、`save <radio> <ssid> <密码文件\|->`、`disable`、`prefer <auto\|wan\|cellular\|hotspot>`、`cellular <on\|off>` |
| `/usr/share/r3mini-hotspot/status.uc` | `status` 与 `debug` 的实现。`status` 一个 ucode 进程读完 uci、ubus 和 `/proc/net/route`，不调外部命令，设备上实测 34–59 ms；`debug` 另读日志，约 0.5 秒 |
| `/usr/share/r3mini-hotspot/log.uc` | 日志的唯一写入口：时间戳、轮转、清理都在这里 |
| `/usr/sbin/r3mini-hotspot-watchdog` | 自动重连 |
| `/etc/init.d/r3mini-hotspot` | 启动看门狗；启动时删掉残留的密码临时文件 |
| `/usr/share/luci/menu.d/luci-app-r3mini-hotspot.json` | 菜单「网络 → 上网出口」 |
| `/usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json` | 只放行执行后端，以及写、删 `/tmp/r3mini-hotspot-key-*` |
| `/www/luci-static/resources/view/network/r3mini-hotspot.js` | 页面 |
| `/etc/config/r3mini_hotspot` | 设置；部署时设备上已有就不覆盖 |

`/etc/config/r3mini_hotspot` 的选项：

| 选项 | 含义 |
|---|---|
| `enabled` | Wi-Fi 上网是否启用 |
| `radio` | 用哪个频段（`radio0` / `radio1`） |
| `interface` | 固定为 `wwan` |
| `preferred_egress` | 优先出口 |
| `check_interval`、`failure_limit` | 看门狗参数，默认 20、3 |
| `cooldown` | 旧版看门狗用的，现在不用；页面状态里仍会读出来 |
| `original_channel_radio0`、`original_channel_radio1` | 启用前该频段的信道，停用或换频段时恢复。旧版的 `original_channel` 只记 5 GHz，第一次保存时自动改成 `original_channel_radio1` |
| `target_channel` | 当前跟随的信道 |

保存流程的实现要点：

- **后台执行**：`save` / `disable` 立即返回，真正的工作在 `setsid` 起的独立进程里跑，进度写在 `/tmp/r3mini-hotspot-job.json`。这样不受 rpcd 30 秒的执行上限限制。rpcd 用 `-t 30` 启动，超时直接 SIGKILL，清理代码不会执行；这一点 2026-11-25 已在设备上实测。
- **密码不进命令行**：页面把密码写进 `/tmp/r3mini-hotspot-key-<16 位十六进制>`（0600）。后端确认路径对、不是符号链接后把文件挪走，用完即删。
- **锁可回收**：锁文件里记 PID，持有进程死了，下次自动回收；旧版留下的 `mkdir` 目录锁也会被清掉。
- **只重载一次**：写完配置后执行一次 `ubus call network reload`，netifd 会重配所有配置有变化的频段，然后等这些频段在 `network.wireless status` 里变成 `up=true、pending=false`（最多 30 秒）。旧版对每个频段各执行一次 `wifi reconf`，而每次 `wifi reconf` 都附带一次 `network reload`，同一个频段被重配了两次。11-25 19:22 实测：连上 7 秒后热点和上网又各断了约 5 秒。
- **不 ifdown**：停用和停靠只把 STA 设成 `disabled`，wwan 自然断开。`ifdown wwan` 会被 netifd 记成手动关闭，之后重配射频 STA 不会启动；遇到这种状态（旧版留下的）时才补 `ifup wwan`。
- **失败还原**：写配置或重配失败时，恢复 network、wireless、firewall、r3mini_hotspot 四份配置，再重载一次。
- **防火墙**：只在第一次把 `wwan` 加进 wan 区时重载。
- **重配前修 `/tmp` 权限、重配后核对本机 AP**：
  - 本机 AP 30 秒内没起来（看 `/sys/class/net/<AP 网卡>` 在不在），保存任务会恢复保存前的设置再等一次。
  - 两次都没起来，任务失败，并在消息里写出手工恢复命令。
  - 停用任务不回滚，只再重配一次。

## 日志与调试面板

日志在 `/mnt/mmcblk0p6/r3mini-hotspot/hotspot.log`（数据分区，重启不丢；目录 0700、文件 0600）。数据分区没挂上时写 `/tmp/r3mini-hotspot-log/hotspot.log`，每行带 `persist=false`，重启会丢。

- **行格式**：`<时间> <级别> <run_id> <事件> <说明> [k=v …]`。
  - 时间是带毫秒和时区的 ISO8601，例如 `2026-11-25T19:47:17.270+08:00`。
  - run_id：保存、停用任务是任务号（与页面上任务的 id 相同），看门狗是 `wd-<PID>`，其余命令是 `cmd-<时间>-<PID>`。
- **级别**：ERROR 表示目标没达成；WARN 表示降级但达成；INFO 是阶段推进；DEBUG 是外部命令的原文、退出码、耗时和输出摘要。
- **主要事件**：
  - `job.start` / `job.step` / `job.found` / `job.write` / `job.connect` / `job.end`：保存或停用的全过程。`job.end` 带 `result=done|failed` 和 `reason`。
  - `reason` 取值：`connected`、`not_connected_auth`（多半密码不对）、`not_connected_absent`（没找到对方或信号弱）、`not_connected_dhcp`（连上了没拿到地址）、`not_found`、`unsupported_channel`、`enterprise`、`wep`、`need_password`、`bad_password_length`、`reload_failed`、`write_failed`、`ap_not_up`、`ap_not_up_hard`、`lock_busy`、`interrupted` 等。
  - `net.reload`、`radio.settle`、`ap.check`、`radio.kick`、`wwan.ifup`、`tmp.fix`：重配过程。
  - `wd.start` / `wd.round` / `wd.park` / `wd.probe` / `wd.unpark` / `wd.up`：看门狗。
  - `prefer.set`、`cellular.set`、`scan.done`、`cmd.fail`：页面上的其他操作。
- **密码**：一律不进日志，`job.start` 只记 `new_key=yes|no`。
- **轮转与清理**：单个文件超过 256 KB 就轮转成 `.1`、`.2`、`.3`，最多 4 份约 1 MB；轮转出的文件超过 14 天删除。看门狗每小时清理一次，每次轮转时也会清理。
- 在设备上直接看：`tail -n 50 /mnt/mmcblk0p6/r3mini-hotspot/hotspot.log`。

**调试面板**：页面右下角的「调试」按钮。打开后显示：

- 发现的问题：`/tmp` 权限、本机 AP 网卡不存在或 hostapd 没在发射、频段重配中或启动失败、STA 没启动或卡在哪一步、wwan 被手动关闭、看门狗没运行、最近任务失败、日志不持久。
- 当前状态：各频段、STA（wpa_supplicant 状态、频率、信号）、wwan、看门狗 PID、目录权限、日志位置。
- 本模块最近 120 行日志，以及系统日志里跟无线有关的最近 100 行（已滤掉 `handle_probe_req: send failed` 等刷屏行）。

面板只在打开、并且标签页在前台时读取，每 10 秒一次；关着时不读。打开与否记在浏览器里，下次进页面保持。「复制」把面板全部内容复制成文本，方便发给别人看。

## 本机 Wi-Fi 起不来（/tmp 权限）

2026-11-22 和 11-25 两次，本机两个 AP 在重配无线后消失，`wifi down/up` 和重启 wpad 都恢复不了。原因是 `/tmp` 的权限被改成了 `drwx------`，OpenWrt 默认是 `drwxrwxrwt`（1777）：

- `/var` 指向 `/tmp`，hostapd 和 wpa_supplicant 以 `network` 用户（uid 101）运行，没有越过文件权限的能力，于是进不了 `/tmp`。
- 开机时已经打开的东西照常工作。一旦重配，netifd 生成的新配置（`/var/run/hostapd-phyN.conf`、`/var/run/wpa_supplicant-*.conf`）它们读不到：
  - hostapd 加载配置失败，就把这个射频上的 AP 删掉，日志只有 `Remove interface 'phyN'`，没有 `Restart interface`；
  - netifd 随后执行 `iw dev phyN-ap0 set txpower` 时报 `command failed: No such device (-19)`；
  - wpa_supplicant 报 `Failed to open config file '/var/run/wpa_supplicant-phy0-sta0.conf', error: Permission denied`。
- 是谁把 `/tmp` 改成 0700 的，没有查实。同一时期 `/etc/openclash` 也是 0700（修改时间 11-24 13:50）。SOCKS5 模块第 3 版的注释写着，它只把「本模块自己的目录」收成 0700，说明以前可能把写临时文件的其他目录也收过。

不重启的恢复办法（2026-11-25 18:06 实测有效，两个 AP 都回来了）：

```sh
chmod 1777 /tmp
ubus call network.wireless down '{"device":"radio1"}'; sleep 2; ubus call network.wireless up '{"device":"radio1"}'
ubus call network.wireless down '{"device":"radio0"}'; sleep 2; ubus call network.wireless up '{"device":"radio0"}'
iw dev
```

`iw dev` 里出现 `phy0-ap0`、`phy1-ap0` 即为恢复。这样做不会触发 `network reload`，也不碰 OpenClash。

本模块的防护：保存、停用、看门狗停靠和重连，每次重配前都检查 `/tmp` 与 `/tmp/run` 对其他用户能否进入。不能进入就恢复成 1777 / 755，写一条 `logger` 日志，并在任务结果里注明。页面顶部会列出「现在没有在运行」的本机 Wi-Fi。

## 部署、测试、回滚

前提：

- 本机装有 Python 的 `paramiko`。`test_hotspot_page.py` 另需 `playwright` 和它的 Chromium。
- 设备主机密钥已固定在 `~/.ssh/known_hosts`。这台电脑上 `.242` 已经固定。新设备要先通过可信的物理链路核对 dropbear 指纹，再写进去；脚本遇到没固定的主机会直接拒绝。
- 私钥是主工作区的 `docs/私密/r3mini-242/id_ed25519_242`，它不进 Git。在其他 worktree 里执行时，`--key` 要写主工作区里的绝对路径。
- 所有脚本的 host 参数默认 `192.168.0.242`。

在仓库根目录按顺序执行：

```powershell
python chatgpt-routing/manage.py backup 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
python fan-dashboard/test_hotspot_backend.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
python fan-dashboard/test_hotspot_page.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242 --candidate
python fan-dashboard/deploy_hotspot.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
python fan-dashboard/test_hotspot_page.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
```

1. **整机备份**：只读抓取整个 `/etc` 和全部 r3mini 程序、页面，DPAPI 加密后存到 `backups/router/`。文件名后缀 `before-chatgpt` 是该工具固定的。
   - 用 `python chatgpt-routing/manage.py check-backup <文件>` 核对。
   - 没有现成的整机还原命令。要还原某个文件，得在本机内存里解密，从归档里取出来再传回设备。
2. **`test_hotspot_backend.py`**：在设备 `/tmp` 沙箱里，用假配置和桩命令跑后端与看门狗，不碰真实配置、无线和路由。
   - 2026-11-25 最新结果：`RESULT pass=182 fail=0`。
3. **`test_hotspot_page.py`**：在设备真实的 LuCI 页面上走查。
   - 加 `--candidate`：把本地页面换进浏览器，状态和搜索由本地后端在设备上只读执行。
   - 保存、停用、切换出口、蜂窝开关、写密码文件，都在浏览器里拦下，不会到达设备。
   - 覆盖：刷新节奏、表单规则、搜索、保存流程、恶意 SSID、320–1440 宽度、暗色、字号不小于 12 px。截图写到 `tmp/hotspot-ui/page-<时间>/`。
   - 2026-11-25：候选版和部署后最新都是 87 项 `PAGE_OK`，含右下角调试面板。
4. **`deploy_hotspot.py`**：
   - 先把要覆盖的文件备份到设备 `/root/r3mini-hotspot-backup-<时间>/`，并打印 `BACKUP=<该目录>`。
   - 装完逐个核对 SHA-256，不一致就自动回滚。
   - ACL 有变化时才重启 rpcd；此时已登录的 LuCI 要重新登录。不重启 uhttpd。
   - 成功时依次打印 `BACKUP=…`、`DEPLOY_SHA256_OK=8/8`、`PRESERVED_CONFIG_OK=1`。

回滚：用要撤销的那次部署自己打印的 `BACKUP=` 目录，里面存的是那次部署覆盖前的文件。

- 忘了目录名：在设备上执行 `ls -d /root/r3mini-hotspot-backup-*`。目录名里的时间就是部署时间，取与要撤销的那次部署同一时刻的那份。
- 部署时只改了一个文件，备份里也就只有那一个文件；用它回滚，也只退那一个文件。
- 要整版退回 2026-11-25 之前的旧版，只能用 `20261125154841`。

```powershell
python fan-dashboard/deploy_hotspot.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242 --rollback /root/r3mini-hotspot-backup-20261125154841
```

回滚的行为：

- 按那份备份的 `.touched` 清单换回文件：部署时新增的文件会被删掉；ACL 有变化就重启 rpcd；最后重启看门狗。成功打印 `ROLLBACK_OK=<目录>`。
- 回滚后不做 SHA-256 核对。需要时在设备上逐个与备份比对，没有输出就表示一致：`b=/root/r3mini-hotspot-backup-<时间>; while read f; do [ -e "$b$f" ] && cmp "$b$f" "$f"; done < "$b/.touched"`。
- 回滚不动 `/etc/config/r3mini_hotspot`。如果用新版保存过 Wi-Fi 上网再回滚旧版：旧版不认识 `original_channel_radio0/1`，停用时不会恢复信道，要手动执行 `uci set wireless.radioX.channel=<原信道>`、`uci commit wireless`、`wifi reconf radioX`。
- `20261125154841` 那份是 2026-11-25 部署前的旧版，也就是 `5279ed3`。

## 2026-11-25 部署记录

- 整机备份：`backups/router/router-backup-20261125-154829-100143-192.168.0.242-before-chatgpt.tar.gz.dpapi`，1192 条。
- 设备端文件备份：
  - `/root/r3mini-hotspot-backup-20261125154841`：旧版 7 个文件。
  - `/root/r3mini-hotspot-backup-20261125155322`、`…160107`、`…160950`：三次补装各自的备份，依次只含上一份页面、后端、页面。
- 部署后：
  - 看门狗 running，`S95r3mini-hotspot` 在。
  - 默认路由仍是 `eth1` metric 5，OpenClash running。
  - `status` 用时 59 ms。旧版要 150–160 ms，而且旧页面从不自动刷新。
- 5G 刷屏的处置（用户 2026-11-25 同意）：
  - 原因：模块里没插 SIM 卡。`AT+CPIN?` 回 `+CME ERROR: 10`，`+CFUN: 0`，ModemManager 报 `failed / sim-missing`。quectel-cm 开射频失败（`mbim_set_radio_state … Status=2`）就退出，netifd 立刻重拉；7 秒内 38 次，128 KB 日志只能留 7 秒。
  - 处置：
    - 执行 `r3mini-hotspot-web cellular off`：设 `network.RM500CNV.auto=0` 并 `ifdown`。
    - ModemManager 执行 `stop` 和 `disable`。没有任何接口用 modemmanager 协议，它和 quectel-cm 重复占着同一个模块。
  - 结果：日志 10 秒内没有新增一行，负载从约 1.6 降到 0.66。
  - 插卡后：在页面点「恢复拨号」就够了，拨号由 quectel-cm 负责，不需要 ModemManager。
  - 只有把蜂窝接口改成 `modemmanager` 协议时，才要恢复 ModemManager：`/etc/init.d/modemmanager enable && /etc/init.d/modemmanager start`。
  - 不要让 ModemManager 和 quectel 协议同时管这块模块。11-25 实测 ModemManager 会占住 `ttyUSB2`，「恢复拨号」查 SIM 卡时只能改用 `ttyUSB3`，查不出结果就照常恢复。

2026-11-25 17:59 的故障：用户在页面上保存了 2.4 GHz 的 Wi-Fi 上网、又停用，本机两个 AP 都没再起来，原因见「本机 Wi-Fi 起不来」一节。18:06 按该节命令恢复，没有重启。18:26 部署了防护版：

- 页面和后端：重配前修 `/tmp` 权限、重配后核对本机 AP；看门狗停靠；页面顶部的本机 Wi-Fi 告警；表单与路由器状态同步；字号 14 px。
- 设备端文件备份：`/root/r3mini-hotspot-backup-20261125182636`。
- 部署后两个本机 AP 都在，`status` 里 `ap_up` 都是 true，信道 12、48。

18:44 用户在页面上把 Wi-Fi 上网保存为 2.4 GHz 的手机热点「nl」：

- 保存后 STA 没有启动。原因是之前停用时执行过 `ifdown wwan`，netifd 把 wwan 记成手动关闭，而保存只重配了射频。
- 一直等到看门狗第一轮 `ifup wwan`（18:46:33），4 秒后连上（18:46:41，信号 −31 dBm），本机 2.4 GHz AP 跟到信道 6，两个本机 AP 都正常。
- 这段时间本机 2.4 GHz AP 实际一直开着（日志 `AP-ENABLED`），页面却按推断显示「暂停中」。

18:59 部署了修正：

- 保存时补 `ifup wwan`；
- AP 是否暂停改读 hostapd 的真实状态；
- 页面去掉多余留白：全宽、区块内边距 16 px、Wi-Fi 上网区宽屏两栏、不用会被 argon 加 1rem 内边距的 `<p>`。

设备端文件备份：`/root/r3mini-hotspot-backup-20261125185952`。

已在真机验证：连接 2.4 GHz 手机热点、本机 AP 跟到对方信道。

19:21:49 用户又保存了一次：

- 11 秒连上（19:22:00），`ifup wwan` 修正生效。
- 但连上 7 秒后（19:22:05），2.4 GHz 又重配了一次，热点和上网各断约 5 秒。原因：后端对两个频段各执行一次 `wifi reconf`，每次都附带 `network reload`。第一次已在重配 radio0，第二次又叠了上去，radio0 迟迟不报启动完成，约 13 秒后被 netifd 超时重来。

19:47 部署了修正：

- 只重载一次、不 ifdown、看门狗不再每轮 ifup；
- 没连上时按 STA 实际状态说明原因；
- 写结构化日志并轮转清理；
- 页面右下角加调试面板；
- 保存进行中显示已用秒数。

设备端文件备份：`/root/r3mini-hotspot-backup-20261125194717`。

还没在真机验证（会断 Wi-Fi，需要用户在场并同意）：

- 用 19:47 的版本再保存一次，确认只断一次；
- 5 GHz 与 2.4 GHz 互换；
- 停用后恢复信道；
- 看门狗停靠和重连；
- 有 SIM 卡时恢复拨号。

## 2026-11-25 克隆机 .246 部署记录

部署前 `.246` 装的是 `5279ed3` 的旧版（「手机热点 WAN」页面），看门狗没开机自启、处于 inactive。当时现场：

- `.242` 不在这个 LAN 上：`192.168.0.0/24` 里只有 `.246` 和一台固定 IP 的电脑。
- `.246` 的 WAN `eth1` 接上级中继，DHCP 取地址。
- 旧版「保存并应用」连手机热点失败，日志里同一秒内建了又删扫描网卡 `r3scan0`，之后没有任何关联记录。新版改用 `iwinfo scan` 借本机 AP 搜索，不再停 AP。

按「部署、测试、回滚」的顺序执行，`--key` 换成 `~/.ssh/mingdaren_246_ed25519`，host 换成 `192.168.0.246`：

- 整机备份：`backups/router/router-backup-20261125-221728-602460-192.168.0.246-before-chatgpt.tar.gz.dpapi`，778 条，`SCOPED_RESTORE_DRILL_OK`；`check-backup` 复核通过。
- `test_hotspot_backend.py`：`RESULT pass=182 fail=0`。
- `deploy_hotspot.py`：`CHANGED_FILES=8`、`ACL_CHANGED=1`、`DEPLOY_SHA256_OK=8/8`、`PRESERVED_CONFIG_OK=1`。8 个文件里 6 个是覆盖旧版，`status.uc`、`log.uc` 两个是新增。
- 设备端文件备份：`/root/r3mini-hotspot-backup-20261125221944`，`.touched` 列了这 8 个文件。

部署后：

- 与整机备份的快照逐项比对：快照范围内只有本模块被覆盖的 6 个文件变了，另外新增了 `S95`/`K05r3mini-hotspot` 两个开机链接；`/etc/config/` 下全部配置未变。`status.uc`、`log.uc` 所在的 `/usr/share/r3mini-hotspot/` 不在快照范围内。
- 看门狗 running，并已开机自启（部署前两者都没有）；`r3mini_hotspot.main.enabled=0`，`wireless.r3mini_phone_sta.disabled=1`。
- 两个本机 AP 都在：信道 6、149。默认路由仍走 `eth1`，`ping 223.5.5.5` 通，DNS 正常，OpenClash running。
- 路由器上的 8 个受管文件与仓库 SHA-256 一致。
- 部署后 `main` 又合入了 `4684330`：只给 `deploy_hotspot.py` 加了读取 `R3MINI_SSH_KEY` 的功能，路由器侧文件没有变化，`.246` 上的仍是最新版。

退回旧版（`5279ed3` 的「手机热点 WAN」）：

```powershell
python fan-dashboard/deploy_hotspot.py 192.168.0.246 --key ~/.ssh/mingdaren_246_ed25519 --rollback /root/r3mini-hotspot-backup-20261125221944
```

回滚会换回 6 个旧文件、删掉 `status.uc` 和 `log.uc`，最后重启看门狗；开机链接不会撤。要回到部署前「看门狗不自启、不运行」的状态，回滚成功后在设备上再执行 `/etc/init.d/r3mini-hotspot disable && /etc/init.d/r3mini-hotspot stop`。

启用 Wi-Fi 上网之前：

- 在 `.246` 上执行 `ping -c 2 -W 2 192.168.0.242`，再看 `ip neigh show 192.168.0.242`。两样都没有回应、也没有 `REACHABLE`/`STALE` 记录，才算 `.242` 不在这个 LAN。
- `.242` 在同一个 LAN 时不要启用，先问用户。
- 页面测试 `test_hotspot_page.py` 在 `.242` 上对同一版跑过（见上节「部署、测试、回滚」第 3 步）；`.246` 上没跑，因为这台电脑没装 `playwright`。它只检查页面，不是启用的前置条件。
- Wi-Fi 上网没在 `.246` 上启用过。上一节「还没在真机验证」的各项，对 `.246` 同样都没有验证。

整机备份可以用 `python chatgpt-routing/manage.py check-backup <文件>` 复核条数和抽样还原：它只在本机内存里解密，不连路由器。

## 失败处置

消息从哪里来：

- 后端命令当场拒绝时，把消息写到 stderr 并以退出码 1 结束，页面原样显示。
- 后台任务的结果写在 `/tmp/r3mini-hotspot-job.json` 的 `message` 里，`state` 为 `failed`（失败）或 `done`（完成）。
- 「任务进程意外退出」是 `status` 发现任务进程已不在时补的。

下表按消息原文查。

| 消息原文 | 出处 | 原因与处置 |
|---|---|---|
| `已有 Wi-Fi 设置任务在执行，请等它结束` | save / disable | 另一个任务还在跑，等页面显示完成或失败。任务进程活着但卡住时：在设备上取 `/tmp/r3mini-hotspot-job.json` 的 `pid`，`kill` 它，再重试 |
| `另一项出口或 Wi-Fi 设置正在执行，请稍后再试` | 各写命令 | 写锁 20 秒内没拿到（切换出口、蜂窝开关、看门狗跟信道），稍后重试 |
| `频段无效`、`请填写 Wi-Fi 名称`、`Wi-Fi 名称不能超过 32 字节`、`Wi-Fi 名称不能包含换行`、`密码不能包含换行` | save / scan | 输入不合法，改正后重试 |
| `密码临时文件无效`、`密码临时文件不存在`、`密码临时文件读取失败` | save | 页面传密码失败，刷新页面重试。命令行调用时用 `-`，或用合规的 `/tmp/r3mini-hotspot-key-<16 位十六进制>` 文件 |
| `这个频段的本机 Wi-Fi 没有运行，无法搜索` | 任务 failed | 保存时借本机 AP 搜索，但它不在。先恢复本机 AP（见「本机 Wi-Fi 起不来」） |
| `没搜到「X」；请确认它开着、在这个频段，并靠近路由器` | 任务 failed | 对方没开、频段选错，或者是隐藏网络。换频段或靠近后重试 |
| `「X」在信道 N，本机 Wi-Fi 不能跟过去（…只支持…）` | 任务 failed | 在手机上把热点改到受支持的信道或频段后重试 |
| `这个 Wi-Fi 用企业认证（802.1X），不支持`、`这个 Wi-Fi 用 WEP 或未知加密，不支持` | 任务 failed | 不支持，换一个网络 |
| `请输入这个 Wi-Fi 的密码`、`密码必须是 8–63 个字符` | 任务 failed | 换了网络必须输入密码；长度按字节算 |
| `没找到防火墙 wan 区域`、`无法创建临时备份`、`无法备份 X 配置` | 任务 failed | 路由器环境异常（防火墙配置被改，或 `/tmp` 满了）。什么都没改，查明后重试 |
| `…；已恢复保存前的设置` | 任务 failed | 写配置或重配失败，四份配置已还原。到「网络 → 无线」看该频段是否正常，再重试 |
| `任务中断；配置已尽量恢复，请检查后重试` | 任务 failed | 任务被信号中断。到「网络 → 无线」核对 STA 和信道后，重新保存或停用 |
| `任务进程意外退出；请检查 Wi-Fi 设置后重试` | status | 任务被强杀，例如路由器重启，配置可能停在中途。核对 STA 和信道后，重新保存或停用 |
| `已保存，但 45 秒内没连上「X」…` | 任务 **done** | 页面显示为「完成」，设置已生效，只是还没连上。常见原因是密码不对、信号弱或对方不分配地址。没连上期间本机这个频段的 Wi-Fi 暂停，约 2 分钟后看门狗停靠让它恢复 |
| `本机 X Wi-Fi 重配后没能起来，已恢复保存前的设置，本机 Wi-Fi 已回来` | 任务 failed | 新设置让本机 AP 起不来，已自动退回。查 `logread \| grep -E "hostapd\|netifd"` 后再试 |
| `本机 X Wi-Fi 重配后起不来，恢复原设置后也没起来…`、`已停用 Wi-Fi 上网，但本机 X Wi-Fi 没能起来…` | 任务 failed | 按「本机 Wi-Fi 起不来」一节的命令恢复；还不行才重启路由器（先问用户） |
| `无法恢复 /tmp 权限，无线服务会读不到配置` | 任务 failed | `chmod 1777 /tmp` 本身失败，已还原，没有重配。手工检查 `/tmp` |
| `本机 X Wi-Fi 现在没有运行，没法借它搜索` | scan | 本机这个频段的 AP 网卡不在，先按「本机 Wi-Fi 起不来」一节恢复 |
| `这次没搜成；如果 Wi-Fi 上网正用这个频段且还没连上…` | scan | 本机 AP 暂停中时搜不了。等连上、停靠后，或先停用 Wi-Fi 上网再搜 |
| `有线 WAN 当前没有取得 IPv4 地址`、`蜂窝网络当前没有连上`、`Wi-Fi 上网当前没有连上` | prefer | 目标出口不在线，不能选 |
| `保存出口选择失败；已恢复`、`切换后默认路由不对；已恢复原来的出口` | prefer | 已还原。查 `ip -4 route show default` 和 `ifstatus <接口>` |
| `没有配置蜂窝网络接口`、`保存失败` | cellular | 前者是 network 里没有蜂窝协议的接口；后者是 uci 提交失败，查 overlay 空间 |
| `5G 模块里没检测到 SIM 卡；插好卡后再启用` | cellular on | 插卡后重试 |

部署器的 error_kind（`python fan-dashboard/deploy_hotspot.py --help` 里也有）：

| error_kind | 处置 |
|---|---|
| `PINNED_HOST_KEY_MISSING` | 先固定主机密钥，见「前提」 |
| `SSH_KEY_MISSING`、`SSH_KEY_LOGIN_FAILED` | `--key` 路径不对，或设备不认这把密钥 |
| `HOST_KEY_MISMATCH` | 设备的主机密钥与固定的不一致。停下来，可能不是同一台设备（重刷过，或 IP 被别的设备占了）。不要删 `known_hosts` 里的记录去绕过，通过可信的物理链路核对指纹后报告用户 |
| `SSH_CONNECTION_FAILED=<异常类>` | 连不上。先查地址对不对、设备是否在线：`Test-NetConnection 192.168.0.242 -Port 22` |
| `UNEXPECTED_DEVICE=<board>` | 不是 BPI-R3 Mini，没有写入任何东西。以上连接类错误都发生在执行任何命令之前，设备上什么都没改 |
| `SHA256_MISMATCH=<文件>`、`PRESERVED_CONFIG_MISSING` | 已自动回滚。看 `ROLLBACK_OK=` 确认 |
| `DEPLOY_BACKUP_MARKER_MISSING` | 设备端脚本没报告备份目录，部署结果不明。在设备上 `ls -d /root/r3mini-hotspot-backup-*` 找最新一份，核对后决定是否回滚 |
| `RuntimeError: remote command failed`，附带 `DEPLOY_ROLLBACK=<目录>` | 设备端脚本中途失败，已按备份还原 |
| 同上，但附带 `DEPLOY_ROLLBACK_FAILED=<目录>` | 还原不全。用 `--rollback <目录>` 再试；仍失败就从那个目录手动拷回文件 |
| `ROLLBACK_BACKUP_INVALID` | `--rollback` 给的目录格式不对，或目录里没有 `.touched` |

保存后该频段的本机 Wi-Fi 一直不出现时，停止继续写入，按下面的顺序处理：

1. 从有线 LAN（或另一个频段的 Wi-Fi）进页面，停用 Wi-Fi 上网。
2. 页面打不开时，从电脑用 SSH 执行停用。它在后台恢复原信道并重配，约十几秒：

   ```powershell
   ssh -i docs/私密/r3mini-242/id_ed25519_242 -o IdentitiesOnly=yes root@192.168.0.242 /usr/sbin/r3mini-hotspot-web disable
   ```

3. 确认停用完成：在设备上执行 `/usr/sbin/r3mini-hotspot-web status | jsonfilter -e '@.job.state' -e '@.job.message'`。
   - 显示 `running`：隔几秒再查。
   - 显示 `done` / `已停用 Wi-Fi 上网`：任务完成。
   - 任务结束 10 分钟后 `job` 就不再输出，这时改查配置：`uci get r3mini_hotspot.main.enabled` 应为 `0`。
   - 最后确认本机 AP 真的在广播：`iw dev` 里该频段的 `phyN-ap0` 还在，并显示 `channel`。
4. 如果 `disable` 被「已有 Wi-Fi 设置任务在执行」拒绝，按上表第一行先结束卡住的任务，再执行第 2 步。
5. 如果 `disable` 本身 `failed`，在设备上手工停用。先关掉 `enabled`，否则看门狗会继续重连，甚至把信道又改过去。以 5 GHz 为例，2.4 GHz 把 `radio1` 换成 `radio0`：

   ```sh
   uci set r3mini_hotspot.main.enabled=0
   uci set wireless.r3mini_phone_sta.disabled=1
   ch="$(uci -q get r3mini_hotspot.main.original_channel_radio1)"; [ -n "$ch" ] && uci set wireless.radio1.channel="$ch"
   uci commit r3mini_hotspot; uci commit wireless
   ubus call network reload
   ```
