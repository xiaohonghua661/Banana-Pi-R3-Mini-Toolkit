'use strict';

// 实际执行 LuCI view 的离线状态机测试，不连接设备、不依赖第三方包。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ROOT = __dirname;
const VIEW = path.join(ROOT, 'router/www/luci-static/resources/view/services/r3mini-chatgpt.js');
const SOURCE = fs.readFileSync(VIEW, 'utf8');
const NOW = Date.parse('2026-11-24T10:00:00Z');
const iso = secondsAgo => new Date(NOW - secondsAgo * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

class Element {
	constructor(tag, text) {
		this.tagName = tag; this.nodeType = tag === '#text' ? 3 : 1;
		this.children = []; this.attributes = {}; this.events = {};
		this._disabled = false; this.hidden = false; this.className = ''; this._value = ''; this.text = text || ''; this.scrollTop = 0;
	}
	get firstChild() { return this.children[0] || null; }
	get disabled() { return this._disabled; }
	set disabled(value) { this._disabled = Boolean(value); }
	appendChild(node) { this.children.push(node); return node; }
	removeChild(node) { this.children.splice(this.children.indexOf(node), 1); return node; }
	setAttribute(key, value) {
		this.attributes[key] = String(value);
		if (key === 'value') this._value = String(value);
		if (key === 'disabled') this.disabled = true;
		if (key === 'hidden') this.hidden = true;
	}
	getAttribute(key) { return Object.prototype.hasOwnProperty.call(this.attributes, key) ? this.attributes[key] : null; }
	addEventListener(key, fn) { this.events[key] = fn; }
	get value() {
		if (this.tagName === 'select') return this.children.some(c => c.value === this._value) ? this._value : '';
		return this._value;
	}
	set value(value) { this._value = String(value); }
	get textContent() { return this.text + this.children.map(c => c.textContent).join(''); }
	set textContent(value) { this.children = []; this.text = String(value); }
	set innerHTML(value) { throw new Error('禁止将外部文本插入 innerHTML'); }
	// Like the DOM: a disabled control ignores clicks.
	click() { return !this.disabled && this.events.click ? this.events.click({ target: this, preventDefault() {} }) : undefined; }
	change(value) { this.value = value; return this.events.change({ target: this }); }
	input(value) { this.value = value; return this.events.input({ target: this }); }
	focus() { this.focused = true; }
	all(match, out = []) {
		for (const c of this.children) {
			if (c.nodeType === 1 && match(c)) out.push(c);
			c.all(match, out);
		}
		return out;
	}
}
const document = { hidden: false, createElement: tag => new Element(tag), createTextNode: text => new Element('#text', String(text)) };

function node(id, name, extra) {
	return Object.assign({ id, name, type: 'ss', dependent: false, eligible: false, median_ms: null, samples_ms: [], country: null,
		error: null, tested_at: null, stale: false }, extra);
}
const N1 = node('1111111111111111', '🇯🇵 日本 01', { eligible: true, country: 'JP', samples_ms: [90, 80, 100], median_ms: 90, tested_at: iso(7200) });
const N2 = node('2222222222222222', '<img src=x onerror=alert(1)>', { type: 'trojan', eligible: true, country: 'US', samples_ms: [50, 60, 70], median_ms: 60, tested_at: iso(600) });
const N3 = node('3333333333333333', '🇹🇼 台湾 03', { type: 'vmess', error: 'PENDING' });
const N4 = node('4444444444444444', '🇭🇰 香港 04', { error: 'TLS_FAILED', tested_at: iso(3600) });
const N5 = node('5555555555555555', '🇺🇸 美国 链式', { dependent: true, error: 'PENDING' });
const ALL = [N1, N2, N3, N4, N5];
const STEAM_ON = { enabled: true, applied: true }, STEAM_OFF = { enabled: false, applied: false };

function rule(o = {}) {
	return Object.assign({ id: 'aaaaaaaaaaaa', label: '演示网站', domains: ['example.com'], preset: '', source: 'lian_li.yaml',
		selected: N1.id, selected_name: N1.name, enabled: true, applied: true, error: null, verified: true, unverified: false,
		target: 'site:example.com', median_ms: 90, country: null, tested_at: iso(7200) }, o);
}
function summary(o = {}) {
	return Object.assign({ ok: true, enabled: false, applied: false, error: null, pending_restart: false, source: 'lian_li.yaml',
		sources: ['lian_li.yaml', 'other.yaml'], rules: [], last_action: null, last_time: null }, o);
}
// Change commands answer with every summary field plus these.
function changed(o = {}, extra = {}) {
	const s = summary(o);
	return Object.assign(s, { site_rules: s.rules, reloaded: true, elapsed_ms: 2100 }, extra);
}
function nodesReply(nodes = ALL, bench = {}, extra = {}) {
	return Object.assign({ ok: true, source: 'lian_li.yaml', target: 'site:example.com', nodes,
		benchmark: Object.assign({ ok: true, running: false, done: 0, total: 0, run_ids: [], started_at: null, finished_at: iso(7300), error: null }, bench) }, extra);
}
function reply(data, code = 0) { return { code, stdout: JSON.stringify(data), stderr: '' }; }
function deferred() {
	let resolve, reject;
	const promise = new Promise((a, b) => { resolve = a; reject = b; });
	return { promise, resolve, reject };
}
const tick = () => new Promise(setImmediate);

function harness(initial = summary()) {
	const calls = [], queued = [], polls = [], timers = [];
	const rpc = { exec: (cli, args) => {
		assert.equal(cli, '/usr/sbin/r3mini-chatgpt');
		calls.push(args);
		assert.ok(queued.length, '出现未安排的接口调用：' + args.join(' '));
		return Promise.resolve(queued.shift());
	} };
	const ui = { modal: null, showModal(title, children, cls) { this.modal = { title, children, cls }; return new Element('div'); },
		hideModal() { this.modal = null; } };
	const def = new Function('view', 'fs', 'poll', 'ui', 'document', SOURCE)({ extend: x => x }, rpc,
		{ add: (fn, interval) => polls.push({ fn, interval }) }, ui, document);
	const view = Object.assign({}, def), clock = { now: NOW };
	view.now = () => clock.now;
	view.later = (fn, ms) => { timers.push({ fn, ms, live: true }); return timers.length; };
	view.cancel = id => { if (timers[id - 1]) timers[id - 1].live = false; };
	view.render(initial ? { status: initial } : { error: '状态读取失败' });
	return { view, calls, polls, timers, ui, clock, queue: result => queued.push(result),
		live: () => timers.filter(t => t.live),
		async runTimers() {
			const due = timers.filter(t => t.live);
			due.forEach(t => { t.live = false; });
			for (const t of due) await t.fn();
			await tick();
		} };
}
const rowsOf = h => h.view.dlg.el.list.all(e => e.tagName === 'button');
const rowIds = h => rowsOf(h).map(b => b.getAttribute('data-id'));
const row = (h, n) => rowsOf(h).find(b => b.getAttribute('data-id') === n.id);
const part = (el, cls) => el.all(e => e.className === cls)[0];
const modalButtons = h => h.ui.modal.children[1].children.filter(c => c.tagName === 'button');
async function openRule(h, existing, nodeOnly = true, nodes = nodesReply()) {
	h.queue(reply(nodes));
	assert.equal(h.view.openEditor(existing, false, nodeOnly), true);
	await tick();
}
async function openNew(h, domains, nodes = nodesReply()) {
	assert.equal(h.view.openEditor(null, false, false), true);
	h.view.dlg.el.domains.input(domains);
	h.queue(reply(nodes));
	await h.runTimers();
}
const enabledWith = (...rules) => summary({ rules, enabled: true, applied: true });

async function run() {
	let passed = 0;
	async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }

	await test('空规则列表、中文标题与30秒空闲刷新', () => {
		const h = harness();
		assert.match(h.view.root.textContent, /网站分流/);
		assert.match(h.view.list.textContent, /还没有网站规则/);
		assert.equal(h.ui.modal, null);
		assert.equal(h.view.disableBtn.disabled, true);
		assert.equal(h.polls[0].interval, 30);
		assert.match(h.view.badge.textContent, /未启用/);
		assert.equal(h.view.presetBtn.hidden, false);
	});

	await test('空闲刷新只读summary：刚读过、标签页在后台、弹窗打开时都不读', async () => {
		const h = harness();
		await h.polls[0].fn();
		assert.equal(h.calls.length, 0, '刚读过不再读');
		h.clock.now += 31000;
		h.queue(reply(enabledWith(rule())));
		await h.polls[0].fn();
		assert.deepEqual(h.calls[0], ['summary']);
		assert.match(h.view.list.textContent, /演示网站/);
		h.clock.now += 31000;
		document.hidden = true;
		await h.polls[0].fn();
		document.hidden = false;
		assert.equal(h.calls.length, 1);
		await openRule(h, h.view.rules[0]);
		h.clock.now += 31000;
		await h.polls[0].fn();
		assert.deepEqual(h.calls.slice(1), [['nodes', 'lian_li.yaml', 'site:example.com']], '弹窗打开时不轮询');
	});

	await test('手动刷新与空闲刷新不重叠', async () => {
		const h = harness(), pending = deferred();
		h.queue(pending.promise);
		const result = h.view.refreshBtn.click();
		assert.equal(h.view.refreshBtn.textContent, '刷新中…');
		h.clock.now += 31000;
		await h.polls[0].fn();
		assert.equal(h.calls.length, 1);
		pending.resolve(reply(summary()));
		assert.equal(await result, true);
		assert.equal(h.view.refreshBtn.textContent, '刷新');
	});

	await test('首次读取失败显示异常且不能添加，刷新成功后恢复', async () => {
		const h = harness(null);
		assert.match(h.view.badge.textContent, /异常/);
		assert.equal(h.view.addBtn.disabled, true);
		assert.equal(h.view.openEditor(null, false, false), false);
		h.queue(reply(summary()));
		await h.view.refresh(true);
		assert.equal(h.view.addBtn.disabled, false);
		assert.match(h.view.badge.textContent, /未启用/);
	});

	await test('网站名、域名和节点名称仅按文本插入', async () => {
		const r = rule({ label: '<svg/onload=alert(1)>', selected: N2.id, selected_name: N2.name });
		const h = harness(enabledWith(r));
		assert.match(h.view.list.textContent, /<svg\/onload=alert\(1\)>/);
		assert.match(h.view.list.textContent, /<img src=x onerror=alert\(1\)> · 90 ms · 2 小时前测/);
		await openRule(h, r);
		const name = part(row(h, N2), 'r3cg-name');
		assert.equal(name.textContent, N2.name);
		assert.equal(name.children[0].nodeType, 3);
	});

	await test('添加网站：先填域名，测速目标跟随第一个域名', async () => {
		const h = harness();
		assert.equal(h.view.addBtn.click(), true);
		assert.equal(h.ui.modal.title, '添加网站');
		assert.equal(h.view.dlg.el.domains.focused, true);
		assert.equal(h.calls.length, 0, '没有域名时不读节点');
		assert.match(h.view.dlg.el.list.textContent, /先在上面填网站域名/);
		h.view.dlg.el.domains.input('https://Example.COM/a\nexample.org');
		assert.match(h.view.dlg.el.preview.textContent, /将匹配：example\.com、example\.org，含子域名/);
		assert.equal(h.live()[0].ms, 600, '停止输入后再读');
		h.queue(reply(nodesReply()));
		await h.runTimers();
		assert.deepEqual(h.calls[0], ['nodes', 'lian_li.yaml', 'site:example.com']);
		assert.equal(h.view.dlg.source, 'lian_li.yaml');
		assert.equal(h.view.dlg.selected, '');
		assert.equal(h.view.dlg.el.save.disabled, true);
		assert.match(h.view.dlg.el.benchLine.textContent, /经节点访问 example\.com 三次/);
		row(h, N1).click();
		assert.equal(h.view.dlg.el.save.disabled, false);
		assert.equal(h.view.dlg.el.picked.textContent, '已选：日本 01 · 90 ms · 2 小时前测');
		assert.equal(row(h, N1).attributes['aria-checked'], 'true');
	});

	await test('ChatGPT预设按chatgpt测速，已有预设时隐藏按钮', async () => {
		const h = harness();
		h.queue(reply(nodesReply(ALL, {}, { target: 'chatgpt' })));
		h.view.presetBtn.click();
		await tick();
		assert.deepEqual(h.calls[0], ['nodes', 'lian_li.yaml', 'chatgpt']);
		assert.equal(h.ui.modal.title, '添加 ChatGPT 预设');
		assert.equal(h.view.dlg.label, 'ChatGPT');
		assert.equal(h.view.dlg.preset, 'chatgpt');
		assert.deepEqual(h.view.domainLines(h.view.dlg.domainsText),
			['chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com', 'chatgpt.livekit.cloud']);
		assert.equal(h.view.dlg.selected, '');
		assert.equal(h.view.dlg.el.save.disabled, true);
		assert.match(h.view.dlg.el.benchLine.textContent, /核对 ChatGPT 是否支持/);
		assert.match(part(row(h, N2), 'r3cg-result').textContent, /60 ms · 出口美国 · 10 分钟前/);
		assert.equal(harness(enabledWith(rule({ preset: 'chatgpt', domains: ['chatgpt.com'] }))).view.presetBtn.hidden, true);
	});

	await test('编辑保留原id、域名、源、节点和预设标记', async () => {
		const r = rule({ preset: 'chatgpt', domains: ['chatgpt.com', 'example.net'] }), h = harness(enabledWith(r));
		await openRule(h, r, false, nodesReply(ALL, {}, { target: 'chatgpt' }));
		assert.deepEqual(h.calls[0], ['nodes', 'lian_li.yaml', 'chatgpt']);
		assert.equal(h.ui.modal.title, '编辑网站');
		assert.equal(h.view.dlg.el.domains.value, 'chatgpt.com\nexample.net');
		assert.equal(h.view.dlg.el.label.value, '演示网站');
		assert.equal(h.view.dlg.selected, N1.id);
		assert.equal(h.view.dlg.el.save.disabled, false);
		h.queue(reply(changed({ rules: [r], enabled: true, applied: true }, { id: r.id })));
		assert.equal(await h.view.dlg.el.save.click(), true);
		assert.deepEqual(JSON.parse(h.calls[1][1]), { label: '演示网站', domains: ['chatgpt.com', 'example.net'], source: 'lian_li.yaml',
			selected: N1.id, enabled: true, id: r.id, preset: 'chatgpt' });
		assert.equal(h.calls[1][0], 'save');
	});

	await test('换节点一步完成：只改节点，用返回状态确认，不再多读一次', async () => {
		const r = rule(), h = harness(enabledWith(r));
		h.queue(reply(nodesReply()));
		h.view.ruleButtons[0].click();
		await tick();
		assert.equal(h.ui.modal.title, '换节点');
		assert.match(h.ui.modal.children[0].textContent, /^演示网站 · example\.com/);
		assert.equal(h.view.dlg.el.search.focused, true);
		row(h, N2).click();
		h.queue(reply(changed({ rules: [rule({ selected: N2.id, selected_name: N2.name, median_ms: 60 })], enabled: true, applied: true }, { id: r.id })));
		assert.equal(await h.view.dlg.el.save.click(), true);
		assert.equal(h.calls.length, 2);
		assert.deepEqual(JSON.parse(h.calls[1][1]), { label: '演示网站', domains: ['example.com'], source: 'lian_li.yaml', selected: N2.id, enabled: true, id: r.id });
		assert.equal(h.ui.modal, null);
		assert.equal(h.view.dlg, null);
		assert.match(h.view.message.textContent, /^网站规则已保存并生效。用时 \d+\.\d 秒。$/);
		assert.equal(h.view.noticeTone, 'ok');
		assert.match(h.view.list.textContent, /60 ms/);
	});

	await test('换节点保持停用规则的停用状态，未重载时说明', async () => {
		const r = rule({ enabled: false, applied: false }), h = harness(summary({ rules: [r] }));
		await openRule(h, r);
		assert.equal(h.view.dlg.el.save.textContent, '保存');
		h.view.selectNode(N2.id);
		h.queue(reply(changed({ rules: [rule({ enabled: false, applied: false, selected: N2.id })] }, { id: r.id, reloaded: false })));
		await h.view.saveDialog();
		assert.equal(JSON.parse(h.calls[1][1]).enabled, false);
		assert.match(h.view.message.textContent, /^网站规则已保存（未启用）。用时 .* 秒，运行配置无变化，未重载。$/);
	});

	await test('未测速或测速未通过的节点可保存，标为未验证', async () => {
		for (const pick of [N3, N4]) {
			const r = rule(), h = harness(enabledWith(r));
			await openRule(h, r);
			h.view.dlg.el.more.click();
			h.view.selectNode(pick.id);
			assert.match(h.view.dlg.el.picked.textContent, pick === N3 ? /未测速，保存后标为「未验证」/ : /测速未通过，仍可保存/);
			assert.equal(h.view.dlg.el.save.disabled, false);
			h.queue(reply(changed({ rules: [rule({ selected: pick.id, selected_name: pick.name, unverified: true, verified: false, median_ms: null })],
				enabled: true, applied: true }, { id: r.id })));
			await h.view.saveDialog();
			assert.equal(JSON.parse(h.calls[1][1]).unverified, true);
			assert.match(h.view.list.textContent, /未测速（未验证）/);
		}
	});

	await test('依赖其他代理的节点禁选且不能保存', async () => {
		const r = rule(), h = harness(enabledWith(r));
		await openRule(h, r);
		h.view.dlg.el.more.click();
		assert.equal(row(h, N5).disabled, true);
		assert.match(row(h, N5).textContent, /依赖其他代理/);
		h.view.selectNode(N5.id);
		assert.equal(h.view.canSave(), false);
		assert.equal(h.view.dlg.el.save.disabled, true);
	});

	await test('节点列表去掉国旗、按地区分组、通过的按延迟排前、未通过的折叠', async () => {
		const r = rule(), h = harness(enabledWith(r));
		await openRule(h, r);
		assert.deepEqual(rowIds(h), [N2.id, N1.id, N3.id]);
		assert.equal(part(row(h, N1), 'r3cg-name').textContent, '日本 01');
		assert.equal(part(row(h, N1), 'r3cg-region').textContent, '日本');
		assert.equal(part(row(h, N1), 'r3cg-result').textContent, '90 ms · 2 小时前');
		assert.equal(part(row(h, N3), 'r3cg-result').textContent, '未测速');
		assert.deepEqual(h.view.dlg.el.chips.children.map(c => c.textContent), ['全部 5', '日本 1', '台湾 1', '香港 1', '美国 1', '其他 1']);
		assert.equal(h.view.dlg.el.more.hidden, false);
		assert.equal(h.view.dlg.el.more.textContent, '显示 2 个未通过的节点');
		h.view.dlg.el.more.click();
		assert.deepEqual(rowIds(h), [N2.id, N1.id, N3.id, N4.id, N5.id]);
		assert.equal(part(row(h, N4), 'r3cg-result').textContent, '连接失败 · 1 小时前');
		assert.equal(h.view.dlg.el.more.textContent, '收起未通过的节点');
		h.view.dlg.el.more.click();
		h.view.dlg.el.search.input('香港');
		assert.deepEqual(rowIds(h), [N4.id], '只剩未通过的节点时直接列出');
	});

	await test('筛选后只测筛出来的节点，测速中每3秒刷新、测完即停', async () => {
		const r = rule(), h = harness(enabledWith(r));
		await openRule(h, r);
		const p = h.view.dlg.el;
		assert.equal(p.benchBtn.textContent, '全部测速（5 个）');
		assert.equal(p.benchAllBtn.hidden, true);
		p.chips.children.find(c => c.textContent === '台湾 1').click();
		assert.deepEqual(rowIds(h), [N3.id]);
		assert.equal(p.benchBtn.textContent, '测速这 1 个');
		assert.equal(p.benchAllBtn.hidden, false);
		h.queue(reply({ ok: true, running: true }));
		h.queue(reply(nodesReply(ALL, { running: true, done: 0, total: 1, run_ids: [N3.id] })));
		await p.benchBtn.click();
		assert.deepEqual(h.calls.slice(1), [['benchmark', 'lian_li.yaml', 'site:example.com', N3.id], ['nodes', 'lian_li.yaml', 'site:example.com']]);
		assert.equal(p.benchBtn.textContent, '测速进行中…');
		assert.equal(p.benchBtn.disabled, true);
		assert.equal(p.progress.hidden, false);
		assert.match(p.benchLine.textContent, /正在测速：0 \/ 1/);
		assert.equal(part(row(h, N3), 'r3cg-result').textContent, '等待测速…');
		assert.deepEqual(h.live().map(t => t.ms), [3000]);
		const done = Object.assign({}, N3, { eligible: true, error: null, samples_ms: [40, 45, 50], median_ms: 45, tested_at: iso(5) });
		h.queue(reply(nodesReply([N1, N2, done, N4, N5], { done: 1, total: 1, run_ids: [N3.id], finished_at: iso(5) })));
		await h.runTimers();
		assert.equal(h.calls.length, 4);
		assert.equal(h.live().length, 0, '测完不再轮询');
		assert.equal(part(row(h, N3), 'r3cg-result').textContent, '45 ms · 刚刚');
		assert.match(p.benchLine.textContent, /^上次测速：刚刚/);
		assert.equal(p.progress.hidden, true);
	});

	await test('全部测速不带节点参数', async () => {
		const r = rule(), h = harness(enabledWith(r));
		await openRule(h, r, true, nodesReply(Array.from({ length: 70 }, (_, i) => node(String(i).padStart(16, 'a'), '节点' + i))));
		assert.equal(h.view.dlg.el.benchBtn.textContent, '全部测速（70 个，约 3 分钟）');
		h.queue(reply({ ok: true, running: true }));
		h.queue(reply(nodesReply([], { running: false })));
		await h.view.dlg.el.benchBtn.click();
		assert.deepEqual(h.calls[1], ['benchmark', 'lian_li.yaml', 'site:example.com']);
	});

	await test('选最快在筛出来且已有结果的节点里挑，不发命令', async () => {
		const r = rule({ selected: N3.id }), h = harness(enabledWith(r));
		await openRule(h, r);
		h.view.dlg.el.fastBtn.click();
		assert.equal(h.view.dlg.selected, N2.id);
		h.view.dlg.el.search.input('日本');
		assert.deepEqual(rowIds(h), [N1.id]);
		h.view.dlg.el.fastBtn.click();
		assert.equal(h.view.dlg.selected, N1.id);
		h.view.dlg.el.search.input('台湾');
		assert.equal(h.view.dlg.el.fastBtn.disabled, true);
		assert.equal(h.calls.length, 1);
	});

	await test('切换订阅：旧响应不覆盖新选择，回到原订阅恢复原节点', async () => {
		const r = rule(), h = harness(enabledWith(r));
		await openRule(h, r);
		const first = deferred(), second = deferred();
		h.queue(first.promise);
		h.view.dlg.el.source.change('other.yaml');
		assert.equal(h.view.dlg.selected, '');
		assert.equal(h.view.dlg.el.save.disabled, true);
		h.queue(second.promise);
		h.view.dlg.el.source.change('lian_li.yaml');
		assert.equal(h.view.dlg.selected, N1.id);
		second.resolve(reply(nodesReply()));
		await tick();
		first.resolve(reply(nodesReply([node('6666666666666666', '另一订阅节点')], {}, { source: 'other.yaml' })));
		await tick();
		assert.equal(h.view.dlg.source, 'lian_li.yaml');
		assert.equal(h.view.dlg.nodes.length, 5);
		assert.equal(h.view.dlg.el.save.disabled, false);
		assert.deepEqual(h.calls.slice(1), [['nodes', 'other.yaml', 'site:example.com'], ['nodes', 'lian_li.yaml', 'site:example.com']]);
	});

	await test('订阅没有节点或读取失败时说明原因', async () => {
		const r = rule(), h = harness(enabledWith(r));
		await openRule(h, r, true, nodesReply([]));
		assert.match(h.view.dlg.el.list.textContent, /这个订阅里没有节点/);
		assert.equal(h.view.dlg.el.save.disabled, true);
		h.queue(reply({ ok: false, error: 'SOURCE_MISSING', message: '订阅文件不存在或不是受允许的普通文件。' }, 1));
		h.view.dlg.el.source.change('other.yaml');
		await tick();
		assert.match(h.view.dlg.el.list.textContent, /订阅文件不存在/);
	});

	await test('保存失败：中文错误留在弹窗里，填写内容保留', async () => {
		const h = harness();
		await openNew(h, 'example.com');
		h.view.dlg.el.label.input('我的网站');
		h.view.selectNode(N1.id);
		h.queue(reply({ ok: false, error: 'DOMAIN_CONFLICT', message: '此域名与另一条网站规则重叠，请修改原规则。' }, 1));
		assert.equal(await h.view.saveDialog(), false);
		assert.notEqual(h.ui.modal, null);
		assert.equal(h.view.dlg.el.message.textContent, '此域名与另一条网站规则重叠，请修改原规则。');
		assert.equal(h.view.dlg.el.message.attributes.role, 'alert');
		assert.equal(h.view.dlg.el.label.value, '我的网站');
		assert.equal(h.view.message.textContent, '');
		assert.equal(h.view.dlg.el.save.disabled, false);
	});

	await test('返回成功但状态不符时不虚报生效', async () => {
		const h = harness();
		await openNew(h, 'example.com');
		h.view.selectNode(N1.id);
		h.queue(reply(changed({ rules: [rule({ id: 'bbbbbbbbbbbb', applied: false })], enabled: true }, { id: 'bbbbbbbbbbbb' })));
		assert.equal(await h.view.saveDialog(), false);
		assert.equal(h.view.noticeTone, 'bad');
		assert.match(h.view.dlg.el.message.textContent, /尚未确认/);
		assert.notEqual(h.ui.modal, null);
	});

	await test('名称不填用第一个域名，名称过长不能保存', async () => {
		const h = harness();
		await openNew(h, 'https://Docs.Example.com/x\nexample.org');
		assert.equal(h.view.dlg.el.label.attributes.placeholder, '不填就叫 docs.example.com');
		h.view.selectNode(N1.id);
		h.view.dlg.el.label.input('很'.repeat(54));
		assert.equal(h.view.dlg.el.save.disabled, true);
		assert.match(h.view.dlg.el.labelHint.textContent, /名称太长/);
		h.view.dlg.el.label.input('  ');
		assert.equal(h.view.dlg.el.save.disabled, false);
		h.queue(reply(changed({ rules: [rule({ id: 'cccccccccccc', label: 'docs.example.com', domains: ['docs.example.com', 'example.org'] })],
			enabled: true, applied: true }, { id: 'cccccccccccc' })));
		assert.equal(await h.view.saveDialog(), true);
		const payload = JSON.parse(h.calls[1][1]);
		assert.equal(payload.label, 'docs.example.com');
		assert.deepEqual(payload.domains, ['https://Docs.Example.com/x', 'example.org']);
		assert.equal(payload.enabled, true);
		assert.equal(payload.id, undefined);
	});

	await test('域名实时检查：无效行、与已有规则重叠时不能保存', async () => {
		const h = harness(enabledWith(rule()));
		await openNew(h, 'shop.example.com');
		h.view.selectNode(N1.id);
		assert.match(h.view.dlg.el.preview.textContent, /shop\.example\.com 与规则「演示网站」的 example\.com 重叠/);
		assert.equal(h.view.dlg.el.preview.className, 'r3cg-hint bad');
		assert.equal(h.view.dlg.el.save.disabled, true);
		h.view.dlg.el.domains.input('example.net\nnot a domain\n\nhttp://');
		assert.match(h.view.dlg.el.preview.textContent, /第 2、4 行不是有效的域名或网址/);
		assert.equal(h.view.dlg.el.save.disabled, true);
		const preset = harness(enabledWith(rule({ preset: 'chatgpt', domains: ['chatgpt.com'] })));
		await openNew(preset, 'cdn.openai.com');
		assert.match(preset.view.dlg.el.preview.textContent, /cdn\.openai\.com 与规则「演示网站」的 openai\.com 重叠/);
	});

	await test('OpenClash离线：只显示待启动生效，不显示实时成功', async () => {
		const h = harness(enabledWith(rule()));
		h.view.disableBtn.click();
		h.queue(reply(changed({ rules: [rule({ enabled: false, applied: false })], pending_restart: true }, { reloaded: false })));
		await modalButtons(h)[1].click();
		assert.match(h.view.message.textContent, /等待 OpenClash 启动后生效/);
		assert.equal(h.view.noticeTone, 'warn');
		assert.match(h.view.badge.textContent, /待启动生效/);
		assert.doesNotMatch(h.view.message.className, /ok/);
	});

	await test('启停精确调用set-enabled，一次调用即核验', async () => {
		const r = rule(), h = harness(enabledWith(r));
		h.queue(reply(changed({ rules: [rule({ enabled: false, applied: false })] })));
		assert.equal(await h.view.ruleButtons[2].click(), true);
		assert.deepEqual(h.calls, [['set-enabled', r.id, '0']]);
		assert.match(h.view.message.textContent, /^网站规则已停用。用时/);
		assert.equal(h.view.ruleButtons[2].textContent, '启用');
		h.queue(reply(changed({ rules: [r], enabled: true, applied: true })));
		await h.view.ruleButtons[2].click();
		assert.deepEqual(h.calls[1], ['set-enabled', r.id, '1']);
		assert.match(h.view.message.textContent, /^网站规则已启用。/);
	});

	await test('删除先弹确认，确认后只传id', async () => {
		const r = rule(), h = harness(enabledWith(r));
		h.view.ruleButtons[3].click();
		assert.equal(h.ui.modal.title, '删除网站规则');
		assert.match(h.ui.modal.children[0].textContent, /^删除「演示网站」？删除后这些域名回到原来的分流/);
		modalButtons(h)[0].click();
		assert.equal(h.ui.modal, null);
		assert.equal(h.calls.length, 0);
		h.view.ruleButtons[3].click();
		h.queue(reply(changed()));
		assert.equal(await modalButtons(h)[1].click(), true);
		assert.deepEqual(h.calls, [['remove', r.id]]);
		assert.equal(h.view.rules.length, 0);
		assert.match(h.view.message.textContent, /^网站规则已删除。/);
	});

	await test('恢复原分流先确认，写明停用几条和关闭Steam', async () => {
		const other = rule({ id: 'bbbbbbbbbbbb', domains: ['example.org'], enabled: false, applied: false });
		const h = harness(summary({ rules: [rule(), other], enabled: true, applied: true, steam_direct: STEAM_ON }));
		h.view.disableBtn.click();
		assert.equal(h.ui.modal.title, '恢复原分流');
		assert.match(h.ui.modal.children[0].textContent, /将停用全部 1 条网站规则（规则保留，随时可以重新启用），并关闭 Steam 直连。/);
		assert.deepEqual(modalButtons(h).map(b => b.textContent), ['取消', '恢复原分流']);
		assert.equal(modalButtons(h)[0].focused, true);
		h.queue(reply(changed({ rules: [rule({ enabled: false, applied: false }), other], steam_direct: STEAM_OFF })));
		await modalButtons(h)[1].click();
		assert.deepEqual(h.calls, [['disable']]);
		assert.match(h.view.message.textContent, /全部网站规则已停用，Steam 直连已关闭/);
		assert.equal(h.view.rules.length, 2);
	});

	await test('保存期间禁用全部操作、防连点、轮询暂停、弹窗关不掉', async () => {
		const h = harness(summary({ rules: [rule()], enabled: true, applied: true, steam_direct: STEAM_OFF })), pending = deferred();
		await openRule(h, h.view.rules[0]);
		h.view.selectNode(N2.id);
		h.queue(pending.promise);
		const result = h.view.saveDialog();
		const p = h.view.dlg.el;
		for (const control of [h.view.addBtn, h.view.presetBtn, h.view.disableBtn, h.view.refreshBtn, h.view.steamSwitch, p.save, p.cancel,
			p.source, p.benchBtn, p.fastBtn].concat(h.view.ruleButtons, rowsOf(h)))
			assert.equal(control.disabled, true);
		assert.equal(p.save.textContent, '正在应用…');
		assert.match(h.view.badge.textContent, /正在应用/);
		assert.match(h.view.list.textContent, /正在应用…/);
		assert.equal(await h.view.saveDialog(), false);
		assert.equal(await h.view.mutate('disable'), false);
		h.clock.now += 60000;
		await h.polls[0].fn();
		p.cancel.click();
		assert.notEqual(h.ui.modal, null);
		assert.equal(h.calls.length, 2);
		pending.resolve(reply(changed({ rules: [rule({ selected: N2.id })], enabled: true, applied: true }, { id: 'aaaaaaaaaaaa' })));
		assert.equal(await result, true);
		assert.equal(h.ui.modal, null);
	});

	await test('Steam直连卡片在网站操作之前，开关是role=switch按钮且三种状态', async () => {
		const h = harness(summary({ steam_direct: STEAM_OFF })), kids = h.view.root.children;
		const cardAt = kids.indexOf(h.view.steamCard), actionsAt = kids.findIndex(c => c.children.includes(h.view.addBtn));
		assert.ok(kids.findIndex(c => c.className === 'r3cg-intro') < cardAt && cardAt < actionsAt);
		assert.match(h.view.steamCard.textContent, /^Steam 直连/);
		assert.ok(h.view.steamCard.textContent.includes('Steam 联机（Valve 服务器和中继 IP）、登录接口、下载走直连，不经过代理节点；商店和社区网页不变。'));
		assert.equal(h.view.steamSwitch.tagName, 'button');
		assert.equal(h.view.steamSwitch.attributes.role, 'switch');
		assert.equal(h.view.steamSwitch.attributes['aria-describedby'], 'r3cg-steam-state r3cg-steam-hint');
		assert.equal(h.view.steamSwitch.disabled, false);
		for (const [steam, text, checked, cls] of [[STEAM_OFF, '未生效', 'false', ''], [STEAM_ON, '已生效', 'true', 'ok'],
			[{ enabled: true, applied: false }, '开启了但配置里没找到——重新打开一次', 'false', 'bad'], [STEAM_OFF, '未生效', 'false', '']]) {
			h.queue(reply(summary({ steam_direct: steam })));
			await h.view.refresh(true);
			assert.equal(h.view.steamState.textContent, text);
			assert.equal(h.view.steamSwitch.attributes['aria-checked'], checked);
			assert.equal(h.view.steamSwitch.className, checked === 'true' ? 'r3cg-switch on' : 'r3cg-switch');
			assert.equal(h.view.steamState.className.trim(), ('r3cg-state ' + cls).trim());
		}
	});

	await test('Steam开关调用steam-direct 1/0，期间禁用，一次调用即核验', async () => {
		const h = harness(summary({ steam_direct: STEAM_OFF })), pending = deferred();
		h.queue(pending.promise);
		const result = h.view.steamSwitch.click();
		assert.deepEqual(h.calls[0], ['steam-direct', '1']);
		assert.equal(h.view.steamSwitch.disabled, true);
		assert.equal(h.view.steamSwitch.attributes['aria-checked'], 'true');
		assert.equal(h.view.steamState.textContent, '正在开启…');
		assert.equal(h.view.root.attributes['aria-busy'], 'true');
		for (const control of [h.view.addBtn, h.view.presetBtn, h.view.disableBtn, h.view.refreshBtn])
			assert.equal(control.disabled, true);
		await h.view.toggleSteam(false);
		h.clock.now += 60000;
		await h.polls[0].fn();
		assert.equal(h.calls.length, 1);
		pending.resolve(reply(changed({ steam_direct: STEAM_ON })));
		await result;
		assert.equal(h.calls.length, 1, '不再额外读状态');
		assert.match(h.view.message.textContent, /^Steam 直连已开启。用时/);
		assert.equal(h.view.noticeTone, 'ok');
		assert.equal(h.view.steamState.textContent, '已生效');
		assert.equal(h.view.steamSwitch.disabled, false);
		h.queue(reply(changed({ steam_direct: STEAM_OFF })));
		await h.view.steamSwitch.click();
		assert.deepEqual(h.calls[1], ['steam-direct', '0']);
		assert.match(h.view.message.textContent, /^Steam 直连已关闭。/);
		assert.equal(h.view.steamSwitch.attributes['aria-checked'], 'false');
	});

	await test('开启但配置里没找到时开关显示关闭，打开一次即重新应用', async () => {
		const h = harness(summary({ steam_direct: { enabled: true, applied: false } }));
		assert.equal(h.view.steamSwitch.attributes['aria-checked'], 'false');
		assert.equal(h.view.steamSwitch.disabled, false);
		h.queue(reply(changed({ steam_direct: STEAM_ON })));
		await h.view.steamSwitch.click();
		assert.deepEqual(h.calls[0], ['steam-direct', '1']);
		assert.equal(h.view.steamState.textContent, '已生效');
	});

	await test('Steam失败显示中文错误并恢复开关，返回不符不虚报', async () => {
		const h = harness(summary({ steam_direct: STEAM_OFF }));
		h.queue(reply({ ok: false, error: 'CONFIG_TEST_FAILED', message: 'Mihomo 未通过候选配置校验，原配置已保留。' }, 1));
		await h.view.steamSwitch.click();
		assert.equal(h.view.message.textContent, 'Mihomo 未通过候选配置校验，原配置已保留。');
		assert.equal(h.view.noticeTone, 'bad');
		assert.equal(h.view.steamSwitch.attributes['aria-checked'], 'false');
		assert.equal(h.view.steamSwitch.disabled, false);
		assert.equal(h.view.steamState.textContent, '未生效');
		h.queue(reply(changed({ steam_direct: { enabled: true, applied: false } })));
		await h.view.steamSwitch.click();
		assert.equal(h.view.noticeTone, 'bad');
		assert.match(h.view.message.textContent, /尚未确认/);
		assert.doesNotMatch(h.view.root.textContent, /CONFIG_TEST_FAILED/);
	});

	await test('缺少Steam字段或读取失败时开关禁用且不发命令', async () => {
		const h = harness(summary());
		assert.equal(h.view.steamSwitch.disabled, true);
		assert.equal(h.view.steamState.textContent, '状态待确认');
		h.view.steamSwitch.click();
		await h.view.toggleSteam(true);
		assert.equal(h.calls.length, 0);
		h.queue(reply(summary({ steam_direct: STEAM_ON })));
		await h.view.refresh(true);
		assert.equal(h.view.steamSwitch.disabled, false);
		h.queue({ code: 0, stdout: '<html>错误</html>' });
		await h.view.refresh(true);
		assert.equal(h.view.steamSwitch.disabled, true);
		assert.equal(h.view.steamState.textContent, '状态待确认');
		assert.match(h.view.message.textContent, /返回内容无法读取/);
		assert.equal(harness(null).view.steamSwitch.disabled, true);
	});

	await test('只开Steam时也可恢复原分流，返回不符不虚报', async () => {
		const h = harness(summary({ steam_direct: STEAM_ON }));
		assert.equal(h.view.disableBtn.disabled, false);
		h.view.disableBtn.click();
		assert.match(h.ui.modal.children[0].textContent, /清除本模块写入运行配置的分流，并关闭 Steam 直连。/);
		h.queue(reply(changed({ steam_direct: STEAM_OFF })));
		await modalButtons(h)[1].click();
		assert.deepEqual(h.calls[0], ['disable']);
		assert.equal(h.view.noticeTone, 'ok');
		assert.equal(h.view.disableBtn.disabled, true);
		const stale = harness(summary({ steam_direct: STEAM_ON }));
		stale.view.disableBtn.click();
		stale.queue(reply(changed({ steam_direct: STEAM_ON })));
		await modalButtons(stale)[1].click();
		assert.equal(stale.view.noticeTone, 'bad');
	});

	await test('状态异常用中文，内部token不回显，恢复入口保留', async () => {
		const h = harness(summary({ enabled: true, rules: [rule({ applied: false, error: 'NODE_MISSING' })], error: 'RUNTIME_GROUP_MISSING' }));
		assert.equal(h.view.message.textContent, '分流状态异常，请刷新或恢复原分流。');
		assert.match(h.view.list.textContent, /节点已不在订阅里，请换节点。/);
		assert.doesNotMatch(h.view.root.textContent, /NODE_MISSING|RUNTIME_GROUP_MISSING/);
		assert.equal(h.view.disableBtn.disabled, false);
		h.queue(reply({ ok: false, message: '订阅文件不存在或不是受允许的普通文件。' }, 1));
		await h.view.refresh(true);
		assert.equal(h.view.disableBtn.disabled, false);
		assert.equal(h.view.addBtn.disabled, true);
		assert.match(h.view.list.textContent, /状态待确认/);
		const mapped = harness(summary({ enabled: true, rules: [rule({ applied: false, error: 'STATE_MISMATCH' })], error: 'STATE_MISMATCH' }));
		assert.equal(mapped.view.message.textContent, '运行配置与设置不一致，可再保存一次或恢复原分流。');
	});

	await test('测速启动失败用中文，不显示内部token或IP', async () => {
		const r = rule(), h = harness(enabledWith(r));
		await openRule(h, r);
		h.queue(reply({ ok: false, error: 'BENCH_BUSY' }, 1));
		await h.view.startBench(true);
		assert.equal(h.view.dlg.el.benchLine.textContent, '另一个测速正在进行，请稍后再试。');
		for (const message of ['PROBE_FAILED 198.51.100.1', '连接 198.51.100.1 失败']) {
			h.queue(reply({ ok: false, message }, 1));
			await h.view.startBench(true);
			assert.equal(h.view.dlg.el.benchLine.textContent, '测速启动失败，请稍后重试。');
		}
		assert.deepEqual(h.calls[1], ['benchmark', 'lian_li.yaml', 'site:example.com']);
		const broken = harness(enabledWith(r));
		await openRule(broken, r, true, nodesReply(ALL, { error: 'CORE_MISSING' }));
		assert.equal(broken.view.dlg.el.benchLine.textContent, '测速暂不可用。');
	});

	await test('取消编辑不保存，计时器清掉，迟到的节点响应不重开弹窗', async () => {
		const r = rule(), h = harness(enabledWith(r)), pending = deferred();
		h.queue(pending.promise);
		h.view.openEditor(r, false, false);
		h.view.dlg.el.domains.input('other.example.org');
		assert.equal(h.live().length, 1);
		h.view.dlg.el.cancel.click();
		assert.equal(h.ui.modal, null);
		assert.equal(h.view.dlg, null);
		assert.equal(h.live().length, 0);
		pending.resolve(reply(nodesReply()));
		await tick();
		assert.equal(h.view.dlg, null);
		assert.equal(h.calls.length, 1);
	});

	await test('LuCI在别处关掉弹窗后恢复空闲刷新', async () => {
		const r = rule(), h = harness(enabledWith(r));
		await openRule(h, r);
		document.body = { classList: { contains: () => false } };
		try {
			h.clock.now += 31000;
			h.queue(reply(enabledWith(r)));
			await h.polls[0].fn();
			assert.deepEqual(h.calls[1], ['summary']);
			assert.equal(h.view.dlg, null);
		}
		finally { delete document.body; }
	});

	await test('弹窗底栏取消在前（LuCI的Esc会点它），弹窗带本模块样式类', async () => {
		const r = rule(), h = harness(enabledWith(r));
		await openRule(h, r);
		assert.equal(h.ui.modal.children[1].className, 'right');
		assert.deepEqual(modalButtons(h).map(b => b.textContent), ['取消', '保存并生效']);
		assert.equal(h.ui.modal.cls, 'r3cg-modal');
	});

	await test('菜单为网站分流且ACL仅开放规定命令', () => {
		const menu = JSON.parse(fs.readFileSync(path.join(ROOT, 'router/usr/share/luci/menu.d/luci-app-r3mini-chatgpt.json'), 'utf8'));
		assert.equal(menu['admin/services/r3mini-chatgpt'].title, '网站分流');
		assert.equal(menu['admin/services/r3mini-chatgpt'].action.path, 'services/r3mini-chatgpt');
		const acl = JSON.parse(fs.readFileSync(path.join(ROOT, 'router/usr/share/rpcd/acl.d/luci-app-r3mini-chatgpt.json'), 'utf8'))['luci-app-r3mini-chatgpt'];
		assert.deepEqual(Object.keys(acl.read.file).sort(), ['benchmark-status *', 'nodes *', 'status', 'status *', 'summary']
			.map(s => '/usr/sbin/r3mini-chatgpt ' + s).sort());
		// Steam: only the two exact commands the page sends, no wildcard.
		assert.deepEqual(Object.keys(acl.write.file).sort(), ['apply *', 'benchmark *', 'disable', 'remove *', 'save *', 'set-enabled *',
			'steam-direct 0', 'steam-direct 1'].map(s => '/usr/sbin/r3mini-chatgpt ' + s).sort());
		assert.deepEqual(acl.read.ubus, { file: ['exec'] });
		assert.deepEqual(acl.write.ubus, { file: ['exec'] });
		assert.ok(!JSON.stringify(acl).includes('hook'));
	});

	console.log('LUCI_VIEW_OK tests=' + passed);
}
run().catch(error => { console.error(error); process.exitCode = 1; });
