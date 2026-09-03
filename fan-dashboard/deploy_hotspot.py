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
KNOWN_HOSTS = PROJECT / "docs" / "私密" / "router_known_hosts"
FILES = (
    "usr/sbin/r3mini-hotspot-web",
    "usr/sbin/r3mini-hotspot-watchdog",
    "usr/sbin/r3mini-egress-manager",
    "etc/init.d/r3mini-hotspot",
    "etc/config/r3mini_hotspot",
    "etc/hotplug.d/iface/95-r3mini-egress",
    "usr/share/luci/menu.d/luci-app-r3mini-hotspot.json",
    "usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json",
    "www/luci-static/resources/view/network/r3mini-hotspot.js",
)
PRESERVED_CONFIG = "etc/config/r3mini_hotspot"
MANAGED_FILES = tuple(relative for relative in FILES if relative != PRESERVED_CONFIG)


def router_password() -> str:
    text = (PROJECT / "docs" / "私密" / "商家交付信息.md").read_text(
        encoding="utf-8", errors="replace"
    )
    match = re.search(r"^\|\s*路由器管理密码\s*\|\s*`([^`\r\n]{1,80})`", text, re.M)
    if not match:
        raise SystemExit("ROUTER_PASSWORD_NOT_FOUND")
    return match.group(1)


def connect() -> paramiko.SSHClient:
    if not KNOWN_HOSTS.is_file():
        raise SystemExit("ROUTER_HOST_KEY_NOT_PINNED")
    client = paramiko.SSHClient()
    client.load_host_keys(str(KNOWN_HOSTS))
    client.set_missing_host_key_policy(paramiko.RejectPolicy())
    try:
        client.connect(
            HOST,
            username="root",
            password=router_password(),
            timeout=8,
            banner_timeout=8,
            auth_timeout=8,
            look_for_keys=False,
            allow_agent=False,
        )
        return client
    except Exception as error:
        client.close()
        raise SystemExit("SSH_LOGIN_OR_HOST_KEY_FAILED") from error


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


def rollback(client: paramiko.SSHClient, backup: str) -> None:
    run(
        client,
        "set -e; b='" + backup + "'; "
        "while IFS= read -r f; do "
        'if [ -e "$b$f" ]; then cp -p "$b$f" "$f"; else rm -f "$f"; fi; '
        'done < "$b/.touched"; '
        "rm -f /tmp/luci-indexcache; "
        "/etc/init.d/rpcd restart; /etc/init.d/uhttpd restart; /etc/init.d/r3mini-hotspot restart",
    )


def deploy(client: paramiko.SSHClient) -> int:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    stage = PurePosixPath(f"/tmp/r3mini-hotspot-src-{stamp}")
    deploy = PurePosixPath(f"/tmp/deploy-hotspot-{stamp}.sh")
    identity = run(client, "ubus call system board | jsonfilter -e '@.board_name'").strip()
    if identity != "bananapi,bpi-r3-mini":
        raise RuntimeError(f"UNEXPECTED_DEVICE={identity}")
    for relative in FILES:
        local = ROOT / "router" / Path(relative)
        if not local.is_file():
            raise FileNotFoundError(local)
        put(client, local, stage / PurePosixPath(relative))
    put(client, ROOT / "deploy-hotspot-router.sh", deploy)

    deploy_output = run(client, f"sh '{deploy}' '{stage}'", timeout=90)
    print(deploy_output, end="")
    backup_match = re.search(r"^BACKUP=(/root/r3mini-hotspot-backup-[0-9]+)$", deploy_output, re.M)
    if not backup_match:
        raise RuntimeError("DEPLOY_BACKUP_MARKER_MISSING")
    backup = backup_match.group(1)
    try:
        remote_hashes = run(
            client,
            "sha256sum " + " ".join(f"'/{relative}'" for relative in FILES),
        )
        expected = {
            f"/{relative}": hashlib.sha256((ROOT / "router" / Path(relative)).read_bytes()).hexdigest()
            for relative in MANAGED_FILES
        }
        found = {line.split(None, 1)[1]: line.split(None, 1)[0] for line in remote_hashes.splitlines()}
        mismatches = [path for path, digest in expected.items() if found.get(path) != digest]
        if mismatches:
            raise RuntimeError("SHA256_MISMATCH=" + ",".join(mismatches))
        config_state = run(client, "test -s /etc/config/r3mini_hotspot && echo preserved").strip()
        if config_state != "preserved":
            raise RuntimeError("PRESERVED_CONFIG_MISSING")
    except Exception as error:
        try:
            rollback(client, backup)
        except Exception as rollback_error:
            raise RuntimeError(f"{error}; ROLLBACK_FAILED={rollback_error}") from error
        raise
    print(f"DEPLOY_SHA256_OK={len(MANAGED_FILES)}/{len(MANAGED_FILES)}")
    print("PRESERVED_CONFIG_OK=1")
    return 0


def main() -> int:
    client = connect()
    try:
        return deploy(client)
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
