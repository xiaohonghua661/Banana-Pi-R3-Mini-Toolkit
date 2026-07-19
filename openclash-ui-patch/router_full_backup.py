from __future__ import annotations

import hashlib
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import paramiko


HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.242"
LABEL = re.sub(r"[^A-Za-z0-9_.-]+", "-", sys.argv[2] if len(sys.argv) > 2 else "stable").strip("-")
OUT_ROOT = Path("backups")


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


def run_text(client: paramiko.SSHClient, command: str, timeout: int = 30) -> str:
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"command failed: {command}\n{out}\n{err}")
    return out


def stream_device(client: paramiko.SSHClient, device: str, out_file: Path, block_size: str = "4M") -> str:
    command = f"dd if='{device}' bs={block_size} 2>/tmp/backup-device.stderr"
    stdin, stdout, stderr = client.exec_command(command, timeout=7200)
    sha = hashlib.sha256()
    total = 0
    last_report = time.monotonic()
    with out_file.open("wb") as f:
        while True:
            chunk = stdout.channel.recv(1024 * 1024)
            if not chunk:
                break
            f.write(chunk)
            sha.update(chunk)
            total += len(chunk)
            now = time.monotonic()
            if now - last_report >= 30:
                print(f"STREAM {out_file.name} {total / (1024 * 1024):.1f} MiB", flush=True)
                last_report = now
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    dd_err = run_text(client, "cat /tmp/backup-device.stderr 2>/dev/null || true", timeout=10)
    out_file.with_suffix(out_file.suffix + ".stderr.txt").write_text((err + dd_err), encoding="utf-8")
    if code != 0:
        raise RuntimeError(f"device backup failed: {device} -> {out_file}\n{err}\n{dd_err}")
    print(f"STREAM_OK {out_file.name} {total} bytes", flush=True)
    return sha.hexdigest()


def main() -> int:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = (OUT_ROOT / f"r3mini-stable-{stamp}-{LABEL}").resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    client = connect()

    board = run_text(client, "ubus call system board 2>/dev/null || true", timeout=15)
    (out_dir / "board.json").write_text(board, encoding="utf-8")
    (out_dir / "network.uci").write_text(run_text(client, "uci export network", timeout=15), encoding="utf-8")
    (out_dir / "wireless.uci").write_text(run_text(client, "uci export wireless", timeout=15), encoding="utf-8")
    (out_dir / "fan.uci").write_text(run_text(client, "uci export r3mini_fan 2>/dev/null || true", timeout=15), encoding="utf-8")
    (out_dir / "packages.txt").write_text(run_text(client, "opkg list-installed 2>/dev/null || true", timeout=30), encoding="utf-8")
    (out_dir / "runtime-status.txt").write_text(
        run_text(
            client,
            "date '+%F %T %z'; ip -4 addr show; ip route show; ifstatus wan 2>/dev/null || true; ifstatus RM500CNV 2>/dev/null || true; /etc/init.d/uhttpd status 2>/dev/null || true; /etc/init.d/r3mini-fan status 2>/dev/null || true; /etc/init.d/openclash status 2>/dev/null || true",
            timeout=30,
        ),
        encoding="utf-8",
    )

    remote_cfg = f"/tmp/config-backup-{stamp}.tar.gz"
    run_text(client, f"sysupgrade -b '{remote_cfg}'", timeout=60)
    stdin, stdout, stderr = client.exec_command(f"cat '{remote_cfg}'", timeout=120)
    config_data = stdout.read()
    config_err = stderr.read().decode("utf-8", "replace")
    config_code = stdout.channel.recv_exit_status()
    if config_code != 0:
        raise RuntimeError(f"config backup download failed: {config_err}")
    (out_dir / "config.tar.gz").write_bytes(config_data)

    shas: dict[str, str] = {"config.tar.gz": hashlib.sha256(config_data).hexdigest()}
    devices = [
        ("/dev/mtd0", "mtd0-bl2.bin", "1M"),
        ("/dev/mtd1", "mtd1-ubi.bin", "1M"),
        ("/dev/mmcblk0boot0", "mmcboot0.bin", "1M"),
        ("/dev/mmcblk0boot1", "mmcboot1.bin", "1M"),
        ("/dev/mmcblk0", "mmcblk0-full.img", "4M"),
    ]
    for dev, name, bs in devices:
        exists = run_text(client, f"[ -e '{dev}' ] && echo yes || echo no", timeout=10).strip() == "yes"
        if not exists:
            print(f"SKIP_MISSING {dev}", flush=True)
            continue
        shas[name] = stream_device(client, dev, out_dir / name, bs)

    client.close()
    sha_lines = [f"{digest}  {name}" for name, digest in sorted(shas.items())]
    (out_dir / "SHA256SUMS.txt").write_text("\n".join(sha_lines) + "\n", encoding="utf-8")
    manifest = {
        "label": LABEL,
        "host": HOST,
        "created_at_local": stamp,
        "files": sorted(shas),
        "sha256_file": "SHA256SUMS.txt",
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print("ROUTER_FULL_BACKUP_OK", flush=True)
    print(f"OUT_DIR={out_dir}", flush=True)
    print(f"FILES={len(shas)}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
