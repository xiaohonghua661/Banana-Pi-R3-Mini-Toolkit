# 5GHz 手机热点 STA 与 AP 共存配置与验收

更新时间：2026-07-24 +08:00。

## 当前结论

BPI-R3 Mini 的 `radio1` 支持 AP 与 managed/STA 并发，但实机能力明确限制为 `#channels <= 1`。让手机热点和电脑都使用 5 GHz 时，手机热点 STA 与 `immortalwrt-5.0` AP 必须使用同一信道，并共享同一块射频的空口时间。

最后已知管理地址为 `192.168.0.242`。不得使用已撤销的 `192.168.110.1` 或复位地址 `192.168.1.1`。

设备已由用户带离现场。下文“已部署”只表示 2026-07-19 22:01 前的最后一次实机回读；当前不得连接、部署或把本地候选实现写成实机完成。

## 已部署组件

LuCI 路径：`网络 → 手机热点 WAN`。

部署器严格校验 6 个受管文件的 SHA-256，并保留设备现有 `/etc/config/r3mini_hotspot`：

```text
/usr/sbin/r3mini-hotspot-web
/usr/sbin/r3mini-hotspot-watchdog
/etc/init.d/r3mini-hotspot
/usr/share/luci/menu.d/luci-app-r3mini-hotspot.json
/usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json
/www/luci-static/resources/view/network/r3mini-hotspot.js
```

`r3mini-hotspot` 已启用开机启动并处于 `running`。页面区分“有线 WAN”“蜂窝网络 5G”“手机热点 Wi-Fi”，稳定状态每 250 ms 查询一次，出口切换期间每 100 ms 尝试查询一次；未完成的状态请求会被复用，不并发堆积。真机单次状态命令实测为 160–180 ms，因此前台页面的典型状态发现窗口约为 170–420 ms。该数字只表示页面反馈与查询速度，不承诺 Wi-Fi 认证、关联或 DHCP 在毫秒内完成。

页面提供“自动、有线 WAN、蜂窝 5G、手机热点”四个出口偏好按钮。离线出口不可选；自动模式按有线、蜂窝、热点设置不同 metric。切换时先把已知默认路由移到临时 metric，再应用最终 metric，避免两个出口抢占同一 metric；内核默认路由缺失时，从 netifd 的 `ifstatus` 路由数据重建。

## 本地候选实现（尚未部署）

本地工作区已把“自动”升级为“智能自动”，但尚未写入设备。候选部署器新增两个受管文件，因此部署后应校验 8 个受管文件：

```text
/usr/sbin/r3mini-egress-manager
/etc/hotplug.d/iface/95-r3mini-egress
```

智能自动固定使用从生产 OpenClash 只读解析出的同一个非 DIRECT 叶子节点。WAN、蜂窝和手机热点各自顺序启动一个全新的临时 Mihomo 核心，启动前把实际 L3 设备写入顶层 `interface-name`，并删除内联节点、provider override 和 provider 文件中的出口绑定。每个核心使用独立 `0700` home、provider 实体副本、controller secret 和带随机认证的 localhost mixed-port；生产 OpenClash controller 只接受 GET，不接受 PUT 或 PATCH。

每个出口均通过自己的 mixed-port 访问固定白名单 `https://claude.ai/` 与 `https://api.anthropic.com/`，以两个有效响应中较慢的首字节时间作为该出口的 Claude 业务分数；任一目标传输失败时，该出口本轮无有效分数。HTTP 2xx/3xx 及未带账号凭据时的 401/403 仅表示目标链路可达，不等价于账号、地区、风控或 Claude 会话可用。页面显示的是该业务探针分数，不再把 Google `generate_204` 延迟标成 Claude 延迟。

自动切换满足以下防抖条件：候选至少快 20 ms 且快 15%，连续确认 2 次，距上次切换至少 30 秒。默认每 10 秒测速；新出口 `ifup/ifupdate` 时通过常驻 manager 的合并唤醒队列提前开始一轮，不在 hotplug 中执行重活，也不绕过确认和最短保持时间。物理接口断开由 hotplug 立即进入故障转移；手动模式始终优先，仍显示延迟但不调用自动切换。自动择优只修改运行时默认路由，不提交 UCI；用户手动选择才持久化出口偏好。

候选页面使用原生 `setInterval(..., 250)` 查询，切换期间每 100 ms 发起一次刷新；同一时刻只保留一个状态 RPC。两次连续 RPC 失败后把总标题和三路出口标成“状态未知”，清除旧的绿色当前出口高亮并暂时禁用出口按钮；恢复响应后按新状态重建。`ERROR` 使用红色，`UNAVAILABLE/STALE` 使用黄色，热点断开时常驻显示“热点未连接，正在重连”。探针数据超过 `3 × 探测周期 + 5 秒` 时显示 `STALE / 已过期`，移动端出口按钮最小高度为 44 px。该刷新速度只表示检测反馈，不代表 Wi-Fi 认证、DHCP 或完整双目标测速能在毫秒内完成。

hotplug 在调用 manager 前读取 `/proc/uptime` 的毫秒起点。manager 完成事件协调后把 `started_ms`、`finished_ms`、`elapsed_ms`、动作和接口原子写入 `/tmp/r3mini-egress-event.json`，其中 `elapsed_ms = finished_ms - started_ms`；LuCI 常驻显示“最近链路事件：N ms · ifdown / wan”。该数字测量路由器内部收到 hotplug 到事件协调返回的时间；页面发现还会增加最多约 250 ms 的查询窗口，Wi-Fi 认证、DHCP 和完整双目标测速继续单独计时。

热点密码候选流程不再把密码放入 `fs.exec` 参数：页面写入随机命名的 `0600` 临时文件，路由器端校验路径和非符号链接后读取并立即删除。无线扫描中断时会恢复 `radio1`，扫描锁、出口锁和探针锁均记录 owner PID 并回收陈旧锁。

本地离线证据：

```text
STATIC_CONTRACTS=PASS
HYSTERESIS_SWITCH=PASS
SMALL_ADVANTAGE_HOLD=PASS
HARD_DOWN_FAILOVER=PASS
DEFAULT_AUTO_FAILOVER=PASS
ACTIVE_TARGET_REPLAY=PASS
NO_EGRESS_SAFE=PASS
MANUAL_PRIORITY=PASS
PROBE_FAILURE_HOLD=PASS
RUNTIME_DATA_ONLY=PASS
LOCK_RECOVERY_AND_CONTENTION=PASS
ATOMIC_LOCK_CLAIM=PASS
EVENT_LOCK_RETRY=PASS
EVENT_MILLISECOND_TIMING=PASS
PROBE_CLEANUP=PASS
MISSING_PROVIDER_FAIL_CLOSED=PASS
CLAUDE_ENDPOINT_POLICY=PASS
PROBE_WAKE_COALESCED=PASS
MIXED_PORT_OWNER_CHECK=PASS
STALE_DELAY_RENDER=PASS
RPC_FAILURE_STATE=PASS
DEPLOY_POSTCHECK_ROLLBACK=PASS
PASSWORD_UCI_STDIN_ONLY=PASS
VERIFY_CLI_GATES=PASS
AUTO_TIMEOUT_BUDGET=PASS
AUTO_VERIFY_POLICY=PASS
TIMING_EVENT_FORMULA=PASS
PROBE_PROOF_CONTRACT=PASS
WAN_FAILOVER_CONTRACT=PASS
SIGNAL_RESTORE_RETRY=PASS
TITLE_CONTRAST=PASS
ALL_ONLINE_MANUAL_CHOICES=PASS
MANUAL_SWITCH_FEEDBACK_MS=170
BURST_DISCONNECT_DISCOVERY_MS=125.9
SINGLE_INFLIGHT_RPC=PASS
DESKTOP_OVERFLOW=false
MOBILE_OVERFLOW=false
MOBILE_BUTTON_MIN_HEIGHT=44
CONSOLE_ERRORS=0
SHELL_SYNTAX=PASS
JS_SYNTAX=PASS
PYTHON_COMPILE=PASS
```

本机没有 Mike Farah `yq` v4 可执行文件，候选代码已拒绝非 v4 实现；每个临时核心也要求 `ss -lntp` 证明 controller 与 mixed-port 均由本轮 core PID 监听。manager 每轮把随机 `proof_id`、叶子节点名称的 SHA-256、各出口 core PID、实际 L3 设备和分数写入仅位于 `/tmp` 的脱敏证据文件，不保存节点名称；验收器要求状态与证据的 `proof_id` 一致、在线出口使用同一个 leaf SHA、PID 互不相同、设备匹配当前 netifd L3 设备且分数一致。生成临时 Clash 配置、关闭 provider health-check、清理节点绑定、端口所有权和上述脱敏证据仍必须在设备返回后用设备自带 yq/ss 与当前生成配置实测。以上离线结果不得替代真实三出口、OpenClash 不受扰动和物理断线恢复验收。

本地 Chromium 使用 LuCI 模拟 RPC 数据完成桌面与 390 px 手机宽度渲染。测试确认顶部“网络接力控制台”为深绿色且无白色遮罩，三出口同时在线时四个偏好按钮均可用，手动切换反馈为 170 ms，100 ms 突发查询发现断开为 125.9 ms，同一时刻最多一个状态 RPC；桌面和移动端均无横向溢出，移动按钮高度为 44 px，控制台错误为 0。该测试过程中发现并修复了根容器 `width:100%` 加内边距导致的 4 px 移动端溢出。以上是模拟状态下的前端反馈证据，不替代路由器 RPC、Wi-Fi 认证、DHCP 或物理链路端到端计时。

## 实机验收入口（候选，尚未在设备执行）

验收器复用部署器的固定 SSH 主机密钥与拒绝未知主机策略，只把校验脚本临时上传到 `/tmp`，结束后删除，不输出管理密码、controller secret 或节点名称。

先运行只读预检：

```powershell
python .\fan-dashboard\verify_egress.py 192.168.0.242 preflight
```

完成新的可恢复备份后，依次运行：

```powershell
python .\fan-dashboard\verify_egress.py 192.168.0.242 probe --allow-runtime-change
python .\fan-dashboard\verify_egress.py 192.168.0.242 manual wan --allow-config-change
python .\fan-dashboard\verify_egress.py 192.168.0.242 manual hotspot --allow-config-change
python .\fan-dashboard\verify_egress.py 192.168.0.242 manual cellular --allow-config-change
python .\fan-dashboard\verify_egress.py 192.168.0.242 auto --allow-config-change
python .\fan-dashboard\verify_egress.py 192.168.0.242 timing 10 ifdown
```

`preflight` 检查板型、root、yq v4、`ss -lntp`、硬链接锁、OpenClash 与热点服务。`probe` 唤醒一次隔离测速，要求每个在线出口都有业务分数，校验同 leaf SHA、不同 core PID、正确 L3 设备和状态/证据关联，同时对比生产 OpenClash 的 PID、配置摘要、provider 摘要和 GLOBAL 选择摘要；发现变化或临时核心残留即失败。`manual` 只接受在线目标，验证默认出口和持久化偏好后恢复原偏好；恢复仅在 UCI 回读确认后标记成功，首次失败会再试一次。`auto` 连续执行三轮受保护探针，验证当前出口等于最低延迟出口；只有优势不足 20 ms 或 15% 时允许按防抖策略保持，拒绝等待超过 300 秒的保持时间，主机端给该模式 900 秒预算。`manual/auto` 缺少 `--allow-config-change` 时拒绝执行。`timing 10 ifdown` 要求偏好为自动，等待十次接口名为 `wan` 的物理断开事件，逐次校验单调时钟公式和出口已切到在线后备链路，再输出 p50、p95、max；p95 超过 500 ms 或 max 超过 1000 ms 时失败。蜂窝设备不在线时跳过对应 manual 命令，不把跳过写成通过。

当前只验证了脚本语法、CLI 变更闸门和离线桩；未得到设备真实输出前，不得把 `PREFLIGHT=PASS`、`PROBE_VERIFY=PASS`、`MANUAL_VERIFY=PASS`、`AUTO_VERIFY=PASS` 或 `TIMING_VERIFY=PASS` 写成实机结论。

## 配置流程

1. 打开手机的 5 GHz 热点，并把手机放在路由器附近。
2. 打开 LuCI 的“网络 → 手机热点 WAN”。
3. 开启“启用手机热点 WAN”。
4. 在页面输入热点名称和密码；密码只写入路由器，不在聊天、日志或文档中记录。
5. 点击“保存并应用”。页面先扫描热点；扫描不到时拒绝写入配置。
6. 扫描成功后，把 `radio1` 固定到热点实际信道，创建 `r3mini_phone_sta` 和 DHCP 客户端接口 `wwan`，再重配 5 GHz。

停用时禁用 STA，并恢复启用前保存的 5 GHz AP 信道。

## 自动重连

按以下策略处理掉线：

```text
每 20 秒检查一次
连续 3 次失败：执行 ifup wwan
连续 3 轮重连仍失败：重新扫描手机热点并重配 radio1
热点信道变化：同步修改 radio1 信道后重配
完整重配冷却：180 秒
```

错误密码或手机热点没有分配 DHCP 时，`wwan` 不会上线；控制器保留配置供页面修正，watchdog 按上述间隔重试，不高频重载无线。

## 已验证证据

实机能力回读：

```text
#{ AP, mesh point } <= 16, #{ managed } <= 19
#channels <= 1
STA/AP BI must match
```

部署后回读：

```text
DEPLOY_SHA256_OK=6/6
PRESERVED_CONFIG_OK=1
r3mini-hotspot=running
5GHz AP type=AP
5GHz AP channel=157, width=80 MHz
OpenClash=running
dnsmasq=running
r3mini-fan=running
r3mini_fan.main.high_up=40000
```

页面黑盒：

```text
当前偏好：自动
当前出口：有线 WAN
有线 WAN：在线并作为默认出口
手机热点：在线待命
蜂窝 5G：未连接且按钮置灰
5GHz 信道：157
Argon 页面内容区：1120 px，display=block
顶部标题：深绿色 `rgb(14, 73, 56)`，无文字阴影；Argon 注入的 `header::after` 装饰条已禁用
稳定刷新：250 ms
切换刷新：100 ms
启用开关后 SSID/密码输入框可用
首次配置缺少 SSID/密码时“保存并应用”不可用
```

手动出口实机切换：

```text
hotspot → 默认路由 phy1-sta0，preferred=hotspot，wwan_up=true
wan     → 默认路由 eth1，preferred=wan，wired_wan_up=true
auto    → 默认路由 eth1，preferred=auto，wired_wan_up=true，wwan_up=true
默认路由条目数：2
```

页面点击在本地 Node 黑盒中的同步反馈耗时为 0.110 ms；170 ms 与 400 ms 慢请求注入下，状态请求最大并发均为 1，连接、断开与出口变化提示均通过。浏览器点击返回时间包含 LuCI RPC 和自动化等待，不作为“同步反馈耗时”证据。

失败保护黑盒：使用一个确认不可见的测试 SSID 调用保存，返回非零；`network`、`wireless`、`firewall`、`r3mini_hotspot` 四份配置摘要前后一致。

扫描解析黑盒：从一次真实 5 GHz 扫描中选取一条可见结果，再用与控制器相同的 JSON 遍历逻辑回查，得到：

```text
SCAN_MATCH_OK channel=40
```

## 当前待验收

手机热点 STA 已关联、`wwan` 已取得 IPv4，STA 与 AP 均在 5 GHz 信道 157；手动切换手机热点、有线 WAN、自动三种偏好已通过。以下四项仍需现场完成：

1. 物理拔掉有线 WAN 后，默认路由和页面当前出口自动切换到 `wwan` / 手机热点 Wi-Fi。
2. 电脑连接本地 5 GHz AP 后取得软路由 DHCP 地址，并持续通过当前选定出口访问互联网。
3. 新建连接能在 OpenClash 中看到，公网出口与 DNS 泄漏结果符合目标。
4. 关闭再打开手机热点后，watchdog 能自动恢复；如手机换信道，本地 AP 跟随新信道后仍可见。

以上四项及智能自动候选的部署验收未取得真实输出前，不得宣称客户端端到端、智能择优和物理断线自动恢复全部完成。

设备返回后按顺序执行：通过可信物理链路核验并固定 SSH 主机密钥；只读核验身份与最后已知基线；获取设备写锁；制作新的可恢复备份；验证设备自带 Mike Farah `yq` v4，并用当前生成配置实跑临时配置转换；部署前记录生产 OpenClash PID、controller、配置摘要和现有连接；部署候选并校验 8 个受管文件；对比确认生产 OpenClash 的上述四项未变化；再测试 WAN 与手机热点的真实延迟、自动选择、手动优先和物理拔线恢复；有蜂窝设备时补测第三出口；最后制作新的 DPAPI 恢复点。部署器会拒绝未固定或不匹配的主机密钥，不再向未知 SSH 主机尝试管理密码。

物理拔线恢复从内核首次报告 WAN `carrier=0` 或收到对应 `ifdown` hotplug 的单调时钟时间开始，到默认路由指向已在线后备出口且 `r3mini-hotspot-web status` 的 `egress_kind` 与之相同为止。WAN 与热点预先同时在线，连续执行至少 10 次，记录每次毫秒值并报告 p50、p95、max；候选目标为 p95 不超过 500 ms、max 不超过 1000 ms。该口径不包含手机热点首次认证和 DHCP，后者单独记录关联及取址耗时。

## 备份与失败处置

本轮写入前 scoped 备份：

```text
D:\Banana_Pi_r3mini\backups\router\router-backup-20260719-191632-before-5g-sta-ap.tar.gz
SHA-256: 01d250363c0e88157a4f18ae3ea3a119772594052ba3614f1811fae32e9925a8
```

稳定完整恢复点仍为：

```text
D:\Banana_Pi_r3mini\backups\router-20260719-175110-stable-current
```

UI、手动出口、毫秒级状态反馈和顶部标题修复完成后的最新本机恢复点为 DPAPI 加密归档：

```text
D:\Banana_Pi_r3mini\backups\router\router-backup-20260719-220116-hotspot-ui-title-final.tar.gz.dpapi
明文 SHA-256: 6E1015792C3E5D6EE1712336CD02BF305472C5A97A2B866FC52540F6E0A64836
加密文件 SHA-256: 7F928D2664FFBEFA4308076C9927F3604FBEC19C9BE02461FB08B62D1A40D701
```

该归档已验证 6 个热点受管文件齐全，DPAPI 解密往返摘要一致；明文归档已删除。它只能由创建归档的 Windows 用户上下文解密，不替代镜像级稳定恢复点。

该归档不包含本节“本地候选实现”。候选尚未部署，因此当前不创建新的路由器备份，也不得把 `router-backup-20260719-220116-hotspot-ui-title-final.tar.gz.dpapi` 标成智能自动版本。

如果应用后 5 GHz AP 不可见，立即停止继续写入；先通过 LAN 检查 STA 与 AP 的实际信道是否相同，再停用手机热点 WAN 恢复原信道。仍无法恢复时，使用本轮 scoped 配置备份或已验证稳定恢复点回滚，不在失联状态继续猜测端口、地址或信道。
