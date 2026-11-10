#!/bin/sh
# Pin the Pi 5 back to static 192.168.0.245 on a 192.168.0.x/24 LAN (e.g. back home) while lan is on DHCP:
# take the gateway DHCP gave, point AdsPower-PH at .245, re-enable OpenClash. Changes nothing unless every
# check passes; rolls back if the gateway is unreachable after the switch. Background log: /tmp/office-fix.log
NEW=192.168.0.245
CUR=$(ip -4 -o addr show br-lan | awk '{print $4; exit}')
GW=$(ip -4 route show default dev br-lan | awk '{print $3; exit}')
echo "现在: 地址=${CUR:-无} 网关=${GW:-无} 协议=$(uci -q get network.lan.proto)"
fail() { echo "没改任何设置: $1。把这一屏发给 Claude"; uci show network.lan; exit 1; }
up() { ping -c 2 -W 1 "$1" >/dev/null 2>&1 || ip neigh show "$1" | grep -q REACHABLE; }
taken() { ping -c 2 -W 1 "$1" >/dev/null 2>&1; ip neigh show "$1" | grep -q lladdr; }
case "$CUR" in 192.168.0.*/24) ;; *) fail "这里不是 192.168.0.x/24 网段" ;; esac
case "$GW" in 192.168.0.*) ;; *) fail "没找到这里的网关，或网关不在 192.168.0.x" ;; esac
up "$GW" || fail "网关 $GW 不通"
if [ "${CUR%/*}" != "$NEW" ]; then taken "$NEW" && fail "$NEW 已被这里别的设备占用"; fi
TS=$(date +%Y%m%d-%H%M%S)
BAK=/etc/config/network.bak-$TS
ABAK=/root/adspower-ph.settings.bak-$TS
cp -a /etc/config/network "$BAK"
cp -a /etc/adspower-ph/settings.yaml "$ABAK"
uci set network.lan.proto=static
uci set network.lan.ipaddr=$NEW
uci set network.lan.netmask=255.255.255.0
uci set network.lan.gateway=$GW
uci -q delete network.lan.dns
uci add_list network.lan.dns=$GW
uci commit network
uci set openclash.config.enable=1
uci commit openclash
sed -i "s/^listen: .*/listen: $NEW/" /etc/adspower-ph/settings.yaml
echo "已改好: 地址 $NEW，网关 $GW。这个页面马上会断，1 分钟后打开 http://$NEW"
(
  trap '' HUP
  sleep 3; /etc/init.d/network reload; sleep 10
  if ! up "$GW"; then
    echo "ROLLBACK: 网关不通，恢复 $BAK 和 $ABAK（OpenClash 保持启用）"
    cp -a "$BAK" /etc/config/network; cp -a "$ABAK" /etc/adspower-ph/settings.yaml
    /etc/init.d/network reload; sleep 10; /etc/init.d/r3mini-adspower-ph restart; exit 1
  fi
  /etc/init.d/sysntpd restart; sleep 10
  /etc/init.d/openclash restart
  /etc/init.d/r3mini-adspower-ph restart
  /etc/init.d/ttyd restart
  pidof clash >/dev/null && echo OPENCLASH_RUNNING || echo OPENCLASH_NOT_RUNNING
) >/tmp/office-fix.log 2>&1 </dev/null &
