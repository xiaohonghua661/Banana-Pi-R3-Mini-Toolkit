# RST 后恢复与完整备份

> 状态更正（2026-07-19）：当前实机只读管理地址为 `192.168.0.242`，LAN 为 `eth0`，WAN 为 `eth1`，5 GHz 为信道 48 且启用；当前 `eth0` 有链路、`eth1` 无链路、WAN 未上线，dnsmasq 正在运行，因此该状态不是已验收的独立 LAN 拓扑。本文后部关于 `192.168.110.1` 的“最终稳定基线”是已撤销的历史候选，不得用于访问或写入设备；`192.168.101.0/24` 也不是当前地址。网络改动前重新读取实机状态并按当前恢复基线执行。

## 结论

RST 会清空可写 overlay。现有备份是配置文件集合，不是系统镜像：它不能重新安装软件包，也不能生成自定义服务的程序、LuCI 页面和启动链接。

本轮恢复从下列压缩包重新起算：

| 项目 | 值 |
|---|---|
| 文件 | `G:\Downloads\backup-immortalwrt-2026-07-18.tar.gz` |
| 修改时间 | `2026-07-18 18:09:27 +08:00` |
| 大小 | `14,340,577` 字节 |
| SHA256 | `D7EADC84AB4EBCC052E49B263B6709D9858B126C47BC872A51963E09C4ACDDC5` |
| 清单 | 103 项，仅 `etc/` 102 项和 `www/` 1 项 |

该归档没有 `/usr`、`/etc/init.d`、`installed_packages.txt` 或 `opkg/status`，因此不能恢复软件包本体。它也不含以下风扇配置和服务文件：

- `/etc/config/r3mini_fan`
- `/etc/init.d/r3mini-fan`
- `/usr/sbin/r3mini-fanctl`
- `/usr/sbin/r3mini-fan-web`
- `/usr/share/luci/menu.d/luci-app-r3mini-fan.json`
- `/usr/share/rpcd/acl.d/luci-app-r3mini-fan.json`
- `/www/luci-static/resources/view/system/r3mini-fan.js`

因此，恢复配置后 OpenClash、ttyd 或风扇服务仍可能不存在或无法启动；先恢复相应软件包和服务文件，再恢复其配置。

`/etc/config/system` 只保存时区、NTP 服务器等设置，不保存“当前时间”。RST 后必须让 WAN 可联网，并重新启动 NTP；没有网络时日期时间不会自行从备份复原。

本轮基线归档早于当晚完成的 OpenClash DNS 分流：其中没有最终的 4 个命名 DNS section，Policy 正文也不符合目标。它保留了 OpenClash 配置、数据和核心，但仍缺软件包载荷与 init/LuCI 文件。把其中的旧 DNS 设置当作历史参考，不能覆盖当前已经验收通过的运行配置。

## 把服务做进固件能保留什么

可以。OpenWrt/ImmortalWrt 的出厂重置通常移除可写 overlay，并重新从固件只读根文件系统启动。因此，构建固件时内置的软件包、`files/` 覆盖目录里的自定义脚本和 LuCI 文件，以及固件里的默认 `/etc/config/*` 都会在 RST 后保留或重新出现。

但 RST 后得到的是**固件里的默认值**，不是按键前最后一次修改的状态。下列内容仍需备份或在首次启动脚本中重建：

- LuCI 后修改的网络、无线、代理、风扇阈值、计划任务和服务启用状态。
- 当前日期时间、日志、临时文件和运行时下载的 OpenClash 核心、订阅或规则。
- 软件安装后才写入 overlay 的文件；只在运行中用 `opkg install` 安装而未做进镜像的包会被清除。
- Docker 数据。数据根在外置 NVMe 时通常不被 reset 触及，但必须以实际 reset 脚本和挂载路径为准，仍应另行备份。

风扇服务适合做进该设备的自定义固件：把服务程序、init 脚本、LuCI 文件和默认 `/etc/config/r3mini_fan` 一起放入镜像。OpenClash 可内置软件包和默认配置，但密钥、订阅和运行时下载内容仍应放进加密的离线恢复包，不能写进公开仓库或固件源码。

## 本次 RST 的恢复顺序

1. 刷回与备份兼容的 ImmortalWrt/OpenWrt 系统，先恢复 `network`、`wireless`、`firewall`，确认 WAN 已能联网。
2. 若原始备份压缩包仍在，用 LuCI 的“系统 → 备份/升级 → 恢复备份”恢复文件；若只剩展开目录，按其中的相对路径复制文件。不要再用旧的临时展开目录覆盖当前有效的 OpenClash 配置。
3. 执行 `opkg update`，按另存的软件包清单重新安装 OpenClash、ttyd、Netdata 等需要的软件包。当前两份备份没有这份清单，丢失的软件包只能按实际需要重新确定并安装。
4. 将完整的 `fan-dashboard` 目录上传到路由器，并执行 `<上传目录>/fan-dashboard/deploy-router.sh <上传目录>/fan-dashboard/router`。该脚本会启用并重启 `r3mini-fan`。
5. 恢复 OpenClash 配置和自定义规则后，再启动 OpenClash；配置文件本身不能替代 OpenClash 包、内核和规则运行文件。
6. 恢复 `system` 配置后执行：

   ```sh
   /etc/init.d/sysntpd enable
   /etc/init.d/sysntpd restart
   date
   ```

7. 逐项验证：`/etc/init.d/r3mini-fan status`、`/etc/init.d/openclash status`、`/etc/init.d/ttyd status`、`date`，以及 LAN/WAN 连通性。服务“已启动”不等于代理、DNS 分流或风扇控制已恢复，仍要做对应功能测试。

## 下次重置前：最小完整备份

把备份保存到电脑、U 盘或 NVMe 的独立目录；不要放在会被 RST 清空的 overlay。恢复包至少包含兼容固件、其 SHA256、配置归档、包名清单、自定义文件归档，以及 Docker 数据根的独立副本。下面命令在路由器上执行，`DEST` 必须替换为外部存储路径。

```sh
DEST=/mnt/data/router-backup/$(date +%Y%m%d-%H%M%S)
mkdir -p "$DEST"

# 配置归档；保存当前系统标识并审阅实际归档内容。
ubus call system board > "$DEST/firmware.json"
sysupgrade -b "$DEST/config.tar.gz"
tar -tzf "$DEST/config.tar.gz" | sort > "$DEST/config-files.txt"

# 软件包不是配置归档的一部分，必须单独保存。
opkg list-installed | awk '{print $1}' | sort -u > "$DEST/packages.txt"

# 保存项目自定义服务、页面和启动扩展；只记录当前实际存在的路径。
: > "$DEST/custom-files.list"
for path in \
  /etc/config/r3mini_fan \
  /etc/init.d/r3mini-fan \
  /usr/sbin/r3mini-fanctl \
  /usr/sbin/r3mini-fan-web \
  /usr/share/luci/menu.d/luci-app-r3mini-fan.json \
  /usr/share/rpcd/acl.d/luci-app-r3mini-fan.json \
  /www/luci-static/resources/view/system/r3mini-fan.js \
  /etc/openclash /etc/crontabs /etc/rc.local; do
  [ -e "$path" ] && printf '%s\n' "$path" >> "$DEST/custom-files.list"
done
tar -czf "$DEST/custom-files.tar.gz" $(cat "$DEST/custom-files.list")

# 归档可读性和覆盖范围检查。
tar -tzf "$DEST/config.tar.gz" > "$DEST/config-files.checked.txt"
tar -tzf "$DEST/custom-files.tar.gz" > "$DEST/custom-files.checked.txt"
sha256sum "$DEST"/* > "$DEST/SHA256SUMS"
wc -l "$DEST/packages.txt" "$DEST/custom-files.list"
```

如需让一个 `sysupgrade` 配置归档也带上自定义文件，先在现有 `/etc/sysupgrade.conf` 追加实际需要的路径，再运行 `sysupgrade -l` 审阅待打包清单；不直接覆盖这个文件。每次新增服务、LuCI 页面或启动脚本后，重新运行此流程，并检查 `config-files.txt` 和 `custom-files.list` 是否出现新路径。

Docker 数据根如 `/mnt/data/docker` 不在上述配置归档中。RST 不代表 NVMe 上的数据可替代备份：停止 Docker 后将其同步或做文件系统快照到第二块可信介质；恢复前先确认 NVMe 已挂载，绝不初始化、清空或 prune 原数据。`/etc/openclash`、无线配置和 Docker `.env` 可能含订阅、节点或 Wi-Fi 密钥；备份仅保存到可信的离线位置，不提交到项目仓库或公开渠道。

## 新设备的恢复顺序

1. 比对当前 `ubus call system board` 与 `firmware.json`；不兼容时先使用匹配或明确兼容的固件，不能把旧包清单盲装到新系统。
2. 恢复基础网络并联网，确认外置盘已挂载。先完成 NTP 校时；无网时临时用 `date -s 'YYYY-MM-DD HH:MM:SS'` 校时，避免 HTTPS、订阅更新和代理因时间错误失败。
3. 运行 `opkg update`，读取 `packages.txt` 逐项安装需要的软件包；记录无法从当前软件源安装的包名和错误，不要跳过或反复重试。
4. 恢复 `config.tar.gz` 与 `custom-files.tar.gz`，然后执行每个实际存在的自定义服务的 `enable` 和 `restart`。确认 Docker 数据根已挂载后才启动 Docker；最后启动 OpenClash。
5. 执行 `sha256sum -c "$DEST/SHA256SUMS"`，验证时间、网络、DNS、代理、计划任务和风扇服务。

不能从本轮基线归档中事后推导出当时完整的软件包集合；今后保存 `packages.txt` 才能消除这个缺口。

## 2026-07-19 本轮恢复结果

- 风扇服务的 7 个文件已补回，服务为开机自启；默认曲线恢复为 `30/35/35/38/37/40°C`，高温时反相 PWM 为 `0`。
- OpenClash 0.47.133 已由系统后台包恢复补回并处于 `running`；4 个 DNS section、6 个主开关、Policy 正文和实际运行 YAML 均通过目标断言。
- Nikki、Mihomo、Netdata、LuCI 中文、Samba4 和 TTYD 软件包仍在，无需重复安装。
- 当前未发现 NVMe；只有约 7.3 GiB 的 eMMC 与约 246 MiB overlay。Docker、dockerd、containerd 均未安装，本轮不把 Docker 写入系统闪存，等 512 GB 或更大 NVMe 到位后再实施数据根迁移和容器验收。

## 2026-07-19 已撤销的候选地址（仅历史）

RST 后设备曾短暂回到默认管理地址 `192.168.1.1`，该地址只属于复位后的过渡态。恢复过程中又曾短暂使用 `192.168.110.1`，随后用户明确改回 `192.168.0.242`。针对 `.110.1` 生成的归档只作为历史恢复点；一次 fresh 黑盒因地址切换而连接超时，不能计为设备功能失败，也不能作为当前验收。

## 2026-07-19 最终稳定基线

- 当前唯一管理地址为 `192.168.0.242/24`，`br-lan=eth0`；WAN 仍为 `eth1`。
- dnsmasq 正在运行，DHCP 池为 `192.168.0.100–199`。
- 2.4 GHz、5 GHz 均启用；5 GHz 为信道 48、HE80。
- `r3mini-fan` 正在运行并开机启用；曲线为 `30/35/35/38/37/40°C`、5 秒采样、AUTO，反相 PWM 高速为 0。
- OpenClash 0.47.133 已使用官方 IPK 和匹配 ImmortalWrt 24.10.6 的离线依赖恢复，正在运行并开机启用。
- 4 个命名 DNS section、6 个主开关、Policy 正文和实际运行 YAML 分别输出 `UCI_DNS_OK`、`RUNTIME_DNS_OK`。
- Nikki 已停止并禁用；Netdata、Samba4、TTyd 正在运行；系统日期已校正，NTP 开机启用。

只读验收脚本为 [`fan-dashboard/verify-stable-router.sh`](../fan-dashboard/verify-stable-router.sh)。主线实机输出：

```text
NETWORK_READONLY_OK
FAN_OK
UCI_DNS_OK
RUNTIME_DNS_OK
SERVICES_OK
TIME_OK
STABLE_BASELINE_OK
```

当前完整备份位于 [`backups/router-20260719-175110-stable-current`](../backups/router-20260719-175110-stable-current/)。敏感主归档使用当前 Windows 用户 DPAPI 加密；解密后 SHA-256 为 `3FC53F5A610F7FB4604FE714494BD5C02E9E867E0E0668B472A830ACBC04B8AB`。备份包含 107 项配置、721 项 overlay、179 项 eMMC 数据、386 个软件包记录、风扇源文件和 13 个离线 IPK；主归档隔离解包、内部摘要 `12/12`、DPAPI 往返及官方 IPK 摘要 `13/13` 均通过。

在项目根目录使用生成备份的同一 Windows 用户解密；输出明文只能放到临时可信目录，校验并使用后立即删除：

```powershell
$plain = Join-Path $env:TEMP ("bpi-final242-restore-{0}.tar.gz" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
.\backups\router-20260719-175110-stable-current\restore-dpapi.ps1 `
  -EncryptedPath '.\backups\router-20260719-175110-stable-current\bpi-final242-20260719-175110.tar.gz.dpapi' `
  -OutputPath $plain
Get-FileHash -Algorithm SHA256 $plain
```

批量部署只复用脚本、离线安装包、摘要清单和验收判据，不复制单台设备的敏感归档或身份数据。每台设备必须先核对同型号、兼容固件和分区布局，建立本机可恢复备份，再单独注入凭据并执行 fresh 黑盒；DPAPI 归档受当前 Windows 用户约束，不能作为跨电脑通用镜像。`network`、`wireless`、`r3mini_hotspot` 仍按每台现场拓扑独立配置，不纳入无条件批量写入。

恢复脚本 [`openclash-ui-patch/restore-stable-baseline.sh`](../openclash-ui-patch/restore-stable-baseline.sh) 只写 OpenClash 与 Nikki，不包含 `network`、`wireless`、`r3mini_hotspot` 或网络 reload。独立安全审计确认信号路径会回滚后退出，失败会恢复 OpenClash/Nikki 原运行和启用状态；验证脚本完全只读。

当前 WAN 与蜂窝接口没有上线，因此尚未执行客户端互联网出口、美国代理出口和 DNS 泄漏黑盒；该项必须在物理上行接通后补测。Docker 仍等待 NVMe 到位，不写入系统闪存。
