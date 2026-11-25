# 克隆到第二台 R3 Mini

> 状态（2026-09-03）：**本文流程已在实机完整执行一遍并通过验收**。源机 `192.168.0.242` 与克隆机 `192.168.0.246` 均在线。下文的输出、哈希与错误信息全部为该次执行的实际观测，不是构造示例。

## 结论

走**配置级克隆**，不走整机 eMMC 镜像回灌。

镜像回灌会把源机的 MAC、SSH 主机密钥、TLS 证书、LAN 地址和主机名一并复制过去。本次两台要同时挂在同一个 LAN 上，这些字段每一项都会撞。配置级克隆可以在恢复归档里预先注入身份改写片段，让新机首次启动时在网络起来之前就改完身份。

## 适用前提

| 项目 | 本次取值 |
|---|---|
| 共存关系 | 两台同时在同一个 LAN 上运行 |
| 新机型号 | 同为 Bananapi BPi-R3 Mini |
| 新机蜂窝模块 | **无**。源机的 `RM500CNV` 接口必须删除 |
| 克隆范围 | 风扇与热点 LuCI 应用、OpenClash 与 DNS 分流、网络与无线拓扑 |
| 不启用 | 智能出口候选（`r3mini-egress-manager`、`95-r3mini-egress`）。该候选从未上机验收，也不在任何恢复点内。从源机备份恢复时它本来就不会出现；只有改走 `deploy_hotspot.py` 才会被装上，那时按第 10 步中和 |

源机身份基线取自 `backups/r3mini-stable-20260719-170136/board.json`、同目录 `network.uci`，以及 `backups/router/router-backup-20260719-220116-hotspot-ui-title-final.tar.gz.dpapi` 内的 `/etc/config/*`：

```text
board_name: bananapi,bpi-r3-mini
release:    ImmortalWrt 24.10.6 r33869-cf234f8de6d5
kernel:     6.6.133
eMMC:       7,818,182,656 字节（15269888 扇区）
LAN:        192.168.0.242/24，br-lan=eth0，WAN=eth1
eth0 MAC:   ca:1b:5c:14:93:4d
eth1 MAC:   ca:1b:5c:14:93:4e（在 /etc/config/network 里硬钉）
hostname:   immortalwrt
ULA:        fdb9:15f7:169b::/48
2.4G:       immortalwrt-2.4，信道 12
5G:         immortalwrt-5.0，HE80，信道见下方说明
5G STA:     r3mini_phone_sta，连手机热点
DHCP:       lan 池 start=100 limit=100，正在发地址
软件包:      386 个（2026-09-03 复核值；7 月归档里记的是 373）
```

**源机 5 GHz 信道有两个值，取哪个取决于热点 STA 开没开。** 上面这份 7 月归档里是 `157`——那是 `r3mini_hotspot` 为了和手机热点同信道共存，把 `radio1` 从 `original_channel 48` 拉过去的结果。2026-09-03 复核时热点 STA 未启用，源机 radio1 停在 **48**。本文其余各处按 48 计算。

这件事对克隆是硬约束：**157 与克隆机用的 149 属于同一个 80 MHz 块**（中心都是 155）。要给源机重新启用热点 STA，必须先把克隆机挪出中心 155 那一块，见第 9 步。

## 已验证与未验证

已在本机离线执行并留有输出：

| 项目 | 结果 |
|---|---|
| 两份 DPAPI 恢复点可解密 | 完整基线 SHA-256 `3FC53F5A610F7FB4604FE714494BD5C02E9E867E0E0668B472A830ACBC04B8AB`、58,023,415 字节；22:01 恢复点 SHA-256 `6E1015792C3E5D6EE1712336CD02BF305472C5A97A2B866FC52540F6E0A64836`、134 条目 |
| 22:01 恢复点不含智能出口候选 | 条目里没有 `r3mini-egress-manager` 与 `95-r3mini-egress` |
| `sysupgrade -b` 归档的覆盖面 | 75 条，**不含** `/etc/openclash`，也不含任何自定义二进制与 LuCI 页面 |
| 备份覆盖面回归测试 | 语法检查 + 六道覆盖面闸门全 `PASS`，收尾 `BACKUP_COVERAGE_BLACKBOX=PASS`；每道都用反向用例验证过能正确失败并 rc=1 |
| 新机预检脚本 | 阻断路径（rc=1）与非阻断路径（rc=0）都跑通，stderr 为空 |
| 身份片段生成器 | 18 个拒绝点全部实测触发，均 rc=2 且 stdout 零字节（不产出片段） |

2026-09-03 实机执行并留有输出：

| 项目 | 结果 |
|---|---|
| eMMC 刷 ImmortalWrt 24.10.6 | GPT 写入后重读得到 5 个具名分区；`preloader`/`fip`/`recovery`/`production` 四块回读 SHA-256 与本地文件全部一致 |
| 固件版本一致 | 克隆机启动后 `ImmortalWrt 24.10.6 r33869-cf234f8de6d5`、内核 `6.6.133`、`board_name=bananapi,bpi-r3-mini`，与源机逐字相同 |
| 身份改写 | uci-defaults 首启执行后自删（`/etc/uci-defaults/` 为空），LAN/主机名/MAC/ULA/SSID/信道/DHCP/蜂窝口全部按预期改写 |
| 全程无地址冲突 | 克隆机从未以 `192.168.0.242` 上线；重启后 42 秒直接以 `192.168.0.246` 出现 |
| 受管件一致性 | 13 个 r3mini 相关文件（含指纹副本、菜单 json、ACL、后端二进制、init 脚本、三个 JS）与源机哈希**逐位相同** |
| 整体验收 | `scripts/router/probe-new-device.sh` 输出 `BLOCKED=0 WARNINGS=0 CLONE_PRECHECK_OK` |
| 源机未受影响 | 克隆全程后复核，源机 LAN/主机名/SSID/MAC/`high_up`/OpenClash 状态均未变 |

仍未验证：

- 两台 5 GHz 同时高负载时的实际干扰。已把两台放进不同的 80 MHz 块（源机中心 42，克隆机中心 155），但没做过吞吐实测。
- OpenClash 订阅在两台共用时的限流表现。源机历史根因是远端返回 `HTTP 429` 且不带 `subscription-userinfo` 响应头；**双机场景下是否加剧未实测**。
- 克隆机的手机热点 STA 与智能出口。两者在克隆机上都是关闭/未安装状态，没有运行数据。

## 必须改写的身份字段

新机每一项都必须与源机不同。`scripts/router/gen-clone-identity.sh` 对每一项都设了拒绝闸门，漏改会在生成阶段就被拦下。

| 字段 | 源机值 | 新机 | 不改的后果 |
|---|---|---|---|
| `network.@device[eth1].macaddr` | `ca:1b:5c:14:93:4e` | 另一个 locally-administered MAC | 上游 `192.168.0.254` 的 ARP 表错乱，两台抢同一条 DHCP 租约 |
| `network.lan.ipaddr` | `192.168.0.242` | 另一个地址 | 地址直接冲突 |
| `network.globals.ula_prefix` | `fdb9:15f7:169b::/48` | 重新随机 | IPv6 ULA 前缀重叠 |
| `system.@system[0].hostname` | `immortalwrt` | 另一个名字 | 两台同名，DHCP 与 mDNS 无法区分 |
| `dhcp.lan.ignore` | 未设，即发地址 | `1` | 两台同时发 DHCP，客户端随机拿到两套网关 |
| `wireless.default_radio0.ssid` | `immortalwrt-2.4` | 另一个 SSID | 同名同频互相干扰 |
| `wireless.radio0.channel` | `12` | 另一个信道 | 同上 |
| `wireless.default_radio1.ssid` | `immortalwrt-5.0` | 另一个 SSID | 同上 |
| `/etc/dropbear/dropbear_*_host_key` | 随归档复制 | 删除，让首启重生 | 两台出示同一把 SSH 主机密钥，部署器的主机密钥固定机制失效 |
| `/etc/uhttpd.{crt,key}` | 随归档复制 | 删除，让首启重生 | 两台同一张 TLS 证书 |
| `/etc/samba/{secrets.tdb,smbpasswd}` | 随归档复制 | 删除 | NetBIOS 名与 SID 冲突 |
| `network.RM500CNV` 整段 | `proto quectel`，`/dev/cdc-wdm0`，APN `CTLET` | 删除 | 新机无模块，接口起不来 |
| `dhcp` 的 4 条静态绑定 | 指向 `192.168.101.x` | 删除 | 与当前 `192.168.0.0/24` 不同网段，属换网段时的遗留脏数据 |

5 GHz 信道单列一条，因为它不在上表里而由生成器的 `NEW_CH5` 控制（默认 149，中心 155；源机 48 中心 42）。生成器判的是**块**不是信道号，同块会以 `GEN_REFUSED=CH5_SAME_80MHZ_BLOCK` 拒绝。

热点 STA 会打乱这个安排：源机的 `r3mini_hotspot` 为与手机热点同信道共存，会把 `radio1` 从 `original_channel 48` 拉到 `target_channel 157`（中心 155），**正好撞进克隆机那一块**。两台若都连同一部手机热点更是会被钉在同一信道，换 SSID 解决不了。因此生成器默认对新机设 `wireless.r3mini_phone_sta.disabled=1` 与 `r3mini_hotspot.main.enabled=0`。要让任一台跑热点 STA，先用 `SRC_CH5` 声明源机将要使用的信道重新生成片段，让闸门替你验算分频。

## 流程

以下步骤已在 2026-09-03 实机执行通过。逐步执行，每步取到判据再进下一步。

**先读三条前置事实，跳过其中任何一条都会在后面炸掉：**

1. **出厂机 SSH 只接受 `none` 认证。** root 无密码时 dropbear 拒绝密码认证，`router_readonly.py` 会打印 `SSH_LOGIN_FAILED`。用 `paramiko` 的 `transport.auth_none("root")` 连接。设备设了密码之后反过来，`none` 通道关闭，改用密码。
2. **新机时钟不可信。** R3 Mini 没有电池供电的 RTC，冷启动后时间退回固件构建日期。时钟落后会让 TLS 报 `certificate is not yet valid`，`opkg update` 全线失败。装任何东西之前先对时。
3. **OpenClash 版本以源机实况为准。** 不要照抄本仓库或任何文档里记的版本号，先只读回读源机的 `opkg list-installed | grep openclash`。版本错配会让 LuCI 整体崩溃。

### 1. 新机到手先只读预检

```bash
sh scripts/router/probe-new-device.sh
```

也可以从 Windows 侧驱动，不必先把脚本传上去：

```powershell
$env:ROUTER_CMD = Get-Content -Raw .\scripts\router\probe-new-device.sh
python .\openclash-ui-patch\router_readonly.py <新机IP>
```

**但出厂机跑不通这条 PowerShell 路径。** `router_readonly.py` 只做密码认证，而出厂 root 无密码时 dropbear 只接受 `none` 认证，会直接 `SSH_LOGIN_FAILED`（见前置事实 1）。出厂机上先用 `paramiko` 的 `transport.auth_none("root")` 自己连，或者把脚本内容粘到 LuCI 终端里跑。**等第 7 步设了 root 密码、并把密码按反引号写进 `docs/私密/商家交付信息.md`，上面这条 PowerShell 才可用**——第 11 步的验收就走它。

该脚本严格只读，不写文件、不改 UCI、不重启服务。输出 `CLONE_PRECHECK_BLOCKED` 时停止，先解决被阻断项。同时抄下它打印的 SSH 主机密钥指纹，填进 `docs/私密/router_known_hosts` 固定新机身份；`fan-dashboard/deploy_hotspot.py` 使用 `RejectPolicy`，主机密钥未固定时会直接拒绝连接。

### 2. 把 ImmortalWrt 刷进 eMMC

出厂机跑的是香蕉派自带的 OpenWrt 21.02-SNAPSHOT（内核 5.4.171、`board_name=bananapi,bpi-r3mini`、无线走联发科私有驱动因此 `/sys/class/ieee80211` 为空）。这套固件装不了源机那批包，必须先刷成与源机同版本的 ImmortalWrt。

**铁律：不能刷正在启动的那一块。** 要写 eMMC 就必须从 NAND 启动。板子左边缘的 `SW1` 拨动开关选启动介质，**断电后再拨**。出厂时 NAND 与 eMMC 各有一份可启动镜像，写 eMMC 期间 NAND 那套完好，刷坏了拨回 NAND 即可恢复。

确认当前确实从 NAND 启动（`/overlay` 挂在 `ubi0_2` 而不是 `mmcblk*`）后，从官方索引取五个文件，前缀均为 `immortalwrt-<版本>-mediatek-filogic-bananapi_bpi-r3-mini-`：`emmc-gpt.bin`、`emmc-preloader.bin`、`emmc-bl31-uboot.fip`、`initramfs-recovery.itb`、`squashfs-sysupgrade.itb`。下载后核对官方 SHA-256，上传到设备 `/tmp` 后**再核一次**。

分区对应关系不要猜，从 `emmc-gpt.bin` 解析。24.10.6 的布局是：

```text
p1 ubootenv     512 KB   （不写文件，留空）
p2 factory        2 MB   （不写文件，留空）
p3 fip            4 MB   <- emmc-bl31-uboot.fip
p4 recovery      32 MB   <- initramfs-recovery.itb
p5 production   300 MB   <- squashfs-sysupgrade.itb
```

`mmcblk0boot0`（4 MB）**不在上面这张表里**：它是 eMMC 的硬件 boot 分区，不属于 GPT 用户区地址空间，所以也没有分区号。写它之前必须先 `echo 0 > /sys/block/mmcblk0boot0/force_ro` 解锁，写入的是 `emmc-preloader.bin`。

两点容易被误读，先说清：

- **p1..p5 加起来只有 338.5 MiB，eMMC 用户区有 7456 MiB，约 95% 未分配，这是设计如此。** `production` 分区里的 f2fs overlay 已经给到 281 MB，够装源机那 386 个包（本次装完余 47 MB）。剩余空间上游镜像不分配，不需要你去扩。
- **p1 `ubootenv` 与 p2 `factory` 不写任何文件是正常的。** `ubootenv` 由 u-boot 首次启动时自行初始化；`factory` 在本板上是空的——实测源机 NAND 的 `Factory` 分区（mtd3）全是 `0xff`、克隆机 eMMC p2 全是 `0x00`，说明这块板子的无线校准数据不走这条路径，出厂固件的 WiFi 也正常工作。不要往 p2 里塞东西。

先写 GPT 到 `/dev/mmcblk0`（写前 `umount` 掉 eMMC 上的任何挂载），`blockdev --rereadpt /dev/mmcblk0` 重读分区表，再写其余四块，最后逐块 `head -c <size> <dev> | sha256sum` 回读比对。`mmc extcsd read /dev/mmcblk0` 里 `PARTITION_CONFIG: 0x48` 表示 Boot Partition 1 已使能，出厂即如此，不需要额外 `mmc bootpart enable`。

断电、把 `SW1` 拨到 eMMC、上电。判据是 `board_name` 变成 `bananapi,bpi-r3-mini`、`/overlay` 挂到 `/dev/fitrw`、`/sys/class/ieee80211` 出现 `phy0 phy1`。

### 3. 源机取证

用 `openclash-ui-patch/router_backup.py` 抓源机实况，不要用几周前的恢复点：

```bash
python .\openclash-ui-patch\router_backup.py 192.168.0.242 clone-source
```

它抓 `/etc/config` 全目录、`/etc/openclash`、`/etc/nikki`、三个 OpenClash lua 补丁和全部 r3mini 受管件，下载时校验 SHA-256，判据是 `ROUTER_BACKUP_OK`，产物落 `backups/router/`。

**别把它和 `scripts/router/backup-router.sh` 搞混。** 那是另一个工具：在**设备上**跑、判据是 `BACKUP_OK`、会额外产出 `custom-files.missing` 与 `CUSTOM_PATHS_MISSING=<数量>` 计数。本流程用的是前者，所以跑完不会有 `custom-files.missing` 这个文件可查；失败表里 `CUSTOM_PATHS_MISSING` 那一行只在你改用 `backup-router.sh` 时适用。

选它而不是 `sysupgrade -b` 有两个理由，一正一反：

- `sysupgrade -b` 的归档只有 75 条，**不含** `/etc/openclash`、也不含任何自定义二进制与 LuCI 页面，克隆出来缺代理配置和整个 LuCI 应用。
- `sysupgrade -b` 的归档**会**包含 `/etc/shadow`、`/etc/dropbear/*_host_key`、`/etc/uhttpd.{crt,key}`、`/etc/samba/secrets.tdb` —— 那些正是克隆时不该复制的设备身份。

`router_backup.py` 的清单里**这两类都没有**：它既抓全了应用文件，也不碰任何身份文件。代价是新机 root 恢复后仍无密码，须按第 7 步手工设置。

同时记下源机的 OpenClash 版本，后面要装同一版：

```bash
opkg list-installed | grep openclash
```

### 4. 对时并补装软件包

新机 WAN 口接上游拿到 DHCP 之后，**先对时再装包**：

```sh
date -u -s '<当前 UTC 时间>'
opkg update
```

判据是七个源全部 `Updated list of available packages`。跳过对时会得到 `wget returned 5` 与 `SSL verify error: certificate is not yet valid`。

按源机与新机的 `opkg list-installed` 差集补装。156 个包一次装容易超时，分批（每批约 30 个）前台执行；不要用 `nohup` 放后台——SSH 通道关闭时进程会被 SIGHUP 杀掉，实测一个包都装不上还不报错。

OpenClash 单独装，**版本以第 3 步读到的源机版本为准**。官方源里的版本通常落后（24.10.6 源里是 0.47.071），本仓库 `backups/router-20260719-175110-stable-current/installers/` 里那份是 0.47.133，两者都可能与源机不符。安装包放 `/root` 而不是 `/tmp`：OpenClash 的升级脚本会清 `/tmp`，把自己的安装包一起删掉，报 `wfopen: /tmp/....ipk: No such file or directory` 后安装失败。

装完用一个不依赖官方摘要的校验：比对新机与源机的 `/usr/share/openclash/openclash_version.lua` 哈希。两边逐位相同即可确认包是正确版本。

### 5. 生成身份改写片段

```bash
NEW_LAN_IP=192.168.0.246 NEW_HOSTNAME=immortalwrt-246 \
NEW_SSID_24=<新2.4G名> NEW_SSID_5=<新5G名> \
NEW_CH24=6 NEW_CH5=149 \
sh scripts/router/gen-clone-identity.sh > tmp/99-r3mini-clone-identity
```

`NEW_CH24` 默认 6、`NEW_CH5` 默认 149，可以不写；`NEW_ETH1_MAC` 与 `NEW_ULA` 不提供时随机生成并写死进产物。源机侧的对照值也都可以覆盖（`SRC_LAN_IP`、`SRC_HOSTNAME`、`SRC_ETH1_MAC`、`SRC_ETH0_MAC`、`SRC_SSID_24`、`SRC_SSID_5`、`SRC_ULA`、`SRC_CH24`、`SRC_CH5`），克隆的不是本文这两台时必须逐个改。

生成器把选定值打到 stderr，记进本次克隆记录：

```text
GEN_OK
NEW_LAN_IP=192.168.0.246
NEW_HOSTNAME=immortalwrt-246
NEW_ETH1_MAC=ca:c6:76:dd:5c:c3
NEW_ULA=fde0:18bf:bc66::/48
NEW_SSID_24=immortalwrt2-2.4
NEW_SSID_5=immortalwrt2-5.0
NEW_CH24=6
NEW_CH5=149 (中心 155，源机 48 中心 42)
```

任何一项与源机撞车都会被拒绝并以 rc=2 退出，产物不会生成（stdout 零字节）。闸门共 **18** 个拒绝点：

```text
 4  必填缺失      NEW_LAN_IP / NEW_HOSTNAME / NEW_SSID_24 / NEW_SSID_5
 2  随机源不可用  URANDOM_UNAVAILABLE_SET_NEW_ETH1_MAC / ..._SET_NEW_ULA
 8  与源机撞车    LAN_IP / HOSTNAME / SSID_24 / SSID_5 / ULA /
                  ETH1_MAC（对源机 eth1）/ ETH1_MAC_..._ETH0（对源机 eth0）/ CH24
 3  5 GHz 块判定  CH5_SAME_80MHZ_BLOCK / CH5_UNKNOWN_BLOCK / SRC_CH5_UNKNOWN_BLOCK
 1  MAC 格式      ETH1_MAC_NOT_LOCALLY_ADMINISTERED
```

### 6. 恢复配置并放置片段

第 3 步的 `router_backup.py` 会把归档下载到本仓库 `backups/router/router-backup-<时间戳>-<label>.tar.gz`，同时生成同名 `.sha256.txt`。把这个 tar 传到新机 `/tmp`（tmpfs，不占 overlay），下面统一称它 `/tmp/src.tar.gz`。

**清理动作的对象是解包出来的那份，不是新机的活系统。** 路径写错会先删掉新机自己的文件，再把源机的同名垃圾原样覆盖回去，清理白做还多一次破坏：

```sh
mkdir -p /tmp/restore
tar -xzf /tmp/src.tar.gz -C /tmp/restore ./files

rm -f /tmp/restore/files/etc/config/.*.uci-*
rm -rf /tmp/restore/files/etc/openclash/core/meta-backup

cp -a /tmp/restore/files/. /
sync
```

两处清理的理由：`.<包名>.uci-XXXXXX` 是源机 uci 事务残留（本次实测 14 个），带过去只是垃圾；`core/meta-backup` 是 OpenClash 内核的一份 10 MB 冗余副本，overlay 紧张时可省，不影响运行。

BusyBox 的 `find` **没有** `-delete` 动作（报 `find: unrecognized: -delete`），所以上面用 `rm -f` 配通配符而不是 `find -delete`。

然后把片段送上去。**这是全流程唯一阻止克隆机顶着源机身份上线的动作，别靠推断，照抄：**

```sh
# 在新机上执行（片段内容从 Windows 侧粘过来，或用 scp/cat 重定向送达）
mkdir -p /etc/uci-defaults
cat > /etc/uci-defaults/99-r3mini-clone-identity <<'FRAGMENT_EOF'
<把第 5 步生成的片段全文粘在这里>
FRAGMENT_EOF
chmod 755 /etc/uci-defaults/99-r3mini-clone-identity
sh -n /etc/uci-defaults/99-r3mini-clone-identity && echo FRAGMENT_SYNTAX_OK
ls -la /etc/uci-defaults/
```

**重启之前必须看到 `FRAGMENT_SYNTAX_OK`，且 `ls` 显示该文件存在、权限含执行位。** 三者缺一就不要重启：片段没落上、落错目录、或没有执行位，`uci-defaults` 都不会跑，磁盘上仍是源机的 `network.lan.ipaddr=192.168.0.242` 与 `eth1 macaddr=ca:1b:5c:14:93:4e`，重启后克隆机会直接以源机身份上到同一个 LAN，把源机撞下线。而且失败是静默的——失败的 `uci-defaults` 不会被删除，等你发现 `/etc/uci-defaults/` 非空时，现网已经撞过了。

确认无误后重启：

```sh
sync
reboot
```

### 7. 设置 root 密码

新机此时 root 仍无密码（配置归档不含 `/etc/shadow`，见第 3 步）。在重启后、做第 11 步验收之前设好：

```sh
passwd
```

然后把密码按反引号写进 `docs/私密/商家交付信息.md`（该路径已被根 `.gitignore` 忽略）。仓库的 `router_readonly.py` / `router_backup.py` / `deploy_hotspot.py` 都从那里提取候选密码，设完之后第 11 步的 PowerShell 验收路径才可用。

设密码之前设备只接受 SSH `none` 认证，设之后只接受密码认证，两者互斥——中间不要让自动化脚本卡在错误的认证方式上。

必须走 `uci-defaults`，不能恢复完再登录去改：恢复进去的是源机配置，此刻磁盘上的 `network.lan.ipaddr` 就是源机的地址。`uci-defaults` 由 `/etc/init.d/boot`（START=10）执行，早于 network（START=20），所以身份在网络起来之前就被改写，两台从不会同时以同一地址上线。实测重启后 42 秒直接以新地址出现。

片段执行成功后由系统自删，`ls /etc/uci-defaults/` 应为空；失败的 `uci-defaults` 不会被删除，会在每次启动时重试。

### 8. 补做服务自启

配置归档**不含 `/etc/rc.d/` 启动符号链接**，恢复后服务不会自启。实测重启后 `/etc/init.d/r3mini-fan status` 返回 `inactive` —— 也就是**温控没有在跑**。

要 enable 的只有 `r3mini-fan` 一个：

```sh
/etc/init.d/r3mini-fan enable
/etc/init.d/r3mini-fan start
```

其余服务不用管，理由逐个列清：`uhttpd`、`rpcd`、`dnsmasq`、`netdata`、`ttyd`、`samba4`、`openclash` 的启动链接由各自的 opkg 包在第 4 步安装时创建，本次实测重启后全部 `running`。**`r3mini-hotspot` 故意不 enable**：克隆机的手机热点 STA 已由身份片段禁用，而该 init 脚本会无条件拉起未验收的 `r3mini-egress-manager`（见第 10 步）。

判据是 `ls /etc/rc.d/ | grep r3mini-fan` 出现 `S99r3mini-fan`，且 `status` 返回 `running`。逐个复核所有服务：

```sh
for s in uhttpd rpcd dnsmasq openclash r3mini-fan netdata ttyd samba4; do
	printf '%-12s %s\n' "$s" "$(/etc/init.d/$s status 2>&1 | head -1)"
done
```

### 9. 确认无线信道已错开

信道由第 5 步的生成器写入，本节只做确认。`gen-clone-identity.sh` 用 `NEW_CH24`（默认 6）与 `NEW_CH5`（默认 149）设置两个 radio，并在生成阶段就拦截同块：

```text
GEN_REFUSED=CH24_SAME_AS_SOURCE=12
GEN_REFUSED=CH5_SAME_80MHZ_BLOCK=src:48(中心42) new:36(中心42) 同块等于没错开
GEN_REFUSED=CH5_UNKNOWN_BLOCK=50 不是已知 HE80 块内信道
```

5 GHz 判的是**块**不是信道号：HE80 以四连信道为一块（`36/40/44/48` 中心 42、`52/56/60/64` 中心 58、`149/153/157/161` 中心 155 等），同块内换信道号占用的频谱完全相同，等于没错开。中国频段下非 DFS 的完整 80 MHz 块只有中心 42 与中心 155 两个。

本次取值：源机 2.4G ch12 / 5G ch48（中心 42），克隆机 2.4G ch6 / 5G ch149（中心 155），间隔 485 MHz 不重叠。

**注意源机 5 GHz 有两个可能值**：手机热点 STA 关闭时 radio1 停在 48；STA 启用时 `r3mini_hotspot` 会把它拉到 `target_channel`（当前配置是 157，中心 155）。**157 与克隆机的 149 同块**。所以要给源机重新启用热点 STA 之前，必须先把克隆机挪出中心 155 那一块，否则两台完全同频。生成器的 `SRC_CH5` 变量就是为此准备的：把它设成源机将要使用的值再重新生成，闸门会替你拦住冲突。

### 10. 仅在走 `deploy_hotspot.py` 时：中和未验收的智能出口

本次克隆**没有触发这一步**。第 6 步是把源机备份覆盖过去，而源机上从未部署智能出口候选，所以克隆机上也没有这两个文件，无需中和。

只有当你改走「用仓库部署器装受管件」这条路时，本节才适用：`deploy_hotspot.py` 的 `FILES` 元组**无条件包含** `usr/sbin/r3mini-egress-manager` 与 `etc/hotplug.d/iface/95-r3mini-egress`，没有排除开关，会把从未上机验收的候选一并装上。

只把 `r3mini_hotspot.main.enabled` 设成 `0` **拦不住它**，原因有两条：

- `/etc/init.d/r3mini-hotspot` 的 `start_service()` 不读任何 `enabled` 选项，无条件把 `r3mini-egress-manager loop` 开成 procd 实例；`deploy-hotspot-router.sh` 结尾还会执行 `/etc/init.d/r3mini-hotspot enable` 与 `restart`。
- `/etc/hotplug.d/iface/95-r3mini-egress` 是 hotplug 脚本，与服务是否启用无关。`INTERFACE` 为 `wan` 或 `wwan` 且 `ACTION` 为 `ifup`/`ifupdate`/`update` 时，它直接调用 `r3mini-egress-manager event` 与 `wake`。

要让新机只保留热点 LuCI 页面而不运行该候选，部署后在新机执行：

```sh
/etc/init.d/r3mini-hotspot stop
/etc/init.d/r3mini-hotspot disable
rm -f /etc/hotplug.d/iface/95-r3mini-egress
```

代价是热点重连 watchdog 一并停止，LuCI 页面仍可打开但后台不工作。要保留 watchdog 而只停出口管理器，需要给 `/etc/init.d/r3mini-hotspot` 加一个 procd 实例开关——本仓库目前没有这个开关，不要靠手工改设备上的 init 脚本，那会在下次部署时被覆盖。

### 11. 验收

```bash
sh scripts/router/probe-new-device.sh
```

要拿到 `BLOCKED=0 WARNINGS=0 CLONE_PRECHECK_OK`，下面十项必须同时成立。左列标出该项不满足时是**阻断**（计入 `BLOCKED`，脚本 rc=1）还是**告警**（计入 `WARNINGS`，rc 仍为 0）：

```text
阻断  BOARD_MATCH=PASS
阻断  EMMC_SIZE_MATCH=PASS
阻断  MAC_COLLISION_WITH_SOURCE=NO
阻断  LAN_IP_COLLISION_WITH_SOURCE=NO
告警  RELEASE_MATCH=PASS
告警  KERNEL_MATCH=PASS
告警  RADIO_PATH_MATCH=PASS
告警  HOSTNAME_COLLISION_WITH_SOURCE=NO
告警  DHCP_SERVER_ACTIVE=NO
参考  CELLULAR_PRESENT=NO        （只报告，不计分）
```

只看 `CLONE_PRECHECK_OK` 不够：`WARNINGS` 非零时脚本仍以 rc=0 退出并打印 `CLONE_PRECHECK_OK_WITH_WARNINGS`，要的是 `WARNINGS=0`。

2026-09-03 实测结果是 `BLOCKED=0 WARNINGS=0 CLONE_PRECHECK_OK`，`MANAGED_FILES_PRESENT=14`。

该脚本只是克隆前的兼容性预检，**不覆盖**「必须改写的身份字段」那张表的大部分内容——它不校验 LAN 是否等于目标地址、不校验 NTP、`high_up`、两个信道、`r3mini_phone_sta`、OpenClash 版本、`/etc/rc.d/` 自启链接。那些按下面两段另行回读。

`MANAGED_FILES_PRESENT` 的预期值取决于智能出口候选在不在：从源机备份恢复得到 `14`（源机没有那两个文件）；走 `deploy_hotspot.py` 得到 `16`，执行了第 10 步的中和后是 `15`。该脚本只数文件存在与否，不判断服务是否运行，因此**它给不出「出口候选已中和」的结论**。要确认中和生效，另外只读回读：

```sh
/etc/init.d/r3mini-hotspot enabled; echo "SERVICE_ENABLED_RC=$?"
pgrep -f r3mini-egress-manager || echo NO_EGRESS_PROCESS
ls /etc/hotplug.d/iface/95-r3mini-egress 2>/dev/null || echo NO_EGRESS_HOTPLUG
```

**文件在不在还不够，要比对内容。** 把两台的受管件逐个 `sha256sum` 对照，本次 13 个文件全部逐位相同：三个 JS（含指纹副本）、两个菜单 json、两个 ACL、四个后端二进制、两个 init 脚本。

**14 和 13 是两套口径，不要相减。** `MANAGED_FILES_PRESENT=14` 是预检脚本在它内置的 16 条路径里数出来的存在数，那 16 条**含** `/etc/config/r3mini_fan` 与 `/etc/config/r3mini_hotspot`、**不含**指纹副本；哈希对照的 13 个是另一组，**含**指纹副本、**不含**那两个 `/etc/config/*`（它们是每台各自的配置，本来就该不同，比哈希没有意义）。

再做一次真实 HTTP 验证，静态资源不需要登录：

```sh
curl -o /dev/null -w '%{http_code} %{size_download}\n' \
  http://<新机IP>/luci-static/resources/view/system/r3mini-fan.js
```

最后对源机重跑一次只读复核，确认克隆过程没有改动源机。本次复核结果：源机 LAN、主机名、SSID、MAC、`high_up=40000`、OpenClash 运行状态均未变。

## 失败处理

| error_kind | 处置 | 实际输出 |
|---|---|---|
| `GEN_REFUSED=NEW_LAN_IP_REQUIRED` | 补齐必填参数后重跑生成器，退出码 2 | `GEN_REFUSED=NEW_LAN_IP_REQUIRED` |
| `GEN_REFUSED=LAN_IP_SAME_AS_SOURCE` | 换一个新机地址 | `GEN_REFUSED=LAN_IP_SAME_AS_SOURCE=192.168.0.242` |
| `GEN_REFUSED=ETH1_MAC_SAME_AS_SOURCE` | 换 MAC，或删掉 `NEW_ETH1_MAC` 让其随机生成 | `GEN_REFUSED=ETH1_MAC_SAME_AS_SOURCE=ca:1b:5c:14:93:4e` |
| `GEN_REFUSED=ETH1_MAC_NOT_LOCALLY_ADMINISTERED` | MAC 第二个十六进制位必须是 `2`/`6`/`a`/`e` | `GEN_REFUSED=ETH1_MAC_NOT_LOCALLY_ADMINISTERED=00:11:22:33:44:55 第二个十六进制位必须是 2/6/a/e` |
| `GEN_REFUSED=NEW_HOSTNAME_REQUIRED`、`NEW_SSID_24_REQUIRED`、`NEW_SSID_5_REQUIRED` | 同为必填缺失，补齐后重跑，rc=2 | `GEN_REFUSED=NEW_HOSTNAME_REQUIRED` |
| `GEN_REFUSED=HOSTNAME_SAME_AS_SOURCE` | 换新机主机名 | `GEN_REFUSED=HOSTNAME_SAME_AS_SOURCE=immortalwrt` |
| `GEN_REFUSED=SSID_24_SAME_AS_SOURCE` / `SSID_5_SAME_AS_SOURCE` | 换 SSID。同名同频会让客户端在两台间乱漫游 | `GEN_REFUSED=SSID_24_SAME_AS_SOURCE=immortalwrt-2.4` |
| `GEN_REFUSED=ULA_SAME_AS_SOURCE` | 换 ULA，或删掉 `NEW_ULA` 让其随机生成 | `GEN_REFUSED=ULA_SAME_AS_SOURCE=fdb9:15f7:169b::/48` |
| `GEN_REFUSED=CH24_SAME_AS_SOURCE` | 换 2.4G 信道 | `GEN_REFUSED=CH24_SAME_AS_SOURCE=12` |
| `GEN_REFUSED=ETH1_MAC_SAME_AS_SOURCE_ETH0` | 新机 eth1 不能等于源机的 **eth0** MAC，两个网口都要避开 | `GEN_REFUSED=ETH1_MAC_SAME_AS_SOURCE_ETH0=ca:1b:5c:14:93:4d` |
| `GEN_REFUSED=CH5_SAME_80MHZ_BLOCK` | 5 GHz 判块不判信道号，换到另一个 80 MHz 块 | `GEN_REFUSED=CH5_SAME_80MHZ_BLOCK=src:48(中心42) new:36(中心42) 同块等于没错开` |
| `GEN_REFUSED=CH5_UNKNOWN_BLOCK` | 新机信道不属于任何已知 HE80 四连块，换一个合法信道。合法值：36/40/44/48、52/56/60/64、100/104/108/112、116/120/124/128、132/136/140/144、149/153/157/161，以及只能跑 20 MHz 的 165 | `GEN_REFUSED=CH5_UNKNOWN_BLOCK=50 不是已知 HE80 块内信道` |
| `GEN_REFUSED=SRC_CH5_UNKNOWN_BLOCK` | **源机**信道不在上述表内，闸门无法判定是否同块，因此拒绝而不是放行。**不要为了过闸把 `SRC_CH5` 改成一个能过的值**——那是向闸门谎报源机信道，等于自己废掉这道检查。正确做法是先只读回读源机 `uci -q get wireless.radio1.channel` 拿到真值；若真值确实不在表内，说明它跑在非标准信道上，此时手工核对两台频谱是否重叠 | `GEN_REFUSED=SRC_CH5_UNKNOWN_BLOCK=165 无法判定是否与新机同块`（该输出为旧版本；现版本已支持 165） |
| `GEN_REFUSED=URANDOM_UNAVAILABLE_SET_NEW_ETH1_MAC` / `..._SET_NEW_ULA` | 取不到随机源，改为显式提供 `NEW_ETH1_MAC` / `NEW_ULA` | 本机未复现，无实际输出可引 |
| `CLONE_PRECHECK_BLOCKED` | 看 `BLOCKED=` 上方各行定位被阻断项，解决后重跑，退出码 1 | `BLOCKED=2` / `WARNINGS=4` / `CLONE_PRECHECK_BLOCKED` |
| `BOARD_MISMATCH` | 型号不同，停止克隆 | `BOARD_MISMATCH=want:bananapi,bpi-r3-mini got:?` |
| `EMMC_SIZE_MISMATCH` | 分区布局不同，停止克隆 | `EMMC_SIZE_MISMATCH=want:15269888 got:?` |
| `MISSING_FROM_BACKUP` | 新增了受管件但没同步 `backup-router.sh` 的路径清单，补上后重跑测试，退出码 1 | `MISSING_FROM_BACKUP=/usr/sbin/r3mini-egress-manager` |
| `CUSTOM_PATHS_MISSING` 非 0 | 备份缺件。检查 `custom-files.missing` 内容，确认是设备上本就没有还是清单写错 | 备份脚本输出 `CUSTOM_PATHS_MISSING=<数量>` |
| `SSH_LOGIN_FAILED` | 出厂 root 无密码时 dropbear 只接受 SSH `none` 认证，`router_readonly.py` 只试密码认证。改用 `transport.auth_none("root")` | `SSH_LOGIN_FAILED`，rc=1 |
| `BadAuthenticationType` | 设备已设 root 密码，`none` 通道关闭。把密码按反引号写进 `docs/私密/商家交付信息.md`，仓库工具会自动取用 | `paramiko.ssh_exception.BadAuthenticationType: Bad authentication type; allowed types: ['publickey', 'password']` |
| `certificate is not yet valid` | 设备时钟落后于证书签发日期。先 `date -u -s` 对时再 `opkg update`，并确认 `system.ntp.enabled=1` | `opkg update` 报 `wget returned 5`；单独 wget 报 `SSL verify error: certificate is not yet valid` |
| `Unknown package` | `nikki` 与 `mihomo-meta` 不在 ImmortalWrt 24.10.6 任何官方源里。源机的 Nikki 本就停止且禁用，可跳过 | `Unknown package 'nikki'.` / `opkg_install_cmd: Cannot install package nikki.` |
| OpenClash 装包时自毁 | OpenClash 的升级脚本会清 `/tmp`，把自己的安装包删掉。把 ipk 放 `/root` 再装 | `wfopen: /tmp/luci-app-openclash_0.47.133_all.ipk: No such file or directory` / `Failed to extract maintainer scripts... Package debris may remain!` |
| `cannot open .../openclash_version.lua` | OpenClash 包版本与 LuCI controller 版本不匹配，LuCI 整体崩溃。装回与源机同版本的 OpenClash | `/usr/lib/lua/luci/ucodebridge.lua:23: cannot open /usr/share/openclash/openclash_version.lua: No such file or directory` |
| `HTTP error 404 while loading class file` | 菜单 json 的 view path 带缓存指纹后缀，需要同名 JS 副本。仓库已纳入该副本并由测试强制两份一致 | `HTTP error 404 while loading class file "/luci-static/resources/view/system/r3mini-fan-3848230b8f.js"` |
| 服务恢复后不自启 | 配置归档不含 `/etc/rc.d/`。按第 8 步 `enable` + `start` | `/etc/init.d/r3mini-fan status` 返回 `inactive`；`ls /etc/rc.d/ \| grep r3mini` 为空 |
| `find: unrecognized: -delete` | BusyBox 的 `find` 没有 `-delete`，改用 `rm -f` 配通配符。**路径必须指向解包出来的那份**：`rm -f /tmp/restore/files/etc/config/.*.uci-*`。写成 `/etc/config/...` 就是删新机自己的文件，正是第 6 步加粗警告的那种错法 | `find: unrecognized: -delete` |
| 后台装包一个都没装上 | `nohup` 挡不住 SSH 通道关闭时的 SIGHUP，进程被杀且不留日志。改前台分批 | 日志文件不存在、包数不变，但 `pgrep` 可能误报存活 |
| DPAPI 解密失败 | 归档只能由创建它的 Windows 用户解密。换用户或换机器都解不开，改用未加密的恢复点 | 本机未复现该失败，无实际输出可引 |

## 不随克隆带走的东西

- **智能出口候选**。`r3mini-egress-manager` 与 `95-r3mini-egress` 本地实现完成但从未部署、从未实机验收。源机上没有这两个文件，所以从源机备份恢复的克隆机也没有。只有改走 `deploy_hotspot.py` 才会被装上，那时按第 10 步中和。
- **OpenClash 订阅的自动拉取**。源机历史根因就是远端 `HTTP 429`，两台共用同一订阅可能加剧限流（**未在双机场景实测**）。新机先手动放配置，不要开自动更新。
- **设备身份文件**。`/etc/shadow`、`/etc/dropbear/*_host_key`、`/etc/uhttpd.{crt,key}`、`/etc/samba/secrets.tdb`。用 `router_backup.py` 时它们本就不在归档里；若改用 `sysupgrade -b` 的归档则必须显式删除，否则两台对外出示同一把 SSH 主机密钥与同一张 TLS 证书。
- **`/etc/config/dhcp` 的静态绑定**。指向 `192.168.101.x`，与当前网段不符，身份片段会清掉。
- **`/etc/config/` 下的 `.<包名>.uci-XXXXXX`**。uci 事务残留，本次实测有 14 个，恢复前删掉。

## 维护

`scripts/router/backup-router.sh` 与 `openclash-ui-patch/router_backup.py` 的路径清单都是手写的，曾漏掉全部热点受管件、也漏掉过 LuCI 指纹副本，两次都表现为**备份静默缺件、克隆后才炸**。新增受管件时必须同步四处：`fan-dashboard/router/` 源码树、对应 `deploy-*.sh` 的推送清单、`backup-router.sh` 的路径清单、`router_backup.py` 的路径清单。

```bash
sh scripts/router/test-backup-covers-managed-files.sh
```

该测试只读仓库文本、不连接设备。它先对 `backup-router.sh` 跑一次 `sh -n`（输出 `BACKUP_SYNTAX=PASS`），再跑六道覆盖面闸门；另外还打印 `BACKUP_PATHS` / `ROUTER_TREE_FILES` / `DEPLOY_PATHS` / `PYBACKUP_PATHS` 四个计数供人眼参考，**计数本身不参与判定**。六道闸门是：

```text
TREE_COVERED_BY_BACKUP      源码树每个文件都在 backup-router.sh 清单里
DEPLOY_COVERED_BY_BACKUP    部署推送的每个路径都在 backup-router.sh 清单里
DEPLOY_MATCHES_REPO_TREE    部署推送的每个路径在源码树里有对应文件
ALIAS_COPIES_CONSISTENT     带指纹后缀的副本与本体逐字节相同
TREE_COVERED_BY_PY_BACKUP   源码树每个文件也在 router_backup.py 清单里（该清单允许列目录，
                            例如 /etc/config 覆盖其下全部文件）
MENU_VIEWS_RESOLVE          菜单 json 声明的 view path 在源码树里能找到对应 JS
```

后三道都是 2026-09-03 那次事故之后加的。`ALIAS_COPIES_CONSISTENT` 与 `MENU_VIEWS_RESOLVE` 针对 404：菜单 json 指向 `system/r3mini-fan-3848230b8f`，该后缀从未进过 git、副本也不在任何清单里，部署或克隆都会得到一个指向空文件的菜单项。`TREE_COVERED_BY_PY_BACKUP` 针对的是更早那个盲区——测试原本只守 `backup-router.sh`，而本流程第 3 步推荐的抓取工具是 `router_backup.py`，它那份清单漏件不会被任何测试发现。六道都对反向用例验证过能正确失败并以 rc=1 退出。
