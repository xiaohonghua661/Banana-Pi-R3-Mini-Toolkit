#!/bin/sh
# 新机到手第一步：与源机做只读兼容性比对，判断能不能往下走克隆。
#
# 严格只读：不写文件、不改 UCI、不重启服务、不联网。可以在陌生设备上放心跑。
# 用法（三选一）：
#   1) 设备上直接跑：      sh /tmp/probe-new-device.sh
#   2) LuCI 终端粘贴全文
#   3) Windows 侧驱动：
#        $env:ROUTER_CMD = Get-Content -Raw .\scripts\router\probe-new-device.sh
#        python .\openclash-ui-patch\router_readonly.py <新机IP>
#
# 源机基线取自 backups/r3mini-stable-20260719-170136/{board.json,network.uci}
# 与 22:01 DPAPI 恢复点内的 /etc/config/*，可用同名环境变量覆盖。
set -u

SRC_BOARD_NAME="${SRC_BOARD_NAME:-bananapi,bpi-r3-mini}"
SRC_RELEASE="${SRC_RELEASE:-ImmortalWrt 24.10.6 r33869-cf234f8de6d5}"
SRC_KERNEL="${SRC_KERNEL:-6.6.133}"
SRC_LAN_IP="${SRC_LAN_IP:-192.168.0.242}"
SRC_ETH0_MAC="${SRC_ETH0_MAC:-ca:1b:5c:14:93:4d}"
SRC_ETH1_MAC="${SRC_ETH1_MAC:-ca:1b:5c:14:93:4e}"
SRC_RADIO0_PATH="${SRC_RADIO0_PATH:-platform/soc/18000000.wifi}"
SRC_RADIO1_PATH="${SRC_RADIO1_PATH:-platform/soc/18000000.wifi+1}"
SRC_EMMC_SECTORS="${SRC_EMMC_SECTORS:-15269888}"
# 仅供人眼参考，脚本不据此判定通过与否——包数会随每次装包合理浮动
# （2026-09-03 实测源机 386、克隆机 387）。不要把它当断言。
SRC_PKG_COUNT="${SRC_PKG_COUNT:-386}"
SRC_HOSTNAME="${SRC_HOSTNAME:-immortalwrt}"

blocked=0
warns=0

block() { printf '%s\n' "$1"; blocked=$((blocked + 1)); }
warn()  { printf '%s\n' "$1"; warns=$((warns + 1)); }

# 读文件；不存在或不可读时给 ?，不让缺失把整份报告打断。
get() { [ -r "$1" ] && cat "$1" 2>/dev/null || printf '?'; }
# 读 UCI；设备上没有 uci 或键不存在时同样给 ?，并吞掉 stderr。
u() { uci -q get "$1" 2>/dev/null || printf '?'; }

board="$(ubus call system board 2>/dev/null || printf '{}')"
jf() { printf '%s' "$board" | jsonfilter -e "$1" 2>/dev/null || true; }

echo '===== 身份 ====='
model="$(jf '@.model')"
board_name="$(jf '@.board_name')"
release="$(jf '@.release.description')"
kernel="$(jf '@.kernel')"
hostname="$(u system.@system[0].hostname)"
printf 'MODEL=%s\n'      "${model:-?}"
printf 'BOARD_NAME=%s\n' "${board_name:-?}"
printf 'RELEASE=%s\n'    "${release:-?}"
printf 'KERNEL=%s\n'     "${kernel:-?}"
printf 'HOSTNAME=%s\n'   "$hostname"

[ "$board_name" = "$SRC_BOARD_NAME" ] \
	&& echo 'BOARD_MATCH=PASS' \
	|| block "BOARD_MISMATCH=want:$SRC_BOARD_NAME got:${board_name:-?}"

[ "$release" = "$SRC_RELEASE" ] \
	&& echo 'RELEASE_MATCH=PASS' \
	|| warn "RELEASE_DIFF=want:$SRC_RELEASE got:${release:-?}"

[ "$kernel" = "$SRC_KERNEL" ] \
	&& echo 'KERNEL_MATCH=PASS' \
	|| warn "KERNEL_DIFF=want:$SRC_KERNEL got:${kernel:-?}"

echo
echo '===== 存储与分区 ====='
sectors="$(get /sys/class/block/mmcblk0/size)"
printf 'EMMC_SECTORS=%s\n' "$sectors"
if [ "$sectors" = '?' ]; then
	printf 'EMMC_BYTES=?\n'
else
	printf 'EMMC_BYTES=%s\n' "$((sectors * 512))"
fi
[ "$sectors" = "$SRC_EMMC_SECTORS" ] \
	&& echo 'EMMC_SIZE_MATCH=PASS' \
	|| block "EMMC_SIZE_MISMATCH=want:$SRC_EMMC_SECTORS got:$sectors"
printf 'MTD_PARTITIONS=%s\n' "$(grep -c '^mtd' /proc/mtd 2>/dev/null || printf '?')"
grep '^mtd' /proc/mtd 2>/dev/null | sed 's/^/  /'
free_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
printf 'OVERLAY_FREE_KB=%s\n' "${free_kb:-?}"

echo
echo '===== 网口与 MAC（源机 MAC 撞车检测）====='
e0="$(get /sys/class/net/eth0/address)"
e1="$(get /sys/class/net/eth1/address)"
printf 'ETH0_MAC=%s\n' "$e0"
printf 'ETH1_MAC=%s\n' "$e1"
if [ "$e0" = "$SRC_ETH0_MAC" ] || [ "$e1" = "$SRC_ETH1_MAC" ] \
	|| [ "$e0" = "$SRC_ETH1_MAC" ] || [ "$e1" = "$SRC_ETH0_MAC" ]; then
	block 'MAC_COLLISION_WITH_SOURCE=YES 两台同 LAN 并存时必须先改 MAC'
else
	echo 'MAC_COLLISION_WITH_SOURCE=NO'
fi

echo
echo '===== 无线 ====='
printf 'PHY_COUNT=%s\n' "$(ls /sys/class/ieee80211 2>/dev/null | wc -l | tr -d ' ')"
r0="$(u wireless.radio0.path)"
r1="$(u wireless.radio1.path)"
printf 'RADIO0_PATH=%s\n' "$r0"
printf 'RADIO1_PATH=%s\n' "$r1"
[ "$r0" = "$SRC_RADIO0_PATH" ] && [ "$r1" = "$SRC_RADIO1_PATH" ] \
	&& echo 'RADIO_PATH_MATCH=PASS' \
	|| warn "RADIO_PATH_DIFF=want:$SRC_RADIO0_PATH,$SRC_RADIO1_PATH got:$r0,$r1"
printf 'COUNTRY=%s\n' "$(u wireless.radio1.country)"

echo
echo '===== 蜂窝模块（本次克隆预期为无）====='
wdm="$(ls /dev/cdc-wdm* 2>/dev/null | tr '\n' ' ')"
if [ -n "$wdm" ]; then
	printf 'CELLULAR_PRESENT=YES devices=%s\n' "$wdm"
	echo 'CELLULAR_NOTE=新机有模块，可保留 network.RM500CNV 段'
else
	echo 'CELLULAR_PRESENT=NO'
	echo 'CELLULAR_NOTE=克隆时必须删掉 network.RM500CNV 整段，否则接口起不来'
fi

echo
echo '===== 当前网络（与源机地址撞车检测）====='
lan="$(u network.lan.ipaddr)"
printf 'LAN_IPADDR=%s\n' "$lan"
ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print "  BR_LAN_RUNTIME=" $2}'
[ "$lan" = "$SRC_LAN_IP" ] \
	&& block "LAN_IP_COLLISION_WITH_SOURCE=$SRC_LAN_IP" \
	|| echo 'LAN_IP_COLLISION_WITH_SOURCE=NO'
[ "$hostname" = "$SRC_HOSTNAME" ] \
	&& warn "HOSTNAME_COLLISION_WITH_SOURCE=$SRC_HOSTNAME" \
	|| echo 'HOSTNAME_COLLISION_WITH_SOURCE=NO'
ign="$(u dhcp.lan.ignore)"
printf 'DHCP_LAN_IGNORE=%s\n' "$ign"
[ "$ign" = '1' ] \
	&& echo 'DHCP_SERVER_ACTIVE=NO' \
	|| warn 'DHCP_SERVER_ACTIVE=YES 两台同 LAN 并存时新机必须设 dhcp.lan.ignore=1'

echo
echo '===== 是否已有本项目受管件（全新机应为 0）====='
present=0
for p in \
	/etc/config/r3mini_fan \
	/etc/init.d/r3mini-fan \
	/usr/sbin/r3mini-fanctl \
	/usr/sbin/r3mini-fan-web \
	/usr/share/luci/menu.d/luci-app-r3mini-fan.json \
	/usr/share/rpcd/acl.d/luci-app-r3mini-fan.json \
	/www/luci-static/resources/view/system/r3mini-fan.js \
	/etc/config/r3mini_hotspot \
	/etc/init.d/r3mini-hotspot \
	/usr/sbin/r3mini-hotspot-web \
	/usr/sbin/r3mini-hotspot-watchdog \
	/usr/sbin/r3mini-egress-manager \
	/etc/hotplug.d/iface/95-r3mini-egress \
	/usr/share/luci/menu.d/luci-app-r3mini-hotspot.json \
	/usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json \
	/www/luci-static/resources/view/network/r3mini-hotspot.js; do
	if [ -e "$p" ]; then
		printf '  EXISTS=%s\n' "$p"
		present=$((present + 1))
	fi
done
printf 'MANAGED_FILES_PRESENT=%s\n' "$present"

echo
echo '===== 软件包 ====='
pkgs="$(opkg list-installed 2>/dev/null | wc -l | tr -d ' ')"
printf 'PACKAGE_COUNT=%s (源机 %s)\n' "${pkgs:-?}" "$SRC_PKG_COUNT"
# 包名按实际安装名写：OpenClash 的包叫 luci-app-openclash，写成 openclash 会永远报 MISSING。
for s in luci-app-openclash nikki luci-compat netdata samba4-server; do
	opkg list-installed 2>/dev/null | grep -q "^$s " \
		&& printf 'PKG_%s=INSTALLED\n' "$s" \
		|| printf 'PKG_%s=MISSING\n' "$s"
done

echo
echo '===== SSH 主机密钥指纹（拿去 docs/私密/router_known_hosts 固定）====='
found_key=0
for k in /etc/dropbear/dropbear_ed25519_host_key /etc/dropbear/dropbear_rsa_host_key; do
	[ -e "$k" ] || continue
	found_key=1
	printf '  %s\n' "$(dropbearkey -y -f "$k" 2>/dev/null | grep -i fingerprint || printf 'FINGERPRINT_UNAVAILABLE')"
done
[ "$found_key" -eq 1 ] || echo '  NO_DROPBEAR_HOST_KEY'

echo
echo '===== 结论 ====='
echo '（本脚本是克隆前的兼容性预检，不是克隆后的整体验收。'
echo '  它不校验 LAN 是否等于目标地址、NTP、high_up、两个信道、'
echo '  r3mini_phone_sta、OpenClash 版本、/etc/rc.d/ 自启链接。'
echo '  这些须按 docs/必读/当前设备运行基线.md 的通过判据另行逐条回读。）'
printf 'BLOCKED=%s\n' "$blocked"
printf 'WARNINGS=%s\n' "$warns"
if [ "$blocked" -gt 0 ]; then
	echo 'CLONE_PRECHECK_BLOCKED'
	exit 1
fi
if [ "$warns" -gt 0 ]; then
	echo 'CLONE_PRECHECK_OK_WITH_WARNINGS'
	exit 0
fi
echo 'CLONE_PRECHECK_OK'
exit 0
