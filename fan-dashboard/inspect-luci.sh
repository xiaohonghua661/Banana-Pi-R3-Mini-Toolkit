grep -R "fs.exec('/etc/init.d\|service.*restart\|rpc.declare.*service" -n /www/luci-static/resources/view /www/luci-static/resources 2>/dev/null | head -40
printf '%s\n' '===ACL EXAMPLES==='
grep -R '"file".*\[.*exec\|"service"' -n /usr/share/rpcd/acl.d 2>/dev/null | head -50
printf '%s\n' '===MENU EXAMPLE==='
sed -n '1,160p' /usr/share/luci/menu.d/luci-app-netdata.json 2>/dev/null || true
printf '%s\n' '===MENUS==='
ls /usr/share/luci/menu.d | head
printf '%s\n' '===SYSTEM ACL SLICE==='
sed -n '120,220p' /usr/share/rpcd/acl.d/luci-mod-system.json
printf '%s\n' '===UCI FORM EXAMPLE==='
sed -n '1,220p' /www/luci-static/resources/view/system/led-trigger/netdev.js 2>/dev/null || true
printf '%s\n' '===FILE EXEC ACLS==='
grep -R '"/.*": \[ "exec" \]' -n /usr/share/rpcd/acl.d 2>/dev/null | head -60
