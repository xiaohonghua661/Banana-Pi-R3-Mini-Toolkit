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
		this.root = E('div', { 'class': 'r3hotspot-app' });
		this.root.innerHTML = `
		<style>
		.r3hotspot-app{--navy:#123a67;--navy-2:#0b2748;--blue:#2379d8;--blue-pale:#eaf3ff;--paper:#f7f8f6;--panel:#fff;--ink:#182433;--muted:#68778a;--line:#dfe5ea;--soft:#f1f4f6;--green:#1b9a72;--amber:#c98212;--red:#c65353;max-width:1180px;margin:0 auto;padding:20px 12px 42px;color:var(--ink);font-family:"Noto Sans SC","Microsoft YaHei",sans-serif}.r3hotspot-app *{box-sizing:border-box}.r3hotspot-app button,.r3hotspot-app input{font:inherit;touch-action:manipulation}.rh-head{display:flex;align-items:flex-start;justify-content:space-between;gap:22px;padding:4px 2px 22px}.rh-eyebrow{margin:0 0 6px;color:var(--blue);font-size:11px;font-weight:700;letter-spacing:.12em}.rh-title{margin:0;font-size:30px;letter-spacing:-.035em;text-wrap:balance}.rh-description{max-width:690px;margin:8px 0 0;color:var(--muted);font-size:13px;line-height:1.65}.rh-health{display:flex;align-items:center;gap:8px;margin-top:4px;padding:8px 11px;border:1px solid var(--line);border-radius:99px;background:var(--panel);color:var(--muted);font-size:12px;white-space:nowrap}.rh-dot{width:8px;height:8px;border-radius:50%;background:var(--amber)}.rh-health.online .rh-dot{background:var(--green);box-shadow:0 0 0 4px rgba(27,154,114,.12)}.rh-hero{overflow:hidden;border:1px solid #cbd8e5;border-radius:12px;background:linear-gradient(122deg,var(--navy-2),var(--navy));box-shadow:0 14px 31px rgba(17,58,103,.16)}.rh-hero-top{display:flex;align-items:flex-start;justify-content:space-between;gap:18px;padding:24px 25px 19px;color:#fff}.rh-hero-label{margin:0;color:#b9d3ef;font-size:12px}.rh-egress{margin:5px 0 0;font-size:28px;letter-spacing:-.035em}.rh-egress-meta{margin:7px 0 0;color:#c7dbee;font-size:12px}.rh-default{padding:7px 9px;border:1px solid rgba(255,255,255,.21);border-radius:5px;color:#dceafa;font-size:11px;white-space:nowrap}.rh-routes{display:grid;grid-template-columns:repeat(3,1fr);gap:1px;border-top:1px solid rgba(255,255,255,.17);background:rgba(255,255,255,.17)}.rh-route{min-height:104px;padding:17px 19px;background:rgba(11,39,72,.63);transition:background .16s}.rh-route.active{background:#fff;color:var(--ink)}.rh-route-name{display:flex;align-items:center;justify-content:space-between;gap:7px;font-weight:700;font-size:14px}.rh-route-badge{padding:3px 6px;border-radius:4px;background:rgba(255,255,255,.13);color:#bfd7ef;font-size:10px;font-weight:400}.rh-route.active .rh-route-badge{background:var(--blue-pale);color:var(--blue)}.rh-route-detail{display:block;margin-top:14px;color:#bdd2e6;font-size:12px}.rh-route.active .rh-route-detail{color:var(--green);font-weight:700}.rh-grid{display:grid;grid-template-columns:minmax(0,1.15fr) minmax(310px,.85fr);gap:17px;margin-top:17px}.rh-card{border:1px solid var(--line);border-radius:11px;background:var(--panel);box-shadow:0 5px 17px rgba(33,48,66,.045)}.rh-card-title{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin:0;padding:19px 20px 14px;border-bottom:1px solid var(--line);font-size:16px}.rh-card-title small{color:var(--muted);font-size:11px;font-weight:400}.rh-metrics{display:grid;grid-template-columns:repeat(2,1fr)}.rh-metric{min-height:82px;padding:17px 20px;border-right:1px solid var(--line);border-bottom:1px solid var(--line)}.rh-metric:nth-child(2n){border-right:0}.rh-metric:nth-last-child(-n+2){border-bottom:0}.rh-metric small{display:block;color:var(--muted);font-size:11px}.rh-metric strong{display:block;margin-top:7px;overflow:hidden;color:var(--ink);font-size:15px;text-overflow:ellipsis;white-space:nowrap}.rh-policy{padding:16px 20px 19px;color:var(--muted);font-size:12px;line-height:1.65}.rh-policy b{color:var(--navy)}.rh-form{padding:3px 20px 20px}.rh-switchrow{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:17px 0;border-bottom:1px solid var(--line)}.rh-switchrow strong{display:block;font-size:14px}.rh-switchrow span{display:block;margin-top:4px;color:var(--muted);font-size:11px;line-height:1.5}.rh-switch{position:relative;width:47px;height:27px;flex:none}.rh-switch input{width:0;height:0;opacity:0}.rh-slider{position:absolute;inset:0;border-radius:99px;background:#c7d0da;cursor:pointer;transition:.18s}.rh-slider:before{content:"";position:absolute;top:4px;left:4px;width:19px;height:19px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.19);transition:.18s}.rh-switch input:checked+.rh-slider{background:var(--blue)}.rh-switch input:checked+.rh-slider:before{transform:translateX(20px)}.rh-field{display:grid;gap:7px;margin-top:16px}.rh-field label{color:#334155;font-size:12px;font-weight:700}.rh-field label span{float:right;color:var(--muted);font-weight:400}.rh-field input{width:100%;height:40px;padding:0 11px;border:1px solid #cfd8e0;border-radius:6px;background:#fff;color:var(--ink)}.rh-field input:focus-visible,.rh-btn:focus-visible,.rh-switch input:focus-visible+.rh-slider{outline:3px solid rgba(35,121,216,.35);outline-offset:2px;border-color:var(--blue)}.rh-field input:focus-visible{box-shadow:0 0 0 3px rgba(35,121,216,.12)}.rh-hint{margin:1px 0 0;color:var(--muted);font-size:11px;line-height:1.55}.rh-warning{display:flex;gap:9px;margin:17px 0 0;padding:11px 12px;border-radius:6px;background:#fff8eb;color:#7b5714;font-size:11px;line-height:1.6}.rh-warning b{color:var(--amber)}.rh-actions{display:flex;gap:9px;margin-top:18px}.rh-btn{min-height:41px;padding:0 13px;border:1px solid #ccd7e1;border-radius:6px;background:#fff;color:#405064;cursor:pointer;transition:background .16s,border-color .16s,color .16s}.rh-btn:hover:not(:disabled){border-color:#9bb8d6;background:#f5f9fd}.rh-btn.primary{flex:1;border-color:var(--navy);background:var(--navy);color:#fff;font-weight:700}.rh-btn.primary:hover:not(:disabled){background:#0c2d51}.rh-btn:disabled{opacity:.5;cursor:wait}.rh-message{min-height:18px;margin:11px 0 0;color:var(--muted);font-size:11px;line-height:1.5}.rh-message.ok{color:var(--green)}.rh-message.error{color:var(--red)}@media(max-width:820px){.rh-grid{grid-template-columns:1fr}.rh-head,.rh-hero-top{flex-direction:column}.rh-routes{grid-template-columns:1fr}.rh-route{min-height:74px}.rh-hero-top{padding-bottom:18px}}@media(max-width:500px){.r3hotspot-app{padding:12px 0 32px}.rh-title{font-size:25px}.rh-hero-top{padding:19px}.rh-metrics{grid-template-columns:1fr}.rh-metric,.rh-metric:nth-last-child(-n+2){border-right:0;border-bottom:1px solid var(--line)}.rh-metric:last-child{border-bottom:0}.rh-actions{flex-direction:column}.rh-btn{width:100%}}
		</style>
		<header class="rh-head"><div><p class="rh-eyebrow">MOBILE UPLINK · DEFAULT ROUTE</p><h1 class="rh-title">手机热点 WAN</h1><p class="rh-description">选择手机热点作为备用上游。页面会读取默认路由，实时告诉你流量实际从哪条出口离开路由器。</p></div><div id="rh-health" class="rh-health"><i class="rh-dot"></i><span>读取状态中</span></div></header>
		<section class="rh-hero"><div class="rh-hero-top"><div><p class="rh-hero-label">当前出口（默认路由）</p><h2 id="rh-egress" class="rh-egress" aria-live="polite">正在读取…</h2><p id="rh-egress-meta" class="rh-egress-meta">--</p></div><span id="rh-default" class="rh-default">默认路由：--</span></div><div class="rh-routes"><div class="rh-route" data-route="wan"><div class="rh-route-name">有线 WAN <span class="rh-route-badge">WAN</span></div><span class="rh-route-detail">检测中</span></div><div class="rh-route" data-route="cellular"><div class="rh-route-name">蜂窝网络 5G <span class="rh-route-badge">SIM</span></div><span class="rh-route-detail">检测中</span></div><div class="rh-route" data-route="hotspot"><div class="rh-route-name">手机热点 Wi-Fi <span class="rh-route-badge">Wi-Fi</span></div><span class="rh-route-detail">检测中</span></div></div></section>
		<main class="rh-grid"><section class="rh-card"><h2 class="rh-card-title">出口详情 <small>每 10 秒刷新</small></h2><div class="rh-metrics"><div class="rh-metric"><small>逻辑接口</small><strong id="rh-iface">--</strong></div><div class="rh-metric"><small>IPv4 地址</small><strong id="rh-ip">--</strong></div><div class="rh-metric"><small>物理设备</small><strong id="rh-device">--</strong></div><div class="rh-metric"><small>5GHz 信道</small><strong id="rh-channel">--</strong></div></div><div class="rh-policy"><b>自动重连：</b><span id="rh-policy">--</span></div></section><section class="rh-card"><h2 class="rh-card-title">手机热点 Wi-Fi 设置 <small id="rh-hotspot-state">--</small></h2><div class="rh-form"><div class="rh-switchrow"><div><strong>启用手机热点 WAN</strong><span>启用后保留本地 5GHz AP，并创建手机热点 STA。</span></div><label class="rh-switch"><input id="rh-enabled" type="checkbox" aria-label="启用手机热点 WAN"><i class="rh-slider"></i></label></div><div class="rh-field"><label for="rh-ssid">手机热点名称 <span>SSID</span></label><input id="rh-ssid" name="hotspot_ssid" maxlength="32" autocomplete="off" spellcheck="false" placeholder="例如：MyPhone-5G…"></div><div class="rh-field"><label for="rh-password">手机热点密码 <span>首次配置必填</span></label><input id="rh-password" name="hotspot_password" type="password" minlength="8" maxlength="63" autocomplete="new-password" placeholder="留空则保留已保存密码…"><p id="rh-password-hint" class="rh-hint">密码不会在页面回显。</p></div><div class="rh-warning"><b>!</b><span>启用或停用会短暂重配 5GHz，已连接设备可能断开约 20–40 秒。启用时会临时自动跟随手机热点信道，停用后恢复原信道。</span></div><div class="rh-actions"><button id="rh-revert" class="rh-btn">恢复当前值</button><button id="rh-apply" class="rh-btn primary">保存并应用</button></div><p id="rh-message" class="rh-message" aria-live="polite">未保存前不会改变无线连接。</p></div></section></main>`;

		this.saved = { enabled: !!status.enabled, ssid: status.ssid || '' };
		this.bind();
		this.update(status, true);
		poll.add(function() {
			return self.call(['status']).then(function(next) { self.update(next, false); }).catch(function(error) { self.message(error.message, 'error'); });
		}, 10);
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
	},

	syncForm: function() {
		var enabled = this.root.querySelector('#rh-enabled').checked;
		var ssid = this.root.querySelector('#rh-ssid').value.trim();
		var password = this.root.querySelector('#rh-password').value;
		var firstSetup = !this.status.key_configured;
		this.root.querySelector('#rh-ssid').disabled = !enabled;
		this.root.querySelector('#rh-password').disabled = !enabled;
		this.root.querySelector('#rh-password-hint').textContent = firstSetup ? '首次启用必须输入 8–63 位热点密码；页面不会回显。' : '留空会保留路由器已保存的热点密码。';
		this.root.querySelector('#rh-apply').disabled = enabled && (!ssid || (firstSetup && password.length < 8));
	},

	setBusy: function(busy) {
		var nodes = this.root.querySelectorAll('button,input');
		for (var i = 0; i < nodes.length; i++) nodes[i].disabled = busy;
		if (!busy) this.syncForm();
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
		this.call(['apply', enabled ? '1' : '0', ssid, password]).then(function(next) {
			self.root.querySelector('#rh-password').value = '';
			self.update(next, true);
			self.message(enabled ? '已保存。手机热点开启后会自动连接。' : '已暂停手机热点 WAN，本地 5GHz AP 会在重配后恢复可用。', 'ok');
		}).catch(function(error) {
			self.message(error.message, 'error');
			ui.addNotification(null, E('p', {}, error.message), 'danger');
		}).finally(function() { self.setBusy(false); });
	},

	update: function(status, resetForm) {
		var state = hotspotState(status);
		var health = this.root.querySelector('#rh-health');
		var kind = status.egress_kind || 'none';
		this.status = status;
		health.classList.toggle('online', kind !== 'none');
		health.querySelector('span').textContent = state;
		this.root.querySelector('#rh-egress').textContent = '当前出口：' + (status.egress_label || '未检测到默认出口');
		this.root.querySelector('#rh-egress-meta').textContent = status.egress_ip ? '正在通过 ' + (status.egress_iface || '--') + ' · ' + status.egress_ip + ' 联网' : '当前没有可用的 IPv4 默认路由';
		this.root.querySelector('#rh-default').textContent = '默认路由：' + (status.egress_device || '--');
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
