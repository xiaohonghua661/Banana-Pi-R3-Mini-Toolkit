#!/bin/sh
# dnsmasq upstream order: AdGuard Home first, OpenClash DNS as fallback (strict-order).
# Verifies: with AGH up, ad domains are blocked (AGH answered); with AGH stopped, names still resolve.
set -u
AGH_PORT=${AGH_PORT:-530}
q() { nslookup "$1" 127.0.0.1 2>/dev/null | awk '/^Name:/{n=1} n && /^Address/ {print $NF}' | head -1; }
TS=$(date +%Y%m%d-%H%M%S)
cp -a /etc/config/dhcp "/etc/config/dhcp.bak-$TS"
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#$AGH_PORT"
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#7874'
uci set dhcp.@dnsmasq[0].strictorder='1'
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].cachesize='0'
uci commit dhcp
/etc/init.d/dnsmasq restart; sleep 2
echo "dhcp backup: /etc/config/dhcp.bak-$TS"
echo "servers: $(uci get dhcp.@dnsmasq[0].server) strictorder=$(uci get dhcp.@dnsmasq[0].strictorder)"
blocked=0; total=0
for d in doubleclick.net pos.baidu.com googleads.g.doubleclick.net ad.doubleclick.net adservice.google.com pagead2.googlesyndication.com; do
	a=$(q "$d"); total=$((total+1)); case "$a" in 0.0.0.0|::) blocked=$((blocked+1));; esac
	echo "AGH up   $d -> ${a:-none}"
done
echo "AGH_UP_BLOCKED=$blocked/$total"
echo "AGH up   www.google.com -> $(q www.google.com)   www.baidu.com -> $(q www.baidu.com)"
/etc/init.d/adguardhome stop; sleep 2
t0=$(date +%s); g=$(q www.google.com); t1=$(date +%s)
echo "AGH down www.google.com -> ${g:-none} (${t0}->${t1}s)   www.baidu.com -> $(q www.baidu.com)   doubleclick.net -> $(q doubleclick.net)"
/etc/init.d/adguardhome start; sleep 4
echo "AGH back doubleclick.net -> $(q doubleclick.net)   www.google.com -> $(q www.google.com)"
