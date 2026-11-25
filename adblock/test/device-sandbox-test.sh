#!/bin/sh
# device-sandbox-test.sh —— 在 R3 Mini 上沙箱验收 r3mini-adblock
# 只写 /tmp/r3ab-test；另起一个只监听 127.0.0.1:19090（API）/ 127.0.0.1:17893（代理）的 mihomo 实例做热加载与拦截测试，
# 不碰 /etc、不碰正在运行的 OpenClash。用法：把 adblock/ 目录传到路由器任意位置（如 /tmp/r3ab-pkg）后 sh <该目录>/test/device-sandbox-test.sh
P=${R3AB_PKG:-$(cd "$(dirname "$0")/.." && pwd)}; T=/tmp/r3ab-test; S=$P/router/usr/sbin/r3mini-adblock
AW=$P/test/fixture-subscription.yaml
REAL_URL=https://raw.githubusercontent.com/TG-Twilight/AWAvenue-Ads-Rule/main/Filters/AWAvenue-Ads-Rule-Clash-Only.Ads.yaml
MP=
cleanup() { [ -n "$MP" ] && kill "$MP" 2>/dev/null; }
trap cleanup EXIT INT TERM
pass=0; fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
ng() { echo "FAIL $*"; fail=$((fail + 1)); }
expect() { name=$1; want=$2; got=$3; if [ "$got" = "$want" ]; then ok "$name"; else ng "$name: 期望 [$want] 实际 [$got]"; fi; }
jget() { jsonfilter -s "$1" -e "@.$2"; }
lines() { grep -c . "$1"; }

for port in 19090 17893; do netstat -ltn 2>/dev/null | grep -q ":$port " && { echo "ABORT 端口 $port 已被占用"; exit 1; }; done
rm -rf "$T"; mkdir -p "$T/config" "$T/data" "$T/home/rule_provider" "$T/run" "$T/src"
cp "$P/router/etc/config/r3mini_adblock" "$T/config/"
cp "$P/router/etc/r3mini-adblock/core.rules" "$P/router/etc/r3mini-adblock/domains.list" "$T/data/"
echo '0 0 * * 1 /usr/share/openclash/openclash_geo.sh ipdb #openclash-cron-task' > "$T/crontab"
export R3AB_UCI_DIR=$T/config R3AB_DATA=$T/data R3AB_PROV=$T/home/rule_provider R3AB_CRON=$T/crontab \
	R3AB_RUN=$T/run R3AB_SELF=$S R3AB_API=http://127.0.0.1:19090 R3AB_SECRET=t3st
D=$T/home/rule_provider/r3mini-adblock-domain.txt; R=$T/home/rule_provider/r3mini-adblock-rule.txt
setsrc() { uci -q -c "$T/config" delete r3mini_adblock.main.source; uci -q -c "$T/config" add_list r3mini_adblock.main.source="$1"; uci -q -c "$T/config" commit r3mini_adblock; }

echo "######## 1 normalize：各种格式"
printf '\357\273\277# 注释\npayload:\n  - '"'"'+.Pangle.CN'"'"'\n  - '"'"'ads3-normal-hl.zijieapi.com'"'"'\n  - "quoted.example.com"\n  - plain.example.com # 行尾注释\nDOMAIN-SUFFIX,suffix.example.com,REJECT\nDOMAIN,exact.example.com\nDOMAIN-KEYWORD,ad\nDOMAIN-REGEX,^x$\nIP-CIDR,1.2.3.0/24\naddress=/dns.example.com/0.0.0.0\naddress=/redirect.example.com/192.168.1.1\nserver=/fwd.example.com/114.114.114.114\nserver=/local.example.com/\naddress=/a1.example.com/a2.example.com/#\n||adg.example.com^\n||adg2.example.com^$third-party\n@@||allow.example.com^\n0.0.0.0 hosts1.example.com hosts2.example.com\n127.0.0.1 localhost\n1.2.3.4\ncom.cn\n-bad.example.com\nbad-.example.com\nunder_score.example.com\n*.wild.example.com\n.dot.example.com\ncrlf.example.com\r\n%s.example.com\n' \
	"$(printf '%0250d' 0 | tr 0 a)" > "$T/src/formats.txt"
"$S" normalize < "$T/src/formats.txt" | LC_ALL=C sort > "$T/norm.out"
printf '%s\n' +.a1.example.com +.a2.example.com +.adg.example.com +.dns.example.com +.dot.example.com +.local.example.com +.pangle.cn \
	+.suffix.example.com +.wild.example.com ads3-normal-hl.zijieapi.com crlf.example.com exact.example.com hosts1.example.com \
	hosts2.example.com plain.example.com quoted.example.com under_score.example.com | LC_ALL=C sort > "$T/norm.want"
if cmp -s "$T/norm.out" "$T/norm.want"; then ok "normalize 17 条全对"; else ng "normalize"; diff "$T/norm.want" "$T/norm.out"; fi

echo "######## 2 prune：白名单与去重"
printf '%s\n' +.example.com a.example.com +.b.example.com snssdk.com +.snssdk.com +.ads.snssdk.com open.snssdk.com \
	x.open.snssdk.com +.example.com | "$S" prune 'aweme.snssdk.com snssdk.com +.open.snssdk.com' > "$T/prune.out"
expect "prune" "+.ads.snssdk.com +.example.com x.open.snssdk.com" "$(tr '\n' ' ' < "$T/prune.out" | sed 's/ $//')"

echo "######## 3 build + 起沙箱 mihomo"
"$S" build
expect "rule 规则集 16 条" 16 "$(lines "$R")"
BUILTIN=$(lines "$D"); echo "domain 规则集（仅内置）$BUILTIN 条"
grep -qx 'v11-reading-video.qznovelvod.com\|+.qznovelvod.com' "$D" && ng "白名单域名进了规则集" || ok "白名单生效（qznovelvod.com 不整域拦）"
cat > "$T/home/config.yaml" <<'EOF'
mode: rule
log-level: info
allow-lan: false
bind-address: 127.0.0.1
mixed-port: 17893
external-controller: 127.0.0.1:19090
secret: t3st
find-process-mode: off
rule-providers:
  r3mini-adblock-rule: {type: file, behavior: classical, format: text, path: ./rule_provider/r3mini-adblock-rule.txt}
  r3mini-adblock-domain: {type: file, behavior: domain, format: text, path: ./rule_provider/r3mini-adblock-domain.txt}
rules:
  - RULE-SET,r3mini-adblock-rule,REJECT
  - RULE-SET,r3mini-adblock-domain,REJECT
  - MATCH,DIRECT
EOF
ln -sf /etc/openclash/clash "$T/r3abmh"
"$T/r3abmh" -d "$T/home" -f "$T/home/config.yaml" >> "$T/mh.log" 2>&1 &
MP=$!
i=0; until curl -s -m 1 -H 'Authorization: Bearer t3st' http://127.0.0.1:19090/version | grep -q version; do
	i=$((i + 1)); [ "$i" -ge 20 ] && { ng "沙箱 mihomo 没起来"; tail -5 "$T/mh.log"; exit 1; }; sleep 1
done
ok "沙箱 mihomo 已启动"

probe() { # 域名 → REJECT / PASS（看 mihomo 日志里这条连接的去向）
	: > "$T/mh.log"
	curl -s -o /dev/null -m 6 -x http://127.0.0.1:17893 "https://$1/" 2>/dev/null
	sleep 1
	if grep -q "$1:443.*using REJECT" "$T/mh.log"; then echo REJECT; elif grep -q "$1:443" "$T/mh.log"; then echo PASS; else echo NOLOG; fi
}

echo "######## 4 status / 热加载 / 拦截"
J=$("$S" status); echo "$J" > "$T/status1.json"
expect "loaded" yes "$(jget "$J" loaded)"
expect "运行中 domain 条数=文件" "$BUILTIN" "$(jget "$J" runtime_domain)"
expect "运行中 rule 条数" 16 "$(jget "$J" runtime_rule)"
expect "红果广告接口（正则）" REJECT "$(probe ads3-normal-hl.zijieapi.com)"
expect "红果广告视频 CDN（正则）" REJECT "$(probe v3-reading-ad.qznovelvod.com)"
expect "内置域名清单" REJECT "$(probe activity-ag.awemeughun.com)"
expect "红果正片不拦" PASS "$(probe v11-reading-video.qznovelvod.com)"
expect "抖音 API 不拦" PASS "$(probe aweme.snssdk.com)"
expect "百度不拦" PASS "$(probe www.baidu.com)"

echo "######## 5 update（本地订阅文件）"
cp "$AW" "$T/src/aw.yaml"; setsrc "file://$T/src/aw.yaml"
OUT=$("$S" update); rc=$?
expect "update 退出码" 0 "$rc"; echo "  $OUT"
J=$("$S" status); echo "$J" > "$T/status2.json"
SUBN=$(jget "$J" "sources[0].count"); echo "  订阅规范后 $SUBN 条，规则集 $(lines "$D") 条"
expect "热加载后运行中条数=文件" "$(lines "$D")" "$(jget "$J" runtime_domain)"
expect "订阅域名被拦" REJECT "$(probe www.adsmoloco.com)"
grep -qx 'open.snssdk.com' "$D" && ng "白名单 open.snssdk.com 进了规则集" || ok "订阅里的 open.snssdk.com 被白名单剔除"
expect "再更新一次：没变化" unchanged "$("$S" update > /dev/null; "$S" status | jsonfilter -e '@.last_result')"

echo "######## 6 开关"
J=$("$S" disable); expect "关闭：enabled" false "$(jget "$J" enabled)"
expect "关闭：运行中只剩占位" "1 1" "$(jget "$J" runtime_domain) $(jget "$J" runtime_rule)"
expect "关闭后广告接口放行" PASS "$(probe ads3-normal-hl.zijieapi.com)"
J=$("$S" enable); expect "打开：恢复条数" "$(lines "$D") 16" "$(jget "$J" runtime_domain) $(jget "$J" runtime_rule)"
expect "打开后又拦" REJECT "$(probe ads3-normal-hl.zijieapi.com)"
J=$("$S" sub off); expect "关订阅：只剩内置" "$BUILTIN" "$(jget "$J" runtime_domain)"
expect "关订阅后订阅域名放行" PASS "$(probe www.adsmoloco.com)"
J=$("$S" sub on); expect "开订阅" "$SUBN" "$(jget "$J" sources[0].count)"
expect "开订阅后订阅域名又拦" REJECT "$(probe www.adsmoloco.com)"

echo "######## 7 定时任务"
"$S" auto on 5 > /dev/null
expect "定时任务行" "30 5 * * * $S update >/dev/null 2>&1 #r3mini-adblock" "$(grep r3mini-adblock "$T/crontab")"
grep -q openclash-cron-task "$T/crontab" && ok "OpenClash 原有定时任务保留" || ng "OpenClash 定时任务丢了"
"$S" auto on 5 > /dev/null; expect "重复设置不重复写" 1 "$(grep -c r3mini-adblock "$T/crontab")"
J=$("$S" auto off); expect "关自动更新" false "$(jget "$J" auto_update)"
expect "定时任务行已删" 0 "$(grep -c r3mini-adblock "$T/crontab")"
grep -q openclash-cron-task "$T/crontab" && ok "OpenClash 定时任务仍在" || ng "OpenClash 定时任务丢了"
"$S" auto bogus > /dev/null 2>&1; expect "非法参数退出码" 1 "$?"
"$S" auto on 24 > /dev/null 2>&1; expect "非法小时退出码" 1 "$?"

echo "######## 8 订阅出错时沿用旧规则"
BEFORE=$(lines "$D")
rm -f "$T/src/aw.yaml"; "$S" update > /dev/null; expect "下载失败退出码" 3 "$?"
expect "下载失败条数不变" "$BEFORE" "$(lines "$D")"
J=$("$S" status); expect "失败写进状态" failed "$(jget "$J" last_result)"; echo "  $(jget "$J" last_message)"
printf 'a.example.com\nb.example.com\n' > "$T/src/aw.yaml"; "$S" update > /dev/null; expect "只剩 2 条：拒收" 3 "$?"
head -120 "$AW" > "$T/src/aw.yaml"; "$S" update > /dev/null; expect "骤降过半：拒收" 3 "$?"
expect "拒收后条数不变" "$BEFORE" "$(lines "$D")"
cp "$AW" "$T/src/aw.yaml"; "$S" update > /dev/null; expect "恢复后更新成功" 0 "$?"

echo "######## 9 并发与后台更新"
( flock -n 9 && sleep 4 ) 9> "$T/run/update.lock" & LP=$!
sleep 1
"$S" update > /dev/null; expect "已有更新在跑：退出码" 4 "$?"
wait "$LP"
sh -c 'sleep 4; :' r3mini-adblock & FP=$!
echo "$FP" > "$T/run/update.pid"
expect "status 按 pid 显示 updating" true "$("$S" status | jsonfilter -e '@.updating')"
kill "$FP" 2>/dev/null; wait "$FP" 2>/dev/null
expect "进程没了就不算 updating" false "$("$S" status | jsonfilter -e '@.updating')"
( flock 7 && sleep 3 ) 7> "$T/run/apply.lock" & LP=$!
sleep 1; t0=$(date +%s)
J=$("$S" disable); t1=$(date +%s)
[ $((t1 - t0)) -ge 1 ] && ok "开关在 apply 锁上排队（等了 $((t1 - t0)) 秒）" || ng "开关没等 apply 锁"
expect "排队后照样关上" "false 1" "$(jget "$J" enabled) $(jget "$J" runtime_domain)"
wait "$LP"; "$S" enable > /dev/null
T0=$(jget "$("$S" status)" last_time); sleep 1
J=$("$S" update-bg); echo "$J" > "$T/status3.json"; sleep 3
[ "$(jget "$("$S" status)" last_time)" != "$T0" ] && ok "update-bg 后台跑完" || ng "update-bg 没跑"
[ -f "$T/run/update.pid" ] && ng "update 结束后 pid 文件没删" || ok "update 结束后 pid 文件已删"

echo "######## 9b 订阅暴涨拒收 / 统计 / 没装好"
awk 'BEGIN { for (i = 0; i < 3000; i++) printf "x%d.example.com\n", i }' > "$T/src/aw.yaml"
"$S" update > /dev/null; expect "暴涨三倍以上：拒收" 3 "$?"
J=$("$S" status); case "$(jget "$J" last_message)" in *暴涨*) ok "拒收原因写明暴涨" ;; *) ng "拒收原因：$(jget "$J" last_message)" ;; esac
cp "$AW" "$T/src/aw.yaml"; rm -f "$D"
OUT=$("$S" update); case "$OUT" in 新增*) ok "规则集文件不在时统计按新增算：$OUT" ;; *) ng "统计：$OUT" ;; esac
mkdir -p "$T/empty"
R3AB_UCI_DIR=$T/empty "$S" enable > /dev/null 2> "$T/err.txt"; expect "没有配置：开关退出码" 1 "$?"; echo "  $(cat "$T/err.txt")"
R3AB_UCI_DIR=$T/empty "$S" update > /dev/null 2>&1; expect "没有配置：update 退出码" 1 "$?"
grep -q r3mini-adblock "$T/crontab" && ng "没有配置时 update 写回了定时任务" || ok "没有配置时不碰定时任务"

echo "######## 9c 订阅自己的下载站永远不拦"
setsrc "$REAL_URL"; K=$(printf '%s' "$REAL_URL" | md5sum | cut -c1-12)
printf '%s\n' +.raw.githubusercontent.com +.githubusercontent.com +.cdn.jsdelivr.net +.jsdelivr.net +.evil-ads.example.com > "$T/data/cache/$K.list"
"$S" apply 2> /dev/null
grep -q 'githubusercontent\|jsdelivr' "$D" && ng "下载站进了规则集：$(grep 'githubusercontent\|jsdelivr' "$D" | tr '\n' ' ')" || ok "下载站没进规则集"
grep -qx '+.evil-ads.example.com' "$D" && ok "同一份订阅里的其它域名照常生效" || ng "订阅其它域名丢了"
setsrc "file://$T/src/aw.yaml"; "$S" update > /dev/null

echo "######## 10 OpenClash 不可达"
R3AB_API=http://127.0.0.1:1 "$S" apply 2> "$T/err.txt"; expect "API 不通：退出码" 2 "$?"; echo "  $(cat "$T/err.txt")"

echo "######## 11 真实订阅地址（经 OpenClash 下载）"
setsrc "$REAL_URL"
OUT=$("$S" update); rc=$?; expect "真实地址 update" 0 "$rc"; echo "  $OUT"
J=$("$S" status); echo "$J" > "$T/status4.json"
echo "  订阅 $(jget "$J" 'sources[0].count') 条，运行中 domain $(jget "$J" runtime_domain) 条"

echo
echo "RESULT pass=$pass fail=$fail"
