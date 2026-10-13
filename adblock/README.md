# 广告过滤（r3mini-adblock）

在 BPI-R3 Mini（ImmortalWrt 24.10 + OpenClash Meta 内核）上拦截红果短剧、抖音等 App 的广告。按域名拦截：设备流量经过本机时，App 用 HTTPDNS 或内置 IP 直连广告服务器也拦得住。LuCI「服务 → 广告过滤」可以一键开关、每天自动更新订阅规则。2026-10-13 在 ImmortalWrt 24.10.6 + OpenClash 0.47.156 上装机验收。

## 工作原理

安装器在 `/etc/openclash/custom/openclash_custom_rules.list` 的 `rule-providers:` 与 `rules:` 下各插一段受管段（`# >>> r3mini-adblock (managed) >>>` 到 `# <<< r3mini-adblock (managed) <<<`），定义两个 `type: file` 规则集，并把引用它们的两条规则放在最前面，命中即 `REJECT`：

| 规则集 | 类型 | 内容 |
|---|---|---|
| `r3mini-adblock-rule` | classical | `/etc/r3mini-adblock/core.rules` 的 16 条：正则匹配红果广告视频 CDN（`*reading-ad*.qznovelvod.com`）、字节广告接口（`ads数字-normal-*.zijieapi.com`）、广告图片（`p数字-ad-sign.byteimg.com`）、抖音广告视频（`*-ad.douyinvod.com`）；穿山甲、巨量引擎、橙子建站；字节 HTTPDNS `dig.bdurl.net` |
| `r3mini-adblock-domain` | domain | `/etc/r3mini-adblock/domains.list` 的 183 个内置广告域名（含子域名）＋订阅＋额外域名，减去白名单 |

- 依赖 OpenClash 流量嗅探：mihomo 从 TLS 握手读出域名再匹配规则，所以 App 绕过 DNS 直连 IP 也被拦。嗅探没开时只拦得住经本机 DNS 解析的连接。
- 开关、换订阅、更新都只改规则集文件，再经 OpenClash API（`PUT /providers/rules/<规则集名>`）热加载，不重启 OpenClash。关闭时两个规则集只剩一条 `.invalid` 占位规则，等于不拦任何东西。
- 订阅默认是秋风广告规则「仅广告」版（不含隐私、遥测、更新类规则，误伤最少）。每次下载后先检查，出现以下情况就拒收、沿用旧规则：下载失败；少于 10 条；超过 100000 条；上次不少于 100 条而这次少了一半以上；比上次多出 3 倍加 1000 条以上。
- 白名单：名单里的域名本身和它的上级域名都不拦，它的子域名照拦。例如白名单有 `toutiao.com`，订阅里整域封 `toutiao.com` 的条目被剔除，`ad.toutiao.com` 照拦。默认白名单保护红果正片、抖音接口、登录支付平台和常见 CDN；订阅自己的下载站（`raw.githubusercontent.com` 与 jsDelivr）永远不拦，免得一份坏订阅把自己的修复也拦掉。

## 前提

安装器逐项检查下面这些，不满足就在日志末行打印 `ABORT <原因>` 并退出，设备不被改动：

| 检查 | 要求 |
|---|---|
| 命令 | 路由器上有 `ruby curl jsonfilter flock setsid md5sum cmp tar`（装了 OpenClash 的 ImmortalWrt 24.10 自带） |
| OpenClash 自定义规则 | `uci get openclash.config.enable_custom_clash_rules` 为 `1` |
| 自定义规则文件 | 有单独成行的顶层 `rules:`；`rule-providers:` 若存在也必须单独成行（没有就自动补上）；受管段的开始 / 结束标记成对 |
| 运行配置 | 自定义规则文件不比运行配置新（改了自定义规则还没重启 OpenClash 时不装） |
| dhcp | `uci changes dhcp` 为空 |
| 网络 | OpenClash 在跑；`nslookup www.baidu.com 127.0.0.1` 有结果；`https://www.baidu.com/` 能访问；改动前能访问 `https://api.anthropic.com/` 的话（有代理节点），改动后也必须能访问 |

安装器不检查、但要满足才有完整效果：

- OpenClash 开启流量嗅探和嗅探纯 IP：`uci get openclash.config.enable_meta_sniffer` 与 `uci get openclash.config.enable_meta_sniffer_pure_ip` 都是 `1`。
- OpenClash 支持从自定义规则文件合并 `rule-providers`（0.47.156 已验证）。不支持时安装器在重启后发现规则集没加载，自动回滚，日志末行 `ROLLED_BACK_OK rules_not_in_runtime`。
- 要过滤的手机、电脑把网关和 DNS 都指向本机；只改 DNS 不改网关的设备，App 直连 IP 的广告拦不住。

## 包内文件

| 包内路径 | 装到路由器 |
|---|---|
| `router/usr/sbin/r3mini-adblock` | 同路径，运行时命令（开关、更新、状态） |
| `router/etc/r3mini-adblock/core.rules`、`domains.list` | 同路径，内置规则与域名 |
| `router/etc/config/r3mini_adblock` | 同路径，默认配置；已存在就保留 |
| `router/www/luci-static/resources/view/services/r3mini-adblock.js` | 同路径，LuCI 页面 |
| `router/usr/share/luci/menu.d/luci-app-r3mini-adblock.json`、`router/usr/share/rpcd/acl.d/luci-app-r3mini-adblock.json` | 同路径，菜单与权限 |
| `install.sh` | 不安装，安装 / 卸载 / 预演入口 |
| `dnsmasq-remove.list` | 不安装，旧方案写进 dnsmasq 的广告域名，安装时删掉（没有就跳过） |
| `test/` | 不安装，验收脚本 |

安装后还会生成 `/etc/openclash/rule_provider/r3mini-adblock-domain.txt`、`r3mini-adblock-rule.txt`（规则集文件）和 `/etc/crontabs/root` 里一行带 `#r3mini-adblock` 标记的定时任务。

## 安装

1. 在局域网内的电脑上（Windows 用 Git Bash），把 `adblock/` 目录传到路由器：

   ```bash
   tar -cf - -C adblock . | ssh root@<路由器IP> 'rm -rf /tmp/r3mini-adblock-pkg && mkdir -p /tmp/r3mini-adblock-pkg && tar -xf - -C /tmp/r3mini-adblock-pkg'
   ```

   路由器没有 SFTP 服务时 `scp` 默认会失败，所以用 tar 经 SSH 管道传。

2. 预演（只读，不改设备）：

   ```bash
   ssh root@<路由器IP> 'sh /tmp/r3mini-adblock-pkg/install.sh dry-run'
   ```

   `== install:` 行要以 `awk_rc=0` 开头，后面和末行 `== 期望 install 核对结果：` 之后的内容一字不差；不一致就停下，不要安装。.242 上的真实输出（已装过的状态下预演）：

   ```text
   缩进：rule-providers 下 [  ]，rules 下 []
   == install: awk_rc=0 same=true providers=r3mini-adblock-domain,r3mini-adblock-rule defs=true ours_rules=2 head=RULE-SET,r3mini-adblock-rule,REJECT,RULE-SET,r3mini-adblock-domain,REJECT
   2: # >>> r3mini-adblock (managed) >>>
   3:   r3mini-adblock-rule:
   4:     type: file
   5:     behavior: classical
   6:     format: text
   7:     path: ./rule_provider/r3mini-adblock-rule.txt
   8:   r3mini-adblock-domain:
   9:     type: file
   10:     behavior: domain
   11:     format: text
   12:     path: ./rule_provider/r3mini-adblock-domain.txt
   13: # <<< r3mini-adblock (managed) <<<
   32: # >>> r3mini-adblock (managed) >>>
   33: - RULE-SET,r3mini-adblock-rule,REJECT
   34: - RULE-SET,r3mini-adblock-domain,REJECT
   35: # <<< r3mini-adblock (managed) <<<
   缩进：rule-providers 下 [  ]，rules 下 []
   == uninstall: awk_rc=0 same=true providers= defs=false ours_rules=0 head=other
   == 期望 install 核对结果：same=true providers=r3mini-adblock-domain,r3mini-adblock-rule defs=true ours_rules=2 head=RULE-SET,r3mini-adblock-rule,REJECT,RULE-SET,r3mini-adblock-domain,REJECT
   ```

3. 后台安装（SSH 断开也不中断；OpenClash 会重启一次，经本机上网的设备断网约 30 秒）：

   ```bash
   ssh root@<路由器IP> 'setsid sh /tmp/r3mini-adblock-pkg/install.sh install </dev/null >/dev/null 2>&1 &'
   ```

4. 约 1 分钟后看日志，最后一行是结论：

   ```bash
   ssh root@<路由器IP> 'cat /tmp/r3mini-adblock-install.log'
   ```

   当前版安装器在 .242 上原地重装的真实日志（已装过，所以 dnsmasq 是 0 → 0、订阅是「规则没有变化」；`udhcpc` 几行是 dnsmasq 重启时探测局域网 DHCP 服务器的正常输出）：

   ```text
   20:26:12 START mode=install pkg=/tmp/r3mini-adblock-pkg backup=/etc/r3mini-adblock-backup-20261013-202612
   20:26:12 外网检查：国内站必须能访问；海外站 api.anthropic.com 改动前能访问，改动后也必须能访问
   20:26:13 before: e075d8f7ad11 rules=3483 dnsmasq_addr=0
   20:26:13 规则集文件：domain 783 行，rule 16 行
   20:26:13 缩进：rule-providers 下 [  ]，rules 下 []
   20:26:14 custom rules: same=true providers=r3mini-adblock-domain,r3mini-adblock-rule defs=true ours_rules=2 head=RULE-SET,r3mini-adblock-rule,REJECT,RULE-SET,r3mini-adblock-domain,REJECT
   20:26:14 dnsmasq: 广告域名 0 条 -> 0 条（其它来源的条目保留）
   udhcpc: started, v1.36.1
   udhcpc: broadcasting discover
   udhcpc: broadcasting select for 192.168.0.28, server 192.168.0.254
   udhcpc: lease of 192.168.0.28 obtained from 192.168.0.254, lease time 7200
   OpenClash Restart...
   OpenClash Already Stop!
   OpenClash Already Start!
   20:26:41 after: e075d8f7ad11 rules=3483
   20:26:42 runtime: head=["RULE-SET,r3mini-adblock-rule,REJECT", "RULE-SET,r3mini-adblock-domain,REJECT"] rule=true domain=true
   20:26:42 status: {"enabled":true,"subscription":true,"auto_update":true,"update_hour":4,"updating":false,"openclash_running":true,"loaded":"yes","runtime_domain":783,"runtime_rule":16,"domain_rules":783,"core_rules":16,"builtin_rules":16,"builtin_domains":183,"last_time":"2026-10-13 20:16:46","last_result":"unchanged","last_message":"规则没有变化","message":"","sources":[{"url":"https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash-Only.Ads.yaml","count":651,"time":"2026-10-13 20:16:46","error":""}]}
   20:26:44 订阅：规则没有变化
   20:26:45 status: {"enabled":true,"subscription":true,"auto_update":true,"update_hour":4,"updating":false,"openclash_running":true,"loaded":"yes","runtime_domain":783,"runtime_rule":16,"domain_rules":783,"core_rules":16,"builtin_rules":16,"builtin_domains":183,"last_time":"2026-10-13 20:26:44","last_result":"unchanged","last_message":"规则没有变化","message":"","sources":[{"url":"https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash-Only.Ads.yaml","count":651,"time":"2026-10-13 20:26:44","error":""}]}
   20:26:45 INSTALL_OK backup=/etc/r3mini-adblock-backup-20261013-202612
   ```

   首次安装的真实日志（2026-10-13 .242，从旧方案升级，删掉了 dnsmasq 里旧的 183 条广告域名；这次用的是上一版安装器，比当前版少一行「外网检查」）：

   ```text
   04:32:21 START mode=install pkg=/tmp/r3mini-adblock-pkg backup=/etc/r3mini-adblock-backup-20261013-043221
   04:32:22 before: e075d8f7ad11 rules=3483 dnsmasq_addr=183
   04:32:22 规则集文件：domain 181 行，rule 16 行
   04:32:22 缩进：rule-providers 下 [  ]，rules 下 []
   04:32:22 custom rules: same=true providers=r3mini-adblock-domain,r3mini-adblock-rule defs=true ours_rules=2 head=RULE-SET,r3mini-adblock-rule,REJECT,RULE-SET,r3mini-adblock-domain,REJECT
   04:32:23 dnsmasq: 广告域名 183 条 -> 0 条（其它来源的条目保留）
   udhcpc: started, v1.36.1
   udhcpc: broadcasting discover
   udhcpc: broadcasting select for 192.168.0.28, server 192.168.0.254
   udhcpc: lease of 192.168.0.28 obtained from 192.168.0.254, lease time 7200
   OpenClash Restart...
   OpenClash Already Stop!
   OpenClash Already Start!
   04:32:49 after: e075d8f7ad11 rules=3483
   04:32:50 runtime: head=["RULE-SET,r3mini-adblock-rule,REJECT", "RULE-SET,r3mini-adblock-domain,REJECT"] rule=true domain=true
   04:32:50 status: {"enabled":true,"subscription":true,"auto_update":true,"update_hour":4,"updating":false,"openclash_running":true,"loaded":"yes","runtime_domain":181,"runtime_rule":16,"domain_rules":181,"core_rules":16,"builtin_rules":16,"builtin_domains":183,"last_time":"","last_result":"","last_message":"","message":"","sources":[{"url":"https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash-Only.Ads.yaml","count":0,"time":"","error":""}]}
   04:32:51 订阅：新增 602 条，移除 0 条
   04:32:52 status: {"enabled":true,"subscription":true,"auto_update":true,"update_hour":4,"updating":false,"openclash_running":true,"loaded":"yes","runtime_domain":783,"runtime_rule":16,"domain_rules":783,"core_rules":16,"builtin_rules":16,"builtin_domains":183,"last_time":"2026-10-13 04:32:51","last_result":"ok","last_message":"新增 602 条，移除 0 条","message":"","sources":[{"url":"https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash-Only.Ads.yaml","count":651,"time":"2026-10-13 04:32:51","error":""}]}
   04:32:52 INSTALL_OK backup=/etc/r3mini-adblock-backup-20261013-043221
   ```

改动前的文件逐个备份并核对到 `/etc/r3mini-adblock-backup-<时间>/`（日志首行和末行都有路径）。`/etc/config/r3mini_adblock` 已存在时保留，重装不丢开关设置。

## 验收

1. 状态：`ssh root@<路由器IP> /usr/sbin/r3mini-adblock status`。`loaded` 要是 `"yes"`，`runtime_domain` 等于 `domain_rules`，`runtime_rule` 等于 `core_rules`。真实输出：

   ```text
   {"enabled":true,"subscription":true,"auto_update":true,"update_hour":4,"updating":false,"openclash_running":true,"loaded":"yes","runtime_domain":783,"runtime_rule":16,"domain_rules":783,"core_rules":16,"builtin_rules":16,"builtin_domains":183,"last_time":"2026-10-13 20:26:44","last_result":"unchanged","last_message":"规则没有变化","message":"","sources":[{"url":"https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash-Only.Ads.yaml","count":651,"time":"2026-10-13 20:26:44","error":""}]}
   ```

2. 页面：浏览器打开 `http://<路由器IP>/cgi-bin/luci/admin/services/r3mini-adblock`（菜单「服务 → 广告过滤」），右上角显示「过滤中」。

3. 拦截探针：在默认网关就是这台路由器的电脑上运行 `python adblock/test/probe_pc.py`。它直连不相干的 IP、在 TLS 握手里带广告域名，模拟 App 用 HTTPDNS 直连，只有按域名拦截才拦得住。电脑网关不是这台路由器时结果没有意义，跳过。.242 上的真实输出：

   ```text
   BLOCK BLOCK ok   ads3-normal-hl.zijieapi.com          内置正则：字节广告接口 (SSLEOFError)
   BLOCK BLOCK ok   v3-reading-ad.qznovelvod.com         内置正则：红果广告视频 (SSLEOFError)
   BLOCK BLOCK ok   dig.bdurl.net                        内置：字节 HTTPDNS (SSLEOFError)
   BLOCK BLOCK ok   activity-ag.awemeughun.com           内置域名清单（旧方案只在 DNS 层拦） (SSLEOFError)
   BLOCK BLOCK ok   www.adsmoloco.com                    订阅：秋风广告规则 (SSLEOFError)
   OPEN  OPEN  ok   www.baidu.com                        对照：百度
   OPEN  OPEN  ok   v5-dj-reading-video.qznovelvod.com   对照：红果正片
   OPEN  OPEN  ok   api5-normal-hl.amemv.com             对照：抖音 API
   OPEN  OPEN  ok   p3-tt.byteimg.com                    白名单：订阅里有，被剔除
   PROBE_ALL_AS_EXPECTED
   ```

4. 路由器上的沙箱测试（只写 `/tmp`，另起一个只监听 127.0.0.1 的测试用 mihomo，不碰正在跑的 OpenClash；最后一节会真实下载一次订阅）：

   ```bash
   ssh root@<路由器IP> 'sh /tmp/r3mini-adblock-pkg/test/device-sandbox-test.sh; sh /tmp/r3mini-adblock-pkg/test/device-installer-dryrun-test.sh'
   ```

   .242 上两个脚本的末行分别是 `RESULT pass=60 fail=0` 和 `RESULT pass=19 fail=0`。

5. 离线页面测试（电脑上，需要 Chrome 或 Edge）：`node adblock/test/ui/run-ui-test.js`，输出 23 行 `PASS` 和 `DONE`，截图写到系统临时目录的 `r3mini-adblock-ui-test/`。

## 日常使用

- 页面「服务 → 广告过滤」：总开关；订阅规则开关；每天自动更新开关和时间（整点 30 分）；「立即更新规则」。开关立即生效。
- 命令行：`r3mini-adblock` 不带参数打印全部子命令和退出码。常用：`r3mini-adblock status`、`r3mini-adblock disable`、`r3mini-adblock enable`、`r3mini-adblock update`。
- 定时更新按路由器本机时间运行。R3 Mini 没有电池供电的时钟，冷启动后时间会退回固件构建日期，确认 `uci get system.ntp.enabled` 为 `1`。

配置在 `/etc/config/r3mini_adblock`（UCI，`config adblock 'main'`）：

| 选项 | 取值 | 默认 | 作用 |
|---|---|---|---|
| `enabled` | `0` / `1` | `1` | 总开关 |
| `subscription` | `0` / `1` | `1` | 是否使用订阅 |
| `auto_update` | `0` / `1` | `1` | 每天定时更新 |
| `update_hour` | `0`–`23` | `4` | 定时更新的小时，分钟固定 30 |
| `source` | 列表，URL | 秋风广告规则「仅广告」Clash 版 | 订阅地址；认 Clash domain/classical（YAML 或文本）、dnsmasq `address=/域名/`、hosts、AdGuard `\|\|域名^`、纯域名；关键词、正则、IP 类规则跳过 |
| `allow` | 列表，域名 | 包内默认（红果、抖音、登录支付、CDN 等） | 白名单 |
| `extra` | 列表，域名 | 空 | 额外拦截（含子域名） |

改白名单或额外域名后执行 `r3mini-adblock apply` 生效，例如：

```bash
uci add_list r3mini_adblock.main.allow='example.com' && uci commit r3mini_adblock && r3mini-adblock apply
```

## 卸载

```bash
ssh root@<路由器IP> 'setsid sh /tmp/r3mini-adblock-pkg/install.sh uninstall </dev/null >/dev/null 2>&1 &'
```

日志末行 `UNINSTALL_OK` 即完成。卸载删掉受管段、规则集文件、定时任务、LuCI 页面、命令和配置，同样先备份、重启 OpenClash 一次、核对并在失败时回滚；不恢复旧方案的 dnsmasq 条目和旧 `hongguo-adblock` 受管段。`/tmp` 在路由器重启后清空，卸载前先按「安装」第 1 步重新上传包。

## 失败处置

安装 / 卸载日志的末行：

| 末行 | 含义 | 处置 |
|---|---|---|
| `INSTALL_OK` / `UNINSTALL_OK` | 完成并核对通过 | 无 |
| `INSTALL_OK UPDATE_FAILED <原因>` | 内置规则已生效，订阅没下载成功 | 稍后执行 `r3mini-adblock update` 或在页面点「立即更新规则」 |
| `INSTALL_OK SUBSCRIPTION_DISABLED <原因>` | 订阅生效后外网检查不过，已自动关掉订阅，内置规则照常生效 | 网络正常后在页面重新打开订阅，再看能否上网 |
| `ABORT <原因>` | 前置检查不过，设备没被改动 | 按下表处理后重新安装 |
| `ROLLED_BACK_OK <原因>` | 已把全部改动还原 | 按下表处理 |
| `ROLLED_BACK_BUT_UNHEALTHY <原因>` | 文件已还原，但 OpenClash 或网络没恢复健康 | 看 `/etc/init.d/openclash status` 和 `/tmp/openclash.log`；备份目录在日志里 |

| 原因 | 处置 |
|---|---|
| `OpenClash 自定义规则没开（enable_custom_clash_rules!=1）…` | 先看自定义规则文件里有没有没注释掉的规则（打开开关会让它们一起生效），确认没问题后执行 `uci set openclash.config.enable_custom_clash_rules=1 && uci commit openclash && /etc/init.d/openclash restart`，再装 |
| `改动前就不健康（OpenClash/DNS/国内外网）…` | 先让 OpenClash 正常运行、能上网 |
| `自定义规则改过但 OpenClash 还没重启…` | 执行 `/etc/init.d/openclash restart` 后再装 |
| `dhcp 有没提交的改动…` | 在 LuCI 里「保存并应用」或撤销 |
| `…受管段开始 / 结束标记不成对…` | 人工补齐或删掉残缺的标记 |
| `已有一个安装/卸载在跑` | 等它结束 |
| `包里缺 …` | 重新完整上传 `adblock/` |
| `rules_not_in_runtime`、`provider_not_loaded` | OpenClash 没加载规则集，多半版本太旧、不合并自定义 `rule-providers`；升级 OpenClash |
| `runtime_changed_beyond_adblock`、`other_rules_changed` | 重启时订阅节点或其它配置也变了；稍后重装 |
| `unhealthy_after_restart` | 重启后网络不健康，已回滚；查 OpenClash 日志 |

缺包文件时的真实失败日志：

```text
20:25:26 START mode=install pkg=/tmp/r3ab-abort backup=/etc/r3mini-adblock-backup-20261013-202526
20:25:26 ABORT 包里缺 dnsmasq-remove.list
```

命令行 `r3mini-adblock` 在 OpenClash 没在运行时，规则照样写进文件，但热加载失败，退出码 `2`，真实输出：

```text
连不上 OpenClash（API 返回 000）；规则已保存，OpenClash 运行后自动生效
```

## 给同型号路由器安装：交给 AI 助手的提示词

把下面整段发给在目标局域网电脑上运行的 Claude Code、Codex 等助手，`<路由器IP>` 换成实际地址：

```text
帮我给一台 Banana Pi BPI-R3 Mini 软路由（ImmortalWrt + OpenClash）装「广告过滤」。路由器地址 <路由器IP>，SSH 用户 root，密码我单独告诉你：不要打印出来，不要写进任何文件。

材料：公开仓库 https://github.com/xiaohonghua661/Banana-Pi-R3-Mini-Toolkit 里的 adblock/ 目录。
- 用 git clone --depth 1 拉这个仓库；main 分支里没有 adblock/ 就改用 git clone --depth 1 -b agent/adblock。没有 git 就下载 https://github.com/xiaohonghua661/Banana-Pi-R3-Mini-Toolkit/archive/refs/heads/main.zip（没有 adblock/ 就把 main 换成 agent/adblock）。
- 只读 adblock/README.md 和 adblock/ 下的文件。仓库根目录的 AGENTS.md、docs/ 写的是原作者自己的设备（例如 192.168.0.242）和他的协作工具 dd，跟这台路由器无关，不要照着做。

按顺序做，每一步把关键输出贴给我：
1. 只读检查，什么都不改：cat /etc/openwrt_release；opkg list-installed | grep openclash；/etc/init.d/openclash status；uci get openclash.config.enable_custom_clash_rules、enable_meta_sniffer、enable_meta_sniffer_pure_ip 三项；/etc/openclash/custom/openclash_custom_rules.list 里没被 # 注释掉的行；df -h /overlay。对照 README「前提」逐项说明满不满足。
2. 自定义规则开关不是 1，或者嗅探没开：先告诉我打开的影响（自定义规则文件里没注释的规则会一起生效；要重启一次 OpenClash，经这台路由器上网的设备断网约半分钟），等我同意再改；我不同意就停。
3. 按 README「安装」第 1 步把 adblock/ 传到路由器 /tmp/r3mini-adblock-pkg。Windows 上在 Git Bash 里执行；路由器没有 SFTP 服务时 scp 会失败，用 README 里的 tar 管道。
4. 跑预演：sh /tmp/r3mini-adblock-pkg/install.sh dry-run。「== install:」那行必须以 awk_rc=0 开头，后面和末行「期望 install 核对结果」之后的内容一字不差；不一致就停下给我看。
5. 跟我确认可以断网半分钟后再后台安装：setsid sh /tmp/r3mini-adblock-pkg/install.sh install </dev/null >/dev/null 2>&1 &。之后每 5 秒看一次 /tmp/r3mini-adblock-install.log，直到最后一行出现 INSTALL_OK、ROLLED_BACK_OK、ROLLED_BACK_BUT_UNHEALTHY 或 ABORT。按 README「失败处置」处理；不要为了让安装通过去改 OpenClash 的其它配置。
6. 验收：/usr/sbin/r3mini-adblock status 里 loaded 是 "yes"，runtime_domain 等于 domain_rules，runtime_rule 等于 core_rules。页面 http://<路由器IP>/cgi-bin/luci/admin/services/r3mini-adblock 让我自己在浏览器里看，不要替我输入路由器密码。如果你所在电脑的默认网关就是这台路由器，再跑 python adblock/test/probe_pc.py，末行应是 PROBE_ALL_AS_EXPECTED；网关不是它就跳过并说明原因。
7. 最后告诉我：日志末行的结论、备份目录、在页面上怎么开关和改更新时间、怎么卸载。提醒我：手机和电脑要把网关和 DNS 都指向这台路由器，广告才会被过滤。
```
