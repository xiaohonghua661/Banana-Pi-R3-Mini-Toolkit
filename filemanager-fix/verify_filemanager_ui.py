from __future__ import annotations

import re
import sys
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

import requests
from playwright.sync_api import sync_playwright


BASE = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://192.168.0.242/cgi-bin/luci"
EXPECTED = sys.argv[2] if len(sys.argv) > 2 else "/mnt"
EDGE = Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe")
OUT_DIR = Path("tmp")


def password_candidates() -> list[str]:
    private_doc = Path("docs") / "私密" / "商家交付信息.md"
    text = private_doc.read_text(encoding="utf-8", errors="replace")
    candidates = [""]
    for match in re.finditer(r"`([^`\s]{1,80})`", text):
        value = match.group(1)
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
        if response.status_code in (302, 303) or any(
            name.startswith("sysauth") for name in session.cookies.get_dict()
        ):
            return session
    raise RuntimeError("LuCI login failed")


def main() -> int:
    if not EDGE.exists():
        raise RuntimeError(f"Edge not found: {EDGE}")

    OUT_DIR.mkdir(exist_ok=True)
    screenshot = (
        OUT_DIR / f"filemanager-ui-{datetime.now().strftime('%Y%m%d-%H%M%S')}.png"
    ).resolve()
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
        context = browser.new_context(viewport={"width": 1440, "height": 1000})
        context.add_cookies(cookies)
        page = context.new_page()
        page.goto(
            f"{BASE}/admin/system/filemanager",
            wait_until="networkidle",
            timeout=30_000,
        )
        page.wait_for_selector("#path-input", state="visible", timeout=20_000)
        page.wait_for_selector("#file-list tr", state="attached", timeout=20_000)

        current = page.locator("#path-input").input_value()
        body = page.locator("body").inner_text()
        rows = page.locator("#file-list tr").count()
        page.screenshot(path=str(screenshot), full_page=True)
        browser.close()

    if current != EXPECTED:
        raise RuntimeError(f"unexpected current directory: {current!r}")
    if "Failed to list directory" in body or "/mnt/nvme0n1p1" in body:
        raise RuntimeError("stale missing-directory error is still visible")
    if rows < 1:
        raise RuntimeError("file list is empty")

    print("FILEMANAGER_UI_OK")
    print(f"CURRENT_DIRECTORY={current}")
    print(f"ROWS={rows}")
    print(f"SCREENSHOT={screenshot}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
