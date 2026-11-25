'use strict';
'require view';
'require fs';
'require ui';

// 网络 → 上网出口：有线 WAN、5G 蜂窝、Wi-Fi 上网（手机热点或任意附近 Wi-Fi）三选一，
// 以及 Wi-Fi 上网的频段、网络和密码设置。后端是 /usr/sbin/r3mini-hotspot-web。

var HELPER = '/usr/sbin/r3mini-hotspot-web';
var SLOW_MS = 5000;   // 平时每 5 秒读一次状态
var FAST_MS = 1000;   // 切换出口、保存 Wi-Fi 期间每秒读一次
var BURST_MS = 8000;  // 切换出口后保持快读的时长
var CHANNELS_5G = [36, 40, 44, 48, 149, 153, 157, 161];
var KINDS = ['wan', 'cellular', 'hotspot'];
var NAMES = { auto: '自动', wan: '有线 WAN', cellular: '5G 蜂窝', hotspot: 'Wi-Fi 上网' };

var CSS = [
	// 全宽，跟其他 LuCI 页面一样；容器查询按页面自身宽度切换布局（侧栏宽窄不影响）。
	// 区块里的文字一律用 div：argon 给 .cbi-section p 加了 1rem 内边距，用 p 会凭空多出留白和缩进。
	'.r3x{font-size:14px;line-height:1.6;container:r3x/inline-size}',
	'.r3x *{box-sizing:border-box}',
	'.r3x [hidden]{display:none!important}',
	// argon 的区块本身没有内边距，内容会贴着白框边缘。
	'.r3x .r3x-body{padding:0 16px 16px}',
	'.r3x .r3x-descr{margin:0 0 12px;opacity:.8}',
	'.r3x .r3x-now{display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px;margin:0 0 12px}',
	'.r3x .r3x-now strong{font-size:18px}',
	'.r3x .r3x-age{font-size:12px;opacity:.7}',
	'.r3x .r3x-age.err{color:#c62828;opacity:1}',
	'.r3x .r3x-exits{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin-bottom:12px}',
	'.r3x .r3x-exit{display:flex;flex-direction:column;gap:4px;min-width:0;padding:12px 14px;border:1px solid rgba(128,128,128,.28);border-radius:8px}',
	'.r3x .r3x-exit.active{border-color:#2e7d32;box-shadow:inset 3px 0 0 #2e7d32}',
	'.r3x .r3x-exit.unknown{opacity:.55}',
	'.r3x .r3x-exit-head{display:flex;align-items:center;justify-content:space-between;gap:8px;font-weight:600}',
	'.r3x .r3x-exit-detail{overflow-wrap:anywhere;font-variant-numeric:tabular-nums}',
	'.r3x .r3x-exit-detail:empty{display:none}',
	'.r3x .r3x-exit-reason{opacity:.8;overflow-wrap:anywhere}',
	'.r3x .r3x-exit-reason:empty{display:none}',
	'.r3x .r3x-exit .cbi-button{align-self:flex-start;margin-top:4px}',
	'.r3x .r3x-pill{flex:none;padding:1px 8px;border-radius:999px;font-size:12px;font-weight:600;white-space:nowrap}',
	'.r3x .r3x-pill.active{background:rgba(46,125,50,.14);color:#2e7d32}',
	'.r3x .r3x-pill.ready{background:rgba(21,101,192,.12);color:#1565c0}',
	'.r3x .r3x-pill.off{background:rgba(128,128,128,.16)}',
	'.r3x .r3x-pill.warn{background:rgba(237,108,2,.14);color:#b45309}',
	'.r3x .r3x-prefer{display:flex;flex-wrap:wrap;align-items:center;gap:8px}',
	'.r3x .r3x-prefer>span{margin-right:4px;font-weight:600}',
	'.r3x .r3x-prefer .cbi-button{flex:0 1 150px;min-width:104px;min-height:38px;margin:0}',
	'.r3x .r3x-prefer .cbi-button[aria-pressed="true"]{outline:2px solid #2e7d32;outline-offset:-2px;font-weight:700}',
	'.r3x .r3x-note{margin:8px 0 0;opacity:.8}',
	'.r3x .r3x-msg{margin:8px 0 0}',
	'.r3x .r3x-msg:empty{display:none}',
	'.r3x .r3x-msg.ok{color:#2e7d32}',
	'.r3x .r3x-msg.err{color:#c62828}',
	// Wi-Fi 上网：窄屏一栏（频段 → 搜索 → 名称密码 → 保存），宽屏两栏（左边设置，右边附近的 Wi-Fi）。
	'.r3x .r3x-wifi{display:grid;gap:14px;grid-template-columns:minmax(0,1fr);grid-template-areas:"top" "scan" "bottom";align-items:start}',
	'.r3x .r3x-top{grid-area:top}',
	'.r3x .r3x-scan{grid-area:scan}',
	'.r3x .r3x-bottom{grid-area:bottom}',
	'.r3x .r3x-top,.r3x .r3x-bottom{display:grid;grid-template-columns:minmax(0,1fr);gap:14px}',
	'.r3x .r3x-field{display:grid;grid-template-columns:minmax(0,1fr);gap:4px}',
	'.r3x .r3x-field select,.r3x .r3x-field input{width:100%;max-width:100%;min-width:0}',
	'.r3x .r3x-field>label{font-weight:600}',
	'.r3x .r3x-hint{opacity:.75}',
	'.r3x .r3x-check{display:flex;align-items:center;gap:8px;font-weight:600}',
	'.r3x .r3x-scan{display:grid;gap:8px;align-content:start;padding:12px 14px;border:1px solid rgba(128,128,128,.28);border-radius:8px}',
	'.r3x .r3x-scan-head{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:8px}',
	'.r3x .r3x-scan-head .cbi-button{margin:0}',
	'.r3x .r3x-list{max-height:420px;overflow:auto;margin:0;padding:0;list-style:none;border-top:1px solid rgba(128,128,128,.18)}',
	'.r3x .r3x-list li{display:flex;flex-wrap:wrap;align-items:center;gap:4px 12px;padding:8px 4px;border-bottom:1px solid rgba(128,128,128,.18)}',
	'.r3x .r3x-list li:last-child{border-bottom:0}',
	'.r3x .r3x-list li.picked{background:rgba(46,125,50,.1)}',
	'.r3x .r3x-list li.no{opacity:.55}',
	'.r3x .r3x-net{flex:1 1 160px;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}',
	'.r3x .r3x-meta{opacity:.8;font-variant-numeric:tabular-nums}',
	'.r3x .r3x-list .cbi-button{margin:0;min-height:32px}',
	'.r3x .r3x-warn{margin:0;padding:8px 12px;border-left:3px solid #ed6c02;background:rgba(237,108,2,.08)}',
	'.r3x .r3x-actions{display:flex;flex-wrap:wrap;gap:8px}',
	'.r3x .r3x-actions .cbi-button{min-height:38px;margin:0}',
	'.r3x .r3x-job{margin:0;padding:8px 12px;border-radius:6px;background:rgba(128,128,128,.1)}',
	'.r3x .r3x-job.err{background:rgba(198,40,40,.1);color:#c62828}',
	'.r3x .r3x-job.ok{background:rgba(46,125,50,.1);color:#2e7d32}',
	'.r3x .r3x-foot{margin:8px 0 0;opacity:.75}',
	'.r3x .r3x-alert{display:grid;gap:6px;margin:0 0 12px}',
	'.r3x .r3x-alert p{margin:0;padding:8px 12px;border-left:4px solid #c62828;background:rgba(198,40,40,.08)}',
	'.r3x .r3x-alert p.paused{border-left-color:#ed6c02;background:rgba(237,108,2,.08)}',
	'@container r3x (min-width:900px){',
	'.r3x .r3x-wifi{grid-template-columns:minmax(340px,520px) minmax(0,1fr);grid-template-rows:auto 1fr;grid-template-areas:"top scan" "bottom scan";column-gap:28px}',
	'}',
	'@container r3x (max-width:700px){',
	'.r3x .r3x-exits{grid-template-columns:minmax(0,1fr)}',
	'.r3x .r3x-prefer{display:grid;grid-template-columns:repeat(2,minmax(0,1fr))}',
	'.r3x .r3x-prefer>span{grid-column:1/-1}',
	'.r3x .r3x-prefer .cbi-button{min-width:0}',
	'}',
	'@media (prefers-color-scheme:dark){',
	'.r3x .r3x-pill.active,.r3x .r3x-msg.ok,.r3x .r3x-job.ok{color:#81c784}',
	'.r3x .r3x-pill.ready{color:#90caf9}',
	'.r3x .r3x-pill.warn{color:#ffb74d}',
	'.r3x .r3x-age.err,.r3x .r3x-msg.err,.r3x .r3x-job.err{color:#ef9a9a}',
	'.r3x .r3x-exit.active{border-color:#81c784;box-shadow:inset 3px 0 0 #81c784}',
	'.r3x .r3x-prefer .cbi-button[aria-pressed="true"]{outline-color:#81c784}',
	'}'
].join('\n');

function parse(res) {
	if (!res || res.code !== 0)
		throw new Error(((res && (res.stderr || res.stdout)) || '后端没有响应').trim());
	return JSON.parse(res.stdout);
}

function bytes(text) { return new TextEncoder().encode(text).length; }

// LuCI 的 E() 会把字符串子节点当 HTML 插入；Wi-Fi 名称等外来文字一律包成文本节点。
function T(text) { return document.createTextNode(String(text == null ? '' : text)); }

function bandName(band) { return band === '2g' ? '2.4 GHz' : band === '5g' ? '5 GHz' : (band || '未知频段'); }

// 与后端 find_network 的判断保持一致。
function encOf(e) {
	if (!e || !e.enabled) return 'none';
	var auth = e.authentication || [], wpa = e.wpa || [];
	if (auth.indexOf('802.1x') >= 0) return 'eap';
	if (auth.indexOf('sae') >= 0) return auth.indexOf('psk') >= 0 ? 'sae-mixed' : 'sae';
	if (auth.indexOf('psk') >= 0) return wpa.indexOf(1) >= 0 && wpa.indexOf(2) >= 0 ? 'psk-mixed' : wpa.indexOf(2) >= 0 ? 'psk2' : 'psk';
	return 'wep';
}

function encName(enc) {
	return { none: '开放', psk: 'WPA', psk2: 'WPA2', 'psk-mixed': 'WPA/WPA2', sae: 'WPA3', 'sae-mixed': 'WPA2/WPA3', eap: '企业认证', wep: 'WEP' }[enc] || enc || '未知';
}

function channelOk(band, ch) {
	return band === '2g' ? ch >= 1 && ch <= 13 : band === '5g' ? CHANNELS_5G.indexOf(ch) >= 0 : false;
}

function signalName(dbm) {
	var n = Number(dbm);
	if (!Number.isFinite(n)) return '';
	return (n >= -60 ? '强' : n >= -72 ? '中' : '弱') + ' ' + n + ' dBm';
}

// 搜索结果：同名只留信号最强的，标出本机能不能连。
function networks(scan, band) {
	var best = {};
	(scan.results || []).forEach(function(r) {
		if (!r.ssid) return;
		if (!best[r.ssid] || Number(r.signal) > Number(best[r.ssid].signal)) best[r.ssid] = r;
	});
	return Object.keys(best).map(function(ssid) {
		var r = best[ssid], enc = encOf(r.encryption), ch = Number(r.channel), why = '';
		if (enc === 'eap') why = '企业认证，不支持';
		else if (enc === 'wep') why = 'WEP 加密，不支持';
		else if (!channelOk(band, ch)) why = '信道 ' + ch + '，本机跟不过去';
		return { ssid: ssid, channel: ch, signal: Number(r.signal), enc: enc, why: why };
	}).sort(function(a, b) { return (a.why ? 1 : 0) - (b.why ? 1 : 0) || b.signal - a.signal; });
}

function keyFileName() {
	var v = new Uint32Array(2);
	window.crypto.getRandomValues(v);
	return '/tmp/r3mini-hotspot-key-' + Array.prototype.map.call(v, function(x) { return x.toString(16).padStart(8, '0'); }).join('');
}

function confirmBox(title, lines, okLabel) {
	return new Promise(function(resolve) {
		ui.showModal(title, lines.map(function(t) { return E('p', {}, [T(t)]); }).concat([
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function() { ui.hideModal(); resolve(false); } }, '取消'), ' ',
				E('button', { 'class': 'cbi-button cbi-button-apply', 'click': function() { ui.hideModal(); resolve(true); } }, okLabel)
			])
		]));
	});
}

function clockText(date) {
	return [date.getHours(), date.getMinutes(), date.getSeconds()].map(function(n) { return String(n).padStart(2, '0'); }).join(':');
}

// 每个出口的状态：tone 决定标签颜色，reason 写给人看的原因。
function exitView(st, kind) {
	var active = st.egress && st.egress.kind === kind;
	if (kind === 'wan') {
		var w = st.wan || {};
		if (!w.present) return { tone: 'off', pill: '未配置', detail: '', reason: '没有 wan 接口' };
		if (!w.up) return { tone: 'off', pill: '不可用', detail: '', reason: '网线没接好，或上级路由没分配地址' };
		return { tone: active ? 'active' : 'ready', pill: active ? '正在使用' : '可用', detail: w.ip + (w.device ? '（' + w.device + '）' : ''), reason: '' };
	}
	if (kind === 'cellular') {
		var c = st.cellular || {};
		if (!c.present) return { tone: 'off', pill: '未配置', detail: '', reason: '没有蜂窝网络接口' };
		if (c.up) return { tone: active ? 'active' : 'ready', pill: active ? '正在使用' : '可用', detail: c.ip, reason: '', action: 'off' };
		if (!c.auto) return { tone: 'off', pill: '已暂停', detail: '', reason: '已暂停自动拨号。插好 SIM 卡后点「恢复拨号」。', action: 'on' };
		return { tone: 'warn', pill: '未连上', detail: '', reason: '正在反复拨号。没插 SIM 卡时会一直重试并刷屏系统日志，可以先暂停。', action: 'off' };
	}
	var f = st.wifi || {};
	if (!f.enabled) return { tone: 'off', pill: '未启用', detail: '', reason: '在下方选择一个 Wi-Fi 并保存后可用' };
	var radio = (st.radios || []).filter(function(r) { return r.name === f.radio; })[0] || {};
	var where = '「' + f.ssid + '」· ' + bandName(radio.band);
	if (f.up) return { tone: active ? 'active' : 'ready', pill: active ? '正在使用' : '可用', detail: f.ip, reason: where + (f.signal != null ? ' · 信号' + signalName(f.signal) : '') };
	if (f.parked) return { tone: 'warn', pill: '等对方出现', detail: '', reason: where + '：对方不在，搜到后自动重连' };
	return { tone: 'warn', pill: '连接中', detail: '', reason: where };
}

// 本机 AP 的异常：没在运行（起不来，红色），或暂停（橙色）。
function apAlerts(st) {
	var out = [], f = st.wifi || {};
	(st.radios || []).forEach(function(r) {
		if (!r.has_ap || r.disabled) return;
		var name = '本机 ' + bandName(r.band) + ' Wi-Fi「' + r.ap_ssid + '」';
		if (!r.ap_up)
			out.push({ kind: 'down', text: name + '现在没有在运行，用它连路由器的设备连不上。可以先停用再启用 Wi-Fi 上网让它重建；仍不行，从有线 LAN 用 SSH 执行 ubus call network.wireless down \'{"device":"' + r.name + '"}\'，再把 down 换成 up 执行一次。' });
		else if (r.ap_paused && f.enabled && !f.parked && !f.up && f.radio === r.name)
			out.push({ kind: 'paused', text: name + '暂停中：Wi-Fi 上网正用这个频段连接「' + f.ssid + '」，连上后恢复；约 2 分钟仍连不上，会先停下 Wi-Fi 上网让它恢复。' });
		else if (r.ap_paused)
			out.push({ kind: 'paused', text: name + '已停止（hostapd 状态 ' + (r.ap_state || '未知') + '），用它连路由器的设备连不上。' });
	});
	return out;
}

function radioLabel(r) {
	if (!r.has_ap) return bandName(r.band);
	if (!r.ap_up) return bandName(r.band) + '（本机 Wi-Fi「' + r.ap_ssid + '」没有在运行）';
	return bandName(r.band) + '（本机 Wi-Fi「' + r.ap_ssid + '」，信道 ' + r.channel + (r.ap_paused ? '，暂停中' : '') + '）';
}

function online(st, kind) {
	if (kind === 'auto') return true;
	if (kind === 'wan') return !!(st.wan && st.wan.up);
	if (kind === 'cellular') return !!(st.cellular && st.cellular.up);
	return !!(st.wifi && st.wifi.up);
}

return view.extend({
	run: function(args) { return fs.exec(HELPER, args).then(parse); },

	load: function() { return this.run(['status']); },

	render: function(st) {
		var self = this;
		this.st = st;
		this.failures = 0;
		this.inflight = null;
		this.busy = false;
		this.burstUntil = 0;
		this.scan = null;
		this.picked = null;
		// 页面发起或看到正在跑的任务；它结束时把表单换成路由器上的新设置。
		this.followJob = st.job && st.job.state === 'running' ? st.job.id : null;
		this.saved = this.savedForm(st);

		this.nodes = {};
		var n = this.nodes;
		n.now = E('strong', {}, '');
		n.nowDetail = E('span', {}, '');
		n.age = E('span', { 'class': 'r3x-age' }, '');
		n.exits = {};
		var cards = KINDS.map(function(kind) {
			var card = E('div', { 'class': 'r3x-exit', 'data-kind': kind }, [
				E('div', { 'class': 'r3x-exit-head' }, [E('span', {}, NAMES[kind]), E('span', { 'class': 'r3x-pill' }, '')]),
				E('div', { 'class': 'r3x-exit-detail' }, ''),
				E('div', { 'class': 'r3x-exit-reason' }, '')
			]);
			if (kind === 'cellular') {
				n.cellBtn = E('button', { 'class': 'cbi-button cbi-button-action', 'click': function() { self.toggleCellular(); } }, '');
				card.appendChild(n.cellBtn);
			}
			n.exits[kind] = card;
			return card;
		});
		n.prefer = {};
		var preferButtons = ['auto'].concat(KINDS).map(function(kind) {
			n.prefer[kind] = E('button', { 'class': 'cbi-button', 'aria-pressed': 'false', 'click': function() { self.prefer(kind); } }, NAMES[kind]);
			return n.prefer[kind];
		});
		n.preferNote = E('div', { 'class': 'r3x-note' }, '');
		n.preferMsg = E('div', { 'class': 'r3x-msg', 'aria-live': 'polite' }, '');

		n.enabled = E('input', { 'type': 'checkbox', 'id': 'r3x-enabled', 'change': function() { self.syncForm(); } });
		n.radio = E('select', { 'class': 'cbi-input-select', 'id': 'r3x-radio', 'change': function() { self.scan = null; self.picked = null; self.renderScan(); self.syncForm(); } });
		n.ssid = E('input', { 'class': 'cbi-input-text', 'id': 'r3x-ssid', 'type': 'text', 'maxlength': '32', 'autocomplete': 'off', 'spellcheck': 'false', 'placeholder': '先搜索再选择，也可以直接输入名称',
			'input': function() { self.picked = null; self.renderScan(); self.syncForm(); } });
		n.scanBtn = E('button', { 'class': 'cbi-button cbi-button-action', 'click': function() { self.doScan(); } }, '搜索');
		n.scanInfo = E('div', { 'class': 'r3x-hint', 'id': 'r3x-scaninfo' }, '点「搜索」列出附近能连的 Wi-Fi，约 2 秒，不会断网；点「选择」填进 Wi-Fi 名称。');
		n.list = E('ul', { 'class': 'r3x-list', 'hidden': '' });
		n.password = E('input', { 'class': 'cbi-input-password', 'id': 'r3x-password', 'type': 'password', 'maxlength': '63', 'autocomplete': 'new-password', 'input': function() { self.syncForm(); } });
		n.passwordHint = E('div', { 'class': 'r3x-hint' }, '');
		n.passwordField = E('div', { 'class': 'r3x-field' }, [E('label', { 'for': 'r3x-password' }, '密码'), n.password, n.passwordHint]);
		n.warn = E('div', { 'class': 'r3x-warn' }, '');
		n.revert = E('button', { 'class': 'cbi-button cbi-button-reset', 'click': function() { self.resetForm(); } }, '还原');
		n.save = E('button', { 'class': 'cbi-button cbi-button-apply', 'click': function() { self.save(); } }, '保存并连接');
		n.job = E('div', { 'class': 'r3x-job', 'role': 'status', 'aria-live': 'polite', 'hidden': '' }, '');
		n.formMsg = E('div', { 'class': 'r3x-msg', 'id': 'r3x-formmsg', 'aria-live': 'polite' }, '');
		n.foot = E('p', { 'class': 'r3x-foot' }, '');
		n.alert = E('div', { 'class': 'r3x-alert', 'role': 'alert', 'hidden': '' });

		this.root = E('div', { 'class': 'r3x' }, [
			E('style', {}, CSS),
			E('h2', { 'name': 'content' }, '上网出口'),
			E('p', { 'class': 'r3x-descr' }, '路由器从这三条线路里选一条上网：有线 WAN、5G 蜂窝、Wi-Fi 上网（连手机热点或附近任意 Wi-Fi）。'),
			n.alert,
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '当前出口'),
				E('div', { 'class': 'r3x-body' }, [
					E('div', { 'class': 'r3x-now' }, [n.now, n.nowDetail, n.age]),
					E('div', { 'class': 'r3x-exits' }, cards),
					E('div', { 'class': 'r3x-prefer', 'role': 'group', 'aria-label': '优先出口' }, [E('span', {}, '优先使用')].concat(preferButtons)),
					n.preferNote,
					n.preferMsg
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, 'Wi-Fi 上网'),
				E('div', { 'class': 'r3x-body r3x-wifi' }, [
					E('div', { 'class': 'r3x-top' }, [
						E('label', { 'class': 'r3x-check' }, [n.enabled, '启用 Wi-Fi 上网']),
						E('div', { 'class': 'r3x-field' }, [E('label', { 'for': 'r3x-radio' }, '频段'), n.radio,
							E('div', { 'class': 'r3x-hint' }, '用这个频段去连对方；本机这个频段的 Wi-Fi 会跟到对方所在信道。')])
					]),
					E('div', { 'class': 'r3x-scan' }, [
						E('div', { 'class': 'r3x-scan-head' }, [E('strong', {}, '附近的 Wi-Fi'), n.scanBtn]),
						n.scanInfo,
						n.list
					]),
					E('div', { 'class': 'r3x-bottom' }, [
						E('div', { 'class': 'r3x-field' }, [E('label', { 'for': 'r3x-ssid' }, 'Wi-Fi 名称'), n.ssid]),
						n.passwordField,
						n.warn,
						E('div', { 'class': 'r3x-actions' }, [n.save, n.revert]),
						n.job,
						n.formMsg
					])
				])
			]),
			n.foot
		]);

		this.fillRadios(st);
		this.resetForm(true);
		this.update(st);

		this.onVisible = function() { if (!document.hidden) self.refresh(); };
		document.addEventListener('visibilitychange', this.onVisible);
		this.schedule();
		return this.root;
	},

	// ---------- 刷新 ----------

	jobRunning: function() { return !!(this.st && this.st.job && this.st.job.state === 'running'); },

	schedule: function() {
		var self = this;
		clearTimeout(this.timer);
		var fast = this.jobRunning() || Date.now() < this.burstUntil;
		this.timer = setTimeout(function() {
			if (!self.root.isConnected) {
				document.removeEventListener('visibilitychange', self.onVisible);
				return;
			}
			if (document.hidden) return self.schedule();
			self.refresh().then(function() { self.schedule(); });
		}, fast ? FAST_MS : SLOW_MS);
	},

	refresh: function() {
		var self = this;
		if (this.inflight) return this.inflight;
		this.inflight = this.run(['status']).then(function(st) {
			self.failures = 0;
			self.update(st);
		}).catch(function(err) {
			self.failures++;
			if (self.failures >= 2) self.markStale(err);
		}).then(function() { self.inflight = null; });
		return this.inflight;
	},

	markStale: function(err) {
		var n = this.nodes;
		n.age.className = 'r3x-age err';
		n.age.textContent = this.jobRunning()
			? '路由器正在重配 Wi-Fi，暂时连不上，恢复后自动刷新'
			: '读不到状态，正在重试（' + (err && err.message || '网络错误') + '）';
		KINDS.forEach(function(kind) { n.exits[kind].classList.add('unknown'); });
		['auto'].concat(KINDS).forEach(function(kind) { n.prefer[kind].disabled = true; });
	},

	update: function(st) {
		var n = this.nodes, self = this;
		this.st = st;
		var e = st.egress || {};
		n.now.textContent = e.kind === 'none' ? '没有可用的出口' : e.kind === 'other' ? '其他线路（' + e.device + '）' : '正在通过 ' + NAMES[e.kind] + ' 上网';
		n.nowDetail.textContent = e.ip ? e.ip + (e.gateway ? '，网关 ' + e.gateway : '') : '';
		n.age.className = 'r3x-age';
		n.age.textContent = '更新于 ' + clockText(new Date());

		KINDS.forEach(function(kind) {
			var v = exitView(st, kind), card = n.exits[kind];
			card.className = 'r3x-exit' + (v.tone === 'active' ? ' active' : '');
			var pill = card.querySelector('.r3x-pill');
			pill.className = 'r3x-pill ' + v.tone;
			pill.textContent = v.pill;
			card.querySelector('.r3x-exit-detail').textContent = v.detail;
			card.querySelector('.r3x-exit-reason').textContent = v.reason;
			if (kind === 'cellular') {
				n.cellBtn.hidden = !v.action;
				n.cellBtn.textContent = v.action === 'on' ? '恢复拨号' : '暂停拨号';
				n.cellBtn.disabled = self.busy;
			}
		});

		var offline = [];
		['auto'].concat(KINDS).forEach(function(kind) {
			var b = n.prefer[kind];
			b.setAttribute('aria-pressed', st.preferred === kind ? 'true' : 'false');
			b.disabled = self.busy || !online(st, kind);
			if (kind !== 'auto' && !online(st, kind)) offline.push(NAMES[kind]);
		});
		n.preferNote.textContent = (st.preferred === 'auto'
			? '自动：有线 WAN 优先，其次 5G 蜂窝，最后 Wi-Fi 上网；在用的断了会换下一条。'
			: '已固定优先用' + NAMES[st.preferred] + '；它断了仍会换到其他在线线路。')
			+ (offline.length ? ' 现在不可选：' + offline.join('、') + '。' : '');

		var r = st.reconnect || {};
		n.foot.textContent = 'Wi-Fi 上网自动重连：每 ' + r.interval + ' 秒检查一次，连续 ' + r.limit + ' 次没连上就重连；约 2 分钟仍连不上，先停下 Wi-Fi 上网让本机 Wi-Fi 恢复，之后每隔 1 分钟起（最长 30 分钟）用本机 Wi-Fi 搜一次对方，搜到再重连。';

		var alerts = apAlerts(st);
		n.alert.hidden = !alerts.length;
		while (n.alert.firstChild) n.alert.removeChild(n.alert.firstChild);
		alerts.forEach(function(a) { n.alert.appendChild(E('p', { 'class': a.kind }, [T(a.text)])); });
		this.labelRadios(st);

		// 表单的「已保存设置」始终跟路由器一致；用户没动过的字段才会跟着变。
		this.saved = this.savedForm(st);
		this.renderJob(st.job);
		this.syncForm();
	},

	renderJob: function(job) {
		var n = this.nodes;
		if (!job) { n.job.hidden = true; return; }
		n.job.hidden = false;
		n.job.className = 'r3x-job' + (job.state === 'failed' ? ' err' : job.state === 'done' ? ' ok' : '');
		n.job.textContent = (job.state === 'running' ? '进行中：' : job.state === 'failed' ? '失败：' : '完成：') + (job.message || '');
		if (job.state === 'running') {
			this.followJob = job.id;
		} else if (job.id === this.followJob) {
			// 跟着的任务刚结束：表单换成路由器上的新设置。
			this.followJob = null;
			this.resetForm(true);
		}
	},

	// ---------- 出口 ----------

	prefer: function(kind) {
		var self = this, n = this.nodes;
		if (this.busy || !online(this.st, kind)) return;
		this.setBusy(true);
		this.message(n.preferMsg, '正在切换到' + NAMES[kind] + '…');
		this.run(['prefer', kind]).then(function(st) {
			self.update(st);
			self.message(n.preferMsg, kind === 'auto' ? '已改为自动选择出口。' : '已改为优先用' + NAMES[kind] + '。', 'ok');
		}).catch(function(err) {
			self.message(n.preferMsg, err.message, 'err');
		}).then(function() {
			self.setBusy(false);
			self.burstUntil = Date.now() + BURST_MS;
			self.schedule();
		});
	},

	toggleCellular: function() {
		var self = this, n = this.nodes, on = !(this.st.cellular || {}).auto;
		if (this.busy) return;
		this.setBusy(true);
		this.message(n.preferMsg, on ? '正在检查 SIM 卡并恢复拨号…' : '正在暂停蜂窝拨号…');
		this.run(['cellular', on ? 'on' : 'off']).then(function(st) {
			self.update(st);
			self.message(n.preferMsg, on ? '已恢复蜂窝拨号。' : '已暂停蜂窝拨号；插好 SIM 卡后再恢复。', 'ok');
		}).catch(function(err) {
			self.message(n.preferMsg, err.message, 'err');
		}).then(function() {
			self.setBusy(false);
			self.burstUntil = Date.now() + BURST_MS;
			self.schedule();
		});
	},

	// ---------- Wi-Fi 上网 ----------

	savedForm: function(st) {
		var f = st.wifi || {}, radios = st.radios || [];
		var radio = f.radio || (radios.filter(function(r) { return r.band === '5g'; })[0] || radios[0] || {}).name || '';
		return { enabled: !!f.enabled, radio: radio, ssid: f.ssid || '', keySet: !!f.key_set };
	},

	fillRadios: function(st) {
		var sel = this.nodes.radio;
		while (sel.firstChild) sel.removeChild(sel.firstChild);
		(st.radios || []).forEach(function(r) {
			sel.appendChild(E('option', { 'value': r.name }, [T(radioLabel(r))]));
		});
	},

	labelRadios: function(st) {
		var options = this.nodes.radio.options;
		(st.radios || []).forEach(function(r) {
			for (var i = 0; i < options.length; i++)
				if (options[i].value === r.name) options[i].textContent = radioLabel(r);
		});
	},

	radioInfo: function(name) {
		return (this.st.radios || []).filter(function(r) { return r.name === name; })[0] || {};
	},

	resetForm: function(quiet) {
		var n = this.nodes, s = this.saved;
		n.enabled.checked = s.enabled;
		n.radio.value = s.radio;
		n.ssid.value = s.ssid;
		n.password.value = '';
		this.scan = null;
		this.picked = null;
		this.renderScan();
		this.syncForm();
		if (!quiet) this.message(n.formMsg, '已还原为路由器上保存的设置。');
	},

	form: function() {
		var n = this.nodes;
		return { enabled: n.enabled.checked, radio: n.radio.value, ssid: n.ssid.value.trim(), password: n.password.value };
	},

	// 当前表单相对路由器上的设置：要做什么、能不能做、为什么不能。
	plan: function() {
		var f = this.form(), s = this.saved, picked = this.picked;
		if (!f.enabled) return s.enabled ? { action: 'disable' } : { action: null };
		var newNetwork = f.ssid !== s.ssid;
		var changed = !s.enabled || newNetwork || f.radio !== s.radio || f.password !== '';
		if (!changed) return { action: null };
		if (!f.ssid) return { action: 'save', block: '请先搜索并选择 Wi-Fi，或输入名称' };
		if (bytes(f.ssid) > 32) return { action: 'save', block: 'Wi-Fi 名称不能超过 32 字节' };
		if (picked && picked.why) return { action: 'save', block: '这个 Wi-Fi 不能用：' + picked.why };
		var needKey = picked ? picked.enc !== 'none' : false;
		if (f.password && (bytes(f.password) < 8 || bytes(f.password) > 63)) return { action: 'save', block: '密码必须是 8–63 个字符' };
		if (needKey && !f.password && (newNetwork || !s.keySet)) return { action: 'save', block: '请输入这个 Wi-Fi 的密码' };
		return { action: 'save' };
	},

	syncForm: function() {
		var n = this.nodes, f = this.form(), s = this.saved, p = this.plan(), running = this.jobRunning();
		var lock = this.busy || running;
		n.enabled.disabled = lock;
		[n.radio, n.ssid, n.scanBtn, n.password].forEach(function(el) { el.disabled = lock || !f.enabled; });
		n.revert.disabled = lock;

		var open = this.picked && this.picked.enc === 'none';
		n.passwordField.hidden = !f.enabled || open;
		n.passwordHint.textContent = f.ssid && f.ssid === s.ssid && s.keySet ? '留空则沿用已保存的密码。' : '8–63 个字符。只写进路由器，页面不会显示。';

		var radio = this.radioInfo(f.radio);
		var target = this.picked && !this.picked.why ? '信道 ' + this.picked.channel : '对方所在信道';
		n.warn.hidden = !p.action;
		n.warn.textContent = p.action === 'disable'
			? '停用后本机 ' + bandName(radio.band) + ' Wi-Fi 会恢复原信道，期间断开十几秒；用它连路由器的设备会短暂断网。'
			: '保存后本机 ' + bandName(radio.band) + ' Wi-Fi（现在信道 ' + (radio.channel || '?') + '）会改到' + target + '，期间断开十几秒' + this.otherBandNote() + '。'
				+ '以后 Wi-Fi 上网没连上时（例如手机热点关了），本机 ' + bandName(radio.band) + ' Wi-Fi 会暂停，最长约 2 分钟后恢复。用这个频段连路由器的设备那时会断网，建议选连接设备少的频段。';

		n.save.textContent = p.action === 'disable' ? '停用 Wi-Fi 上网' : '保存并连接';
		n.save.disabled = lock || !p.action || !!p.block;
		if (p.block && f.enabled) this.message(n.formMsg, p.block);
		else if (!this.formMsgSticky) this.message(n.formMsg, '');
	},

	// 从一个频段换到另一个频段时，原来那个频段也要恢复原信道、重配一次。
	otherBandNote: function() {
		var s = this.saved, f = this.form();
		if (!s.enabled || !s.radio || s.radio === f.radio) return '';
		return '；原来用的本机 ' + bandName(this.radioInfo(s.radio).band) + ' Wi-Fi 也会恢复原信道，同样断开十几秒';
	},

	doScan: function() {
		var self = this, n = this.nodes, radio = n.radio.value;
		n.scanBtn.disabled = true;
		n.scanInfo.textContent = '正在搜索 ' + bandName(this.radioInfo(radio).band) + ' 附近的 Wi-Fi…';
		this.run(['scan', radio]).then(function(scan) {
			if (n.radio.value !== radio) return;
			self.scan = networks(scan, self.radioInfo(radio).band);
			var usable = self.scan.filter(function(x) { return !x.why; }).length;
			n.scanInfo.textContent = '找到 ' + self.scan.length + ' 个，' + usable + ' 个可以连。不支持隐藏名称的网络。';
			var match = self.scan.filter(function(x) { return x.ssid === n.ssid.value.trim(); })[0];
			self.picked = match || null;
			self.renderScan();
		}).catch(function(err) {
			n.scanInfo.textContent = err.message;
		}).then(function() { self.syncForm(); });
	},

	renderScan: function() {
		var self = this, n = this.nodes, list = n.list;
		while (list.firstChild) list.removeChild(list.firstChild);
		list.hidden = !this.scan;
		if (!this.scan) return;
		if (!this.scan.length) {
			list.appendChild(E('li', {}, '附近没有搜到 Wi-Fi。'));
			return;
		}
		this.scan.forEach(function(x) {
			var picked = self.picked && self.picked.ssid === x.ssid;
			var meta = signalName(x.signal) + ' · 信道 ' + x.channel + ' · ' + encName(x.enc) + (x.why ? ' · ' + x.why : '');
			list.appendChild(E('li', { 'class': (picked ? 'picked' : '') + (x.why ? ' no' : '') }, [
				E('span', { 'class': 'r3x-net', 'title': x.ssid }, [T(x.ssid)]),
				E('span', { 'class': 'r3x-meta' }, [T(meta)]),
				x.why ? '' : E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': function() { self.pick(x); } }, picked ? '已选' : '选择')
			]));
		});
	},

	pick: function(x) {
		var n = this.nodes;
		this.picked = x;
		n.ssid.value = x.ssid;
		if (x.enc === 'none') n.password.value = '';
		this.renderScan();
		this.syncForm();
		if (x.enc !== 'none') n.password.focus();
	},

	save: function() {
		var self = this, n = this.nodes, f = this.form(), p = this.plan(), radio = this.radioInfo(f.radio);
		if (!p.action || p.block || this.busy || this.jobRunning()) return;
		var title = p.action === 'disable' ? '停用 Wi-Fi 上网' : '连接 Wi-Fi';
		var lines = p.action === 'disable'
			? ['本机 ' + bandName(radio.band) + ' Wi-Fi 会断开十几秒并恢复原信道。']
			: ['路由器会用 ' + bandName(radio.band) + ' 连接「' + f.ssid + '」。', '本机 ' + bandName(radio.band) + ' Wi-Fi 会断开十几秒并改到对方信道' + this.otherBandNote() + '。如果你正用它连着路由器，页面会短暂断开，之后自动恢复。',
				'注意：以后 Wi-Fi 上网没连上时（例如手机热点关了），本机 ' + bandName(radio.band) + ' Wi-Fi 会暂停，最长约 2 分钟后由后台先停下 Wi-Fi 上网让它恢复，搜到对方再自动重连。这是 OpenWrt 同一频段上网和发射共用一块射频的限制。'];
		confirmBox(title, lines, p.action === 'disable' ? '停用' : '保存并连接').then(function(ok) {
			if (!ok) return;
			self.setBusy(true);
			self.message(n.formMsg, '正在提交…');
			var keyFile = p.action === 'save' && f.password ? keyFileName() : null;
			var start = keyFile
				? fs.write(keyFile, f.password, 384).then(function() { return self.run(['save', f.radio, f.ssid, keyFile]); })
				: self.run(p.action === 'disable' ? ['disable'] : ['save', f.radio, f.ssid, '-']);
			return start.then(function(st) {
				n.password.value = '';
				if (st.job) self.followJob = st.job.id;
				self.update(st);
				self.message(n.formMsg, '');
			}).catch(function(err) {
				self.message(n.formMsg, err.message, 'err');
			}).then(function() {
				if (keyFile) fs.remove(keyFile).catch(function() {});
				self.setBusy(false);
				self.schedule();
			});
		});
	},

	setBusy: function(busy) {
		this.busy = busy;
		this.update(this.st);
	},

	message: function(node, text, tone) {
		node.className = 'r3x-msg' + (tone ? ' ' + tone : '');
		node.textContent = text || '';
		if (node === this.nodes.formMsg) this.formMsgSticky = !!tone;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
