"""Repeatable Netdata zh-CN overlay deployment for OpenWrt routers.

Set NETDATA_ROUTER_PASSWORD in the caller environment; do not store a password here.
Use one --host for one router or repeat --host for a production batch.
"""
from __future__ import annotations

import argparse
import base64
import os
from pathlib import Path
import re
import sys

import paramiko


ROOT = Path(__file__).resolve().parent
PASSWORD = os.environ.get("NETDATA_ROUTER_PASSWORD")
BACKUP_PATH = re.compile(r"/root/netdata-zh-cn-backup-\d{8}-\d{6}\Z")


def run(client: paramiko.SSHClient, command: str) -> str:
    _, stdout, stderr = client.exec_command(command, timeout=30)
    output = stdout.read().decode("utf-8", "replace")
    error = stderr.read().decode("utf-8", "replace")
    if error or stdout.channel.recv_exit_status() != 0:
        raise RuntimeError((error or output).strip())
    return output


def encoded_chunks(payload: bytes, size: int = 180) -> list[str]:
    return [base64.b64encode(payload[offset:offset + size]).decode("ascii") for offset in range(0, len(payload), size)]


def upload(client: paramiko.SSHClient, local: Path, remote: str) -> None:
    payload = local.read_bytes().replace(b"\r\n", b"\n")
    run(client, f"umask 077; mkdir -p /tmp/netdata-zh-cn; : > {remote}")
    for encoded in encoded_chunks(payload):
        run(client, f"printf '%s\\n' '{encoded}' | openssl base64 -d >> {remote}")


def validated_backup_path(path: str) -> str:
    if not BACKUP_PATH.fullmatch(path):
        raise ValueError("invalid_rollback_backup")
    return path


def verify(client: paramiko.SSHClient) -> None:
    result = run(client, "netdata -V; test -s /usr/share/netdata/web/netdata-zh-cn.js; grep -q 'netdata-zh-cn.js' /usr/share/netdata/web/index.html; grep -Eq ':19999\\?v=[0-9a-f]{12}' /www/luci-static/resources/view/netdata.js; wget -qO- http://127.0.0.1:19999/ | grep -q 'netdata-zh-cn.js'; sha256sum /usr/share/netdata/web/index.html /usr/share/netdata/web/netdata-zh-cn.js /www/luci-static/resources/view/netdata.js")
    if "netdata v1.38.1" not in result:
        raise RuntimeError("unexpected_netdata_version")
    print(result, end="")


def deploy(host: str, rollback_backup: str | None) -> None:
    if not PASSWORD:
        raise RuntimeError("NETDATA_ROUTER_PASSWORD is required")
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(host, username="root", password=PASSWORD, timeout=10, banner_timeout=10, auth_timeout=10, look_for_keys=False, allow_agent=False)
        upload(client, ROOT / "netdata-zh-cn.js", "/tmp/netdata-zh-cn/netdata-zh-cn.js")
        upload(client, ROOT / "deploy-openwrt.sh", "/tmp/netdata-zh-cn/deploy-openwrt.sh")
        run(client, "chmod 700 /tmp/netdata-zh-cn/deploy-openwrt.sh")
        run(client, "test -s /tmp/netdata-zh-cn/netdata-zh-cn.js; grep -q 'Netdata v1.38.1 Simplified Chinese overlay' /tmp/netdata-zh-cn/netdata-zh-cn.js; grep -q 'usage: deploy-openwrt.sh' /tmp/netdata-zh-cn/deploy-openwrt.sh")
        if rollback_backup:
            print(run(client, f"sh /tmp/netdata-zh-cn/deploy-openwrt.sh rollback {validated_backup_path(rollback_backup)}"), end="")
            verify(client)
            return
        applied = run(client, "sh /tmp/netdata-zh-cn/deploy-openwrt.sh apply")
        backup = re.search(r"^backup=(.+)$", applied, re.MULTILINE)
        if not backup:
            raise RuntimeError("backup_path_not_reported")
        try:
            verify(client)
        except Exception:
            run(client, f"sh /tmp/netdata-zh-cn/deploy-openwrt.sh rollback {backup.group(1)}")
            raise
        print(f"host={host}\n{applied}", end="")
    finally:
        client.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", action="append", required=True)
    parser.add_argument("--rollback", metavar="BACKUP")
    args = parser.parse_args()
    for host in args.host:
        deploy(host, args.rollback)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"error={error}", file=sys.stderr)
        raise SystemExit(1)
