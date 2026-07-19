# LuCI 文件管理器路径修复

## 问题

`luci-app-filemanager` 从 `/etc/config/filemanager` 读取 `currentDirectory`。恢复旧配置但没有安装 NVMe 时，旧值 `/mnt/nvme0n1p1` 不存在，页面会报 `Failed to list directory` 并停止渲染文件列表。

## 应用

先为每台设备创建并下载当前 `sysupgrade -b` 配置备份，再把 `apply-router.sh` 上传到设备执行：

```sh
sh /tmp/apply-router.sh /mnt
```

脚本只修改 `filemanager.@filemanager[0].currentDirectory`，目标必须是已存在的绝对目录。失败时恢复 `/root/filemanager-backups/` 中的改前文件；重复执行会输出 `FILEMANAGER_PATH_ALREADY_OK`。

## 验收

在项目根目录执行：

```powershell
python .\filemanager-fix\verify_filemanager_ui.py
```

通过标记为 `FILEMANAGER_UI_OK`。脚本实际登录 LuCI，确认路径输入框为 `/mnt`、文件列表存在，并拒绝旧路径或 `Failed to list directory` 错误。

## 回滚

将对应的 `/root/filemanager-backups/filemanager-*.conf` 恢复到 `/etc/config/filemanager`；或从电脑端改前备份目录中的 `filemanager.conf` 恢复。恢复后重新打开 LuCI 页面即可，不需要重启网络、无线或路由器。

批量部署时逐台验证 `/mnt` 存在并分别生成改前备份；不要复制单台设备的完整配置归档或凭据。
