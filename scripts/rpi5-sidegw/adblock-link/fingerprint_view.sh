#!/bin/sh
# Point the 广告过滤 menu at a content-fingerprinted copy of its view JS, so browsers load the new
# file instead of a cached old one (LuCI requests views at a fixed URL). Same pattern as
# r3mini-fan-3848230b8f.js. After any later edit of r3mini-adblock.js, rerun this script.
set -eu
V=/www/luci-static/resources/view/services
M=/usr/share/luci/menu.d/luci-app-r3mini-adblock.json
H=$(sha256sum "$V/r3mini-adblock.js" | cut -c1-10)
grep -q 'r3ab-agh' "$V/r3mini-adblock.js" || { echo 'ABORT: page has no AdGuard Home button'; exit 1; }
cp -a "$M" "$M.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
rm -f "$V"/r3mini-adblock-*.js
cp -a "$V/r3mini-adblock.js" "$V/r3mini-adblock-$H.js"
sed -i -E "s#\"path\": \"services/r3mini-adblock(-[0-9a-f]+)?\"#\"path\": \"services/r3mini-adblock-$H\"#" "$M"
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
echo "menu path: $(grep -o '"path": "[^"]*"' "$M")"
echo "copy served: $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/luci-static/resources/view/services/r3mini-adblock-$H.js")  identical: $(cmp -s "$V/r3mini-adblock.js" "$V/r3mini-adblock-$H.js" && echo yes || echo no)"
echo FINGERPRINT_OK
