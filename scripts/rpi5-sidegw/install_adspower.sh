#!/bin/sh
# Port 0.242's AdsPower PH listener (separate mihomo instance, authenticated SOCKS on a specific LAN IP).
set -eu
tar -xzf /tmp/adspower242.tar.gz -C /
cp -a /etc/openclash/core/clash_meta /usr/sbin/adspower-ph-core
chmod 755 /usr/sbin/adspower-ph-core /usr/sbin/adspower-ph-start /etc/init.d/r3mini-adspower-ph
chmod 700 /etc/adspower-ph /usr/share/adspower-ph
chmod 600 /etc/adspower-ph/settings.yaml
echo "core sha256: $(sha256sum /usr/sbin/adspower-ph-core | cut -c1-64)"
# 0.242 listened on its own LAN IP; the Pi listens on its own
sed -i 's/^listen: .*/listen: 192.168.0.245/' /etc/adspower-ph/settings.yaml
grep -E '^(listen|port|proxy-name):' /etc/adspower-ph/settings.yaml
/etc/init.d/r3mini-adspower-ph enable
/etc/init.d/r3mini-adspower-ph restart
for i in $(seq 1 20); do netstat -lnt 2>/dev/null | grep -q '192.168.0.245:10810 ' && break; sleep 2; done
echo "service: $(/etc/init.d/r3mini-adspower-ph status)"
netstat -lnt | grep ':10810 ' || echo 'NOT LISTENING'
logread -e adspower | tail -3 | cut -c1-160
cred=$(ruby -ryaml -e 's = YAML.load_file("/etc/adspower-ph/settings.yaml"); print s["username"].to_s + ":" + s["password"].to_s')
echo "via socks5 10810: $(curl -sS -m 15 --socks5-hostname 192.168.0.245:10810 -U "$cred" -o /dev/null -w '%{http_code}' https://www.google.com 2>&1 | head -c 80)  exit_ip: $(curl -sS -m 15 --socks5-hostname 192.168.0.245:10810 -U "$cred" https://api.ipify.org 2>&1 | head -c 60)"
cred=
free | sed -n 2p
echo ADSPOWER_OK
