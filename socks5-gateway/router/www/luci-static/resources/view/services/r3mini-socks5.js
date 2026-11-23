'use strict';
'require view';
'require fs';
'require poll';

// SOCKS5 出口页面（第 3 版）。数据全部来自 /usr/sbin/r3mini-socks5：
// status 很快；节点清单 targets 按订阅在后台加载；换节点、开关仅 IPv4 只调 SOCKS5 自己的内核，
// 换订阅、改端口密码也只动它，路由器上其他设备不受影响。
// 卡片用主题自带的 .cbi-section，标题不用 h3（argon 把所有 h3 画成白底面板）。

var CLI = '/usr/sbin/r3mini-socks5';
var REGION = {
	US: '美国', GB: '英国', IQ: '伊拉克', JP: '日本', HK: '香港', TW: '台湾', SG: '新加坡', KR: '韩国',
	DE: '德国', FR: '法国', NL: '荷兰', TR: '土耳其', RU: '俄罗斯', IN: '印度', ID: '印度尼西亚',
	PK: '巴基斯坦', PH: '菲律宾', VN: '越南', TH: '泰国', MY: '马来西亚', AU: '澳大利亚', CA: '加拿大',
	BR: '巴西', AE: '阿联酋', SA: '沙特', IL: '以色列', IT: '意大利', ES: '西班牙', CN: '中国', MO: '澳门',
	AR: '阿根廷', MX: '墨西哥', UA: '乌克兰', PL: '波兰', SE: '瑞典', CH: '瑞士', IR: '伊朗', EG: '埃及',
	NG: '尼日利亚', ZA: '南非', KZ: '哈萨克斯坦', MN: '蒙古', KH: '柬埔寨', MM: '缅甸', BD: '孟加拉',
	LK: '斯里兰卡', NP: '尼泊尔', CL: '智利', CO: '哥伦比亚', PE: '秘鲁', NZ: '新西兰', IE: '爱尔兰',
	FI: '芬兰', NO: '挪威', DK: '丹麦', AT: '奥地利', BE: '比利时', PT: '葡萄牙', GR: '希腊', RO: '罗马尼亚',
	CZ: '捷克', HU: '匈牙利', BG: '保加利亚', JO: '约旦', KW: '科威特', QA: '卡塔尔', OM: '阿曼', BH: '巴林'
};
// 订阅里常见的「信息条目」（剩余流量、到期时间等）不是节点，列表里收起来。
var INFO_NODE = /剩余流量|套餐到期|到期时间|过期时间|下次重置|重置剩余|官网|网址|官方网站|流量重置|Traffic|Expire/i;

/* ---------- 小工具 ---------- */

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
		if (Array.isArray(c)) c.forEach(function(x) { if (x != null && x !== false) node.appendChild(x.nodeType ? x : document.createTextNode(String(x))); });
		else if (c != null && c !== false) node.appendChild(c.nodeType ? c : document.createTextNode(String(c)));
	});
	return node;
}

function clear(node) {
	while (node.firstChild) node.removeChild(node.firstChild);
	return node;
}

function setText(node, text) {
	node.textContent = text == null ? '' : String(text);
	return node;
}

function b64(text) {
	var bytes;
	if (window.TextEncoder) bytes = new TextEncoder().encode(text);
	else bytes = unescape(encodeURIComponent(text)).split('').map(function(c) { return c.charCodeAt(0); });
	var bin = '';
	for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
	return 'b64:' + btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function call(args) {
	return fs.exec(CLI, args).then(function(res) {
		var data = null;
		try { data = JSON.parse(res && res.stdout || ''); } catch (e) {}
		if (!data) throw new Error(res && res.code !== 0 ? '操作失败，请刷新页面后重试。' : '路由器返回的内容无法读取，请刷新页面后重试。');
		if (data.ok !== true) {
			var err = new Error(data.message || '操作失败。');
			err.data = data;
			throw err;
		}
		return data;
	});
}

function errorText(e) {
	var msg = e && e.message || '';
	if (/permission|access denied|denied/i.test(msg)) return '当前登录没有这个操作的权限，请退出 LuCI 后重新登录。';
	if (/timed? ?out|timeout/i.test(msg)) return '路由器响应超时，请稍后刷新页面查看结果。';
	return /[㐀-鿿]/.test(msg) ? msg : '无法读取路由器响应，请检查连接后刷新。';
}

function flagOf(code) {
	if (!/^[A-Z]{2}$/.test(code || '')) return '';
	return String.fromCodePoint(0x1F1E6 + code.charCodeAt(0) - 65, 0x1F1E6 + code.charCodeAt(1) - 65);
}

function regionName(code) {
	if (!code) return '未知';
	return (flagOf(code) + ' ' + (REGION[code] || code)).trim();
}

// 从节点名里取国旗（两位代码）和地区名，用于地区筛选。
function parseNode(name) {
	var chars = Array.from(name || '');
	var code = '', rest = name || '';
	if (chars.length >= 2) {
		var a = chars[0].codePointAt(0), b = chars[1].codePointAt(0);
		if (a >= 0x1F1E6 && a <= 0x1F1FF && b >= 0x1F1E6 && b <= 0x1F1FF) {
			code = String.fromCharCode(a - 0x1F1E6 + 65, b - 0x1F1E6 + 65);
			rest = chars.slice(2).join('').trim();
		}
	}
	var word = (rest.match(/^[^\s\d|·\-_(（\[]+/) || [''])[0];
	var region = code ? (REGION[code] || word || code) : (word && word.length <= 6 ? word : '其他');
	return { code: code, region: region, key: code || region, rest: rest };
}

function delayClass(ms) {
	if (!ms) return 'none';
	return ms < 300 ? 'good' : ms < 800 ? 'ok' : 'slow';
}

function delayText(ms) {
	return ms ? ms + ' ms' : '—';
}

function timeText(date) {
	var d = date instanceof Date ? date : new Date(date);
	if (isNaN(d.getTime())) return '';
	var p = function(n) { return (n < 10 ? '0' : '') + n; };
	return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function copyText(text) {
	if (navigator.clipboard && window.isSecureContext)
		return navigator.clipboard.writeText(text);
	var area = el('textarea', { style: 'position:fixed;left:-9999px;top:0', readonly: true });
	area.value = text;
	document.body.appendChild(area);
	area.select();
	var ok = false;
	try { ok = document.execCommand('copy'); } catch (e) {}
	document.body.removeChild(area);
	return ok ? Promise.resolve() : Promise.reject(new Error('复制失败，请手动选中复制。'));
}

var CSS = [
	'.s5{line-height:1.5;--s5-line:rgba(127,127,127,.28);--s5-soft:rgba(127,127,127,.1);--s5-blue:#2f6fde;--s5-green:#1f9d55;--s5-amber:#b7791f;--s5-red:#d14343}',
	'.s5 *{box-sizing:border-box}.s5 [hidden]{display:none!important}',
	'.s5-top{display:flex;align-items:center;gap:.7rem;flex-wrap:wrap;margin:.2rem 0 1rem}',
	'.s5-sub{opacity:.75;font-size:.92em}',
	'.s5-pill{display:inline-flex;align-items:center;gap:.4rem;font-size:.82em;font-weight:600;padding:.12rem .6rem;border-radius:999px;border:1px solid var(--s5-line);white-space:nowrap}',
	'.s5-dot{width:.55rem;height:.55rem;border-radius:50%;background:#7a8590;flex:none}',
	'.s5-pill.ok .s5-dot{background:var(--s5-green)}.s5-pill.bad .s5-dot{background:var(--s5-red)}.s5-pill.warn .s5-dot{background:var(--s5-amber)}',
	'.s5-banner{display:flex;align-items:center;justify-content:space-between;gap:.8rem;flex-wrap:wrap;padding:.6rem .8rem;border-radius:8px;margin-bottom:1rem;border:1px solid rgba(209,67,67,.45);background:rgba(209,67,67,.08)}',
	'.s5-banner.warn{border-color:rgba(183,121,31,.45);background:rgba(183,121,31,.08)}',
	'.s5 .cbi-section.s5-card{margin-bottom:1rem;padding:1rem 1.25rem}',
	'.s5-card-head{display:flex;align-items:center;justify-content:space-between;gap:.6rem;flex-wrap:wrap;margin-bottom:.7rem}',
	'.s5-title{font-weight:600;font-size:1.05rem}',
	'.s5-label{font-size:.8em;opacity:.65}',
	'.s5-exit{display:flex;align-items:center;justify-content:space-between;gap:1rem;flex-wrap:wrap}',
	'.s5-exit-name{font-size:1.45rem;font-weight:700;line-height:1.25;word-break:break-word}',
	'.s5-meta{display:flex;flex-wrap:wrap;gap:.3rem .9rem;font-size:.88em;opacity:.9;margin-top:.3rem;align-items:center}',
	'.s5-badge{display:inline-block;font-size:.78em;padding:.05rem .45rem;border-radius:5px;border:1px solid var(--s5-line);white-space:nowrap;font-weight:500}',
	'.s5-badge.blue{border-color:rgba(47,111,222,.5);color:var(--s5-blue)}',
	'.s5-ms{font-variant-numeric:tabular-nums;font-weight:600;white-space:nowrap}.s5-ms.good{color:var(--s5-green)}.s5-ms.ok{color:var(--s5-amber)}.s5-ms.slow{color:var(--s5-red)}.s5-ms.none{opacity:.45;font-weight:400}',
	'.s5-actions{display:flex;gap:.5rem;flex-wrap:wrap;align-items:center}',
	'.s5 .cbi-button[disabled]{opacity:.55;cursor:default}',
	'.s5 button.s5-link{background:none!important;border:0!important;box-shadow:none!important;padding:0!important;margin:0;min-height:0!important;height:auto!important;line-height:inherit;color:var(--s5-blue)!important;cursor:pointer;font:inherit;text-decoration:underline}',
	'.s5-switch-row{display:flex;gap:.8rem;align-items:flex-start;margin-top:1rem;padding-top:.9rem;border-top:1px dashed var(--s5-line)}',
	'.s5-switch{position:relative;display:inline-block;width:2.6rem;height:1.45rem;flex:none;margin-top:.1rem}',
	'.s5-switch input{opacity:0!important;width:0!important;height:0!important;position:absolute;margin:0}',
	'.s5-switch span{position:absolute;inset:0;border-radius:999px;background:rgba(127,127,127,.45);transition:background .15s;cursor:pointer}',
	'.s5-switch span:before{content:"";position:absolute;width:1.05rem;height:1.05rem;left:.2rem;top:.2rem;border-radius:50%;background:#fff;transition:transform .15s}',
	'.s5-switch input:checked+span{background:var(--s5-blue)}.s5-switch input:checked+span:before{transform:translateX(1.15rem)}',
	'.s5-switch input:disabled+span{opacity:.5;cursor:default}.s5-switch input:focus-visible+span{outline:2px solid var(--s5-blue);outline-offset:2px}',
	'@media (prefers-reduced-motion:reduce){.s5-switch span,.s5-switch span:before{transition:none}.s5-spin{animation-duration:2s}}',
	'.s5-note{font-size:.84em;opacity:.72}',
	'.s5-picker{margin-top:1rem;border-top:1px solid var(--s5-line);padding-top:.9rem;display:grid;gap:.6rem}',
	'.s5-subs{display:flex;gap:.4rem;flex-wrap:wrap}',
	'.s5 button.s5-sub-tab{flex:none;box-shadow:none!important;min-height:0;height:auto;border:1px solid var(--s5-line);background:transparent;color:inherit;border-radius:8px;padding:.35rem .75rem;font:inherit;font-size:.9em;cursor:pointer;display:inline-flex;gap:.35rem;align-items:center;white-space:nowrap}',
	'.s5 button.s5-sub-tab.on{border-color:var(--s5-blue);background:rgba(47,111,222,.1);color:var(--s5-blue);font-weight:600}',
	'.s5-sub-tab small{font-size:.75em;opacity:.75;font-weight:400}',
	'.s5-filter{display:grid;grid-template-columns:minmax(0,1fr) auto auto;gap:.5rem;align-items:center}',
	'.s5-filter input[type=search]{width:100%;min-width:0}',
	'.s5-filter select{max-width:14rem}',
	'.s5-list{max-height:26rem;overflow:auto;border:1px solid var(--s5-line);border-radius:8px}',
	'.s5-row{display:grid;grid-template-columns:minmax(0,1fr) 6rem;align-items:stretch;border-bottom:1px solid var(--s5-soft)}',
	'.s5-row:last-child{border-bottom:0}.s5-row:hover{background:var(--s5-soft)}.s5-row.cur{background:rgba(47,111,222,.14)}',
	'.s5 button.s5-pick,.s5 button.s5-ping{box-shadow:none!important;background:transparent!important;border:0!important;margin:0;height:auto;min-height:0;color:inherit;font:inherit;border-radius:0;cursor:pointer}',
	'.s5 button.s5-pick{display:grid;grid-template-columns:2.2rem minmax(0,1fr) auto auto;gap:.6rem;align-items:center;width:100%;text-align:left;padding:.5rem .4rem .5rem .75rem;min-height:2.6rem}',
	'.s5 button.s5-ping{padding:.5rem .75rem;text-align:right;white-space:nowrap}',
	'.s5 button.s5-ping:hover{text-decoration:underline;background:var(--s5-soft)!important}.s5 button.s5-ping .s5-hint{font-size:.85em;font-weight:500;color:var(--s5-blue);opacity:1}',
	'.s5 button.s5-pick:focus-visible,.s5 button.s5-ping:focus-visible{outline:2px solid var(--s5-blue);outline-offset:-2px}',
	'.s5-cc{font-size:.72em;font-weight:700;opacity:.6;letter-spacing:.03em;text-align:center}',
	'.s5-row .nm{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}',
	'.s5-row .ty{font-size:.78em;opacity:.55;white-space:nowrap}',
	'.s5-row.busy{opacity:.6}.s5 .s5-row button[disabled]{cursor:default}',
	'.s5-list-foot{display:flex;justify-content:space-between;gap:.6rem;flex-wrap:wrap}',
	'.s5-empty{padding:1rem;text-align:center;opacity:.65}',
	'.s5-kv{display:grid;grid-template-columns:max-content 1fr;gap:.45rem 1.2rem;margin:0}',
	'.s5-kv dt{opacity:.65}.s5-kv dd{margin:0;word-break:break-all}',
	'.s5-big{font-weight:700}',
	'.s5-msg{padding:.55rem .75rem;border-radius:7px;font-size:.88em;margin-top:.8rem;border:1px solid transparent}',
	'.s5-msg:empty{display:none}.s5-msg.ok{border-color:rgba(31,157,85,.45);background:rgba(31,157,85,.08)}',
	'.s5-msg.bad{border-color:rgba(209,67,67,.45);background:rgba(209,67,67,.08)}.s5-msg.warn{border-color:rgba(183,121,31,.45);background:rgba(183,121,31,.08)}',
	'.s5-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:.9rem}',
	'.s5-field{display:flex;flex-direction:column;gap:.3rem;min-width:0}.s5-field>label{font-weight:600;font-size:.88em}',
	'.s5-field input[type=text],.s5-field input[type=number],.s5-field input[type=password],.s5-field select{width:100%}',
	'.s5-inline{display:flex;gap:.4rem;align-items:center;flex-wrap:wrap}.s5-inline>input{flex:1 1 7rem;min-width:0}',
	'.s5 details>summary{cursor:pointer;font-weight:600;list-style:revert}',
	'.s5-mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.88em;word-break:break-all}',
	'.s5-spin{display:inline-block;width:.85em;height:.85em;border:2px solid currentColor;border-right-color:transparent;border-radius:50%;animation:s5spin .7s linear infinite;vertical-align:-.1em;margin-right:.35em}',
	'@keyframes s5spin{to{transform:rotate(360deg)}}',
	'.s5-regions{display:flex;flex-wrap:wrap;gap:.5rem;margin:.1rem 0 .6rem}',
	'.s5-region{display:flex;flex-direction:column;gap:.1rem;border:1px solid var(--s5-line);border-radius:8px;padding:.45rem .75rem;min-width:9rem;max-width:100%}',
	'.s5-region b{font-size:1.15rem}.s5-region span{font-size:.8em;opacity:.7}',
	'.s5-region.minor{border-color:rgba(183,121,31,.55);background:rgba(183,121,31,.07)}',
	'.s5-fold{margin-top:.7rem}.s5-fold>summary{font-weight:500;font-size:.9em}',
	'.s5-checks{margin-top:.5rem;border:1px solid var(--s5-line);border-radius:8px;overflow:hidden}',
	'.s5-check{display:grid;grid-template-columns:minmax(9rem,1.3fr) minmax(6.5rem,.8fr) minmax(10rem,1.3fr);gap:.2rem .8rem;padding:.5rem .7rem;border-top:1px solid var(--s5-soft);align-items:start}',
	'.s5-check:first-child{border-top:0}.s5-check .s5-note{font-size:.8em}.s5-check-ip{word-break:break-all}',
	'.s5-toast{position:fixed;left:50%;bottom:1.5rem;transform:translateX(-50%);background:#1f2933;color:#fff;padding:.55rem 1rem;border-radius:8px;font-size:.9em;z-index:9999;box-shadow:0 6px 20px rgba(0,0,0,.25);max-width:90vw}',
	'@media (max-width:640px){.s5 .cbi-section.s5-card{padding:.85rem .9rem}.s5-exit-name{font-size:1.25rem}.s5-filter{grid-template-columns:1fr 1fr}.s5-filter input[type=search]{grid-column:1/-1}.s5-filter select{max-width:none;width:100%}',
	'.s5-row{grid-template-columns:minmax(0,1fr) 5rem}.s5 button.s5-pick{grid-template-columns:2rem minmax(0,1fr) auto}.s5-row .ty{display:none}.s5-kv{grid-template-columns:1fr}.s5-kv dt{margin-top:.3rem}.s5-check{grid-template-columns:1fr}}'
].join('\n');

return view.extend({
	load: function() {
		return call(['status']).catch(function(e) {
			return { ok: true, enabled: false, error: 'LOAD_FAILED', message: errorText(e), listener: {} };
		});
	},

	render: function(initial) {
		var st = initial || {};
		var busy = '';
		var probeSeq = 0;
		var browse = null;          // 选择器里正在看的订阅文件名
		var lists = {};             // 订阅文件名 → targets 结果
		var loading = {};
		var filter = { text: '', region: '' };
		var synced = false;
		var scrollPending = false;

		/* ---------- 骨架 ---------- */

		var pill = el('span', { class: 's5-pill' });
		var subline = el('span', { class: 's5-sub' });
		var banner = el('div', { class: 's5-banner', hidden: true, role: 'alert' });

		var exitName = el('div', { class: 's5-exit-name' });
		var exitMeta = el('div', { class: 's5-meta' });
		var changeBtn = el('button', { class: 'cbi-button cbi-button-action', type: 'button', 'aria-expanded': 'false', click: function() { togglePicker(); } }, '更换节点');
		var enableBtn = el('button', { class: 'cbi-button cbi-button-apply', type: 'button', hidden: true, click: function() { runEnable(); } }, '启用 SOCKS5');
		var ipv4Input = el('input', { type: 'checkbox', 'aria-label': '仅 IPv4 出口', change: function() { runIpv4(ipv4Input.checked); } });
		var ipv4State = el('span', { class: 's5-note' });
		var exitMsg = el('div', { class: 's5-msg', 'aria-live': 'polite' });

		var subsBox = el('div', { class: 's5-subs', role: 'tablist', 'aria-label': '订阅' });
		var subNote = el('div', { class: 's5-note' });
		var search = el('input', { type: 'search', placeholder: '搜索节点或地区', 'aria-label': '搜索节点' });
		var regionSelect = el('select', { 'aria-label': '按地区筛选', change: function() { filter.region = regionSelect.value; buildRows(); } });
		var benchBtn = el('button', { class: 'cbi-button cbi-button-neutral s5-busyable', type: 'button', click: function() { runBench(); } }, '全部测速');
		var list = el('div', { class: 's5-list', role: 'listbox', 'aria-label': '出口节点' });
		var listFoot = el('div', { class: 's5-list-foot s5-note' });
		var picker = el('div', { class: 's5-picker', hidden: true }, [
			subsBox, subNote, el('div', { class: 's5-filter' }, [search, regionSelect, benchBtn]), list, listFoot
		]);

		var probeBtn = el('button', { class: 'cbi-button cbi-button-neutral', type: 'button', click: function() { runProbe(true); } }, '检测');
		var probeBody = el('div');
		var probeMsg = el('div', { class: 's5-msg' });

		var settingsBox = el('details', {});
		var settingsMsg = el('div', { class: 's5-msg', 'aria-live': 'polite' });
		var howBox = el('div');
		var toastBox = null;

		var card = function(children) { return el('div', { class: 'cbi-section s5-card' }, children); };

		var root = el('div', { class: 's5' }, [
			el('style', {}, CSS),
			el('h2', { name: 'content' }, 'SOCKS5 出口'),
			el('div', { class: 's5-top' }, [pill, subline]),
			banner,
			card([
				el('div', { class: 's5-exit' }, [
					el('div', { style: 'min-width:0;flex:1' }, [el('div', { class: 's5-label' }, '当前出口'), exitName, exitMeta]),
					el('div', { class: 's5-actions' }, [changeBtn, enableBtn])
				]),
				el('div', { class: 's5-switch-row' }, [
					el('label', { class: 's5-switch' }, [ipv4Input, el('span', {})]),
					el('div', {}, [
						el('div', {}, [el('b', {}, '仅 IPv4 出口'), ' ', ipv4State]),
						el('div', { class: 's5-note' }, '网站一律按 IPv4 地址访问，不让节点改走 IPv6。开启后普通 HTTP、QUIC（HTTP/3）和只有 IPv6 的网站打不开，浏览器会自动改用 HTTPS/TCP。')
					])
				]),
				exitMsg,
				picker
			]),
			card([
				el('div', { class: 's5-card-head' }, [el('div', { class: 's5-title' }, '出口地区检测'), probeBtn]),
				probeBody,
				probeMsg
			]),
			card([settingsBox, settingsMsg]),
			card([el('div', { class: 's5-card-head' }, el('div', { class: 's5-title' }, '怎么连')), howBox])
		]);

		/* ---------- 通用 ---------- */

		function toast(text) {
			if (toastBox && toastBox.parentNode) toastBox.parentNode.removeChild(toastBox);
			toastBox = el('div', { class: 's5-toast', role: 'status' }, text);
			document.body.appendChild(toastBox);
			var box = toastBox;
			setTimeout(function() { if (box.parentNode) box.parentNode.removeChild(box); }, 2600);
		}

		function say(box, cls, text) {
			box.className = 's5-msg' + (cls ? ' ' + cls : '');
			setText(box, text);
		}

		function spinning(text) {
			return [el('span', { class: 's5-spin', 'aria-hidden': 'true' }), text];
		}

		function currentFile() {
			return st.subscription && st.subscription.file || null;
		}

		function subLabel(file) {
			return String(file || '').replace(/\.ya?ml$/, '');
		}

		function setBusy(name) {
			busy = name || '';
			var off = !!busy;
			changeBtn.disabled = off || !st.enabled;
			ipv4Input.disabled = off || !st.enabled || !(st.shim && st.shim.binary);
			probeBtn.disabled = off || !st.enabled;
			enableBtn.disabled = off;
			benchBtn.disabled = off || !st.enabled || browse !== currentFile();
			Array.prototype.forEach.call(root.querySelectorAll('.s5-busyable'), function(b) { if (b !== benchBtn) b.disabled = off; });
			Array.prototype.forEach.call(list.querySelectorAll('.s5-pick'), function(b) { b.disabled = off; });
			Array.prototype.forEach.call(list.querySelectorAll('.s5-ping'), function(b) { b.disabled = off || b.getAttribute('data-can') !== '1' || b.getAttribute('data-running') === '1'; });
		}

		function host() {
			return st.listen && st.listen !== '0.0.0.0' ? st.listen : (location.hostname || '192.168.0.242');
		}

		/* ---------- 状态 ---------- */

		function stateOf() {
			if (st.error === 'LOAD_FAILED') return { text: '读取失败', cls: 'bad' };
			if (!st.enabled) return { text: st.error ? '异常' : '已停用', cls: st.error ? 'bad' : '' };
			if (st.error) return { text: '异常', cls: 'bad' };
			return st.applied ? { text: '运行中', cls: 'ok' } : { text: '未生效', cls: 'warn' };
		}

		function renderHead() {
			var s = stateOf();
			clear(pill).appendChild(el('span', { class: 's5-dot' }));
			pill.appendChild(document.createTextNode(s.text));
			pill.className = 's5-pill' + (s.cls ? ' ' + s.cls : '');
			setText(subline, st.port ? [host() + ':' + st.port, '账号 ' + (st.username || '—'), 'UDP ' + (st.udp ? '已开' : '关闭'),
				currentFile() ? '订阅 ' + subLabel(currentFile()) : null, st.listen === '127.0.0.1' ? '仅本机' : null]
				.filter(Boolean).join(' · ') : '');
		}

		function renderBanner() {
			clear(banner);
			var code = st.error;
			banner.hidden = !code;
			if (!code) return;
			banner.className = 's5-banner' + (code === 'TARGET_MISSING' || code === 'SUBSCRIPTION_MISSING' ? ' warn' : '');
			var text = st.message || '状态异常。';
			if (st.hook_error && st.hook_error.error && st.hook_error.error !== code)
				text += ' 上次 OpenClash 重建配置时：' + (st.hook_error.message || st.hook_error.error) + '。';
			banner.appendChild(el('span', {}, text));
			var actions = el('div', { class: 's5-actions' });
			if (['NOT_APPLIED', 'STATE_MISMATCH', 'IPV4_SERVICE', 'CORE_FAILED'].indexOf(code) >= 0 && st.enabled)
				actions.appendChild(el('button', { class: 'cbi-button cbi-button-apply s5-busyable', type: 'button', click: runRepair }, '修复'));
			if (code === 'TARGET_MISSING' || code === 'SUBSCRIPTION_MISSING')
				actions.appendChild(el('button', { class: 'cbi-button cbi-button-action s5-busyable', type: 'button', click: function() { togglePicker(true); } }, '重新选择出口'));
			if (actions.firstChild) banner.appendChild(actions);
		}

		function renderExit() {
			var ex = st.exit || {};
			var now = ex.now || st.target || '';
			changeBtn.hidden = !st.enabled;
			enableBtn.hidden = !!st.enabled;
			clear(exitMeta);
			if (!st.enabled) {
				setText(exitName, '已停用');
				exitMeta.appendChild(el('span', {}, st.password_set ? '保存过的出口：' + (st.target || '—') : '先在下方「连接设置」里设置密码，再启用。'));
			} else if (now === 'DIRECT' || now === 'REJECT') {
				setText(exitName, now === 'DIRECT' ? '直连（不走节点）' : '拒绝（全部断开）');
			} else {
				setText(exitName, now || '—');
				if (ex.type) exitMeta.appendChild(el('span', { class: 's5-badge' }, ex.type));
				exitMeta.appendChild(el('span', {}, ['延迟 ', el('span', { class: 's5-ms ' + delayClass(ex.delay) }, delayText(ex.delay))]));
				exitMeta.appendChild(el('button', { class: 's5-link s5-busyable', type: 'button', click: runDelay }, '测速'));
			}
			if (st.enabled && currentFile()) {
				exitMeta.appendChild(el('span', {}, ['订阅 ', el('b', {}, subLabel(currentFile())),
					st.subscription && st.subscription.active ? el('span', { class: 's5-badge', style: 'margin-left:.35rem' }, 'OpenClash 也在用') : null]));
			}
			ipv4Input.checked = !!st.ipv4_only;
			if (st.shim && !st.shim.binary) setText(ipv4State, '（路由器上没有 sing-box，不能开启）');
			else if (st.ipv4_only) setText(ipv4State, st.shim && st.shim.running ? '· 已开启' : '· 已开启，但转发进程没在运行');
			else setText(ipv4State, '· 关闭（节点自己选 IPv4/IPv6）');
			setBusy(busy);
		}

		function renderSettings() {
			clear(settingsBox);
			var portInput = el('input', { type: 'number', min: '1', max: '65535', step: '1', value: String(st.port || 7896) });
			var portMsg = el('div', { class: 's5-note' });
			var checkSeq = 0;
			var checkPort = function() {
				var port = String(portInput.value || '').trim();
				if (!/^\d{1,5}$/.test(port) || +port < 1 || +port > 65535) return setText(portMsg, '端口必须是 1–65535 的整数。');
				var seq = ++checkSeq;
				setText(portMsg, '检测中…');
				call(['check-port', port]).then(function(r) {
					if (seq !== checkSeq) return;
					setText(portMsg, r.reserved ? '端口 ' + port + ' 是 OpenClash 或本模块内部在用的，换一个。' :
						r.free ? '端口 ' + port + ' 空闲，可以用。' :
						r.own ? '端口 ' + port + ' 正由本模块使用。' :
						'端口 ' + port + ' 已被 ' + (r.owner ? r.owner.name + '（pid ' + r.owner.pid + '）' : '其他程序') + ' 占用。');
				}).catch(function(e) { if (seq === checkSeq) setText(portMsg, errorText(e)); });
			};
			portInput.addEventListener('change', checkPort);
			var listenSelect = el('select', {}, (st.listen_options || ['0.0.0.0']).map(function(a) {
				return el('option', { value: a, selected: a === st.listen },
					a === '0.0.0.0' ? '0.0.0.0 — 所有网卡（局域网可用）' : a === '127.0.0.1' ? '127.0.0.1 — 仅本机' : a);
			}));
			var userInput = el('input', { type: 'text', value: st.username || 'r3mini', autocomplete: 'off', spellcheck: 'false' });
			var passInput = el('input', { type: 'password', value: '', autocomplete: 'new-password',
				placeholder: st.password_set ? '留空 = 不修改（当前 ' + st.password_length + ' 位）' : '至少 4 位' });
			var udpInput = el('input', { type: 'checkbox', checked: st.udp !== false });
			var showBtn = el('button', { class: 'cbi-button cbi-button-neutral', type: 'button', click: function() {
				passInput.type = passInput.type === 'password' ? 'text' : 'password';
				setText(showBtn, passInput.type === 'password' ? '显示' : '隐藏');
			} }, '显示');
			var genBtn = el('button', { class: 'cbi-button cbi-button-neutral', type: 'button', click: function() {
				var abc = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789', bytes = new Uint8Array(16), out = '';
				(window.crypto || window.msCrypto).getRandomValues(bytes);
				for (var i = 0; i < bytes.length; i++) out += abc[bytes[i] % abc.length];
				passInput.value = out;
				passInput.type = 'text';
				setText(showBtn, '隐藏');
			} }, '随机生成');
			var saveBtn = el('button', { class: 'cbi-button cbi-button-apply s5-busyable', type: 'button', click: function() {
				var port = Number(String(portInput.value || '').trim());
				if (!(port >= 1 && port <= 65535 && Math.floor(port) === port)) return say(settingsMsg, 'bad', '端口必须是 1–65535 的整数。');
				var payload = { port: port, listen: listenSelect.value, username: String(userInput.value || '').trim(), udp: !!udpInput.checked, enabled: true };
				if (passInput.value) payload.password = passInput.value;
				if (!st.password_set && !payload.password) return say(settingsMsg, 'bad', '第一次启用必须设置密码。');
				runSave(payload, passInput);
			} }, st.enabled ? '保存连接设置' : '保存并启用');
			var offBtn = el('button', { class: 'cbi-button cbi-button-reset s5-busyable', type: 'button', hidden: !st.enabled, click: runDisable }, '停用 SOCKS5');
			settingsBox.open = !st.password_set;
			settingsBox.appendChild(el('summary', {}, '连接设置（端口、账号、密码、UDP）'));
			settingsBox.appendChild(el('div', { style: 'margin-top:.9rem' }, [
				el('div', { class: 's5-grid' }, [
					el('div', { class: 's5-field' }, [el('label', {}, '端口'), portInput, portMsg]),
					el('div', { class: 's5-field' }, [el('label', {}, '监听地址'), listenSelect]),
					el('div', { class: 's5-field' }, [el('label', {}, '账号'), userInput, el('div', { class: 's5-note' }, '字母、数字与 . _ -')]),
					el('div', { class: 's5-field' }, [el('label', {}, '密码'), el('div', { class: 's5-inline' }, [passInput, showBtn, genBtn]),
						el('div', { class: 's5-note' }, '4–128 位，不能有空格和冒号；页面不回显已存密码。')])
				]),
				el('label', { style: 'display:flex;gap:.5rem;align-items:center;margin-top:.8rem' }, [udpInput, '同时转发 UDP（语音、游戏、WebRTC 需要）']),
				el('div', { class: 's5-note', style: 'margin-top:.6rem' }, '保存只动 SOCKS5 自己的内核，路由器上其他设备不受影响；改端口、账号、密码时，正在用 SOCKS5 的连接会断开一下。'),
				el('div', { class: 's5-actions', style: 'margin-top:.8rem' }, [saveBtn, offBtn])
			]));
		}

		function renderHow() {
			clear(howBox);
			var addr = host() + ':' + (st.port || 7896);
			var row = function(label, value, copy) {
				return [el('dt', {}, label), el('dd', {}, [el('span', { class: 's5-mono' }, value), copy ? ' ' : null, copy ?
					el('button', { class: 's5-link', type: 'button', click: function() {
						copyText(value).then(function() { toast('已复制：' + value); }, function(e) { toast(e.message); });
					} }, '复制') : null])];
			};
			howBox.appendChild(el('dl', { class: 's5-kv' }, [].concat(
				row('类型', 'SOCKS5'),
				row('地址与端口', addr, true),
				row('账号', st.username || 'r3mini', true),
				row('密码', st.password_set ? '已设置（' + st.password_length + ' 位，页面不显示）' : '未设置'),
				row('测试命令', 'curl --socks5-hostname ' + addr + " --proxy-user '" + (st.username || 'r3mini') + ":密码' https://www.gstatic.com/generate_204 -v", true)
			)));
		}

		function renderAll() {
			renderHead();
			renderBanner();
			renderExit();
			renderHow();
		}

		/* ---------- 节点选择器 ---------- */

		function loadList(file, force) {
			if (loading[file] && !force) return loading[file];
			if (!lists[file] || force) clear(list).appendChild(el('div', { class: 's5-empty' }, spinning('正在读取 ' + subLabel(file) + ' 的节点…')));
			loading[file] = call(file ? ['targets', b64(file)] : ['targets']).then(function(t) {
				lists[t.file] = t;
				loading[file] = null;
				if (!browse) browse = t.file;
				if (browse === t.file) { buildSubs(); buildRegions(); buildRows(); }
				return t;
			}).catch(function(e) {
				loading[file] = null;
				if (browse === file || !browse)
					clear(list).appendChild(el('div', { class: 's5-empty' }, [errorText(e), ' ',
						el('button', { class: 's5-link', type: 'button', click: function() { loadList(file, true); } }, '重试')]));
			});
			return loading[file];
		}

		function data() {
			return browse && lists[browse] || null;
		}

		function buildSubs() {
			clear(subsBox);
			var t = data();
			var subs = t ? t.subscriptions : [];
			subs.forEach(function(s) {
				var on = s.file === browse;
				subsBox.appendChild(el('button', {
					class: 's5-sub-tab' + (on ? ' on' : ''), type: 'button', role: 'tab', 'aria-selected': on ? 'true' : 'false',
					click: function() { if (s.file !== browse) switchSub(s.file); }
				}, [s.name, s.file === currentFile() ? el('small', {}, '· SOCKS5 在用') : null, s.active ? el('small', {}, '· OpenClash') : null]));
			});
			var cur = currentFile();
			setText(subNote, browse && cur && browse !== cur
				? '这是另一个订阅：点下面的节点，SOCKS5 会换到「' + subLabel(browse) + '」，路由器其他设备照旧用 OpenClash 的配置。'
				: '「OpenClash」标记的是路由器其他设备正在用的配置；SOCKS5 可以用任意一个订阅，互不影响。');
		}

		function nodesOf(t) {
			return (t && t.nodes || []).filter(function(n) { return !INFO_NODE.test(n.name); });
		}

		function buildRegions() {
			var t = data();
			var nodes = nodesOf(t);
			var groups = {}, order = [];
			nodes.forEach(function(n) {
				var info = parseNode(n.name);
				if (!groups[info.key]) { groups[info.key] = { label: info.code ? regionName(info.code) : info.region, count: 0 }; order.push(info.key); }
				groups[info.key].count++;
			});
			order.sort(function(a, b) { return groups[b].count - groups[a].count || groups[a].label.localeCompare(groups[b].label, 'zh'); });
			if (filter.region && !groups[filter.region]) filter.region = '';
			clear(regionSelect).appendChild(el('option', { value: '' }, '全部地区（' + nodes.length + '）'));
			order.forEach(function(k) {
				regionSelect.appendChild(el('option', { value: k, selected: k === filter.region }, groups[k].label + '（' + groups[k].count + '）'));
			});
			regionSelect.value = filter.region;
		}

		function buildRows() {
			var t = data();
			clear(list);
			if (!t) return;
			var cur = browse === currentFile() ? ((st.exit && st.exit.now) || st.target) : null;
			var text = filter.text.trim().toLowerCase();
			var all = nodesOf(t);
			var hidden = (t.nodes || []).length - all.length;
			var shown = 0;
			var frag = document.createDocumentFragment();
			all.forEach(function(n) {
				var info = parseNode(n.name);
				if (filter.region && info.key !== filter.region) return;
				if (text && (n.name + ' ' + info.region + ' ' + (REGION[info.code] || '')).toLowerCase().indexOf(text) < 0) return;
				shown++;
				var current = n.name === cur;
				var pick = el('button', { class: 's5-pick', type: 'button', title: n.name, click: function() { runUse(n.name, row, pick); } }, [
					el('span', { class: 's5-cc' }, info.code || '—'),
					el('span', { class: 'nm' }, info.code ? info.rest || n.name : n.name),
					el('span', { class: 'ty' }, n.type || ''),
					current ? el('span', { class: 's5-badge blue' }, '当前') : null
				]);
				var row = el('div', { class: 's5-row' + (current ? ' cur' : ''), role: 'option', 'aria-selected': current ? 'true' : 'false' },
					[pick, pingButton(n, t)]);
				frag.appendChild(row);
			});
			if (!shown) frag.appendChild(el('div', { class: 's5-empty' }, all.length ? '没有匹配的节点。' : '这个订阅里没有节点。'));
			list.appendChild(frag);
			clear(listFoot).appendChild(el('span', {}, '共 ' + all.length + ' 个节点' + (shown !== all.length ? '，显示 ' + shown + ' 个' : '') +
				(hidden ? '；另有 ' + hidden + ' 条订阅信息（剩余流量、到期时间）已隐藏' : '')));
			listFoot.appendChild(el('span', {}, canPing(t) ? '点右边的延迟单独测速' : '换到这个订阅后才能测速'));
			setBusy(busy);
			var row = list.querySelector('.s5-row.cur');
			if (row && scrollPending) {
				scrollPending = false;
				list.scrollTop = row.getBoundingClientRect().top - list.getBoundingClientRect().top + list.scrollTop - (list.clientHeight - row.offsetHeight) / 2;
			}
		}

		// 能测速的：SOCKS5 正在用的订阅（SOCKS5 内核测），或 OpenClash 正在用的订阅（OpenClash 测）。
		function canPing(t) {
			if (!t) return false;
			if (t.file === currentFile() && st.enabled) return true;
			return (t.subscriptions || []).some(function(s) { return s.active && s.file === t.file; });
		}

		function pingLabel(btn, n) {
			clear(btn);
			if (n.failed) btn.appendChild(el('span', { class: 's5-ms slow' }, '超时'));
			else if (n.delay) btn.appendChild(el('span', { class: 's5-ms ' + delayClass(n.delay) }, n.delay + ' ms'));
			else btn.appendChild(el('span', { class: canPing(lists[btn.getAttribute('data-file')]) ? 's5-hint' : 's5-ms none' },
				canPing(lists[btn.getAttribute('data-file')]) ? '测速' : '—'));
		}

		function pingButton(n, t) {
			var can = canPing(t);
			var btn = el('button', {
				class: 's5-ping', type: 'button', 'data-file': t.file, 'data-can': can ? '1' : '0',
				title: can ? '测一下「' + n.name + '」的延迟' : '换到这个订阅后才能测速', 'aria-label': '测速 ' + n.name,
				click: function(ev) { ev.stopPropagation(); runPing(n, t.file, btn); }
			});
			btn.disabled = !can;
			pingLabel(btn, n);
			return btn;
		}

		function runPing(n, file, btn) {
			if (btn.disabled) return;
			btn.disabled = true;
			btn.setAttribute('data-running', '1');
			clear(btn).appendChild(el('span', { class: 's5-spin', 'aria-hidden': 'true' }));
			var args = ['delay', b64(n.name)];
			if (file !== currentFile()) args.push(b64(file));
			call(args).then(function(r) {
				n.delay = r.delay;
				n.failed = false;
			}).catch(function(e) {
				n.delay = null;
				n.failed = !(e.data && e.data.error === 'DELAY_UNAVAILABLE');
				if (!n.failed) toast(errorText(e));
			}).then(function() {
				btn.removeAttribute('data-running');
				btn.disabled = !!busy;
				pingLabel(btn, n);
				if (st.exit && st.exit.now === n.name && file === currentFile()) { st.exit.delay = n.delay; renderExit(); }
			});
		}

		function switchSub(file) {
			browse = file;
			filter.region = '';
			scrollPending = file === currentFile();
			buildSubs();
			if (lists[file]) { buildRegions(); buildRows(); }
			else { clear(regionSelect); loadList(file); }
		}

		var searchTimer = null;
		search.addEventListener('input', function() {
			clearTimeout(searchTimer);
			searchTimer = setTimeout(function() { filter.text = search.value; buildRows(); }, 120);
		});

		function togglePicker(force) {
			var open = force === true ? true : picker.hidden;
			picker.hidden = !open;
			setText(changeBtn, open ? '收起' : '更换节点');
			changeBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
			if (!open) return;
			scrollPending = true;
			if (!browse || !lists[browse]) {
				browse = currentFile();
				loadList(browse);
			} else {
				buildSubs(); buildRegions(); buildRows();
			}
		}

		/* ---------- 出口地区检测 ---------- */

		var CACHE_KEY = 'r3mini-socks5-probe2';
		var foldOpen = false;

		function probeKey() {
			return [currentFile(), (st.exit && st.exit.now) || st.target, st.ipv4_only ? 4 : 0].join('|');
		}

		function names(items) {
			return items.map(function(c) { return c.name; }).join('、');
		}

		function renderProbe(r, when) {
			clear(probeBody);
			if (!r) {
				probeBody.appendChild(el('div', { class: 's5-note' }, st.enabled
					? '点「检测」，看 Google、Cloudflare、Apple 和 IP 地址库各自把这个出口判成哪里（约 5 秒）。'
					: '启用后可检测。'));
				return;
			}
			var checks = (r.checks || []).filter(function(c) { return c && c.id; });
			var groups = [];
			checks.forEach(function(c) {
				if (!c.region) return;
				var g = groups.filter(function(x) { return x.code === c.region; })[0];
				if (!g) groups.push(g = { code: c.region, list: [] });
				g.list.push(c);
			});
			groups.sort(function(a, b) { return b.list.length - a.list.length; });
			var major = groups[0];
			probeBody.appendChild(el('div', { class: 's5-regions' }, groups.length ? groups.map(function(g, i) {
				return el('div', { class: 's5-region' + (i > 0 ? ' minor' : '') }, [el('b', {}, regionName(g.code)), el('span', {}, names(g.list))]);
			}) : el('div', { class: 's5-note' }, '各家都没取到地区。')));
			var ips = {}, order = [];
			checks.forEach(function(c) {
				if (!c.ip) return;
				if (!ips[c.ip]) { ips[c.ip] = { family: c.family, list: [] }; order.push(c.ip); }
				ips[c.ip].list.push(c);
			});
			if (order.length) {
				probeBody.appendChild(el('div', { class: 's5-meta' }, [el('span', { class: 's5-label' }, order.length > 1 ? '各家看到的出口 IP' : '出口 IP')].concat(order.map(function(ip) {
					return el('span', {}, [el('span', { class: 's5-mono' }, ip), ' ', el('span', { class: 's5-badge' }, ips[ip].family || '?'),
						order.length > 1 ? ' ' + names(ips[ip].list) : null]);
				}))));
			}
			var v6 = checks.filter(function(c) { return c.family === 'IPv6'; });
			if (r.ipv4_only && v6.length)
				probeBody.appendChild(el('div', { class: 's5-msg bad' }, '「仅 IPv4」开着，但 ' + names(v6) + ' 看到的还是 IPv6 地址。点上方「修复」后再检测一次。'));
			else if (!r.ipv4_only && v6.length && v6.length < checks.filter(function(c) { return c.ip; }).length)
				probeBody.appendChild(el('div', { class: 's5-msg warn' }, names(v6) + ' 走的是 IPv6，其余是 IPv4。想统一用 IPv4，打开上面的「仅 IPv4 出口」。'));
			if (groups.length > 1) {
				var odd = groups.slice(1).map(function(g) { return names(g.list) + ' 判为 ' + regionName(g.code); }).join('；');
				var google = groups.slice(1).some(function(g) { return g.list.some(function(c) { return c.id === 'google'; }); });
				probeBody.appendChild(el('div', { class: 's5-msg warn' }, '各家判定不一致：' + odd + '，其余判为 ' + regionName(major.code) + '。' +
					(google ? 'YouTube、Google Play 会按 Google 的判定处理。' : '用到这些服务时按它们自己的判定处理。') +
					'切换 IPv4/IPv6 一般改变不了，只能换节点。'));
			} else if (major) {
				var nodeCode = parseNode(r.exit || '').code;
				if (nodeCode && nodeCode !== major.code)
					probeBody.appendChild(el('div', { class: 's5-msg warn' }, '节点名写的是 ' + regionName(nodeCode) + '，但各家都判为 ' + regionName(major.code) + '。'));
			}
			var got = checks.filter(function(c) { return c.region; }).length;
			var fold = el('details', { class: 's5-fold' }, [
				el('summary', {}, '各家详情（' + got + '/' + checks.length + ' 家取到地区）'),
				el('div', { class: 's5-checks' }, checks.map(function(c) {
					return el('div', { class: 's5-check' }, [
						el('div', {}, [el('b', {}, c.name), el('div', { class: 's5-note' }, c.note || '')]),
						el('div', { class: c.region ? 's5-big' : 's5-note' }, c.region ? regionName(c.region) : '没取到'),
						el('div', { class: 's5-check-ip' }, [
							c.ip ? el('span', {}, [el('span', { class: 's5-mono' }, c.ip), ' ', el('span', { class: 's5-badge' }, c.family || '?')])
								: el('span', { class: 's5-note' }, c.id === 'apple' ? '只给地区' : '—'),
							c.detail ? el('div', { class: 's5-note' }, c.detail) : null
						])
					]);
				}))
			]);
			fold.open = foldOpen;
			fold.addEventListener('toggle', function() { foldOpen = fold.open; });
			probeBody.appendChild(fold);
			probeBody.appendChild(el('div', { class: 's5-note', style: 'margin-top:.5rem' },
				(r.exit ? '出口 ' + r.exit + ' · ' : '') + (r.ipv4_only ? '仅 IPv4 · ' : '') + (when ? timeText(when) : '') +
				(r.elapsed_ms ? '（用时 ' + (r.elapsed_ms / 1000).toFixed(1) + ' 秒）' : '')));
		}

		function runProbe() {
			if (!st.enabled) return;
			var seq = ++probeSeq;
			probeBtn.disabled = true;
			clear(probeBody).appendChild(el('div', { class: 's5-note' }, spinning('正在经 SOCKS5 访问 Google、Cloudflare、Apple、ipinfo、MaxMind…')));
			say(probeMsg, '', '');
			return call(['probe']).then(function(r) {
				if (seq !== probeSeq) return;
				var when = new Date();
				renderProbe(r, when);
				try { localStorage.setItem(CACHE_KEY, JSON.stringify({ key: probeKey(), at: when.getTime(), r: r })); } catch (e) {}
			}).catch(function(e) {
				if (seq !== probeSeq) return;
				renderProbe(e.data && e.data.checks ? e.data : null);
				say(probeMsg, 'bad', '检测失败：' + errorText(e));
			}).then(function() {
				if (seq === probeSeq) probeBtn.disabled = !!busy || !st.enabled;
			});
		}

		function restoreProbe() {
			try {
				var cached = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
				if (cached && cached.key === probeKey() && Date.now() - cached.at < 30 * 60 * 1000) {
					renderProbe(cached.r, new Date(cached.at));
					return true;
				}
			} catch (e) {}
			renderProbe(null);
			return false;
		}

		/* ---------- 动作 ---------- */

		function refresh() {
			return call(['status']).then(function(next) { st = next; renderAll(); return next; });
		}

		function runUse(name, row, pick) {
			if (busy) return;
			var cur = currentFile();
			var switching = browse && cur && browse !== cur;
			if (!switching && name === ((st.exit && st.exit.now) || st.target)) { togglePicker(); return; }
			setBusy('use');
			if (row) row.classList.add('busy');
			if (pick) clear(pick.firstChild).appendChild(el('span', { class: 's5-spin', 'aria-hidden': 'true' }));
			say(exitMsg, '', '');
			var target = browse;
			call(switching ? ['use', b64(name), b64(target)] : ['use', b64(name)]).then(function(r) {
				st = r;
				setBusy('');
				renderAll();
				togglePicker(false);
				toast('已切换到 ' + name + (switching ? '（订阅 ' + subLabel(target) + '）' : '') + (r.closed ? '，断开了 ' + r.closed + ' 条旧连接' : ''));
				runProbe();
			}).catch(function(e) {
				setBusy('');
				buildRows();
				say(exitMsg, 'bad', '切换失败：' + errorText(e));
			});
		}

		function runBench() {
			if (busy || browse !== currentFile()) return;
			setBusy('bench');
			var label = benchBtn.textContent;
			clear(benchBtn).appendChild(el('span', {}, spinning('测速中')));
			call(['delay-all']).then(function(r) {
				var t = lists[browse];
				var delays = r.delays || {};
				if (t) t.nodes.forEach(function(n) { n.delay = delays[n.name] || null; n.failed = !delays[n.name]; });
				setText(benchBtn, label);
				setBusy('');
				buildRows();
				toast(Object.keys(delays).length + ' 个节点有响应');
			}).catch(function(e) {
				setText(benchBtn, label);
				setBusy('');
				say(exitMsg, 'bad', '测速失败：' + errorText(e));
			});
		}

		function runIpv4(on) {
			if (busy) return;
			setBusy('ipv4');
			setText(ipv4State, on ? '· 正在开启…' : '· 正在关闭…');
			say(exitMsg, '', '');
			call(['ipv4', on ? 'on' : 'off']).then(function(r) {
				st = r;
				setBusy('');
				renderAll();
				toast(on ? '已开启仅 IPv4' : '已关闭仅 IPv4');
				runProbe();
			}).catch(function(e) {
				setBusy('');
				ipv4Input.checked = !on;
				renderExit();
				say(exitMsg, 'bad', (on ? '开启' : '关闭') + '失败：' + errorText(e));
			});
		}

		function runDelay() {
			if (busy) return;
			setBusy('delay');
			call(['delay']).then(function(r) {
				setBusy('');
				if (st.exit) st.exit.delay = r.delay;
				renderExit();
				toast((r.name || '当前出口') + '：' + r.delay + ' ms');
			}).catch(function(e) {
				setBusy('');
				if (st.exit) st.exit.delay = null;
				renderExit();
				say(exitMsg, 'bad', errorText(e));
			});
		}

		function runRepair(quiet) {
			if (busy) return;
			setBusy('apply');
			if (quiet !== true) {
				clear(exitMsg).appendChild(el('span', {}, spinning('正在重新应用…')));
				exitMsg.className = 's5-msg';
			}
			return call(['apply']).then(function(r) {
				st = r;
				setBusy('');
				if (quiet !== true) say(exitMsg, r.error ? 'warn' : 'ok', r.error ? (r.message || '已应用，但状态仍有异常。') : '已修复。');
				renderAll();
				lists = {};
				if (!picker.hidden) loadList(browse = currentFile(), true);
			}).catch(function(e) {
				setBusy('');
				say(exitMsg, 'bad', (quiet === true ? '同步订阅失败：' : '修复失败：') + errorText(e));
			});
		}

		function runSave(payload, passInput) {
			if (busy) return;
			setBusy('save');
			clear(settingsMsg).appendChild(el('span', {}, spinning('正在保存…')));
			settingsMsg.className = 's5-msg';
			call(['save', b64(JSON.stringify(payload))]).then(function(r) {
				st = r;
				setBusy('');
				if (passInput) passInput.value = '';
				renderSettings();
				renderAll();
				say(settingsMsg, r.error ? 'warn' : 'ok', r.error ? '已保存，但：' + (r.message || r.error) : '已保存并生效。');
			}).catch(function(e) {
				setBusy('');
				say(settingsMsg, 'bad', '保存失败：' + errorText(e));
			});
		}

		function runEnable() {
			if (!st.password_set) {
				settingsBox.open = true;
				say(settingsMsg, 'warn', '先设置密码，再点「保存并启用」。');
				return;
			}
			if (busy) return;
			setBusy('enable');
			say(exitMsg, '', '');
			call(['enable']).then(function(r) {
				st = r;
				setBusy('');
				renderSettings();
				renderAll();
				restoreProbe() || runProbe();
				toast('SOCKS5 已启用');
			}).catch(function(e) {
				setBusy('');
				say(exitMsg, 'bad', '启用失败：' + errorText(e));
			});
		}

		function runDisable() {
			if (busy) return;
			if (!window.confirm('停用后 ' + host() + ':' + st.port + ' 不再接受连接，正在用的设备会断开。确定停用？')) return;
			setBusy('disable');
			call(['disable']).then(function(r) {
				st = r;
				setBusy('');
				renderSettings();
				renderAll();
				renderProbe(null);
				toast('SOCKS5 已停用');
			}).catch(function(e) {
				setBusy('');
				say(settingsMsg, 'bad', '停用失败：' + errorText(e));
			});
		}

		// OpenClash 更新了订阅文件：静默同步一次，节点和账号信息跟上。
		function syncIfStale() {
			if (synced || busy || !st.enabled || !(st.subscription && st.subscription.stale)) return;
			synced = true;
			runRepair(true).then(function() { if (!st.error) toast('订阅有更新，已同步节点'); });
		}

		/* ---------- 启动 ---------- */

		renderSettings();
		renderAll();
		if (st.error === 'TARGET_MISSING' || st.error === 'SUBSCRIPTION_MISSING') togglePicker(true);
		if (st.enabled && !st.error && !restoreProbe()) runProbe();
		else if (!st.enabled || st.error) restoreProbe();
		syncIfStale();

		poll.add(function() {
			if (busy || document.visibilityState === 'hidden') return Promise.resolve();
			var before = probeKey();
			return refresh().then(function() {
				if (probeKey() !== before) restoreProbe();
				syncIfStale();
			}).catch(function() {});
		}, 20);

		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
