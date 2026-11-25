"""在路由器 /tmp 沙箱里跑上网出口后端的测试（test_hotspot_router.sh）。

    python fan-dashboard/test_hotspot_backend.py 192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242

用设备自带的 sh、uci、jsonfilter、ucode 跑本地工作区里的 r3mini-hotspot-web、watchdog、status.uc；
配置是假数据，wifi/ifup/ip/ubus 等都是桩，不碰设备真实配置、无线和路由。结束后删掉沙箱。
最后一行 RESULT pass=N fail=M；有失败时退出码 1。连不上设备时的 error_kind 同 deploy_hotspot.py。
"""
from __future__ import annotations

import argparse
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from deploy_hotspot import ROOT, connect, local_bytes, run  # noqa: E402

FILES = {
    "web": "usr/sbin/r3mini-hotspot-web",
    "wd": "usr/sbin/r3mini-hotspot-watchdog",
    "status.uc": "usr/share/r3mini-hotspot/status.uc",
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("host", nargs="?", default="192.168.0.242")
    ap.add_argument("--key", required=True)
    args = ap.parse_args()
    client = connect(args.host, args.key)
    work = f"/tmp/r3hs-run-{secrets.token_hex(4)}"
    try:
        run(client, f"mkdir -p {work}")
        for name, relative in FILES.items():
            run(client, f"cat > {work}/{name}", local_bytes(relative))
        run(client, f"cat > {work}/test.sh", (ROOT / "test_hotspot_router.sh").read_bytes().replace(b"\r\n", b"\n"))
        stdin, stdout, _ = client.exec_command(f"cd {work} && sh test.sh {work}/web {work}/wd {work}/status.uc 2>&1", timeout=600)
        stdin.channel.shutdown_write()
        for line in iter(stdout.readline, ""):
            print(line, end="", flush=True)
        code = stdout.channel.recv_exit_status()
    finally:
        run(client, f"rm -rf {work}")
        client.close()
    return 0 if code == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
