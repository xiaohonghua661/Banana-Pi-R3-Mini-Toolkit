#!/bin/sh
# 在路由器上跑 r3mini-mesl-relay 的沙箱测试：只写 /tmp/mesl-relay-t，不碰运行配置、覆写脚本、/etc/r3mini-mesl-relay。
# 会真的查节点商 DoH、直连测中转端口（gid 65534），读旧副本 $SNAP、订阅原文件和当前运行配置。
# 电脑上（Git Bash，仓库根目录）：
#   R 'mkdir -p /tmp/mesl-relay-t && cat > /tmp/mesl-relay-t/r3mini-mesl-relay && chmod 755 /tmp/mesl-relay-t/r3mini-mesl-relay' < mesl-relay/router/usr/sbin/r3mini-mesl-relay
#   R 'SNAP=/etc/openclash/config/<带中转入口的旧副本>.yaml sh -s' < mesl-relay/test_router.sh
# 最后一行 TEST_SUMMARY pass=<n> fail=<n>；fail=0 才算过。KEEP=1 时保留沙箱。
set -u
T=/tmp/mesl-relay-t
G=$T/r3mini-mesl-relay
[ -x "$G" ] || { echo "缺 $G，先把脚本传上来"; exit 2; }
export R3MR_STATE=$T/state
rm -rf "$T/state" "$T"/*.yaml "$T"/out*
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
mode() { ruby -e 'printf("%o", File.stat(ARGV[0]).mode & 07777)' "$1"; }
ng() { fail=$((fail + 1)); echo "FAIL $1"; }
RT=/etc/openclash/$(basename "$(uci -q get openclash.config.config_path)")
# 测试从订阅原文件起步（运行配置可能已经被正式 hook 换过入口）
BASE=$(uci -q get openclash.config.config_path)
SNAP=${SNAP:-}
[ -f "$SNAP" ] || { echo "先用 SNAP=<带中转入口的旧副本> 指定旧订阅副本"; exit 2; }
CORE=/etc/openclash/core/clash_meta
h0=$(sha256sum "$RT" | cut -c1-16)

echo "== T1 没对照表、help"
"$G" help | grep -q 'build-map' && ok help || ng help
cp "$BASE" "$T/cfg.yaml"
"$G" hook "$T/cfg.yaml" > "$T/out1"; grep -q 'skip reason=no_map' "$T/out1" && cmp -s "$T/cfg.yaml" "$BASE" && ok no-map-untouched || { ng no-map-untouched; cat "$T/out1"; }

echo "== T2 建对照表（不含密码）"
"$G" build-map "$SNAP" > "$T/out2"; cat "$T/out2"
grep -q '^MAP_OK nodes=' "$T/out2" && ok build-map || ng build-map
grep -q 'password' "$T/state/map.yaml" && ng map-no-password || ok map-no-password
[ "$(mode "$T/state/map.yaml")" = 600 ] && ok map-mode-600 || ng map-mode-600
"$G" build-map "$T/nonexistent.yaml" > /dev/null 2>&1 && ng build-map-missing || ok build-map-missing

echo "== T3 hook 换入口，只换 server/port/sni，密码等不动"
"$G" hook "$T/cfg.yaml" > "$T/out3"; cat "$T/out3"
grep -q '^MESL_RELAY applied=[1-9]' "$T/out3" && ok hook-applied || ng hook-applied
ruby -ryaml -E UTF-8 - "$BASE" "$T/cfg.yaml" "$T/state/map.yaml" <<'RB' && ok fields-only || ng fields-only
a = YAML.load_file(ARGV[0], aliases: true); b = YAML.load_file(ARGV[1], aliases: true); m = YAML.load_file(ARGV[2])
bad = 0
an = a['proxies'].to_h { |p| [p['name'], p] }
b['proxies'].each do |p|
  o = an[p['name']] or (bad += 1; next)
  diff = (o.keys | p.keys).reject { |k| o[k] == p[k] }
  if m[p['name']]
    bad += 1 unless (diff - %w[server port sni]).empty? && p['server'] == m[p['name']]['server'] && p['port'] == m[p['name']]['port']
  else
    bad += 1 unless diff.empty?
  end
end
other = (a.keys | b.keys) - ['proxies']
bad += 1 unless other.all? { |k| a[k] == b[k] }
servers = m.values.map { |v| v['server'] }.uniq
puts "  bad=#{bad} relay_nodes=#{b['proxies'].count { |p| servers.include?(p['server'].to_s) }}/#{b['proxies'].size}"
exit(bad.zero? ? 0 : 1)
RB
m1=$(mode "$T/cfg.yaml"); m2=$(mode "$BASE"); [ -n "$m1" ] && [ "$m1" = "$m2" ] && ok "mode-kept ($m1)" || ng "mode-kept ($m1 vs $m2)"
SAFE_PATHS=/usr/share/openclash:/etc/ssl "$CORE" -t -d /etc/openclash -f "$T/cfg.yaml" > "$T/out3t" 2>&1 && ok core-config-test || { ng core-config-test; tail -3 "$T/out3t"; }
"$G" hook "$T/cfg.yaml" > "$T/out3b"; grep -q 'skip reason=unchanged' "$T/out3b" && ok second-run-unchanged || { ng second-run-unchanged; cat "$T/out3b"; }
"$G" status "$T/cfg.yaml" > "$T/out3s"; grep -q 'mesl=yes relay_nodes=[1-9]' "$T/out3s" && grep -q '^switch=on' "$T/out3s" && ok status || { ng status; cat "$T/out3s"; }

echo "== T4 非 MESL 订阅不动"
for f in /etc/openclash/config/*.yaml; do
  ruby -ryaml -e 'c = YAML.load_file(ARGV[0], aliases: true); exit(Array(c["proxy-groups"]).any? { |g| g.is_a?(Hash) && g["name"] == "MESL" } ? 1 : 0)' "$f" 2>/dev/null || continue
  cp "$f" "$T/other.yaml"
  "$G" hook "$T/other.yaml" > "$T/out4"
  grep -q 'skip reason=not_mesl' "$T/out4" && cmp -s "$T/other.yaml" "$f" && ok "not-mesl-${f##*/}" || { ng "not-mesl-${f##*/}"; cat "$T/out4"; }
done

echo "== T5 关掉开关不动；中转主机不通时不换"
cp "$BASE" "$T/cfg.yaml"
"$G" off > /dev/null; "$G" hook "$T/cfg.yaml" > "$T/out5"
grep -q 'skip reason=disabled' "$T/out5" && cmp -s "$T/cfg.yaml" "$BASE" && ok disabled || ng disabled
"$G" on > /dev/null
cp "$T/state/map.yaml" "$T/map.good"
ruby -ryaml -e 'm = YAML.load_file(ARGV[0]); m.each_value { |v| v["port"] = 9 }; File.write(ARGV[0], YAML.dump(m))' "$T/state/map.yaml"
"$G" hook "$T/cfg.yaml" > "$T/out5b"; cat "$T/out5b"
grep -q 'skip reason=all_hosts_down' "$T/out5b" && cmp -s "$T/cfg.yaml" "$BASE" && ok hosts-down-untouched || ng hosts-down-untouched
cp "$T/map.good" "$T/state/map.yaml"

echo "== T6 没有节点商 DoH 时不换"
ruby -ryaml -E UTF-8 -e 'c = YAML.load_file(ARGV[0], aliases: true); c["dns"]["proxy-server-nameserver"] = ["223.5.5.5"]; c["dns"]["nameserver"] = ["https://1.1.1.1/dns-query#MESL"]; File.write(ARGV[1], YAML.dump(c))' "$BASE" "$T/nodoh.yaml"
cp "$T/nodoh.yaml" "$T/nodoh.orig"
"$G" hook "$T/nodoh.yaml" > "$T/out6"; grep -q 'skip reason=no_doh' "$T/out6" && cmp -s "$T/nodoh.yaml" "$T/nodoh.orig" && ok no-doh-untouched || { ng no-doh-untouched; cat "$T/out6"; }

[ "$(sha256sum "$RT" | cut -c1-16)" = "$h0" ] && ok runtime-config-untouched || ng runtime-config-untouched
[ "${KEEP:-0}" = 1 ] || rm -rf /tmp/mesl-relay-t
echo "TEST_SUMMARY pass=$pass fail=$fail"
[ $fail -eq 0 ]
