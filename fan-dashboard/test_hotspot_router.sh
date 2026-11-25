#!/bin/sh
# 在路由器上跑的沙箱测试：r3mini-hotspot-web、r3mini-hotspot-watchdog、status.uc、log.uc。
# 配置全是假数据，放在 /tmp/r3hs-test.*；ubus、wifi、ifup、iw、ip 等都换成桩，不碰真实配置、无线和路由。
# status.uc 通过 ucode 的 ubus 模块读的是真实系统（只读），其余都在沙箱里。
# 用法（由 test_hotspot_backend.py 上传并调用）：sh test_hotspot_router.sh <web> <watchdog> <status.uc> <log.uc>
# 输出每项 PASS/FAIL，最后一行 RESULT pass=N fail=M；有失败时退出码 1。

WEB="$1"; WD="$2"; UC="$3"; LOGUC="$4"
T="$(mktemp -d /tmp/r3hs-test.XXXXXX)" || exit 2
SIM="$T/sim"
mkdir -p "$T/conf" "$T/state" "$T/lock" "$T/initd" "$T/bin" "$SIM" "$T/sysnet" "$T/fakeroot/tmp/run" "$T/apstate" "$T/log"
export R3HS_CONF_DIR="$T/conf" R3HS_STATE_DIR="$T/state" R3HS_LOCK_DIR="$T/lock" R3HS_INITD="$T/initd"
export R3HS_PATH="$T/bin" R3HS_STATUS_UC="$UC" R3HS_LOG_UC="$LOGUC" R3HS_LOG_DIR="$T/log"
export R3HS_CONNECT_WAIT=3 R3HS_TTYS='' R3HS_SIM="$SIM"
# 本机 AP 网卡放在 $T/sysnet；「/tmp」换成 $T/fakeroot/tmp，用来模拟它被改成 0700；hostapd 的 AP 状态换成文件。
export R3HS_SYSNET="$T/sysnet" R3HS_AP_WAIT=4 R3HS_RADIO_WAIT=3 R3HS_DAEMON_DIRS="$T/fakeroot/tmp:1777 $T/fakeroot/tmp/run:755"
export R3HS_AP_STATE_DIR="$T/apstate"
trap 'rm -rf "$T"; rm -f /tmp/r3mini-hotspot-key-r3hstest*' 0

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1${2:+: $2}"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want [$3] got [$2]"; }
contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] lacks [$3]" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "[$2] has [$3]" ;; *) ok "$1" ;; esac; }
u() { uci -c "$T/conf" -P "$T/conf/.uci" -q get "$1"; }
uset() { uci -c "$T/conf" -P "$T/conf/.uci" set "$1"; }
ucommit() { uci -c "$T/conf" -P "$T/conf/.uci" commit "$1"; }
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
count_calls() { grep -c "$1" "$SIM/calls" 2>/dev/null; }
logtext() { cat "$T/log/hotspot.log" 2>/dev/null; }
wd() { ( R3HS_WATCHDOG_LIB=1 R3HS_WEB="$WEB"; . "$WD"; for _ in $(seq "$1"); do tick; done; echo "rounds=$rounds" >> "$R3HS_SIM/calls" ); }

reset_world() {
	rm -rf "$T/conf"/* "$T/conf/.uci" "$T/state"/* "$T/lock"/* "$T/log"/*
	: > "$SIM/calls"
	rm -f "$SIM/wwan_up" "$SIM/connect_ok" "$SIM/fail_reload" "$SIM/scan_delay" "$SIM"/ap_fail* "$SIM/manual_down" "$SIM/wpa_state"
	touch "$T/sysnet/phy0-ap0" "$T/sysnet/phy1-ap0"
	rm -f "$T/sysnet/phy1-sta0"
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
	uset wireless.r3mini_phone_sta.key=oldpassword
	ucommit wireless
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
{ "radio0": { "up": true, "pending": false, "interfaces": [ { "section": "default_radio0", "ifname": "phy0-ap0" } ] },
  "radio1": { "up": true, "pending": false, "interfaces": [ { "section": "default_radio1", "ifname": "phy1-ap0" }, { "section": "r3mini_phone_sta", "ifname": "phy1-sta0" } ] } }
EOF

# 重建一个频段的本机 AP：像真机那样，「/tmp」别人进不去、或设了 ap_fail 时就建不起来。
cat > "$SIM/rebuild_ap" <<'EOF'
#!/bin/sh
# 标志文件按网卡分：ap_fail_once.<网卡>（只失败一次）、ap_fail.<网卡>（一直失败）。
ap="$1"
rm -f "$R3HS_SYSNET/$ap"
perm="$(ls -ld "${R3HS_DAEMON_DIRS%%:*}" | cut -c10)"
if [ -f "$R3HS_SIM/ap_fail_once.$ap" ]; then
	rm -f "$R3HS_SIM/ap_fail_once.$ap"
elif [ ! -f "$R3HS_SIM/ap_fail.$ap" ] && { [ "$perm" = t ] || [ "$perm" = x ]; }; then
	touch "$R3HS_SYSNET/$ap"
fi
EOF
cat > "$T/bin/ubus" <<'EOF'
#!/bin/sh
[ "$1" = -t ] && shift 2
[ -f "$R3HS_SIM/scan_delay" ] && [ "$3" = scan ] && sleep "$(cat "$R3HS_SIM/scan_delay")"
case "$1 $2 $3" in
	"call iwinfo scan")
		case "$4" in *phy1-ap0*) cat "$R3HS_SIM/scan5.json" ;; *phy0-ap0*) cat "$R3HS_SIM/scan2.json" ;; *) exit 4 ;; esac ;;
	"call network.wireless status") cat "$R3HS_SIM/wireless_status.json" ;;
	"call network reload")
		echo "ubus network reload" >> "$R3HS_SIM/calls"
		[ -f "$R3HS_SIM/fail_reload" ] && exit 1
		sh "$R3HS_SIM/rebuild_ap" phy0-ap0
		sh "$R3HS_SIM/rebuild_ap" phy1-ap0
		[ -f "$R3HS_SIM/connect_ok" ] && [ ! -f "$R3HS_SIM/manual_down" ] && touch "$R3HS_SIM/wwan_up"
		exit 0 ;;
	"call network.wireless down") echo "ubus wireless down $4" >> "$R3HS_SIM/calls" ;;
	"call network.wireless up")
		echo "ubus wireless up $4" >> "$R3HS_SIM/calls"
		case "$4" in *radio0*) sh "$R3HS_SIM/rebuild_ap" phy0-ap0 ;; *radio1*) sh "$R3HS_SIM/rebuild_ap" phy1-ap0 ;; esac ;;
	"call wpa_supplicant phy_status")
		printf '{ "state": "%s" }\n' "$(cat "$R3HS_SIM/wpa_state" 2>/dev/null || echo SCANNING)" ;;
	*) exit 3 ;;
esac
EOF
cat > "$T/bin/wifi" <<'EOF'
#!/bin/sh
echo "wifi $*" >> "$R3HS_SIM/calls"
exit 0
EOF
cat > "$T/bin/ifstatus" <<'EOF'
#!/bin/sh
auto=true
[ -f "$R3HS_SIM/manual_down" ] && auto=false
case "$1" in
	wan) echo '{"up":true,"autostart":true,"ipv4-address":[{"address":"192.168.0.29"}],"l3_device":"eth1","route":[{"target":"0.0.0.0","nexthop":"192.168.0.254"}]}' ;;
	wwan)
		if [ -f "$R3HS_SIM/wwan_up" ]; then
			echo "{\"up\":true,\"autostart\":$auto,\"ipv4-address\":[{\"address\":\"172.20.10.2\"}],\"l3_device\":\"phy1-sta0\",\"route\":[{\"target\":\"0.0.0.0\",\"nexthop\":\"172.20.10.1\"}]}"
		else
			echo "{\"up\":false,\"autostart\":$auto,\"pending\":true}"
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
cat > "$T/bin/ifup" <<'EOF'
#!/bin/sh
echo "ifup $*" >> "$R3HS_SIM/calls"
if [ "$1" = wwan ]; then
	rm -f "$R3HS_SIM/manual_down"
	[ -f "$R3HS_SIM/connect_ok" ] && touch "$R3HS_SIM/wwan_up"
fi
exit 0
EOF
cat > "$T/bin/ifdown" <<'EOF'
#!/bin/sh
echo "ifdown $*" >> "$R3HS_SIM/calls"
[ "$1" = wwan ] && { touch "$R3HS_SIM/manual_down"; rm -f "$R3HS_SIM/wwan_up"; }
exit 0
EOF
printf '#!/bin/sh\necho "logger $*" >> "$R3HS_SIM/calls"\n' > "$T/bin/logger"
for s in firewall r3mini-hotspot; do
	printf '#!/bin/sh\necho "initd %s $*" >> "$R3HS_SIM/calls"\n' "$s" > "$T/initd/$s"
done
chmod +x "$T/bin"/* "$T/initd"/*

# ---------- 用例 ----------

reset_world
echo "== 状态"
out="$(web status)"
expect status_version "$(printf '%s' "$out" | jsonfilter -e '@.version')" 2
expect status_wifi_ssid "$(printf '%s' "$out" | jsonfilter -e '@.wifi.ssid')" nl
expect status_radios "$(printf '%s' "$out" | jsonfilter -e '@.radios[*].name' | tr '\n' ' ')" 'radio0 radio1 '
expect status_cell_iface "$(printf '%s' "$out" | jsonfilter -e '@.cellular.iface')" RM500CNV
expect status_preferred "$(printf '%s' "$out" | jsonfilter -e '@.preferred')" wan
out="$(web scan radio1)"
expect scan_raw_passthrough "$(printf '%s' "$out" | jsonfilter -e '@.results[0].ssid')" Phone5G
contains scan_logged "$(logtext)" 'scan.done'
web scan radio9 >/dev/null 2>&1 && bad scan_rejects_bad_radio || ok scan_rejects_bad_radio

echo "== 连接新 Wi-Fi（5 GHz，WPA2/WPA3）；wwan 之前被手动关过"
reset_world
touch "$SIM/connect_ok" "$SIM/manual_down"
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
expect save_single_reload "$(count_calls 'ubus network reload')" 1
lacks save_no_wifi_reconf "$(calls)" 'wifi reconf'
contains save_ifup_after_manual_down "$(calls)" 'ubus network reload;ifup wwan'
contains save_firewall_reload_first_time "$(calls)" 'initd firewall reload'
contains save_restarts_watchdog "$(calls)" 'initd r3mini-hotspot restart'
[ -e "$T/state/r3mini-hotspot-job.key" ] && bad save_deletes_job_key || ok save_deletes_job_key
[ -e "$T/lock/r3mini-hotspot-job" ] || [ -e "$T/lock/r3mini-hotspot-write" ] && bad save_releases_locks || ok save_releases_locks
out="$(web status)"
expect status_shows_job "$(printf '%s' "$out" | jsonfilter -e '@.job.state')" done

echo "== 日志"
log="$(logtext)"
contains log_job_start "$log" 'job.start'
contains log_job_end_done "$log" 'job.end'
contains log_result_done "$log" 'result=done'
contains log_reload_cmd "$log" 'cmd="ubus call network reload"'
contains log_ap_check "$log" 'ap.check'
grep -q 'secret-pass-1' "$T/log/hotspot.log" && bad log_has_no_password || ok log_has_no_password
grep -q 'oldpassword' "$T/log/hotspot.log" && bad log_has_no_old_password || ok log_has_no_old_password
id="$(job id)"
grep -q " $id job.end " "$T/log/hotspot.log" && ok log_run_id_is_job_id || bad log_run_id_is_job_id "$id"
bad_lines="$(grep -v -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}[+-][0-9]{2}:[0-9]{2} (ERROR|WARN|INFO|DEBUG) [^ ]+ [a-z0-9_.]+ ' "$T/log/hotspot.log" | head -n 2)"
expect log_line_format "$bad_lines" ''
ls -ld "$T/log/hotspot.log" | grep -q '^-rw-------' && ok log_file_0600 || bad log_file_0600 "$(ls -l "$T/log/hotspot.log")"

echo "== 没被手动关过：只重配一次，不 ifup"
reset_world
touch "$SIM/connect_ok"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect plain_save_done "$(job state)" done
lacks plain_save_no_ifup "$(calls)" 'ifup wwan'
expect plain_save_single_reload "$(count_calls 'ubus network reload')" 1

echo "== 换到 2.4 GHz，恢复 5 GHz 原信道，只 reload 一次"
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
expect band_single_reload "$(count_calls 'ubus network reload')" 1
lacks band_no_firewall_reload "$(calls)" 'initd firewall reload'

echo "== 同一个 Wi-Fi 不填密码：沿用已保存的"
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
contains dfs_reason_logged "$(logtext)" 'reason=unsupported_channel'
web save radio1 Nowhere - >/dev/null; wait_job
contains missing_message "$(job message)" '没搜到「Nowhere」'
contains missing_reason_logged "$(logtext)" 'reason=not_found'
web save radio1 Corp - >/dev/null; wait_job
contains eap_message "$(job message)" '企业认证'
web save radio1 Phone5G - >/dev/null; wait_job
contains new_network_needs_key "$(job message)" '请输入这个 Wi-Fi 的密码'
k="$(keyfile 'short')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
contains short_key_rejected "$(job message)" '8–63'
grep -q 'short' "$T/log/hotspot.log" && bad log_has_no_short_password || ok log_has_no_short_password
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

echo "== 重载失败自动回滚"
reset_world
before="$(conf_sum)"
touch "$SIM/fail_reload"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect reload_fail_state "$(job state)" failed
contains reload_fail_message "$(job message)" '重载网络配置失败；已恢复保存前的设置'
expect reload_fail_restores_config "$(conf_sum)" "$before"
[ "$(count_calls 'ubus network reload')" -ge 2 ] && ok reload_fail_reapplies || bad reload_fail_reapplies "$(calls)"
[ -e "$T/state/r3mini-hotspot-job.key" ] && bad reload_fail_deletes_key || ok reload_fail_deletes_key

echo "== 没连上：保存成功，按 STA 状态说明原因"
reset_world
echo 4WAY_HANDSHAKE > "$SIM/wpa_state"
touch "$T/sysnet/phy1-sta0"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect noconnect_done "$(job state)" done
contains noconnect_message "$(job message)" '没连上「Phone5G」'
contains noconnect_diagnosis "$(job message)" '密码不对'
contains noconnect_logged "$(logtext)" 'reason=not_connected_auth'

echo "== 停用：不 ifdown，只 reload 一次"
: > "$SIM/calls"
web disable >/dev/null; wait_job
expect disable_done "$(job state)" done
expect disable_sta_off "$(u wireless.r3mini_phone_sta.disabled)" 1
expect disable_channel_restored "$(u wireless.radio1.channel)" 48
expect disable_enabled_0 "$(u r3mini_hotspot.main.enabled)" 0
lacks disable_no_ifdown "$(calls)" 'ifdown wwan'
expect disable_single_reload "$(count_calls 'ubus network reload')" 1

echo "== 旧版 original_channel 迁移"
reset_world
uset r3mini_hotspot.main.original_channel=36
ucommit r3mini_hotspot
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect migrate_new_key "$(u r3mini_hotspot.main.original_channel_radio1)" 36
expect migrate_old_key_removed "$(u r3mini_hotspot.main.original_channel)" ''

echo "== /tmp 被改成 0700：重配前恢复，本机 AP 照常起来"
reset_world
chmod 700 "$T/fakeroot/tmp"
touch "$SIM/connect_ok"
out="$(web debug)"
contains debug_reports_tmp_mode "$(printf '%s' "$out" | jsonfilter -e '@.problems[*].text' | tr '\n' ' ')" '0700'
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect tmp_fix_job_done "$(job state)" done
expect tmp_fix_mode "$(ls -ld "$T/fakeroot/tmp" | cut -c1-10)" drwxrwxrwt
contains tmp_fix_reported "$(job message)" '已恢复'
contains tmp_fix_logged "$(logtext)" 'tmp.fix'
[ -e "$T/sysnet/phy1-ap0" ] && ok tmp_fix_ap_up || bad tmp_fix_ap_up

echo "== 重配后本机 AP 没起来：回滚"
reset_world
before="$(conf_sum)"
touch "$SIM/ap_fail_once.phy1-ap0"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect ap_once_failed "$(job state)" failed
contains ap_once_message "$(job message)" '已恢复保存前的设置'
contains ap_once_back "$(job message)" '本机 Wi-Fi 已回来'
expect ap_once_config_restored "$(conf_sum)" "$before"
[ -e "$T/sysnet/phy1-ap0" ] && ok ap_once_ap_back || bad ap_once_ap_back
reset_world
touch "$SIM/ap_fail.phy1-ap0"
k="$(keyfile 'secret-pass-1')"
web save radio1 Phone5G "$k" >/dev/null; wait_job
expect ap_hard_failed "$(job state)" failed
contains ap_hard_message "$(job message)" '也没起来'
contains ap_hard_kicked "$(calls)" 'ubus wireless down'
contains ap_hard_logged "$(logtext)" 'reason=ap_not_up_hard'
rm -f "$SIM/ap_fail.phy1-ap0"

echo "== 停用后本机 AP 没起来：关了再开"
reset_world
touch "$SIM/connect_ok"
web save radio1 Open5G - >/dev/null; wait_job
: > "$SIM/calls"
touch "$SIM/ap_fail_once.phy1-ap0"
web disable >/dev/null; wait_job
expect disable_kick_done "$(job state)" done
contains disable_kick_down "$(calls)" 'ubus wireless down'
contains disable_kick_up "$(calls)" 'ubus wireless up'
[ -e "$T/sysnet/phy1-ap0" ] && ok disable_kick_ap_up || bad disable_kick_ap_up

echo "== 本机 AP 不在时搜索与状态"
reset_world
rm -f "$T/sysnet/phy0-ap0"
out="$(web scan radio0 2>&1)" && bad scan_ap_down_rejected || contains scan_ap_down_rejected "$out" '没有运行'
out="$(web status)"
expect status_ap_down "$(printf '%s' "$out" | jsonfilter -e '@.radios[0].ap_up')" false
expect status_ap_up "$(printf '%s' "$out" | jsonfilter -e '@.radios[1].ap_up')" true
expect status_channel_from_uci "$(printf '%s' "$out" | jsonfilter -e '@.radios[0].channel')" 12
out="$(web debug)"
contains debug_reports_ap_down "$(printf '%s' "$out" | jsonfilter -e '@.problems[*].text' | tr '\n' ' ')" '网卡 phy0-ap0 不存在'

echo "== 调试数据"
reset_world
web scan radio1 >/dev/null
out="$(web debug)"
expect debug_has_module_log "$([ "$(printf '%s' "$out" | jsonfilter -e '@.module_log[*]' | wc -l)" -ge 1 ] && echo yes)" yes
contains debug_module_log_content "$(printf '%s' "$out" | jsonfilter -e '@.module_log[*]')" 'scan.done'
expect debug_log_path "$(printf '%s' "$out" | jsonfilter -e '@.diag.log.path')" "$T/log/hotspot.log"
expect debug_dirs "$(printf '%s' "$out" | jsonfilter -e '@.diag.dirs[0].mode')" 1777
printf '%s' "$out" | jsonfilter -e '@.syslog' >/dev/null && ok debug_syslog_array || bad debug_syslog_array

echo "== STA 状态诊断"
reset_world
(
	R3MINI_HOTSPOT_LIB=1
	. "$WEB"
	echo "nosta=$(sta_diagnose)" >> "$R3HS_SIM/calls"
	touch "$R3HS_SYSNET/phy1-sta0"
	echo SCANNING > "$R3HS_SIM/wpa_state"; echo "scan=$(sta_diagnose)" >> "$R3HS_SIM/calls"
	echo ASSOCIATING > "$R3HS_SIM/wpa_state"; echo "assoc=$(sta_diagnose)" >> "$R3HS_SIM/calls"
	echo COMPLETED > "$R3HS_SIM/wpa_state"; echo "dhcp=$(sta_diagnose)" >> "$R3HS_SIM/calls"
	touch "$R3HS_SIM/wwan_up"; echo "up=$(sta_diagnose)" >> "$R3HS_SIM/calls"
)
contains diag_no_sta "$(calls)" 'nosta=no_sta'
contains diag_absent "$(calls)" 'scan=absent'
contains diag_auth "$(calls)" 'assoc=auth'
contains diag_dhcp "$(calls)" 'dhcp=dhcp'
contains diag_connected "$(calls)" 'up=connected'

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
uset network.wwan=interface
uset network.wwan.proto=dhcp
ucommit network
web prefer hotspot >/dev/null
expect prefer_hotspot_saved "$(u r3mini_hotspot.main.preferred_egress)" hotspot
expect prefer_hotspot_metric "$(u network.wwan.metric)" 5
expect prefer_hotspot_wan_metric "$(u network.wan.metric)" 20
expect prefer_hotspot_route "$(sh "$T/bin/ip" -4 route show default | head -n 1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')" phy1-sta0
contains prefer_logged "$(logtext)" 'prefer.set'
web prefer wan >/dev/null
expect prefer_wan_route "$(sh "$T/bin/ip" -4 route show default | head -n 1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')" eth1
expect prefer_wan_routes_kept "$(wc -l < "$SIM/routes" | tr -d ' ')" 2
out="$(web prefer cellular 2>&1)" && bad prefer_offline_rejected || contains prefer_offline_rejected "$out" '蜂窝网络当前没有连上'
expect prefer_offline_keeps "$(u r3mini_hotspot.main.preferred_egress)" wan
contains fail_logged "$(logtext)" 'cmd.fail'

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

echo "== 看门狗：连不上时不反复重配，2 轮后停靠"
reset_world
uset wireless.r3mini_phone_sta.ssid=Phone5G
uset wireless.r3mini_phone_sta.disabled=0
uset wireless.radio1.channel=36
ucommit wireless
uset r3mini_hotspot.main.enabled=1
ucommit r3mini_hotspot
out="$(web status)"
expect status_ap_running_not_paused "$(printf '%s' "$out" | jsonfilter -e '@.radios[1].ap_paused')" false
echo DISABLED > "$T/apstate/phy1-ap0"
out="$(web status)"
expect status_ap_paused "$(printf '%s' "$out" | jsonfilter -e '@.radios[1].ap_paused')" true
expect status_ap_state "$(printf '%s' "$out" | jsonfilter -e '@.radios[1].ap_state')" DISABLED
echo ENABLED > "$T/apstate/phy1-ap0"
wd 3
contains watchdog_counts_round "$(calls)" 'rounds=1'
lacks watchdog_round_no_ifup "$(calls)" 'ifup wwan'
lacks watchdog_round_no_reload "$(calls)" 'ubus network reload'
contains watchdog_round_logged "$(logtext)" 'wd.round'
expect watchdog_not_parked_yet "$(u wireless.r3mini_phone_sta.disabled)" 0
: > "$SIM/calls"
touch "$SIM/manual_down"
wd 3
contains watchdog_ifup_when_manual_down "$(calls)" 'ifup wwan'
: > "$SIM/calls"
wd 6
expect watchdog_parks "$(u wireless.r3mini_phone_sta.disabled)" 1
expect watchdog_park_keeps_enabled "$(u r3mini_hotspot.main.enabled)" 1
expect watchdog_park_single_reload "$(count_calls 'ubus network reload')" 1
lacks watchdog_park_no_ifdown "$(calls)" 'ifdown wwan'
contains watchdog_park_logged "$(logtext)" 'wd.park'
out="$(web status)"
expect status_parked "$(printf '%s' "$out" | jsonfilter -e '@.wifi.parked')" true

echo "== 看门狗：停靠中搜到对方就重连，并跟到对方信道"
: > "$SIM/calls"
touch "$SIM/manual_down"
wd 1
expect watchdog_unparks "$(u wireless.r3mini_phone_sta.disabled)" 0
expect watchdog_unpark_channel "$(u wireless.radio1.channel)" 44
expect watchdog_unpark_target "$(u r3mini_hotspot.main.target_channel)" 44
expect watchdog_unpark_single_reload "$(count_calls 'ubus network reload')" 1
contains watchdog_unpark_ifup "$(calls)" 'ifup wwan'
lacks watchdog_no_wifi_down "$(calls)" 'wifi down'
contains watchdog_unpark_logged "$(logtext)" 'wd.unpark'
: > "$SIM/calls"
uset wireless.r3mini_phone_sta.disabled=1
uset wireless.r3mini_phone_sta.ssid=Gone
ucommit wireless
wd 1
expect watchdog_stays_parked "$(u wireless.r3mini_phone_sta.disabled)" 1
lacks watchdog_no_reload_when_absent "$(calls)" 'ubus network reload'
contains watchdog_probe_logged "$(logtext)" 'wd.probe'
: > "$SIM/calls"
sleep 300 &
holder=$!
printf '%s\n' "$holder" > "$T/lock/r3mini-hotspot-job"
wd 3
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
lacks watchdog_idle_during_job "$(calls)" 'ubus network reload'

echo "== 日志轮转与清理"
reset_world
(
	export R3HS_LOG_MAX=1500
	i=0
	while [ "$i" -lt 40 ]; do ucode "$LOGUC" write t INFO test.fill "填充第 $i 行" "n=$i"; i=$((i + 1)); done
)
[ -e "$T/log/hotspot.log.1" ] && ok log_rotated || bad log_rotated "$(ls "$T/log")"
[ -e "$T/log/hotspot.log.4" ] && bad log_keeps_at_most_4 || ok log_keeps_at_most_4
contains log_rotate_logged "$(cat "$T/log"/hotspot.log*)" 'log.rotate'
touch -t 202601010000 "$T/log/hotspot.log.1"
ucode "$LOGUC" prune
[ -e "$T/log/hotspot.log.1" ] && bad log_prune_old || ok log_prune_old
contains log_prune_logged "$(logtext)" 'log.prune'

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
