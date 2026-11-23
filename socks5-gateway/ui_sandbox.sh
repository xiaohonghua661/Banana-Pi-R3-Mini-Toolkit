#!/bin/sh
# 页面改版用的沙箱（在路由器上跑）：新后端 + 设备上**真实的订阅文件** + 真实运行配置里的 DNS 设置，
# SOCKS5 内核开在 127.0.0.1:27886（内部端口平移 +10020，和集成测试错开）。配合 ui_check.py 在真实 LuCI 里看新页面。
# 不碰正式 OpenClash 和正式 SOCKS5：运行配置的副本去掉了本模块条目，控制接口指向不存在的端口。
#   sh ui_sandbox.sh up /tmp/x/r3mini-socks5.rb '🇮🇶 伊拉克'      # 打印 ROOT=...
#   sh ui_sandbox.sh down
set -u
BASE=/tmp/r3s5-ui
ROOT=$BASE/root
CORE=/etc/openclash/core/clash_meta
SB=$(for p in /usr/bin/sing-box /mnt/mmcblk0p6/r3mini-socks5/sing-box; do [ -x $p ] && echo $p && break; done)

down() {
	for f in $BASE/sc.pid $BASE/sb.pid; do [ -f $f ] && kill $(cat $f) 2>/dev/null; done
	sleep 1
	for p in $(pidof clash_meta sing-box 2>/dev/null); do
		case "$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)" in *$BASE*) kill $p 2>/dev/null;; esac
	done
	rm -rf $BASE
}

case "${1:-}" in
down) down; echo DOWN_OK; exit 0;;
up) [ $# -eq 3 ] || { echo "用法：sh ui_sandbox.sh up <后端.rb> <节点名>"; exit 2; };;
*) echo "用法：sh ui_sandbox.sh up <后端.rb> <节点名> | down"; exit 2;;
esac
down
BACKEND=$2
NODE=$3
ACTIVE=$(basename "$(uci -q get openclash.config.config_path)")
mkdir -p $ROOT/sbin $ROOT/usr/bin $ROOT/usr/libexec $ROOT/etc/openclash/config $ROOT/etc/openclash/core $ROOT/etc/init.d $ROOT/tmp $ROOT/var/lock $ROOT/etc/r3mini-socks5
chmod 700 $BASE $ROOT/etc/r3mini-socks5
ln -s /proc $ROOT/proc
ln -s /usr/bin/curl $ROOT/usr/bin/curl
ln -s "$(command -v ip)" $ROOT/sbin/ip
ln -s "$SB" $ROOT/usr/bin/sing-box
ln -s $CORE $ROOT/etc/openclash/core/clash_meta
cp "$BACKEND" $ROOT/usr/libexec/r3mini-socks5.rb
cp /etc/openclash/config/*.yaml $ROOT/etc/openclash/config/ 2>/dev/null
chmod 600 $ROOT/etc/openclash/config/*
cat > $ROOT/sbin/uci <<EOF
#!/bin/sh
[ "\$1" = "-q" ] && [ "\$2" = "get" ] || exit 1
case "\$3" in
	openclash.config.config_path) echo /etc/openclash/config/$ACTIVE;;
	openclash.config.*_port) uci -q get "\$3";;
	*) exit 1;;
esac
EOF
cat > $ROOT/etc/init.d/r3mini-socks5 <<EOF
#!/bin/sh
C=$ROOT/tmp/r3mini-socks5/core
P=$ROOT/tmp/r3mini-socks5/ipv4.json
G='Process.groups=[65534]; Process::Sys.setgid(65534); exec(*ARGV)'
alive() { [ -f "\$1" ] && kill -0 \$(cat "\$1") 2>/dev/null; }
stop() { for f in $BASE/sc.pid $BASE/sb.pid; do [ -f \$f ] && kill \$(cat \$f) 2>/dev/null; rm -f \$f; done; sleep 1; }
start() {
	[ -s \$C/config.yaml ] || return 0
	alive $BASE/sc.pid || { SAFE_PATHS=\$C ruby -e "\$G" $ROOT/etc/openclash/core/clash_meta -d \$C -f \$C/config.yaml </dev/null >>$BASE/core.log 2>&1 & echo \$! > $BASE/sc.pid; }
	[ -s \$P ] || return 0
	alive $BASE/sb.pid || { ruby -e "\$G" $ROOT/usr/bin/sing-box run -c \$P </dev/null >/dev/null 2>&1 & echo \$! > $BASE/sb.pid; }
}
case "\$1" in start) start;; stop) stop;; restart) stop; start;; esac
EOF
chmod 755 $ROOT/sbin/uci $ROOT/etc/init.d/r3mini-socks5
# 运行配置副本：只为读 DNS 设置。去掉本模块条目、控制接口改到不存在的端口，后端碰不到正式 OpenClash。
ruby -ryaml -e '
c = YAML.safe_load(File.read(ARGV[0]), aliases: true)
c["external-controller"] = "127.0.0.1:1"
c["listeners"] = Array(c["listeners"]).reject { |l| l["name"].to_s.start_with?("r3mini-socks5") }
c["proxy-groups"] = Array(c["proxy-groups"]).reject { |g| g["name"].to_s.start_with?("r3mini-socks5") }
c["proxies"] = Array(c["proxies"]).reject { |p| p["name"].to_s.start_with?("r3mini-socks5") }
c["sniffer"]["skip-src-address"] = Array(c.dig("sniffer", "skip-src-address")) - ["127.0.0.2/32"] if c["sniffer"].is_a?(Hash)
File.write(ARGV[1], YAML.dump(c))
' /etc/openclash/$ACTIVE $ROOT/etc/openclash/$ACTIVE || exit 1
chmod 600 $ROOT/etc/openclash/$ACTIVE
NODE_JSON=$(ruby -e 'require ARGV[0]; print R3MiniSocks5.json(ARGV[1])' $BACKEND "$NODE")
printf '{"version":3,"enabled":true,"port":27886,"listen":"127.0.0.1","username":"uiuser","password":"ui-pass-%s","udp":true,"ipv4_only":true,"subscription":"%s","target":%s,"last_action":null,"last_time":null}\n' "$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')" "$ACTIVE" "$NODE_JSON" > $ROOT/etc/r3mini-socks5/settings.json
chmod 600 $ROOT/etc/r3mini-socks5/settings.json
R3MINI_SOCKS5_ROOT=$ROOT R3MINI_SOCKS5_PORT_SHIFT=10020 ruby $ROOT/usr/libexec/r3mini-socks5.rb apply | ruby -ryaml -e 'x = YAML.safe_load(STDIN.read); puts "APPLY applied=#{x["applied"]} error=#{x["error"]} exit=#{x.dig("exit", "now")}"'
echo "ROOT=$ROOT"
