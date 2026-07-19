from __future__ import annotations

import base64
import re
import sys
from datetime import datetime
from pathlib import Path

import paramiko


HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.242"
STATUS = "/usr/lib/lua/luci/view/openclash/status.htm"
SUBINFO = "/usr/lib/lua/luci/view/openclash/sub_info_show.htm"


def password_candidates() -> list[str]:
    text = (Path("docs") / "\u79c1\u5bc6" / "\u5546\u5bb6\u4ea4\u4ed8\u4fe1\u606f.md").read_text(
        encoding="utf-8", errors="replace"
    )
    candidates = [""]
    for match in re.finditer(r"`([^`\s]{1,80})`", text):
        value = match.group(1)
        if value not in candidates:
            candidates.append(value)
    return candidates


def connect() -> paramiko.SSHClient:
    for password in password_candidates():
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(
                HOST,
                username="root",
                password=password,
                timeout=8,
                banner_timeout=8,
                auth_timeout=8,
                look_for_keys=False,
                allow_agent=False,
            )
            return client
        except Exception:
            try:
                client.close()
            except Exception:
                pass
    raise SystemExit("SSH_LOGIN_FAILED")


def run(client: paramiko.SSHClient, command: str, timeout: int = 60, stdin_data: str | None = None) -> tuple[str, str]:
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    if stdin_data is not None:
        stdin.write(stdin_data)
        stdin.channel.shutdown_write()
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"command failed: {command}\n{out}\n{err}")
    return out, err


def read_file(client: paramiko.SSHClient, path: str) -> str:
    out, _ = run(client, f"cat '{path}'", timeout=30)
    return out


def write_file(client: paramiko.SSHClient, path: str, text: str) -> None:
    data = base64.b64encode(text.encode("utf-8")).decode("ascii")
    run(client, f"ruby -e 'STDOUT.write STDIN.read.unpack1(\"m\")' > '{path}'", timeout=30, stdin_data=data)


def patch_status(s: str) -> str:
    if "oc-status-sub-info: force fresh subscription request" not in s:
        s = s.replace(
            "            var cachedData = localStorage.getItem('sub_info_' + filename);\n            var shouldFetchNew = true;\n",
            "            var cachedData = localStorage.getItem('sub_info_' + filename);\n            var shouldFetchNew = true;\n            // oc-status-sub-info: force fresh subscription request\n            var forceRefresh = !!this.forceRefresh;\n            this.forceRefresh = false;\n",
            1,
        )
        s = s.replace(
            "                    if (parsedData.get_time) {\n",
            "                    if (!forceRefresh && parsedData.get_time) {\n",
            1,
        )
        s = s.replace(
            "                StateManager.cachedXHRGetWithParams('<%=luci.dispatcher.build_url(\"admin\", \"services\", \"openclash\", \"sub_info_get\")%>', {filename: filename}, function(x, status) {\n",
            "                StateManager.cachedXHRGetWithParams('<%=luci.dispatcher.build_url(\"admin\", \"services\", \"openclash\", \"sub_info_get\")%>', {filename: filename, _t: Date.now()}, function(x, status) {\n",
            1,
        )

    if "oc-status-sub-info: sync update badge with refresh attempt" not in s:
        helper = """        syncUpdateBadgeWithRefresh: function(status) {
            // oc-status-sub-info: sync update badge with refresh attempt
            if (!status || !status.get_time) return;
            var fileModifyTimeElement = document.getElementById('file-modify-time');
            if (!fileModifyTimeElement) return;
            var timestamp = parseInt(status.get_time, 10);
            if (isNaN(timestamp)) return;
            var date = new Date(timestamp * 1000);
            var pad = function(n) { return n < 10 ? '0' + n : '' + n; };
            var formatted = date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
            // oc-status-sub-info: local refresh time formatter
            fileModifyTimeElement.textContent = '<%:Update Time%>: ' + formatted;
            fileModifyTimeElement.title = fileModifyTimeElement.textContent;
        },

"""
        s = s.replace("        displaySubscriptionInfo: function(data) {\n", helper + "        displaySubscriptionInfo: function(data) {\n", 1)
        s = s.replace(
            "                    var needsErrorHandling = false;\n",
            "                    SubscriptionManager.syncUpdateBadgeWithRefresh(status);\n                    var needsErrorHandling = false;\n",
            1,
        )

    if "oc-status-sub-info: keep last good data on manual refresh" not in s:
        s = s.replace(
            "        localStorage.removeItem('sub_info_' + filename);\n        SubscriptionManager.getSubscriptionInfo();\n",
            "        // oc-status-sub-info: keep last good data on manual refresh\n        SubscriptionManager.forceRefresh = true;\n        SubscriptionManager.getSubscriptionInfo();\n",
            1,
        )

    required = [
        "oc-status-sub-info: force fresh subscription request",
        "oc-status-sub-info: sync update badge with refresh attempt",
        "oc-status-sub-info: local refresh time formatter",
        "oc-status-sub-info: keep last good data on manual refresh",
    ]
    missing = [m for m in required if m not in s]
    if missing:
        raise RuntimeError(f"status patch markers missing: {missing}")
    return s


def patch_subinfo(s: str) -> str:
    if "oc-sub-info: force fresh subscription request" not in s:
        s = s.replace(
            "\tXHR.get('<%=luci.dispatcher.build_url(\"admin\", \"services\", \"openclash\", \"sub_info_get\")%>', {filename: \"<%=filename%>\"}, function(x, status) {\n",
            "    // oc-sub-info: force fresh subscription request\n\tXHR.get('<%=luci.dispatcher.build_url(\"admin\", \"services\", \"openclash\", \"sub_info_get\")%>', {filename: \"<%=filename%>\", _t: Date.now()}, function(x, status) {\n",
            1,
        )
    if "oc-sub-info: keep last good data on refresh failure" not in s:
        s = s.replace(
            "    if (force) {\n        localStorage.removeItem(\"sub_info_<%=filename%>\");\n    }\n\n",
            "    // oc-sub-info: keep last good data on refresh failure\n\n",
            1,
        )
        s = s.replace(
            "            dispaly_progressbar('<%=idname%>', status);\n            if (status && status.providers) {\n",
            "            if (status && status.providers && status.providers.length > 0) {\n                dispaly_progressbar('<%=idname%>', status);\n            } else if (save_info && save_info.providers && save_info.providers.length > 0) {\n                dispaly_progressbar('<%=idname%>', save_info);\n            } else {\n                dispaly_progressbar('<%=idname%>', status);\n            }\n            if (status && status.providers && status.providers.length > 0) {\n",
            1,
        )
    required = [
        "oc-sub-info: force fresh subscription request",
        "oc-sub-info: keep last good data on refresh failure",
    ]
    missing = [m for m in required if m not in s]
    if missing:
        raise RuntimeError(f"sub_info patch markers missing: {missing}")
    return s


def main() -> int:
    client = connect()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    remote_backup = f"/root/openclash-ui-current-before-patch-{stamp}.tar.gz"
    run(client, f"tar -czf '{remote_backup}' '{STATUS}' '{SUBINFO}' /usr/lib/lua/luci/controller/openclash.lua /etc/config/openclash /etc/openclash/config 2>/dev/null || tar -czf '{remote_backup}' '{STATUS}' '{SUBINFO}'", timeout=60)

    status = patch_status(read_file(client, STATUS))
    subinfo = patch_subinfo(read_file(client, SUBINFO))
    write_file(client, STATUS, status)
    write_file(client, SUBINFO, subinfo)
    run(client, "rm -f /tmp/luci-indexcache; /etc/init.d/uhttpd restart", timeout=60)
    verify, _ = run(
        client,
        "grep -q 'oc-status-sub-info: force fresh subscription request' /usr/lib/lua/luci/view/openclash/status.htm && "
        "grep -q 'oc-status-sub-info: keep last good data on manual refresh' /usr/lib/lua/luci/view/openclash/status.htm && "
        "grep -q 'oc-sub-info: force fresh subscription request' /usr/lib/lua/luci/view/openclash/sub_info_show.htm && "
        "grep -q 'oc-sub-info: keep last good data on refresh failure' /usr/lib/lua/luci/view/openclash/sub_info_show.htm && "
        "echo OPENCLASH_UI_CURRENT_PATCH_OK && /etc/init.d/uhttpd status && uci -q get r3mini_fan.main.high_up",
        timeout=30,
    )
    client.close()
    print(f"BACKUP={remote_backup}")
    print(verify.strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
