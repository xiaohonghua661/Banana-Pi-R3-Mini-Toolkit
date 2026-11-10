"""Add an "AdGuard Home 管理" link button to the r3mini-adblock LuCI page (same file on 0.242 and the Pi).

The link opens http://<the host the page was loaded from>:800/ (AdGuard Home admin port on both boxes).
Every replacement must match exactly once, otherwise nothing is written.
Usage: python -I add_agh_link.py <original r3mini-adblock.js> <output js>
"""
import pathlib
import sys

src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
EDITS = [
    (
        ".r3ab-btn:disabled{opacity:.5;cursor:wait}\\\n",
        ".r3ab-btn:disabled{opacity:.5;cursor:wait}\\\n"
        ".r3ab-link{display:inline-flex;align-items:center;text-decoration:none;background:#fff;color:#0e4938}\\\n",
    ),
    (
        "\t\t\t\t\tE('button', { 'id': 'r3ab-update', 'class': 'r3ab-btn' }, '立即更新规则'),\n",
        "\t\t\t\t\tE('button', { 'id': 'r3ab-update', 'class': 'r3ab-btn' }, '立即更新规则'),\n"
        "\t\t\t\t\tE('a', { 'id': 'r3ab-agh', 'class': 'r3ab-btn r3ab-link', 'href': 'http://' + location.hostname + ':800/', "
        "'target': '_blank', 'rel': 'noopener', 'title': 'DNS 层广告拦截（AdGuard Home）的管理页面' }, 'AdGuard Home 管理'),\n",
    ),
]
for old, new in EDITS:
    count = src.count(old)
    if count != 1:
        sys.exit(f"EDIT_MISMATCH expected 1 got {count}: {old[:50]!r}")
    src = src.replace(old, new)
out = pathlib.Path(sys.argv[2])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(src.encode("utf-8"))
print("AGH_LINK_OK", out)
