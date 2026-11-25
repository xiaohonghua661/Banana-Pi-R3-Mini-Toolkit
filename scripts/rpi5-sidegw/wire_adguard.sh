#!/bin/sh
# Chain: clients -> dnsmasq :53 -> AdGuard Home 127.0.0.1:530 -> OpenClash DNS 127.0.0.1:7874
# Keeps the user's wizard choices (web :800, DNS :530) and the admin account untouched.
set -eu
TS=$(date +%Y%m%d-%H%M%S)
cp -a /etc/adguardhome.yaml "/etc/adguardhome.yaml.bak-$TS"
cp -a /etc/config/dhcp "/etc/config/dhcp.bak-$TS"
cp -a /etc/config/openclash "/root/openclash.uci.bak-$TS"
echo "backups: /etc/adguardhome.yaml.bak-$TS /etc/config/dhcp.bak-$TS /root/openclash.uci.bak-$TS"

# allowlist copied from 192.168.0.242 r3mini_adblock
mkdir -p /tmp/restore
tar -xzf /tmp/src.tar.gz -C /tmp/restore ./files/etc/config/r3mini_adblock
uci -c /tmp/restore/files/etc/config get r3mini_adblock.main.allow | tr ' ' '\n' > /tmp/allow.txt
echo "allowlist entries: $(grep -c . /tmp/allow.txt)"

/etc/init.d/adguardhome stop
ruby -ryaml -e '
f = "/etc/adguardhome.yaml"
c = YAML.load_file(f)
d = c["dns"]
d["upstream_dns"] = ["127.0.0.1:7874"]
d["bootstrap_dns"] = ["223.5.5.5", "119.29.29.29"]
d["fallback_dns"] = ["223.5.5.5", "119.29.29.29"]
d["ratelimit"] = 0
d["cache_optimistic"] = false
c["querylog"]["interval"] = "168h"
fl = c["filters"] || []
unless fl.any? { |x| x["url"].to_s.include?("anti-ad.net") }
  fl << { "enabled" => true, "url" => "https://anti-ad.net/easylist.txt", "name" => "anti-AD", "id" => (fl.map { |x| x["id"].to_i }.max || 0) + 1 }
end
c["filters"] = fl
b = "! >>> allowlist from 192.168.0.242 r3mini_adblock >>>"
e = "! <<< allowlist from 192.168.0.242 r3mini_adblock <<<"
old = c["user_rules"] || []
keep = []; skip = false
old.each { |r| if r == b then skip = true elsif r == e then skip = false elsif !skip then keep << r end }
allow = File.readlines("/tmp/allow.txt").map(&:strip).reject(&:empty?)
c["user_rules"] = keep + [b] + allow.map { |x| "@@||" + x + "^" } + [e]
File.write(f, c.to_yaml)
puts "yaml updated: upstream=#{d["upstream_dns"].inspect} filters=#{fl.map { |x| x["name"] }.inspect} user_rules=#{c["user_rules"].size}"
'

uci set openclash.config.enable_redirect_dns='0'
uci commit openclash
/etc/init.d/openclash restart >/dev/null 2>&1 || true
for i in $(seq 1 40); do pidof clash >/dev/null && netstat -lnt 2>/dev/null | grep -q ":7874 " && break; sleep 3; done
echo "openclash: $(/etc/init.d/openclash status) redirect_dns=$(uci get openclash.config.enable_redirect_dns)"

uci -q delete dhcp.@dnsmasq[0].server || true
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#530'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].cachesize='0'
uci commit dhcp
/etc/init.d/adguardhome start
sleep 3
/etc/init.d/dnsmasq restart
sleep 2
echo "dnsmasq server=$(uci -q get dhcp.@dnsmasq[0].server) noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv) cachesize=$(uci -q get dhcp.@dnsmasq[0].cachesize)"
echo "adguardhome: $(/etc/init.d/adguardhome status)"
netstat -lnt | grep -E ":(53|530|800|7874) " | awk '{print $4}' | sort -u | tr '\n' ' '; echo
echo WIRE_OK
