#!/bin/sh
# 设备端：把 $1 目录里的文件装到位。先备份要覆盖的文件，任何一步失败都还原。
# 由 deploy_hotspot.py 上传并调用；成功时打印 BACKUP=<备份目录>。

set -eu

src="$1"
stamp="$(date +%Y%m%d%H%M%S)"
backup="/root/r3mini-hotspot-backup-$stamp"
touched="$backup/.touched"
finished=0
acl_changed=0

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
	rm -f /tmp/luci-indexcache*
	[ "$acl_changed" -eq 0 ] || /etc/init.d/rpcd restart >/dev/null 2>&1 || true
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
		cmp -s "$from" "$to" && return 0
		mkdir -p "$backup$(dirname "$to")"
		cp -p "$to" "$backup$to"
	fi
	case "$to" in /usr/share/rpcd/acl.d/*) acl_changed=1 ;; esac
	printf '%s\n' "$to" >> "$touched"
	mkdir -p "$(dirname "$to")"
	cp "$from" "$to.r3new"
	chmod "$mode" "$to.r3new"
	mv -f "$to.r3new" "$to"
}

put_if_missing() {
	local from="$src/$1" to="$1" mode="$2"
	[ -e "$to" ] && return 0
	printf '%s\n' "$to" >> "$touched"
	mkdir -p "$(dirname "$to")"
	cp "$from" "$to"
	chmod "$mode" "$to"
}

put /usr/sbin/r3mini-hotspot-web 755
put /usr/sbin/r3mini-hotspot-watchdog 755
put /usr/share/r3mini-hotspot/status.uc 644
put /etc/init.d/r3mini-hotspot 755
put_if_missing /etc/config/r3mini_hotspot 600
put /usr/share/luci/menu.d/luci-app-r3mini-hotspot.json 644
put /usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json 644
put /www/luci-static/resources/view/network/r3mini-hotspot.js 644

# 旧版用 mkdir 目录当锁；进程被杀后会一直留着。没有进程持有时清掉。
for lock in /var/lock/r3mini-hotspot-write /var/lock/r3mini-hotspot-scan; do
	[ -d "$lock" ] && rmdir "$lock" 2>/dev/null || true
done

rm -f /tmp/luci-indexcache*
# rpcd 只在登录时读 ACL；ACL 变了就重启 rpcd，已登录的 LuCI 页面要重新登录。
[ "$acl_changed" -eq 0 ] || /etc/init.d/rpcd restart
/etc/init.d/r3mini-hotspot enable
/etc/init.d/r3mini-hotspot restart

finished=1
trap - 0 1 2 15
printf 'BACKUP=%s\n' "$backup"
printf 'CHANGED_FILES=%s\n' "$(wc -l < "$touched")"
printf 'ACL_CHANGED=%s\n' "$acl_changed"
