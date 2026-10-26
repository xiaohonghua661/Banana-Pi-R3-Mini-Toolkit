# GPT 夜间省流

每天 00:00 把「网站分流」里的 ChatGPT 规则从 MESL「台湾 01 [0.3X]」切到 `peiqian_lv.yaml` 的 0.1 倍节点（东京07，不合格时用东京08），07:30 恢复原规则。夜里由电脑上的守护进程盯着 Codex 的真实请求，变慢或断连就立刻回退。

改路由只用 `r3mini-chatgpt` 模块自己的命令（`benchmark` / `save` / `set-enabled`），不直接改 OpenClash 配置。

电脑端需要 Python 3.10+ 与 `paramiko`。SSH 复用 `chatgpt-routing/manage.py` 的连接方式：要求 `~/.ssh/known_hosts` 已固定设备密钥，口令在连接时从本机 `docs/私密/商家交付信息.md` 在内存解析，不打印。

## 时间表

| 时间 | 谁 | 做什么 |
|---|---|---|
| 00:00 | 电脑计划任务 `r3mini-gpt-night` | 测速夜间源（约 4 分钟）→ 切到第一个通过的夜间节点 → 守护到 07:20 |
| 07:30 | 电脑计划任务 `r3mini-gpt-day` | 恢复切换前的规则 |
| 08:30 | 路由器 cron | 兜底：夜间标记还在、规则仍在夜间节点上（电脑没跑白天任务），就停用规则回原分流 |

只在 23:30–07:00 之间开始切换。电脑睡眠错过时间，唤醒后补跑也受这个时段约束。计划任务只在用户登录时运行，用 `pythonw` 无窗口执行。

## 回退条件

守护每 10 秒读一次 Codex 日志库（`~/.codex/logs_*.sqlite`），满足任一条就回退：

- 大于 10 MB 的请求 45 秒还没拿到响应头（MESL 同期最长 19 秒）；
- 10 分钟内 `/codex/responses` 请求失败 2 次（切换后 30 秒内的失败不算，那是断开旧连接造成的）；
- 每 5 分钟经当前节点访问 `https://chatgpt.com/cdn-cgi/trace`，连续 2 次不是 200。

回退分两步：先停用规则，ChatGPT 立刻走原分流 `🤖 AI`（当前是 MESL「台湾 09 家宽」）；再把规则恢复为 MESL「台湾 01 [0.3X]」。模块要求所选节点有测速证明，MESL 的测速缓存过期（24 小时）时恢复前要先测速，约 7 分钟。恢复后当晚不再切换。

模块每次保存或停用前都用核心校验候选配置。MESL 配置实测校验要 5.3 / 7.0 / 5.7 秒，模块原来的 7 秒上限在首晚连续以 `CONFIG_TEST_FAILED` 拒绝恢复，现已放宽到 20 秒。切换、停用、恢复遇到非测速证明类的失败时仍隔 30 秒重试，最多 3 次；每次失败都把模块错误码写进日志。

每次切换都会断开 chatgpt.com / openai.com 上不走当前分流的旧连接：路由切换只影响新连接，Codex 会长时间复用旧连接。

## 命令

```powershell
python gpt-night/gpt_night.py status            # 规则、夜间标记、计划任务、路由器夜间日志
python gpt-night/gpt_night.py rollback 原因      # 夜间模式下立刻回退并恢复 MESL
python gpt-night/gpt_night.py day               # 立刻恢复切换前的规则
python gpt-night/gpt_night.py night --trial 20  # 忽略时段试运行 20 分钟（之后运行 day）
python gpt-night/gpt_night.py install           # 安装或更新：路由器兜底脚本、cron、两个计划任务
python gpt-night/gpt_night.py uninstall         # 先恢复规则，再删除上述三项
```

`install` 先把路由器的 `/etc/crontabs/root` 和 `/etc/r3mini-chatgpt/settings.json` 存到 `tmp/gpt-night/backup-<时间>/`。

## 文件

- 电脑日志：`tmp/gpt-night/gpt-night.log`
- 路由器日志：`/mnt/mmcblk0p6/r3mini-gpt-night.log`，syslog 标签 `r3mini-gpt-night`
- 夜间标记：`/etc/r3mini-gpt-night.json`（切换前的规则、夜间节点、状态 `night` / `rolled_back` / `restored`）
- 兜底脚本：`/usr/sbin/r3mini-gpt-night-failsafe`，cron 行带 `#r3mini-gpt-night`

## 实测（2026-10-25）

晚高峰试运行 `night --trial 20`：测速 `peiqian_lv.yaml` 后 21:30:18 切到东京07，断开旧连接 22 条。东京07 上 6 个约 39 MB 的请求等响应头 30 / 16 / 21 / 33 / 24 / 39 秒；21:36:53 一个请求 46 秒没有响应头，守护停用规则（断开 17 条），21:37:05 恢复 MESL「台湾 01 [0.3X]」（MESL 测速缓存未过期，无需重测；断开 10 条）。全程 Codex 只失败 1 次，是恢复时断开旧连接打断的在途请求，Codex 自动重发。

首晚（2026-10-26）：00:00 测速时东京07 `TRACE_FAILED`，改用东京08（中位 3.1 秒）；00:05 切换，00:09 一个大请求 48 秒没有响应头，守护停用规则。随后恢复台湾01 三次都因核心校验超时失败（当时还没有重试），规则停在原分流「台湾 09 家宽」；Codex 在其上 109 个大请求响应头中位 8 秒、最长 15 秒，失败 1 次。04:22 手动重试一次就恢复成功。

用同日 20:10–21:20 的真实 Codex 日志回放判定：MESL 上 73 个大请求，最长 19 秒、中位 15 秒，0 次误触发。夜间（00:00 以后）便宜节点的表现尚未实测，以首晚日志为准。

## 测试

```powershell
python gpt-night/test_gpt_night.py
```

假路由器按模块的测速证明规则模拟 `save`，配合假时钟和合成的 Codex 日志库，覆盖切换、各回退条件、宽限期、恢复要测速、恢复失败、白天恢复、手动改过规则不覆盖。

路由器兜底脚本在 `/tmp` 下用假模块实测（不碰真实规则）：把 `router/usr/sbin/r3mini-gpt-night-failsafe` 上传为 `/tmp/r3gn-test/failsafe`，再把 `test_failsafe_router.sh` 经 SSH 交给 `sh -s` 运行。
