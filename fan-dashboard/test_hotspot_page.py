"""在设备真实的 LuCI 页面上验收「网络 → 上网出口」。

    python fan-dashboard/test_hotspot_page.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242 [--candidate] [--out DIR]

- 经密钥 SSH 临时授权一个 LuCI 会话（照 rpcd 的 root 登录授权，不输入密码），结束后销毁。
- --candidate：把本地工作区的页面换进浏览器，状态与搜索由本地的 r3mini-hotspot-web + status.uc
  在设备 /tmp 里只读执行（真实数据）；不加时用设备上已装的版本。
- 保存、停用、切换出口、蜂窝开关、写密码文件这几类写命令一律在浏览器里拦下，返回假结果，不会到达设备。
- 各种状态（Wi-Fi 已连上、任务进行中/失败、读状态失败、恶意 SSID）用假数据注入。
覆盖：刷新节奏（平时 5 秒、后台标签不读、任务中 1 秒）、表单规则、搜索与选择、保存流程、
320–1440 宽度、暗色、字号不小于 12 px、控制台无报错。最后一行 PAGE_OK 或 PAGE_FAIL n。
"""
from __future__ import annotations

import argparse
import copy
import json
import secrets
import shlex
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from deploy_hotspot import ROOT, connect, local_bytes, run  # noqa: E402

HELPER = "/usr/sbin/r3mini-hotspot-web"
VIEW = "www/luci-static/resources/view/network/r3mini-hotspot.js"
WRITE_CMDS = {"save", "disable", "prefer", "cellular", "apply", "apply-file", "auto-select"}

FIX_SCAN = {"results": [
    {"ssid": "Phone5G", "channel": 44, "signal": -48, "encryption": {"enabled": True, "wpa": [2], "authentication": ["psk", "sae"]}},
    {"ssid": "CafeOpen", "channel": 149, "signal": -66, "encryption": {"enabled": False}},
    {"ssid": "DFS-AP", "channel": 52, "signal": -52, "encryption": {"enabled": True, "wpa": [2], "authentication": ["psk"]}},
    {"ssid": "<img src=x onerror=__xss=1>", "channel": 36, "signal": -75, "encryption": {"enabled": True, "wpa": [2], "authentication": ["psk"]}},
    {"ssid": "一个非常非常长的中文无线网络名称用来测试换行", "channel": 157, "signal": -80, "encryption": {"enabled": True, "wpa": [2], "authentication": ["sae"]}},
]}


def mint(client) -> str:
    sid = json.loads(run(client, "ubus call session create " + shlex.quote(json.dumps({"timeout": 1800}))))["ubus_rpc_session"]
    raw = run(client, "for f in /usr/share/rpcd/acl.d/*.json; do cat \"$f\"; printf '\\n@@ACL@@\\n'; done")
    grants: dict[str, list[list[str]]] = {}
    for block in raw.split("@@ACL@@"):
        try:
            data = json.loads(block.strip() or "null")
        except json.JSONDecodeError:
            continue
        for group, spec in (data or {}).items():
            for perm in ("read", "write"):
                scopes = spec.get(perm) if isinstance(spec, dict) else None
                if not isinstance(scopes, dict):
                    continue
                grants.setdefault("access-group", []).append([group, perm])
                for scope, value in scopes.items():
                    if isinstance(value, dict):
                        for obj, funcs in value.items():
                            grants.setdefault(scope, []).extend([obj, f] for f in funcs if isinstance(f, str))
                    elif isinstance(value, list):
                        grants.setdefault(scope, []).extend([obj, perm] for obj in value if isinstance(obj, str))
    script = ["set -e"]
    for scope, objects in grants.items():
        script.append("ubus call session grant " + shlex.quote(json.dumps({"ubus_rpc_session": sid, "scope": scope, "objects": objects})) + " >/dev/null")
    script.append("ubus call session set " + shlex.quote(json.dumps({"ubus_rpc_session": sid, "values": {"username": "root", "token": secrets.token_hex(16)}})) + " >/dev/null")
    run(client, "sh -s", "\n".join(script).encode())
    return sid


class Page:
    def __init__(self, client, host, candidate, out):
        self.client, self.host, self.candidate, self.out = client, host, candidate, out
        self.failures: list[str] = []
        self.status_calls: list[float] = []
        self.blocked: list[list] = []
        self.forwarded_writes: list[list] = []
        self.fixture = None          # 设了就用假状态
        self.fail_status = False     # True 时状态读取返回错误
        self.fix_scan = False
        self.work = None

    # ---------- 断言 ----------
    def check(self, name, cond, detail=""):
        print(("PASS " if cond else "FAIL ") + name + ("" if cond else f": {detail}"), flush=True)
        if not cond:
            self.failures.append(name)

    # ---------- 设备侧只读执行 ----------
    def helper(self, args):
        if self.candidate:
            env = f"R3HS_STATUS_UC={self.work}/status.uc"
            cmd = f"{env} sh {self.work}/web " + " ".join(shlex.quote(a) for a in args)
        else:
            cmd = HELPER + " " + " ".join(shlex.quote(a) for a in args)
        stdin, stdout, stderr = self.client.exec_command(cmd, timeout=30)
        stdin.channel.shutdown_write()
        out = stdout.read().decode()
        err = stderr.read().decode()
        return {"code": stdout.channel.recv_exit_status(), "stdout": out, "stderr": err}

    def real_status(self):
        return json.loads(self.helper(["status"])["stdout"])

    # ---------- 拦截 ubus ----------
    def fake_exec(self, argv):
        cmd = argv[0] if argv else ""
        if cmd == "status":
            self.status_calls.append(time.time())
            if self.fail_status:
                return {"code": 1, "stdout": "", "stderr": "模拟：读不到状态"}
            st = self.fixture if self.fixture is not None else self.real_status()
            if callable(st):
                st = st()
            return {"code": 0, "stdout": json.dumps(st, ensure_ascii=False)}
        if cmd == "scan":
            if self.fix_scan:
                return {"code": 0, "stdout": json.dumps(FIX_SCAN, ensure_ascii=False)}
            return self.helper(argv)
        # 写命令：记下来，返回假结果
        self.blocked.append(argv)
        st = copy.deepcopy(self.fixture if isinstance(self.fixture, dict) else self.base)
        if cmd == "save":
            st["job"] = {"id": "t1", "action": "save", "state": "running", "step": "scan", "message": f"正在搜索「{argv[2]}」…", "started": 0, "updated": 0}
        elif cmd == "disable":
            st["job"] = {"id": "t2", "action": "disable", "state": "running", "step": "write", "message": "正在停用 Wi-Fi 上网…", "started": 0, "updated": 0}
        elif cmd == "prefer":
            st["preferred"] = argv[1]
        elif cmd == "cellular":
            st["cellular"]["auto"] = argv[1] == "on"
        return {"code": 0, "stdout": json.dumps(st, ensure_ascii=False)}

    def route_ubus(self, route, request):
        try:
            body = json.loads(request.post_data or "null")
        except json.JSONDecodeError:
            return route.continue_()
        items = body if isinstance(body, list) else [body]
        mine, rest = {}, []
        for item in items:
            p = item.get("params") or []
            obj, method = (p[1], p[2]) if len(p) >= 3 else (None, None)
            args = p[3] if len(p) > 3 else {}
            if obj == "file" and method == "exec" and args.get("command") == HELPER:
                mine[item["id"]] = {"jsonrpc": "2.0", "id": item["id"], "result": [0, self.fake_exec(list(args.get("params") or []))]}
            elif obj == "file" and method in ("write", "remove"):
                self.blocked.append([method, args.get("path", "")])
                if method == "write":
                    self.written = args
                mine[item["id"]] = {"jsonrpc": "2.0", "id": item["id"], "result": [0]}
            else:
                if obj == "file" and method == "exec":
                    self.forwarded_writes.append(args.get("params"))
                rest.append(item)
        replies = []
        if rest:
            resp = route.fetch(post_data=json.dumps(rest if isinstance(body, list) else rest[0]))
            data = resp.json()
            replies = data if isinstance(data, list) else [data]
        by_id = {r["id"]: r for r in replies}
        by_id.update(mine)
        out = [by_id[i["id"]] for i in items]
        route.fulfill(status=200, content_type="application/json", body=json.dumps(out if isinstance(body, list) else out[0], ensure_ascii=False))

    def route_view(self, route, request):
        route.fulfill(status=200, content_type="application/javascript", body=local_bytes(VIEW))


def run_page(t: Page, sid: str) -> None:
    from playwright.sync_api import sync_playwright

    url = f"http://{t.host}/cgi-bin/luci/admin/network/r3mini-hotspot"
    console: list[str] = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)
        ctx = browser.new_context(viewport={"width": 1440, "height": 1000}, locale="zh-CN")
        ctx.add_cookies([{"name": "sysauth_http", "value": sid, "domain": t.host, "path": "/", "httpOnly": True}])
        ctx.route("**/ubus/**", t.route_ubus)
        if t.candidate:
            ctx.route("**/view/network/r3mini-hotspot.js*", t.route_view)
        page = ctx.new_page()
        page.on("console", lambda m: m.type == "error" and "X-Frame-Options" not in m.text and "Failed to load resource" not in m.text and console.append(m.text[:200]))
        page.on("response", lambda r: r.status >= 400 and console.append(f"HTTP {r.status} {r.url}"))
        page.on("pageerror", lambda e: console.append(str(e)[:200]))
        q = lambda sel: page.locator(".r3x " + sel)

        t0 = time.time()
        page.goto(url, wait_until="domcontentloaded")
        page.wait_for_selector(".r3x .r3x-exit", timeout=30000)
        t.check("page_renders", True)
        print(f"FIRST_RENDER_S={time.time() - t0:.2f}")
        page.screenshot(path=str(t.out / "real-1440.png"), full_page=True)
        text = page.inner_text(".r3x")
        t.base = t.real_status()
        kind = t.base["egress"]["kind"]
        names = {"wan": "有线 WAN", "cellular": "5G 蜂窝", "hotspot": "Wi-Fi 上网"}
        t.check("real_current_exit", kind not in names or ("正在通过 " + names[kind]) in text, text[:200])
        t.check("no_english_decor", all(w not in text for w in ("UPLINK", "DEFAULT EGRESS", "route /")), text[:200])
        t.check("save_disabled_when_unchanged", q("#r3x-enabled").is_checked() == t.base["wifi"]["enabled"] and page.locator(".r3x .r3x-actions .cbi-button-apply").is_disabled())

        # 刷新节奏：平时 5 秒
        n0 = len(t.status_calls)
        page.wait_for_timeout(12500)
        idle = len(t.status_calls) - n0
        t.check("poll_every_5s", 2 <= idle <= 3, f"{idle} calls in 12.5 s")
        # 后台标签不读
        page.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:()=>true}); document.dispatchEvent(new Event('visibilitychange'))")
        n0 = len(t.status_calls)
        page.wait_for_timeout(11000)
        t.check("hidden_tab_no_poll", len(t.status_calls) == n0, f"{len(t.status_calls) - n0} calls")
        page.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:()=>false}); document.dispatchEvent(new Event('visibilitychange'))")
        page.wait_for_timeout(800)
        t.check("visible_again_refreshes", len(t.status_calls) > n0)

        # 真实搜索（只读、不停 AP）
        if not q("#r3x-enabled").is_checked():
            q("#r3x-enabled").check()
        page.wait_for_timeout(200)
        t.check("enable_unlocks_fields", not q("#r3x-ssid").is_disabled() and not q("#r3x-radio").is_disabled())
        t.check("warn_mentions_outage", "断开十几秒" in q(".r3x-warn").inner_text())
        q(".r3x-row .cbi-button-action").click()
        page.wait_for_function("() => !document.querySelector('.r3x .r3x-list').hidden", timeout=20000)
        real_rows = q(".r3x-list li").count()
        t.check("real_scan_lists_networks", real_rows > 0, str(real_rows))
        page.screenshot(path=str(t.out / "real-scan.png"), full_page=True)

        # 假数据：搜索结果的规则
        t.fix_scan = True
        q(".r3x-row .cbi-button-action").click()
        page.wait_for_timeout(600)
        rows = q(".r3x-list li")
        t.check("scan_dedupes_and_lists", rows.count() == 5, str(rows.count()))
        t.check("scan_unsupported_greyed", "本机跟不过去" in q(".r3x-list li.no").first.inner_text())
        t.check("xss_rendered_as_text", page.evaluate("window.__xss === undefined") and "<img" in q(".r3x-list").inner_text())
        q(".r3x-list li:has-text('onerror') button").click()
        q("#r3x-password").fill("correct-horse-1")
        page.locator(".r3x .r3x-actions .cbi-button-apply").click()
        page.wait_for_selector(".modal .cbi-button-neutral", timeout=5000)
        t.check("xss_not_in_confirm", page.evaluate("window.__xss === undefined") and "<img" in page.inner_text(".modal"))
        page.locator(".modal .cbi-button-neutral").click()
        t.check("cancel_sends_nothing", not [b for b in t.blocked if b[0] in ("save", "write")], str(t.blocked))
        q("#r3x-password").fill("")
        q(".r3x-list li:has-text('Phone5G') button").click()
        t.check("pick_fills_ssid", q("#r3x-ssid").input_value() == "Phone5G")
        t.check("pick_needs_password", page.locator(".r3x .r3x-actions .cbi-button-apply").is_disabled() and "请输入" in q(".r3x-form > .r3x-msg").inner_text())
        q("#r3x-password").fill("short")
        t.check("short_password_blocked", page.locator(".r3x .r3x-actions .cbi-button-apply").is_disabled())
        q("#r3x-password").fill("correct-horse-1")
        t.check("valid_password_enables_save", not page.locator(".r3x .r3x-actions .cbi-button-apply").is_disabled())
        t.check("warn_names_target_channel", "信道 44" in q(".r3x-warn").inner_text(), q(".r3x-warn").inner_text())
        q(".r3x-list li:has-text('CafeOpen') button").click()
        t.check("open_network_hides_password", q("#r3x-password").is_hidden() and not page.locator(".r3x .r3x-actions .cbi-button-apply").is_disabled())
        q(".r3x-list li:has-text('Phone5G') button").click()
        q("#r3x-password").fill("correct-horse-1")
        page.screenshot(path=str(t.out / "form-1440.png"), full_page=True)

        # 保存：确认框 → 写密码文件 → save 命令；全部被拦
        running = copy.deepcopy(t.base)
        running["job"] = {"id": "t1", "action": "save", "state": "running", "step": "reconf", "message": "正在把本机 5 GHz Wi-Fi 切到信道 44，这个频段会断开十几秒…", "started": 0, "updated": 0}
        t.fixture = running
        page.locator(".r3x .r3x-actions .cbi-button-apply").click()
        page.wait_for_selector(".modal .cbi-button-apply", timeout=5000)
        page.screenshot(path=str(t.out / "confirm.png"))
        page.locator(".modal .cbi-button-apply").click()
        page.wait_for_timeout(1500)
        writes = [b for b in t.blocked if b[0] == "write"]
        saves = [b for b in t.blocked if b[0] == "save"]
        t.check("password_via_temp_file", len(writes) == 1 and writes[0][1].startswith("/tmp/r3mini-hotspot-key-") and getattr(t, "written", {}).get("mode") == 384, str(writes))
        t.check("save_args_no_password", len(saves) == 1 and "correct-horse-1" not in json.dumps(saves) and saves[0][1:3] == ["radio1", "Phone5G"], str(saves))
        t.check("no_write_reached_device", not t.forwarded_writes, str(t.forwarded_writes))
        t.check("job_progress_shown", "进行中" in q(".r3x-job").inner_text())
        t.check("form_locked_during_job", q("#r3x-enabled").is_disabled())
        n0 = len(t.status_calls)
        page.wait_for_timeout(4200)
        fast = len(t.status_calls) - n0
        t.check("poll_every_1s_during_job", 3 <= fast <= 5, f"{fast} calls in 4.2 s")
        t.fail_status = True
        page.wait_for_timeout(2600)
        t.check("job_outage_message", "正在重配 Wi-Fi" in q(".r3x-age").inner_text(), q(".r3x-age").inner_text())
        t.fail_status = False
        done = copy.deepcopy(t.base)
        done["wifi"].update({"enabled": True, "ssid": "Phone5G", "radio": "radio1", "up": True, "ip": "172.20.10.2", "signal": -48, "key_set": True})
        done["job"] = dict(running["job"], state="done", step="connect", message="已连上「Phone5G」，IP 172.20.10.2")
        t.fixture = done
        page.wait_for_timeout(2500)
        t.check("job_done_shown", "完成：已连上「Phone5G」" in q(".r3x-job").inner_text(), q(".r3x-job").inner_text())
        t.check("form_reset_after_done", q("#r3x-ssid").input_value() == "Phone5G" and page.locator(".r3x .r3x-actions .cbi-button-apply").is_disabled())
        t.check("wifi_card_up", "可用" in q(".r3x-exit[data-kind=hotspot]").inner_text() and "信号强" in q(".r3x-exit[data-kind=hotspot]").inner_text())
        page.wait_for_timeout(6000)
        page.screenshot(path=str(t.out / "wifi-up-1440.png"), full_page=True)

        # 切换出口与蜂窝开关（被拦）
        q(".r3x-prefer button:has-text('Wi-Fi 上网')").click()
        page.wait_for_timeout(800)
        t.check("prefer_sends_command", ["prefer", "hotspot"] in t.blocked, str(t.blocked[-2:]))
        t.check("prefer_feedback", "Wi-Fi 上网" in q(".r3x-prefer ~ .r3x-msg").inner_text())
        cell = copy.deepcopy(done)
        cell["cellular"].update({"present": True, "up": False, "auto": True, "dialing": True})
        t.fixture = cell
        page.wait_for_timeout(1500)
        t.check("cellular_reason_shown", "反复拨号" in q(".r3x-exit[data-kind=cellular]").inner_text())
        q(".r3x-exit[data-kind=cellular] button").click()
        page.wait_for_timeout(800)
        t.check("cellular_pause_command", ["cellular", "off"] in t.blocked)

        # 读状态失败
        t.fail_status = True
        t.fixture = done
        page.wait_for_timeout(11000)
        t.check("stale_message", "读不到状态" in q(".r3x-age").inner_text(), q(".r3x-age").inner_text())
        t.check("stale_disables_prefer", q(".r3x-prefer button").first.is_disabled())
        t.fail_status = False
        page.wait_for_timeout(5500)
        t.check("recovers_after_failure", "更新于" in q(".r3x-age").inner_text())

        # 布局
        for w in (1440, 1024, 768, 600, 390, 320):
            page.set_viewport_size({"width": w, "height": 900})
            page.wait_for_timeout(400)
            m = page.evaluate("""() => {
                const d = document.documentElement, root = document.querySelector('.r3x');
                const els = [...root.querySelectorAll('*')].filter(e => e.offsetParent !== null);
                const small = els.filter(e => [...e.childNodes].some(n => n.nodeType === 3 && n.textContent.trim()) && parseFloat(getComputedStyle(e).fontSize) < 12).map(e => e.className || e.tagName);
                const over = els.filter(e => e.getBoundingClientRect().right > window.innerWidth + 1).map(e => e.className || e.tagName);
                return { page: d.scrollWidth > d.clientWidth, small, over: over.slice(0, 5) };
            }""")
            t.check(f"layout_{w}_no_overflow", not m["page"] and not m["over"], json.dumps(m, ensure_ascii=False))
            t.check(f"layout_{w}_font_12", not m["small"], json.dumps(m["small"][:5], ensure_ascii=False))
            page.screenshot(path=str(t.out / f"w{w}.png"), full_page=True)
        page.emulate_media(color_scheme="dark")
        page.set_viewport_size({"width": 1280, "height": 900})
        page.wait_for_timeout(500)
        page.screenshot(path=str(t.out / "dark-1280.png"), full_page=True)
        t.check("console_clean", not console, json.dumps(console, ensure_ascii=False))
        browser.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("host", nargs="?", default="192.168.0.242")
    ap.add_argument("--key", required=True)
    ap.add_argument("--candidate", action="store_true")
    ap.add_argument("--out", default=str(ROOT.parent / "tmp" / "hotspot-ui" / ("page-" + time.strftime("%Y%m%d-%H%M%S"))))
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    client = connect(args.host, args.key)
    t = Page(client, args.host, args.candidate, out)
    sid = None
    try:
        if args.candidate:
            t.work = f"/tmp/r3hs-page-{secrets.token_hex(4)}"
            run(client, f"mkdir -p {t.work}")
            run(client, f"cat > {t.work}/web", local_bytes("usr/sbin/r3mini-hotspot-web"))
            run(client, f"cat > {t.work}/status.uc", local_bytes("usr/share/r3mini-hotspot/status.uc"))
        sid = mint(client)
        run_page(t, sid)
    finally:
        if sid:
            run(client, "ubus call session destroy " + shlex.quote(json.dumps({"ubus_rpc_session": sid})) + " >/dev/null 2>&1; true")
        if t.work:
            run(client, f"rm -rf {t.work}")
        client.close()
    print(f"SCREENSHOTS={out}")
    print("PAGE_OK" if not t.failures else f"PAGE_FAIL {len(t.failures)}")
    return 0 if not t.failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
