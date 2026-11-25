# 上网出口与 Wi-Fi 上网

更新时间：2026-11-25 +08:00。适用于源机 `192.168.0.242`。克隆机 `.246` 没装 5G 模块，`r3mini_hotspot.main.enabled=0`，不要在它上面启用 Wi-Fi 上网。

LuCI 位置：「网络 → 上网出口」，地址 `/cgi-bin/luci/admin/network/r3mini-hotspot`。2026-11-25 前这一页叫「手机热点 WAN / 网络接力控制台」。

## 页面能做什么

- **当前出口**：显示正在用哪条线路（有线 WAN、5G 蜂窝、Wi-Fi 上网），以及 IP 和网关。三张卡片各写状态：正在使用 / 可用 / 未连上 / 已暂停 / 未启用，不可用时写原因。
- **优先使用**：自动 / 有线 WAN / 5G 蜂窝 / Wi-Fi 上网。不在线的出口按钮不可点，按钮下方写明哪些不可选。
  - 自动：有线 metric 10、蜂窝 20、Wi-Fi 30。
  - 固定某条：那条 metric 5，其余 20/30，选中的断了仍会走其他在线线路。
  - 切换后核对内核默认路由；不对就恢复原路由和配置，并报「切换后默认路由不对；已恢复原来的出口」。
- **5G 蜂窝卡片**：
  - 拨号没连上时显示「暂停拨号」，即 `network.<蜂窝接口>.auto=0` 加 `ifdown`。
  - 已暂停时显示「恢复拨号」：先经空闲的 AT 口（`/dev/ttyUSB2`、`/dev/ttyUSB3`）发 `AT+CPIN?` 查 SIM 卡，查到没卡就拒绝；查不出结果照常恢复。
- **Wi-Fi 上网**（连手机热点或附近任意 Wi-Fi）：
  1. 勾选「启用 Wi-Fi 上网」，选频段（2.4 GHz / 5 GHz）。
  2. 点「搜索附近 Wi-Fi」：用该频段本机 AP 做 `iwinfo scan`，约 2 秒，**不停 AP、不断网**。列表同名只留信号最强的，并标出本机连不了的网络及原因。
  3. 点「选择」，或直接输入名称。需要密码时输入 8–63 个字符的密码；同一个网络留空则沿用已保存的密码，开放网络不显示密码框。
  4. 「保存并连接」：只有设置有改动且合法时可点，确认框写明会断哪个频段。保存在后台执行，页面显示进度：搜索 → 写入 → 切信道 → 连接 → 完成/失败。
  5. 取消勾选后按钮变成「停用 Wi-Fi 上网」：停用 STA，恢复该频段原信道。

刷新：平时每 5 秒读一次状态；标签页在后台时不读，切回来立即读一次；保存任务进行中、切换出口或蜂窝开关后 8 秒内每秒读一次。连续两次读不到时，页面写「读不到状态，正在重试」并禁用出口按钮；保存任务进行中读不到时写「路由器正在重配 Wi-Fi」。

## 硬件约束

- `radio0`（2.4 GHz）和 `radio1`（5 GHz）都只能同时用一个信道（`#channels <= 1`）。所以 Wi-Fi 上网用哪个频段，本机这个频段的 AP 就必须改到对方所在信道。保存和停用时，该频段 AP 会断开十几秒，另一个频段不受影响。
- 能跟过去的信道：
  - 2.4 GHz：1–13。
  - 5 GHz：只支持 36、40、44、48、149、153、157、161。原因是 HE80、非 DFS；52–144 要等雷达检测，165 只能 20 MHz。
- 不支持：企业认证（802.1X）、WEP、隐藏名称的网络（保存时必须先搜到它）。
- 加密方式从搜索结果判断：
  - WPA2+WPA3 → `sae-mixed`
  - 仅 WPA3 → `sae`
  - WPA2 → `psk2`
  - WPA/WPA2 → `psk-mixed`
  - 开放 → `none`
- 5 GHz 跟到 149–161 时，会和克隆机的 149 落在同一个 80 MHz 块，两台互相干扰。必要时按 `docs/必读/当前设备运行基线.md` 的做法把克隆机挪到 36–48。

## 自动重连（看门狗）

`/etc/init.d/r3mini-hotspot` 常驻 `/usr/sbin/r3mini-hotspot-watchdog`：

- Wi-Fi 上网启用后，每 20 秒检查一次，连续 3 次没连上就 `ifup wwan`。
- 重连 3 轮仍无效、且距上次超过冷却时间（180 秒起，每次翻倍，最多 1800 秒），用 `iwinfo scan` 搜一次（不停 AP）。对方换了信道就把本机该频段改过去并 `wifi reconf`。
- 页面的保存任务在跑时，看门狗不动手；它和页面共用 `/var/lock/r3mini-hotspot-write` 写锁。

## 受管文件

| 文件 | 作用 |
|---|---|
| `/usr/sbin/r3mini-hotspot-web` | 后端命令：`status`、`scan <radio>`、`save <radio> <ssid> <密码文件\|->`、`disable`、`prefer <auto\|wan\|cellular\|hotspot>`、`cellular <on\|off>` |
| `/usr/share/r3mini-hotspot/status.uc` | `status` 的实现：一个 ucode 进程读完 uci、ubus、`/proc/net/route`，不起外部命令；设备上实测 46–59 ms |
| `/usr/sbin/r3mini-hotspot-watchdog` | 自动重连，见上节 |
| `/etc/init.d/r3mini-hotspot` | 起看门狗；启动时删掉残留的密码临时文件 |
| `/usr/share/luci/menu.d/luci-app-r3mini-hotspot.json` | 菜单「网络 → 上网出口」 |
| `/usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json` | 只放行执行后端，以及写/删 `/tmp/r3mini-hotspot-key-*` |
| `/www/luci-static/resources/view/network/r3mini-hotspot.js` | 页面 |
| `/etc/config/r3mini_hotspot` | 设置；部署时设备上已有就不覆盖 |

`/etc/config/r3mini_hotspot` 里由程序维护的选项：

- `enabled`、`radio`：是否启用、用哪个频段。
- `preferred_egress`：优先出口。
- `original_channel_radio0` / `original_channel_radio1`：启用前该频段的信道，停用或换频段时恢复。旧版的 `original_channel` 只记 5 GHz，第一次保存时自动改名。
- `target_channel`：当前跟随的信道。

保存流程的实现要点：

- 后端 `save` / `disable` 立即返回，真正的工作在 `setsid` 起的独立进程里跑，进度写在 `/tmp/r3mini-hotspot-job.json`。所以不受 rpcd 30 秒执行上限的限制：rpcd 用 `-t 30` 启动，超时直接 SIGKILL，清理代码不会执行，2026-11-25 已在设备上实测。
- 密码由页面写进 `/tmp/r3mini-hotspot-key-<16 位十六进制>`（0600），后端校验路径、不是符号链接后挪走，用完即删；密码不出现在命令行参数里。
- 锁文件里记 PID，持有进程死了下次自动回收；旧版留下的 `mkdir` 目录锁也会被清掉。
- 写配置或重配失败时，恢复 network、wireless、firewall、r3mini_hotspot 四份配置并重配受影响的频段，任务报「…；已恢复保存前的设置」。
- 防火墙只在第一次把 `wwan` 加进 wan 区时重载。

## 部署、测试、回滚

在仓库根目录执行（密钥登录，主机密钥必须已在 `~/.ssh/known_hosts`）：

```powershell
python fan-dashboard/test_hotspot_backend.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
python fan-dashboard/test_hotspot_page.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242 --candidate
python fan-dashboard/deploy_hotspot.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
python fan-dashboard/test_hotspot_page.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
```

- `test_hotspot_backend.py`：在设备 `/tmp` 沙箱里用假配置和桩命令跑后端与看门狗，不碰真实配置、无线和路由。2026-11-25 结果 `RESULT pass=101 fail=0`。
- `test_hotspot_page.py`：在设备真实 LuCI 页面上走查。
  - 加 `--candidate` 时，把本地页面换进浏览器，状态和搜索用本地后端在设备上只读执行。
  - 保存、停用、切换出口、蜂窝开关、写密码文件都在浏览器里拦下，不到设备。
  - 覆盖刷新节奏、表单规则、搜索、保存流程、恶意 SSID、320–1440 宽度、暗色、字号不小于 12 px。
  - 2026-11-25 候选版和部署后都是 51 项 `PAGE_OK`。
- `deploy_hotspot.py`：先把要覆盖的文件备份到设备 `/root/r3mini-hotspot-backup-<时间>/`，装完逐个核对 SHA-256，不一致自动回滚。
  - ACL 有变化才重启 rpcd，已登录的 LuCI 要重新登录；不重启 uhttpd。
  - 成功输出 `BACKUP=…`、`DEPLOY_SHA256_OK=7/7`、`PRESERVED_CONFIG_OK=1`。

回滚到上一版页面（2026-11-25 部署前那份）：

```powershell
python fan-dashboard/deploy_hotspot.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242 --rollback /root/r3mini-hotspot-backup-20261125154841
```

回滚只换回程序文件，不动 `/etc/config/r3mini_hotspot`。用新版保存过 Wi-Fi 上网之后再回滚，旧版不认识 `original_channel_radio0/1`，停用时不会恢复信道，需要手动 `uci set wireless.radioX.channel=<原信道>`。

## 2026-11-25 部署记录

- 部署前整机备份：`backups/router/router-backup-20261125-154829-100143-192.168.0.242-before-chatgpt.tar.gz.dpapi`。
  - 由 `python chatgpt-routing/manage.py backup 192.168.0.242 --key …` 生成，文件名后缀是该工具固定的。
  - 1192 条，含整个 `/etc` 与全部 r3mini 程序和页面。
- 设备端文件备份：`/root/r3mini-hotspot-backup-20261125154841`（7 个文件）。
- 部署后：
  - 看门狗 running，`S95r3mini-hotspot` 在。
  - 默认路由仍是 `eth1` metric 5，OpenClash running。
  - `status` 用时 59 ms；旧版是 150–160 ms，而且旧页面从不自动刷新。
- 5G 刷屏的处置（用户 11-25 同意）：
  - 原因：模块里没插 SIM 卡（`AT+CPIN?` 回 `+CME ERROR: 10`，`+CFUN: 0`；ModemManager 报 `failed / sim-missing`）。quectel-cm 开射频失败（`mbim_set_radio_state … Status=2`）就退出，netifd 立刻重拉，7 秒内 38 次，128 KB 日志只能留 7 秒。
  - 处置：`r3mini-hotspot-web cellular off` 让 `network.RM500CNV.auto=0` 并 `ifdown`；ModemManager 执行 `stop` + `disable`（没有接口用 modemmanager 协议，它与 quectel-cm 重复占着同一个模块）。
  - 结果：日志 10 秒不增一行，负载从约 1.6 降到 0.66。
  - 插卡后：在页面点「恢复拨号」。要恢复 ModemManager，执行 `/etc/init.d/modemmanager enable && /etc/init.d/modemmanager start`。

未在真机验证（会断 Wi-Fi，需要用户在场同意）：

- 实际连接一个 Wi-Fi；
- 2.4/5 GHz 互换；
- 停用后恢复信道；
- 看门狗在真机上跟随信道；
- 有 SIM 卡时恢复拨号。

## 失败处置

后端出错时把下面原文写到 stderr、退出码 1，页面原样显示；后台任务的失败写在任务消息里。

| 原文（error_kind） | 原因与处置 |
|---|---|
| `已有 Wi-Fi 设置任务在执行，请等它结束` | 另一个保存/停用任务还在跑；等页面显示完成或失败。任务进程已死的话，锁会自动回收 |
| `另一项出口或 Wi-Fi 设置正在执行，请稍后再试` | 写锁 20 秒内没拿到（切换出口、蜂窝开关、看门狗跟信道）；稍后重试 |
| `没搜到「X」；请确认它开着、在这个频段，并靠近路由器` | 对方没开、频段选错，或是隐藏网络；换频段或靠近后重试 |
| `「X」在信道 N，本机 Wi-Fi 不能跟过去（5 GHz 只支持 36–48、149–161）` | 让手机热点改用 2.4 GHz 或换信道，或改用 2.4 GHz 频段 |
| `这个 Wi-Fi 用企业认证（802.1X），不支持` / `这个 Wi-Fi 用 WEP 或未知加密，不支持` | 不支持，换网络 |
| `请输入这个 Wi-Fi 的密码` / `密码必须是 8–63 个字符` | 换了网络必须输入密码 |
| `重新配置 radioX 失败；已恢复保存前的设置` 等「…；已恢复保存前的设置」 | 配置已自动还原；到「网络 → 无线」看该频段是否正常，再重试 |
| `已保存，但 45 秒内没连上「X」…` | 设置已生效但没连上：密码不对、信号弱或对方不分配地址；看门狗每 20 秒重试 |
| `任务进程意外退出；请检查 Wi-Fi 设置后重试` | 后台任务被杀（例如路由器重启）；配置可能停在中途，到「网络 → 无线」核对 STA 和信道后重新保存 |
| `5G 模块里没检测到 SIM 卡；插好卡后再启用` | 「恢复拨号」时查到没卡；插卡后重试 |
| `切换后默认路由不对；已恢复原来的出口` | 目标出口的默认路由没生效；查 `ip -4 route show default` 与 `ifstatus <接口>` |
| 部署：`PINNED_HOST_KEY_MISSING`、`SSH_KEY_LOGIN_FAILED`、`SHA256_MISMATCH=<文件>`（已自动回滚）、`ROLLBACK_BACKUP_INVALID` | 依次是：主机密钥没固定、密钥登不上、装上的文件与本地不一致、回滚目录不对 |

保存后该频段本机 Wi-Fi 一直不出现时，停止继续写入。从有线 LAN 进页面停用 Wi-Fi 上网；页面打不开就 SSH 执行 `/usr/sbin/r3mini-hotspot-web disable`，它会恢复原信道并重配。
