'use strict';
'require view';
'require fs';
'require poll';
'require ui';

var HELPER = '/usr/sbin/r3mini-fan-web';
// [key, 标签, UCI 键, min, max]。只有这 4 个是配置真身：3 个"到这个温度就开这一档"，
// 外加一个统一回差决定什么时候降回去。停转/降档三条线由 derived() 算出来，页面不存、
// 不让改、也不从后端读——后端 status.config 同样只回这 4 个值。
var FIELDS = [
	['start', '低速开启', 'start_temp', 20, 80],
	['mediumUp', '中速开启', 'medium_up', 20, 80],
	['highUp', '高速开启', 'high_up', 20, 80],
	['hysteresis', '回差回落', 'hysteresis', 1, 10]
];

// 与 r3mini-fanctl 的 derive_thresholds()、r3mini-fan-web 的校验链同一条减法。
function derived(c) {
	return { stop: c.start - c.hysteresis, mediumDown: c.mediumUp - c.hysteresis, highDown: c.highUp - c.hysteresis };
}

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
		.r3fan-app{--ink:#151712;--paper:#e7e2d3;--lime:#c7ff28;--orange:#ff6b2c;--muted:#8d9085;--line:rgba(231,226,211,.16);color:var(--paper);font-family:"Bahnschrift","Noto Sans SC","Microsoft YaHei",sans-serif;background:linear-gradient(rgba(231,226,211,.035) 1px,transparent 1px),linear-gradient(90deg,rgba(231,226,211,.035) 1px,transparent 1px),radial-gradient(circle at 82% 14%,rgba(199,255,40,.08),transparent 28%),#0e100c;background-size:36px 36px,36px 36px,auto,auto;border-radius:6px;padding:13px;display:flex;flex-direction:column;min-height:calc(100vh - 130px)}
		.r3fan-app *{box-sizing:border-box}.r3fan-app button,.r3fan-app input{font:inherit}.rf-top{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px;padding-bottom:11px;border-bottom:1px solid var(--line)}
		.rf-brand{display:flex;align-items:center;gap:10px;font-weight:800;font-size:14px;letter-spacing:.08em}.rf-mark{flex:none;position:relative;width:24px;height:24px;border:2px solid var(--lime);border-radius:50%}.rf-mark:before,.rf-mark:after{content:"";position:absolute;inset:4px 10px;background:var(--lime);transform:rotate(45deg)}.rf-mark:after{transform:rotate(-45deg)}
		.rf-pill{display:inline-flex;align-items:center;gap:7px;padding:5px 9px;border:1px solid var(--line);border-radius:99px;color:var(--paper);font-size:11px}.rf-dot{width:6px;height:6px;border-radius:50%;background:var(--lime);box-shadow:0 0 13px var(--lime)}
		.rf-panel{overflow:hidden;border:1px solid var(--line);border-radius:6px;background:rgba(24,26,21,.9);box-shadow:0 14px 40px rgba(0,0,0,.22)}
		/* flex:1 + align-items:stretch + 第二行 1fr：面板拉伸铺满可用高度，不在底部留白 */
		/* 左右两栏：左列堆 温度/指标/曲线，右列整条放控制器。
		   控制器天然很高，若与 hero 同处一行会把 hero、metrics 一起拉高留出大片空白；
		   分成两栏后左侧三块的总高与右侧接近，多余空间被三块分摊，不集中在一处。 */
		.rf-layout{display:grid;gap:11px;margin-top:11px;grid-template-columns:minmax(0,1.55fr) minmax(318px,1fr);grid-template-areas:"hero ctrl" "metrics ctrl" "curve ctrl"}
		.rf-hero{grid-area:hero}.rf-metrics{grid-area:metrics}.rf-curvepanel{grid-area:curve}.rf-ctrlpanel{grid-area:ctrl;align-self:start}
		.rf-hero{position:relative;display:grid;grid-template-columns:minmax(0,1fr) auto;align-content:center;gap:14px;padding:16px}.rf-hero>div:first-child{display:flex;flex-direction:column;justify-content:center}.rf-eye{color:var(--muted);font-size:clamp(10px,.62vw,14px);font-weight:800;letter-spacing:.18em;text-transform:uppercase}.rf-temp{display:flex;align-items:flex-end;gap:5px;margin-top:10px;line-height:.82}.rf-temp strong{font-family:"DIN Condensed","Bahnschrift Condensed",Impact,sans-serif;font-size:clamp(52px,6.6vw,164px);letter-spacing:-.055em}.rf-temp span{padding-bottom:5px;color:var(--lime);font:italic clamp(20px,2.4vw,54px) Georgia,serif}		.rf-fanbox{display:grid;place-items:center;align-content:center;padding-left:14px;border-left:1px solid var(--line)}.rf-fan{--fanpx:clamp(86px,min(9.2vw,25vh),250px);position:relative;width:var(--fanpx);height:var(--fanpx);border:1px solid rgba(231,226,211,.23);border-radius:50%}.rf-fan.spinning{animation:rf-spin var(--fan-speed,1.2s) linear infinite}.rf-blade{position:absolute;left:calc(var(--fanpx)*.4414);top:calc(var(--fanpx)*.0966);width:calc(var(--fanpx)*.2759);height:calc(var(--fanpx)*.4069);border-radius:60% 10% 70% 26%;background:linear-gradient(145deg,var(--lime),#688817);transform-origin:calc(var(--fanpx)*.0552) calc(var(--fanpx)*.4)}.rf-blade:nth-child(2){transform:rotate(90deg)}.rf-blade:nth-child(3){transform:rotate(180deg)}.rf-blade:nth-child(4){transform:rotate(270deg)}.rf-hub{position:absolute;inset:calc(var(--fanpx)*.3931);z-index:2;border-radius:50%;background:var(--paper);box-shadow:0 0 0 calc(var(--fanpx)*.048) var(--ink)}@keyframes rf-spin{to{transform:rotate(360deg)}}.rf-stage{text-align:center;margin-top:11px}.rf-stage strong{display:block;font-size:clamp(17px,1.35vw,32px);margin-top:3px}
		.rf-metrics{display:grid;grid-template-columns:repeat(2,1fr);align-content:stretch}.rf-metric{display:flex;flex-direction:column;gap:6px;justify-content:center;min-height:78px;padding:11px 13px;border-right:1px solid var(--line);border-bottom:1px solid var(--line)}.rf-metric:nth-child(2n){border-right:0}.rf-metric:nth-child(n+3){border-bottom:0}.rf-metric strong{font:italic clamp(22px,2.1vw,46px) Georgia,serif}.rf-metric small{color:var(--muted);font-size:clamp(10px,.7vw,14px);line-height:1.45}
		.rf-head{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px;padding:11px 14px;border-bottom:1px solid var(--line)}.rf-title{margin:2px 0 0;color:var(--paper);font-size:clamp(16px,1.2vw,28px);font-weight:800}
		/* 曲线面板整列拉伸，SVG 吃掉剩余高度——这是"铺满"而不是留白的关键 */
		.rf-curvebody{padding:11px 14px 14px}.rf-curve{display:block;width:100%;height:clamp(150px,22vh,360px)}.rf-legend{display:flex;flex-wrap:wrap;gap:12px;margin-top:6px;color:var(--muted);font-size:clamp(10px,.66vw,13px)}.rf-legend i{display:inline-block;width:15px;height:2px;margin-right:5px;vertical-align:middle;background:var(--lime)}.rf-legend i.down{background:var(--orange)}
		.rf-control{padding:13px 14px}.rf-modes{display:grid;grid-template-columns:repeat(4,1fr);margin:6px 0 11px;border:1px solid var(--line);border-radius:5px;overflow:hidden}.rf-modes button{min-height:38px;border:0;border-right:1px solid var(--line);background:transparent;color:var(--muted);cursor:pointer}.rf-modes button:last-child{border-right:0}.rf-modes button.active{background:var(--lime);color:var(--ink);font-weight:800}.rf-modes button.auto-running{color:var(--lime);box-shadow:inset 0 -3px var(--lime)}.rf-modes button:disabled{cursor:wait;opacity:.45}
		.rf-night{margin:0 0 11px;padding:10px 12px;border:1px solid var(--line);border-radius:5px;background:rgba(0,0,0,.14)}.rf-night-head{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:8px}.rf-toggle{display:flex;align-items:center;gap:9px;color:var(--paper);font-size:13px;font-weight:800;cursor:pointer}.rf-toggle input{flex:none;width:16px;height:16px;accent-color:var(--lime);cursor:pointer}.rf-night-badge{border-color:var(--orange);color:var(--orange);font-weight:800}.rf-night-badge[hidden]{display:none}.rf-night-row{display:grid;grid-template-columns:minmax(0,1fr) auto minmax(0,1fr) auto;align-items:center;gap:8px;margin-top:9px}.rf-night-row input[type=time]{width:100%;min-width:0;padding:7px 8px;border:1px solid var(--line);border-radius:4px;background:rgba(0,0,0,.18);color:var(--paper);outline:0}.rf-night-row input[type=time]:focus{border-color:var(--lime)}.rf-night-arrow{color:var(--muted);font-size:12px}.rf-night-row .rf-btn{flex:none;min-height:34px;padding:0 12px}.rf-night-guard{display:grid;grid-template-columns:minmax(0,1fr) 78px;align-items:center;gap:10px;margin-top:8px;color:var(--paper);font-size:11px}.rf-night-note{margin:8px 0 0;color:var(--muted);font-size:10px;line-height:1.55}
		.rf-thresholds{display:grid;gap:9px 10px;grid-template-columns:repeat(auto-fit,minmax(230px,1fr))}.rf-threshold{display:grid;grid-template-columns:minmax(0,1fr) 76px;align-items:center;gap:10px}.rf-threshold label{display:flex;flex-wrap:nowrap;justify-content:space-between;gap:8px;margin-bottom:2px;color:var(--paper);font-size:11px;white-space:nowrap}.rf-threshold label code{min-width:0;overflow:hidden;text-overflow:ellipsis}.rf-threshold label span{color:var(--muted)}.rf-threshold input[type=range]{width:100%;accent-color:var(--lime)}.rf-number{position:relative}.rf-number input{width:100%;padding:7px 21px 7px 7px;border:1px solid var(--line);border-radius:4px;background:rgba(0,0,0,.18);color:var(--paper);outline:0}.rf-number input:focus{border-color:var(--lime)}.rf-number:after{content:"°C";position:absolute;right:5px;top:8px;color:var(--muted);font-size:10px}.rf-divider{height:1px;margin:13px 0;background:var(--line)}.rf-actions{display:flex;flex-wrap:wrap;gap:8px}.rf-btn{flex:1 1 140px;min-height:40px;border:1px solid var(--line);border-radius:4px;background:transparent;color:var(--paper);cursor:pointer}.rf-btn.primary{border-color:var(--lime);background:var(--lime);color:var(--ink);font-weight:800}.rf-btn:disabled{cursor:not-allowed;opacity:.35}.rf-msg{min-height:18px;margin:9px 0 0;color:var(--muted);font-size:11px;line-height:1.5}.rf-msg.error,.rf-msg.warning{color:var(--orange)}.rf-msg.ok{color:var(--lime)}
		.rf-foot{display:flex;flex-wrap:wrap;justify-content:space-between;gap:8px;margin-top:10px;color:#686b61;font-size:9px;letter-spacing:.08em;text-transform:uppercase}
		@media(max-width:900px){.rf-layout{grid-template-columns:minmax(0,1fr);grid-template-areas:"hero" "metrics" "ctrl" "curve"}}
		@media(max-width:560px){.r3fan-app{padding:9px}.rf-top{align-items:flex-start}.rf-node{display:none}.rf-hero{grid-template-columns:1fr;padding:14px}.rf-fanbox{padding:13px 0 0;border:0;border-top:1px solid var(--line)}.rf-threshold{grid-template-columns:minmax(0,1fr) 72px}.rf-night-row{grid-template-columns:minmax(0,1fr) auto minmax(0,1fr)}.rf-night-row .rf-btn{grid-column:1/-1;margin-top:3px}.rf-foot{flex-direction:column;gap:3px}}
		@media(pointer:coarse){.rf-modes button{min-height:44px}.rf-btn{min-height:44px}.rf-night-row .rf-btn{min-height:44px}.rf-night-row input[type=time]{min-height:42px}.rf-number input{min-height:42px}.rf-toggle{min-height:44px}.rf-toggle input{width:20px;height:20px}.rf-threshold input[type=range]{height:28px}}
		@media(prefers-reduced-motion:reduce){.r3fan-app *{animation-duration:.01ms!important;animation-iteration-count:1!important}}
		</style>
		<div class="rf-top"><div class="rf-brand"><span class="rf-mark"></span><span>BPI-R3 Mini / Thermal</span></div><div><span class="rf-pill rf-node">节点 ${location.hostname}</span> <span class="rf-pill"><i class="rf-dot"></i><span id="rf-connection">路由器实时数据</span></span></div></div>
		<section class="rf-layout">
			<article class="rf-panel rf-hero"><div><div class="rf-eye">CPU package temperature</div><div class="rf-temp"><strong id="rf-temp">--.-</strong><span>°C</span></div></div><div class="rf-fanbox"><div class="rf-fan" id="rf-fan"><i class="rf-blade"></i><i class="rf-blade"></i><i class="rf-blade"></i><i class="rf-blade"></i><i class="rf-hub"></i></div><div class="rf-stage"><div class="rf-eye">Current stage</div><strong id="rf-stage">--</strong></div></div></article>
			<aside class="rf-panel rf-metrics"><div class="rf-metric"><span class="rf-eye">风扇输出</span><strong id="rf-pwm">--</strong><small id="rf-pwm-note">等待硬件数据</small></div><div class="rf-metric"><span class="rf-eye">内核模式</span><strong id="rf-kernel">--</strong><small id="rf-kernel-note">等待数据</small></div><div class="rf-metric"><span class="rf-eye">采样周期</span><strong id="rf-interval">--</strong><small>页面与控制器<br>按周期刷新</small></div><div class="rf-metric"><span class="rf-eye">运行策略</span><strong id="rf-policy">--</strong><small>手动档位重启后<br>恢复自动温控</small></div></aside>
			<article class="rf-panel rf-curvepanel"><div class="rf-head"><div><div class="rf-eye">Hysteresis map</div><div class="rf-title">温控回差曲线</div></div><span class="rf-pill">高温优先保护</span></div><div class="rf-curvebody"><svg class="rf-curve" id="rf-curve" viewBox="0 0 760 260" preserveAspectRatio="xMidYMid meet" role="img" aria-label="风扇升档和降档曲线"></svg><div class="rf-legend"><span><i></i>升温档位</span><span><i class="down"></i>降温档位</span><span>阴影区域 = 回差，防止临界温度抖动</span></div></div></article>
			<article class="rf-panel rf-ctrlpanel"><div class="rf-head"><div><div class="rf-eye">Controller</div><div class="rf-title">风扇控制</div></div><span class="rf-pill" id="rf-dirty">参数已同步</span></div><div class="rf-control"><div class="rf-eye">运行模式</div><div class="rf-modes" id="rf-modes"><button data-mode="auto">自动</button><button data-mode="low">低速</button><button data-mode="medium">中速</button><button data-mode="high">高速</button></div><div class="rf-night"><div class="rf-night-head"><label class="rf-toggle" for="rf-night-enabled"><input type="checkbox" id="rf-night-enabled"><span>夜间模式</span></label><span class="rf-pill rf-night-badge" id="rf-night-badge" hidden>限速中</span></div><div class="rf-night-row"><input type="time" id="rf-night-start" value="23:00" aria-label="夜间开始时间"><span class="rf-night-arrow">→</span><input type="time" id="rf-night-end" value="07:00" aria-label="夜间结束时间"><button class="rf-btn" id="rf-night-save">保存</button></div><div class="rf-night-guard"><label for="rf-night-override">硬件保护 · 解除限速温度</label><div class="rf-number"><input type="number" id="rf-night-override" min="45" max="95" step="1" value="55" aria-label="解除限速温度"></div></div><p class="rf-night-note">仅叠加在自动模式，窗口内封顶中速；超过上方温度即解除，手动档位不受影响。</p></div><div class="rf-thresholds" id="rf-thresholds"></div><div class="rf-divider"></div><div class="rf-actions"><button class="rf-btn" id="rf-reset">恢复当前值</button><button class="rf-btn primary" id="rf-apply">应用并重启服务</button></div><p class="rf-msg" id="rf-message" aria-live="polite">自动模式使用回差调速；手动模式不会永久保存，设备重启后恢复自动。</p></div></article>
		</section>
		<footer class="rf-foot"><span>R3MINI-FAN / LIVE</span><span>INVERTED PWM / 1 = FULL SPEED / 0 = PWM OFF</span></footer>`;

		this.root = root;
		this.status = status;
		this.saved = Object.assign({}, status.config);
		this.config = Object.assign({}, status.config);
		this.busy = false;
		this.nightDirty = false;
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
			var field = FIELDS[i], key = field[0], lo = field[3], hi = field[4];
			html += '<div class="rf-threshold"><div><label for="rf-' + key + '-range"><span>' + field[1] + '</span><code>' + field[2] + '</code></label><input id="rf-' + key + '-range" data-key="' + key + '" type="range" min="' + lo + '" max="' + hi + '" step="1" value="' + this.config[key] + '"></div><div class="rf-number"><input id="rf-' + key + '" data-key="' + key + '" type="number" min="' + lo + '" max="' + hi + '" step="1" value="' + this.config[key] + '" aria-label="' + field[1] + '"></div></div>';
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
		// 时间框和温度框改动后标脏，避免 5 秒一次的轮询把用户正在输入的值覆盖掉。
		this.root.querySelector('.rf-night').addEventListener('input', function(event) {
			if (event.target.type === 'time' || event.target.type === 'number') self.nightDirty = true;
		});
		// 开关按“立即生效”处理：拨一下就落盘，不需要再点保存。
		this.root.querySelector('#rf-night-enabled').addEventListener('change', function() {
			if (!self.busy) self.applyNight();
		});
		this.root.querySelector('#rf-night-save').addEventListener('click', function() {
			if (!self.busy) self.applyNight();
		});
	},

	renderNight: function(data) {
		var night = data.night || {};
		var enabled = Number(night.enabled) === 1;
		var badge = this.root.querySelector('#rf-night-badge');
		if (!this.nightDirty) {
			this.root.querySelector('#rf-night-enabled').checked = enabled;
			this.root.querySelector('#rf-night-start').value = night.start || '23:00';
			this.root.querySelector('#rf-night-end').value = night.end || '07:00';
			this.root.querySelector('#rf-night-override').value = night.override;
		}
		badge.hidden = night.active !== true;
		// 说明文字改成 HTML 里的静态一行，不再回填时间段和解除温度：那两个值上面的控件就是真身。
	},

	applyNight: function() {
		var self = this;
		var enabled = this.root.querySelector('#rf-night-enabled').checked ? '1' : '0';
		var start = this.root.querySelector('#rf-night-start').value;
		var end = this.root.querySelector('#rf-night-end').value;
		var override = Number(this.root.querySelector('#rf-night-override').value);
		if (!/^\d{2}:\d{2}$/.test(start) || !/^\d{2}:\d{2}$/.test(end)) {
			this.setMessage('夜间时间必须填写为 HH:MM。', 'error');
			return;
		}
		if (start === end) {
			this.setMessage('夜间开始与结束时间不能相同。', 'error');
			return;
		}
		if (!Number.isInteger(override) || override < 45 || override > 95) {
			this.setMessage('解除限速温度必须是 45–95 之间的整数。', 'error');
			return;
		}
		if (override <= this.config.highUp) {
			this.setMessage('解除限速温度必须高于高速开启的 ' + this.config.highUp + '°C，否则夜间限速永远不会生效。', 'error');
			return;
		}
		this.setBusy(true);
		this.setMessage('正在保存夜间模式设置…');
		this.call(['night', enabled, start, end, String(override)]).then(function(data) {
			self.nightDirty = false;
			self.updateStatus(data);
			self.setMessage(enabled === '1'
				? '夜间模式已写入路由器：' + start + '–' + end + ' 最高中速，最迟 ' + data.interval + ' 秒后生效。'
				: '夜间模式已关闭，自动温控恢复完整档位。', 'ok');
		}).catch(function(error) {
			self.setMessage(error.message, 'error');
			ui.addNotification(null, E('p', {}, error.message), 'danger');
		}).finally(function() { self.setBusy(false); });
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
		var range = FIELDS.every(function(field) {
			var v = c[field[0]];
			return Number.isInteger(v) && v >= field[3] && v <= field[4];
		});
		// 三层闸门（本视图 / r3mini-fan-web / r3mini-fanctl）同一条链，缺一不可。
		// 旧模型在这里抄了 7 条，其中 5 条是这 2 条的推论——回差模型让它们自动成立。
		// fanctl 另有 hysteresis<start_temp（防停转温度变负），本层不抄：上面的
		// range 已保证 回差<=10 < 20<=低速开启，抄过来是一条永远为真的死校验。
		var valid = range && c.start < c.mediumUp && c.mediumUp < c.highUp;
		if (!valid) {
			this.setMessage('参数无效：低速开启 < 中速开启 < 高速开启，温度取 20–80°C，回差取 1–10°C。', 'error');
			return false;
		}
		// r3mini-fan-web 的 apply_config 还拦一条 high_up < night_override（否则夜间限速在
		// 高温段静默失效）。此前只有后端有这条，页面的"应用"按钮不会变灰，用户点下去才报错——
		// 与"不通过就保持禁用"的承诺不符。两边现在同一条。
		var override = this.status && this.status.night ? Number(this.status.night.override) : NaN;
		if (Number.isFinite(override) && c.highUp >= override) {
			this.setMessage('高速开启温度必须低于夜间解除限速温度 ' + override + '°C，否则夜间限速在高温段会静默失效；要设更高的高速开启温度，请先调高下方夜间设置里的解除限速温度。', 'error');
			return false;
		}
		return true;
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
		// state/pwm 为 -1 = 助手读不出 PWM 接口。此时报"未知"而不是"停转 0%"：
		// 接口坏掉恰恰是最该有人去现场看的情况，谎报一个确定的 0 会把它藏起来。
		var pwm = Number(data.pwm);
		var pwmNode = this.root.querySelector('#rf-pwm'), pwmNote = this.root.querySelector('#rf-pwm-note');
		if (pwm < 0) {
			pwmNode.textContent = '--';
			pwmNote.innerHTML = '<b>PWM 接口读取失败</b><br>档位与功率均无法确认，请现场检查';
		} else if (pwm === 0) {
			// (255-0)/255 = 100%，但 pwm=0 触发驱动 pwm_disable()，风扇是停的。
			// 按公式显示 100% 会和左边的"停转"档位直接打架，且正好是最危险的误读方向。
			pwmNode.textContent = '0%';
			pwmNote.innerHTML = '<b>PWM 已被关闭（pwm1=0）</b><br>风扇停转，不是满速；写入 1 可立即抢回满速';
		} else {
			pwmNode.textContent = Math.round((255 - pwm) / 255 * 100) + '%';
			pwmNote.innerHTML = '有效风扇功率<br>反相 PWM 原始值=' + pwm;
		}
		this.root.querySelector('#rf-kernel').textContent = data.mode === 'disabled' ? 'OFF' : 'ON';
		this.root.querySelector('#rf-kernel-note').innerHTML = data.running ? '用户态服务接管<br>mode=disabled' : '服务未运行<br>mode=' + data.mode;
		this.root.querySelector('#rf-interval').textContent = data.interval + 's';
		var nightActive = data.night && data.night.active === true;
		this.root.querySelector('#rf-policy').textContent = activeMode === 'auto' ? (nightActive ? 'AUTO · 夜间' : 'AUTO') : activeMode === 'kernel' ? 'KERNEL' : 'MANUAL';
		this.renderNight(data);
		this.drawCurve();
		this.root.querySelector('#rf-connection').textContent = '路由器实时数据';
		var fan = this.root.querySelector('#rf-fan');
		fan.classList.toggle('spinning', state > 0);
		fan.style.setProperty('--fan-speed', speeds[state] || '1s');
		// 这里原本用文字复述阈值（目标温度、降档温度、夜间解除温度）。那些值的真身是右侧区间控件
		// 和夜间温度框，同一个数字两个地方显示只会让人怀疑哪个说了算。夜间是否生效由「运行策略」呈现。
	},

	drawCurve: function() {
		var c = this.config, svg = this.root.querySelector('#rf-curve');
		// viewBox 跟容器实际像素 1:1，缩放比恒为 1：既不会被 meet 上下留边，也不会被 none 拉变形。
		// 图表读自身尺寸是正常做法，这不是用 JS 模拟布局。
		var W = Math.max(320, Math.round(svg.clientWidth || 760));
		var H = Math.max(150, Math.round(svg.clientHeight || 240));
		svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
		var padL = 62, padR = 24, padT = 12, padB = 32;
		var band = (H - padT - padB) / 3;
		// 夹到 [20,80]：停转线 = 低速开启 − 回差，最低可到 10°C，落在 X 轴定义域之外。
		// 不夹紧会让降档折线画到 padL 左边，视觉上像"曲线跑出图表"。
		var x = function(t) { return padL + (Math.min(80, Math.max(20, t)) - 20) / 60 * (W - padL - padR); };
		var y = function(s) { return H - padB - s * band; };
		var labels = ['停转', '低速', '中速', '高速'];
		var grid = labels.map(function(label, s) { return '<line x1="' + padL + '" y1="' + y(s) + '" x2="' + (W - padR) + '" y2="' + y(s) + '" stroke="rgba(231,226,211,.10)"/><text x="10" y="' + (y(s) + 4) + '" fill="#8d9085" font-size="11">' + label + '</text>'; }).join('');
		var ticks = [20,30,40,50,60,70,80].map(function(t) { return '<line x1="' + x(t) + '" y1="' + (H - padB) + '" x2="' + x(t) + '" y2="' + (H - padB + 5) + '" stroke="#8d9085"/><text x="' + x(t) + '" y="' + (H - padB + 20) + '" text-anchor="middle" fill="#8d9085" font-size="10">' + t + '°</text>'; }).join('');
		var d = derived(c);
		var up = [[20,0],[c.start,0],[c.start,1],[c.mediumUp,1],[c.mediumUp,2],[c.highUp,2],[c.highUp,3],[80,3]];
		var down = [[80,3],[d.highDown,3],[d.highDown,2],[d.mediumDown,2],[d.mediumDown,1],[d.stop,1],[d.stop,0],[20,0]];
		var points = function(values) { return values.map(function(v) { return x(v[0]) + ',' + y(v[1]); }).join(' '); };
		var bands = [[d.stop,c.start,0],[d.mediumDown,c.mediumUp,1],[d.highDown,c.highUp,2]].map(function(v) { return '<rect x="' + x(v[0]) + '" y="' + y(v[2] + 1) + '" width="' + Math.max(2, x(v[1]) - x(v[0])) + '" height="' + band + '" fill="rgba(199,255,40,.055)"/>'; }).join('');
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
