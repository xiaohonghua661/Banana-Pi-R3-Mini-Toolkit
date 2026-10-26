# 网站分流

LuCI「服务 → 网站分流」添加自定义域名或网站 URL，为每条规则手选订阅和节点；支持逐条启停、删除，也提供 ChatGPT 预设。首次安装为空且保持关闭；保存启用规则才改变运行分流。「恢复原分流」停用所有规则并移除本模块的专属节点、组和规则；模块继续保留在菜单中。其他规则保留。

先对所选订阅执行「3 轮测速」。每个节点使用独立的隔离核心发起三轮新 HTTPS 连接，读取真实出口地区，要求三轮地区一致且位于模块采用的 ChatGPT 支持地区清单，并验证 OpenAI API 可达。页面展示三次首字节时间及中位数，只允许选择验证通过的节点；「选择最低延迟」采用已通过节点中最低的三轮中位数，仍可手动改选其他通过的节点。地区来自实际请求，不依赖节点名称中的国家标签；内置地区清单是已核验的保守子集，测速结果同时返回官方来源和核验日期。

测速异步执行，进度缓存在 `/tmp/r3mini-site-bench/`，不切换生产节点。隔离核心使用设备的 `nogroup` 组（当前 GID 65534），使出站连接避开生产 OpenClash 的 OUTPUT 重捕获。保存规则时把节点内容 SHA-256、三轮结果、地区和中位数作为证明持久保存到该规则的 `node_validation`；同一节点参数未变时可跨测速缓存过期或设备重启继续使用。节点参数改变需重测；新鲜完成且失败的复测会撤销旧证明，不能继续沿用旧成功结果。

在 Windows 项目根目录使用 Python 3.10+、`paramiko` 和 `pywin32`。设备需有 OpenClash、Ruby 的 `yaml`/`digest/sha2`、curl。先在 `~/.ssh/known_hosts` 固定设备密钥；管理脚本拒绝未知或变化的主机密钥，连接时才在内存中解析本机 `docs/私密/商家交付信息.md` 的反引号候选密码，不打印凭据。

用实际目标替换示例中的 `HOST_A`、`HOST_B`；没有默认设备。命令可批量处理显式目标：

```powershell
python chatgpt-routing/manage.py backup HOST_A HOST_B
python chatgpt-routing/manage.py check-backup HOST_A HOST_B
python chatgpt-routing/manage.py install HOST_A HOST_B
python chatgpt-routing/manage.py verify HOST_A HOST_B
python chatgpt-routing/manage.py rollback HOST_A HOST_B
```

`--host` 可重复使用。`install` 默认先做即时备份，也可用 `--backup <本机归档路径>` 指定两小时内且仍与设备逐项一致的备份；该参数只接受一个目标。`rollback --backup <归档路径>` 恢复指定恢复点，不指定时使用该目标最新的本模块备份。备份本身可用 `check-backup <归档路径>` 离线核验。

备份位于 `backups/router/*-before-chatgpt.tar.gz.dpapi` 和同名 `.manifest.json`。归档包含完整 `/etc`、OpenClash 程序、包清单和已有 r3mini/AdsPower 程序及 LuCI 文件。清单使用 JSON 信封，身份、快照、服务状态和运行配置路径存入 DPAPI 加密载荷；同一 Windows 用户在同一机器解密。保存后立即解密验哈希，并在临时目录模拟改动和恢复，输出 `BACKUP_OK`、`BACKUP_CHECK_OK`、`SCOPED_RESTORE_DRILL_OK`。Windows 演练验证文件字节和存在状态，POSIX 权限及链接使用 tar 元数据核对；不代表磁盘整机恢复或硬件冷启动验收。

安装通过 SSH 标准输入原子上传文件，核对 SHA-256，保留已有 OpenClash overwrite 钩子的其他原字节，把 `BEGIN/END R3MINI-CHATGPT` 块放在最后的 `exit 0` 前。只清理已知 LuCI 缓存并 reload rpcd；不重启 OpenClash。失败时按该次备份定向恢复。`verify` 检查文件权限/哈希、实时专属规则状态、LuCI 静态页、菜单树、ACL 和原有核心/服务。

`rollback` 是返回指定恢复点：先制作当前状态的 DPAPI 检查点，确保操作可撤回，再恢复本模块六个程序/页面文件（含测速助手）、`/etc/r3mini-chatgpt/`、overwrite 钩子和备份时的运行 YAML，移除原来不存在的受管件。恢复点在首次安装前时，结果是卸载模块；恢复点已有旧版模块时，结果是回到旧版。页面的「恢复原分流」只停用规则。恢复器从本地包在内存加载校验所需后端与助手，卸载后无需把模块写回设备。

整份运行 YAML/钩子回放前，脚本比较当前与备份的非本模块 YAML 语义和去专属块后的钩子原字节。订阅更新、DNS 或其他钩子发生变化时，以 `ROLLBACK_NONMODULE_RUNTIME_CONFLICT` 或 `ROLLBACK_NONMODULE_HOOK_CONFLICT` 在写入前阻断；不覆盖这些新变化。允许恢复时先停用本模块，再通过原 controller 平滑 reload；核对恢复范围的哈希、权限和存在状态，要求范围外的当前快照不变。完整归档中的其他配置不会被写回。回滚新建的检查点也会成为最新恢复点；重复操作时用 `--backup` 明确目标。

设备接口：

```sh
/usr/sbin/r3mini-chatgpt status [source.yaml]
/usr/sbin/r3mini-chatgpt benchmark source.yaml
/usr/sbin/r3mini-chatgpt benchmark-status source.yaml
/usr/sbin/r3mini-chatgpt apply source.yaml NODE_SHA16
/usr/sbin/r3mini-chatgpt save RULE_JSON
/usr/sbin/r3mini-chatgpt set-enabled RULE_ID 0
/usr/sbin/r3mini-chatgpt remove RULE_ID
/usr/sbin/r3mini-chatgpt disable
```

`status` 返回 JSON，顶层 `enabled` 表示是否有启用的规则，`applied` 是运行规则/节点的实际核验结果，`site_rules` 提供每条规则的状态。`benchmark` 启动异步实测，`benchmark-status` 读取进度、每节点结果和 `best` 推荐令牌。节点令牌由页面读取，不能用节点名代替。`save` 接收页面生成的规则 JSON；`set-enabled` 的末项可为 `0`/`1`，`remove` 删除单条规则，`disable` 全部停用；`apply` 保留旧 ChatGPT 预设接口。订阅仅接受 `/etc/openclash/config/` 下普通 YAML 文件。`hook RUNTIME_YAML` 仅供 OpenClash 覆写钩子内部调用，LuCI ACL 不授权它。

后端是 `/usr/libexec/r3mini-chatgpt.rb`，测速助手是 `/usr/libexec/r3mini-site-bench.rb`，状态是 `/etc/r3mini-chatgpt/settings.json`，事务备份在该目录的 `backups/`。LuCI 菜单与 ACL 分别是 `/usr/share/luci/menu.d/luci-app-r3mini-chatgpt.json`、`/usr/share/rpcd/acl.d/luci-app-r3mini-chatgpt.json`，页面是 `/www/luci-static/resources/view/services/r3mini-chatgpt.js`。运行 YAML 优先从 `openclash.@overwrite[0].config_path`（兼容命名 section `overwrite`），否则从 `openclash.config.config_path` 的文件名推导到 `/etc/openclash/`。

执行 `python chatgpt-routing/test_manage.py` 运行部署器离线测试。所有失败输出为 `OPERATION_FAILED kind=TOKEN`；先处理对应原因再重跑。`PINNED_HOST_KEY_MISSING` 需核验并固定密钥，`BACKUP_NO_LONGER_MATCHES_PRODUCTION` 需重新备份，`BACKUP_IDENTITY_MISMATCH`/`BACKUP_RUNTIME_CHANGED` 需核对目标和恢复点，`INSTALL_FAILED_AND_ROLLBACK_FAILED` 需保留恢复点并检查设备当前状态。安装、真实网络分流与硬件启动的验收以实际执行记录为准。

2026-10-25 实机验收：刷新 `lian_li.yaml` 后对 56 个条目完成三轮测试，36 个通过。最低延迟节点为「新加坡高速05」，真实出口 SG，三次首字节时间 306.549 / 285.575 / 291.032 ms，中位数 291.032 ms。LuCI 保存启用后，从 Mihomo 连接链观察到专用 `R3Site-` 组及选定节点，ChatGPT trace 返回 200 / SG，未带密钥的 OpenAI API 探测返回正常的 401。实际执行「恢复原分流」后，运行 YAML 与安装前备份的语义完全一致；再次启用并重启 OpenClash 后，专用分流自动恢复，其他运行规则、DNS、覆写脚本和服务保持一致。这是当轮实测结果，后续可在页面重新测速。

核心候选校验与生产进程使用相同的 `nogroup` GID，并设置生产要求的 `SAFE_PATHS=/usr/share/openclash:/etc/ssl`；校验看门狗为 20 秒（2026-10-26 实测 440 KB 的 MESL 运行配置校验要 5.3 / 7.0 / 5.7 秒，原 7 秒上限在轻微负载下就以 `CONFIG_TEST_FAILED` 拒绝保存）。校验慢时，经 LuCI 保存可能先显示请求超时，设备上仍会完成，刷新页面即可看到结果。设备 Ruby 不依赖 `json`、`fileutils`、`net/http` 等可选库。当前离线验收包括后端 41 项、测速助手 11 项、部署器 15 项、页面 36 项。

同日 19:30 修复：源配置只写 `default-nameserver`、不写 `proxy-server-nameserver` 时（如 `MESL_yue.yaml`），测速助手原先拿不到 bootstrap 解析器，隔离核心只能用路由器的解析器，在 fake-ip 模式下拿到 198.18.x.x，172 个节点全部 `TLS_FAILED`。现在缺 `proxy-server-nameserver` 时改用该源的 `default-nameserver`，新增回归测试覆盖。复测后该源 172 个节点中 119 个通过，台湾 9 个全部通过（真实出口 TW）；未通过的 53 个里 45 个是 `UNSUPPORTED_REGION`（如香港），另有 6 个 `TLS_FAILED`、2 个 `TRACE_FAILED`。ChatGPT 规则随即改为该源「台湾 01 [0.3X]」，同区备用为台湾 02、台湾 03，三者都是 AnyTLS（TCP）。此前选用的 `peiqian_lv.yaml` 台湾节点是 Hysteria2（UDP），晚高峰成批拨号超时：19:14–19:24 这 10 分钟里 Codex 有 62 次请求失败、39 次成功。切换后 Codex 连续 43 次请求成功、0 次失败，Mihomo 没有 chatgpt 拨号错误。

同晚晚高峰（19:55–20:09）试过两个便宜订阅，都按 Codex 的真实大请求（每次约 43 MB）评判，没留下：
- `lian_li.yaml`「美国洛杉矶01｜流媒体｜0.01x」（vless）：测速端点 16 MB 上传 4.29 MB/s，实际向 chatgpt.com 的上传 7 分钟只走了 8 MB，请求挂起。
- `peiqian_lv.yaml`「日本东京07-0.1倍｜高速专线」（vless）：测速 9.81 MB/s；实际 5 个大请求 26.5–57.5 秒才拿到响应头，第 6 个超过 45 秒，试运行脚本自动切回。
- 同期 MESL「台湾 01 [0.3X]」31 个大请求全部在 7.3–21.0 秒内完成。

测速端点的吞吐不能代表向 chatgpt.com 的大上传：换节点前先用真实流量试运行，并准备自动回退。

同日后续验收：`peiqian_lv.yaml` 只有 HTTPS bootstrap DNS 时，测速助手原先生成空 `default-nameserver`，真实 Mihomo 拒绝启动，全部 70 项报 `CORE_START_FAILED`。现在空列表时省略该字段，保留源解析器；新增回归模拟核心拒绝空数组，修复后通过。订阅更新后的 `PENDING` 也改为「尚未测速」，运行队列显示「等待测速」，保持禁选。正式分流最终选择该源台湾 2，路由器连接链确认命中专用组；电脑端连续三次 ChatGPT trace 均返回 200 / TW，首字节 313.831 / 469.727 / 322.787 ms，OpenAI API 和 ChatGPT backend API 探测均返回正常的 401。初次正式连接曾出现拨号超时，不能把隔离测速通过等同于正式连接已经成功；正式与隔离解析器存在差异，但未据此改动全局 DNS，也未把尚未确认的解析机制写成永久修复结论。
