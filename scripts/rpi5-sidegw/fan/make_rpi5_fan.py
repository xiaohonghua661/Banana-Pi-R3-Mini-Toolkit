"""Derive the Raspberry Pi 5 variant of 0.242's r3mini-fan app.

R3 Mini drives its fan with inverted PWM (255 = stop, 1 = full, 0 forbidden); the Pi 5 pwm-fan is
non-inverted (0 = stop, 255 = full). Only the PWM-dependent lines change, plus a lookup of the
pwmfan hwmon by name (the Pi's hwmon numbering is not fixed). Every replacement must match exactly
once, otherwise the script stops without writing anything.

Usage: python -I make_rpi5_fan.py <src_root_of_0.242_capture> <out_root>
"""
import pathlib
import sys

SRC = pathlib.Path(sys.argv[1])
OUT = pathlib.Path(sys.argv[2])

RESOLVER = (
    "# 树莓派 5：hwmon 序号随驱动加载顺序变化，按名字 pwmfan 找风扇接口，找到就覆盖上面的值。\n"
    "for h in /sys/class/hwmon/hwmon*; do [ \"$(cat \"$h/name\" 2>/dev/null)\" = pwmfan ] && "
    "{ PWM=\"$h/pwm1\"; PWM_ENABLE=\"$h/pwm1_enable\"; break; }; done\n"
)

EDITS = {
    "usr/sbin/r3mini-fanctl": [
        (
            'PWM_ENABLE="$(cfg pwm_enable)"; [ -n "$PWM_ENABLE" ] || PWM_ENABLE="/sys/class/hwmon/hwmon1/pwm1_enable"\n',
            'PWM_ENABLE="$(cfg pwm_enable)"; [ -n "$PWM_ENABLE" ] || PWM_ENABLE="/sys/class/hwmon/hwmon1/pwm1_enable"\n' + RESOLVER,
        ),
        (
            "\t\t# 反相驱动：pwm1 越小风扇越快（实听验证 25/80 有声、128 无声）。\n"
            "\t\t# 硬红线：任何分支都不许写 0——0 会触发 pwm_disable()，debugfs 里 enabled 字样消失，风扇彻底停转。\n"
            "\t\t0) pwm=255 ;; # stop:   duty 9999ns\n"
            "\t\t1) pwm=128 ;; # low:    duty 5020ns\n"
            "\t\t2) pwm=80  ;; # medium: duty 3137ns\n"
            "\t\t3) pwm=1   ;; # high:   duty 40ns，最快的合法值（0 是禁区）\n"
            "\t\t*) pwm=1 ;;   # 兜底同样取最快档，且同样不能写 0\n",
            "\t\t# 树莓派 5 是正相驱动：pwm1 越大风扇越快，0 就是停转（与 R3 Mini 相反）。\n"
            "\t\t# 75/150/255 对应低/中/满速（实测 75 约 2000 rpm）。\n"
            "\t\t0) pwm=0   ;; # stop\n"
            "\t\t1) pwm=75  ;; # low\n"
            "\t\t2) pwm=150 ;; # medium\n"
            "\t\t3) pwm=255 ;; # high\n"
            "\t\t*) pwm=255 ;; # 兜底取满速\n",
        ),
    ],
    "usr/sbin/r3mini-fan-web": [
        (
            "PWM_ENABLE=/sys/class/hwmon/hwmon1/pwm1_enable\n",
            "PWM_ENABLE=/sys/class/hwmon/hwmon1/pwm1_enable\n" + RESOLVER,
        ),
        (
            'echo 1 > "$PWM" 2>/dev/null && [ "$(cat "$THERMAL_MODE" 2>/dev/null)" = disabled ] && [ "$(read_num "$PWM")" = 1 ]',
            'echo 255 > "$PWM" 2>/dev/null && [ "$(cat "$THERMAL_MODE" 2>/dev/null)" = disabled ] && [ "$(read_num "$PWM")" = 255 ]',
        ),
        (
            "\t\t255) state=0 ;;\n"
            "\t\t128) state=1 ;;\n"
            "\t\t80) state=2 ;;\n"
            "\t\t1|25) state=3 ;; # 25 是旧版高速值，留着兼容尚未升级的设备\n"
            "\t\t# 0 曾被当成\"高速\"上报，这正是\"页面显示高速、风扇实际不转\"的根因：\n"
            "\t\t# 0 会让驱动 disable PWM。物理上风扇是停的，就如实报停转。\n"
            "\t\t0) state=0 ;;\n"
            "\t\t*) if [ \"$pwm\" -gt 192 ]; then state=0; elif [ \"$pwm\" -gt 104 ]; then state=1; elif [ \"$pwm\" -gt 40 ]; then state=2; else state=3; fi ;;\n",
            "\t\t# 树莓派 5 正相：0 停转，75 低速，150 中速，255 满速。\n"
            "\t\t0) state=0 ;;\n"
            "\t\t75) state=1 ;;\n"
            "\t\t150) state=2 ;;\n"
            "\t\t255) state=3 ;;\n"
            "\t\t*) if [ \"$pwm\" -lt 38 ]; then state=0; elif [ \"$pwm\" -lt 113 ]; then state=1; elif [ \"$pwm\" -lt 203 ]; then state=2; else state=3; fi ;;\n",
        ),
        (
            "\t\tlow) pwm=128 ;;\n\t\tmedium) pwm=80 ;;\n\t\thigh) pwm=1 ;;\n",
            "\t\tlow) pwm=75 ;;\n\t\tmedium) pwm=150 ;;\n\t\thigh) pwm=255 ;;\n",
        ),
    ],
}

JS_OLD = (
    "\t\t} else if (pwm === 0) {\n"
    "\t\t\t// (255-0)/255 = 100%，但 pwm=0 触发驱动 pwm_disable()，风扇是停的。\n"
    "\t\t\t// 按公式显示 100% 会和左边的\"停转\"档位直接打架，且正好是最危险的误读方向。\n"
    "\t\t\tpwmNode.textContent = '0%';\n"
    "\t\t\tpwmNote.innerHTML = '<b>PWM 已被关闭（pwm1=0）</b><br>风扇停转，不是满速；写入 1 可立即抢回满速';\n"
    "\t\t} else {\n"
    "\t\t\tpwmNode.textContent = Math.round((255 - pwm) / 255 * 100) + '%';\n"
    "\t\t\tpwmNote.innerHTML = '有效风扇功率<br>反相 PWM 原始值=' + pwm;\n"
)
JS_NEW = (
    "\t\t} else if (pwm === 0) {\n"
    "\t\t\t// 树莓派 5 是正相驱动：pwm1=0 就是停转。\n"
    "\t\t\tpwmNode.textContent = '0%';\n"
    "\t\t\tpwmNote.innerHTML = '<b>风扇停转（pwm1=0）</b><br>温度到低速开启线后自动起转';\n"
    "\t\t} else {\n"
    "\t\t\tpwmNode.textContent = Math.round(pwm / 255 * 100) + '%';\n"
    "\t\t\tpwmNote.innerHTML = '有效风扇功率<br>PWM 原始值=' + pwm;\n"
)
for name in ("r3mini-fan.js", "r3mini-fan-3848230b8f.js"):
    EDITS["www/luci-static/resources/view/system/" + name] = [(JS_OLD, JS_NEW)]

UNCHANGED = [
    "etc/init.d/r3mini-fan",
    "usr/share/luci/menu.d/luci-app-r3mini-fan.json",
    "usr/share/rpcd/acl.d/luci-app-r3mini-fan.json",
]

CONFIG = """
config fan 'main'
\toption sensor '/sys/class/thermal/thermal_zone0/temp'
\toption mode '/sys/class/thermal/thermal_zone0/mode'
\toption pwm '/sys/class/hwmon/hwmon2/pwm1'
\toption pwm_enable '/sys/class/hwmon/hwmon2/pwm1_enable'
\toption start_temp '50000'
\toption medium_up '60000'
\toption high_up '68000'
\toption hysteresis '5000'
\toption interval '5'
\toption night_enabled '0'
\toption night_start '00:00'
\toption night_end '07:00'
\toption night_override '75000'
"""

results = {}
for rel, edits in EDITS.items():
    text = (SRC / rel).read_text(encoding="utf-8")
    for old, new in edits:
        count = text.count(old)
        if count != 1:
            sys.exit(f"EDIT_MISMATCH {rel}: expected 1 match, got {count} for: {old[:60]!r}")
        text = text.replace(old, new)
    results[rel] = text
for rel, text in results.items():
    dst = OUT / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(text.encode("utf-8"))
for rel in UNCHANGED:
    dst = OUT / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes((SRC / rel).read_bytes())
cfg = OUT / "etc/config/r3mini_fan"
cfg.parent.mkdir(parents=True, exist_ok=True)
cfg.write_bytes(CONFIG.encode("utf-8"))
print("RPI5_FAN_BUILD_OK", len(results) + len(UNCHANGED) + 1, "files")
