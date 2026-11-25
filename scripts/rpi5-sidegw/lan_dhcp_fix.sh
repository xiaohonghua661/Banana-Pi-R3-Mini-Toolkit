#!/bin/sh
# Pi 5 on any LAN with lan as DHCP client: OpenClash takes its LAN IP from br-lan (not the static
# network.lan.ipaddr), AdsPower-PH listens on the current br-lan IP (it only accepts a specific IPv4).
# Re-enables OpenClash, restarts OpenClash / AdsPower-PH / sysntpd, then checks each service.
# Rerun whenever the Pi's address changes. Prints no credentials.
IP=$(ip -4 -o addr show br-lan | awk '{print $4; exit}' | cut -d/ -f1)
GW=$(ip -4 route show default dev br-lan | awk '{print $3; exit}')
echo "现在: 地址=${IP:-无} 网关=${GW:-无} 时间=$(date '+%F %T')"
if [ -z "$IP" ] || [ -z "$GW" ]; then echo "没改任何设置: 还没拿到地址或网关。把这一屏发给 Claude"; exit 1; fi
TS=$(date +%Y%m%d-%H%M%S)
cp -a /etc/config/openclash "/root/openclash.uci.bak-$TS"
cp -a /etc/adspower-ph/settings.yaml "/root/adspower-ph.settings.bak-$TS"
uci set openclash.config.lan_interface_name=br-lan
uci set openclash.config.enable=1
uci commit openclash
sed -i "s/^listen: .*/listen: $IP/" /etc/adspower-ph/settings.yaml
echo "正在重启 OpenClash，要等半分钟左右..."
/etc/init.d/openclash restart >/dev/null 2>&1
/etc/init.d/r3mini-adspower-ph restart
/etc/init.d/sysntpd restart
for i in 1 2 3 4 5 6 7 8 9 10; do netstat -lnt 2>/dev/null | grep -q "$IP:10810 " && break; sleep 2; done
BAD=0
chk() { if [ -n "$2" ]; then echo "  好  $1: $2"; else echo "  坏  $1"; BAD=1; fi; }
chk "OpenClash 进程" "$(pidof clash)"
chk "Google 解析成 fake-ip" "$(nslookup www.google.com 127.0.0.1 2>/dev/null | awk '/^Address/ && $NF ~ /^198\.18\./ {print $NF; exit}')"
chk "百度解析" "$(nslookup www.baidu.com 127.0.0.1 2>/dev/null | awk '/^Name:/ {n=1} n && /^Address/ {print $NF; exit}')"
# Right after a restart the first local request can miss OpenClash; retry before calling it broken.
G=""; for i in 1 2 3; do G=$(curl -m 10 -s -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 | grep -x 204) && break; sleep 3; done
chk "Google 访问" "$G"
chk "SOCKS5 :7896" "$(/usr/sbin/r3mini-socks5 verify 2>/dev/null | grep -o '"http_code":204')"
chk "AdsPower :10810" "$(netstat -lnt 2>/dev/null | grep -o "$IP:10810")"
echo "时间: $(date '+%F %T')"
if [ "$BAD" = 0 ]; then
  echo "全部正常。办公室设备上把网关/DNS、SOCKS5(:7896)、AdsPower(:10810) 都填 $IP"
else
  echo "有坏项，把这一屏发给 Claude。OpenClash 日志最后几行:"
  # The proxy-auth tip reads "...authentication of SOCKS5/HTTP(S) proxy with【user:pass】" (no word "password").
  grep -viE 'authentication|password|密码|【' /tmp/openclash.log | tail -n 15
fi
