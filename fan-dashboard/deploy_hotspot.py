from __future__ import annotations

import hashlib
import re
import sys
from datetime import datetime
from pathlib import Path, PurePosixPath

import paramiko


HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.242"
ROOT = Path(__file__).resolve().parent
PROJECT = ROOT.parent
FILES = (
    "usr/sbin/r3mini-hotspot-web",
    "usr/sbin/r3mini-hotspot-watchdog",
    "etc/init.d/r3mini-hotspot",
    "etc/config/r3mini_hotspot",
    "usr/share/luci/menu.d/luci-app-r3mini-hotspot.json",
    "usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json",
    "www/luci-static/resources/view/network/r3mini-hotspot.js",
)


def password_candidates() -> list[str]:
    text = (PROJECT / "docs" / "私密" / "商家交付信息.md").read_text(
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
            client.close()
    raise SystemExit("SSH_LOGIN_FAILED")


def run(client: paramiko.SSHClient, command: str, timeout: int = 60) -> str:
    _, stdout, stderr = client.exec_command(command, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"remote command failed ({code})\n{out}{err}")
    return out


def put(client: paramiko.SSHClient, local: Path, remote: PurePosixPath) -> None:
    run(client, f"mkdir -p '{remote.parent}'")
    stdin, stdout, stderr = client.exec_command(f"cat > '{remote}'", timeout=60)
    stdin.channel.sendall(local.read_bytes())
    stdin.channel.shutdown_write()
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"upload failed: {remote} ({code})\n{out}{err}")


def main() -> int:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    stage = PurePosixPath(f"/tmp/r3mini-hotspot-src-{stamp}")
    deploy = PurePosixPath(f"/tmp/deploy-hotspot-{stamp}.sh")
    client = connect()
    for relative in FILES:
        local = ROOT / "router" / Path(relative)
        if not local.is_file():
            raise FileNotFoundError(local)
        put(client, local, stage / PurePosixPath(relative))
    put(client, ROOT / "deploy-hotspot-router.sh", deploy)

    print(run(client, f"sh '{deploy}' '{stage}'", timeout=90), end="")
    remote_hashes = run(
        client,
        "sha256sum " + " ".join(f"'/{relative}'" for relative in FILES),
    )
    client.close()

    expected = {
        f"/{relative}": hashlib.sha256((ROOT / "router" / Path(relative)).read_bytes()).hexdigest()
        for relative in FILES
    }
    found = {line.split(None, 1)[1]: line.split(None, 1)[0] for line in remote_hashes.splitlines()}
    mismatches = [path for path, digest in expected.items() if found.get(path) != digest]
    if mismatches:
        raise RuntimeError("SHA256_MISMATCH=" + ",".join(mismatches))
    print(f"DEPLOY_SHA256_OK={len(FILES)}/{len(FILES)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
