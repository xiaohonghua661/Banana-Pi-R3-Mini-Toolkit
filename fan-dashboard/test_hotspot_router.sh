#!/bin/sh
# 在路由器上跑的沙箱测试：r3mini-hotspot-web、r3mini-hotspot-watchdog、status.uc。
# 配置全是假数据，放在 /tmp/r3hs-test.*；wifi、ifup、iw、ip、ubus 等都换成桩，不碰真实配置、无线和路由。
# 用法（由 test_hotspot_backend.py 上传并调用）：sh test_hotspot_router.sh <web> <watchdog> <status.uc>
# 输出每项 PASS/FAIL，最后一行 RESULT pass=N fail=M；有失败时退出码 1。

WEB="$1"; WD="$2"; UC="$3"
T="$(mktemp -d /tmp/r3hs-test.XXXXXX)" || exit 2
SIM="$T/sim"
mkdir -p "$T/conf" "$T/state" "$T/lock" "$T/initd" "$T/bin" "$SIM" "$T/sysnet" "$T/fakeroot/tmp/run"
export R3HS_CONF_DIR="$T/conf" R3HS_STATE_DIR="$T/state" R3HS_LOCK_DIR="$T/lock" R3HS_INITD="$T/initd"
export R3HS_PATH="$T/bin" R3HS_STATUS_UC="$UC" R3HS_CONNECT_WAIT=3 R3HS_TTYS='' R3HS_SIM="$SIM"
# 本机 AP 网卡放在 $T/sysnet；「/tmp」换成 $T/fakeroot/tmp，用来模拟它被改成 0700。
export R3HS_SYSNET="$T/sysnet" R3HS_AP_WAIT=4 R3HS_DAEMON_DIRS="$T/fakeroot/tmp:1777 $T/fakeroot/tmp/run:755"
# hostapd 报告的 AP 状态换成文件；ifup 后不用等 netifd。
export R3HS_AP_STATE_DIR="$T/apstate" R3HS_SETTLE=0
mkdir -p "$T/apstate"
trap 'rm -rf "$T"; rm -f /tmp/r3mini-hotspot-key-r3hstest*' 0

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want [$3] got [$2]"; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] lacks [$3]" ;; esac; }
u() { uci -c "$T/conf" -P "$T/conf/.uci" -q get "$1"; }
conf_sum() { cat "$T/conf/network" "$T/conf/wireless" "$T/conf/firewall" "$T/conf/r3mini_hotspot" | md5sum | cut -c1-32; }
web() { sh "$WEB" "$@"; }
job() { jsonfilter -i "$T/state/r3mini-hotspot-job.json" -e "@.$1" 2>/dev/null; }
wait_job() {
	local i=0
	while [ "$i" -lt 60 ]; do
		[ "$(job state)" != running ] && return 0
		sleep 1; i=$((i + 1))
	done
	return 1
}
keyfile() {
	# 页面传密码的临时文件；名字必须是 /tmp/r3mini-hotspot-key-<16 位十六进制>。
	local f="/tmp/r3mini-hotspot-key-$(tr -d '-' < /proc/sys/kernel/random/uuid | cut -c1-16)"
	printf '%s' "$1" > "$f"
	printf '%s' "$f"
}
calls() { cat "$SIM/calls" 2>/dev/null | tr '\n' ';'; }

reset_world() {
	rm -rf "$T/conf"/* "$T/conf/.uci" "$T/state"/* "$T/lock"/* "$SIM"/state_*
	: > "$SIM/calls"
	rm -f "$SIM/wwan_up" "$SIM/connect_ok" "$SIM/fail_reconf" "$SIM/scan_delay" "$SIM/ap_fail" "$SIM/ap_fail_once"
	touch "$T/sysnet/phy0-ap0" "$T/sysnet/phy1-ap0"
	echo ENABLED > "$T/apstate/phy0-ap0"; echo ENABLED > "$T/apstate/phy1-ap0"
	chmod 1777 "$T/fakeroot/tmp"; chmod 755 "$T/fakeroot/tmp/run"
	cat > "$T/conf/network" <<'EOF'
config interface 'lan'
	option device 'br-lan'
	option proto 'static'

config interface 'wan'
	option device 'eth1'
	option proto 'dhcp'
	option metric '5'

config interface 'RM500CNV'
	option proto 'quectel'
	option device '/dev/cdc-wdm0'
	option metric '20'
EOF
	cat > "$T/conf/wireless" <<'EOF'
config wifi-device 'radio0'
	option band '2g'
	option channel '12'
	option htmode 'HE20'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'immortalwrt-2.4'

config wifi-device 'radio1'
	option band '5g'
	option channel '48'
	option htmode 'HE80'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'immortalwrt-5.0'

config wifi-iface 'r3mini_phone_sta'
	option device 'radio1'
	option mode 'sta'
	option network 'wwan'
	option ssid 'nl'
	option encryption 'sae-mixed'
	option disabled '1'
EOF
	# 假密码用命令写，避免提交闸门把它当成真凭据。
	uci -c "$T/conf" -P "$T/conf/.uci" set wireless.r3mini_phone_sta.key=oldpassword
	uci -c "$T/conf" -P "$T/conf/.uci" commit wireless
	cat > "$T/conf/firewall" <<'EOF'
config zone
	option name 'lan'
	list network 'lan'

config zone
	option name 'wan'
	list network 'wan'
	list network 'RM500CNV'
EOF
	cat > "$T/conf/r3mini_hotspot" <<'EOF'
config hotspot 'main'
	option enabled '0'
	option radio 'radio1'
	option interface 'wwan'
	option check_interval '20'
	option failure_limit '3'
	option cooldown '180'
	option preferred_egress 'wan'
EOF
	printf 'default via 192.168.0.254 dev eth1 src 192.168.0.29 metric 5\n' > "$SIM/routes"
}

# ---------- 桩 ----------
cat > "$SIM/scan5.json" <<'EOF'
{ "results": [
 { "ssid": "Phone5G", "channel": 44, "signal": -50, "encryption": { "enabled": true, "wpa": [ 2 ], "authentication": [ "psk", "sae" ] } },
 { "ssid": "Phone5G", "channel": 40, "signal": -80, "encryption": { "enabled": true, "wpa": [ 2 ], "authentication": [ "psk", "sae" ] } },
 { "ssid": "Open5G", "channel": 149, "signal": -60, "encryption": { "enabled": false } },
 { "ssid": "DFS5G", "channel": 52, "signal": -55, "encryption": { "enabled": true, "wpa": [ 2 ], "authentication": [ "psk" ] } },
 { "ssid": "Corp", "channel": 36, "signal": -58, "encryption": { "enabled": true, "wpa": [ 2 ], "authentication": [ "802.1x" ] } },
 { "ssid": "a'b $(touch /tmp/r3hs-pwned) \"q\"", "channel": 36, "signal": -61, "encryption": { "enabled": true, "wpa": [ 1, 2 ], "authentication": [ "psk" ] } }
] }
EOF
cat > "$SIM/scan2.json" <<'EOF'
{ "results": [
 { "ssid": "Home24", "channel": 6, "signal": -45, "encryption": { "enabled": true, "wpa": [ 2 ], "authentication": [ "psk" ] } }
] }
EOF
cat > "$SIM/wireless_status.json" <<'EOF'
{ "radio0": { "interfaces": [ { "section": "default_radio0", "ifname": "phy0-ap0" } ] },
  "radio1": { "interfaces": [ { "section": "default_radio1", "ifname": "phy1-ap0" }, { "section": "r3mini_phone_sta", "ifname": "phy1-sta0" } ] } }
EOF

cat > "$T/bin/ubus" <<'EOF'
#!/bin/sh
[ "$1" = -t ] && shift 2
[ -f "$R3HS_SIM/scan_delay" ] && sleep "$(cat "$R3HS_SIM/scan_delay")"
case "$1 $2 $3" in
	"call iwinfo scan")
		case "$4" in *phy1-ap0*) cat "$R3HS_SIM/scan5.json" ;; *phy0-ap0*) cat "$R3HS_SIM/scan2.json" ;; *) exit 4 ;; esac ;;
	"call network.wireless status") cat "$R3HS_SIM/wireless_status.json" ;;
	*) exit 3 ;;
esac
EOF
cat > "$T/bin/wifi" <<'EOF'
#!/bin/sh
# 重配一个频段：本机 AP 网卡先消失再重建。像真机那样，「/tmp」别人进不去、或设了 ap_fail 时就建不起来。
echo "wifi $*" >> "$R3HS_SIM/calls"
[ "$1" = reconf ] && [ -f "$R3HS_SIM/fail_reconf" ] && exit 1
if [ "$1" = reconf ]; then
	case "$2" in radio0) ap=phy0-ap0 ;; radio1) ap=phy1-ap0 ;; *) ap='' ;; esac
	if [ -n "$ap" ]; then
		rm -f "$R3HS_SYSNET/$ap"
		perm="$(ls -ld "${R3HS_DAEMON_DIRS%%:*}" | cut -c10)"
		if [ -f "$R3HS_SIM/ap_fail_once" ]; then
			rm -f "$R3HS_SIM/ap_fail_once"
		elif [ ! -f "$R3HS_SIM/ap_fail" ] && { [ "$perm" = t ] || [ "$perm" = x ]; }; then
			touch "$R3HS_SYSNET/$ap"
		fi
	fi
fi
[ -f "$R3HS_SIM/connect_ok" ] && touch "$R3HS_SIM/wwan_up"
exit 0
EOF
cat > "$T/bin/ifstatus" <<'EOF'
#!/bin/sh
case "$1" in
	wan) echo '{"up":true,"ipv4-address":[{"address":"192.168.0.29"}],"l3_device":"eth1","route":[{"target":"0.0.0.0","nexthop":"192.168.0.254"}]}' ;;
	wwan)
		if [ -f "$R3HS_SIM/wwan_up" ]; then
			echo '{"up":true,"ipv4-address":[{"address":"172.20.10.2"}],"l3_device":"phy1-sta0","route":[{"target":"0.0.0.0","nexthop":"172.20.10.1"}]}'
		else
			echo '{"up":false,"pending":true}'
		fi ;;
	RM500CNV) echo '{"up":false,"pending":true}' ;;
	*) echo "Interface $1 not found"; exit 1 ;;
esac
EOF
cat > "$T/bin/iw" <<'EOF'
#!/bin/sh
case "$1 $3" in
	"dev link") [ -f "$R3HS_SIM/wwan_up" ] && echo "Connected to 02:00:00:00:00:01 (on $2)" ;;
	"dev info") echo "	channel 48 (5240 MHz), width: 80 MHz" ;;
esac
exit 0
EOF
cat > "$T/bin/ip" <<'EOF'
#!/bin/sh
# 只模拟 ip -4 route {show,del,add} default，路由表在 $R3HS_SIM/routes，按 metric 排序。
R="$R3HS_SIM/routes"
[ "$1" = -4 ] && shift
[ "$1" = route ] || exit 0
op="$2"; shift 2
sorted() { awk '{ m = 0; for (i = 1; i <= NF; i++) if ($i == "metric") m = $(i + 1); print m "\t" $0 }' "$R" | sort -n | cut -f2-; }
case "$op" in
	show)
		[ "$2" = dev ] && { sorted | grep " dev $3 "; exit 0; }
		sorted ;;
	del)
		line="$(grep -n " dev $3 " "$R" | head -n 1 | cut -d: -f1)"
		[ -n "$line" ] || exit 2
		sed -i "${line}d" "$R" ;;
	add) echo "$*" >> "$R" ;;
esac
EOF
for c in ifup ifdown; do
	printf '#!/bin/sh\necho "%s $*" >> "$R3HS_SIM/calls"\n[ "%s $1" = "ifup wwan" ] && [ -f "$R3HS_SIM/connect_ok" ] && touch "$R3HS_SIM/wwan_up"\nexit 0\n' "$c" "$c" > "$T/bin/$c"
done
printf '#!/bin/sh\necho "logger $*" >> "$R3HS_SIM/calls"\n' > "$T/bin/logger"
for s in firewall r3mini-hotspot; do
	printf '#!/bin/sh\necho "initd %s $*" >> "$R3HS_SIM/calls"\n' "$s" > "$T/initd/$s"
done
chmod +x "$T/bin"/* "$T/initd"/*

# ---------- 用例 ----------

reset_world
echo "== 状态"
s="$(date +%s%N 2>/dev/null)"
out="$(web status)"
expect status_version "$(printf '%s' "$out" | jsonfilter -e '@.version')" 2
expect status_wifi_ssid "$(printf '%s' "$out" | jsonfilter -e '@.wifi.ssid')" nl
expect status_radios "$(printf '%s' "$out" | jsonfilter -e '@.radios[*].name' | tr '\n' ' ')" 'radio0 radio1 '
expect status_cell_iface "$(printf '%s' "$out" | jsonfilter -e '@.cellular.iface')" RM500CNV
expect status_preferred "$(printf '%s' "$out" | jsonfilter -e '@.preferred')" wan
out="$(web scan radio1)"
expect scan_raw_passthrough "$(printf '%s' "$out" | jsonfilter -e '@.results[0].ssid')" Phone5G
web scan radio9 >/dev/null 2>&1 && bad scan_rejects_bad_radio || ok scan_rejects_bad_radio

echo "== 连接新 Wi-Fi（5 GHz，WPA2/WPA3）"
reset_world
touch "$SIM/connect_ok"
k="$(keyfile 'secret-pass-1')"
out="$(web save radio1 Phone5G "$k")"
expect save_returns_running_job "$(printf '%s' "$out" | jsonfilter -e '@.job.action')" save
[ -e "$k" ] && bad save_moves_key_file || ok save_moves_key_file
wait_job
expect save_job_done "$(job state)" done
contains save_job_message "$(job message)" '已连上「Phone5G」'
expect save_sta_radio "$(u wireless.r3mini_phone_sta.device)" radio1
expect save_sta_ssid "$(u wireless.r3mini_phone_sta.ssid)" Phone5G
expect save_sta_enc "$(u wireless.r3mini_phone_sta.encryption)" sae-mixed
expect save_sta_key "$(u wireless.r3mini_phone_sta.key)" secret-pass-1
expect save_sta_enabled "$(u wireless.r3mini_phone_sta.disabled)" 0
expect save_channel_follows_strongest "$(u wireless.radio1.channel)" 44
expect save_remembers_original "$(u r3mini_hotspot.main.original_channel_radio1)" 48
expect save_enabled "$(u r3mini_hotspot.main.enabled)" 1
expect save_wwan_iface "$(u network.wwan.proto)" dhcp
contains save_firewall_zone "$(u firewall.@zone[1].network)" wwan
contains save_reconf_radio1 "$(calls)" 'wifi reconf radio1'
contains save_firewall_reload_first_time "$(calls)" 'initd firewall reload'
contains save_restarts_watchdog "$(calls)" 'initd r3mini-hotspot restart'
contains save_ifup_wwan "$(calls)" 'wifi reconf radio1;ifup wwan'
[ -e "$T/state/r3mini-hotspot-job.key" ] && bad save_deletes_job_key || ok save_deletes_job_key
[ -e "$T/lock/r3mini-hotspot-job" ] || [ -e "$T/lock/r3mini-hotspot-write" ] && bad save_releases_locks || ok save_releases_locks
out="$(web status)"
expect status_shows_job "$(printf '%s' "$out" | jsonfilter -e '@.job.state')" done

echo "== 换到 2.4 GHz，恢复 5 GHz 原信道"
: > "$SIM/calls"
k="$(keyfile 'home-pass-24')"
web save radio0 Home24 "$k" >/dev/null; wait_job
expect band_job_done "$(job state)" done
expect band_sta_radio "$(u wireless.r3mini_phone_sta.device)" radio0
expect band_radio0_channel "$(u wireless.radio0.channel)" 6
expect band_radio1_restored "$(u wireless.radio1.channel)" 48
expect band_radio1_memory_cleared "$(u r3mini_hotspot.main.original_channel_radio1)" ''
expect band_radio0_original "$(u r3mini_hotspot.main.original_channel_radio0)" 12
expect band_enc_psk2 "$(u wireless.r3mini_phone_sta.encryption)" psk2
contains band_reconf_both "$(calls)" 'wifi reconf radio1;wifi reconf radio0'
case "$(calls)" in *'initd firewall reload'*) bad band_no_second_firewall_reload ;; *) ok band_no_second_firewall_reload ;; esac

echo "== 同一个 Wi-Fi 不填密码：沿用已保存的"
k="$(keyfile 'x')"; rm -f "$k"
web save radio0 Home24 - >/dev/null; wait_job
expect same_ssid_reuses_key "$(u wireless.r3mini_phone_sta.key)" home-pass-24
expect same_ssid_done "$(job state)" done

echo "== 开放网络"
web save radio1 Open5G - >/dev/null; wait_job
expect open_done "$(job state)" done
expect open_enc_none "$(u wireless.r3mini_phone_sta.encryption)" none
expect open_key_removed "$(u wireless.r3mini_phone_sta.key)" ''
expect open_radio0_restored "$(u wireless.radio0.channel)" 12
expect open_radio1_channel "$(u wireless.radio1.channel)" 149

echo "== 拒绝并保持原配置"
reset_world
before="$(conf_sum)"
web save radio1 DFS5G - >/dev/null; wait_job
expect dfs_failed "$(job state)" failed
contains dfs_message "$(job message)" '信道 52'
web save radio1 Nowhere - >/dev/null; wait_job
contains missing_message "$(job message)" '没搜到「Nowhere」'
web save radio1 Corp - >/dev/null; wait_job
contains eap_message "$(job message)" '企业认证'
web save radio1 Phone5G - >/dev/null; wait_job
contains new_network_needs_key "$(job message)" '请输入这个 Wi-Fi 的密码'
k="$(keyfile 'short')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
contains short_key_rejected "$(job message)" '8–63'
expect rejects_keep_config "$(conf_sum)" "$before"
[ -e "$T/lock/r3mini-hotspot-write" ] && bad rejects_release_write_lock || ok rejects_release_write_lock
web save radio1 Phone5G /tmp/not-a-key >/dev/null 2>&1 && bad bad_key_path_rejected || ok bad_key_path_rejected
ln -s /etc/passwd /tmp/r3mini-hotspot-key-r3hstest00000000 2>/dev/null
web save radio1 Phone5G /tmp/r3mini-hotspot-key-r3hstest00000000 >/dev/null 2>&1 && bad symlink_key_rejected || ok symlink_key_rejected
web save radio1 "$(printf 'a\nb')" - >/dev/null 2>&1 && bad newline_ssid_rejected || ok newline_ssid_rejected

echo "== 特殊字符名称"
reset_world
touch "$SIM/connect_ok"
rm -f /tmp/r3hs-pwned
k="$(keyfile 'quote-pass-1')"
odd="a'b \$(touch /tmp/r3hs-pwned) \"q\""
web save radio1 "$odd" "$k" >/dev/null; wait_job
expect odd_done "$(job state)" done
expect odd_ssid_verbatim "$(u wireless.r3mini_phone_sta.ssid)" "$odd"
expect odd_enc_mixed "$(u wireless.r3mini_phone_sta.encryption)" psk-mixed
[ -e /tmp/r3hs-pwned ] && bad odd_no_command_exec || ok odd_no_command_exec

echo "== 重配失败自动回滚"
reset_world
before="$(conf_sum)"
touch "$SIM/fail_reconf"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect reconf_fail_state "$(job state)" failed
contains reconf_fail_message "$(job message)" '已恢复保存前的设置'
expect reconf_fail_restores_config "$(conf_sum)" "$before"
[ "$(grep -c 'wifi reconf radio1' "$SIM/calls")" -ge 2 ] && ok reconf_fail_reapplies_radio || bad reconf_fail_reapplies_radio "$(calls)"
[ -e "$T/state/r3mini-hotspot-job.key" ] && bad reconf_fail_deletes_key || ok reconf_fail_deletes_key

echo "== 没连上：保存成功但提示原因"
reset_world
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect noconnect_done "$(job state)" done
contains noconnect_message "$(job message)" '没连上「Phone5G」'

echo "== 停用"
: > "$SIM/calls"
web disable >/dev/null; wait_job
expect disable_done "$(job state)" done
expect disable_sta_off "$(u wireless.r3mini_phone_sta.disabled)" 1
expect disable_channel_restored "$(u wireless.radio1.channel)" 48
expect disable_enabled_0 "$(u r3mini_hotspot.main.enabled)" 0
contains disable_ifdown "$(calls)" 'ifdown wwan'
contains disable_reconf "$(calls)" 'wifi reconf radio1'

echo "== 旧版 original_channel 迁移"
reset_world
uci -c "$T/conf" -P "$T/conf/.uci" set r3mini_hotspot.main.original_channel=36
uci -c "$T/conf" -P "$T/conf/.uci" commit r3mini_hotspot
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect migrate_new_key "$(u r3mini_hotspot.main.original_channel_radio1)" 36
expect migrate_old_key_removed "$(u r3mini_hotspot.main.original_channel)" ''

echo "== 任务锁"
reset_world
sleep 300 &
holder=$!
printf '%s\n' "$holder" > "$T/lock/r3mini-hotspot-job"
web save radio1 Open5G - >/dev/null 2>&1 && bad busy_job_rejected || ok busy_job_rejected
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
web save radio1 Open5G - >/dev/null 2>&1; wait_job
expect stale_job_lock_recovered "$(job state)" done
mkdir "$T/lock/r3mini-hotspot-write"
web prefer auto >/dev/null 2>&1 && ok legacy_dir_lock_recovered || bad legacy_dir_lock_recovered
[ -e "$T/lock/r3mini-hotspot-write" ] && bad prefer_releases_lock || ok prefer_releases_lock

echo "== 任务进程被杀"
reset_world
echo 4 > "$SIM/scan_delay"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null
pid="$(job pid)"
kill -9 "$pid" 2>/dev/null
sleep 1
out="$(web status)"
expect killed_job_reported "$(printf '%s' "$out" | jsonfilter -e '@.job.state')" failed
contains killed_job_message "$(printf '%s' "$out" | jsonfilter -e '@.job.message')" '意外退出'
rm -f "$SIM/scan_delay"
web save radio1 Open5G - >/dev/null 2>&1; wait_job
expect after_kill_next_job_runs "$(job state)" done

echo "== 出口选择"
reset_world
touch "$SIM/wwan_up"
printf 'default via 172.20.10.1 dev phy1-sta0 src 172.20.10.2 metric 30\n' >> "$SIM/routes"
uci -c "$T/conf" -P "$T/conf/.uci" set network.wwan=interface
uci -c "$T/conf" -P "$T/conf/.uci" set network.wwan.proto=dhcp
uci -c "$T/conf" -P "$T/conf/.uci" commit network
web prefer hotspot >/dev/null
expect prefer_hotspot_saved "$(u r3mini_hotspot.main.preferred_egress)" hotspot
expect prefer_hotspot_metric "$(u network.wwan.metric)" 5
expect prefer_hotspot_wan_metric "$(u network.wan.metric)" 20
expect prefer_hotspot_route "$(ip_out="$(sh "$T/bin/ip" -4 route show default | head -n 1)"; printf '%s' "$ip_out" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')" phy1-sta0
web prefer wan >/dev/null
expect prefer_wan_route "$(sh "$T/bin/ip" -4 route show default | head -n 1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')" eth1
expect prefer_wan_routes_kept "$(wc -l < "$SIM/routes" | tr -d ' ')" 2
out="$(web prefer cellular 2>&1)" && bad prefer_offline_rejected || contains prefer_offline_rejected "$out" '蜂窝网络当前没有连上'
expect prefer_offline_keeps "$(u r3mini_hotspot.main.preferred_egress)" wan

echo "== 蜂窝拨号开关"
: > "$SIM/calls"
web cellular off >/dev/null
expect cellular_off_auto "$(u network.RM500CNV.auto)" 0
contains cellular_off_ifdown "$(calls)" 'ifdown RM500CNV'
web cellular on >/dev/null
expect cellular_on_auto "$(u network.RM500CNV.auto)" ''
contains cellular_on_ifup "$(calls)" 'ifup RM500CNV'
out="$(web status)"
expect status_cell_auto "$(printf '%s' "$out" | jsonfilter -e '@.cellular.auto')" true

echo "== /tmp 被改成 0700：重配前恢复，本机 AP 照常起来"
reset_world
chmod 700 "$T/fakeroot/tmp"
touch "$SIM/connect_ok"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect tmp_fix_job_done "$(job state)" done
expect tmp_fix_mode "$(ls -ld "$T/fakeroot/tmp" | cut -c1-10)" drwxrwxrwt
contains tmp_fix_reported "$(job message)" '已恢复'
[ -e "$T/sysnet/phy1-ap0" ] && ok tmp_fix_ap_up || bad tmp_fix_ap_up

echo "== 重配后本机 AP 没起来：回滚"
reset_world
before="$(conf_sum)"
touch "$SIM/ap_fail_once"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect ap_once_failed "$(job state)" failed
contains ap_once_message "$(job message)" '已恢复保存前的设置，本机 Wi-Fi 已回来'
expect ap_once_config_restored "$(conf_sum)" "$before"
[ -e "$T/sysnet/phy1-ap0" ] && ok ap_once_ap_back || bad ap_once_ap_back
reset_world
touch "$SIM/ap_fail"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect ap_hard_failed "$(job state)" failed
contains ap_hard_message "$(job message)" '恢复原设置后也没起来'
rm -f "$SIM/ap_fail"

echo "== 停用后本机 AP 没起来：再重配一次"
reset_world
touch "$SIM/connect_ok"
web save radio1 Open5G - >/dev/null; wait_job
: > "$SIM/calls"
touch "$SIM/ap_fail_once"
web disable >/dev/null; wait_job
expect disable_retry_done "$(job state)" done
[ "$(grep -c 'wifi reconf radio1' "$SIM/calls")" -ge 2 ] && ok disable_retry_reconf || bad disable_retry_reconf "$(calls)"
[ -e "$T/sysnet/phy1-ap0" ] && ok disable_retry_ap_up || bad disable_retry_ap_up

echo "== 本机 AP 不在时搜索与状态"
reset_world
rm -f "$T/sysnet/phy0-ap0"
out="$(web scan radio0 2>&1)" && bad scan_ap_down_rejected || contains scan_ap_down_rejected "$out" '没有运行'
out="$(web status)"
expect status_ap_down "$(printf '%s' "$out" | jsonfilter -e '@.radios[0].ap_up')" false
expect status_ap_up "$(printf '%s' "$out" | jsonfilter -e '@.radios[1].ap_up')" true
expect status_channel_from_uci "$(printf '%s' "$out" | jsonfilter -e '@.radios[0].channel')" 12

echo "== 看门狗：连不上就停靠，让本机 AP 恢复"
reset_world
uci -c "$T/conf" -P "$T/conf/.uci" set wireless.r3mini_phone_sta.ssid=Phone5G
uci -c "$T/conf" -P "$T/conf/.uci" set wireless.r3mini_phone_sta.disabled=0
uci -c "$T/conf" -P "$T/conf/.uci" set wireless.radio1.channel=36
uci -c "$T/conf" -P "$T/conf/.uci" commit wireless
uci -c "$T/conf" -P "$T/conf/.uci" set r3mini_hotspot.main.enabled=1
uci -c "$T/conf" -P "$T/conf/.uci" commit r3mini_hotspot
out="$(web status)"
expect status_ap_running_not_paused "$(printf '%s' "$out" | jsonfilter -e '@.radios[1].ap_paused')" false
echo DISABLED > "$T/apstate/phy1-ap0"
out="$(web status)"
expect status_ap_paused "$(printf '%s' "$out" | jsonfilter -e '@.radios[1].ap_paused')" true
expect status_ap_state "$(printf '%s' "$out" | jsonfilter -e '@.radios[1].ap_state')" DISABLED
echo ENABLED > "$T/apstate/phy1-ap0"
(
	R3HS_WATCHDOG_LIB=1 R3HS_WEB="$WEB"
	. "$WD"
	tick; tick; tick
	echo "rounds=$rounds" >> "$R3HS_SIM/calls"
)
contains watchdog_ifup_after_limit "$(calls)" 'ifup wwan'
contains watchdog_counts_round "$(calls)" 'rounds=1'
expect watchdog_not_parked_yet "$(u wireless.r3mini_phone_sta.disabled)" 0
: > "$SIM/calls"
(
	R3HS_WATCHDOG_LIB=1 R3HS_WEB="$WEB"
	. "$WD"
	tick; tick; tick; tick; tick; tick
)
expect watchdog_parks "$(u wireless.r3mini_phone_sta.disabled)" 1
expect watchdog_park_keeps_enabled "$(u r3mini_hotspot.main.enabled)" 1
contains watchdog_park_reconf "$(calls)" 'wifi reconf radio1'
contains watchdog_park_ifdown "$(calls)" 'ifdown wwan'
out="$(web status)"
expect status_parked "$(printf '%s' "$out" | jsonfilter -e '@.wifi.parked')" true
expect status_parked_ap_not_paused "$(printf '%s' "$out" | jsonfilter -e '@.radios[1].ap_paused')" false

echo "== 看门狗：停靠中搜到对方就重连，并跟到对方信道"
: > "$SIM/calls"
(
	R3HS_WATCHDOG_LIB=1 R3HS_WEB="$WEB"
	. "$WD"
	tick
)
expect watchdog_unparks "$(u wireless.r3mini_phone_sta.disabled)" 0
expect watchdog_unpark_channel "$(u wireless.radio1.channel)" 44
expect watchdog_unpark_target "$(u r3mini_hotspot.main.target_channel)" 44
contains watchdog_unpark_reconf "$(calls)" 'wifi reconf radio1'
contains watchdog_unpark_ifup "$(calls)" 'ifup wwan'
case "$(calls)" in *'wifi down'*) bad watchdog_no_wifi_down ;; *) ok watchdog_no_wifi_down ;; esac
: > "$SIM/calls"
uci -c "$T/conf" -P "$T/conf/.uci" set wireless.r3mini_phone_sta.disabled=1
uci -c "$T/conf" -P "$T/conf/.uci" set wireless.r3mini_phone_sta.ssid=Gone
uci -c "$T/conf" -P "$T/conf/.uci" commit wireless
(
	R3HS_WATCHDOG_LIB=1 R3HS_WEB="$WEB"
	. "$WD"
	tick
)
expect watchdog_stays_parked "$(u wireless.r3mini_phone_sta.disabled)" 1
case "$(calls)" in *'wifi reconf'*) bad watchdog_no_reconf_when_absent "$(calls)" ;; *) ok watchdog_no_reconf_when_absent ;; esac
: > "$SIM/calls"
sleep 300 &
holder=$!
printf '%s\n' "$holder" > "$T/lock/r3mini-hotspot-job"
(
	R3HS_WATCHDOG_LIB=1 R3HS_WEB="$WEB"
	. "$WD"
	tick; tick; tick
)
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
case "$(calls)" in *'ifup wwan'*) bad watchdog_idle_during_job ;; *) ok watchdog_idle_during_job ;; esac

echo "== status.uc 耗时"
reset_world
i=0; total=0
while [ "$i" -lt 5 ]; do
	s="$(cut -d' ' -f1 /proc/uptime)"; web status >/dev/null; e="$(cut -d' ' -f1 /proc/uptime)"
	total="$(awk -v t="$total" -v a="$s" -v b="$e" 'BEGIN { print t + (b - a) * 1000 }')"
	i=$((i + 1))
done
avg="$(awk -v t="$total" 'BEGIN { printf "%d", t / 5 }')"
echo "STATUS_AVG_MS=$avg"
[ "$avg" -le 80 ] && ok status_under_80ms || bad status_under_80ms "${avg} ms"

echo "RESULT pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
