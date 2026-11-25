from __future__ import annotations

import argparse
import io
import os
import re
import tarfile
from pathlib import Path

import paramiko


ROOT = Path(__file__).resolve().parent
SRC = ROOT / "router"
DEPLOY = ROOT / "deploy-router.sh"


def password_candidates() -> list[str]:
    text = (Path("docs") / "私密" / "商家交付信息.md").read_text(
        encoding="utf-8", errors="replace"
    )
    candidates = [""]
    for match in re.finditer(r"`([^`\s]{1,80})`", text):
        value = match.group(1)
        if value not in candidates:
            candidates.append(value)
    return candidates


def connect(host: str, key: str | None) -> paramiko.SSHClient:
    # 两种登录方式都只连 ~/.ssh/known_hosts 里已有指纹的主机
    known = Path.home() / ".ssh" / "known_hosts"
    if not known.is_file() or host not in paramiko.HostKeys(str(known)):
        raise SystemExit(f"PINNED_HOST_KEY_MISSING host={host}")
    if key is not None:
        # 密钥模式：只用这把密钥，不试口令、不读私密文档
        key = os.path.expanduser(key)
        if not Path(key).is_file():
            raise SystemExit(f"SSH_KEY_MISSING key={key}")
        try:
            paramiko.PKey.from_path(key)
        except Exception:
            raise SystemExit(f"SSH_KEY_INVALID key={key}")
        client = paramiko.SSHClient()
        client.load_host_keys(str(known))
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
        try:
            client.connect(host, username="root", key_filename=str(key), look_for_keys=False,
                           allow_agent=False, timeout=8, banner_timeout=8, auth_timeout=8)
            return client
        except paramiko.AuthenticationException:
            client.close()
            raise SystemExit(f"SSH_KEY_LOGIN_FAILED host={host}")
        except Exception as exc:
            client.close()
            raise SystemExit(f"SSH_CONNECTION_OR_PIN_FAILED host={host} {type(exc).__name__}")
    for password in password_candidates():
        client = paramiko.SSHClient()
        client.load_host_keys(str(known))
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
        try:
            client.connect(
                host,
                username="root",
                password=password,
                timeout=8,
                banner_timeout=8,
                auth_timeout=8,
                look_for_keys=False,
                allow_agent=False,
            )
            return client
        except paramiko.AuthenticationException:
            client.close()
        except Exception as exc:
            client.close()
            raise SystemExit(f"SSH_CONNECTION_OR_PIN_FAILED host={host} {type(exc).__name__}")
    raise SystemExit("SSH_LOGIN_FAILED")


def make_tar() -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for path in SRC.rglob("*"):
            if path.is_file():
                tar.add(path, arcname=path.relative_to(SRC).as_posix())
    return buf.getvalue()


def run(client: paramiko.SSHClient, command: str, timeout: int = 60, stdin_data: bytes | str | None = None) -> tuple[str, str]:
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    if stdin_data is not None:
        if isinstance(stdin_data, str):
            stdin.write(stdin_data)
        else:
            stdin.channel.sendall(stdin_data)
        stdin.channel.shutdown_write()
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if code != 0:
        raise RuntimeError(f"command failed: {command}\n{out}\n{err}")
    return out, err


def main() -> int:
    ap = argparse.ArgumentParser(description="把 fan-dashboard/router/ 的风扇管理部署到路由器")
    ap.add_argument("host", nargs="?", default="192.168.0.242", help="路由器地址，默认 192.168.0.242")
    ap.add_argument("--key", default=os.environ.get("R3MINI_SSH_KEY") or None,
                    help="root 的 SSH 私钥（默认取环境变量 R3MINI_SSH_KEY）；给了就只用密钥登录，不读口令文件")
    args = ap.parse_args()
    client = connect(args.host, args.key)
    tar_data = make_tar()
    run(client, "rm -rf /tmp/r3mini-fan-src && mkdir -p /tmp/r3mini-fan-src && tar -xzf - -C /tmp/r3mini-fan-src", stdin_data=tar_data)
    out, err = run(client, "sh -s /tmp/r3mini-fan-src", timeout=90, stdin_data=DEPLOY.read_text(encoding="utf-8"))
    verify = r"""
echo CONFIG
uci -q show r3mini_fan | sed -n '1,80p'
echo FILES
for p in /usr/sbin/r3mini-fanctl /usr/sbin/r3mini-fan-web /etc/init.d/r3mini-fan /etc/config/r3mini_fan /usr/share/luci/menu.d/luci-app-r3mini-fan.json /usr/share/rpcd/acl.d/luci-app-r3mini-fan.json /www/luci-static/resources/view/system/r3mini-fan.js; do [ -e "$p" ] && echo "OK $p" || echo "MISS $p"; done
echo STATUS
/etc/init.d/r3mini-fan status 2>/dev/null || true
echo THERMAL
cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true
cat /sys/class/thermal/thermal_zone0/mode 2>/dev/null || true
cat /sys/class/hwmon/hwmon1/pwm1 2>/dev/null || true
cat /sys/class/hwmon/hwmon1/pwm1_enable 2>/dev/null || true
"""
    vout, _ = run(client, verify, timeout=30)
    client.close()
    print(out.strip())
    if err.strip():
        print(err.strip())
    print(vout.strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
