set -eu

src="$1"
stamp="$(date +%Y%m%d%H%M%S)"
backup="/root/r3mini-fan-ui-backup-$stamp"

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

put /usr/sbin/r3mini-fan-web 755
put /usr/sbin/r3mini-fanctl 755
put /etc/init.d/r3mini-fan 755
put_if_missing /etc/config/r3mini_fan 600
put /usr/share/luci/menu.d/luci-app-r3mini-fan.json 644
put /usr/share/rpcd/acl.d/luci-app-r3mini-fan.json 644
put /www/luci-static/resources/view/system/r3mini-fan.js 644

rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
/etc/init.d/r3mini-fan enable
if ! /etc/init.d/r3mini-fan restart || ! /etc/init.d/r3mini-fan status >/dev/null 2>&1; then
	echo disabled > /sys/class/thermal/thermal_zone0/mode 2>/dev/null || true
	echo 1 > /sys/class/hwmon/hwmon1/pwm1_enable 2>/dev/null || true
	echo 0 > /sys/class/hwmon/hwmon1/pwm1 2>/dev/null || true
	echo 'ERROR=r3mini-fan failed to start; full-speed fallback requested' >&2
	exit 1
fi

printf 'BACKUP=%s\n' "$backup"
printf 'INSTALLED_FILES=7\n'
