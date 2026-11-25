# 上网出口与 Wi-Fi 上网

更新时间：2026-11-25 +08:00。

适用范围：

- **源机 `192.168.0.242`**：只部署在这台。
- **克隆机 `.246`**：不装本模块的新版，也不要在它上面启用 Wi-Fi 上网。它没有 5G 模块，`r3mini_hotspot.main.enabled=0`。

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
  - 保存和停用时，该频段 AP 断开十几秒，另一个频段不受影响。
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

`/etc/init.d/r3mini-hotspot` 常驻 `/usr/sbin/r3mini-hotspot-watchdog`，只在 Wi-Fi 上网启用时工作：

- 每 `check_interval` 秒（默认 20）检查一次，连续 `failure_limit` 次（默认 3）没连上就 `ifup wwan`。
- 重连 3 轮仍无效，且距上次搜索超过冷却时间，就用 `iwinfo scan` 搜一次（不停 AP）。对方换了信道时，把本机该频段改过去并 `wifi reconf`。
  - 冷却时间从 `cooldown`（默认 180 秒）起，每次翻倍，最多 1800 秒。
- 页面的保存任务在跑时，看门狗不动手。它和页面共用写锁 `/var/lock/r3mini-hotspot-write`。

## 受管文件与设置

| 文件 | 作用 |
|---|---|
| `/usr/sbin/r3mini-hotspot-web` | 后端：`status`、`scan <radio>`、`save <radio> <ssid> <密码文件\|->`、`disable`、`prefer <auto\|wan\|cellular\|hotspot>`、`cellular <on\|off>` |
| `/usr/share/r3mini-hotspot/status.uc` | `status` 的实现。一个 ucode 进程读完 uci、ubus 和 `/proc/net/route`，不调外部命令；设备上实测 34–59 ms |
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
| `check_interval`、`failure_limit`、`cooldown` | 看门狗参数，默认 20、3、180 |
| `original_channel_radio0`、`original_channel_radio1` | 启用前该频段的信道，停用或换频段时恢复。旧版的 `original_channel` 只记 5 GHz，第一次保存时自动改成 `original_channel_radio1` |
| `target_channel` | 当前跟随的信道 |

保存流程的实现要点：

- **后台执行**：`save` / `disable` 立即返回，真正的工作在 `setsid` 起的独立进程里跑，进度写在 `/tmp/r3mini-hotspot-job.json`。这样不受 rpcd 30 秒的执行上限限制。rpcd 用 `-t 30` 启动，超时直接 SIGKILL，清理代码不会执行；这一点 2026-11-25 已在设备上实测。
- **密码不进命令行**：页面把密码写进 `/tmp/r3mini-hotspot-key-<16 位十六进制>`（0600）。后端确认路径对、不是符号链接后把文件挪走，用完即删。
- **锁可回收**：锁文件里记 PID，持有进程死了，下次自动回收；旧版留下的 `mkdir` 目录锁也会被清掉。
- **失败还原**：写配置或重配失败时，恢复 network、wireless、firewall、r3mini_hotspot 四份配置，并重配受影响的频段。
- **防火墙**：只在第一次把 `wwan` 加进 wan 区时重载。

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
   - 2026-11-25 结果：`RESULT pass=101 fail=0`。
3. **`test_hotspot_page.py`**：在设备真实的 LuCI 页面上走查。
   - 加 `--candidate`：把本地页面换进浏览器，状态和搜索由本地后端在设备上只读执行。
   - 保存、停用、切换出口、蜂窝开关、写密码文件，都在浏览器里拦下，不会到达设备。
   - 覆盖：刷新节奏、表单规则、搜索、保存流程、恶意 SSID、320–1440 宽度、暗色、字号不小于 12 px。截图写到 `tmp/hotspot-ui/page-<时间>/`。
   - 2026-11-25：候选版和部署后都是 51 项，`PAGE_OK`。
4. **`deploy_hotspot.py`**：
   - 先把要覆盖的文件备份到设备 `/root/r3mini-hotspot-backup-<时间>/`，并打印 `BACKUP=<该目录>`。
   - 装完逐个核对 SHA-256，不一致就自动回滚。
   - ACL 有变化时才重启 rpcd；此时已登录的 LuCI 要重新登录。不重启 uhttpd。
   - 成功时依次打印 `BACKUP=…`、`DEPLOY_SHA256_OK=7/7`、`PRESERVED_CONFIG_OK=1`。

回滚：用某次部署打印的 `BACKUP=` 目录。忘了的话，在设备上执行 `ls -d /root/r3mini-hotspot-backup-*`，取那次部署之前最新的一份。

```powershell
python fan-dashboard/deploy_hotspot.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242 --rollback /root/r3mini-hotspot-backup-20261125154841
```

回滚的行为：

- 按那份备份的 `.touched` 清单换回文件：部署时新增的文件会被删掉；ACL 有变化就重启 rpcd；最后重启看门狗。成功打印 `ROLLBACK_OK=<目录>`。
- 回滚后不做 SHA-256 核对。需要时在设备上自己 `sha256sum` 比对。
- 回滚不动 `/etc/config/r3mini_hotspot`。如果用新版保存过 Wi-Fi 上网再回滚旧版：旧版不认识 `original_channel_radio0/1`，停用时不会恢复信道，要手动执行 `uci set wireless.radioX.channel=<原信道>`、`uci commit wireless`、`wifi reconf radioX`。
- `20261125154841` 那份是 2026-11-25 部署前的旧版，也就是 `5279ed3`。

## 2026-11-25 部署记录

- 整机备份：`backups/router/router-backup-20261125-154829-100143-192.168.0.242-before-chatgpt.tar.gz.dpapi`，1192 条。
- 设备端文件备份：
  - `/root/r3mini-hotspot-backup-20261125154841`：旧版 7 个文件。
  - `/root/r3mini-hotspot-backup-20261125155322`、`…160107`：两次补装各自的备份，分别只含新版页面、后端的上一份。
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
  - 插卡后：在页面点「恢复拨号」。要恢复 ModemManager，执行 `/etc/init.d/modemmanager enable && /etc/init.d/modemmanager start`。

下面几项没有在真机上验证，因为都会断 Wi-Fi，需要用户在场并同意：实际连接一个 Wi-Fi、2.4/5 GHz 互换、停用后恢复信道、看门狗在真机上跟随信道、有 SIM 卡时恢复拨号。

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
| `这个频段的本机 Wi-Fi 没有运行，无法搜索` | scan / 任务 | 该频段的本机 AP 被关了或被禁用，先到「网络 → 无线」打开它 |
| `搜索失败，请稍后重试` | scan | `iwinfo scan` 出错，稍后重试 |
| `没搜到「X」；请确认它开着、在这个频段，并靠近路由器` | 任务 failed | 对方没开、频段选错，或者是隐藏网络。换频段或靠近后重试 |
| `「X」在信道 N，本机 Wi-Fi 不能跟过去（…只支持…）` | 任务 failed | 在手机上把热点改到受支持的信道或频段后重试 |
| `这个 Wi-Fi 用企业认证（802.1X），不支持`、`这个 Wi-Fi 用 WEP 或未知加密，不支持` | 任务 failed | 不支持，换一个网络 |
| `请输入这个 Wi-Fi 的密码`、`密码必须是 8–63 个字符` | 任务 failed | 换了网络必须输入密码；长度按字节算 |
| `没找到防火墙 wan 区域`、`无法创建临时备份`、`无法备份 X 配置` | 任务 failed | 路由器环境异常（防火墙配置被改，或 `/tmp` 满了）。什么都没改，查明后重试 |
| `…；已恢复保存前的设置` | 任务 failed | 写配置或重配失败，四份配置已还原。到「网络 → 无线」看该频段是否正常，再重试 |
| `任务中断；配置已尽量恢复，请检查后重试` | 任务 failed | 任务被信号中断。到「网络 → 无线」核对 STA 和信道后，重新保存或停用 |
| `任务进程意外退出；请检查 Wi-Fi 设置后重试` | status | 任务被强杀，例如路由器重启，配置可能停在中途。核对 STA 和信道后，重新保存或停用 |
| `已保存，但 45 秒内没连上「X」…` | 任务 **done** | 页面显示为「完成」，设置已生效，只是还没连上。常见原因是密码不对、信号弱或对方不分配地址；看门狗每 20 秒重试 |
| `有线 WAN 当前没有取得 IPv4 地址`、`蜂窝网络当前没有连上`、`Wi-Fi 上网当前没有连上` | prefer | 目标出口不在线，不能选 |
| `保存出口选择失败；已恢复`、`切换后默认路由不对；已恢复原来的出口` | prefer | 已还原。查 `ip -4 route show default` 和 `ifstatus <接口>` |
| `没有配置蜂窝网络接口`、`保存失败` | cellular | 前者是 network 里没有蜂窝协议的接口；后者是 uci 提交失败，查 overlay 空间 |
| `5G 模块里没检测到 SIM 卡；插好卡后再启用` | cellular on | 插卡后重试 |

部署器的 error_kind（`python fan-dashboard/deploy_hotspot.py --help` 里也有）：

| error_kind | 处置 |
|---|---|
| `PINNED_HOST_KEY_MISSING` | 先固定主机密钥，见「前提」 |
| `SSH_KEY_MISSING`、`SSH_KEY_LOGIN_FAILED` | `--key` 路径不对，或设备不认这把密钥 |
| `SSH_CONNECTION_OR_PIN_FAILED` | 连不上，或主机密钥与固定的不一致。后者要停下来查，可能不是同一台设备 |
| `UNEXPECTED_DEVICE=<board>` | 不是 BPI-R3 Mini，没有写入任何东西 |
| `SHA256_MISMATCH=<文件>`、`PRESERVED_CONFIG_MISSING` | 已自动回滚。看 `ROLLBACK_OK=` 确认 |
| `DEPLOY_BACKUP_MARKER_MISSING` | 设备端脚本没报告备份目录，部署结果不明。在设备上 `ls -d /root/r3mini-hotspot-backup-*` 找最新一份，核对后决定是否回滚 |
| `RuntimeError: remote command failed`，附带 `DEPLOY_ROLLBACK=<目录>` | 设备端脚本中途失败，已按备份还原 |
| 同上，但附带 `DEPLOY_ROLLBACK_FAILED=<目录>` | 还原不全。用 `--rollback <目录>` 再试；仍失败就从那个目录手动拷回文件 |
| `ROLLBACK_BACKUP_INVALID` | `--rollback` 给的目录格式不对，或目录里没有 `.touched` |

保存后该频段的本机 Wi-Fi 一直不出现时，停止继续写入，按下面的顺序处理：

1. 从有线 LAN 进页面，停用 Wi-Fi 上网。
2. 页面打不开时，SSH 执行 `/usr/sbin/r3mini-hotspot-web disable`。它在后台恢复原信道并重配，约十几秒。
3. 用 `/usr/sbin/r3mini-hotspot-web status | jsonfilter -e '@.job'` 确认 `state` 为 `done`。
4. 如果 `disable` 被「已有任务」拒绝，按表中第一行先结束卡住的任务。
5. 如果 `disable` 本身 `failed`：在「网络 → 无线」把 `r3mini_phone_sta` 设为禁用，把该频段信道改回 `original_channel_radioX` 记的值，再保存应用。
