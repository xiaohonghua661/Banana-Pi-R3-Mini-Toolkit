# 安装：把本文件整段插到 /etc/openclash/custom/openclash_custom_overwrite.sh 最后的 `exit 0` 之前，
# 再 `rm -f /tmp/openclash.change && /etc/init.d/openclash restart` 让 OpenClash 重新生成运行配置。
# 回滚：删掉 BEGIN 到 END 整段，同样重启。测试见同目录 test_router.sh。
# BEGIN R3MINI-MUSE
# Muse 分流：新建名为 Muse 的手动选择组，默认选主代理组；muse.ai 等 5 个域名走它。
# 主代理组：有 MESL 组就用 MESL；否则沿 MATCH 规则指向的 select 组往下找；再没有就取第一个有真实出口的 select 组。
# 组成员照抄「🤖 AI」组（没有就照抄主代理组）。每次生成运行配置都重建，可重复执行；失败只记日志，配置原样不动。
ruby -ryaml -E UTF-8 - "$CONFIG_FILE" <<'R3MINI_MUSE_RUBY'
path = ARGV.fetch(0)
config = YAML.load_file(path, aliases: true)
list = config.fetch('proxy-groups')
groups = list.select { |g| g.is_a?(Hash) && g['name'].is_a?(String) && !g['name'].empty? }
named = groups.to_h { |g| [g['name'], g] }
main = named['MESL']
unless main
  match = Array(config['rules']).reverse.find { |r| r.is_a?(String) && r.start_with?('MATCH,') }
  group = match && named[match.split(',')[1].to_s.strip]
  seen = {}
  while group && !seen[group['name']]
    seen[group['name']] = true
    main = group
    first = named[Array(group['proxies']).first]
    break unless group['type'] == 'select' && first && first['type'] == 'select'
    group = first
  end
end
builtin = %w[DIRECT REJECT REJECT-DROP PASS COMPATIBLE]
main ||= groups.find { |g| g['type'] == 'select' && Array(g['proxies']).any? { |p| !builtin.include?(p) } }
abort 'MUSE_NO_MAIN_GROUP' unless main
main = main['name']
template = named["\u{1F916} AI"] || named[main]
members = ([main] + Array(template['proxies'])).reject { |p| p == 'Muse' }.uniq
muse = { 'name' => 'Muse', 'type' => 'select', 'proxies' => members }
muse['use'] = template['use'].dup if template['use']
old = list.index { |g| g.is_a?(Hash) && g['name'] == 'Muse' }
if old
  list[old] = muse
else
  list.insert(list.index(template) + 1, muse)
end
owned = %w[muse.ai museai.com metaaivm.com meta.ai meta.com].map { |d| "DOMAIN-SUFFIX,#{d},Muse" }
rules = Array(config['rules']).reject { |r| owned.include?(r) }
at = 0
at += 1 while at < rules.length && rules[at].to_s.start_with?('RULE-SET,r3mini-adblock-')
rules.insert(at, *owned)
config['rules'] = rules
unless YAML.load_file(path, aliases: true) == config
  tmp = path + '.muse-new'
  mode = File.stat(path).mode & 07777
  begin
    File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, mode) { |f| f.write(YAML.dump(config)); f.flush; f.fsync }
    File.chmod(mode, tmp)
    File.rename(tmp, path)
  ensure
    File.unlink(tmp) if File.exist?(tmp)
  end
end
R3MINI_MUSE_RUBY
muse_result=$?
if [ "$muse_result" -ne 0 ]; then
  logger -t r3mini-muse "Muse group injection failed ($muse_result), config left unchanged"
  LOG_WARN "R3MINI-MUSE: failed ($muse_result), ${CONFIG_FILE##*/} left unchanged"
else
  LOG_TIP "R3MINI-MUSE: Muse group and 5 rules applied to ${CONFIG_FILE##*/}"
fi
# END R3MINI-MUSE
