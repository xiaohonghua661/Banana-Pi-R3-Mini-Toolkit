'use strict';
'require view';
'require fs';
'require poll';
'require ui';

var HELPER = '/usr/sbin/r3mini-fan-web';
var FIELDS = [
	['stop', '停止风扇', 'stop_temp'],
	['start', '启动低速', 'start_temp'],
	['mediumDown', '降为低速', 'medium_down'],
	['mediumUp', '升为中速', 'medium_up'],
	['highDown', '降为中速', 'high_down'],
	['highUp', '升为高速', 'high_up']
];

function parseResult(result) {
	if (!result || result.code !== 0)
		throw new Error((result && result.stderr || '风扇控制接口无响应').trim());
	return JSON.parse(result.stdout);
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
		var root = E('div', { 'class': 'r3fan-app' });
		root.innerHTML = `
		<style>
		.r3fan-app{--ink:#151712;--paper:#e7e2d3;--lime:#c7ff28;--orange:#ff6b2c;--muted:#8d9085;--line:rgba(231,226,211,.16);color:var(--paper);font-family:"Bahnschrift","Noto Sans SC","Microsoft YaHei",sans-serif;background:linear-gradient(rgba(231,226,211,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(231,226,211,.035) 1px,transparent 1px),radial-gradient(circle at 82% 14%,rgba(199,255,40,.08),transparent 28%),#0e100c;background-size:36px 36px,36px 36px,auto,auto;border-radius:6px;padding:18px;min-height:calc(100vh - 125px)}
		.r3fan-app *{box-sizing:border-box}.r3fan-app button,.r3fan-app input{font:inherit}.rf-top{display:flex;align-items:center;justify-content:space-between;gap:16px;padding-bottom:17px;border-bottom:1px solid var(--line)}
		.rf-brand{display:flex;align-items:center;gap:12px;font-weight:800;letter-spacing:.08em}.rf-mark{position:relative;width:29px;height:29px;border:2px solid var(--lime);border-radius:50%}.rf-mark:before,.rf-mark:after{content:"";position:absolute;inset:5px 12px;background:var(--lime);transform:rotate(45deg)}.rf-mark:after{transform:rotate(-45deg)}
		.rf-pill{display:inline-flex;align-items:center;gap:8px;padding:7px 10px;border:1px solid var(--line);border-radius:99px;color:var(--paper);font-size:12px}.rf-dot{width:7px;height:7px;border-radius:50%;background:var(--lime);box-shadow:0 0 13px var(--lime)}
		.rf-grid{display:grid;grid-template-columns:1.35fr .65fr;gap:16px;margin-top:16px}.rf-panel{overflow:hidden;border:1px solid var(--line);border-radius:6px;background:rgba(24,26,21,.9);box-shadow:0 18px 55px rgba(0,0,0,.22)}
		.rf-hero{position:relative;display:grid;grid-template-columns:minmax(0,1fr) 245px;min-height:335px;padding:27px}.rf-eye{color:var(--muted);font-size:10px;font-weight:800;letter-spacing:.18em;text-transform:uppercase}.rf-temp{display:flex;align-items:flex-end;gap:8px;margin-top:32px;line-height:.82}.rf-temp strong{font-family:"DIN Condensed","Bahnschrift Condensed",Impact,sans-serif;font-size:clamp(104px,13vw,180px);letter-spacing:-.055em}.rf-temp span{padding-bottom:10px;color:var(--lime);font:italic 45px Georgia,serif}.rf-note{max-width:540px;margin-top:19px;color:var(--muted);font-size:12px;line-height:1.7}
		.rf-fanbox{display:grid;place-items:center;align-content:center;border-left:1px solid var(--line)}.rf-fan{position:relative;width:145px;height:145px;border:1px solid rgba(231,226,211,.23);border-radius:50%}.rf-fan.spinning{animation:rf-spin var(--fan-speed,1.2s) linear infinite}.rf-blade{position:absolute;left:64px;top:14px;width:40px;height:59px;border-radius:60% 10% 70% 26%;background:linear-gradient(145deg,var(--lime),#688817);transform-origin:8px 58px}.rf-blade:nth-child(2){transform:rotate(90deg)}.rf-blade:nth-child(3){transform:rotate(180deg)}.rf-blade:nth-child(4){transform:rotate(270deg)}.rf-hub{position:absolute;inset:57px;z-index:2;border-radius:50%;background:var(--paper);box-shadow:0 0 0 7px var(--ink)}@keyframes rf-spin{to{transform:rotate(360deg)}}.rf-stage{text-align:center;margin-top:18px}.rf-stage strong{display:block;font-size:23px;margin-top:5px}
		.rf-metrics{display:grid;grid-template-columns:repeat(2,1fr);min-height:335px}.rf-metric{display:flex;flex-direction:column;justify-content:space-between;min-height:167px;padding:18px;border-right:1px solid var(--line);border-bottom:1px solid var(--line)}.rf-metric:nth-child(2n){border-right:0}.rf-metric:nth-child(n+3){border-bottom:0}.rf-metric strong{font:italic 32px Georgia,serif}.rf-metric small{color:var(--muted);font-size:10px;line-height:1.5}
		.rf-work{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(330px,.8fr);gap:16px;margin-top:16px}.rf-head{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:18px 20px;border-bottom:1px solid var(--line)}.rf-title{margin:4px 0 0;color:var(--paper);font-size:21px;font-weight:800}.rf-curvebody{padding:18px 20px 22px}.rf-curve{display:block;width:100%;min-height:225px}.rf-legend{display:flex;flex-wrap:wrap;gap:15px;color:var(--muted);font-size:10px}.rf-legend i{display:inline-block;width:17px;height:2px;margin-right:6px;vertical-align:middle;background:var(--lime)}.rf-legend i.down{background:var(--orange)}
		.rf-control{padding:20px}.rf-modes{display:grid;grid-template-columns:repeat(4,1fr);margin:9px 0 21px;border:1px solid var(--line);border-radius:5px;overflow:hidden}.rf-modes button{min-height:40px;border:0;border-right:1px solid var(--line);background:transparent;color:var(--muted);cursor:pointer}.rf-modes button:last-child{border-right:0}.rf-modes button.active{background:var(--lime);color:var(--ink);font-weight:800}.rf-modes button.auto-running{color:var(--lime);box-shadow:inset 0 -3px var(--lime)}.rf-modes button:disabled{cursor:wait;opacity:.45}
		.rf-thresholds{display:grid;gap:12px}.rf-threshold{display:grid;grid-template-columns:1fr 92px;align-items:center;gap:14px}.rf-threshold label{display:flex;justify-content:space-between;gap:8px;color:var(--paper);font-size:11px}.rf-threshold label span{color:var(--muted)}.rf-threshold input[type=range]{width:100%;accent-color:var(--lime)}.rf-number{position:relative}.rf-number input{width:100%;padding:9px 27px 9px 10px;border:1px solid var(--line);border-radius:4px;background:rgba(0,0,0,.18);color:var(--paper);outline:0}.rf-number input:focus{border-color:var(--lime)}.rf-number:after{content:"°C";position:absolute;right:8px;top:10px;color:var(--muted);font-size:10px}.rf-divider{height:1px;margin:20px 0;background:var(--line)}.rf-actions{display:flex;gap:9px}.rf-btn{flex:1;min-height:43px;border:1px solid var(--line);border-radius:4px;background:transparent;color:var(--paper);cursor:pointer}.rf-btn.primary{border-color:var(--lime);background:var(--lime);color:var(--ink);font-weight:800}.rf-btn:disabled{cursor:not-allowed;opacity:.35}.rf-msg{min-height:20px;margin:11px 0 0;color:var(--muted);font-size:11px;line-height:1.5}.rf-msg.error,.rf-msg.warning{color:var(--orange)}.rf-msg.ok{color:var(--lime)}
		.rf-foot{display:flex;justify-content:space-between;gap:12px;margin-top:13px;color:#686b61;font-size:9px;letter-spacing:.08em;text-transform:uppercase}
		@media(max-width:1050px){.rf-grid,.rf-work{grid-template-columns:1fr}}@media(max-width:650px){.r3fan-app{padding:10px}.rf-top{align-items:flex-start}.rf-node{display:none}.rf-hero{grid-template-columns:1fr;padding:20px}.rf-fanbox{border:0;border-top:1px solid var(--line);padding-top:23px}.rf-temp{margin:22px 0}.rf-temp strong{font-size:106px}.rf-note{margin-bottom:23px}.rf-threshold{grid-template-columns:1fr 82px}.rf-foot{flex-direction:column}}@media(prefers-reduced-motion:reduce){.r3fan-app *{animation-duration:.01ms!important;animation-iteration-count:1!important}}
		</style>
		<div class="rf-top"><div class="rf-brand"><span class="rf-mark"></span><span>BPI-R3 Mini / Thermal</span></div><div><span class="rf-pill rf-node">节点 ${location.hostname}</span> <span class="rf-pill"><i class="rf-dot"></i><span id="rf-connection">路由器实时数据</span></span></div></div>
		<section class="rf-grid">
			<article class="rf-panel rf-hero"><div><div class="rf-eye">CPU package temperature</div><div class="rf-temp"><strong id="rf-temp">--.-</strong><span>°C</span></div><p class="rf-note" id="rf-note"></p></div><div class="rf-fanbox"><div class="rf-fan" id="rf-fan"><i class="rf-blade"></i><i class="rf-blade"></i><i class="rf-blade"></i><i class="rf-blade"></i><i class="rf-hub"></i></div><div class="rf-stage"><div class="rf-eye">Current stage</div><strong id="rf-stage">--</strong></div></div></article>
			<aside class="rf-panel rf-metrics"><div class="rf-metric"><span class="rf-eye">风扇输出</span><strong id="rf-pwm">--</strong><small id="rf-pwm-note">等待硬件数据</small></div><div class="rf-metric"><span class="rf-eye">内核模式</span><strong id="rf-kernel">--</strong><small id="rf-kernel-note">等待数据</small></div><div class="rf-metric"><span class="rf-eye">采样周期</span><strong id="rf-interval">--</strong><small>页面与控制器<br>按周期刷新</small></div><div class="rf-metric"><span class="rf-eye">运行策略</span><strong id="rf-policy">--</strong><small>手动档位重启后<br>恢复自动温控</small></div></aside>
		</section>
		<section class="rf-work">
			<article class="rf-panel"><div class="rf-head"><div><div class="rf-eye">Hysteresis map</div><div class="rf-title">温控回差曲线</div></div><span class="rf-pill">高温优先保护</span></div><div class="rf-curvebody"><svg class="rf-curve" id="rf-curve" viewBox="0 0 760 260" role="img" aria-label="风扇升档和降档曲线"></svg><div class="rf-legend"><span><i></i>升温档位</span><span><i class="down"></i>降温档位</span><span>阴影区域 = 回差，防止临界温度抖动</span></div></div></article>
			<article class="rf-panel"><div class="rf-head"><div><div class="rf-eye">Controller</div><div class="rf-title">风扇控制</div></div><span class="rf-pill" id="rf-dirty">参数已同步</span></div><div class="rf-control"><div class="rf-eye">运行模式</div><div class="rf-modes" id="rf-modes"><button data-mode="auto">自动</button><button data-mode="low">低速</button><button data-mode="medium">中速</button><button data-mode="high">高速</button></div><div class="rf-thresholds" id="rf-thresholds"></div><div class="rf-divider"></div><div class="rf-actions"><button class="rf-btn" id="rf-reset">恢复当前值</button><button class="rf-btn primary" id="rf-apply">应用并重启服务</button></div><p class="rf-msg" id="rf-message" aria-live="polite">自动模式使用回差调速；手动模式不会永久保存，设备重启后恢复自动。</p></div></article>
		</section>
		<footer class="rf-foot"><span>R3MINI-FAN / LIVE</span><span>INVERTED PWM / 0 = FULL SPEED</span></footer>`;

		this.root = root;
		this.status = status;
		this.saved = Object.assign({}, status.config);
		this.config = Object.assign({}, status.config);
		this.busy = false;
		this.renderInputs();
		this.bindEvents();
		this.updateStatus(status);

		poll.add(function() {
			return self.call(['status']).then(function(data) {
				self.updateStatus(data);
			}).catch(function(error) {
				self.setMessage(error.message, 'error');
				self.root.querySelector('#rf-connection').textContent = '连接异常';
			});
		}, 5);

		return root;
	},

	renderInputs: function() {
		var html = '';
		for (var i = 0; i < FIELDS.length; i++) {
			var field = FIELDS[i], key = field[0];
			html += '<div class="rf-threshold"><div><label for="rf-' + key + '-range"><span>' + field[1] + '</span><code>' + field[2] + '</code></label><input id="rf-' + key + '-range" data-key="' + key + '" type="range" min="20" max="80" step="1" value="' + this.config[key] + '"></div><div class="rf-number"><input id="rf-' + key + '" data-key="' + key + '" type="number" min="20" max="80" step="1" value="' + this.config[key] + '" aria-label="' + field[1] + '"></div></div>';
		}
		this.root.querySelector('#rf-thresholds').innerHTML = html;
		this.syncInputs();
	},

	bindEvents: function() {
		var self = this;
		this.root.querySelector('#rf-thresholds').addEventListener('input', function(event) {
			var key = event.target.getAttribute('data-key');
			if (!key) return;
			self.config[key] = Number(event.target.value);
			self.syncInputs();
			if (self.validate()) self.setMessage('参数尚未应用，路由器仍使用已保存阈值；点击“应用并重启服务”后生效。', 'warning');
		});
		this.root.querySelector('#rf-modes').addEventListener('click', function(event) {
			var button = event.target.closest('button');
			if (button && !self.busy) self.setMode(button.getAttribute('data-mode'));
		});
		this.root.querySelector('#rf-reset').addEventListener('click', function() {
			self.config = Object.assign({}, self.saved);
			self.syncInputs();
			self.setMessage('已恢复为路由器当前配置。');
		});
		this.root.querySelector('#rf-apply').addEventListener('click', function() {
			self.applyConfig();
		});
	},

	syncInputs: function() {
		for (var i = 0; i < FIELDS.length; i++) {
			var key = FIELDS[i][0], nodes = this.root.querySelectorAll('[data-key="' + key + '"]');
			for (var n = 0; n < nodes.length; n++) nodes[n].value = this.config[key];
		}
		this.root.querySelector('#rf-dirty').textContent = JSON.stringify(this.config) === JSON.stringify(this.saved) ? '参数已同步' : '未应用（点击保存）';
		this.root.querySelector('#rf-apply').disabled = !this.validate() || this.busy;
		this.drawCurve();
	},

	validate: function() {
		var c = this.config;
		var values = FIELDS.map(function(field) { return c[field[0]]; });
		var range = values.every(function(value) { return Number.isInteger(value) && value >= 20 && value <= 80; });
		var valid = range && c.stop < c.start && c.start <= c.mediumUp && c.mediumUp < c.highUp && c.mediumDown < c.mediumUp && c.highDown < c.highUp;
		if (!valid) this.setMessage('阈值无效：停止 < 启动 ≤ 中速升档 < 高速升档，且各降档值必须低于对应升档值。', 'error');
		return valid;
	},

	setBusy: function(value) {
		this.busy = value;
		var controls = this.root.querySelectorAll('button,input');
		for (var i = 0; i < controls.length; i++) controls[i].disabled = value;
		if (!value) this.syncInputs();
	},

	setMode: function(mode) {
		var self = this;
		this.setBusy(true);
		this.setMessage('正在切换风扇模式…');
		this.call(['mode', mode]).then(function(data) {
			self.updateStatus(data);
			self.setMessage(mode === 'auto' ? '已恢复自动回差温控。' : '已切换手动档位；设备重启后恢复自动。', 'ok');
		}).catch(function(error) {
			self.setMessage(error.message, 'error');
			ui.addNotification(null, E('p', {}, error.message), 'danger');
		}).finally(function() { self.setBusy(false); });
	},

	applyConfig: function() {
		var self = this;
		if (!this.validate()) return;
		var args = ['apply'].concat(FIELDS.map(function(field) { return String(self.config[field[0]]); }));
		this.setBusy(true);
		this.setMessage('正在保存配置并重启风扇服务…');
		this.call(args).then(function(data) {
			self.status = data;
			self.saved = Object.assign({}, data.config);
			self.config = Object.assign({}, data.config);
			self.updateStatus(data);
			self.setMessage('配置已写入路由器，自动温控服务运行正常。', 'ok');
		}).catch(function(error) {
			self.setMessage(error.message, 'error');
			ui.addNotification(null, E('p', {}, error.message), 'danger');
		}).finally(function() { self.setBusy(false); });
	},

	updateStatus: function(data) {
		this.status = data;
		var state = Number(data.state);
		var names = ['停转', '低速', '中速', '高速'];
		var speeds = ['0s', '2.4s', '1.25s', '.65s'];
		var temperature = Number(data.temp) / 1000;
		var gearMode = ['off', 'low', 'medium', 'high'][state];
		var activeMode = data.control_mode === 'auto' ? 'auto' : data.control_mode === 'manual' ? gearMode : 'kernel';
		var buttons = this.root.querySelectorAll('#rf-modes button');
		for (var i = 0; i < buttons.length; i++) {
			var buttonMode = buttons[i].getAttribute('data-mode');
			buttons[i].classList.toggle('active', buttonMode === gearMode);
			buttons[i].classList.toggle('auto-running', buttonMode === 'auto' && data.control_mode === 'auto');
		}
		this.root.querySelector('#rf-temp').textContent = temperature.toFixed(1);
		this.root.querySelector('#rf-stage').textContent = names[state] || '未知';
		var outputPercent = Math.round((255 - Number(data.pwm)) / 255 * 100);
		this.root.querySelector('#rf-pwm').textContent = outputPercent + '%';
		this.root.querySelector('#rf-pwm-note').innerHTML = '有效风扇功率<br>反相 PWM 原始值=' + data.pwm;
		this.root.querySelector('#rf-kernel').textContent = data.mode === 'disabled' ? 'OFF' : 'ON';
		this.root.querySelector('#rf-kernel-note').innerHTML = data.running ? '用户态服务接管<br>mode=disabled' : '服务未运行<br>mode=' + data.mode;
		this.root.querySelector('#rf-interval').textContent = data.interval + 's';
		this.root.querySelector('#rf-policy').textContent = activeMode === 'auto' ? 'AUTO' : activeMode === 'kernel' ? 'KERNEL' : 'MANUAL';
		this.root.querySelector('#rf-connection').textContent = '路由器实时数据';
		var fan = this.root.querySelector('#rf-fan');
		fan.classList.toggle('spinning', state !== 0);
		fan.style.setProperty('--fan-speed', speeds[state] || '1s');
		var down = state === 3 ? this.config.highDown : state === 2 ? this.config.mediumDown : this.config.stop;
		this.root.querySelector('#rf-note').textContent = '目标低于 ' + this.config.highUp + '°C。当前为' + (names[state] || '未知') + '档；温度降至 ' + down + '°C 后才会降低档位。';
	},

	drawCurve: function() {
		var c = this.config, svg = this.root.querySelector('#rf-curve');
		var x = function(t) { return 70 + (t - 20) / 60 * 650; };
		var y = function(s) { return 220 - s * 58; };
		var labels = ['停转', '低速', '中速', '高速'];
		var grid = labels.map(function(label, s) { return '<line x1="70" y1="' + y(s) + '" x2="720" y2="' + y(s) + '" stroke="rgba(231,226,211,.10)"/><text x="18" y="' + (y(s)+4) + '" fill="#8d9085" font-size="11">' + label + '</text>'; }).join('');
		var ticks = [20,30,40,50,60,70,80].map(function(t) { return '<line x1="' + x(t) + '" y1="220" x2="' + x(t) + '" y2="225" stroke="#8d9085"/><text x="' + x(t) + '" y="246" text-anchor="middle" fill="#8d9085" font-size="10">' + t + '°</text>'; }).join('');
		var up = [[20,0],[c.start,0],[c.start,1],[c.mediumUp,1],[c.mediumUp,2],[c.highUp,2],[c.highUp,3],[80,3]];
		var down = [[80,3],[c.highDown,3],[c.highDown,2],[c.mediumDown,2],[c.mediumDown,1],[c.stop,1],[c.stop,0],[20,0]];
		var points = function(values) { return values.map(function(v) { return x(v[0]) + ',' + y(v[1]); }).join(' '); };
		var bands = [[c.stop,c.start,0],[c.mediumDown,c.mediumUp,1],[c.highDown,c.highUp,2]].map(function(v) { return '<rect x="' + x(v[0]) + '" y="' + y(v[2]+1) + '" width="' + Math.max(2,x(v[1])-x(v[0])) + '" height="58" fill="rgba(199,255,40,.055)"/>'; }).join('');
		svg.innerHTML = bands + grid + ticks + '<polyline points="' + points(up) + '" fill="none" stroke="#c7ff28" stroke-width="4" stroke-linejoin="round"/><polyline points="' + points(down) + '" fill="none" stroke="#ff6b2c" stroke-width="2" stroke-dasharray="7 7" stroke-linejoin="round"/>';
	},

	setMessage: function(text, type) {
		var node = this.root && this.root.querySelector('#rf-message');
		if (!node) return;
		node.className = 'rf-msg' + (type ? ' ' + type : '');
		node.textContent = text;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
