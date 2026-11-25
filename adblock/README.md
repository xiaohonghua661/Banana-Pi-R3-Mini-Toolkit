# 广告过滤（r3mini-adblock）

在 BPI-R3 Mini（ImmortalWrt 24.10 + OpenClash Meta 内核）上拦截红果短剧、抖音等 App 的广告。按域名拦截：设备流量经过本机时，App 用 HTTPDNS 或内置 IP 直连广告服务器也拦得住。LuCI「服务 → 广告过滤」可以一键开关、每天自动更新订阅规则。2026-10-13 在 ImmortalWrt 24.10.6 + OpenClash 0.47.156 上装机验收。

## 工作原理

安装器在 `/etc/openclash/custom/openclash_custom_rules.list` 的 `rule-providers:` 与 `rules:` 下各插一段受管段（`# >>> r3mini-adblock (managed) >>>` 到 `# <<< r3mini-adblock (managed) <<<`），定义两个 `type: file` 规则集，并把引用它们的两条规则放在最前面，命中即 `REJECT`：

| 规则集 | 类型 | 内容 |
|---|---|---|
| `r3mini-adblock-rule` | classical | `/etc/r3mini-adblock/core.rules` 的 16 条：正则匹配红果广告视频 CDN（`*reading-ad*.qznovelvod.com`）、字节广告接口（`ads数字-normal-*.zijieapi.com`）、广告图片（`p数字-ad-sign.byteimg.com`）、抖音广告视频（`*-ad.douyinvod.com`）；穿山甲、巨量引擎、橙子建站；字节 HTTPDNS `dig.bdurl.net` |
| `r3mini-adblock-domain` | domain | `/etc/r3mini-adblock/domains.list` 的 183 个内置广告域名（含子域名）＋订阅＋额外域名，减去白名单 |

- 只对把网关和 DNS 都指向本机的设备生效。
- 依赖 OpenClash 流量嗅探：mihomo 从 TLS 握手读出域名再匹配规则，所以 App 绕过 DNS 直连 IP 也被拦。嗅探没开、或开了「大陆 IP 绕过」时，直连国内 IP 的流量不经 mihomo 判断，只拦得住经本机 DNS 解析的连接。
- 开关、换订阅、更新都只改规则集文件，再经 OpenClash API（`PUT /providers/rules/<规则集名>`）热加载，不重启 OpenClash。关闭时两个规则集只剩一条 `.invalid` 占位规则，等于不拦任何东西。
- 订阅默认是秋风广告规则「仅广告」版（不含隐私、遥测、更新类规则，误伤最少）。每次下载后先检查，出现以下任一情况就拒收、沿用旧规则：下载失败；少于 10 条；超过 100000 条；上次不少于 100 条时，这次不到上次的一半，或超过「上次 × 3 + 1000」条。
- 白名单：白名单里的域名本身，以及能覆盖它的上级整域条目（`+.上级域名`）都会从拦截列表剔除；上级域名的单个精确条目和更深的子域名条目照拦。例如白名单有 `toutiao.com`，订阅里整域封 `toutiao.com` 的条目被剔除，`ad.toutiao.com` 照拦。默认白名单保护红果正片、抖音接口、登录支付平台和常见 CDN；订阅自己的下载站（`raw.githubusercontent.com` 与 jsDelivr）永远不拦，免得一份坏订阅把自己的修复也拦掉。

## 包内文件

| 包内路径 | 装到路由器 |
|---|---|
| `router/usr/sbin/r3mini-adblock` | 同路径，运行时命令（开关、更新、状态） |
| `router/etc/r3mini-adblock/core.rules`、`domains.list` | 同路径，内置规则与域名 |
| `router/etc/config/r3mini_adblock` | 同路径，默认配置；已存在就保留 |
| `router/www/luci-static/resources/view/services/r3mini-adblock.js` | 同路径，LuCI 页面 |
| `router/usr/share/luci/menu.d/luci-app-r3mini-adblock.json`、`router/usr/share/rpcd/acl.d/luci-app-r3mini-adblock.json` | 同路径，菜单与权限 |
| `install.sh` | 不安装，预检 / 预演 / 安装 / 卸载入口；**必须带参数**，不带参数只打印用法 |
| `dnsmasq-remove.list` | 不安装，必须随包上传；列的是旧方案写进 dnsmasq 的广告域名，安装时逐条从 dnsmasq 删掉，路由器上本来没有的条目自动跳过 |
| `test/` | 不安装，验收脚本 |

安装后还会生成 `/etc/openclash/rule_provider/r3mini-adblock-domain.txt`、`r3mini-adblock-rule.txt`（规则集文件）和 `/etc/crontabs/root` 里一行带 `#r3mini-adblock` 标记的定时任务。每次安装、卸载都在 `/etc` 下留一个 `r3mini-adblock-backup-<时间>/` 备份目录，不自动清理；确认运行正常后可以手动删旧的。

## 连接路由器

下面的命令在局域网内的电脑上执行，工作目录是仓库根目录（命令里用 `-C adblock`）。Windows 用 Git Bash；没有 Git Bash 时用 PowerShell，但「安装」第 1 步的上传命令要改用该步给的 `cmd /c` 写法：Windows PowerShell 5.1 的管道会损坏二进制数据。

- SSH 登录建议用密钥：`ssh-keygen -t ed25519 -f ~/.ssh/r3mini_ed25519 -N ""` 生成密钥，把 `~/.ssh/r3mini_ed25519.pub` 的内容贴进 LuCI「系统 → 管理权 → SSH 密钥」并保存，之后用 `ssh -i ~/.ssh/r3mini_ed25519 root@<路由器IP>` 免密登录。AI 助手不要代人输入路由器密码；不能用密钥时，由人自己执行命令、把输出贴给助手。
- 第一次连接要确认主机指纹；非交互执行时给 ssh 加 `-o StrictHostKeyChecking=accept-new`。
- 下文命令里的 `ssh root@<路由器IP>` 按上面两条补上 `-i` 和 `-o` 参数。

## 安装

1. 把 `adblock/` 目录传到路由器：

   ```bash
   tar -cf - -C adblock . | ssh root@<路由器IP> 'rm -rf /tmp/r3mini-adblock-pkg && mkdir -p /tmp/r3mini-adblock-pkg && tar -xf - -C /tmp/r3mini-adblock-pkg'
   ```

   路由器没有 SFTP 服务时 `scp` 默认会失败，所以用 tar 经 SSH 管道传。没有 Git Bash 时在 PowerShell 里执行下面这条，把管道交给 `cmd`；`cmd` 不认单引号，远端命令必须用双引号，否则 `&&` 之后的部分会在电脑上执行：

   ```powershell
   cmd /c 'tar -cf - -C adblock . | ssh root@<路由器IP> "rm -rf /tmp/r3mini-adblock-pkg && mkdir -p /tmp/r3mini-adblock-pkg && tar -xf - -C /tmp/r3mini-adblock-pkg"'
   ```

2. 只读预检（不改设备），逐项打印 `[通过]`、`[不通过]`、`[提醒]`，末行 `CHECK_OK` 或 `CHECK_FAIL <第一项不通过的原因>`：

   ```bash
   ssh root@<路由器IP> 'sh /tmp/r3mini-adblock-pkg/install.sh check'
   ```

   `[不通过]` 会让安装直接 ABORT，按「失败处置」的预检表处理；`[提醒]` 不挡安装，但对应的效果会打折扣。.242 上的真实输出（2026-10-28）：

   ```text
   只读预检（不改设备）：
     [通过] 安装包
     [通过] 命令：ruby curl jsonfilter flock setsid md5sum cmp tar 都在
     [通过] OpenClash版本：0.47.156
     [通过] OpenClash运行
     [通过] 自定义规则开关
     [通过] 流量嗅探
     [通过] 大陆IP绕过：关
     [通过] 自定义规则文件：/etc/openclash/custom/openclash_custom_rules.list
     [通过] 运行配置：/etc/openclash/MESL_yue.yaml
     [通过] dhcp暂存改动：无
     [通过] 剩余空间：/overlay 剩 88 MB
     [通过] 网络：本机 DNS 与国内站正常；海外站 api.anthropic.com 能访问，改动后也必须能访问
   CHECK_OK 可以安装
   ```

3. 只读预演，打印安装 / 卸载后自定义规则文件里的受管段和核对结果：

   ```bash
   ssh root@<路由器IP> 'sh /tmp/r3mini-adblock-pkg/install.sh dry-run'
   ```

   `== install:` 行要以 `awk_rc=0` 开头，后面和末行 `== 期望 install 核对结果：` 之后的内容一字不差（核对不一致时退出码也是 0，只能比对文字；受管段标记不成对时只打印 `MARKERS_BAD` 并以 1 退出）；不一致就停下，不要安装。.242 上的真实输出（已装过的状态下预演；`head=other` 表示卸载后排第一的不是本方案的规则）：

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

4. 后台安装（SSH 断开也不中断；OpenClash 会重启一次，经本机上网的设备断网约 30 秒，执行命令的电脑如果也经本机上网，同样会断）：

   ```bash
   ssh root@<路由器IP> 'date +%Y%m%d-%H%M%S; setsid sh /tmp/r3mini-adblock-pkg/install.sh install </dev/null >/dev/null 2>&1 &'
   ```

   打印的是路由器上的启动时间（年月日-时分秒），第 5 步要用。已有一个安装 / 卸载在跑时，第二次启动直接退出，不写日志、不影响正在跑的那次。

5. 每 5 秒看一次日志的首行和末行，直到末行出现 `INSTALL_OK`、`ROLLED_BACK_OK`、`ROLLED_BACK_BUT_UNHEALTHY` 或 `ABORT`：

   ```bash
   ssh root@<路由器IP> 'head -n 1 /tmp/r3mini-adblock-install.log; tail -n 1 /tmp/r3mini-adblock-install.log'
   ```

   首行 `backup=` 末尾的年月日-时分秒早于第 4 步打印的时间，说明看到的是上一次安装 / 卸载留下的旧日志，末行不算数；只看行首的时分秒不够，旧日志可能是前几天的。正常约 1 分钟结束。网络时好时坏时，健康检查要反复重试，最长可能要 20 分钟以上；超过 20 分钟还没有结论，就停止轮询，把 `cat /tmp/r3mini-adblock-install.log` 的全文交给人判断。启动 1 分钟后日志首行还是旧时间（或日志文件不存在），说明安装器没起来，用 `ps w | grep install.sh` 看进程，并检查第 1 步上传是否完整。

   当前版安装器在 .242 上原地重装的真实日志（2026-10-13，已装过，所以 dnsmasq 是 0 → 0、订阅是「规则没有变化」；`udhcpc` 几行是 dnsmasq 重启时探测局域网 DHCP 服务器的正常输出）：

   ```text
   21:11:03 START mode=install pkg=/tmp/r3mini-adblock-pkg backup=/etc/r3mini-adblock-backup-20261013-211103
   21:11:03 前置检查：
     [通过] 安装包
     [通过] 命令：ruby curl jsonfilter flock setsid md5sum cmp tar 都在
     [通过] OpenClash版本：0.47.156
     [通过] OpenClash运行
     [通过] 自定义规则开关
     [通过] 流量嗅探
     [通过] 大陆IP绕过：关
     [通过] 自定义规则文件：/etc/openclash/custom/openclash_custom_rules.list
     [通过] 运行配置：/etc/openclash/MESL_Yue.yaml
     [通过] dhcp暂存改动：无
     [通过] 剩余空间：/overlay 剩 112 MB
     [通过] 网络：本机 DNS 与国内站正常；海外站 api.anthropic.com 能访问，改动后也必须能访问
   21:11:05 before: e075d8f7ad11 rules=3496 dnsmasq_addr=0
   21:11:05 规则集文件：domain 783 行，rule 16 行
   21:11:05 缩进：rule-providers 下 [  ]，rules 下 []
   21:11:05 custom rules: same=true providers=r3mini-adblock-domain,r3mini-adblock-rule defs=true ours_rules=2 head=RULE-SET,r3mini-adblock-rule,REJECT,RULE-SET,r3mini-adblock-domain,REJECT
   21:11:06 dnsmasq: 广告域名 0 条 -> 0 条（其它来源的条目保留）
   udhcpc: started, v1.36.1
   udhcpc: broadcasting discover
   udhcpc: broadcasting select for 192.168.0.28, server 192.168.0.254
   udhcpc: lease of 192.168.0.28 obtained from 192.168.0.254, lease time 7200
   OpenClash Restart...
   OpenClash Already Stop!
   OpenClash Already Start!
   21:11:34 after: e075d8f7ad11 rules=3496
   21:11:34 runtime: head=["RULE-SET,r3mini-adblock-rule,REJECT", "RULE-SET,r3mini-adblock-domain,REJECT"] rule=true domain=true
   21:11:35 status: {"enabled":true,"subscription":true,"auto_update":true,"update_hour":4,"updating":false,"openclash_running":true,"loaded":"yes","runtime_domain":783,"runtime_rule":16,"domain_rules":783,"core_rules":16,"builtin_rules":16,"builtin_domains":183,"last_time":"2026-10-13 20:26:44","last_result":"unchanged","last_message":"规则没有变化","message":"","sources":[{"url":"https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash-Only.Ads.yaml","count":651,"time":"2026-10-13 20:26:44","error":""}]}
   21:11:36 订阅：规则没有变化
   21:11:37 status: {"enabled":true,"subscription":true,"auto_update":true,"update_hour":4,"updating":false,"openclash_running":true,"loaded":"yes","runtime_domain":783,"runtime_rule":16,"domain_rules":783,"core_rules":16,"builtin_rules":16,"builtin_domains":183,"last_time":"2026-10-13 21:11:36","last_result":"unchanged","last_message":"规则没有变化","message":"","sources":[{"url":"https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash-Only.Ads.yaml","count":651,"time":"2026-10-13 21:11:36","error":""}]}
   21:11:37 INSTALL_OK backup=/etc/r3mini-adblock-backup-20261013-211103
   ```

   首次安装的真实日志（2026-10-13 .242，从旧方案升级，删掉了 dnsmasq 里旧的 183 条广告域名；当时用的是更早一版安装器，前置检查只打印一行外网结果，其余步骤相同）：

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

1. 状态：`ssh root@<路由器IP> /usr/sbin/r3mini-adblock status`。`loaded` 要是 `"yes"`；总开关开着（`enabled` 为 `true`）时，`runtime_domain` 等于 `domain_rules`、`runtime_rule` 等于 `core_rules`（关着时运行中两项都是 1，即占位规则）。真实输出：

   ```text
   {"enabled":true,"subscription":true,"auto_update":true,"update_hour":4,"updating":false,"openclash_running":true,"loaded":"yes","runtime_domain":783,"runtime_rule":16,"domain_rules":783,"core_rules":16,"builtin_rules":16,"builtin_domains":183,"last_time":"2026-10-13 20:26:44","last_result":"unchanged","last_message":"规则没有变化","message":"","sources":[{"url":"https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash-Only.Ads.yaml","count":651,"time":"2026-10-13 20:26:44","error":""}]}
   ```

2. 页面：浏览器打开 `http://<路由器IP>/cgi-bin/luci/admin/services/r3mini-adblock`（菜单「服务 → 广告过滤」），右上角显示「过滤中」。

3. 拦截探针：先确认电脑的默认网关就是这台路由器（Windows 用 `ipconfig`，看「默认网关」），再在仓库根目录运行 `python adblock/test/probe_pc.py`。它直连不相干的 IP、在 TLS 握手里带广告域名，模拟 App 用 HTTPDNS 直连，只有按域名拦截才拦得住。判读：
   - 末行 `PROBE_ALL_AS_EXPECTED` 为通过；`BLOCK` 行括号里应是 `SSLEOFError` 或 `ConnectionResetError`（被代理立刻断开）。
   - 出现 `ERROR` 行和 `PROBE_INVALID=` 时结果无效：多半是电脑没经这台路由器上网，或对照网站连不上；先查网关。
   - 网关确实是这台路由器、却出现 `BLOCK` 期望下的 `OPEN`：广告没拦住，查 `status` 的 `loaded`，以及预检里的「流量嗅探」「大陆IP绕过」两项。
   - 网关不是这台路由器时跳过这一步，并说明原因。

   .242 上的真实输出：

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

4. 路由器上的沙箱测试（只写 `/tmp`，另起一个只监听 127.0.0.1 的测试用 mihomo，不碰正在跑的 OpenClash；沙箱测试最后一节会真实下载一次订阅）：

   ```bash
   ssh root@<路由器IP> 'sh /tmp/r3mini-adblock-pkg/test/device-sandbox-test.sh; sh /tmp/r3mini-adblock-pkg/test/device-installer-dryrun-test.sh'
   ```

   .242 上两个脚本的末行分别是 `RESULT pass=60 fail=0` 和 `RESULT pass=19 fail=0`。

5. 离线页面测试（电脑上）：`node adblock/test/ui/run-ui-test.js`。需要 Chrome，不在默认安装位置时用环境变量 `R3AB_BROWSER` 指定它的完整路径（指向的文件不存在时直接报错退出）。不要用 Edge：Edge 156 实测截完第一张图后进程不退出，脚本会一直卡住。输出 23 行 `PASS`、一行 `DONE`，最后三行是截图路径（写到系统临时目录的 `r3mini-adblock-ui-test/`）。

## 日常使用

- 页面「服务 → 广告过滤」：总开关；订阅规则开关；每天自动更新开关和时间（每天所选小时的 30 分）；「立即更新规则」。开关立即生效。
- 命令行：`r3mini-adblock` 不带参数打印全部子命令和退出码。常用：`r3mini-adblock status`、`r3mini-adblock disable`、`r3mini-adblock enable`、`r3mini-adblock update`。OpenClash 没在运行时，规则照样写进文件、等 OpenClash 运行后生效：`apply`、`update` 以退出码 `2` 结束并打印原因；`enable`、`disable`、`sub` 仍以退出码 `0` 结束，原因写在输出 JSON 的 `message` 字段里。真实原因文字：

  ```text
  连不上 OpenClash（API 返回 000）；规则已保存，OpenClash 运行后自动生效
  ```

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
ssh root@<路由器IP> 'date +%Y%m%d-%H%M%S; setsid sh /tmp/r3mini-adblock-pkg/install.sh uninstall </dev/null >/dev/null 2>&1 &'
```

日志末行 `UNINSTALL_OK` 即完成，轮询方法同安装。卸载删掉受管段、规则集文件、定时任务、LuCI 页面、命令和配置，同样先备份、重启 OpenClash 一次、核对并在失败时回滚；不恢复旧方案的 dnsmasq 条目和旧 `hongguo-adblock` 受管段。`/tmp` 在路由器重启后清空，卸载前先按「安装」第 1 步重新上传包。

卸载同样要过预检里的网络检查。网络已经不正常、只想先停掉过滤时：

1. 执行 `r3mini-adblock disable`：立即生效、不重启 OpenClash，两个规则集只剩占位规则。
2. 还要彻底删掉时，在路由器上手动执行下面的命令，删受管段、文件和定时任务，再重启 OpenClash（重启需同意）。其中改文件的部分在 .242 的文件副本上验证过：两段受管段共 16 行删净，剩下的规则文件解析正常，定时任务只删带 `#r3mini-adblock` 标记的那行：

   ```bash
   F=/etc/openclash/custom/openclash_custom_rules.list; cp -p "$F" /root/openclash_custom_rules.list.bak
   awk '$0 == "# >>> r3mini-adblock (managed) >>>" { s = 1; next } $0 == "# <<< r3mini-adblock (managed) <<<" { s = 0; next } !s' /root/openclash_custom_rules.list.bak > "$F"
   sed -i '/#r3mini-adblock$/d' /etc/crontabs/root; /etc/init.d/cron restart
   rm -f /usr/sbin/r3mini-adblock /etc/config/r3mini_adblock /etc/openclash/rule_provider/r3mini-adblock-*.txt \
     /www/luci-static/resources/view/services/r3mini-adblock.js /usr/share/luci/menu.d/luci-app-r3mini-adblock.json \
     /usr/share/rpcd/acl.d/luci-app-r3mini-adblock.json
   rm -rf /etc/r3mini-adblock /tmp/luci-indexcache* /tmp/luci-modulecache; /etc/init.d/rpcd reload; /etc/init.d/openclash restart
   ```

## 失败处置

标「需同意」的处置会重启 OpenClash 或改其它配置：AI 助手先向人说明影响，得到同意再做。

安装 / 卸载日志的末行：

| 末行 | 含义 | 处置 |
|---|---|---|
| `INSTALL_OK` / `UNINSTALL_OK` | 完成并核对通过 | 无 |
| `INSTALL_OK UPDATE_FAILED <原因>` | 内置规则已生效，订阅没下载成功（常见于路由器访问不了 GitHub / jsDelivr） | 稍后执行 `r3mini-adblock update`，或在页面点「立即更新规则」 |
| `INSTALL_OK SUBSCRIPTION_DISABLED <原因>` | 订阅生效后外网检查不过，已自动关掉订阅，内置规则照常生效 | 网络正常后在页面重新打开订阅，再确认能上网 |
| `ABORT <名称>：<说明>（设备没被改动）` | 预检不通过 | 按下面的预检表处理后重新安装 |
| `ABORT 建不了备份目录…`、`ABORT 备份失败：…`、`ABORT 备份 /etc/r3mini-adblock 失败`、`ABORT 读不了运行配置` | 备份阶段失败，设备没被改动 | 查 `/overlay` 空间（`df -h /overlay`）和运行配置文件是否存在，修好再装 |
| `ROLLED_BACK_OK <代号>` | 已把全部改动还原 | 按下面的回滚表处理 |
| `ROLLED_BACK_OK <代号>（OpenClash 还没重启过，只还原了文件）` | 失败发生在重启 OpenClash 之前，只还原文件，网络没中断过 | 同上 |
| `ROLLED_BACK_BUT_UNHEALTHY <代号>` | 文件已还原，但 OpenClash 或网络没恢复健康 | 停下交给人：看 `/etc/init.d/openclash status` 和 `/tmp/openclash.log`；备份目录在日志里 |

预检项（`check` 与安装共用；卸载跳过「安装包」「自定义规则开关」「dhcp暂存改动」三项）：

| 名称 | 不通过 / 提醒时的处置 |
|---|---|
| 安装包 | 重新完整上传 `adblock/` |
| 命令 | 缺 `ruby` 等时，确认 OpenClash 装全（`opkg list-installed \| grep ruby`）；缺的包装上再试（需同意） |
| OpenClash版本 | 没装：先装 OpenClash。`[提醒]` 版本不是 0.47.x 及以上：可以装，规则集没被加载时会自动回滚，见回滚表 `rules_not_in_runtime` |
| OpenClash运行 | 在 OpenClash 页面启动它，确认能正常上网后再装 |
| 自定义规则开关 | 先看自定义规则文件里有没有没注释掉的规则（打开开关会让它们一起生效），然后（需同意）：`uci set openclash.config.enable_custom_clash_rules=1 && uci commit openclash && /etc/init.d/openclash restart` |
| 流量嗅探（提醒） | 不挡安装，但 App 绕过 DNS 直连 IP 的广告拦不住。打开（需同意）：`uci set openclash.config.enable_meta_sniffer=1 && uci set openclash.config.enable_meta_sniffer_pure_ip=1 && uci commit openclash && /etc/init.d/openclash restart` |
| 大陆IP绕过（提醒） | 不挡安装，但直连国内 IP 的广告拦不住。关闭会让国内流量也经过 OpenClash，在 OpenClash 页面关掉（需同意） |
| 自定义规则文件 | 文件不存在、没有单独成行的 `rules:`、`rule-providers:` 写成行内值、受管段标记不成对：人工改正文件后，执行 `/etc/init.d/openclash restart`（需同意），再装 |
| 运行配置 | 自定义规则改过但 OpenClash 没重启：`/etc/init.d/openclash restart`（需同意）后再装；运行配置文件不存在：OpenClash 没正常生成配置，先修 OpenClash |
| dhcp暂存改动 | LuCI 里有没保存的 DHCP/DNS 改动：让人在 LuCI 里「保存并应用」或撤销 |
| 剩余空间 | `/overlay` 不足 2 MB：删掉旧的 `/etc/r3mini-adblock-backup-*` 等不要的文件 |
| 网络 | OpenClash、本机 DNS、`www.baidu.com` 至少一项不正常：先让路由器正常上网再装 |

回滚代号：

| 代号 | 含义 | 处置 |
|---|---|---|
| `copy_failed`、`build_failed`、`provider_files_missing` | 拷文件或生成规则集文件失败 | 查 `/overlay` 空间；重新上传完整的包再装 |
| `custom_rules_write_failed`、`custom_rules_not_written`、`custom_rules_unexpected`、`managed_block_still_present` | 改写自定义规则文件失败，或改写后的核对不通过 | 跑 `install.sh dry-run` 看核对结果；文件写法特殊时人工检查 |
| `dhcp_commit_failed` | 删 dnsmasq 旧条目后 `uci commit dhcp` 失败 | 查 `/etc/config/dhcp` 是否可写 |
| `unhealthy_after_restart` | 重启 OpenClash 后网络检查一直不过 | 查 OpenClash 日志；网络稳定后重装 |
| `snapshot_failed` | 重启后读不了运行配置 | 查 OpenClash 是否正常生成运行配置 |
| `runtime_changed_beyond_adblock`、`other_rules_changed` | 重启后，除本方案外的 DNS 段、分组、节点数、其它规则集或规则有变化（例如重启时订阅节点刷新了） | 稍后重装 |
| `rules_not_in_runtime`、`provider_not_loaded` | OpenClash 没加载本方案的规则集，多半版本太旧、不合并自定义 `rule-providers` | 升级 OpenClash（需同意）后重装 |
| `provider_still_in_runtime` | 卸载后运行配置里还有本方案的规则集 | 人工检查自定义规则文件，再执行 `/etc/init.d/openclash restart`（需同意） |
| `unhealthy_even_without_subscription` | 订阅生效后外网检查不过，关掉订阅也不过 | 已整套回滚；查网络或 OpenClash 后再装 |

缺包文件时的真实失败日志（2026-10-13 .242，故意少传 `dnsmasq-remove.list`）：

```text
21:14:19 START mode=install pkg=/tmp/r3ab-abort backup=/etc/r3mini-adblock-backup-20261013-211419
21:14:19 前置检查：
  [不通过] 安装包：包里缺 dnsmasq-remove.list，重新完整上传 adblock/
  [通过] 命令：ruby curl jsonfilter flock setsid md5sum cmp tar 都在
  [通过] OpenClash版本：0.47.156
  [通过] OpenClash运行
  [通过] 自定义规则开关
  [通过] 流量嗅探
  [通过] 大陆IP绕过：关
  [通过] 自定义规则文件：/etc/openclash/custom/openclash_custom_rules.list
  [通过] 运行配置：/etc/openclash/MESL_Yue.yaml
  [通过] dhcp暂存改动：无
  [通过] 剩余空间：/overlay 剩 111 MB
  [通过] 网络：本机 DNS 与国内站正常；海外站 api.anthropic.com 能访问，改动后也必须能访问
21:14:20 ABORT 安装包：包里缺 dnsmasq-remove.list，重新完整上传 adblock/（设备没被改动）
```

## 给同型号路由器安装：交给 AI 助手的提示词

把下面整段发给在目标局域网电脑上运行的 Claude Code、Codex 等助手，`<路由器IP>` 换成实际地址：

```text
帮我给一台 Banana Pi BPI-R3 Mini 软路由（ImmortalWrt + OpenClash）装「广告过滤」。路由器地址 <路由器IP>，SSH 用户 root。

材料：公开仓库 https://github.com/xiaohonghua661/Banana-Pi-R3-Mini-Toolkit 里的 adblock/ 目录。
- 拉取：git clone --depth 1 -b agent/adblock https://github.com/xiaohonghua661/Banana-Pi-R3-Mini-Toolkit.git r3mini-toolkit（如果仓库 main 分支里已经有 adblock/，用 main 也行）。没有 git 就下载 https://github.com/xiaohonghua661/Banana-Pi-R3-Mini-Toolkit/archive/refs/heads/agent/adblock.zip 解压。GitHub 打不开就停下来让我把 adblock 文件夹发给你。
- 只读 adblock/README.md 和 adblock/ 下的文件，严格按 README 操作，命令在仓库根目录执行。仓库根目录的 AGENTS.md、docs/ 写的是原作者自己的设备（例如 192.168.0.242）和他的协作工具 dd，跟这台路由器无关，不要照着做。

规矩：
- 不要替我输入路由器密码。按 README「连接路由器」生成 SSH 密钥，把公钥给我，我自己贴进 LuCI「系统 → 管理权 → SSH 密钥」；之后你用密钥登录，ssh 加 -o StrictHostKeyChecking=accept-new。用不了密钥就把每条命令给我，我执行后把输出贴回来。
- README 里标「需同意」的处置（重启 OpenClash、改 OpenClash 开关、装包、升级），先跟我说清影响，等我同意再做。不要为了让安装通过去改 OpenClash 的其它配置。

按顺序做，每一步把关键输出贴给我：
1. 按 README「安装」第 1 步把 adblock/ 传到路由器 /tmp/r3mini-adblock-pkg。
2. 跑只读预检 sh /tmp/r3mini-adblock-pkg/install.sh check，把每一项结果解释给我听。[不通过] 按 README「失败处置」的预检表处理（需同意的先问我）；[提醒] 告诉我影响，由我决定要不要处理。处理后重跑预检，直到末行是 CHECK_OK。
3. 跑只读预演 sh /tmp/r3mini-adblock-pkg/install.sh dry-run。「== install:」那行必须以 awk_rc=0 开头，后面和末行「期望 install 核对结果」之后的内容一字不差；不一致就停下给我看。
4. 告诉我安装时 OpenClash 会重启一次、经这台路由器上网的设备断网约半分钟，等我同意后按 README「安装」第 4 步后台安装，记下它打印的路由器时间。之后按第 5 步每 5 秒看一次日志首行和末行，最多看 20 分钟，判断结束和异常；末行的处置按 README「失败处置」；末行是 ROLLED_BACK_BUT_UNHEALTHY 就停下交给我。
5. 按 README「验收」第 1–3 步验收：status 字段、页面我自己在浏览器里看、拦截探针（先确认你所在电脑的默认网关就是这台路由器，不是就跳过并说明）。
6. 最后告诉我：日志末行的结论、备份目录、在页面上怎么开关和改更新时间、出问题时怎么立即关掉（r3mini-adblock disable）、怎么卸载。提醒我：手机和电脑要把网关和 DNS 都指向这台路由器，广告才会被过滤。
```
