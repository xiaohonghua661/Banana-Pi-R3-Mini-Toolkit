#!/usr/bin/env python3
"""Page acceptance on the real router: the live LuCI page (argon theme and header band, LuCI's own
ui.js and modal, the router's real subscriptions and node names), never a synthetic stand-in.

  python chatgpt-routing/test_real_page.py --key KEY_PATH [--candidate] [--host 192.168.0.242]

--candidate serves this checkout's page script in place of the installed one (before installing);
without it the installed page is checked (after installing). Every r3mini-chatgpt command that
writes (save, set-enabled, remove, disable, steam-direct, benchmark, apply) is aborted in the
browser before it reaches the router; the walk only reads: it opens dialogs, switches through every
subscription, picks a region from the dropdown, and cancels both confirmations.

A LuCI session is granted over the key-only SSH link the way rpcd's root login would grant it, so
no password is typed; it is destroyed afterwards. Screenshots and report.json go to
tmp/site-routing/realpage-<time>/ (git-ignored). Exit code 0 only when nothing overflows, no
script error occurs, the status line sits below argon's header band, and no write was attempted.
"""
from __future__ import annotations

import argparse
import json
import secrets
import shlex
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import manage  # noqa: E402  pinned host key, key-only login

VIEW = HERE / "router/www/luci-static/resources/view/services/r3mini-chatgpt.js"
WRITES = {"save", "set-enabled", "remove", "disable", "steam-direct", "benchmark", "apply", "hook"}
# LuCI's own warning about a meta tag; not this page.
IGNORED = ("Failed to load resource", "X-Frame-Options")
RUNS = [(1280, "light", 1), (1280, "dark", 1), (768, "light", 1), (375, "light", 1), (320, "light", 1),
        (1280, "light", 2), (375, "light", 2)]
METRICS = """() => {
  const vw = innerWidth, box = e => { if (!e) return null; const r = e.getBoundingClientRect();
    return {x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height), b: Math.round(r.bottom)}; };
  const over = [...document.querySelectorAll('.r3cg *, .r3cg-modal *')].filter(e => {
    const r = e.getBoundingClientRect(); return r.width > 0 && (r.right > vw + 1 || r.left < -1); }).slice(0, 6)
    .map(e => e.tagName.toLowerCase() + '.' + String(e.className).slice(0, 30));
  const overlay = document.getElementById('modal_overlay'), source = document.getElementById('r3cg-source');
  return { vw, pageOverflow: document.scrollingElement.scrollWidth > vw + 1,
    modalOverflow: overlay ? overlay.scrollWidth > overlay.clientWidth + 1 : false, over,
    header: box(document.querySelector('.main-right > header') || document.querySelector('header')),
    status: box(document.querySelector('.r3cg-statusbar')), modal: box(document.querySelector('#modal_overlay > .modal')),
    chips: document.querySelectorAll('#modal_overlay .r3cg-chip').length,
    moreRegions: Math.max(0, (document.querySelector('#modal_overlay select.r3cg-more') || {options: [0]}).options.length - 1),
    rows: document.querySelectorAll('#modal_overlay button.r3cg-row').length,
    source: source ? source.options[source.selectedIndex]?.textContent : null,
    active: (document.querySelector('.r3cg-active') || {}).textContent || '' };
}"""


def grant_session(client) -> str:
    """A LuCI session with the grants rpcd gives root, set up over SSH; no password involved."""
    sid = json.loads(manage.text(client, "ubus call session create " + shlex.quote(json.dumps({"timeout": 1800}))))["ubus_rpc_session"]
    raw = manage.text(client, "for f in /usr/share/rpcd/acl.d/*.json; do cat \"$f\"; printf '\\n@@ACL@@\\n'; done")
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
                # LuCI checks access-group by exact name; a '*' grant does not pass it.
                grants.setdefault("access-group", []).append([group, perm])
                for scope, value in scopes.items():
                    if isinstance(value, dict):
                        for obj, funcs in value.items():
                            grants.setdefault(scope, []).extend([obj, f] for f in funcs if isinstance(f, str))
                    elif isinstance(value, list):
                        grants.setdefault(scope, []).extend([obj, perm] for obj in value if isinstance(obj, str))
    script = ["set -e"] + ["ubus call session grant " + shlex.quote(json.dumps({"ubus_rpc_session": sid, "scope": scope, "objects": objects},
                                                                                 ensure_ascii=False)) + " >/dev/null"
                           for scope, objects in grants.items()]
    script.append("ubus call session set " + shlex.quote(json.dumps({"ubus_rpc_session": sid, "values": {
        "username": "root", "token": secrets.token_hex(16)}})) + " >/dev/null; echo GRANT_OK")
    if "GRANT_OK" not in manage.text(client, "sh -s", data="\n".join(script).encode()):
        raise RuntimeError("SESSION_GRANT_FAILED")
    return sid


def exec_calls(post: str | None) -> list[list[str]]:
    try:
        data = json.loads(post or "")
    except json.JSONDecodeError:
        return []
    return [[item["params"][3].get("command", "")] + list(item["params"][3].get("params") or [])
            for item in (data if isinstance(data, list) else [data])
            if len(item.get("params") or []) >= 4 and item["params"][1:3] == ["file", "exec"]]


def walk(page, shot, close):
    page.locator(".r3cg-rule").first.get_by_role("button", name="换节点").click()
    page.wait_for_selector("#modal_overlay button.r3cg-row", timeout=60000)
    shot("change-node")
    for source in page.evaluate("() => [...document.getElementById('r3cg-source').options].map(o => o.value).filter(Boolean)"):
        page.select_option("#r3cg-source", source)
        page.wait_for_function("(s) => document.getElementById('r3cg-source').value === s && "
                               "document.querySelectorAll('#modal_overlay button.r3cg-row').length > 0", arg=source, timeout=60000)
        shot("source-" + source.removesuffix(".yaml"))
        if page.query_selector("#modal_overlay select.r3cg-more"):
            values = page.evaluate("() => [...document.querySelector('#modal_overlay select.r3cg-more').options].map(o => o.value).filter(Boolean)")
            page.select_option("#modal_overlay select.r3cg-more", values[len(values) // 2])
            shot("region-dropdown-" + source.removesuffix(".yaml"))
    close()
    page.get_by_role("button", name="添加网站").click()
    shot("add-empty")
    page.fill("#r3cg-domains", "www.example.org")
    page.wait_for_selector("#modal_overlay button.r3cg-row", timeout=60000)
    shot("add-typed")
    close()
    page.locator(".r3cg-rule").first.get_by_role("button", name="删除").click()
    shot("confirm-delete")
    page.locator("#modal_overlay .right").get_by_role("button", name="取消").click()
    page.get_by_role("button", name="恢复原分流").click()
    shot("confirm-restore")
    page.locator("#modal_overlay .right").get_by_role("button", name="取消").click()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="192.168.0.242")
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--candidate", action="store_true", help="serve this checkout's page script instead of the installed one")
    args = parser.parse_args(argv)
    from playwright.sync_api import sync_playwright
    out = HERE.parent / "tmp" / "site-routing" / ("realpage-" + time.strftime("%Y%m%d-%H%M%S"))
    out.mkdir(parents=True, exist_ok=True)
    url = f"http://{args.host}/cgi-bin/luci/admin/services/r3mini-chatgpt"
    client = manage.connect(args.host, args.key)
    sid = grant_session(client)
    report = {"host": args.host, "candidate": args.candidate, "at": time.strftime("%Y-%m-%d %H:%M:%S"), "runs": [], "blocked_writes": []}
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            for width, scheme, zoom in RUNS:
                tag = f"{width}-{scheme}" + (f"-text{zoom * 100}" if zoom > 1 else "")
                ctx = browser.new_context(viewport={"width": width, "height": 900}, color_scheme=scheme, locale="zh-CN")
                ctx.add_cookies([{"name": "sysauth_http", "value": sid, "domain": args.host, "path": "/", "httpOnly": True}])
                page = ctx.new_page()
                errors: list[str] = []
                page.on("pageerror", lambda e: errors.append(str(e)))
                page.on("console", lambda m: errors.append(m.text) if m.type == "error" and not any(i in m.text for i in IGNORED) else None)
                if args.candidate:
                    page.route("**/luci-static/resources/view/services/r3mini-chatgpt.js*",
                               lambda r: r.fulfill(status=200, body=VIEW.read_bytes(), content_type="application/javascript"))

                def guard(route):
                    calls = exec_calls(route.request.post_data)
                    if any(c[0].endswith("r3mini-chatgpt") and len(c) > 1 and c[1] in WRITES for c in calls):
                        report["blocked_writes"].extend(calls)
                        return route.abort()
                    return route.continue_()
                page.route("**/ubus**", guard)
                steps = []

                def shot(name):
                    page.wait_for_timeout(300)
                    m = page.evaluate(METRICS)
                    page.screenshot(path=str(out / f"{tag}-{len(steps):02d}-{name}.png"), full_page=not m["modal"])
                    steps.append({"step": name, **m})

                def close():
                    page.keyboard.press("Escape")
                    page.wait_for_function("() => !document.body.classList.contains('modal-overlay-active')", timeout=5000)

                page.goto(url, wait_until="domcontentloaded")
                page.wait_for_selector(".r3cg-rule h3, .r3cg-list .r3cg-empty", timeout=60000)
                if zoom > 1:
                    page.evaluate(f"document.documentElement.style.fontSize = '{16 * zoom}px'")
                shot("page")
                if page.query_selector(".r3cg-rule"):
                    walk(page, shot, close)
                report["runs"].append({"tag": tag, "errors": errors[:5], "steps": steps})
                ctx.close()
            browser.close()
    finally:
        manage.run(client, "ubus call session destroy " + shlex.quote(json.dumps({"ubus_rpc_session": sid})), check=False)
        client.close()
    problems = []
    for run in report["runs"]:
        problems += [[run["tag"], "script error", e] for e in run["errors"]]
        for s in run["steps"]:
            if s["pageOverflow"] or s["modalOverflow"] or s["over"]:
                problems.append([run["tag"], s["step"], "overflow", s["over"]])
        first = run["steps"][0]
        if first["header"] and first["status"] and first["status"]["y"] < first["header"]["b"]:
            problems.append([run["tag"], "page", "status line on argon's header band"])
    if report["blocked_writes"]:
        problems.append(["all", "a write command was attempted", report["blocked_writes"]])
    report["problems"] = problems
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    steps = report["runs"][0]["steps"]
    print("REAL_PAGE out=" + str(out))
    print("active: " + (steps[0]["active"] or "(none)"))
    for s in steps:
        if s["step"].startswith(("source-", "add-")):
            print(f"{s['step']}: chips={s['chips']} dropdown_regions={s['moreRegions']} rows={s['rows']} source={s['source']}")
    for problem in problems:
        print("PROBLEM " + json.dumps(problem, ensure_ascii=False))
    print("REAL_PAGE_OK" if not problems else "REAL_PAGE_FAILED")
    return 0 if not problems else 1


if __name__ == "__main__":
    if sys.stdout:
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
