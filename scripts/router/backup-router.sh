#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
	echo "usage: $0 DEST" >&2
	exit 2
fi

dest="$1"
[ -n "$dest" ] || exit 2
mkdir -p "$dest"

ubus call system board > "$dest/firmware.json"
sysupgrade -b "$dest/config.tar.gz"
tar -tzf "$dest/config.tar.gz" | sort > "$dest/config-files.txt"

opkg list-installed | sort > "$dest/packages-full.txt"
opkg list-installed | awk '{print $1}' | sort -u > "$dest/packages.txt"

: > "$dest/custom-files.list"
for path in \
	/etc/config/r3mini_fan \
	/etc/init.d/r3mini-fan \
	/usr/sbin/r3mini-fanctl \
	/usr/sbin/r3mini-fan-web \
	/usr/share/luci/menu.d/luci-app-r3mini-fan.json \
	/usr/share/rpcd/acl.d/luci-app-r3mini-fan.json \
	/www/luci-static/resources/view/system/r3mini-fan.js \
	/etc/openclash \
	/etc/crontabs \
	/etc/rc.local \
	/etc/sysupgrade.conf \
	/usr/lib/opkg/status; do
	[ ! -e "$path" ] || printf '%s\n' "$path" >> "$dest/custom-files.list"
done

if [ -s "$dest/custom-files.list" ]; then
	# Paths are fixed by this script and contain no whitespace.
	tar -czf "$dest/custom-files.tar.gz" $(cat "$dest/custom-files.list")
else
	tar -czf "$dest/custom-files.tar.gz" -T /dev/null
fi
tar -tzf "$dest/custom-files.tar.gz" | sort > "$dest/custom-files.checked.txt"

cat /proc/mtd > "$dest/mtd.txt"
block info > "$dest/block-info.txt" 2>/dev/null || true
df -h > "$dest/df.txt"
ubus call service list > "$dest/services.json"

{
	printf 'created_at=%s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
	printf 'model=%s\n' "$(ubus call system board | jsonfilter -e '@.model')"
	printf 'release=%s\n' "$(ubus call system board | jsonfilter -e '@.release.description')"
	printf 'kernel=%s\n' "$(uname -r)"
} > "$dest/manifest.txt"

sha256sum \
	"$dest/config.tar.gz" \
	"$dest/custom-files.tar.gz" \
	"$dest/firmware.json" \
	"$dest/packages-full.txt" \
	"$dest/packages.txt" \
	"$dest/services.json" > "$dest/SHA256SUMS"

sha256sum -c "$dest/SHA256SUMS"
tar -tzf "$dest/config.tar.gz" >/dev/null
tar -tzf "$dest/custom-files.tar.gz" >/dev/null

printf 'BACKUP_DIR=%s\n' "$dest"
printf 'CONFIG_ENTRIES='; wc -l < "$dest/config-files.txt"
printf 'CUSTOM_ENTRIES='; wc -l < "$dest/custom-files.checked.txt"
printf 'PACKAGE_COUNT='; wc -l < "$dest/packages.txt"
echo 'BACKUP_OK'
