#!/usr/bin/env python3
"""在路由器的真实 LuCI 里看 SOCKS5 页面（真实主题、真实页面框架、真实数据），截图并走一遍主要操作。

    python socks5-gateway/ui_check.py [--view 本地视图.js] [--sandbox] [--out tmp/socks5-exit/shots]

- 经密钥 SSH 临时签一个 LuCI 会话（照 rpcd 给 root 登录的授权来，不输入密码），用完销毁；
- --view：把页面视图换成本地文件（部署前看改版）；不给就看设备上已部署的视图；
- --sandbox：页面对 /usr/sbin/r3mini-socks5 的调用改由路由器上的沙箱后端回答（先在路由器上跑
  `sh ui_sandbox.sh up ...`），沙箱用的是真实订阅文件，不碰正式 SOCKS5；不给就调正式后端（只做只读操作）。
需要 paramiko 和 playwright（chromium）。
"""
from __future__ import annotations

import argparse
import json
import secrets
import shlex
import sys
import time
from pathlib import Path

import paramiko
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
HOST = "192.168.0.242"
KEY = ROOT / "docs" / "私密" / "r3mini-242" / "id_ed25519_242"
CLI = "/usr/sbin/r3mini-socks5"
SANDBOX = "/tmp/r3s5-ui/root"
READ_ONLY = {"status", "targets", "check-port", "probe", "verify", "delay", "delay-all"}


def ssh() -> paramiko.SSHClient:
    client = paramiko.SSHClient()
    client.load_host_keys(str(Path.home() / ".ssh" / "known_hosts"))
    client.set_missing_host_key_policy(paramiko.RejectPolicy())
    client.connect(HOST, username="root", key_filename=str(KEY), look_for_keys=False, allow_agent=False,
                   timeout=8, banner_timeout=8, auth_timeout=8)
    return client


def run(client, command: str, data: bytes | None = None, timeout: int = 120) -> tuple[int, str]:
    stdin, stdout, _stderr = client.exec_command(command, timeout=timeout)
    if data is not None:
        stdin.channel.sendall(data)
    stdin.channel.shutdown_write()
    out = stdout.read().decode("utf-8", "replace")
    return stdout.channel.recv_exit_status(), out


def mint(client) -> str:
    """签一个和 root 登录同等授权的 LuCI 会话（按 acl.d 逐组授权）。"""
    sid = json.loads(run(client, "ubus call session create " + shlex.quote(json.dumps({"timeout": 1800})))[1])["ubus_rpc_session"]
    raw = run(client, "for f in /usr/share/rpcd/acl.d/*.json; do cat \"$f\"; printf '\\n@@ACL@@\\n'; done")[1]
    grants: dict[str, list[list[str]]] = {}
    for block in raw.split("@@ACL@@"):
        try:
            data = json.loads(block.strip() or "null")
        except json.JSONDecodeError:
            continue
        for group, spec in (data or {}).items():
            if not isinstance(spec, dict):
                continue
            for perm in ("read", "write"):
                scopes = spec.get(perm)
                if not isinstance(scopes, dict):
                    continue
                grants.setdefault("access-group", []).append([group, perm])
                for scope, value in scopes.items():
                    if isinstance(value, dict):
                        for obj, funcs in value.items():
                            if isinstance(funcs, list):
                                grants.setdefault(scope, []).extend([obj, f] for f in funcs if isinstance(f, str))
                    elif isinstance(value, list):
                        grants.setdefault(scope, []).extend([obj, perm] for obj in value if isinstance(obj, str))
    lines = ["set -e"]
    for scope, objects in grants.items():
        payload = {"ubus_rpc_session": sid, "scope": scope, "objects": objects}
        lines.append("ubus call session grant " + shlex.quote(json.dumps(payload, ensure_ascii=False)) + " >/dev/null")
    values = {"ubus_rpc_session": sid, "values": {"username": "root", "token": secrets.token_hex(16)}}
    lines.append("ubus call session set " + shlex.quote(json.dumps(values)) + " >/dev/null")
    lines.append("echo MINT_OK")
    if "MINT_OK" not in run(client, "sh -s", data="\n".join(lines).encode())[1]:
        raise SystemExit("SESSION_MINT_FAILED")
    return sid


def destroy(client, sid: str) -> None:
    run(client, "ubus call session destroy " + shlex.quote(json.dumps({"ubus_rpc_session": sid})) + " >/dev/null 2>&1; true")


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--view", type=Path)
    ap.add_argument("--sandbox", action="store_true")
    ap.add_argument("--out", type=Path, default=ROOT / "tmp" / "socks5-exit" / "shots")
    ap.add_argument("--steps", default="load,picker,sub,mobile", help="load,picker,ping,sub,probe,mobile,dark")
    args = ap.parse_args()
    out = args.out / time.strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True, exist_ok=True)
    steps = set(args.steps.split(","))
    client = ssh()
    sid = mint(client)
    calls: list[dict] = []
    errors: list[str] = []

    def exec_cli(params: list[str]) -> dict:
        if not args.sandbox and (params[:1] and params[0] not in READ_ONLY):
            return {"code": 1, "stdout": json.dumps({"ok": False, "error": "ARGUMENT_INVALID", "message": "ui_check 只读模式拦下了写操作"})}
        if args.sandbox:
            cmd = (f"R3MINI_SOCKS5_ROOT={SANDBOX} R3MINI_SOCKS5_PORT_SHIFT=10020 ruby {SANDBOX}/usr/libexec/r3mini-socks5.rb "
                   + " ".join(shlex.quote(p) for p in params))
        else:
            cmd = CLI + " " + " ".join(shlex.quote(p) for p in params)
        t0 = time.time()
        code, stdout = run(client, cmd)
        calls.append({"argv": params, "ms": round((time.time() - t0) * 1000), "bytes": len(stdout)})
        return {"code": code, "stdout": stdout}

    def on_ubus(route):
        req = route.request
        try:
            body = json.loads(req.post_data or "")
        except json.JSONDecodeError:
            return route.continue_()
        items = body if isinstance(body, list) else [body]

        def ours(item):
            p = item.get("params") or []
            return len(p) >= 4 and p[1] == "file" and p[2] == "exec" and (p[3] or {}).get("command") == CLI

        if not any(ours(i) for i in items):
            return route.continue_()
        answers = {}
        rest = [i for i in items if not ours(i)]
        if rest:
            resp = route.fetch(post_data=json.dumps(rest if isinstance(body, list) else rest[0]))
            got = resp.json()
            for r in (got if isinstance(got, list) else [got]):
                answers[r.get("id")] = r
        for i in items:
            if ours(i):
                answers[i.get("id")] = {"jsonrpc": "2.0", "id": i.get("id"),
                                        "result": [0, exec_cli(list((i["params"][3] or {}).get("params") or []))]}
        merged = [answers[i.get("id")] for i in items]
        route.fulfill(status=200, content_type="application/json",
                      body=json.dumps(merged if isinstance(body, list) else merged[0], ensure_ascii=False))

    def on_view(route):
        if args.view:
            return route.fulfill(status=200, content_type="application/javascript", body=args.view.read_bytes())
        return route.continue_()

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)

            def page_for(width, height, dark=False):
                ctx = browser.new_context(viewport={"width": width, "height": height}, locale="zh-CN",
                                          color_scheme="dark" if dark else "light", device_scale_factor=1)
                ctx.add_cookies([{"name": "sysauth_http", "value": sid, "domain": HOST, "path": "/", "httpOnly": True}])
                page = ctx.new_page()
                page.on("console", lambda m: errors.append(f"[{m.type}] {m.text}") if m.type in ("error", "warning") else None)
                page.on("pageerror", lambda e: errors.append(f"[pageerror] {e}"))
                page.route("**/ubus/**", on_ubus)
                page.route("**/ubus", on_ubus)
                page.route("**/view/services/r3mini-socks5*.js*", on_view)
                t0 = time.time()
                page.goto(f"http://{HOST}/cgi-bin/luci/admin/services/r3mini-socks5", wait_until="domcontentloaded")
                page.wait_for_selector(".s5", timeout=60000)
                print(f"rendered {width}px in {time.time() - t0:.1f}s", flush=True)
                page.wait_for_timeout(1500)
                return page

            if "load" in steps or "picker" in steps or "sub" in steps:
                page = page_for(1440, 1000)
                page.screenshot(path=str(out / "1-load.png"), full_page=True)
                if "picker" in steps or "sub" in steps:
                    page.get_by_role("button", name="更换节点").click()
                    page.wait_for_selector(".s5-row", timeout=30000)
                    page.wait_for_timeout(800)
                    page.screenshot(path=str(out / "2-picker.png"), full_page=True)
                if "ping" in steps:
                    pings = page.locator(".s5-ping:not([disabled])")
                    print(f"  可点的单独测速按钮 {pings.count()} 个", flush=True)
                    for i in range(min(3, pings.count())):
                        pings.nth(i).click()
                    page.wait_for_timeout(500)
                    page.wait_for_function("document.querySelector('.s5-ping[data-running]') === null", timeout=30000)
                    page.screenshot(path=str(out / "2b-ping.png"), full_page=False)
                if "sub" in steps:
                    tabs = page.locator(".s5-sub-tab")
                    if tabs.count() > 1:
                        tabs.nth(tabs.count() - 1).click()
                        page.wait_for_timeout(2500)
                        page.screenshot(path=str(out / "3-other-sub.png"), full_page=True)
                if "probe" in steps:
                    page.get_by_role("button", name="检测").click()
                    page.wait_for_selector(".s5-regions", timeout=40000)
                    page.screenshot(path=str(out / "4-probe.png"), full_page=True)
            if "mobile" in steps:
                page = page_for(390, 844)
                page.screenshot(path=str(out / "5-mobile.png"), full_page=True)
                page.get_by_role("button", name="更换节点").click()
                page.wait_for_selector(".s5-row", timeout=30000)
                page.wait_for_timeout(800)
                page.screenshot(path=str(out / "6-mobile-picker.png"), full_page=True)
            if "dark" in steps:
                page = page_for(1440, 1000, dark=True)
                page.screenshot(path=str(out / "7-dark.png"), full_page=True)
                page.get_by_role("button", name="更换节点").click()
                page.wait_for_selector(".s5-row", timeout=30000)
                page.wait_for_timeout(800)
                page.screenshot(path=str(out / "8-dark-picker.png"), full_page=False)
            browser.close()
    finally:
        destroy(client, sid)
        client.close()
    (out / "calls.json").write_text(json.dumps({"calls": calls, "errors": errors}, ensure_ascii=False, indent=1), encoding="utf-8")
    for c in calls:
        print(f"  {c['ms']:>5} ms {c['bytes']:>7} B  {' '.join(c['argv'])[:80]}")
    for e in errors[:15]:
        print("  " + e[:200])
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
