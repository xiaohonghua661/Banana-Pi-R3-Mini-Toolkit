#!/bin/sh
# Install the 0.242 custom components (adblock manager, chatgpt routing + night failsafe, socks5, traffic)
# onto the Pi 5 side gateway. Files land byte-identical; only data/log paths are adapted via config/cron.
set -eu
TS=$(date +%Y%m%d-%H%M%S)
echo "--- pre-existing (should be none)"
tar -tzf /tmp/comp242.tar.gz | while read -r p; do [ -e "/$p" ] && [ ! -d "/$p" ] && echo "EXISTS /$p"; done || true
tar -xzf /tmp/comp242.tar.gz -C /
chmod 755 /usr/sbin/r3mini-adblock /usr/sbin/r3mini-chatgpt /usr/sbin/r3mini-socks5 /usr/sbin/r3mini-traffic /usr/sbin/r3mini-gpt-night-failsafe /etc/init.d/r3mini-traffic
echo "files: $(tar -tzf /tmp/comp242.tar.gz | grep -v '/$' | wc -l)"

# traffic logger: R3 Mini kept data on /mnt/mmcblk0p6; the Pi keeps it on the USB root fs
mkdir -p /opt/r3mini-traffic
uci set r3mini_traffic.main.data_dir='/opt/r3mini-traffic'
uci set r3mini_traffic.main.require_mount='-'
uci commit r3mini_traffic

# cron (same schedule as 0.242; night-failsafe log moved off the R3 Mini eMMC path)
touch /etc/crontabs/root
cp -a /etc/crontabs/root "/etc/crontabs/root.bak-$TS"
grep -v -E '#r3mini-adblock$|#r3mini-gpt-night$' /etc/crontabs/root > /tmp/crontab.new || true
echo '30 4 * * * /usr/sbin/r3mini-adblock update >/dev/null 2>&1 #r3mini-adblock' >> /tmp/crontab.new
echo '30 8 * * * R3GN_LOG=/opt/r3mini-gpt-night.log /usr/sbin/r3mini-gpt-night-failsafe >/dev/null 2>&1 #r3mini-gpt-night' >> /tmp/crontab.new
cp /tmp/crontab.new /etc/crontabs/root
/etc/init.d/cron enable
/etc/init.d/cron restart
echo "--- crontab"; cat /etc/crontabs/root

/etc/init.d/r3mini-traffic enable
/etc/init.d/r3mini-traffic restart
/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true

# re-run OpenClash so its custom overwrite hooks (r3mini-chatgpt / r3mini-socks5) now find their programs
/etc/init.d/openclash restart >/dev/null 2>&1 || true
for i in $(seq 1 40); do pidof clash >/dev/null && netstat -lnt 2>/dev/null | grep -q ":7874 " && break; sleep 3; done
sleep 3
echo "--- services"
echo "openclash: $(/etc/init.d/openclash status)  r3mini-traffic: $(/etc/init.d/r3mini-traffic status)"
netstat -lnt | grep -E ":(7874|7896) " | awk '{print $4}' | tr '\n' ' '; echo
echo "--- hooks in running config"
RUN=/etc/openclash/$(basename "$(uci get openclash.config.config_path)")
grep -c -i -E 'r3mini' "$RUN" || true
grep -n -E 'r3mini' /tmp/openclash.log | tail -5 | cut -c1-160 || true
echo INSTALL_OK
