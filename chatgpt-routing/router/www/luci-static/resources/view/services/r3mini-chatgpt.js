'use strict';
'require view';
'require fs';
'require poll';

var CLI = '/usr/sbin/r3mini-chatgpt';
var DEFAULT_SOURCE = 'lian_li.yaml';
var CHATGPT_DOMAINS = ['chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com', 'chatgpt.livekit.cloud'];
var COUNTRY_NAMES = { JP: '日本', US: '美国', SG: '新加坡', TW: '台湾', HK: '香港', KR: '韩国', GB: '英国', DE: '德国',
	FR: '法国', AU: '澳大利亚', CA: '加拿大', NL: '荷兰', IN: '印度', ES: '西班牙', IT: '意大利', CH: '瑞士',
	SE: '瑞典', FI: '芬兰', IE: '爱尔兰', NO: '挪威', NZ: '新西兰', BR: '巴西' };
var BENCH_ERRORS = { UNSUPPORTED_REGION: '地区不支持', REGION_CHANGED: '三轮地区不一致', SOURCE_CHANGED: '配置已更新，请重新测速',
	BENCH_INTERRUPTED: '测速已中断，请重试', CORE_MISSING: '测速暂不可用', CORE_START_FAILED: '测速启动失败',
	CORE_NOT_READY: '测速服务尚未就绪', TLS_FAILED: '连接失败', TRACE_FAILED: '地区验证失败', API_UNAVAILABLE: '服务连接失败',
	PROBE_FAILED: '连接失败' };

function countryName(country) {
	return typeof country === 'string' && /^[A-Z]{2}$/.test(country) ? COUNTRY_NAMES[country] || country : '地区未确认';
}

function measured(node) {
	return node && Array.isArray(node.samples_ms) && node.samples_ms.length === 3 && node.samples_ms.every(function(n) {
		return typeof n === 'number' && isFinite(n) && n > 0;
	}) && typeof node.median_ms === 'number' && isFinite(node.median_ms) && node.median_ms > 0 && /^[A-Z]{2}$/.test(node.country || '');
}

function eligible(node) {
	return !!(node && node.eligible === true && measured(node));
}

function latency(ms) {
	return typeof ms === 'number' && isFinite(ms) && ms > 0 ? Math.round(ms) + ' ms' : '—';
}

function benchmarkError(error) {
	return Object.prototype.hasOwnProperty.call(BENCH_ERRORS, error) ? BENCH_ERRORS[error] : '测速未通过，请重试。';
}

// 网站名、节点名、域名都按文本插入，禁止作为 HTML 解释。
function el(tag, attrs, children) {
	var node = document.createElement(tag);
	Object.keys(attrs || {}).forEach(function(k) {
		var v = attrs[k];
		if (v == null || v === false) return;
		if (typeof v === 'function') node.addEventListener(k, v);
		else if (k === 'class') node.className = v;
		else node.setAttribute(k, v === true ? '' : String(v));
	});
	(Array.isArray(children) ? children : [children]).forEach(function(c) {
		if (c != null && c !== false)
			node.appendChild(c.nodeType ? c : document.createTextNode(String(c)));
	});
	return node;
}

function clear(node) {
	while (node.firstChild) node.removeChild(node.firstChild);
	return node;
}

function parseResult(res) {
	var data;
	try { data = JSON.parse(res && res.stdout || ''); }
	catch (e) {
		throw new Error(res && res.code !== 0 ? '操作失败，请刷新后重试。' : '返回内容无法读取，请刷新后重试。');
	}
	if (!res || res.code !== 0 || !data || data.ok !== true)
		throw new Error(data && typeof data.message === 'string' && data.message || '操作失败，请刷新后重试。');
	return data;
}

function errorText(e) {
	var msg = e && e.message || '';
	if (/permission|access denied|拒绝/i.test(msg))
		return '当前会话没有操作权限，请退出 LuCI 后重新登录。';
	return /[\u3400-\u9fff]/.test(msg) ? msg : '无法读取路由器响应，请检查连接后刷新。';
}

function statusErrorText(st) {
	if (!st || !st.error) return '';
	if (typeof st.message === 'string' && /[\u3400-\u9fff]/.test(st.message)) return st.message;
	if (typeof st.error === 'string' && /[\u3400-\u9fff]/.test(st.error)) return st.error;
	return '分流状态异常，请刷新或恢复原分流。';
}

function isSource(s) {
	return typeof s === 'string' && s.length > 0 && s.length <= 255 && !/[\/\\\x00-\x1f]/.test(s) && s !== '.' && s !== '..';
}

function nodesOf(nodes) {
	return (Array.isArray(nodes) ? nodes : []).filter(function(n) {
		return n && /^[a-f0-9]{16}$/.test(n.id) && typeof n.name === 'string' && n.name.length > 0;
	});
}

function rulesOf(rules) {
	return (Array.isArray(rules) ? rules : []).filter(function(r) {
		return r && /^[a-f0-9]{12}$/.test(r.id) && Array.isArray(r.domains);
	});
}

function titleOf(rule) {
	return rule.label || rule.domains[0] || '未命名网站';
}

function ruleState(rule, pending) {
	if (pending) return { text: '待启动生效', cls: 'warn' };
	if (rule.error || rule.enabled && !rule.applied || rule.applied && !rule.enabled) return { text: '异常', cls: 'bad' };
	return rule.enabled ? { text: '已启用', cls: 'ok' } : { text: '已停用', cls: '' };
}

var CSS = [
	'.r3cg{max-width:1080px;line-height:1.5}.r3cg *{box-sizing:border-box}',
	'.r3cg-header,.r3cg-heading,.r3cg-actions{display:flex;align-items:center;flex-wrap:wrap;gap:.65rem}',
	'.r3cg-header{justify-content:space-between;margin-bottom:1rem}.r3cg h2,.r3cg h3{margin:0}',
	'.r3cg-intro{margin:0 0 1rem}.r3cg-state{display:inline-flex;align-items:center;gap:.4rem;font-size:.9em;font-weight:600}',
	'.r3cg-dot{height:.6rem;width:.6rem;border-radius:50%;background:#707a83;flex:none}',
	'.r3cg-state.ok .r3cg-dot{background:#24904e}.r3cg-state.bad .r3cg-dot{background:#c84343}',
	'.r3cg-state.warn .r3cg-dot{background:#b07800}.r3cg-list{display:grid;gap:1rem;margin:1rem 0}',
	'.r3cg-rule{border:1px solid #8885;border-radius:5px;padding:1rem;min-width:0}',
	'.r3cg-rule-head{display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:.5rem}',
	'.r3cg-rule h3{font-size:1.05em;overflow-wrap:anywhere;min-width:0}',
	'.r3cg-data,.r3cg-fields{display:grid;grid-template-columns:minmax(0,1fr);gap:1rem}',
	'.r3cg-data{margin:.8rem 0}.r3cg-data dt{font-size:.9em;opacity:.75}',
	'.r3cg-data dd{margin:.2rem 0 0;overflow-wrap:anywhere}.r3cg-field{min-width:0}',
	'.r3cg-form{margin:1.25rem 0;padding:1rem;border:1px solid #8885;border-radius:5px}',
	'.r3cg-form[hidden]{display:none}.r3cg-form h3{margin-bottom:1rem}',
	'.r3cg-field label{display:block;font-weight:600;margin-bottom:.4rem}',
	'.r3cg input,.r3cg textarea,.r3cg select{display:block;width:100%;max-width:100%;min-width:0;min-height:42px;font:inherit}',
	'.r3cg textarea{resize:vertical;min-height:8rem}.r3cg-hint{font-size:.9em;opacity:.8;margin:.4rem 0 0;overflow-wrap:anywhere}',
	'.r3cg-actions{margin-top:1rem}.r3cg button{min-height:42px;white-space:normal;max-width:100%}',
	'.r3cg button:focus-visible,.r3cg input:focus-visible,.r3cg textarea:focus-visible,.r3cg select:focus-visible{outline:2px solid currentColor;outline-offset:3px}',
	'.r3cg button:disabled,.r3cg input:disabled,.r3cg textarea:disabled,.r3cg select:disabled{cursor:default;opacity:.55}',
	'.r3cg-message{margin:.8rem 0 0;padding:.7rem .85rem;border:1px solid #8885;border-radius:4px;overflow-wrap:anywhere}',
	'.r3cg-message.bad{border-color:#c84343}.r3cg-message.ok{border-color:#24904e}.r3cg-message.warn{border-color:#b07800}',
	'.r3cg-message:empty{display:none}.r3cg-note,.r3cg-empty{font-size:.9em;opacity:.8;margin:1rem 0;overflow-wrap:anywhere}',
	'.r3cg-field.full{grid-column:1/-1}',
	'.r3cg-benchmark{grid-column:1/-1;min-width:0}.r3cg-benchmark progress{display:block;width:100%;height:12px;margin:.6rem 0}',
	'.r3cg-benchmark summary{cursor:pointer;margin-top:.75rem}.r3cg-bench-list{list-style:none;padding:0;margin:.5rem 0}',
	'.r3cg-bench-list li{padding:.6rem 0;border-bottom:1px solid #8884;overflow-wrap:anywhere}',
	'.r3cg-bench-list strong{font-weight:600}.r3cg-bench-list p{margin:.2rem 0;font-size:.9em;opacity:.85}',
	'@media(min-width:700px){.r3cg-fields{grid-template-columns:repeat(2,minmax(0,1fr))}.r3cg-data{grid-template-columns:2fr 1fr 1fr}}',
	'@media(max-width:420px){.r3cg-header{align-items:flex-start}.r3cg-form>.r3cg-actions{display:grid;grid-template-columns:minmax(0,1fr)}',
	'.r3cg-form>.r3cg-actions button{width:100%}.r3cg-rule .r3cg-actions{gap:.5rem}.r3cg-rule .r3cg-actions button{flex:1 1 auto}}'
].join('');

return view.extend({
	load: function() {
		return fs.exec(CLI, ['status']).then(parseResult).then(function(st) { return { status: st }; })
			.catch(function(e) { return { error: errorText(e) }; });
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	render: function(data) {
		var self = this;
		this.status = null;
		this.statusError = data.error || '';
		this.source = '';
		this.selected = '';
		this.label = '';
		this.domainsText = '';
		this.preset = '';
		this.editId = '';
		this.sources = [];
		this.nodes = [];
		this.rules = [];
		this.nodesSource = '';
		this.benchmark = null;
		this.benchmarkStarting = Object.create(null);
		this.benchmarkNotice = '';
		this.readSerial = 0;
		this.reading = false;
		this.foreground = false;
		this.mutating = false;
		this.formOpen = false;
		this.notice = '';
		this.noticeTone = '';
		this.dirty = false;
		this.ruleButtons = [];
		this.root = el('div', { 'class': 'r3cg' }, el('style', {}, CSS));
		this.badge = el('span', { 'class': 'r3cg-state', 'role': 'status', 'aria-live': 'polite' });
		this.refreshBtn = this.button('刷新', 'neutral', function() { self.refreshStatus(true); });
		this.root.appendChild(el('div', { 'class': 'r3cg-header' }, [
			el('div', { 'class': 'r3cg-heading' }, [el('h2', {}, '网站分流'), this.badge]), this.refreshBtn
		]));
		this.root.appendChild(el('p', { 'class': 'r3cg-intro' }, '添加网站域名，并为每条规则手动指定节点；其他流量保持现状。'));
		this.addBtn = this.button('添加网站', 'add', function() { self.openForm(null, false); });
		this.presetBtn = this.button('ChatGPT 预设', 'neutral', function() { self.openForm(null, true); });
		this.disableBtn = this.button('恢复原分流', 'reset', function() { self.mutate('disable'); });
		this.root.appendChild(el('div', { 'class': 'r3cg-actions' }, [this.addBtn, this.presetBtn, this.disableBtn]));
		this.message = el('p', { 'class': 'r3cg-message', 'role': 'status', 'aria-live': 'polite' });
		this.root.appendChild(this.message);
		this.list = this.root.appendChild(el('div', { 'class': 'r3cg-list', 'aria-label': '网站分流规则' }));
		this.buildForm();
		this.root.appendChild(el('p', { 'class': 'r3cg-note' },
			'域名规则同时覆盖子域名。恢复原分流会停用全部网站规则并保留定义，移除此模块的专用设置；其他流量保持现状。'));
		if (data.status) this.acceptStatus(data.status, '');
		else { this.renderRules(); this.renderSources(); this.renderNodes(); }
		this.sync();
		poll.add(function() { return self.refreshStatus(false); }, 5);
		return this.root;
	},

	button: function(text, kind, click) {
		return el('button', { 'type': 'button', 'class': 'cbi-button cbi-button-' + kind, 'click': click }, text);
	},

	buildForm: function() {
		var self = this;
		this.form = el('section', { 'class': 'r3cg-form', 'aria-label': '网站规则编辑', 'hidden': true });
		this.formTitle = el('h3', {}, '添加网站');
		this.labelInput = el('input', { 'id': 'r3cg-label', 'type': 'text', 'maxlength': 128, 'placeholder': '例如：常用网站（可选）',
			'input': function(ev) { self.label = ev.target.value; self.dirty = true; self.sync(); } });
		this.domainsInput = el('textarea', { 'id': 'r3cg-domains', 'rows': 5, 'placeholder': 'example.com\nhttps://example.org/path',
			'aria-describedby': 'r3cg-domain-hint', 'input': function(ev) {
				self.domainsText = ev.target.value;
				self.dirty = true;
				self.sync();
			} });
		this.sourceSelect = el('select', { 'id': 'r3cg-source', 'aria-describedby': 'r3cg-source-hint', 'change': function(ev) {
			if (self.mutating) return;
			self.source = ev.target.value;
			self.selected = '';
			self.nodes = [];
			self.nodesSource = '';
			self.benchmark = null;
			self.benchmarkNotice = '';
			self.dirty = true;
			self.notice = '';
			self.renderNodes();
			self.refreshStatus(true);
		} });
		this.nodeSelect = el('select', { 'id': 'r3cg-node', 'aria-describedby': 'r3cg-node-hint', 'change': function(ev) {
			if (self.mutating) return;
			self.selected = ev.target.value;
			self.dirty = true;
			self.notice = '';
			self.sync();
		} });
		this.sourceHint = el('p', { 'class': 'r3cg-hint', 'id': 'r3cg-source-hint' });
		this.nodeHint = el('p', { 'class': 'r3cg-hint', 'id': 'r3cg-node-hint', 'aria-live': 'polite' });
		this.benchmarkBtn = this.button('3 轮测速', 'neutral', function() { self.startBenchmark(); });
		this.bestBtn = this.button('选择最低延迟', 'neutral', function() { self.selectBest(); });
		this.benchmarkProgress = el('p', { 'class': 'r3cg-hint', 'role': 'status', 'aria-live': 'polite' });
		this.benchmarkBar = el('progress', { 'max': 1, 'value': 0, 'aria-label': '节点测速进度' });
		this.benchmarkRows = el('ul', { 'class': 'r3cg-bench-list' });
		function field(label, id, control, hint, full) {
			return el('div', { 'class': 'r3cg-field' + (full ? ' full' : '') },
				[el('label', { 'for': id }, label), control, hint]);
		}
		this.form.appendChild(this.formTitle);
		this.form.appendChild(el('div', { 'class': 'r3cg-fields' }, [
			field('网站名称（可选）', 'r3cg-label', this.labelInput, null, true),
			field('网站域名或 URL', 'r3cg-domains', this.domainsInput,
				el('p', { 'class': 'r3cg-hint', 'id': 'r3cg-domain-hint' }, '一行一个；URL 会提取域名。不要与其他规则填写相同或上下级域名。'), true),
			field('源配置', 'r3cg-source', this.sourceSelect, this.sourceHint),
			field('指定节点', 'r3cg-node', this.nodeSelect, this.nodeHint),
			el('div', { 'class': 'r3cg-benchmark' }, [
				el('div', { 'class': 'r3cg-actions' }, [this.benchmarkBtn, this.bestBtn]),
				this.benchmarkProgress, this.benchmarkBar,
				el('p', { 'class': 'r3cg-hint' }, '仅可选择实测地区支持 ChatGPT、3 轮全部通过的节点。测速完成后可选择最低延迟，也可手选其他通过节点。'),
				el('details', {}, [el('summary', {}, '查看各节点的 3 轮结果'), this.benchmarkRows])
			])
		]));
		this.saveBtn = this.button('保存并启用', 'apply', function() { self.mutate('save'); });
		this.cancelBtn = this.button('取消', 'neutral', function() { self.closeForm(); });
		this.form.appendChild(el('div', { 'class': 'r3cg-actions' }, [this.saveBtn, this.cancelBtn]));
		this.root.appendChild(this.form);
	},

	openForm: function(rule, preset) {
		if (this.mutating) return;
		this.formOpen = true;
		this.editId = rule ? rule.id : '';
		this.label = rule ? rule.label || '' : preset ? 'ChatGPT' : '';
		this.domainsText = rule ? rule.domains.join('\n') : preset ? CHATGPT_DOMAINS.join('\n') : '';
		this.preset = rule ? rule.preset || '' : preset ? 'chatgpt' : '';
		this.source = rule ? rule.source : this.sources.indexOf(DEFAULT_SOURCE) >= 0 ? DEFAULT_SOURCE :
			this.status && this.sources.indexOf(this.status.source) >= 0 ? this.status.source : this.sources[0] || '';
		this.selected = rule ? rule.selected || '' : '';
		this.nodes = [];
		this.nodesSource = '';
		this.benchmark = null;
		this.benchmarkNotice = '';
		this.dirty = false;
		this.notice = '';
		this.formTitle.textContent = rule ? '编辑网站' : preset ? '添加 ChatGPT 预设' : '添加网站';
		this.labelInput.value = this.label;
		this.domainsInput.value = this.domainsText;
		this.form.hidden = false;
		this.renderSources();
		this.renderNodes();
		this.refreshStatus(true);
		this.labelInput.focus();
	},

	closeForm: function() {
		if (this.mutating) return;
		++this.readSerial;
		this.reading = false;
		this.formOpen = false;
		this.form.hidden = true;
		this.editId = '';
		this.source = '';
		this.selected = '';
		this.dirty = false;
		this.sync();
	},

	acceptStatus: function(st, requestedSource) {
		this.status = st;
		this.statusError = '';
		this.sources = (Array.isArray(st.sources) ? st.sources : []).filter(isSource);
		this.rules = rulesOf(st.site_rules);
		var nodeSource = requestedSource || st.source;
		if (this.formOpen && nodeSource === this.source) {
			this.nodes = nodesOf(st.nodes);
			this.nodesSource = nodeSource;
			this.benchmark = st.benchmark && st.benchmark.source === this.source ? st.benchmark : null;
		}
		this.renderRules();
		this.renderSources();
		this.renderNodes();
	},

	renderRules: function() {
		var self = this;
		clear(this.list);
		this.ruleButtons = [];
		if (!this.rules.length) {
			this.list.appendChild(el('p', { 'class': 'r3cg-empty' }, this.statusError ?
				'规则暂时无法读取，请刷新重试。' : '还没有网站规则。可添加自定义网站，或使用 ChatGPT 预设。'));
			return;
		}
		this.rules.forEach(function(rule) {
			var state = self.statusError ? { text: '状态待确认', cls: 'bad' } : ruleState(rule, self.status && self.status.pending_restart), name = titleOf(rule);
			var badge = el('span', { 'class': 'r3cg-state ' + state.cls },
				[el('span', { 'class': 'r3cg-dot', 'aria-hidden': 'true' }), state.text]);
			var edit = self.button('编辑', 'neutral', function() { self.openForm(rule, false); });
			var toggle = self.button(rule.enabled ? '停用' : '启用', 'neutral', function() {
				self.mutate('set-enabled', rule.id, !rule.enabled);
			});
			var remove = self.button('删除', 'remove', function() { self.mutate('remove', rule.id); });
			[edit, toggle, remove].forEach(function(b) {
				b.setAttribute('aria-label', b.textContent + '：' + name);
				self.ruleButtons.push(b);
			});
			function detail(label, text) { return el('div', {}, [el('dt', {}, label), el('dd', {}, text)]); }
			var card = el('article', { 'class': 'r3cg-rule' }, [
				el('div', { 'class': 'r3cg-rule-head' }, [el('h3', {}, name), badge]),
				el('dl', { 'class': 'r3cg-data' }, [
					detail('网站域名', rule.domains.join('、')),
					detail('源配置', rule.source || '未指定'),
					detail('指定节点', rule.selected_name || '节点名称不可用')
				]),
				rule.error ? el('p', { 'class': 'r3cg-hint' }, statusErrorText(rule)) : null,
				el('div', { 'class': 'r3cg-actions' }, [edit, toggle, remove])
			]);
			self.list.appendChild(card);
		});
	},

	renderSources: function() {
		var self = this;
		clear(this.sourceSelect).appendChild(el('option', { 'value': '' }, this.sources.length ? '请选择源配置' : '没有可用的源配置'));
		this.sources.forEach(function(s) { self.sourceSelect.appendChild(el('option', { 'value': s }, s)); });
		if (this.source && this.sources.indexOf(this.source) < 0)
			this.sourceSelect.appendChild(el('option', { 'value': this.source, 'disabled': true }, this.source + '（已不可用）'));
		this.sourceSelect.value = this.source;
	},

	renderNodes: function() {
		var self = this;
		clear(this.nodeSelect).appendChild(el('option', { 'value': '' }, this.nodes.length ? '请手动选择节点' : '没有可用节点'));
		var sorted = this.nodes.slice().sort(function(a, b) {
			return Number(eligible(b)) - Number(eligible(a)) || (eligible(a) ? a.median_ms - b.median_ms : 0);
		});
		clear(this.benchmarkRows);
		sorted.forEach(function(n) {
			var allowed = eligible(n), reason = self.nodeReason(n), name = countryName(n.country) + ' · ' + n.name + ' · ' + latency(n.median_ms);
			self.nodeSelect.appendChild(el('option', { 'value': n.id, 'disabled': !allowed }, name + (allowed ? '' : '（' + reason + '）')));
			self.benchmarkRows.appendChild(el('li', {}, [el('strong', {}, countryName(n.country) + ' · ' + n.name),
				el('p', {}, '3 轮：' + (Array.isArray(n.samples_ms) && n.samples_ms.length ? n.samples_ms.map(latency).join(' / ') : '尚未完成') +
					'；中位延迟：' + latency(n.median_ms) + '；' + (allowed ? '已通过，可选用' : reason))]));
		});
		if (this.selected && !this.selectedNode())
			this.nodeSelect.appendChild(el('option', { 'value': this.selected, 'disabled': true }, '原选择已不可用，请重新选择'));
		this.nodeSelect.value = this.selected;
	},

	selectedNode: function() {
		var selected = this.selected;
		return this.nodes.filter(function(n) { return n.id === selected; })[0] || null;
	},

	hasSelected: function() {
		return eligible(this.selectedNode());
	},

	nodeReason: function(node) {
		var results = this.benchmark && Array.isArray(this.benchmark.results) ? this.benchmark.results : [];
		var result = results.filter(function(r) { return r.id === node.id; })[0];
		var err = node.error || result && result.error;
		if (err === 'PENDING' || err === 'BENCH_PENDING') return this.benchmark && this.benchmark.running ? '等待测速' : '尚未测速';
		if (err) return benchmarkError(err);
		if (measured(node) && node.eligible !== true) return '验证已失效，请重新测速';
		if (Array.isArray(node.samples_ms) && node.samples_ms.length) return '3 轮尚未全部通过';
		return this.benchmark && this.benchmark.running && !result ? '等待测速' : '尚未测速';
	},

	bestNode: function() {
		var bench = this.benchmark;
		if (!bench || bench.source !== this.source || bench.running || !(bench.total > 0) || bench.done < bench.total) return null;
		var best = this.nodes.filter(function(n) { return n.id === bench.best && eligible(n); })[0];
		var result = (Array.isArray(bench.results) ? bench.results : []).filter(function(r) { return r.id === bench.best && eligible(r); })[0];
		return best && result && !this.nodes.some(function(n) { return eligible(n) && n.median_ms < best.median_ms; }) ? best : null;
	},

	selectBest: function() {
		if (this.bestBtn.disabled) return;
		var best = this.bestNode();
		if (!best) return;
		this.selected = best.id;
		this.dirty = true;
		this.renderNodes();
		this.sync();
	},

	startBenchmark: function() {
		if (this.benchmarkBtn.disabled) return Promise.resolve(false);
		var self = this, source = this.source;
		this.benchmarkStarting[source] = true;
		this.benchmarkNotice = '';
		this.sync();
		return fs.exec(CLI, ['benchmark', source]).then(parseResult).then(function() {
			if (self.formOpen && self.source === source) return self.refreshStatus(false);
		}).catch(function(e) {
			if (self.formOpen && self.source === source) self.benchmarkNotice = /permission|access denied|拒绝/i.test(e && e.message || '') ?
				'当前会话没有测速权限，请退出 LuCI 后重新登录。' : '测速启动失败，请刷新后重试。';
		}).then(function() {
			delete self.benchmarkStarting[source];
			self.sync();
		});
	},

	domains: function() {
		return this.domainsText.split(/\r?\n/).map(function(s) { return s.trim(); }).filter(function(s) { return !!s; });
	},

	sync: function() {
		var st = this.status, unavailable = !st || !!this.statusError;
		var bad = unavailable || !!st.error || st.enabled === true && st.applied !== true && !st.pending_restart;
		var state = bad ? { text: '异常', cls: 'bad' } : st.pending_restart ? { text: '待启动生效', cls: 'warn' } :
			st.enabled ? { text: '已启用', cls: 'ok' } : { text: '已停用', cls: '' };
		clear(this.badge).appendChild(el('span', { 'class': 'r3cg-dot', 'aria-hidden': 'true' }));
		this.badge.appendChild(document.createTextNode(state.text));
		this.badge.className = 'r3cg-state ' + state.cls;
		var loading = this.reading && this.foreground;
		this.addBtn.disabled = this.presetBtn.disabled = this.mutating || unavailable;
		this.disableBtn.disabled = this.mutating || !st || (!st.enabled && !st.applied && !st.error && !this.rules.some(function(r) { return r.enabled; }));
		this.refreshBtn.disabled = this.mutating || this.reading;
		this.refreshBtn.textContent = loading ? '刷新中…' : '刷新';
		this.labelInput.disabled = this.domainsInput.disabled = this.mutating;
		this.sourceSelect.disabled = this.mutating || !this.sources.length;
		this.nodeSelect.disabled = this.mutating || loading || unavailable || !this.nodes.length || this.nodesSource !== this.source;
		this.saveBtn.disabled = this.mutating || loading || unavailable || !this.formOpen || !this.domains().length ||
			this.sources.indexOf(this.source) < 0 || this.nodesSource !== this.source || !this.hasSelected();
		this.cancelBtn.disabled = this.mutating;
		var bench = this.benchmark, running = bench && bench.running, starting = this.benchmarkStarting[this.source];
		this.benchmarkBtn.disabled = this.mutating || unavailable || loading || !this.formOpen || !this.nodes.length ||
			this.sources.indexOf(this.source) < 0 || this.nodesSource !== this.source || running || starting;
		this.benchmarkBtn.textContent = starting ? '正在启动…' : running ? '测速进行中…' : '3 轮测速';
		this.bestBtn.disabled = this.mutating || unavailable || loading || !this.bestNode();
		var total = bench && Number(bench.total) || 0, done = bench && Number(bench.done) || 0;
		this.benchmarkBar.setAttribute('max', Math.max(1, total));
		this.benchmarkBar.setAttribute('value', Math.min(Math.max(0, done), total));
		this.benchmarkProgress.textContent = this.benchmarkNotice || (unavailable ? '测速状态读取失败，请刷新。' : starting ? '正在启动 3 轮测速…' :
			bench && bench.error ? benchmarkError(bench.error) : running ? '正在测速：已完成 ' + done + ' / ' + total + ' 个节点。' :
			total > 0 ? '测速完成：' + done + ' / ' + total + ' 个节点。' : '尚未测速，请先完成 3 轮测速。');
		this.ruleButtons.forEach(function(b) { b.disabled = this.mutating || unavailable; }, this);
		this.saveBtn.textContent = this.mutating === 'save' ? '正在保存…' : '保存并启用';
		this.disableBtn.textContent = this.mutating === 'disable' ? '正在恢复…' : '恢复原分流';
		this.root.setAttribute('aria-busy', this.mutating || loading ? 'true' : 'false');
		this.sourceHint.textContent = st && st.source_error ? '此源配置暂时不可用，可切换配置或稍后刷新。' : '默认使用 lian_li.yaml。';
		this.nodeHint.textContent = loading ? '正在读取节点…' : !this.source ? '先选择源配置。' : unavailable ?
			'读取失败后可点击刷新重试。' : !this.nodes.length ? '此配置没有可用节点，请选择其他源配置。' :
			this.selected && !this.selectedNode() ? '原选择已不在此配置中，请重新选择。' : this.selected && !this.hasSelected() ?
			'所选节点尚未通过地区与 3 轮测速，请重新测速或选择其他已通过节点。' : this.hasSelected() ?
			countryName(this.selectedNode().country) + '；3 轮：' + this.selectedNode().samples_ms.map(latency).join(' / ') +
			'；中位延迟：' + latency(this.selectedNode().median_ms) + (this.dirty ? '；编辑尚未保存。' : '') : '请手动选择已通过的节点。';
		var err = this.statusError || statusErrorText(st);
		var pending = st && st.pending_restart ? '已保存，等待 OpenClash 启动后生效。' : '';
		this.message.textContent = this.notice || err || pending;
		this.message.className = 'r3cg-message' + (this.notice ? ' ' + this.noticeTone : err ? ' bad' : pending ? ' warn' : '');
		this.message.setAttribute('role', this.noticeTone === 'bad' || (!this.notice && err) ? 'alert' : 'status');
	},

	refreshStatus: function(manual, duringMutation) {
		if ((this.mutating && !duringMutation) || (!manual && this.reading)) return Promise.resolve(false);
		var self = this, serial = ++this.readSerial, source = this.formOpen ? this.source : '';
		this.reading = true;
		this.foreground = !!manual;
		if (manual && !duringMutation) this.notice = '';
		this.sync();
		return fs.exec(CLI, source ? ['status', source] : ['status']).then(parseResult).then(function(st) {
			if (serial !== self.readSerial) return false;
			self.acceptStatus(st, source);
			return true;
		}).catch(function(e) {
			if (serial === self.readSerial) { self.statusError = errorText(e); self.renderRules(); }
			return false;
		}).then(function(ok) {
			if (serial === self.readSerial) { self.reading = false; self.sync(); }
			return ok;
		});
	},

	mutate: function(action, id, enabled) {
		if (this.mutating || ['save', 'set-enabled', 'remove', 'disable'].indexOf(action) < 0 ||
			action === 'save' && this.saveBtn.disabled || action === 'disable' && this.disableBtn.disabled ||
			(action === 'set-enabled' || action === 'remove') && !this.rules.some(function(r) { return r.id === id; }))
			return Promise.resolve(false);
		var self = this, payload, args, before = this.rules.map(function(r) { return r.id; });
		if (action === 'save') {
			payload = { label: this.label.trim(), domains: this.domains(), source: this.source, selected: this.selected, enabled: true };
			if (this.editId) payload.id = this.editId;
			if (this.preset) payload.preset = this.preset;
			args = ['save', JSON.stringify(payload)];
		} else if (action === 'set-enabled') args = ['set-enabled', id, enabled ? '1' : '0'];
		else if (action === 'remove') args = ['remove', id];
		else args = ['disable'];
		this.mutating = action;
		++this.readSerial;
		this.reading = false;
		this.notice = '';
		this.noticeTone = '';
		this.sync();
		return fs.exec(CLI, args).then(parseResult).then(function(result) {
			return self.refreshStatus(true, true).then(function(ok) {
				var st = self.status, target;
				if (!ok) {
					self.notice = result.pending_restart ? '已保存，等待 OpenClash 启动后生效；当前状态读取失败，请稍后刷新确认。' :
						'操作已提交，当前状态读取失败。请点击刷新确认。';
					self.noticeTone = 'warn';
					return;
				}
				if (action === 'save') {
					var savedId = payload.id || result.id || result.rule && result.rule.id;
					target = self.rules.filter(function(r) {
						return savedId ? r.id === savedId : before.indexOf(r.id) < 0 &&
							r.source === payload.source && r.selected === payload.selected && r.enabled === true;
					});
					target = target.length === 1 ? target[0] : null;
				} else target = self.rules.filter(function(r) { return r.id === id; })[0];
				var pending = result.pending_restart || st.pending_restart;
				var verified = action === 'save' ? target && target.source === payload.source && target.selected === payload.selected && target.enabled === true &&
					(pending || target.applied === true && !target.error) :
					action === 'remove' ? !target : action === 'set-enabled' ? target && target.enabled === enabled &&
						(pending || (enabled ? target.applied === true && !target.error : target.applied !== true)) :
						!self.rules.some(function(r) { return r.enabled; }) && st.enabled === false && (pending || st.applied !== true && !st.error);
				if (!verified) {
					self.notice = statusErrorText(st) || '操作已提交，尚未确认生效。请刷新状态。';
					self.noticeTone = 'bad';
					return;
				}
				self.notice = pending ? '已保存，等待 OpenClash 启动后生效。' : action === 'save' ? '网站规则已保存并启用。' :
					action === 'remove' ? '网站规则已删除。' : action === 'set-enabled' ? (enabled ? '网站规则已启用。' : '网站规则已停用。') :
						'已恢复原分流，全部网站规则已停用。';
				self.noticeTone = pending ? 'warn' : 'ok';
				if (action === 'save' || action === 'remove' && id === self.editId) {
					self.formOpen = false;
					self.form.hidden = true;
					self.editId = '';
					self.source = '';
					self.selected = '';
					self.dirty = false;
				}
			});
		}).catch(function(e) {
			self.notice = errorText(e);
			self.noticeTone = 'bad';
		}).then(function() {
			self.mutating = false;
			self.sync();
		});
	}
});
