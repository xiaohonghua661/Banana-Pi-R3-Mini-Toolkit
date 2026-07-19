#!/bin/sh
set -eu

web=/usr/share/netdata/web
luci_view=/www/luci-static/resources/view/netdata.js
marker='netdata-zh-cn.js'
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

fail() { echo "error=$1" >&2; exit 1; }
hashes() { sha256sum "$@"; }

apply() {
  [ -r "$web/index.html" ] || fail 'netdata_index_missing'
  [ -r "$luci_view" ] || fail 'luci_netdata_view_missing'
  [ -s "$source_dir/netdata-zh-cn.js" ] || fail 'overlay_missing'

  backup="/root/netdata-zh-cn-backup-$(date +%Y%m%d-%H%M%S)"
  umask 077
  mkdir -p "$backup"
  cp -p "$web/index.html" "$backup/index.html"
  cp -p "$web/dashboard-react.js" "$backup/dashboard-react.js"
  cp -p "$luci_view" "$backup/luci-netdata.js"
  [ ! -e "$web/$marker" ] || cp -p "$web/$marker" "$backup/$marker"
  hashes "$backup/index.html" > "$backup/SHA256SUMS.before"
  hashes "$backup/dashboard-react.js" >> "$backup/SHA256SUMS.before"
  hashes "$backup/luci-netdata.js" >> "$backup/SHA256SUMS.before"
  [ ! -e "$backup/$marker" ] || hashes "$backup/$marker" >> "$backup/SHA256SUMS.before"

  tmp="$web/.$marker.$$"
  cp "$source_dir/$marker" "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$web/$marker"

  if ! grep -q 'Netdata v1.38.1 Simplified Chinese overlay' "$web/dashboard-react.js"; then
    printf '\n;\n' >> "$web/dashboard-react.js"
    cat "$web/$marker" >> "$web/dashboard-react.js"
  fi

  version=$(sha256sum "$web/$marker" | awk '{print substr($1,1,12)}')
  script_tag="<script src=\"./$marker?v=$version\"></script>"
  inline_loader="<script id=\"netdata-zh-cn-inline\">fetch('./$marker?v=$version').then(function(r){return r.text()}).then(function(s){(0,eval)(s)})</script>"

  if ! grep -q "$marker" "$web/index.html"; then
    tmp="$web/.index.html.$$"
    sed "s#</body>#$script_tag</body>#" "$web/index.html" > "$tmp"
    grep -q "$marker" "$tmp" || { rm -f "$tmp"; fail 'index_injection_failed'; }
    chmod --reference="$web/index.html" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    mv "$tmp" "$web/index.html"
  else
    tmp="$web/.index.html.$$"
    sed "s#<script src=\"\\./$marker[^\"]*\"></script>#$script_tag#g" "$web/index.html" > "$tmp"
    grep -q "v=$version" "$tmp" || { rm -f "$tmp"; fail 'index_version_update_failed'; }
    chmod --reference="$web/index.html" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    mv "$tmp" "$web/index.html"
  fi

  if ! grep -q 'netdata-zh-cn-inline' "$web/index.html"; then
    tmp="$web/.index.html.$$"
    sed "s#</body>#$inline_loader</body>#" "$web/index.html" > "$tmp"
    grep -q 'netdata-zh-cn-inline' "$tmp" || { rm -f "$tmp"; fail 'inline_loader_injection_failed'; }
    chmod --reference="$web/index.html" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
    mv "$tmp" "$web/index.html"
  fi

  tmp="$web/.index.html.$$"
  sed "s#src=\"dashboard-react.js[^\"]*\"#src=\"dashboard-react.js?v=$version\"#" "$web/index.html" > "$tmp"
  grep -q "dashboard-react.js?v=$version" "$tmp" || { rm -f "$tmp"; fail 'react_bundle_version_update_failed'; }
  chmod --reference="$web/index.html" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
  mv "$tmp" "$web/index.html"

  tmp="$luci_view.$$.tmp"
  sed -E "s#(:19999)(\?v=[^\"']*)?([\"'])#\1?v=$version\3#g" "$luci_view" > "$tmp"
  grep -Fq ":19999?v=$version" "$tmp" || { rm -f "$tmp"; fail 'luci_iframe_cachebuster_failed'; }
  chmod --reference="$luci_view" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
  mv "$tmp" "$luci_view"

  grep -q "$marker" "$web/index.html" || fail 'marker_not_found'
  [ -s "$web/$marker" ] || fail 'overlay_not_written'
  hashes "$web/index.html" "$web/dashboard-react.js" "$web/$marker" "$luci_view" > "$backup/SHA256SUMS.after"
  printf 'backup=%s\nstatus=applied\n' "$backup"
}

rollback() {
  backup=${1:?usage: deploy-openwrt.sh rollback /root/netdata-zh-cn-backup-...}
  [ -r "$backup/index.html" ] || fail 'backup_index_missing'
  [ -r "$backup/dashboard-react.js" ] || fail 'backup_dashboard_missing'
  [ -r "$backup/luci-netdata.js" ] || fail 'backup_luci_view_missing'
  cp -p "$backup/index.html" "$web/index.html"
  cp -p "$backup/dashboard-react.js" "$web/dashboard-react.js"
  cp -p "$backup/luci-netdata.js" "$luci_view"
  if [ -e "$backup/$marker" ]; then
    cp -p "$backup/$marker" "$web/$marker"
  else
    rm -f "$web/$marker"
  fi
  printf 'backup=%s\nstatus=rolled_back\n' "$backup"
}

case "${1:-apply}" in
  apply) apply ;;
  rollback) shift; rollback "$@" ;;
  *) fail 'usage: deploy-openwrt.sh [apply|rollback BACKUP]' ;;
esac
