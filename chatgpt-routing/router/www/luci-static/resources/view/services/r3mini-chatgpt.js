'use strict';
'require view';
'require fs';
'require poll';
'require ui';

var CLI = '/usr/sbin/r3mini-chatgpt';
var DEFAULT_SOURCE = 'lian_li.yaml';
var CHATGPT_DOMAINS = ['chatgpt.com', 'openai.com', 'oaistatic.com', 'oaiusercontent.com', 'chatgpt.livekit.cloud'];
// The router adds these to every ChatGPT preset rule (DOMAINS in r3mini-chatgpt.rb); used for the overlap hint only.
var PRESET_BUILTIN = CHATGPT_DOMAINS.concat(['openaiapi-site.azureedge.net', 'openaicom.imgix.net',
	'chat.openai.com.cdn.cloudflare.net', 'openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net', 'openai-api.arkoselabs.com',
	'production-openaicom-storage.azureedge.net']);
// The page reads the light `summary` every 30 s while visible and idle; an open node picker
// reads `nodes` every 3 s only while a benchmark runs. Nothing polls behind a hidden tab or a dialog.
var IDLE_POLL = 30, FRESH_MS = 5000, BENCH_POLL_MS = 3000, TARGET_DELAY_MS = 600;
// The backend accepts at most 64 node ids per run; a full sweep measured about 2.5 s per node.
var BENCH_MAX_IDS = 64, SECONDS_PER_NODE = 2.5;
// Region filter: the biggest regions as buttons, the long tail (MESL: 83 more) in a dropdown.
var REGION_CHIPS = 8;
// settings.json validation (and therefore rollback to an older backend) caps a name at 160 UTF-8 bytes.
var LABEL_BYTES = 160;
var REGION_NAMES = { HK: '香港', TW: '台湾', JP: '日本', SG: '新加坡', US: '美国', KR: '韩国', GB: '英国', DE: '德国',
	FR: '法国', AU: '澳大利亚', CA: '加拿大', NL: '荷兰', IN: '印度', ES: '西班牙', IT: '意大利', CH: '瑞士', SE: '瑞典',
	FI: '芬兰', IE: '爱尔兰', NO: '挪威', NZ: '新西兰', BR: '巴西', TR: '土耳其', RU: '俄罗斯', MY: '马来西亚', TH: '泰国',
	VN: '越南', PH: '菲律宾', ID: '印尼', AR: '阿根廷', MO: '澳门', AE: '阿联酋', CN: '中国', '?': '其他' };
// Words win over the flag: some subscriptions put another flag on Taiwan nodes. Longer words first.
var REGION_WORDS = [['香港', 'HK'], ['台湾', 'TW'], ['臺灣', 'TW'], ['日本', 'JP'], ['东京', 'JP'], ['大阪', 'JP'],
	['新加坡', 'SG'], ['狮城', 'SG'], ['美国', 'US'], ['洛杉矶', 'US'], ['硅谷', 'US'], ['韩国', 'KR'], ['首尔', 'KR'],
	['英国', 'GB'], ['伦敦', 'GB'], ['德国', 'DE'], ['法国', 'FR'], ['加拿大', 'CA'], ['澳大利亚', 'AU'], ['澳洲', 'AU'],
	['荷兰', 'NL'], ['印度尼西亚', 'ID'], ['印尼', 'ID'], ['印度', 'IN'], ['土耳其', 'TR'], ['俄罗斯', 'RU'],
	['马来西亚', 'MY'], ['泰国', 'TH'], ['越南', 'VN'], ['菲律宾', 'PH'], ['阿根廷', 'AR'], ['澳门', 'MO']];
// Verdicts about the node itself (VERDICT_ERRORS in the backend); other errors say nothing about it.
var VERDICTS = ['UNSUPPORTED_REGION', 'REGION_CHANGED', 'TLS_FAILED', 'TRACE_FAILED', 'API_UNAVAILABLE', 'SITE_FAILED', 'NODE_DEPENDENCY'];
var BENCH_ERRORS = { UNSUPPORTED_REGION: '地区不支持', REGION_CHANGED: '三轮地区不一致', SOURCE_CHANGED: '订阅已更新，请重新测速',
	BENCH_INTERRUPTED: '测速中断，请重测', CORE_MISSING: '测速暂不可用', CORE_START_FAILED: '测速启动失败',
	CORE_NOT_READY: '测速服务未就绪', TLS_FAILED: '连接失败', TRACE_FAILED: '地区验证失败', API_UNAVAILABLE: '服务连接失败',
	SITE_FAILED: '网站打不开', PROBE_FAILED: '连接失败', NODE_DEPENDENCY: '依赖其他代理，不能单独使用',
	BENCH_BUSY: '另一个测速正在进行，请稍后再试', NODE_MISSING: '节点已不在订阅里' };
var RULE_ERRORS = { NODE_MISSING: '节点已不在订阅里，请换节点。', NODE_CHANGED: '节点参数变了，请重新测速或换节点。',
	BENCHMARK_REQUIRED: '节点验证已失效，请重新测速或换节点。', NODE_DEPENDENCY: '节点依赖其他代理，请换节点。',
	SOURCE_MISSING: '订阅文件不在了，请换节点。', SOURCE_INVALID: '订阅文件名无效，请换节点。',
	SOURCE_YAML_INVALID: '订阅文件无法解析。', SOURCE_NODES_INVALID: '订阅里的节点列表无效。',
	STATE_MISMATCH: '运行配置与设置不一致，可再保存一次或恢复原分流。',
	CONTROLLER_UNAVAILABLE: '读不到 OpenClash 控制接口，OpenClash 可能没在运行。',
	RUNTIME_MISSING: '没找到 OpenClash 运行配置。', ROUTING_MODE_UNSUPPORTED: 'OpenClash 不是规则模式，分流无法生效。' };
var STEAM_HINT = 'Steam 联机（Valve 服务器和中继 IP）、登录接口、下载走直连，不经过代理节点；商店和社区网页不变。';
// Subscriptions list their quota and expiry as fake proxies (on .242: 「剩余流量：1017.5 GB」).
var INFO_RE = /剩余流量|套餐到期|到期时间|过期时间|下次重置|流量重置|官网|官方网站|traffic|expire/i;
var ORDER = { ok: 0, untested: 1, failed: 2, info: 3, blocked: 4 };

function has(map, key) {
	return Object.prototype.hasOwnProperty.call(map, key);
}

// 网站名、节点名、域名都按文本插入，禁止作为 HTML 解释（LuCI 的 E() 会把字符串子节点当 HTML）。
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

function setState(node, state) {
	var cls = 'r3cg-state ' + state.cls;
	if (node.textContent === state.text && node.className === cls) return;
	clear(node).appendChild(el('span', { 'class': 'r3cg-dot', 'aria-hidden': 'true' }));
	node.appendChild(document.createTextNode(state.text));
	node.className = cls;
}

function parseResult(res) {
	var data;
	try { data = JSON.parse(res && res.stdout || ''); }
	catch (e) {
		throw new Error(res && res.code !== 0 ? '操作失败，请刷新后重试。' : '返回内容无法读取，请刷新后重试。');
	}
	if (!res || res.code !== 0 || !data || data.ok !== true) {
		var error = new Error(data && typeof data.message === 'string' && data.message || '操作失败，请刷新后重试。');
		error.token = data && typeof data.error === 'string' ? data.error : '';
		throw error;
	}
	return data;
}

function permissionDenied(e) {
	return /permission|access denied|拒绝/i.test(e && e.message || '');
}

function errorText(e) {
	if (permissionDenied(e)) return '当前会话没有操作权限，请退出 LuCI 后重新登录。';
	var msg = e && e.message || '';
	return /[㐀-鿿]/.test(msg) ? msg : '无法读取路由器响应，请检查连接后刷新。';
}

function statusErrorText(st) {
	if (!st || !st.error) return '';
	if (has(RULE_ERRORS, st.error)) return RULE_ERRORS[st.error];
	if (typeof st.message === 'string' && /[㐀-鿿]/.test(st.message)) return st.message;
	return '分流状态异常，请刷新或恢复原分流。';
}

function ruleErrorText(token) {
	return has(RULE_ERRORS, token) ? RULE_ERRORS[token] : '这条规则状态异常，请重新保存或换节点。';
}

function benchError(token) {
	return has(BENCH_ERRORS, token) ? BENCH_ERRORS[token] : '测速未通过';
}

function isSource(s) {
	return typeof s === 'string' && s.length > 0 && s.length <= 255 && !/[\/\\\x00-\x1f]/.test(s) && s !== '.' && s !== '..';
}

function rulesOf(rules) {
	return (Array.isArray(rules) ? rules : []).filter(function(r) {
		return r && /^[a-f0-9]{12}$/.test(r.id) && Array.isArray(r.domains);
	});
}

function nodesOf(nodes) {
	return (Array.isArray(nodes) ? nodes : []).filter(function(n) {
		return n && /^[a-f0-9]{16}$/.test(n.id) && typeof n.name === 'string' && n.name.length > 0;
	});
}

function titleOf(rule) {
	return rule.label || rule.domains[0] || '未命名网站';
}

function shortDomains(domains) {
	return domains.slice(0, 3).join('、') + (domains.length > 3 ? ' 等 ' + domains.length + ' 个' : '');
}

function utf8Length(text) {
	var n = 0;
	for (var i = 0; i < text.length; i++) {
		var c = text.charCodeAt(i);
		if (c < 0x80) n += 1;
		else if (c < 0x800) n += 2;
		else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++; }
		else n += 3;
	}
	return n;
}

// Same rules as normalize_domain in r3mini-chatgpt.rb; the router stays authoritative.
function normalizeDomain(value) {
	if (typeof value !== 'string' || value.length > 2048) return null;
	var v = value.trim().toLowerCase();
	if (/^https?:\/\//.test(v)) v = v.replace(/^https?:\/\//, '').split(/[\/?#]/)[0];
	v = v.replace(/^\*\./, '').replace(/\.$/, '');
	var labels = v.split('.'), tld = labels[labels.length - 1];
	if (v.length < 4 || v.length > 253 || labels.length < 2 || !/[a-z]/.test(tld) || tld.length < 2) return null;
	return labels.every(function(l) { return l.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(l); }) ? v : null;
}

function flagCode(name) {
	var cps = Array.from(String(name || '')).slice(0, 2).map(function(c) { return c.codePointAt(0); });
	return cps.length === 2 && cps.every(function(c) { return c >= 0x1f1e6 && c <= 0x1f1ff; }) ?
		String.fromCharCode(cps[0] - 0x1f1e6 + 65, cps[1] - 0x1f1e6 + 65) : '';
}

function regionOf(name) {
	var text = String(name || '');
	for (var i = 0; i < REGION_WORDS.length; i++)
		if (text.indexOf(REGION_WORDS[i][0]) >= 0) return REGION_WORDS[i][1];
	return flagCode(text);
}

// Windows draws a flag as two letters; the region tag already says where the node is.
function displayName(name) {
	var text = String(name || '');
	return flagCode(text) ? Array.from(text).slice(2).join('').trim() || text : text;
}

// MESL lists 91 regions (2026-11-24); the browser names the ones the table above leaves out.
var REGION_NAMER = null;
try { REGION_NAMER = new Intl.DisplayNames(['zh-CN'], { type: 'region' }); } catch (e) {}

function regionName(code) {
	if (has(REGION_NAMES, code)) return REGION_NAMES[code];
	try {
		var name = code && REGION_NAMER ? REGION_NAMER.of(code) : '';
		if (name && name !== code) return name;
	} catch (e) {}
	return code || REGION_NAMES['?'];
}

function latency(ms) {
	return typeof ms === 'number' && isFinite(ms) && ms > 0 ? Math.round(ms) + ' ms' : '';
}

function ago(iso, now) {
	var seconds = (now - (typeof iso === 'string' ? Date.parse(iso) : NaN)) / 1000;
	if (!isFinite(seconds)) return '';
	if (seconds < 60) return '刚刚';
	if (seconds < 3600) return Math.floor(seconds / 60) + ' 分钟前';
	if (seconds < 86400) return Math.floor(seconds / 3600) + ' 小时前';
	return Math.floor(seconds / 86400) + ' 天前';
}

function steamOf(st) {
	var steam = st && st.steam_direct;
	return steam && typeof steam.enabled === 'boolean' && typeof steam.applied === 'boolean' ? steam : null;
}

function steamState(steam) {
	if (!steam) return { text: '状态待确认', cls: 'bad' };
	if (steam.enabled && steam.applied) return { text: '已生效', cls: 'ok' };
	if (steam.enabled) return { text: '开启了但配置里没找到——重新打开一次', cls: 'bad' };
	return { text: '未生效', cls: '' };
}

function ruleState(rule, pending) {
	if (pending) return { text: '待启动生效', cls: 'warn' };
	if (rule.error || rule.enabled && !rule.applied || rule.applied && !rule.enabled) return { text: '异常', cls: 'bad' };
	return rule.enabled ? { text: '已生效', cls: 'ok' } : { text: '已停用', cls: '' };
}

// ok: has current proof; untested: no verdict yet (or only an outdated one); failed: a verdict
// against the node; info: a subscription notice posing as a node; blocked: the node cannot run
// alone (dialer-proxy).
function nodeState(n) {
	if (n.dependent || n.error === 'NODE_DEPENDENCY') return 'blocked';
	if (n.eligible) return 'ok';
	if (INFO_RE.test(n.name)) return 'info';
	if (VERDICTS.indexOf(n.error) >= 0) return 'failed';
	if (!n.error && !n.stale && n.samples_ms.length) return 'failed';
	return 'untested';
}

function benchOf(b) {
	b = b && typeof b === 'object' ? b : {};
	return { running: b.running === true, done: Math.max(0, Number(b.done) || 0), total: Math.max(0, Number(b.total) || 0),
		run_ids: Array.isArray(b.run_ids) ? b.run_ids : [], finished_at: b.finished_at,
		error: typeof b.error === 'string' ? b.error : '' };
}

var CSS = [
	'.r3cg{max-width:1080px;line-height:1.5}.r3cg *,.r3cg-modal *{box-sizing:border-box}',
	'.r3cg [hidden],.r3cg-modal [hidden]{display:none!important}',
	'.r3cg-statusbar,.r3cg-actions,.r3cg-toolbar{display:flex;align-items:center;flex-wrap:wrap;gap:.6rem}',
	'.r3cg-statusbar{gap:.4rem 1rem;padding:0 1.25rem}.r3cg-statusbar .cbi-button{margin-left:auto}.r3cg h3{margin:0}',
	'.r3cg-active{font-size:.9em;opacity:.8;overflow-wrap:anywhere}',
	'.r3cg-modal select.r3cg-more{display:inline-block;width:auto;max-width:100%;min-height:1.9rem;font-size:.9em}',
	// argon keeps button text on one line; long labels must wrap on phones with large text.
	'.r3cg .cbi-button,.r3cg-modal .cbi-button{white-space:normal;max-width:100%}',
	'.r3cg-state{display:inline-flex;align-items:center;gap:.4rem;font-size:.9em;font-weight:600}',
	'.r3cg-dot{height:.6rem;width:.6rem;border-radius:50%;background:#707a83;flex:none}',
	'.r3cg-state.ok .r3cg-dot{background:#24904e}.r3cg-state.bad .r3cg-dot{background:#c84343}.r3cg-state.warn .r3cg-dot{background:#b07800}',
	'.r3cg-steam{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:.5rem 1rem;',
	'border:1px solid #8885;border-radius:6px;padding:.75rem 1rem;margin:0 0 1rem}',
	'.r3cg-steam-main{display:flex;align-items:center;gap:.75rem;min-width:0}.r3cg-steam .r3cg-hint{flex-basis:100%;margin:0}',
	// A button, not a checkbox: argon forces every checkbox to a 1rem tick box with !important.
	'.r3cg button.r3cg-switch{-webkit-appearance:none;appearance:none;position:relative;display:inline-block;flex:none;',
	'width:2.75rem;min-width:2.75rem;height:1.5rem;min-height:0;margin:0;padding:0;border:0;border-radius:.75rem;',
	'background:#8a939b;background-image:none;box-shadow:none;cursor:pointer;vertical-align:middle;transition:background-color .15s}',
	'.r3cg button.r3cg-switch>span{position:absolute;top:.1875rem;left:.1875rem;width:1.125rem;height:1.125rem;border-radius:50%;',
	'background:#fff;box-shadow:0 1px 2px #0005;transition:transform .15s}',
	'.r3cg button.r3cg-switch.on{background:#24904e}.r3cg button.r3cg-switch.on>span{transform:translateX(1.25rem)}',
	'.r3cg button.r3cg-switch:disabled{opacity:.5;cursor:default}.r3cg-switch-label{font-weight:600;font-size:1.05em;cursor:pointer}',
	'.r3cg-list{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,19rem),1fr));gap:1rem;margin:1rem 0}',
	'.r3cg-rule{display:flex;flex-direction:column;gap:.3rem;border:1px solid #8885;border-radius:6px;padding:.9rem 1rem;min-width:0}',
	'.r3cg-rule.off{opacity:.8}.r3cg-rule-head{display:flex;justify-content:space-between;align-items:flex-start;gap:.5rem}',
	// argon draws every h3 as a padded white panel title with line-height:1.1 !important.
	'.r3cg .r3cg-rule h3{display:block;width:auto;margin:0;padding:0;border:0;border-radius:0;background:none;box-shadow:none;',
	'color:inherit;font-size:1.05em;font-weight:600;line-height:1.4!important;overflow-wrap:anywhere;min-width:0}',
	'.r3cg-rule p{margin:0;overflow-wrap:anywhere}.r3cg-state{white-space:nowrap}',
	'.r3cg-node{font-weight:600}.r3cg-domains,.r3cg-source{font-size:.9em;opacity:.8}',
	'.r3cg-rule .r3cg-actions{margin-top:auto;padding-top:.5rem;gap:.5rem}',
	'.r3cg-hint{font-size:.9em;opacity:.85;margin:.3rem 0 0;overflow-wrap:anywhere}.r3cg-hint:empty{display:none}',
	'.r3cg .r3cg-hint.bad,.r3cg-modal .r3cg-hint.bad{color:#c84343;opacity:1}',
	'.r3cg-message{margin:.75rem 0;padding:.6rem .85rem;border:1px solid #8885;border-left-width:4px;border-radius:4px;overflow-wrap:anywhere}',
	'.r3cg-message.bad{border-color:#c84343}.r3cg-message.ok{border-color:#24904e}.r3cg-message.warn{border-color:#b07800}',
	'.r3cg-message:empty{display:none}.r3cg-note,.r3cg-empty{font-size:.9em;opacity:.8;margin:1rem 0;overflow-wrap:anywhere}',
	'.r3cg-footer{display:flex;align-items:center;flex-wrap:wrap;gap:.75rem;margin-top:1.5rem;padding-top:1rem;border-top:1px solid #8884}',
	'.r3cg-footer .r3cg-note{margin:0;flex:1 1 16rem}',
	'.r3cg button:focus-visible,.r3cg-modal button:focus-visible,.r3cg-modal input:focus-visible,.r3cg-modal textarea:focus-visible,',
	'.r3cg-modal select:focus-visible{outline:2px solid currentColor;outline-offset:2px}',
	'.modal.r3cg-modal{width:96%;max-width:46rem;margin:2rem auto;align-items:stretch}',
	'.r3cg-dialog{display:flex;flex-direction:column;gap:.75rem;min-width:0;line-height:1.5}.r3cg-dialog p{margin:0}',
	'.r3cg-fields{display:grid;grid-template-columns:minmax(0,1fr);gap:.75rem}.r3cg-field{min-width:0}',
	'.r3cg-modal label{display:block;font-weight:600;margin-bottom:.3rem}',
	'.r3cg-modal input[type=text],.r3cg-modal input[type=search],.r3cg-modal textarea,.r3cg-modal select{display:block;width:100%;max-width:100%;min-width:0}',
	'.r3cg-modal textarea{min-height:5.5rem;resize:vertical}',
	'.r3cg-picker{display:flex;flex-direction:column;gap:.5rem;min-width:0}',
	'.r3cg-picker-head{display:grid;grid-template-columns:minmax(0,1fr);gap:.5rem}',
	'.r3cg-chips{display:flex;flex-wrap:wrap;gap:.35rem}',
	'.r3cg-modal button.r3cg-chip{-webkit-appearance:none;appearance:none;margin:0;padding:.15rem .65rem;min-height:1.9rem;height:auto;',
	'border:1px solid #8886;border-radius:999px;background:transparent;background-image:none;color:inherit;font:inherit;',
	'font-size:.9em;line-height:1.4;box-shadow:none;cursor:pointer}',
	'.r3cg-modal button.r3cg-chip[aria-pressed=true]{background:#24904e;border-color:#24904e;color:#fff}',
	'.r3cg-nodes{max-height:min(46vh,24rem);overflow-y:auto;border:1px solid #8885;border-radius:6px}',
	'.r3cg-modal button.r3cg-row{-webkit-appearance:none;appearance:none;display:grid;grid-template-columns:3.5rem minmax(0,1fr) auto;',
	'grid-template-areas:"region name result" "region type result";align-items:center;column-gap:.6rem;width:100%;',
	'margin:0;padding:.45rem .7rem;min-height:0;height:auto;border:0;border-bottom:1px solid #8883;border-radius:0;',
	'background:transparent;background-image:none;box-shadow:none;color:inherit;font:inherit;line-height:1.4;',
	'text-align:left;text-transform:none;letter-spacing:normal;cursor:pointer}',
	'.r3cg-modal button.r3cg-row:last-child{border-bottom:0}.r3cg-modal button.r3cg-row:hover{background:#8881}',
	'.r3cg-modal button.r3cg-row.picked{background:#24904e22;box-shadow:inset 4px 0 0 #24904e}',
	'.r3cg-modal button.r3cg-row:disabled{cursor:default;opacity:.55}',
	'.r3cg-region{grid-area:region;font-size:.85em;opacity:.8}.r3cg-name{grid-area:name;font-weight:600;overflow-wrap:anywhere;min-width:0}',
	'.r3cg-type{grid-area:type;font-size:.8em;opacity:.65}.r3cg-result{grid-area:result;font-size:.9em;text-align:right;white-space:nowrap}',
	'.r3cg-row.ok .r3cg-result{color:#24904e;font-weight:600}.r3cg-row.failed .r3cg-result,.r3cg-row.blocked .r3cg-result{color:#c84343}',
	'.r3cg-modal progress{display:block;width:100%;height:.5rem}.r3cg-picked{font-weight:600;overflow-wrap:anywhere}',
	'.r3cg-picker>.cbi-button{align-self:flex-start}',
	'.r3cg-modal .right{display:flex;justify-content:flex-end;flex-wrap:wrap;gap:.5rem}',
	'@media(min-width:36rem){.r3cg-picker-head{grid-template-columns:minmax(0,1fr) minmax(0,1.4fr)}}',
	// Phones: the name already says the region, so its column goes and the result stays on the right.
	'@media(max-width:30rem){.r3cg-modal button.r3cg-row{grid-template-columns:minmax(0,1fr) auto;',
	'grid-template-areas:"name result" "type result"}.r3cg-region{display:none}',
	'.r3cg-rule .r3cg-actions button{flex:1 1 auto}.modal.r3cg-modal{margin:.5rem auto;width:98%}}',
	'@media(prefers-reduced-motion:reduce){.r3cg button.r3cg-switch,.r3cg button.r3cg-switch>span{transition:none}}'
].join('');

return view.extend({
	load: function() {
		return fs.exec(CLI, ['summary']).then(parseResult).then(function(st) { return { status: st }; })
			.catch(function(e) { return { error: errorText(e) }; });
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	now: function() { return Date.now(); },
	later: function(fn, ms) { return setTimeout(fn, ms); },
	cancel: function(id) { clearTimeout(id); },

	render: function(data) {
		var self = this;
		this.status = null;
		this.statusError = data.error || '';
		this.rules = [];
		this.sources = [];
		this.mutating = false;
		this.busyId = '';
		this.reading = false;
		this.foreground = false;
		this.readSerial = 0;
		this.lastRead = 0;
		this.notice = '';
		this.noticeTone = '';
		this.dlg = null;
		this.steamTarget = false;
		this.steamOn = false;
		this.ruleButtons = [];
		this.root = el('div', { 'class': 'r3cg' }, el('style', {}, CSS));
		this.badge = el('span', { 'class': 'r3cg-state', 'role': 'status', 'aria-live': 'polite' });
		this.activeInfo = el('span', { 'class': 'r3cg-active' });
		// LuCI already shows its own 「刷新」 poll switch in the header; this one reads at once.
		this.refreshBtn = this.button('立即刷新', 'neutral', function() { return self.refresh(true); });
		// Standard LuCI layout: argon draws a lone h2 as the title card over its blue header band,
		// so status and buttons go below it, on the page background.
		this.root.appendChild(el('h2', { 'name': 'content' }, '网站分流'));
		this.root.appendChild(el('div', { 'class': 'cbi-map-descr' }, '给指定网站单独选一个出口节点；其他流量照旧走 OpenClash 原有规则。'));
		this.root.appendChild(el('div', { 'class': 'r3cg-statusbar' }, [this.badge, this.activeInfo, this.refreshBtn]));
		this.steamSwitch = el('button', { 'type': 'button', 'role': 'switch', 'class': 'r3cg-switch', 'id': 'r3cg-steam',
			'aria-checked': 'false', 'aria-labelledby': 'r3cg-steam-label', 'aria-describedby': 'r3cg-steam-state r3cg-steam-hint',
			'click': function() { return self.toggleSteam(!self.steamOn); } }, el('span', { 'aria-hidden': 'true' }));
		this.steamState = el('span', { 'class': 'r3cg-state', 'id': 'r3cg-steam-state', 'role': 'status', 'aria-live': 'polite' });
		this.steamCard = this.root.appendChild(el('section', { 'class': 'r3cg-steam', 'aria-label': 'Steam 直连' }, [
			el('div', { 'class': 'r3cg-steam-main' }, [this.steamSwitch, el('span', { 'class': 'r3cg-switch-label', 'id': 'r3cg-steam-label',
				'click': function() { return self.toggleSteam(!self.steamOn); } }, 'Steam 直连')]),
			this.steamState,
			el('p', { 'class': 'r3cg-hint', 'id': 'r3cg-steam-hint' }, STEAM_HINT)
		]));
		this.addBtn = this.button('添加网站', 'add', function() { return self.openEditor(null, false, false); });
		this.presetBtn = this.button('ChatGPT 预设', 'neutral', function() { return self.openEditor(null, true, false); });
		this.root.appendChild(el('div', { 'class': 'r3cg-actions' }, [this.addBtn, this.presetBtn]));
		this.message = this.root.appendChild(el('p', { 'class': 'r3cg-message', 'role': 'status', 'aria-live': 'polite' }));
		this.list = this.root.appendChild(el('div', { 'class': 'r3cg-list', 'aria-label': '网站分流规则' }));
		this.disableBtn = this.button('恢复原分流', 'reset', function() { return self.confirmDisable(); });
		this.root.appendChild(el('div', { 'class': 'r3cg-footer' }, [this.disableBtn, el('p', { 'class': 'r3cg-note' },
			'域名规则同时覆盖子域名。恢复原分流会停用全部网站规则（规则保留）并关闭 Steam 直连，OpenClash 原有分流不受影响。')]));
		if (data.status) this.acceptStatus(data.status);
		else this.renderRules();
		this.sync();
		poll.add(function() { return self.idleRefresh(); }, IDLE_POLL);
		if (typeof document.addEventListener === 'function')
			document.addEventListener('visibilitychange', function() { if (!document.hidden) self.idleRefresh(); });
		return this.root;
	},

	button: function(text, kind, click) {
		return el('button', { 'type': 'button', 'class': 'cbi-button cbi-button-' + kind, 'click': click }, text);
	},

	ruleById: function(id) {
		return this.rules.filter(function(r) { return r.id === id; })[0] || null;
	},

	// LuCI code elsewhere (session expiry, another view) may close the shared modal.
	dialogOpen: function() {
		var body = document.body;
		if (this.dlg && body && body.classList && !body.classList.contains('modal-overlay-active')) {
			this.cancelTimer(this.dlg, 'timer');
			this.cancelTimer(this.dlg, 'targetTimer');
			this.dlg = null;
		}
		return !!this.dlg;
	},

	cancelTimer: function(d, key) {
		if (d && d[key] != null) {
			this.cancel(d[key]);
			d[key] = null;
		}
	},

	idleRefresh: function() {
		if (this.mutating || this.reading || this.dialogOpen() || document.hidden || this.now() - this.lastRead < FRESH_MS)
			return Promise.resolve(false);
		return this.refresh(false);
	},

	refresh: function(manual) {
		if (this.mutating || this.reading && !manual) return Promise.resolve(false);
		var self = this, serial = ++this.readSerial;
		this.reading = true;
		this.foreground = !!manual;
		if (manual) { this.notice = ''; this.noticeTone = ''; }
		this.sync();
		return fs.exec(CLI, ['summary']).then(parseResult).then(function(st) {
			if (serial !== self.readSerial) return false;
			self.acceptStatus(st);
			return true;
		}).catch(function(e) {
			if (serial === self.readSerial) {
				self.statusError = errorText(e);
				self.lastRead = self.now();
				self.renderRules();
			}
			return false;
		}).then(function(ok) {
			if (serial === self.readSerial) {
				self.reading = false;
				self.foreground = false;
				self.sync();
			}
			return ok;
		});
	},

	acceptStatus: function(st) {
		this.status = st;
		this.statusError = '';
		this.lastRead = this.now();
		this.sources = (Array.isArray(st.sources) ? st.sources : []).filter(isSource);
		this.rules = rulesOf(Array.isArray(st.rules) ? st.rules : st.site_rules);
		this.renderRules();
		if (this.dlg && this.dlg.el && this.dlg.kind !== 'confirm') {
			this.renderSources();
			this.syncDialog();
		}
	},

	renderRules: function() {
		var self = this;
		clear(this.list);
		this.ruleButtons = [];
		if (!this.rules.length) {
			this.list.appendChild(el('p', { 'class': 'r3cg-empty' }, this.statusError ?
				'规则暂时无法读取，请刷新重试。' : '还没有网站规则。可以添加自定义网站，或用 ChatGPT 预设。'));
			return;
		}
		this.rules.forEach(function(rule) { self.list.appendChild(self.card(rule)); });
	},

	card: function(rule) {
		var self = this, name = titleOf(rule), busy = this.mutating && this.busyId === rule.id;
		var state = busy ? { text: '正在应用…', cls: 'warn' } : this.statusError ? { text: '状态待确认', cls: 'bad' } :
			ruleState(rule, this.status && this.status.pending_restart);
		var badge = el('span', { 'class': 'r3cg-state ' + state.cls }, [el('span', { 'class': 'r3cg-dot', 'aria-hidden': 'true' }), state.text]);
		var change = this.button('换节点', 'action', function() { return self.openEditor(rule, false, true); });
		var edit = this.button('编辑', 'neutral', function() { return self.openEditor(rule, false, false); });
		var toggle = this.button(rule.enabled ? '停用' : '启用', 'neutral', function() { return self.mutate('set-enabled', rule.id, !rule.enabled); });
		var remove = this.button('删除', 'remove', function() { return self.confirmRemove(rule); });
		[change, edit, toggle, remove].forEach(function(b) {
			b.setAttribute('aria-label', b.textContent + '：' + name);
			self.ruleButtons.push(b);
		});
		return el('article', { 'class': 'r3cg-rule' + (rule.enabled ? '' : ' off') }, [
			el('div', { 'class': 'r3cg-rule-head' }, [el('h3', {}, name), badge]),
			el('p', { 'class': 'r3cg-domains', 'title': rule.domains.join('\n') }, shortDomains(rule.domains)),
			el('p', { 'class': 'r3cg-node' }, this.nodeLine(rule)),
			el('p', { 'class': 'r3cg-source' }, '订阅：' + (rule.source || '未指定') + (rule.source && rule.source === this.activeSource() ? '（当前配置）' : '')),
			rule.enabled && rule.error && !this.statusError ? el('p', { 'class': 'r3cg-hint bad' }, ruleErrorText(rule.error)) : null,
			el('div', { 'class': 'r3cg-actions' }, [change, edit, toggle, remove])
		]);
	},

	nodeLine: function(rule) {
		var parts = [displayName(rule.selected_name) || '节点名称不可用'];
		if (typeof rule.median_ms === 'number' && rule.median_ms > 0) {
			parts.push(latency(rule.median_ms));
			var when = ago(rule.tested_at, this.now());
			if (when) parts.push(when + '测');
		}
		else parts.push(rule.unverified ? '未测速（未验证）' : '未测速');
		return parts.join(' · ');
	},

	sync: function() {
		var st = this.status, unavailable = !st || !!this.statusError, busy = !!this.mutating;
		var bad = unavailable || !!st.error || st.enabled === true && st.applied !== true && !st.pending_restart;
		setState(this.badge, busy ? { text: '正在应用…', cls: 'warn' } : bad ? { text: '异常', cls: 'bad' } :
			st.pending_restart ? { text: '待启动生效', cls: 'warn' } : st.enabled ? { text: '已生效', cls: 'ok' } : { text: '未启用', cls: '' });
		var steam = steamOf(st), steamBusy = this.mutating === 'steam-direct';
		setState(this.steamState, steamBusy ? { text: this.steamTarget ? '正在开启…' : '正在关闭…', cls: 'warn' } :
			unavailable ? { text: '状态待确认', cls: 'bad' } : steamState(steam));
		// The switch shows the effective state, so a saved-but-missing block reads as off.
		this.steamOn = steamBusy ? this.steamTarget : !!(steam && steam.enabled && steam.applied);
		this.steamSwitch.setAttribute('aria-checked', this.steamOn ? 'true' : 'false');
		this.steamSwitch.className = 'r3cg-switch' + (this.steamOn ? ' on' : '');
		this.steamSwitch.disabled = busy || unavailable || !steam;
		this.addBtn.disabled = this.presetBtn.disabled = busy || unavailable;
		this.presetBtn.hidden = this.rules.some(function(r) { return r.preset === 'chatgpt'; });
		this.disableBtn.disabled = busy || !st || (!st.enabled && !st.applied && !st.error && !this.rules.some(function(r) { return r.enabled; }) &&
			!(steam && (steam.enabled || steam.applied)));
		this.disableBtn.textContent = this.mutating === 'disable' ? '正在恢复…' : '恢复原分流';
		this.refreshBtn.disabled = busy || this.reading;
		this.refreshBtn.textContent = this.reading && this.foreground ? '读取中…' : '立即刷新';
		this.activeInfo.textContent = st && isSource(st.active_source) ? 'OpenClash 当前配置：' + st.active_source : '';
		this.ruleButtons.forEach(function(b) { b.disabled = busy || unavailable; });
		this.root.setAttribute('aria-busy', busy || this.reading && this.foreground ? 'true' : 'false');
		var err = this.statusError || statusErrorText(st);
		var pending = st && st.pending_restart ? '已保存，等待 OpenClash 启动后生效。' : '';
		this.message.textContent = this.notice || err || pending;
		this.message.className = 'r3cg-message' + (this.notice ? ' ' + this.noticeTone : err ? ' bad' : pending ? ' warn' : '');
		this.message.setAttribute('role', this.noticeTone === 'bad' || (!this.notice && err) ? 'alert' : 'status');
	},

	// OpenClash's current config; null when unknown (older backend, uci unreadable).
	activeSource: function() {
		var st = this.status;
		return st && this.sources.indexOf(st.active_source) >= 0 ? st.active_source : null;
	},

	defaultSource: function() {
		var st = this.status, s = this.sources;
		if (this.activeSource()) return this.activeSource();
		if (st && s.indexOf(st.source) >= 0) return st.source;
		return s.indexOf(DEFAULT_SOURCE) >= 0 ? DEFAULT_SOURCE : s[0] || '';
	},

	domainLines: function(text) {
		return text.split(/\r?\n/).map(function(s) { return s.trim(); }).filter(function(s) { return !!s; });
	},

	// The ChatGPT preset is measured against chatgpt.com; any other site against its first domain.
	targetOf: function(d) {
		if (d.preset === 'chatgpt') return 'chatgpt';
		var first = d.kind === 'node' ? d.rule.domains[0] : normalizeDomain(this.domainLines(d.domainsText)[0] || '');
		return first ? 'site:' + first : '';
	},

	domainCheck: function() {
		var d = this.dlg, raw = d.domainsText.split(/\r?\n/), out = [], bad = [], count = 0;
		raw.forEach(function(line, i) {
			if (!line.trim()) return;
			count++;
			var n = normalizeDomain(line);
			if (!n) bad.push(i + 1);
			else if (out.indexOf(n) < 0) out.push(n);
		});
		if (!count) return { ok: false, empty: true, text: '一行一个域名，也可以直接粘贴网址。', domains: [] };
		if (bad.length) return { ok: false, text: '第 ' + bad.join('、') + ' 行不是有效的域名或网址。', domains: out };
		if (count > 30) return { ok: false, text: '一条规则最多 30 个域名。', domains: out };
		var clash = this.overlap(out, d.preset, d.rule && d.rule.id);
		if (clash) return { ok: false, domains: out,
			text: clash.mine + ' 与规则「' + titleOf(clash.rule) + '」的 ' + clash.theirs + ' 重叠，同一个网站只能归一条规则。' };
		return { ok: true, text: '将匹配：' + out.join('、') + '，含子域名。', domains: out };
	},

	// Same test as check_domains on the router: equal, or one is a subdomain of the other.
	overlap: function(domains, preset, selfId) {
		function setOf(list, p) {
			return p === 'chatgpt' ? list.concat(PRESET_BUILTIN.filter(function(x) { return list.indexOf(x) < 0; })) : list;
		}
		function hit(a, b) {
			return a === b || a.slice(-(b.length + 1)) === '.' + b || b.slice(-(a.length + 1)) === '.' + a;
		}
		var mine = setOf(domains, preset);
		for (var i = 0; i < this.rules.length; i++) {
			var rule = this.rules[i];
			if (rule.id === selfId) continue;
			var theirs = setOf(rule.domains, rule.preset);
			for (var j = 0; j < mine.length; j++)
				for (var k = 0; k < theirs.length; k++)
					if (hit(mine[j], theirs[k])) return { rule: rule, mine: mine[j], theirs: theirs[k] };
		}
		return null;
	},

	openEditor: function(rule, preset, nodeOnly) {
		if (this.mutating || this.dialogOpen() || !this.status || this.statusError) return false;
		var self = this, d = {
			kind: nodeOnly && rule ? 'node' : 'edit', rule: rule || null,
			preset: rule ? rule.preset || '' : preset ? 'chatgpt' : '',
			label: rule ? rule.label || '' : preset ? 'ChatGPT' : '',
			domainsText: rule ? rule.domains.join('\n') : preset ? CHATGPT_DOMAINS.join('\n') : '',
			source: rule ? rule.source : this.defaultSource(), selected: rule ? rule.selected || '' : '',
			target: '', nodes: [], bench: null, nodesKey: '', serial: 0, loading: false, loadError: '',
			query: '', region: '', showFailed: false, starting: false, timer: null, targetTimer: null,
			benchNotice: '', message: '', tone: '', dirty: false, el: null
		};
		d.target = this.targetOf(d);
		this.dlg = d;
		var p = d.el = {}, parts = [];
		if (d.kind === 'node') {
			parts.push(el('p', {}, [el('strong', {}, titleOf(rule)), ' · ' + shortDomains(rule.domains)]));
		}
		else {
			p.domains = el('textarea', { 'id': 'r3cg-domains', 'rows': 4, 'spellcheck': 'false', 'aria-describedby': 'r3cg-domain-hint',
				'placeholder': 'example.com\nhttps://example.org/path', 'input': function(ev) { self.setDomains(ev.target.value); } });
			p.domains.value = d.domainsText;
			p.preview = el('p', { 'class': 'r3cg-hint', 'id': 'r3cg-domain-hint', 'aria-live': 'polite' });
			p.label = el('input', { 'id': 'r3cg-label', 'type': 'text', 'maxlength': 80, 'autocomplete': 'off', 'aria-describedby': 'r3cg-label-hint',
				'input': function(ev) { d.label = ev.target.value; d.dirty = true; self.syncDialog(); } });
			p.label.value = d.label;
			p.labelHint = el('p', { 'class': 'r3cg-hint', 'id': 'r3cg-label-hint', 'aria-live': 'polite' });
			parts.push(el('div', { 'class': 'r3cg-fields' }, [
				el('div', { 'class': 'r3cg-field' }, [el('label', { 'for': 'r3cg-domains' }, '网站域名或网址'), p.domains, p.preview]),
				el('div', { 'class': 'r3cg-field' }, [el('label', { 'for': 'r3cg-label' }, '名称（可不填）'), p.label, p.labelHint])
			]));
		}
		parts.push(this.buildPicker(d));
		p.message = el('p', { 'class': 'r3cg-message', 'role': 'status', 'aria-live': 'polite' });
		parts.push(p.message);
		// LuCI's Escape handler clicks the first button under .right, so Cancel goes first.
		p.cancel = this.button('取消', 'neutral', function() { return self.closeDialog(); });
		p.save = this.button('保存', 'apply', function() { return self.saveDialog(); });
		ui.showModal(d.kind === 'node' ? '换节点' : rule ? '编辑网站' : preset ? '添加 ChatGPT 预设' : '添加网站',
			[el('div', { 'class': 'r3cg-dialog' }, parts), el('div', { 'class': 'right' }, [p.cancel, ' ', p.save])], 'r3cg-modal');
		this.renderSources();
		this.renderPicker();
		this.syncDialog();
		(d.kind === 'edit' && !rule && !preset ? p.domains : p.search).focus();
		this.loadNodes(false);
		return true;
	},

	buildPicker: function(d) {
		var self = this, p = d.el;
		p.source = el('select', { 'id': 'r3cg-source', 'change': function(ev) { self.changeSource(ev.target.value); } });
		p.search = el('input', { 'id': 'r3cg-search', 'type': 'search', 'placeholder': '名称、地区或类型', 'autocomplete': 'off',
			'input': function(ev) { d.query = ev.target.value; self.renderPicker(); self.syncDialog(); } });
		p.chips = el('div', { 'class': 'r3cg-chips', 'role': 'group', 'aria-label': '按地区筛选' });
		p.benchBtn = this.button('测速', 'action', function() { return self.startBench(false); });
		p.benchAllBtn = this.button('全部测速', 'neutral', function() { return self.startBench(true); });
		p.fastBtn = this.button('选最快', 'neutral', function() { self.pickFastest(); });
		p.benchLine = el('p', { 'class': 'r3cg-hint', 'role': 'status', 'aria-live': 'polite' });
		p.progress = el('progress', { 'max': 1, 'value': 0, 'aria-label': '测速进度' });
		p.list = el('div', { 'class': 'r3cg-nodes', 'role': 'radiogroup', 'aria-label': '节点', 'keydown': function(ev) {
			if (ev.key !== 'ArrowDown' && ev.key !== 'ArrowUp' || !p.list.querySelectorAll) return;
			var rows = Array.prototype.slice.call(p.list.querySelectorAll('button.r3cg-row:not(:disabled)'));
			var at = rows.indexOf(document.activeElement);
			var next = rows[at < 0 ? 0 : Math.max(0, Math.min(rows.length - 1, at + (ev.key === 'ArrowDown' ? 1 : -1)))];
			if (next) { next.focus(); ev.preventDefault(); }
		} });
		p.more = this.button('', 'neutral', function() { d.showFailed = !d.showFailed; self.renderPicker(); });
		p.picked = el('p', { 'class': 'r3cg-picked', 'aria-live': 'polite' });
		return el('section', { 'class': 'r3cg-picker', 'aria-label': '选择节点' }, [
			el('div', { 'class': 'r3cg-picker-head' }, [
				el('div', { 'class': 'r3cg-field' }, [el('label', { 'for': 'r3cg-source' }, '订阅'), p.source]),
				el('div', { 'class': 'r3cg-field' }, [el('label', { 'for': 'r3cg-search' }, '搜索节点'), p.search])
			]),
			p.chips,
			el('div', { 'class': 'r3cg-toolbar' }, [p.benchBtn, p.benchAllBtn, p.fastBtn]),
			p.benchLine, p.progress, p.list, p.more, p.picked
		]);
	},

	renderSources: function() {
		var d = this.dlg;
		if (!d || !d.el || d.kind === 'confirm') return;
		var select = clear(d.el.source);
		if (!this.sources.length) select.appendChild(el('option', { 'value': '' }, '没有可用的订阅'));
		var active = this.activeSource();
		this.sources.forEach(function(s) { select.appendChild(el('option', { 'value': s }, s + (s === active ? '（OpenClash 当前配置）' : ''))); });
		if (d.source && this.sources.indexOf(d.source) < 0)
			select.appendChild(el('option', { 'value': d.source, 'disabled': true }, d.source + '（已不可用）'));
		select.value = d.source;
	},

	changeSource: function(value) {
		var d = this.dlg;
		if (!d || this.mutating || value === d.source) return;
		d.source = value;
		d.selected = d.rule && d.rule.source === value ? d.rule.selected : '';
		d.region = '';
		d.nodes = [];
		d.bench = null;
		d.nodesKey = '';
		d.benchNotice = '';
		d.message = '';
		d.dirty = true;
		this.loadNodes(false);
	},

	setDomains: function(text) {
		var d = this.dlg, self = this;
		if (!d) return;
		d.domainsText = text;
		d.dirty = true;
		d.message = '';
		var target = this.targetOf(d);
		if (target !== d.target) {
			d.target = target;
			this.cancelTimer(d, 'targetTimer');
			// Results are per site; wait for typing to settle before reading them.
			d.targetTimer = this.later(function() {
				d.targetTimer = null;
				if (self.dlg === d) self.loadNodes(false);
			}, TARGET_DELAY_MS);
		}
		this.syncDialog();
	},

	indexNodes: function(list) {
		var rows = nodesOf(list).map(function(n, i) {
			var row = { id: n.id, name: n.name, type: typeof n.type === 'string' ? n.type : '', dependent: n.dependent === true,
				eligible: n.eligible === true, median_ms: n.median_ms, samples_ms: Array.isArray(n.samples_ms) ? n.samples_ms : [],
				country: /^[A-Z]{2}$/.test(n.country || '') ? n.country : '', error: typeof n.error === 'string' ? n.error : '',
				tested_at: n.tested_at, stale: n.stale === true, index: i, region: regionOf(n.name) || '?', label: displayName(n.name) };
			row.state = nodeState(row);
			row.haystack = (row.label + ' ' + row.type + ' ' + regionName(row.region) + ' ' + row.region).toLowerCase();
			return row;
		});
		return rows.sort(function(a, b) {
			var ma = typeof a.median_ms === 'number' ? a.median_ms : Infinity, mb = typeof b.median_ms === 'number' ? b.median_ms : Infinity;
			return ORDER[a.state] - ORDER[b.state] || (a.state === 'ok' && ma !== mb ? ma - mb : 0) || a.index - b.index;
		});
	},

	loadNodes: function(quiet) {
		var d = this.dlg;
		if (!d || !d.el || d.kind === 'confirm') return Promise.resolve(false);
		var self = this, source = d.source, target = d.target, serial = ++d.serial;
		this.cancelTimer(d, 'timer');
		if (!target || !isSource(source)) {
			d.loading = false;
			this.renderPicker();
			this.syncDialog();
			return Promise.resolve(false);
		}
		if (!quiet) {
			d.loading = true;
			d.loadError = '';
			this.renderPicker();
			this.syncDialog();
		}
		return fs.exec(CLI, ['nodes', source, target]).then(parseResult).then(function(res) {
			if (self.dlg !== d || serial !== d.serial) return false;
			d.nodes = self.indexNodes(res.nodes);
			d.bench = benchOf(res.benchmark);
			d.nodesKey = source + '\n' + target;
			d.loadError = '';
			return true;
		}).catch(function(e) {
			// A failed background read keeps the rows on screen and tries again on the next tick.
			if (self.dlg === d && serial === d.serial && !quiet) {
				d.loadError = errorText(e);
				d.nodes = [];
				d.nodesKey = '';
			}
			return false;
		}).then(function(ok) {
			if (self.dlg !== d || serial !== d.serial) return ok;
			d.loading = false;
			self.renderPicker();
			self.syncDialog();
			if (d.bench && d.bench.running)
				d.timer = self.later(function() {
					d.timer = null;
					if (self.dlg === d) self.loadNodes(true);
				}, BENCH_POLL_MS);
			return ok;
		});
	},

	pickerRows: function() {
		var d = this.dlg, q = d.query.trim().toLowerCase(), region = d.region;
		return d.nodes.filter(function(n) {
			return (!region || n.region === region) && (!q || n.haystack.indexOf(q) >= 0);
		});
	},

	emptyText: function(d) {
		if (!d.target) return '先在上面填网站域名，测速会针对这个网站。';
		if (d.loadError) return d.loadError;
		if (d.loading || !d.nodesKey) return '正在读取节点…';
		if (!d.nodes.length) return '这个订阅里没有节点。';
		return '没有符合筛选条件的节点。';
	},

	renderPicker: function() {
		var d = this.dlg;
		if (!d || !d.el || d.kind === 'confirm') return;
		var self = this, p = d.el, counts = {}, codes = [];
		d.nodes.forEach(function(n) {
			if (!has(counts, n.region)) { counts[n.region] = 0; codes.push(n.region); }
			counts[n.region]++;
		});
		codes.sort(function(a, b) {
			return (a === '?') - (b === '?') || counts[b] - counts[a] || regionName(a).localeCompare(regionName(b), 'zh');
		});
		if (d.region && !has(counts, d.region)) d.region = '';
		// One more chip beats a dropdown holding a single region.
		var chips = codes.length > REGION_CHIPS + 1 ? codes.slice(0, REGION_CHIPS) : codes, rest = codes.slice(chips.length);
		clear(p.chips);
		p.chips.hidden = codes.length < 2;
		if (codes.length > 1) {
			[''].concat(chips).forEach(function(code) {
				p.chips.appendChild(el('button', { 'type': 'button', 'class': 'r3cg-chip', 'aria-pressed': d.region === code ? 'true' : 'false',
					'click': function() { d.region = code; self.renderPicker(); self.syncDialog(); } },
					code ? regionName(code) + ' ' + counts[code] : '全部 ' + d.nodes.length));
			});
		}
		if (rest.length) {
			var more = el('select', { 'class': 'r3cg-more', 'aria-label': '其他地区',
				'change': function(ev) { d.region = ev.target.value; self.renderPicker(); self.syncDialog(); } },
				el('option', { 'value': '' }, '其他 ' + rest.length + ' 个地区…'));
			rest.slice().sort(function(a, b) { return regionName(a).localeCompare(regionName(b), 'zh'); }).forEach(function(code) {
				more.appendChild(el('option', { 'value': code }, regionName(code) + ' ' + counts[code]));
			});
			more.value = rest.indexOf(d.region) >= 0 ? d.region : '';
			p.chips.appendChild(more);
		}
		var rows = this.pickerRows(), hidden = 0, shown = 0, failed = 0;
		var live = rows.some(function(n) { return n.state === 'ok' || n.state === 'untested'; });
		var active = document.activeElement, focused = active && active.getAttribute && p.list.contains && p.list.contains(active) ?
			active.getAttribute('data-id') : '';
		var top = p.list.scrollTop;
		clear(p.list);
		rows.forEach(function(n) {
			var out = n.state === 'failed' || n.state === 'info' || n.state === 'blocked';
			if (out) failed++;
			// Failed nodes fold away unless asked for, selected, or nothing else matches.
			if (out && !d.showFailed && n.id !== d.selected && live) { hidden++; return; }
			shown++;
			p.list.appendChild(self.nodeRow(n, d));
		});
		if (!shown) p.list.appendChild(el('p', { 'class': 'r3cg-empty' }, this.emptyText(d)));
		p.list.scrollTop = top;
		if (focused && p.list.querySelector) {
			var again = p.list.querySelector('[data-id="' + focused + '"]');
			if (again) again.focus();
		}
		p.more.hidden = !hidden && !(d.showFailed && failed && live);
		p.more.textContent = d.showFailed ? '收起未通过和不可用的条目' : '显示 ' + hidden + ' 个未通过或不可用的条目';
	},

	nodeRow: function(n, d) {
		var self = this, picked = n.id === d.selected;
		return el('button', { 'type': 'button', 'class': 'r3cg-row ' + n.state + (picked ? ' picked' : ''), 'role': 'radio',
			'data-id': n.id, 'aria-checked': picked ? 'true' : 'false', 'disabled': n.state === 'blocked' || n.state === 'info' || !!this.mutating,
			'click': function() { self.selectNode(n.id); } }, [
			el('span', { 'class': 'r3cg-region' }, regionName(n.region)),
			el('span', { 'class': 'r3cg-name' }, n.label),
			el('span', { 'class': 'r3cg-type' }, n.type),
			el('span', { 'class': 'r3cg-result' }, this.nodeStatus(n, d))
		]);
	},

	nodeStatus: function(n, d) {
		var when = ago(n.tested_at, this.now());
		if (n.state === 'ok') {
			var exit = d.target === 'chatgpt' && n.country && n.country !== n.region ? '出口' + regionName(n.country) : '';
			return [latency(n.median_ms) || '已通过', exit, when].filter(Boolean).join(' · ');
		}
		if (n.state === 'blocked') return benchError('NODE_DEPENDENCY');
		if (n.state === 'info') return '订阅信息，不是节点';
		if (n.state === 'failed') return [n.error ? benchError(n.error) : '验证未通过', when].filter(Boolean).join(' · ');
		if (n.error === 'PENDING' && d.bench && d.bench.running && d.bench.run_ids.indexOf(n.id) >= 0) return '等待测速…';
		if (n.stale) return '结果已过期' + (when ? '（' + when + '）' : '');
		if (n.error && n.error !== 'PENDING') return benchError(n.error);
		return '未测速';
	},

	selectedNode: function() {
		var d = this.dlg;
		if (!d || d.nodesKey !== d.source + '\n' + d.target) return null;
		return d.nodes.filter(function(n) { return n.id === d.selected; })[0] || null;
	},

	selectNode: function(id) {
		var d = this.dlg;
		if (!d || !d.el || this.mutating) return;
		d.selected = id;
		d.dirty = true;
		d.message = '';
		d.tone = '';
		this.renderPicker();
		this.syncDialog();
	},

	// Picks among the rows on screen, so it works as soon as the first results arrive.
	pickFastest: function() {
		var d = this.dlg, best = null;
		if (!d || !d.el || this.mutating) return;
		this.pickerRows().forEach(function(n) {
			if (n.state === 'ok' && typeof n.median_ms === 'number' && (!best || n.median_ms < best.median_ms)) best = n;
		});
		if (best) this.selectNode(best.id);
	},

	// Filtered rows are measured on their own; otherwise (or past 64 ids) the whole subscription.
	benchPlan: function() {
		var d = this.dlg, total = d.nodes.length, minutes = Math.ceil(total * SECONDS_PER_NODE / 60);
		var all = { ids: [], label: '全部测速（' + total + ' 个' + (minutes >= 2 ? '，约 ' + minutes + ' 分钟' : '') + '）' };
		if (!d.query.trim() && !d.region) return all;
		var ids = this.pickerRows().filter(function(n) { return n.state !== 'blocked' && n.state !== 'info'; }).map(function(n) { return n.id; });
		if (!ids.length) return { ids: null, label: '没有可测速的节点' };
		return ids.length > BENCH_MAX_IDS || ids.length === total ? all : { ids: ids, label: '测速这 ' + ids.length + ' 个' };
	},

	startBench: function(all) {
		var d = this.dlg;
		if (!d || !d.el || this.mutating || d.starting || d.loading || d.bench && d.bench.running ||
			d.nodesKey !== d.source + '\n' + d.target || !d.nodes.length)
			return Promise.resolve(false);
		var self = this, plan = all ? { ids: [] } : this.benchPlan();
		if (!plan.ids) return Promise.resolve(false);
		d.starting = true;
		d.benchNotice = '';
		this.syncDialog();
		return fs.exec(CLI, ['benchmark', d.source, d.target].concat(plan.ids)).then(parseResult).then(function() {
			if (self.dlg === d) return self.loadNodes(true);
		}).catch(function(e) {
			if (self.dlg === d) d.benchNotice = permissionDenied(e) ? '当前会话没有测速权限，请退出 LuCI 后重新登录。' :
				e && has(BENCH_ERRORS, e.token) ? BENCH_ERRORS[e.token] + '。' : '测速启动失败，请稍后重试。';
		}).then(function() {
			if (self.dlg === d) {
				d.starting = false;
				self.syncDialog();
			}
			return true;
		});
	},

	benchLine: function(d) {
		var b = d.bench;
		if (d.benchNotice) return d.benchNotice;
		if (d.starting) return '正在启动测速…';
		if (!b || !d.target) return '';
		if (b.running) return '正在测速：' + b.done + ' / ' + b.total + '，结果逐行出现；关掉窗口也会继续测。';
		if (b.error) return benchError(b.error) + '。';
		var when = ago(b.finished_at, this.now());
		return (when ? '上次测速：' + when + '。' : '这个订阅还没测过速。') + (d.target === 'chatgpt' ?
			'测速会核对 ChatGPT 是否支持节点所在地区。' : '测速是经节点访问 ' + d.target.slice(5) + ' 三次，取中位首字节时间。');
	},

	pickedText: function(d) {
		if (!d.selected) return '还没选节点：点上面列表里的一行。';
		var n = this.selectedNode();
		if (!n) return d.nodesKey === d.source + '\n' + d.target ? '原来的节点已不在这个订阅里，请重新选择。' : '';
		var text = '已选：' + n.label;
		if (n.state === 'ok') {
			var when = ago(n.tested_at, this.now());
			return [text, latency(n.median_ms), when && when + '测'].filter(Boolean).join(' · ');
		}
		if (n.state === 'blocked') return text + '（依赖其他代理，不能使用）';
		if (n.state === 'info') return text + '（这是订阅信息，不是节点，请换一个）';
		return text + (n.state === 'failed' ? '（测速未通过，仍可保存，标为「未验证」）' : '（未测速，保存后标为「未验证」）');
	},

	syncDialog: function() {
		var d = this.dlg;
		if (!d || !d.el || d.kind === 'confirm') return;
		var p = d.el, busy = !!this.mutating, ready = !d.loading && d.nodesKey === d.source + '\n' + d.target;
		if (d.kind === 'edit') {
			var check = this.domainCheck(), first = check.domains[0], long = utf8Length(d.label.trim()) > LABEL_BYTES;
			p.preview.textContent = check.text;
			p.preview.className = 'r3cg-hint' + (check.ok || check.empty ? '' : ' bad');
			p.label.setAttribute('placeholder', first ? '不填就叫 ' + first.slice(0, LABEL_BYTES) : '例如：常用网站');
			p.labelHint.textContent = long ? '名称太长，最多约 50 个汉字。' : '';
			p.labelHint.className = 'r3cg-hint' + (long ? ' bad' : '');
			p.label.disabled = p.domains.disabled = busy;
		}
		p.source.disabled = busy || !this.sources.length;
		p.search.disabled = !d.nodes.length;
		var running = !!(d.bench && d.bench.running), plan = this.benchPlan(), rows = ready ? this.pickerRows() : [];
		p.benchBtn.disabled = busy || !ready || d.starting || running || !d.nodes.length || !plan.ids;
		p.benchBtn.textContent = d.starting ? '正在启动…' : running ? '测速进行中…' : plan.label;
		p.benchAllBtn.hidden = !plan.ids || !plan.ids.length;
		p.benchAllBtn.disabled = busy || !ready || d.starting || running;
		p.fastBtn.disabled = busy || !rows.some(function(n) { return n.state === 'ok'; });
		p.progress.hidden = !running;
		p.progress.setAttribute('max', Math.max(1, d.bench ? d.bench.total : 0));
		p.progress.setAttribute('value', d.bench ? Math.min(d.bench.done, d.bench.total) : 0);
		p.benchLine.textContent = this.benchLine(d);
		p.picked.textContent = this.pickedText(d);
		p.message.textContent = d.message;
		p.message.className = 'r3cg-message' + (d.tone ? ' ' + d.tone : '');
		p.message.setAttribute('role', d.tone === 'bad' ? 'alert' : 'status');
		p.save.disabled = !this.canSave();
		p.save.textContent = this.mutating === 'save' ? '正在应用…' : d.rule && d.rule.enabled === false ? '保存' : '保存并生效';
		p.cancel.disabled = busy;
	},

	canSave: function() {
		var d = this.dlg;
		if (!d || !d.el || d.kind === 'confirm' || this.mutating || d.loading || d.nodesKey !== d.source + '\n' + d.target ||
			this.sources.indexOf(d.source) < 0)
			return false;
		if (d.kind === 'edit' && (!this.domainCheck().ok || utf8Length(d.label.trim()) > LABEL_BYTES)) return false;
		var n = this.selectedNode();
		return !!n && n.state !== 'blocked' && n.state !== 'info';
	},

	saveDialog: function() {
		var d = this.dlg;
		if (!this.canSave()) return Promise.resolve(false);
		var n = this.selectedNode(), edit = d.kind === 'edit';
		var payload = {
			label: edit ? d.label.trim() || this.domainCheck().domains[0].slice(0, LABEL_BYTES) : d.rule.label,
			domains: edit ? this.domainLines(d.domainsText) : d.rule.domains.slice(),
			source: d.source, selected: d.selected, enabled: d.rule ? d.rule.enabled !== false : true
		};
		// No current proof: the router keeps the node and marks the rule unverified.
		if (n.state !== 'ok') payload.unverified = true;
		if (d.rule) payload.id = d.rule.id;
		if (d.preset) payload.preset = d.preset;
		return this.mutate('save', d.rule ? d.rule.id : '', payload);
	},

	closeDialog: function(force) {
		var d = this.dlg;
		if (!d || this.mutating && !force) return false;
		this.cancelTimer(d, 'timer');
		this.cancelTimer(d, 'targetTimer');
		d.el = null;
		this.dlg = null;
		ui.hideModal();
		this.sync();
		// A benchmark may have finished while the dialog was open.
		if (!force) this.idleRefresh();
		return true;
	},

	showConfirm: function(title, lines, okText, kind, action) {
		if (this.mutating || this.dialogOpen()) return false;
		var self = this;
		var cancel = this.button('取消', 'neutral', function() { return self.closeDialog(); });
		var ok = this.button(okText, kind, function() { self.closeDialog(true); return action(); });
		this.dlg = { kind: 'confirm', ok: ok, cancel: cancel };
		ui.showModal(title, [el('div', { 'class': 'r3cg-dialog' }, lines), el('div', { 'class': 'right' }, [cancel, ' ', ok])], 'r3cg-modal');
		cancel.focus();
		return true;
	},

	confirmRemove: function(rule) {
		var self = this;
		return this.showConfirm('删除网站规则', [
			el('p', {}, '删除「' + titleOf(rule) + '」？'),
			el('p', { 'class': 'r3cg-hint' }, rule.enabled ? '删除后这些域名回到原来的分流。删除不能撤销，只能重新添加。' :
				'这条规则已停用，删除不影响当前分流。删除不能撤销。')
		], '删除', 'negative', function() { return self.mutate('remove', rule.id); });
	},

	confirmDisable: function() {
		if (this.disableBtn.disabled) return false;
		var self = this, steam = steamOf(this.status), on = this.rules.filter(function(r) { return r.enabled; }).length;
		var what = (on ? '停用全部 ' + on + ' 条网站规则（规则保留，随时可以重新启用）' : '清除本模块写入运行配置的分流') +
			(steam && (steam.enabled || steam.applied) ? '，并关闭 Steam 直连' : '') + '。';
		return this.showConfirm('恢复原分流', [el('p', {}, '将' + what), el('p', { 'class': 'r3cg-hint' }, 'OpenClash 原有的分流规则不受影响。')],
			'恢复原分流', 'negative', function() { return self.mutate('disable'); });
	},

	toggleSteam: function(want) {
		if (typeof want !== 'boolean' || this.mutating || this.steamSwitch.disabled) {
			this.sync();
			return Promise.resolve(false);
		}
		return this.mutate('steam-direct', '', want);
	},

	// Every change command answers with the same fields as `summary`, read back from the
	// controller after the reload, so the page needs no second read to confirm it.
	verified: function(action, id, arg, st) {
		var pending = !!st.pending_restart, steam = steamOf(st), rule = this.ruleById(action === 'save' ? st.id || id : id);
		if (action === 'steam-direct') return !!steam && steam.enabled === arg && steam.applied === arg;
		if (action === 'remove') return !rule;
		if (action === 'save')
			return !!rule && rule.source === arg.source && rule.selected === arg.selected && rule.enabled === arg.enabled &&
				(pending || !arg.enabled || rule.applied === true && !rule.error);
		if (action === 'set-enabled')
			return !!rule && rule.enabled === arg && (pending || (arg ? rule.applied === true && !rule.error : rule.applied !== true));
		return !this.rules.some(function(r) { return r.enabled; }) && st.enabled === false &&
			(pending || st.applied !== true && !st.error) && (!steam || !steam.enabled && !steam.applied);
	},

	doneText: function(action, arg, pending) {
		if (pending) return '已保存，等待 OpenClash 启动后生效。';
		if (action === 'steam-direct') return arg ? 'Steam 直连已开启。' : 'Steam 直连已关闭。';
		if (action === 'save') return arg.enabled ? '网站规则已保存并生效。' : '网站规则已保存（未启用）。';
		if (action === 'remove') return '网站规则已删除。';
		if (action === 'set-enabled') return arg ? '网站规则已启用。' : '网站规则已停用。';
		return '已恢复原分流，全部网站规则已停用，Steam 直连已关闭。';
	},

	mutate: function(action, id, arg) {
		if (this.mutating || ['save', 'set-enabled', 'remove', 'disable', 'steam-direct'].indexOf(action) < 0 ||
			(action === 'set-enabled' || action === 'remove') && !this.ruleById(id) ||
			(action === 'set-enabled' || action === 'steam-direct') && typeof arg !== 'boolean' ||
			action === 'save' && (!arg || typeof arg !== 'object'))
			return Promise.resolve(false);
		var self = this, d = action === 'save' && this.dlg && this.dlg.el ? this.dlg : null, started = this.now();
		var args = action === 'save' ? ['save', JSON.stringify(arg)] : action === 'set-enabled' ? ['set-enabled', id, arg ? '1' : '0'] :
			action === 'remove' ? ['remove', id] : action === 'steam-direct' ? ['steam-direct', arg ? '1' : '0'] : ['disable'];
		if (action === 'steam-direct') this.steamTarget = arg;
		this.mutating = action;
		this.busyId = id || '';
		++this.readSerial;
		this.reading = false;
		this.notice = '';
		this.noticeTone = '';
		if (d) { d.message = ''; d.tone = ''; }
		this.renderRules();
		this.sync();
		this.renderPicker();
		this.syncDialog();
		return fs.exec(CLI, args).then(parseResult).then(function(result) {
			if (Array.isArray(result.rules)) return result;
			return fs.exec(CLI, ['summary']).then(parseResult).then(function(st) {
				st.id = result.id;
				return st;
			});
		}).then(function(st) {
			self.acceptStatus(st);
			if (!self.verified(action, id, arg, st)) {
				var text = statusErrorText(st) || '操作已提交，尚未确认生效。请刷新状态。';
				if (d && self.dlg === d) { d.message = text; d.tone = 'bad'; }
				self.notice = text;
				self.noticeTone = 'bad';
				return false;
			}
			if (d && self.dlg === d) self.closeDialog(true);
			var pending = !!st.pending_restart && action !== 'steam-direct';
			self.notice = self.doneText(action, arg, pending) + '用时 ' + ((self.now() - started) / 1000).toFixed(1) + ' 秒' +
				(st.reloaded === false ? '，运行配置无变化，未重载' : '') + '。';
			self.noticeTone = pending ? 'warn' : 'ok';
			return true;
		}).catch(function(e) {
			var text = errorText(e);
			// A failed save keeps the dialog and everything typed in it.
			if (d && self.dlg === d) { d.message = text; d.tone = 'bad'; }
			else { self.notice = text; self.noticeTone = 'bad'; }
			return false;
		}).then(function(ok) {
			self.mutating = false;
			self.busyId = '';
			self.renderRules();
			self.sync();
			self.renderPicker();
			self.syncDialog();
			return ok;
		});
	}
});
