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
  PRESET_ID = Digest::SHA256.hexdigest('r3mini-chatgpt-preset')[0, 12]
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
    when String
      '"' + value.each_codepoint.map { |c|
        if c == 34 then '\\"'
        elsif c == 92 then '\\\\'
        elsif c < 32 then format('\\u%04x', c)
        else c.chr(Encoding::UTF_8)
        end
      }.join + '"'
    when true then 'true'
    when false then 'false'
    when nil then 'null'
    when Integer then value.to_s
    when Float then value.finite? ? value.to_s : 'null'
    else raise Failure, 'INTERNAL_ERROR'
    end
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
    end

    def path(absolute)
      @root + absolute
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
                'last_action' => nil, 'last_time' => nil}
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

    def validate_rule(rule)
      fail!('SETTINGS_INVALID') unless rule.is_a?(Hash) && rule['id'].is_a?(String) &&
        rule['id'].match?(/\A[0-9a-f]{12}\z/) && rule['label'].is_a?(String) &&
        rule['label'].bytesize.between?(1, 160) && rule['label'] !~ /[\x00-\x1f\x7f]/ &&
        rule['domains'].is_a?(Array) && rule['domains'].length.between?(1, 30) &&
        [true, false].include?(rule['enabled']) && rule['selected'].is_a?(String) &&
        rule['selected'].match?(/\A[0-9a-f]{16}\z/) && ['', 'chatgpt', nil].include?(rule['preset'])
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

    def selected_node(s)
      found = nodes(s['source']).find { |id, _node| id == s['selected'] }
      fail!('NODE_MISSING') unless found
      node = found[1]
      fail!('NODE_DEPENDENCY') if node.key?('dialer-proxy') && ![nil, ''].include?(node['dialer-proxy'])
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

    def benchmark(source, operation = 'status')
      source_path(source)
      helper = path('/usr/libexec/r3mini-site-bench.rb')
      fail!('BENCHMARK_UNAVAILABLE') unless File.lstat(helper).file?
      output = IO.popen(['/usr/bin/ruby', helper, operation, source], err: '/dev/null') { |io| io.read(4 * 1024 * 1024 + 1) } || ''
      fail!('BENCHMARK_UNAVAILABLE') if output.bytesize > 4 * 1024 * 1024
      result = parse(output, 'BENCHMARK_UNAVAILABLE')
      fail!('BENCHMARK_UNAVAILABLE') unless result.is_a?(Hash) && [true, false].include?(result['ok'])
      result
    rescue SystemCallError
      fail!('BENCHMARK_UNAVAILABLE')
    end

    def benchmark_status(source)
      @bench_cache ||= {}
      @bench_cache[source] ||= benchmark(source)
    rescue Failure => error
      @bench_cache[source] ||= {'ok' => false, 'error' => error.token, 'nodes' => [], 'results' => [], 'best' => nil, 'running' => false}
    end

    def measured_node(source, id)
      @bench_indexes ||= {}
      @bench_indexes[source] ||= begin
        report = benchmark_status(source)
        (report['nodes'] || report['results'] || []).each_with_object({}) do |entry, index|
          index[entry['id']] = entry if entry.is_a?(Hash) && entry['id'].is_a?(String)
        end
      end
      @bench_indexes[source][id]
    end

    def valid_proof?(proof, fingerprint)
      proof.is_a?(Hash) && proof['eligible'] == true && proof['node_hash'] == fingerprint &&
        proof['country'].is_a?(String) && proof['country'].match?(/\A[A-Z]{2}\z/) &&
        supported_regions.include?(proof['country']) &&
        proof['samples_ms'].is_a?(Array) && proof['samples_ms'].length == 3 &&
        proof['samples_ms'].all? { |v| v.is_a?(Numeric) && v > 0 && v.finite? } &&
        proof['median_ms'].is_a?(Numeric) && proof['median_ms'] > 0 && proof['median_ms'].finite? &&
        proof['median_ms'] == proof['samples_ms'].sort[1]
    end

    def supported_regions
      @supported_regions ||= begin
        helper = path('/usr/libexec/r3mini-site-bench.rb')
        require helper
        R3MiniSiteBench.new.supported_regions
      rescue LoadError, StandardError
        []
      end
    end

    def core_gid
      helper = path('/usr/libexec/r3mini-site-bench.rb')
      fail!('CORE_GROUP_MISSING') unless File.lstat(helper).file?
      require helper
      gid = R3MiniSiteBench.new.core_gid
      fail!('CORE_GROUP_MISSING') unless gid.is_a?(Integer) && gid.between?(1, 4_294_967_294)
      gid
    rescue LoadError, StandardError
      fail!('CORE_GROUP_MISSING')
    end

    def node_proof(source, node, s)
      fingerprint = node_hash(node)
      selected_id = Digest::SHA256.hexdigest(node['name'])[0, 16]
      matching_rules = (s['rules'] || []).select { |rule| rule['source'] == source && rule['selected'] == selected_id }
      persisted = matching_rules.map { |rule| rule['node_validation'] }.find { |proof| valid_proof?(proof, fingerprint) }
      known_failed = matching_rules.any? { |rule|
        ['BENCHMARK_REQUIRED', 'NODE_CHANGED'].include?((s['rule_errors'] || {})[rule['id']])
      }
      report = benchmark_status(source)
      actual_source_hash = source_snapshot(source)['sha256']
      result = measured_node(source, selected_id)
      # A completed, current retest supersedes saved proof even when it fails.
      # Empty/expired caches and a still-pending row may use saved validation.
      current = report['ok'] && report['source_sha256'] == actual_source_hash &&
        report['error'] != 'BENCH_EXPIRED' && result.is_a?(Hash) && result['node_hash'] == fingerprint
      completed = result.is_a?(Hash) && (result['eligible'] == true ||
        result['error'].is_a?(String) && !['', 'PENDING', 'BENCH_PENDING'].include?(result['error']) ||
        report['running'] == false && report['finished_at'].is_a?(String))
      return known_failed ? nil : persisted unless current && completed
      return nil unless !report['error'] && valid_proof?(result, fingerprint)
      {'eligible' => true, 'node_hash' => fingerprint, 'country' => result['country'],
       'samples_ms' => result['samples_ms'], 'median_ms' => result['median_ms'],
       'source_sha256' => actual_source_hash, 'tested_at' => report['finished_at'] || report['completed_at'] || report['updated_at'] || report['time']}
    end

    def require_node_proof(rule, s)
      node = selected_node(rule)
      proof = node_proof(rule['source'], node, s)
      unless proof
        previous = (s['rules'] || []).find { |r| r['id'] == rule['id'] }
        old = rule['node_validation'] || previous && previous['node_validation']
        fail!(old.is_a?(Hash) && old['node_hash'] != node_hash(node) ? 'NODE_CHANGED' : 'BENCHMARK_REQUIRED')
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

    def transform(config, s, closed = {})
      result = config.dup
      result['proxies'] = (config['proxies'] || []).reject { |n| owned_node?(n['name']) }
      result['proxy-groups'] = (config['proxy-groups'] || []).reject { |g| owned_group?(g['name']) }
      result['rules'] = (config['rules'] || []).reject { |r| owned_rule?(r) }
      prefix = []
      (s['rules'] || []).select { |r| r['enabled'] }.each do |rule|
        mode = config['mode']
        fail!('ROUTING_MODE_UNSUPPORTED') unless mode.nil? || mode.is_a?(String) && mode.downcase == 'rule'
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
                # Only promote siblings the benchmark actually proved usable.
                measured = measured_node(rule['source'], id)
                measured.is_a?(Hash) && measured['eligible'] == true
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
      result['rules'] = prefix + result['rules']
      result
    end

    def controller(config, method, route, body = nil)
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
      argv = [curl, '-q', '--silent', '--fail', '--noproxy', '*', '--connect-timeout', '2',
              '--max-time', '2', '--header', '@' + header, '--request', method]
      argv += ['--data-binary', '@' + bodyfile] if bodyfile
      argv << "http://#{host}:#{port}#{route}"
      output = IO.popen(argv, err: '/dev/null') { |io| io.read(2 * 1024 * 1024 + 1) } || ''
      fail!('CONTROLLER_UNAVAILABLE') unless $?.success? && output.bytesize <= 2 * 1024 * 1024
      return {} if output.strip.empty?
      result = parse(output, 'CONTROLLER_UNAVAILABLE')
      fail!('CONTROLLER_UNAVAILABLE') unless result.is_a?(Hash)
      result
    ensure
      [header, bodyfile].compact.each { |f| File.unlink(f) if File.exist?(f) }
    end

    def live_snapshot(config)
      proxies = controller(config, 'GET', '/proxies')['proxies']
      rules = controller(config, 'GET', '/rules')['rules']
      fail!('CONTROLLER_UNAVAILABLE') unless proxies.is_a?(Hash) && rules.is_a?(Array)
      {'proxies' => proxies, 'rules' => rules}
    end

    def expected_live_rules(rule)
      types = {'DOMAIN' => 'Domain', 'DOMAIN-SUFFIX' => 'DomainSuffix', 'DOMAIN-KEYWORD' => 'DomainKeyword'}
      domain_pairs(rule).map { |kind, domain| [types[kind], domain, group_name(rule)] }
    end

    def live_rule_tuple(rule)
      rule.is_a?(Hash) ? [rule['type'], rule['payload'], rule['proxy']] : nil
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
      actual = snapshot['rules'].first(expected.length).map { |r| live_rule_tuple(r) }
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

    def live_matches?(config, s)
      snapshot_matches?(live_snapshot(config), s)
    end

    def status(source = nil, verified_snapshot = nil)
      s = settings
      candidate_source = source || s['source']
      source_name(candidate_source)
      source_error = nil
      begin
        candidates = nodes(candidate_source)
      rescue Failure => e
        candidates = []
        source_error = e.token
      end
      site_status = s['rules'].map do |rule|
        selected_name = nil
        rule_error = nil
        begin
          selected_name = selected_node(rule)['name']
          require_node_proof(rule, s) if rule['enabled']
        rescue Failure => e
          rule_error = e.token if rule['enabled']
        end
        rule_error = (s['rule_errors'] || {})[rule['id']] || rule_error if rule['enabled']
        {'id' => rule['id'], 'label' => rule['label'], 'domains' => rule['domains'], 'preset' => rule['preset'] || '',
         'source' => rule['source'], 'selected' => rule['selected'], 'selected_name' => selected_name,
         'enabled' => rule['enabled'], 'applied' => false, 'error' => rule_error}
      end
      applied = false
      error = site_status.find { |r| r['enabled'] && r['error'] }
      error = error && error['error']
      pending_restart = s['pending_restart'] == true
      begin
        fail!('CONTROLLER_UNAVAILABLE') if verified_snapshot == false
        snapshot = verified_snapshot || live_snapshot(runtime(runtime_path))
        matches = snapshot_matches?(snapshot, s)
        pending_restart = false if matches
        site_status.each_with_index do |site, index|
          next unless site['enabled']
          site['applied'] = !site['error'] && live_rule_matches?(snapshot, s['rules'][index])
          site['error'] ||= 'STATE_MISMATCH' unless site['applied']
        end
        applied = s['enabled'] && matches && site_status.select { |r| r['enabled'] }.all? { |r| r['applied'] }
        error ||= 'STATE_MISMATCH' unless matches
      rescue Failure => e
        error ||= e.token
        site_status.each { |r| r['error'] ||= e.token if r['enabled'] }
      end
      error = nil if pending_restart && !s['enabled'] && error == 'CONTROLLER_UNAVAILABLE'
      selected_site = site_status.find { |r| r['preset'] == 'chatgpt' } ||
        site_status.find { |r| r['enabled'] } || site_status.first
      backups = @state + '/backups'
      bench = benchmark_status(candidate_source)
      {'ok' => true, 'enabled' => s['enabled'], 'applied' => applied, 'source' => s['source'],
       'selected' => selected_site && selected_site['selected'], 'selected_name' => selected_site && selected_site['selected_name'],
       'site_rules' => site_status,
       'sources' => source_files, 'nodes' => candidates.map { |id, n|
         proof = node_proof(candidate_source, n, s)
         measured = measured_node(candidate_source, id)
         display = proof || measured || {}
         {'id' => id, 'name' => n['name'], 'type' => n['type'], 'eligible' => !proof.nil?,
          'median_ms' => display['median_ms'], 'samples_ms' => display['samples_ms'] || [],
          'country' => display['country']}
       },
       'benchmark' => bench,
       'backup_count' => File.directory?(backups) ? Dir.children(backups).count { |n| File.directory?(backups + '/' + n) } : 0,
       'last_action' => s['last_action'], 'last_time' => s['last_time'], 'error' => error,
       'source_error' => source_error, 'pending_restart' => pending_restart,
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

    def backup(file)
      dir = @state + '/backups'
      mkdir_private(dir)
      dir += '/' + Time.now.utc.strftime('%Y%m%dT%H%M%SZ') + "-#{Process.pid}-#{random_suffix}"
      mkdir_private(dir)
      atomic_write(dir + '/runtime.yaml', File.binread(file))
      atomic_write(dir + '/runtime.mode', (File.stat(file).mode & 0777).to_s)
      if File.exist?(@settings_path)
        atomic_write(dir + '/settings.json', File.binread(@settings_path))
      else
        atomic_write(dir + '/settings.absent', '')
      end
      dir
    end

    def validate(candidate)
      core = ['/etc/openclash/core/clash_meta', '/etc/openclash/core/mihomo', '/etc/openclash/core/clash'].map { |p| path(p) }.find { |p| File.executable?(p) && File.file?(p) }
      fail!('CORE_MISSING') unless core
      pid = Process.spawn({'SAFE_PATHS' => '/usr/share/openclash:/etc/ssl'},
                          core, '-t', '-d', @base, '-f', candidate, gid: core_gid, out: '/dev/null', err: '/dev/null')
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 7
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

    def reload(config, file)
      controller(config, 'PUT', '/configs?force=true', {'path' => file})
    rescue Failure
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
          rule = {'id' => affected_id, 'label' => payload['label'],
                  'domains' => payload['domains'].map { |d| normalize_domain(d) }.uniq,
                  'preset' => payload.key?('preset') ? payload['preset'] : previous['preset'] || '',
                  'source' => payload['source'], 'selected' => payload['selected'],
                  'enabled' => payload.key?('enabled') ? payload['enabled'] : true}
          validate_rule(rule)
          selected_node(rule)
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
          desired['rules'].each { |r| r['enabled'] = false }
        end
        desired['enabled'] = desired['rules'].any? { |r| r['enabled'] }
        desired['version'] = 2
        check_domains(desired['rules'])
        file = runtime_path(hook_path, action == 'hook')
        old_config = runtime(file)
        check_namespace(old_config, s)
        hook_errors = {}
        if action == 'hook'
          desired['rules'].select { |r| r['enabled'] }.each do |rule|
            begin
              rule['node_validation'] = require_node_proof(rule, s)
            rescue Failure => error
              hook_errors[rule['id']] = error.token
              rule.delete('node_validation') if ['BENCHMARK_REQUIRED', 'NODE_CHANGED'].include?(error.token)
            end
          end
        else
          desired['rules'].select { |r| r['enabled'] }.each do |rule|
            rule['node_validation'] = require_node_proof(rule, s)
          end
        end
        # OpenClash ignores hook exit status: failed sites use a sole REJECT
        # target while every unaffected site retains its chosen independent node.
        new_config = transform(old_config, desired, hook_errors)
        if action == 'hook' && hook_errors.empty? && new_config == old_config
          return {'ok' => true, 'action' => 'hook', 'changed' => false}
        end
        offline_disable = false
        if action != 'hook' && !desired['enabled']
          begin
            controller(old_config, 'GET', '/proxies')
          rescue Failure => error
            raise unless error.token == 'CONTROLLER_UNAVAILABLE'
            offline_disable = true
          end
        end
        saved = backup(file)
        changed = false
        reloaded = false
        begin
          candidate = temporary(File.dirname(file), '.yaml') { |f| f.write(YAML.dump(new_config)); f.flush; f.fsync }
          validate(candidate)
          File.rename(candidate, file)
          changed = true
          File.chmod(0600, file)
          unless action == 'hook' || offline_disable
            # Reload can fail after the controller has already loaded the file.
            reloaded = true
            reload(old_config, file)
            verified_snapshot = live_snapshot(new_config)
            fail!('VERIFY_FAILED') unless snapshot_matches?(verified_snapshot, desired)
          end
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
          desired['pending_restart'] = offline_disable
          desired['last_action'] = hook_errors.empty? ? action : 'hook_failed'
          desired['last_time'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
          atomic_write(@settings_path, R3MiniChatGPT.json(desired) + "\n")
          verified_snapshot = false if offline_disable
          unless hook_errors.empty?
            # Fail-closed fallback is intentional and must survive this error.
            hook_error = hook_errors.values.first
            result = {'ok' => false, 'error' => hook_error, 'message' => ERRORS[hook_error],
             'fail_closed' => true}
          else
            result = nil
          end
          if result
            result
          elsif action == 'hook'
            {'ok' => true, 'action' => 'hook', 'changed' => true}
          else
            result = status(nil, verified_snapshot)
            fail!('VERIFY_FAILED') if desired['enabled'] && !result['applied']
            result['id'] = affected_id if affected_id
            if offline_disable
              result['error'] = nil
              result['message'] = '已恢复磁盘规则，控制接口离线，OpenClash 下次启动时生效。'
            end
            result
          end
        rescue StandardError => error
          restore(file, saved, old_config, reloaded) if changed
          raise error
        ensure
          File.unlink(candidate) if candidate && File.exist?(candidate)
        end
      end
    end

    def run(argv)
      command = argv[0]
      case command
      when 'status'
        fail!('ARGUMENT_INVALID') unless argv.length.between?(1, 2)
        status(argv[1])
      when 'apply'
        fail!('ARGUMENT_INVALID') unless argv.length == 3
        mutate('apply', argv[1], argv[2])
      when 'save', 'remove'
        fail!('ARGUMENT_INVALID') unless argv.length == 2
        mutate(command, argv[1])
      when 'benchmark', 'benchmark-status'
        fail!('ARGUMENT_INVALID') unless argv.length == 2
        command == 'benchmark' ? benchmark(argv[1], 'start') : benchmark_status(argv[1])
      when 'set-enabled'
        fail!('ARGUMENT_INVALID') unless argv.length == 3
        mutate(command, argv[1], argv[2])
      when 'disable'
        fail!('ARGUMENT_INVALID') unless argv.length == 1
        mutate('disable')
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
