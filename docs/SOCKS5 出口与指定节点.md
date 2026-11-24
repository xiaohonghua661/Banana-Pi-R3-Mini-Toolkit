---
name: SOCKS5-GATEWAY
description: 源机 192.168.0.242 的 SOCKS5 出口模块（第 3 版）：本模块自己的 Mihomo 提供带账号密码的 SOCKS5，出口可选 OpenClash 任意一个订阅里的节点，和 OpenClash 互不影响；「仅 IPv4」走 sing-box；出口地区按 Google、Cloudflare、Apple、ipinfo、MaxMind 五家检测。含结构、页面、命令、部署回滚与测试方法、实测数据、已知限制和全部 error_kind。
---

# SOCKS5 出口与指定节点

## 结构

```text
局域网设备 ─账号密码─▶ SOCKS5 内核 <端口，默认 7896>（入站 r3mini-socks5）→ 选择组 r3mini-socks5-mode
   ├─ r3mini-socks5-exit   出口选择组：所选订阅的全部节点 + DIRECT
   └─ r3mini-socks5-ipv4   回环 socks5 → sing-box 127.0.0.1:17896（「仅 IPv4」时选它）
        sing-box：经出口用 DoH(1.1.1.1) 查 A 记录；拒绝 IPv6、HTTP(80)、QUIC；TLS 记录分片
        → SOCKS5 内核 127.0.0.1:17897（入站 r3mini-socks5-up）→ r3mini-socks5-exit
SOCKS5 内核的控制接口：127.0.0.1:17898（随机密钥）
```

- **SOCKS5 内核**是本模块自己的 Mihomo 进程，用 OpenClash 的同一个二进制（`/etc/openclash/core/clash_meta`），配置由后端从所选订阅文件 `/etc/openclash/config/<订阅>.yaml` 生成。OpenClash 的运行配置里**没有**本模块的任何条目：OpenClash 换配置、重启、更新订阅都不会把 SOCKS5 弄断；SOCKS5 换节点、换订阅、改端口密码也不会让其他设备断线。
- 换节点：对 SOCKS5 内核发一次 `PUT /proxies/r3mini-socks5-exit`，再断开它里面的全部连接（它只服务 SOCKS5）。
- 开关仅 IPv4：只切 `r3mini-socks5-mode`。sing-box 在启用期间常驻，所以开关是即时的。
- 换订阅、改端口：重新生成配置，热重载 SOCKS5 内核（进程不重启）。改账号密码：重启 SOCKS5 内核和 sing-box（两边的入站账号都要换）。
- 两个进程都以 `nogroup` 运行：OpenClash 的透明代理规则放行这个组，它们自己的出站不会被 OpenClash 再接管一次。解析节点服务器用的 DNS 取自 OpenClash 运行配置的 `dns.default-nameserver` 与 `dns.proxy-server-nameserver`，同样先查 `/etc/hosts`（实测 SOCKS5 内核连的是 `/etc/hosts` 受管段里钉住的入口 IP）。
- OpenClash 的覆写钩子仍会调用本模块：清掉候选配置里第 2 版残留的条目（只在命中时改写），并在订阅文件有更新时同步 SOCKS5 内核。钩子出错不阻断 OpenClash，错误写 `/tmp/r3mini-socks5/hook.log`。

### 仅 IPv4 为什么要绕开 OpenClash

两件事都在 2026-11-23 实测确认，缺一个就会漏出 IPv6：

1. **节点服务器按 TLS 的 SNI 重新解析目标，且优先 IPv6。** 只把数字 IPv4 交给节点不够，sing-box 必须对 ClientHello 做 TLS 记录分片，节点读不到 SNI 才会按给定的 IPv4 连接。
2. **OpenClash 内核是 `redir-host` 模式。** 局域网设备查过的域名，它记着 IP→域名映射，交给它的数字 IPv4 会被还原成域名，节点拿到域名又走 IPv6（第 2 版之前 Cloudflare 系网站因此看到 IPv6）。SOCKS5 内核不开 DNS 增强模式、不嗅探，没有这个问题。

### 订阅

- 可选的订阅就是 OpenClash 的配置文件（`/etc/openclash/config/*.yaml`），2026-11-24 源机上有 4 个：订阅 A、B 是同一家的，各 172 个节点（A 是 OpenClash 当前在用的），C、D 分别 56、70 个节点。只有 A、B 有伊拉克节点。订阅文件名、节点入口和出口地址只记在 `docs/私密/SOCKS5 实测记录.md`。
- 设置里记着 SOCKS5 用哪个订阅；第一次应用时自动定成 OpenClash 当前配置，此后固定，不跟着 OpenClash 切换。
- 节点清单直接读订阅文件，按文件大小和修改时间缓存在 `/tmp/r3mini-socks5/sub-*.cache`。OpenClash 更新了订阅文件后，`status` 报 `subscription.stale`，页面打开时会自动同步一次；OpenClash 重建配置时钩子也会同步。
- 订阅里「剩余流量」「到期时间」这类信息条目页面不列出来（后端照常返回）。
- 节点延迟：SOCKS5 内核自己测过的优先；所选订阅正是 OpenClash 在用的那个时，没测过的借用 OpenClash 最近一次测速。

## 页面

LuCI → 服务 → SOCKS5 出口。视图文件部署时改名带内容指纹（`r3mini-socks5-<10 位>.js`），浏览器不会用旧缓存。卡片用主题自带的 `.cbi-section`，标题不用 `h3`（argon 主题把所有 `h3` 画成白底面板）。

| 区域 | 内容 |
|---|---|
| 顶部 | 页面标题；状态（运行中 / 未生效 / 异常 / 已停用 / 读取失败）、连接地址、账号、UDP、所用订阅；异常时横幅给出原因：`NOT_APPLIED`、`STATE_MISMATCH`、`IPV4_SERVICE`、`CORE_FAILED` 带「修复」（等于 `apply`），`TARGET_MISSING`、`SUBSCRIPTION_MISSING` 带「重新选择出口」 |
| 当前出口 | 节点名、协议、延迟（可点测速）、所用订阅（OpenClash 也在用时加标记）；「更换节点」展开选择器 |
| 选择器 | 订阅切换（每个订阅一个按钮，标出 SOCKS5 在用的和 OpenClash 在用的）；搜索框、地区下拉（按节点数排序）、「全部测速」；节点列表打开时滚到当前节点。点节点名切换出口（看别的订阅时连订阅一起换过去）；点行右边的延迟（没测过显示「测速」）单独测这个节点，不切换。SOCKS5 在用的订阅由 SOCKS5 内核测，OpenClash 在用的订阅由 OpenClash 测，其余订阅要换过去才能测 |
| 仅 IPv4 出口 | 开关，即时生效 |
| 出口地区检测 | 五家并发检测，按地区归堆、标出少数派；漏出 IPv6、各家判定不一致、与节点名地区不符时提示；各家明细折叠。浏览器缓存 30 分钟，换出口或开关仅 IPv4 后自动重测 |
| 连接设置（折叠） | 端口（改完即检测占用）、监听地址、账号、密码（留空沿用，可随机生成）、UDP；保存、停用 |
| 怎么连 | 地址、端口、账号，一键复制 |

页面可见时每 20 秒刷新一次 `status`。

## 出口地区检测

`probe` 经本机 SOCKS5（带账号密码）同时访问下列地址，约 3–5 秒，全部失败时隔 1 秒重测一次：

| 检测 | 地址 | 取什么 | 影响谁 |
|---|---|---|---|
| Google | `redirector.gvt1.com/report_mapping` + `www.youtube.com` | 出口 IP、Google 节点名；YouTube 页面里的 `INNERTUBE_CONTEXT_GL` 地区 | YouTube、Google Play、Google 搜索 |
| Cloudflare | `www.cloudflare.com/cdn-cgi/trace` | `ip`、`loc`、机房 `colo` | 套了 Cloudflare 的网站（如 ChatGPT） |
| Apple | `gspe1-ssl.ls.apple.com/pep/gcc` | 两位地区码（不回 IP） | App Store、Apple ID |
| ipinfo | `ipinfo.io/json` | `ip`、`country`、`org`、`city` | 常用 IP 地址库 |
| MaxMind | `ifconfig.co/json` | `ip`、`country_iso`、`asn_org`、`city` | MaxMind 地址库（广告、风控常用） |

只用 HTTPS（仅 IPv4 拒绝 80 端口）。输出的 `checks[]` 每项是 `{id,name,note,ok,ip,family,region,detail}`，另保留 `google`、`cloudflare` 两个键。

## 命令

`/usr/sbin/r3mini-socks5 <命令>`，输出单行 JSON；失败为 `ok:false` + `error` + `message`，退出码 1。参数里的名字可写 `b64:<base64url>`。页面经 rpcd 调同一入口，权限见 `/usr/share/rpcd/acl.d/luci-app-r3mini-socks5.json`（读：`status targets check-port probe verify delay delay-all`；写：`use ipv4 save apply enable disable reset`）。

| 命令 | 作用 |
|---|---|
| `status` | 设置与运行态对照，约 1 秒；运行态异常也返回 `ok:true`，原因在 `error`。含 `subscription{file,name,exists,active,stale,nodes}`、`exit`、`core`、`shim`、`listener` |
| `targets [订阅]` | 某个订阅的节点清单（默认 SOCKS5 在用的那个）：`subscriptions[]`、`nodes[]{name,type,delay,alive}`、`current`；0.4–1.4 秒 |
| `use <节点> [订阅]` | 换节点；给了另一个订阅就连订阅一起换。返回 `status` 加 `closed`（断开的连接数） |
| `ipv4 on\|off` | 开关仅 IPv4 |
| `delay [节点] [订阅]` | 测一个节点的延迟，默认测当前出口。订阅是 SOCKS5 在用的由 SOCKS5 内核测（`by:"socks5"`），是 OpenClash 在用的由 OpenClash 测（`by:"openclash"`），其余返回 `DELAY_UNAVAILABLE` |
| `delay-all` | 让 SOCKS5 内核把当前订阅的节点全测一遍（并发，约 5 秒） |
| `probe` | 出口地区检测 |
| `verify` | 经 SOCKS5 取 `generate_204`；仅 IPv4 时还要求 Google 与 Cloudflare 都看到 IPv4 |
| `check-port <端口>` | `free/own/occupied/reserved/owner/protocols` |
| `save '<JSON>'` | 改设置并应用；字段 `port listen username password udp ipv4_only subscription target enabled`，省略即沿用；空密码表示沿用旧密码；请求体严格按 JSON 解析，上限 16 KB |
| `apply` / `enable` / `disable` | 按设置重新应用 / 启用 / 停用（停用会停掉两个进程、删掉生成的配置） |
| `reset` | 停掉进程、删除设置（设置文件损坏时的出路） |
| `hook <路径>` | 只给 OpenClash 覆写钩子用，恒 `ok:true` |
| `prepare` | 只给开机的 procd 服务用：按设置生成两份配置 |

`save` 的校验：端口 1–65535，且不在 OpenClash 的端口集合（`uci openclash.config.*_port`，读到少于 3 个时并入 `9090 7874 7890 7891 7892 7893 7895`）和本模块内部端口 17896–17898 里，也不能被别的程序占着；监听地址是 `0.0.0.0` 或本机 IPv4；账号 `[A-Za-z0-9._-]{1,64}`；密码 4–128 字符、不超过 128 字节、不含空白和冒号；订阅必须是 `/etc/openclash/config/` 下存在的 `.yaml`/`.yml`；换了订阅或出口时，出口必须在该订阅里。

## 文件、进程与端口

| 路径 | 作用 |
|---|---|
| `/usr/libexec/r3mini-socks5.rb` | 后端 |
| `/usr/sbin/r3mini-socks5` | CLI 入口；清掉 `R3MINI_SOCKS5_ROOT`、`RUBYOPT`、`RUBYLIB`，`umask 077` |
| `/etc/init.d/r3mini-socks5` | procd 服务，两个实例：`core`（SOCKS5 内核，`SAFE_PATHS` 限在自己目录）、`shim`（sing-box）。已 `enable`；设置里停用时不起进程 |
| `/etc/r3mini-socks5/settings.json` | 设置，`0600`，含明文密码 |
| `/etc/r3mini-socks5/backups/` | 改写 OpenClash 运行配置前的副本（只在清理第 2 版条目时产生），只留最近 5 份 |
| `/etc/r3mini-socks5/install-backup-<时间>/` | `manage.py install` 前的副本，不自动清理；旧的可以搬到电脑上加密保存后删掉，腾出闪存空间 |
| `/tmp/r3mini-socks5/core/config.yaml`、`meta.json`、`cache.db` | SOCKS5 内核配置（含节点凭据与入站账号，`0600`）、随机控制密钥与订阅摘要、选择记忆 |
| `/tmp/r3mini-socks5/ipv4.json` | sing-box 配置（只含回环上游和本模块账号） |
| `/tmp/r3mini-socks5/sub-*.cache` | 订阅解析缓存 |
| `/etc/openclash/custom/openclash_custom_overwrite.sh` | `# BEGIN R3MINI-SOCKS5` … `# END R3MINI-SOCKS5` 钩子块 |
| `/usr/share/luci/menu.d/luci-app-r3mini-socks5.json`、`/www/luci-static/resources/view/services/r3mini-socks5-<指纹>.js` | 菜单与页面 |

sing-box 用 `/usr/bin/sing-box`，没有就用 `/mnt/mmcblk0p6/r3mini-socks5/sing-box`（源机用后者，1.12.25）。内部端口 17896–17898 只监听 `127.0.0.1`，不在临时端口段 32768–60999 内。

## 部署、测试、回滚

前提：

- 电脑：Python 3 和 `paramiko`（页面检查另需 `playwright` 和它的 chromium）；路由器的 SSH 主机密钥已经在 `~/.ssh/known_hosts` 里（否则报 `PINNED_HOST_KEY_MISSING`，先经可信链路核对指纹再加）；登录用专用私钥，`--key <私钥>` 或环境变量 `R3MINI_SSH_KEY` 给出。
- 路由器：OpenClash 的 Mihomo 内核（`/etc/openclash/core/clash_meta`，没有就找 `/etc/openclash/core/mihomo`）、带 yaml 和 digest 的 Ruby、curl。「仅 IPv4」还要 sing-box：源机用 1.12.25 验证过，换别的版本先用 `sing-box check -c /tmp/r3mini-socks5/ipv4.json` 检查后端生成的配置。
- 动设备前按工程的协作规则声明占用路由器，做完释放，避免和别的任务同时改。

在工作区根目录、Git Bash 下执行（`MSYS_NO_PATHCONV=1` 防止 `/etc/...` 参数被改写成 Windows 路径）。

```bash
MSYS_NO_PATHCONV=1 python socks5-gateway/manage.py install 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
MSYS_NO_PATHCONV=1 python socks5-gateway/manage.py verify 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
MSYS_NO_PATHCONV=1 python socks5-gateway/manage.py rollback 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242 --backup /etc/r3mini-socks5/install-backup-<时间>
```

- `install`：建 `install-backup-<时间>` 并打印 `BACKUP_DIR=/etc/r3mini-socks5/install-backup-<时间>`（回滚时把它传给 `--backup`；路由器上 `ls /etc/r3mini-socks5/` 也能看到）；上传文件；停掉并取消自启第 2 版的 `/etc/init.d/r3mini-socks5-v4`，删掉旧版遗留文件；写钩子块；启用 `/etc/init.d/r3mini-socks5`；设置为启用时跑一次 `apply`。从第 2 版升级时，`apply` 会清掉 OpenClash 运行配置里第 2 版的条目并让 OpenClash 重载一次（全屋连接断一下），把端口让给 SOCKS5 内核；之后不再碰 OpenClash。成功打印 `INSTALL_OK ...`。
- `verify`：核对文件哈希与权限、钩子块、服务自启、`status` 无错误、`targets` 结构，成功打印 `VERIFY_OK ... subscription=<订阅> nodes=<节点数>`。
- `rollback`：停掉并取消自启第 3 版服务，按备份恢复本模块文件、设置和旧服务的自启状态。覆写脚本和 OpenClash 运行配置是几个模块共用的，**不整份覆盖**：覆写脚本只把本模块那一段换回备份里的样子（备份里没有就删掉），其他模块之后的改动原样保留；运行配置交给恢复出来的那一版自己的钩子去改，钩子改了才重载 OpenClash。备份里的 `runtime.yaml`、`overwrite.sh` 只留作手工恢复。成功打印 `ROLLBACK_OK ... hook_block=kept|removed openclash_reload=<HTTP 码>|skipped`。

**测试环境必须是实机环境**：数据要用设备上的真实订阅，页面要在真实 LuCI 主题里看。

下面的 `$R3` 指用专用密钥登录源机执行命令：`R3="ssh -i docs/私密/r3mini-242/id_ed25519_242 -o IdentitiesOnly=yes root@192.168.0.242"`（Git Bash 下先 `export MSYS_NO_PATHCONV=1`）。

后端集成测试（在路由器上起隔离沙箱：复制真实订阅文件；临时「OpenClash」带着第 2 版条目测清理迁移；公开端口 27896、内部端口平移到 27906–27908；约 3 分钟）：

```bash
$R3 'mkdir -p /tmp/r3s5-src && cat > /tmp/r3s5-src/r3mini-socks5.rb' < socks5-gateway/router/usr/libexec/r3mini-socks5.rb
$R3 'cat > /tmp/r3s5-src/test_integration.sh' < socks5-gateway/test_integration.sh
$R3 "cd /tmp/r3s5-src && BACKEND=/tmp/r3s5-src/r3mini-socks5.rb NODE='🇮🇶 伊拉克' PIN=<测通的入口 IPv4> sh test_integration.sh"
```

`PIN` 把沙箱订阅副本里测试节点的入口改成一个测通的 IPv4，可省略（源机用的值见私密记录）；`SUB` 默认是 OpenClash 当前配置，`OTHER` 默认是另一个订阅文件，都可以用文件名覆盖。

页面检查（在真实 LuCI 里看改版：经密钥 SSH 临时签一个 LuCI 会话，不输入密码，用完销毁）：

```bash
$R3 'mkdir -p /tmp/r3s5-src && cat > /tmp/r3s5-src/r3mini-socks5.rb' < socks5-gateway/router/usr/libexec/r3mini-socks5.rb
$R3 'cat > /tmp/r3s5-src/ui_sandbox.sh' < socks5-gateway/ui_sandbox.sh
$R3 "sh /tmp/r3s5-src/ui_sandbox.sh up /tmp/r3s5-src/r3mini-socks5.rb '🇮🇶 伊拉克'"
python socks5-gateway/ui_check.py --view socks5-gateway/router/www/luci-static/resources/view/services/r3mini-socks5.js --sandbox --steps load,picker,sub,probe,mobile,dark
$R3 'sh /tmp/r3s5-src/ui_sandbox.sh down'
```

页面检查要求路由器上已经装好本模块（菜单和权限文件在位，`ui_check.py` 只替换视图和后端调用）。沙箱用真实订阅和真实 DNS 设置，SOCKS5 内核开在 127.0.0.1:27886（内部端口平移 +10020），不碰正式实例。`ui_check.py` 不带 `--sandbox` 时调正式后端，只放行只读命令；截图写到 `tmp/socks5-exit/shots/<时间>/`。需要 `paramiko` 和 `playwright`（chromium）。

## 实测数据

2026-11-24 00:35，源机（ImmortalWrt 24.10.6，Mihomo Meta alpha-gbc76c13，sing-box 1.12.25），订阅为 OpenClash 当前在用的订阅 A，出口「🇵🇰 巴基斯坦」，仅 IPv4 开启（出口地址等原始输出见私密记录）：

```text
install   INSTALL_OK enabled=true applied=true ipv4_only=true exit=🇵🇰 巴基斯坦 error=None
verify    VERIFY_OK enabled=true applied=true ipv4_only=true exit=🇵🇰 巴基斯坦 nodes=172
监听      :::7896 与 127.0.0.1:17897/17898 归 SOCKS5 内核（clash_meta，gid 65534）；127.0.0.1:17896 归 sing-box；
          OpenClash 内核只剩自己的端口；它的运行配置里本模块条目 0 行
内存      SOCKS5 内核约 66 MB（172 个节点），sing-box 约 34 MB，OpenClash 内核约 250 MB
status 0.98 秒；targets：4 个订阅 0.44–1.37 秒（当前订阅 172 个节点，167 个借用 OpenClash 的延迟）
probe（先在路由器上 nslookup 这些域名，让 OpenClash 记下映射）4.1 秒：
  google     PK  <出口 IPv4> IPv4
  cloudflare PK  <出口 IPv4> IPv4
  apple      PK
  ipinfo     PK  <出口 IPv4> IPv4
  maxmind    PK  <出口 IPv4> IPv4
verify    {"ok":true,"http_code":204,...}，Google 与 Cloudflare 看到同一个 IPv4
开机路径  停服务、删掉配置后 start，6.8 秒恢复 applied
局域网    这台电脑经 192.168.0.242:7896：cdn-cgi/trace loc=PK；ipinfo country=PK；错误密码 curl 退出码 97
```

集成测试 54 项全过（输出留在本机 `tmp/socks5-exit/`）：apply（含清理迁移与 OpenClash 重载）4.8 秒；开仅 IPv4 1.1 秒、换节点 1.1 秒，都不重启进程；换到另一个订阅 2.2–2.7 秒（热重载）；全部测速 5.3 秒（172 个节点 165 个有响应）；改端口 2.4 秒（热重载，旧端口释放）；改密码 6.0 秒（重启，旧密码被拒）；订阅文件更新后 `stale` 置位、钩子同步后清零；钩子清理第 2 版条目且幂等。

伊拉克节点（仅 IPv4）11-23 实测：五家看到同一个 IPv4，Google 判 GB，其余四家判 IQ。

## 已知限制

1. **Google 把伊拉克节点判成英国**：IPv4 和 IPv6 两条出口 Google 都判 GB。RIPE 登记里这个 IPv4 段的国家是 IQ、IPv6 段是 GB（段名与地址见私密记录）。IPv6 判英国有登记依据，IPv4 判英国是 Google 自己的库没跟上，路由器这边改不了。能走的路：本人登录 Google 在「Report IP problems」（`https://support.google.com/websearch/workflow/9308722`）报这个 IPv4 所在的 /24 应为伊拉克（Google 说更新可能超过一个月；要填的内容见私密记录）；或请节点商经 Google ISP Portal 提交 geofeed。巴基斯坦节点五家都判 PK。
2. **仅 IPv4 下的代价**：普通 HTTP、QUIC（HTTP/3）、只有 IPv6 的网站打不开；浏览器会自动改用 HTTPS/TCP。
3. **出口只能是节点或 DIRECT**：订阅里的策略组不放进 SOCKS5 内核（第 3 版起），要换节点就在页面里选。
4. **节点入口域名的 DNS 答案不稳定**：节点商的入口域名按运营商线路和时间给不同答案，部分 IP 从家里连不上。另一个模块在 `/etc/hosts` 里维护了受管段，把入口钉到测通的 IP；SOCKS5 内核同样先查 `/etc/hosts`。
5. SOCKS5 内核常驻约 66 MB、sing-box 约 34 MB 内存，只在启用期间运行。
6. 改账号密码会重启 SOCKS5 内核，正在用 SOCKS5 的连接断开一下；改端口、换订阅只热重载。
7. 订阅更新后要等页面打开或 OpenClash 重建配置才同步；同步前 SOCKS5 仍用旧的节点信息。

## error_kind

| error | message | 处置 |
|---|---|---|
| `ARGUMENT_INVALID` | 命令参数无效，请刷新页面后重试。 | 参数个数、类型不对或请求体超 16 KB |
| `BUSY` | 另一个操作正在进行，请稍后再试。 | 写命令互斥（`/var/lock/r3mini-socks5.lock`）；钩子会等锁 |
| `SETTINGS_INVALID` | 本模块设置文件损坏；执行 r3mini-socks5 reset 清掉后重新保存。 | 跑 `reset` 后重新保存 |
| `DISABLED` | SOCKS5 出口已停用，请先启用。 | 先启用 |
| `NOT_APPLIED` | SOCKS5 没有按当前设置运行，请点「修复」。 | SOCKS5 内核没在跑或入站没起来；`apply` |
| `PORT_INVALID` | 端口必须为 1–65535 的整数。 | |
| `PORT_RESERVED` | 此端口被 OpenClash 或本模块内部占用，请换一个端口。 | 换端口 |
| `PORT_IN_USE` | 此端口已被其他程序监听，请换一个端口。 | 先 `check-port` 看占用者 |
| `LISTEN_INVALID` | 监听地址无效，只能选择全部网卡、仅本机或本机现有地址。 | |
| `USERNAME_INVALID` | 账号只能使用字母、数字与 . _ -，长度 1–64。 | |
| `PASSWORD_INVALID` | 密码需 4–128 个字符且不超过 128 字节，不能含空白或冒号。 | 用「随机生成」 |
| `PASSWORD_REQUIRED` | 启用前必须设置密码。 | |
| `TARGET_INVALID` | 出口名称无效。 | 含控制字符或超长 |
| `TARGET_MISSING` | 选中的节点在这个订阅里已经没有了，请重新选择。 | 订阅更新删了它；此时出口组第一个是 REJECT，宁可不通也不换国家 |
| `SUBSCRIPTION_MISSING` | 所选订阅的配置文件不在了，请重新选择订阅。 | OpenClash 里删了这个配置；在页面里换订阅 |
| `SUBSCRIPTION_INVALID` | 这个订阅的配置文件读不出节点。 | 文件损坏或只用 `proxy-providers`；换订阅 |
| `RUNTIME_MISSING` | 未找到当前 OpenClash 运行配置。 | 只影响钩子与清理第 2 版条目；查 `uci get openclash.config.config_path` |
| `RUNTIME_INVALID` | 当前 OpenClash 运行配置无效。 | 同上 |
| `CONTROLLER_INVALID` | 当前 OpenClash 配置没有可用的本机控制接口。 | 只影响清理第 2 版条目与借用 OpenClash 测速 |
| `CONTROLLER_UNAVAILABLE` | 无法读取 OpenClash 控制接口，请确认 OpenClash 正在运行。 | 同上 |
| `CORE_MISSING` | 没有找到 Mihomo 内核文件（/etc/openclash/core/clash_meta）。 | OpenClash 内核文件缺失 |
| `CORE_FAILED` | SOCKS5 内核没有启动或没有接受新配置。 | 12 秒内入站没起来。内核输出不进 `logread`；手动检查配置：`SAFE_PATHS=/tmp/r3mini-socks5/core /etc/openclash/core/clash_meta -t -d /tmp/r3mini-socks5/core -f /tmp/r3mini-socks5/core/config.yaml`，改好后 `apply` |
| `SWITCH_FAILED` | SOCKS5 内核没有接受这次切换，请重试。 | |
| `RELOAD_FAILED` | OpenClash 没有接受清理后的配置，已恢复原配置。 | 只在从第 2 版升级时出现 |
| `SHIM_MISSING` | 没有找到 sing-box，无法开启仅 IPv4。 | |
| `IPV4_SERVICE` | 仅 IPv4 转发进程没有运行，请点「修复」。 | sing-box 没在跑；`sing-box check -c /tmp/r3mini-socks5/ipv4.json` 看配置，再 `apply` |
| `PROBE_TOOL_MISSING` | 探测工具 curl 不可用。 | |
| `PROBE_FAILED` | 经 SOCKS5 访问测试网站失败：出口节点不通或账号密码被拒。 | 换节点或测速 |
| `DELAY_FAILED` | 节点测速失败或超时。 | |
| `DELAY_UNAVAILABLE` | 这个订阅现在没有内核在跑，换到它之后才能测速。 | 既不是 SOCKS5 在用的、也不是 OpenClash 在用的订阅 |
| `STATE_MISMATCH` | 运行状态与保存的设置不一致，请点「修复」。 | 例如内核配置不是按当前设置生成的；`apply` |
| `IO_FAILED` | 读取或保存失败，改前备份已保留。 | 查 overlay 空间 |
| `INTERNAL_ERROR` | 操作失败，未输出任何凭据。 | 设 `R3MINI_SOCKS5_DEBUG=1` 用 `ruby /usr/libexec/r3mini-socks5.rb` 重跑看栈 |
