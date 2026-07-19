from __future__ import annotations

import re
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

import requests
from playwright.sync_api import sync_playwright


BASE = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://192.168.0.242/cgi-bin/luci"
EDGE = Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe")
OUT_DIR = Path("tmp")


def private_doc() -> Path:
    return Path("docs") / "\u79c1\u5bc6" / "\u5546\u5bb6\u4ea4\u4ed8\u4fe1\u606f.md"


def password_candidates() -> list[str]:
    text = private_doc().read_text(encoding="utf-8", errors="replace")
    candidates = [""]
    for match in re.finditer(r"`([^`\s]{1,80})`", text):
        value = match.group(1)
        if value not in candidates:
            candidates.append(value)
    for line in text.splitlines():
        if any(k in line.lower() for k in ("pass", "pwd")) or any(k in line for k in ("密码", "口令")):
            for part in re.split(r"[|：:=\s]+", line):
                value = part.strip("` *,")
                if value and len(value) <= 80 and value.lower() not in {"密码", "口令", "password", "passwd", "pwd"}:
                    if value not in candidates:
                        candidates.append(value)
    return candidates


def login() -> requests.Session:
    session = requests.Session()
    for password in password_candidates():
        response = session.post(
            BASE,
            data={"luci_username": "root", "luci_password": password},
            timeout=10,
            allow_redirects=False,
        )
        if response.status_code in (302, 303) or any(name.startswith("sysauth") for name in session.cookies.get_dict()):
            page = session.get(f"{BASE}/admin/services/openclash", timeout=15)
            if page.status_code == 200 and "OpenClash" in page.text:
                return session
    raise RuntimeError("LuCI login failed")


def main() -> int:
    if not EDGE.exists():
        raise RuntimeError(f"Edge not found: {EDGE}")

    OUT_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    screenshot = (OUT_DIR / f"openclash-refresh-edge-{stamp}.png").resolve()

    session = login()
    host = urlparse(BASE).hostname or "192.168.0.242"
    cookies = [
        {
            "name": cookie.name,
            "value": cookie.value,
            "domain": host,
            "path": cookie.path or "/",
            "httpOnly": False,
            "secure": False,
            "sameSite": "Lax",
        }
        for cookie in session.cookies
    ]

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            executable_path=str(EDGE),
            headless=True,
            args=["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"],
        )
        context = browser.new_context(viewport={"width": 1280, "height": 900}, device_scale_factor=1)
        context.add_cookies(cookies)
        page = context.new_page()
        page.set_default_timeout(15_000)
        page.goto(f"{BASE}/admin/services/openclash", wait_until="domcontentloaded", timeout=20_000)
        page.wait_for_selector("#refresh-subscription", state="visible", timeout=20_000)
        page.wait_for_selector("#file-modify-time", state="attached", timeout=20_000)
        before = page.locator("#file-modify-time").inner_text(timeout=10_000).strip()
        clicked_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        page.locator("#refresh-subscription").click(timeout=10_000)
        page.wait_for_function(
            """before => {
                const el = document.querySelector('#file-modify-time');
                if (!el) return false;
                const text = (el.textContent || '').trim();
                return text && text !== before && !text.includes('--');
            }""",
            arg=before,
            timeout=45_000,
        )
        after = page.locator("#file-modify-time").inner_text(timeout=10_000).strip()
        page.screenshot(path=str(screenshot), full_page=False)
        browser.close()

    print(f"EDGE_UI_REFRESH_OK")
    print(f"CLICKED_AT={clicked_at}")
    print(f"BEFORE={before}")
    print(f"AFTER={after}")
    print(f"SCREENSHOT={screenshot}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
