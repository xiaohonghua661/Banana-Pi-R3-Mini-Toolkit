# Netdata LuCI 内嵌中文化部署与验收

## 适用范围

此流程只支持 Netdata `v1.38.1`。目标是把简体中文覆盖层显示在 LuCI 的“系统 → Netdata”内嵌页面，不以直接访问 `:19999` 页面代替验收。

部署会改动 Netdata 的 `index.html`、`dashboard-react.js`、覆盖脚本和 LuCI 的 Netdata 视图。不会修改 `network`、`wireless`、热点、风扇或 OpenClash。

RST 会清空可写 overlay；恢复系统后先重新确认 Netdata 版本和 LuCI 视图存在，再从本仓库重新执行本流程。不要把旧设备的网页文件直接覆盖到不同版本的 Netdata 或 LuCI 上。

## 本地预检

进入 `third_party/netdata-chinese-patch/compat`，先运行：

```powershell
python test_overlay.py
python test_deploy_upload.py
bash -n deploy-openwrt.sh
python deploy_router.py --help
```

已验证的关键输出为：

```text
OVERLAY_TRANSLATION=PASS
CHUNKED_UPLOAD=PASS
```

任一命令失败时停止，不上传、不修改设备。`test_overlay.py` 覆盖静态文本、属性、分段文本、动态文本和 Cloud/推广入口隐藏；`test_deploy_upload.py` 覆盖 Base64 分片还原、LuCI iframe 版本参数替换和非法回滚路径拒绝。

## 部署

在执行端以环境变量提供路由器 root 密码；不要把真实密码写入脚本、文档、终端历史或仓库。

```powershell
$env:NETDATA_ROUTER_PASSWORD = '<router-root-password>'
python deploy_router.py --host <router-management-ip>
```

该入口先把覆盖脚本和部署脚本上传到设备临时目录，再由设备完成以下事务：先在 `/root/netdata-zh-cn-backup-YYYYMMDD-HHMMSS` 备份受影响文件与 SHA-256 清单，再写入覆盖层和缓存版本参数，最后进行版本、文件、LuCI iframe 与本机 HTTP 核验。核验失败时，入口会回滚到本次刚创建的备份并报错。

记录每台设备输出的 `backup=` 路径。它是该设备的唯一回滚凭据；不要把一台设备的路径用于另一台设备。

## 批量部署

重复 `--host` 即可按给定顺序部署多个设备：

```powershell
python deploy_router.py --host <router-a-ip> --host <router-b-ip>
```

批量是顺序 fail-fast：某台失败时后续设备不会继续，已成功的设备不会自动跨设备回滚。量产时先用一台同版本样机完成完整 LuCI 黑盒验收，再按小批次推进；每台都保存自己的 `backup=` 输出。

## LuCI 黑盒验收

在浏览器打开：

```text
http://<router-management-ip>/cgi-bin/luci/admin/system/netdata
```

刷新页面后确认以下可见结果：

- iframe 地址带有 `?v=` 的 12 位版本值。
- “系统概览”“磁盘读取”“网络入站”等主界面文字为中文。
- “System Overview”“Disk Read”不再显示。
- Cloud 登录、定价、隐私和社交推广入口不可见。
- 实时图表持续更新。

只检查文件哈希、只访问 `http://<router-management-ip>:19999/`，或只看到 LuCI 外壳中文，都不能证明内嵌页面已经中文化。

## 回滚

对仍保持覆盖层结构的历史部署版本，使用该设备在部署输出中记录的精确路径：

```powershell
python deploy_router.py --host <router-management-ip> --rollback /root/netdata-zh-cn-backup-YYYYMMDD-HHMMSS
```

入口只接受上述格式的路径，非法路径会报 `invalid_rollback_backup`。回滚会恢复备份中的 Netdata 页面、React 包、LuCI 视图和先前覆盖脚本状态。

当前入口在显式回滚后仍执行“覆盖层必须存在”的部署核验。因此，不要用它把设备回退到完全未部署覆盖层的初始页面；该场景恢复后会因核验条件不成立而返回失败，不能作为量产回滚方案。保留现场与备份，先报告该限制并补齐专用回滚验收后再操作。

## 交付证据

交付每台设备时保留以下证据：

- 本地四项预检的真实输出。
- 部署输出中的 `host=`、`backup=`、`status=applied`。
- LuCI 内嵌页面的截图或 DOM 检查结果。
- 需要回滚时的 `status=rolled_back`，以及回滚后的 LuCI 页面检查结果。

覆盖层只翻译已定义的 Netdata 文本和常见动态片段；不要宣称所有第三方插件、指标名或未来 Netdata 版本均已完整汉化。升级 Netdata 或 LuCI 后，必须重新执行本地预检和 LuCI 黑盒验收。
