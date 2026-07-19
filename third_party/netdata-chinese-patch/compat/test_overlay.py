from pathlib import Path

from playwright.sync_api import sync_playwright


overlay = Path(__file__).with_name("netdata-zh-cn.js")

with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    page = browser.new_page()
    page.set_content("""<html><head><title>netdata dashboard</title></head><body>
        <h1>System Overview</h1><span>Disk Read</span><button id='settings' title='Settings'>Settings</button>
        <p id='promo'>Discover the free benefits of Netdata Cloud:</p>
        <p id='cpu'>Total CPU utilization (all cores). 100% here means there is no CPU idle time at all.</p>
        <p id='history'>Every 2 seconds, Netdata collects 1,378 metrics on immortalwrt, presents them in 381 charts, and monitors them with 0 alarms.</p>
        <p id='split'>Keep an eye on <span>iowait</span></p>
        <p id='kernel'>kernel documentation</p>
        <p id='star'>Do you like Netdata? Give us a star!</p>
        <button id='cloud'>Connection to Cloud</button><a id='pricing'>Pricing</a><button id='alerts'>Alerts</button>
        <p id='late'>Pending</p>
    </body></html>""")
    page.add_script_tag(path=str(overlay))
    page.wait_for_timeout(50)
    assert page.title() == "Netdata \u4eea\u8868\u76d8"
    assert page.locator("h1").inner_text() == "\u7cfb\u7edf\u6982\u89c8"
    assert page.locator("body > span").inner_text() == "\u78c1\u76d8\u8bfb\u53d6"
    assert page.locator("#settings").inner_text() == "\u8bbe\u7f6e"
    assert page.locator("#settings").get_attribute("title") == "\u8bbe\u7f6e"
    assert page.locator("#promo").inner_text() == "\u63a2\u7d22 Netdata Cloud \u7684\u514d\u8d39\u529f\u80fd\uff1a"
    assert "\u603b CPU \u5229\u7528\u7387" in page.locator("#cpu").inner_text()
    history = page.locator("#history").inner_text()
    assert history == "Netdata \u6bcf 2 \u79d2\u5728 immortalwrt \u4e0a\u91c7\u96c6 1,378 \u9879\u6307\u6807\uff0c\u4ee5 381 \u5f20\u56fe\u8868\u5c55\u793a\uff0c\u5e76\u76d1\u63a7 0 \u6761\u544a\u8b66\u3002", history
    assert page.locator("#split").inner_text() == "\u5173\u6ce8 I/O \u7b49\u5f85"
    assert page.locator("#kernel").inner_text() == "\u5185\u6838\u6587\u6863"
    assert page.locator("#star").inner_text() == "\u559c\u6b22 Netdata \u5417\uff1f \u8bf7\u7ed9\u6211\u4eec\u70b9\u4e2a Star\uff01"
    assert not page.locator("#cloud").is_visible()
    assert not page.locator("#promo").is_visible()
    assert not page.locator("#pricing").is_visible()
    assert page.locator("#alerts").is_visible()
    page.locator("#late").evaluate("node => node.firstChild.nodeValue = 'Total CPU utilization (system.cpu)'")
    page.wait_for_timeout(50)
    assert page.locator("#late").inner_text() == "\u603b CPU \u5229\u7528\u7387\uff08system.cpu\uff09"
    print("OVERLAY_TRANSLATION=PASS")
    browser.close()
