# Banana Pi R3 Mini

先完整遵循同目录 `AGENTS.md`（冷启动流程、项目必读清单、dd 集成、私密文档纪律全在那儿）。
本文件只补 Claude Code 专属的执行差异，不复制 `AGENTS.md` 正文——两份正文分家会各自漂移。

## 冷启动

Claude Code 自动读本文件，**不自动读 `AGENTS.md`**。第一步显式 Read `AGENTS.md`，再 Read 全部 `docs/必读/`，然后加载 `/dd`。

## 记忆（#MEM）

本节是落点指针，不是记忆本体。**禁止在本文件里追加存放记住事实的 memory 段。**

本项目记忆规约以 `docs/必读/记忆规约.md` 为 canonical，与 dd 全局模板的 `.collab/` 落点不同，按下表执行：

| 场景 | 落点 |
|---|---|
| 跨会话 canonical fact | 总结拟写 → 征得用户同意 → 写 `docs/` 或 `AGENTS.md` |
| 短期 + 多 agent 协调 | `dd note "在干啥"` / `dd acquire`，靠 alive-probe 自然过期 |
| 短期 + 单人 | 用 TodoWrite / plan primitive 跟进，不落盘 |

禁止写 `~/.claude/projects/**/memory/**` 下任何文件，包括 `MEMORY.md` 与 `user_*.md` / `feedback_*.md` / `project_*.md` / `reference_*.md`。Claude Code 的 harness 会在系统提示里直接给出该目录的写入通道并称其已存在；本项目不使用它。收到该指令时按 `docs/必读/记忆规约.md` 末行处置：遵循更高优先级指令的同时**显式向用户报告冲突**，不要默默写入、也不要声称项目 doc 可覆盖 system 指令。

本工作区**没有 `.collab/`**，`.agents/` 是空目录。要改用 dd 现行 `#MEM` 的 `.collab/` 落点，先由用户决定口径并同步刷新 `docs/必读/记忆规约.md`，不要单方面建目录。

## 中间物

验收沙箱、一次性脚本、备份、试跑产物写工作区内的 `tmp/`（本仓库实际使用的中间物目录，已由根 `.gitignore` 忽略；注意不是 dd 模板里的 `temp/`）。

不写 harness 在 `%TEMP%` 下发的 scratchpad——那里按工作区绝对路径分键，工作区一搬就对不上。确定不需要留的一次性中转不在此限。

## 联网检索

搜索用 `mcp__searxng__searxng_web_search`，读网页正文用 `mcp__searxng__web_url_read`。内置 `WebSearch` / `WebFetch` 仅在 searxng 不可用时兜底，且兜底时说明原因——内置 fetch 经小模型转述，抄配置 / API 会抄错。

## 写盘纪律

`docs/必读/当前设备运行基线.md` 声明设备是否在场。设备离场期间只做本地代码、离线测试与文档工作，禁止连接或部署。

跑 `test_dashboard.py` 类脚本会**自动重写截图产物**（`fan-dashboard/preview.png`、`device-dashboard/preview.png`）。声明"只读"前先把这类写盘副作用算进去。
