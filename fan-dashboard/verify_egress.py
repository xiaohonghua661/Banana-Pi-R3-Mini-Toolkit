from __future__ import annotations

import argparse
import secrets
import sys
from pathlib import Path, PurePosixPath

import deploy_hotspot as transport


ROOT = Path(__file__).resolve().parent
ROUTER_VERIFY = ROOT / "verify-egress-router.sh"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="BPI-R3 Mini 智能出口实机验收")
    parser.add_argument("host", help="已核验身份并固定 SSH 主机密钥的管理地址")
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("preflight", help="只读检查设备、依赖和生产 OpenClash")
    probe = sub.add_parser("probe", help="触发一次隔离探针并验证生产 OpenClash 不变")
    probe.add_argument("--allow-runtime-change", action="store_true")
    manual = sub.add_parser("manual", help="切换一个手动出口并恢复原偏好")
    manual.add_argument("target", choices=("wan", "cellular", "hotspot"))
    manual.add_argument("--allow-config-change", action="store_true")
    auto = sub.add_parser("auto", help="验证自动出口选择并恢复原偏好")
    auto.add_argument("--allow-config-change", action="store_true")
    timing = sub.add_parser("timing", help="收集物理链路事件处理时间")
    timing.add_argument("trials", type=int)
    timing.add_argument("action", choices=("ifup", "ifdown", "ifupdate", "update", "link"))
    return parser.parse_args()


def remote_args(args: argparse.Namespace) -> list[str]:
    if args.mode == "probe" and not args.allow_runtime_change:
        raise SystemExit("PROBE_REQUIRES_--allow-runtime-change_AFTER_BACKUP")
    if args.mode in {"manual", "auto"} and not args.allow_config_change:
        raise SystemExit(f"{args.mode.upper()}_REQUIRES_--allow-config-change_AFTER_BACKUP")
    values = [args.mode]
    if args.mode == "manual":
        values.append(args.target)
    elif args.mode == "timing":
        if not 1 <= args.trials <= 50:
            raise SystemExit("TIMING_TRIALS_MUST_BE_1_TO_50")
        values.extend((str(args.trials), args.action))
    return values


def verify(args: argparse.Namespace) -> int:
    if not ROUTER_VERIFY.is_file():
        raise SystemExit("ROUTER_VERIFY_SCRIPT_MISSING")
    values = remote_args(args)
    transport.HOST = args.host
    client = transport.connect()
    remote = PurePosixPath(f"/tmp/r3mini-egress-verify-{secrets.token_hex(8)}.sh")
    try:
        transport.put(client, ROUTER_VERIFY, remote)
        transport.run(client, f"chmod 700 '{remote}'")
        command = " ".join([f"'{remote}'", *(f"'{value}'" for value in values)])
        if args.mode == "timing":
            timeout = max(180, args.trials * 130)
        elif args.mode == "auto":
            timeout = 900
        else:
            timeout = 180
        output = transport.run(client, command, timeout=timeout)
        print(output, end="")
        return 0
    finally:
        try:
            try:
                transport.run(client, f"rm -f '{remote}'")
            except Exception:
                print("VERIFY_CLEANUP_WARNING=remote_temp_script_may_remain", file=sys.stderr)
        finally:
            client.close()


def main() -> int:
    return verify(parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
