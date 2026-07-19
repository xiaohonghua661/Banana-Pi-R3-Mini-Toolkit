from __future__ import annotations

import io
import re
import sys
import tarfile
from pathlib import Path

import paramiko


HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.242"
PKG_ROOT = Path("backups") / "router-20260719-170558-prechange" / "installers"
FALLBACK_OPENCLASH = Path("docs") / "\u79c1\u5bc6" / "\u8bbe\u5907\u5907\u4efd" / "packages"


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


def package_files() -> list[Path]:
    files = []
    dep_dir = PKG_ROOT / "deps"
    if dep_dir.exists():
        files.extend(sorted(dep_dir.glob("*.ipk")))
    files.extend(sorted(PKG_ROOT.glob("luci-app-openclash_*.ipk")))
    if not any(p.name.startswith("luci-app-openclash_") for p in files):
        files.extend(sorted(FALLBACK_OPENCLASH.glob("luci-app-openclash_*.ipk")))
    if not files:
        raise SystemExit("NO_IPK_FOUND")
    return files


def make_tar(files: list[Path]) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for path in files:
            tar.add(path, arcname=path.name)
    return buf.getvalue()


def run(client: paramiko.SSHClient, command: str, timeout: int = 120, stdin_data: bytes | None = None) -> tuple[str, str]:
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    if stdin_data is not None:
        stdin.channel.sendall(stdin_data)
        stdin.channel.shutdown_write()
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"command failed: {command}\n{out}\n{err}")
    return out, err


def main() -> int:
    files = package_files()
    client = connect()
    tar_data = make_tar(files)
    run(client, "rm -rf /tmp/openclash-ipks && mkdir -p /tmp/openclash-ipks && tar -xzf - -C /tmp/openclash-ipks", stdin_data=tar_data)
    command = r"""
set -eu
echo BEFORE
opkg list-installed | grep -Ei 'openclash|ruby|libyaml|unzip' || true
echo INSTALL
opkg install /tmp/openclash-ipks/*.ipk
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
echo AFTER
opkg list-installed | grep -Ei 'openclash|ruby|libyaml|unzip' || true
echo FILES
test -f /usr/lib/lua/luci/controller/openclash.lua && echo controller_ok
test -f /usr/lib/lua/luci/view/openclash/status.htm && echo status_view_ok
test -f /usr/lib/lua/luci/view/openclash/sub_info_show.htm && echo sub_info_view_ok
"""
    out, err = run(client, command, timeout=180)
    client.close()
    print(f"UPLOADED_IPKS={len(files)}")
    print(out.strip())
    if err.strip():
        print(err.strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
