#!/usr/bin/ruby
# frozen_string_literal: true

# r3mini-socks5 —— 路由器上带账号密码的 SOCKS5 出口，出口可选 OpenClash 任意一个订阅里的节点。
#
# SOCKS5 由本模块自己的 Mihomo 进程（「SOCKS5 内核」，用 OpenClash 的同一个二进制）提供，OpenClash 的
# 运行配置里不放本模块的任何条目：OpenClash 换配置、重启、更新订阅都不会把 SOCKS5 弄断；改端口、密码、
# 换订阅、换节点也只动 SOCKS5 内核，路由器上其他设备不受影响。
#
#   客户端 ─账号密码─▶ SOCKS5 内核 <端口>（入站 r3mini-socks5）→ 选择组 r3mini-socks5-mode
#     ├─ r3mini-socks5-exit   出口选择组：所选订阅的全部节点 + DIRECT
#     └─ r3mini-socks5-ipv4   回环 socks5 → sing-box 127.0.0.1:17896（「仅 IPv4」时选它）
#          sing-box：经出口用 DoH 查 A 记录，拒绝 IPv6、HTTP、QUIC，对 TLS 做记录分片
#          → SOCKS5 内核 127.0.0.1:17897（入站 r3mini-socks5-up）→ r3mini-socks5-exit
# SOCKS5 内核不开 DNS 增强模式、不嗅探，交给它的 IPv4 不会被还原成域名（节点拿到域名会改走 IPv6）；
# 节点服务器自己也按 SNI 改写目标，所以 TLS 必须分片。
# 换节点、开关仅 IPv4 只调 SOCKS5 内核的控制接口；换订阅、改端口热重载 SOCKS5 内核；改账号密码重启它。

module R3MiniSocks5
  VERSION = 3
  LISTENER = 'r3mini-socks5'
  UP_LISTENER = 'r3mini-socks5-up'
  EXIT_GROUP = 'r3mini-socks5-exit'
  MODE_GROUP = 'r3mini-socks5-mode'
  SHIM_PROXY = 'r3mini-socks5-ipv4'
  OWNER_KEY = 'x-r3mini-owner'
  # 内部端口都在临时端口段（32768–60999）之外。沙箱测试（设了 R3MINI_SOCKS5_ROOT）用
  # R3MINI_SOCKS5_PORT_SHIFT 整体平移，和正式实例并存。
  PORT_SHIFT = ENV['R3MINI_SOCKS5_ROOT'].to_s.empty? ? 0 : ENV['R3MINI_SOCKS5_PORT_SHIFT'].to_i
  SHIM_PORT = 17_896 + PORT_SHIFT
  UP_PORT = 17_897 + PORT_SHIFT
  CORE_API_PORT = 17_898 + PORT_SHIFT
  # 第 2 版在 OpenClash 嗅探里加过这个跳过项；清理旧条目时一并去掉。
  SKIP_SRC = '127.0.0.2/32'
  LEGACY_MARK = %r{r3mini-socks5|127\.0\.0\.2/32}.freeze
  RUN_DIR = '/tmp/r3mini-socks5'
  SHIM_PROFILE = '/tmp/r3mini-socks5/ipv4.json'
  CORE_DIR = '/tmp/r3mini-socks5/core'
  CORE_CONFIG = '/tmp/r3mini-socks5/core/config.yaml'
  CORE_META = '/tmp/r3mini-socks5/core/meta.json'
  SERVICE = '/etc/init.d/r3mini-socks5'
  SUB_DIR = '/etc/openclash/config'
  SHIM_BINARIES = ['/usr/bin/sing-box', '/mnt/mmcblk0p6/r3mini-socks5/sing-box'].freeze
  CORE_BINARIES = ['/etc/openclash/core/clash_meta', '/etc/openclash/core/mihomo'].freeze
  DEFAULT_PORT = 7896
  BUILTIN_NAMES = %w[DIRECT REJECT REJECT-DROP PASS COMPATIBLE GLOBAL].freeze
  FOREIGN_NAME = /\Ar3mini-/.freeze
  NON_NODE_TYPES = %w[direct reject reject-drop pass compatible dns].freeze
  TYPE_NAMES = {
    'anytls' => 'AnyTLS', 'vless' => 'VLESS', 'vmess' => 'VMess', 'trojan' => 'Trojan', 'ss' => 'Shadowsocks',
    'ssr' => 'ShadowsocksR', 'hysteria' => 'Hysteria', 'hysteria2' => 'Hysteria2', 'tuic' => 'TUIC',
    'wireguard' => 'WireGuard', 'socks5' => 'Socks5', 'http' => 'HTTP', 'snell' => 'Snell', 'ssh' => 'SSH',
    'mieru' => 'Mieru'
  }.freeze
  RESERVED_FALLBACK = [9090, 7874, 7890, 7891, 7892, 7893, 7895].freeze
  OPENCLASH_PORT_KEYS = %w[http_port socks_port mixed_port tproxy_port proxy_port redir_port dns_port cn_port].freeze
  CORE_NAMES = %w[clash_meta mihomo clash meta].freeze
  BACKUP_KEEP = 5
  TEST_URL = 'https://www.gstatic.com/generate_204'
  GOOGLE_URL = 'https://redirector.gvt1.com/report_mapping?di=no'
  YOUTUBE_URL = 'https://www.youtube.com/?hl=en'
  CLOUDFLARE_URL = 'https://www.cloudflare.com/cdn-cgi/trace'
  APPLE_URL = 'https://gspe1-ssl.ls.apple.com/pep/gcc'
  IPINFO_URL = 'https://ipinfo.io/json'
  MAXMIND_URL = 'https://ifconfig.co/json'

  ERRORS = {
    'ARGUMENT_INVALID' => '命令参数无效，请刷新页面后重试。',
    'BUSY' => '另一个操作正在进行，请稍后再试。',
    'SETTINGS_INVALID' => '本模块设置文件损坏；执行 r3mini-socks5 reset 清掉后重新保存。',
    'DISABLED' => 'SOCKS5 出口已停用，请先启用。',
    'NOT_APPLIED' => 'SOCKS5 没有按当前设置运行，请点「修复」。',
    'PORT_INVALID' => '端口必须为 1–65535 的整数。',
    'PORT_RESERVED' => '此端口被 OpenClash 或本模块内部占用，请换一个端口。',
    'PORT_IN_USE' => '此端口已被其他程序监听，请换一个端口。',
    'LISTEN_INVALID' => '监听地址无效，只能选择全部网卡、仅本机或本机现有地址。',
    'USERNAME_INVALID' => '账号只能使用字母、数字与 . _ -，长度 1–64。',
    'PASSWORD_INVALID' => '密码需 4–128 个字符且不超过 128 字节，不能含空白或冒号。',
    'PASSWORD_REQUIRED' => '启用前必须设置密码。',
    'TARGET_INVALID' => '出口名称无效。',
    'TARGET_MISSING' => '选中的节点在这个订阅里已经没有了，请重新选择。',
    'SUBSCRIPTION_MISSING' => '所选订阅的配置文件不在了，请重新选择订阅。',
    'SUBSCRIPTION_INVALID' => '这个订阅的配置文件读不出节点。',
    'RUNTIME_MISSING' => '未找到当前 OpenClash 运行配置。',
    'RUNTIME_INVALID' => '当前 OpenClash 运行配置无效。',
    'CONTROLLER_INVALID' => '当前 OpenClash 配置没有可用的本机控制接口。',
    'CONTROLLER_UNAVAILABLE' => '无法读取 OpenClash 控制接口，请确认 OpenClash 正在运行。',
    'CORE_MISSING' => '没有找到 Mihomo 内核文件（/etc/openclash/core/clash_meta）。',
    'CORE_FAILED' => 'SOCKS5 内核没有启动或没有接受新配置。',
    'SWITCH_FAILED' => 'SOCKS5 内核没有接受这次切换，请重试。',
    'RELOAD_FAILED' => 'OpenClash 没有接受清理后的配置，已恢复原配置。',
    'SHIM_MISSING' => '没有找到 sing-box，无法开启仅 IPv4。',
    'IPV4_SERVICE' => '仅 IPv4 转发进程没有运行，请点「修复」。',
    'PROBE_TOOL_MISSING' => '探测工具 curl 不可用。',
    'PROBE_FAILED' => '经 SOCKS5 访问测试网站失败：出口节点不通或账号密码被拒。',
    'DELAY_FAILED' => '节点测速失败或超时。',
    'DELAY_UNAVAILABLE' => '这个订阅现在没有内核在跑，换到它之后才能测速。',
    'STATE_MISMATCH' => '运行状态与保存的设置不一致，请点「修复」。',
    'IO_FAILED' => '读取或保存失败，改前备份已保留。',
    'INTERNAL_ERROR' => '操作失败，未输出任何凭据。'
  }.freeze

  class Failure < StandardError
    attr_reader :token

    def initialize(token)
      @token = token
      super(token)
    end
  end

  # save 的请求体按 JSON 严格解析，不让 YAML 把裸 yes/no 当成布尔。只用于小请求体，按字节扫描。
  class JsonReader
    def initialize(text)
      @text = text.b
      @pos = 0
    end

    def read
      value = read_value
      skip_space
      fail! unless @pos == @text.bytesize
      value
    end

    private

    def fail!
      raise Failure, 'ARGUMENT_INVALID'
    end

    def peek
      @text.getbyte(@pos)
    end

    def skip_space
      @pos += 1 while (c = peek) && [0x20, 0x09, 0x0a, 0x0d].include?(c)
    end

    def read_value
      skip_space
      case peek
      when nil then fail!
      when 0x7b then read_object
      when 0x5b then read_array
      when 0x22 then read_string
      when 0x74 then literal('true', true)
      when 0x66 then literal('false', false)
      when 0x6e then literal('null', nil)
      else read_number
      end
    end

    def literal(word, value)
      fail! unless @text.byteslice(@pos, word.bytesize) == word
      @pos += word.bytesize
      value
    end

    def read_object
      @pos += 1
      result = {}
      skip_space
      if peek == 0x7d
        @pos += 1
        return result
      end
      loop do
        skip_space
        key = read_string
        skip_space
        fail! unless peek == 0x3a
        @pos += 1
        result[key] = read_value
        skip_space
        case peek
        when 0x2c then @pos += 1
        when 0x7d
          @pos += 1
          return result
        else fail!
        end
      end
    end

    def read_array
      @pos += 1
      result = []
      skip_space
      if peek == 0x5d
        @pos += 1
        return result
      end
      loop do
        result << read_value
        skip_space
        case peek
        when 0x2c then @pos += 1
        when 0x5d
          @pos += 1
          return result
        else fail!
        end
      end
    end

    def hex4
      hex = @text.byteslice(@pos, 4)
      fail! unless hex&.match?(/\A[0-9a-fA-F]{4}\z/)
      @pos += 4
      hex.to_i(16)
    end

    def read_string
      fail! unless peek == 0x22
      @pos += 1
      out = +''.b
      loop do
        c = peek
        fail! if c.nil? || c < 0x20
        @pos += 1
        case c
        when 0x22
          out.force_encoding(Encoding::UTF_8)
          fail! unless out.valid_encoding?
          return out
        when 0x5c
          esc = peek
          @pos += 1
          case esc
          when 0x22 then out << '"'
          when 0x5c then out << '\\'
          when 0x2f then out << '/'
          when 0x62 then out << "\b"
          when 0x66 then out << "\f"
          when 0x6e then out << "\n"
          when 0x72 then out << "\r"
          when 0x74 then out << "\t"
          when 0x75
            code = hex4
            if code.between?(0xD800, 0xDBFF)
              fail! unless @text.byteslice(@pos, 2) == '\\u'
              @pos += 2
              low = hex4
              fail! unless low.between?(0xDC00, 0xDFFF)
              code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            end
            out << [code].pack('U').b
          else fail!
          end
        else
          out << c
        end
      end
    end

    def read_number
      start = @pos
      @pos += 1 while (c = peek) && '-+0123456789.eE'.include?(c.chr)
      text = @text.byteslice(start, @pos - start)
      fail! unless text.match?(/\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\z/)
      text.match?(/[.eE]/) ? Float(text) : Integer(text, 10)
    end
  end

  def self.json(value)
    case value
    when Hash then '{' + value.map { |k, v| json(k.to_s) + ':' + json(v) }.join(',') + '}'
    when Array then '[' + value.map { |v| json(v) }.join(',') + ']'
    when String
      '"' + value.each_codepoint.map { |c|
        if c == 34 then '\\"'
        elsif c == 92 then '\\\\'
        elsif c < 32 || c == 0x2028 || c == 0x2029 then format('\\u%04x', c)
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
    DEFAULTS = {
      'version' => VERSION, 'enabled' => false, 'port' => DEFAULT_PORT, 'listen' => '0.0.0.0',
      'username' => 'r3mini', 'password' => '', 'udp' => true, 'ipv4_only' => false,
      'subscription' => '', 'target' => 'DIRECT', 'last_action' => nil, 'last_time' => nil
    }.freeze
    BACKUP_NAME = /\A\d{8}T\d{6}Z-\d+-[0-9a-f]{16}\z/.freeze

    def initialize
      sandbox = ENV['R3MINI_SOCKS5_ROOT']
      @root = sandbox && !sandbox.empty? ? File.realpath(sandbox) : ''
      raise Failure, 'ARGUMENT_INVALID' if @root == '/'

      @state = path('/etc/r3mini-socks5')
      @settings_path = @state + '/settings.json'
      @temp = path(RUN_DIR)
      @hook_log = @temp + '/hook.log'
      @shim_profile = path(SHIM_PROFILE)
    end

    def path(absolute)
      @root + absolute
    end

    def fail!(token)
      raise Failure, token
    end

    def yaml!
      require 'yaml'
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def wait_until(seconds, step = 0.2)
      deadline = monotonic + seconds
      loop do
        return true if yield
        return false if monotonic >= deadline

        sleep step
      end
    end

    # ---------- 基础 IO ----------

    def parse_json(text, token)
      yaml!
      YAML.safe_load(text.to_s, permitted_classes: [], permitted_symbols: [], aliases: false)
    rescue Failure
      raise
    rescue StandardError
      fail!(token)
    end

    def parse_yaml(bytes, token)
      yaml!
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
      Dir.mkdir(dir, 0o700) unless File.exist?(dir)
      fail!('IO_FAILED') unless File.lstat(dir).directory? && !File.symlink?(dir)
      File.chmod(0o700, dir)
    end

    def mkdir_p(dir)
      return if File.exist?(dir)

      parent = File.dirname(dir)
      mkdir_p(parent) unless parent == dir
      Dir.mkdir(dir, 0o755) unless File.exist?(dir)
    end

    def random_suffix
      File.binread('/dev/urandom', 8).unpack1('H*')
    end

    def own_dir?(dir)
      [@temp, @state].any? { |base| dir == base || dir.start_with?(base + '/') }
    end

    def private_dir(dir)
      mkdir_p(File.dirname(dir))
      mkdir_private(dir)
      dir
    end

    # 本模块自己的目录才收成 0700；别人的目录（/etc/openclash）只在里面建临时文件，不改目录权限。
    def temporary(dir, suffix)
      private_dir(dir) if own_dir?(dir)
      name = "#{dir}/.r3mini-socks5-#{Process.pid}-#{random_suffix}#{suffix}"
      File.open(name, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| yield f }
      name
    end

    def atomic_write(destination, bytes, mode = 0o600)
      candidate = temporary(File.dirname(destination), '.tmp') do |f|
        f.write(bytes)
        f.flush
        f.fsync
      end
      File.chmod(mode, candidate)
      File.rename(candidate, destination)
    ensure
      File.unlink(candidate) if candidate && File.exist?(candidate)
    end

    def decode_arg(value)
      fail!('ARGUMENT_INVALID') unless value.is_a?(String)
      return value.dup.force_encoding(Encoding::UTF_8) unless value.start_with?('b64:')

      raw = value[4..].tr('-_', '+/')
      fail!('ARGUMENT_INVALID') unless raw.match?(%r{\A[A-Za-z0-9+/]*\z}) && raw.length <= 4096
      raw += '=' * ((4 - (raw.length % 4)) % 4)
      out = raw.unpack1('m0').force_encoding(Encoding::UTF_8)
      fail!('ARGUMENT_INVALID') unless out.valid_encoding?
      out
    rescue ArgumentError
      fail!('ARGUMENT_INVALID')
    end

    def escape(text)
      text.b.bytes.map { |b| b.chr.match?(/[A-Za-z0-9\-._~]/) ? b.chr : format('%%%02X', b) }.join
    end

    # ---------- 设置 ----------

    def settings
      result = DEFAULTS.dup
      return result unless File.exist?(@settings_path)

      loaded = parse_json(read(@settings_path, 'SETTINGS_INVALID', 64 * 1024), 'SETTINGS_INVALID')
      fail!('SETTINGS_INVALID') unless loaded.is_a?(Hash)
      result.merge!(loaded)
      fail!('SETTINGS_INVALID') unless result['port'].is_a?(Integer) && result['port'].between?(1, 65_535)
      %w[enabled udp ipv4_only].each { |k| fail!('SETTINGS_INVALID') unless [true, false].include?(result[k]) }
      %w[listen username password target subscription].each do |key|
        fail!('SETTINGS_INVALID') unless result[key].is_a?(String) && result[key].valid_encoding?
      end
      result['version'] = VERSION
      result
    end

    def save_settings(value)
      ordered = DEFAULTS.keys.to_h { |k| [k, value[k]] }
      atomic_write(@settings_path, R3MiniSocks5.json(ordered) + "\n")
    end

    def stamp(s, action)
      s.merge('version' => VERSION, 'last_action' => action,
              'last_time' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'))
    end

    # 这些字段写进 SOCKS5 内核的入站；内核配置记着它的摘要，用来判断运行的是不是当前设置。
    def settings_key(s)
      require 'digest'
      Digest::SHA256.hexdigest(R3MiniSocks5.json([s['port'], s['listen'], s['udp'], s['username'], s['password']]))[0, 24]
    end

    def uci(key)
      uci_bin = path('/sbin/uci')
      return '' unless File.executable?(uci_bin)

      IO.popen([uci_bin, '-q', 'get', key], err: File::NULL, &:read).to_s.strip
    rescue SystemCallError
      ''
    end

    def reserved_ports
      @reserved_ports ||= begin
        ports = OPENCLASH_PORT_KEYS.filter_map do |key|
          value = uci('openclash.config.' + key)
          value.to_i if value.match?(/\A\d{1,5}\z/) && value.to_i.between?(1, 65_535)
        end
        # uci 只读到个别键时并上兜底集合，避免把 OpenClash 的端口当空闲。
        ports = (ports + RESERVED_FALLBACK) if ports.length < 3
        (ports + [SHIM_PORT, UP_PORT, CORE_API_PORT]).uniq
      end
    end

    def int_port(value)
      return value if value.is_a?(Integer) && value.between?(1, 65_535)
      if value.is_a?(String) && value.match?(/\A\d{1,5}\z/)
        number = value.to_i
        return number if number.between?(1, 65_535)
      end
      fail!('PORT_INVALID')
    end

    def local_addresses
      list = ['127.0.0.1']
      ip_bin = path('/sbin/ip')
      if File.executable?(ip_bin)
        IO.popen([ip_bin, '-o', '-4', 'addr', 'show'], err: File::NULL, &:read).to_s.each_line do |line|
          cols = line.split
          list << cols[3].split('/')[0] if cols.length >= 4
        end
      end
      list.uniq
    rescue SystemCallError
      ['127.0.0.1']
    end

    def allowed_listen
      @allowed_listen ||= (['0.0.0.0'] + local_addresses).uniq
    end

    # ---------- 端口与进程 ----------

    def socket_table
      entries = []
      [['tcp', '/proc/net/tcp', true], ['tcp6', '/proc/net/tcp6', true],
       ['udp', '/proc/net/udp', false], ['udp6', '/proc/net/udp6', false]].each do |proto, rel, listen_only|
        file = path(rel)
        next unless File.file?(file)

        File.foreach(file).drop(1).each do |line|
          cols = line.split
          next if cols.length < 10

          hex = cols[1].to_s.split(':')[1].to_s
          next unless hex.match?(/\A[0-9A-Fa-f]{1,4}\z/)
          next if listen_only && cols[3] != '0A'

          entries << { 'proto' => proto, 'port' => hex.to_i(16), 'inode' => cols[9].to_s }
        end
      end
      entries
    rescue SystemCallError
      []
    end

    def process_names
      Dir.glob(path('/proc/[0-9]*/comm')).each_with_object({}) do |comm, map|
        map[File.basename(File.dirname(comm)).to_i] = File.read(comm).strip
      rescue SystemCallError
        next
      end
    end

    # 先查内核和 sing-box 进程的 fd，命中就停；查不到再扫其余进程。
    def socket_owner(inodes)
      wanted = inodes.reject { |i| i == '0' }.map { |i| "socket:[#{i}]" }
      return nil if wanted.empty?

      names = process_names
      likely = ->(name) { CORE_NAMES.any? { |c| name.downcase.start_with?(c) } || name == 'sing-box' }
      names.keys.sort_by { |pid| likely.call(names[pid]) ? 0 : 1 }.each do |pid|
        fddir = path("/proc/#{pid}/fd")
        begin
          Dir.children(fddir).each do |fd|
            link = File.readlink(fddir + '/' + fd)
            next unless wanted.include?(link)

            name = names[pid].to_s
            return { 'pid' => pid, 'name' => name.empty? ? 'unknown' : name }
          rescue SystemCallError
            next
          end
        rescue SystemCallError
          next
        end
      end
      nil
    end

    def port_state(port)
      busy = socket_table.select { |entry| entry['port'] == port }
      return { 'free' => true, 'owner' => nil, 'protocols' => [] } if busy.empty?

      { 'free' => false, 'owner' => socket_owner(busy.map { |e| e['inode'] }),
        'protocols' => busy.map { |e| e['proto'] }.uniq.sort }
    end

    def core_process?(owner)
      owner.is_a?(Hash) && CORE_NAMES.any? { |core| owner['name'].to_s.downcase.start_with?(core) }
    end

    def process_args(pid)
      File.binread(path("/proc/#{pid}/cmdline")).split("\0")
    rescue SystemCallError
      []
    end

    # SOCKS5 内核：控制接口端口归它，命令行的 -f 是本模块的配置。
    def core_pid
      owner = port_state(CORE_API_PORT)['owner']
      return nil unless core_process?(owner)

      args = process_args(owner['pid'])
      index = args.index('-f')
      index && [CORE_CONFIG, path(CORE_CONFIG)].include?(args[index + 1]) ? owner['pid'] : nil
    end

    def core_ready?(s)
      pid = core_pid
      return false unless pid

      owner = port_state(s['port'])['owner']
      owner.is_a?(Hash) && owner['pid'] == pid
    end

    def shim_alive?
      state = port_state(SHIM_PORT)
      owner = state['owner']
      return false unless owner && owner['name'] == 'sing-box' && state['protocols'].any? { |p| p.start_with?('tcp') }

      args = process_args(owner['pid'])
      [SHIM_PROFILE, @shim_profile].include?(args.last) && args[-3..-2] == %w[run -c]
    end

    def check_port(port)
      port = int_port(port)
      state = port_state(port)
      owner = state['owner']
      pid = state['free'] ? nil : core_pid
      configured = begin
        settings['port'] == port
      rescue Failure
        false
      end
      # 反查不到占用进程时，只要内核在跑、端口是设置里的那个，仍算本模块自己占着。
      own = !state['free'] && !pid.nil? && (owner.is_a?(Hash) ? owner['pid'] == pid : configured)
      { 'port' => port, 'free' => state['free'], 'own' => own, 'occupied' => !state['free'] && !own,
        'owner' => owner, 'protocols' => state['protocols'], 'reserved' => reserved_ports.include?(port) }
    end

    # ---------- 校验 ----------

    def validate_credentials!(s)
      fail!('USERNAME_INVALID') unless s['username'].is_a?(String) && s['username'].match?(/\A[A-Za-z0-9._-]{1,64}\z/)
      password = s['password']
      if password.to_s.empty?
        fail!('PASSWORD_REQUIRED') if s['enabled']
        return
      end
      # curl 的 proxy-user 用冒号分隔账号密码，含冒号的密码会被截断。
      fail!('PASSWORD_INVALID') unless password.is_a?(String) && password.length.between?(4, 128) &&
                                       password.bytesize <= 128 && password.valid_encoding? &&
                                       password !~ /[\s\x00-\x1f\x7f:]/
    end

    def validate_target_format!(target)
      fail!('TARGET_INVALID') unless target.is_a?(String) && target.length.between?(1, 256) &&
                                     target.valid_encoding? && target !~ /[\x00-\x1f\x7f]/
    end

    def validate_settings!(s, listen: true)
      port = s['port']
      fail!('PORT_INVALID') unless port.is_a?(Integer) && port.between?(1, 65_535)
      fail!('PORT_RESERVED') if reserved_ports.include?(port)
      fail!('LISTEN_INVALID') if listen && !allowed_listen.include?(s['listen'])
      fail!('LISTEN_INVALID') unless s['listen'].is_a?(String) && s['listen'].match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/)
      validate_credentials!(s)
      validate_target_format!(s['target'])
      fail!('SUBSCRIPTION_MISSING') unless s['subscription'].to_s.empty? || sub_name_ok?(s['subscription'])
      fail!('ARGUMENT_INVALID') unless [true, false].include?(s['udp']) && [true, false].include?(s['ipv4_only'])
      s
    end

    def merge_settings(s, payload)
      desired = s.dup
      desired['port'] = int_port(payload['port']) if payload.key?('port')
      %w[listen username password target subscription].each do |key|
        next unless payload.key?(key)
        fail!('ARGUMENT_INVALID') unless payload[key].is_a?(String) && payload[key].valid_encoding?
        # 空密码表示“沿用旧密码”，页面不回显明文。
        next if key == 'password' && payload[key].empty?

        desired[key] = payload[key]
      end
      %w[udp enabled ipv4_only].each do |key|
        next unless payload.key?(key)
        fail!('ARGUMENT_INVALID') unless [true, false].include?(payload[key])

        desired[key] = payload[key]
      end
      desired
    end

    # ---------- OpenClash 运行配置（只读 DNS；清理第 2 版留下的条目） ----------

    def active_basename
      uci_bin = path('/sbin/uci')
      fail!('RUNTIME_MISSING') unless File.executable?(uci_bin)

      ['openclash.@overwrite[0].config_path', 'openclash.config.config_path'].each do |key|
        value = IO.popen([uci_bin, '-q', 'get', key], err: File::NULL, &:read).to_s.strip
        next if value.empty?

        name = File.basename(value)
        fail!('RUNTIME_MISSING') unless name.end_with?('.yaml', '.yml') && name.length <= 255 &&
                                       !name.include?('/') && name != '.' && name != '..'
        return name
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
      config = parse_yaml(read(file, 'RUNTIME_INVALID'), 'RUNTIME_INVALID')
      fail!('RUNTIME_INVALID') unless config.is_a?(Hash)

      { 'proxies' => Hash, 'proxy-groups' => Hash, 'listeners' => Hash, 'rules' => String }.each do |key, type|
        next if config[key].nil?

        fail!('RUNTIME_INVALID') unless config[key].is_a?(Array) && config[key].all? { |item| item.is_a?(type) }
      end
      fail!('RUNTIME_INVALID') unless config['sniffer'].nil? || config['sniffer'].is_a?(Hash)
      config
    end

    def strip_own(config)
      result = config.dup
      if config['listeners']
        result['listeners'] = config['listeners'].reject { |e| [LISTENER, UP_LISTENER].include?(e['name']) }
      end
      if config['proxies']
        result['proxies'] = config['proxies'].reject { |e| e['name'] == SHIM_PROXY && e[OWNER_KEY] == LISTENER }
      end
      if config['proxy-groups']
        result['proxy-groups'] = config['proxy-groups'].reject { |e| [EXIT_GROUP, MODE_GROUP].include?(e['name']) }
      end
      skip = config.dig('sniffer', 'skip-src-address')
      if skip.is_a?(Array) && skip.include?(SKIP_SRC)
        sniffer = config['sniffer'].dup
        rest = skip - [SKIP_SRC]
        rest.empty? ? sniffer.delete('skip-src-address') : sniffer['skip-src-address'] = rest
        result['sniffer'] = sniffer
      end
      result.delete('listeners') if result['listeners'] == [] && !config['listeners'].nil? && config['listeners'].all? { |e| [LISTENER, UP_LISTENER].include?(e['name']) }
      result
    end

    # ---------- 控制接口（OpenClash 内核与 SOCKS5 内核共用） ----------

    def scalar(text)
      return '' if text.nil? || text.empty?
      return text[1...-1].gsub("''", "'") if text.start_with?("'") && text.end_with?("'") && text.length >= 2
      return parse_json(text, 'CONTROLLER_INVALID').to_s if text.start_with?('"')

      text.sub(/\s+#.*\z/, '')
    end

    # 只扫顶层两行，不为拿接口地址解析整份运行配置。
    def controller_endpoint
      @controller_endpoint ||= begin
        found = {}
        File.foreach(runtime_path, encoding: 'UTF-8') do |line|
          m = line.match(/\A(external-controller|secret):[ \t]*(.*?)[ \t]*\r?\n?\z/)
          next unless m

          found[m[1]] = scalar(m[2])
          break if found.size == 2
        end
        address = found['external-controller'].to_s
        secret = found['secret'].to_s
        fail!('CONTROLLER_INVALID') unless address.match?(/\A(?:\[[0-9a-fA-F:]+\]|[A-Za-z0-9_.-]*):[0-9]{1,5}\z/)
        port = address.split(':')[-1].to_i
        fail!('CONTROLLER_INVALID') unless port.between?(1, 65_535) && secret !~ /[\x00-\x1f\x7f]/
        [address.start_with?('[') ? '[::1]' : '127.0.0.1', port, secret]
      end
    rescue SystemCallError
      fail!('RUNTIME_MISSING')
    end

    def curl_path
      curl = path('/usr/bin/curl')
      fail!('CONTROLLER_UNAVAILABLE') unless File.executable?(curl)
      curl
    end

    def controller_header(secret)
      temporary(@temp, '.h') { |f| f.write("Authorization: Bearer #{secret}\nContent-Type: application/json\n") }
    end

    def api(method, route, body = nil, timeout: 4, endpoint: nil, down: 'CONTROLLER_UNAVAILABLE', denied: 'CONTROLLER_INVALID')
      host, port, secret = endpoint || controller_endpoint
      header = controller_header(secret)
      bodyfile = temporary(@temp, '.b') { |f| f.write(R3MiniSocks5.json(body)) } unless body.nil?
      argv = [curl_path, '-q', '--silent', '--noproxy', '*', '--connect-timeout', '2', '--max-time', timeout.to_s,
              '--header', '@' + header, '--request', method, '--write-out', "\n%{http_code}"]
      argv += ['--data-binary', '@' + bodyfile] if bodyfile
      argv << "http://#{host}:#{port}#{route}"
      out = IO.popen(argv, err: File::NULL) { |io| io.read(6 * 1024 * 1024) }.to_s
      fail!(down) unless $?.success?
      text, _sep, code = out.rpartition("\n")
      code = code.to_i
      fail!(down) if code.zero?
      fail!(denied) if [401, 403].include?(code)
      [code, text.force_encoding(Encoding::UTF_8)]
    ensure
      [header, bodyfile].compact.each { |f| File.unlink(f) if File.exist?(f) }
    end

    def proxies_of(text, token)
      data = parse_json(text, token)
      data = data['proxies'] if data.is_a?(Hash) && data['proxies'].is_a?(Hash)
      data.is_a?(Hash) ? data : nil
    end

    def main_proxies
      code, text = api('GET', '/proxies', timeout: 8)
      code == 200 ? proxies_of(text, 'CONTROLLER_UNAVAILABLE') : nil
    rescue Failure
      nil
    end

    def main_proxy(name)
      code, text = api('GET', '/proxies/' + escape(name), timeout: 3)
      data = code == 200 ? parse_json(text, 'CONTROLLER_UNAVAILABLE') : nil
      data.is_a?(Hash) ? data : nil
    rescue Failure
      nil
    end

    def last_delay(info)
      record = Array(info.is_a?(Hash) ? info['history'] : nil).last
      delay = record.is_a?(Hash) ? record['delay'] : nil
      delay.is_a?(Integer) && delay.positive? ? delay : nil
    end

    # ---------- 订阅 ----------

    def sub_name_ok?(file)
      file.is_a?(String) && file.valid_encoding? && file.length.between?(6, 200) &&
        file.match?(/\A[^\/\x00-\x1f\x7f]+\.ya?ml\z/) && !file.start_with?('.')
    end

    def sub_path(file)
      fail!('SUBSCRIPTION_MISSING') unless sub_name_ok?(file)
      dir = path(SUB_DIR)
      full = File.join(dir, file)
      fail!('SUBSCRIPTION_MISSING') unless File.file?(full) && File.dirname(File.realpath(full)) == File.realpath(dir)
      full
    rescue SystemCallError
      fail!('SUBSCRIPTION_MISSING')
    end

    def sub_key(full)
      st = File.stat(full)
      "#{st.size}-#{st.mtime.to_i}-#{st.mtime.nsec}"
    end

    def active_file
      active_basename
    rescue Failure
      nil
    end

    # OpenClash 的配置文件就是各个订阅（/etc/openclash/config/*.yaml）。
    def subscriptions(current = nil)
      dir = path(SUB_DIR)
      active = active_file
      Dir.children(dir).select { |n| sub_name_ok?(n) && File.file?(File.join(dir, n)) }.sort_by(&:downcase).map do |n|
        { 'file' => n, 'name' => n.sub(/\.ya?ml\z/, ''), 'active' => n == active, 'current' => n == current }
      end
    rescue SystemCallError
      []
    end

    # 设置里还没指定订阅时，跟 OpenClash 当前配置走；第一次应用时写进设置固定下来。
    def current_sub(s)
      file = s['subscription'].to_s
      file.empty? ? active_file : file
    end

    # 订阅文件几百 KB，解析要 0.3–0.5 秒：按大小和修改时间把解析出的节点缓存在 /tmp（只有 root 可读）。
    def load_sub(file)
      full = sub_path(file)
      key = sub_key(full)
      cache = "#{@temp}/sub-#{escape(file)}.cache"
      if File.file?(cache)
        data = begin
          Marshal.load(File.binread(cache)) # rubocop:disable Security/MarshalLoad
        rescue StandardError
          nil
        end
        return data if data.is_a?(Hash) && data['key'] == key && data['file'] == file
      end
      config = parse_yaml(read(full, 'SUBSCRIPTION_INVALID', 16 * 1024 * 1024), 'SUBSCRIPTION_INVALID')
      fail!('SUBSCRIPTION_INVALID') unless config.is_a?(Hash)
      seen = {}
      proxies = Array(config['proxies']).select do |p|
        next false unless p.is_a?(Hash) && p['name'].is_a?(String) && p['type'].is_a?(String)

        name = p['name']
        next false if name.empty? || name.length > 256 || name.match?(/[\x00-\x1f\x7f]/) || seen[name]
        next false if name.match?(FOREIGN_NAME) || BUILTIN_NAMES.include?(name.upcase) ||
                      NON_NODE_TYPES.include?(p['type'].downcase)

        seen[name] = true
      end
      fail!('SUBSCRIPTION_INVALID') if proxies.empty?
      data = { 'file' => file, 'key' => key, 'proxies' => proxies }
      private_dir(@temp)
      atomic_write(cache, Marshal.dump(data))
      data
    end

    def type_name(type)
      TYPE_NAMES[type.to_s.downcase] || type.to_s
    end

    # ---------- SOCKS5 内核与 sing-box ----------

    def shim_binary
      SHIM_BINARIES.map { |p| path(p) }.find { |p| File.file?(p) && File.executable?(p) }
    end

    def core_binary
      CORE_BINARIES.map { |p| path(p) }.find { |p| File.file?(p) && File.executable?(p) }
    end

    def service(action)
      script = path(SERVICE)
      File.executable?(script) && system(script, action, out: File::NULL, err: File::NULL)
    end

    # 解析节点服务器用的 DNS 跟 OpenClash 运行配置一致（用户在 OpenClash 里配的），拿不到就用公共 DNS。
    def dns_settings
      main = begin
        runtime(runtime_path)
      rescue Failure
        {}
      end
      dns = main['dns'].is_a?(Hash) ? main['dns'] : {}
      plain = Array(dns['default-nameserver']).map(&:to_s).select { |v| v.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/) }
      plain = %w[223.5.5.5 119.29.29.29] if plain.empty?
      servers = Array(dns['proxy-server-nameserver']).map(&:to_s).reject(&:empty?)
      servers = plain if servers.empty?
      ipv6 = main['ipv6'] == true
      [{ 'enable' => true, 'ipv6' => ipv6, 'default-nameserver' => plain, 'nameserver' => servers,
         'proxy-server-nameserver' => servers }, ipv6]
    end

    def core_config(s, sub, secret, dns, ipv6)
      names = sub['proxies'].map { |p| p['name'] }
      # 选中的节点不在了就把 REJECT 排第一：宁可不通，也不悄悄换到别的国家。
      first = names.include?(s['target']) || s['target'] == 'DIRECT' ? s['target'] : 'REJECT'
      users = [{ 'username' => s['username'], 'password' => s['password'] }]
      {
        'allow-lan' => false, 'mode' => 'rule', 'log-level' => 'warning', 'ipv6' => ipv6,
        'unified-delay' => true, 'tcp-concurrent' => true,
        'external-controller' => "127.0.0.1:#{CORE_API_PORT}", 'secret' => secret,
        'profile' => { 'store-selected' => true },
        # 不写 enhanced-mode：普通 DNS 模式，不做 IP→域名反查；不嗅探。DNS 只用来解析节点服务器和直连目标。
        'dns' => dns, 'sniffer' => { 'enable' => false },
        'proxies' => sub['proxies'] + [{
          'name' => SHIM_PROXY, 'type' => 'socks5', 'server' => '127.0.0.1', 'port' => SHIM_PORT,
          'username' => s['username'], 'password' => s['password'], 'udp' => s['udp']
        }],
        'proxy-groups' => [
          { 'name' => EXIT_GROUP, 'type' => 'select', 'proxies' => ([first] + names + %w[DIRECT REJECT]).uniq },
          { 'name' => MODE_GROUP, 'type' => 'select',
            'proxies' => s['ipv4_only'] ? [SHIM_PROXY, EXIT_GROUP] : [EXIT_GROUP, SHIM_PROXY] }
        ],
        'listeners' => [
          { 'name' => LISTENER, 'type' => 'socks', 'port' => s['port'], 'listen' => s['listen'], 'udp' => s['udp'],
            'users' => users, 'proxy' => MODE_GROUP },
          { 'name' => UP_LISTENER, 'type' => 'socks', 'port' => UP_PORT, 'listen' => '127.0.0.1', 'udp' => s['udp'],
            'users' => users, 'proxy' => EXIT_GROUP }
        ],
        'rules' => ['MATCH,REJECT']
      }
    end

    def shim_profile(s)
      users = [{ 'username' => s['username'], 'password' => s['password'] }]
      rules = [
        { 'ip_version' => 6, 'action' => 'reject' },
        { 'network' => 'tcp', 'port' => 80, 'action' => 'reject' },
        { 'network' => 'udp', 'port' => 443, 'action' => 'reject' }
      ]
      rules << { 'network' => 'udp', 'action' => 'reject' } unless s['udp']
      rules.concat([
        { 'action' => 'sniff', 'sniffer' => %w[http tls quic], 'timeout' => '400ms' },
        { 'protocol' => %w[http quic], 'action' => 'reject' },
        { 'action' => 'resolve', 'server' => 'exit-dns', 'strategy' => 'ipv4_only' },
        { 'network' => 'tcp', 'ip_cidr' => ['0.0.0.0/0'], 'action' => 'route', 'outbound' => 'up',
          'tls_record_fragment' => true },
        { 'network' => 'udp', 'ip_cidr' => ['0.0.0.0/0'], 'action' => 'route', 'outbound' => 'up' },
        { 'action' => 'reject' }
      ])
      {
        'log' => { 'disabled' => true },
        'dns' => { 'servers' => [{ 'type' => 'https', 'tag' => 'exit-dns', 'server' => '1.1.1.1', 'detour' => 'up' }],
                   'final' => 'exit-dns' },
        'inbounds' => [{ 'type' => 'socks', 'tag' => 'in', 'listen' => '127.0.0.1', 'listen_port' => SHIM_PORT,
                         'users' => users }],
        'outbounds' => [{ 'type' => 'socks', 'tag' => 'up', 'server' => '127.0.0.1', 'server_port' => UP_PORT,
                          'version' => '5', 'username' => s['username'], 'password' => s['password'] }],
        'route' => { 'rules' => rules, 'final' => 'up' }
      }
    end

    def shim_bytes(s)
      R3MiniSocks5.json(shim_profile(s)) + "\n"
    end

    def core_meta
      file = path(CORE_META)
      return {} unless File.file?(file)

      data = parse_json(File.read(file), 'NOT_APPLIED')
      data.is_a?(Hash) ? data : {}
    rescue Failure, SystemCallError
      {}
    end

    def core_endpoint
      secret = core_meta['secret']
      fail!('NOT_APPLIED') unless secret.is_a?(String) && secret.match?(/\A[0-9a-f]{32}\z/)
      ['127.0.0.1', CORE_API_PORT, secret]
    end

    def core_api(method, route, body = nil, timeout: 4)
      api(method, route, body, timeout: timeout, endpoint: core_endpoint, down: 'NOT_APPLIED', denied: 'NOT_APPLIED')
    end

    def core_proxy(name)
      code, text = core_api('GET', '/proxies/' + escape(name))
      return nil if code == 404
      fail!('NOT_APPLIED') unless code == 200

      data = parse_json(text, 'NOT_APPLIED')
      data.is_a?(Hash) ? data : nil
    end

    def core_proxies
      code, text = core_api('GET', '/proxies', timeout: 8)
      code == 200 ? proxies_of(text, 'NOT_APPLIED') : nil
    rescue Failure
      nil
    end

    def put_core(group, name)
      code, = core_api('PUT', '/proxies/' + escape(group), { 'name' => name })
      fail!('SWITCH_FAILED') unless [200, 204].include?(code)
    end

    # 写好 SOCKS5 内核和 sing-box 的配置（不启动进程）；返回 [内核配置变了, sing-box 配置变了]。
    # 内核配置不跑 `-t`（路由器上要 2 秒多）：节点是订阅里原样复制的；热重载时内核自己校验、不接受就保留
    # 旧配置，冷启动起不来会在等待就绪时报 CORE_FAILED。
    def write_files(s, sub)
      yaml!
      private_dir(@temp)
      private_dir(path(CORE_DIR))
      old = core_meta['secret']
      secret = old.is_a?(String) && old.match?(/\A[0-9a-f]{32}\z/) ? old : random_suffix + random_suffix
      dns, ipv6 = dns_settings
      core_bytes = YAML.dump(core_config(s, sub, secret, dns, ipv6))
      meta = R3MiniSocks5.json({ 'secret' => secret, 'subscription' => sub['file'], 'sub_key' => sub['key'],
                                 'settings_key' => settings_key(s), 'nodes' => sub['proxies'].length }) + "\n"
      same = ->(file, bytes) { File.file?(file) && File.binread(file) == bytes.b }
      core_changed = !same.call(path(CORE_CONFIG), core_bytes)
      shim_changed = false
      if shim_binary
        shim = shim_bytes(s)
        unless same.call(@shim_profile, shim)
          candidate = temporary(@temp, '.json') { |f| f.write(shim) }
          fail!('IPV4_SERVICE') unless system(shim_binary, 'check', '-c', candidate, out: File::NULL, err: File::NULL)
          File.rename(candidate, @shim_profile)
          shim_changed = true
        end
      elsif File.file?(@shim_profile)
        File.unlink(@shim_profile)
        shim_changed = true
      end
      atomic_write(path(CORE_CONFIG), core_bytes) if core_changed
      atomic_write(path(CORE_META), meta) unless same.call(path(CORE_META), meta)
      [core_changed, shim_changed]
    ensure
      File.unlink(candidate) if candidate && File.exist?(candidate)
    end

    def core_reload
      code, = core_api('PUT', '/configs?force=true', { 'path' => path(CORE_CONFIG) }, timeout: 20)
      [200, 204].include?(code)
    rescue Failure
      false
    end

    # 让 SOCKS5 内核（和 sing-box）按设置运行：配置变了就热重载，进程不在就启动。返回订阅数据。
    def sync_core(s)
      fail!('CORE_MISSING') unless core_binary
      file = current_sub(s)
      fail!('SUBSCRIPTION_MISSING') unless file
      sub = load_sub(file)
      core_changed, shim_changed = write_files(s, sub)
      if core_pid.nil?
        service('start')
      elsif shim_changed || (core_changed && !core_reload)
        service('restart')
      end
      ready = wait_until(12, 0.15) { core_ready?(s) }
      # 刚清理完 OpenClash 里第 2 版的入站时，端口可能还没放出来：再热重载一次让入站重新绑定。
      ready = core_reload && wait_until(6, 0.2) { core_ready?(s) } if !ready && core_pid
      fail!('CORE_FAILED') unless ready
      if shim_binary && !shim_alive?
        service('start')
        wait_until(5, 0.15) { shim_alive? }
      end
      select!(s)
      sub
    end

    def select!(s)
      group = core_proxy(EXIT_GROUP)
      fail!('CORE_FAILED') unless group
      put_core(EXIT_GROUP, s['target']) if Array(group['all']).include?(s['target']) && group['now'] != s['target']
      mode = core_proxy(MODE_GROUP)
      want = s['ipv4_only'] ? SHIM_PROXY : EXIT_GROUP
      put_core(MODE_GROUP, want) if mode && mode['now'] != want
    end

    def stop_core
      service('stop') if core_pid || shim_alive? || File.file?(path(CORE_CONFIG))
      wait_until(5, 0.2) { core_pid.nil? }
      [@shim_profile, path(CORE_CONFIG), path(CORE_META)].each { |f| File.unlink(f) if File.file?(f) }
    end

    # 订阅文件被 OpenClash 更新过、设置改过，或者内核没在跑，都需要同步。
    def core_stale?(s)
      file = current_sub(s)
      meta = core_meta
      return true unless file && core_pid && meta['subscription'] == file && meta['settings_key'] == settings_key(s)

      meta['sub_key'] != sub_key(sub_path(file))
    rescue Failure, SystemCallError
      true
    end

    # 换出口后断开 SOCKS5 内核里的全部连接（它只服务 SOCKS5），新连接立刻走新出口。
    def close_connections
      code, text = core_api('GET', '/connections', timeout: 5)
      return 0 unless code == 200

      count = text.scan(/"id":"[0-9A-Za-z-]{8,64}"/).length
      core_api('DELETE', '/connections', timeout: 5) if count.positive?
      count
    rescue Failure
      0
    end

    # ---------- 清理第 2 版留在 OpenClash 里的条目 ----------

    def backup(file)
      dir = @state + '/backups/' + Time.now.utc.strftime('%Y%m%dT%H%M%SZ') + "-#{Process.pid}-#{random_suffix}"
      mkdir_private(@state)
      mkdir_private(File.dirname(dir))
      mkdir_private(dir)
      atomic_write(dir + '/runtime.yaml', File.binread(file))
      atomic_write(dir + '/runtime.mode', (File.stat(file).mode & 0o777).to_s)
      dir
    end

    def remove_tree(dir)
      Dir.children(dir).each do |name|
        entry = dir + '/' + name
        File.directory?(entry) && !File.symlink?(entry) ? remove_tree(entry) : File.unlink(entry)
      end
      Dir.rmdir(dir)
    rescue SystemCallError
      nil
    end

    def prune_backups
      root = @state + '/backups'
      return unless File.directory?(root)

      entries = Dir.children(root).select { |n| n.match?(BACKUP_NAME) && File.directory?(root + '/' + n) }
                   .map { |n| [File.mtime(root + '/' + n), n] }.sort_by(&:first)
      entries.first([entries.length - BACKUP_KEEP, 0].max).each { |_t, n| remove_tree(root + '/' + n) }
    rescue SystemCallError
      nil
    end

    # 第 2 版把入站和出口组注入在 OpenClash 运行配置里；改由独立内核提供前清掉，让出端口（只做一次）。
    def migrate_main!
      file = runtime_path
      return false unless File.read(file).match?(LEGACY_MARK)

      yaml!
      config = runtime(file)
      cleaned = strip_own(config)
      return false if cleaned == config

      saved = backup(file)
      mode = File.stat(file).mode & 0o777
      atomic_write(file, YAML.dump(cleaned), mode)
      begin
        code, = api('PUT', '/configs?force=true', { 'path' => file }, timeout: 30)
        unless [200, 204].include?(code)
          atomic_write(file, File.binread(saved + '/runtime.yaml'), mode)
          fail!('RELOAD_FAILED')
        end
      rescue Failure => e
        # OpenClash 没在运行：文件已经清理好，它下次启动直接用。
        raise unless e.token == 'CONTROLLER_UNAVAILABLE'
      end
      prune_backups
      true
    rescue Failure => e
      raise unless e.token == 'RUNTIME_MISSING'

      false
    end

    def with_lock(wait: false)
      mkdir_private(@state)
      lockdir = path('/var/lock')
      mkdir_p(lockdir)
      lock = lockdir + '/r3mini-socks5.lock'
      fail!('IO_FAILED') if File.symlink?(lock)
      File.open(lock, File::RDWR | File::CREAT, 0o600) do |handle|
        fail!('BUSY') unless handle.flock(wait ? File::LOCK_EX : File::LOCK_EX | File::LOCK_NB)
        begin
          yield
        ensure
          handle.flock(File::LOCK_UN)
        end
      end
    end

    # ---------- 钩子（OpenClash 每次生成配置时调用） ----------

    def hook_record(token, detail = nil)
      mkdir_p(File.dirname(@temp))
      mkdir_private(@temp)
      line = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') + ' ' + token.to_s +
             (detail ? ' ' + detail.to_s.slice(0, 200) : '') + "\n"
      File.open(@hook_log, File::WRONLY | File::CREAT | File::APPEND, 0o600) { |f| f.write(line) }
    rescue SystemCallError
      nil
    end

    def hook_error
      return nil unless File.file?(@hook_log)

      tail = File.readlines(@hook_log).last.to_s.strip
      return nil if tail.empty?

      parts = tail.split(' ', 3)
      { 'time' => parts[0], 'error' => parts[1], 'message' => ERRORS[parts[1]] || '未知错误' }
    rescue SystemCallError
      nil
    end

    # OpenClash 不看钩子退出码，这里永不阻断它。只做两件事：清掉第 2 版残留的条目；订阅文件更新了就同步 SOCKS5 内核。
    def hook(candidate)
      with_lock(wait: true) { inject_hook(candidate) }
    end

    def inject_hook(candidate)
      file = runtime_path(candidate, true)
      changed = false
      if File.read(file).match?(LEGACY_MARK)
        yaml!
        config = runtime(file)
        cleaned = strip_own(config)
        if cleaned != config
          atomic_write(file, YAML.dump(cleaned), File.stat(file).mode & 0o777)
          changed = true
        end
      end
      problem = nil
      begin
        s = settings
        sync_core(s) if s['enabled'] && !s['password'].empty? && core_stale?(s)
      rescue Failure => e
        problem = e.token
      end
      if problem
        hook_record(problem)
      elsif File.exist?(@hook_log)
        File.unlink(@hook_log)
      end
      result = { 'ok' => true, 'action' => 'hook', 'changed' => changed }
      result['error'] = problem if problem
      result
    rescue Failure => e
      hook_record(e.token)
      { 'ok' => true, 'action' => 'hook', 'changed' => false, 'skipped' => true, 'error' => e.token }
    rescue StandardError => e
      hook_record('INTERNAL_ERROR', e.class.name)
      { 'ok' => true, 'action' => 'hook', 'changed' => false, 'skipped' => true, 'error' => 'INTERNAL_ERROR' }
    end

    # ---------- 写操作 ----------

    def apply_settings(payload, action)
      with_lock do
        s = settings
        desired = action == 'save' ? merge_settings(s, payload) : s.dup
        desired['enabled'] = true if action == 'enable'
        desired['enabled'] = false if action == 'disable'
        desired['subscription'] = current_sub(desired).to_s if desired['subscription'].to_s.empty?
        begin
          if desired['enabled']
            validate_settings!(desired)
            sub = load_sub(desired['subscription'])
            if payload.key?('target') || payload.key?('subscription')
              names = sub['proxies'].map { |p| p['name'] }
              fail!('TARGET_MISSING') unless desired['target'] == 'DIRECT' || names.include?(desired['target'])
            end
            fail!('CORE_MISSING') unless core_binary
            fail!('SHIM_MISSING') if desired['ipv4_only'] && shim_binary.nil?
            migrate_main!
            fail!('PORT_IN_USE') if check_port(desired['port'])['occupied']
            begin
              sync_core(desired)
            rescue Failure
              begin
                s['enabled'] && !s['password'].empty? ? sync_core(s) : stop_core
              rescue Failure, SystemCallError
                nil
              end
              raise
            end
          else
            stop_core
            migrate_main!
          end
          save_settings(stamp(desired, action))
        rescue SystemCallError, IOError
          fail!('IO_FAILED')
        end
        status.merge('action' => action)
      end
    end

    def use(name_arg, file_arg = nil)
      name = decode_arg(name_arg)
      validate_target_format!(name)
      file = file_arg ? decode_arg(file_arg) : nil
      with_lock do
        s = settings
        fail!('DISABLED') unless s['enabled']
        current = current_sub(s)
        if file && file != current
          names = load_sub(file)['proxies'].map { |p| p['name'] }
          fail!('TARGET_MISSING') unless name == 'DIRECT' || names.include?(name)
          desired = s.merge('subscription' => file, 'target' => name)
          begin
            sync_core(desired)
          rescue Failure
            begin
              sync_core(s)
            rescue Failure
              nil
            end
            raise
          end
        else
          group = core_proxy(EXIT_GROUP)
          fail!('NOT_APPLIED') unless group
          fail!('TARGET_MISSING') unless Array(group['all']).include?(name) && name != 'REJECT'
          put_core(EXIT_GROUP, name) unless group['now'] == name
          desired = s.merge('target' => name, 'subscription' => current.to_s)
        end
        save_settings(stamp(desired, 'use'))
        closed = close_connections
        status.merge('action' => 'use', 'closed' => closed)
      end
    end

    def ipv4(value)
      flag = { 'on' => true, '1' => true, 'true' => true, 'off' => false, '0' => false, 'false' => false }[value]
      fail!('ARGUMENT_INVALID') if flag.nil?
      with_lock do
        s = settings
        fail!('DISABLED') unless s['enabled']
        fail!('SHIM_MISSING') if flag && shim_binary.nil?
        mode = core_proxy(MODE_GROUP)
        fail!('NOT_APPLIED') unless mode
        if flag && !shim_alive?
          sync_core(s)
          fail!('IPV4_SERVICE') unless shim_alive?
        end
        put_core(MODE_GROUP, flag ? SHIM_PROXY : EXIT_GROUP)
        save_settings(stamp(s.merge('ipv4_only' => flag), 'ipv4'))
        closed = close_connections
        status.merge('action' => 'ipv4', 'closed' => closed)
      end
    end

    def reset
      with_lock do
        stop_core
        begin
          migrate_main!
        rescue Failure => e
          raise unless %w[RUNTIME_INVALID CONTROLLER_INVALID RELOAD_FAILED].include?(e.token)
        end
        File.unlink(@settings_path) if File.exist?(@settings_path)
        { 'ok' => true, 'action' => 'reset', 'note' => '设置已清空，SOCKS5 已停止；重新保存即可启用。' }
      end
    end

    # ---------- 查询 ----------

    def broken_status(token)
      {
        'ok' => true, 'version' => VERSION, 'enabled' => false, 'applied' => false,
        'port' => nil, 'listen' => nil, 'username' => nil, 'password_set' => false, 'password_length' => 0,
        'target' => nil, 'udp' => false, 'ipv4_only' => false, 'last_action' => nil, 'last_time' => nil,
        'subscription' => nil, 'reserved_ports' => reserved_ports, 'listen_options' => allowed_listen,
        'hook_error' => nil, 'error' => token, 'message' => ERRORS[token],
        'listener' => { 'live' => false, 'port_matches' => false, 'controller' => false, 'in_config' => false }
      }
    end

    def sub_status(file, meta)
      info = { 'file' => file, 'name' => file&.sub(/\.ya?ml\z/, ''), 'exists' => false, 'active' => false,
               'stale' => false, 'nodes' => meta['subscription'] == file ? meta['nodes'] : nil }
      return info unless file

      info['active'] = file == active_file
      full = sub_path(file)
      info['exists'] = true
      info['stale'] = meta['subscription'] == file && meta['sub_key'].is_a?(String) && meta['sub_key'] != sub_key(full)
      info
    rescue Failure, SystemCallError
      info
    end

    def status
      begin
        s = settings
      rescue Failure => e
        return broken_status(e.token)
      end
      file = current_sub(s)
      meta = core_meta
      result = {
        'ok' => true, 'version' => VERSION, 'enabled' => s['enabled'], 'applied' => false,
        'port' => s['port'], 'listen' => s['listen'], 'username' => s['username'],
        'password_set' => !s['password'].empty?, 'password_length' => s['password'].length,
        'target' => s['target'], 'udp' => s['udp'], 'ipv4_only' => s['ipv4_only'],
        'subscription' => sub_status(file, meta),
        'last_action' => s['last_action'], 'last_time' => s['last_time'],
        'reserved_ports' => reserved_ports, 'listen_options' => allowed_listen,
        'hook_error' => hook_error, 'error' => nil
      }
      begin
        pid = core_pid
        port = port_state(s['port'])
        live = !pid.nil? && port['owner'].is_a?(Hash) && port['owner']['pid'] == pid
        exit_group = pid ? core_proxy(EXIT_GROUP) : nil
        mode_group = pid ? core_proxy(MODE_GROUP) : nil
        exit_now = exit_group && exit_group['now']
        node = exit_now && !%w[DIRECT REJECT].include?(exit_now) ? core_proxy(exit_now) : nil
        target_ok = exit_group ? Array(exit_group['all']).include?(s['target']) : true
        shim = shim_alive?
        config_ok = !pid.nil? && meta['subscription'] == file && meta['settings_key'] == settings_key(s)
        want_mode = s['ipv4_only'] ? SHIM_PROXY : EXIT_GROUP
        mode_now = mode_group && mode_group['now']
        delay = last_delay(node)
        # SOCKS5 内核还没测过这个节点时，借用 OpenClash 最近一次的测速（同一订阅时节点完全相同）。
        delay = last_delay(main_proxy(exit_now)) if delay.nil? && node && result['subscription']['active']
        result['exit'] = {
          'now' => exit_now, 'type' => node ? node['type'] : (exit_now == 'DIRECT' ? 'Direct' : nil),
          'alive' => node ? node['alive'] : nil, 'delay' => delay,
          'members' => exit_group ? [Array(exit_group['all']).length - 2, 0].max : 0
        }
        result['mode'] = mode_now
        result['shim'] = { 'running' => shim, 'binary' => !shim_binary.nil?, 'port' => SHIM_PORT }
        result['core'] = { 'running' => !pid.nil?, 'binary' => !core_binary.nil? }
        result['listener'] = { 'live' => live, 'port_matches' => !port['free'], 'owner' => port['owner'],
                               'protocols' => port['protocols'], 'controller' => !pid.nil?, 'in_config' => config_ok }
        result['applied'] = s['enabled'] && live && config_ok && target_ok && exit_now == s['target'] &&
                            mode_now == want_mode && (!s['ipv4_only'] || shim)
        result['error'] =
          if s['enabled']
            if !result['subscription']['exists'] then 'SUBSCRIPTION_MISSING'
            elsif pid.nil? then 'NOT_APPLIED'
            elsif !live then port['free'] ? 'NOT_APPLIED' : 'PORT_IN_USE'
            elsif !target_ok then 'TARGET_MISSING'
            elsif s['ipv4_only'] && !shim then 'IPV4_SERVICE'
            elsif !result['applied'] then 'STATE_MISMATCH'
            end
          elsif pid
            'STATE_MISMATCH'
          end
      rescue Failure => e
        result['listener'] = { 'live' => false, 'port_matches' => false, 'controller' => false, 'in_config' => false }
        result['error'] = s['enabled'] ? e.token : nil
      end
      result['message'] = ERRORS[result['error']] if result['error']
      result
    end

    # 节点清单直接读订阅文件（缓存过），延迟取 SOCKS5 内核最近一次测速；同一订阅正被 OpenClash 用着时，
    # 没测过的节点借用 OpenClash 的测速结果。
    def targets(arg = nil)
      s = settings
      current = current_sub(s)
      file = arg ? decode_arg(arg) : current
      subs = subscriptions(current)
      fail!('SUBSCRIPTION_MISSING') unless file && subs.any? { |x| x['file'] == file }
      sub = load_sub(file)
      delays = {}
      now = nil
      if file == current && s['enabled'] && (data = core_proxies)
        sub['proxies'].each do |p|
          info = data[p['name']]
          delays[p['name']] = [last_delay(info), info['alive']] if info.is_a?(Hash)
        end
        now = data.dig(EXIT_GROUP, 'now')
      end
      if file == active_file && sub['proxies'].any? { |p| delays.dig(p['name'], 0).nil? } && (main = main_proxies)
        sub['proxies'].each do |p|
          next unless delays.dig(p['name'], 0).nil? && main[p['name']].is_a?(Hash)

          delays[p['name']] = [last_delay(main[p['name']]), main[p['name']]['alive']]
        end
      end
      nodes = sub['proxies'].map do |p|
        delay, alive = delays[p['name']]
        { 'name' => p['name'], 'type' => type_name(p['type']), 'delay' => delay, 'alive' => alive != false }
      end
      { 'ok' => true, 'file' => file, 'current' => file == current ? (now || s['target']) : nil,
        'subscriptions' => subs, 'nodes' => nodes, 'builtins' => ['DIRECT'] }
    end

    # 测一个节点的延迟。SOCKS5 正在用的订阅由 SOCKS5 内核测；OpenClash 正在用的订阅可以让 OpenClash 测
    # （两边节点完全相同）；其余订阅没有内核装着它的节点，测不了。
    def delay(arg = nil, file_arg = nil)
      s = settings
      current = current_sub(s)
      file = file_arg ? decode_arg(file_arg) : current
      name = arg ? decode_arg(arg) : core_proxy(EXIT_GROUP)&.dig('now')
      fail!('NOT_APPLIED') unless name
      validate_target_format!(name)
      route = "/proxies/#{escape(name)}/delay?timeout=5000&url=#{escape(TEST_URL)}"
      by = if file == current && s['enabled'] && core_pid then 'socks5'
           elsif file == active_file then 'openclash'
           else fail!('DELAY_UNAVAILABLE')
           end
      code, text = by == 'socks5' ? core_api('GET', route, timeout: 9) : api('GET', route, timeout: 9)
      data = code == 200 ? parse_json(text, 'DELAY_FAILED') : nil
      if data.is_a?(Hash) && data['delay'].is_a?(Integer) && data['delay'].positive?
        { 'ok' => true, 'action' => 'delay', 'name' => name, 'file' => file, 'by' => by, 'delay' => data['delay'] }
      else
        { 'ok' => false, 'action' => 'delay', 'name' => name, 'file' => file, 'by' => by,
          'error' => 'DELAY_FAILED', 'message' => ERRORS['DELAY_FAILED'] }
      end
    end

    # 让 SOCKS5 内核把当前订阅的节点全测一遍（内核自己并发测，几秒）。
    def delay_all
      s = settings
      fail!('DISABLED') unless s['enabled']
      code, text = core_api('GET', "/group/#{escape(EXIT_GROUP)}/delay?timeout=5000&url=#{escape(TEST_URL)}", timeout: 30)
      data = code == 200 ? parse_json(text, 'DELAY_FAILED') : nil
      fail!('DELAY_FAILED') unless data.is_a?(Hash)
      delays = data.select { |k, v| v.is_a?(Integer) && v.positive? && !%w[DIRECT REJECT].include?(k) && k != SHIM_PROXY }
      { 'ok' => true, 'action' => 'delay-all', 'file' => current_sub(s), 'delays' => delays }
    end

    # ---------- 经 SOCKS5 实测 ----------

    def socks_endpoint(s)
      host = s['listen'] == '0.0.0.0' ? '127.0.0.1' : s['listen']
      "#{host}:#{s['port']}"
    end

    # 凭据经标准输入的 curl 配置传入，不出现在进程表里。
    def socks_open(s, url, extra = [])
      curl = path('/usr/bin/curl')
      fail!('PROBE_TOOL_MISSING') unless File.executable?(curl)
      argv = [curl, '-q', '-K', '-', '--silent', '--noproxy', '', '--socks5-hostname', socks_endpoint(s),
              '--connect-timeout', '6', '--max-time', '12'] + extra + [url]
      io = IO.popen(argv, 'r+', err: File::NULL)
      secret = "#{s['username']}:#{s['password']}".gsub('\\', '\\\\\\\\').gsub('"', '\\"')
      io.write("proxy-user = \"#{secret}\"\n")
      io.close_write
      io
    end

    def drain(io, limit, stop = nil)
      buffer = +''.b
      while buffer.bytesize < limit
        chunk = io.readpartial(16_384)
        buffer << chunk
        break if stop && buffer.match?(stop)
      end
      buffer
    rescue EOFError, IOError
      buffer
    ensure
      begin
        io.close
      rescue IOError, SystemCallError
        nil
      end
    end

    def family(ip)
      return nil unless ip.is_a?(String) && !ip.empty?

      ip.include?(':') ? 'IPv6' : 'IPv4'
    end

    # 各家同时测；全部失败时隔 1 秒再测一次（节点偶发抖动、刚开仅 IPv4 时 DNS 还没热）。
    def probe
      first = probe_once
      return first if first['ok']

      sleep 1
      probe_once
    end

    def region_check(id, name, note, ip, region, detail = nil)
      region = nil unless region.to_s.match?(/\A[A-Z]{2}\z/)
      ip = nil unless ip.to_s.match?(/\A[0-9a-fA-F:.]{2,45}\z/)
      detail = detail.to_s.strip
      { 'id' => id, 'name' => name, 'note' => note, 'ok' => !(ip.nil? && region.nil?), 'ip' => ip,
        'family' => family(ip), 'region' => region, 'detail' => detail.empty? ? nil : detail.slice(0, 80) }
    end

    def json_field(text, key)
      text[/"#{Regexp.escape(key)}"\s*:\s*"([^"\\]{0,120})"/, 1]
    end

    # 网站各自查地区：Google 用自己的库，Cloudflare 站点（ChatGPT 等）按 Cloudflare，App Store 按 Apple，
    # 其余多数网站和指纹浏览器查 IP 地址库（ipinfo、MaxMind）。同一出口各家可能判得不一样。
    def probe_once
      s = settings
      fail!('DISABLED') unless s['enabled']
      fail!('PASSWORD_REQUIRED') if s['password'].empty?
      started = monotonic
      gl = /INNERTUBE_CONTEXT_GL":"([A-Z]{2})"/n
      ios = {
        'google' => socks_open(s, GOOGLE_URL),
        # 设备上的 curl 不支持 --compressed；地区字段在页面前 100 KB 内，读到就断开。
        'youtube' => socks_open(s, YOUTUBE_URL, ['--header', 'Accept-Language: en-US,en;q=0.8']),
        'cloudflare' => socks_open(s, CLOUDFLARE_URL),
        'apple' => socks_open(s, APPLE_URL),
        'ipinfo' => socks_open(s, IPINFO_URL),
        'maxmind' => socks_open(s, MAXMIND_URL)
      }
      text = ->(key) { drain(ios[key], 8192).force_encoding(Encoding::UTF_8).scrub }
      mapping = text.call('google').lines.first.to_s.strip
      youtube = drain(ios['youtube'], 900_000, gl)[gl, 1]
      trace = text.call('cloudflare')
      apple = text.call('apple').strip
      info = text.call('ipinfo')
      mm = text.call('maxmind')
      google_ip = mapping[/\A([0-9a-fA-F:.]+)\s*=>/, 1]
      cluster = mapping[/=>\s*(\S+)/, 1]
      cf_ip = trace[/^ip=([0-9a-fA-F:.]+)$/, 1]
      cf_loc = trace[/^loc=([A-Z]{2})$/, 1]
      checks = [
        region_check('google', 'Google', 'YouTube、Google Play、Google 搜索', google_ip, youtube,
                     cluster && "节点 #{cluster}"),
        region_check('cloudflare', 'Cloudflare', '套了 Cloudflare 的网站（如 ChatGPT）', cf_ip, cf_loc,
                     trace[/^colo=([A-Z]{3})$/, 1]&.then { |c| "机房 #{c}" }),
        region_check('apple', 'Apple', 'App Store、Apple ID', nil, apple[/\A([A-Z]{2})\z/, 1]),
        region_check('ipinfo', 'ipinfo', '常用 IP 地址库', json_field(info, 'ip'), json_field(info, 'country'),
                     [json_field(info, 'org'), json_field(info, 'city')].compact.join(' · ')),
        region_check('maxmind', 'MaxMind', 'IP 地址库（广告、风控常用；经 ifconfig.co 查）', json_field(mm, 'ip'),
                     json_field(mm, 'country_iso'), [json_field(mm, 'asn_org'), json_field(mm, 'city')].compact.join(' · '))
      ]
      exit_now = begin
        core_proxy(EXIT_GROUP)&.dig('now')
      rescue Failure
        nil
      end
      result = {
        'ok' => checks.any? { |c| c['ok'] }, 'action' => 'probe',
        'elapsed_ms' => ((monotonic - started) * 1000).round, 'exit' => exit_now, 'ipv4_only' => s['ipv4_only'],
        'checks' => checks,
        'google' => { 'ip' => google_ip, 'family' => family(google_ip), 'cluster' => cluster, 'region' => youtube },
        'cloudflare' => { 'ip' => cf_ip, 'family' => family(cf_ip), 'region' => cf_loc }
      }
      unless result['ok']
        result['error'] = 'PROBE_FAILED'
        result['message'] = ERRORS['PROBE_FAILED']
      end
      result
    end

    def verify
      s = settings
      result = { 'ok' => false, 'action' => 'verify', 'http_code' => 0, 'listener' => LISTENER,
                 'target' => s['target'], 'port' => s['port'] }
      fail!('PASSWORD_REQUIRED') if s['password'].empty?
      fail!('DISABLED') unless s['enabled']
      current = status
      fail!(current['error']) if %w[NOT_APPLIED PORT_IN_USE TARGET_MISSING IPV4_SERVICE SUBSCRIPTION_MISSING].include?(current['error'])

      code = drain(socks_open(s, TEST_URL, ['--output', File::NULL, '--write-out', '%{http_code}']), 64).to_i
      result['http_code'] = code
      result['ok'] = code.between?(200, 399)
      if result['ok'] && s['ipv4_only']
        google = socks_open(s, GOOGLE_URL)
        cloudflare = socks_open(s, CLOUDFLARE_URL)
        ip = drain(google, 4096).force_encoding(Encoding::UTF_8).scrub[/\A([0-9a-fA-F:.]+)\s*=>/, 1]
        cf = drain(cloudflare, 4096).force_encoding(Encoding::UTF_8).scrub[/^ip=([0-9a-fA-F:.]+)$/, 1]
        result['google_ip'] = ip
        result['cloudflare_ip'] = cf
        result['google_ipv4'] = ip if family(ip) == 'IPv4'
        result['ok'] = family(ip) == 'IPv4' && family(cf) == 'IPv4'
      end
      unless result['ok']
        result['error'] = 'PROBE_FAILED'
        result['message'] = ERRORS['PROBE_FAILED']
      end
      result
    rescue Failure => e
      (result || {}).merge('ok' => false, 'action' => 'verify', 'error' => e.token, 'message' => ERRORS[e.token])
    end

    # 开机时 /tmp 是空的：procd 服务启动前由它按设置生成配置。不拿锁——后端持锁启动服务时文件都已写好，
    # 服务不会回调这里。
    def prepare
      s = settings
      file = current_sub(s)
      if s['enabled'] && !s['password'].empty? && core_binary && file
        write_files(s, load_sub(file))
        { 'ok' => true, 'action' => 'prepare', 'written' => true }
      else
        [@shim_profile, path(CORE_CONFIG), path(CORE_META)].each { |f| File.unlink(f) if File.file?(f) }
        { 'ok' => false, 'action' => 'prepare', 'written' => false, 'error' => 'DISABLED', 'message' => ERRORS['DISABLED'] }
      end
    end

    def run(argv)
      command = argv[0]
      arity = { 'status' => [1], 'targets' => [1, 2], 'check-port' => [2], 'save' => [2], 'apply' => [1],
                'enable' => [1], 'disable' => [1], 'reset' => [1], 'verify' => [1], 'probe' => [1],
                'use' => [2, 3], 'ipv4' => [2], 'hook' => [2], 'prepare' => [1],
                'delay' => [1, 2, 3], 'delay-all' => [1] }
      fail!('ARGUMENT_INVALID') unless arity.fetch(command, []).include?(argv.length)

      case command
      when 'status' then status
      when 'targets' then targets(argv[1])
      when 'check-port' then { 'ok' => true }.merge(check_port(argv[1]))
      when 'save'
        body = decode_arg(argv[1])
        fail!('ARGUMENT_INVALID') unless body.bytesize <= 16 * 1024
        payload = JsonReader.new(body).read
        fail!('ARGUMENT_INVALID') unless payload.is_a?(Hash)
        apply_settings(payload, 'save')
      when 'apply', 'enable', 'disable' then apply_settings({}, command)
      when 'reset' then reset
      when 'verify' then verify
      when 'probe' then probe
      when 'use' then use(argv[1], argv[2])
      when 'ipv4' then ipv4(argv[1])
      when 'hook' then hook(argv[1])
      when 'prepare' then prepare
      when 'delay' then delay(argv[1], argv[2])
      when 'delay-all' then delay_all
      end
    end
  end

  def self.main(argv)
    result = App.new.run(argv)
    puts json(result)
    result['ok'] ? 0 : 1
  rescue Failure => e
    puts json({ 'ok' => false, 'error' => e.token, 'message' => ERRORS[e.token] || ERRORS['INTERNAL_ERROR'] })
    1
  rescue SystemCallError, IOError => e
    warn("r3mini-socks5: #{e.class}: #{e.message}") if ENV['R3MINI_SOCKS5_DEBUG'] == '1'
    puts json({ 'ok' => false, 'error' => 'IO_FAILED', 'message' => ERRORS['IO_FAILED'] })
    1
  rescue StandardError => e
    warn("r3mini-socks5: #{e.class}: #{e.message}\n#{e.backtrace&.first(6)&.join("\n")}") if ENV['R3MINI_SOCKS5_DEBUG'] == '1'
    puts json({ 'ok' => false, 'error' => 'INTERNAL_ERROR', 'message' => ERRORS['INTERNAL_ERROR'] })
    1
  end
end

exit R3MiniSocks5.main(ARGV) if $PROGRAM_NAME == __FILE__
