#!/bin/sh
# Restore only the OpenClash parts of the 192.168.0.242 capture onto the Pi 5 side gateway.
# Never touches network/dhcp/system/wireless/firewall configs.
set -eu
R=/tmp/restore
rm -rf "$R"; mkdir -p "$R"
tar -xzf /tmp/src.tar.gz -C "$R" ./files/etc/openclash ./files/etc/config/openclash
rm -rf "$R/files/etc/openclash/core/meta-backup"
rm -f "$R"/files/etc/config/.*.uci-* 2>/dev/null || true
echo "--- restoring"
/etc/init.d/openclash stop >/dev/null 2>&1 || true
cp -a "$R/files/etc/openclash/." /etc/openclash/
cp -a "$R/files/etc/config/openclash" /etc/config/openclash
chmod 755 /etc/openclash/core/clash_meta
ls -la /etc/openclash/ | head -40
echo "--- symlinks"
ls -l /etc/openclash/clash /etc/openclash/cache.db 2>&1
echo "--- core"
/etc/openclash/core/clash_meta -v 2>&1 | head -2
echo "--- config path in uci"
uci get openclash.config.config_path
ls -l "$(uci get openclash.config.config_path)"
echo "--- access-control style options (names only)"
uci show openclash | grep -E "lan_ac|black|white|bypass|interface" | sed -E "s/=.*//" | sort -u | head -30
sync
echo RESTORE_OK
