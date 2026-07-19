#!/bin/sh

set -eu

src="$1"
stamp="$(date +%Y%m%d%H%M%S)"
backup="/root/r3mini-hotspot-backup-$stamp"
touched="$backup/.touched"
finished=0

rollback() {
	local rc="$?" to restored=1
	trap - 0 1 2 15
	[ "$finished" -eq 0 ] || exit "$rc"
	[ -s "$touched" ] || exit "$rc"
	while IFS= read -r to; do
		if [ -e "$backup$to" ]; then
			cp -p "$backup$to" "$to" 2>/dev/null || restored=0
		else
			rm -f "$to" || restored=0
		fi
	done < "$touched"
	rm -f /tmp/luci-indexcache
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
	/etc/init.d/r3mini-hotspot restart >/dev/null 2>&1 || true
	printf 'DEPLOY_ROLLBACK=%s\n' "$backup" >&2
	[ "$restored" -eq 1 ] || printf 'DEPLOY_ROLLBACK_FAILED=%s\n' "$backup" >&2
	[ "$rc" -ne 0 ] || rc=1
	exit "$rc"
}

mkdir -p "$backup"
: > "$touched"
trap rollback 0 1 2 15

put() {
	local from="$src/$1" to="$1" mode="$2"
	if [ -e "$to" ]; then
		mkdir -p "$backup$(dirname "$to")"
		cp -p "$to" "$backup$to"
	fi
	printf '%s\n' "$to" >> "$touched"
	mkdir -p "$(dirname "$to")"
	cp "$from" "$to"
	chmod "$mode" "$to"
}

put_if_missing() {
	local from="$src/$1" to="$1" mode="$2"
	if [ ! -e "$to" ]; then
		printf '%s\n' "$to" >> "$touched"
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

finished=1
trap - 0 1 2 15
printf 'BACKUP=%s\n' "$backup"
printf 'MANAGED_FILES=6\n'
printf 'PRESERVED_CONFIG=/etc/config/r3mini_hotspot\n'
