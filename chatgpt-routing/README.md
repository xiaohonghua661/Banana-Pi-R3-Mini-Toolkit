LuCI「服务 → 网站分流」给指定网站单独选一个出口节点。每条规则是一组域名加「订阅 + 节点」，以卡片列出，可换节点、编辑、启停、删除；另有 ChatGPT 预设，已有预设规则时不再显示该按钮。首次安装为空且保持关闭；保存启用的规则才改变运行分流。「恢复原分流」先弹确认，写明会停用几条规则、要关闭哪几个直连开关；执行后停用所有规则（定义保留）、关闭 Steam 和 UU 远程直连，并移除本模块的专属节点、组和规则，模块继续保留在菜单中，其他规则保留。删除规则同样先确认。

页面标题按 LuCI 的标准写法单独成行（argon 把它画成压在蓝色页头上的标题卡），状态、「OpenClash 当前配置」和「立即刷新」放在标题下面；LuCI 页头自带的「刷新」是轮询开关，本页按钮因此叫「立即刷新」。OpenClash 挂了几个订阅、会换当前配置：添加网站时默认用 OpenClash 当前配置，订阅下拉和规则卡片都标出它。地区筛选按节点数取前 8 个做按钮，其余进「其他 N 个地区」下拉（MESL 订阅有 91 个地区），地区名由浏览器给出中文名。

页面打开时和之后每 30 秒读一次轻量的 `summary`：不解析订阅、不启动测速助手，2026-11-23 在设备上实测 0.7 秒、约 0.7 KB（旧版每 10 秒读一次 `status`，5.7 秒、112 KB）。标签页在后台或弹窗打开时不读。「换节点」「编辑」「添加网站」都在 LuCI 弹窗里完成，底栏「取消」在前，按 Esc 即取消。节点选择器打开时读一次 `nodes`：可搜索名称、地区或类型，按节点名开头的国旗或地名分出地区，点一下筛选；测过且通过的按三轮中位延迟排前，未测速的其次，未通过的折叠。「测速这 N 个」只测当前筛出的节点（超过 64 个时改为全部测速），测速进行时每 3 秒刷新一次，结果逐行出现，测完即停；关掉弹窗测速照常进行。「选最快」在筛出且已有结果的节点里挑。未测速或测速未通过的节点也能保存，规则标为「未验证」。名称可不填，默认用第一个域名。保存、启停、删除直接用命令返回的状态确认，不再额外读一次，提示里带用时。

页面顶部的「Steam 直连」开关让 Steam 联机（Valve 服务器和中继 IP）、登录接口和下载走直连，不经过代理节点；商店和社区网页不变。开启后运行 YAML 的 `rules:` 最前面是 23 条连续的 DIRECT 规则：`DOMAIN-SUFFIX,steamserver.net`、`DOMAIN-SUFFIX,steamcontent.com`、`DOMAIN,api.steampowered.com`，再加 Valve AS32590 的 20 个 IPv4 网段（`IP-CIDR,网段,DIRECT,no-resolve`，取自 2026-11-12 的 RIPEstat 公告前缀并合并相邻段，列表在后端常量 `STEAM_PREFIXES`）；网站规则排在它们后面。开关状态存为 `settings.json` 的 `steam_direct`，OpenClash 重启或订阅更新后由覆写钩子重新加入。切换时先确认控制接口在线，再备份、经控制接口重载（Mihomo 解析失败时控制接口返回 400 并继续运行原配置）并回读核验，任一步失败都恢复原文件和设置。只切换直连块不重建网站规则，所以某条网站规则等待重新测速时开关照常可用。关闭时只删除位于最顶部且完整的这一组；用户配置里的同类规则，即使是顶部以外的完整副本，也一律保留。开启后若顶部这组缺失或残缺，页面显示「开启了但配置里没找到——重新打开一次」，开关显示为关；再打开一次会在顶部补回完整的一组，残缺的旧行保留不删。开启要求 OpenClash 处于规则模式（否则报 `ROUTING_MODE_UNSUPPORTED`），控制接口离线时报 `CONTROLLER_UNAVAILABLE`，两者都不写任何文件。

「UU 远程直连」开关在 Steam 下面，做法相同：让网易 UU 远程的账号接口、信令与中继、公网地址探测和文件传输走直连。开启后运行 YAML 的 `rules:` 最前面（Steam 组之后）是 6 条 DIRECT 规则：`DOMAIN-SUFFIX,uu.163.com`、`DOMAIN-SUFFIX,uuyc.163.com`、`DOMAIN-SUFFIX,nrd.nie.163.com`、`DOMAIN-SUFFIX,nie.netease.com`、`DOMAIN-SUFFIX,fp.ps.netease.com`、`DOMAIN,uuyc.webapp.163.com`（后端常量 `UU_RULES`）。这些域名取自 2026-11-27 一次真实 UU 远程会话期间树莓派旁路由 AdGuard Home 的查询记录。点对点画面直接连对方的国内 IP，由订阅的 `GEOIP,CN` 直连，不需要单独规则。要它的原因：`MESL` 系订阅里有 `163.com`、`netease.com` 的 DIRECT 规则，`LinuxDO1/2` 这类订阅没有，切到后者时 UU 远程会落到 `MATCH` 走节点；这组规则排在最前，不管用哪个订阅都直连。状态存为 `settings.json` 的 `uu_direct`，两个开关互不影响：关掉一个只删它自己那组，另一组原样留在顶部。

测速对每个节点起一个隔离核心，发起三轮新的 HTTPS 连接，记录三次首字节时间及中位数。ChatGPT 预设测 chatgpt.com：读取真实出口地区，要求三轮地区一致且在模块采用的 ChatGPT 支持地区清单内，并验证 OpenAI API 可达；地区来自实际请求，不依赖节点名称中的国家标签；内置地区清单是已核验的保守子集，测速结果同时返回官方来源和核验日期。其他网站测网站自己：经节点向 `https://第一个域名/` 发三次 HEAD，有 HTTP 应答即算可达，不判断地区。结果按「订阅 + 测速目标」分开保存。

测速异步执行，进度在 `/tmp/r3mini-site-bench/`；每轮结束把结果写一份到 `/etc/r3mini-chatgpt/bench/`，路由器重启后仍在，超过 7 天显示为过期。只测部分节点时，其余节点的结果保留。测速不切换生产节点。隔离核心使用设备的 `nogroup` 组（当前 GID 65534），使出站连接避开生产 OpenClash 的 OUTPUT 重捕获。保存规则时把节点内容 SHA-256、三轮结果、地区和中位数作为证明持久保存到该规则的 `node_validation`；同一节点参数未变时可跨测速缓存过期或设备重启继续使用。节点参数改变需重测；新鲜完成且失败的复测会撤销旧证明，不能继续沿用旧成功结果。

在 Windows 项目根目录使用 Python 3.10+、`paramiko` 和 `pywin32`。设备需有 OpenClash、Ruby 的 `yaml`/`digest/sha2`、curl。先在 `~/.ssh/known_hosts` 固定设备密钥；管理脚本拒绝未知或变化的主机密钥，连接时才在内存中解析本机 `docs/私密/商家交付信息.md` 的反引号候选密码，不打印凭据。

加 `--key KEY_PATH`（或设环境变量 `R3MINI_SSH_KEY`，两者都给时以 `--key` 为准）后，`backup`、`install`、`verify`、`rollback` 都只用这个私钥以 root 登录：不读取商家交付信息，不尝试密码、ssh-agent 或 `~/.ssh` 里的默认密钥，主机密钥固定检查照旧。私钥须是无口令的 OpenSSH 私钥文件；相对路径按当前目录解析。`check-backup` 不连接设备，不使用私钥。

用实际目标替换示例中的 `HOST_A`、`HOST_B`；没有默认设备。命令可批量处理显式目标：

```powershell
python chatgpt-routing/manage.py backup HOST_A HOST_B
python chatgpt-routing/manage.py check-backup HOST_A HOST_B
python chatgpt-routing/manage.py install HOST_A HOST_B
python chatgpt-routing/manage.py verify HOST_A HOST_B
python chatgpt-routing/manage.py rollback HOST_A HOST_B
python chatgpt-routing/manage.py verify HOST_A --key KEY_PATH
```

`--host` 可重复使用。`install` 默认先做即时备份，也可用 `--backup <本机归档路径>` 指定两小时内且仍与设备逐项一致的备份；该参数只接受一个目标。`rollback --backup <归档路径>` 恢复指定恢复点，不指定时使用该目标最新的本模块备份。备份本身可用 `check-backup <归档路径>` 离线核验。

备份位于 `backups/router/*-before-chatgpt.tar.gz.dpapi` 和同名 `.manifest.json`。归档包含完整 `/etc`、OpenClash 程序、包清单和已有 r3mini/AdsPower 程序及 LuCI 文件。清单使用 JSON 信封，身份、快照、服务状态和运行配置路径存入 DPAPI 加密载荷；同一 Windows 用户在同一机器解密。保存后立即解密验哈希，并在临时目录模拟改动和恢复，输出 `BACKUP_OK`、`BACKUP_CHECK_OK`、`SCOPED_RESTORE_DRILL_OK`。Windows 演练验证文件字节和存在状态，POSIX 权限及链接使用 tar 元数据核对；不代表磁盘整机恢复或硬件冷启动验收。

安装通过 SSH 标准输入原子上传文件，核对 SHA-256，保留已有 OpenClash overwrite 钩子的其他原字节，把 `BEGIN/END R3MINI-CHATGPT` 块放在最后的 `exit 0` 前。只清理已知 LuCI 缓存并 reload rpcd；不重启 OpenClash。失败时按该次备份定向恢复。`verify` 检查文件权限/哈希、实时专属规则状态、Steam 与 UU 远程直连开关和运行 YAML 是否一致、LuCI 静态页、菜单树、ACL（含 `summary`、`nodes`、两条 `steam-direct` 和两条 `uu-direct` 命令，并用只有本模块授权的会话经 rpcd 实际执行一次 `summary`）和原有核心/服务，成功时输出 `VERIFY_OK files=6 enabled=… steam_direct=… uu_direct=…`。

`rollback` 是返回指定恢复点：先制作当前状态的 DPAPI 检查点，确保操作可撤回，再恢复本模块六个程序/页面文件（含测速助手）、`/etc/r3mini-chatgpt/`、overwrite 钩子和备份时的运行 YAML，移除原来不存在的受管件。恢复点在首次安装前时，结果是卸载模块；恢复点已有旧版模块时，结果是回到旧版。页面的「恢复原分流」只停用规则并关闭 Steam 直连。恢复器从本地包在内存加载校验所需后端与助手，卸载后无需把模块写回设备。

整份运行 YAML/钩子回放前，脚本比较当前与备份的非本模块 YAML 语义和去专属块后的钩子原字节。订阅更新、DNS 或其他钩子发生变化时，以 `ROLLBACK_NONMODULE_RUNTIME_CONFLICT` 或 `ROLLBACK_NONMODULE_HOOK_CONFLICT` 在写入前阻断；不覆盖这些新变化。允许恢复时先停用本模块，再通过原 controller 平滑 reload；核对恢复范围的哈希、权限和存在状态，要求范围外的当前快照不变。完整归档中的其他配置不会被写回。回滚新建的检查点也会成为最新恢复点；重复操作时用 `--backup` 明确目标。

设备接口：

```sh
/usr/sbin/r3mini-chatgpt summary
/usr/sbin/r3mini-chatgpt nodes source.yaml [chatgpt|site:example.com]
/usr/sbin/r3mini-chatgpt status [source.yaml]
/usr/sbin/r3mini-chatgpt benchmark source.yaml [chatgpt|site:example.com] [NODE_SHA16 ...]
/usr/sbin/r3mini-chatgpt benchmark-status source.yaml [chatgpt|site:example.com]
/usr/sbin/r3mini-chatgpt apply source.yaml NODE_SHA16
/usr/sbin/r3mini-chatgpt save RULE_JSON
/usr/sbin/r3mini-chatgpt set-enabled RULE_ID 0
/usr/sbin/r3mini-chatgpt remove RULE_ID
/usr/sbin/r3mini-chatgpt disable
/usr/sbin/r3mini-chatgpt steam-direct 1
/usr/sbin/r3mini-chatgpt steam-direct 0
/usr/sbin/r3mini-chatgpt uu-direct 1
/usr/sbin/r3mini-chatgpt uu-direct 0
```

`summary` 是页面用的状态：`enabled`、`applied`、`error`、`pending_restart`、`steam_direct`、`uu_direct`、`sources`、`active_source`（OpenClash 当前配置，读不到或不在订阅目录里时为 null），`rules` 每条另带 `applied`、`error`、`verified`、`unverified`、`median_ms`、`tested_at`。`nodes` 返回一个订阅对一个测速目标的节点行和测速进度，目标缺省为 `chatgpt`。`benchmark` 的目标同样缺省为 `chatgpt`，带节点令牌时只测这些节点（最多 64 个）。修改类命令（`save`、`set-enabled`、`remove`、`disable`、`steam-direct`、`uu-direct`）返回与 `summary` 相同的字段，另加 `site_rules`、`id`、`reloaded`（这次有没有热重载）和 `elapsed_ms`；生成的运行配置没变化时（只改名称、删除已停用的规则、原样再保存）只写设置文件，不重载。

`status` 的输出格式保持不变，供 gpt-night 和 `manage.py verify` 使用：顶层 `enabled` 表示是否有启用的规则，`applied` 是运行规则/节点的实际核验结果，`site_rules` 提供每条规则的状态，`steam_direct` 是 `{"enabled": 布尔, "applied": 布尔}`：`enabled` 为保存的开关，`applied` 表示运行 YAML 的 `rules:` 最前面有完整的 Steam 规则组；`uu_direct` 格式相同，`applied` 表示 UU 规则组紧接在顶部（Steam 组之后）。`benchmark` 启动异步实测，`benchmark-status` 读取进度、每节点结果和 `best` 推荐令牌。节点令牌由页面读取，不能用节点名代替。`save` 接收页面生成的规则 JSON；`set-enabled` 的末项可为 `0`/`1`，`remove` 删除单条规则，`disable` 全部停用并关闭 Steam 和 UU 远程直连；`steam-direct 1`/`0`、`uu-direct 1`/`0` 分别开关 Steam 和 UU 远程直连，重复执行时若设置、文件和实时规则都已一致，就不备份、不写文件、不重载；其他参数报 `ARGUMENT_INVALID`；`apply` 保留旧 ChatGPT 预设接口。订阅仅接受 `/etc/openclash/config/` 下普通 YAML 文件。`hook RUNTIME_YAML` 仅供 OpenClash 覆写钩子内部调用，LuCI ACL 不授权它；ACL 对直连开关只授权 `steam-direct 0`、`steam-direct 1`、`uu-direct 0`、`uu-direct 1` 四条完整命令。

后端是 `/usr/libexec/r3mini-chatgpt.rb`，测速助手是 `/usr/libexec/r3mini-site-bench.rb`，状态是 `/etc/r3mini-chatgpt/settings.json`。事务备份在内存盘 `/tmp/r3mini-chatgpt/backups/`，只留最近 5 份：它们只在重载核验完成前有用，以前存在闪存上，2026-11-23 已积到 85 份、37 MB。节点索引缓存在 `/tmp/r3mini-chatgpt/index-*.json`，订阅文件的 SHA-256 一变就重建。LuCI 菜单与 ACL 分别是 `/usr/share/luci/menu.d/luci-app-r3mini-chatgpt.json`、`/usr/share/rpcd/acl.d/luci-app-r3mini-chatgpt.json`，页面是 `/www/luci-static/resources/view/services/r3mini-chatgpt.js`。运行 YAML 优先从 `openclash.@overwrite[0].config_path`（兼容命名 section `overwrite`），否则从 `openclash.config.config_path` 的文件名推导到 `/etc/openclash/`。

离线测试：

```powershell
python chatgpt-routing/test_manage.py
python chatgpt-routing/test_backend.py --key KEY_PATH
node chatgpt-routing/test_luci_view.js
python chatgpt-routing/test_real_page.py --key KEY_PATH --candidate
```

`test_manage.py` 是部署器测试，其中 2 项需要 WSL。`test_backend.py` 把后端、测速助手和 `test_router_suite.rb`（73 项）传到设备 `/tmp` 下的新目录，用设备自带的 Ruby 运行，跑完删除；每项用例都把 `R3MINI_CHATGPT_ROOT` 指到自己的沙箱，配假 curl、假 Mihomo 内核和假 uci，不读写正式文件，约 4 分钟、一个 CPU 核。`-k 关键字` 只跑名字含该关键字的用例，`test_benchmark.py` 只跑测速助手部分。`test_luci_view.js`（45 项）在 Node 里执行页面源码；其中的大订阅用例按设备上 MESL 的实际规模造数据（172 个节点、91 个地区）。

页面验收只认 `test_real_page.py`：它打开设备上真实的 LuCI 页面，用的是 argon 主题和它的蓝色页头、LuCI 自己的弹窗，以及设备上全部订阅的真实节点名和数量；`--candidate` 把本地的页面脚本换进去，用于安装前验收，不加则验收已安装的页面。浏览器里会拦掉所有写命令，走查只读：打开弹窗、逐个切换订阅、从下拉里选地区、取消两个确认框。它在 320、375、768、1280 宽度、暗色、文字放大到 200% 下截图，检查溢出、脚本错误、状态行有没有压在页头上，截图放 `tmp/site-routing/realpage-<时间>/`。LuCI 会话经密钥 SSH 按 rpcd 给 root 的授权建立，不输入密码，结束后销毁。`test_luci_preview.html?mode=…` 用自编数据和模拟弹窗，只供开发时看交互，不能当验收：2026-11-23 它排得好看的地区按钮，换成设备上 91 个地区的订阅就是一整墙；它也没有 argon 的蓝色页头，标题旁的状态和按钮装上设备后压在了页头上。

所有失败输出为 `OPERATION_FAILED kind=TOKEN`；先处理对应原因再重跑。`PINNED_HOST_KEY_MISSING` 需核验并固定密钥，`SSH_KEY_MISSING` 表示私钥路径不是文件，`SSH_KEY_INVALID` 表示无法作为无口令私钥读取，`SSH_KEY_LOGIN_FAILED` 表示设备拒绝该私钥（需确认设备已登记对应公钥），这三种都不会改用密码重试；`BACKUP_NO_LONGER_MATCHES_PRODUCTION` 需重新备份，`BACKUP_IDENTITY_MISMATCH`/`BACKUP_RUNTIME_CHANGED` 需核对目标和恢复点，`INSTALL_FAILED_AND_ROLLBACK_FAILED` 需保留恢复点并检查设备当前状态。安装、真实网络分流与硬件启动的验收以实际执行记录为准。

2026-10-25 实机验收：刷新 `lian_li.yaml` 后对 56 个条目完成三轮测试，36 个通过。最低延迟节点为「新加坡高速05」，真实出口 SG，三次首字节时间 306.549 / 285.575 / 291.032 ms，中位数 291.032 ms。LuCI 保存启用后，从 Mihomo 连接链观察到专用 `R3Site-` 组及选定节点，ChatGPT trace 返回 200 / SG，未带密钥的 OpenAI API 探测返回正常的 401。实际执行「恢复原分流」后，运行 YAML 与安装前备份的语义完全一致；再次启用并重启 OpenClash 后，专用分流自动恢复，其他运行规则、DNS、覆写脚本和服务保持一致。这是当轮实测结果，后续可在页面重新测速。

页面上的保存、启停、删除和 Steam 开关不再单独跑 `mihomo -t`（440 KB 的运行配置要 5–7 秒）：控制接口重载用的是同一个解析器，解析失败返回 400、原配置照常运行，后端随即还原文件。OpenClash 启动时的覆写钩子和控制接口离线时的写入没有控制接口把关，仍先做核心校验：与生产进程使用相同的 `nogroup` GID，并设置 `SAFE_PATHS=/usr/share/openclash:/etc/ssl`，看门狗 20 秒（2026-10-26 实测 440 KB 的 MESL 运行配置校验要 5.3 / 7.0 / 5.7 秒）。设备 Ruby 不依赖 `json`、`fileutils`、`net/http` 等可选库。

同日 19:30 修复：源配置只写 `default-nameserver`、不写 `proxy-server-nameserver` 时（如 `MESL_yue.yaml`），测速助手原先拿不到 bootstrap 解析器，隔离核心只能用路由器的解析器，在 fake-ip 模式下拿到 198.18.x.x，172 个节点全部 `TLS_FAILED`。现在缺 `proxy-server-nameserver` 时改用该源的 `default-nameserver`，新增回归测试覆盖。复测后该源 172 个节点中 119 个通过，台湾 9 个全部通过（真实出口 TW）；未通过的 53 个里 45 个是 `UNSUPPORTED_REGION`（如香港），另有 6 个 `TLS_FAILED`、2 个 `TRACE_FAILED`。ChatGPT 规则随即改为该源「台湾 01 [0.3X]」，同区备用为台湾 02、台湾 03，三者都是 AnyTLS（TCP）。此前选用的 `peiqian_lv.yaml` 台湾节点是 Hysteria2（UDP），晚高峰成批拨号超时：19:14–19:24 这 10 分钟里 Codex 有 62 次请求失败、39 次成功。切换后 Codex 连续 43 次请求成功、0 次失败，Mihomo 没有 chatgpt 拨号错误。

同晚晚高峰（19:55–20:09）试过两个便宜订阅，都按 Codex 的真实大请求（每次约 43 MB）评判，没留下：
- `lian_li.yaml`「美国洛杉矶01｜流媒体｜0.01x」（vless）：测速端点 16 MB 上传 4.29 MB/s，实际向 chatgpt.com 的上传 7 分钟只走了 8 MB，请求挂起。
- `peiqian_lv.yaml`「日本东京07-0.1倍｜高速专线」（vless）：测速 9.81 MB/s；实际 5 个大请求 26.5–57.5 秒才拿到响应头，第 6 个超过 45 秒，试运行脚本自动切回。
- 同期 MESL「台湾 01 [0.3X]」31 个大请求全部在 7.3–21.0 秒内完成。

测速端点的吞吐不能代表向 chatgpt.com 的大上传：换节点前先用真实流量试运行，并准备自动回退。

同日后续验收：`peiqian_lv.yaml` 只有 HTTPS bootstrap DNS 时，测速助手原先生成空 `default-nameserver`，真实 Mihomo 拒绝启动，全部 70 项报 `CORE_START_FAILED`。现在空列表时省略该字段，保留源解析器；新增回归模拟核心拒绝空数组，修复后通过。订阅更新后的 `PENDING` 也改为「尚未测速」，运行队列显示「等待测速」，保持禁选。正式分流最终选择该源台湾 2，路由器连接链确认命中专用组；电脑端连续三次 ChatGPT trace 均返回 200 / TW，首字节 313.831 / 469.727 / 322.787 ms，OpenAI API 和 ChatGPT backend API 探测均返回正常的 401。初次正式连接曾出现拨号超时，不能把隔离测速通过等同于正式连接已经成功；正式与隔离解析器存在差异，但未据此改动全局 DNS，也未把尚未确认的解析机制写成永久修复结论。
