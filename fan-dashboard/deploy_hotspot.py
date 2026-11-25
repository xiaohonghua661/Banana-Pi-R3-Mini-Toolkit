"""部署 / 回滚「网络 → 上网出口」模块（r3mini-hotspot）。

    python fan-dashboard/deploy_hotspot.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
    python fan-dashboard/deploy_hotspot.py 192.168.0.242 --key <私钥> --rollback /root/r3mini-hotspot-backup-<时间>

只用密钥登录，主机密钥必须已在 ~/.ssh/known_hosts 里（不认识的主机直接拒绝）。
部署前把要覆盖的文件备份到设备 /root/r3mini-hotspot-backup-<时间>/，部署后逐个核对 SHA-256，不一致就自动回滚。
/etc/config/r3mini_hotspot 只在设备上没有时才写入。不重启 uhttpd；ACL 有变化时重启 rpcd（已登录的 LuCI 会话需要重新登录）。

host 默认 192.168.0.242。依赖 paramiko。

输出：部署成功打印 BACKUP=…、DEPLOY_SHA256_OK=7/7、PRESERVED_CONFIG_OK=1；回滚成功打印 ROLLBACK_OK=<目录>。
失败时以非零退出并打印 error_kind：
    PINNED_HOST_KEY_MISSING        ~/.ssh/known_hosts 里没有该主机
    SSH_KEY_MISSING                --key 指的文件不存在
    SSH_KEY_LOGIN_FAILED           设备不认这把密钥
    SSH_CONNECTION_OR_PIN_FAILED   连不上，或主机密钥与固定的不一致
    UNEXPECTED_DEVICE=<board>      不是 BPI-R3 Mini，什么都没写
    DEPLOY_BACKUP_MARKER_MISSING   设备端脚本没报告备份目录
    SHA256_MISMATCH=<文件>         装上的文件与本地不一致，已自动回滚
    PRESERVED_CONFIG_MISSING       装完后 /etc/config/r3mini_hotspot 为空，已自动回滚
    ROLLBACK_BACKUP_INVALID        --rollback 给的目录格式不对或里面没有 .touched
设备端脚本中途失败时，它会自己按备份还原并在 stderr 打印 DEPLOY_ROLLBACK=<目录>（还原不全时另有
DEPLOY_ROLLBACK_FAILED=<目录>），本程序以 RuntimeError: remote command failed 退出并附上这些输出。
"""
from __future__ import annotations

import argparse
import hashlib
import re
import shlex
import sys
from datetime import datetime
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent
FILES = (
    "usr/sbin/r3mini-hotspot-web",
    "usr/sbin/r3mini-hotspot-watchdog",
    "usr/share/r3mini-hotspot/status.uc",
    "etc/init.d/r3mini-hotspot",
    "etc/config/r3mini_hotspot",
    "usr/share/luci/menu.d/luci-app-r3mini-hotspot.json",
    "usr/share/rpcd/acl.d/luci-app-r3mini-hotspot.json",
    "www/luci-static/resources/view/network/r3mini-hotspot.js",
)
PRESERVED_CONFIG = "etc/config/r3mini_hotspot"
MANAGED_FILES = tuple(f for f in FILES if f != PRESERVED_CONFIG)


def fail(kind: str) -> None:
    print(kind, file=sys.stderr)
    raise SystemExit(1)


def connect(host: str, key: str):
    import paramiko

    known = Path.home() / ".ssh" / "known_hosts"
    if not known.is_file() or host not in paramiko.HostKeys(str(known)):
        fail("PINNED_HOST_KEY_MISSING")
    if not Path(key).is_file():
        fail("SSH_KEY_MISSING")
    client = paramiko.SSHClient()
    client.load_host_keys(str(known))
    client.set_missing_host_key_policy(paramiko.RejectPolicy())
    try:
        client.connect(host, username="root", key_filename=str(key), look_for_keys=False,
                       allow_agent=False, timeout=8, banner_timeout=8, auth_timeout=8)
    except paramiko.AuthenticationException:
        client.close()
        fail("SSH_KEY_LOGIN_FAILED")
    except Exception:
        client.close()
        fail("SSH_CONNECTION_OR_PIN_FAILED")
    return client


def run(client, command: str, data: bytes | None = None, timeout: int = 120) -> str:
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    if data is not None:
        stdin.channel.sendall(data)
    stdin.channel.shutdown_write()
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"remote command failed ({code})\n{out}{err}")
    return out


def local_bytes(relative: str) -> bytes:
    # 仓库在 Windows 上可能按 CRLF 检出；设备上的脚本和配置一律用 LF。
    return (ROOT / "router" / Path(relative)).read_bytes().replace(b"\r\n", b"\n")


def deploy(client) -> None:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    stage = PurePosixPath(f"/tmp/r3mini-hotspot-src-{stamp}")
    board = run(client, "ubus call system board | jsonfilter -e '@.board_name'").strip()
    if board != "bananapi,bpi-r3-mini":
        fail(f"UNEXPECTED_DEVICE={board}")
    for relative in FILES:
        target = stage / PurePosixPath(relative)
        run(client, f"mkdir -p {shlex.quote(str(target.parent))} && cat > {shlex.quote(str(target))}", local_bytes(relative))
    script = stage / "deploy.sh"
    run(client, f"cat > {shlex.quote(str(script))}", (ROOT / "deploy-hotspot-router.sh").read_bytes().replace(b"\r\n", b"\n"))
    try:
        out = run(client, f"sh {shlex.quote(str(script))} {shlex.quote(str(stage))}", timeout=120)
    finally:
        run(client, f"rm -rf {shlex.quote(str(stage))}")
    print(out, end="")
    match = re.search(r"^BACKUP=(/root/r3mini-hotspot-backup-[0-9]+)$", out, re.M)
    if not match:
        fail("DEPLOY_BACKUP_MARKER_MISSING")
    backup = match.group(1)
    remote = run(client, "sha256sum " + " ".join(shlex.quote("/" + f) for f in MANAGED_FILES))
    found = {line.split(None, 1)[1]: line.split(None, 1)[0] for line in remote.splitlines() if line.strip()}
    bad = [f for f in MANAGED_FILES if found.get("/" + f) != hashlib.sha256(local_bytes(f)).hexdigest()]
    if bad:
        rollback(client, backup)
        fail("SHA256_MISMATCH=" + ",".join(bad))
    if run(client, "test -s /etc/config/r3mini_hotspot && echo preserved").strip() != "preserved":
        rollback(client, backup)
        fail("PRESERVED_CONFIG_MISSING")
    print(f"DEPLOY_SHA256_OK={len(MANAGED_FILES)}/{len(MANAGED_FILES)}")
    print("PRESERVED_CONFIG_OK=1")


def rollback(client, backup: str) -> None:
    if not re.fullmatch(r"/root/r3mini-hotspot-backup-[0-9]+", backup):
        fail("ROLLBACK_BACKUP_INVALID")
    q = shlex.quote(backup)
    run(client, f"test -s {q}/.touched || {{ echo ROLLBACK_BACKUP_INVALID >&2; exit 1; }}")
    run(client,
        f"b={q}; acl_changed=0; "
        'while IFS= read -r f; do '
        '  case "$f" in /usr/share/rpcd/acl.d/*) acl_changed=1 ;; esac; '
        '  if [ -e "$b$f" ]; then cp -p "$b$f" "$f"; else rm -f "$f"; fi; '
        'done < "$b/.touched"; '
        "rmdir /usr/share/r3mini-hotspot 2>/dev/null; "
        "rm -f /tmp/luci-indexcache*; "
        '[ "$acl_changed" = 1 ] && /etc/init.d/rpcd restart; '
        "/etc/init.d/r3mini-hotspot restart; true")
    print(f"ROLLBACK_OK={backup}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host", nargs="?", default="192.168.0.242", help="设备地址，默认 192.168.0.242")
    ap.add_argument("--key", required=True, help="SSH 私钥路径")
    ap.add_argument("--rollback", metavar="BACKUP_DIR", help="用设备上的这份备份回滚")
    args = ap.parse_args()
    client = connect(args.host, args.key)
    try:
        if args.rollback:
            rollback(client, args.rollback)
        else:
            deploy(client)
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
