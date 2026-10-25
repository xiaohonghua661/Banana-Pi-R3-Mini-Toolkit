#!/usr/bin/ruby
# frozen_string_literal: true

# Runs on the router's minimal Ruby: no JSON, Socket, Net::HTTP, FileUtils,
# Open3, Tempfile or external timeout/ss/stat package is needed.
require 'yaml'
require 'digest/sha2'

class R3MiniSiteBench
  TTL = 86_400
  CONCURRENCY = 2
  SUPPORTED_SOURCE = 'https://help.openai.com/en/articles/7947663-chatgpt-supported-countries'
  SUPPORTED_VERIFIED = '2026-10-25'
  # Conservative, verified subset; not a claim to enumerate every supported country.
  SUPPORTED = %w[US JP SG TW KR GB DE FR NL CA AU AT BE CH ES IT SE NO FI DK IE PT PL CZ NZ PH MY ID TH VN IN ZA BR MX AR CL TR IL AE SA].freeze
  RESULT_KEYS = %w[id name node_hash country samples_ms median_ms eligible error].freeze
  class Failure < StandardError; end

  def self.json(value)
    case value
    when Hash then '{' + value.map { |k, v| json(k.to_s) + ':' + json(v) }.join(',') + '}'
    when Array then '[' + value.map { |v| json(v) }.join(',') + ']'
    when String
      '"' + value.each_codepoint.map { |c|
        if c == 34 then '\\"'
        elsif c == 92 then '\\\\'
        elsif c < 32 then format('\\u%04x', c)
        else c.chr(Encoding::UTF_8)
        end
      }.join + '"'
    when Integer then value.to_s
    when Float then value.finite? ? value.to_s : 'null'
    when true then 'true'
    when false then 'false'
    when nil then 'null'
    else raise Failure, 'INTERNAL_ERROR'
    end
  end

  def self.sorted(value)
    case value
    when Hash then value.keys.sort_by(&:to_s).each_with_object({}) { |key, out| out[key] = sorted(value[key]) }
    when Array then value.map { |item| sorted(item) }
    else value
    end
  end

  def self.node_hash(node)
    Digest::SHA256.hexdigest(YAML.dump(sorted(node.reject { |key, _| key == 'name' })))
  end

  def initialize
    sandbox = ENV['R3MINI_CHATGPT_ROOT']
    @root = sandbox && !sandbox.empty? ? File.realpath(sandbox) : ''
    raise Failure, 'ARGUMENT_INVALID' if @root == '/'
    @base = path('/tmp/r3mini-site-bench')
    @sources = path('/etc/openclash/config')
    @owned = {}
    @ports = {}
    @guard = Mutex.new
    @bootstrap = []
  end

  def path(value); @root + value; end
  def now; Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'); end
  def monotonic; Process.clock_gettime(Process::CLOCK_MONOTONIC); end
  def random; File.binread('/dev/urandom', 12).unpack1('H*'); end

  def source_path(source)
    raise Failure, 'SOURCE_INVALID' unless source.is_a?(String) && source.valid_encoding? &&
      source.bytesize.between?(6, 255) && source !~ /[\x00-\x1f\x7f\\\/]/ && source.match?(/\.(yaml|yml)\z/)
    file = @sources + '/' + source
    raise Failure, 'SOURCE_MISSING' unless File.lstat(file).file? &&
      File.dirname(File.realpath(file)) == File.realpath(@sources)
    file
  rescue SystemCallError
    raise Failure, 'SOURCE_MISSING'
  end

  def source_data(source)
    file = source_path(source)
    raise Failure, 'SOURCE_YAML_INVALID' if File.size(file) > 32 * 1024 * 1024
    bytes = File.binread(file)
    config = YAML.safe_load(bytes.force_encoding(Encoding::UTF_8), permitted_classes: [], permitted_symbols: [], aliases: true)
    nodes = config.is_a?(Hash) && config['proxies']
    raise Failure, 'SOURCE_NODES_INVALID' unless nodes.is_a?(Array) && nodes.length.between?(1, 2000)
    names = {}
    nodes.each do |node|
      name = node.is_a?(Hash) && node['name']
      raise Failure, 'SOURCE_NODES_INVALID' unless name.is_a?(String) && name.valid_encoding? &&
        name.bytesize.between?(1, 512) && name !~ /[\x00-\x1f\x7f]/ && !names[name]
      names[name] = true
    end
    dns = config['dns'].is_a?(Hash) ? config['dns'] : {}
    # Node servers are usually hostnames. A source without proxy-server-nameserver
    # (e.g. MESL) still names plain resolvers in default-nameserver; without either,
    # the probe core falls back to the router resolver, which answers 198.18.x.x in
    # fake-ip mode, and every node ends in TLS_FAILED.
    servers = Array(dns['proxy-server-nameserver'])
    servers = Array(dns['default-nameserver']) if servers.empty?
    @bootstrap = servers.select do |entry|
      entry.is_a?(String) && (entry.match?(/\A(?:\d{1,3}\.){3}\d{1,3}\z/) ||
        entry.match?(/\A[0-9a-fA-F:]+\z/) || entry.match?(/\Ahttps:\/\/[a-zA-Z0-9.-]+(?::\d+)?\/[a-zA-Z0-9_\/.?=&%-]*\z/))
    end
    [Digest::SHA256.hexdigest(bytes), nodes]
  rescue Psych::Exception, ArgumentError
    raise Failure, 'SOURCE_YAML_INVALID'
  end

  def private_dir(dir)
    Dir.mkdir(dir, 0700) unless File.exist?(dir)
    raise Failure, 'IO_FAILED' unless File.lstat(dir).directory? && !File.symlink?(dir)
    File.chmod(0700, dir)
    dir
  end

  def job_dir(source)
    private_dir(@base)
    private_dir(@base + '/' + Digest::SHA256.hexdigest(source)[0, 16])
  end

  def atomic(file, bytes)
    temp = File.dirname(file) + '/.write-' + random
    File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(bytes); f.flush; f.fsync }
    File.rename(temp, file)
  ensure
    File.unlink(temp) if temp && File.exist?(temp)
  end

  def parse_json(file)
    return nil unless File.exist?(file)
    raise Failure, 'STATE_INVALID' unless File.lstat(file).file? && File.size(file) < 4 * 1024 * 1024
    YAML.safe_load(File.binread(file), permitted_classes: [], permitted_symbols: [], aliases: false)
  rescue Psych::Exception
    raise Failure, 'STATE_INVALID'
  end

  def process_stamp(pid)
    # /proc starttime prevents a recycled PID from being mistaken for our process.
    stat = File.read('/proc/' + pid.to_i.to_s + '/stat')
    fields = stat.sub(/\A.*\) /m, '').split
    fields[0] == 'Z' ? nil : fields[19]
  rescue SystemCallError
    nil
  end

  def alive?(pid, stamp)
    pid.is_a?(Integer) && pid > 1 && stamp && process_stamp(pid) == stamp
  end

  def blank_result(node)
    {'id' => Digest::SHA256.hexdigest(node['name'])[0, 16], 'name' => node['name'],
     'node_hash' => self.class.node_hash(node), 'country' => nil, 'samples_ms' => [],
     'median_ms' => nil, 'eligible' => false, 'error' => 'PENDING'}
  end

  def empty_state(source, sha, nodes)
    {'ok' => true, 'running' => false, 'done' => 0, 'total' => nodes.length,
     'source' => source, 'source_hash' => sha, 'source_sha256' => sha,
     'started_at' => nil, 'finished_at' => nil, 'started_epoch' => nil,
     'results' => nodes.map { |node| blank_result(node) }, 'best' => nil, 'error' => nil}
  end

  def public_state(state)
    result = state.reject { |key, _| %w[pid pid_stamp started_epoch finished_epoch].include?(key) }
    result['results'] = state['results'].map { |row| row.select { |key, _| RESULT_KEYS.include?(key) } }
    result['results'].sort_by! { |row| [row['eligible'] ? 0 : 1, row['median_ms'] || 1.0e20, row['name']] }
    result['nodes'] = result['results']
    result['best'] = result['results'].find { |row| row['eligible'] }&.fetch('id')
    result['supported_regions_source'] = SUPPORTED_SOURCE
    result['supported_regions_verified'] = SUPPORTED_VERIFIED
    result
  end

  def status(source)
    sha, nodes = source_data(source)
    dir = job_dir(source)
    stored = parse_json(dir + '/state.json')
    return public_state(empty_state(source, sha, nodes)) unless stored.is_a?(Hash)
    cleanup_orphans(dir) if stored['running'] && !alive?(stored['pid'], stored['pid_stamp'])
    if stored['source_sha256'] != sha || stored['source'] != source
      return public_state(empty_state(source, sha, nodes).merge('error' => 'SOURCE_CHANGED'))
    end
    if stored['running'] && !alive?(stored['pid'], stored['pid_stamp'])
      stored['running'] = false
      stored['error'] = 'BENCH_INTERRUPTED'
      stored['results'].each { |row| row['eligible'] = false; row['error'] = 'BENCH_INTERRUPTED' }
    end
    if stored['started_epoch'].to_i < Time.now.to_i - TTL
      stored['running'] = false
      stored['error'] = 'BENCH_EXPIRED'
      stored['results'].each { |row| row['eligible'] = false; row['error'] = 'BENCH_EXPIRED' }
    end
    public_state(stored)
  end

  def start(source)
    sha, nodes = source_data(source)
    dir = job_dir(source)
    lockpath = dir + '/job.lock'
    raise Failure, 'IO_FAILED' if File.symlink?(lockpath)
    lock = File.open(lockpath, File::RDWR | File::CREAT, 0600)
    unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      lock.close
      return status(source).merge('already_running' => true)
    end
    File.chmod(0600, lockpath)
    global_path = @base + '/global.lock'
    raise Failure, 'IO_FAILED' if File.symlink?(global_path)
    global = File.open(global_path, File::RDWR | File::CREAT, 0600)
    unless global.flock(File::LOCK_EX | File::LOCK_NB)
      global.close
      lock.close
      return {'ok' => false, 'error' => 'BENCH_BUSY'}
    end
    Dir.children(@base).select { |name| name.match?(/\A[0-9a-f]{16}\z/) }.each do |name|
      old_dir = @base + '/' + name
      next if File.symlink?(old_dir) || !File.directory?(old_dir)
      old = parse_json(old_dir + '/state.json')
      cleanup_orphans(old_dir) unless old.is_a?(Hash) && old['running'] && alive?(old['pid'], old['pid_stamp'])
    end
    state = empty_state(source, sha, nodes).merge('running' => true, 'started_at' => now, 'started_epoch' => Time.now.to_i)
    # Pipe makes publishing the child identity race-free without waiting for probes.
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Process.setsid
      File.umask(0077)
      STDIN.reopen('/dev/null', 'r'); STDOUT.reopen('/dev/null', 'w'); STDERR.reopen('/dev/null', 'w')
      state['pid'] = Process.pid
      state['pid_stamp'] = process_stamp(Process.pid)
      atomic(dir + '/state.json', self.class.json(state))
      writer.write('1'); writer.close
      begin
        run_job(dir, state, nodes)
      ensure
        lock.close
        global.close
      end
      exit! 0
    end
    writer.close
    # The child only writes the tiny initial state here, never waits for network.
    reader.read(1) if IO.select([reader], nil, nil, 3)
    reader.close
    lock.close
    global.close
    Process.detach(pid)
    status(source)
  rescue StandardError
    lock.close if lock && !lock.closed?
    global.close if global && !global.closed?
    raise
  end

  def supported_regions
    %w[json yaml yml].each do |suffix|
      file = path('/usr/share/r3mini-site-routing/supported-regions.' + suffix)
      next unless File.exist?(file)
      raise Failure, 'REGIONS_INVALID' unless File.lstat(file).file? && File.size(file) < 65_536
      value = YAML.safe_load(File.read(file), permitted_classes: [], permitted_symbols: [], aliases: false)
      value = value['countries'] || value['regions'] if value.is_a?(Hash)
      raise Failure, 'REGIONS_INVALID' unless value.is_a?(Array) && !value.empty? && value.all? { |v| v.is_a?(String) && v.match?(/\A[A-Z]{2}\z/) }
      return value.uniq
    end
    SUPPORTED
  rescue Psych::Exception
    raise Failure, 'REGIONS_INVALID'
  end

  def run_job(dir, state, nodes)
    stopped = false
    Signal.trap('TERM') { stopped = true }
    Signal.trap('INT') { stopped = true }
    regions = supported_regions
    queue = nodes.each_with_index.to_a
    mutex = Mutex.new
    threads = Array.new(CONCURRENCY) do
      Thread.new do
        loop do
          entry = mutex.synchronize { stopped ? nil : queue.shift }
          break unless entry
          node, index = entry
          row = probe(node, dir, regions, -> { stopped })
          mutex.synchronize do
            state['results'][index] = row
            state['done'] += 1
            atomic(dir + '/state.json', self.class.json(state))
          end
        end
      end
    end
    threads.each(&:join)
    state['error'] = 'BENCH_INTERRUPTED' if stopped
    current_sha, = source_data(state['source'])
    state['error'] = 'SOURCE_CHANGED' if current_sha != state['source_sha256']
  rescue Failure => error
    state['error'] = error.message
  rescue StandardError
    state['error'] = 'PROBE_FAILED'
  ensure
    @owned.keys.each { |pid| stop_core(pid) }
    state['running'] = false
    state['finished_at'] = now
    state['finished_epoch'] = Time.now.to_i
    if state['error']
      state['results'].each { |row| row['eligible'] = false; row['error'] = state['error'] }
    end
    atomic(dir + '/state.json', self.class.json(state))
  end

  def proc_tcp
    ['/proc/net/tcp', '/proc/net/tcp6'].flat_map { |file| File.exist?(file) ? File.readlines(file).drop(1) : [] }
  end

  def free_port
    taken = proc_tcp.map { |line| line.split[1].split(':')[1].to_i(16) }
    @guard.synchronize do
      100.times do
        port = 20_000 + File.binread('/dev/urandom', 2).unpack1('n') % 40_000
        next if taken.include?(port) || @ports[port]
        @ports[port] = true
        return port
      end
    end
    raise Failure, 'PORT_UNAVAILABLE'
  end

  def listening?(pid, port)
    inodes = Dir.glob('/proc/' + pid.to_s + '/fd/*').filter_map do |file|
      begin
        File.readlink(file)[/\Asocket:\[(\d+)\]\z/, 1]
      rescue SystemCallError
        nil
      end
    end
    proc_tcp.any? do |line|
      parts = line.split
      address, hexport = parts[1].split(':')
      parts[3] == '0A' && hexport.to_i(16) == port &&
        %w[0100007F 00000000000000000000000001000000 0000000000000000FFFF00000100007F].include?(address) && inodes.include?(parts[9])
    end
  rescue SystemCallError
    false
  end

  def minimal_config(node, port)
    copy = Marshal.load(Marshal.dump(node))
    copy['name'] = 'probe-node'
    dns = {'enable' => !@bootstrap.empty?, 'listen' => '127.0.0.1:0',
           'proxy-server-nameserver' => @bootstrap, 'nameserver' => @bootstrap,
           'fallback-filter' => {'geoip' => false}}
    plain_bootstrap = @bootstrap.reject { |entry| entry.start_with?('https:') }
    # An explicitly empty array is invalid; omission uses Mihomo's defaults.
    dns['default-nameserver'] = plain_bootstrap unless plain_bootstrap.empty?
    {'mixed-port' => port, 'bind-address' => '127.0.0.1', 'allow-lan' => false,
     'mode' => 'rule', 'ipv6' => false, 'log-level' => 'warning',
     'geo-auto-update' => false, 'geodata-mode' => false,
     'profile' => {'store-selected' => false, 'store-fake-ip' => false},
     'dns' => dns,
     'tun' => {'enable' => false}, 'proxies' => [copy], 'rules' => ['MATCH,probe-node']}
  end

  def core_gid
    return @core_gid if @core_gid
    file = path('/etc/group')
    raise Failure, 'CORE_GROUP_MISSING' unless File.file?(file) && File.size(file) <= 65_536
    groups = File.readlines(file).map { |line| line.chomp.split(':', -1) }
    group = groups.find { |fields| fields[0] == 'nogroup' && fields[2]&.match?(/\A\d+\z/) }
    raise Failure, 'CORE_GROUP_MISSING' unless group && group[2].to_i.between?(1, 4_294_967_294)
    @core_gid = group[2].to_i
  rescue SystemCallError
    raise Failure, 'CORE_GROUP_MISSING'
  end

  def stop_core(pid)
    stamp = @guard.synchronize { @owned[pid] }
    return unless stamp
    begin
      Process.kill('TERM', pid) if alive?(pid, stamp)
      deadline = monotonic + 3
      loop do
        begin
          break if Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          # A coordinator killed with SIGKILL leaves adopted children. Their
          # /proc identity is still ours; ECHILD does not mean they exited.
        end
        break unless alive?(pid, stamp)
        break if monotonic >= deadline
        sleep 0.05
      end
      Process.kill('KILL', pid) if alive?(pid, stamp)
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        deadline = monotonic + 2
        sleep 0.05 while alive?(pid, stamp) && monotonic < deadline
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @guard.synchronize { @owned.delete(pid) }
    end
  end

  def erase_tree(dir)
    return unless File.directory?(dir) && !File.symlink?(dir)
    Dir.children(dir).each do |name|
      file = dir + '/' + name
      File.directory?(file) && !File.symlink?(file) ? erase_tree(file) : File.unlink(file)
    end
    Dir.rmdir(dir)
  end

  def cleanup_orphans(dir)
    Dir.glob(dir + '/run-*').each do |scratch|
      next unless File.directory?(scratch) && !File.symlink?(scratch)
      owner = parse_json(scratch + '/owner.json')
      if owner.is_a?(Hash) && alive?(owner['pid'], owner['stamp'])
        command = File.binread('/proc/' + owner['pid'].to_s + '/cmdline').split("\0")
        if command.include?(scratch) && command.include?(scratch + '/config.yaml')
          @guard.synchronize { @owned[owner['pid']] = owner['stamp'] }
          stop_core(owner['pid'])
        end
      end
      erase_tree(scratch)
    rescue SystemCallError, Failure
      nil
    end
  end

  def curl_probe(port, scratch, url)
    body = scratch + '/response'
    metrics = scratch + '/metrics'
    # Each call starts a new curl process and therefore a new TLS connection.
    # -q must be first: user curlrc settings must not alter this isolated probe.
    args = [path('/usr/bin/curl'), '-q', '--silent', '--show-error', '--http1.1',
            '--no-keepalive', '--noproxy', '', '--proxy', 'http://127.0.0.1:' + port.to_s,
            '--connect-timeout', '8', '--max-time', '18', '--max-filesize', '65536',
            '--header', 'Cache-Control: no-cache', '--output', body,
            '--write-out', '%{http_code}\n%{time_starttransfer}\n', url]
    success = system(*args, out: metrics, err: '/dev/null')
    code = $?.exitstatus
    raise Failure, code == 35 || code == 60 ? 'TLS_FAILED' : 'TRACE_FAILED' unless success
    values = File.read(metrics).split
    raise Failure, 'TRACE_FAILED' unless values.length == 2 && values[0].match?(/\A\d{3}\z/) && values[1].match?(/\A\d+(?:\.\d+)?\z/)
    [values[0].to_i, values[1].to_f * 1000.0, File.binread(body).force_encoding(Encoding::UTF_8)]
  end

  def probe(node, dir, regions, stopped = -> { false })
    row = blank_result(node)
    raise Failure, 'NODE_DEPENDENCY' if node.key?('dialer-proxy') || node.key?('proxy')
    raise Failure, 'CORE_MISSING' unless File.executable?(path('/etc/openclash/core/clash_meta'))
    scratch = private_dir(dir + '/run-' + random)
    port = free_port
    config = scratch + '/config.yaml'
    atomic(config, YAML.dump(minimal_config(node, port)))
    %w[Country.mmdb GeoSite.dat GeoIP.dat].each do |name|
      original = path('/etc/openclash/' + name)
      File.symlink(original, scratch + '/' + name) if File.file?(original)
    end
    # OpenClash excludes its nogroup-owned core from OUTPUT interception. Match
    # that identity for this child only, so probe traffic reaches this node and
    # does not re-enter the production core. Helper and curl retain their GID.
    pid = Process.spawn(path('/etc/openclash/core/clash_meta'), '-d', scratch, '-f', config,
                        gid: core_gid, in: '/dev/null', out: scratch + '/core.log', err: [:child, :out])
    stamp = process_stamp(pid)
    @guard.synchronize { @owned[pid] = stamp }
    atomic(scratch + '/owner.json', self.class.json({'pid' => pid, 'stamp' => stamp}))
    deadline = monotonic + 15
    loop do
      raise Failure, 'BENCH_INTERRUPTED' if stopped.call
      raise Failure, 'CORE_START_FAILED' unless alive?(pid, stamp)
      break if listening?(pid, port)
      raise Failure, 'CORE_NOT_READY' if monotonic >= deadline
      sleep 0.1
    end
    country = nil
    3.times do
      raise Failure, 'BENCH_INTERRUPTED' if stopped.call
      code, ms, body = curl_probe(port, scratch, 'https://chatgpt.com/cdn-cgi/trace?r3mini=' + random)
      raise Failure, 'TRACE_FAILED' unless code == 200 && ms.positive? && ms.finite?
      locations = body.lines.filter_map { |line| line.strip[/\Aloc=([A-Z]{2})\z/, 1] }
      raise Failure, 'TRACE_FAILED' unless locations.length == 1
      current = locations[0]
      row['country'] = current
      raise Failure, 'UNSUPPORTED_REGION' unless regions.include?(current)
      raise Failure, 'REGION_CHANGED' if country && country != current
      country = current
      row['samples_ms'] << ms.round(3)
    end
    code, _, body = curl_probe(port, scratch, 'https://api.openai.com/v1/models?r3mini=' + random)
    raise Failure, 'UNSUPPORTED_REGION' if body.downcase.include?('unsupported_country')
    raise Failure, 'API_UNAVAILABLE' unless code == 401
    row['median_ms'] = row['samples_ms'].sort[1]
    row['eligible'] = true
    row['error'] = nil
    row
  rescue Failure => error
    row['error'] = error.message
    row
  rescue StandardError
    row['error'] = 'PROBE_FAILED'
    row
  ensure
    stop_core(pid) if pid
    erase_tree(scratch) if scratch
    @guard.synchronize { @ports.delete(port) } if port
  end

  def run(argv)
    raise Failure, 'ARGUMENT_INVALID' unless argv.length == 2 && %w[start status].include?(argv[0])
    argv[0] == 'start' ? start(argv[1]) : status(argv[1])
  end

  def self.run_cli(argv)
    result = new.run(argv)
    puts json(result)
    result['ok'] ? 0 : 1
  rescue Failure => error
    puts json({'ok' => false, 'error' => error.message})
    1
  rescue StandardError
    puts json({'ok' => false, 'error' => 'IO_FAILED'})
    1
  end
end

exit R3MiniSiteBench.run_cli(ARGV) if $PROGRAM_NAME == __FILE__
