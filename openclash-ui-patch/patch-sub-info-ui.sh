#!/bin/sh
set -eu

VIEW=/usr/lib/lua/luci/view/openclash/sub_info_show.htm
STATUS_VIEW=/usr/lib/lua/luci/view/openclash/status.htm
MODE=${1:-apply}

check_patch() {
	grep -q 'oc-sub-info: drop stale negative cache' "$VIEW" &&
	grep -q 'oc-sub-info: keep last good data on refresh failure' "$VIEW" &&
	grep -q 'oc-sub-info: show last successful refresh time' "$VIEW" &&
	grep -q 'oc-sub-info: force fresh subscription request' "$VIEW" &&
	grep -q 'oc-sub-info: show current refresh attempt time on fallback' "$VIEW" &&
	grep -q 'oc-status-sub-info: sync update badge with refresh attempt' "$STATUS_VIEW" &&
	grep -q 'oc-status-sub-info: local refresh time formatter' "$STATUS_VIEW"
}

case "$MODE" in
	check)
		check_patch
		echo 'SUB_INFO_UI_PATCH_OK'
		exit 0
		;;
	rollback)
		BACKUP=${2:-}
		[ -n "$BACKUP" ] && [ -s "$BACKUP" ] || {
			echo 'usage: patch-sub-info-ui.sh rollback /root/openclash-sub-info-ui-*.tar.gz' >&2
			exit 2
		}
		tar -tzf "$BACKUP" >/dev/null
		tar -xzf "$BACKUP" -C /
		/etc/init.d/uhttpd restart
		echo "ROLLBACK_OK backup=$BACKUP"
		exit 0
		;;
	apply) ;;
	*) echo 'usage: patch-sub-info-ui.sh [apply|check|rollback BACKUP]' >&2; exit 2 ;;
esac

[ -r "$VIEW" ] || { echo "view_missing:$VIEW" >&2; exit 1; }
[ -r "$STATUS_VIEW" ] || { echo "view_missing:$STATUS_VIEW" >&2; exit 1; }
command -v ruby >/dev/null 2>&1 || { echo 'ruby_missing' >&2; exit 1; }

if check_patch; then
	echo 'SUB_INFO_UI_ALREADY_PATCHED'
	exit 0
fi

TS=$(date +%Y%m%d-%H%M%S)
RAW=$(uci -q get openclash.@overwrite[0].config_path || uci -q get openclash.config.config_path)
RUN=/etc/openclash/$(basename "$RAW")
[ -r "$RUN" ] || { echo "runtime_missing:$RUN" >&2; exit 1; }
BACKUP=/root/openclash-sub-info-ui-$TS.tar.gz
tar -czf "$BACKUP" "$VIEW" "$STATUS_VIEW" /usr/lib/lua/luci/controller/openclash.lua /etc/config/openclash "$RUN"
tar -tzf "$BACKUP" >/dev/null

ruby - "$VIEW" <<'RUBY'
path = ARGV.fetch(0)
s = File.binread(path)

unless s.include?('oc-sub-info: drop stale negative cache')
  if s.include?('// Drop stale negative cache so recovered subscription headers are fetched immediately.')
    s = s.sub('// Drop stale negative cache so recovered subscription headers are fetched immediately.', '// oc-sub-info: drop stale negative cache')
  else
    anchor = '    var save_info = (localStorage.getItem("sub_info_<%=filename%>")) ? JSON.parse(localStorage.getItem("sub_info_<%=filename%>")) : null;'
    abort('negative_cache_anchor_mismatch') unless s.scan(anchor).length == 1
    addition = <<'JS'
    // oc-sub-info: drop stale negative cache
    if (save_info && (!Array.isArray(save_info.providers) || save_info.providers.length === 0)) {
        localStorage.removeItem("sub_info_<%=filename%>");
        save_info = null;
    }
JS
    s = s.sub(anchor, anchor + addition)
  end
end

unless s.include?('oc-sub-info: keep last good data on refresh failure')
  force_delete = <<'JS'
    if (force) {
        localStorage.removeItem("sub_info_<%=filename%>");
    }

JS
  force_comment = <<'JS'
    // oc-sub-info: keep last good data on refresh failure

JS
  if s.include?(force_delete)
    s = s.sub(force_delete, force_comment)
  elsif s.include?('// A forced refresh keeps the last good value until a new request succeeds.')
    s = s.sub('// A forced refresh keeps the last good value until a new request succeeds.', '// oc-sub-info: keep last good data on refresh failure')
  else
    abort('force_refresh_anchor_mismatch')
  end

  old_fallback = <<'JS'
            dispaly_progressbar('<%=idname%>', status);
            if (status && status.providers && status.providers.length > 0) {
                (window.requestIdleCallback || function(cb) { setTimeout(cb, 1); })(function() { localStorage.setItem("sub_info_<%=filename%>", JSON.stringify(status)); });
            }
JS
  new_fallback = <<'JS'
            if (status && status.providers && status.providers.length > 0) {
                dispaly_progressbar('<%=idname%>', status);
                (window.requestIdleCallback || function(cb) { setTimeout(cb, 1); })(function() { localStorage.setItem("sub_info_<%=filename%>", JSON.stringify(status)); });
            } else if (save_info && save_info.providers && save_info.providers.length > 0) {
                // oc-sub-info: keep last good data on refresh failure
                dispaly_progressbar('<%=idname%>', save_info);
            } else {
                dispaly_progressbar('<%=idname%>', status);
            }
JS
  unless s.include?('else if (save_info && save_info.providers && save_info.providers.length > 0)')
    abort('refresh_fallback_anchor_mismatch') unless s.scan(old_fallback).length == 1
    s = s.sub(old_fallback, new_fallback)
  end
end

unless s.include?('oc-sub-info: show last successful refresh time')
  start_anchor = <<'JS'
function dispaly_progressbar(id, status) {
    document.getElementById(id).className = "sub_tab_show";
JS
  time_addition = <<'JS'
    // oc-sub-info: show last successful refresh time
    var refreshTimeHtml = "";
    if (status && status.providers && status.providers.length > 0 && status.get_time) {
        var refreshDate = new Date(parseInt(status.get_time, 10) * 1000);
        if (!isNaN(refreshDate.getTime())) {
            refreshTimeHtml = '<div class="sub_refresh_time" style="font-size:11px;line-height:1.5;margin-top:2px;color:#666;">\u8ba2\u9605\u5237\u65b0\u65f6\u95f4\uff1a' + refreshDate.toLocaleString() + '</div>';
        }
    }
JS
  start_replacement = start_anchor + time_addition
  abort('refresh_time_start_anchor_mismatch') unless s.scan(start_anchor).length == 1
  s = s.sub(start_anchor, start_replacement)

  end_anchor = <<'JS'
    } else {
        document.getElementById(id).innerHTML = "<span><%:No Sub Info Found%></span>";
    }
};

function sub_info_refresh_<%=idname%>(force) {
JS
  end_replacement = <<'JS'
    } else {
        document.getElementById(id).innerHTML = "<span><%:No Sub Info Found%></span>";
    }
    if (refreshTimeHtml) {
        document.getElementById(id).innerHTML += refreshTimeHtml;
    }
};

function sub_info_refresh_<%=idname%>(force) {
JS
  abort('refresh_time_end_anchor_mismatch') unless s.scan(end_anchor).length == 1
  s = s.sub(end_anchor, end_replacement)
end

refresh_time_line = "            refreshTimeHtml = '<div class=\"sub_refresh_time\" style=\"font-size:11px;line-height:1.5;margin-top:2px;color:#666;\">\\u8ba2\\u9605\\u5237\\u65b0\\u65f6\\u95f4\\uff1a' + refreshDate.toLocaleString() + '</div>';\n"
s = s.lines.map { |line|
  line.include?("refreshTimeHtml = '<div class=\"sub_refresh_time\"") ? refresh_time_line : line
}.join

unless s.include?('oc-sub-info: force fresh subscription request')
  old_xhr = <<'JS'
	XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "sub_info_get")%>', {filename: "<%=filename%>"}, function(x, status) {
JS
  new_xhr = <<'JS'
    // oc-sub-info: force fresh subscription request
	XHR.get('<%=luci.dispatcher.build_url("admin", "services", "openclash", "sub_info_get")%>', {filename: "<%=filename%>", _t: Date.now()}, function(x, status) {
JS
  abort('fresh_request_anchor_mismatch') unless s.scan(old_xhr).length == 1
  s = s.sub(old_xhr, new_xhr)
end

unless s.include?('oc-sub-info: show current refresh attempt time on fallback')
  old_fallback_display = <<'JS'
            } else if (save_info && save_info.providers && save_info.providers.length > 0) {
                // Keep last good subscription info when a manual refresh is blocked or times out.
                dispaly_progressbar('<%=idname%>', save_info);
            } else {
JS
  new_fallback_display = <<'JS'
            } else if (save_info && save_info.providers && save_info.providers.length > 0) {
                // oc-sub-info: show current refresh attempt time on fallback
                var display_info = JSON.parse(JSON.stringify(save_info));
                if (status && status.get_time) {
                    display_info.get_time = status.get_time;
                }
                dispaly_progressbar('<%=idname%>', display_info);
            } else {
JS
  abort('fallback_attempt_time_anchor_mismatch') unless s.scan(old_fallback_display).length == 1
  s = s.sub(old_fallback_display, new_fallback_display)
end

tmp = path + '.tmp.' + Process.pid.to_s
File.binwrite(tmp, s)
File.rename(tmp, path)
RUBY

ruby - "$STATUS_VIEW" <<'RUBY'
path = ARGV.fetch(0)
s = File.binread(path)

unless s.include?('oc-status-sub-info: sync update badge with refresh attempt')
  helper_anchor = <<'JS'
        displaySubscriptionInfo: function(data) {
JS
  helper = <<'JS'
        syncUpdateBadgeWithRefresh: function(status) {
            // oc-status-sub-info: sync update badge with refresh attempt
            if (!status || !status.get_time) return;
            var fileModifyTimeElement = document.getElementById('file-modify-time');
            if (!fileModifyTimeElement) return;
            fileModifyTimeElement.textContent = '<%:Update Time%>: ' + this.formatUnixTime(status.get_time);
            fileModifyTimeElement.title = fileModifyTimeElement.textContent;
        },

JS
  abort('status_helper_anchor_mismatch') unless s.scan(helper_anchor).length == 1
  s = s.sub(helper_anchor, helper + helper_anchor)

  callback_anchor = <<'JS'
                    var needsErrorHandling = false;
JS
  callback_patch = <<'JS'
                    SubscriptionManager.syncUpdateBadgeWithRefresh(status);
                    var needsErrorHandling = false;
JS
  abort('status_callback_anchor_mismatch') unless s.scan(callback_anchor).length == 1
  s = s.sub(callback_anchor, callback_patch)
end

unless s.include?('oc-status-sub-info: local refresh time formatter')
  old_line = "            fileModifyTimeElement.textContent = '<%:Update Time%>: ' + this.formatUnixTime(status.get_time);\n"
  new_block = <<'JS'
            // oc-status-sub-info: local refresh time formatter
            var timestamp = parseInt(status.get_time, 10);
            if (isNaN(timestamp)) return;
            var date = new Date(timestamp * 1000);
            var pad = function(n) { return n < 10 ? '0' + n : '' + n; };
            var formatted = date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
            fileModifyTimeElement.textContent = '<%:Update Time%>: ' + formatted;
JS
  abort('status_time_formatter_anchor_mismatch') unless s.scan(old_line).length == 1
  s = s.sub(old_line, new_block)
end

tmp = path + '.tmp.' + Process.pid.to_s
File.binwrite(tmp, s)
File.rename(tmp, path)
RUBY

check_patch
/etc/init.d/uhttpd restart
[ "$(/etc/init.d/uhttpd status)" = running ]
echo "SUB_INFO_UI_PATCH_OK backup=$BACKUP"
