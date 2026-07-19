#!/bin/sh
set -eu

stamp="$(date +%Y%m%d-%H%M%S)"
backup="/root/openclash-dns-backup-$stamp"
mkdir -p "$backup"
cp -p /etc/config/openclash "$backup/openclash"

policy=/etc/openclash/custom/openclash_custom_domain_dns_policy.list
if [ -e "$policy" ]; then
	cp -p "$policy" "$backup/openclash_custom_domain_dns_policy.list"
fi

protected_hashes() {
	sha256sum /etc/config/network /etc/config/wireless 2>/dev/null
	[ ! -e /etc/config/r3mini_hotspot ] || sha256sum /etc/config/r3mini_hotspot
}

protected_hashes > "$backup/protected.before"

for section in dns_cf dns_cf_fb dns_ali dns_tx; do
	uci -q delete "openclash.$section" || true
done

uci set openclash.dns_cf=dns_servers
uci set openclash.dns_cf.enabled='1'
uci set openclash.dns_cf.group='nameserver'
uci set openclash.dns_cf.type='https'
uci set openclash.dns_cf.ip='1.1.1.1/dns-query'
uci set openclash.dns_cf.interface='Disable'
uci set openclash.dns_cf.node_resolve='0'
uci set openclash.dns_cf.specific_group='MESL'

uci set openclash.dns_cf_fb=dns_servers
uci set openclash.dns_cf_fb.enabled='1'
uci set openclash.dns_cf_fb.group='fallback'
uci set openclash.dns_cf_fb.type='https'
uci set openclash.dns_cf_fb.ip='1.0.0.1/dns-query'
uci set openclash.dns_cf_fb.interface='Disable'
uci set openclash.dns_cf_fb.node_resolve='0'
uci set openclash.dns_cf_fb.specific_group='MESL'

uci set openclash.dns_ali=dns_servers
uci set openclash.dns_ali.enabled='1'
uci set openclash.dns_ali.group='default'
uci set openclash.dns_ali.type='udp'
uci set openclash.dns_ali.ip='223.5.5.5'
uci set openclash.dns_ali.interface='Disable'
uci set openclash.dns_ali.node_resolve='1'

uci set openclash.dns_tx=dns_servers
uci set openclash.dns_tx.enabled='1'
uci set openclash.dns_tx.group='default'
uci set openclash.dns_tx.type='udp'
uci set openclash.dns_tx.ip='119.29.29.29'
uci set openclash.dns_tx.interface='Disable'
uci set openclash.dns_tx.node_resolve='1'

for section in $(uci show openclash | sed -n 's/^openclash\.\([^=]*\)=dns_servers$/\1/p'); do
	case "$section" in
		dns_cf|dns_cf_fb|dns_ali|dns_tx) ;;
		*) uci set "openclash.$section.enabled=0" ;;
	esac
done

uci set openclash.config.enable='1'
uci set openclash.config.enable_custom_dns='1'
uci set openclash.config.append_wan_dns='0'
uci set openclash.config.append_default_dns='0'
uci set openclash.config.enable_respect_rules='0'
uci set openclash.config.custom_fallback_filter='0'
uci set openclash.config.custom_name_policy='1'

policy_tmp="$policy.tmp.$$"
printf '%s\n' '"geosite:cn": [https://doh.pub/dns-query, https://dns.alidns.com/dns-query]' > "$policy_tmp"
mv "$policy_tmp" "$policy"

uci commit openclash
/etc/init.d/openclash restart
[ "$(/etc/init.d/openclash status)" = running ] || {
	echo 'OPENCLASH_NOT_RUNNING' >&2
	exit 1
}

# Some restored images leave dnsmasq inactive after OpenClash restarts.
# Restore the LAN DNS listener without changing DHCP/network UCI.
if [ "$(/etc/init.d/dnsmasq status 2>/dev/null || true)" != running ]; then
	/etc/init.d/dnsmasq start
fi
[ "$(/etc/init.d/dnsmasq status 2>/dev/null || true)" = running ] || {
	echo 'DNSMASQ_NOT_RUNNING' >&2
	exit 1
}
netstat -lnup 2>/dev/null | grep -q ':53 ' || {
	echo 'DNS_PORT_53_NOT_LISTENING' >&2
	exit 1
}
nslookup claude.ai 127.0.0.1 >/dev/null 2>&1 || {
	echo 'LOCAL_DNS_LOOKUP_FAILED' >&2
	exit 1
}

expect() {
	actual="$(uci -q get "$1" || true)"
	[ "$actual" = "$2" ] || {
		echo "UCI_MISMATCH:$1" >&2
		exit 1
	}
}

expect openclash.dns_cf.enabled 1
expect openclash.dns_cf.group nameserver
expect openclash.dns_cf.type https
expect openclash.dns_cf.ip 1.1.1.1/dns-query
expect openclash.dns_cf.node_resolve 0
expect openclash.dns_cf.specific_group MESL
expect openclash.dns_cf_fb.enabled 1
expect openclash.dns_cf_fb.group fallback
expect openclash.dns_cf_fb.type https
expect openclash.dns_cf_fb.ip 1.0.0.1/dns-query
expect openclash.dns_cf_fb.node_resolve 0
expect openclash.dns_cf_fb.specific_group MESL
expect openclash.dns_ali.enabled 1
expect openclash.dns_ali.group default
expect openclash.dns_ali.type udp
expect openclash.dns_ali.ip 223.5.5.5
expect openclash.dns_tx.enabled 1
expect openclash.dns_tx.group default
expect openclash.dns_tx.type udp
expect openclash.dns_tx.ip 119.29.29.29
expect openclash.config.enable_custom_dns 1
expect openclash.config.append_wan_dns 0
expect openclash.config.append_default_dns 0
expect openclash.config.enable_respect_rules 0
expect openclash.config.custom_fallback_filter 0
expect openclash.config.custom_name_policy 1

count=0
for section in $(uci show openclash | sed -n 's/^openclash\.\([^=]*\)=dns_servers$/\1/p'); do
	[ "$(uci -q get "openclash.$section.enabled")" != 1 ] || count=$((count + 1))
done
[ "$count" -eq 4 ] || {
	echo "UCI_ENABLED_DNS_COUNT:$count" >&2
	exit 1
}

expected_policy='"geosite:cn": [https://doh.pub/dns-query, https://dns.alidns.com/dns-query]'
actual_policy="$(sed '/^[[:space:]]*$/d' "$policy")"
[ "$actual_policy" = "$expected_policy" ] || {
	echo 'POLICY_MISMATCH' >&2
	exit 1
}

raw="$(uci -q get 'openclash.@overwrite[0].config_path' || uci -q get openclash.config.config_path || true)"
run="/etc/openclash/$(basename "$raw")"
[ -r "$run" ] || {
	echo 'RUNTIME_YAML_MISSING' >&2
	exit 1
}

ruby -ryaml -e '
c = YAML.load_file(ARGV.fetch(0))
d = c.fetch("dns")
abort("RUNTIME_DEFAULT") unless d["default-nameserver"] == ["223.5.5.5", "119.29.29.29"]
abort("RUNTIME_NAMESERVER") unless d["nameserver"] == ["https://1.1.1.1/dns-query#MESL"]
abort("RUNTIME_PROXY_SERVER") unless d["proxy-server-nameserver"] == ["223.5.5.5", "119.29.29.29"]
abort("RUNTIME_FALLBACK") unless d["fallback"] == ["https://1.0.0.1/dns-query#MESL"]
abort("RUNTIME_CN_POLICY") unless d.fetch("nameserver-policy")["geosite:cn"] == ["https://doh.pub/dns-query", "https://dns.alidns.com/dns-query"]
abort("MESL_GROUP_MISSING") unless c.fetch("proxy-groups").any? { |g| g["name"] == "MESL" }
' "$run"

protected_hashes > "$backup/protected.after"
cmp -s "$backup/protected.before" "$backup/protected.after" || {
	echo 'PROTECTED_CONFIG_CHANGED' >&2
	exit 1
}

printf 'BACKUP=%s\n' "$backup"
echo 'UCI_DNS_OK'
echo 'RUNTIME_DNS_OK'
echo 'DNSMASQ_OK'
echo 'PROTECTED_HASHES_OK'
