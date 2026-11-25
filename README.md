# Banana Pi R3 Mini Toolkit

给 Banana Pi BPI-R3 Mini 软路由（ImmortalWrt 24.10 + OpenClash）加的一组 LuCI 功能，带部署工具、回滚方法和测试。全部在作者自己的设备上装过、用过（ImmortalWrt 24.10.6、OpenClash 0.47.156）。

仓库只放源码、测试和文档，不含设备镜像、配置备份、密码、订阅或节点。

## 功能一览

| 功能 | LuCI 里的位置 | 做什么 | 先读 |
|---|---|---|---|
| 网站分流 | 服务 → 网站分流 | 给指定网站（如 ChatGPT）单独选订阅和节点，节点先测速再选；附「Steam 直连」开关 | [chatgpt-routing/README.md](chatgpt-routing/README.md) |
| SOCKS5 出口 | 服务 → SOCKS5 出口 | 开一个带账号密码的 SOCKS5 入口，出口可选 OpenClash 任一订阅里的节点，与 OpenClash 运行配置互不影响 | [docs/SOCKS5 出口与指定节点.md](docs/SOCKS5%20出口与指定节点.md) |
| 广告过滤 | 服务 → 广告过滤 | 按域名拦截红果短剧、抖音等 App 的广告，App 绕过 DNS 直连 IP 也拦得住；每天自动更新订阅规则 | [adblock/README.md](adblock/README.md) |
| 流量记录 | 状态 → 流量记录 | 按「小时 × 设备 × 出口 × 目标」记录走代理和直连的流量 | [traffic-logger/README.md](traffic-logger/README.md) |
| 上网出口 | 网络 → 上网出口 | 在有线 WAN、5G 蜂窝、Wi-Fi 上网（连手机热点等）之间设优先级，断了自动换 | [docs/上网出口与Wi-Fi上网.md](docs/上网出口与Wi-Fi上网.md) |
| 风扇管理 | 系统 → 风扇管理 | 按温度控制风扇 | [docs/设备监控与风扇温控.md](docs/设备监控与风扇温控.md) |
| GPT 夜间省流 | 电脑上的计划任务 | 夜里把 ChatGPT 的分流切到便宜节点，变慢就自动回退，早上切回 | [gpt-night/README.md](gpt-night/README.md) |

其他目录：

- `openclash-ui-patch/`：OpenClash 页面修补与只读核验。
- `filemanager-fix/`：LuCI 文件管理器路径修复。
- `third_party/netdata-chinese-patch/`：Netdata v1.38.1 简体中文覆盖层，见 [docs/Netdata LuCI 内嵌中文化部署与验收.md](docs/Netdata%20LuCI%20内嵌中文化部署与验收.md)。
- `device-dashboard/`：设备管理面板原型。
- `scripts/router/`：整机配置备份、`/tmp` 清理、把配置克隆到第二台 R3 Mini（见 [docs/克隆到第二台 R3 Mini.md](docs/克隆到第二台%20R3%20Mini.md)）。
- `scripts/rpi5-sidegw/`：把树莓派 5 做成旁路由的脚本，见 [docs/必读/树莓派5旁路由.md](docs/必读/树莓派5旁路由.md)。

## 哪些内容只对原作者有效

- 根目录的 `AGENTS.md`、`CLAUDE.md` 和 `docs/必读/` 是作者自己的设备记录和 AI 协作约定（`192.168.0.242`、`dd` 协作工具等），跟你的路由器无关。Claude Code 会自动读 `CLAUDE.md`：让 AI 助手帮你装时，明确告诉它忽略这三处，只按模块文档做。
- 文档和命令里的 `192.168.0.242`、订阅文件名、节点名都是作者的，换成你自己的。
- GPT 夜间省流把路由器地址、订阅名和节点名写死在 `gpt-night/gpt_night.py` 开头的常量里（`HOST`、`NIGHT_SOURCE`、`NIGHT_NODES`），不改用不了。

## 准备

路由器：

- BPI-R3 Mini，ImmortalWrt 24.10。
- 网站分流、SOCKS5 出口、广告过滤、流量记录都依赖 OpenClash（Meta 内核），装好并能正常上网后再装这些模块。

电脑（作者用 Windows 11 + Git Bash，以下按这个环境写）：

- Python 3.10 以上：`pip install paramiko pywin32`。网站分流、流量记录的部署器会把整机备份用 Windows DPAPI 加密，存到电脑的 `backups/router/`，所以要 `pywin32`，只能在 Windows 上用。
- 页面测试另需 Chrome，或 `pip install playwright` 后 `playwright install chromium`，以各模块文档为准。

SSH 登录：

1. 生成密钥：`ssh-keygen -t ed25519 -f ~/.ssh/r3mini_ed25519 -N ""`。
2. 把 `~/.ssh/r3mini_ed25519.pub` 的内容贴进 LuCI「系统 → 管理权 → SSH 密钥」并保存。
3. 先手动连一次 `ssh -i ~/.ssh/r3mini_ed25519 root@<路由器IP>`，核对并接受主机指纹。除风扇管理的部署脚本外，部署工具只连 `~/.ssh/known_hosts` 里已有指纹的设备。

各部署工具怎么登录：

| 部署工具 | 登录方式 |
|---|---|
| `chatgpt-routing/manage.py`、`socks5-gateway/manage.py`、`fan-dashboard/deploy_hotspot.py` | 加 `--key ~/.ssh/r3mini_ed25519` |
| `traffic-logger/manage.py`、`gpt-night/gpt_night.py`、`fan-dashboard/deploy_fan_only.py` | 只认口令。先给路由器 root 设口令（LuCI「系统 → 管理权」），再新建 `docs/私密/商家交付信息.md`，把口令用反引号包住写进去（如 `` `你的口令` ``）。`docs/私密/` 已被 `.gitignore` 忽略，不会提交。`deploy_fan_only.py` 不核对主机指纹，运行前自己确认地址没填错 |
| `adblock/install.sh` | 在路由器上运行。按它的文档用 `tar` 经 SSH 上传，`ssh` 要加 `-i ~/.ssh/r3mini_ed25519` 和 `-o StrictHostKeyChecking=accept-new` |

## 安装一个功能

每个功能的安装、验收、回滚都写在「先读」那一列的文档里。通用顺序：

1. 读该功能的文档，确认前提满足。
2. 安装。部署工具会先备份：网站分流把整机备份加密存到电脑的 `backups/router/`，SOCKS5 出口和上网出口把备份放在路由器上。回滚方法写在各功能的文档里。例如：

   ```bash
   python chatgpt-routing/manage.py install <路由器IP> --key ~/.ssh/r3mini_ed25519
   MSYS_NO_PATHCONV=1 python socks5-gateway/manage.py install <路由器IP> --key ~/.ssh/r3mini_ed25519
   python fan-dashboard/deploy_hotspot.py <路由器IP> --key ~/.ssh/r3mini_ed25519
   ```

   命令按 Git Bash 写。Git Bash 里参数带 `/` 开头路径的命令要加 `MSYS_NO_PATHCONV=1`，否则路径会被改写成 Windows 路径。在 PowerShell 里运行时，去掉 `MSYS_NO_PATHCONV=1`，并把 `~` 换成 `$HOME`。
3. 按文档验收，在 LuCI 里打开对应页面确认。

部分操作会重载或重启 OpenClash，局域网会短暂断网，各文档写明了时长。改路由器之前先做整机备份。

## 让 AI 助手帮你装

用 Claude Code、Codex 等助手时，在仓库根目录打开它，然后发：

```text
帮我给一台 BPI-R3 Mini（ImmortalWrt + OpenClash，地址 <路由器IP>）装「<功能名>」。
只按 <该功能的文档路径> 操作。根目录的 AGENTS.md、CLAUDE.md 和 docs/必读/ 是原作者自己的设备和协作约定，跟这台路由器无关，不要照做。
SSH 用密钥 ~/.ssh/r3mini_ed25519。不要替我输入路由器密码。会重启 OpenClash、改其它配置的步骤，先告诉我影响，等我同意再做。
```

[adblock/README.md](adblock/README.md) 末尾有一份更完整的示例提示词。

## 安全

- 不要提交 `docs/私密/`、`backups/`、设备镜像、配置归档、Wi-Fi/管理密码、代理订阅或密钥；`.gitignore` 已经忽略前两个目录。
- 不要把文档里的示例地址当成你设备的地址；每次操作前先只读确认。
- 改 `network`、`wireless`、代理、风扇或启动服务之前先备份。
- Netdata 中文覆盖层只适用于 v1.38.1，升级 Netdata 后要重新测试。

## 版本与更新记录

更新记录在 [CHANGELOG.md](CHANGELOG.md)。GitHub Releases 提供源码压缩包和对应的 SHA-256。
