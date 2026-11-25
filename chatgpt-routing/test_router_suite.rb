#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline acceptance for the site-routing backend (r3mini-chatgpt.rb) and its
# benchmark helper (r3mini-site-bench.rb). Needs only Ruby's yaml and digest, so
# the router's own packaged Ruby can run it:
#
#   ruby test_router_suite.rb WORKDIR [NAME_FILTER]
#
# WORKDIR is a fresh directory under /tmp holding both module files. Every case
# builds its own sandbox root below it (R3MINI_CHATGPT_ROOT) with a mock curl,
# mock Mihomo core and mock uci, so no production path is read or written.
# python chatgpt-routing/test_backend.py uploads and runs this file.

require 'yaml'
require 'digest/sha2'

WORK = File.realpath(ARGV[0] || '.')
FILTER = ARGV[1]
abort('REFUSED: WORKDIR must be a dedicated directory under /tmp') unless WORK.start_with?('/tmp/') && WORK.length > 5
BACKEND = WORK + '/r3mini-chatgpt.rb'
HELPER = WORK + '/r3mini-site-bench.rb'
# OpenWrt's Ruby has no rbconfig, and its /usr/bin/ruby is a wrapper script around
# /usr/lib/ruby/ruby3.3-bin that sets the load flags; production calls the wrapper.
RUBY = File.executable?('/usr/bin/ruby') ? '/usr/bin/ruby' : File.readlink('/proc/self/exe')
require BACKEND
require HELPER

def jdump(value)
  R3MiniChatGPT.json(value)
end

def jload(text)
  YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: true)
end

def mono
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def mkdir_p(dir)
  return if File.directory?(dir)
  mkdir_p(File.dirname(dir))
  Dir.mkdir(dir)
end

def rm_rf(path)
  return unless File.symlink?(path) || File.exist?(path)
  if File.directory?(path) && !File.symlink?(path)
    Dir.children(path).each { |name| rm_rf(path + '/' + name) }
    Dir.rmdir(path)
  else
    File.unlink(path)
  end
end

# Controller state is Marshal so GET mocks start without loading yaml.
MOCK_CURL = <<~'RUBY'
  #!RUBY_PATH
  # frozen_string_literal: true
  ROOT = File.expand_path('../..', __dir__)
  def enc(value)
    case value
    when Hash then '{' + value.map { |k, v| enc(k.to_s) + ':' + enc(v) }.join(',') + '}'
    when Array then '[' + value.map { |v| enc(v) }.join(',') + ']'
    when String then '"' + value.gsub(/["\\\x00-\x1f]/) { |c| c == '"' ? '\\"' : c == '\\' ? '\\\\' : format('\\u%04x', c.ord) } + '"'
    when nil then 'null'
    else value.to_s
    end
  end
  args = ARGV.dup
  opt = ->(name) { i = args.index(name); i && args[i + 1] }
  if args.include?('--proxy')
    # Helper probe through an isolated probe core.
    exit 90 unless args[0] == '-q' && args.include?('--no-keepalive') && opt.('--noproxy') == ''
    port = opt.('--proxy').split(':').last
    manifest = ROOT + '/mock-ports/' + port + '.bin'
    exit 91 unless File.exist?(manifest)
    state = Marshal.load(File.binread(manifest))
    exit 92 unless File.exist?('/proc/' + state['pid'].to_s)
    node = state['node']
    call = state['calls']
    state['calls'] += 1
    File.binwrite(manifest, Marshal.dump(state))
    url = args[-1]
    head = args.include?('--head')
    File.open(ROOT + '/probe-urls.log', 'a') { |f| f.puts((head ? 'HEAD ' : 'GET ') + url) }
    sleep(node['mock-curl-delay'].to_f) if node['mock-curl-delay']
    exit 35 if node['mock-tls-fail']
    if head
      code = node['mock-site-code'] || 200
      body = ''
    elsif url.include?('api.openai.com')
      code = node['mock-api-code'] || 401
      body = code == 403 ? '{"error":{"code":"unsupported_country_region_territory"}}' : '{"error":"invalid_api_key"}'
    else
      exit 93 unless url.include?('?r3mini=')
      code = node['mock-trace-code'] || 200
      country = node['mock-country'] || 'US'
      country = country[[call, country.length - 1].min] if country.is_a?(Array)
      body = "ip=192.0.2.8\nloc=#{country}\n"
    end
    File.write(opt.('--output'), body)
    samples = node['mock-samples'] || [0.3, 0.1, 0.2]
    print "#{code}\n#{samples[[call, 2].min]}\n"
    exit 0
  end
  statefile = ROOT + '/controller.bin'
  state = Marshal.load(File.binread(statefile))
  header = opt.('--header')[1..-1]
  exit 80 unless File.stat(header).mode & 0o777 == 0o600
  exit 81 unless File.read(header).include?("Authorization: Bearer test-controller-secret\n")
  url = args[-1]
  exit 82 unless url.start_with?('http://127.0.0.1:9090/')
  route = url.sub('http://127.0.0.1:9090', '')
  method = opt.('--request')
  max_time = opt.('--max-time').to_f
  state['calls'] << [method, route, max_time]
  save = -> { File.binwrite(statefile, Marshal.dump(state)) }
  delay = state['delay_seconds'].to_f
  delay = state['put_delay_seconds'].to_f if method == 'PUT' && state['put_delay_seconds']
  if delay > max_time
    sleep(max_time)
    save.()
    print "\n000"
    exit 28
  end
  sleep(delay) if delay > 0
  if state['offline']
    save.()
    print "\n000"
    exit 7
  end
  if method == 'PUT'
    require 'yaml'
    bodyfile = opt.('--data-binary')[1..-1]
    exit 83 unless File.stat(bodyfile).mode & 0o777 == 0o600
    path = YAML.safe_load(File.read(bodyfile))['path']
    if state.delete('reject_next_reload')
      save.()
      print "{\"message\":\"parse failed\"}\n400"
      exit 0
    end
    runtime = YAML.safe_load(File.read(path), aliases: true)
    types = {'DOMAIN-SUFFIX' => 'DomainSuffix', 'DOMAIN' => 'Domain', 'DOMAIN-KEYWORD' => 'DomainKeyword',
             'MATCH' => 'Match', 'RULE-SET' => 'RuleSet', 'IP-CIDR' => 'IPCIDR'}
    proxies = {}
    (runtime['proxies'] || []).each { |n| proxies[n['name']] = {'type' => n['type']} }
    (runtime['proxy-groups'] || []).each { |g| v = g['proxies'] || []; proxies[g['name']] = {'all' => v, 'now' => v[0]} }
    rules = (runtime['rules'] || []).map do |entry|
      parts = entry.split(',')
      {'type' => types.fetch(parts[0], parts[0]), 'payload' => parts.length > 2 ? parts[1] : '',
       'proxy' => parts.length > 2 ? parts[2] : parts[1]}
    end
    state['proxies'] = proxies
    state['rules'] = rules
    state['reloads'] = state['reloads'].to_i + 1
    state['rules'] = rules.reject { |r| r['proxy'].start_with?('R3Site-') } if state.delete('bad_next_reload')
    state['rules'] = rules.reject { |r| r['type'] == 'IPCIDR' } if state.delete('drop_steam_next_reload')
    failed = state.delete('fail_after_load')
    save.()
    print(failed ? "{\"message\":\"apply failed\"}\n500" : "\n204")
    exit 0
  end
  save.()
  object = lambda do |name, value|
    value.key?('all') ? {'name' => name, 'type' => 'Selector', 'all' => value['all'], 'now' => value['now'], 'history' => []} :
      {'name' => name, 'type' => value['type'], 'history' => [], 'alive' => true}
  end
  if route == '/rules'
    format = state['rules_format'] || 'index'
    list = state['rules'].each_with_index.map do |r, i|
      t, p, x = enc(r['type']), enc(r['payload']), enc(r['proxy'])
      case format
      when 'index' then "{\"index\":#{i},\"type\":#{t},\"payload\":#{p},\"proxy\":#{x},\"size\":-1,\"extra\":{\"disabled\":false,\"hitCount\":0}}"
      when 'plain' then "{\"type\":#{t},\"payload\":#{p},\"proxy\":#{x},\"size\":-1}"
      else "{\"proxy\":#{x},\"payload\":#{p},\"type\":#{t}}"
      end
    end
    print "{\"rules\":[#{list.join(',')}]}\n200"
  elsif route == '/proxies'
    print enc({'proxies' => state['proxies'].map { |name, value| [name, object.(name, value)] }.to_h}) + "\n200"
  elsif route.start_with?('/proxies/') && state['proxies'].key?(route.sub('/proxies/', ''))
    name = route.sub('/proxies/', '')
    print enc(object.(name, state['proxies'][name])) + "\n200"
  else
    print "{\"message\":\"Resource not found\"}\n404"
  end
RUBY

MOCK_CORE = <<~'RUBY'
  #!RUBY_PATH
  # frozen_string_literal: true
  require 'yaml'
  # Installed at ROOT/etc/openclash/core/clash_meta.
  ROOT = File.expand_path('../../..', __dir__)
  # Every refusal below is an exit code; the runner prints this log when a case fails.
  at_exit do
    status = $!.is_a?(SystemExit) ? $!.status : ($! ? $!.class : 0)
    File.write(ROOT + '/core-exit.log', "#{ARGV[0]} exit=#{status}\n", mode: 'a')
  rescue StandardError
    nil
  end
  args = ARGV.dup
  gid = File.read(ROOT + '/etc/group').split(':')[2].to_i
  proof = "{\"gid\":#{Process.gid},\"egid\":#{Process.egid}}"
  if args[0] == '-t'
    exit 48 unless ENV['SAFE_PATHS'] == '/usr/share/openclash:/etc/ssl'
    File.write(ROOT + '/core-safe-paths', ENV['SAFE_PATHS'])
    exit 49 unless Process.gid == gid && Process.egid == gid
    File.write(ROOT + '/core-gid-proof.json', proof)
    exit 50 unless args[1] == '-d' && args[2] == ROOT + '/etc/openclash' && args[3] == '-f'
    exit 51 unless File.basename(args[4]).start_with?('.r3mini-chatgpt-')
    YAML.safe_load(File.read(args[4]), aliases: true)
    File.write(ROOT + '/core-call.json', args.inspect)
    if File.exist?(ROOT + '/hang_core')
      File.write(ROOT + '/core-test-pid', Process.pid.to_s)
      sleep 30
    end
    exit(File.exist?(ROOT + '/fail_core') ? 1 : 0)
  end
  # Probe core: -d SCRATCH -f CONFIG; it must LISTEN on mixed-port as this very PID.
  exit 60 unless Process.gid == gid && Process.egid == gid
  File.write(ROOT + '/core-gid-proof.json', proof)
  exit 61 unless args[0] == '-d' && args[2] == '-f'
  scratch = args[1]
  exit 62 unless File.stat(scratch).mode & 0o777 == 0o700 && File.stat(args[3]).mode & 0o777 == 0o600
  cfg = YAML.safe_load(File.read(args[3]), aliases: true) # mihomo accepts anchors too
  exit 64 if cfg.key?('external-controller') || cfg['allow-lan'] || cfg['bind-address'] != '127.0.0.1'
  exit 65 if cfg['tun']['enable'] || cfg['geo-auto-update']
  exit 66 unless cfg['dns']['listen'] == '127.0.0.1:0' && cfg['dns']['fallback-filter']['geoip'] == false
  exit 67 unless cfg['rules'] == ['MATCH,probe-node'] && cfg['proxies'].length == 1
  bootstrap = ROOT + '/mock-bootstrap.yaml'
  expected = File.exist?(bootstrap) ? YAML.safe_load(File.read(bootstrap)) : ['1.1.1.1']
  exit 68 unless cfg['dns']['proxy-server-nameserver'] == expected
  exit 69 if cfg['dns'].key?('default-nameserver') && cfg['dns']['default-nameserver'].empty?
  plain = expected.reject { |entry| entry.start_with?('https:') }
  exit 70 unless plain.empty? ? !cfg['dns'].key?('default-nameserver') : cfg['dns']['default-nameserver'] == plain
  File.write(ROOT + '/core-dns-proof.yaml', YAML.dump(cfg['dns']))
  exit 71 unless File.symlink?(scratch + '/Country.mmdb')
  node = cfg['proxies'][0]
  port = cfg['mixed-port']
  sleep(node['mock-start-delay'] || 0.15)
  File.binwrite(ROOT + "/mock-ports/#{port}.bin", Marshal.dump({'node' => node, 'pid' => Process.pid, 'calls' => 0}))
  # exec keeps this PID, which owns the LISTEN socket; -c keeps the config path in
  # the command line, which is how the helper recognises an orphaned probe core.
  if File.executable?('/usr/sbin/uhttpd')
    exec('/usr/sbin/uhttpd', '-f', '-p', "127.0.0.1:#{port}", '-h', scratch, '-c', args[3])
  else
    exec('python3', '-c', 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(3600)',
         port.to_s, scratch, args[3])
  end
RUBY

MOCK_UCI = "#!/bin/sh\nprintf '%s\\n' /etc/openclash/config/MESL_yue.yaml\n"

class AssertionFailed < StandardError; end

class Case
  STEAM_BLOCK = R3MiniChatGPT::STEAM_RULES
  STEAM_ON = {'enabled' => true, 'applied' => true}.freeze
  STEAM_OFF = {'enabled' => false, 'applied' => false}.freeze
  PRESET_ID = R3MiniChatGPT::PRESET_ID
  PRESET_GROUP = 'R3Site-' + PRESET_ID
  SECRETS = %w[selected-secret original-private selected.invalid test-controller-secret private-55].freeze
  HELPER_SECRETS = ['secret.invalid', 'private-secret', '192.0.2.8', '"uuid"', '"server"', '"password"'].freeze

  def check(condition, message = 'check failed')
    raise AssertionFailed, message unless condition
  end

  def eq(expected, actual, message = nil)
    return if expected == actual
    raise AssertionFailed, "#{message || 'mismatch'}: expected #{expected.inspect[0, 400]} got #{actual.inspect[0, 400]}"
  end

  def setup
    @root = WORK + '/case-' + File.binread('/dev/urandom', 6).unpack1('H*')
    %w[etc/openclash/config etc/openclash/core etc/r3mini-chatgpt tmp var/lock sbin usr/bin usr/libexec mock-ports].each do |dir|
      mkdir_p(@root + '/' + dir)
    end
    @gid = Process.gid.positive? ? Process.gid : 65_534
    File.write(@root + '/etc/group', "nogroup:x:#{@gid}:\n")
    @runtime = @root + '/etc/openclash/MESL_yue.yaml'
    @source = @root + '/etc/openclash/config/lian_li.yaml'
    @settings = @root + '/etc/r3mini-chatgpt/settings.json'
    @initial = {
      'external-controller' => '0.0.0.0:9090', 'secret' => 'test-controller-secret',
      'mixed-port' => 7890, 'mode' => 'rule', 'ipv6' => false,
      'dns' => {'enable' => true, 'nameserver' => ['https://dns.example.test/dns-query'], 'fake-ip-filter' => ['+.example.test']},
      'profile' => {'store-selected' => true, 'store-fake-ip' => true},
      'proxy-providers' => {'original' => {'type' => 'file', 'path' => './provider/original.yaml'}},
      'proxies' => [{'name' => '原节点', 'type' => 'ss', 'server' => 'original.invalid', 'password' => 'original-private'}],
      'proxy-groups' => [{'name' => 'AI', 'type' => 'select', 'proxies' => ['原节点', 'DIRECT']},
                         {'name' => '其他', 'type' => 'select', 'use' => ['original']}],
      'rules' => ['DOMAIN-SUFFIX,claude.ai,AI', 'DOMAIN-SUFFIX,anthropic.com,AI', 'DOMAIN-SUFFIX,openai.com,AI',
                  'RULE-SET,OtherAI,AI', 'MATCH,其他']
    }
    File.write(@runtime, YAML.dump(@initial))
    File.chmod(0o644, @runtime)
    @nodes = [{'name' => '日本 "A"\\线路', 'type' => 'hysteria2', 'server' => 'selected.invalid', 'password' => 'selected-secret'}] +
             (0...56).map { |i| {'name' => "节点-#{i}", 'type' => 'vless', 'server' => 'unselected.invalid', 'uuid' => "private-#{i}"} }
    write_source(@nodes)
    install('usr/bin/curl', MOCK_CURL.sub('RUBY_PATH', RUBY))
    install('etc/openclash/core/clash_meta', MOCK_CORE.sub('RUBY_PATH', RUBY))
    install('sbin/uci', MOCK_UCI)
    File.binwrite(@root + '/usr/libexec/r3mini-site-bench.rb', File.binread(HELPER))
    write_controller({'calls' => [], 'reloads' => 0, 'proxies' => {}, 'rules' => []})
    seed_live
    store_bench
  end

  def core_log
    File.read(@root + '/core-exit.log')
  rescue SystemCallError
    nil
  end

  def teardown
    Dir.glob(@root + '/mock-ports/*.bin').each do |manifest|
      Process.kill('TERM', Marshal.load(File.binread(manifest))['pid'])
    rescue StandardError
      nil
    end
    Dir.glob(@root + '/tmp/r3mini-site-bench/*/state.json').each do |file|
      state = jload(File.read(file))
      Process.kill('TERM', state['pid']) if state.is_a?(Hash) && state['running']
    rescue StandardError
      nil
    end
    sleep 0.05
    rm_rf(@root)
  end

  def install(relative, text)
    File.write(@root + '/' + relative, text)
    File.chmod(0o755, @root + '/' + relative)
  end

  def node_id(name)
    Digest::SHA256.hexdigest(name)[0, 16]
  end

  def write_source(nodes, file = @source, extra = {})
    File.write(file, YAML.dump({'proxies' => nodes}.merge(extra)))
  end

  def source_nodes(name)
    jload(File.read(@root + '/etc/openclash/config/' + name))['proxies']
  end

  def controller
    Marshal.load(File.binread(@root + '/controller.bin'))
  end

  def write_controller(state)
    File.binwrite(@root + '/controller.bin', Marshal.dump(state))
  end

  def flag_controller(flags)
    state = controller
    flags.each { |key, value| state[key.to_s] = value }
    write_controller(state)
  end

  TYPES = {'DOMAIN-SUFFIX' => 'DomainSuffix', 'DOMAIN' => 'Domain', 'DOMAIN-KEYWORD' => 'DomainKeyword',
           'IP-CIDR' => 'IPCIDR', 'MATCH' => 'Match', 'RULE-SET' => 'RuleSet'}.freeze

  def seed_live
    config = runtime_config
    state = controller
    state['proxies'] = {}
    (config['proxies'] || []).each { |node| state['proxies'][node['name']] = {'type' => node['type']} }
    (config['proxy-groups'] || []).each do |group|
      values = group['proxies'] || []
      state['proxies'][group['name']] = {'all' => values, 'now' => values[0]}
    end
    state['rules'] = (config['rules'] || []).map do |rule|
      parts = rule.split(',')
      {'type' => TYPES.fetch(parts[0], parts[0]), 'payload' => parts.length > 2 ? parts[1] : '',
       'proxy' => parts.length > 2 ? parts[2] : parts[1]}
    end
    write_controller(state)
  end

  def runtime_config(path = @runtime)
    jload(File.read(path))
  end

  def rules_of(path = @runtime)
    runtime_config(path)['rules']
  end

  def settings_json
    jload(File.read(@settings))
  end

  def tmp_backups
    dir = @root + '/tmp/r3mini-chatgpt/backups'
    File.directory?(dir) ? Dir.children(dir).length : 0
  end

  def run(argv)
    errfile = @root + '/stderr.txt'
    out = IO.popen({'R3MINI_CHATGPT_ROOT' => @root}, argv, err: errfile, &:read)
    [out, File.read(errfile), $?]
  end

  def cmd(*args, ok: true)
    out, err, status = run([RUBY, BACKEND, *args])
    eq('', err, "stderr of #{args.first}")
    result = jload(out)
    check(result.is_a?(Hash), "non-JSON output of #{args.first}: #{out[0, 200]}")
    eq(ok, result['ok'], "ok of #{args.join(' ')[0, 80]} => #{out[0, 300]}")
    eq(ok ? 0 : 1, status.exitstatus, "exit code of #{args.first}")
    SECRETS.each { |secret| check(!out.include?(secret), "#{secret} leaked by #{args.first}") }
    result
  end

  def hcli(*args, ok: true)
    out, err, status = run([RUBY, @root + '/usr/libexec/r3mini-site-bench.rb', *args])
    eq('', err, "helper stderr of #{args.first}")
    result = jload(out)
    eq(ok, result['ok'], "helper ok of #{args.join(' ')[0, 80]} => #{out[0, 300]}")
    eq(ok ? 0 : 1, status.exitstatus, 'helper exit code')
    (SECRETS + HELPER_SECRETS).each { |secret| check(!out.include?(secret), "#{secret} leaked by helper #{args.first}") }
    result
  end

  def apply(index = 0)
    cmd('apply', 'lian_li.yaml', node_id(@nodes[index]['name']))
  end

  def bench_key(source, target)
    Digest::SHA256.hexdigest(source + "\n" + target)[0, 16]
  end

  def bench_rows(nodes, flags)
    nodes.each_with_index.map do |node, i|
      eligible = flags.fetch(:eligible, true)
      {'id' => node_id(node['name']), 'name' => node['name'],
       'node_hash' => flags[:wrong_hash] ? '0' * 64 : R3MiniSiteBench.node_hash(node),
       'country' => flags.key?(:country) ? flags[:country] : 'US',
       'samples_ms' => flags[:samples] || [30.5 + i, 10.5 + i, 20.5 + i], 'median_ms' => 20.5 + i,
       'eligible' => eligible, 'error' => eligible ? nil : flags[:row_error] || 'UNSUPPORTED_REGION',
       'tested_at' => '2026-11-23T00:00:00Z',
       'tested_epoch' => flags[:stale] ? Time.now.to_i - 8 * 86_400 : Time.now.to_i}
    end
  end

  # Stands in for a finished benchmark run: the helper's persisted results file.
  def store_bench(source: 'lian_li.yaml', target: 'chatgpt', nodes: nil, **flags)
    nodes ||= source_nodes(source)
    dir = @root + '/etc/r3mini-chatgpt/bench'
    mkdir_p(dir)
    File.write("#{dir}/#{bench_key(source, target)}.json",
               jdump({'source' => source, 'target' => target,
                      'source_sha256' => Digest::SHA256.file(@root + '/etc/openclash/config/' + source).hexdigest,
                      'finished_at' => '2026-11-23T00:00:10Z', 'results' => bench_rows(nodes, flags)}))
  end

  def clear_bench
    rm_rf(@root + '/etc/r3mini-chatgpt/bench')
  end

  def site_target(domain)
    value = domain.strip.downcase.sub(%r{\Ahttps?://}, '').split(%r{[/?#]}, 2)[0].to_s
    'site:' + value.sub(/\A\*\./, '').sub(/\.\z/, '')
  end

  def save_site(label, domains, index: 0, source: 'lian_li.yaml', ok: true, bench: true, **extra)
    payload = {'label' => label, 'domains' => domains, 'source' => source,
               'selected' => node_id(@nodes[index]['name']), 'enabled' => true}
    extra.each { |key, value| payload[key.to_s] = value }
    store_bench(source: source, target: site_target(domains[0])) if bench && !domains.empty?
    cmd('save', jdump(payload), ok: ok)
  end

  def tmp_hook(config = @initial)
    file = @root + '/tmp/MESL_yue.yaml'
    File.write(file, YAML.dump(config))
    file
  end

  def group_of(config, id)
    config['proxy-groups'].find { |group| group['name'] == 'R3Site-' + id }
  end

  # ---------------------------------------------------------------- backend

  def test_status_json_and_candidate_source
    clear_bench
    result = cmd('status')
    check(!result['enabled'] && !result['applied'])
    eq(57, result['nodes'].length)
    eq(@nodes[0]['name'], result['nodes'][0]['name'])
    %w[id name type eligible country samples_ms median_ms].each { |key| check(result['nodes'][0].key?(key), "node field #{key}") }
    write_source([@nodes[1]], @root + '/etc/openclash/config/other.yaml')
    viewed = cmd('status', 'other.yaml')
    eq('lian_li.yaml', viewed['source'])
    eq(1, viewed['nodes'].length)
    check(!File.exist?(@settings), 'reads never create settings')
  end

  def test_apply_only_one_node_and_disable_restores_all_other_config
    result = apply
    check(result['enabled'] && result['applied'], 'applied')
    runtime = runtime_config
    alias_name = 'r3mini-site-node-' + PRESET_ID + '-' + node_id(@nodes[0]['name'])
    eq(2, runtime['proxies'].length)
    eq({'name' => PRESET_GROUP, 'type' => 'select', 'proxies' => [alias_name]}, runtime['proxy-groups'][-1])
    eq('selected.invalid', runtime['proxies'][-1]['server'])
    eq(@initial['rules'], runtime['rules'][-@initial['rules'].length..-1])
    eq(@initial['dns'], runtime['dns'])
    eq(@initial['profile'], runtime['profile'])
    eq(false, apply['reloaded'], 'an identical apply loads nothing')
    eq(runtime, runtime_config)
    result = cmd('disable')
    check(!result['enabled'] && !result['applied'])
    eq(@initial, runtime_config)
    cmd('disable')
    eq(@initial, runtime_config)
    eq(0o600, File.stat(@runtime).mode & 0o777)
    Dir.glob(@root + '/tmp/r3mini-chatgpt/backups/**/*').each do |file|
      eq(File.directory?(file) ? 0o700 : 0o600, File.stat(file).mode & 0o777, file)
    end
    check(!File.exist?(@root + '/etc/r3mini-chatgpt/backups'), 'no transaction backup on flash')
    leftovers = Dir.children(@root + '/tmp/r3mini-chatgpt').reject { |name| name == 'backups' || name.start_with?('index-') }
    eq([], leftovers, 'controller headers and bodies are removed')
  end

  def test_hook_reapplies_after_runtime_regeneration_and_disabled_cleanup
    apply
    reloads = controller['reloads']
    File.write(@runtime, YAML.dump(@initial))
    check(cmd('status')['applied'], 'live state is still loaded')
    check(cmd('hook', '/etc/openclash/MESL_yue.yaml')['changed'])
    eq(reloads, controller['reloads'], 'the hook never reloads')
    check(!cmd('hook', '/etc/openclash/MESL_yue.yaml')['changed'])
    cmd('disable')
    stored = settings_json
    stored['enabled'] = false
    stored['rules'].each { |rule| rule['enabled'] = false }
    File.write(@settings, jdump(stored))
    File.write(@runtime, YAML.dump(@initial))
    cmd('hook', '/etc/openclash/MESL_yue.yaml')
  end

  def test_rejects_traversal_symlink_missing_node_and_dialer_dependency
    original = File.binread(@runtime)
    ['../lian_li.yaml', '/etc/passwd.yaml', 'bad\\name.yaml', "evil\nname.yaml"].each do |name|
      eq('SOURCE_INVALID', cmd('apply', name, '0' * 16, ok: false)['error'], name.inspect)
    end
    File.symlink(@source, @root + '/etc/openclash/config/alias.yaml')
    eq('SOURCE_MISSING', cmd('apply', 'alias.yaml', '0' * 16, ok: false)['error'])
    eq('ARGUMENT_INVALID', cmd('apply', 'lian_li.yaml', '$(bad)', ok: false)['error'])
    eq('NODE_MISSING', cmd('apply', 'lian_li.yaml', '0' * 16, ok: false)['error'])
    @nodes[0]['dialer-proxy'] = 'another-node'
    write_source(@nodes)
    eq('NODE_DEPENDENCY', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'])
    eq(original, File.binread(@runtime))
    check(!File.exist?(@settings))
  end

  def test_controller_rejection_keeps_running_config_and_file
    before = File.binread(@runtime)
    flag_controller(reject_next_reload: true)
    eq('CONFIG_TEST_FAILED', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'])
    eq(before, File.binread(@runtime))
    eq(0o644, File.stat(@runtime).mode & 0o777)
    check(!File.exist?(@settings))
    eq(0, controller['reloads'])
    eq(1, controller['calls'].count { |call| call[0] == 'PUT' }, 'a rejected candidate needs no restore reload')
    eq(1, tmp_backups)
    check(!File.exist?(@root + '/core-call.json'), 'live edits skip mihomo -t')
  end

  def test_failed_core_validation_in_hook_preserves_bytes
    apply
    hookfile = tmp_hook
    before = File.binread(hookfile)
    settings_before = File.binread(@settings)
    File.write(@root + '/fail_core', '')
    eq('CONFIG_TEST_FAILED', cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['error'])
    eq(before, File.binread(hookfile))
    eq(settings_before, File.binread(@settings))
  end

  def test_reload_failure_after_loading_candidate_rolls_back_runtime_and_settings
    apply
    before_runtime = File.binread(@runtime)
    before_settings = File.binread(@settings)
    flag_controller(fail_after_load: true)
    eq('RELOAD_FAILED', cmd('disable', ok: false)['error'])
    eq(before_runtime, File.binread(@runtime))
    eq(before_settings, File.binread(@settings))
    check(cmd('status')['applied'])
  end

  def test_verification_failure_rolls_back_and_no_false_success
    before = File.binread(@runtime)
    flag_controller(bad_next_reload: true)
    eq('VERIFY_FAILED', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'])
    eq(before, File.binread(@runtime))
    check(!File.exist?(@settings))
    check(!controller['proxies'].key?(PRESET_GROUP))
  end

  def test_lock_contention_is_nonblocking
    File.open(@root + '/var/lock/r3mini-chatgpt.lock', File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX | File::LOCK_NB)
      eq('BUSY', cmd('disable', ok: false)['error'])
    end
    check(!File.exist?(@settings))
  end

  def test_missing_subscription_does_not_prevent_disable
    apply
    File.unlink(@source)
    eq('SOURCE_MISSING', cmd('status')['error'])
    result = cmd('disable')
    check(!result['enabled'] && !result['applied'])
    eq(@initial, runtime_config)
    cmd('disable')
  end

  def test_hook_cannot_edit_source_or_arbitrary_absolute_path
    original = File.binread(@source)
    ['/etc/openclash/config/lian_li.yaml', '/tmp/other.yaml', 'relative.yaml'].each do |logical|
      eq('RUNTIME_MISSING', cmd('hook', logical, ok: false)['error'], logical)
    end
    eq(original, File.binread(@source))
  end

  def test_stale_controller_is_never_reported_applied
    apply
    state = controller
    state['rules'] = state['rules'][1..-1]
    write_controller(state)
    status = cmd('status')
    check(status['enabled'] && !status['applied'])
    eq('STATE_MISMATCH', status['error'])
    flag_controller(offline: true)
    status = cmd('status')
    check(!status['applied'])
    eq('CONTROLLER_UNAVAILABLE', status['error'])
    eq('CONTROLLER_UNAVAILABLE', cmd('summary')['error'])
  end

  def test_removed_selected_node_never_shows_applied
    apply
    write_source(@nodes[1..-1])
    status = cmd('status')
    check(!status['applied'])
    eq('NODE_MISSING', status['error'])
    cmd('disable')
  end

  def test_tmp_hook_restricts_active_basename_and_fails_closed
    apply
    hookfile = tmp_hook
    cmd('hook', '/tmp/MESL_yue.yaml')
    eq(PRESET_GROUP, runtime_config(hookfile)['proxy-groups'][-1]['name'])
    File.write(@root + '/tmp/other.yaml', File.read(hookfile))
    eq('RUNTIME_MISSING', cmd('hook', '/tmp/other.yaml', ok: false)['error'])
    File.unlink(hookfile)
    File.symlink(@runtime, hookfile)
    eq('RUNTIME_MISSING', cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['error'])
    File.unlink(hookfile)
    tmp_hook
    File.unlink(@source)
    2.times do
      failure = cmd('hook', '/tmp/MESL_yue.yaml', ok: false)
      eq('SOURCE_MISSING', failure['error'])
      eq(true, failure['fail_closed'])
    end
    closed = runtime_config(hookfile)
    eq(['REJECT'], closed['proxy-groups'][-1]['proxies'])
    eq(@initial['rules'], closed['rules'][-@initial['rules'].length..-1])
    check(!cmd('status')['applied'])
  end

  def test_offline_disable_restores_disk_for_next_start
    apply
    flag_controller(offline: true)
    response = cmd('disable')
    eq(true, response['pending_restart'])
    eq(nil, response['error'])
    check(response['message'].include?('下次启动'))
    check(!response['enabled'] && !response['applied'])
    eq(@initial, runtime_config)
    eq(false, settings_json['enabled'])
    eq(true, cmd('status')['pending_restart'])
    eq(nil, cmd('status')['error'])
    cmd('disable')
  end

  def test_invalid_yaml_and_duplicate_names_leave_runtime_unchanged
    before = File.binread(@runtime)
    File.write(@source, 'proxies: [')
    eq('SOURCE_YAML_INVALID', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'])
    write_source([@nodes[0], @nodes[0]])
    eq('SOURCE_NODES_INVALID', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'])
    eq(before, File.binread(@runtime))
  end

  def test_global_mode_is_rejected_without_claiming_routing_success
    File.write(@runtime, YAML.dump(@initial.merge('mode' => 'global')))
    before = File.binread(@runtime)
    eq('ROUTING_MODE_UNSUPPORTED', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'])
    eq(before, File.binread(@runtime))
  end

  def test_existing_reserved_business_names_are_never_deleted
    %w[group node rule].each do |entry|
      config = Marshal.load(Marshal.dump(@initial))
      case entry
      when 'group' then config['proxy-groups'] << {'name' => 'ChatGPT-LianLi', 'type' => 'select', 'proxies' => ['原节点']}
      when 'node' then config['proxies'] << {'name' => 'r3mini-chatgpt-node-' + 'a' * 16, 'type' => 'ss', 'server' => 'business.invalid'}
      else config['rules'].unshift('DOMAIN-SUFFIX,business.example,ChatGPT-LianLi')
      end
      File.write(@runtime, YAML.dump(config))
      before = File.binread(@runtime)
      eq('NAME_CONFLICT', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'], entry)
      eq(before, File.binread(@runtime))
      eq('NAME_CONFLICT', cmd('disable', ok: false)['error'], entry)
    end
    File.write(@runtime, YAML.dump(@initial))
    apply
    cmd('disable')
    config = runtime_config
    config['proxy-groups'] << {'name' => 'ChatGPT-LianLi', 'type' => 'select', 'proxies' => ['原节点']}
    File.write(@runtime, YAML.dump(config))
    eq('NAME_CONFLICT', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'])
  end

  def test_enabled_hook_refuses_foreign_group_with_reserved_name
    apply
    config = Marshal.load(Marshal.dump(@initial))
    config['proxy-groups'] << {'name' => 'ChatGPT-LianLi', 'type' => 'select', 'proxies' => ['原节点']}
    hookfile = tmp_hook(config)
    before = File.binread(hookfile)
    eq('NAME_CONFLICT', cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['error'])
    eq(before, File.binread(hookfile))
  end

  def test_two_websites_choose_independent_sources_and_single_nodes
    first = save_site('网站甲', ['https://EXAMPLE.COM/path?q=ignored'])
    write_source([@nodes[1]], @root + '/etc/openclash/config/other.yaml')
    second = save_site('网站乙', ['*.second.example.net'], index: 1, source: 'other.yaml')
    sites = second['site_rules']
    eq([first['id'], second['id']], sites.map { |rule| rule['id'] })
    eq([['example.com'], ['second.example.net']], sites.map { |rule| rule['domains'] })
    check(sites.all? { |rule| rule['applied'] } && second['applied'])
    config = runtime_config
    sites.zip(@nodes[0, 2]).each do |site, expected|
      alias_name = 'r3mini-site-node-' + site['id'] + '-' + site['selected']
      eq([alias_name], group_of(config, site['id'])['proxies'])
      eq(expected['server'], config['proxies'].find { |node| node['name'] == alias_name }['server'])
    end
    eq(['DOMAIN-SUFFIX,example.com,R3Site-' + first['id'], 'DOMAIN-SUFFIX,second.example.net,R3Site-' + second['id']],
       config['rules'][0, 2])
    eq(@initial['rules'], config['rules'][2..-1])
    eq(3, config['proxies'].length)
    eq(@initial['dns'], config['dns'])
    eq(@initial['profile'], config['profile'])
    viewed = cmd('status', 'lian_li.yaml')
    eq(57, viewed['nodes'].length)
    eq('other.yaml', viewed['source'])
    eq(sites, viewed['site_rules'])
  end

  def test_domain_validation_and_cross_rule_suffix_conflicts
    invalid = ['127.0.0.1', 'https://127.0.0.1/path', 'https://[::1]/', 'example.com:443', 'https://example.com:443/path',
               'https://user:pass' + '@example.com/', 'http://', 'localhost', 'bad_domain.example', 'a..example.com',
               'https://-bad.example.com', "https://good.example.com\nmalformed", 'ftp://example.com/path']
    before = File.binread(@runtime)
    invalid.each do |domain|
      payload = jdump({'label' => 'bad', 'domains' => [domain], 'source' => 'lian_li.yaml', 'selected' => node_id(@nodes[0]['name'])})
      eq('DOMAIN_INVALID', cmd('save', payload, ok: false)['error'], domain.inspect)
      eq(before, File.binread(@runtime))
    end
    first = save_site('main', ['EXAMPLE.com.', '*.example.com'])
    eq(['example.com'], first['site_rules'][0]['domains'])
    ['example.com', 'sub.example.com', '*.example.com'].each do |domain|
      payload = jdump({'label' => 'collision', 'domains' => [domain], 'source' => 'lian_li.yaml', 'selected' => node_id(@nodes[1]['name'])})
      eq('DOMAIN_CONFLICT', cmd('save', payload, ok: false)['error'], domain)
    end
    eq(1, cmd('status')['site_rules'].length)
  end

  def test_edit_enable_remove_and_disable_preserve_other_site
    first = save_site('first', ['first.example.com'])
    second = save_site('second', ['second.example.com'], index: 1)
    first_id = first['id']
    second_id = second['id']
    changed = save_site('first edited', ['new.example.com'], index: 2, id: first_id)
    eq([first_id, second_id], changed['site_rules'].map { |rule| rule['id'] })
    eq(node_id(@nodes[2]['name']), changed['site_rules'][0]['selected'])
    check(changed['site_rules'][1]['applied'])
    stopped = cmd('set-enabled', first_id, '0')
    check(!stopped['site_rules'][0]['enabled'] && !stopped['site_rules'][0]['applied'])
    check(stopped['site_rules'][1]['applied'])
    check(stopped['enabled'] && stopped['applied'])
    cmd('set-enabled', first_id, '1')
    removed = cmd('remove', first_id)
    eq([second_id], removed['site_rules'].map { |rule| rule['id'] })
    check(removed['site_rules'][0]['applied'])
    stopped = cmd('disable')
    eq(1, stopped['site_rules'].length)
    check(!stopped['enabled'] && !stopped['applied'])
    eq(@initial, runtime_config)
    eq('RULE_MISSING', cmd('remove', first_id, ok: false)['error'])
    eq('ARGUMENT_INVALID', cmd('set-enabled', second_id, 'yes', ok: false)['error'])
  end

  def test_save_chatgpt_preset_and_explicit_conversion_to_custom
    preset = save_site('ChatGPT', ['chatgpt.com', 'openai.com'], preset: 'chatgpt')
    site = preset['site_rules'][0]
    eq('chatgpt', site['preset'])
    config = runtime_config
    eq(12, config['rules'].length - @initial['rules'].length)
    check(config['rules'].include?('DOMAIN,openai-api.arkoselabs.com,R3Site-' + site['id']))
    check(config['rules'].include?('DOMAIN-KEYWORD,openai,R3Site-' + site['id']))
    edited = save_site('renamed', ['chatgpt.com', 'openai.com'], id: site['id'])
    eq('chatgpt', edited['site_rules'][0]['preset'])
    eq(false, edited['reloaded'], 'a rename alone loads nothing')
    payload = jdump({'label' => 'overlap', 'domains' => ['openaiapi-site.azureedge.net'], 'source' => 'lian_li.yaml',
                     'selected' => node_id(@nodes[0]['name'])})
    eq('DOMAIN_CONFLICT', cmd('save', payload, ok: false)['error'])
    custom = save_site('custom', ['custom.example.com'], id: site['id'], preset: '')
    eq('', custom['site_rules'][0]['preset'])
    config = runtime_config
    eq('DOMAIN-SUFFIX,custom.example.com,R3Site-' + site['id'], config['rules'][0])
    eq(@initial['rules'], config['rules'][1..-1])
  end

  def test_one_failed_site_hook_rejects_only_that_site
    first = save_site('first', ['first.example.com'])
    other = @root + '/etc/openclash/config/other.yaml'
    write_source([@nodes[1]], other)
    second = save_site('second', ['second.example.com'], index: 1, source: 'other.yaml')
    File.unlink(other)
    hookfile = tmp_hook
    eq(true, cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['fail_closed'])
    config = runtime_config(hookfile)
    eq(['REJECT'], group_of(config, second['id'])['proxies'])
    eq(1, group_of(config, first['id'])['proxies'].length)
    check(group_of(config, first['id'])['proxies'][0].start_with?('r3mini-site-node-'))
    File.binwrite(@runtime, File.binread(hookfile))
    seed_live
    status = cmd('status')
    check(status['site_rules'][0]['applied'])
    check(!status['site_rules'][1]['applied'])
    eq('SOURCE_MISSING', status['site_rules'][1]['error'])
    check(!status['applied'])
    cmd('disable')
    eq(@initial, runtime_config)
  end

  def test_new_site_namespace_collision_is_preserved
    config = Marshal.load(Marshal.dump(@initial))
    config['proxy-groups'] << {'name' => 'R3Site-' + 'a' * 12, 'type' => 'select', 'proxies' => ['原节点']}
    File.write(@runtime, YAML.dump(config))
    before = File.binread(@runtime)
    eq('NAME_CONFLICT', save_site('new', ['example.com'], ok: false)['error'])
    eq(before, File.binread(@runtime))
  end

  def test_multisite_mutation_failure_restores_all_settings_and_sites
    first = save_site('first', ['first.example.com'])
    save_site('second', ['second.example.com'], index: 1)
    before_runtime = File.binread(@runtime)
    before_settings = File.binread(@settings)
    flag_controller(fail_after_load: true)
    eq('RELOAD_FAILED', cmd('remove', first['id'], ok: false)['error'])
    eq(before_runtime, File.binread(@runtime))
    eq(before_settings, File.binread(@settings))
    check(cmd('status')['applied'])
  end

  def test_new_node_requires_supported_country_and_three_real_samples
    before = File.binread(@runtime)
    [{eligible: false}, {samples: [10, 20]}, {samples: [10, 0, 20]}, {wrong_hash: true}, {stale: true},
     {country: 'CN'}, {samples: [1, 2, 3]}, {samples: [1, 2, 3, 4]}].each do |flags|
      clear_bench
      store_bench(**flags)
      eq('BENCHMARK_REQUIRED', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'], flags.inspect)
      eq(before, File.binread(@runtime))
      check(!File.exist?(@settings))
      check(!cmd('status')['nodes'][0]['eligible'], "#{flags.inspect} must not prove the node")
    end
    clear_bench
    store_bench
    apply
    proof = settings_json['rules'][0]['node_validation']
    eq(true, proof['eligible'])
    eq('US', proof['country'])
    eq([30.5, 10.5, 20.5], proof['samples_ms'])
    eq(20.5, proof['median_ms'])
    eq('chatgpt', proof['target'])
    check(cmd('status')['nodes'][0]['eligible'])
  end

  def test_benchmark_cli_and_nodes_view_return_no_connection_credentials
    clear_bench
    @nodes = @nodes[0, 3].each_with_index.map { |node, i| node.merge('mock-samples' => [0.3 + i * 0.1, 0.1 + i * 0.1, 0.2 + i * 0.1]) }
    write_source(@nodes, @source, 'dns' => {'proxy-server-nameserver' => ['1.1.1.1']})
    File.write(@root + '/etc/openclash/Country.mmdb', 'fake-geodata')
    eq(true, cmd('benchmark', 'lian_li.yaml')['running'])
    finished = wait_bench
    eq(3, finished['nodes'].length)
    check(finished['nodes'].all? { |node| node['eligible'] && node['samples_ms'].length == 3 }, finished['nodes'].map { |n| n['error'] }.inspect)
    eq(node_id(@nodes[0]['name']), finished['best'])
    view = cmd('nodes', 'lian_li.yaml')
    check(view['nodes'].all? { |node| node['eligible'] && node['country'] == 'US' && node['tested_at'] })
    eq(finished['best'], cmd('status')['benchmark']['best'])
  end

  def wait_bench(target = nil)
    deadline = mono + 60
    loop do
      args = ['benchmark-status', 'lian_li.yaml']
      args << target if target
      result = cmd(*args)
      return result unless result['running']
      raise AssertionFailed, 'benchmark did not finish' if mono > deadline
      sleep 0.3
    end
  end

  def test_persistent_validation_survives_missing_benchmark_cache
    first_id = apply['site_rules'][0]['id']
    clear_bench
    store_bench(eligible: false, stale: true)
    status = cmd('status')
    check(status['applied'])
    check(status['nodes'][0]['eligible'])
    check(!status['nodes'][1]['eligible'])
    eq(true, cmd('nodes', 'lian_li.yaml')['nodes'][1]['stale'])
    hookfile = tmp_hook
    cmd('hook', '/tmp/MESL_yue.yaml')
    check(group_of(runtime_config(hookfile), first_id)['proxies'] != ['REJECT'])
    cmd('set-enabled', first_id, '0')
    cmd('set-enabled', first_id, '1')
    check(cmd('status')['applied'])
  end

  def test_changed_node_parameters_require_retest_and_hook_fails_closed
    site_id = apply['site_rules'][0]['id']
    @nodes[1]['server'] = 'unrelated-change.invalid'
    write_source(@nodes)
    clear_bench
    store_bench(eligible: false, row_error: 'PENDING')
    check(cmd('status')['applied'], 'the selected parameters are unchanged')
    @nodes[0]['server'] = 'changed-selected.invalid'
    write_source(@nodes)
    status = cmd('status')
    check(!status['applied'])
    eq('NODE_CHANGED', status['site_rules'][0]['error'])
    check(!status['nodes'][0]['eligible'])
    hookfile = tmp_hook
    eq('NODE_CHANGED', cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['error'])
    eq(['REJECT'], group_of(runtime_config(hookfile), site_id)['proxies'])
    cmd('disable')
    eq('BENCHMARK_REQUIRED', cmd('set-enabled', site_id, '1', ok: false)['error'])
    cmd('remove', site_id)
    eq(@initial, runtime_config)
  end

  def test_save_cannot_import_user_supplied_validation
    clear_bench
    payload = jdump({'label' => 'forged', 'domains' => ['example.com'], 'source' => 'lian_li.yaml',
                     'selected' => node_id(@nodes[0]['name']), 'enabled' => true,
                     'node_validation' => {'eligible' => true, 'country' => 'US', 'samples_ms' => [1, 2, 3],
                                           'median_ms' => 2, 'node_hash' => 'forged'}})
    eq('BENCHMARK_REQUIRED', cmd('save', payload, ok: false)['error'])
    check(!File.exist?(@settings))
  end

  def test_float_metrics_and_shared_supported_regions
    response = apply
    eq([30.5, 10.5, 20.5], settings_json['rules'][0]['node_validation']['samples_ms'])
    check(cmd('nodes', 'lian_li.yaml')['nodes'][0]['median_ms'].is_a?(Float))
    cmd('disable')
    regions = @root + '/usr/share/r3mini-site-routing'
    mkdir_p(regions)
    File.write(regions + '/supported-regions.json', jdump({'countries' => ['JP']}))
    eq('BENCHMARK_REQUIRED', cmd('set-enabled', response['site_rules'][0]['id'], '1', ok: false)['error'])
  end

  def test_fresh_failed_retest_revokes_saved_supported_region_proof
    site_id = apply['site_rules'][0]['id']
    clear_bench
    store_bench(eligible: false, country: 'HK', row_error: 'UNSUPPORTED_REGION')
    status = cmd('status')
    check(!status['applied'])
    check(!status['nodes'][0]['eligible'])
    eq('HK', status['nodes'][0]['country'])
    eq('BENCHMARK_REQUIRED', status['site_rules'][0]['error'])
    hookfile = tmp_hook
    eq(true, cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['fail_closed'])
    eq(['REJECT'], group_of(runtime_config(hookfile), site_id)['proxies'])
    cmd('disable')
    eq('BENCHMARK_REQUIRED', cmd('set-enabled', site_id, '1', ok: false)['error'])
  end

  def test_pending_retest_may_use_saved_proof_until_that_node_completes
    apply
    clear_bench
    store_bench(eligible: false, country: nil, row_error: 'PENDING')
    status = cmd('status')
    check(status['applied'])
    check(status['nodes'][0]['eligible'])
    eq('US', status['nodes'][0]['country'])
  end

  def test_failed_hook_revocation_survives_losing_benchmark_results
    site_id = apply['site_rules'][0]['id']
    clear_bench
    store_bench(eligible: false, country: 'HK', row_error: 'UNSUPPORTED_REGION')
    hookfile = tmp_hook
    cmd('hook', '/tmp/MESL_yue.yaml', ok: false)
    stored = settings_json
    check(!stored['rules'][0].key?('node_validation'))
    eq('BENCHMARK_REQUIRED', stored['rule_errors'][site_id])
    clear_bench
    tmp_hook
    cmd('hook', '/tmp/MESL_yue.yaml', ok: false)
    status = cmd('status')
    check(!status['applied'] && !status['nodes'][0]['eligible'])
    eq(['REJECT'], group_of(runtime_config(hookfile), site_id)['proxies'])
    cmd('disable')
    eq('BENCHMARK_REQUIRED', settings_json['rule_errors'][site_id])
    eq('BENCHMARK_REQUIRED', cmd('set-enabled', site_id, '1', ok: false)['error'])
  end

  def test_successful_apply_uses_targeted_controller_calls
    flag_controller(delay_seconds: 0.25)
    started = mono
    response = apply
    elapsed = mono - started
    check(response['applied'])
    calls = controller['calls']
    eq([['GET', '/rules'], ['GET', '/proxies'], ['PUT', '/configs?force=true'],
        ['GET', '/rules'], ['GET', '/proxies'], ['GET', '/proxies/' + PRESET_GROUP]], calls.map { |call| call[0, 2] })
    eq([2.0, 2.0, 6.0, 2.0, 2.0, 2.0], calls.map { |call| call[2] })
    check(elapsed < 8, "apply took #{elapsed.round(2)} s")
    eq(true, response['reloaded'])
    check(response['timings'].key?('reload_ms') && response['elapsed_ms'].is_a?(Integer))
    cmd('summary')
    eq(9, controller['calls'].length)
  end

  def test_controller_timeouts_stay_within_the_rpc_budget
    before = File.binread(@runtime)
    flag_controller(delay_seconds: 4.2)
    started = mono
    eq('CONTROLLER_UNAVAILABLE', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'])
    check(mono - started < 5, 'an unreachable controller fails after one 2 s call')
    eq(before, File.binread(@runtime))
    check(!File.exist?(@settings))
    flag_controller(delay_seconds: 0, put_delay_seconds: 7)
    started = mono
    eq('ROLLBACK_FAILED', cmd('apply', 'lian_li.yaml', node_id(@nodes[0]['name']), ok: false)['error'])
    elapsed = mono - started
    check(elapsed < 17, "reload plus rollback took #{elapsed.round(2)} s (LuCI gives up at 20 s)")
    eq(before, File.binread(@runtime))
    check(!File.exist?(@settings))
    eq([6.0, 6.0], controller['calls'].select { |call| call[0] == 'PUT' }.map { |call| call[2] })
  end

  def test_core_validation_watchdog_stops_child_and_preserves_original
    apply
    hookfile = tmp_hook
    before = File.binread(hookfile)
    File.write(@root + '/hang_core', '')
    started = mono
    eq('CONFIG_TEST_FAILED', cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['error'])
    elapsed = mono - started
    check(elapsed >= 20 && elapsed < 23, "watchdog took #{elapsed.round(2)} s")
    eq(before, File.binread(hookfile))
    check(!File.exist?('/proc/' + File.read(@root + '/core-test-pid').strip), 'the hung core is killed')
  end

  def test_core_validation_gets_production_paths_and_nogroup
    apply
    tmp_hook
    cmd('hook', '/tmp/MESL_yue.yaml')
    eq('/usr/share/openclash:/etc/ssl', File.read(@root + '/core-safe-paths'))
    eq({'gid' => @gid, 'egid' => @gid}, jload(File.read(@root + '/core-gid-proof.json')))
  end

  def test_missing_helper_or_core_group_cannot_fall_back_to_root
    apply
    hookfile = tmp_hook
    before = File.binread(hookfile)
    helper = @root + '/usr/libexec/r3mini-site-bench.rb'
    saved = File.binread(helper)
    File.unlink(helper)
    eq('CORE_GROUP_MISSING', cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['error'])
    File.binwrite(helper, saved)
    ["root:x:0:\n", "nogroup:x:0:\n"].each do |content|
      File.write(@root + '/etc/group', content)
      eq('CORE_GROUP_MISSING', cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['error'], content)
    end
    File.unlink(@root + '/etc/group')
    eq('CORE_GROUP_MISSING', cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['error'])
    eq(before, File.binread(hookfile))
  end

  def test_large_subscription_save_and_reads_stay_within_budget
    count = 600
    @nodes = (0...count).map { |i| {'name' => "scale-#{i}", 'type' => 'hysteria2', 'server' => 'scale.invalid', 'password' => 'x' * 4000} }
    File.write(@source, jdump({'proxies' => @nodes}))
    clear_bench
    store_bench
    started = mono
    result = apply
    apply_s = mono - started
    check(result['applied'])
    eq(2, runtime_config['proxies'].length)
    started = mono
    view = cmd('nodes', 'lian_li.yaml')
    nodes_s = mono - started
    eq(count, view['nodes'].length)
    started = mono
    check(cmd('summary')['applied'])
    summary_s = mono - started
    puts format('    %.1f MB subscription: save %.2f s, nodes %.2f s, summary %.2f s', File.size(@source) / 1e6, apply_s, nodes_s, summary_s)
    check(apply_s < 15 && nodes_s < 6 && summary_s < 4, 'large subscription exceeded the read/save budget')
  end

  def test_status_reports_steam_direct_and_keeps_existing_fields
    result = cmd('status')
    eq(STEAM_OFF, result['steam_direct'])
    eq(%w[applied backup_count benchmark enabled error last_action last_time nodes ok pending_restart runtime_group
          selected selected_name site_rules source source_error sources steam_direct], result.keys.sort)
    check(!File.exist?(@settings))
    File.write(@settings, jdump({'rules' => [], 'steam_direct' => 'yes'}))
    eq('SETTINGS_INVALID', cmd('status', ok: false)['error'])
    eq('SETTINGS_INVALID', cmd('summary', ok: false)['error'])
    eq('SETTINGS_INVALID', cmd('steam-direct', '1', ok: false)['error'])
  end

  def test_steam_direct_on_off_is_idempotent_and_restores_original
    on = cmd('steam-direct', '1')
    eq(STEAM_ON, on['steam_direct'])
    check(!on['enabled'] && !on['applied'] && !on['error'])
    eq([['GET', '/rules'], ['GET', '/proxies'], ['PUT', '/configs?force=true'], ['GET', '/rules'], ['GET', '/proxies']],
       controller['calls'].map { |call| call[0, 2] })
    eq(@initial.merge('rules' => STEAM_BLOCK + @initial['rules']), runtime_config)
    live = controller['rules']
    eq({'type' => 'IPCIDR', 'payload' => '45.121.184.0/24', 'proxy' => 'DIRECT'}, live[3])
    eq('claude.ai', live[STEAM_BLOCK.length]['payload'])
    before = [controller['reloads'], tmp_backups]
    eq(STEAM_ON, cmd('steam-direct', '1')['steam_direct'])
    eq(STEAM_BLOCK + @initial['rules'], rules_of)
    eq(before, [controller['reloads'], tmp_backups])
    eq(STEAM_OFF, cmd('steam-direct', '0')['steam_direct'])
    eq(@initial, runtime_config)
    eq('claude.ai', controller['rules'][0]['payload'])
    before = [controller['reloads'], tmp_backups]
    eq(STEAM_OFF, cmd('steam-direct', '0')['steam_direct'])
    eq(before, [controller['reloads'], tmp_backups])
    eq(@initial, runtime_config)
    stored = settings_json
    eq(false, stored['steam_direct'])
    eq('steam-direct', stored['last_action'])
    eq(0o600, File.stat(@runtime).mode & 0o777)
  end

  def test_hook_adds_steam_block_only_when_enabled_and_ahead_of_site_rules
    hookfile = tmp_hook
    check(!cmd('hook', '/tmp/MESL_yue.yaml')['changed'])
    site = save_site('site', ['example.com'])
    site_rule = 'DOMAIN-SUFFIX,example.com,R3Site-' + site['id']
    cmd('hook', '/tmp/MESL_yue.yaml')
    eq([site_rule] + @initial['rules'], rules_of(hookfile))
    eq(STEAM_ON, cmd('steam-direct', '1')['steam_direct'])
    expected = STEAM_BLOCK + [site_rule] + @initial['rules']
    eq(expected, rules_of)
    reloads = controller['reloads']
    ['/tmp/MESL_yue.yaml', '/etc/openclash/MESL_yue.yaml'].each do |logical|
      target = @root + logical
      File.write(target, YAML.dump(@initial))
      check(cmd('hook', logical)['changed'])
      eq(expected, rules_of(target))
      check(!cmd('hook', logical)['changed'])
    end
    eq(reloads, controller['reloads'])
    eq(STEAM_ON, cmd('status')['steam_direct'])
    second = save_site('second', ['second.example.net'], index: 1)
    check(second['applied'])
    eq(STEAM_ON, second['steam_direct'])
    eq(STEAM_BLOCK + [site_rule, 'DOMAIN-SUFFIX,second.example.net,R3Site-' + second['id']] + @initial['rules'], rules_of)
  end

  def test_damaged_or_missing_block_is_restored_and_lookalikes_never_removed
    lookalikes = ['DOMAIN-SUFFIX,steamcontent.com,DIRECT', 'DOMAIN-SUFFIX,steamserver.net,DIRECT']
    config = Marshal.load(Marshal.dump(@initial))
    config['rules'] = config['rules'][0, 2] + lookalikes + STEAM_BLOCK + config['rules'][2..-1]
    File.write(@runtime, YAML.dump(config))
    seed_live
    eq(STEAM_OFF, cmd('status')['steam_direct'])
    cmd('steam-direct', '0')
    eq(config['rules'], rules_of)
    cmd('steam-direct', '1')
    eq(STEAM_BLOCK + config['rules'], rules_of)
    damaged = STEAM_BLOCK[0, 5] + STEAM_BLOCK[6..-1]
    [[], damaged].each do |broken|
      File.write(@runtime, YAML.dump(config.merge('rules' => broken + config['rules'])))
      seed_live
      eq({'enabled' => true, 'applied' => false}, cmd('status')['steam_direct'])
      eq(STEAM_ON, cmd('steam-direct', '1')['steam_direct'])
      eq(STEAM_BLOCK + broken + config['rules'], rules_of)
    end
    eq(STEAM_OFF, cmd('steam-direct', '0')['steam_direct'])
    eq(damaged + config['rules'], rules_of)
  end

  def test_disable_also_turns_steam_direct_off
    save_site('site', ['example.com'])
    eq(STEAM_ON, cmd('steam-direct', '1')['steam_direct'])
    result = cmd('disable')
    eq(STEAM_OFF, result['steam_direct'])
    check(!result['enabled'] && !result['applied'])
    eq(@initial, runtime_config)
    eq(false, settings_json['steam_direct'])
    eq('claude.ai', controller['rules'][0]['payload'])
    cmd('steam-direct', '1')
    flag_controller(offline: true)
    response = cmd('disable')
    eq(true, response['pending_restart'])
    eq(STEAM_OFF, response['steam_direct'])
    eq(@initial, runtime_config)
    before = [File.binread(@runtime), File.binread(@settings), tmp_backups]
    eq('CONTROLLER_UNAVAILABLE', cmd('steam-direct', '1', ok: false)['error'])
    eq(before, [File.binread(@runtime), File.binread(@settings), tmp_backups])
  end

  def test_steam_direct_failures_change_nothing
    before = File.binread(@runtime)
    flag_controller(reject_next_reload: true)
    eq('CONFIG_TEST_FAILED', cmd('steam-direct', '1', ok: false)['error'])
    eq(before, File.binread(@runtime))
    eq(0, controller['reloads'])
    [['fail_after_load', 'RELOAD_FAILED'], ['drop_steam_next_reload', 'VERIFY_FAILED']].each do |flag, token|
      flag_controller(flag => true)
      eq(token, cmd('steam-direct', '1', ok: false)['error'], flag)
      eq(before, File.binread(@runtime))
      eq('claude.ai', controller['rules'][0]['payload'])
    end
    check(!File.exist?(@settings))
    eq(STEAM_OFF, cmd('status')['steam_direct'])
    [['steam-direct'], ['steam-direct', '2'], ['steam-direct', 'on'], ['steam-direct', '1', '1']].each do |args|
      eq('ARGUMENT_INVALID', cmd(*args, ok: false)['error'], args.inspect)
    end
    global_mode = YAML.dump(@initial.merge('mode' => 'global'))
    File.write(@runtime, global_mode)
    eq('ROUTING_MODE_UNSUPPORTED', cmd('steam-direct', '1', ok: false)['error'])
    eq(global_mode, File.read(@runtime))
    check(!File.exist?(@settings))
    File.binwrite(@runtime, before)
    cmd('steam-direct', '1')
    hookfile = tmp_hook(@initial.merge('mode' => 'global'))
    hooked = File.binread(hookfile)
    eq('ROUTING_MODE_UNSUPPORTED', cmd('hook', '/tmp/MESL_yue.yaml', ok: false)['error'])
    eq(hooked, File.binread(hookfile))
  end

  def test_steam_switch_leaves_a_site_rule_awaiting_retest_untouched
    apply
    @nodes[0]['server'] = 'changed-selected.invalid'
    write_source(@nodes)
    clear_bench
    store_bench(eligible: false, row_error: 'PENDING')
    before = runtime_config
    stored = settings_json
    result = cmd('steam-direct', '1')
    eq(STEAM_ON, result['steam_direct'])
    eq('NODE_CHANGED', result['site_rules'][0]['error'])
    eq(before.merge('rules' => STEAM_BLOCK + before['rules']), runtime_config)
    updated = settings_json
    eq(stored['rules'], updated['rules'])
    eq(true, updated['steam_direct'])
    cmd('disable')
    eq(@initial, runtime_config)
  end

  # ----------------------------------------------------- refactor additions

  def test_summary_is_light_secret_free_and_has_no_node_list
    apply
    out, = run([RUBY, BACKEND, 'summary'])
    summary = jload(out)
    eq(%w[active_source applied enabled error last_action last_time ok pending_restart rules source sources steam_direct], summary.keys.sort)
    check(out.bytesize < 2048, "summary is #{out.bytesize} bytes")
    rule = summary['rules'][0]
    eq(true, rule['applied'])
    eq(true, rule['verified'])
    eq(@nodes[0]['name'], rule['selected_name'])
    eq(20.5, rule['median_ms'])
    eq('chatgpt', rule['target'])
    check(!File.directory?(@root + '/tmp/r3mini-site-bench'), 'summary never starts the benchmark helper')
    cmd('summary')
  end

  def test_nodes_view_reuses_index_cache_until_the_subscription_changes
    view = cmd('nodes', 'lian_li.yaml')
    eq(57, view['nodes'].length)
    check(view['nodes'].all? { |node| node['eligible'] })
    eq('chatgpt', view['target'])
    check(view['supported_regions'].include?('US'))
    cache = Dir.glob(@root + '/tmp/r3mini-chatgpt/index-*.json')
    eq(1, cache.length)
    eq(0o600, File.stat(cache[0]).mode & 0o777)
    index = jload(File.read(cache[0]))
    index['nodes'][1]['name'] = 'cached-name-proof'
    File.write(cache[0], jdump(index))
    eq('cached-name-proof', cmd('nodes', 'lian_li.yaml')['nodes'][1]['name'], 'the index cache is reused')
    write_source(@nodes + [{'name' => 'new-node', 'type' => 'vless', 'server' => 'new.invalid'}])
    fresh = cmd('nodes', 'lian_li.yaml')
    eq(58, fresh['nodes'].length)
    eq(@nodes[1]['name'], fresh['nodes'][1]['name'], 'a changed subscription rebuilds the index')
    check(fresh['nodes'][0]['eligible'], 'unchanged nodes keep their result after a refresh')
    check(!fresh['nodes'][57]['eligible'])
    site = cmd('nodes', 'lian_li.yaml', 'site:example.com')
    eq('site:example.com', site['target'])
    eq(nil, site['supported_regions'])
    check(site['nodes'].none? { |node| node['eligible'] })
    eq('TARGET_INVALID', cmd('nodes', 'lian_li.yaml', 'site:bad_domain', ok: false)['error'])
    eq('TARGET_INVALID', cmd('benchmark', 'lian_li.yaml', 'site:-x.com', ok: false)['error'])
  end

  def test_label_edit_and_removing_a_disabled_rule_skip_the_reload
    site = save_site('first', ['first.example.com'])
    reloads = controller['reloads']
    runtime_bytes = File.binread(@runtime)
    renamed = save_site('renamed', ['first.example.com'], id: site['id'])
    eq(false, renamed['reloaded'])
    eq([reloads, runtime_bytes], [controller['reloads'], File.binread(@runtime)])
    eq('renamed', settings_json['rules'][0]['label'])
    check(renamed['applied'])
    cmd('set-enabled', site['id'], '0')
    reloads = controller['reloads']
    removed = cmd('remove', site['id'])
    eq(false, removed['reloaded'])
    eq(reloads, controller['reloads'])
    eq([], settings_json['rules'])
  end

  def test_summary_names_the_active_openclash_config
    eq(nil, cmd('summary')['active_source'], 'the active config is not a subscription file here')
    write_source(@nodes, @root + '/etc/openclash/config/MESL_yue.yaml')
    summary = cmd('summary')
    eq('MESL_yue.yaml', summary['active_source'])
    eq('lian_li.yaml', summary['source'], 'the last saved source stays separate')
    check(summary['sources'].include?('MESL_yue.yaml'))
  end

  def test_blank_name_defaults_to_the_first_domain
    site = save_site('  ', ['https://Docs.Example.com/path', 'example.org'])
    eq('docs.example.com', settings_json['rules'][0]['label'])
    eq(['docs.example.com', 'example.org'], settings_json['rules'][0]['domains'])
    payload = {'domains' => ['example.net'], 'source' => 'lian_li.yaml', 'selected' => node_id(@nodes[1]['name']), 'enabled' => true}
    store_bench(target: 'site:example.net')
    cmd('save', jdump(payload))
    eq('example.net', settings_json['rules'].find { |r| r['domains'] == ['example.net'] }['label'])
    eq(site['id'], settings_json['rules'][0]['id'])
  end

  def test_live_edits_skip_core_test_and_keep_few_backups_in_ram
    7.times { |i| save_site("site #{i}", ["s#{i}.example.com"], index: i) }
    check(!File.exist?(@root + '/core-call.json'), 'mihomo -t does not run for live edits')
    eq(5, tmp_backups)
    check(!File.exist?(@root + '/etc/r3mini-chatgpt/backups'))
    eq(7, controller['reloads'])
  end

  def test_unrecognised_rules_layout_falls_back_to_the_exact_parser
    apply
    %w[plain reordered].each do |layout|
      flag_controller(rules_format: layout)
      check(cmd('summary')['applied'], "#{layout} layout")
    end
  end

  def test_identical_save_repairs_a_drifted_controller_without_rewriting_the_file
    site = save_site('site', ['example.com'])
    state = controller
    state['rules'] = state['rules'].reject { |rule| rule['proxy'].start_with?('R3Site-') }
    write_controller(state)
    check(!cmd('summary')['applied'])
    bytes = File.binread(@runtime)
    mtime = File.mtime(@runtime)
    again = save_site('site', ['example.com'], id: site['id'])
    eq(true, again['reloaded'])
    check(again['applied'])
    eq(bytes, File.binread(@runtime))
    eq(mtime, File.mtime(@runtime))
  end

  def test_offline_controller_refuses_enabling_without_touching_files
    flag_controller(offline: true)
    before = File.binread(@runtime)
    eq('CONTROLLER_UNAVAILABLE', save_site('site', ['example.com'], ok: false)['error'])
    eq(before, File.binread(@runtime))
    check(!File.exist?(@settings))
    eq(0, tmp_backups)
  end

  def test_proof_follows_the_rule_target
    clear_bench
    store_bench(target: 'site:example.com', country: nil)
    site = save_site('site', ['example.com'], bench: false)
    eq(true, site['site_rules'][0]['verified'])
    eq('site:example.com', settings_json['rules'][0]['node_validation']['target'])
    eq('BENCHMARK_REQUIRED', save_site('ChatGPT', ['chatgpt.com'], preset: 'chatgpt', index: 1, bench: false, ok: false)['error'])
    unverified = save_site('ChatGPT', ['chatgpt.com'], preset: 'chatgpt', index: 1, bench: false, unverified: true)
    rule = unverified['site_rules'].find { |entry| entry['preset'] == 'chatgpt' }
    eq(false, rule['verified'])
    eq(true, rule['unverified'])
    check(rule['applied'])
  end

  # ------------------------------------------------------- benchmark helper

  def bench_nodes(nodes, dns = {'proxy-server-nameserver' => ['1.1.1.1', 'https://invalid.test/dns-query#PROXY']})
    @nodes = nodes
    clear_bench
    write_source(nodes, @source, 'dns' => dns)
    File.write(@root + '/etc/openclash/Country.mmdb', 'fake-geodata')
  end

  def finish(target = nil, ids = [])
    started = mono
    args = ['start', 'lian_li.yaml']
    args << target if target
    hcli(*(args + ids))
    check(mono - started < 4, 'start returns without waiting for probes')
    deadline = mono + 60
    loop do
      args = ['status', 'lian_li.yaml']
      args << target if target
      result = hcli(*args)
      unless result['running']
        eq(nil, result['error'], 'job error')
        return result
      end
      raise AssertionFailed, 'async benchmark did not complete' if mono > deadline
      sleep 0.2
    end
  end

  def alive_cores
    Dir.glob(@root + '/mock-ports/*.bin').count do |manifest|
      File.exist?('/proc/' + Marshal.load(File.binread(manifest))['pid'].to_s)
    rescue StandardError
      false
    end
  end

  def test_bench_actual_country_three_samples_and_private_cleanup
    bench_nodes([{'name' => '美国 "A"\\测试', 'type' => 'vless', 'server' => 'secret.invalid', 'uuid' => 'private-secret'}])
    result = finish
    row = result['results'][0]
    eq('US', row['country'])
    eq([300.0, 100.0, 200.0], row['samples_ms'])
    eq(200.0, row['median_ms'])
    eq(true, row['eligible'])
    eq(row['id'], result['best'])
    eq(Digest::SHA256.file(@source).hexdigest, result['source_sha256'])
    eq(result['results'], result['nodes'])
    state = Dir.glob(@root + '/tmp/r3mini-site-bench/*/state.json')[0]
    eq(0o600, File.stat(state).mode & 0o777)
    eq(0o700, File.stat(File.dirname(state)).mode & 0o777)
    eq([], Dir.glob(File.dirname(state) + '/run-*'))
    eq(0, alive_cores, 'probe cores are stopped')
    eq({'gid' => @gid, 'egid' => @gid}, jload(File.read(@root + '/core-gid-proof.json')))
    stored = Dir.glob(@root + '/etc/r3mini-chatgpt/bench/*.json')
    eq(1, stored.length)
    eq(0o600, File.stat(stored[0]).mode & 0o777)
  end

  def test_bench_https_only_bootstrap_omits_empty_default_nameserver
    bootstrap = ['https://dns.example.test/dns-query', 'https://resolver.example.test/dns-query']
    bench_nodes([{'name' => 'node-a', 'type' => 'vless'}], {'proxy-server-nameserver' => bootstrap})
    File.write(@root + '/mock-bootstrap.yaml', YAML.dump(bootstrap))
    check(finish['results'][0]['eligible'])
    dns = jload(File.read(@root + '/core-dns-proof.yaml'))
    eq(bootstrap, dns['proxy-server-nameserver'])
    eq(bootstrap, dns['nameserver'])
    check(!dns.key?('default-nameserver'))
  end

  def test_bench_missing_proxy_server_nameserver_falls_back_to_default_nameserver
    plain = ['223.5.5.5', '119.29.29.29']
    bench_nodes([{'name' => 'node-a', 'type' => 'vless'}],
                {'default-nameserver' => plain, 'nameserver' => ['https://provider.example.test/api-query']})
    File.write(@root + '/mock-bootstrap.yaml', YAML.dump(plain))
    check(finish['results'][0]['eligible'])
    dns = jload(File.read(@root + '/core-dns-proof.yaml'))
    eq(true, dns['enable'])
    eq(plain, dns['proxy-server-nameserver'])
    eq(plain, dns['nameserver'])
    eq(plain, dns['default-nameserver'])
  end

  def test_bench_country_not_node_name_determines_eligibility_and_best
    bench_nodes([
      {'name' => '香港名称但美国出口', 'type' => 'vless', 'mock-country' => 'US', 'mock-samples' => [0.9, 0.1, 0.2]},
      {'name' => '美国名称但香港出口', 'type' => 'vless', 'mock-country' => 'HK'},
      {'name' => '日本稳定较快', 'type' => 'vless', 'mock-country' => 'JP', 'mock-samples' => [0.15, 0.16, 0.17]},
      {'name' => 'country-changes', 'type' => 'vless', 'mock-country' => %w[US JP US]},
      {'name' => 'api-blocked', 'type' => 'vless', 'mock-api-code' => 403},
      {'name' => 'tls-fails', 'type' => 'vless', 'mock-tls-fail' => true}
    ])
    result = finish
    rows = result['results'].map { |row| [row['name'], row] }.to_h
    eq(node_id('日本稳定较快'), result['best'])
    check(rows['香港名称但美国出口']['eligible'])
    eq('UNSUPPORTED_REGION', rows['美国名称但香港出口']['error'])
    eq('REGION_CHANGED', rows['country-changes']['error'])
    eq('UNSUPPORTED_REGION', rows['api-blocked']['error'])
    eq('TLS_FAILED', rows['tls-fails']['error'])
  end

  def test_bench_partial_rerun_keeps_every_other_result
    bench_nodes((0...4).map { |i| {'name' => "node-#{i}", 'type' => 'vless', 'mock-samples' => [0.3 + i * 0.01, 0.1, 0.2]} })
    first = finish
    check(first['results'].all? { |row| row['eligible'] })
    tested = first['results'].map { |row| [row['id'], row['tested_epoch']] }.to_h
    sleep 1.1
    picked = node_id('node-2')
    partial = finish(nil, [picked])
    eq([picked], partial['run_ids'])
    eq([1, 1], [partial['total'], partial['done']])
    eq(4, partial['results'].length)
    check(partial['results'].all? { |row| row['eligible'] }, 'a partial rerun keeps every other row')
    partial['results'].each do |row|
      if row['id'] == picked
        check(row['tested_epoch'] > tested[row['id']], 'the picked node is retested')
      else
        eq(tested[row['id']], row['tested_epoch'], row['name'])
      end
    end
  end

  def test_bench_results_survive_losing_tmp
    bench_nodes([{'name' => 'node-a', 'type' => 'vless'}])
    finish
    rm_rf(@root + '/tmp/r3mini-site-bench')
    result = hcli('status', 'lian_li.yaml')
    check(result['results'][0]['eligible'], 'a reboot keeps the last results')
    eq(false, result['running'])
    eq(result['results'][0]['id'], result['best'])
  end

  def test_bench_subscription_refresh_keeps_unchanged_nodes_only
    dns = {'proxy-server-nameserver' => ['1.1.1.1']}
    bench_nodes([{'name' => 'stays', 'type' => 'vless'}, {'name' => 'moves', 'type' => 'vless', 'mock-port-hint' => 'a'}], dns)
    finish
    @nodes[1]['mock-port-hint'] = 'b'
    write_source(@nodes, @source, 'dns' => dns)
    result = hcli('status', 'lian_li.yaml')
    rows = result['results'].map { |row| [row['name'], row] }.to_h
    check(rows['stays']['eligible'])
    eq(false, rows['moves']['eligible'])
    eq('PENDING', rows['moves']['error'])
    eq(nil, result['error'])
  end

  def test_bench_stale_rows_are_shown_but_never_best
    bench_nodes([{'name' => 'node-a', 'type' => 'vless'}])
    finish
    file = Dir.glob(@root + '/etc/r3mini-chatgpt/bench/*.json')[0]
    state = jload(File.read(file))
    state['results'].each { |row| row['tested_epoch'] -= 8 * 86_400 }
    File.write(file, jdump(state))
    rm_rf(@root + '/tmp/r3mini-site-bench')
    result = hcli('status', 'lian_li.yaml')
    eq(true, result['results'][0]['stale'])
    eq(nil, result['best'])
    a = {'name' => 'a', 'type' => 'vless', 'x' => {'z' => 1, 'a' => 2}}
    b = {'x' => {'a' => 2, 'z' => 1}, 'type' => 'vless', 'name' => 'b'}
    eq(R3MiniSiteBench.node_hash(a), R3MiniSiteBench.node_hash(b))
  end

  def test_bench_duplicate_start_and_global_concurrency
    bench_nodes((0...5).map { |i| {'name' => "node-#{i}", 'type' => 'vless', 'mock-curl-delay' => 0.15} })
    eq(true, hcli('start', 'lian_li.yaml')['running'])
    eq(true, hcli('start', 'lian_li.yaml')['already_running'])
    File.write(@root + '/etc/openclash/config/other.yaml', File.read(@source))
    eq('BENCH_BUSY', hcli('start', 'other.yaml', ok: false)['error'])
    maximum = 0
    deadline = mono + 40
    while mono < deadline
      maximum = [maximum, alive_cores].max
      break unless hcli('status', 'lian_li.yaml')['running']
      sleep 0.1
    end
    eq(2, maximum, 'two probe cores at most')
  end

  def test_bench_paths_and_symlink_are_rejected
    ['../secret.yaml', '/etc/a.yaml', 'a\\b.yaml', 'foo.json', "a\nyaml.yaml"].each do |name|
      eq('SOURCE_INVALID', hcli('status', name, ok: false)['error'], name.inspect)
    end
    File.symlink(@source, @root + '/etc/openclash/config/link.yaml')
    eq('SOURCE_MISSING', hcli('status', 'link.yaml', ok: false)['error'])
    eq('TARGET_INVALID', hcli('status', 'lian_li.yaml', 'site:x', ok: false)['error'])
  end

  def test_bench_configured_region_allowlist_and_dependent_node
    regions = @root + '/usr/share/r3mini-site-routing'
    mkdir_p(regions)
    File.write(regions + '/supported-regions.json', jdump({'countries' => ['JP']}))
    bench_nodes([{'name' => 'actual-us', 'type' => 'vless'}, {'name' => 'actual-jp', 'type' => 'vless', 'mock-country' => 'JP'},
                 {'name' => 'dependent', 'type' => 'vless', 'dialer-proxy' => 'production-node'}])
    result = finish
    rows = result['results'].map { |row| [row['name'], row] }.to_h
    check(!rows['actual-us']['eligible'])
    check(rows['actual-jp']['eligible'])
    eq('NODE_DEPENDENCY', rows['dependent']['error'])
    eq(node_id('actual-jp'), result['best'])
  end

  def test_bench_site_target_measures_the_site_without_region_gate
    bench_nodes([{'name' => 'hk-node', 'type' => 'vless', 'mock-country' => 'HK', 'mock-site-code' => 403}])
    result = finish('site:example.com')
    row = result['results'][0]
    check(row['eligible'], row.inspect)
    eq(3, row['samples_ms'].length)
    eq(nil, row['country'])
    eq(['HEAD https://example.com/'] * 3, File.readlines(@root + '/probe-urls.log', chomp: true))
    eq('site:example.com', result['target'])
    eq(false, hcli('status', 'lian_li.yaml')['results'][0]['eligible'], 'site results never count for ChatGPT')
  end

  def test_bench_dead_coordinator_is_detected_and_orphan_core_cleaned
    bench_nodes([{'name' => 'slow', 'type' => 'vless', 'mock-curl-delay' => 1.0}])
    hcli('start', 'lian_li.yaml')
    deadline = mono + 8
    sleep 0.05 while mono < deadline && alive_cores.zero?
    state = jload(File.read(Dir.glob(@root + '/tmp/r3mini-site-bench/*/state.json')[0]))
    Process.kill('KILL', state['pid'])
    sleep 0.2
    result = hcli('status', 'lian_li.yaml')
    eq('BENCH_INTERRUPTED', result['error'])
    eq(false, result['running'])
    eq('BENCH_INTERRUPTED', result['results'][0]['error'])
    eq([], Dir.glob(@root + '/tmp/r3mini-site-bench/*/run-*'))
    sleep 0.3
    eq(0, alive_cores, 'the orphaned probe core is stopped')
  end
end

names = Case.instance_methods(false).grep(/\Atest_/).sort
names = names.select { |name| name.to_s.include?(FILTER) } if FILTER && !FILTER.empty?
failures = []
started = mono
names.each do |name|
  test = Case.new
  t0 = mono
  begin
    test.setup
    test.public_send(name)
    puts format('PASS %-78s %5.1fs', name, mono - t0)
  rescue AssertionFailed, StandardError, ScriptError => error
    failures << name
    detail = error.is_a?(AssertionFailed) ? error.message : "#{error.class}: #{error.message} @ #{error.backtrace&.first}"
    puts format('FAIL %-78s %5.1fs', name, mono - t0)
    puts '     ' + detail.gsub("\n", "\n     ")
    core = test.core_log
    puts '     mock core: ' + core.split("\n").last(6).join(' | ') if core
  ensure
    begin
      test.teardown
    rescue StandardError => error
      puts "     teardown: #{error.class}: #{error.message}"
    end
  end
  $stdout.flush
end
puts format('%d tests, %d failed, %.0f s', names.length, failures.length, mono - started)
puts failures.empty? ? 'SUITE_OK' : 'SUITE_FAILED ' + failures.join(' ')
exit(failures.empty? ? 0 : 1)
