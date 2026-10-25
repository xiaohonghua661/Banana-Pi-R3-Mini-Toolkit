#!/bin/sh
# 路由器兜底脚本的实机测试：全部在 /tmp 下用假 r3mini-chatgpt 跑，不碰真实规则与标记。
# 先把 router/usr/sbin/r3mini-gpt-night-failsafe 上传为 /tmp/r3gn-test/failsafe，再把本文件经 SSH 交给 sh -s 运行。
D=/tmp/r3gn-test
FS=$D/failsafe
export R3GN_MARKER=$D/marker.json R3GN_CLI=$D/cli R3GN_LOG=$D/log/night.log
mkdir -p $D/log
cat > $R3GN_CLI <<'CLI'
#!/bin/sh
# 假模块：status 输出 $D/rule 描述的规则；set-enabled 记录调用并把规则改成停用
D=/tmp/r3gn-test
read src sel on < $D/rule
case "$1" in
	status) printf '{"ok":true,"site_rules":[{"id":"aaaaaaaaaaaa","source":"x.yaml","selected":"1111111111111111","enabled":true},{"id":"6c30a15270ea","source":"%s","selected":"%s","enabled":%s}]}\n' "$src" "$sel" "$on" ;;
	set-enabled) echo "$*" >> $D/calls; echo "$src $sel false" > $D/rule; echo '{"ok":true}' ;;
	*) echo "$*" >> $D/calls; echo '{"ok":false}' ;;
esac
CLI
chmod 755 $R3GN_CLI
marker() { printf '{"mode":"%s","rule":"%s","night":{"source":"peiqian_lv.yaml","selected":"ec534e9910c8f868"},"before":{"source":"MESL_yue.yaml","selected":"bd7cdc171723bbdd"}}\n' "$1" "${2:-6c30a15270ea}" > $R3GN_MARKER; }
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
reset() { rm -f $D/calls $R3GN_LOG $R3GN_MARKER; echo "$1" > $D/rule; }

reset "peiqian_lv.yaml ec534e9910c8f868 true"
sh $FS; check "no marker: no call" "$(cat $D/calls 2>/dev/null)" ""

reset "peiqian_lv.yaml ec534e9910c8f868 true"; marker night
sh $FS; check "night node live: disables" "$(cat $D/calls)" "set-enabled 6c30a15270ea 0"
check "night node live: rule now off" "$(cat $D/rule)" "peiqian_lv.yaml ec534e9910c8f868 false"
check "night node live: marker kept" "$(test -f $R3GN_MARKER && echo kept)" "kept"
check "night node live: logged" "$(grep -c 'failsafe: 08:30' $R3GN_LOG)" "1"

sh $FS; check "second run: no new call" "$(wc -l < $D/calls | tr -d ' ')" "1"

reset "MESL_yue.yaml bd7cdc171723bbdd true"; marker night
sh $FS; check "already restored: no call" "$(cat $D/calls 2>/dev/null)" ""

reset "peiqian_lv.yaml fd14ad7e7dbad6f9 true"; marker night
sh $FS; check "user picked other node: no call" "$(cat $D/calls 2>/dev/null)" ""

reset "peiqian_lv.yaml ec534e9910c8f868 true"; marker night "6c30a15270e'"
sh $FS; rc=$?; check "bad rule id: refused" "$rc $(cat $D/calls 2>/dev/null)" "1 "

reset "peiqian_lv.yaml ec534e9910c8f868 true"; marker night "6c30a15270eZ"
sh $FS; rc=$?; check "non-hex rule id: refused" "$rc $(cat $D/calls 2>/dev/null)" "1 "

sh -n $FS && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL sh -n"; }
echo "failsafe tests: pass=$pass fail=$fail"
rm -rf $D
