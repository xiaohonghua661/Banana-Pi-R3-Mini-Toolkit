'use strict';
// 上网出口页面的状态：一个进程读完，不调外部命令（实测约 20 ms）。
// 由 /usr/sbin/r3mini-hotspot-web status 调用；测试时用环境变量 R3HS_CONF_DIR、R3HS_STATE_DIR 换配置和状态目录。

import { cursor } from 'uci';
import { connect } from 'ubus';
import { readfile, access } from 'fs';

const conf_dir = getenv('R3HS_CONF_DIR');
const state_dir = getenv('R3HS_STATE_DIR') || '/tmp';
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
	const info = ap ? call('iwinfo', 'info', { device: ap }) : {};
	push(radios, {
		name,
		band: r.band ?? '',
		channel: `${info.channel ?? r.channel ?? ''}`,
		ap,
		ap_ssid: ap_section?.ssid ?? '',
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

print(sprintf('%J\n', {
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
		enabled: cfg('enabled', '0') == '1',
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
}));
