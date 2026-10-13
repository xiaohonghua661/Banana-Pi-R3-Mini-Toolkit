'use strict';
// run-ui-test.js —— 离线验收 LuCI 广告过滤页：用无头 Chrome 渲染 view 文件（LuCI 运行时用替身），
// 走一遍开关 / 改时间 / 立即更新 / 出错路径，并截桌面、手机宽度、OpenClash 未运行三张图。
// 用法：node run-ui-test.js（需要本机 Chrome 或 Edge；截图与临时页面写到 R3AB_UI_OUT，默认系统临时目录下 r3mini-adblock-ui-test）
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const here = __dirname;
const view = fs.readFileSync(path.join(here, '../../router/www/luci-static/resources/view/services/r3mini-adblock.js'), 'utf8')
	.replace(/^'use strict';\s*('require [^']+';\s*)*/, '');
const base = JSON.parse(fs.readFileSync(path.join(here, 'status-sample.json'), 'utf8'));
const out = process.env.R3AB_UI_OUT || path.join(os.tmpdir(), 'r3mini-adblock-ui-test');
fs.mkdirSync(out, { recursive: true });
const chrome = ['C:/Program Files/Google/Chrome/Application/chrome.exe', 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe']
	.find(p => fs.existsSync(p));

function page(scenario) {
	return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{margin:0;background:#eef2ef}#view{padding:12px}</style></head><body><div id="view"></div><pre id="out"></pre><script>
const BASE = ${JSON.stringify(base)};
const calls = [], log = [];
let st = JSON.parse(JSON.stringify(BASE)), nextExec = null, pollQueue = [];
function result(v) { return { code: 0, stdout: JSON.stringify(v), stderr: '' }; }
const fsStub = { exec(helper, args) {
	calls.push(args.join(' '));
	if (nextExec) { const r = nextExec; nextExec = null; return Promise.resolve(r); }
	const a = args[0];
	if (a === 'enable') Object.assign(st, { enabled: true, runtime_domain: 783, runtime_rule: 16, message: '' });
	if (a === 'disable') Object.assign(st, { enabled: false, runtime_domain: 1, runtime_rule: 1, message: '' });
	if (a === 'sub') Object.assign(st, { subscription: args[1] === 'on', runtime_domain: args[1] === 'on' ? 783 : 181 });
	if (a === 'auto') Object.assign(st, { auto_update: args[1] === 'on', update_hour: +args[2] });
	if (a === 'update-bg') { Object.assign(st, { updating: true }); pollQueue = [{ updating: true }, { updating: false, last_result: 'ok', last_message: '新增 3 条，移除 1 条', last_time: '2026-10-13 04:30:05' }]; }
	if (a === 'status' && pollQueue.length) Object.assign(st, pollQueue.shift());
	return Promise.resolve(result(st));
} };
function E(tag, attrs, children) {
	const n = document.createElement(tag);
	Object.entries(attrs || {}).forEach(([k, v]) => k === 'class' ? n.className = v : n.setAttribute(k, v));
	(Array.isArray(children) ? children : children == null ? [] : [children]).forEach(c => n.append(c && c.nodeType ? c : document.createTextNode(String(c))));
	return n;
}
const mod = new Function('view', 'fs', 'ui', 'E', ${JSON.stringify(view)})({ extend: v => v }, fsStub, { addNotification() {} }, E);
const $ = s => document.querySelector(s);
const txt = s => $(s).textContent;
const sleep = ms => new Promise(r => setTimeout(r, ms));
function check(name, cond, detail) { log.push((cond ? 'PASS ' : 'FAIL ') + name + (cond ? '' : ' :: ' + detail)); }
function click(sel) { const n = $(sel); if (n.type === 'checkbox') { n.checked = !n.checked; n.dispatchEvent(new Event('change')); } else n.click(); }
window.onerror = (m) => log.push('FAIL js-error :: ' + m);
(async () => {
	const scenario = ${JSON.stringify(scenario)};
	$('#view').append(mod.render(scenario === 'nooc' ? Object.assign({}, st, { openclash_running: false, loaded: 'unknown', runtime_domain: null, runtime_rule: null }) : st));
	if (scenario !== 'full') { await sleep(50); document.getElementById('out').textContent = 'viewport=' + document.documentElement.clientWidth + ' overflow=' + (document.documentElement.scrollWidth > document.documentElement.clientWidth); return; }
	check('初始：总开关开', $('#r3ab-enabled').checked, '');
	check('初始：订阅开', $('#r3ab-sub').checked, '');
	check('初始：自动更新关', !$('#r3ab-auto').checked, '');
	check('初始：时间 05:30', $('#r3ab-hour').value === '5', $('#r3ab-hour').value);
	check('初始：状态 过滤中', txt('#r3ab-pill span') === '过滤中', txt('#r3ab-pill span'));
	check('初始：正在生效 799 条', txt('#r3ab-active') === '799 条', txt('#r3ab-active'));
	check('初始：内置规则', txt('#r3ab-builtin') === '16 条规则 + 183 个域名', txt('#r3ab-builtin'));
	check('初始：订阅 651 条', txt('#r3ab-source') === '651 条' && /秋风广告规则（仅广告）/.test(txt('#r3ab-source-sub')), txt('#r3ab-source') + '|' + txt('#r3ab-source-sub'));
	check('初始：上次更新', txt('#r3ab-last') === '2026-10-13 03:32', txt('#r3ab-last'));

	click('#r3ab-enabled'); await sleep(50);
	check('关闭：调用 disable', calls.at(-1) === 'disable', calls.at(-1));
	check('关闭：状态 已关闭', txt('#r3ab-pill span') === '已关闭', txt('#r3ab-pill span'));
	check('关闭：正在生效 0 条', txt('#r3ab-active') === '0 条', txt('#r3ab-active'));
	check('关闭：提示', txt('#r3ab-msg') === '广告过滤已关闭', txt('#r3ab-msg'));
	click('#r3ab-enabled'); await sleep(50);
	check('打开：调用 enable', calls.at(-1) === 'enable' && txt('#r3ab-pill span') === '过滤中', calls.at(-1));

	click('#r3ab-sub'); await sleep(50);
	check('关订阅：sub off', calls.at(-1) === 'sub off' && txt('#r3ab-source') === '已关闭', calls.at(-1) + '|' + txt('#r3ab-source'));
	click('#r3ab-sub'); await sleep(50);

	const sel = $('#r3ab-hour'); sel.value = '7'; sel.dispatchEvent(new Event('change')); await sleep(50);
	check('改时间：auto off 7', calls.at(-1) === 'auto off 7', calls.at(-1));
	click('#r3ab-auto'); await sleep(50);
	check('开自动更新：auto on 7', calls.at(-1) === 'auto on 7' && txt('#r3ab-msg') === '已打开每天自动更新', calls.at(-1));

	click('#r3ab-update'); await sleep(100);
	check('立即更新：update-bg 且控件锁定', calls.at(-1) === 'update-bg' && $('#r3ab-update').disabled, calls.at(-1));
	await sleep(6000);
	check('立即更新：轮询到完成', /更新完成：新增 3 条，移除 1 条/.test(txt('#r3ab-msg')) && !$('#r3ab-update').disabled, txt('#r3ab-msg'));
	check('立即更新：上次更新刷新', txt('#r3ab-last') === '2026-10-13 04:30', txt('#r3ab-last'));

	nextExec = { code: 0, stdout: JSON.stringify(Object.assign({}, st, { message: '连不上 OpenClash（API 返回 000）；规则已保存，OpenClash 运行后自动生效' })), stderr: '' };
	click('#r3ab-enabled'); await sleep(50);
	check('生效失败：红字提示', /连不上 OpenClash/.test(txt('#r3ab-msg')) && $('#r3ab-msg').className.includes('err'), txt('#r3ab-msg'));
	nextExec = { code: 1, stdout: '', stderr: 'Permission denied' };
	click('#r3ab-sub'); await sleep(100);
	check('接口出错：显示错误且恢复可点', txt('#r3ab-msg') === 'Permission denied' && !$('#r3ab-sub').disabled, txt('#r3ab-msg'));
	check('无横向滚动', document.documentElement.scrollWidth <= document.documentElement.clientWidth, document.documentElement.scrollWidth);
	document.getElementById('out').textContent = log.join('\\n') + '\\nDONE';
})();
</script></body></html>`;
}

function runChrome(file, extra) {
	return execFileSync(chrome, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
		'--user-data-dir=' + path.join(out, '.chrome'), '--virtual-time-budget=15000', ...extra, 'file:///' + file.replace(/\\/g, '/')],
		{ encoding: 'utf8', maxBuffer: 1 << 24, stdio: ['ignore', 'pipe', 'ignore'] });
}

const full = path.join(out, 'harness-full.html');
fs.writeFileSync(full, page('full'));
const dom = runChrome(full, ['--window-size=1280,900', '--dump-dom']);
const result = (dom.match(/<pre id="out">([\s\S]*?)<\/pre>/) || [])[1] || 'NO OUTPUT';
console.log(result.replace(/&gt;/g, '>').replace(/&lt;/g, '<').replace(/&amp;/g, '&'));

for (const [name, size, scenario] of [['desktop', '1280,900', 'shot'], ['mobile', '820,1200', 'shot'], ['nooc', '1280,900', 'nooc']]) {
	const f = path.join(out, 'harness-' + name + '.html');
	fs.writeFileSync(f, page(scenario));
	if (name === 'mobile') {  // Chrome 窗口有最小宽度，手机宽度用 390px 的 iframe 模拟
		fs.writeFileSync(path.join(out, 'harness-mobile-inner.html'), page(scenario));
		fs.writeFileSync(f, '<!doctype html><body style="margin:0;background:#888"><iframe src="harness-mobile-inner.html" style="width:390px;height:1180px;border:0;background:#fff"></iframe></body>');
	}
	runChrome(f, ['--window-size=' + size, '--hide-scrollbars', '--screenshot=' + path.join(out, 'ui-' + name + '.png')]);
	console.log('screenshot ' + path.join(out, 'ui-' + name + '.png'));
}
