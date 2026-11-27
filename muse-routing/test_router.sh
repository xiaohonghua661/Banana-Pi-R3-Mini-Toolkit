#!/bin/sh
# 在路由器上测 muse-routing/hook-block.sh：只写 /tmp/muse-t，不碰覆写脚本、运行配置和订阅原文件。
# 对 /etc/openclash/config/ 下每份订阅各跑一次：Muse 组和 5 条规则都在、其他组和规则不变、跑两次结果不变、
# clash_meta -t 通过；没有任何代理组的配置要失败且文件不动。
# 电脑上（Git Bash，仓库根目录，R 是 ssh 到路由器的函数）：
#   R 'rm -rf /tmp/muse-t; mkdir -p /tmp/muse-t && cat > /tmp/muse-t/muse-block.sh' < muse-routing/hook-block.sh
#   R 'sh -s; rm -rf /tmp/muse-t' < muse-routing/test_router.sh
# 最后一行 TEST_SUMMARY pass=<n> fail=<n>；fail=0 才算过。
T=/tmp/muse-t
B=$T/muse-block.sh
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
ng() { fail=$((fail + 1)); echo "FAIL $1"; }
LOG_TIP() { echo "  LOG_TIP $*"; }
LOG_WARN() { echo "  LOG_WARN $*"; }
logger() { echo "  logger $*"; }
for src in /etc/openclash/config/*.yaml; do
  n=${src##*/}
  CONFIG_FILE=$T/$n
  cp "$src" "$CONFIG_FILE"
  . "$B"
  [ "$muse_result" -eq 0 ] && ok "$n block-ran" || { ng "$n block-ran ($muse_result)"; continue; }
  ruby -ryaml -E UTF-8 - "$src" "$CONFIG_FILE" <<'RB' && ok "$n group-and-rules" || ng "$n group-and-rules"
a = YAML.load_file(ARGV[0], aliases: true); b = YAML.load_file(ARGV[1], aliases: true)
g = b['proxy-groups'].find { |x| x['name'] == 'Muse' } or exit 1
owned = %w[muse.ai museai.com metaaivm.com meta.ai meta.com].map { |d| "DOMAIN-SUFFIX,#{d},Muse" }
rules_ok = owned.all? { |r| b['rules'].count(r) == 1 }
others_same = (b['rules'] - owned) == (a['rules'] - owned)
groups_same = b['proxy-groups'].reject { |x| x['name'] == 'Muse' } == a['proxy-groups'].reject { |x| x['name'] == 'Muse' }
puts "  Muse first=#{g['proxies'].first} members=#{g['proxies'].size} rules_ok=#{rules_ok} others_same=#{others_same} groups_same=#{groups_same}"
exit(rules_ok && others_same && groups_same && a['proxies'] == b['proxies'] ? 0 : 1)
RB
  h1=$(sha256sum "$CONFIG_FILE" | cut -d' ' -f1)
  . "$B"
  h2=$(sha256sum "$CONFIG_FILE" | cut -d' ' -f1)
  [ "$h1" = "$h2" ] && ok "$n idempotent" || ng "$n idempotent"
  SAFE_PATHS=/usr/share/openclash:/etc/ssl /etc/openclash/core/clash_meta -t -d /etc/openclash -f "$CONFIG_FILE" > "$T/core.out" 2>&1 \
    && ok "$n core-test" || { ng "$n core-test"; tail -2 "$T/core.out"; }
done
echo "-- 没有任何代理组的配置：失败只记日志，文件不动"
printf 'proxies: []\nproxy-groups: []\nrules: [MATCH,DIRECT]\n' > "$T/empty.yaml"; cp "$T/empty.yaml" "$T/empty.orig"
CONFIG_FILE=$T/empty.yaml
. "$B" 2>/dev/null
[ "$muse_result" -ne 0 ] && cmp -s "$T/empty.yaml" "$T/empty.orig" && ok no-main-group-untouched || ng no-main-group-untouched
echo "TEST_SUMMARY pass=$pass fail=$fail"
[ $fail -eq 0 ]
