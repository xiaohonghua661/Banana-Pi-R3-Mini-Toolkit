"""LuCI 页面 r3mini-traffic.js 的浏览器测试（Playwright + Chromium，不需要登录路由器）。

  python traffic-logger/test_luci_view.py                          离线：桩数据，校验交互、请求参数、XSS、移动端、暗色
  python traffic-logger/test_luci_view.py --live HOST [--cli PATH] 在线：页面经 SSH 调设备上真实的 web 接口

页面里的 fs.exec 被替换成桩；离线桩不实现查询口径（口径由设备上的 selftest 与 test_replay.py 校验），
只按请求的分组维度回一份固定结果，用来检查页面发出的参数与渲染。
截图写到 tmp/traffic-luci-ui/；在线模式的截图含真实设备与目标，不入库。
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shlex
import sys

from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
VIEW = HERE / "router" / "www" / "luci-static" / "resources" / "view" / "status" / "r3mini-traffic.js"
OUT = HERE.parent / "tmp" / "traffic-luci-ui"
ORIGIN = "http://r3t.test/"
HTML = ('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>body{margin:0;font-family:system-ui,"Microsoft YaHei",sans-serif}#view{padding:16px}</style></head>'
        '<body><div id="view"></div></body></html>')

# 写成函数：Playwright 会把字符串表达式的值当函数调用，末句若是赋值箭头函数就会被误调
FAKE = r"""() => {
window.__fakeOpts = { delay: 0, fail: null, status: {
  version: '1.4.0', version_cli: '1.4.0', run_id: 'abcd1234', pid: 1234, state: 'STATUS_OK', problems: [], poll_ms: 2000,
  connections: 1234, today: '2026-10-24', hour: '2026-10-24T15',
  data: { first: '2026-10-20', last: '2026-10-24', count: 5, bytes: 987654, retention_days: 60, max_bytes: 209715200, mount_ok: true } } };
const DATA = {
  device: ['192.0.2.10 02:00:00:00:00:10 (书房电脑)', '192.0.2.11 02:00:00:00:00:11', '192.0.2.1 (路由器本机)', '?'],
  exit: ['🇯🇵 节点A < 🤖 AI组', 'DIRECT', 'socks:ph-socks', 'forward:DIRECT@eth1', '订阅节点直连(DIRECT)'],
  target: ['api.example.com', 'cdn.example.net:8443', '<img src=x onerror="window.__xss=1">', 'node.example [订阅节点]',
           '198.51.100.7:443', 'very-long-subdomain-name-for-wrapping-checks.service.region.example.org:44300'],
  date: ['2026-10-20', '2026-10-21', '2026-10-22', '2026-10-23', '2026-10-24'],
  hour: ['00:00', '01:00', '13:00', '23:00'],
  kind: ['clash', 'socks', 'forward'],
};
function facet(list) { return list.map((k, i) => ({ k, up: (list.length - i) * 1048576, down: 1000 * i, conns: i + 1 })); }
window.__fake = (cmd, args) => new Promise(resolve => setTimeout(() => {
  const o = window.__fakeOpts;
  if (o.fail) return resolve(o.fail);
  if (args[1] === 'status') return resolve({ code: 0, stdout: JSON.stringify(o.status), stderr: '' });
  const a = {};
  for (let i = 2; i < args.length; i++) { if (args[i] === '--proxy') a.proxy = true; else a[args[i].slice(2)] = args[++i]; }
  const by = a.by || 'device', sort = a.sort || 'up', top = +(a.top || 100);
  const parts = (a.date || '2026-10-24').split('..'), range = [parts[0], parts[1] || parts[0]];
  let rows = DATA[by].map((k, i) => ({ k: [k], up: (6 - i) * 1073741824 + i, down: (i + 1) * 1048576, conns: 10 * (i + 1) }));
  const m = r => sort === 'down' ? r.down : sort === 'total' ? r.up + r.down : sort === 'conns' ? r.conns : r.up;
  rows.sort(sort === 'key' ? (x, y) => (x.k[0] < y.k[0] ? -1 : 1) : (x, y) => m(y) - m(x));
  const total = rows.reduce((t, r) => ({ up: t.up + r.up, down: t.down + r.down, conns: t.conns + r.conns, rows: t.rows + 3 }),
    { up: 0, down: 0, conns: 0, rows: 0 });
  const days = Math.round((Date.parse(range[1]) - Date.parse(range[0])) / 86400000) + 1;
  resolve({ code: 0, stderr: '', stdout: JSON.stringify({
    version: '1.4.0', today: o.status.today || '2026-10-24', from: range[0], to: range[1], days, hours: [+(a.from || 0), +(a.to || 24)],
    by: [by], sort, proxy: !!a.proxy, filters: { device: a.device || null, exit: a.exit || null, target: a.target || null, kind: a.kind || null },
    dates: DATA.date.filter(d => d >= range[0] && d <= range[1]), available: { first: '2026-10-20', last: '2026-10-24', count: 5 },
    mount_ok: true, groups: by === 'target' ? rows.length + 7 : rows.length, rows: rows.slice(0, top), total,
    unattributed: { up: 123456, down: 654321 }, facets: { device: facet(DATA.device), exit: facet(DATA.exit) }, elapsed_ms: 321 }) });
}, window.__fakeOpts.delay));
}
"""

BOOT = r"""
async ({ source, live }) => {
  window.__calls = []; window.__inflight = 0; window.__maxInflight = 0;
  const backend = live ? (cmd, args) => window.r3exec(cmd, args) : (cmd, args) => window.__fake(cmd, args);
  const fsStub = { exec(cmd, args) {
    window.__calls.push([cmd].concat(args));
    window.__inflight++; window.__maxInflight = Math.max(window.__maxInflight, window.__inflight);
    return Promise.resolve(backend(cmd, args)).then(r => {
      window.__inflight--;
      if (r && r.reject) throw new Error(r.reject);
      return r;
    }, e => { window.__inflight--; throw e; });
  } };
  const pollStub = { add(fn) { window.__poll = fn; } };
  const mod = new Function('view', 'fs', 'poll', source)({ extend: v => v }, fsStub, pollStub);
  const data = await mod.load();
  document.querySelector('#view').append(mod.render(data));
}
"""

IDLE = "() => window.__inflight === 0 && !document.querySelector('.r3t').classList.contains('is-busy')"


class Run:
    def __init__(self, page, live: bool):
        self.page = page
        self.live = live
        self.errors: list[str] = []
        page.on("console", lambda m: self.errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: self.errors.append(str(e)))
        page.route(ORIGIN + "**", lambda route: route.fulfill(status=200, content_type="text/html; charset=utf-8", body=HTML))

    def boot(self, url: str = ORIGIN) -> None:
        self.page.goto(url)
        if not self.live:
            self.page.evaluate(FAKE)
        self.page.evaluate(BOOT, {"source": VIEW.read_text(encoding="utf-8"), "live": self.live})
        self.idle()

    def idle(self) -> None:
        self.page.wait_for_function(IDLE, timeout=30000)

    def calls(self) -> list[list[str]]:
        return self.page.evaluate("window.__calls")

    def last(self) -> list[str]:
        return [c for c in self.calls() if c[2] == "report"][-1]

    def click(self, selector: str) -> None:
        self.page.click(selector)
        self.page.wait_for_timeout(30)
        self.idle()

    def dim(self, label: str) -> None:
        self.click(f".r3t-seg .r3t-btn:text-is('{label}')")


failures = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global failures
    failures += not ok
    print(f"{name}_{'OK' if ok else 'FAIL'} {detail}".rstrip())


def arg(call: list[str], flag: str) -> str | None:
    return call[call.index(flag) + 1] if flag in call else None


def overflow(page) -> dict:
    return page.evaluate("""() => {
      const w = document.documentElement.clientWidth;
      const bad = Array.from(document.querySelectorAll('.r3t *')).filter(n => {
        const r = n.getBoundingClientRect(); return r.width && (r.left < -0.5 || r.right > w + 0.5); });
      return { scroll: document.documentElement.scrollWidth, client: w, offenders: bad.slice(0, 5).map(n => n.className || n.tagName) };
    }""")


def offline(browser) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    page = browser.new_page(viewport={"width": 1440, "height": 1000})
    r = Run(page, live=False)
    r.boot()
    first = r.calls()
    check("LOAD_CALLS", first == [["/usr/sbin/r3mini-traffic", "web", "status"],
                                  ["/usr/sbin/r3mini-traffic", "web", "report", "--by", "device", "--proxy"]], repr(first))
    rows = page.eval_on_selector_all(".r3t-row:not(.head) .r3t-drill", "ns => ns.map(n => n.textContent)")
    check("RENDER_DEVICE_ROWS", len(rows) == 4 and "书房电脑" in rows[0], repr(rows))
    check("STATUS_PILL", page.text_content(".r3t-pill").strip() == "记录中")
    check("SUMMARY_CARDS", page.locator(".r3t-stat").count() == 5)
    page.screenshot(path=str(OUT / "offline-desktop.png"), full_page=True)

    r.dim("目标")
    xss = page.evaluate("() => ({ flag: window.__xss, imgs: document.querySelectorAll('.r3t img').length, "
                        "text: Array.from(document.querySelectorAll('.r3t-drill')).some(n => n.textContent.includes('<img src=x')) })")
    check("XSS_AS_TEXT", xss["flag"] is None and xss["imgs"] == 0 and xss["text"], repr(xss))
    check("MORE_ROWS_NOTE", "共 13 项" in (page.text_content(".r3t-more") or ""))

    r.dim("设备")
    r.click(".r3t-row:not(.head) .r3t-drill >> nth=0")
    last = r.last()
    check("DRILL_ARGS", arg(last, "--device") == "=192.0.2.10 02:00:00:00:00:10 (书房电脑)" and arg(last, "--by") == "target",
          repr(last))
    chips = page.eval_on_selector_all(".r3t-chip span", "ns => ns.map(n => n.textContent)")
    check("DRILL_CHIP", "设备 = 192.0.2.10 02:00:00:00:00:10 (书房电脑)" in chips, repr(chips))
    r.click(".r3t-chips .r3t-btn:text-is('← 返回上一步')")
    last = r.last()
    check("BACK", arg(last, "--by") == "device" and "--device" not in last, repr(last))

    r.click(".r3t-th:text-is('下载')")
    check("SORT_DOWN", arg(r.last(), "--sort") == "down")
    r.click(".r3t-btn:text-is('近 7 天')")
    check("QUICK_7D", arg(r.last(), "--date") == "2026-10-18..2026-10-24", repr(r.last()))
    page.uncheck(".r3t-check input")
    r.idle()
    check("PROXY_OFF", "--proxy" not in r.last() and "含直连流量" in page.text_content(".r3t-chips"))
    page.select_option("select[aria-label=出口]", "=🇯🇵 节点A < 🤖 AI组")
    r.idle()
    check("EXIT_FACET", arg(r.last(), "--exit") == "=🇯🇵 节点A < 🤖 AI组", repr(r.last()))
    page.select_option("select[aria-label=开始小时]", "8")
    r.idle()
    check("HOURS", arg(r.last(), "--from") == "8" and arg(r.last(), "--to") == "24", repr(r.last()))
    page.fill("input[aria-label=目标]", "example")
    page.press("input[aria-label=目标]", "Enter")
    r.idle()
    check("TARGET_FILTER", arg(r.last(), "--target") == "example", repr(r.last()))

    # 地址栏记着查询：用同一个 # 重新打开，首个查询参数应一致
    want, url = r.last()[1:], page.url
    page2 = browser.new_page(viewport={"width": 1200, "height": 900})
    r2 = Run(page2, live=False)
    r2.boot(url)
    check("HASH_RESTORE", r2.last()[1:] == want, f"url={url[len(ORIGIN):]!r} got={r2.last()[1:]!r}")
    check("HASH_CONTROLS", page2.input_value("input[aria-label=目标]") == "example" and
          page2.input_value("select[aria-label=出口]") == "=🇯🇵 节点A < 🤖 AI组")
    page2.close()
    # 原型链上的键（constructor、toString）与不存在的日期都不能混过校验：整份地址栏状态作废，回到默认查询
    for bad_hash in ("#from=2026-10-20&to=2026-10-24&by=constructor&sort=up&top=100&proxy=1",
                     "#from=2026-10-20&to=2026-10-24&by=device&sort=toString&top=100&proxy=1",
                     "#from=2026-10-20&to=2026-10-24&by=device&sort=up&top=100&proxy=1&kind=constructor",
                     "#from=2026-02-30&to=2026-03-01&by=device&sort=up&top=100&proxy=1"):
        page3 = browser.new_page(viewport={"width": 1200, "height": 900})
        r3 = Run(page3, live=False)
        r3.boot(ORIGIN + bad_hash)
        check("HASH_REJECTED", r3.last()[1:] == ["web", "report", "--by", "device", "--proxy"] and not r3.errors,
              f"hash={bad_hash[1:60]!r} got={r3.last()[1:]!r}")
        page3.close()

    # 单飞：查询未返回时又改了条件，只保留一个在途请求，最后显示最后一次的条件
    page.evaluate("() => { window.__fakeOpts.delay = 200; window.__maxInflight = 0; }")
    page.click(".r3t-btn:text-is('昨天')")
    page.click(".r3t-btn:text-is('今天')")
    r.idle()
    inflight = page.evaluate("window.__maxInflight")
    stat_date = page.eval_on_selector_all(".r3t-stat b", "ns => ns.map(n => n.textContent)")[-1]
    check("SINGLE_FLIGHT", inflight == 1 and arg(r.last(), "--date") == "2026-10-24" and stat_date == "2026-10-24",
          f"max_inflight={inflight} last={arg(r.last(), '--date')} shown={stat_date}")
    page.evaluate("() => { window.__fakeOpts.delay = 0; }")

    page.evaluate("() => { window.__fakeOpts.fail = { code: 2, stdout: '', stderr: '查询超过 14 秒仍未读完（读到 2026-09-26），请缩小日期范围\\n' }; }")
    r.click(".r3t-btn:text-is('近 30 天')")
    check("ERROR_SHOWN", "查询超过 14 秒" in (page.text_content(".r3t-error") or ""))
    page.evaluate("() => { window.__fakeOpts.fail = { reject: 'Permission denied' }; }")
    r.click(".r3t-btn:text-is('今天')")
    check("PERMISSION_HINT", "重新登录" in (page.text_content(".r3t-error") or ""))
    page.evaluate("() => { window.__fakeOpts.fail = null; }")
    r.click(".r3t-btn:text-is('今天')")
    check("RECOVER", page.locator(".r3t-error").count() == 0 and page.locator(".r3t-row:not(.head)").count() > 0)

    def status(st: dict) -> str:
        page.evaluate("st => { window.__fakeOpts.status = Object.assign({}, window.__fakeOpts.status, st); return window.__poll(); }", st)
        return page.text_content(".r3t-status")
    check("STATUS_DEGRADED", "OpenClash 控制接口失败（TIMEOUT）" in status({"state": "STATUS_DEGRADED", "problems": ["API_TIMEOUT"]}))
    check("VERSION_MISMATCH", "重启 r3mini-traffic 服务后生效" in status({"state": "STATUS_OK", "problems": [], "version": "1.3.0"}))
    check("STATUS_NOT_RUNNING", "记录器没有运行" in status({"state": "NOT_RUNNING", "problems": ["NOT_RUNNING"], "version": None}))
    # 页面开过午夜：状态轮询带回新日期后，「今天」跟着路由器走
    status({"state": "STATUS_OK", "version": "1.4.0", "today": "2026-10-25"})
    r.click(".r3t-btn:text-is('今天')")
    check("MIDNIGHT_TODAY", arg(r.last(), "--date") == "2026-10-25" and
          page.get_attribute("input[aria-label=结束日期]", "max") == "2026-10-25", repr(r.last()))

    page.set_viewport_size({"width": 390, "height": 844})
    page.wait_for_timeout(100)
    ov = overflow(page)
    page.screenshot(path=str(OUT / "offline-mobile.png"), full_page=True)
    check("MOBILE_NO_OVERFLOW", ov["scroll"] <= ov["client"] and not ov["offenders"], repr(ov))
    # 所有可点的元素：按钮（含表头排序、行名下钻、过滤条的 ✕）、下拉、日期与搜索框、「只看代理」整个标签
    tap = page.evaluate("""() => {
      const sel = '.r3t button, .r3t select, .r3t input[type=date], .r3t input[type=search], .r3t label.r3t-check';
      const all = Array.from(document.querySelectorAll(sel)).map(n => {
        const r = n.getBoundingClientRect();
        return { name: n.className || n.tagName, h: r.height, w: r.width };
      }).filter(x => x.h > 0);
      const small = all.filter(x => x.h < 40 || (x.name === '' && x.w < 40));
      return { count: all.length, kinds: Array.from(new Set(all.map(x => x.name))).length, small: small.slice(0, 6) };
    }""")
    check("MOBILE_TAP_TARGET", tap["count"] > 20 and not tap["small"], repr(tap))
    check("CONSOLE_ERRORS", not r.errors, repr(r.errors[:3]))
    page.close()

    ctx = browser.new_context(color_scheme="dark", viewport={"width": 1280, "height": 900})
    dark = ctx.new_page()
    rd = Run(dark, live=False)
    rd.boot()
    bg = dark.evaluate("() => getComputedStyle(document.querySelector('.r3t')).backgroundColor")
    dark.screenshot(path=str(OUT / "offline-dark.png"), full_page=True)
    check("DARK_SCHEME", bg == "rgb(20, 24, 29)", bg)
    ctx.close()


def live(browser, host: str, cli: str | None) -> None:
    sys.path.insert(0, str(HERE))
    import manage  # noqa: E402 — 只在在线模式需要 paramiko 与私密文档
    client = manage.connect(host)
    times: list[float] = []
    failed: list[str] = []

    def r3exec(cmd: str, args: list[str]) -> dict:
        import time
        # 页面渲染的是真实网络数据：桥只放行与 ACL 相同的 r3mini-traffic web ...，别的一律拒绝
        if cmd != "/usr/sbin/r3mini-traffic" or not args or args[0] != "web":
            failed.append(f"blocked cmd={cmd!r} args={args!r}")
            return {"code": 126, "stdout": "", "stderr": "blocked by test bridge"}
        t = time.time()
        rc, out, err = manage.run(client, shlex.join([cli or cmd] + list(args)), timeout=60, check=False)
        times.append(time.time() - t)
        if rc:
            failed.append(f"rc={rc} args={args} err={err.decode('utf-8', 'replace').strip()[:200]}")
        return {"code": rc, "stdout": out.decode("utf-8", "replace"), "stderr": err.decode("utf-8", "replace")}

    try:
        OUT.mkdir(parents=True, exist_ok=True)
        page = browser.new_page(viewport={"width": 1440, "height": 1000})
        page.expose_function("r3exec", r3exec)
        r = Run(page, live=True)
        r.boot()
        bad = []

        def ok(step: str) -> None:
            if page.locator(".r3t-error").count():
                bad.append(f"{step}: {page.text_content('.r3t-error')}")
        ok("load")
        check("LIVE_STATUS", page.text_content(".r3t-pill").strip() in ("记录中", "记录异常"), page.text_content(".r3t-status"))
        page.screenshot(path=str(OUT / "live-device.png"), full_page=True)
        for label in ("出口", "目标", "日期", "小时", "类型", "设备"):
            r.dim(label)
            ok(label)
        if page.locator(".r3t-row:not(.head) .r3t-drill:not([disabled])").count():
            r.click(".r3t-row:not(.head) .r3t-drill:not([disabled]) >> nth=0")
            ok("drill")
            page.screenshot(path=str(OUT / "live-drill.png"), full_page=True)
        for label in ("昨天", "近 7 天", "今天"):
            r.click(f".r3t-btn:text-is('{label}')")
            ok(label)
        r.dim("出口")
        page.screenshot(path=str(OUT / "live-exit.png"), full_page=True)
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        ov = overflow(page)
        page.screenshot(path=str(OUT / "live-mobile.png"), full_page=True)
        check("LIVE_ALL_QUERIES_OK", not bad and not failed, repr((bad + failed)[:3]))
        check("LIVE_MOBILE_NO_OVERFLOW", ov["scroll"] <= ov["client"] and not ov["offenders"], repr(ov))
        check("LIVE_CONSOLE_ERRORS", not r.errors, repr(r.errors[:3]))
        print(f"LIVE_CALLS={len(r.calls())} max_exec_seconds={max(times):.2f}")
    finally:
        client.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--live")
    ap.add_argument("--cli")
    a = ap.parse_args()
    with sync_playwright() as p:
        browser = p.chromium.launch()
        try:
            if a.live:
                live(browser, a.live, a.cli)
            else:
                offline(browser)
        finally:
            browser.close()
    print(f"SCREENSHOTS={OUT}")
    print("UI_TEST_" + ("PASS" if not failures else f"FAIL failures={failures}"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
