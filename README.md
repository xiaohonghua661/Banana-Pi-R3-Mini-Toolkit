# Banana Pi R3 Mini Toolkit

面向 Banana Pi BPI-R3 Mini 与 ImmortalWrt/OpenWrt 的配置、监控、恢复和 LuCI 扩展工具集。仓库保留可复用源码、测试和公开文档，不包含设备镜像、配置归档、密码、订阅或本机私密资料。

## 主要内容

- `fan-dashboard/`：温控风扇与热点管理的 LuCI 页面、服务脚本、部署和验收工具。
- `device-dashboard/`：设备管理面板原型与界面测试。
- `openclash-ui-patch/`：OpenClash UI 修补、离线恢复和只读验收工具。
- `third_party/netdata-chinese-patch/compat/`：面向 Netdata v1.38.1 的简体中文覆盖层、批量部署、备份和回滚脚本。
- `scripts/router/`：路由器配置备份与恢复辅助脚本。
- `docs/`：RST 恢复、稳定基线、DNS 分流、硬件、电源与 Netdata 部署文档。

## 快速验证

在项目根目录按实际模块运行测试：

```powershell
python fan-dashboard/test_dashboard.py
python device-dashboard/test_dashboard.py
python third_party/netdata-chinese-patch/compat/test_overlay.py
python third_party/netdata-chinese-patch/compat/test_deploy_upload.py
bash -n third_party/netdata-chinese-patch/compat/deploy-openwrt.sh
```

涉及真实路由器的脚本默认先备份、再变更、最后验收。执行前阅读对应文档，确认固件、Netdata、LuCI 和设备路径与目标设备一致。

## 安全边界

- 不提交 `docs/私密/`、`backups/`、设备镜像、配置归档、Wi-Fi/管理密码、代理订阅或密钥。
- 不把示例管理地址当作当前设备地址；每次操作前重新只读确认。
- 不在未备份时修改 `network`、`wireless`、代理、风扇或启动服务。
- Netdata 中文覆盖层仅针对 v1.38.1；升级后必须重新测试。

## 发布内容

GitHub Releases 提供经过同一排除规则生成的源码备份与 SHA-256。每个版本的新增、修改、移除、修复和安全变化记录在 [CHANGELOG.md](CHANGELOG.md)。
