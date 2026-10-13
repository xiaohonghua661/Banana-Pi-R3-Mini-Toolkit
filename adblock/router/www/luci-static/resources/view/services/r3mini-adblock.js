'use strict';
'require view';
'require fs';
'require ui';

var HELPER = '/usr/sbin/r3mini-adblock';

function parse(result) {
	if (!result || result.code !== 0)
		throw new Error(((result && (result.stderr || result.stdout)) || '广告过滤接口无响应').trim());
	return JSON.parse(result.stdout);
}

function sourceName(url) {
	if (/AWAvenue-Ads-Rule/.test(url)) return '秋风广告规则' + (/Only\.Ads/.test(url) ? '（仅广告）' : '');
	return url.replace(/^https?:\/\//, '').replace(/[?#].*$/, '');
}

var RESULT = { ok: '成功', unchanged: '成功', partial: '部分失败', failed: '失败' };

var CSS = '\
#view .r3ab{max-width:880px;margin:0 auto;padding:16px 10px 40px;color:#14231f;font-family:"Noto Sans SC","Microsoft YaHei",sans-serif}\
.r3ab *{box-sizing:border-box}\
.r3ab-head{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;margin-bottom:12px;padding:16px 18px;border:1px solid #dbe3df;border-radius:12px;background:linear-gradient(135deg,#fff 58%,#edf6f2)}\
.r3ab-head h2{margin:0;color:#0e4938!important;font-size:26px;font-weight:750;letter-spacing:-.03em;text-shadow:none!important}\
.r3ab-head p{margin:6px 0 0;color:#66736e!important;font-size:12px;line-height:1.7}\
.r3ab-pill{display:flex;align-items:center;gap:8px;padding:7px 11px;border:1px solid #dbe3df;border-radius:8px;background:#fff;color:#66736e;font-size:12px;white-space:nowrap}\
.r3ab-pill i{width:8px;height:8px;border-radius:50%;background:#a96b0a}\
.r3ab-pill.on{color:#0e4938}.r3ab-pill.on i{background:#138564;box-shadow:0 0 0 4px rgba(19,133,100,.12)}\
.r3ab-pill.off i{background:#9aa6a1}\
.r3ab-pill.bad{border-color:#e8b9b5;background:#fff1f0;color:#ba4b4b}.r3ab-pill.bad i{background:#ba4b4b}\
.r3ab-card{margin-top:12px;border:1px solid #dbe3df;border-radius:12px;background:#fff;box-shadow:0 6px 20px rgba(23,43,36,.04)}\
.r3ab-card h3{margin:0;padding:13px 16px 11px;border-bottom:1px solid #dbe3df;font-size:14px;background:none!important;color:#14231f!important}\
.r3ab-row{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:13px 16px;border-bottom:1px solid #eef2f0}\
.r3ab-row:last-child{border-bottom:0}\
.r3ab-row strong{display:block;font-size:13px}\
.r3ab-row span.r3ab-sub{display:block;margin-top:3px;color:#66736e;font-size:11px;line-height:1.5}\
.r3ab-ctl{display:flex;align-items:center;gap:10px;flex:none}\
.r3ab-ctl select{height:34px;min-width:92px;padding:0 6px;border:1px solid #cad5d0;border-radius:7px;background:#fff;font-size:12px}\
.r3ab-switch{position:relative;width:44px;height:24px;flex:none;margin:0}\
.r3ab-switch:after{content:"";position:absolute;inset:-10px -8px}\n.r3ab-switch input{position:absolute;width:0;height:0;opacity:0}\
.r3ab-switch b{position:absolute;inset:0;border-radius:99px;background:#c9d1cd;cursor:pointer;transition:.18s}\
.r3ab-switch b:before{content:"";position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.2);transition:.18s}\
.r3ab-switch input:checked+b{background:#138564}\
.r3ab-switch input:checked+b:before{transform:translateX(20px)}\
.r3ab-switch input:disabled+b{opacity:.5;cursor:wait}\
.r3ab-switch input:focus-visible+b{outline:3px solid rgba(19,133,100,.25);outline-offset:2px}\
.r3ab-grid{display:grid;grid-template-columns:repeat(2,1fr)}\
.r3ab-metric{padding:13px 16px;border-right:1px solid #eef2f0;border-bottom:1px solid #eef2f0}\
.r3ab-metric:nth-child(2n){border-right:0}\
.r3ab-metric small{display:block;color:#66736e;font-size:11px}\
.r3ab-metric strong{display:block;margin-top:5px;color:#0e4938;font-size:15px;word-break:break-all}\
.r3ab-metric em{display:block;margin-top:3px;color:#66736e;font-size:11px;font-style:normal;line-height:1.5}\
.r3ab-metric em.err{color:#ba4b4b}\
.r3ab-actions{display:flex;align-items:center;gap:12px;padding:13px 16px}\
.r3ab-btn{min-height:38px;padding:0 16px;border:1px solid #0e4938;border-radius:7px;background:#0e4938;color:#fff;font-size:13px;font-weight:650;cursor:pointer}\
.r3ab-btn:disabled{opacity:.5;cursor:wait}\
.r3ab-msg{margin:0;color:#66736e;font-size:12px;line-height:1.5}\
.r3ab-msg.ok{color:#138564}.r3ab-msg.err{color:#ba4b4b}\
@media (max-width:640px){.r3ab-head{flex-direction:column;align-items:flex-start}.r3ab-grid{grid-template-columns:1fr}.r3ab-metric{border-right:0}.r3ab-row{align-items:flex-start}}';

return view.extend({
	call: function(args) {
		return fs.exec(HELPER, args).then(parse);
	},

	load: function() {
		return this.call(['status']).catch(function(e) { return { error: e.message }; });
	},

	switchEl: function(id, label) {
		return E('label', { 'class': 'r3ab-switch' }, [
			E('input', { 'id': id, 'type': 'checkbox', 'aria-label': label }), E('b')
		]);
	},

	row: function(title, sub, ctl) {
		return E('div', { 'class': 'r3ab-row' }, [
			E('div', {}, [E('strong', {}, title), E('span', { 'class': 'r3ab-sub' }, sub)]),
			E('div', { 'class': 'r3ab-ctl' }, ctl)
		]);
	},

	metric: function(id, title) {
		return E('div', { 'class': 'r3ab-metric' }, [
			E('small', {}, title), E('strong', { 'id': id }, '--'), E('em', { 'id': id + '-sub' }, '')
		]);
	},

	render: function(st) {
		var self = this;
		var hours = [];
		for (var h = 0; h < 24; h++)
			hours.push(E('option', { 'value': String(h) }, ('0' + h).slice(-2) + ':30'));

		this.root = E('div', { 'class': 'r3ab' }, [
			E('style', {}, CSS),
			E('div', { 'class': 'r3ab-head' }, [
				E('div', {}, [
					E('h2', {}, '广告过滤'),
					E('p', {}, '拦截红果短剧、抖音等 App 里的广告。按域名拦截，App 绕过 DNS 直连 IP 也拦得住；开关和更新立即生效，不重启 OpenClash。')
				]),
				E('div', { 'id': 'r3ab-pill', 'class': 'r3ab-pill' }, [E('i'), E('span', {}, '读取中')])
			]),
			E('div', { 'class': 'r3ab-card' }, [
				E('h3', {}, '开关'),
				this.row('广告过滤', '总开关。关掉后所有经过本机的设备都不再过滤广告。', [this.switchEl('r3ab-enabled', '广告过滤')]),
				this.row('订阅规则', '秋风广告规则（仅广告版），覆盖更多 App 的广告 SDK。关掉后只保留内置的红果 / 抖音规则。', [this.switchEl('r3ab-sub', '订阅规则')]),
				this.row('每天自动更新', '到点自动下载最新订阅规则并生效；下载失败会沿用旧规则。', [
					E('select', { 'id': 'r3ab-hour', 'aria-label': '每天更新时间' }, hours),
					this.switchEl('r3ab-auto', '每天自动更新')
				])
			]),
			E('div', { 'class': 'r3ab-card' }, [
				E('h3', {}, '规则'),
				E('div', { 'class': 'r3ab-grid' }, [
					this.metric('r3ab-active', '正在生效'),
					this.metric('r3ab-builtin', '内置红果 / 抖音规则'),
					this.metric('r3ab-source', '订阅'),
					this.metric('r3ab-last', '上次更新')
				]),
				E('div', { 'class': 'r3ab-actions' }, [
					E('button', { 'id': 'r3ab-update', 'class': 'r3ab-btn' }, '立即更新规则'),
					E('p', { 'id': 'r3ab-msg', 'class': 'r3ab-msg', 'aria-live': 'polite' }, '')
				])
			])
		]);

		var q = function(id) { return self.root.querySelector('#' + id); };
		q('r3ab-enabled').addEventListener('change', function() {
			self.act([this.checked ? 'enable' : 'disable'], this.checked ? '广告过滤已打开' : '广告过滤已关闭');
		});
		q('r3ab-sub').addEventListener('change', function() {
			self.act(['sub', this.checked ? 'on' : 'off'], this.checked ? '订阅规则已打开' : '订阅规则已关闭，只保留内置规则');
		});
		q('r3ab-auto').addEventListener('change', function() {
			self.act(['auto', this.checked ? 'on' : 'off', q('r3ab-hour').value], this.checked ? '已打开每天自动更新' : '已关闭自动更新');
		});
		q('r3ab-hour').addEventListener('change', function() {
			self.act(['auto', q('r3ab-auto').checked ? 'on' : 'off', this.value], '更新时间已改为每天 ' + ('0' + this.value).slice(-2) + ':30');
		});
		q('r3ab-update').addEventListener('click', function() {
			self.act(['update-bg'], null);
		});

		if (st.error) {
			this.busy = false;
			this.show({}, st.error, 'err');
		} else {
			this.show(st);
			if (st.updating) this.watch();
		}
		return this.root;
	},

	act: function(args, okText) {
		var self = this;
		this.setBusy(true);
		this.msg(args[0] === 'update-bg' ? '正在下载订阅规则…' : '正在应用…', '');
		return this.call(args).then(function(st) {
			self.setBusy(false);
			if (st.message && !st.updating)
				self.show(st, st.message, 'err');
			else
				self.show(st, okText, 'ok');
			if (st.updating) self.watch();
		}).catch(function(e) {
			self.setBusy(false);
			self.msg(e.message, 'err');
			return self.refresh();
		});
	},

	watch: function() {
		var self = this;
		this.setBusy(true);
		clearTimeout(this.timer);
		this.timer = setTimeout(function tick() {
			if (!self.root.isConnected) return;
			self.call(['status']).then(function(st) {
				if (st.updating) {
					self.show(st, '正在下载订阅规则…', '');
					self.timer = setTimeout(tick, 2000);
					return;
				}
				self.setBusy(false);
				self.show(st, (st.last_result === 'failed' ? '更新失败：' : '更新完成：') + (st.last_message || ''),
					st.last_result === 'failed' || st.last_result === 'partial' ? 'err' : 'ok');
			}).catch(function() { self.timer = setTimeout(tick, 3000); });
		}, 1500);
	},

	refresh: function() {
		var self = this;
		return this.call(['status']).then(function(st) { self.show(st); }).catch(function() {});
	},

	setBusy: function(busy) {
		this.busy = busy;
		var nodes = this.root.querySelectorAll('input, select, button');
		for (var i = 0; i < nodes.length; i++) nodes[i].disabled = busy;
	},

	msg: function(text, kind) {
		var m = this.root.querySelector('#r3ab-msg');
		m.textContent = text || '';
		m.className = 'r3ab-msg' + (kind ? ' ' + kind : '');
	},

	show: function(st, text, kind) {
		var q = this.root.querySelector.bind(this.root);
		var set = function(id, main, sub, err) {
			q('#' + id).textContent = main;
			q('#' + id + '-sub').textContent = sub || '';
			q('#' + id + '-sub').className = err ? 'err' : '';
		};

		q('#r3ab-enabled').checked = !!st.enabled;
		q('#r3ab-sub').checked = !!st.subscription;
		q('#r3ab-auto').checked = !!st.auto_update;
		q('#r3ab-hour').value = String(st.update_hour != null ? st.update_hour : 4);

		var pill = q('#r3ab-pill'), label;
		if (!st.openclash_running) { pill.className = 'r3ab-pill bad'; label = 'OpenClash 未运行，过滤不生效'; }
		else if (st.loaded === 'no') { pill.className = 'r3ab-pill bad'; label = 'OpenClash 未加载规则'; }
		else if (!st.enabled) { pill.className = 'r3ab-pill off'; label = '已关闭'; }
		else { pill.className = 'r3ab-pill on'; label = '过滤中'; }
		pill.querySelector('span').textContent = label;

		if (!st.enabled)
			set('r3ab-active', '0 条', '广告过滤已关闭');
		else if (st.runtime_domain != null)
			set('r3ab-active', (st.runtime_domain + st.runtime_rule) + ' 条', '域名 ' + st.runtime_domain + ' 条 + 正则等 ' + st.runtime_rule + ' 条');
		else
			set('r3ab-active', (st.domain_rules || 0) + (st.core_rules || 0) + ' 条', '读不到 OpenClash 运行状态，显示的是规则文件', true);

		set('r3ab-builtin', (st.builtin_rules || 0) + ' 条规则 + ' + (st.builtin_domains || 0) + ' 个域名',
			'红果广告视频 / 广告接口 / 穿山甲 / 字节 HTTPDNS 等');

		var src = (st.sources || [])[0];
		if (!src)
			set('r3ab-source', '未配置', '');
		else if (!st.subscription)
			set('r3ab-source', '已关闭', sourceName(src.url) + '，已下载 ' + src.count + ' 条');
		else
			set('r3ab-source', src.count + ' 条', sourceName(src.url) + (src.error ? '；上次失败：' + src.error : src.time ? '；' + src.time + ' 下载' : '；尚未下载'), !!src.error);

		if (st.last_time)
			set('r3ab-last', st.last_time.replace(/:\d\d$/, ''), (RESULT[st.last_result] || st.last_result) + '：' + (st.last_message || ''),
				st.last_result === 'failed' || st.last_result === 'partial');
		else
			set('r3ab-last', '还没有更新过', st.auto_update ? '每天 ' + ('0' + st.update_hour).slice(-2) + ':30 自动更新' : '自动更新已关闭');

		if (text !== undefined) this.msg(text, kind);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
