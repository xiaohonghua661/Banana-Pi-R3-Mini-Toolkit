from __future__ import annotations

import hashlib
import re
import sys
from datetime import datetime
from pathlib import Path

import paramiko


HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.242"
LABEL = re.sub(r"[^A-Za-z0-9_.-]+", "-", sys.argv[2] if len(sys.argv) > 2 else "manual").strip("-")
OUT_DIR = Path("backups") / "router"


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


def run(client: paramiko.SSHClient, command: str, timeout: int = 60) -> tuple[str, str]:
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"command failed: {command}\n{out}\n{err}")
    return out, err


def run_script(client: paramiko.SSHClient, script: str, timeout: int = 60) -> tuple[str, str]:
    stdin, stdout, stderr = client.exec_command("sh -s", timeout=timeout)
    stdin.write(script)
    stdin.channel.shutdown_write()
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"script failed\n{out}\n{err}")
    return out, err


def main() -> int:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    remote_dir = f"/tmp/router-backup-{stamp}-{LABEL}"
    remote_tar = f"/tmp/router-backup-{stamp}-{LABEL}.tar.gz"
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    local_tar = (OUT_DIR / f"router-backup-{stamp}-{LABEL}.tar.gz").resolve()
    local_manifest = (OUT_DIR / f"router-backup-{stamp}-{LABEL}.sha256.txt").resolve()

    client = connect()
    script = f"""
set -eu
rm -rf '{remote_dir}' '{remote_tar}'
mkdir -p '{remote_dir}/files'
{{
  echo 'backup_label={LABEL}'
  echo 'backup_time=$(date "+%F %T %z")'
  echo 'hostname=$(hostname 2>/dev/null || true)'
  echo 'uname=$(uname -a 2>/dev/null || true)'
  echo 'release='
  cat /etc/openwrt_release 2>/dev/null || true
  echo '--- ip_addr ---'
  ip -4 addr show 2>/dev/null || true
  echo '--- ip_route ---'
  ip route show 2>/dev/null || true
  echo '--- ifstatus_wan ---'
  ifstatus wan 2>/dev/null || true
  echo '--- ifstatus_wan6 ---'
  ifstatus wan6 2>/dev/null || true
  echo '--- services ---'
  for s in uhttpd openclash nikki r3mini-fan r3mini-hotspot; do /etc/init.d/$s status 2>/dev/null || true; done
  echo '--- packages ---'
  opkg list-installed 2>/dev/null || true
}} > '{remote_dir}/manifest.txt'
for p in \
  /etc/config \
  /etc/openclash \
  /etc/nikki \
  /usr/lib/lua/luci/controller/openclash.lua \
  /usr/lib/lua/luci/view/openclash/status.htm \
  /usr/lib/lua/luci/view/openclash/sub_info_show.htm \
  /usr/sbin/r3mini-fanctl \
  /usr/sbin/r3mini-fan-web \
  /etc/init.d/r3mini-fan \
  /usr/share/rpcd/acl.d/luci-app-r3mini-fan.json \
  /usr/share/luci/menu.d/luci-app-r3mini-fan.json \
  /www/luci-static/resources/view/system/r3mini-fan.js \
  /usr/sbin/r3mini-hotspot-web \
  /usr/sbin/r3mini-hotspot-watchdog \
  /etc/init.d/r3mini-hotspot \
  /usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json \
  /usr/share/luci/menu.d/luci-app-r3mini-hotspot.json \
  /www/luci-static/resources/view/network/r3mini-hotspot.js; do
  if [ -e "$p" ]; then
    mkdir -p "{remote_dir}/files$(dirname "$p")"
    cp -a "$p" "{remote_dir}/files$p"
  fi
done
tar -C '{remote_dir}' -czf '{remote_tar}' .
sha256sum '{remote_tar}'
"""
    out, _ = run_script(client, script, timeout=120)
    remote_sha = out.strip().split()[0]
    stdin, stdout, stderr = client.exec_command(f"cat '{remote_tar}'", timeout=120)
    data = stdout.read()
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"download failed: {err}")
    client.close()

    local_tar.write_bytes(data)
    local_sha = hashlib.sha256(data).hexdigest()
    if local_sha != remote_sha:
        raise RuntimeError(f"sha256 mismatch remote={remote_sha} local={local_sha}")
    local_manifest.write_text(f"{local_sha}  {local_tar.name}\n", encoding="utf-8")
    print("ROUTER_BACKUP_OK")
    print(f"LABEL={LABEL}")
    print(f"SHA256={local_sha}")
    print(f"LOCAL_TAR={local_tar}")
    print(f"LOCAL_SHA256={local_manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
