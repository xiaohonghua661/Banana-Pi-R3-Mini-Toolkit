#!/bin/sh

set -eu

tag="$(date +%Y%m%d-%H%M%S)"
openclash_cfg=/etc/config/openclash
nikki_cfg=/etc/config/nikki
policy=/etc/openclash/custom/openclash_custom_domain_dns_policy.list
openclash_backup="${openclash_cfg}.pre-stable.${tag}"
nikki_backup="${nikki_cfg}.pre-disable.${tag}"
policy_backup="${policy}.pre-stable.${tag}"
policy_tmp="${policy}.tmp.$$"

[ -s "$openclash_cfg" ] || { echo "openclash_config_missing:$openclash_cfg" >&2; exit 1; }
[ -x /etc/init.d/openclash ] || { echo "openclash_service_missing" >&2; exit 1; }
[ -x /etc/init.d/nikki ] || { echo "nikki_service_missing" >&2; exit 1; }

cp "$openclash_cfg" "$openclash_backup"
nikki_config_existed=0
policy_existed=0
if [ -f "$nikki_cfg" ]; then
	cp "$nikki_cfg" "$nikki_backup"
	nikki_config_existed=1
fi
if [ -f "$policy" ]; then
	cp "$policy" "$policy_backup"
	policy_existed=1
fi

nikki_enabled=0
nikki_running=0
openclash_enabled=0
openclash_running=0
/etc/init.d/nikki enabled >/dev/null 2>&1 && nikki_enabled=1
/etc/init.d/nikki status >/dev/null 2>&1 && nikki_running=1
/etc/init.d/openclash enabled >/dev/null 2>&1 && openclash_enabled=1
/etc/init.d/openclash status >/dev/null 2>&1 && openclash_running=1

rollback() {
	set +e
	rm -f "$policy_tmp"
	cp "$openclash_backup" "$openclash_cfg"
	if [ "$policy_existed" -eq 1 ]; then
		cp "$policy_backup" "$policy"
	else
		rm -f "$policy"
	fi
	uci revert openclash 2>/dev/null || true
	if [ "$openclash_enabled" -eq 1 ]; then /etc/init.d/openclash enable; else /etc/init.d/openclash disable; fi
	if [ "$openclash_running" -eq 1 ]; then /etc/init.d/openclash restart; else /etc/init.d/openclash stop; fi
	if [ "$nikki_enabled" -eq 1 ]; then /etc/init.d/nikki enable; else /etc/init.d/nikki disable; fi
	if [ "$nikki_running" -eq 1 ]; then /etc/init.d/nikki start; else /etc/init.d/nikki stop; fi
}

on_exit() {
	code=$?
	trap - HUP INT TERM EXIT
	[ "$code" -eq 0 ] || rollback
	exit "$code"
}

on_signal() {
	code=$1
	trap - HUP INT TERM EXIT
	rollback
	exit "$code"
}

trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_exit' EXIT

/etc/init.d/nikki stop
/etc/init.d/nikki disable

for section in $(uci show openclash | sed -n 's/^openclash\.\([^=]*\)=dns_servers$/\1/p'); do
	uci set "openclash.${section}.enabled=0"
done

for section in dns_cf dns_cf_fb dns_ali dns_tx; do
	uci -q delete "openclash.${section}" || true
done

uci set openclash.dns_cf=dns_servers
uci set openclash.dns_cf.enabled=1
uci set openclash.dns_cf.group=nameserver
uci set openclash.dns_cf.type=https
uci set openclash.dns_cf.ip=1.1.1.1/dns-query
uci set openclash.dns_cf.interface=Disable
uci set openclash.dns_cf.node_resolve=0
uci set openclash.dns_cf.specific_group=MESL

uci set openclash.dns_cf_fb=dns_servers
uci set openclash.dns_cf_fb.enabled=1
uci set openclash.dns_cf_fb.group=fallback
uci set openclash.dns_cf_fb.type=https
uci set openclash.dns_cf_fb.ip=1.0.0.1/dns-query
uci set openclash.dns_cf_fb.interface=Disable
uci set openclash.dns_cf_fb.node_resolve=0
uci set openclash.dns_cf_fb.specific_group=MESL

uci set openclash.dns_ali=dns_servers
uci set openclash.dns_ali.enabled=1
uci set openclash.dns_ali.group=default
uci set openclash.dns_ali.type=udp
uci set openclash.dns_ali.ip=223.5.5.5
uci set openclash.dns_ali.interface=Disable
uci set openclash.dns_ali.node_resolve=1
uci -q delete openclash.dns_ali.specific_group || true

uci set openclash.dns_tx=dns_servers
uci set openclash.dns_tx.enabled=1
uci set openclash.dns_tx.group=default
uci set openclash.dns_tx.type=udp
uci set openclash.dns_tx.ip=119.29.29.29
uci set openclash.dns_tx.interface=Disable
uci set openclash.dns_tx.node_resolve=1
uci -q delete openclash.dns_tx.specific_group || true

uci set openclash.config.enable=1
uci set openclash.config.enable_custom_dns=1
uci set openclash.config.append_wan_dns=0
uci set openclash.config.append_default_dns=0
uci set openclash.config.enable_respect_rules=0
uci set openclash.config.custom_fallback_filter=0
uci set openclash.config.custom_name_policy=1

printf '%s\n' '"geosite:cn": [https://doh.pub/dns-query, https://dns.alidns.com/dns-query]' > "$policy_tmp"
chmod 600 "$policy_tmp"
mv "$policy_tmp" "$policy"

expect() {
	actual="$(uci -q get "$1")"
	[ "$actual" = "$2" ] || {
		echo "uci_mismatch:$1 expected=$2 actual=$actual" >&2
		exit 1
	}
}

expect openclash.dns_cf.enabled 1
expect openclash.dns_cf.group nameserver
expect openclash.dns_cf.ip 1.1.1.1/dns-query
expect openclash.dns_cf.specific_group MESL
expect openclash.dns_cf_fb.enabled 1
expect openclash.dns_cf_fb.group fallback
expect openclash.dns_cf_fb.ip 1.0.0.1/dns-query
expect openclash.dns_cf_fb.specific_group MESL
expect openclash.dns_ali.enabled 1
expect openclash.dns_ali.ip 223.5.5.5
expect openclash.dns_tx.enabled 1
expect openclash.dns_tx.ip 119.29.29.29
expect openclash.config.enable_custom_dns 1
expect openclash.config.append_wan_dns 0
expect openclash.config.append_default_dns 0
expect openclash.config.enable_respect_rules 0
expect openclash.config.custom_fallback_filter 0
expect openclash.config.custom_name_policy 1

count=0
for section in $(uci show openclash | sed -n 's/^openclash\.\([^=]*\)=dns_servers$/\1/p'); do
	[ "$(uci -q get "openclash.${section}.enabled")" = 1 ] && count=$((count + 1))
done
[ "$count" -eq 4 ] || { echo "enabled_dns_count_mismatch:$count" >&2; exit 1; }

expected_policy='"geosite:cn": [https://doh.pub/dns-query, https://dns.alidns.com/dns-query]'
actual_policy="$(sed '/^[[:space:]]*$/d' "$policy")"
[ "$actual_policy" = "$expected_policy" ] || { echo "policy_mismatch:$actual_policy" >&2; exit 1; }

uci commit openclash
/etc/init.d/openclash enable
/etc/init.d/openclash restart
status="$(/etc/init.d/openclash status)"
[ "$status" = running ] || { echo "openclash_not_running:$status" >&2; exit 1; }

raw="$(uci -q get openclash.@overwrite[0].config_path || uci -q get openclash.config.config_path)"
[ -n "$raw" ] || { echo 'config_path_missing' >&2; exit 1; }
run="/etc/openclash/$(basename "$raw")"
[ -r "$run" ] || { echo "run_yaml_unreadable:$run" >&2; exit 1; }

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
cn_policy = ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query']
abort('runtime_mismatch:nameserver-policy.geosite:cn') unless policy['geosite:cn'] == cn_policy
groups = config.fetch('proxy-groups')
abort('mesl_group_missing') unless groups.any? { |group| group['name'] == 'MESL' }
puts 'RUNTIME_DNS_OK'
RUBY

/etc/init.d/nikki status >/dev/null 2>&1 && { echo 'nikki_still_running' >&2; exit 1; }
/etc/init.d/nikki enabled >/dev/null 2>&1 && { echo 'nikki_still_enabled' >&2; exit 1; }

trap - HUP INT TERM EXIT
echo 'UCI_DNS_OK'
echo 'NIKKI_DISABLED_OK'
echo "OPENCLASH_BACKUP=$openclash_backup"
if [ "$nikki_config_existed" -eq 1 ]; then echo "NIKKI_BACKUP=$nikki_backup"; else echo 'NIKKI_BACKUP=not_created'; fi
if [ "$policy_existed" -eq 1 ]; then echo "POLICY_BACKUP=$policy_backup"; else echo 'POLICY_BACKUP=not_created'; fi
