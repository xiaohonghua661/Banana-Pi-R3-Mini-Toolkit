#!/usr/bin/ruby
# Build one isolated, authenticated SOCKS listener from the current OpenClash node.
# Usage: ruby build_profile.rb SOURCE_YAML SETTINGS_YAML OUTPUT_YAML
# --stdin accepts a YAML mapping with source/settings and prints YAML without writing.
require 'yaml'

def build_profile(source, settings)
  address = settings.fetch('listen')
  octets = address.split('.', -1)
  valid = octets.length == 4 && octets.all? { |part| part.match?(/\A[0-9]{1,3}\z/) && (0..255).include?(part.to_i) }
  raise 'LISTEN_ADDRESS_MUST_BE_SPECIFIC_IPV4' unless valid && octets.map(&:to_i).join('.') == address && address != '0.0.0.0'
  port = Integer(settings.fetch('port'))
  raise 'PORT_OUT_OF_RANGE' unless (1024..65_535).include?(port)
  username = settings.fetch('username')
  password = settings.fetch('password')
  raise 'INVALID_SOCKS_USERNAME' unless username.match?(/\A[A-Za-z0-9_.-]{1,64}\z/)
  raise 'INVALID_SOCKS_PASSWORD' unless (12..128).include?(password.bytesize)
  wanted = settings.fetch('proxy-name')
  node = (source['proxies'] || []).find { |item| item['name'] == wanted }
  node = Marshal.load(Marshal.dump(node)) if node
  node['name'] = 'PH_FIXED' if node
  outbound = node ? 'PH_FIXED' : 'REJECT'
  # The router's port 53 returns fake IPs for browser traffic. Node bootstrap
  # must use the subscription's real node resolvers, as the main core does.
  source_dns = source['dns'] || {}
  bootstrap = source_dns['default-nameserver']
  bootstrap = ['223.5.5.5', '119.29.29.29'] unless bootstrap.is_a?(Array) && !bootstrap.empty?
  node_dns = source_dns['proxy-server-nameserver']
  node_dns = bootstrap unless node_dns.is_a?(Array) && !node_dns.empty?
  bootstrap = Marshal.load(Marshal.dump(bootstrap))
  node_dns = Marshal.load(Marshal.dump(node_dns))
  {
    'mode' => 'rule', 'log-level' => 'error', 'ipv6' => false,
    'allow-lan' => true, 'bind-address' => address,
    'profile' => { 'store-selected' => false, 'store-fake-ip' => false },
    'dns' => {
      'enable' => !node.nil?, 'ipv6' => false, 'enhanced-mode' => 'redir-host',
      'default-nameserver' => bootstrap,
      'proxy-server-nameserver' => node_dns,
      'nameserver' => ["https://1.1.1.1/dns-query##{outbound}"]
    },
    'proxies' => node ? [node] : [],
    'listeners' => [{
      'name' => 'adspower-ph', 'type' => 'socks', 'listen' => address,
      'port' => port, 'udp' => false, 'proxy' => outbound,
      'users' => [{ 'username' => username, 'password' => password }]
    }],
    'rules' => ["MATCH,#{outbound}"]
  }
end

begin
  if ARGV == ['--stdin']
    input = YAML.load(STDIN.read, aliases: true)
    STDOUT.write(YAML.dump(build_profile(input.fetch('source'), input.fetch('settings'))))
  elsif ARGV.length == 3
    source = YAML.load_file(ARGV[0], aliases: true)
    settings = YAML.load_file(ARGV[1], aliases: true)
    result = build_profile(source, settings)
    temporary = ARGV[2] + '.new'
    File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(YAML.dump(result)) }
    File.chmod(0o600, temporary)
    File.rename(temporary, ARGV[2])
  else
    warn 'usage: ruby build_profile.rb SOURCE_YAML SETTINGS_YAML OUTPUT_YAML | --stdin'
    exit 2
  end
rescue StandardError => error
  begin
    File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
  rescue StandardError
    # Preserve the original error; deployment rollback also removes this file.
  end
  # Error classes identify failures without logging nodes, credentials or remote data.
  warn "PROFILE_BUILD_FAILED:#{error.class}"
  exit 1
end
