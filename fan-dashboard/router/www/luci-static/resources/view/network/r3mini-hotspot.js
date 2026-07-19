'use strict';
'require view';
'require fs';
'require poll';
'require ui';

var HELPER = '/usr/sbin/r3mini-hotspot-web';

function parseResult(result) {
	if (!result || result.code !== 0)
		throw new Error((result && result.stderr || '手机热点接口无响应').trim());
	return JSON.parse(result.stdout);
}

function hotspotState(status) {
	if (!status.configured) return '未配置热点';
	if (!status.enabled) return '热点连接已暂停';
	return status.wwan_up ? '热点已连接' : '正在连接热点';
}

function routeOnline(status, kind) {
	if (kind === 'wan') return !!status.wired_wan_up;
	if (kind === 'cellular') return !!status.cellular_up;
	return !!status.wwan_up;
}

function routeName(kind) {
	return kind === 'wan' ? '有线 WAN' : kind === 'cellular' ? '蜂窝网络 5G' : '手机热点 Wi-Fi';
}

return view.extend({
	call: function(args) {
		return fs.exec(HELPER, args).then(parseResult);
	},

	load: function() {
		return this.call(['status']);
	},

	render: function(status) {
		var self = this;
		this.status = status;
		this.lastWwanUp = !!status.wwan_up;
		this.root = E('div', { 'class': 'r3hotspot-app' });
		this.root.innerHTML = `
		<style>
		#view .r3hotspot-app{display:block!important;width:100%;min-width:0;flex:1 1 100%}
		.r3hotspot-app{--ink:#14231f;--muted:#66736e;--line:#dbe3df;--paper:#f4f6f3;--panel:#fff;--forest:#0e4938;--green:#138564;--green-soft:#e9f7f1;--blue:#2563a9;--amber:#a96b0a;--amber-soft:#fff7e7;--red:#ba4b4b;max-width:1120px;margin:0 auto;padding:18px 12px 44px;color:var(--ink);font-family:"Noto Sans SC","Source Han Sans SC","Microsoft YaHei",sans-serif;container-type:inline-size}.r3hotspot-app *{box-sizing:border-box}.r3hotspot-app button,.r3hotspot-app input{font:inherit;touch-action:manipulation}.rh-head{display:flex;align-items:flex-end;justify-content:space-between;gap:20px;margin-bottom:14px;padding:18px 20px;border:1px solid var(--line);border-radius:12px;background:linear-gradient(135deg,#fff 58%,#edf6f2);box-shadow:0 8px 24px rgba(23,43,36,.055)}.rh-head>div:first-child{min-width:0}.rh-eyebrow{margin:0 0 5px;color:var(--green)!important;font-family:"IBM Plex Mono","SFMono-Regular",monospace;font-size:10px;font-weight:700;letter-spacing:.16em}.rh-title{margin:0;color:var(--forest)!important;text-shadow:none!important;font-size:clamp(24px,2vw + 12px,34px);font-weight:750;letter-spacing:-.045em}.rh-description{max-width:650px;margin:6px 0 0;color:var(--muted)!important;font-size:12px;line-height:1.7}.rh-health{display:flex;align-items:center;gap:8px;padding:7px 10px;border:1px solid var(--line);border-radius:8px;background:var(--panel);color:var(--muted);font-size:11px;white-space:nowrap}.rh-dot{width:7px;height:7px;border-radius:50%;background:var(--amber)}.rh-health.online .rh-dot{background:var(--green);box-shadow:0 0 0 4px rgba(19,133,100,.12)}.rh-success{display:none;grid-template-columns:auto 1fr auto;align-items:center;gap:12px;margin-bottom:12px;padding:12px 14px;border:1px solid #a9ddca;border-radius:10px;background:linear-gradient(100deg,#edf9f4,#f9fdfb);box-shadow:0 6px 20px rgba(14,73,56,.07);animation:rh-enter .28s ease-out}.rh-success.show{display:grid}.rh-success-icon{display:grid;width:30px;height:30px;place-items:center;border-radius:8px;background:var(--green);color:#fff;font-size:17px;font-weight:800}.rh-success strong{display:block;color:var(--forest);font-size:13px}.rh-success span{display:block;margin-top:2px;color:#4f6e63;font-size:11px}.rh-success-code{padding:5px 7px;border:1px solid #bfe5d7;border-radius:6px;color:var(--green);font-family:"IBM Plex Mono","SFMono-Regular",monospace;font-size:9px;font-weight:700;letter-spacing:.08em}.rh-console{overflow:hidden;border:1px solid var(--line);border-radius:12px;background:var(--panel);box-shadow:0 10px 28px rgba(23,43,36,.065)}.rh-console-top{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:18px;padding:20px 22px 17px;border-bottom:1px solid var(--line);background:linear-gradient(135deg,#fff 58%,#f0f6f3)}.rh-console-label{margin:0;color:var(--green);font-family:"IBM Plex Mono","SFMono-Regular",monospace;font-size:9px;font-weight:700;letter-spacing:.13em}.rh-egress{margin:5px 0 0;font-size:clamp(21px,1.6vw + 10px,29px);font-weight:760;letter-spacing:-.04em}.rh-egress-meta{margin:5px 0 0;color:var(--muted);font-size:11px}.rh-default{padding:8px 10px;border:1px solid #cddbd5;border-radius:7px;background:#fff;color:var(--forest);font-family:"IBM Plex Mono","SFMono-Regular",monospace;font-size:10px;white-space:nowrap}.rh-routes{display:grid;grid-template-columns:repeat(3,1fr);gap:0}.rh-route{position:relative;min-height:78px;padding:14px 16px;border-right:1px solid var(--line);background:#fff;transition:background .18s,border-color .18s}.rh-route:last-child{border-right:0}.rh-route:before{content:"";position:absolute;inset:0 auto 0 0;width:3px;background:transparent}.rh-route.active{background:var(--green-soft)}.rh-route.active:before{background:var(--green)}.rh-route-name{display:flex;align-items:center;justify-content:space-between;gap:8px;font-size:12px;font-weight:720}.rh-route-badge{padding:3px 5px;border:1px solid var(--line);border-radius:5px;color:#7a8983;font-family:"IBM Plex Mono","SFMono-Regular",monospace;font-size:8px;font-weight:650}.rh-route.active .rh-route-badge{border-color:#b7dfd0;background:#fff;color:var(--green)}.rh-route-detail{display:block;margin-top:10px;color:#88958f;font-size:10px}.rh-route.active .rh-route-detail{color:var(--green);font-weight:750}.rh-preference{display:grid;grid-template-columns:minmax(190px,.72fr) minmax(0,1.28fr);align-items:center;gap:16px;margin-top:12px;padding:14px 16px;border:1px solid var(--line);border-radius:12px;background:var(--panel);box-shadow:0 6px 20px rgba(23,43,36,.04)}.rh-preference-copy strong{display:block;font-size:12px}.rh-preference-copy span{display:block;margin-top:4px;color:var(--muted);font-size:9px;line-height:1.5}.rh-preference-buttons{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}.rh-prefer{min-height:38px;padding:0 8px;border:1px solid #cbd7d2;border-radius:7px;background:#fff;color:#42554d;font-size:10px;font-weight:650;cursor:pointer;transition:.15s}.rh-prefer:hover:not(:disabled){border-color:#7cac9a;background:#f4faf7}.rh-prefer.selected{border-color:var(--forest);background:var(--forest);color:#fff;box-shadow:0 4px 12px rgba(14,73,56,.14)}.rh-prefer:disabled{opacity:.42;cursor:not-allowed}.rh-grid{display:grid;grid-template-columns:minmax(0,1.05fr) minmax(320px,.95fr);gap:12px;margin-top:12px}.rh-card{overflow:hidden;border:1px solid var(--line);border-radius:12px;background:var(--panel);box-shadow:0 6px 20px rgba(23,43,36,.04)}.rh-card-title{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin:0;padding:15px 17px 12px;border-bottom:1px solid var(--line);font-size:14px}.rh-card-title small{color:var(--muted);font-size:9px;font-weight:500}.rh-metrics{display:grid;grid-template-columns:repeat(2,1fr)}.rh-metric{min-height:70px;padding:14px 17px;border-right:1px solid var(--line);border-bottom:1px solid var(--line)}.rh-metric:nth-child(2n){border-right:0}.rh-metric:nth-last-child(-n+2){border-bottom:0}.rh-metric small{display:block;color:var(--muted);font-size:10px}.rh-metric strong{display:block;margin-top:6px;overflow:hidden;color:var(--forest);font-family:"IBM Plex Mono","SFMono-Regular",monospace;font-size:14px;text-overflow:ellipsis;white-space:nowrap}.rh-policy{padding:12px 17px 14px;border-top:1px solid var(--line);background:#fbfcfb;color:var(--muted);font-size:10px;line-height:1.65}.rh-policy b{color:var(--forest)}.rh-form{padding:0 17px 16px}.rh-switchrow{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:14px 0;border-bottom:1px solid var(--line)}.rh-switchrow strong{display:block;font-size:12px}.rh-switchrow span{display:block;margin-top:3px;color:var(--muted);font-size:10px;line-height:1.5}.rh-switch{position:relative;width:43px;height:24px;flex:none}.rh-switch input{width:0;height:0;opacity:0}.rh-slider{position:absolute;inset:0;border-radius:99px;background:#c9d1cd;cursor:pointer;transition:.18s}.rh-slider:before{content:"";position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.2);transition:.18s}.rh-switch input:checked+.rh-slider{background:var(--green)}.rh-switch input:checked+.rh-slider:before{transform:translateX(19px)}.rh-field{display:grid;gap:5px;margin-top:12px}.rh-field label{color:#34443e;font-size:10px;font-weight:720}.rh-field label span{float:right;color:var(--muted);font-weight:500}.rh-field input{width:100%;height:36px;padding:0 10px;border:1px solid #cad5d0;border-radius:7px;background:#fff;color:var(--ink);font-size:12px}.rh-field input:focus-visible,.rh-btn:focus-visible,.rh-prefer:focus-visible,.rh-switch input:focus-visible+.rh-slider{outline:3px solid rgba(19,133,100,.22);outline-offset:2px;border-color:var(--green)}.rh-hint{margin:0;color:var(--muted);font-size:9px;line-height:1.5}.rh-warning{display:flex;gap:8px;margin:13px 0 0;padding:9px 10px;border:1px solid #f0dbad;border-radius:7px;background:var(--amber-soft);color:#795517;font-size:9px;line-height:1.55}.rh-warning b{color:var(--amber)}.rh-actions{display:flex;gap:8px;margin-top:13px}.rh-btn{min-height:37px;padding:0 12px;border:1px solid #c9d5d0;border-radius:7px;background:#fff;color:#40534b;font-size:11px;cursor:pointer;transition:.16s}.rh-btn:hover:not(:disabled){border-color:#8eb3a5;background:#f7fbf9}.rh-btn.primary{flex:1;border-color:var(--forest);background:var(--forest);color:#fff;font-weight:720}.rh-btn.primary:hover:not(:disabled){background:#0a3b2d}.rh-btn:disabled{opacity:.48;cursor:wait}.rh-message{min-height:16px;margin:9px 0 0;color:var(--muted);font-size:9px;line-height:1.5}.rh-message.ok{color:var(--green);font-weight:650}.rh-message.error{color:var(--red)}@keyframes rh-enter{from{opacity:0;transform:translateY(-5px)}to{opacity:1;transform:none}}@container(max-width:760px){.rh-grid{grid-template-columns:1fr}.rh-head{align-items:flex-start}.rh-routes{grid-template-columns:1fr}.rh-route{min-height:58px;border-right:0;border-bottom:1px solid var(--line)}.rh-route:last-child{border-bottom:0}.rh-preference{grid-template-columns:1fr}.rh-preference-buttons{grid-template-columns:repeat(2,1fr)}}@container(max-width:480px){.r3hotspot-app{padding:10px 0 30px}.rh-head,.rh-console-top{grid-template-columns:1fr;flex-direction:column;align-items:flex-start}.rh-success{grid-template-columns:auto 1fr}.rh-success-code{display:none}.rh-metrics{grid-template-columns:1fr}.rh-metric,.rh-metric:nth-last-child(-n+2){border-right:0;border-bottom:1px solid var(--line)}.rh-metric:last-child{border-bottom:0}.rh-actions{flex-direction:column}.rh-btn{width:100%}}
		#view .r3hotspot-app .rh-eyebrow{color:var(--green)!important}
		#view .r3hotspot-app .rh-title{color:var(--forest)!important;text-shadow:none!important}
		#view .r3hotspot-app .rh-description{color:var(--muted)!important}
		#view .r3hotspot-app .rh-head::after{content:none!important;display:none!important}
		</style>
		<header class="rh-head"><div><p class="rh-eyebrow">UPLINK RELAY / LIVE</p><h1 class="rh-title">网络接力控制台</h1><p class="rh-description">统一查看有线、蜂窝与手机热点出口。手机热点支持 Wi-Fi 6 与 WPA2/WPA3-Personal。</p></div><div id="rh-health" class="rh-health"><i class="rh-dot"></i><span>读取状态中</span></div></header>
		<section id="rh-success" class="rh-success" role="status" aria-live="polite"><i class="rh-success-icon">✓</i><div><strong>手机热点连接成功</strong><span id="rh-success-meta">正在读取连接信息…</span></div><code class="rh-success-code">UPLINK ACTIVE</code></section>
		<section class="rh-console"><div class="rh-console-top"><div><p class="rh-console-label">DEFAULT EGRESS</p><h2 id="rh-egress" class="rh-egress" aria-live="polite">正在读取…</h2><p id="rh-egress-meta" class="rh-egress-meta">--</p></div><span id="rh-default" class="rh-default">route / --</span></div><div class="rh-routes"><div class="rh-route" data-route="wan"><div class="rh-route-name">有线 WAN <span class="rh-route-badge">ETH</span></div><span class="rh-route-detail">检测中</span></div><div class="rh-route" data-route="cellular"><div class="rh-route-name">蜂窝网络 <span class="rh-route-badge">5G SIM</span></div><span class="rh-route-detail">检测中</span></div><div class="rh-route" data-route="hotspot"><div class="rh-route-name">手机热点 <span class="rh-route-badge">WIFI</span></div><span class="rh-route-detail">检测中</span></div></div></section>
		<section class="rh-preference"><div class="rh-preference-copy"><strong>出口偏好</strong><span>仅在线出口可选；“自动”按有线 → 蜂窝 → 热点排序。</span></div><div class="rh-preference-buttons" role="group" aria-label="选择默认网络出口"><button class="rh-prefer" data-prefer="auto">自动</button><button class="rh-prefer" data-prefer="wan">有线 WAN</button><button class="rh-prefer" data-prefer="cellular">蜂窝 5G</button><button class="rh-prefer" data-prefer="hotspot">手机热点</button></div></section>
		<main class="rh-grid"><section class="rh-card"><h2 class="rh-card-title">出口详情 <small>稳定 250ms / 切换 100ms 刷新</small></h2><div class="rh-metrics"><div class="rh-metric"><small>逻辑接口</small><strong id="rh-iface">--</strong></div><div class="rh-metric"><small>IPv4 地址</small><strong id="rh-ip">--</strong></div><div class="rh-metric"><small>物理设备</small><strong id="rh-device">--</strong></div><div class="rh-metric"><small>5GHz 信道</small><strong id="rh-channel">--</strong></div></div><div class="rh-policy"><b>自动重连：</b><span id="rh-policy">--</span></div></section><section class="rh-card"><h2 class="rh-card-title">手机热点 Wi-Fi 设置 <small id="rh-hotspot-state">--</small></h2><div class="rh-form"><div class="rh-switchrow"><div><strong>启用手机热点 WAN</strong><span>启用后保留本地 5GHz AP，并创建手机热点 STA。</span></div><label class="rh-switch"><input id="rh-enabled" type="checkbox" aria-label="启用手机热点 WAN"><i class="rh-slider"></i></label></div><div class="rh-field"><label for="rh-ssid">手机热点名称 <span>SSID</span></label><input id="rh-ssid" name="hotspot_ssid" maxlength="32" autocomplete="off" spellcheck="false" placeholder="例如：MyPhone-5G…"></div><div class="rh-field"><label for="rh-password">手机热点密码 <span>首次配置必填</span></label><input id="rh-password" name="hotspot_password" type="password" minlength="8" maxlength="63" autocomplete="new-password" placeholder="留空则保留已保存密码…"><p id="rh-password-hint" class="rh-hint">密码不会在页面回显。</p></div><div class="rh-warning"><b>!</b><span>必须通过 LAN 管理。保存时会短暂停止本地 5GHz AP，用 STA 扫描手机信道，再让 AP 与手机热点切到同一信道；设备可能断开约 20–40 秒。</span></div><div class="rh-actions"><button id="rh-revert" class="rh-btn">恢复当前值</button><button id="rh-apply" class="rh-btn primary">保存并应用</button></div><p id="rh-message" class="rh-message" aria-live="polite">未保存前不会改变无线连接。</p></div></section></main>`;

		this.saved = { enabled: !!status.enabled, ssid: status.ssid || '' };
		this.busy = false;
		this.statusRequest = null;
		this.bind();
		this.update(status, true);
		poll.add(function() {
			return self.refreshStatus();
		}, 0.25);
		return this.root;
	},

	bind: function() {
		var self = this;
		this.root.querySelector('#rh-enabled').addEventListener('change', function() { self.syncForm(); });
		this.root.querySelector('#rh-ssid').addEventListener('input', function() { self.syncForm(); });
		this.root.querySelector('#rh-password').addEventListener('input', function() { self.syncForm(); });
		this.root.querySelector('#rh-revert').addEventListener('click', function() {
			self.root.querySelector('#rh-enabled').checked = self.saved.enabled;
			self.root.querySelector('#rh-ssid').value = self.saved.ssid;
			self.root.querySelector('#rh-password').value = '';
			self.syncForm();
			self.message('已恢复为路由器已保存的配置。');
		});
		this.root.querySelector('#rh-apply').addEventListener('click', function() { self.apply(); });
		var preferences = this.root.querySelectorAll('[data-prefer]');
		for (var i = 0; i < preferences.length; i++) preferences[i].addEventListener('click', function() { self.prefer(this.getAttribute('data-prefer')); });
	},

	refreshStatus: function() {
		var self = this;
		if (this.statusRequest) return this.statusRequest;
		this.statusRequest = this.call(['status']).then(function(next) {
			self.update(next, false);
			return next;
		}).catch(function(error) {
			self.message('状态读取失败：' + error.message, 'error');
		}).finally(function() { self.statusRequest = null; });
		return this.statusRequest;
	},

	startBurst: function() {
		var self = this;
		var until = Date.now() + 5000;
		clearTimeout(this.burstTimer);
		function tick() {
			if (!self.root || !self.root.isConnected || Date.now() >= until) return;
			self.refreshStatus();
			self.burstTimer = setTimeout(tick, 100);
		}
		tick();
	},

	syncForm: function() {
		var enabled = this.root.querySelector('#rh-enabled').checked;
		var ssid = this.root.querySelector('#rh-ssid').value.trim();
		var password = this.root.querySelector('#rh-password').value;
		var ssidBytes = new TextEncoder().encode(ssid).length;
		var passwordBytes = new TextEncoder().encode(password).length;
		var firstSetup = !this.status.key_configured;
		this.root.querySelector('#rh-enabled').disabled = this.busy;
		this.root.querySelector('#rh-ssid').disabled = this.busy || !enabled;
		this.root.querySelector('#rh-password').disabled = this.busy || !enabled;
		this.root.querySelector('#rh-revert').disabled = this.busy;
		this.root.querySelector('#rh-password-hint').textContent = firstSetup ? '首次启用必须输入 8–63 位热点密码；页面不会回显。' : '留空会保留路由器已保存的热点密码。';
		this.root.querySelector('#rh-apply').disabled = this.busy || enabled && (!ssid || ssidBytes > 32 || (firstSetup && passwordBytes < 8) || (password && (passwordBytes < 8 || passwordBytes > 63)));
		this.syncPreference(this.status);
	},

	setBusy: function(busy) {
		this.busy = busy;
		this.syncForm();
	},

	syncPreference: function(status) {
		var selected = status.preferred_egress || 'auto';
		var nodes = this.root.querySelectorAll('[data-prefer]');
		for (var i = 0; i < nodes.length; i++) {
			var kind = nodes[i].getAttribute('data-prefer');
			nodes[i].classList.toggle('selected', kind === selected);
			nodes[i].disabled = this.busy || kind !== 'auto' && !routeOnline(status, kind);
			nodes[i].setAttribute('aria-pressed', kind === selected ? 'true' : 'false');
			nodes[i].title = kind === 'auto' || routeOnline(status, kind) ? '' : '该出口当前未连接';
		}
	},

	prefer: function(kind) {
		var self = this;
		if (this.busy || kind !== 'auto' && !routeOnline(this.status, kind)) return;
		this.setBusy(true);
		this.root.querySelector('#rh-egress').textContent = kind === 'auto' ? '正在恢复自动选择…' : '正在切换到' + routeName(kind) + '…';
		this.message(kind === 'auto' ? '正在恢复自动出口策略…' : '正在切换默认出口到' + routeName(kind) + '…');
		this.startBurst();
		this.call(['prefer', kind]).then(function(next) {
			self.update(next, false);
			self.message(kind === 'auto' ? '已恢复自动出口策略。' : '已选择' + routeName(kind) + '作为优先出口。', 'ok');
		}).catch(function(error) {
			self.message(error.message, 'error');
			ui.addNotification(null, E('p', {}, error.message), 'danger');
		}).finally(function() {
			self.setBusy(false);
			self.startBurst();
		});
	},

	apply: function() {
		var self = this;
		var enabled = this.root.querySelector('#rh-enabled').checked;
		var ssid = this.root.querySelector('#rh-ssid').value.trim();
		var password = this.root.querySelector('#rh-password').value;
		var prompt = enabled ? '5GHz 将短暂断开约 20–40 秒并重新关联手机热点。确认保存并开始自动连接吗？' : '停用同样会短暂重配 5GHz，当前设备可能断开约 20–40 秒。确认停用吗？';
		if (!window.confirm(prompt)) return;
		this.setBusy(true);
		this.message(enabled ? '正在保存并重配 5GHz；页面可能短暂断开…' : '正在暂停手机热点 WAN 并短暂重配 5GHz；页面可能短暂断开…');
		this.startBurst();
		this.call(['apply', enabled ? '1' : '0', ssid, password]).then(function(next) {
			self.root.querySelector('#rh-password').value = '';
			self.update(next, true);
			self.message(enabled && next.wwan_up && next.egress_kind === 'hotspot' ? '连接成功：手机热点已成为当前默认出口。' : enabled && next.wwan_up ? '手机热点已连接，当前在线待命。' : enabled ? '配置已保存，正在等待手机热点连接。' : '已暂停手机热点 WAN，本地 5GHz AP 会在重配后恢复可用。', 'ok');
		}).catch(function(error) {
			self.message(error.message, 'error');
			ui.addNotification(null, E('p', {}, error.message), 'danger');
		}).finally(function() { self.setBusy(false); self.startBurst(); });
	},

	update: function(status, resetForm) {
		var state = hotspotState(status);
		var health = this.root.querySelector('#rh-health');
		var success = this.root.querySelector('#rh-success');
		var kind = status.egress_kind || 'none';
		var becameConnected = !this.lastWwanUp && !!status.wwan_up;
		var becameDisconnected = this.lastWwanUp && !status.wwan_up;
		var egressChanged = this.lastEgressKind && this.lastEgressKind !== kind;
		this.status = status;
		this.lastWwanUp = !!status.wwan_up;
		this.lastEgressKind = kind;
		health.classList.toggle('online', kind !== 'none');
		health.querySelector('span').textContent = state;
		success.classList.toggle('show', !!status.wwan_up);
		this.root.querySelector('#rh-success-meta').textContent = status.wwan_up ? (status.wwan_ip || '--') + ' · 5GHz 信道 ' + (status.channel || '--') + ' · 默认路由 ' + (status.egress_device || '--') : '正在读取连接信息…';
		this.root.querySelector('#rh-egress').textContent = status.egress_label || '未检测到默认出口';
		this.root.querySelector('#rh-egress-meta').textContent = status.egress_ip ? '正在通过 ' + (status.egress_iface || '--') + ' · ' + status.egress_ip + ' 联网' : '当前没有可用的 IPv4 默认路由';
		this.root.querySelector('#rh-default').textContent = 'route / ' + (status.egress_device || '--');
		this.root.querySelector('#rh-iface').textContent = status.egress_iface || '--';
		this.root.querySelector('#rh-ip').textContent = status.egress_ip || '--';
		this.root.querySelector('#rh-device').textContent = status.egress_device || '--';
		this.root.querySelector('#rh-channel').textContent = status.channel ? status.channel + ' 信道' + (status.target_channel && status.target_channel !== status.channel ? '（目标 ' + status.target_channel + '）' : '') : '--';
		this.root.querySelector('#rh-hotspot-state').textContent = state;
		this.root.querySelector('#rh-policy').textContent = '每 ' + status.check_interval + ' 秒检查；连续 ' + status.failure_limit + ' 次失败先重连，连续三轮无效才重配；冷却 ' + status.cooldown + ' 秒。';
		for (var i = 0; i < ['wan', 'cellular', 'hotspot'].length; i++) {
			var route = ['wan', 'cellular', 'hotspot'][i];
			var node = this.root.querySelector('[data-route="' + route + '"]');
			var active = kind === route;
			node.classList.toggle('active', active);
			node.querySelector('.rh-route-detail').textContent = active ? '当前默认出口' : routeOnline(status, route) ? '在线待命' : '未连接';
		}
		if (resetForm) {
			this.saved = { enabled: !!status.enabled, ssid: status.ssid || '' };
			this.root.querySelector('#rh-enabled').checked = this.saved.enabled;
			this.root.querySelector('#rh-ssid').value = this.saved.ssid;
		}
		if (becameConnected) {
			this.message(kind === 'hotspot' ? '连接成功：手机热点已成为当前默认出口。' : '手机热点已连接，当前处于在线待命。', 'ok');
			ui.addNotification(null, E('p', {}, kind === 'hotspot' ? '手机热点连接成功，已成为默认出口。' : '手机热点连接成功，当前在线待命。'), 'info');
		}
		if (becameDisconnected) {
			this.message(status.enabled ? '手机热点连接已断开，自动重连正在接管。' : '手机热点连接已停止。', status.enabled ? 'error' : '');
			ui.addNotification(null, E('p', {}, status.enabled ? '手机热点连接已断开，正在自动重连。' : '手机热点连接已停止。'), status.enabled ? 'warning' : 'info');
		}
		if (egressChanged && !becameConnected && !becameDisconnected) {
			ui.addNotification(null, E('p', {}, kind === 'none' ? '当前没有可用的默认网络出口。' : '默认出口已切换到' + (status.egress_label || kind) + '。'), kind === 'none' ? 'warning' : 'info');
		}
		this.syncForm();
	},

	message: function(text, type) {
		var node = this.root.querySelector('#rh-message');
		node.className = 'rh-message' + (type ? ' ' + type : '');
		node.textContent = text;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
