#!/bin/sh
# device-installer-dryrun-test.sh —— 在 R3 Mini 上用 install.sh dry-run 验收自定义规则文件改写（只读，只写 /tmp/r3ab-dry-test）
# 用设备上真实的 openclash_custom_rules.list 派生几种写法：CRLF、已有规则集 4 格缩进、rules 缩进写法、没有 rule-providers: 键、标记不成对、已装过一次。
P=${R3AB_PKG:-$(cd "$(dirname "$0")/.." && pwd)}; T=/tmp/r3ab-dry-test; I="$P/install.sh"
SRC=/etc/openclash/custom/openclash_custom_rules.list
WANT="same=true providers=r3mini-adblock-domain,r3mini-adblock-rule defs=true ours_rules=2 head=RULE-SET,r3mini-adblock-rule,REJECT,RULE-SET,r3mini-adblock-domain,REJECT"
pass=0; fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
ng() { echo "FAIL $*"; fail=$((fail + 1)); }
rm -rf "$T"; mkdir -p "$T"
# 先剥掉设备文件里已有的受管段得到干净底稿，再补一段旧 hongguo-adblock 段，模拟「从旧方案升级」；与设备当前装没装无关
awk '$0 == "# >>> r3mini-adblock (managed) >>>" || $0 == "# >>> hongguo-adblock (managed) >>>" { s = 1; next }
	$0 == "# <<< r3mini-adblock (managed) <<<" || $0 == "# <<< hongguo-adblock (managed) <<<" { s = 0; next } !s' "$SRC" > "$T/clean.list"
awk '{ print } /^rules:/ && !d { print "# >>> hongguo-adblock (managed) >>>"; print "- DOMAIN,dig.bdurl.net,REJECT"; print "# <<< hongguo-adblock (managed) <<<"; d = 1 }' "$T/clean.list" > "$T/real.list"
sed 's/$/\r/' "$T/real.list" > "$T/crlf.list"
awk '{ print } /^rule-providers:/ { print "    myset:"; print "        type: http"; print "        behavior: domain"; print "        url: https://example.com/a.txt"; print "        path: ./rule_provider/myset.txt" }' "$T/real.list" > "$T/indent4.list"
sed 's/^- /  - /' "$T/real.list" > "$T/rulesindent.list"
grep -v '^# <<< hongguo-adblock' "$T/real.list" > "$T/nomarkerend.list"
sed "/^rule-providers:/d" "$T/real.list" > "$T/nopv.list"

run() { sh "$I" dry-run "$1" "$T/$2.installed" > "$T/$2.out" 2>&1; }
line() { sed -n "s/^== $2: awk_rc=\([0-9]*\) /rc=\1 /p" "$T/$1.out"; }

for v in real crlf indent4 rulesindent nopv; do
	run "$T/$v.list" "$v"
	[ "$(line "$v" install)" = "rc=0 $WANT" ] && ok "$v：install 改写正确" || { ng "$v：install -> $(line "$v" install)"; }
	case "$(line "$v" uninstall)" in "rc=0 same=true providers= defs=false ours_rules=0 "*) ok "$v：uninstall 改写正确" ;; *) ng "$v：uninstall -> $(line "$v" uninstall)" ;; esac
done
grep -q '^    r3mini-adblock-rule:$' "$T/indent4.installed" && grep -q '^      type: file$' "$T/indent4.installed" && ok "indent4：插入跟随 4 格缩进" || ng "indent4：缩进没跟随"
grep -q '^  - RULE-SET,r3mini-adblock-rule,REJECT$' "$T/rulesindent.installed" && ok "rulesindent：规则跟随 2 格缩进" || ng "rulesindent：缩进没跟随"
grep -q 'hongguo-adblock' "$T/real.installed" && ng "real：旧段没删" || ok "real：旧 hongguo 段已删"
grep -q "^rule-providers:$" "$T/nopv.installed" && [ "$(grep -n "^rule-providers:$" "$T/nopv.installed" | cut -d: -f1)" -lt "$(grep -n "^rules:" "$T/nopv.installed" | cut -d: -f1)" ] && ok "nopv：补上 rule-providers: 且在 rules: 前" || ng "nopv：没补 rule-providers:"
CR=$(printf '\015')
[ "$(grep -c "$CR\$" "$T/crlf.installed")" -gt 50 ] && [ "$(grep -c "$CR\$" "$T/real.installed")" -eq 0 ] && ok "crlf：原有行保留 CRLF" || ng "crlf：换行被改"

run "$T/nomarkerend.list" nomarkerend
grep -q MARKERS_BAD "$T/nomarkerend.out" && ok "结束标记缺失：拒绝改写" || ng "结束标记缺失：$(head -2 "$T/nomarkerend.out")"

# 已装过一次的文件再预演：install 幂等、uninstall 能还原到不含任何受管段
sh "$I" dry-run "$T/real.list" "$T/installed.list" > /dev/null 2>&1
run "$T/installed.list" installed
[ "$(line installed install)" = "rc=0 $WANT" ] && ok "已装过：再 install 结果不变" || ng "已装过：install -> $(line installed install)"
sh "$I" dry-run "$T/installed.list" "$T/installed2.list" > /dev/null 2>&1
cmp -s "$T/installed.list" "$T/installed2.list" && ok "已装过：再 install 逐字节相同（幂等）" || ng "已装过：再 install 文件有变化"
case "$(line installed uninstall)" in "rc=0 same=true providers= defs=false ours_rules=0 "*) ok "已装过：uninstall 改写正确" ;; *) ng "已装过：uninstall -> $(line installed uninstall)" ;; esac
echo
echo "RESULT pass=$pass fail=$fail"
