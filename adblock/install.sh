#!/bin/sh
# install.sh —— 在 R3 Mini（ImmortalWrt + OpenClash Meta）上安装 / 卸载「广告过滤」（r3mini-adblock）
#
# 用法（必须带参数；不带参数只打印用法，不会安装）：先把整个包目录（含 router/、dnsmasq-remove.list、本脚本）传到
# /tmp/r3mini-adblock-pkg/，然后：
#   sh /tmp/r3mini-adblock-pkg/install.sh check      只读预检，逐项打印 [通过]/[不通过]/[提醒]，末行 CHECK_OK 或 CHECK_FAIL <原因>
#   sh /tmp/r3mini-adblock-pkg/install.sh dry-run [文件 [安装结果另存为]]
#                                                    只读预演：打印自定义规则文件（默认设备上那份）安装 / 卸载后的受管段和核对结果
#   setsid sh /tmp/r3mini-adblock-pkg/install.sh install   </dev/null >/dev/null 2>&1 &   后台安装（SSH 断开不中断）
#   setsid sh /tmp/r3mini-adblock-pkg/install.sh uninstall </dev/null >/dev/null 2>&1 &   后台卸载
# 安装 / 卸载的结果看 /tmp/r3mini-adblock-install.log 最后一行：
#   INSTALL_OK [UPDATE_FAILED <原因> | SUBSCRIPTION_DISABLED <原因>] / UNINSTALL_OK
#   ROLLED_BACK_OK <原因> / ROLLED_BACK_BUT_UNHEALTHY <原因> / ABORT <原因>（ABORT 时设备没被改动）
# 已有一个安装 / 卸载在跑时，第二次启动直接退出，不写日志。
#
# 安装做的事（改前把涉及的文件逐个备份并核对到 /etc/r3mini-adblock-backup-<时间>/，备份失败就 ABORT）：
#   1. 装 /usr/sbin/r3mini-adblock、/etc/r3mini-adblock/ 规则数据、LuCI 页面（服务 → 广告过滤）；
#      /etc/config/r3mini_adblock 已存在就保留（重装不丢开关设置）
#   2. openclash_custom_rules.list：删掉旧的 hongguo-adblock 受管段，在 rule-providers: 和 rules: 下各插一段受管段
#      （缩进跟随文件原有写法；核对改写后除本方案以外的解析结果不变）
#   3. dnsmasq：删掉旧方案写进去的广告域名（dnsmasq-remove.list；这些域名改由规则集拦）
#   4. 重启 OpenClash，核对运行配置里本方案以外的 DNS 段、分组、节点数、其它规则集、规则逐条不变，且两个规则集已加载；
#      任一项不符就把上面全部改动回滚（OpenClash 还没重启时回滚只还原文件，不重启）
#   5. 下载一次订阅；下载失败不回滚（内置规则照常生效）；下载后外网检查不过就关掉订阅再查，还不过才回滚
# 卸载：删掉上述全部改动；dnsmasq 旧条目和旧 hongguo-adblock 受管段都不恢复；同样核对并回滚。
# 安装 / 卸载期间持有 r3mini-adblock 的 update 与 apply 锁：先等正在跑的订阅更新结束，再挡住开关和定时更新。
set -u
PKG=$(cd "$(dirname "$0")" && pwd)
MODE=${1:-}
TS=$(date +%Y%m%d-%H%M%S)
BK=/etc/r3mini-adblock-backup-$TS
LOG=/tmp/r3mini-adblock-install.log
RULES=/etc/openclash/custom/openclash_custom_rules.list
PROV=/etc/openclash/rule_provider
CRON=/etc/crontabs/root
VIEWDIR=/www/luci-static/resources/view/services
B='# >>> r3mini-adblock (managed) >>>'
E='# <<< r3mini-adblock (managed) <<<'
OB='# >>> hongguo-adblock (managed) >>>'
OE='# <<< hongguo-adblock (managed) <<<'
SYS_FILES="usr/sbin/r3mini-adblock www/luci-static/resources/view/services/r3mini-adblock.js
usr/share/luci/menu.d/luci-app-r3mini-adblock.json usr/share/rpcd/acl.d/luci-app-r3mini-adblock.json"
GEN="etc/config/r3mini_adblock etc/openclash/rule_provider/r3mini-adblock-domain.txt etc/openclash/rule_provider/r3mini-adblock-rule.txt"
CHECK_INSTALL="same=true providers=r3mini-adblock-domain,r3mini-adblock-rule defs=true ours_rules=2 head=RULE-SET,r3mini-adblock-rule,REJECT,RULE-SET,r3mini-adblock-domain,REJECT"
HAD_CRON=0; HAD_DATA=0; HAD_VIEWDIR=0; RESTARTED=0; NEED_OVERSEAS=0
say() { echo "$(date +%T) $*"; }

run_yaml() { echo "/etc/openclash/$(basename "$(uci -q get openclash.config.config_path)")"; }

# 运行配置快照：stdout 打印 DNS 段 / 分组名 / 节点数 / 本方案以外的规则集定义，$1 写入本方案以外的全部规则（逐条）
# 「本方案」= 含 r3mini-adblock 的规则，加上旧 hongguo-adblock 受管段里的规则（从备份的自定义规则文件取）
snapshot() {
	ruby -ryaml -e '
		def s(o) o.is_a?(Hash) ? o.sort_by { |k, _| k.to_s }.map { |k, v| [k, s(v)] } : (o.is_a?(Array) ? o.map { |x| s(x) } : o) end
		c = YAML.load_file(ARGV[0]); old = []; inb = false
		File.readlines(ARGV[1]).each { |l| l = l.chomp.sub(/\r\z/, "")
			if l == ARGV[3] then inb = true elsif l == ARGV[4] then inb = false elsif inb then old << l.strip.sub(/^- /, "") end }
		r = (c["rules"] || []).map(&:to_s).reject { |x| x.include?("r3mini-adblock") || old.include?(x) }
		File.write(ARGV[2], r.join("\n") + "\n")
		pv = (c["rule-providers"] || {}).reject { |k, _| k.to_s.start_with?("r3mini-adblock") }
		puts [s(c["dns"]).inspect, (c["proxy-groups"] || []).map { |g| g["name"] }.inspect, (c["proxies"] || []).size, s(pv).inspect].join("|")
	' "$(run_yaml)" "$BK/openclash_custom_rules.list" "$1" "$OB" "$OE"
}

# 运行配置里本方案的状态：规则前两条、两个规则集的定义
ours_runtime() {
	ruby -ryaml -e '
		c = YAML.load_file(ARGV[0]); p = c["rule-providers"] || {}
		ok = ->(n, b) { p[n].is_a?(Hash) && p[n]["type"] == "file" && p[n]["behavior"] == b && p[n]["path"].to_s.end_with?(n + ".txt") }
		puts "head=#{(c["rules"] || []).first(2).inspect} rule=#{ok.("r3mini-adblock-rule", "classical")} domain=#{ok.("r3mini-adblock-domain", "domain")}"
	' "$(run_yaml)"
}

# 自定义规则文件改写前后对比：除本方案（和旧 hongguo 段）以外解析结果是否不变，本方案的规则集定义与规则是否正确
custom_check() {
	ruby -ryaml -e '
		o = YAML.load_file(ARGV[0]); n = YAML.load_file(ARGV[1]); old = []; inb = false
		File.readlines(ARGV[0]).each { |l| l = l.chomp.sub(/\r\z/, "")
			if l == ARGV[2] then inb = true elsif l == ARGV[3] then inb = false elsif inb then old << l.strip.sub(/^- /, "") end }
		strip = lambda { |c| c = (c.is_a?(Hash) ? c : {}).dup
			c["rule-providers"] = (c["rule-providers"] || {}).reject { |k, _| k.to_s.start_with?("r3mini-adblock") }
			c["rules"] = (c["rules"] || []).map(&:to_s).reject { |x| x.include?("r3mini-adblock") || old.include?(x) }
			c }
		pv = n.is_a?(Hash) ? (n["rule-providers"] || {}) : {}; r = n.is_a?(Hash) ? (n["rules"] || []).map(&:to_s) : []
		want = ->(k, b) { {"type" => "file", "behavior" => b, "format" => "text", "path" => "./rule_provider/#{k}.txt"} }
		defs = pv["r3mini-adblock-rule"] == want.("r3mini-adblock-rule", "classical") && pv["r3mini-adblock-domain"] == want.("r3mini-adblock-domain", "domain")
		puts "same=#{strip.(o) == strip.(n)} providers=#{pv.keys.map(&:to_s).select { |k| k.start_with?("r3mini-adblock") }.sort.join(",")} defs=#{defs} ours_rules=#{r.count { |x| x.include?("r3mini-adblock") }} head=#{r.first(2).all? { |x| x.include?("r3mini-adblock") } ? r.first(2).join(",") : "other"}"
	' "$1" "$2" "$OB" "$OE" 2>&1
}

# 受管段开始 / 结束标记是否成对（容忍 CRLF）
markers_ok() {
	[ "$(awk -v b="$B" -v e="$E" -v ob="$OB" -v oe="$OE" '
		{ l = $0; sub(/\r$/, "", l) }
		l == b || l == ob { if (open) bad = 1; open = 1 }
		l == e || l == oe { if (!open) bad = 1; open = 0 }
		END { print (bad || open) ? "bad" : "ok" }' "$1")" = ok ]
}

# 改写自定义规则文件：模式 输入 输出 临时目录。去掉新旧受管段；install 时在 rule-providers: 与 rules: 下一行各插一段，
# 缩进跟随原文件（rule-providers 下第一个条目、rules 下第一条规则的缩进）；文件里没有 rule-providers: 时补在 rules: 前面。
# stdout 打印检测到的缩进。
edit_custom() {
	ind=$(awk -v b="$B" -v e="$E" -v ob="$OB" -v oe="$OE" '
		{ l = $0; sub(/\r$/, "", l) }
		l == b || l == ob { skip = 1; next }
		l == e || l == oe { skip = 0; next }
		skip { next }
		l ~ /^[A-Za-z_][A-Za-z0-9_-]*:/ { sec = l; next }
		l ~ /^[ \t]*(#|$)/ { next }
		sec ~ /^rule-providers:/ && pi == "" && l ~ /^[ \t]+[^ \t-]/ { match(l, /^[ \t]+/); pi = substr(l, 1, RLENGTH) }
		sec ~ /^rules:/ && !rs && l ~ /^[ \t]*- / { match(l, /^[ \t]*/); ri = substr(l, 1, RLENGTH); rs = 1 }
		END { printf "%s|%s", (pi == "" ? "  " : pi), ri }' "$2")
	pi=${ind%%|*}; ri=${ind#*|}
	for p in r3mini-adblock-rule:classical r3mini-adblock-domain:domain; do
		printf '%s%s:\n%s  type: file\n%s  behavior: %s\n%s  format: text\n%s  path: ./rule_provider/%s.txt\n' \
			"$pi" "${p%%:*}" "$pi" "$pi" "${p#*:}" "$pi" "$pi" "${p%%:*}"
	done > "$4/providers.snip"
	printf '%s- RULE-SET,r3mini-adblock-rule,REJECT\n%s- RULE-SET,r3mini-adblock-domain,REJECT\n' "$ri" "$ri" > "$4/rules.snip"
	echo "缩进：rule-providers 下 [${pi}]，rules 下 [${ri}]"
	haspv=0; grep -q '^rule-providers:' "$2" && haspv=1
	awk -v b="$B" -v e="$E" -v ob="$OB" -v oe="$OE" -v mode="$1" -v ps="$4/providers.snip" -v rs="$4/rules.snip" -v haspv="$haspv" '
		{ l = $0; sub(/\r$/, "", l) }
		l == b || l == ob { skip = 1; next }
		l == e || l == oe { skip = 0; next }
		skip { next }
		mode == "install" && !haspv && l ~ /^rules:[ \t]*$/ && !p { print "rule-providers:"; print b; while ((getline x < ps) > 0) print x; print e; p = 1 }
		{ print }
		mode == "install" && l ~ /^rule-providers:[ \t]*$/ && !p { print b; while ((getline x < ps) > 0) print x; print e; p = 1 }
		mode == "install" && l ~ /^rules:[ \t]*$/ && !r { print b; while ((getline x < rs) > 0) print x; print e; r = 1 }
		END { if (mode == "install" && (!p || !r)) exit 3 }
	' "$2" > "$3"
}

addr_count() { uci -q get dhcp.@dnsmasq[0].address | tr ' ' '\n' | grep -c '/0\.0\.0\.0$'; }

http_ok() { code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$1" 2>/dev/null); [ -n "$code" ] && [ "$code" != 000 ]; }

# 健康：OpenClash 在跑、本机 DNS 能解析、国内站能访问；海外站改动前能访问的话（有代理节点），改动后也必须能访问
healthy() {
	[ "$(/etc/init.d/openclash status 2>/dev/null)" = running ] || return 1
	[ -n "$(nslookup www.baidu.com 127.0.0.1 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)" ] || return 1
	http_ok https://www.baidu.com/ || return 1
	[ "$NEED_OVERSEAS" = 1 ] || return 0
	http_ok https://api.anthropic.com/
}

wait_healthy() {
	i=0
	while [ "$i" -lt 30 ]; do
		healthy && return 0
		sleep 3; i=$((i + 1))
	done
	return 1
}

luci_refresh() { rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache; /etc/init.d/rpcd reload; }

rollback() {
	say "ROLLBACK: $1"
	cp -p "$BK/openclash_custom_rules.list" "$RULES"
	cp -p "$BK/dhcp" /etc/config/dhcp; uci -q revert dhcp
	if [ "$HAD_CRON" = 1 ]; then cat "$BK/crontab" > "$CRON"; else rm -f "$CRON"; fi
	rm -rf /etc/r3mini-adblock
	[ "$HAD_DATA" = 1 ] && tar -xf "$BK/data.tar" -C /etc
	for f in $SYS_FILES $GEN; do
		if [ -e "$BK/files/$f" ]; then mkdir -p "$(dirname "/$f")"; cp -p "$BK/files/$f" "/$f"; else rm -f "/$f"; fi
	done
	[ "$HAD_VIEWDIR" = 1 ] || rmdir "$VIEWDIR" 2>/dev/null
	/etc/init.d/cron restart
	luci_refresh
	if [ "$RESTARTED" = 1 ]; then
		[ "$MODE" = install ] && /etc/init.d/dnsmasq restart
		/etc/init.d/openclash restart
		if wait_healthy; then say "ROLLED_BACK_OK $1 backup=$BK"; else say "ROLLED_BACK_BUT_UNHEALTHY $1 backup=$BK"; fi
	else
		say "ROLLED_BACK_OK $1（OpenClash 还没重启过，只还原了文件）backup=$BK"
	fi
	exit 1
}

bk() { cp -p "$1" "$2" && cmp -s "$1" "$2" || { say "ABORT 备份失败：$1 -> $2（设备没被改动）"; exit 1; }; }

# 前置检查：每项打印一行「[通过] / [不通过] / [提醒] 名称：说明」，不改设备。参数：install | uninstall
# 第一项不通过写进 FIRST_FAIL；install / uninstall 据此 ABORT，check 模式全部打印完再给结论。[提醒] 不挡安装。
FIRST_FAIL=
item() {
	echo "  [$1] $2${3:+：$3}"
	[ "$1" = 不通过 ] && [ -z "$FIRST_FAIL" ] && FIRST_FAIL="$2：$3"
	return 0
}
preflight() {
	if [ "$1" = install ]; then
		miss=
		for f in $SYS_FILES etc/config/r3mini_adblock etc/r3mini-adblock/core.rules etc/r3mini-adblock/domains.list; do
			[ -s "$PKG/router/$f" ] || miss="$miss router/$f"
		done
		[ -s "$PKG/dnsmasq-remove.list" ] || miss="$miss dnsmasq-remove.list"
		if [ -n "$miss" ]; then item 不通过 安装包 "包里缺$miss，重新完整上传 adblock/"; else item 通过 安装包; fi
	fi
	miss=
	for c in ruby curl jsonfilter flock setsid md5sum cmp tar opkg; do command -v "$c" > /dev/null || miss="$miss $c"; done
	if [ -n "$miss" ]; then item 不通过 命令 "缺$miss"; else item 通过 命令 "ruby curl jsonfilter flock setsid md5sum cmp tar 都在"; fi
	v=$(opkg list-installed 2>/dev/null | sed -n 's/^luci-app-openclash - //p')
	case "$v" in
		'') item 不通过 OpenClash版本 "没装 luci-app-openclash" ;;
		0.47.*|0.4[89].*|0.[5-9]*|[1-9]*) item 通过 OpenClash版本 "$v" ;;
		*) item 提醒 OpenClash版本 "$v，只在 0.47.156 上验证过；太旧的版本不合并自定义规则集，安装器会在重启后发现并自动回滚" ;;
	esac
	if [ "$(/etc/init.d/openclash status 2>/dev/null)" = running ]; then item 通过 OpenClash运行; else item 不通过 OpenClash运行 "没在运行"; fi
	if [ "$1" = install ]; then
		if [ "$(uci -q get openclash.config.enable_custom_clash_rules)" = 1 ]; then item 通过 自定义规则开关
		else item 不通过 自定义规则开关 "enable_custom_clash_rules 不是 1，规则集不会被加载"; fi
	fi
	if [ "$(uci -q get openclash.config.enable_meta_sniffer)" = 1 ] && [ "$(uci -q get openclash.config.enable_meta_sniffer_pure_ip)" = 1 ]; then item 通过 流量嗅探
	else item 提醒 流量嗅探 "嗅探或嗅探纯 IP 没开，App 绕过 DNS 直连 IP 的广告拦不住"; fi
	case "$(uci -q get openclash.config.china_ip_route)" in
		''|0) item 通过 大陆IP绕过 "关" ;;
		*) item 提醒 大陆IP绕过 "开着，直连国内 IP 的流量不经过 OpenClash，App 绕过 DNS 直连 IP 的广告拦不住" ;;
	esac
	if [ ! -f "$RULES" ]; then item 不通过 自定义规则文件 "$RULES 不存在"
	elif ! grep -q '^rules:[[:space:]]*$' "$RULES"; then item 不通过 自定义规则文件 "没有单独成行的顶层 rules:"
	elif grep -q '^rule-providers:' "$RULES" && ! grep -q '^rule-providers:[[:space:]]*$' "$RULES"; then item 不通过 自定义规则文件 "rule-providers: 写成了行内值，不自动改"
	elif ! markers_ok "$RULES"; then item 不通过 自定义规则文件 "受管段开始 / 结束标记不成对，请人工检查"
	else item 通过 自定义规则文件 "$RULES"; fi
	y=$(run_yaml)
	if [ ! -f "$y" ]; then item 不通过 运行配置 "$y 不存在"
	elif [ "$RULES" -nt "$y" ]; then item 不通过 运行配置 "自定义规则改过但 OpenClash 还没重启（$y 比它旧），先重启 OpenClash"
	else item 通过 运行配置 "$y"; fi
	if [ "$1" = install ]; then
		if [ -z "$(uci changes dhcp)" ]; then item 通过 dhcp暂存改动 "无"
		else item 不通过 dhcp暂存改动 "有没提交的改动（LuCI 里没点保存并应用？）"; fi
	fi
	free=$(df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')
	if [ "${free:-0}" -ge 2048 ]; then item 通过 剩余空间 "/overlay 剩 $((free / 1024)) MB"
	else item 不通过 剩余空间 "/overlay 剩 ${free:-?} KB，不足 2 MB"; fi
	NEED_OVERSEAS=0; http_ok https://api.anthropic.com/ && NEED_OVERSEAS=1
	if healthy; then item 通过 网络 "本机 DNS 与国内站正常；海外站 api.anthropic.com $([ "$NEED_OVERSEAS" = 1 ] && echo '能访问，改动后也必须能访问' || echo '访问不了，不作要求')"
	else item 不通过 网络 "OpenClash、本机 DNS、国内站 www.baidu.com 至少一项不正常"; fi
	[ -z "$FIRST_FAIL" ]
}

usage() { echo "用法：sh install.sh check | dry-run [文件 [安装结果另存为]] | install | uninstall（必须带参数）" >&2; }

case "$MODE" in
	check)
		echo "只读预检（不改设备）："
		if preflight install; then echo "CHECK_OK 可以安装"; exit 0; else echo "CHECK_FAIL $FIRST_FAIL"; exit 1; fi ;;
	dry-run)
		F=${2:-$RULES}; D=$(mktemp -d /tmp/r3ab-dry.XXXXXX)
		markers_ok "$F" || { echo "MARKERS_BAD 受管段开始 / 结束标记不成对"; rm -rf "$D"; exit 1; }
		for m in install uninstall; do
			edit_custom "$m" "$F" "$D/$m.out" "$D"; rc=$?
			echo "== $m: awk_rc=$rc $(custom_check "$F" "$D/$m.out")"
			awk -v b="$B" -v e="$E" '$0 == b { p = 1 } p { print NR ": " $0 } $0 == e { p = 0 }' "$D/$m.out"
		done
		echo "== 期望 install 核对结果：$CHECK_INSTALL"
		[ -n "${3:-}" ] && cp "$D/install.out" "$3"
		rm -rf "$D"; exit 0 ;;
	install|uninstall) ;;
	*) usage; exit 1 ;;
esac

# 锁：安装器单实例（第二个实例直接退出，不碰正在跑那次的日志）；等正在跑的订阅更新结束，并在整个过程中挡住开关与定时更新
command -v flock > /dev/null || { echo "$(date +%T) ABORT 命令：缺 flock（设备没被改动）" > "$LOG"; exit 1; }
mkdir -p /var/lock /var/run/r3mini-adblock
exec 6> /var/lock/r3mini-adblock-install.lock
flock -n 6 || { echo "已有一个安装 / 卸载在跑，看 $LOG" >&2; exit 1; }
exec > "$LOG" 2>&1
say "START mode=$MODE pkg=$PKG backup=$BK"
exec 5> /var/run/r3mini-adblock/update.lock; flock 5
exec 4> /var/run/r3mini-adblock/apply.lock; flock 4
export R3AB_LOCKED=1

say "前置检查："
preflight "$MODE" || { say "ABORT $FIRST_FAIL（设备没被改动）"; exit 1; }

# 备份（逐个核对）
mkdir -p "$BK/files" || { say "ABORT 建不了备份目录 $BK"; exit 1; }
bk "$RULES" "$BK/openclash_custom_rules.list"
bk /etc/config/dhcp "$BK/dhcp"
[ -f "$CRON" ] && { bk "$CRON" "$BK/crontab"; HAD_CRON=1; }
[ -d /etc/r3mini-adblock ] && { tar -cf "$BK/data.tar" -C /etc r3mini-adblock || { say "ABORT 备份 /etc/r3mini-adblock 失败"; exit 1; }; HAD_DATA=1; }
[ -d "$VIEWDIR" ] && HAD_VIEWDIR=1
for f in $SYS_FILES $GEN; do
	[ -e "/$f" ] && { mkdir -p "$(dirname "$BK/files/$f")"; bk "/$f" "$BK/files/$f"; }
done
echo "HAD_CRON=$HAD_CRON HAD_DATA=$HAD_DATA HAD_VIEWDIR=$HAD_VIEWDIR" > "$BK/had.txt"
BEFORE=$(snapshot "$BK/rules.before") || { say "ABORT 读不了运行配置"; exit 1; }
echo "$BEFORE" > "$BK/snapshot.before"
say "before: $(echo "$BEFORE" | md5sum | cut -c1-12) rules=$(grep -c . "$BK/rules.before") dnsmasq_addr=$(addr_count)"

# 1. 文件
if [ "$MODE" = install ]; then
	mkdir -p /etc/r3mini-adblock
	cp "$PKG/router/etc/r3mini-adblock/core.rules" "$PKG/router/etc/r3mini-adblock/domains.list" /etc/r3mini-adblock/ || rollback copy_failed
	for f in $SYS_FILES; do mkdir -p "$(dirname "/$f")"; cp "$PKG/router/$f" "/$f" || rollback copy_failed; done
	chmod 755 /usr/sbin/r3mini-adblock
	chmod 644 /etc/r3mini-adblock/core.rules /etc/r3mini-adblock/domains.list "$VIEWDIR/r3mini-adblock.js" \
		/usr/share/luci/menu.d/luci-app-r3mini-adblock.json /usr/share/rpcd/acl.d/luci-app-r3mini-adblock.json
	[ -s /etc/config/r3mini_adblock ] || cp "$PKG/router/etc/config/r3mini_adblock" /etc/config/r3mini_adblock || rollback copy_failed
	/usr/sbin/r3mini-adblock build || rollback build_failed
	[ -s "$PROV/r3mini-adblock-domain.txt" ] && [ -s "$PROV/r3mini-adblock-rule.txt" ] || rollback provider_files_missing
	say "规则集文件：domain $(wc -l < "$PROV/r3mini-adblock-domain.txt") 行，rule $(wc -l < "$PROV/r3mini-adblock-rule.txt") 行"
else
	[ -f "$CRON" ] && { grep -v -F '#r3mini-adblock' "$CRON" > "$CRON.r3ab.tmp"; cat "$CRON.r3ab.tmp" > "$CRON"; rm -f "$CRON.r3ab.tmp"; }
	/etc/init.d/cron restart
	for f in $SYS_FILES $GEN; do rm -f "/$f"; done
	rm -rf /etc/r3mini-adblock
	rmdir "$VIEWDIR" 2>/dev/null
fi

# 2. OpenClash 自定义规则：去掉新旧受管段；install 时在 rule-providers: 与 rules: 下一行各插一段
OUT=$(edit_custom "$MODE" "$BK/openclash_custom_rules.list" "$RULES.new" "$BK") && mv "$RULES.new" "$RULES" || rollback custom_rules_write_failed
say "$OUT"
CHECK=$(custom_check "$BK/openclash_custom_rules.list" "$RULES")
say "custom rules: $CHECK"
if [ "$MODE" = install ]; then
	[ "$CHECK" = "$CHECK_INSTALL" ] || rollback custom_rules_not_written
else
	case "$CHECK" in "same=true providers= defs=false ours_rules=0 "*) ;; *) rollback custom_rules_unexpected ;; esac
	grep -q 'r3mini-adblock (managed)\|hongguo-adblock (managed)' "$RULES" && rollback managed_block_still_present
fi

# 3. dnsmasq：删旧方案的广告域名
if [ "$MODE" = install ]; then
	N0=$(addr_count)
	while read -r d; do [ -n "$d" ] && uci -q del_list dhcp.@dnsmasq[0].address="/$d/0.0.0.0"; done < "$PKG/dnsmasq-remove.list"
	uci commit dhcp || rollback dhcp_commit_failed
	say "dnsmasq: 广告域名 $N0 条 -> $(addr_count) 条（其它来源的条目保留）"
fi

# 4. 重启并核对
RESTARTED=1
[ "$MODE" = install ] && /etc/init.d/dnsmasq restart
/etc/init.d/openclash restart
wait_healthy || rollback unhealthy_after_restart
AFTER=$(snapshot "$BK/rules.after") || rollback snapshot_failed
echo "$AFTER" > "$BK/snapshot.after"
say "after: $(echo "$AFTER" | md5sum | cut -c1-12) rules=$(grep -c . "$BK/rules.after")"
[ "$AFTER" = "$BEFORE" ] || rollback runtime_changed_beyond_adblock
cmp -s "$BK/rules.before" "$BK/rules.after" || rollback other_rules_changed
RT=$(ours_runtime); say "runtime: $RT"
if [ "$MODE" = uninstall ]; then
	case "$RT" in *'rule=false domain=false') ;; *) rollback provider_still_in_runtime ;; esac
	luci_refresh
	rm -rf /var/run/r3mini-adblock
	say "UNINSTALL_OK backup=$BK"
	exit 0
fi
[ "$RT" = 'head=["RULE-SET,r3mini-adblock-rule,REJECT", "RULE-SET,r3mini-adblock-domain,REJECT"] rule=true domain=true' ] || rollback rules_not_in_runtime
/usr/sbin/r3mini-adblock apply || rollback provider_not_loaded
say "status: $(/usr/sbin/r3mini-adblock status)"
luci_refresh

# 5. 下载订阅
if MSG=$(/usr/sbin/r3mini-adblock update); then
	say "订阅：$MSG"
	if wait_healthy; then
		say "status: $(/usr/sbin/r3mini-adblock status)"
		say "INSTALL_OK backup=$BK"
	else
		say "订阅生效后外网检查不过，关掉订阅再查"
		/usr/sbin/r3mini-adblock sub off > /dev/null
		wait_healthy || rollback unhealthy_even_without_subscription
		say "INSTALL_OK SUBSCRIPTION_DISABLED 订阅生效后外网检查不过，已关掉订阅（内置规则照常生效） backup=$BK"
	fi
else
	say "INSTALL_OK UPDATE_FAILED $MSG backup=$BK"
fi
