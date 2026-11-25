'use strict';
'require view';
'require fs';
'require poll';

// 只读页面：ACL 只放行 `r3mini-traffic web *`。查询口径全部在 r3mini-traffic report 里，页面只拼参数、画结果。
// 设备名、目标、出口来自网络数据，一律按文本插入（不用 innerHTML，也不用 LuCI 的 E() 单字符串子节点）。
var CLI = '/usr/sbin/r3mini-traffic';

var DIMS = [['device', '设备'], ['exit', '出口'], ['target', '目标'], ['date', '日期'], ['hour', '小时'], ['kind', '类型']];
var DIM_NAME = {};
DIMS.forEach(function(d) { DIM_NAME[d[0]] = d[1]; });
var KIND_NAME = { clash: 'OpenClash', socks: 'SOCKS 端口', forward: '转发直连' };
var SORT_NAME = { up: '上传', down: '下载', total: '合计', conns: '连接', key: '名称' };
var TOPS = [50, 100, 200, 500];
// 点一行往下钻：把这一行设成精确过滤，再换到下一个还没限定的维度
var NEXT = { device: 'target', exit: 'target', target: 'device', date: 'device', hour: 'device', kind: 'device' };
var PROBLEM_TEXT = {
	STALE: '状态超过 40 秒没有更新',
	NOT_RECORDING: '没有在记录（等待对时或数据分区）',
	DATA_MOUNT_MISSING: '数据分区未挂载',
	PENDING_WRITES: '有数据等待补写',
	NOT_RUNNING: '记录器没有运行'
};
var DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

// 只认对象自己的键：#by=constructor 之类不能借原型链混过校验
function has(o, k) {
	return Object.prototype.hasOwnProperty.call(o, k);
}

function el(tag, attrs, children) {
	var node = document.createElement(tag);
	Object.keys(attrs || {}).forEach(function(k) {
		var v = attrs[k];
		if (v == null || v === false)
			return;
		if (typeof v === 'function')
			node.addEventListener(k, v);
		else if (k === 'class')
			node.className = v;
		else
			node.setAttribute(k, v === true ? '' : String(v));
	});
	(Array.isArray(children) ? children : [children]).forEach(function(c) {
		if (c != null && c !== false)
			node.appendChild(c.nodeType ? c : document.createTextNode(String(c)));
	});
	return node;
}

function clear(node) {
	while (node.firstChild)
		node.removeChild(node.firstChild);
	return node;
}

function pad(n) {
	return (n < 10 ? '0' : '') + n;
}

// 两个接口都失败时（拿不到路由器的日期）才退回浏览器本地日期
function localDay() {
	var d = new Date();
	return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
}

function addDays(day, n) {
	var p = day.split('-'), d = new Date(Date.UTC(+p[0], +p[1] - 1, +p[2]) + n * 86400000);
	return d.getUTCFullYear() + '-' + pad(d.getUTCMonth() + 1) + '-' + pad(d.getUTCDate());
}

// 真实存在的日期（02-30 这类会被路由器拒绝，留在地址栏里每次刷新都报错）
function isDay(d) {
	return DAY_RE.test(d || '') && addDays(d, 0) === d;
}

// 与 r3mini-traffic 的 hs() 同一套单位：1024 进位，两位小数
function bytes(n) {
	var u = ['B', 'KB', 'MB', 'GB', 'TB'], x = n, i = 0;
	while (x >= 1024 && i < 4) { x /= 1024; i++; }
	return i ? x.toFixed(2) + ' ' + u[i] : n + ' B';
}

function count(n) {
	return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function parseResult(res) {
	if (!res || res.code !== 0) {
		var msg = ((res && (res.stderr || res.stdout)) || '').trim().split('\n')[0];
		throw new Error(msg || '流量记录接口无响应');
	}
	return JSON.parse(res.stdout);
}

function errorText(e) {
	var msg = (e && e.message) || String(e);
	if (/permission|access denied|拒绝/i.test(msg))
		return msg + '。新装的页面要重新登录 LuCI 才有权限';
	return msg;
}

function defaults(today) {
	return { from: today, to: today, h0: 0, h1: 24, by: 'device', sort: 'up', top: 100, proxy: true,
		device: '', exit: '', target: '', kind: '' };
}

function copy(s) {
	return Object.assign({}, s);
}

function pinned(s, dim) {
	return /^=/.test(s[dim] || '');
}

// 与 web report 的参数一一对应；等价命令行也由它生成
function reportArgs(s) {
	var a = ['--date', s.from === s.to ? s.from : s.from + '..' + s.to, '--by', s.by, '--sort', s.sort, '--top', String(s.top)];
	if (s.h0 !== 0 || s.h1 !== 24)
		a.push('--from', String(s.h0), '--to', String(s.h1));
	if (s.proxy)
		a.push('--proxy');
	['device', 'exit', 'target', 'kind'].forEach(function(k) {
		if (s[k])
			a.push('--' + k, s[k]);
	});
	return a;
}

function shellQuote(a) {
	return /^[A-Za-z0-9_.,:=@\/+-]+$/.test(a) ? a : "'" + a.replace(/'/g, "'\\''") + "'";
}

function hashOf(s) {
	var q = ['from=' + s.from, 'to=' + s.to, 'by=' + s.by, 'sort=' + s.sort, 'top=' + s.top, 'proxy=' + (s.proxy ? 1 : 0)];
	if (s.h0 !== 0 || s.h1 !== 24)
		q.push('h0=' + s.h0, 'h1=' + s.h1);
	['device', 'exit', 'target', 'kind'].forEach(function(k) {
		if (s[k])
			q.push(k + '=' + encodeURIComponent(s[k]));
	});
	return '#' + q.join('&');
}

// 地址栏 # 后面记着当前查询，刷新或收藏后能回到同一视图；任何一项不合法就整体弃用
function readHash(hash) {
	var h = (hash || '').replace(/^#/, ''), m = {};
	if (!h)
		return null;
	try {
		h.split('&').forEach(function(p) {
			var i = p.indexOf('=');
			if (i > 0)
				m[p.slice(0, i)] = decodeURIComponent(p.slice(i + 1));
		});
	} catch (e) {
		return null;
	}
	var s = defaults(m.from), int = function(v, d) { return v == null ? d : (/^\d{1,3}$/.test(v) ? +v : NaN); };
	s.to = m.to;
	s.by = m.by || 'device';
	s.sort = m.sort || 'up';
	s.top = int(m.top, 100);
	s.proxy = m.proxy !== '0';
	s.h0 = int(m.h0, 0);
	s.h1 = int(m.h1, 24);
	['device', 'exit', 'target', 'kind'].forEach(function(k) { s[k] = m[k] || ''; });
	if (!isDay(s.from) || !isDay(s.to) || s.from > s.to || !has(DIM_NAME, s.by) || !has(SORT_NAME, s.sort) ||
	    TOPS.indexOf(s.top) < 0 || !(s.h0 >= 0 && s.h0 < s.h1 && s.h1 <= 24) || (s.kind && !has(KIND_NAME, s.kind)))
		return null;
	return s;
}

function dimValue(dim, v) {
	return dim === 'kind' ? (KIND_NAME[v] || v) : v;
}

var CSS = [
	'.r3t{--bg:#f4f6f8;--card:#fff;--ink:#17202a;--muted:#5d6875;--line:#dde2e8;--soft:#eef1f4;--up:#c2410c;--down:#1d63c9;',
	'--ok:#1f8a4c;--warn:#b7791f;--bad:#c53030;--focus:#2563eb;container:r3t/inline-size;color:var(--ink);background:var(--bg);',
	'border-radius:8px;padding:clamp(10px,1.6vw,18px);font-size:14px;line-height:1.45;color-scheme:light}',
	'@media (prefers-color-scheme:dark){.r3t{--bg:#14181d;--card:#1c2229;--ink:#e6eaef;--muted:#9aa5b1;--line:#2d3640;',
	'--soft:#232b33;--up:#ff8a4c;--down:#62a8ff;--ok:#4ade80;--warn:#f6c453;--bad:#ff7a7a;--focus:#7aa7ff;color-scheme:dark}}',
	'.r3t *{box-sizing:border-box}.r3t button,.r3t input,.r3t select{font:inherit;color:inherit}',
	'.r3t-head{display:flex;flex-wrap:wrap;align-items:flex-start;justify-content:space-between;gap:10px 16px;margin-bottom:12px}',
	'.r3t-title{margin:0;font-size:clamp(18px,1.2rem + .4vw,24px);font-weight:700;letter-spacing:.01em}',
	'.r3t-sub{margin:2px 0 0;color:var(--muted);font-size:13px}',
	'.r3t-status{display:flex;flex-wrap:wrap;align-items:center;gap:6px 10px;justify-content:flex-end}',
	'.r3t-pill{display:inline-flex;align-items:center;gap:7px;padding:4px 10px;border:1px solid var(--line);border-radius:99px;',
	'background:var(--card);font-weight:600;font-size:13px}.r3t-dot{width:8px;height:8px;border-radius:50%;background:var(--muted)}',
	'.r3t-pill.ok .r3t-dot{background:var(--ok)}.r3t-pill.warn .r3t-dot{background:var(--warn)}.r3t-pill.bad .r3t-dot{background:var(--bad)}',
	'.r3t-meta{color:var(--muted);font-size:12px}.r3t-problems{flex-basis:100%;text-align:right;color:var(--warn);font-size:12px}',
	'.r3t-card{background:var(--card);border:1px solid var(--line);border-radius:8px}',
	'.r3t-controls{display:flex;flex-direction:column;gap:12px;padding:12px;margin-bottom:12px}',
	'.r3t-band{display:flex;flex-wrap:wrap;align-items:flex-end;gap:10px 24px}',
	'.r3t-field{display:flex;flex-direction:column;gap:5px;min-width:0;max-width:100%}.r3t-field.grow{flex:1 1 340px}',
	'.r3t-label{color:var(--muted);font-size:12px;font-weight:600}',
	'.r3t-line{display:flex;flex-wrap:wrap;align-items:center;gap:6px}.r3t-line>*{min-width:0}',
	'.r3t input[type=date],.r3t input[type=search],.r3t select{min-height:36px;padding:5px 8px;border:1px solid var(--line);',
	'border-radius:6px;background:var(--card);max-width:100%}.r3t input[type=date]{flex:0 1 150px}',
	'.r3t-filter select,.r3t-filter input[type=search]{flex:1 1 210px}.r3t-filter select.kind{flex:0 1 130px}',
	'.r3t-btn{min-height:36px;padding:5px 12px;border:1px solid var(--line);border-radius:6px;background:var(--card);cursor:pointer}',
	'.r3t-btn:hover{border-color:var(--muted)}.r3t-btn.on{background:var(--ink);border-color:var(--ink);color:var(--card)}',
	'.r3t-btn:focus-visible,.r3t-drill:focus-visible,.r3t input:focus-visible,.r3t select:focus-visible,.r3t-th:focus-visible{outline:2px solid var(--focus);outline-offset:1px}',
	'.r3t-seg{display:flex;flex-wrap:wrap;gap:6px}',
	'.r3t-check{display:inline-flex;align-items:center;gap:7px;min-height:36px;cursor:pointer}.r3t-check input{width:16px;height:16px}',
	'.r3t-hint{color:var(--muted);font-size:12px}',
	'.r3t-chips{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-bottom:10px}.r3t-chips:empty{display:none}',
	'.r3t-chip{display:inline-flex;align-items:center;gap:6px;max-width:100%;padding:3px 4px 3px 10px;border-radius:99px;',
	'background:var(--soft);border:1px solid var(--line);font-size:13px}.r3t-chip span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
	'.r3t-chip button{border:0;background:transparent;cursor:pointer;width:28px;height:28px;border-radius:50%;color:var(--muted)}',
	'.r3t-chip button:hover{background:var(--line);color:var(--ink)}',
	'.r3t-sum{display:grid;gap:10px;margin-bottom:12px;grid-template-columns:repeat(auto-fit,minmax(min(100%,170px),1fr))}',
	'.r3t-stat{padding:10px 12px}.r3t-stat b{display:block;font-size:clamp(18px,1.1rem + .5vw,24px);font-variant-numeric:tabular-nums}',
	'.r3t-stat .up{color:var(--up)}.r3t-stat .down{color:var(--down)}.r3t-stat small{color:var(--muted);font-size:12px}',
	'.r3t-table{position:relative;overflow:hidden}.r3t-row{display:grid;align-items:center;gap:4px 12px;padding:8px 12px;',
	'grid-template-columns:2.2rem minmax(0,1fr) repeat(4,minmax(5.5rem,auto));border-top:1px solid var(--line)}',
	'.r3t-row.head{border-top:0;color:var(--muted);font-size:12px;font-weight:600;background:var(--soft)}',
	'.r3t-num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}.r3t-rank{color:var(--muted);font-variant-numeric:tabular-nums}',
	'.r3t-th{border:0;background:transparent;padding:0;cursor:pointer;color:inherit;font-weight:inherit;text-align:inherit}',
	'.r3t-th.on{color:var(--ink)}.r3t-th.on:after{content:" ▼"}',
	'.r3t-name{min-width:0}.r3t-drill{display:block;width:100%;border:0;background:transparent;padding:0;text-align:left;cursor:pointer;',
	'overflow-wrap:anywhere;color:inherit}.r3t-drill:hover{text-decoration:underline}.r3t-drill[disabled]{cursor:default;text-decoration:none}',
	'.r3t-bar{height:4px;margin-top:5px;border-radius:2px;background:var(--soft);overflow:hidden}.r3t-bar i{display:block;height:100%;background:var(--up)}',
	'.r3t-bar.down i{background:var(--down)}.r3t-up{color:var(--up)}.r3t-down{color:var(--down)}',
	'.r3t-empty,.r3t-error{padding:28px 14px;text-align:center;color:var(--muted)}.r3t-error{color:var(--bad)}',
	'.r3t-more{padding:8px 12px;color:var(--muted);font-size:12px;border-top:1px solid var(--line)}',
	'.r3t-busy{position:absolute;inset:0;display:none;align-items:flex-start;justify-content:center;padding-top:40px;',
	'background:color-mix(in srgb,var(--card) 65%,transparent)}.r3t.is-busy .r3t-busy{display:flex}',
	'.r3t-busy span{padding:6px 14px;border-radius:99px;background:var(--ink);color:var(--card);font-size:13px}',
	'.r3t-notes{margin-top:12px;color:var(--muted);font-size:12px}.r3t-notes summary{cursor:pointer;font-weight:600}',
	'.r3t-notes ul{margin:6px 0 0;padding-left:18px}.r3t-cmd{display:block;margin-top:8px;padding:6px 8px;border-radius:6px;',
	'background:var(--soft);color:var(--ink);font-family:ui-monospace,Consolas,monospace;font-size:12px;overflow-wrap:anywhere}',
	'@container r3t (max-width:720px){.r3t-row{grid-template-columns:1.8rem minmax(0,1fr) minmax(0,1fr);',
	'grid-template-areas:"rank name name" "rank up down" "rank total conns"}.r3t-row>:nth-child(1){grid-area:rank}',
	'.r3t-row>:nth-child(2){grid-area:name}.r3t-row>:nth-child(3){grid-area:up}.r3t-row>:nth-child(4){grid-area:down}',
	'.r3t-row>:nth-child(5){grid-area:total}.r3t-row>:nth-child(6){grid-area:conns}.r3t-row .r3t-num{text-align:left}',
	// 窄屏上表头换成一排可点的排序按钮；所有可点的东西不低于 40 px
	'.r3t-row.head{display:flex;flex-wrap:wrap;gap:6px}.r3t-row.head>:first-child{display:none}',
	'.r3t-th{min-height:40px;padding:0 12px;border:1px solid var(--line);border-radius:99px;background:var(--card)}',
	'.r3t-th.on{border-color:var(--ink)}',
	'.r3t-btn,.r3t input[type=date],.r3t input[type=search],.r3t select,.r3t-check,.r3t-drill{min-height:40px}',
	'.r3t-chip button{width:40px;height:40px}}'
].join('');

return view.extend({
	load: function() {
		var s = readHash(location.hash);
		return Promise.all([
			fs.exec(CLI, ['web', 'status']).then(parseResult).catch(function(e) { return { state: 'ERROR', error: errorText(e) }; }),
			fs.exec(CLI, ['web', 'report'].concat(s ? reportArgs(s) : ['--by', 'device', '--proxy']))
				.then(parseResult).catch(function(e) { return { error: errorText(e) }; })
		]);
	},

	render: function(data) {
		var status = data[0] || {}, rep = data[1] || {};
		this.today = rep.today || status.today || localDay();
		this.state = readHash(location.hash) || defaults(this.today);
		this.back = [];
		this.status = status;
		this.report = rep.error ? null : rep;
		this.error = rep.error || null;
		this.root = el('div', { 'class': 'r3t' }, [el('style', {}, CSS)]);
		this.buildHead();
		this.buildControls();
		this.chips = this.root.appendChild(el('div', { 'class': 'r3t-chips' }));
		this.summary = this.root.appendChild(el('div', { 'class': 'r3t-sum' }));
		this.table = this.root.appendChild(el('div', { 'class': 'r3t-card r3t-table' }));
		this.notes = this.root.appendChild(el('details', { 'class': 'r3t-notes' }));
		this.sync();
		this.renderStatus();
		this.renderResults();
		poll.add(this.refreshStatus.bind(this), 30);
		return this.root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	buildHead: function() {
		var self = this;
		this.statusBox = el('div', { 'class': 'r3t-status' });
		this.root.appendChild(el('div', { 'class': 'r3t-head' }, [
			el('div', {}, [
				el('h2', { 'class': 'r3t-title' }, '代理流量记录'),
				el('p', { 'class': 'r3t-sub' }, '经过本路由器的流量，按设备、出口、目标查看（r3mini-traffic 记录，只读）')
			]),
			this.statusBox,
		]));
		this.refreshBtn = el('button', { 'type': 'button', 'class': 'r3t-btn', 'click': function() {
			self.refreshStatus();
			self.query();
		} }, '刷新');
	},

	buildControls: function() {
		var self = this, box = el('div', { 'class': 'r3t-card r3t-controls' });
		var change = function(fn) { return function(ev) { var s = copy(self.state); fn(s, ev.target); self.go(s, false); }; };
		var field = function(label, kids, cls) {
			return el('div', { 'class': 'r3t-field' + (cls ? ' ' + cls : '') }, [
				el('span', { 'class': 'r3t-label' }, label), el('div', { 'class': 'r3t-line' }, kids)]);
		};
		var to = function() { return el('span', { 'class': 'r3t-hint' }, '至'); };

		this.inFrom = el('input', { 'type': 'date', 'aria-label': '开始日期', 'change': change(function(s, t) {
			if (DAY_RE.test(t.value)) { s.from = t.value; if (s.to < s.from) s.to = s.from; }
		}) });
		this.inTo = el('input', { 'type': 'date', 'aria-label': '结束日期', 'change': change(function(s, t) {
			if (DAY_RE.test(t.value)) { s.to = t.value; if (s.from > s.to) s.from = s.to; }
		}) });
		var quick = [['今天', 0, 0], ['昨天', -1, -1], ['近 7 天', -6, 0], ['近 30 天', -29, 0]].map(function(q) {
			return el('button', { 'type': 'button', 'class': 'r3t-btn', 'click': function() {
				var s = copy(self.state);
				s.from = addDays(self.today, q[1]);
				s.to = addDays(self.today, q[2]);
				self.go(s, false);
			} }, q[0]);
		});
		this.inH0 = el('select', { 'aria-label': '开始小时', 'change': change(function(s, t) {
			s.h0 = +t.value; if (s.h1 <= s.h0) s.h1 = s.h0 + 1;
		}) });
		this.inH1 = el('select', { 'aria-label': '结束小时', 'change': change(function(s, t) {
			s.h1 = +t.value; if (s.h0 >= s.h1) s.h0 = s.h1 - 1;
		}) });
		for (var h = 0; h <= 24; h++) {
			if (h < 24) this.inH0.appendChild(el('option', { 'value': h }, pad(h) + ':00'));
			if (h > 0) this.inH1.appendChild(el('option', { 'value': h }, pad(h) + ':00'));
		}
		box.appendChild(el('div', { 'class': 'r3t-band' }, [
			field('日期', [this.inFrom, to(), this.inTo].concat(quick), 'grow'),
			field('每天时段', [this.inH0, to(), this.inH1])
		]));

		this.dimBtns = {};
		var seg = el('div', { 'class': 'r3t-seg', 'role': 'group', 'aria-label': '分组' }, DIMS.map(function(d) {
			return self.dimBtns[d[0]] = el('button', { 'type': 'button', 'class': 'r3t-btn', 'click': function() {
				var s = copy(self.state);
				s.by = d[0];
				if (d[0] === 'date' || d[0] === 'hour') s.sort = 'key';
				else if (s.sort === 'key') s.sort = 'up';
				self.go(s, false);
			} }, d[1]);
		}));
		this.inTop = el('select', { 'aria-label': '显示条数', 'change': change(function(s, t) { s.top = +t.value; }) },
			TOPS.map(function(n) { return el('option', { 'value': n }, '前 ' + n + ' 项'); }));
		box.appendChild(el('div', { 'class': 'r3t-band' }, [
			field('分组', [seg], 'grow'),
			field('显示', [this.inTop, this.refreshBtn])
		]));

		this.inDevice = el('select', { 'aria-label': '设备', 'change': change(function(s, t) { s.device = t.value; }) });
		this.inExit = el('select', { 'aria-label': '出口', 'change': change(function(s, t) { s.exit = t.value; }) });
		this.inTarget = el('input', { 'type': 'search', 'placeholder': '目标包含…（回车查询）', 'aria-label': '目标',
			'change': change(function(s, t) { s.target = t.value.trim(); }) });
		this.inKind = el('select', { 'class': 'kind', 'aria-label': '类型', 'change': change(function(s, t) { s.kind = t.value; }) },
			[el('option', { 'value': '' }, '全部类型')].concat(Object.keys(KIND_NAME).map(function(k) {
				return el('option', { 'value': k }, KIND_NAME[k]);
			})));
		this.inProxy = el('input', { 'type': 'checkbox', 'change': change(function(s, t) { s.proxy = t.checked; }) });
		box.appendChild(el('div', { 'class': 'r3t-band' }, [
			field('过滤', [this.inDevice, this.inExit, this.inTarget, this.inKind,
				el('label', { 'class': 'r3t-check' }, [this.inProxy, '只看代理'])], 'grow r3t-filter')
		]));
		this.root.appendChild(box);
	},

	// 状态 → 控件；下拉框的候选项来自上一次查询结果的 facets
	sync: function() {
		var s = this.state, rep = this.report, avail = rep && rep.available;
		this.inFrom.value = s.from;
		this.inTo.value = s.to;
		[this.inFrom, this.inTo].forEach(function(i) {
			if (avail && avail.first) i.min = avail.first;
			if (this.today) i.max = this.today;
		}, this);
		this.inH0.value = String(s.h0);
		this.inH1.value = String(s.h1);
		this.inTop.value = String(s.top);
		this.inKind.value = s.kind;
		this.inProxy.checked = s.proxy;
		this.inTarget.value = s.target.replace(/^=/, '');
		Object.keys(this.dimBtns).forEach(function(d) {
			this.dimBtns[d].className = 'r3t-btn' + (d === s.by ? ' on' : '');
			this.dimBtns[d].setAttribute('aria-pressed', d === s.by ? 'true' : 'false');
		}, this);
		this.fillFacet(this.inDevice, '全部设备', rep && rep.facets && rep.facets.device, s.device);
		this.fillFacet(this.inExit, '全部出口', rep && rep.facets && rep.facets.exit, s.exit);
	},

	fillFacet: function(sel, all, list, cur) {
		clear(sel).appendChild(el('option', { 'value': '' }, all));
		var seen = false;
		(list || []).forEach(function(f) {
			seen = seen || cur === '=' + f.k;
			sel.appendChild(el('option', { 'value': '=' + f.k }, f.k + '  ·  上传 ' + bytes(f.up)));
		});
		if (cur && !seen)
			sel.appendChild(el('option', { 'value': cur }, /^=/.test(cur) ? cur.slice(1) + '（本范围无数据）' : '包含「' + cur + '」'));
		sel.value = cur;
	},

	// push=true 时记下当前状态，供「返回上一步」
	go: function(s, push) {
		if (push)
			this.back.push(this.state);
		this.state = s;
		this.sync();
		this.query();
	},

	query: function() {
		var self = this;
		if (this.busy) {
			this.pending = true;
			return;
		}
		this.busy = true;
		this.root.classList.add('is-busy');
		var s = copy(this.state);
		try {
			history.replaceState(null, '', hashOf(s));
		} catch (e) {}
		return fs.exec(CLI, ['web', 'report'].concat(reportArgs(s))).then(parseResult).then(function(rep) {
			self.report = rep;
			self.error = null;
			self.today = rep.today || self.today;
		}).catch(function(e) {
			self.error = errorText(e);
		}).then(function() {
			self.busy = false;
			self.root.classList.remove('is-busy');
			if (self.pending) {
				self.pending = false;
				return self.query();
			}
			self.sync();
			self.renderResults();
		});
	},

	refreshStatus: function() {
		var self = this;
		return fs.exec(CLI, ['web', 'status']).then(parseResult).catch(function(e) {
			return { state: 'ERROR', error: errorText(e) };
		}).then(function(st) {
			self.status = st;
			// 页面开过午夜后「今天」「近 N 天」要跟着路由器的日期走
			if (st.today && st.today !== self.today) {
				self.today = st.today;
				self.sync();
			}
			self.renderStatus();
		});
	},

	renderStatus: function() {
		var st = this.status || {}, box = clear(this.statusBox), cls = 'bad', text = '记录器没有运行', meta = [];
		if (st.state === 'STATUS_OK') { cls = 'ok'; text = '记录中'; }
		else if (st.state === 'STATUS_DEGRADED') { cls = 'warn'; text = '记录异常'; }
		else if (st.state === 'ERROR') { text = '状态读取失败'; }
		if (st.version)
			meta.push('v' + st.version, '轮询 ' + (st.poll_ms / 1000).toFixed(1) + ' 秒', '当前连接 ' + count(st.connections || 0));
		box.appendChild(el('span', { 'class': 'r3t-pill ' + cls }, [el('span', { 'class': 'r3t-dot' }), text]));
		if (meta.length)
			box.appendChild(el('span', { 'class': 'r3t-meta' }, meta.join(' · ')));
		var probs = (st.problems || []).filter(function(p) { return p !== 'NOT_RUNNING' || st.state !== 'NOT_RUNNING'; })
			.map(function(p) { return PROBLEM_TEXT[p] || (/^API_/.test(p) ? 'OpenClash 控制接口失败（' + p.slice(4) + '）' : p); });
		if (st.error)
			probs.push(st.error);
		if (st.version && st.version_cli && st.version !== st.version_cli)
			probs.push('运行中的是 v' + st.version + '，已安装 v' + st.version_cli + '：重启 r3mini-traffic 服务后生效');
		if (probs.length)
			box.appendChild(el('span', { 'class': 'r3t-problems' }, probs.join('；')));
	},

	chip: function(label, onRemove) {
		return el('span', { 'class': 'r3t-chip' }, [el('span', { 'title': label }, label),
			el('button', { 'type': 'button', 'aria-label': '去掉：' + label, 'title': '去掉', 'click': onRemove }, '✕')]);
	},

	renderChips: function() {
		var self = this, s = this.state, box = clear(this.chips);
		var drop = function(fn) { return function() { var n = copy(self.state); fn(n); self.go(n, false); }; };
		if (this.back.length)
			box.appendChild(el('button', { 'type': 'button', 'class': 'r3t-btn', 'click': function() {
				self.state = self.back.pop();
				self.sync();
				self.query();
			} }, '← 返回上一步'));
		['device', 'exit', 'target'].forEach(function(k) {
			if (s[k])
				box.appendChild(self.chip(DIM_NAME[k] + (pinned(s, k) ? ' = ' + s[k].slice(1) : ' 包含「' + s[k] + '」'),
					drop(function(n) { n[k] = ''; })));
		});
		if (s.kind)
			box.appendChild(this.chip('类型 = ' + KIND_NAME[s.kind], drop(function(n) { n.kind = ''; })));
		if (s.h0 !== 0 || s.h1 !== 24)
			box.appendChild(this.chip('每天 ' + pad(s.h0) + ':00–' + pad(s.h1) + ':00', drop(function(n) { n.h0 = 0; n.h1 = 24; })));
		if (!s.proxy)
			box.appendChild(this.chip('含直连流量', drop(function(n) { n.proxy = true; })));
	},

	renderSummary: function(rep) {
		var box = clear(this.summary), s = this.state;
		var stat = function(label, value, cls, small) {
			return el('div', { 'class': 'r3t-card r3t-stat' }, [el('small', {}, label), el('b', { 'class': cls || '' }, value),
				small ? el('small', {}, small) : null]);
		};
		var filtered = s.device || s.exit || s.target || s.kind;
		box.appendChild(stat('上传', bytes(rep.total.up), 'up', '下载 ' + bytes(rep.total.down)));
		box.appendChild(stat('合计', bytes(rep.total.up + rep.total.down), '', rep.groups + ' 个' + DIM_NAME[rep.by[0]]));
		box.appendChild(stat('连接', count(rep.total.conns), '', '明细 ' + count(rep.total.rows) + ' 行'));
		box.appendChild(stat('未归因上传', bytes(rep.unattributed.up), '', '下载 ' + bytes(rep.unattributed.down) + ' · ' +
			(filtered ? '不随过滤变化' : '对不上具体连接的部分')));
		var span = rep.from === rep.to ? rep.from : rep.from + ' 至 ' + rep.to;
		box.appendChild(stat('日期', span, '', rep.dates.length + ' / ' + rep.days + ' 天有数据 · 查询 ' +
			(rep.elapsed_ms / 1000).toFixed(1) + ' 秒'));
	},

	renderResults: function() {
		var self = this, rep = this.report, s = this.state, box = clear(this.table);
		this.renderChips();
		box.appendChild(el('div', { 'class': 'r3t-busy' }, el('span', {}, '查询中…')));
		if (this.error) {
			box.appendChild(el('div', { 'class': 'r3t-error', 'role': 'alert' }, this.error));
			clear(this.summary);
			this.renderNotes();
			return;
		}
		this.renderSummary(rep);
		var dim = rep.by[0], sortBy = rep.sort;
		var metric = function(r) { return sortBy === 'down' ? r.down : sortBy === 'total' ? r.up + r.down : sortBy === 'conns' ? r.conns : r.up; };
		var whole = sortBy === 'down' ? rep.total.down : sortBy === 'total' ? rep.total.up + rep.total.down :
			sortBy === 'conns' ? rep.total.conns : rep.total.up;
		var th = function(key, label, num) {
			return el('button', { 'type': 'button', 'class': 'r3t-th' + (sortBy === key ? ' on' : '') + (num ? ' r3t-num' : ''),
				'aria-label': '按' + label + '排序', 'click': function() {
					var n = copy(self.state);
					n.sort = key;
					self.go(n, false);
				} }, label);
		};
		box.appendChild(el('div', { 'class': 'r3t-row head' }, [
			el('span', {}, '#'), th('key', DIM_NAME[dim]), th('up', '上传', true), th('down', '下载', true),
			th('total', '合计', true), th('conns', '连接', true)]));
		if (!rep.rows.length) {
			box.appendChild(el('div', { 'class': 'r3t-empty' }, rep.dates.length ? '这个范围里没有符合条件的流量' :
				'这个日期范围还没有记录（最早的数据：' + (rep.available.first || '无') + '）'));
		}
		rep.rows.forEach(function(r, i) {
			var key = r.k[0], share = whole > 0 ? metric(r) / whole : 0;
			var canDrill = !(dim === 'date' && s.from === s.to) && !(dim === 'hour' && s.h1 - s.h0 === 1) && !pinned(s, dim);
			box.appendChild(el('div', { 'class': 'r3t-row' }, [
				el('span', { 'class': 'r3t-rank' }, i + 1),
				el('div', { 'class': 'r3t-name' }, [
					el('button', { 'type': 'button', 'class': 'r3t-drill', 'title': canDrill ? '只看这一项，并按' +
						DIM_NAME[NEXT[dim]] + '展开' : key, 'disabled': !canDrill, 'click': function() { self.drill(dim, key); } },
						dimValue(dim, key)),
					el('div', { 'class': 'r3t-bar' + (sortBy === 'down' ? ' down' : '') },
						el('i', { 'style': 'width:' + Math.max(share * 100, share > 0 ? 0.5 : 0).toFixed(2) + '%' }))
				]),
				el('span', { 'class': 'r3t-num r3t-up' }, bytes(r.up)),
				el('span', { 'class': 'r3t-num r3t-down' }, bytes(r.down)),
				el('span', { 'class': 'r3t-num' }, bytes(r.up + r.down)),
				el('span', { 'class': 'r3t-num' }, count(r.conns))
			]));
		});
		if (rep.groups > rep.rows.length)
			box.appendChild(el('div', { 'class': 'r3t-more' }, '只显示了前 ' + rep.rows.length + ' 项，共 ' + rep.groups + ' 项' +
				(rep.clipped ? '（结果太大，已截短）' : '；可在上方调大显示条数或加过滤')));
		this.renderNotes();
	},

	drill: function(dim, key) {
		var n = copy(this.state);
		if (dim === 'date') { n.from = key; n.to = key; }
		else if (dim === 'hour') { n.h0 = parseInt(key, 10); n.h1 = n.h0 + 1; }
		else if (dim === 'kind') n.kind = key;
		else n[dim] = '=' + key;
		n.by = [NEXT[dim], 'target', 'device', 'exit'].filter(function(d) { return d !== dim && !pinned(n, d); })[0] || 'target';
		if (n.sort === 'key')
			n.sort = 'up';
		this.go(n, true);
	},

	renderNotes: function() {
		var st = this.status || {}, d = st.data || {}, box = clear(this.notes);
		var cmd = ['r3mini-traffic', 'report'].concat(reportArgs(this.state)).map(shellQuote).join(' ');
		box.appendChild(el('summary', {}, '口径与说明'));
		box.appendChild(el('ul', {}, [
			el('li', {}, '字节是载荷估算：OpenClash 连接取核心计数；SOCKS 与转发按连接跟踪表扣除包头估算。'),
			el('li', {}, '「只看代理」不含直连与转发；目标是订阅节点服务器的直连仍计入，标「订阅节点直连」。'),
			el('li', {}, '「未归因」是 OpenClash 核心计数里对不上具体连接的部分（含直连），不随过滤变化。'),
			el('li', {}, '设备名在 /etc/config/r3mini_traffic 里用 config device（mac、name）命名。'),
			d.count != null ? el('li', {}, '数据保留 ' + d.retention_days + ' 天、上限 ' + bytes(d.max_bytes) + '；现有 ' + d.count +
				' 天（' + (d.first || '-') + ' 起），占用 ' + bytes(d.bytes) + '。') : null,
			el('li', {}, '一次查询最多读盘 14 秒，范围太大会提示缩小。点一行只看这一项并按下一维度展开。')
		]));
		box.appendChild(el('code', { 'class': 'r3t-cmd', 'title': '在路由器上执行可得到同一结果' }, cmd));
	}
});
