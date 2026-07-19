#!/bin/sh

set -eu

src="$1"
stamp="$(date +%Y%m%d%H%M%S)"
backup="/root/r3mini-hotspot-backup-$stamp"

put() {
	local from="$src/$1" to="$1" mode="$2"
	if [ -e "$to" ]; then
		mkdir -p "$backup$(dirname "$to")"
		cp -p "$to" "$backup$to"
	fi
	mkdir -p "$(dirname "$to")"
	cp "$from" "$to"
	chmod "$mode" "$to"
}

put_if_missing() {
	local from="$src/$1" to="$1" mode="$2"
	if [ ! -e "$to" ]; then
		mkdir -p "$(dirname "$to")"
		cp "$from" "$to"
		chmod "$mode" "$to"
	fi
}

put /usr/sbin/r3mini-hotspot-web 755
put /usr/sbin/r3mini-hotspot-watchdog 755
put /etc/init.d/r3mini-hotspot 755
put_if_missing /etc/config/r3mini_hotspot 600
put /usr/share/luci/menu.d/luci-app-r3mini-hotspot.json 644
put /usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json 644
put /www/luci-static/resources/view/network/r3mini-hotspot.js 644

rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/r3mini-hotspot enable
/etc/init.d/r3mini-hotspot restart

printf 'BACKUP=%s\n' "$backup"
printf 'INSTALLED_FILES=7\n'
