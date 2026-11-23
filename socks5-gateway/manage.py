#!/usr/bin/env python3
"""r3mini-socks5 部署器。设备地址必须显式给出。

用法：
    python socks5-gateway/manage.py install  192.168.0.242 --key docs/私密/r3mini-242/id_ed25519_242
    python socks5-gateway/manage.py verify   192.168.0.242 --key ...
    python socks5-gateway/manage.py rollback 192.168.0.242 --key ... --backup /etc/r3mini-socks5/install-backup-<时间>

不带 --key 时按旧方式用 docs/私密/商家交付信息.md 里的密码登录。主机密钥必须已固定在 ~/.ssh/known_hosts。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import sys
from datetime import datetime, timezone, timedelta

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

CLI = "/usr/sbin/r3mini-socks5"
BACKEND = "/usr/libexec/r3mini-socks5.rb"
SERVICE = "/etc/init.d/r3mini-socks5"
# 第 2 版的服务（只跑仅 IPv4 的两个进程）；第 3 版起 SOCKS5 整个由 SERVICE 提供。
OLD_SERVICE = "/etc/init.d/r3mini-socks5-v4"
MENU = "/usr/share/luci/menu.d/luci-app-r3mini-socks5.json"
ACL = "/usr/share/rpcd/acl.d/luci-app-r3mini-socks5.json"
VIEW_DIR = "/www/luci-static/resources/view/services"
VIEW_SOURCE = "/www/luci-static/resources/view/services/r3mini-socks5.js"
STATE = "/etc/r3mini-socks5"
SETTINGS = STATE + "/settings.json"
HOOK = "/etc/openclash/custom/openclash_custom_overwrite.sh"
RCD_LINK = "/etc/rc.d/S99r3mini-socks5"
OLD_RCD_LINK = "/etc/rc.d/S99r3mini-socks5-v4"
# 旧版留下、新版不再需要的文件：安装时删除，回滚时按备份恢复。
LEGACY = ("/usr/libexec/r3mini-socks5-ipv4.rb", VIEW_SOURCE, OLD_SERVICE)

BEGIN = b"# BEGIN R3MINI-SOCKS5"
END = b"# END R3MINI-SOCKS5"
HOOK_BLOCK = BEGIN + b'\n/usr/sbin/r3mini-socks5 hook "$CONFIG_FILE" || exit 0\n' + END + b"\n"
TZ = timezone(timedelta(hours=8))

SNAPSHOT_GLOBS = (
    "/etc/init.d/r3mini-socks5*",
    "/etc/openclash/*.yaml",
    HOOK,
    "/usr/sbin/r3mini-*",
    "/usr/libexec/r3mini-*",
    "/usr/share/luci/menu.d/luci-app-r3mini-*",
    "/usr/share/rpcd/acl.d/luci-app-r3mini-*",
    VIEW_DIR + "/r3mini-*.js",
)


def fail(code: str) -> None:
    raise SystemExit(code)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def connect(host: str, key: Path | None):
    import paramiko

    known = Path.home() / ".ssh" / "known_hosts"
    if not known.is_file() or host not in paramiko.HostKeys(str(known)):
        fail("PINNED_HOST_KEY_MISSING")
    client = paramiko.SSHClient()
    client.load_host_keys(str(known))
    client.set_missing_host_key_policy(paramiko.RejectPolicy())
    if key is not None:
        if not key.is_file():
            fail("SSH_KEY_MISSING")
        try:
            client.connect(host, username="root", key_filename=str(key), look_for_keys=False,
                           allow_agent=False, timeout=8, banner_timeout=8, auth_timeout=8)
            return client
        except paramiko.AuthenticationException:
            client.close()
            fail("SSH_KEY_LOGIN_FAILED")
        except Exception:  # noqa: BLE001
            client.close()
            fail("SSH_CONNECTION_OR_PIN_FAILED")
    private = (ROOT / "docs" / "私密" / "商家交付信息.md").read_text(encoding="utf-8")
    for password in dict.fromkeys([""] + re.findall(r"`([^`\s]{1,80})`", private)):
        client = paramiko.SSHClient()
        client.load_host_keys(str(known))
        client.set_missing_host_key_policy(paramiko.RejectPolicy())
        try:
            client.connect(host, username="root", password=password, look_for_keys=False,
                           allow_agent=False, timeout=8, banner_timeout=8, auth_timeout=8)
            return client
        except paramiko.AuthenticationException:
            client.close()
        except Exception:  # noqa: BLE001
            client.close()
            fail("SSH_CONNECTION_OR_PIN_FAILED")
    fail("SSH_LOGIN_FAILED")


def run(client, command: str, *, data: bytes | None = None, timeout: int = 90, check: bool = True):
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    if data is not None:
        stdin.channel.sendall(data)
        stdin.channel.shutdown_write()
    out = stdout.read()
    err = stderr.read()
    code = stdout.channel.recv_exit_status()
    if check and code:
        fail("REMOTE_COMMAND_FAILED: " + command[:120] + " :: " + err.decode("utf-8", "replace")[:400])
    return code, out, err


def text(client, command: str, **kwargs) -> str:
    return run(client, command, **kwargs)[1].decode("utf-8", "replace").strip()


def identity(client, host: str) -> None:
    board = json.loads(text(client, "ubus call system board"))
    address = text(client, "uci -q get network.lan.ipaddr")
    if board.get("board_name") != "bananapi,bpi-r3-mini" or address != host:
        fail("ROUTER_IDENTITY_MISMATCH")


def runtime_path(client) -> str:
    source = text(client, "uci -q get 'openclash.@overwrite[0].config_path' 2>/dev/null || "
                          "uci -q get openclash.config.config_path")
    name = PurePosixPath(source).name
    if not name.endswith((".yaml", ".yml")):
        fail("OPENCLASH_RUNTIME_PATH_INVALID")
    return "/etc/openclash/" + name


def snapshot(client, runtime: str) -> dict:
    globs = " ".join(SNAPSHOT_GLOBS)
    script = (
        "for f in " + globs + "; do "
        '[ -f "$f" ] || continue; '
        'if [ -x "$f" ]; then p=755; else p=644; fi; '
        "printf '%s\\t%s\\t%s\\n' \"$f\" \"$p\" "
        "\"$(sha256sum \"$f\" | cut -d' ' -f1)\"; done | sort"
    )
    result = {}
    for line in text(client, script).splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            result[parts[0]] = {"mode": parts[1], "sha256": parts[2]}
    if runtime not in result:
        fail("RUNTIME_NOT_FOUND")
    return result


def is_module_path(path: str) -> bool:
    return (path in (CLI, BACKEND, SERVICE, MENU, ACL, *LEGACY)
            or (path.startswith(VIEW_DIR + "/r3mini-socks5") and path.endswith(".js")))


def assert_outside(before: dict, after: dict, runtime: str) -> None:
    def outside(state):
        return {p: v for p, v in state.items() if not (is_module_path(p) or p in (HOOK, runtime))}
    if outside(before) != outside(after):
        fail("PROTECTED_FILES_CHANGED")


def hook_without_block(original: bytes) -> bytes:
    if original.count(BEGIN) != original.count(END) or original.count(BEGIN) > 1:
        fail("HOOK_MARKER_INVALID")
    base = re.sub(rb"(?m)^" + re.escape(BEGIN) + rb"\r?\n.*?^" + re.escape(END) + rb"(?:\r?\n|$)",
                  b"", original, flags=re.S)
    if BEGIN in base or END in base:
        fail("HOOK_MARKER_INVALID")
    return base


def hook_insert(base: bytes, block: bytes) -> bytes:
    exits = list(re.finditer(rb"(?m)^[ \t]*exit[ \t]+0[ \t]*(?:\r?\n|$)", base))
    if not exits or base[exits[-1].end():].strip():
        fail("HOOK_FINAL_EXIT_ZERO_MISSING")
    index = exits[-1].start()
    return base[:index] + block + base[index:]


def hook_with_block(original: bytes) -> bytes:
    return hook_insert(hook_without_block(original), HOOK_BLOCK)


def own_block(data: bytes) -> bytes | None:
    """取出覆写脚本里本模块那一段（含首尾标记行），没有就返回 None。"""
    m = re.search(rb"(?ms)^" + re.escape(BEGIN) + rb"\r?\n.*?^" + re.escape(END) + rb"[^\n]*(?:\n|$)", data)
    if not m:
        return None
    block = m.group(0)
    return block if block.endswith(b"\n") else block + b"\n"


def upload(client, path: str, data: bytes, mode: str) -> None:
    if not (is_module_path(path) or path in (HOOK, SETTINGS)):
        fail("UNMANAGED_WRITE_REFUSED")
    quoted = shlex.quote(path)
    script = f'''set -eu
umask 077
mkdir -p {shlex.quote(str(PurePosixPath(path).parent))}
t={quoted}.r3mini-socks5.$$.new
trap 'rm -f "$t"' EXIT HUP INT TERM
cat > "$t"
[ "$(sha256sum "$t" | cut -d' ' -f1)" = {shlex.quote(digest(data))} ]
chmod {mode} "$t"
mv -f "$t" {quoted}
trap - EXIT HUP INT TERM
'''
    run(client, "sh -c " + shlex.quote(script), data=data)


def clear_luci(client) -> None:
    run(client, '''for p in /tmp/luci-indexcache* /tmp/luci-modulecache/*; do
  if [ -f "$p" ] || [ -L "$p" ]; then rm -f "$p"; fi
done
/etc/init.d/rpcd reload >/dev/null 2>&1''', check=False)


def view_files() -> tuple[str, bytes, bytes]:
    """返回（设备上的视图路径, 视图内容, 指向它的菜单）。文件名带内容指纹，浏览器不会拿旧缓存。"""
    view = (HERE / "router" / VIEW_SOURCE.lstrip("/")).read_bytes()
    stem = "r3mini-socks5-" + digest(view)[:10]
    menu = json.loads((HERE / "router" / MENU.lstrip("/")).read_text(encoding="utf-8"))
    for entry in menu.values():
        entry["action"]["path"] = "services/" + stem
    menu_bytes = (json.dumps(menu, ensure_ascii=False, indent="\t") + "\n").encode("utf-8")
    return f"{VIEW_DIR}/{stem}.js", view, menu_bytes


def local_files() -> list[tuple[str, bytes, str]]:
    files = []
    for path, mode in ((CLI, "755"), (BACKEND, "755"), (SERVICE, "755"), (ACL, "644")):
        local = HERE / "router" / path.lstrip("/")
        if not local.is_file():
            fail("LOCAL_MODULE_FILE_MISSING: " + str(local))
        files.append((path, local.read_bytes(), mode))
    view_path, view, menu = view_files()
    files.append((MENU, menu, "644"))
    files.append((view_path, view, "644"))
    return files


def remote_views(client) -> list[str]:
    listing = text(client, f"ls {VIEW_DIR}/r3mini-socks5*.js 2>/dev/null || true")
    return [p for p in listing.split() if p.endswith(".js")]


def backup(client, host: str, runtime: str) -> str:
    stamp = datetime.now(TZ).strftime("%Y%m%dT%H%M%S")
    directory = f"{STATE}/install-backup-{stamp}"
    paths = sorted(set((CLI, BACKEND, SERVICE, MENU, ACL, *LEGACY, *remote_views(client))))
    script = f'''set -eu
umask 077
mkdir -p {shlex.quote(directory)}/module
cp -p {shlex.quote(runtime)} {shlex.quote(directory)}/runtime.yaml
cp -p {shlex.quote(HOOK)} {shlex.quote(directory)}/overwrite.sh
for p in {' '.join(shlex.quote(p) for p in paths)}; do
  [ -f "$p" ] || continue
  mkdir -p {shlex.quote(directory)}/module"${{p%/*}}"
  cp -p "$p" {shlex.quote(directory)}/module"$p"
done
if [ -f {SETTINGS} ]; then cp -p {SETTINGS} {shlex.quote(directory)}/settings.json; else : > {shlex.quote(directory)}/settings.absent; fi
if [ -L {OLD_RCD_LINK} ]; then : > {shlex.quote(directory)}/rcd.enabled; fi
if [ -L {RCD_LINK} ]; then : > {shlex.quote(directory)}/rcd-socks5.enabled; fi
printf '%s\\n' {shlex.quote(host)} > {shlex.quote(directory)}/host
printf '%s\\n' {shlex.quote(runtime)} > {shlex.quote(directory)}/runtime.path
'''
    run(client, "sh -c " + shlex.quote(script))
    return directory


def install(client, host: str, args) -> None:
    identity(client, host)
    runtime = runtime_path(client)
    before = snapshot(client, runtime)
    hook = hook_with_block(run(client, "cat " + shlex.quote(HOOK))[1])
    files = local_files()
    directory = backup(client, host, runtime)
    print("BACKUP_DIR=" + directory, flush=True)
    try:
        for path, data, mode in sorted(files, key=lambda item: item[0] == BACKEND):
            upload(client, path, data, mode)
        keep = {path for path, _data, _mode in files}
        # 第 2 版的服务先停掉、取消自启再删，让出它占着的内部端口；SOCKS5 入站由下面的 apply 接过去。
        run(client, f"if [ -x {OLD_SERVICE} ]; then {OLD_SERVICE} stop; {OLD_SERVICE} disable; fi; true", check=False)
        stale = [p for p in (*LEGACY, *remote_views(client)) if p not in keep]
        if stale:
            run(client, "rm -f " + " ".join(shlex.quote(p) for p in stale))
        run(client, f"ruby -c {BACKEND} >/dev/null && sh -n {CLI} && sh -n {SERVICE}")
        run(client, f"mkdir -p {STATE} && chmod 700 {STATE}")
        hook_mode = before.get(HOOK, {}).get("mode") or "755"
        upload(client, HOOK, hook, hook_mode)
        run(client, "sh -n " + shlex.quote(HOOK))
        run(client, f"{SERVICE} enable")
        clear_luci(client)
        status = json.loads(text(client, CLI + " status", timeout=60))
        if status.get("enabled"):
            applied = json.loads(text(client, CLI + " apply", timeout=120, check=False) or "{}")
            if applied.get("ok") is not True:
                fail("APPLY_FAILED: " + str(applied.get("error")))
            status = applied
        after = snapshot(client, runtime)
        assert_outside(before, after, runtime)
        print("INSTALL_OK enabled=%s applied=%s ipv4_only=%s exit=%s error=%s" % (
            str(status.get("enabled")).lower(), str(status.get("applied")).lower(),
            str(status.get("ipv4_only")).lower(), (status.get("exit") or {}).get("now"), status.get("error")), flush=True)
    except BaseException:
        print("INSTALL_FAILED_BACKUP=" + directory, flush=True)
        raise


def verify(client, host: str, args) -> None:
    identity(client, host)
    runtime = runtime_path(client)
    now = snapshot(client, runtime)
    for path, data, mode in local_files():
        item = now.get(path)
        if not item or item["sha256"] != digest(data) or item["mode"] != mode:
            fail("INSTALLED_MODULE_HASH_OR_MODE_MISMATCH: " + path)
    leftovers = [p for p in LEGACY if p in now]
    if leftovers:
        fail("LEGACY_FILES_PRESENT: " + " ".join(leftovers))
    hook = run(client, "cat " + shlex.quote(HOOK))[1]
    if hook_with_block(hook) != hook:
        fail("INSTALLED_HOOK_MISMATCH")
    if run(client, f"[ -L {RCD_LINK} ]", check=False)[0] != 0:
        fail("SERVICE_NOT_ENABLED")
    status = json.loads(text(client, CLI + " status", timeout=60))
    if status.get("ok") is not True or not isinstance(status.get("enabled"), bool):
        fail("STATUS_SCHEMA_INVALID")
    if status.get("error"):
        fail("STATUS_ERROR: " + str(status.get("error")))
    targets = json.loads(text(client, CLI + " targets", timeout=60))
    if targets.get("ok") is not True or not isinstance(targets.get("nodes"), list):
        fail("TARGETS_SCHEMA_INVALID")
    print("VERIFY_OK enabled=%s applied=%s ipv4_only=%s exit=%s groups=%d nodes=%d" % (
        str(status.get("enabled")).lower(), str(status.get("applied")).lower(), str(status.get("ipv4_only")).lower(),
        (status.get("exit") or {}).get("now"), len(targets.get("groups") or []), len(targets.get("nodes") or [])),
        flush=True)


def rollback(client, host: str, args) -> None:
    if not args.backup:
        fail("BACKUP_REQUIRED")
    identity(client, host)
    directory = args.backup.rstrip("/")
    if not re.fullmatch(re.escape(STATE) + r"/install-backup-[0-9]{8}T[0-9]{6}", directory):
        fail("BACKUP_PATH_REFUSED")
    runtime = text(client, "cat " + shlex.quote(directory + "/runtime.path"))
    if runtime != runtime_path(client) or text(client, "cat " + shlex.quote(directory + "/host")) != host:
        fail("BACKUP_IDENTITY_OR_RUNTIME_MISMATCH")
    if run(client, f"[ -d {shlex.quote(directory)}/module ]", check=False)[0] != 0:
        fail("BACKUP_HAS_NO_MODULE_COPY")
    paths = sorted(set((CLI, BACKEND, SERVICE, MENU, ACL, *LEGACY, *remote_views(client))))
    d = shlex.quote(directory)
    script = f'''set -eu
for svc in {SERVICE} {OLD_SERVICE}; do
  [ -x "$svc" ] && "$svc" stop >/dev/null 2>&1 || true
  [ -x "$svc" ] && "$svc" disable >/dev/null 2>&1 || true
done
rm -f /tmp/r3mini-socks5/ipv4.json /tmp/r3mini-socks5/core/config.yaml /tmp/r3mini-socks5/core/meta.json
if [ -f {d}/settings.json ]; then cp -p {d}/settings.json {SETTINGS}; else rm -f {SETTINGS}; fi
for p in {' '.join(shlex.quote(p) for p in paths)}; do
  if [ -f {d}/module"$p" ]; then cp -p {d}/module"$p" "$p"; else rm -f "$p"; fi
done
if [ -f {d}/rcd.enabled ] && [ -x {OLD_SERVICE} ]; then {OLD_SERVICE} enable; fi
if [ -f {d}/rcd-socks5.enabled ] && [ -x {SERVICE} ]; then {SERVICE} enable; fi
'''
    run(client, "sh -c " + shlex.quote(script))
    # 覆写脚本和 OpenClash 运行配置是几个模块共用的，备份之后别的模块可能改过：都不整份覆盖。
    # 覆写脚本只换回本模块那一段；运行配置交给恢复出来的那一版自己的钩子去改（备份里的 runtime.yaml
    # 只留作手工恢复）。
    current = run(client, "cat " + shlex.quote(HOOK))[1]
    block = own_block(run(client, "cat " + shlex.quote(directory + "/overwrite.sh"))[1])
    base = hook_without_block(current)
    restored = hook_insert(base, block) if block else base
    if restored != current:
        mode = text(client, f"if [ -x {HOOK} ]; then echo 755; else echo 644; fi")
        upload(client, HOOK, restored, mode)
        run(client, "sh -n " + shlex.quote(HOOK))
    hooked = text(client, f"[ -x {CLI} ] && {CLI} hook {shlex.quote(runtime)} 2>/dev/null || true", check=False)
    code = "skipped"
    if '"changed":true' in hooked:
        payload = shlex.quote(json.dumps({"path": runtime}))
        code = text(client, 'S=$(uci -q get openclash.config.dashboard_password); '
                            'P=$(uci -q get openclash.config.cn_port || echo 9090); '
                            'curl -s -o /dev/null -w "%{http_code}" --max-time 30 -H "Authorization: Bearer $S" '
                            '-X PUT "http://127.0.0.1:${P:-9090}/configs?force=true" --data-binary ' + payload, check=False)
    clear_luci(client)
    print("ROLLBACK_OK restored=%s hook_block=%s openclash_reload=%s" % (directory, "kept" if block else "removed", code), flush=True)


def main(argv=None) -> int:
    # 节点名带国旗，Windows 控制台默认 GBK 打不出来。
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description="r3mini-socks5 部署器")
    parser.add_argument("command", choices=["install", "verify", "rollback"])
    parser.add_argument("host")
    parser.add_argument("--backup", default="")
    parser.add_argument("--key", type=Path, default=os.environ.get("R3MINI_SSH_KEY") or None)
    args = parser.parse_args(argv)
    key = args.key if args.key is None or args.key.is_absolute() else ROOT / args.key
    client = connect(args.host, key)
    try:
        {"install": install, "verify": verify, "rollback": rollback}[args.command](client, args.host, args)
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
