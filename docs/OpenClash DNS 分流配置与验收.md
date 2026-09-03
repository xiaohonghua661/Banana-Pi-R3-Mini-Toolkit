# OpenClash DNS 分流配置与验收

> 当前状态（2026-07-19 20:28 +08:00）：管理地址为 `192.168.0.242`，dnsmasq 与 OpenClash 正在运行。该时刻 `eth1 carrier=1`，存在经 `192.168.0.254` 的默认路由；后续热点任务可能切换默认出口，因此每次验收先 fresh 回读当前路由，不把某一出口写成永久事实。本文只记录 DNS 证据，不授权修改或重启 `network`、`wireless`、`r3mini_hotspot`、OpenClash。

## 目标与边界

- 将中国域名交给国内 DNS，将未命中中国规则的域名交给国外 DNS。
- 将国外 DNS 绑定到 `MESL` 策略组，不把本地 WAN 直连设为国外 DNS 的预期路径。
- 保留国内启动解析，降低代理节点域名和 DoH 上游域名形成启动循环的风险。
- 不修改系统时区、WAN 全局 DNS、订阅、节点凭据或业务 VPN。
- 禁止在项目文档中记录订阅链接、认证信息、完整公网出口 IP 或带认证信息的终端 URL。

## 目标配置

OpenClash 重启后的实际运行 YAML 必须包含下表字段。以运行 YAML 为验收真相源，不以 LuCI 表单或尚未提交的 UCI 暂存值代替。

| YAML 字段 | 值 | 用途 |
|---|---|---|
| `default-nameserver` | `223.5.5.5`、`119.29.29.29` | 直连启动解析 |
| `proxy-server-nameserver` | `223.5.5.5`、`119.29.29.29` | 解析代理节点域名，避免启动循环 |
| `nameserver` | `https://1.1.1.1/dns-query#MESL` | 未命中策略的默认国外 DoH |
| `fallback` | `https://1.0.0.1/dns-query#MESL` | 仅使用经 `MESL` 连接的国外备用 DoH |
| `nameserver-policy.geosite:cn` | `https://doh.pub/dns-query`、`https://dns.alidns.com/dns-query` | 中国域名使用国内 DoH |

运行配置中必须存在名为 `MESL` 的策略组，否则 `#MESL` 引用不能成立。

持久 UCI 使用 4 个命名 `dns_servers` section：

| UCI section | `group` | 地址 | `node_resolve` | `specific_group` |
|---|---|---|---:|---|
| `dns_cf` | `nameserver` | `1.1.1.1/dns-query` | `0` | `MESL` |
| `dns_cf_fb` | `fallback` | `1.0.0.1/dns-query` | `0` | `MESL` |
| `dns_ali` | `default` | `223.5.5.5` | `1` | 无 |
| `dns_tx` | `default` | `119.29.29.29` | `1` | 无 |

以上 section 均设置 `enabled=1` 和 `interface=Disable`。其余旧 `dns_servers` section 保持 `enabled=0`。UCI 的 HTTPS 地址只填写主机/IP 与路径，并用 `type=https` 声明协议；OpenClash 生成运行 YAML 时补出 `https://` 前缀。

主开关使用 `enable_custom_dns=1`、`append_wan_dns=0`、`append_default_dns=0`、`enable_respect_rules=0`、`custom_fallback_filter=0`、`custom_name_policy=1`。

Nameserver Policy 正文保存在：

```text
/etc/openclash/custom/openclash_custom_domain_dns_policy.list
```

文件内容为：

```yaml
"geosite:cn": [https://doh.pub/dns-query, https://dns.alidns.com/dns-query]
```

## 验收流程

### 1. 回读持久配置

执行：

```sh
expect_uci() {
  section=$1
  shift
  section_type=$(uci -q get "openclash.$section")
  [ "$section_type" = dns_servers ] || {
    echo "uci_type_mismatch:$section expected=dns_servers actual=$section_type" >&2
    exit 1
  }
  while [ "$#" -gt 0 ]; do
    option=$1
    expected=$2
    shift 2
    actual=$(uci -q get "openclash.$section.$option")
    [ "$actual" = "$expected" ] || {
      echo "uci_mismatch:$section.$option expected=$expected actual=$actual" >&2
      exit 1
    }
  done
}

expect_absent() {
  section=$1
  option=$2
  if uci -q get "openclash.$section.$option" >/dev/null; then
    echo "uci_unexpected_option:$section.$option" >&2
    exit 1
  fi
}

expect_config() {
  option=$1
  expected=$2
  actual=$(uci -q get "openclash.config.$option")
  [ "$actual" = "$expected" ] || {
    echo "config_mismatch:$option expected=$expected actual=$actual" >&2
    exit 1
  }
}

expect_uci dns_cf enabled 1 group nameserver type https \
  ip 1.1.1.1/dns-query interface Disable node_resolve 0 specific_group MESL
expect_uci dns_cf_fb enabled 1 group fallback type https \
  ip 1.0.0.1/dns-query interface Disable node_resolve 0 specific_group MESL
expect_uci dns_ali enabled 1 group default type udp \
  ip 223.5.5.5 interface Disable node_resolve 1
expect_uci dns_tx enabled 1 group default type udp \
  ip 119.29.29.29 interface Disable node_resolve 1
expect_absent dns_ali specific_group
expect_absent dns_tx specific_group

expect_config enable_custom_dns 1
expect_config append_wan_dns 0
expect_config append_default_dns 0
expect_config enable_respect_rules 0
expect_config custom_fallback_filter 0
expect_config custom_name_policy 1

policy_file=/etc/openclash/custom/openclash_custom_domain_dns_policy.list
[ -r "$policy_file" ] || { echo "policy_unreadable:$policy_file" >&2; exit 1; }
expected_policy='"geosite:cn": [https://doh.pub/dns-query, https://dns.alidns.com/dns-query]'
actual_policy=$(sed '/^[[:space:]]*$/d' "$policy_file")
[ "$actual_policy" = "$expected_policy" ] || {
  echo 'policy_mismatch' >&2
  exit 1
}

for s in dns_cf dns_cf_fb dns_ali dns_tx; do
  uci show "openclash.$s"
done

count=0
for s in $(uci show openclash | sed -n \
  's/^openclash\.\([^=]*\)=dns_servers$/\1/p'); do
  if [ "$(uci -q get "openclash.$s.enabled")" = 1 ]; then
    echo "$s group=$(uci -q get "openclash.$s.group") ip=$(uci -q get "openclash.$s.ip")"
    count=$((count + 1))
  fi
done
echo "COUNT=$count"
[ "$count" -eq 4 ] || exit 1
echo 'UCI_DNS_OK'
```

成功输出必须同时包含 `COUNT=4` 和 `UCI_DNS_OK`。`COUNT=4` 只证明启用数量；其余断言验证 section 类型、字段值、国内 section 不含 `specific_group`、6 个主开关及 Policy 文件正文。出现 `uci_type_mismatch`、`uci_mismatch`、`uci_unexpected_option`、`config_mismatch`、`policy_unreadable` 或 `policy_mismatch` 时停止提交。

### 2. 重启并定位实际运行 YAML

执行：

```sh
uci commit openclash
/etc/init.d/openclash restart
status=$(/etc/init.d/openclash status)
[ "$status" = running ] || { echo "openclash_not_running:$status" >&2; exit 1; }

raw=$(uci -q get openclash.@overwrite[0].config_path || \
      uci -q get openclash.config.config_path)
[ -n "$raw" ] || { echo 'config_path_missing' >&2; exit 1; }
run="/etc/openclash/$(basename "$raw")"
[ -r "$run" ] || { echo "run_yaml_unreadable:$run" >&2; exit 1; }

ruby -ryaml - "$run" <<'RUBY'
config = YAML.load_file(ARGV.fetch(0))
dns = config.fetch('dns')
expected = {
  'default-nameserver' => ['223.5.5.5', '119.29.29.29'],
  'nameserver' => ['https://1.1.1.1/dns-query#MESL'],
  'proxy-server-nameserver' => ['223.5.5.5', '119.29.29.29'],
  'fallback' => ['https://1.0.0.1/dns-query#MESL']
}
expected.each do |key, value|
  abort("runtime_mismatch:#{key}") unless dns[key] == value
end
policy = dns.fetch('nameserver-policy')
cn_policy = ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query']
abort('runtime_mismatch:nameserver-policy.geosite:cn') unless policy['geosite:cn'] == cn_policy
groups = config.fetch('proxy-groups')
abort('mesl_group_missing') unless groups.any? { |group| group['name'] == 'MESL' }
puts 'RUNTIME_DNS_OK'
RUBY
```

仅在状态为 `running` 且 Ruby 校验输出 `RUNTIME_DNS_OK` 后继续。命令输出 `openclash_not_running`、`config_path_missing`、`run_yaml_unreadable:<path>`、`runtime_mismatch:<key>` 或 `mesl_group_missing` 时停止验收，先修复运行配置；不得退回只检查原始订阅 YAML。

### 3. 清理客户端 DNS 缓存

Windows 客户端执行：

```powershell
ipconfig /flushdns
```

同时关闭或核对浏览器“安全 DNS”、应用自带 DoH 和 IPv6 DNS，防止客户端绕过路由器 DNS。

### 4. 验证国外出口与 DNS

打开：

```text
https://ip.net.coffee/claude/
https://ip.net.coffee/dns/
```

确认：

- Claude 出口仍位于美国。
- Claude 检测页不再显示中国移动 DNS 出口。
- DNS 快速测试不再发现中国 DNS 解析器。
- WebRTC UDP 不暴露国内真实出口。

### 5. 验证国内访问

打开至少两个中国域名，例如百度和腾讯首页。确认页面正常加载，再按需比较修改前后的 RTT、TTFB 和 CDN 地址；仅凭“能打开”不能证明长期网络质量不变。

## 2026-07-18 验收记录

当次从实际运行 YAML 提取的原始字段为：

```text
SERVICE
running
17:  default-nameserver:
18-    - 223.5.5.5
19-    - 119.29.29.29
20-  nameserver:
21-    - https://1.1.1.1/dns-query#MESL
113:  proxy-server-nameserver:
114-    - 223.5.5.5
115-    - 119.29.29.29
116-  nameserver-policy:
117-    geosite:cn:
118-      - https://doh.pub/dns-query
119-      - https://dns.alidns.com/dns-query
120-  fallback:
121-    - https://1.0.0.1/dns-query#MESL
2005:- name: MESL
```

- Net.Coffee 显示 Claude 出口位于美国，出口 IP 仅记为 `99.144.*.*`；原中国移动 DNS 出口不再出现。
- Claude 页显示“DNS 加密或未暴露出口”；DNS 快速测试为 `0` 个解析器，并提示可能已使用 DoH/DoT。
- WebRTC UDP 未检测到泄露，UDP 出口位于美国。
- 百度和腾讯首页均正常加载。本次只完成可用性冒烟测试，长期吞吐、RTT、TTFB、CDN 与抓包对比列为后续增强项，不作为本次通过条件。

## 2026-07-19 RST 恢复复验

- `luci-app-openclash` 已恢复为 0.47.133，服务状态为 `running`。官方 IPK 为 `luci-app-openclash_0.47.133_all.ipk`，大小 `9,173,397` 字节，SHA-256 为 `c2490630043ea7e3db91a8f0d079088bc39c6aab4dc283d292f302064f891b90`；本地摘要与 GitHub Release 资产摘要一致。
- 持久 UCI 的 4 个命名 `dns_servers` section、6 个主开关、Policy 正文和启用数量检查输出 `UCI_DNS_OK`。
- 从 OpenClash 当前实际运行 YAML 校验 `default-nameserver`、`nameserver`、`proxy-server-nameserver`、`fallback`、`geosite:cn` 和 `MESL` 组，输出 `RUNTIME_DNS_OK`。
- OpenClash 重启后 dnsmasq 曾处于 inactive；未修改 DHCP/network UCI，只启动 dnsmasq 后恢复 53 端口监听和本机 DNS 查询。复现脚本已增加 `DNSMASQ_OK` 与 `PROTECTED_HASHES_OK`，但这些 marker 是当次恢复证据，不自动代表后续每一时刻仍通过。
- [`scripts/router/restore-openclash-dns.sh`](../scripts/router/restore-openclash-dns.sh) 是当次恢复脚本：会先备份 OpenClash 并保护 network/wireless/hotspot 哈希，但失败时不会自动恢复已提交的 OpenClash。当前没有再次部署授权；需要再次部署时，先做路由器外部备份并使用带失败回滚的 `restore-stable-baseline.sh`。
- 本轮没有修改订阅、节点、WAN DNS、时区或业务 VPN。

## 2026-07-19 RST 后恢复记录

用户按下 RST 后，路由器从 `G:\Downloads\backup-immortalwrt-2026-07-18.tar.gz` 对应的旧状态重新开始；该备份时间为 2026-07-18 18:09:27。备份包内的 OpenClash UCI 仍是旧 DNS 状态：`enable_custom_dns=0`，`custom_name_policy=0`，policy 文件仍为注释示例。因此恢复时必须重新回读当前路由器，而不是假设备份包已经包含 2026-07-18 晚间的最终 DNS 分流。

2026-07-19 现场复核结果：

```text
OpenClash: running
Nikki: inactive
UCI_DNS_OK
RUNTIME_DNS_OK
```

当前 OpenClash 运行文件 `/etc/openclash/MESL_家宽.yaml` 已包含目标 DNS 分流：

```text
default-nameserver: 223.5.5.5, 119.29.29.29
nameserver: https://1.1.1.1/dns-query#MESL
proxy-server-nameserver: 223.5.5.5, 119.29.29.29
nameserver-policy.geosite:cn: https://doh.pub/dns-query, https://dns.alidns.com/dns-query
fallback: https://1.0.0.1/dns-query#MESL
```

恢复期间曾临时启用 Nikki 进行排查，确认 OpenClash 正常后已停止并禁用 Nikki，避免 Nikki 与 OpenClash 同时抢透明代理和 DNS 端口。Nikki 配置备份留在路由器本地：`/etc/config/nikki.bak.20260719-125832`；禁用前备份为 `/etc/config/nikki.pre-disable.20260719-*`。

联网冒烟结果：路由器侧 `curl` 打开百度返回 `200`，Net.Coffee Claude 页和 DNS 页均返回 `200`；腾讯首页对命令行请求返回 `501`，该结果只记录为 curl 兼容性现象，不作为浏览器访问失败结论。

## 2026-07-19 客户端路径：历史结果与当前差异

### 已验证但不能替代端到端黑盒的证据

- 当次 OpenClash UCI、Policy 和实际运行 YAML 通过 `UCI_DNS_OK` 与 `RUNTIME_DNS_OK`。
- 当次运行规则包含中国域名/IP 直连，最终规则为 `MATCH,Final`；`Final` 选择 `MESL` 且可递归到 `MESL`，`MESL` 当时选择美国节点。路由器内部经 Clash 认证代理请求 Claude trace 时国家代码为 `US`。
- 当次对 `192.168.0.242:53` 发起两次唯一域名查询后，Net.Coffee 返回 `0` 个可见递归解析器，其中中国解析器为 `0`。该结果只能证明那次指定 DNS 路径未被页面观察到中国递归出口，不能替代客户端默认网关、浏览器 DoH、IPv6 和 WebRTC 的联合验收。
- 同期使用浏览器 User-Agent 请求百度和腾讯首页均返回 `200`；这是历史可用性冒烟，不代表当前客户端样本的国内访问已通过。
- 该次只读复验没有提交或重启 OpenClash，也没有修改 Nikki、系统时区、WAN DNS、订阅或节点凭据；风扇仅做只读保护检查，`r3mini_fan.high_up=40000`。

### 已判废的旧客户端结果

旧测试电脑当时使用 `192.168.0.254` 作为默认网关和 DNS，浏览器流量绕过 BPI。用户刷新并等待 Net.Coffee Claude 页完整加载后提供截图，fresh 无上下文黑盒验收员仅依据该截图判定：

| 历史项目 | 当次观察 | 判定边界 |
|---|---|---|
| 客户端网络 | IPv4 `192.168.0.253`；网关/DNS `192.168.0.254` | 绕过 BPI |
| Claude 出口 | 韩国 `South Korea / Mapo-gu / SK Broadband` | FAIL：不是美国 |
| DNS | 截图标记“中国 DNS”、`China Mobile`；同期直连测试还观察到中国电信解析器 | FAIL：存在中国解析器 |
| WebRTC | “WebRTC 已禁用或无泄漏” | PASS |
| 时区 | 本地 `Asia/Shanghai (UTC+8)`；出口 `Asia/Seoul (UTC+9)` | 仅历史观察，不计入路由器 DNS 通过条件 |

该路径总体为 `REJECT`；它证明客户端没有经过软路由，不证明 OpenClash DNS 配置本身失败。截图中的完整公网 IP 未写入文档。文档中曾出现的 `192.168.101.x/192.168.101.1` 是过期候选，禁止继续使用。

### 当前网络状态边界

2026-07-19 20:28 的 fresh 只读回读为：

```text
管理地址: 192.168.0.242
br-lan: eth0
WAN: eth1
eth0: carrier=1
eth1: carrier=1
default route: via 192.168.0.254 dev eth1
dnsmasq: running
OpenClash: running
Nikki: inactive
```

后续 5 GHz 热点任务可能让 `wwan` 成为默认出口。DNS 验收只要求当次存在可用默认路由，并以 `ip route`、Mihomo debug 和客户端网络详情为真相源；不要继续引用早期“eth1 无链路、无默认路由”的阻塞结论，也不要把 `eth1` 或 `wwan` 写成永久默认出口。

只读验收使用 `UCI_DNS_OK`、`RUNTIME_DNS_OK`、dnsmasq 状态、53 端口监听和实际查询结果。`PROTECTED_HASHES_OK` 只用于确有写入时证明冻结配置未变化，不能冒充只读验收 marker。

### Net.Coffee 的 DNS 判定算法

页面在浏览器中生成随机 token，并连续请求两次：

```text
https://<token>-1.d.ip.net.coffee/pixel.gif
https://<token>-2.d.ip.net.coffee/pixel.gif
```

随后页面读取 `/api/dns/result/<token>` 返回的递归解析器地址。只要 Claude 出口不在中国、任一解析器的 `country_code=cn`，页面就显示“可能泄露/中国 DNS”；它不判断该解析器是否由国内域名策略产生，也不证明某个应走国外 DNS 的查询实际走了中国 DNS。因此，单看黄色提示不能判定路由器分流失败，必须把同一 token 与 Mihomo debug 对齐。

### 路由器侧实时证据

dnsmasq 没有混入 WAN DNS：

```text
no-resolv
server=127.0.0.1#7874
append_wan_dns=0
append_default_dns=0
```

国内随机子域名 `dnsprobe-1784464469.baidu.com` 的实时日志为：

```text
[DNS] resolve ... from https://dns.alidns.com:443/dns-query
[DNS] resolve ... from https://doh.pub:443/dns-query
```

对 Net.Coffee 完全同类的 `codex-1784465302.d.ip.net.coffee`，实时日志为：

```text
[DNS] resolve ... from https://1.0.0.1:443/dns-query
[DNS] resolve ... from https://1.1.1.1:443/dns-query
[TCP] mihomo -> 1.0.0.1:443 using MESL[美国住宅节点]
[TCP] mihomo -> 1.1.1.1:443 using MESL[美国住宅节点]
[TCP] ... -> codex-1784465302.d.ip.net.coffee:443 using Final[美国住宅节点]
```

这组同域合成探针证明：路由器会把 `d.ip.net.coffee` 国外探测域交给 Cloudflare DoH，并通过 `MESL` 出站。路由器配置与机制判定为 `PASS`；页面当次随机 token 仍需按下文逐条与 Mihomo debug 对齐，不能用合成探针替代客户端端到端证据。

### 有线 PC 与移动端差异

| 客户端 | 当次可见结果 | 判定 |
|---|---|---|
| 有线 PC / Edge | DNS“加密或未暴露出口”；Claude 与 WebRTC 为美国；Cloudflare 卡片获取失败 | 该样本未观察到 DNS 出口；不把 Cloudflare 卡片失败当 DNS 泄漏 |
| 移动端 | 系统“私人 DNS”已关闭；Claude、Cloudflare、WebRTC 为美国；DNS 先后显示中国移动与中国联通 | 代理路径正常，但 DNS/网络路径存在旁路嫌疑且尚未闭环，也可能是结果聚合误报；判定 `PARTIAL` |

BPI 当次 DHCP 租约表为空，不能证明移动端从 BPI 获得了地址、网关和 DNS；客户端也可能使用静态地址或从上游 DHCP 获址。OpenClash 的 DNS Hijack 只覆盖 TCP/UDP 53，不能拦截浏览器 DoH、系统/应用 DoT 853、IPv6 RDNSS、蜂窝双通道或 VPN。

### 移动端最小排查与验收

1. 关闭移动数据、VPN、WLAN+/双通道网络加速，只保留 BPI Wi-Fi。
2. 查看 Wi-Fi 详情，确认默认网关和 DNS 均为当前 BPI LAN 地址 `192.168.0.242`；使用 BPI DHCP 时，租约表必须出现该设备。
3. 保持系统“私人 DNS”关闭，同时关闭浏览器“安全 DNS/加密 DNS”和应用自带 DoH/DoT；彻底退出并重新打开浏览器。
4. 暂时关闭客户端 IPv6，排除 DHCPv6/RDNSS、IPv6 默认路由和 IPv6 WebRTC 旁路。
5. 重新打开 Net.Coffee，同时记录 Mihomo debug；页面生成的两个 `<token>-<n>.d.ip.net.coffee` 必须逐条出现在日志中，并全部命中 `1.0.0.1/1.1.1.1 + MESL`。
6. 保存不含完整公网 IP、订阅或凭据的截图、token、时间和命令输出，再交给 fresh 无上下文黑盒代理判定 `ACCEPT/REJECT`；主线自审不能替代该裁决。

| 结果 | 处置 |
|---|---|
| 页面 token 未出现在 Mihomo 日志 | 客户端绕过 BPI DNS；检查网关、DNS、SSID、蜂窝、VPN、浏览器 DoH 和 IPv6 |
| token 出现且日志走国内 DNS | 路由器策略异常；停止验收，回读实际运行 YAML 与规则匹配 |
| token 出现且日志走 `1.0.0.1/1.1.1 + MESL`，页面仍报中国 DNS | 保留 token、时间和脱敏截图，按 Net.Coffee 归属库/结果聚合误报处理 |
| token 与日志一致且页面不再显示中国 DNS | 移动端 DNS 验收 `ACCEPT` |

当前结论为：路由器 DNS 分流 `PASS`；有线 PC 样本未暴露解析器；移动端 `PARTIAL`；整套客户端验收保持 `PARTIAL`。

当前 `.242` 恢复态备份为 `backups/router-20260719-175110-stable-current`。DPAPI 主归档隔离解包、内部摘要 `12/12`、DPAPI 往返和官方 IPK 摘要 `13/13` 均通过；该备份明确不包含 WAN、美国出口和 DNS 泄漏的通过结论，且未再次执行破坏性 RST 整机回灌。

### 国内/国外时区的边界

DNS 分流和 Clash 规则不能按网站改变操作系统或浏览器 JavaScript 时区。路由器和国内日常客户端继续使用 `Asia/Shanghai`；若国外网站必须读取美国时区，使用独立浏览器配置、扩展或隔离环境把该配置设为目标美国时区，并单独做网页黑盒。不要修改路由器系统时区来伪装国外网站，否则会影响日志、计划任务和证书排障。国内/国外时区分离属于客户端浏览器层功能，不计入本 DNS 恢复已完成范围。

## 限制与判读

- `default-nameserver` 和 `proxy-server-nameserver` 是国内 UDP DNS。设计上它们承担启动解析和节点解析；若把“任何明文启动解析”也定义为泄漏，则当前方案不是零明文 DNS。严格确认实际查询范围和出站路径时检查 Mihomo DNS 日志和 WAN 抓包。
- 不要直接删除两条国内启动 DNS。删除后可能出现代理尚未建立、代理节点域名又必须经代理 DNS 解析的循环依赖。
- Net.Coffee 显示 `0` 个 DNS 解析器表示测试页未观察到递归解析器出口，不能单独证明所有应用、IPv6 和所有域名永远不旁路。需要严格证明时，结合 Mihomo DNS 日志和 WAN 抓包。
- DNS 分流不会修改客户端或系统时区。检测页显示本地 `Asia/Shanghai`、Claude 出口 `America/Los_Angeles`，只是客户端时区与出口所在地时区的对照；若国外网站必须读取到美国 JavaScript 时区，使用独立浏览器配置处理。
- 订阅更新后必须重新检查实际运行 YAML。原订阅中的 `fallback` 不会因为禁用旧 UCI fallback 行而自动消失，因此当前方案显式用国外 DoH 覆盖最终 `fallback`。

## 故障处理与回滚

| 现象 | 处理 |
|---|---|
| OpenClash 重启失败 | 先检查实际运行 YAML 的 `dns` 段和 `MESL` 组是否存在；不要连续反复重启。 |
| 国外域名无法解析 | 检查 `MESL` 是否可用，以及 `nameserver`、`fallback` 是否都带 `#MESL`。 |
| 国内域名解析异常 | 检查 `nameserver-policy` 是否包含 `geosite:cn`，并确认国内 DoH 可直连。 |
| 再次出现中国 DNS 出口 | 先检查浏览器安全 DNS、应用自带 DoH、IPv6 DNS 和最终运行 YAML，再修改 OpenClash。 |
| 出现启动循环 | 保留国内 `default-nameserver` 与 `proxy-server-nameserver`，检查代理节点域名能否直连解析。 |

### 历史回滚记录

下列备份和命令对应 2026-07-18 的历史变更，不是当前 `.242` 恢复态的直接回滚授权。执行任何新写入前先生成 fresh scoped 备份并下载到路由器以外的位置；优先使用带失败回滚的 [`openclash-ui-patch/restore-stable-baseline.sh`](../openclash-ui-patch/restore-stable-baseline.sh)。只有在校验历史备份确与目标状态匹配时，才参考下列命令。

当次变更前创建的 OpenClash UCI 备份为：

```text
/etc/config/openclash.bak.20260718-190412
```

需要回滚时，在路由器终端执行：

```sh
set -e
backup=/etc/config/openclash.bak.20260718-190412
[ -s "$backup" ] || { echo "backup_missing_or_empty:$backup" >&2; exit 1; }

tmpdir=$(mktemp -d) || exit 1
cp "$backup" "$tmpdir/openclash" || exit 1
uci -c "$tmpdir" show openclash >/dev/null || {
  rm -rf "$tmpdir"
  echo "backup_parse_failed:$backup" >&2
  exit 1
}
rm -rf "$tmpdir"

current="/etc/config/openclash.pre-rollback.$(date +%Y%m%d-%H%M%S)"
cp /etc/config/openclash "$current" || exit 1
restore_tmp="/etc/config/.openclash.restore.$$"
trap 'rm -f "$restore_tmp"' EXIT
cp "$backup" "$restore_tmp"
mv "$restore_tmp" /etc/config/openclash
uci revert openclash
/etc/init.d/openclash restart
status=$(/etc/init.d/openclash status)
[ "$status" = running ] || { echo "rollback_restart_failed:$status" >&2; exit 1; }
trap - EXIT
```

命令输出 `backup_missing_or_empty:<path>` 或 `backup_parse_failed:<path>` 时禁止覆盖当前配置。输出 `rollback_restart_failed:<status>` 时停止继续修改，保留 `$current` 并检查 OpenClash 服务日志。回滚后重新执行完整验收流程，不要把“服务已启动”当作 DNS 分流已经恢复。
