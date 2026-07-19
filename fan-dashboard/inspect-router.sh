set -e
printf '%s\n' '===BOARD==='
ubus call system board
printf '%s\n' '===PACKAGES==='
opkg list-installed | grep -E '^(luci-base|luci-compat|luci-lib|uhttpd|rpcd-mod)' || true
printf '%s\n' '===LUA==='
command -v lua || true
lua -v 2>&1 || true
printf '%s\n' '===LUCI_LAYOUT==='
ls -ld /usr/lib/lua/luci /usr/share/luci/menu.d /www/luci-static 2>/dev/null || true
printf '%s\n' '===UHTTPD==='
uci show uhttpd.main | grep -E '(home|rfc1918_filter|lua_prefix|lua_handler|cgi_prefix|listen_)' || true
printf '%s\n' '===FAN_STATUS==='
printf 'temp='; cat /sys/class/thermal/thermal_zone0/temp
printf 'state='; cat /sys/class/thermal/cooling_device0/cur_state
printf 'pwm='; cat /sys/class/hwmon/hwmon1/pwm1
printf 'pwm_enable='; cat /sys/class/hwmon/hwmon1/pwm1_enable
printf 'mode='; cat /sys/class/thermal/thermal_zone0/mode
/etc/init.d/r3mini-fan status || true
printf '%s\n' '===FAN_CONFIG==='
uci show r3mini_fan
printf '%s\n' '===FANCTL==='
sed -n '1,260p' /usr/sbin/r3mini-fanctl
printf '%s\n' '===INIT==='
sed -n '1,220p' /etc/init.d/r3mini-fan
printf '%s\n' '===FREE==='
df -h /overlay /tmp
free -m
