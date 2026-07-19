from __future__ import annotations

import re
import os
import sys
from pathlib import Path

import paramiko


HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.242"
CMD = os.environ.get("ROUTER_CMD", sys.argv[2] if len(sys.argv) > 2 else "true")
CMD_TIMEOUT = int(os.environ.get("ROUTER_CMD_TIMEOUT", sys.argv[3] if len(sys.argv) > 3 else "8"))


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


client = None
for password in password_candidates():
    try:
        current = paramiko.SSHClient()
        current.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        current.connect(
            HOST,
            username="root",
            password=password,
            timeout=5,
            banner_timeout=5,
            auth_timeout=5,
            look_for_keys=False,
            allow_agent=False,
        )
        client = current
        break
    except Exception:
        try:
            current.close()
        except Exception:
            pass

if client is None:
    raise SystemExit("SSH_LOGIN_FAILED")

stdin, stdout, stderr = client.exec_command(CMD, timeout=CMD_TIMEOUT)
out = stdout.read().decode("utf-8", "replace")
err = stderr.read().decode("utf-8", "replace")
code = stdout.channel.recv_exit_status()
client.close()
if out:
    print(out, end="")
if err:
    print(err, end="", file=sys.stderr)
raise SystemExit(code)
