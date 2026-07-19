from pathlib import Path

from playwright.sync_api import sync_playwright


url = Path(__file__).with_name("index.html").as_uri()
preview = Path(__file__).with_name("preview.png")

with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1440, "height": 1050})
    errors = []
    page.on("console", lambda message: errors.append(message.text) if message.type == "error" else None)
    page.goto(url)
    page.wait_for_load_state("networkidle")

    assert page.title() == "BPI-R3 Mini 风扇管理"
    assert page.locator("#modeToggle button").count() == 4
    assert page.locator("#temperature").is_visible()

    page.get_by_role("button", name="高速").click()
    assert page.locator("#stage").inner_text() == "高速"
    assert page.locator("#pwm").inner_text() == "0"

    page.locator("#mediumUp").fill("45")
    page.locator("#mediumUp").dispatch_event("input")
    assert page.locator("#apply").is_disabled()
    assert "阈值关系无效" in page.locator("#message").inner_text()
    page.locator("#reset").click()
    assert not page.locator("#apply").is_disabled()

    page.reload()
    page.wait_for_load_state("networkidle")
    desktop_overflow = page.evaluate("document.documentElement.scrollWidth > document.documentElement.clientWidth")
    page.screenshot(path=str(preview), full_page=True)

    page.set_viewport_size({"width": 390, "height": 844})
    page.reload()
    page.wait_for_load_state("networkidle")
    mobile_overflow = page.evaluate("document.documentElement.scrollWidth > document.documentElement.clientWidth")

    print(f"TITLE={page.title()}", flush=True)
    print("MODE_SWITCH=PASS", flush=True)
    print("VALIDATION=PASS", flush=True)
    print(f"DESKTOP_OVERFLOW={desktop_overflow}", flush=True)
    print(f"MOBILE_OVERFLOW={mobile_overflow}", flush=True)
    print(f"CONSOLE_ERRORS={len(errors)}", flush=True)
    print(f"SCREENSHOT={preview}", flush=True)
    browser.close()
