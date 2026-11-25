'use strict';
// 上网出口页面的状态：一个进程读完，不调外部命令（实测约 20–50 ms）。
//   ucode status.uc          页面每 5 秒读一次的状态
//   ucode status.uc debug    调试面板：发现的问题、诊断数据、本模块日志与系统无线日志（只在面板打开时读）
// 由 /usr/sbin/r3mini-hotspot-web status|debug 调用；测试时用环境变量 R3HS_CONF_DIR、R3HS_STATE_DIR 等换目录。

import { cursor } from 'uci';
import { connect } from 'ubus';
import { readfile, access, stat, popen } from 'fs';

const conf_dir = getenv('R3HS_CONF_DIR');
const state_dir = getenv('R3HS_STATE_DIR') || '/tmp';
const sysnet = getenv('R3HS_SYSNET') || '/sys/class/net';
// 测试时用文件代替 hostapd 报告的 AP 状态：<目录>/<网卡名> 里写 ENABLED、DISABLED 等。
const ap_state_dir = getenv('R3HS_AP_STATE_DIR');
const uci = conf_dir ? cursor(conf_dir, conf_dir + '/.uci') : cursor();
const bus = connect();
const now = time();

function call(object, method, args) {
	const reply = bus ? bus.call(object, method, args) : null;
	return reply ?? {};
}

function cfg(name, fallback) {
	const value = uci.get('r3mini_hotspot', 'main', name);
	return value == null || value == '' ? fallback : value;
}

function uint(value, fallback) {
	const n = +value;
	return type(value) != null && match(`${value}`, /^[0-9]+$/) ? n : fallback;
}

const dump = call('network.interface', 'dump').interface ?? [];
function iface(name) {
	if (!name)
		return null;
	for (let i in dump)
		if (i.interface == name)
			return i;
	return null;
}
function ipv4(i) { return i?.['ipv4-address']?.[0]?.address ?? ''; }
function online(i) { return !!(i?.up && ipv4(i)); }

// 蜂窝接口：按协议找第一个（与 r3mini-hotspot-web 的 cellular_interface 一致）。
let cell = null;
uci.foreach('network', 'interface', (s) => {
	if (cell == null && s['.name'] != 'wwan' && index(['3g', 'ncm', 'qmi', 'mbim', 'quectel', 'modemmanager'], s.proto) >= 0)
		cell = s['.name'];
});

// 内核实际使用的默认路由：/proc/net/route 里 metric 最小的 0.0.0.0/0。
function default_device() {
	let best = null, best_metric = null;
	for (let line in split(readfile('/proc/net/route') ?? '', '\n')) {
		const f = split(line, '\t');
		if (length(f) < 8 || f[1] != '00000000' || f[7] != '00000000')
			continue;
		const metric = +f[6];
		if (best == null || metric < best_metric) {
			best = trim(f[0]);
			best_metric = metric;
		}
	}
	return best ?? '';
}

const wan = iface('wan'), wwan = iface('wwan'), cellular = iface(cell);
const dev = default_device();
let egress = { kind: 'none', iface: '', device: dev, ip: '', gateway: '' };
if (dev) {
	if (wan?.l3_device == dev)
		egress = { kind: 'wan', iface: 'wan', device: dev, ip: ipv4(wan), gateway: filter(wan.route ?? [], r => r.target == '0.0.0.0')[0]?.nexthop ?? '' };
	else if (wwan?.l3_device == dev)
		egress = { kind: 'hotspot', iface: 'wwan', device: dev, ip: ipv4(wwan), gateway: filter(wwan.route ?? [], r => r.target == '0.0.0.0')[0]?.nexthop ?? '' };
	else if (cell && cellular?.l3_device == dev)
		egress = { kind: 'cellular', iface: cell, device: dev, ip: ipv4(cellular), gateway: '' };
	else
		egress = { kind: 'other', iface: dev, device: dev, ip: '', gateway: '' };
}

// Wi-Fi 上网（STA）
const sta = uci.get_all('wireless', 'r3mini_phone_sta') ?? {};
let link = {};
if (wwan?.l3_device)
	link = call('iwinfo', 'info', { device: wwan.l3_device });
const wifi_up = online(wwan) && link.ssid != null && link.ssid != '';
const wifi_enabled = cfg('enabled', '0') == '1';
// 看门狗在对方长时间不在时会把 STA 停掉（停靠），让同频段的本机 Wi-Fi 恢复。
const wifi_parked = wifi_enabled && sta.disabled == '1';

// hostapd 报告的 AP 状态。STA 开着却没连上时，OpenWrt 会让 hostapd 停掉同频段的 AP（状态变成 DISABLED）。
function ap_state(ifname) {
	if (ap_state_dir)
		return trim(readfile(ap_state_dir + '/' + ifname) ?? '');
	return call('hostapd.' + ifname, 'get_status').status ?? '';
}

// 本机各频段：AP 接口与实际信道
const wstatus = call('network.wireless', 'status');
let radios = [];
uci.foreach('wireless', 'wifi-device', (r) => {
	const name = r['.name'];
	let ap_section = null;
	uci.foreach('wireless', 'wifi-iface', (s) => {
		if (ap_section == null && s.device == name && s.mode == 'ap' && s.disabled != '1')
			ap_section = s;
	});
	let ap = '';
	for (let i in wstatus?.[name]?.interfaces ?? [])
		if (ap_section && i.section == ap_section['.name'] && i.ifname)
			ap = i.ifname;
	// 网卡不在：AP 没起来。网卡在但 hostapd 没报 ENABLED：AP 暂停或停止。
	// 网卡不在时 iwinfo 可能给出假信道，只在网卡存在时信它。
	const ap_exists = !!(ap && access(sysnet + '/' + ap));
	const state = ap_exists ? ap_state(ap) : '';
	const info = ap_exists ? call('iwinfo', 'info', { device: ap }) : {};
	push(radios, {
		name,
		band: r.band ?? '',
		channel: `${info.channel ?? r.channel ?? ''}`,
		ap,
		ap_ssid: ap_section?.ssid ?? '',
		has_ap: ap_section != null,
		ap_up: ap_exists,
		ap_state: state,
		ap_paused: ap_exists && state != 'ENABLED',
		disabled: r.disabled == '1'
	});
});

// 后台任务
let job = null;
const raw = readfile(state_dir + '/r3mini-hotspot-job.json');
if (raw) {
	const j = json(raw);
	if (type(j) == 'object') {
		let state = j.state, message = j.message;
		if (state == 'running' && !(j.pid > 0 && access('/proc/' + j.pid))) {
			state = 'failed';
			message = '任务进程意外退出；请检查 Wi-Fi 设置后重试';
		}
		if (state == 'running' || !(j.finished > 0) || now - j.finished <= 600)
			job = { id: j.id, action: j.action, state, step: j.step, message, started: j.started, updated: j.updated };
	}
}

const preferred = cfg('preferred_egress', 'auto');

const result = {
	version: 2,
	now,
	preferred: index(['auto', 'wan', 'cellular', 'hotspot'], preferred) >= 0 ? preferred : 'auto',
	egress,
	wan: { present: wan != null, up: online(wan), ip: ipv4(wan), device: wan?.l3_device ?? '' },
	cellular: {
		present: cell != null,
		iface: cell ?? '',
		up: online(cellular),
		ip: ipv4(cellular),
		auto: cell == null || uci.get('network', cell, 'auto') != '0',
		dialing: !!cellular?.pending
	},
	wifi: {
		enabled: wifi_enabled,
		parked: wifi_parked,
		ssid: sta.ssid ?? '',
		radio: sta.device ?? cfg('radio', ''),
		encryption: sta.encryption ?? '',
		key_set: !!sta.key,
		up: wifi_up,
		ip: ipv4(wwan),
		device: wwan?.l3_device ?? '',
		signal: wifi_up ? link.signal : null,
		channel: wifi_up ? link.channel : null,
		target_channel: cfg('target_channel', '')
	},
	radios,
	reconnect: {
		interval: uint(cfg('check_interval'), 20),
		limit: uint(cfg('failure_limit'), 3),
		cooldown: uint(cfg('cooldown'), 180)
	},
	job
};

if (ARGV[0] != 'debug') {
	print(sprintf('%J\n', result));
	exit(0);
}

// ---------- 调试面板 ----------

function band_name(b) { return b == '2g' ? '2.4 GHz' : b == '5g' ? '5 GHz' : (b || '?'); }

function last(list, n) { return length(list) > n ? slice(list, length(list) - n) : list; }

function lines_of(text) { return filter(split(text ?? '', '\n'), (l) => l != ''); }

// 与 log.uc 的选择一致：数据分区挂着就写那里，否则写内存盘。
function log_location() {
	const forced = getenv('R3HS_LOG_DIR');
	if (forced)
		return [forced, true];
	if (match(readfile('/proc/mounts') ?? '', /\n?[^ ]+ \/mnt\/mmcblk0p6 /))
		return ['/mnt/mmcblk0p6/r3mini-hotspot', true];
	return ['/tmp/r3mini-hotspot-log', false];
}

let problems = [];
function problem(level, text) { push(problems, { level, text }); }

// 无线服务要能进的目录（与后端 DAEMON_DIRS 同源）
let dirs = [];
for (let entry in split(getenv('R3HS_DAEMON_DIRS') ?? '/tmp:1777 /tmp/run:755', ' ')) {
	const dir = split(entry, ':')[0];
	const st = dir ? stat(dir) : null;
	if (!st)
		continue;
	const mode = sprintf('%04o', st.mode & 0o7777);
	push(dirs, { dir, mode });
	if (!st.perm?.other_exec)
		problem('error', `${dir} 的权限是 ${mode}，无线服务（hostapd、wpa_supplicant）进不去，重配后本机 Wi-Fi 会起不来`);
}

// 各频段
for (let r in radios) {
	const ws = wstatus?.[r.name] ?? {};
	if (r.has_ap && !r.disabled && !r.ap_up)
		problem('error', `本机 ${band_name(r.band)} Wi-Fi「${r.ap_ssid}」的网卡 ${r.ap || '?'} 不存在，AP 没起来`);
	else if (r.ap_paused)
		problem('warn', `本机 ${band_name(r.band)} Wi-Fi「${r.ap_ssid}」没在发射（hostapd 状态 ${r.ap_state || '空'}）`);
	if (ws.pending)
		problem('warn', `${r.name} 正在重配`);
	if (ws.retry_setup_failed)
		problem('error', `${r.name} 多次启动失败（retry_setup_failed）`);
}

// Wi-Fi 上网（STA）
let sta_ifname = '';
for (let name in keys(wstatus ?? {}))
	for (let i in wstatus[name]?.interfaces ?? [])
		if (i.section == 'r3mini_phone_sta' && i.ifname)
			sta_ifname = i.ifname;
const sta_exists = !!(sta_ifname && access(sysnet + '/' + sta_ifname));
const wpa = sta_exists ? call('wpa_supplicant', 'phy_status', { phy: split(sta_ifname, '-')[0] }) : {};
if (wifi_enabled && !wifi_parked) {
	if (!sta_exists)
		problem('warn', 'Wi-Fi 上网已启用，但 STA 没有启动');
	else if (wpa.state != 'COMPLETED')
		problem('warn', `Wi-Fi 上网还没连上「${sta.ssid ?? ''}」：wpa_supplicant 状态 ${wpa.state ?? '未知'}`);
	else if (!online(wwan))
		problem('warn', '已连上对方，但还没拿到地址（DHCP）');
}
if (wifi_enabled && wwan && wwan.autostart === false)
	problem('warn', 'wwan 被手动关闭（autostart=false），STA 连上也不会拿地址');
if (wifi_parked)
	problem('info', `对方「${sta.ssid ?? ''}」不在，Wi-Fi 上网已停靠，看门狗在定期搜索`);

// 看门狗
const svc = call('service', 'list', { name: 'r3mini-hotspot' })?.['r3mini-hotspot'];
let wd_running = false, wd_pid = null;
for (let k in keys(svc?.instances ?? {}))
	if (svc.instances[k].running) {
		wd_running = true;
		wd_pid = svc.instances[k].pid;
	}
if (!wd_running)
	problem('error', '看门狗没有在运行（/etc/init.d/r3mini-hotspot）');

if (job && job.state == 'failed')
	problem('error', `最近一次${job.action == 'save' ? '保存' : '停用'}失败：${job.message}`);

// 本模块日志：当前文件不够就从上一份补
const where = log_location();
const logfile = where[0] + '/hotspot.log';
if (!where[1])
	problem('warn', '数据分区没挂上，日志只写在内存里，重启会丢');
let module_log = last(lines_of(readfile(logfile)), 120);
if (length(module_log) < 120) {
	let older = last(lines_of(readfile(logfile + '.1')), 120 - length(module_log));
	for (let l in module_log)
		push(older, l);
	module_log = older;
}

// 系统日志里跟无线有关的行，去掉刷屏的噪声。logread -e 是基本正则，不认 |，所以全取来在这里筛。
let syslog = [];
const p = popen('logread -l 800 2>/dev/null', 'r');
if (p) {
	syslog = last(filter(lines_of(p.read('all')), (l) =>
		match(l, /hostapd|wpa_supplicant|netifd|r3mini-hotspot|phy[0-9]-/) &&
		!match(l, /handle_probe_req: send failed|ModemManager|avahi-daemon|CTRL-EVENT-DSCP-POLICY|ttyd/)), 100);
	p.close();
}

print(sprintf('%J\n', {
	generated: now,
	problems,
	diag: {
		dirs,
		radios: map(radios, (r) => ({
			name: r.name, band: r.band, channel: r.channel,
			up: wstatus?.[r.name]?.up ?? null, pending: wstatus?.[r.name]?.pending ?? null,
			ap: r.ap, ap_exists: r.ap_up, hostapd: r.ap_state
		})),
		sta: { ifname: sta_ifname, exists: sta_exists, wpa_state: wpa.state ?? '', frequency: wpa.frequency ?? null, signal: wifi_up ? link.signal : null },
		wwan: { autostart: wwan?.autostart ?? null, up: !!wwan?.up, pending: !!wwan?.pending, ip: ipv4(wwan), errors: wwan?.errors ?? [] },
		wifi: result.wifi,
		watchdog: { running: wd_running, pid: wd_pid },
		job,
		log: { path: logfile, persistent: where[1], size: stat(logfile)?.size ?? 0 }
	},
	module_log,
	syslog
}));
