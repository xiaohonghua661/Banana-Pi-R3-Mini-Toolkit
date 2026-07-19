# 5GHz 手机热点 STA 与 AP 共存配置与验收

更新时间：2026-07-19 22:01 +08:00。

## 当前结论

BPI-R3 Mini 的 `radio1` 支持 AP 与 managed/STA 并发，但实机能力明确限制为 `#channels <= 1`。让手机热点和电脑都使用 5 GHz 时，手机热点 STA 与 `immortalwrt-5.0` AP 必须使用同一信道，并共享同一块射频的空口时间。

当前管理地址为 `192.168.0.242`。不得使用已撤销的 `192.168.110.1` 或复位地址 `192.168.1.1`。

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

以上四项未取得真实输出前，不得宣称客户端端到端和物理断线自动恢复全部完成。

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

如果应用后 5 GHz AP 不可见，立即停止继续写入；先通过 LAN 检查 STA 与 AP 的实际信道是否相同，再停用手机热点 WAN 恢复原信道。仍无法恢复时，使用本轮 scoped 配置备份或已验证稳定恢复点回滚，不在失联状态继续猜测端口、地址或信道。
