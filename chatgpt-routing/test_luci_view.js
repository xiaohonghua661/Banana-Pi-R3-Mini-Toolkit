'use strict';

// 实际执行 LuCI view 的离线状态机测试，不连接设备、不依赖第三方包。
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ROOT = __dirname;
const VIEW = path.join(ROOT, 'router/www/luci-static/resources/view/services/r3mini-chatgpt.js');
const SOURCE = fs.readFileSync(VIEW, 'utf8');

class Element {
	constructor(tag, text) {
		this.tagName = tag; this.nodeType = tag === '#text' ? 3 : 1;
		this.children = []; this.attributes = {}; this.events = {};
		this.disabled = false; this.className = ''; this._value = ''; this.text = text || '';
	}
	get firstChild() { return this.children[0] || null; }
	get disabled() { return this._disabled; }
	set disabled(value) { this._disabled = Boolean(value); }
	appendChild(node) { this.children.push(node); return node; }
	removeChild(node) { this.children.splice(this.children.indexOf(node), 1); }
	setAttribute(key, value) {
		this.attributes[key] = String(value);
		if (key === 'value') this._value = String(value);
		if (key === 'disabled') this.disabled = true;
		if (key === 'hidden') this.hidden = true;
	}
	addEventListener(key, fn) { this.events[key] = fn; }
	get value() {
		if (this.tagName === 'select') return this.children.some(c => c.value === this._value) ? this._value : '';
		return this._value;
	}
	set value(value) { this._value = String(value); }
	get textContent() { return this.text + this.children.map(c => c.textContent).join(''); }
	set textContent(value) { this.children = []; this.text = String(value); }
	set innerHTML(value) { throw new Error('禁止将外部文本插入 innerHTML'); }
	change(value) { this.value = value; this.events.change({ target: this }); }
	input(value) { this.value = value; this.events.input({ target: this }); }
	focus() { this.focused = true; }
}
const document = { createElement: tag => new Element(tag), createTextNode: text => new Element('#text', String(text)) };
const N1 = { id: '1111111111111111', name: '测试节点一', type: 'ss', eligible: true, country: 'JP', samples_ms: [90, 80, 100], median_ms: 90 };
const N2 = { id: '2222222222222222', name: '<img src=x onerror=alert(1)>', type: 'trojan', eligible: true, country: 'US', samples_ms: [50, 60, 70], median_ms: 60 };
const N3 = { id: '3333333333333333', name: '另一配置节点', type: 'vmess', eligible: true, country: 'SG', samples_ms: [120, 130, 140], median_ms: 130 };
function rule(overrides = {}) {
	return Object.assign({ id: 'aaaaaaaaaaaa', label: '演示网站', domains: ['example.com'], source: 'lian_li.yaml',
		selected: N1.id, selected_name: N1.name, enabled: true, applied: true, error: '', preset: '' }, overrides);
}
function status(overrides = {}) {
	return Object.assign({ ok: true, enabled: false, applied: false, source: 'lian_li.yaml', selected: '',
		sources: ['lian_li.yaml', 'other.yaml'], nodes: [N1, N2], site_rules: [], pending_restart: false,
		source_error: '', error: '' }, overrides);
}
function reply(data, code = 0) { return { code, stdout: JSON.stringify(data), stderr: '' }; }
function benchmark(overrides = {}) {
	return Object.assign({ ok: true, source: 'lian_li.yaml', source_hash: 'a'.repeat(64), running: false, done: 2, total: 2,
		results: [Object.assign({}, N1), Object.assign({}, N2)], best: N2.id, error: null }, overrides);
}
function deferred() {
	let resolve, reject;
	const promise = new Promise((a, b) => { resolve = a; reject = b; });
	return { promise, resolve, reject };
}
function harness(initial = status()) {
	const calls = [], queued = [], polls = [];
	const rpc = { exec: (cli, args) => {
		assert.equal(cli, '/usr/sbin/r3mini-chatgpt');
		calls.push(args);
		assert.ok(queued.length, '出现未安排的接口调用：' + args.join(' '));
		return Promise.resolve(queued.shift());
	} };
	const def = new Function('view', 'fs', 'poll', 'document', SOURCE)({ extend: x => x }, rpc,
		{ add: (fn, interval) => polls.push({ fn, interval }) }, document);
	const view = Object.assign({}, def);
	view.render(initial ? { status: initial } : { error: '状态读取失败' });
	return { view, calls, polls, queue: result => queued.push(result) };
}
const tick = () => new Promise(setImmediate);
async function open(h, existing = null, preset = false, candidate = null) {
	h.queue(reply(candidate || h.view.status));
	h.view.openForm(existing, preset);
	await tick();
}
async function run() {
	let passed = 0;
	async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }
	await test('空规则列表、中文标题与5秒轮询', () => {
		const h = harness();
		assert.match(h.view.root.textContent, /网站分流/);
		assert.match(h.view.list.textContent, /还没有网站规则/);
		assert.equal(h.view.form.hidden, true);
		assert.equal(h.view.disableBtn.disabled, true);
		assert.equal(h.polls[0].interval, 5);
	});
	await test('自定义网站默认配置但节点必须手选', async () => {
		const h = harness();
		await open(h);
		assert.equal(h.view.source, 'lian_li.yaml');
		assert.equal(h.view.selected, '');
		assert.equal(h.view.nodeSelect.value, '');
		h.view.domainsInput.input('example.com');
		assert.equal(h.view.saveBtn.disabled, true);
		h.view.nodeSelect.change(N2.id);
		assert.equal(h.view.saveBtn.disabled, false);
	});
	await test('网站名、域名和节点名称仅按文本插入', async () => {
		const r = rule({ label: '<svg/onload=alert(1)>', domains: ['<img src=x>'], selected_name: N2.name });
		const h = harness(status({ site_rules: [r], enabled: true, applied: true }));
		assert.match(h.view.list.textContent, /<svg\/onload=alert\(1\)>/);
		await open(h);
		const option = h.view.nodeSelect.children.find(c => c.value === N2.id);
		assert.equal(option.textContent, '美国 · ' + N2.name + ' · 60 ms');
		assert.equal(option.children[0].nodeType, 3);
	});
	await test('ChatGPT预设填入域名与preset且不自动选节点', async () => {
		const h = harness();
		await open(h, null, true);
		assert.equal(h.view.label, 'ChatGPT');
		assert.equal(h.view.preset, 'chatgpt');
		assert.deepEqual(h.view.domains(), ['chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com', 'chatgpt.livekit.cloud']);
		assert.equal(h.view.selected, '');
		assert.equal(h.view.saveBtn.disabled, true);
		h.view.domainsInput.input(h.view.domainsText + '\nexample.org');
		assert.equal(h.view.preset, 'chatgpt');
	});
	await test('编辑保留原id、域名、源、节点和预设标记', async () => {
		const r = rule({ preset: 'chatgpt' }), h = harness(status({ site_rules: [r], enabled: true, applied: true }));
		await open(h, r);
		assert.equal(h.view.editId, r.id);
		assert.equal(h.view.selected, N1.id);
		assert.equal(h.view.domainsInput.value, 'example.com');
		assert.equal(h.view.preset, 'chatgpt');
		assert.equal(h.view.saveBtn.disabled, false);
	});
	await test('轮询更新列表但保留未提交名称、域名、源与节点', async () => {
		const h = harness();
		await open(h);
		h.view.labelInput.input('尚未保存的网站');
		h.view.domainsInput.input('https://Example.NET/some/path\nexample.org');
		h.view.nodeSelect.change(N2.id);
		h.queue(reply(status({ site_rules: [rule()], enabled: true, applied: true })));
		await h.polls[0].fn();
		assert.equal(h.view.labelInput.value, '尚未保存的网站');
		assert.equal(h.view.domainsInput.value, 'https://Example.NET/some/path\nexample.org');
		assert.equal(h.view.source, 'lian_li.yaml');
		assert.equal(h.view.selected, N2.id);
		assert.match(h.view.list.textContent, /演示网站/);
		assert.equal(h.view.dirty, true);
	});
	await test('源配置异步竞态：旧响应不覆盖新选择', async () => {
		const h = harness(), first = deferred(), second = deferred();
		await open(h);
		h.queue(first.promise); h.view.sourceSelect.change('other.yaml');
		assert.equal(h.view.selected, '');
		assert.equal(h.view.saveBtn.disabled, true);
		h.queue(second.promise); h.view.sourceSelect.change('lian_li.yaml');
		second.resolve(reply(status())); await tick();
		first.resolve(reply(status({ nodes: [N3] }))); await tick();
		assert.equal(h.view.source, 'lian_li.yaml');
		assert.equal(h.view.nodes[0].id, N1.id);
	});
	await test('查看其他配置不依赖顶层active source', async () => {
		const h = harness();
		await open(h);
		h.queue(reply(status({ source: 'lian_li.yaml', nodes: [N3] })));
		h.view.sourceSelect.change('other.yaml'); await tick();
		h.view.domainsInput.input('example.com'); h.view.nodeSelect.change(N3.id);
		h.queue(reply(status({ source: 'lian_li.yaml', nodes: [N3] })));
		await h.polls[0].fn();
		assert.equal(h.view.source, 'other.yaml');
		assert.equal(h.view.selected, N3.id);
		assert.equal(h.view.saveBtn.disabled, false);
	});
	await test('节点或源被移除时禁止自动替换及保存', async () => {
		const h = harness(); await open(h);
		h.view.domainsInput.input('example.com'); h.view.nodeSelect.change(N2.id);
		h.queue(reply(status({ nodes: [N1], sources: ['other.yaml'] })));
		await h.view.refreshStatus(true);
		assert.equal(h.view.source, 'lian_li.yaml');
		assert.equal(h.view.selected, N2.id);
		assert.equal(h.view.saveBtn.disabled, true);
		assert.match(h.view.nodeHint.textContent, /重新选择/);
	});
	await test('save精确传递多行URL、节点与源并回读新增id', async () => {
		const h = harness(); await open(h);
		h.view.labelInput.input(' 示例网站 ');
		h.view.domainsInput.input('https://Example.COM/a\nexample.org');
		h.view.nodeSelect.change(N2.id);
		const saved = rule({ id: 'bbbbbbbbbbbb', label: '示例网站', domains: ['example.com', 'example.org'], selected: N2.id, selected_name: N2.name });
		h.queue(reply({ ok: true, id: saved.id }));
		h.queue(reply(status({ site_rules: [saved], enabled: true, applied: true })));
		await h.view.mutate('save');
		const payload = JSON.parse(h.calls[1][1]);
		assert.deepEqual(payload, { label: '示例网站', domains: ['https://Example.COM/a', 'example.org'], source: 'lian_li.yaml', selected: N2.id, enabled: true });
		assert.equal(h.calls[1][0], 'save');
		assert.equal(h.view.form.hidden, true);
		assert.match(h.view.message.textContent, /已保存并启用/);
	});
	await test('编辑save传原id，ChatGPT预设save传preset', async () => {
		const r = rule({ preset: 'chatgpt' }), h = harness(status({ site_rules: [r], enabled: true, applied: true }));
		await open(h, r);
		h.queue(reply({ ok: true, id: r.id }));
		h.queue(reply(status({ site_rules: [r], enabled: true, applied: true })));
		await h.view.mutate('save');
		const payload = JSON.parse(h.calls[1][1]);
		assert.equal(payload.id, r.id);
		assert.equal(payload.preset, 'chatgpt');
	});
	await test('保存期间禁用表单及所有操作、防连点', async () => {
		const h = harness(), pending = deferred(); await open(h);
		h.view.domainsInput.input('example.com'); h.view.nodeSelect.change(N1.id);
		h.queue(pending.promise);
		h.queue(reply(status({ site_rules: [rule()], enabled: true, applied: true })));
		const result = h.view.mutate('save');
		for (const control of [h.view.addBtn, h.view.presetBtn, h.view.sourceSelect, h.view.nodeSelect, h.view.labelInput,
			h.view.domainsInput, h.view.saveBtn, h.view.cancelBtn, h.view.disableBtn, h.view.refreshBtn])
			assert.equal(control.disabled, true);
		await h.view.mutate('save'); await h.polls[0].fn();
		assert.equal(h.calls.length, 2);
		pending.resolve(reply({ ok: true, id: 'aaaaaaaaaaaa' })); await result;
	});
	await test('每条规则启停精确调用set-enabled并核验', async () => {
		const r = rule(), h = harness(status({ site_rules: [r], enabled: true, applied: true }));
		h.queue(reply({ ok: true })); h.queue(reply(status({ site_rules: [rule({ enabled: false, applied: false })] })));
		await h.view.mutate('set-enabled', r.id, false);
		assert.deepEqual(h.calls[0], ['set-enabled', r.id, '0']);
		assert.match(h.view.message.textContent, /已停用/);
		h.queue(reply({ ok: true })); h.queue(reply(status({ site_rules: [r], enabled: true, applied: true })));
		await h.view.mutate('set-enabled', r.id, true);
		assert.deepEqual(h.calls[2], ['set-enabled', r.id, '1']);
		assert.match(h.view.message.textContent, /已启用/);
	});
	await test('删除只传id，回读确认条目消失', async () => {
		const r = rule(), h = harness(status({ site_rules: [r], enabled: true, applied: true }));
		h.queue(reply({ ok: true })); h.queue(reply(status()));
		await h.view.mutate('remove', r.id);
		assert.deepEqual(h.calls[0], ['remove', r.id]);
		assert.match(h.view.message.textContent, /已删除/);
		assert.equal(h.view.rules.length, 0);
	});
	await test('全局恢复停用全部规则并保留定义', async () => {
		const h = harness(status({ site_rules: [rule()], enabled: true, applied: true }));
		h.queue(reply({ ok: true }));
		h.queue(reply(status({ site_rules: [rule({ enabled: false, applied: false })] })));
		await h.view.mutate('disable');
		assert.deepEqual(h.calls[0], ['disable']);
		assert.equal(h.view.rules.length, 1);
		assert.equal(h.view.rules[0].enabled, false);
		assert.match(h.view.message.textContent, /全部网站规则已停用/);
	});
	await test('controller离线pending_restart不显示实时恢复绿成功', async () => {
		const h = harness(status({ site_rules: [rule()], enabled: true, applied: true }));
		h.queue(reply({ ok: true, pending_restart: true }));
		h.queue(reply(status({ pending_restart: true, site_rules: [rule({ enabled: false, applied: false })] })));
		await h.view.mutate('disable');
		assert.match(h.view.message.textContent, /等待 OpenClash 启动后生效/);
		assert.equal(h.view.noticeTone, 'warn');
		assert.match(h.view.badge.textContent, /待启动生效/);
		assert.doesNotMatch(h.view.message.className, /ok/);
	});
	await test('非零或ok:false显示中文错误且不虚报保存成功', async () => {
		const h = harness(); await open(h);
		h.view.domainsInput.input('example.com'); h.view.nodeSelect.change(N1.id);
		h.queue(reply({ ok: false, message: '此域名与已有网站规则冲突。' }, 1));
		await h.view.mutate('save');
		assert.equal(h.view.message.textContent, '此域名与已有网站规则冲突。');
		assert.equal(h.view.form.hidden, false);
		h.queue(reply({ ok: false, message: '所选节点已不存在。' }));
		await h.view.mutate('save');
		assert.equal(h.view.message.textContent, '所选节点已不存在。');
		assert.equal(h.view.noticeTone, 'bad');
	});
	await test('新增规则离线待启动时保存定义但不显示实时启用', async () => {
		const h = harness(); await open(h);
		h.view.domainsInput.input('example.com'); h.view.nodeSelect.change(N1.id);
		h.queue(reply({ ok: true, id: 'aaaaaaaaaaaa', pending_restart: true }));
		h.queue(reply(status({ site_rules: [rule({ applied: false })], enabled: true, pending_restart: true })));
		await h.view.mutate('save');
		assert.match(h.view.message.textContent, /等待 OpenClash 启动后生效/);
		assert.equal(h.view.noticeTone, 'warn');
		assert.equal(h.view.form.hidden, true);
	});
	await test('返回成功但回读不匹配不虚报保存生效', async () => {
		const h = harness(); await open(h);
		h.view.domainsInput.input('example.com'); h.view.nodeSelect.change(N1.id);
		h.queue(reply({ ok: true, id: 'bbbbbbbbbbbb' }));
		h.queue(reply(status({ site_rules: [rule()], enabled: true, applied: true })));
		await h.view.mutate('save');
		assert.equal(h.view.noticeTone, 'bad');
		assert.match(h.view.message.textContent, /尚未确认/);
		assert.equal(h.view.form.hidden, false);
	});
	await test('读取失败保留恢复入口，内部token不回显', async () => {
		const h = harness(status({ enabled: true, site_rules: [rule({ applied: false, error: 'NODE_MISSING' })], error: 'RUNTIME_GROUP_MISSING' }));
		assert.equal(h.view.message.textContent, '分流状态异常，请刷新或恢复原分流。');
		assert.doesNotMatch(h.view.list.textContent, /NODE_MISSING/);
		assert.equal(h.view.disableBtn.disabled, false);
		h.queue(reply({ ok: false, message: '源配置已不存在。' }, 1));
		await h.view.refreshStatus(true);
		assert.equal(h.view.disableBtn.disabled, false);
		assert.equal(h.view.addBtn.disabled, true);
		assert.match(h.view.list.textContent, /状态待确认/);
	});
	await test('加载、空节点、错误与恢复后状态', async () => {
		const h = harness(null), pending = deferred();
		assert.match(h.view.badge.textContent, /异常/);
		h.queue(reply(status())); await h.view.refreshStatus(true);
		h.queue(pending.promise); h.view.openForm(null, false);
		assert.match(h.view.nodeHint.textContent, /正在读取/);
		pending.resolve(reply(status({ nodes: [] }))); await tick();
		assert.equal(h.view.nodeSelect.disabled, true);
		assert.match(h.view.nodeHint.textContent, /没有可用节点/);
		h.queue({ code: 0, stdout: '<html>错误</html>' });
		await h.view.refreshStatus(true);
		assert.match(h.view.message.textContent, /返回内容无法读取/);
		h.queue(reply(status())); await h.view.refreshStatus(true);
		assert.equal(h.view.nodeSelect.disabled, false);
	});
	await test('取消编辑不调用保存，旧查询不重开表单', async () => {
		const h = harness(), pending = deferred();
		h.queue(pending.promise); h.view.openForm(null, false);
		h.view.domainsInput.input('example.com'); h.view.closeForm();
		pending.resolve(reply(status())); await tick();
		assert.equal(h.view.formOpen, false);
		assert.equal(h.view.form.hidden, true);
		assert.equal(h.calls.length, 1);
	});
	await test('poll请求不重叠且后台读取不禁用正在编辑的节点', async () => {
		const h = harness(), pending = deferred(); await open(h);
		h.queue(pending.promise); const p = h.polls[0].fn();
		await h.polls[0].fn();
		assert.equal(h.calls.length, 2);
		assert.equal(h.view.nodeSelect.disabled, false);
		pending.resolve(reply(status())); await p;
	});
	await test('未测速及地区不支持的节点禁选且不能强行保存', async () => {
		const untested = Object.assign({}, N1, { eligible: false, country: null, samples_ms: [], median_ms: null });
		const blocked = Object.assign({}, N2, { eligible: false, country: 'HK', samples_ms: [], median_ms: null });
		const h = harness(status({ nodes: [untested, blocked], benchmark: benchmark({ best: null,
			results: [Object.assign({}, blocked, { error: 'UNSUPPORTED_REGION' })] }) }));
		await open(h);
		assert.equal(h.view.nodeSelect.children.find(n => n.value === N1.id).disabled, true);
		assert.match(h.view.nodeSelect.children.find(n => n.value === N1.id).textContent, /尚未测速/);
		assert.match(h.view.nodeSelect.children.find(n => n.value === N2.id).textContent, /香港.*地区不支持/);
		h.view.domainsInput.input('example.com'); h.view.nodeSelect.change(N1.id);
		assert.equal(h.view.saveBtn.disabled, true);
		await h.view.mutate('save');
		assert.equal(h.calls.length, 1);
	});
	await test('配置更新后PENDING显示尚未测速且保持禁选', async () => {
		for (const pendingError of ['PENDING', 'BENCH_PENDING']) {
			for (const errorOnNode of [true, false]) {
				const pending = Object.assign({}, N1, { eligible: false, country: null, samples_ms: [], median_ms: null,
					error: errorOnNode ? pendingError : null });
				const h = harness(status({ nodes: [pending], benchmark: benchmark({ best: null, done: 0, total: 1,
					results: [Object.assign({}, pending, { error: pendingError })], error: 'SOURCE_CHANGED' }) }));
				await open(h);
				const option = h.view.nodeSelect.children.find(n => n.value === N1.id);
				assert.match(option.textContent, /尚未测速/);
				assert.doesNotMatch(option.textContent, /测速未通过|连接失败/);
				assert.match(h.view.benchmarkRows.textContent, /尚未测速/);
				assert.match(h.view.benchmarkProgress.textContent, /配置已更新，请重新测速/);
				assert.equal(option.disabled, true);
				h.view.domainsInput.input('example.com'); h.view.nodeSelect.change(N1.id);
				assert.equal(h.view.saveBtn.disabled, true);
			}
		}
	});
	await test('测速进行中的PENDING显示等待测速', async () => {
		const pending = Object.assign({}, N1, { eligible: false, country: null, samples_ms: [], median_ms: null, error: 'PENDING' });
		const h = harness(status({ nodes: [pending], benchmark: benchmark({ running: true, done: 0, total: 1,
			results: [pending], best: null }) }));
		await open(h);
		const option = h.view.nodeSelect.children.find(n => n.value === N1.id);
		assert.match(option.textContent, /等待测速/);
		assert.equal(option.disabled, true);
		assert.doesNotMatch(h.view.benchmarkRows.textContent, /测速未通过|连接失败/);
	});
	await test('eligible标志缺少地区或3轮完整证明时仍禁选', async () => {
		for (const overrides of [{ samples_ms: [20, 30] }, { country: null }, { samples_ms: [20, null, 30] }, { median_ms: null }]) {
			const h = harness(status({ nodes: [Object.assign({}, N1, overrides)] }));
			await open(h);
			h.view.domainsInput.input('example.com'); h.view.nodeSelect.change(N1.id);
			assert.equal(h.view.hasSelected(), false);
			assert.equal(h.view.saveBtn.disabled, true);
		}
	});
	await test('通过节点按中位延迟排序，其余节点置底禁用', async () => {
		const bad = Object.assign({}, N3, { eligible: false, error: 'TLS_FAILED', median_ms: 1 });
		const h = harness(status({ nodes: [bad, N1, N2], benchmark: benchmark() })); await open(h);
		assert.deepEqual(h.view.nodeSelect.children.slice(1).map(n => n.value), [N2.id, N1.id, bad.id]);
		assert.equal(h.view.nodeSelect.children[3].disabled, true);
		assert.match(h.view.benchmarkRows.textContent, /美国.*3 轮：50 ms \/ 60 ms \/ 70 ms；中位延迟：60 ms/);
		assert.match(h.view.benchmarkRows.textContent, /连接失败/);
	});
	await test('最低延迟必须显式点击，仍可手选其他通过节点', async () => {
		const h = harness(status({ benchmark: benchmark() })); await open(h);
		assert.equal(h.view.selected, '');
		assert.equal(h.view.bestBtn.disabled, false);
		h.view.selectBest();
		assert.equal(h.view.selected, N2.id);
		assert.equal(h.calls.length, 1);
		h.view.nodeSelect.change(N1.id);
		h.queue(reply(status({ benchmark: benchmark() }))); await h.polls[0].fn();
		assert.equal(h.view.selected, N1.id);
		assert.match(h.view.nodeHint.textContent, /日本.*90 ms.*80 ms.*100 ms.*中位延迟：90 ms/);
	});
	await test('未完成或跨源或最优结果异常时最低延迟按钮禁用', async () => {
		for (const overrides of [{ running: true, done: 1 }, { source: 'other.yaml' }, { best: N1.id },
			{ results: [Object.assign({}, N2, { samples_ms: [10, 20] })] }, { best: N3.id }]) {
			const h = harness(status({ benchmark: benchmark(overrides) })); await open(h);
			assert.equal(h.view.bestBtn.disabled, true);
			h.view.selectBest();
			assert.equal(h.view.selected, '');
		}
	});
	await test('3轮测速异步启动且不禁用恢复或其他规则操作', async () => {
		const h = harness(status({ enabled: true, applied: true, site_rules: [rule()] })), pending = deferred(); await open(h);
		h.queue(pending.promise);
		h.queue(reply(status({ enabled: true, applied: true, site_rules: [rule()], benchmark: benchmark({ running: true, done: 12, total: 57 }) })));
		const result = h.view.startBenchmark();
		assert.equal(h.view.mutating, false);
		assert.equal(h.view.benchmarkBtn.disabled, true);
		assert.equal(h.view.disableBtn.disabled, false);
		assert.equal(h.view.ruleButtons[1].disabled, false);
		assert.equal(h.view.cancelBtn.disabled, false);
		await h.view.startBenchmark();
		assert.equal(h.calls.length, 2);
		pending.resolve(reply({ ok: true, running: true })); await result;
		assert.deepEqual(h.calls[1], ['benchmark', 'lian_li.yaml']);
		assert.match(h.view.benchmarkProgress.textContent, /12 \/ 57/);
		assert.equal(h.view.benchmarkBtn.disabled, true);
		assert.equal(h.view.bestBtn.disabled, true);
	});
	await test('测速启动旧响应不能覆盖新源配置', async () => {
		const h = harness(), pending = deferred(); await open(h);
		h.queue(pending.promise); const start = h.view.startBenchmark();
		h.queue(reply(status({ nodes: [N3], benchmark: benchmark({ source: 'other.yaml', best: N3.id, results: [N3], done: 1, total: 1 }) })));
		h.view.sourceSelect.change('other.yaml'); await tick();
		pending.resolve(reply({ ok: true, running: true })); await start;
		assert.equal(h.view.source, 'other.yaml');
		assert.equal(h.view.benchmark.source, 'other.yaml');
		assert.equal(h.view.selected, '');
		assert.equal(h.calls.length, 3);
	});
	await test('测速启动等待期间仍可实际恢复原分流', async () => {
		const h = harness(status({ enabled: true, applied: true, site_rules: [rule()] })), pending = deferred(); await open(h);
		h.queue(pending.promise); const start = h.view.startBenchmark();
		const restored = status({ site_rules: [rule({ enabled: false, applied: false })], benchmark: benchmark({ running: true, done: 1, total: 57 }) });
		h.queue(reply({ ok: true })); h.queue(reply(restored));
		await h.view.mutate('disable');
		assert.deepEqual(h.calls[2], ['disable']);
		assert.match(h.view.message.textContent, /全部网站规则已停用/);
		h.queue(reply(restored)); pending.resolve(reply({ ok: true, running: true })); await start;
		assert.match(h.view.message.textContent, /全部网站规则已停用/);
		assert.equal(h.view.mutating, false);
	});
	await test('测速错误使用中文且不显示内部token或IP', async () => {
		const h = harness(); await open(h);
		for (const message of ['PROBE_FAILED 198.51.100.1', '连接 198.51.100.1 失败']) {
			h.queue(reply({ ok: false, message }, 1));
			await h.view.startBenchmark();
			assert.match(h.view.benchmarkProgress.textContent, /测速启动失败/);
			assert.doesNotMatch(h.view.benchmarkProgress.textContent, /198\.51\.100\.1|PROBE_FAILED/);
		}
		h.queue(reply(status({ benchmark: benchmark({ error: 'CORE_MISSING' }) })));
		await h.view.refreshStatus(true);
		h.view.benchmarkNotice = ''; h.view.sync();
		assert.equal(h.view.benchmarkProgress.textContent, '测速暂不可用');
	});
	await test('已有规则有效持久证明可编辑保存，无证明则不可保存', async () => {
		const r = rule(), h = harness(status({ site_rules: [r], enabled: true, applied: true })); await open(h, r);
		assert.equal(h.view.hasSelected(), true);
		assert.equal(h.view.saveBtn.disabled, false);
		h.queue(reply(status({ site_rules: [r], enabled: true, applied: true, nodes: [Object.assign({}, N1, { eligible: false })] })));
		await h.polls[0].fn();
		assert.equal(h.view.selected, N1.id);
		assert.equal(h.view.saveBtn.disabled, true);
	});
	await test('菜单为网站分流且ACL仅开放规定命令', () => {
		const menu = JSON.parse(fs.readFileSync(path.join(ROOT, 'router/usr/share/luci/menu.d/luci-app-r3mini-chatgpt.json'), 'utf8'));
		assert.equal(menu['admin/services/r3mini-chatgpt'].title, '网站分流');
		assert.equal(menu['admin/services/r3mini-chatgpt'].action.path, 'services/r3mini-chatgpt');
		const acl = JSON.parse(fs.readFileSync(path.join(ROOT, 'router/usr/share/rpcd/acl.d/luci-app-r3mini-chatgpt.json'), 'utf8'))['luci-app-r3mini-chatgpt'];
		assert.deepEqual(Object.keys(acl.read.file).sort(), ['benchmark-status *', 'status', 'status *'].map(s => '/usr/sbin/r3mini-chatgpt ' + s));
		assert.deepEqual(Object.keys(acl.write.file).sort(), ['apply *', 'benchmark *', 'disable', 'remove *', 'save *', 'set-enabled *'].map(s => '/usr/sbin/r3mini-chatgpt ' + s).sort());
		assert.deepEqual(acl.read.ubus, { file: ['exec'] });
		assert.deepEqual(acl.write.ubus, { file: ['exec'] });
		assert.ok(!JSON.stringify(acl).includes('hook'));
	});
	console.log('LUCI_VIEW_OK tests=' + passed);
}
run().catch(error => { console.error(error); process.exitCode = 1; });
