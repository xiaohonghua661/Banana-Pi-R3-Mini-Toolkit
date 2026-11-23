# socks5-gateway

在 Banana Pi R3 Mini（ImmortalWrt + OpenClash）上开一个带账号密码的 SOCKS5 出口。SOCKS5 由本模块自己的 Mihomo 进程提供（用 OpenClash 的同一个二进制），出口可选 OpenClash 任意一个订阅里的节点，和路由器其他设备用的 OpenClash 配置互不影响。

## 能力

- **订阅与节点**：页面里切换订阅（OpenClash 的各个配置文件），搜索或按地区筛选节点，点一下即切换；换节点只调 SOCKS5 内核的控制接口，换订阅热重载它，都不碰 OpenClash。
- **仅 IPv4**：开关即时生效。链路是 SOCKS5 内核 → sing-box（只放行 IPv4、TLS 分片）→ SOCKS5 内核 → 节点；不经过 OpenClash，局域网 DNS 缓存不会把地址还原成域名、让节点改走 IPv6。
- **出口地区检测**：同时问 Google、Cloudflare、Apple、ipinfo、MaxMind 各自把出口判成哪里，按地区归堆显示，判定不一致或漏出 IPv6 时提示；各家明细折叠。
- **端口 / 账号 / 密码 / 监听地址 / UDP**：保存前检测端口占用；只动 SOCKS5 内核。
- **持久化**：procd 服务开机按设置生成配置并启动；OpenClash 更新订阅后，页面打开或 OpenClash 重建配置时自动同步。

## 文件

| 路径 | 作用 |
|---|---|
| `router/usr/libexec/r3mini-socks5.rb` | 后端（全部命令） |
| `router/usr/sbin/r3mini-socks5` | CLI 入口 |
| `router/etc/init.d/r3mini-socks5` | procd 服务：SOCKS5 内核和 sing-box |
| `router/usr/share/rpcd/acl.d/luci-app-r3mini-socks5.json` | LuCI 权限 |
| `router/www/luci-static/resources/view/services/r3mini-socks5.js` | LuCI 页面（部署时改名带内容指纹） |
| `manage.py` | 部署、核对、回滚 |
| `test_integration.sh` | 设备上的后端集成测试（真实订阅副本、临时 OpenClash、平移端口，不碰正式实例） |
| `ui_sandbox.sh` | 设备上的页面测试沙箱（真实订阅、真实 DNS 设置） |
| `ui_check.py` | 在真实 LuCI 里打开页面、走主要操作、截图（可把视图换成本地文件、把后端换成沙箱） |

## 用法

```bash
MSYS_NO_PATHCONV=1 python socks5-gateway/manage.py install 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
MSYS_NO_PATHCONV=1 python socks5-gateway/manage.py verify 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
MSYS_NO_PATHCONV=1 python socks5-gateway/manage.py rollback 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242 --backup /etc/r3mini-socks5/install-backup-<时间>
```

测试必须在实机环境做：后端集成测试和页面检查的命令见 `../docs/SOCKS5 出口与指定节点.md`「部署、测试、回滚」。

## 安全边界

- `settings.json` 含明文密码，`0600`；页面只回显位数。不要拷进仓库或聊天记录。
- SOCKS5 内核的配置（`/tmp/r3mini-socks5/core/config.yaml`，`0600`）含订阅里的节点凭据和入站账号。
- 内部端口只监听 `127.0.0.1`（17896 sing-box、17897 回环入站、17898 控制接口），都要本模块的账号密码或随机密钥。
- CLI 入口清掉 `R3MINI_SOCKS5_ROOT`，页面请求不能把后端指到沙箱根。`ui_check.py` 临时签的 LuCI 会话用完即销毁。
