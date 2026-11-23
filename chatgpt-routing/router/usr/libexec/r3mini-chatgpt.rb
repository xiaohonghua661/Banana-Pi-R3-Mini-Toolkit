#!/usr/bin/ruby
# frozen_string_literal: true

# OpenWrt's OpenClash Ruby installation is intentionally small.  Only these two
# packaged libraries are required; JSON, HTTP and filesystem helpers stay local.
require 'yaml'
require 'digest/sha2'

module R3MiniChatGPT
  GROUP = 'ChatGPT-LianLi'
  NODE_PREFIX = 'r3mini-chatgpt-node-'
  DOMAINS = [
    ['DOMAIN-SUFFIX', 'chatgpt.com'],
    ['DOMAIN-SUFFIX', 'openai.com'],
    ['DOMAIN-SUFFIX', 'oaistatic.com'],
    ['DOMAIN-SUFFIX', 'oaiusercontent.com'],
    ['DOMAIN-SUFFIX', 'chatgpt.livekit.cloud'],
    ['DOMAIN-SUFFIX', 'openaiapi-site.azureedge.net'],
    ['DOMAIN-SUFFIX', 'openaicom.imgix.net'],
    ['DOMAIN', 'chat.openai.com.cdn.cloudflare.net'],
    ['DOMAIN', 'openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net'],
    ['DOMAIN', 'openai-api.arkoselabs.com'],
    ['DOMAIN', 'production-openaicom-storage.azureedge.net'],
    ['DOMAIN-KEYWORD', 'openai']
  ].freeze
  RULES = DOMAINS.map { |kind, domain| "#{kind},#{domain},#{GROUP}" }.freeze
  # Valve Corporation AS32590 IPv4 prefixes: RIPEstat announced-prefixes, queried
  # 2026-11-12, adjacent prefixes collapsed. Steam relays and game servers are
  # dialed by raw IP, which the domain rules cannot match.
  STEAM_PREFIXES = %w[
    45.121.184.0/24 103.10.124.0/23 103.28.54.0/24 146.66.152.0/24 146.66.155.0/24
    155.133.224.0/21 155.133.236.0/22 155.133.240.0/23 155.133.244.0/24 155.133.246.0/24
    155.133.248.0/22 155.133.252.0/24 155.133.254.0/23 162.254.192.0/21 185.25.180.0/24
    185.25.182.0/23 192.69.96.0/22 205.196.6.0/24 208.64.200.0/22 208.78.164.0/22
  ].freeze
  STEAM_RULES = (%w[DOMAIN-SUFFIX,steamserver.net,DIRECT DOMAIN-SUFFIX,steamcontent.com,DIRECT
                    DOMAIN,api.steampowered.com,DIRECT] +
                 STEAM_PREFIXES.map { |prefix| "IP-CIDR,#{prefix},DIRECT,no-resolve" }).freeze
  LIVE_TYPES = {'DOMAIN' => 'Domain', 'DOMAIN-SUFFIX' => 'DomainSuffix', 'DOMAIN-KEYWORD' => 'DomainKeyword',
                'IP-CIDR' => 'IPCIDR'}.freeze
  # The controller's /rules payload omits the no-resolve flag.
  STEAM_LIVE = STEAM_RULES.map { |rule| kind, payload, target = rule.split(','); [LIVE_TYPES[kind], payload, target] }.freeze
  PRESET_ID = Digest::SHA256.hexdigest('r3mini-chatgpt-preset')[0, 12]
  # Transaction backups live in RAM: they only matter until the reload is verified,
  # and a copy per save used to fill the flash overlay (85 copies, 37 MB, 2026-11-23).
  BACKUP_KEEP = 5
  # Live edits are validated by the controller's own parser (PUT /configs answers
  # 400 and keeps the old config), so the 5-7 s `mihomo -t` pass is skipped there.
  RELOAD_SECONDS = 6
  # mihomo /rules entries keep the Go struct field order: index, type, payload, proxy.
  RULE_RE = /\{(?:"index":\d+,)?"type":"((?:[^"\\]|\\.)*)","payload":"((?:[^"\\]|\\.)*)","proxy":"((?:[^"\\]|\\.)*)"/
  OWNED_NAME_RE = /"name":"(R3Site-[0-9a-f]{12}|r3mini-site-node-[0-9a-f]{12}-[0-9a-f]{16}|r3mini-chatgpt-node-[0-9a-f]{16}|ChatGPT-LianLi)"/
  # Only a verdict about the node itself revokes saved evidence; an interrupted or
  # overloaded benchmark says nothing about the node.
  VERDICT_ERRORS = %w[UNSUPPORTED_REGION REGION_CHANGED TLS_FAILED TRACE_FAILED API_UNAVAILABLE SITE_FAILED NODE_DEPENDENCY].freeze
  ERRORS = {
    'ARGUMENT_INVALID' => '命令参数无效，请刷新页面后重试。',
    'BUSY' => '另一个操作正在进行，请稍后重试。',
    'SOURCE_INVALID' => '订阅文件名无效。',
    'SOURCE_MISSING' => '订阅文件不存在或不是受允许的普通文件。',
    'SOURCE_YAML_INVALID' => '订阅 YAML 无效，未修改当前运行配置。',
    'SOURCE_NODES_INVALID' => '订阅节点列表无效或节点名称重复。',
    'NODE_MISSING' => '所选节点已不存在，请刷新节点列表。',
    'NODE_DEPENDENCY' => '所选节点依赖其他代理，无法作为独立专用节点使用。',
    'NAME_CONFLICT' => '现有配置已使用本模块的保留名称，未修改原有节点、分组或规则。',
    'RULE_MISSING' => '网站规则不存在，请刷新页面。',
    'DOMAIN_INVALID' => '网站地址无效，请填写域名或 HTTP/HTTPS 链接，不含端口或账号。',
    'DOMAIN_CONFLICT' => '此域名与另一条网站规则重叠，请修改原规则。',
    'TARGET_INVALID' => '测速目标无效，请刷新页面后重试。',
    'BENCHMARK_UNAVAILABLE' => '节点实测服务尚不可用。',
    'BENCHMARK_REQUIRED' => '此节点尚未通过支持地区及至少三轮 HTTPS 实测，请先测速。',
    'NODE_CHANGED' => '节点连接参数已变化，请重新实测后再启用。',
    'SETTINGS_INVALID' => '本模块设置文件无效。',
    'RUNTIME_MISSING' => '未找到当前 OpenClash 运行配置。',
    'RUNTIME_INVALID' => '当前 OpenClash 运行配置无效。',
    'ROUTING_MODE_UNSUPPORTED' => '当前 OpenClash 不是规则模式，专用分流无法生效。',
    'CONTROLLER_INVALID' => '当前配置没有可用的本机控制接口。',
    'CONTROLLER_UNAVAILABLE' => '无法读取 OpenClash 本机控制接口。',
    'CORE_MISSING' => '未找到 OpenClash Mihomo 内核。',
    'CORE_GROUP_MISSING' => '无法取得 OpenClash 内核专用组，未校验或加载候选配置。',
    'CONFIG_TEST_FAILED' => 'Mihomo 未通过候选配置校验，原配置已保留。',
    'RELOAD_FAILED' => 'OpenClash 未接受候选配置，已恢复原文件。',
    'VERIFY_FAILED' => '运行规则或节点核验不符，已恢复原配置。',
    'ROLLBACK_FAILED' => '恢复文件后重新加载失败，请检查 OpenClash；改前备份已保留。',
    'STATE_MISMATCH' => '运行状态与已保存的设置不一致。',
    'IO_FAILED' => '读取或保存失败，改前备份已保留。',
    'INTERNAL_ERROR' => '操作失败，未输出任何订阅凭据。'
  }.freeze
  ESCAPES = {'"' => '\\"', '\\' => '\\\\'}.freeze
  JSON_ESCAPES = {'b' => "\b", 'f' => "\f", 'n' => "\n", 'r' => "\r", 't' => "\t"}.freeze

  class Failure < StandardError
    attr_reader :token
    def initialize(token)
      @token = token
      super(token)
    end
  end

  # JSON output must not depend on the optional ruby-json package.
  def self.json(value)
    case value
    when Hash
      '{' + value.map { |k, v| json(k.to_s) + ':' + json(v) }.join(',') + '}'
    when Array then '[' + value.map { |v| json(v) }.join(',') + ']'
    when String then '"' + value.gsub(/["\\\x00-\x1f]/) { |c| ESCAPES[c] || format('\\u%04x', c.ord) } + '"'
    when true then 'true'
    when false then 'false'
    when nil then 'null'
    when Integer then value.to_s
    when Float then value.finite? ? value.to_s : 'null'
    else raise Failure, 'INTERNAL_ERROR'
    end
  end

  def self.unescape(text)
    return text unless text.include?('\\')
    text.gsub(/\\(?:u([0-9a-fA-F]{4})|(.))/m) { $1 ? [$1.hex].pack('U') : JSON_ESCAPES.fetch($2, $2) }
  end

  class App
    def initialize
      sandbox = ENV['R3MINI_CHATGPT_ROOT']
      @root = sandbox && !sandbox.empty? ? File.realpath(sandbox) : ''
      raise Failure, 'ARGUMENT_INVALID' if @root == '/'
      @base = path('/etc/openclash')
      @sources = path('/etc/openclash/config')
      @state = path('/etc/r3mini-chatgpt')
      @settings_path = @state + '/settings.json'
      @temp = path('/tmp/r3mini-chatgpt')
      @started = monotonic
      @timings = {}
    end

    def path(absolute)
      @root + absolute
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def timed(key)
      start = monotonic
      yield
    ensure
      @timings[key] = ((monotonic - start) * 1000).round
    end

    def utc_now
      Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    end

    def fail!(token)
      raise Failure, token
    end

    def parse(bytes, token)
      YAML.safe_load(bytes, permitted_classes: [], permitted_symbols: [], aliases: true)
    rescue StandardError
      fail!(token)
    end

    def read(pathname, token, limit = 32 * 1024 * 1024)
      fail!(token) unless File.lstat(pathname).file? && File.size(pathname) <= limit
      File.binread(pathname).force_encoding(Encoding::UTF_8)
    rescue SystemCallError
      fail!(token)
    end

    def mkdir_private(dir)
      Dir.mkdir(dir, 0700) unless File.exist?(dir)
      fail!('IO_FAILED') unless File.lstat(dir).directory? && !File.symlink?(dir)
      File.chmod(0700, dir)
    end

    def random_suffix
      File.binread('/dev/urandom', 8).unpack('H*')[0]
    end

    def temporary(dir, suffix)
      pathname = "#{dir}/.r3mini-chatgpt-#{Process.pid}-#{random_suffix}#{suffix}"
      File.open(pathname, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| yield f }
      pathname
    end

    def atomic_write(destination, bytes)
      candidate = temporary(File.dirname(destination), '.tmp') { |f| f.write(bytes); f.flush; f.fsync }
      File.rename(candidate, destination)
      File.chmod(0600, destination)
    ensure
      File.unlink(candidate) if candidate && File.exist?(candidate)
    end

    def settings
      result = {'version' => 2, 'rules' => [], 'enabled' => false, 'source' => 'lian_li.yaml', 'selected' => nil,
                'last_action' => nil, 'last_time' => nil, 'steam_direct' => false}
      return result unless File.exist?(@settings_path)
      loaded = parse(read(@settings_path, 'SETTINGS_INVALID', 512 * 1024), 'SETTINGS_INVALID')
      fail!('SETTINGS_INVALID') unless loaded.is_a?(Hash)
      unless loaded.key?('rules')
        loaded['rules'] = loaded['selected'] ? [{
          'id' => PRESET_ID, 'label' => 'ChatGPT / OpenAI', 'preset' => 'chatgpt',
          'domains' => DOMAINS.reject { |kind, _| kind == 'DOMAIN-KEYWORD' }.map { |_, domain| domain }.uniq,
          'source' => loaded['source'], 'selected' => loaded['selected'], 'enabled' => loaded['enabled'] == true
        }] : []
      end
      result.merge!(loaded)
      source_name(result['source'])
      fail!('SETTINGS_INVALID') unless result['rules'].is_a?(Array) && result['rules'].length <= 20
      ids = {}
      result['rules'].each do |rule|
        validate_rule(rule)
        fail!('SETTINGS_INVALID') if ids[rule['id']]
        ids[rule['id']] = true
      end
      check_domains(result['rules'])
      result['version'] = 2
      result['enabled'] = result['rules'].any? { |r| r['enabled'] }
      fail!('SETTINGS_INVALID') unless result['rule_errors'].nil? || result['rule_errors'].is_a?(Hash)
      fail!('SETTINGS_INVALID') unless [true, false].include?(result['steam_direct'])
      result
    end

    def normalize_domain(value)
      fail!('DOMAIN_INVALID') unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 2048
      value = value.strip.downcase
      if value.match?(/\Ahttps?:\/\//)
        value = value.sub(/\Ahttps?:\/\//, '').split(/[\/?#]/, 2)[0].to_s
      end
      value = value.sub(/\A\*\./, '').sub(/\.\z/, '')
      labels = value.split('.', -1)
      fail!('DOMAIN_INVALID') unless value.bytesize.between?(4, 253) && labels.length >= 2 &&
        labels.all? { |label| label.bytesize.between?(1, 63) && label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/) } &&
        labels[-1].match?(/[a-z]/) && labels[-1].length >= 2
      value
    end

    def display_text?(value)
      value.nil? || value.is_a?(String) && value.bytesize <= 512 && value.valid_encoding? && value !~ /[\x00-\x1f\x7f]/
    end

    def validate_rule(rule)
      fail!('SETTINGS_INVALID') unless rule.is_a?(Hash) && rule['id'].is_a?(String) &&
        rule['id'].match?(/\A[0-9a-f]{12}\z/) && rule['label'].is_a?(String) &&
        rule['label'].bytesize.between?(1, 160) && rule['label'] !~ /[\x00-\x1f\x7f]/ &&
        rule['domains'].is_a?(Array) && rule['domains'].length.between?(1, 30) &&
        [true, false].include?(rule['enabled']) && rule['selected'].is_a?(String) &&
        rule['selected'].match?(/\A[0-9a-f]{16}\z/) && ['', 'chatgpt', nil].include?(rule['preset']) &&
        display_text?(rule['selected_name']) && display_text?(rule['updated_at'])
      source_name(rule['source'])
      rule['domains'].each { |domain| fail!('DOMAIN_INVALID') unless normalize_domain(domain) == domain }
    end

    def check_domains(rules)
      rules.each_with_index do |left, index|
        rules[(index + 1)..-1].each do |right|
          domain_pairs(left).reject { |kind, _| kind == 'DOMAIN-KEYWORD' }.map { |_, domain| domain }.each do |a|
            domain_pairs(right).reject { |kind, _| kind == 'DOMAIN-KEYWORD' }.map { |_, domain| domain }.each do |b|
              fail!('DOMAIN_CONFLICT') if a == b || a.end_with?('.' + b) || b.end_with?('.' + a)
            end
          end
        end
      end
    end

    def group_name(rule)
      'R3Site-' + rule['id']
    end

    def node_name(rule)
      'r3mini-site-node-' + rule['id'] + '-' + rule['selected']
    end

    # The leading flag pair identifies a region without trusting the label text.
    def node_region(name)
      prefix = name.is_a?(String) ? name.byteslice(0, 8) : nil
      return nil unless prefix && prefix.valid_encoding? &&
        prefix.match?(/\A[\u{1F1E6}-\u{1F1FF}]{2}\z/)
      prefix
    end

    def domain_pairs(rule)
      pairs = rule['domains'].map { |domain| ['DOMAIN-SUFFIX', domain] }
      return pairs unless rule['preset'] == 'chatgpt'
      # Preserve exact OpenAI CDN matches while accepting additional sites.
      DOMAINS + pairs.reject { |_, domain| DOMAINS.any? { |_, builtin| builtin == domain } }
    end

    def generated_rules(rule)
      domain_pairs(rule).map { |kind, domain| "#{kind},#{domain},#{group_name(rule)}" }
    end

    # The ChatGPT preset is measured against chatgpt.com and its supported
    # regions; every other site is measured against its own first domain.
    def target_of(rule)
      rule['preset'] == 'chatgpt' ? 'chatgpt' : 'site:' + rule['domains'][0]
    end

    def target_arg(value)
      return 'chatgpt' if value == 'chatgpt'
      fail!('TARGET_INVALID') unless value.is_a?(String) && value.start_with?('site:')
      domain = value[5..-1]
      normalized = begin
        normalize_domain(domain)
      rescue Failure
        nil
      end
      fail!('TARGET_INVALID') unless normalized == domain
      value
    end

    def source_name(name)
      fail!('SOURCE_INVALID') unless name.is_a?(String) && name.bytesize.between?(6, 255) &&
        name.valid_encoding? && name !~ /[\x00-\x1f\x7f\\\/]/ &&
        name != '.' && name != '..' && name.match?(/\.(yaml|yml)\z/)
      name
    end

    def source_path(name)
      source_name(name)
      candidate = @sources + '/' + name
      fail!('SOURCE_MISSING') unless File.lstat(candidate).file? &&
        File.dirname(File.realpath(candidate)) == File.realpath(@sources)
      candidate
    rescue SystemCallError
      fail!('SOURCE_MISSING')
    end

    def source_files
      return [] unless File.directory?(@sources)
      Dir.children(@sources).sort.select do |name|
        begin
          source_path(name)
          true
        rescue Failure
          false
        end
      end
    end

    def source_snapshot(name)
      @source_cache ||= {}
      return @source_cache[name] if @source_cache.key?(name)
      bytes = read(source_path(name), 'SOURCE_YAML_INVALID')
      sha256 = Digest::SHA256.hexdigest(bytes)
      config = parse(bytes, 'SOURCE_YAML_INVALID')
      fail!('SOURCE_NODES_INVALID') unless config.is_a?(Hash) && config['proxies'].is_a?(Array)
      seen = {}
      entries = config['proxies'].map do |node|
        fail!('SOURCE_NODES_INVALID') unless node.is_a?(Hash) && node['name'].is_a?(String) &&
          node['name'].bytesize.between?(1, 512) && node['name'] !~ /[\x00-\x1f\x7f]/ &&
          node['type'].is_a?(String) && node['type'].match?(/\A[a-zA-Z0-9-]{1,40}\z/)
        id = Digest::SHA256.hexdigest(node['name'])[0, 16]
        fail!('SOURCE_NODES_INVALID') if seen[id]
        seen[id] = true
        [id, node]
      end
      @source_cache[name] = {'sha256' => sha256, 'nodes' => entries}
    end

    def nodes(name)
      source_snapshot(name)['nodes']
    end

    def dependent?(node)
      node.key?('dialer-proxy') && ![nil, ''].include?(node['dialer-proxy'])
    end

    # id/name/type/fingerprint of every node, cached per subscription digest so a
    # page read never re-parses a 450 KB subscription.
    def source_index(name)
      @source_index ||= {}
      return @source_index[name] if @source_index.key?(name)
      sha = Digest::SHA256.file(source_path(name)).hexdigest
      cache = "#{@temp}/index-#{Digest::SHA256.hexdigest(name)[0, 16]}.json"
      index = nil
      if File.file?(cache) && !File.symlink?(cache)
        begin
          loaded = parse(read(cache, 'IO_FAILED', 8 * 1024 * 1024), 'IO_FAILED')
          index = loaded if loaded.is_a?(Hash) && loaded['version'] == 1 && loaded['source'] == name &&
                            loaded['sha256'] == sha && loaded['nodes'].is_a?(Array)
        rescue Failure
          index = nil
        end
      end
      unless index
        snapshot = source_snapshot(name)
        index = {'version' => 1, 'source' => name, 'sha256' => snapshot['sha256'], 'nodes' => snapshot['nodes'].map { |id, node|
          {'id' => id, 'name' => node['name'], 'type' => node['type'], 'node_hash' => node_hash(node), 'dependent' => dependent?(node)}
        }}
        begin
          mkdir_private(@temp)
          atomic_write(cache, R3MiniChatGPT.json(index))
        rescue Failure, SystemCallError
          nil
        end
      end
      @source_index[name] = index
    end

    def index_entry(rule)
      entry = source_index(rule['source'])['nodes'].find { |node| node['id'] == rule['selected'] }
      fail!('NODE_MISSING') unless entry
      fail!('NODE_DEPENDENCY') if entry['dependent']
      entry
    end

    def selected_node(s)
      found = nodes(s['source']).find { |id, _node| id == s['selected'] }
      fail!('NODE_MISSING') unless found
      node = found[1]
      fail!('NODE_DEPENDENCY') if dependent?(node)
      node
    end

    def canonical(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) { |key, result| result[key] = canonical(value[key]) }
      when Array then value.map { |item| canonical(item) }
      else value
      end
    end

    def node_hash(node)
      @node_hashes ||= {}.compare_by_identity
      @node_hashes[node] ||= Digest::SHA256.hexdigest(YAML.dump(canonical(node.reject { |key, _| key == 'name' })))
    end

    def bench
      @bench ||= begin
        helper = path('/usr/libexec/r3mini-site-bench.rb')
        fail!('BENCHMARK_UNAVAILABLE') unless File.lstat(helper).file?
        require helper
        R3MiniSiteBench.new
      rescue LoadError, SystemCallError
        fail!('BENCHMARK_UNAVAILABLE')
      end
    end

    def bench_report(source, target = 'chatgpt')
      @bench_reports ||= {}
      @bench_reports[source + "\n" + target] ||= begin
        index = source_index(source)
        bench.report(source, target, index['sha256'], index['nodes'])
      rescue Failure => error
        {'ok' => false, 'error' => error.token, 'nodes' => [], 'results' => [], 'best' => nil, 'running' => false}
      rescue StandardError => error
        token = defined?(R3MiniSiteBench::Failure) && error.is_a?(R3MiniSiteBench::Failure) ? error.message : 'BENCHMARK_UNAVAILABLE'
        {'ok' => false, 'error' => token, 'nodes' => [], 'results' => [], 'best' => nil, 'running' => false}
      end
    end

    def start_benchmark(source, target, ids)
      source_path(source)
      helper = path('/usr/libexec/r3mini-site-bench.rb')
      fail!('BENCHMARK_UNAVAILABLE') unless File.lstat(helper).file?
      argv = ['/usr/bin/ruby', helper, 'start', source, target] + ids
      output = IO.popen(argv, err: '/dev/null') { |io| io.read(4 * 1024 * 1024 + 1) } || ''
      fail!('BENCHMARK_UNAVAILABLE') if output.bytesize > 4 * 1024 * 1024
      result = parse(output, 'BENCHMARK_UNAVAILABLE')
      fail!('BENCHMARK_UNAVAILABLE') unless result.is_a?(Hash) && [true, false].include?(result['ok'])
      result
    rescue SystemCallError
      fail!('BENCHMARK_UNAVAILABLE')
    end

    def measured_node(source, id, target = 'chatgpt')
      @bench_indexes ||= {}
      @bench_indexes[source + "\n" + target] ||= (bench_report(source, target)['results'] || []).each_with_object({}) do |entry, index|
        index[entry['id']] = entry if entry.is_a?(Hash) && entry['id'].is_a?(String)
      end
      @bench_indexes[source + "\n" + target][id]
    end

    def valid_proof?(proof, fingerprint, chatgpt = true)
      return false unless proof.is_a?(Hash) && proof['eligible'] == true && proof['node_hash'] == fingerprint &&
        proof['samples_ms'].is_a?(Array) && proof['samples_ms'].length == 3 &&
        proof['samples_ms'].all? { |v| v.is_a?(Numeric) && v > 0 && v.finite? } &&
        proof['median_ms'].is_a?(Numeric) && proof['median_ms'] > 0 && proof['median_ms'].finite? &&
        proof['median_ms'] == proof['samples_ms'].sort[1]
      return true unless chatgpt
      [nil, 'chatgpt'].include?(proof['target']) &&
        proof['country'].is_a?(String) && proof['country'].match?(/\A[A-Z]{2}\z/) &&
        supported_regions.include?(proof['country'])
    end

    def supported_regions
      @supported_regions ||= begin
        bench.supported_regions
      rescue StandardError
        []
      end
    end

    def core_gid
      gid = bench.core_gid
      fail!('CORE_GROUP_MISSING') unless gid.is_a?(Integer) && gid.between?(1, 4_294_967_294)
      gid
    rescue Failure
      fail!('CORE_GROUP_MISSING')
    rescue LoadError, StandardError
      fail!('CORE_GROUP_MISSING')
    end

    def node_proof(source, id, fingerprint, s, target = 'chatgpt')
      chatgpt = target == 'chatgpt'
      matching_rules = (s['rules'] || []).select { |rule| rule['source'] == source && rule['selected'] == id }
      persisted = matching_rules.map { |rule| rule['node_validation'] }.find { |proof| valid_proof?(proof, fingerprint, chatgpt) }
      known_failed = matching_rules.any? { |rule|
        ['BENCHMARK_REQUIRED', 'NODE_CHANGED'].include?((s['rule_errors'] || {})[rule['id']])
      }
      report = bench_report(source, target)
      result = measured_node(source, id, target)
      # A finished, current retest supersedes saved proof even when it fails;
      # untested, stale or interrupted rows leave the saved proof in place.
      current = report['ok'] && result.is_a?(Hash) && result['node_hash'] == fingerprint && !result['stale']
      completed = current && (result['eligible'] == true || VERDICT_ERRORS.include?(result['error']))
      return known_failed ? nil : persisted unless completed
      return nil unless valid_proof?(result.merge('target' => target), fingerprint, chatgpt)
      {'eligible' => true, 'node_hash' => fingerprint, 'country' => result['country'],
       'samples_ms' => result['samples_ms'], 'median_ms' => result['median_ms'], 'target' => target,
       'source_sha256' => report['source_sha256'], 'tested_at' => result['tested_at'] || report['finished_at']}
    end

    def require_node_proof(rule, s)
      # Explicit operator opt-out: keep the node without a probe, marked so the
      # UI and status output can show it as unverified instead of gating it.
      return {'unverified' => true} if rule['unverified'] == true
      entry = index_entry(rule)
      proof = node_proof(rule['source'], rule['selected'], entry['node_hash'], s, target_of(rule))
      unless proof
        previous = (s['rules'] || []).find { |r| r['id'] == rule['id'] }
        old = rule['node_validation'] || previous && previous['node_validation']
        changed = old.is_a?(Hash) && old['node_hash'].is_a?(String) && old['node_hash'] != entry['node_hash']
        fail!(changed ? 'NODE_CHANGED' : 'BENCHMARK_REQUIRED')
      end
      proof
    end

    def active_basename
      uci = path('/sbin/uci')
      fail!('RUNTIME_MISSING') unless File.executable?(uci)
      ['openclash.@overwrite[0].config_path', 'openclash.config.config_path'].each do |key|
        value = IO.popen([uci, '-q', 'get', key], err: '/dev/null', &:read).strip
        next if value.empty?
        return source_name(File.basename(value))
      end
      fail!('RUNTIME_MISSING')
    end

    def runtime_path(logical = nil, hook = false)
      basename = active_basename
      logical ||= '/etc/openclash/' + basename
      allowed = ['/etc/openclash/' + basename]
      allowed << '/tmp/' + basename if hook
      fail!('RUNTIME_MISSING') unless logical.is_a?(String) && allowed.include?(logical)
      candidate = path(logical)
      fail!('RUNTIME_MISSING') unless File.lstat(candidate).file? &&
        File.dirname(File.realpath(candidate)) == File.realpath(path(File.dirname(logical)))
      candidate
    rescue SystemCallError
      fail!('RUNTIME_MISSING')
    end

    def runtime(file)
      config = parse(read(file, 'RUNTIME_INVALID'), 'RUNTIME_INVALID')
      fail!('RUNTIME_INVALID') unless config.is_a?(Hash)
      {'proxies' => Hash, 'proxy-groups' => Hash, 'rules' => String}.each do |key, type|
        fail!('RUNTIME_INVALID') unless config[key].nil? ||
          config[key].is_a?(Array) && config[key].all? { |item| item.is_a?(type) }
      end
      config
    end

    # The two top-level scalars the controller needs, without parsing the whole
    # runtime; anything unusual falls back to the full parse.
    def controller_config(file)
      found = {}
      File.foreach(file, encoding: 'UTF-8') do |line|
        key = line[/\A(external-controller|secret):/, 1]
        next unless key
        value = parse(line, 'RUNTIME_INVALID')
        found[key] = value[key] if value.is_a?(Hash)
        break if found.length == 2
      end
      found['external-controller'].is_a?(String) ? found : runtime(file)
    rescue SystemCallError
      fail!('RUNTIME_MISSING')
    end

    def owned_node?(name)
      name.is_a?(String) && name.match?(/\A(?:r3mini-chatgpt-node-[0-9a-f]{16}|r3mini-site-node-[0-9a-f]{12}-[0-9a-f]{16})\z/)
    end

    def owned_group?(name)
      name == GROUP || name.is_a?(String) && name.match?(/\AR3Site-[0-9a-f]{12}\z/)
    end

    def owned_rule?(rule)
      parts = rule.split(',').map(&:strip)
      owned_group?(parts[2])
    end

    def check_namespace(config, s)
      reserved_nodes = (config['proxies'] || []).select { |n| owned_node?(n['name']) }
      reserved_groups = (config['proxy-groups'] || []).select { |g| owned_group?(g['name']) }
      reserved_rules = (config['rules'] || []).select { |r| owned_rule?(r) }
      return if reserved_nodes.empty? && reserved_groups.empty? && reserved_rules.empty?
      # A saved selection alone does not prove ownership of an existing name.
      fail!('NAME_CONFLICT') unless s['enabled'] && s['owned'] == true
      enabled = (s['rules'] || []).select { |r| r['enabled'] }
      aliases = enabled.map { |r| node_name(r) }
      permitted_rules = enabled.flat_map { |r| generated_rules(r) }
      # Migration accepts the previous module's strict one-node template.
      legacy = enabled.find { |r| r['preset'] == 'chatgpt' }
      aliases << NODE_PREFIX + legacy['selected'] if legacy
      permitted_rules += RULES if legacy
      own_prefixes = enabled.map { |r| 'r3mini-site-node-' + r['id'] + '-' }
      fail!('NAME_CONFLICT') unless reserved_nodes.all? do |n|
          aliases.include?(n['name']) ||
            own_prefixes.any? do |prefix|
              n['name'].start_with?(prefix) && n['name'].match?(/\A#{Regexp.escape(prefix)}[0-9a-f]{16}\z/)
            end
        end &&
        reserved_nodes.map { |n| n['name'] }.uniq.length == reserved_nodes.length &&
        reserved_groups.map { |g| g['name'] }.uniq.length == reserved_groups.length &&
        reserved_rules.all? { |r| permitted_rules.include?(r) }
      reserved_groups.each do |group|
        rule = enabled.find { |r| group_name(r) == group['name'] }
        rule = legacy if group['name'] == GROUP
        fail!('NAME_CONFLICT') unless rule
        alias_name = group['name'] == GROUP ? NODE_PREFIX + rule['selected'] : node_name(rule)
        closed_group = {'name' => group['name'], 'type' => 'select', 'proxies' => ['REJECT']}
        recorded_error = (s['rule_errors'] || {})[rule['id']] || s['error']
        next if recorded_error && group == closed_group
        if group['name'] == GROUP
          normal = {'name' => group['name'], 'type' => 'select', 'proxies' => [alias_name]}
          fail!('NAME_CONFLICT') unless group == normal
        else
          own_prefix = 'r3mini-site-node-' + rule['id'] + '-'
          familiar = group.is_a?(Hash) && group['type'].is_a?(String) &&
            %w[select fallback].include?(group['type']) &&
            group['proxies'].is_a?(Array) && group['proxies'].include?(alias_name) &&
            group['proxies'].all? do |name|
              name == alias_name || name.is_a?(String) &&
                name.match?(/\A#{Regexp.escape(own_prefix)}[0-9a-f]{16}\z/)
            end
          fail!('NAME_CONFLICT') unless familiar
        end
      end
    end

    def routing_mode!(config)
      mode = config['mode']
      fail!('ROUTING_MODE_UNSUPPORTED') unless mode.nil? || mode.is_a?(String) && mode.downcase == 'rule'
    end

    # The Steam block belongs to this module only while it is intact at the very
    # top; look-alike rules anywhere else are the user's own and stay untouched.
    def steam_block?(rules)
      rules.is_a?(Array) && rules.first(STEAM_RULES.length) == STEAM_RULES
    end

    def without_steam(rules)
      steam_block?(rules) ? rules.drop(STEAM_RULES.length) : rules
    end

    def transform(config, s, closed = {})
      result = config.dup
      result['proxies'] = (config['proxies'] || []).reject { |n| owned_node?(n['name']) }
      result['proxy-groups'] = (config['proxy-groups'] || []).reject { |g| owned_group?(g['name']) }
      result['rules'] = without_steam(config['rules'] || []).reject { |r| owned_rule?(r) }
      prefix = []
      (s['rules'] || []).select { |r| r['enabled'] }.each do |rule|
        routing_mode!(config)
        members = []
        if closed[rule['id']]
          target = 'REJECT'
        else
          original = selected_node(rule)
          node = original.dup
          node['name'] = node_name(rule)
          result['proxies'] << node
          target = node['name']
          members << target
          # Same-region siblings ride along so a dead primary fails over in place.
          region = node_region(original['name'])
          if region
            siblings = nodes(rule['source']).
              reject { |id, _sibling| id == rule['selected'] }.
              select do |id, sibling|
                next false unless node_region(sibling['name']) == region &&
                  !sibling.key?('dialer-proxy') && !sibling.key?('proxy')
                # Only promote siblings a current benchmark actually proved usable.
                measured = measured_node(rule['source'], id, target_of(rule))
                measured.is_a?(Hash) && measured['eligible'] == true && !measured['stale']
              end.first(2)
            siblings.each do |id, sibling|
              copy = sibling.dup
              copy['name'] = 'r3mini-site-node-' + rule['id'] + '-' + id
              result['proxies'] << copy
              members << copy['name']
            end
          end
        end
        if members.length > 1
          # Health checks stay off chatgpt.com: probing it from three nodes every
          # 30s adds rate-limit pressure to the very host we are protecting.
          result['proxy-groups'] << {'name' => group_name(rule), 'type' => 'fallback',
                                     'url' => 'http://www.gstatic.com/generate_204',
                                     'interval' => 20, 'timeout' => 3000, 'proxies' => members}
        else
          result['proxy-groups'] << {'name' => group_name(rule), 'type' => 'select', 'proxies' => [target]}
        end
        prefix += generated_rules(rule)
      end
      routing_mode!(config) if s['steam_direct']
      # Steam goes first so a broader site rule (e.g. steampowered.com) cannot take its hosts.
      result['rules'] = (s['steam_direct'] ? STEAM_RULES : []) + prefix + result['rules']
      result
    end

    def controller_call(config, method, route, body = nil, seconds = 2)
      address = config['external-controller']
      fail!('CONTROLLER_INVALID') unless address.is_a?(String) &&
        address.match?(/\A(?:\[[0-9a-fA-F:]+\]|[A-Za-z0-9_.-]+):[0-9]{1,5}\z/)
      port = address.split(':')[-1].to_i
      fail!('CONTROLLER_INVALID') unless port.between?(1, 65535)
      secret = config['secret'] || ''
      fail!('CONTROLLER_INVALID') unless secret.is_a?(String) && secret !~ /[\x00-\x1f\x7f]/
      host = address.start_with?('[') ? '[::1]' : '127.0.0.1'
      mkdir_private(@temp)
      header = temporary(@temp, '.headers') { |f| f.write("Authorization: Bearer #{secret}\nContent-Type: application/json\n") }
      bodyfile = temporary(@temp, '.body') { |f| f.write(R3MiniChatGPT.json(body)) } if body
      curl = path('/usr/bin/curl')
      fail!('CONTROLLER_UNAVAILABLE') unless File.executable?(curl)
      argv = [curl, '-q', '--silent', '--noproxy', '*', '--connect-timeout', '2', '--max-time', seconds.to_s,
              '--header', '@' + header, '--request', method, '--write-out', "\n%{http_code}"]
      argv += ['--data-binary', '@' + bodyfile] if bodyfile
      argv << "http://#{host}:#{port}#{route}"
      output = IO.popen(argv, err: '/dev/null') { |io| io.read(16 * 1024 * 1024 + 16) } || ''
      success = $?.success?
      fail!('CONTROLLER_UNAVAILABLE') if output.bytesize > 16 * 1024 * 1024
      text, _, code = output.rpartition("\n")
      [success, code.to_i, text]
    ensure
      [header, bodyfile].compact.each { |f| File.unlink(f) if File.exist?(f) }
    end

    def controller(config, method, route, raw = false)
      success, code, text = controller_call(config, method, route)
      fail!('CONTROLLER_UNAVAILABLE') unless success && code.between?(200, 299)
      return text if raw
      return {} if text.strip.empty?
      result = parse(text, 'CONTROLLER_UNAVAILABLE')
      fail!('CONTROLLER_UNAVAILABLE') unless result.is_a?(Hash)
      result
    end

    # Scans the 800 KB /rules body instead of parsing it (2.6 s -> 0.1 s on the
    # router); any entry the pattern misses falls back to the exact parser.
    def parse_rules(raw)
      rules = []
      raw.scan(RULE_RE) do |type, payload, proxy|
        rules << {'type' => R3MiniChatGPT.unescape(type), 'payload' => R3MiniChatGPT.unescape(payload),
                  'proxy' => R3MiniChatGPT.unescape(proxy)}
      end
      return rules if raw.lstrip.start_with?('{') && rules.length == raw.scan('"payload":').length
      data = parse(raw, 'CONTROLLER_UNAVAILABLE')
      fail!('CONTROLLER_UNAVAILABLE') unless data.is_a?(Hash) && data['rules'].is_a?(Array)
      data['rules']
    end

    # Only this module's names matter for verification: list them from /proxies
    # and fetch each owned group on its own instead of parsing every proxy.
    def live_snapshot(config)
      rules = parse_rules(controller(config, 'GET', '/rules', true))
      raw = controller(config, 'GET', '/proxies', true)
      fail!('CONTROLLER_UNAVAILABLE') unless raw.lstrip.start_with?('{')
      proxies = {}
      raw.scan(OWNED_NAME_RE) { |(name)| proxies[name] ||= {} }
      proxies.keys.select { |name| owned_group?(name) }.each do |name|
        group = controller(config, 'GET', '/proxies/' + name)
        fail!('CONTROLLER_UNAVAILABLE') unless group.is_a?(Hash)
        proxies[name] = group
      end
      {'proxies' => proxies, 'rules' => rules}
    end

    def expected_live_rules(rule)
      domain_pairs(rule).map { |kind, domain| [LIVE_TYPES[kind], domain, group_name(rule)] }
    end

    def live_rule_tuple(rule)
      rule.is_a?(Hash) ? [rule['type'], rule['payload'], rule['proxy']] : nil
    end

    def steam_live?(snapshot)
      snapshot['rules'].first(STEAM_LIVE.length).map { |r| live_rule_tuple(r) } == STEAM_LIVE
    end

    def live_rule_matches?(snapshot, rule)
      proxies = snapshot['proxies']
      group = proxies[group_name(rule)]
      alias_name = node_name(rule)
      # A fallback group lists the primary plus same-region siblings.
      return false unless group.is_a?(Hash) && group['all'].is_a?(Array) &&
        group['all'].include?(alias_name) && group['all'].all? { |name| proxies.key?(name) } &&
        group['all'].include?(group['now']) && proxies.key?(alias_name)
      snapshot['rules'].select { |r| r.is_a?(Hash) && r['proxy'] == group_name(rule) }.map { |r| live_rule_tuple(r) } == expected_live_rules(rule)
    end

    def snapshot_matches?(snapshot, s)
      active = (s['rules'] || []).select { |r| r['enabled'] }
      return false unless active.all? { |r| live_rule_matches?(snapshot, r) }
      expected = active.flat_map { |r| expected_live_rules(r) }
      # Site rules come right after a loaded Steam block.
      offset = steam_live?(snapshot) ? STEAM_LIVE.length : 0
      actual = snapshot['rules'].drop(offset).first(expected.length).map { |r| live_rule_tuple(r) }
      proxies = snapshot['proxies']
      owned_nodes = proxies.keys.select { |n| owned_node?(n) }
      actual == expected &&
        proxies.keys.select { |n| owned_group?(n) }.sort == active.map { |r| group_name(r) }.sort &&
        owned_nodes.all? do |name|
          active.any? { |rule| name.start_with?('r3mini-site-node-' + rule['id'] + '-') }
        end &&
        active.all? { |rule| owned_nodes.include?(node_name(rule)) } &&
        snapshot['rules'].count { |r| r.is_a?(Hash) && owned_group?(r['proxy']) } == expected.length
    end

    def rule_view(rule, s)
      entry = nil
      error = nil
      begin
        entry = index_entry(rule)
      rescue Failure => e
        error = e.token
      end
      proof = nil
      if rule['enabled'] && entry
        begin
          proof = require_node_proof(rule, s)
        rescue Failure => e
          error = e.token
        end
      end
      error = rule['enabled'] ? (s['rule_errors'] || {})[rule['id']] || error : nil
      target = target_of(rule)
      shown = proof if proof.is_a?(Hash) && proof['eligible'] == true
      saved = rule['node_validation']
      shown ||= saved if entry && saved.is_a?(Hash) && saved['eligible'] == true && saved['node_hash'] == entry['node_hash']
      measured = entry && measured_node(rule['source'], rule['selected'], target)
      measured = nil unless measured.is_a?(Hash) && measured['eligible'] == true && !measured['stale']
      latest = [shown, measured].compact.max_by { |p| p['tested_at'].to_s }
      {'id' => rule['id'], 'label' => rule['label'], 'domains' => rule['domains'], 'preset' => rule['preset'] || '',
       'source' => rule['source'], 'selected' => rule['selected'],
       'selected_name' => entry ? entry['name'] : rule['selected_name'],
       'enabled' => rule['enabled'], 'applied' => false, 'error' => error,
       'verified' => !shown.nil?, 'unverified' => rule['unverified'] == true, 'target' => target,
       'median_ms' => latest && latest['median_ms'], 'country' => latest && latest['country'],
       'tested_at' => latest && latest['tested_at']}
    end

    # Light state for the page: no subscription parse, no helper process, no node list.
    def summary(snapshot = nil)
      s = settings
      live_error = nil
      if snapshot.nil?
        begin
          snapshot = timed('live_ms') { live_snapshot(controller_config(runtime_path)) }
        rescue Failure => e
          live_error = e.token
          snapshot = false
        end
      elsif snapshot == false
        live_error = 'CONTROLLER_UNAVAILABLE'
      end
      rules = s['rules'].map { |rule| rule_view(rule, s) }
      error = rules.find { |r| r['enabled'] && r['error'] }
      error = error && error['error']
      matches = false
      if snapshot
        matches = snapshot_matches?(snapshot, s)
        rules.each_with_index do |view, index|
          next unless view['enabled']
          view['applied'] = !view['error'] && live_rule_matches?(snapshot, s['rules'][index])
          view['error'] ||= 'STATE_MISMATCH' unless view['applied']
        end
        error ||= 'STATE_MISMATCH' unless matches
      else
        error ||= live_error
        rules.each { |view| view['error'] ||= live_error if view['enabled'] }
      end
      pending_restart = s['pending_restart'] == true && !matches
      error = nil if pending_restart && !s['enabled'] && error == 'CONTROLLER_UNAVAILABLE'
      applied = s['enabled'] && matches && rules.select { |r| r['enabled'] }.all? { |r| r['applied'] }
      sources = source_files
      # OpenClash's current config (users switch among several subscriptions); new rules default to it.
      active = begin
        active_basename
      rescue Failure
        nil
      end
      {'ok' => true, 'enabled' => s['enabled'], 'applied' => applied == true, 'error' => error,
       'pending_restart' => pending_restart,
       'steam_direct' => {'enabled' => s['steam_direct'], 'applied' => snapshot ? steam_live?(snapshot) : false},
       'source' => s['source'], 'sources' => sources, 'active_source' => sources.include?(active) ? active : nil,
       'rules' => rules,
       'last_action' => s['last_action'], 'last_time' => s['last_time']}
    end

    # Node picker data for one subscription, measured against one target.
    def nodes_view(source, target = 'chatgpt')
      s = settings
      index = source_index(source)
      report = bench_report(source, target)
      rows = index['nodes'].map do |entry|
        result = measured_node(source, entry['id'], target)
        result = nil unless result.is_a?(Hash) && result['node_hash'] == entry['node_hash']
        proof = node_proof(source, entry['id'], entry['node_hash'], s, target)
        shown = result && (result['eligible'] == true || result['error'] != 'PENDING') ? result : proof || {}
        {'id' => entry['id'], 'name' => entry['name'], 'type' => entry['type'], 'dependent' => entry['dependent'] == true,
         'eligible' => !proof.nil?, 'median_ms' => shown['median_ms'], 'samples_ms' => shown['samples_ms'] || [],
         'country' => shown['country'], 'error' => result && result['error'], 'tested_at' => shown['tested_at'],
         'stale' => result ? result['stale'] == true : false}
      end
      {'ok' => true, 'source' => source, 'target' => target, 'source_sha256' => index['sha256'], 'nodes' => rows,
       'benchmark' => {'ok' => report['ok'], 'running' => report['running'] == true, 'done' => report['done'] || 0,
                       'total' => report['total'] || 0, 'run_ids' => report['run_ids'] || [],
                       'started_at' => report['started_at'], 'finished_at' => report['finished_at'],
                       'error' => report['error']},
       'supported_regions' => target == 'chatgpt' ? supported_regions : nil}
    end

    # Unchanged output contract for gpt-night and manage.py verify.
    def status(source = nil)
      s = settings
      candidate = source || s['source']
      source_name(candidate)
      base = summary
      source_error = nil
      view = begin
        nodes_view(candidate, 'chatgpt')
      rescue Failure => e
        source_error = e.token
        nil
      end
      rules = base['rules']
      selected_site = rules.find { |r| r['preset'] == 'chatgpt' } || rules.find { |r| r['enabled'] } || rules.first
      backups = @temp + '/backups'
      {'ok' => true, 'enabled' => base['enabled'], 'applied' => base['applied'], 'source' => s['source'],
       'selected' => selected_site && selected_site['selected'],
       'selected_name' => selected_site && selected_site['selected_name'],
       'site_rules' => rules, 'steam_direct' => base['steam_direct'], 'sources' => base['sources'],
       'nodes' => view ? view['nodes'] : [],
       'benchmark' => view ? bench_report(candidate, 'chatgpt') : {'ok' => false, 'error' => source_error, 'nodes' => [],
                                                                   'results' => [], 'best' => nil, 'running' => false},
       'backup_count' => File.directory?(backups) ? Dir.children(backups).count { |n| File.directory?(backups + '/' + n) } : 0,
       'last_action' => s['last_action'], 'last_time' => s['last_time'], 'error' => base['error'],
       'source_error' => source_error, 'pending_restart' => base['pending_restart'],
       'runtime_group' => selected_site ? 'R3Site-' + selected_site['id'] : 'R3Site'}
    end

    def with_lock
      mkdir_private(@state)
      lockpath = path('/var/lock/r3mini-chatgpt.lock')
      fail!('IO_FAILED') if File.symlink?(lockpath)
      File.open(lockpath, File::RDWR | File::CREAT, 0600) do |lock|
        fail!('BUSY') unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
    end

    def erase(dir)
      return unless File.directory?(dir) && !File.symlink?(dir)
      Dir.children(dir).each do |name|
        file = dir + '/' + name
        File.unlink(file) if File.file?(file) || File.symlink?(file)
      end
      Dir.rmdir(dir)
    rescue SystemCallError
      nil
    end

    def backup(file)
      mkdir_private(@temp)
      root = @temp + '/backups'
      mkdir_private(root)
      dir = root + '/' + Time.now.utc.strftime('%Y%m%dT%H%M%SZ') + "-#{Process.pid}-#{random_suffix}"
      mkdir_private(dir)
      atomic_write(dir + '/runtime.yaml', File.binread(file))
      atomic_write(dir + '/runtime.mode', (File.stat(file).mode & 0777).to_s)
      if File.exist?(@settings_path)
        atomic_write(dir + '/settings.json', File.binread(@settings_path))
      else
        atomic_write(dir + '/settings.absent', '')
      end
      older = Dir.children(root).select { |n| n.match?(/\A\d{8}T\d{6}Z-\d+-[0-9a-f]{16}\z/) } - [File.basename(dir)]
      older.sort.reverse.drop(BACKUP_KEEP - 1).each { |name| erase(root + '/' + name) }
      dir
    end

    def validate(candidate)
      core = ['/etc/openclash/core/clash_meta', '/etc/openclash/core/mihomo', '/etc/openclash/core/clash'].map { |p| path(p) }.find { |p| File.executable?(p) && File.file?(p) }
      fail!('CORE_MISSING') unless core
      pid = Process.spawn({'SAFE_PATHS' => '/usr/share/openclash:/etc/ssl'},
                          core, '-t', '-d', @base, '-f', candidate, gid: core_gid, out: '/dev/null', err: '/dev/null')
      # 2026-10-26 measured 5.3/7.0/5.7 s for a 440 KB runtime; 7 s rejected saves under light load.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      loop do
        finished = Process.waitpid2(pid, Process::WNOHANG)
        if finished
          pid = nil
          fail!('CONFIG_TEST_FAILED') unless finished[1].success?
          return
        end
        fail!('CONFIG_TEST_FAILED') if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.025
      end
    ensure
      if pid
        begin
          Process.kill('KILL', pid)
          Process.waitpid(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end
      end
    end

    # 400 means the controller's parser rejected the file and kept the running
    # config; anything else (timeout, offline) leaves the outcome unknown.
    def reload(config, file)
      success, code, = controller_call(config, 'PUT', '/configs?force=true', {'path' => file}, RELOAD_SECONDS)
      return if success && code.between?(200, 299)
      fail!(success && code == 400 ? 'CONFIG_TEST_FAILED' : 'RELOAD_FAILED')
    rescue Failure => error
      raise if error.token == 'CONFIG_TEST_FAILED'
      fail!('RELOAD_FAILED')
    end

    def restore(file, saved, old_config, do_reload)
      atomic_write(file, File.binread(saved + '/runtime.yaml'))
      File.chmod(File.read(saved + '/runtime.mode').to_i, file)
      if File.exist?(saved + '/settings.json')
        atomic_write(@settings_path, File.binread(saved + '/settings.json'))
      elsif File.exist?(@settings_path)
        File.unlink(@settings_path)
      end
      reload(old_config, file) if do_reload
    rescue StandardError
      fail!('ROLLBACK_FAILED')
    end

    def finish_settings(desired, s, hook_errors, action, offline)
      desired['error'] = nil
      # Disabling a failed rule must not erase its revocation marker.
      # A newly successful validation for that same source/node clears it.
      successful_pairs = desired['rules'].select { |rule| rule['enabled'] && !hook_errors[rule['id']] }.
        map { |rule| [rule['source'], rule['selected']] }
      desired['rule_errors'] = (s['rule_errors'] || {}).select do |id, _error|
        rule = desired['rules'].find { |entry| entry['id'] == id }
        rule && !successful_pairs.include?([rule['source'], rule['selected']])
      end.merge(hook_errors)
      desired['owned'] = true
      desired['pending_restart'] = offline
      desired['last_action'] = hook_errors.empty? ? action : 'hook_failed'
      desired['last_time'] = utc_now
      atomic_write(@settings_path, R3MiniChatGPT.json(desired) + "\n")
    end

    def response(snapshot, affected_id, reloaded)
      result = summary(snapshot)
      result['site_rules'] = result['rules']
      result['id'] = affected_id if affected_id
      result['reloaded'] = reloaded
      result['timings'] = @timings
      result['elapsed_ms'] = ((monotonic - @started) * 1000).round
      result
    end

    # Used when nothing will load the file right now (OpenClash start hook,
    # controller offline): only here does `mihomo -t` guard the write.
    def write_validated(file, new_config, s, desired, hook_errors, action, offline, affected_id)
      saved = backup(file)
      changed = false
      begin
        candidate = temporary(File.dirname(file), '.yaml') { |f| f.write(YAML.dump(new_config)); f.flush; f.fsync }
        timed('validate_ms') { validate(candidate) }
        File.rename(candidate, file)
        changed = true
        File.chmod(0600, file)
        finish_settings(desired, s, hook_errors, action, offline)
      rescue StandardError => error
        restore(file, saved, nil, false) if changed
        raise error
      ensure
        File.unlink(candidate) if candidate && File.exist?(candidate)
      end
      unless hook_errors.empty?
        # Fail-closed fallback is intentional and must survive this error.
        hook_error = hook_errors.values.first
        return {'ok' => false, 'error' => hook_error, 'message' => ERRORS[hook_error], 'fail_closed' => true}
      end
      return {'ok' => true, 'action' => 'hook', 'changed' => true} if action == 'hook'
      result = response(false, affected_id, false)
      result['error'] = nil
      result['message'] = '已恢复磁盘规则，控制接口离线，OpenClash 下次启动时生效。'
      result
    end

    def apply_live(file, old_config, new_config, desired, s, action, affected_id)
      saved = backup(file)
      changed = false
      reloaded = false
      begin
        if new_config != old_config
          candidate = temporary(File.dirname(file), '.yaml') { |f| f.write(YAML.dump(new_config)); f.flush; f.fsync }
          File.rename(candidate, file)
          changed = true
          File.chmod(0600, file)
        end
        # Reload can fail after the controller has already loaded the file.
        reloaded = true
        timed('reload_ms') { reload(old_config, file) }
        snapshot = timed('verify_ms') { live_snapshot(new_config) }
        fail!('VERIFY_FAILED') unless snapshot_matches?(snapshot, desired) &&
          steam_live?(snapshot) == steam_block?(new_config['rules'])
        finish_settings(desired, s, {}, action, false)
        result = response(snapshot, affected_id, true)
        fail!('VERIFY_FAILED') if desired['enabled'] && !result['applied']
        result
      rescue StandardError => error
        rejected = error.is_a?(Failure) && error.token == 'CONFIG_TEST_FAILED'
        restore(file, saved, old_config, reloaded && !rejected) if changed || reloaded && !rejected
        raise error
      ensure
        File.unlink(candidate) if candidate && File.exist?(candidate)
      end
    end

    def mutate(action, source = nil, node_id = nil, hook_path = nil)
      with_lock do
        s = settings
        desired = Marshal.load(Marshal.dump(s))
        affected_id = nil
        if action == 'apply'
          source_name(source)
          fail!('ARGUMENT_INVALID') unless node_id.is_a?(String) && node_id.match?(/\A[0-9a-f]{16}\z/)
          rule = {'id' => PRESET_ID, 'label' => 'ChatGPT / OpenAI', 'preset' => 'chatgpt',
                  'domains' => DOMAINS.reject { |kind, _| kind == 'DOMAIN-KEYWORD' }.map { |_, domain| domain }.uniq,
                  'source' => source, 'selected' => node_id, 'enabled' => true}
          index = desired['rules'].index { |r| r['id'] == PRESET_ID || r['preset'] == 'chatgpt' }
          rule['id'] = desired['rules'][index]['id'] if index
          index ? desired['rules'][index] = rule : desired['rules'] << rule
          desired['source'] = source
          affected_id = rule['id']
        elsif action == 'save'
          fail!('ARGUMENT_INVALID') unless source.is_a?(String) && source.bytesize <= 16 * 1024 && source.lstrip.start_with?('{')
          payload = parse(source, 'ARGUMENT_INVALID')
          fail!('ARGUMENT_INVALID') unless payload.is_a?(Hash)
          affected_id = payload['id']
          if affected_id
            fail!('ARGUMENT_INVALID') unless affected_id.is_a?(String) && affected_id.match?(/\A[0-9a-f]{12}\z/)
            index = desired['rules'].index { |r| r['id'] == affected_id }
            fail!('RULE_MISSING') unless index
            previous = desired['rules'][index]
          else
            fail!('ARGUMENT_INVALID') if desired['rules'].length >= 20
            affected_id = random_suffix[0, 12]
            previous = {}
          end
          fail!('DOMAIN_INVALID') unless payload['domains'].is_a?(Array) && payload['domains'].length.between?(1, 30)
          domains = payload['domains'].map { |d| normalize_domain(d) }.uniq
          label = payload['label'].is_a?(String) ? payload['label'].strip : payload['label']
          # The page calls the name optional; a blank one used to fail as SETTINGS_INVALID.
          label = domains[0][0, 160] if label.nil? || label == ''
          rule = {'id' => affected_id, 'label' => label, 'domains' => domains,
                  'preset' => payload.key?('preset') ? payload['preset'] : previous['preset'] || '',
                  'source' => payload['source'], 'selected' => payload['selected'],
                  'unverified' => payload['unverified'] == true,
                  'enabled' => payload.key?('enabled') ? payload['enabled'] : true}
          validate_rule(rule)
          # Input errors first: a clashing domain is reported before any node or benchmark check.
          check_domains(desired['rules'].reject { |r| r['id'] == affected_id } + [rule])
          rule['selected_name'] = index_entry(rule)['name']
          rule['updated_at'] = utc_now
          rule['node_validation'] = require_node_proof(rule, s)
          index ? desired['rules'][index] = rule : desired['rules'] << rule
          desired['source'] = rule['source']
        elsif action == 'remove' || action == 'set-enabled'
          fail!('ARGUMENT_INVALID') unless source.is_a?(String) && source.match?(/\A[0-9a-f]{12}\z/)
          index = desired['rules'].index { |r| r['id'] == source }
          fail!('RULE_MISSING') unless index
          affected_id = source
          if action == 'remove'
            desired['rules'].delete_at(index)
          else
            fail!('ARGUMENT_INVALID') unless ['0', '1'].include?(node_id)
            desired['rules'][index]['enabled'] = node_id == '1'
          end
        elsif action == 'disable'
          # Restoring the original routing removes every module-owned rule.
          desired['rules'].each { |r| r['enabled'] = false }
          desired['steam_direct'] = false
        end
        desired['enabled'] = desired['rules'].any? { |r| r['enabled'] }
        desired['version'] = 2
        check_domains(desired['rules'])
        file = runtime_path(hook_path, action == 'hook')
        old_config = timed('parse_ms') { runtime(file) }
        check_namespace(old_config, s)
        hook_errors = {}
        desired['rules'].select { |r| r['enabled'] }.each do |rule|
          begin
            rule['node_validation'] = require_node_proof(rule, s)
          rescue Failure => error
            raise unless action == 'hook'
            hook_errors[rule['id']] = error.token
            rule.delete('node_validation') if ['BENCHMARK_REQUIRED', 'NODE_CHANGED'].include?(error.token)
          end
        end
        # OpenClash ignores hook exit status: failed sites use a sole REJECT
        # target while every unaffected site retains its chosen independent node.
        new_config = timed('transform_ms') { transform(old_config, desired, hook_errors) }
        if action == 'hook'
          return {'ok' => true, 'action' => 'hook', 'changed' => false} if hook_errors.empty? && new_config == old_config
          return write_validated(file, new_config, s, desired, hook_errors, action, false, nil)
        end
        live = begin
          timed('live_ms') { live_snapshot(old_config) }
        rescue Failure => error
          raise unless error.token == 'CONTROLLER_UNAVAILABLE'
          nil
        end
        unless live
          # Offline, only switching every site off is written; it loads at next start.
          fail!('CONTROLLER_UNAVAILABLE') if desired['enabled']
          return write_validated(file, new_config, s, desired, {}, action, true, affected_id)
        end
        if new_config == old_config && snapshot_matches?(live, desired) &&
           steam_live?(live) == steam_block?(old_config['rules'])
          # Labels, an identical save or a disabled rule's removal: settings only, no reload.
          finish_settings(desired, s, {}, action, false)
          return response(live, affected_id, false)
        end
        apply_live(file, old_config, new_config, desired, s, action, affected_id)
      end
    end

    # Touches only the Steam block, so a site rule waiting for a new benchmark
    # cannot block this switch; the hook still rebuilds everything at start.
    def steam_direct(value)
      fail!('ARGUMENT_INVALID') unless ['0', '1'].include?(value)
      enabled = value == '1'
      with_lock do
        s = settings
        file = runtime_path
        old_config = timed('parse_ms') { runtime(file) }
        routing_mode!(old_config) if enabled
        new_config = old_config.merge('rules' => (enabled ? STEAM_RULES : []) + without_steam(old_config['rules'] || []))
        # Read-only first: an offline controller fails here before anything is written.
        current = timed('live_ms') { live_snapshot(old_config) }
        # A successful reload from disk leaves no change waiting for a restart.
        desired = s.merge('steam_direct' => enabled, 'pending_restart' => false, 'last_action' => 'steam-direct',
                          'last_time' => utc_now)
        if new_config == old_config && steam_live?(current) == steam_block?(old_config['rules'])
          atomic_write(@settings_path, R3MiniChatGPT.json(desired) + "\n") unless s['steam_direct'] == enabled
          return response(current, nil, false)
        end
        saved = backup(file)
        changed = false
        reloaded = false
        begin
          if new_config != old_config
            candidate = temporary(File.dirname(file), '.yaml') { |f| f.write(YAML.dump(new_config)); f.flush; f.fsync }
            File.rename(candidate, file)
            changed = true
            File.chmod(0600, file)
          end
          reloaded = true
          timed('reload_ms') { reload(old_config, file) }
          snapshot = timed('verify_ms') { live_snapshot(new_config) }
          fail!('VERIFY_FAILED') unless steam_live?(snapshot) == steam_block?(new_config['rules'])
          atomic_write(@settings_path, R3MiniChatGPT.json(desired) + "\n")
          response(snapshot, nil, true)
        rescue StandardError => error
          rejected = error.is_a?(Failure) && error.token == 'CONFIG_TEST_FAILED'
          restore(file, saved, old_config, reloaded && !rejected) if changed || reloaded && !rejected
          raise error
        ensure
          File.unlink(candidate) if candidate && File.exist?(candidate)
        end
      end
    end

    def bench_args(argv)
      fail!('ARGUMENT_INVALID') unless argv.length.between?(2, 67)
      rest = argv[2..-1]
      target = rest.first && !rest.first.match?(/\A[0-9a-f]{16}\z/) ? target_arg(rest.shift) : 'chatgpt'
      fail!('ARGUMENT_INVALID') unless rest.length <= 64 && rest.all? { |id| id.match?(/\A[0-9a-f]{16}\z/) }
      [argv[1], target, rest]
    end

    def run(argv)
      command = argv[0]
      case command
      when 'summary'
        fail!('ARGUMENT_INVALID') unless argv.length == 1
        summary
      when 'nodes'
        fail!('ARGUMENT_INVALID') unless argv.length.between?(2, 3)
        source_path(argv[1])
        nodes_view(argv[1], argv[2] ? target_arg(argv[2]) : 'chatgpt')
      when 'status'
        fail!('ARGUMENT_INVALID') unless argv.length.between?(1, 2)
        status(argv[1])
      when 'apply'
        fail!('ARGUMENT_INVALID') unless argv.length == 3
        mutate('apply', argv[1], argv[2])
      when 'save', 'remove'
        fail!('ARGUMENT_INVALID') unless argv.length == 2
        mutate(command, argv[1])
      when 'benchmark'
        source, target, ids = bench_args(argv)
        start_benchmark(source, target, ids)
      when 'benchmark-status'
        source, target, ids = bench_args(argv)
        fail!('ARGUMENT_INVALID') unless ids.empty?
        source_path(source)
        bench_report(source, target)
      when 'set-enabled'
        fail!('ARGUMENT_INVALID') unless argv.length == 3
        mutate(command, argv[1], argv[2])
      when 'disable'
        fail!('ARGUMENT_INVALID') unless argv.length == 1
        mutate('disable')
      when 'steam-direct'
        fail!('ARGUMENT_INVALID') unless argv.length == 2
        steam_direct(argv[1])
      when 'hook'
        fail!('ARGUMENT_INVALID') unless argv.length == 2
        mutate('hook', nil, nil, argv[1])
      else
        fail!('ARGUMENT_INVALID')
      end
    end
  end

  def self.main(argv)
    result = App.new.run(argv)
    puts json(result)
    result['ok'] ? 0 : 1
  rescue Failure => e
    puts json({'ok' => false, 'error' => e.token, 'message' => ERRORS[e.token] || ERRORS['INTERNAL_ERROR']})
    1
  rescue SystemCallError, IOError
    puts json({'ok' => false, 'error' => 'IO_FAILED', 'message' => ERRORS['IO_FAILED']})
    1
  rescue StandardError
    puts json({'ok' => false, 'error' => 'INTERNAL_ERROR', 'message' => ERRORS['INTERNAL_ERROR']})
    1
  end
end

exit R3MiniChatGPT.main(ARGV) if $PROGRAM_NAME == __FILE__
