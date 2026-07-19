#!/bin/sh

set -eu

fail() {
	echo "$1" >&2
	exit 1
}

expect_uci() {
	actual="$(uci -q get "$1")"
	[ "$actual" = "$2" ] || fail "uci_mismatch:$1 expected=$2 actual=$actual"
}

expect_uci network.lan.ipaddr 192.168.0.242
expect_uci network.lan.device br-lan
expect_uci network.wan.device eth1
expect_uci dhcp.lan.start 100
expect_uci dhcp.lan.limit 100
radio0_disabled="$(uci -q get wireless.radio0.disabled || true)"
radio1_disabled="$(uci -q get wireless.radio1.disabled || true)"
case "$radio0_disabled" in ''|0) ;; *) fail "radio0_disabled:$radio0_disabled" ;; esac
case "$radio1_disabled" in ''|0) ;; *) fail "radio1_disabled:$radio1_disabled" ;; esac
expect_uci wireless.radio1.channel 48
expect_uci wireless.radio1.htmode HE80

bridge_section=''
for section in $(uci show network | sed -n 's/^network\.\([^=]*\)=device$/\1/p'); do
	if [ "$(uci -q get "network.${section}.name")" = br-lan ]; then
		bridge_section="$section"
		break
	fi
done
[ -n "$bridge_section" ] || fail 'br_lan_device_section_missing'
expect_uci "network.${bridge_section}.ports" eth0
/etc/init.d/dnsmasq status 2>/dev/null | grep -qx running || fail 'dnsmasq_not_running'
echo 'NETWORK_READONLY_OK'

for path in \
	/etc/config/r3mini_fan \
	/etc/init.d/r3mini-fan \
	/usr/sbin/r3mini-fanctl \
	/usr/sbin/r3mini-fan-web \
	/usr/share/luci/menu.d/luci-app-r3mini-fan.json \
	/usr/share/rpcd/acl.d/luci-app-r3mini-fan.json \
	/www/luci-static/resources/view/system/r3mini-fan.js; do
	[ -s "$path" ] || fail "fan_file_missing:$path"
done

/etc/init.d/r3mini-fan status 2>/dev/null | grep -qx running || fail 'fan_not_running'
/etc/init.d/r3mini-fan enabled >/dev/null 2>&1 || fail 'fan_not_enabled'
expect_uci r3mini_fan.main.stop_temp 30000
expect_uci r3mini_fan.main.start_temp 35000
expect_uci r3mini_fan.main.medium_down 35000
expect_uci r3mini_fan.main.medium_up 38000
expect_uci r3mini_fan.main.high_down 37000
expect_uci r3mini_fan.main.high_up 40000
expect_uci r3mini_fan.main.interval 5

fan_status="$(/usr/sbin/r3mini-fan-web status)"
fan_mode="$(jsonfilter -s "$fan_status" -e '@.control_mode')"
kernel_mode="$(jsonfilter -s "$fan_status" -e '@.mode')"
fan_running="$(jsonfilter -s "$fan_status" -e '@.running')"
stage="$(jsonfilter -s "$fan_status" -e '@.state')"
pwm="$(jsonfilter -s "$fan_status" -e '@.pwm')"
[ "$fan_mode" = auto ] || fail "fan_control_mode_mismatch:$fan_mode"
[ "$kernel_mode" = disabled ] || fail "kernel_thermal_mode_mismatch:$kernel_mode"
[ "$fan_running" = true ] || fail "fan_running_mismatch:$fan_running"
case "$stage:$pwm" in
	0:255|1:128|2:80|3:0) ;;
	*) fail "fan_stage_pwm_mismatch:stage=$stage pwm=$pwm" ;;
esac
echo 'FAN_OK'

opkg list-installed | grep -qx 'luci-app-openclash - 0.47.133' || fail 'openclash_package_mismatch'
/etc/init.d/openclash status 2>/dev/null | grep -qx running || fail 'openclash_not_running'
/etc/init.d/openclash enabled >/dev/null 2>&1 || fail 'openclash_not_enabled'
/etc/init.d/nikki status >/dev/null 2>&1 && fail 'nikki_still_running'
/etc/init.d/nikki enabled >/dev/null 2>&1 && fail 'nikki_still_enabled'

expect_uci openclash.dns_cf.enabled 1
expect_uci openclash.dns_cf.group nameserver
expect_uci openclash.dns_cf.type https
expect_uci openclash.dns_cf.ip 1.1.1.1/dns-query
expect_uci openclash.dns_cf.interface Disable
expect_uci openclash.dns_cf.node_resolve 0
expect_uci openclash.dns_cf.specific_group MESL
expect_uci openclash.dns_cf_fb.enabled 1
expect_uci openclash.dns_cf_fb.group fallback
expect_uci openclash.dns_cf_fb.type https
expect_uci openclash.dns_cf_fb.ip 1.0.0.1/dns-query
expect_uci openclash.dns_cf_fb.interface Disable
expect_uci openclash.dns_cf_fb.node_resolve 0
expect_uci openclash.dns_cf_fb.specific_group MESL
expect_uci openclash.dns_ali.enabled 1
expect_uci openclash.dns_ali.group default
expect_uci openclash.dns_ali.type udp
expect_uci openclash.dns_ali.ip 223.5.5.5
expect_uci openclash.dns_ali.node_resolve 1
expect_uci openclash.dns_tx.enabled 1
expect_uci openclash.dns_tx.group default
expect_uci openclash.dns_tx.type udp
expect_uci openclash.dns_tx.ip 119.29.29.29
expect_uci openclash.dns_tx.node_resolve 1
expect_uci openclash.config.enable_custom_dns 1
expect_uci openclash.config.append_wan_dns 0
expect_uci openclash.config.append_default_dns 0
expect_uci openclash.config.enable_respect_rules 0
expect_uci openclash.config.custom_fallback_filter 0
expect_uci openclash.config.custom_name_policy 1

count=0
for section in $(uci show openclash | sed -n 's/^openclash\.\([^=]*\)=dns_servers$/\1/p'); do
	[ "$(uci -q get "openclash.${section}.enabled")" = 1 ] && count=$((count + 1))
done
[ "$count" -eq 4 ] || fail "enabled_dns_count_mismatch:$count"

policy=/etc/openclash/custom/openclash_custom_domain_dns_policy.list
expected_policy='"geosite:cn": [https://doh.pub/dns-query, https://dns.alidns.com/dns-query]'
actual_policy="$(sed '/^[[:space:]]*$/d' "$policy")"
[ "$actual_policy" = "$expected_policy" ] || fail "policy_mismatch:$actual_policy"
echo 'UCI_DNS_OK'

raw="$(uci -q get openclash.@overwrite[0].config_path || uci -q get openclash.config.config_path)"
[ -n "$raw" ] || fail 'config_path_missing'
run="/etc/openclash/$(basename "$raw")"
[ -r "$run" ] || fail "run_yaml_unreadable:$run"
ruby -ryaml - "$run" <<'RUBY'
config = YAML.load_file(ARGV.fetch(0))
dns = config.fetch('dns')
expected = {
  'default-nameserver' => ['223.5.5.5', '119.29.29.29'],
  'nameserver' => ['https://1.1.1.1/dns-query#MESL'],
  'proxy-server-nameserver' => ['223.5.5.5', '119.29.29.29'],
  'fallback' => ['https://1.0.0.1/dns-query#MESL']
}
expected.each do |key, value|
  abort("runtime_mismatch:#{key}") unless dns[key] == value
end
policy = dns.fetch('nameserver-policy')
expected_cn = ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query']
abort('runtime_mismatch:nameserver-policy.geosite:cn') unless policy['geosite:cn'] == expected_cn
groups = config.fetch('proxy-groups')
abort('mesl_group_missing') unless groups.any? { |group| group['name'] == 'MESL' }
puts 'RUNTIME_DNS_OK'
RUBY

for service in netdata samba4 ttyd; do
	/etc/init.d/$service status 2>/dev/null | grep -qx running || fail "service_not_running:$service"
done

year="$(date +%Y)"
[ "$year" -ge 2026 ] || fail "clock_invalid_year:$year"
/etc/init.d/sysntpd enabled >/dev/null 2>&1 || fail 'sysntpd_not_enabled'
echo 'SERVICES_OK'
echo 'TIME_OK'
echo 'STABLE_BASELINE_OK'
