#!/bin/sh
# r3mini-socks5 集成测试（第 3 版）：在路由器上搭一套隔离沙箱，用**设备上真实的订阅文件**跑后端全流程。
#   - 订阅：复制 /etc/openclash/config/ 里的真实订阅（节点数、名字、协议都和实机一样），测完删除；
#   - 「OpenClash」：一个临时 Mihomo（127.0.0.1:19090），运行配置里带着第 2 版注入的条目，用来测清理迁移；
#   - SOCKS5：公开端口 27896，内部端口平移 +10010（27906/27907/27908），和正式实例并存。
# 不碰正式 OpenClash、正式 SOCKS5 的配置、进程和端口；结束时杀掉临时进程、删除目录。
# 用法（在路由器上）：
#   BACKEND=/tmp/x/r3mini-socks5.rb NODE='🇮🇶 伊拉克' [SUB=<订阅文件名>] [OTHER=<另一个订阅文件名>] [PIN=<节点入口 IPv4>] sh test_integration.sh
# SUB 默认是 OpenClash 当前配置，OTHER 默认是 /etc/openclash/config/ 里排在最前的另一个订阅。
set -u
BASE=/tmp/r3s5-it-$$
ROOT=$BASE/root
BACKEND=${BACKEND:?需要 BACKEND=后端文件路径}
NODE=${NODE:?需要 NODE=测试用节点名}
SUB=${SUB:-$(basename "$(uci -q get openclash.config.config_path)")}
OTHER=${OTHER:-$(ls /etc/openclash/config/ | grep -E '\.ya?ml$' | grep -vxF "$SUB" | head -n 1)}
[ -n "$SUB" ] && [ -n "$OTHER" ] || { echo "找不到两个订阅文件"; exit 1; }
PIN=${PIN:-}
CORE=/etc/openclash/core/clash_meta
SB=$(for p in /usr/bin/sing-box /mnt/mmcblk0p6/r3mini-socks5/sing-box; do [ -x $p ] && echo $p && break; done)
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  通过  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  失败  $1"; [ -n "${2:-}" ] && echo "        $2" | cut -c1-400; return 0; }
g65534() { ruby -e 'Process.groups=[65534]; Process::Sys.setgid(65534); exec(*ARGV)' "$@"; }

cleanup() {
	for f in $BASE/main.pid $BASE/sb.pid $BASE/sc.pid $BASE/dl.pid; do [ -f $f ] && kill $(cat $f) 2>/dev/null; done
	sleep 1
	for p in $(pidof clash_meta sing-box curl 2>/dev/null); do
		case "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)" in *$BASE*) kill $p 2>/dev/null;; esac
	done
	rm -rf $BASE
}
trap cleanup EXIT INT TERM

mkdir -p $ROOT/sbin $ROOT/usr/bin $ROOT/usr/libexec $ROOT/etc/openclash/config $ROOT/etc/openclash/core $ROOT/etc/init.d $ROOT/tmp $ROOT/var/lock $BASE/mh
chmod 700 $BASE
ln -s /proc $ROOT/proc
ln -s /usr/bin/curl $ROOT/usr/bin/curl
ln -s "$(command -v ip)" $ROOT/sbin/ip
ln -s "$SB" $ROOT/usr/bin/sing-box
ln -s $CORE $ROOT/etc/openclash/core/clash_meta
cp "$BACKEND" $ROOT/usr/libexec/r3mini-socks5.rb
cat > $ROOT/sbin/uci <<EOF
#!/bin/sh
[ "\$1" = "-q" ] && [ "\$2" = "get" ] || exit 1
case "\$3" in
	openclash.config.config_path) echo /etc/openclash/config/$SUB;;
	openclash.config.http_port) echo 7890;; openclash.config.socks_port) echo 7891;;
	openclash.config.mixed_port) echo 7893;; openclash.config.tproxy_port) echo 7895;;
	openclash.config.proxy_port) echo 7892;; openclash.config.dns_port) echo 7874;;
	openclash.config.cn_port) echo 9090;;
	*) exit 1;;
esac
EOF
# 模拟 procd：start 只补起没在跑的实例，stop 全停，restart 先停后起。
cat > $ROOT/etc/init.d/r3mini-socks5 <<EOF
#!/bin/sh
C=$ROOT/tmp/r3mini-socks5/core
P=$ROOT/tmp/r3mini-socks5/ipv4.json
G='Process.groups=[65534]; Process::Sys.setgid(65534); exec(*ARGV)'
alive() { [ -f "\$1" ] && kill -0 \$(cat "\$1") 2>/dev/null; }
stop() { for f in $BASE/sc.pid $BASE/sb.pid; do [ -f \$f ] && kill \$(cat \$f) 2>/dev/null; rm -f \$f; done; sleep 1; }
start() {
	[ -s \$C/config.yaml ] || R3MINI_SOCKS5_ROOT=$ROOT R3MINI_SOCKS5_PORT_SHIFT=10010 ruby $ROOT/usr/libexec/r3mini-socks5.rb prepare >/dev/null 2>&1
	[ -s \$C/config.yaml ] || return 0
	alive $BASE/sc.pid || { SAFE_PATHS=\$C ruby -e "\$G" $ROOT/etc/openclash/core/clash_meta -d \$C -f \$C/config.yaml </dev/null >>$BASE/small.log 2>&1 & echo \$! > $BASE/sc.pid; }
	[ -s \$P ] || return 0
	alive $BASE/sb.pid || { ruby -e "\$G" $ROOT/usr/bin/sing-box run -c \$P </dev/null >/dev/null 2>&1 & echo \$! > $BASE/sb.pid; }
}
case "\$1" in start) start;; stop) stop;; restart) stop; start;; esac
EOF
chmod 755 $ROOT/sbin/uci $ROOT/etc/init.d/r3mini-socks5

# 真实订阅文件（必要时把测试节点的入口钉成 PIN），和一份带第 2 版注入条目的「OpenClash 运行配置」。
for f in $SUB $OTHER; do cp /etc/openclash/config/$f $ROOT/etc/openclash/config/$f || exit 1; done
chmod 600 $ROOT/etc/openclash/config/*
Y=/etc/openclash/$(basename "$(uci -q get openclash.config.config_path)")
ruby -ryaml -e '
y, sub, out, node, pin = ARGV
rt = YAML.safe_load(File.read(y), aliases: true)
s = YAML.safe_load(File.read(sub), aliases: true)
main = s["proxies"].find { |p| p["name"] == node } or abort("订阅里没有节点 #{node}")
unless pin.empty?
  main["server"] = pin
  File.write(sub, YAML.dump(s))
end
users = [{ "username" => "ituser", "password" => "it-pass-old" }]
c = { "allow-lan" => false, "mode" => "rule", "log-level" => "warning", "ipv6" => false,
      "external-controller" => "127.0.0.1:19090", "secret" => "it-secret", "profile" => { "store-selected" => true },
      "dns" => rt["dns"].slice("default-nameserver", "nameserver", "proxy-server-nameserver").merge("enable" => false),
      "sniffer" => { "enable" => true, "skip-src-address" => ["127.0.0.2/32"] },
      "proxies" => [main, { "name" => "r3mini-socks5-ipv4", "type" => "socks5", "server" => "127.0.0.1", "port" => 27906,
                            "username" => "ituser", "password" => "it-pass-old", "x-r3mini-owner" => "r3mini-socks5" }],
      "proxy-groups" => [
        { "name" => "MESL", "type" => "select", "proxies" => [node] },
        { "name" => "r3mini-socks5-exit", "type" => "select", "hidden" => true, "proxies" => [node, "DIRECT", "REJECT"] },
        { "name" => "r3mini-socks5-mode", "type" => "select", "hidden" => true, "proxies" => ["r3mini-socks5-exit", "r3mini-socks5-ipv4"] }],
      "listeners" => [{ "name" => "r3mini-socks5", "type" => "socks", "port" => 27896, "listen" => "127.0.0.1", "udp" => true,
                        "users" => users, "proxy" => "r3mini-socks5-mode" }],
      "rules" => ["MATCH,DIRECT"] }
File.write(out, YAML.dump(c))
puts "订阅 #{File.basename(sub)}：#{s["proxies"].size} 个节点；测试节点 #{node}#{pin.empty? ? "" : "（入口钉成 " + pin + "）"}"
' "$Y" $ROOT/etc/openclash/config/$SUB $ROOT/etc/openclash/$SUB "$NODE" "$PIN" || exit 1
chmod 600 $ROOT/etc/openclash/$SUB
cp $ROOT/etc/openclash/$SUB $BASE/main.orig.yaml
mkdir -p $ROOT/etc/r3mini-socks5 && chmod 700 $ROOT/etc/r3mini-socks5
NODE_JSON=$(ruby -e 'require ARGV[0]; print R3MiniSocks5.json(ARGV[1])' $BACKEND "$NODE")
# 第 2 版格式的设置（没有 subscription 键）：apply 时应自动定成 OpenClash 当前配置。
printf '{"version":2,"enabled":true,"port":27896,"listen":"127.0.0.1","username":"ituser","password":"it-pass-old","udp":true,"ipv4_only":false,"target":%s,"owned":true,"last_action":null,"last_time":null}\n' "$NODE_JSON" > $ROOT/etc/r3mini-socks5/settings.json
chmod 600 $ROOT/etc/r3mini-socks5/settings.json

SAFE_PATHS=$ROOT/etc/openclash g65534 $CORE -d $BASE/mh -f $ROOT/etc/openclash/$SUB </dev/null >$BASE/main.log 2>&1 &
echo $! > $BASE/main.pid
sleep 3

be() { R3MINI_SOCKS5_ROOT=$ROOT R3MINI_SOCKS5_PORT_SHIFT=10010 R3MINI_SOCKS5_DEBUG=1 ruby $ROOT/usr/libexec/r3mini-socks5.rb "$@" 2>>$BASE/stderr.log; }
j() { ruby -ryaml -e 'x = YAML.safe_load(STDIN.read); v = ARGV[0].split(".").reduce(x) { |a, k| a.is_a?(Hash) ? a[k] : nil }; print v.is_a?(String) ? v : v.inspect' "$1"; }
b64() { printf '%s' "$1" | ruby -e 'print "b64:" + [STDIN.read].pack("m0").tr("+/", "-_").delete("=")'; }
up() { cut -d' ' -f1 /proc/uptime; }
el() { awk -v a=$1 -v b=$2 'BEGIN{printf "%.2f", b-a}'; }
hexport() { printf '%04X' $1; }
owner_pid() { ino=$(awk -v p=":$(hexport $1)\$" '$4=="0A" && $2 ~ p {print $10; exit}' /proc/net/tcp /proc/net/tcp6); [ -n "$ino" ] || return 0; for d in /proc/[0-9]*; do ls -l $d/fd 2>/dev/null | grep -q "socket:\[$ino\]" && { basename $d; return 0; }; done; }
corepid() { cat $BASE/sc.pid 2>/dev/null; }
creds() { printf 'proxy-user = "%s:%s"\n' ituser "$1"; }

echo "== 1. apply：清理「OpenClash」里第 2 版的条目，SOCKS5 改由自己的内核提供"
main_before=$(owner_pid 27896)
a=$(up); out=$(be apply); b=$(up)
[ "$(echo "$out" | j applied)" = true ] && ok "apply 后 applied=true（$(el $a $b)s）" || bad "apply" "$out"
grep -q 'r3mini-socks5\|127.0.0.2/32' $ROOT/etc/openclash/$SUB && bad "OpenClash 运行配置里还有第 2 版条目" || ok "OpenClash 运行配置里的第 2 版条目已清掉"
[ "$(owner_pid 27896)" = "$(corepid)" ] && [ "$main_before" != "$(corepid)" ] && ok "27896 由 SOCKS5 内核监听（原来是「OpenClash」）" || bad "27896 的监听者" "before=$main_before now=$(owner_pid 27896) core=$(corepid)"
[ "$(be status | j subscription.file)" = "$SUB" ] && grep -q "\"subscription\":\"$SUB\"" $ROOT/etc/r3mini-socks5/settings.json && ok "订阅自动定成 OpenClash 当前配置 $SUB 并写进设置" || bad "订阅没写进设置"
grep -q 'it-pass' $ROOT/tmp/r3mini-socks5/core/config.yaml && [ "$(ls -l $ROOT/tmp/r3mini-socks5/core/config.yaml | cut -c1-10)" = "-rw-------" ] && ok "内核配置含入站账号，权限 0600" || bad "内核配置权限"

echo "== 2. status / targets（真实订阅规模）"
a=$(up); st=$(be status); b=$(up)
[ "$(echo "$st" | j applied)" = true ] && [ "$(echo "$st" | j exit.now)" = "$NODE" ] && ok "status applied、出口=$NODE（$(el $a $b)s）" || bad "status" "$st"
echo "$st" | grep -q 'it-pass' && bad "status 泄露了密码" || ok "status 不含密码"
total=$(ruby -ryaml -e 'puts YAML.safe_load(File.read(ARGV[0]), aliases: true)["proxies"].size' $ROOT/etc/openclash/config/$SUB)
a=$(up); t=$(be targets); b=$(up)
[ "$(echo "$t" | ruby -ryaml -e 'puts YAML.safe_load(STDIN.read)["nodes"].size')" = "$total" ] && [ "$(echo "$t" | j current)" = "$NODE" ] && ok "targets：$total 个节点、current=$NODE（$(el $a $b)s）" || bad "targets" "$(echo "$t" | cut -c1-300)"
a=$(up); be targets >/dev/null; b=$(up); ok "targets 第二次（走缓存）$(el $a $b)s"
echo "$t" | ruby -ryaml -e 'x = YAML.safe_load(STDIN.read); puts x["subscriptions"].map { |s| s["file"] + (s["active"] ? "*" : "") + (s["current"] ? "(当前)" : "") }.join(" ")' | sed 's/^/  订阅：/'
t2=$(be targets "$(b64 $OTHER)"); n2=$(echo "$t2" | ruby -ryaml -e 'puts YAML.safe_load(STDIN.read)["nodes"].size')
[ "${n2:-0}" -gt 0 ] && [ "$(echo "$t2" | j current)" = nil ] && ok "浏览另一个订阅 $OTHER：$n2 个节点" || bad "targets $OTHER" "$(echo "$t2" | cut -c1-300)"

echo "== 3. 节点默认出口（未开仅 IPv4）"
pr=$(be probe); echo "  $(echo "$pr" | j google.ip) Google=$(echo "$pr" | j google.region) CF=$(echo "$pr" | j cloudflare.region)"
[ "$(echo "$pr" | j ok)" = true ] && ok "probe 成功（$(echo "$pr" | j elapsed_ms) ms）" || bad "probe" "$pr"

echo "== 4. 开关仅 IPv4（不重启内核）"
p0=$(corepid); a=$(up); out=$(be ipv4 on); b=$(up)
[ "$(echo "$out" | j applied)" = true ] && [ "$(echo "$out" | j mode)" = r3mini-socks5-ipv4 ] && ok "ipv4 on：applied、mode=ipv4（$(el $a $b)s）" || bad "ipv4 on" "$out"
[ "$(corepid)" = "$p0" ] && ok "开仅 IPv4 没有重启内核" || bad "开仅 IPv4 重启了内核"
pr=$(be probe); echo "$pr" | ruby -ryaml -e 'x = YAML.safe_load(STDIN.read); c = x["checks"] || []
v6 = c.select { |e| e["family"] == "IPv6" }.map { |e| e["id"] }
puts "  " + c.map { |e| "#{e["id"]}=#{e["region"] || "?"}/#{e["family"] || "-"}" }.join(" ")
puts (c.size == 5 && c.count { |e| e["ok"] } >= 4 && v6.empty?) ? "OK" : "BAD v6=#{v6.inspect} ok=#{c.count { |e| e["ok"] }}"' | { read l; echo "$l"; read r; [ "$r" = OK ] && ok "五家地区检测：至少 4 家有结果，没有 IPv6" || bad "多家地区检测" "$r"; }
v=$(be verify); [ "$(echo "$v" | j ok)" = true ] && ok "verify：Google $(echo "$v" | j google_ip)、Cloudflare $(echo "$v" | j cloudflare_ip)" || bad "verify" "$v"

echo "== 5. 同一订阅里换节点（不重载内核、断开旧连接）"
creds it-pass-old | curl -K - -s -m 60 --limit-rate 30k --socks5-hostname 127.0.0.1:27896 -o /dev/null 'https://speed.cloudflare.com/__down?bytes=20000000' &
echo $! > $BASE/dl.pid; sleep 3
alt=$(echo "$t" | ruby -ryaml -e 'x = YAML.safe_load(STDIN.read); n = x["nodes"].map { |e| e["name"] } - [ARGV[0]]; puts n.find { |e| e.include?("香港") } || n.first' "$NODE")
p0=$(corepid); a=$(up); out=$(be use "$(b64 "$alt")"); b=$(up)
[ "$(echo "$out" | j exit.now)" = "$alt" ] && [ "$(echo "$out" | j applied)" = true ] && ok "换到 $alt（$(el $a $b)s）" || bad "use $alt" "$out"
[ "$(corepid)" = "$p0" ] && ok "换节点没有重启内核" || bad "换节点重启了内核"
n=$(echo "$out" | j closed); [ "${n:-0}" -ge 1 ] 2>/dev/null && ok "断开了 $n 条旧连接" || bad "没有断开旧连接" "$out"
out=$(be use "$(b64 "$NODE")"); [ "$(echo "$out" | j exit.now)" = "$NODE" ] && ok "换回 $NODE" || bad "换回" "$out"

echo "== 6. 换到另一个订阅的节点再换回（热重载，不重启进程）"
first=$(echo "$t2" | ruby -ryaml -e 'puts YAML.safe_load(STDIN.read)["nodes"].first["name"]')
p0=$(corepid); a=$(up); out=$(be use "$(b64 "$first")" "$(b64 $OTHER)"); b=$(up)
[ "$(echo "$out" | j subscription.file)" = "$OTHER" ] && [ "$(echo "$out" | j exit.now)" = "$first" ] && [ "$(echo "$out" | j applied)" = true ] && ok "切到 $OTHER / $first（$(el $a $b)s）" || bad "换订阅" "$out"
[ "$(corepid)" = "$p0" ] && ok "换订阅没有重启内核" || bad "换订阅重启了内核"
pr=$(be probe); echo "  经 $first：$(echo "$pr" | j cloudflare.ip) $(echo "$pr" | j cloudflare.region)（仅供参考，节点本身可能不通）"
a=$(up); out=$(be use "$(b64 "$NODE")" "$(b64 $SUB)"); b=$(up)
[ "$(echo "$out" | j subscription.file)" = "$SUB" ] && [ "$(echo "$out" | j exit.now)" = "$NODE" ] && [ "$(echo "$out" | j applied)" = true ] && ok "切回 $SUB / $NODE（$(el $a $b)s）" || bad "切回" "$out"
[ "$(echo "$out" | j mode)" = r3mini-socks5-ipv4 ] && ok "换订阅后仍是仅 IPv4" || bad "换订阅后模式" "$out"

echo "== 7. 测速"
a=$(up); d=$(be delay-all); b=$(up)
nd=$(echo "$d" | ruby -ryaml -e 'puts (YAML.safe_load(STDIN.read)["delays"] || {}).size')
[ "$(echo "$d" | j ok)" = true ] && [ "${nd:-0}" -ge 1 ] && ok "全部测速：$nd 个节点有延迟（$(el $a $b)s）" || bad "delay-all" "$(echo "$d" | cut -c1-300)"
d=$(be delay); [ "$(echo "$d" | j ok)" = true ] && ok "当前出口延迟 $(echo "$d" | j delay) ms" || bad "delay" "$d"
d=$(be delay "$(b64 "$alt")"); [ "$(echo "$d" | j by)" = socks5 ] && ok "单独测一个非当前节点（$alt）：$(echo "$d" | j delay) ms" || bad "delay $alt" "$d"
d=$(be delay "$(b64 "$NODE")" "$(b64 $SUB)"); [ "$(echo "$d" | j by)" = socks5 ] && ok "指明当前订阅时由 SOCKS5 内核测" || bad "delay 指明订阅" "$d"
d=$(be delay "$(b64 "$first")" "$(b64 $OTHER)"); [ "$(echo "$d" | j error)" = DELAY_UNAVAILABLE ] && ok "没在运行的订阅 → DELAY_UNAVAILABLE" || bad "delay 其他订阅" "$d"
t=$(be targets); echo "$t" | ruby -ryaml -e 'x = YAML.safe_load(STDIN.read); puts x["nodes"].count { |e| e["delay"] }' | { read c; [ "${c:-0}" -ge 1 ] && ok "targets 带上了 $c 个延迟" || bad "targets 没有延迟"; }

echo "== 8. 改端口（热重载）与改密码（重启内核）"
p0=$(corepid); a=$(up); out=$(be save "$(b64 '{"port":27899}')"); b=$(up)
[ "$(echo "$out" | j applied)" = true ] && [ "$(owner_pid 27899)" = "$(corepid)" ] && [ -z "$(owner_pid 27896)" ] && ok "端口 27896 → 27899（$(el $a $b)s）" || bad "改端口" "$out"
[ "$(corepid)" = "$p0" ] && ok "改端口没有重启内核" || bad "改端口重启了内核"
out=$(be save "$(b64 '{"port":27896}')"); [ "$(owner_pid 27896)" = "$(corepid)" ] && ok "端口改回 27896" || bad "端口改回" "$out"
a=$(up); out=$(be save "$(b64 '{"password":"it-pass-new"}')"); b=$(up)
[ "$(echo "$out" | j applied)" = true ] && ok "改密码后 applied（$(el $a $b)s）" || bad "改密码" "$out"
code=$(creds it-pass-old | curl -K - -s -m 10 -o /dev/null -w '%{http_code}' --socks5-hostname 127.0.0.1:27896 https://www.gstatic.com/generate_204); [ "$code" = 000 ] && ok "旧密码被拒" || bad "旧密码还能用" "$code"
v=$(be verify); [ "$(echo "$v" | j ok)" = true ] && ok "新密码 verify 通过" || bad "新密码 verify" "$v"

echo "== 9. 订阅文件更新后，钩子同步；钩子清理第 2 版残留"
touch $ROOT/etc/openclash/config/$SUB
[ "$(be status | j subscription.stale)" = true ] && ok "status 报订阅已更新（stale）" || bad "stale 没报"
cp $ROOT/etc/openclash/$SUB $ROOT/tmp/$SUB
h=$(be hook /tmp/$SUB); [ "$(echo "$h" | j changed)" = false ] && [ "$(be status | j subscription.stale)" = false ] && ok "钩子同步了订阅、运行配置不变" || bad "hook 同步" "$h"
cp $BASE/main.orig.yaml $ROOT/tmp/$SUB
h=$(be hook /tmp/$SUB); [ "$(echo "$h" | j changed)" = true ] && ! grep -q 'r3mini-socks5' $ROOT/tmp/$SUB && ok "钩子清掉了候选配置里的第 2 版条目" || bad "hook 清理" "$h"
h=$(be hook /tmp/$SUB); [ "$(echo "$h" | j changed)" = false ] && ok "钩子幂等" || bad "hook 幂等" "$h"

echo "== 10. 错误路径"
kill -0 $(cat $BASE/main.pid) 2>/dev/null && echo "  （「OpenClash」进程在，19090 监听者 pid=$(owner_pid 19090)）" || echo "  （「OpenClash」进程已退出）"
o=$(be use NOPE); [ "$(echo "$o" | j error)" = TARGET_MISSING ] && ok "use 不存在 → TARGET_MISSING" || bad "use NOPE" "$o"
o=$(be use "$(b64 "$NODE")" "$(b64 nope.yaml)"); [ "$(echo "$o" | j error)" = SUBSCRIPTION_MISSING ] && ok "不存在的订阅 → SUBSCRIPTION_MISSING" || bad "bad sub" "$o"
o=$(be targets "$(b64 ../../etc/passwd)"); [ "$(echo "$o" | j error)" = SUBSCRIPTION_MISSING ] && ok "订阅名带路径 → 拒绝" || bad "sub path" "$o"
o=$(be save "$(b64 '{"port":9090}')"); [ "$(echo "$o" | j error)" = PORT_RESERVED ] && ok "端口 9090 → PORT_RESERVED" || bad "9090" "$o"
o=$(be save "$(b64 '{"port":27907}')"); [ "$(echo "$o" | j error)" = PORT_RESERVED ] && ok "内部端口 27907 → PORT_RESERVED" || bad "27907" "$o"
o=$(be save "$(b64 '{"port":19090}')"); [ "$(echo "$o" | j error)" = PORT_IN_USE ] && ok "被「OpenClash」占着的 19090 → PORT_IN_USE" || bad "19090" "$o"
o=$(be save yes); [ "$(echo "$o" | j error)" = ARGUMENT_INVALID ] && ok "save yes → ARGUMENT_INVALID" || bad "save yes" "$o"
o=$(be check-port 27906); [ "$(echo "$o" | j reserved)" = true ] && ok "check-port 27906 reserved" || bad "check-port" "$o"
o=$(be check-port 27896); [ "$(echo "$o" | j own)" = true ] && ok "check-port 27896 own" || bad "check-port own" "$o"

echo "== 11. 关仅 IPv4、停用、启用、reset"
p0=$(corepid); out=$(be ipv4 off); [ "$(echo "$out" | j mode)" = r3mini-socks5-exit ] && [ "$(corepid)" = "$p0" ] && ok "ipv4 off：mode=exit，没重启内核" || bad "ipv4 off" "$out"
out=$(be disable); [ "$(echo "$out" | j enabled)" = false ] && [ "$(echo "$out" | j error)" = nil ] && [ ! -f $ROOT/tmp/r3mini-socks5/core/config.yaml ] && ok "disable：内核停了、配置删了" || bad "disable" "$out"
sleep 1; [ -z "$(owner_pid 27896)" ] && ok "27896 已释放" || bad "27896 还在监听"
out=$(be enable); [ "$(echo "$out" | j applied)" = true ] && ok "enable：恢复 applied" || bad "enable" "$out"
rss=$(awk '/^VmRSS/{print $2}' /proc/$(corepid)/status 2>/dev/null); echo "  SOCKS5 内核内存 ${rss:-?} kB（$total 个节点）"
out=$(be reset); [ "$(echo "$out" | j ok)" = true ] && [ ! -f $ROOT/etc/r3mini-socks5/settings.json ] && ok "reset：设置删除" || bad "reset" "$out"
sleep 1; [ -z "$(owner_pid 27896)" ] && ok "reset 后 27896 已释放" || bad "reset 后还在监听"

echo "== 结果：通过 $PASS，失败 $FAIL"
[ -s $BASE/stderr.log ] && { echo "-- 后端 stderr（末 10 行）"; tail -n 10 $BASE/stderr.log; }
[ -s $BASE/main.log ] && { echo "-- 「OpenClash」日志（末 5 行）"; grep -v -i "password" $BASE/main.log | tail -n 5 | cut -c1-200; }
[ -s $BASE/small.log ] && { echo "-- SOCKS5 内核日志（末 6 行）"; grep -v -i 'password' $BASE/small.log | tail -n 6 | cut -c1-200; }
[ $FAIL -eq 0 ]
