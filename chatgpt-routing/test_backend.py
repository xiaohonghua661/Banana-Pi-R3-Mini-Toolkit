#!/usr/bin/env python3
"""Backend and benchmark-helper acceptance (the cases live in test_router_suite.rb).

The suite needs Linux with Ruby. When this PC has neither (WSL2 cannot start here),
it runs on the router inside a fresh /tmp sandbox reached over the key-only SSH link.
Every case points R3MINI_CHATGPT_ROOT at its own directory and uses a mock curl, mock
Mihomo core and mock uci, so no production file is read or written; the run costs the
router about one CPU core for a few minutes and removes its directory afterwards.

  python chatgpt-routing/test_backend.py                # all cases on 192.168.0.242
  python chatgpt-routing/test_backend.py -k steam       # only cases whose name contains "steam"
  python chatgpt-routing/test_backend.py --local        # this machine's ruby (Linux only)

Output: one PASS/FAIL line per case, then SUITE_OK or SUITE_FAILED <names>. Exit code 0 only on SUITE_OK.
"""
from __future__ import annotations

import argparse
import io
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
FILES = {
    "r3mini-chatgpt.rb": HERE / "router/usr/libexec/r3mini-chatgpt.rb",
    "r3mini-site-bench.rb": HERE / "router/usr/libexec/r3mini-site-bench.rb",
    "test_router_suite.rb": HERE / "test_router_suite.rb",
}
DEFAULT_HOST = "192.168.0.242"
# Relative to the current directory like manage.py --key; R3MINI_SSH_KEY overrides.
DEFAULT_KEY = Path(os.environ.get("R3MINI_SSH_KEY") or Path("docs") / "私密" / "r3mini-242" / "id_ed25519_242")


def bundle() -> bytes:
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w") as tar:
        for name, path in FILES.items():
            body = path.read_bytes()
            info = tarfile.TarInfo(name)
            info.size = len(body)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(body))
    return data.getvalue()


def run_remote(host: str, key: Path, name_filter: str) -> int:
    sys.path.insert(0, str(HERE))
    import manage  # noqa: E402 - pinned host key, key-only login

    client = manage.connect(host, key)
    try:
        command = ('set -e; D=$(mktemp -d /tmp/r3sr-test.XXXXXX); trap \'rm -rf "$D"\' EXIT; '
                   'tar -xf - -C "$D"; cd "$D"; ruby test_router_suite.rb "$D" ' + shlex.quote(name_filter))
        stdin, stdout, stderr = client.exec_command(command, timeout=3600)
        stdin.channel.sendall(bundle())
        stdin.channel.shutdown_write()
        for line in iter(stdout.readline, ""):
            print(line, end="", flush=True)
        code = stdout.channel.recv_exit_status()
        err = stderr.read().decode("utf-8", "replace").strip()
        if err:
            print(err, file=sys.stderr)
        return code
    finally:
        client.close()


def run_local(name_filter: str) -> int:
    ruby = shutil.which("ruby")
    if os.name == "nt" or not ruby:
        print("LOCAL_RUBY_UNAVAILABLE: run without --local to use the router sandbox", file=sys.stderr)
        return 2
    work = Path(tempfile.mkdtemp(prefix="r3sr-test.", dir="/tmp"))
    try:
        for name, path in FILES.items():
            shutil.copyfile(path, work / name)
        return subprocess.call([ruby, str(work / "test_router_suite.rb"), str(work), name_filter])
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-k", dest="name_filter", default="", help="run only cases whose name contains this text")
    parser.add_argument("--local", action="store_true", help="use this machine's ruby instead of the router sandbox")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--key", type=Path, default=DEFAULT_KEY)
    args = parser.parse_args(argv)
    if args.local:
        return run_local(args.name_filter)
    return run_remote(args.host, args.key, args.name_filter)


if __name__ == "__main__":
    if sys.stdout:
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
