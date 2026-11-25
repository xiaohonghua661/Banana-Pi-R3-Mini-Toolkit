#!/bin/sh
# 生成新机专用的身份改写片段，输出到 stdout。
#
# 产物是一个 /etc/uci-defaults/99-r3mini-clone-identity 脚本：把它注入到要恢复的
# 配置归档里，新机首次启动会在网络起来之前改完身份，然后自删。
#
# 为什么必须走 uci-defaults 而不是「恢复完再登录去改」：
# sysupgrade -r 恢复的是源机配置，重启后新机会顶着源机的 MAC 与 192.168.0.242 上线，
# 两台同 LAN 时那一瞬间就已经撞了；等你能登录进去改，网络已经乱了。
#
# 用法：
#   NEW_LAN_IP=192.168.0.243 NEW_HOSTNAME=immortalwrt-2 \
#   NEW_SSID_24=nl-2.4b NEW_SSID_5=nl-5b \
#   sh scripts/router/gen-clone-identity.sh > tmp/99-r3mini-clone-identity
#
# 未提供的 MAC 与 ULA 会随机生成并写死进产物（产物是固定件，不是每次跑都变的模板）。
set -eu

# ---- 源机身份：新机的任何一项都不许和这里相同 ----
SRC_LAN_IP="${SRC_LAN_IP:-192.168.0.242}"
SRC_HOSTNAME="${SRC_HOSTNAME:-immortalwrt}"
SRC_ETH1_MAC="${SRC_ETH1_MAC:-ca:1b:5c:14:93:4e}"
SRC_ETH0_MAC="${SRC_ETH0_MAC:-ca:1b:5c:14:93:4d}"
SRC_SSID_24="${SRC_SSID_24:-immortalwrt-2.4}"
SRC_SSID_5="${SRC_SSID_5:-immortalwrt-5.0}"
SRC_ULA="${SRC_ULA:-fdb9:15f7:169b::/48}"
SRC_CH24="${SRC_CH24:-12}"
SRC_CH5="${SRC_CH5:-48}"

# ---- 新机身份 ----
NEW_LAN_IP="${NEW_LAN_IP:-}"
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
NEW_SSID_24="${NEW_SSID_24:-}"
NEW_SSID_5="${NEW_SSID_5:-}"
NEW_ETH1_MAC="${NEW_ETH1_MAC:-}"
NEW_ULA="${NEW_ULA:-}"
NEW_CH24="${NEW_CH24:-6}"
NEW_CH5="${NEW_CH5:-149}"

# ---- 行为开关 ----
DISABLE_DHCP="${DISABLE_DHCP:-1}"
DROP_CELLULAR="${DROP_CELLULAR:-1}"
DISABLE_PHONE_STA="${DISABLE_PHONE_STA:-1}"
REGEN_HOST_KEYS="${REGEN_HOST_KEYS:-1}"

die() { printf 'GEN_REFUSED=%s\n' "$1" >&2; exit 2; }

rand_hex() { od -An -N"$1" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'; }

# 必填项
[ -n "$NEW_LAN_IP" ]   || die 'NEW_LAN_IP_REQUIRED'
[ -n "$NEW_HOSTNAME" ] || die 'NEW_HOSTNAME_REQUIRED'
[ -n "$NEW_SSID_24" ]  || die 'NEW_SSID_24_REQUIRED'
[ -n "$NEW_SSID_5" ]   || die 'NEW_SSID_5_REQUIRED'

# 未给就随机生成：MAC 保持 locally-administered（首字节 bit1=1、bit0=0）
if [ -z "$NEW_ETH1_MAC" ]; then
	h="$(rand_hex 5)"
	[ -n "$h" ] || die 'URANDOM_UNAVAILABLE_SET_NEW_ETH1_MAC'
	NEW_ETH1_MAC="ca:$(echo "$h" | cut -c1-2):$(echo "$h" | cut -c3-4):$(echo "$h" | cut -c5-6):$(echo "$h" | cut -c7-8):$(echo "$h" | cut -c9-10)"
fi
if [ -z "$NEW_ULA" ]; then
	h="$(rand_hex 5)"
	[ -n "$h" ] || die 'URANDOM_UNAVAILABLE_SET_NEW_ULA'
	NEW_ULA="fd$(echo "$h" | cut -c1-2):$(echo "$h" | cut -c3-6):$(echo "$h" | cut -c7-10)::/48"
fi

# 撞车闸门：任何一项与源机相同都拒绝出片段，这是「避免手改漏项」的实处
[ "$NEW_LAN_IP"   != "$SRC_LAN_IP" ]   || die "LAN_IP_SAME_AS_SOURCE=$SRC_LAN_IP"
[ "$NEW_HOSTNAME" != "$SRC_HOSTNAME" ] || die "HOSTNAME_SAME_AS_SOURCE=$SRC_HOSTNAME"
[ "$NEW_SSID_24"  != "$SRC_SSID_24" ]  || die "SSID_24_SAME_AS_SOURCE=$SRC_SSID_24"
[ "$NEW_SSID_5"   != "$SRC_SSID_5" ]   || die "SSID_5_SAME_AS_SOURCE=$SRC_SSID_5"
[ "$NEW_ULA"      != "$SRC_ULA" ]      || die "ULA_SAME_AS_SOURCE=$SRC_ULA"
[ "$NEW_ETH1_MAC" != "$SRC_ETH1_MAC" ] || die "ETH1_MAC_SAME_AS_SOURCE=$SRC_ETH1_MAC"
[ "$NEW_ETH1_MAC" != "$SRC_ETH0_MAC" ] || die "ETH1_MAC_SAME_AS_SOURCE_ETH0=$SRC_ETH0_MAC"
[ "$NEW_CH24"     != "$SRC_CH24" ]     || die "CH24_SAME_AS_SOURCE=$SRC_CH24"

# 5 GHz 判的不是「信道不同」而是「不落在同一个 80 MHz 块」。HE80 以四连信道
# 为一块，块内任意两个信道占用完全相同的 5735–5815 之类跨度，换信道号不换块
# 等于没错开。返回块中心信道号，取不到则回 unknown（未知不放行）。
ch5_block() {
	case "$1" in
		36|40|44|48)      echo 42 ;;
		52|56|60|64)      echo 58 ;;
		100|104|108|112)  echo 106 ;;
		116|120|124|128)  echo 122 ;;
		132|136|140|144)  echo 138 ;;
		149|153|157|161)  echo 155 ;;
		# 165 在中国频段只能跑 20 MHz，凑不满 HE80 四连块，因此不与任何
		# 80 MHz 块重叠。给它一个独有值，永远不会与上面任何中心相等。
		165)              echo narrow165 ;;
		*)                echo unknown ;;
	esac
}
_sb="$(ch5_block "$SRC_CH5")"
_nb="$(ch5_block "$NEW_CH5")"
[ "$_nb" != unknown ] || die "CH5_UNKNOWN_BLOCK=$NEW_CH5 不是已知 HE80 块内信道"
[ "$_sb" != unknown ] || die "SRC_CH5_UNKNOWN_BLOCK=$SRC_CH5 无法判定是否与新机同块"
[ "$_nb" != "$_sb" ] || die "CH5_SAME_80MHZ_BLOCK=src:$SRC_CH5(中心$_sb) new:$NEW_CH5(中心$_nb) 同块等于没错开"

case "$NEW_ETH1_MAC" in
	[0-9a-f][26ae]:*) : ;;
	*) die "ETH1_MAC_NOT_LOCALLY_ADMINISTERED=$NEW_ETH1_MAC 第二个十六进制位必须是 2/6/a/e" ;;
esac

cat <<GENEOF
#!/bin/sh
# 新机身份改写。由 scripts/router/gen-clone-identity.sh 生成。
# 放到 /etc/uci-defaults/99-r3mini-clone-identity；首次启动执行一次后由系统自删。
# 源机保持 $SRC_LAN_IP / $SRC_HOSTNAME / $SRC_ETH1_MAC 不变，本片段只改新机。
set -e

uci -q set network.lan.ipaddr='$NEW_LAN_IP'
uci -q set network.globals.ula_prefix='$NEW_ULA'
uci -q set system.@system[0].hostname='$NEW_HOSTNAME'
uci -q set wireless.default_radio0.ssid='$NEW_SSID_24'
uci -q set wireless.default_radio1.ssid='$NEW_SSID_5'
uci -q set wireless.radio0.channel='$NEW_CH24'
uci -q set wireless.radio1.channel='$NEW_CH5'

# 源机配置里 NTP 是关的；R3 Mini 没有电池供电的 RTC，照搬过去每次冷启动
# 时钟都会跑偏，TLS 会因「certificate is not yet valid」失败，opkg 与
# OpenClash 订阅一起崩。克隆到新机必须打开。
uci -q set system.ntp.enabled='1'

# eth1 的 macaddr 挂在匿名 device 段上，段号不固定，按 name 找。
i=0
while :; do
	n="\$(uci -q get network.@device[\$i].name)" || break
	[ -n "\$n" ] || break
	if [ "\$n" = 'eth1' ]; then
		uci -q set "network.@device[\$i].macaddr=$NEW_ETH1_MAC"
		break
	fi
	i=\$((i + 1))
done
GENEOF

if [ "$DISABLE_DHCP" = '1' ]; then
	cat <<'GENEOF'

# 两台同 LAN 并存：新机不发地址，否则客户端会随机拿到两套网关。
uci -q set dhcp.lan.ignore='1'
GENEOF
fi

if [ "$DROP_CELLULAR" = '1' ]; then
	cat <<'GENEOF'

# 新机无 5G 模块：删掉蜂窝接口，否则接口起不来且出口探针一直报错。
uci -q delete network.RM500CNV || true
GENEOF
fi

if [ "$DISABLE_PHONE_STA" = '1' ]; then
	cat <<'GENEOF'

# 手机热点 STA 会把 5 GHz AP 钉到热点所在信道；两台都连同一部手机时必然同频打架。
# 加 || true：热点段可能尚未部署到新机，缺段不该让 uci-defaults 整体失败——
# 失败的 uci-defaults 不会被删除，会在每次启动时重试。
uci -q set wireless.r3mini_phone_sta.disabled='1' || true
uci -q set r3mini_hotspot.main.enabled='0' || true

# 注意：main.enabled=0 只关热点业务逻辑，拦不住未验收的智能出口候选。
# /etc/init.d/r3mini-hotspot 的 start_service 无条件把 r3mini-egress-manager
# 开成 procd 实例，且 /etc/hotplug.d/iface/95-r3mini-egress 与服务开关无关，
# WAN 一 ifup 就会直接调用它。要中和必须在部署之后另做，见
# docs/克隆到第二台 R3 Mini.md 的「中和未验收的智能出口」。
GENEOF
fi

cat <<'GENEOF'

uci commit network
uci commit wireless
uci commit system
uci commit dhcp
uci commit r3mini_hotspot 2>/dev/null || true
GENEOF

if [ "$REGEN_HOST_KEYS" = '1' ]; then
	cat <<'GENEOF'

# 恢复归档带着源机的 SSH 主机密钥与 TLS 证书；删掉让新机首启自行重生，
# 否则两台对外出示同一把主机密钥，部署器的主机密钥固定机制形同虚设。
rm -f /etc/dropbear/dropbear_*_host_key
rm -f /etc/uhttpd.crt /etc/uhttpd.key
rm -f /etc/samba/secrets.tdb /etc/samba/smbpasswd
GENEOF
fi

cat <<'GENEOF'

# 源机遗留的静态绑定指向 192.168.101.x，与当前网段不符，带过来只会更乱。
while uci -q delete dhcp.@host[0]; do :; done
uci commit dhcp

exit 0
GENEOF

{
	printf '\n'
	printf 'GEN_OK\n'
	printf 'NEW_LAN_IP=%s\n'   "$NEW_LAN_IP"
	printf 'NEW_HOSTNAME=%s\n' "$NEW_HOSTNAME"
	printf 'NEW_ETH1_MAC=%s\n' "$NEW_ETH1_MAC"
	printf 'NEW_ULA=%s\n'      "$NEW_ULA"
	printf 'NEW_SSID_24=%s\n'  "$NEW_SSID_24"
	printf 'NEW_SSID_5=%s\n'   "$NEW_SSID_5"
	printf 'NEW_CH24=%s\n'     "$NEW_CH24"
	printf 'NEW_CH5=%s (块 %s，源机 %s 块 %s)\n' "$NEW_CH5" "$_nb" "$SRC_CH5" "$_sb"
} >&2
