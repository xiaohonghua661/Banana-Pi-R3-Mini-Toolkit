from pathlib import Path

from playwright.sync_api import sync_playwright


page_url = Path(__file__).with_name("index.html").as_uri()
preview = Path(__file__).with_name("preview.png")

with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1440, "height": 960})
    errors = []
    page.on("console", lambda message: errors.append(message.text) if message.type == "error" else None)
    page.goto(page_url)
    page.wait_for_load_state("networkidle")

    assert page.title() == "R3 Mini · 设备指挥台"
    assert page.locator("[data-device]").count() == 7
    assert page.locator("#onlineCount").inner_text() == "6"

    page.get_by_role("button", name="客厅电视 的网络开关").click()
    assert page.locator("#onlineCount").inner_text() == "5"

    page.locator("#search").fill("摄像头")
    assert page.locator("[data-device]").count() == 1
    assert page.locator(".name").inner_text() == "门口摄像头"
    page.locator("#search").fill("")
    page.get_by_role("button", name="按流量排序").click()
    assert page.locator("[data-device]").count() == 7

    page.screenshot(path=str(preview), full_page=True)

    page.set_viewport_size({"width": 390, "height": 844})
    page.reload()
    page.wait_for_load_state("networkidle")
    assert not page.evaluate("document.documentElement.scrollWidth > document.documentElement.clientWidth")
    assert not errors
    print("TITLE=PASS")
    print("DEVICE_TOGGLE=PASS")
    print("SEARCH=PASS")
    print("MOBILE_LAYOUT=PASS")
    print(f"PREVIEW={preview}")
    browser.close()
