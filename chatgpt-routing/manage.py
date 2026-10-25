"""ChatGPT routing module manager. Run --help; all device targets are explicit."""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timedelta, timezone
import fnmatch
import hashlib
import io
import ipaddress
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import sys
import tarfile
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
BACKUPS = ROOT / "backups" / "router"
TZ = timezone(timedelta(hours=8))
CLI = "/usr/sbin/r3mini-chatgpt"
BACKEND = "/usr/libexec/r3mini-chatgpt.rb"
BENCHMARK = "/usr/libexec/r3mini-site-bench.rb"
MENU = "/usr/share/luci/menu.d/luci-app-r3mini-chatgpt.json"
ACL = "/usr/share/rpcd/acl.d/luci-app-r3mini-chatgpt.json"
VIEW = "/www/luci-static/resources/view/services/r3mini-chatgpt.js"
STATE = "/etc/r3mini-chatgpt"
SETTINGS = STATE + "/settings.json"
HOOK = "/etc/openclash/custom/openclash_custom_overwrite.sh"
OWNED = (CLI, BACKEND, BENCHMARK, MENU, ACL, VIEW)
BEGIN = b"# BEGIN R3MINI-CHATGPT"
END = b"# END R3MINI-CHATGPT"
HOOK_BLOCK = BEGIN + b'\n/usr/sbin/r3mini-chatgpt hook "$CONFIG_FILE" || exit 1\n' + END + b"\n"
ARCHIVE_ROOTS = ("/etc", "/usr/share/openclash", "/usr/lib/opkg/status",
                 "/usr/lib/lua/luci/controller/openclash.lua", "/usr/lib/lua/luci/view/openclash",
                 "/usr/share/adspower-ph")
ARCHIVE_GLOBS = ("/usr/sbin/r3mini-*", "/usr/sbin/adspower-ph-*", "/usr/libexec/r3mini-*",
                 "/usr/share/luci/menu.d/*r3mini*", "/usr/share/rpcd/acl.d/*r3mini*",
                 "/www/luci-static/resources/view/system/r3mini-*",
                 "/www/luci-static/resources/view/network/r3mini-*",
                 "/www/luci-static/resources/view/status/r3mini-*",
                 "/www/luci-static/resources/view/services/r3mini-*")
SNAP_DIRS = ("/etc/config", "/etc/init.d", "/etc/rc.d", "/etc/crontabs",
             "/usr/share/luci/menu.d", "/usr/share/rpcd/acl.d",
             "/www/luci-static/resources/view/system", "/www/luci-static/resources/view/network",
             "/www/luci-static/resources/view/status", "/www/luci-static/resources/view/services")


def fail(code):
    raise RuntimeError(code)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def dpapi(data, decrypt=False):
    import win32crypt
    if decrypt:
        return win32crypt.CryptUnprotectData(data, None, None, None, 0)[1]
    return win32crypt.CryptProtectData(data, "R3 Mini ChatGPT routing backup", None, None, None, 0)


def connect(host):
    import paramiko
    known = Path.home() / ".ssh" / "known_hosts"
    if not known.is_file() or host not in paramiko.HostKeys(str(known)):
        fail("PINNED_HOST_KEY_MISSING")
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
        except Exception:
            client.close()
            fail("SSH_CONNECTION_OR_PIN_FAILED")
    fail("SSH_LOGIN_FAILED")


def run(client, command, *, data=None, timeout=45, check=True):
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    if data is not None:
        stdin.channel.sendall(data)
    stdin.channel.shutdown_write()
    out, err = stdout.read(), stderr.read()
    code = stdout.channel.recv_exit_status()
    if check and code:
        fail("REMOTE_COMMAND_FAILED")
    return code, out, err


def text(client, command, **kwargs):
    return run(client, command, **kwargs)[1].decode("utf-8", "strict").strip()


def identity(client, host):
    board = json.loads(text(client, "ubus call system board"))
    address = text(client, "uci -q get network.lan.ipaddr")
    mac = text(client, "cat /sys/class/net/eth0/address").lower()
    if board.get("board_name") != "bananapi,bpi-r3-mini" or address != host:
        fail("ROUTER_IDENTITY_MISMATCH")
    if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
        fail("ROUTER_IDENTITY_INVALID")
    key = client.get_transport().get_remote_server_key()
    return {"board": board["board_name"], "mac": mac, "lan": address,
            "host_key_sha256": digest(key.asbytes())}


def runtime_path(client):
    source = text(client, '''p=$(uci -q get 'openclash.@overwrite[0].config_path' 2>/dev/null || true)
if [ -z "$p" ]; then p=$(uci -q get openclash.overwrite.config_path 2>/dev/null || true); fi
if [ -z "$p" ]; then p=$(uci -q get openclash.config.config_path); fi
printf '%s' "$p"''')
    name = PurePosixPath(source).name
    if not name or name in (".", "..") or not name.endswith((".yaml", ".yml")) or "\n" in name:
        fail("OPENCLASH_RUNTIME_PATH_INVALID")
    return "/etc/openclash/" + name


def scope_path(path, runtime):
    return path in (*OWNED, HOOK, runtime) or path == STATE or path.startswith(STATE + "/")


def snapshot(client, runtime):
    patterns = [d + "/*" for d in SNAP_DIRS] + list(ARCHIVE_GLOBS)
    exact = list((*OWNED, HOOK, runtime, STATE))
    script = "require 'digest/sha2'\npatterns=" + json.dumps(patterns) + "\nexact=" + json.dumps(exact) + r'''
paths=patterns.flat_map { |pattern| Dir.glob(pattern) } + exact
paths += Dir.glob('/etc/r3mini-chatgpt/**/*', File::FNM_DOTMATCH).reject { |p| ['.','..'].include?(File.basename(p)) } if File.directory?('/etc/r3mini-chatgpt') && !File.symlink?('/etc/r3mini-chatgpt')
paths.uniq.sort.each do |p|
  raise 'invalid path' if p =~ /[\t\r\n]/
  begin
    st=File.lstat(p)
  rescue Errno::ENOENT
    puts ['N',p,'-','-'].join("\t")
    next
  end
  mode=(st.mode & 07777).to_s(8)
  if st.symlink?
    value=File.readlink(p)
    raise 'invalid link' if value =~ /[\t\r\n]/
    puts ['L',p,mode,value].join("\t")
  elsif st.file?
    puts ['F',p,mode,Digest::SHA256.file(p).hexdigest].join("\t")
  elsif st.directory?
    puts ['D',p,mode,'-'].join("\t")
  end
end
'''
    out = text(client, "ruby -", data=script.encode(), timeout=90)
    result = {}
    for line in out.splitlines():
        kind, path, mode, value = line.split("\t", 3)
        result[path] = {"kind": kind, "mode": mode, "value": value}
    return result


def services(client):
    data = json.loads(text(client, "ubus call service list"))
    return {name: sum(bool(i.get("running")) for i in (item.get("instances") or {}).values())
            for name, item in data.items()}


def production_core_pids(client, runtime):
    ruby = r'''runtime=ARGV.fetch(0)
pids=[]
Dir.glob('/proc/[0-9]*/cmdline').each do |file|
  begin
    args=File.binread(file).split("\0")
    next unless args[0].to_s.start_with?('/etc/openclash/')
    core=File.basename(args[0].to_s)
    next unless ['clash','clash_meta','clash_tun','clash_game','mihomo'].include?(core)
    index=args.index('-f')
    next unless index && args[index+1] == runtime
    pids << file.split('/')[2]
  rescue SystemCallError, IOError
    next
  end
end
puts pids.sort_by(&:to_i).join(' ')
'''
    value = text(client, "ruby -e " + shlex.quote(ruby) + " -- " + shlex.quote(runtime))
    pids = value.split()
    if not all(re.fullmatch(r"[0-9]+", pid) for pid in pids):
        fail("PRODUCTION_CORE_PID_INVALID")
    return pids


def health(client, runtime=None):
    runtime = runtime or runtime_path(client)
    return {"services": services(client),
            "core_pid": production_core_pids(client, runtime)}


def safe_snapshot_item(item):
    if item is None:
        return {"kind": "N", "mode": "-", "sha256": None}
    kind, value = item.get("kind"), item.get("value", "")
    sha = value if kind == "F" and re.fullmatch(r"[0-9a-f]{64}", value) else digest(value.encode()) if kind == "L" else None
    return {"kind": kind, "mode": item.get("mode"), "sha256": sha}


def report_backup_changes(before, after, old_health, new_health, old_identity, new_identity):
    """Emit only metadata/hashes. Never print link targets, runtime bodies, credentials or service environments."""
    changed = False
    for path in sorted(before.keys() | after.keys()):
        if before.get(path) != after.get(path):
            changed = True
            print("BACKUP_SNAPSHOT_CHANGED " + json.dumps({"path": path, "before": safe_snapshot_item(before.get(path)),
                  "after": safe_snapshot_item(after.get(path))}, ensure_ascii=True), flush=True)
    for label, first, second in (("health", old_health, new_health), ("identity", old_identity, new_identity)):
        for field in sorted(first.keys() | second.keys()):
            if first.get(field) != second.get(field):
                changed = True
                encoded_old = json.dumps(first.get(field), sort_keys=True).encode()
                encoded_new = json.dumps(second.get(field), sort_keys=True).encode()
                print("BACKUP_" + label.upper() + "_CHANGED " + json.dumps({"field": field,
                      "before_sha256": digest(encoded_old), "after_sha256": digest(encoded_new)}, ensure_ascii=True), flush=True)
    return changed


def archive_members(archive):
    tf = tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz")
    members = {}
    for member in tf.getmembers():
        name = member.name.lstrip("/")
        while name.startswith("./"):
            name = name[2:]
        if not name or ".." in PurePosixPath(name).parts or "\x00" in name:
            tf.close()
            fail("BACKUP_MEMBER_PATH_INVALID")
        members["/" + name.rstrip("/")] = member
    return tf, members


def archive_data(tf, members, path):
    member = members.get(path)
    if member is None:
        fail("BACKUP_SCOPED_MEMBER_MISSING")
    stream = tf.extractfile(member) if member.isfile() or member.islnk() else None
    return stream.read() if stream else b""


def validate_archive(archive, manifest):
    if digest(archive) != manifest["archive_sha256"]:
        fail("BACKUP_HASH_MISMATCH")
    tf, members = archive_members(archive)
    try:
        if len(members) != manifest["archive_entries"]:
            fail("BACKUP_ENTRY_COUNT_MISMATCH")
        for required in ("/etc/config/openclash", "/etc/init.d/openclash", "/etc/openclash/core/clash_meta"):
            if required not in members:
                fail("BACKUP_REQUIRED_MEMBER_MISSING")
        checked = 0
        for path, item in manifest["snapshot"].items():
            covered = any(path == p or path.startswith(p + "/") for p in ARCHIVE_ROOTS) or any(
                fnmatch.fnmatchcase(path, p) for p in ARCHIVE_GLOBS)
            if item["kind"] == "N" or not covered:
                continue
            member = members.get(path)
            kind_matches = member is not None and ((item["kind"] == "F" and (member.isfile() or member.islnk())) or
                (item["kind"] == "L" and member.issym()) or (item["kind"] == "D" and member.isdir()))
            if not kind_matches or format(member.mode, "o") != item["mode"]:
                actual_mode = format(member.mode, "o") if member else "absent"
                actual_kind = ("F" if member.isfile() else "L" if member.issym() else "H" if member.islnk() else "D" if member.isdir() else "other") if member else "N"
                print("BACKUP_METADATA_MISMATCH " + json.dumps({"path": path, "expected_kind": item["kind"], "expected_mode": item["mode"], "actual_kind": actual_kind, "actual_mode": actual_mode}, ensure_ascii=True), flush=True)
                fail("BACKUP_MEMBER_METADATA_MISMATCH")
            if item["kind"] == "F" and digest(archive_data(tf, members, path)) != item["value"]:
                fail("BACKUP_MEMBER_HASH_MISMATCH")
            if item["kind"] == "L" and member.linkname != item["value"]:
                fail("BACKUP_LINK_MISMATCH")
            checked += 1
        return checked
    finally:
        tf.close()


def scoped_snapshot(manifest):
    return {p: v for p, v in manifest["snapshot"].items() if scope_path(p, manifest["runtime"])}


def restore_drill(archive, manifest):
    """Restore bytes/existence in isolation; POSIX mode/link metadata stays in a tar ledger on Windows."""
    tf, members = archive_members(archive)
    expected = scoped_snapshot(manifest)
    with tempfile.TemporaryDirectory(prefix="r3mini-chatgpt-restore-") as temp:
        root = Path(temp)
        ledger = {}

        def restore():
            for path, item in expected.items():
                target = root.joinpath(*PurePosixPath(path).parts[1:])
                if item["kind"] == "N":
                    if target.is_file():
                        target.unlink()
                    ledger.pop(path, None)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                if item["kind"] == "D":
                    target.mkdir(exist_ok=True)
                else:
                    target.write_bytes(archive_data(tf, members, path) if item["kind"] == "F" else item["value"].encode())
                ledger[path] = dict(item)

        try:
            restore()
            for path, item in expected.items():
                target = root.joinpath(*PurePosixPath(path).parts[1:])
                if item["kind"] != "D":
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(b"simulated change")
                    ledger[path] = {"kind": "F", "mode": "600", "value": "changed"}
            restore()
            for path, item in expected.items():
                target = root.joinpath(*PurePosixPath(path).parts[1:])
                if item["kind"] == "N":
                    if target.exists() or path in ledger:
                        fail("SCOPED_RESTORE_EXISTENCE_FAILED")
                elif item["kind"] == "F":
                    if digest(target.read_bytes()) != item["value"]:
                        fail("SCOPED_RESTORE_HASH_FAILED")
                if item["kind"] != "N" and ledger[path] != item:
                    fail("SCOPED_RESTORE_METADATA_FAILED")
        finally:
            tf.close()
    return len(expected)


def manifest_path(archive_path):
    return Path(str(archive_path).removesuffix(".tar.gz.dpapi") + ".manifest.json")


def load_backup(path):
    path = Path(path).resolve()
    if path.suffixes[-3:] != [".tar", ".gz", ".dpapi"]:
        fail("BACKUP_PATH_INVALID")
    envelope = json.loads(manifest_path(path).read_text(encoding="utf-8"))
    if envelope.get("format") != "r3mini-chatgpt-dpapi-v1":
        fail("BACKUP_FORMAT_UNSUPPORTED")
    manifest = json.loads(dpapi(base64.b64decode(envelope["payload_dpapi"]), True))
    encrypted = path.read_bytes()
    if digest(encrypted) != manifest["cipher_sha256"]:
        fail("BACKUP_CIPHER_HASH_MISMATCH")
    plain = dpapi(encrypted, True)
    validate_archive(plain, manifest)
    return manifest, plain


def backup(client, host):
    ident = identity(client, host)
    runtime = runtime_path(client)
    before = snapshot(client, runtime)
    baseline_health = health(client, runtime)
    if not baseline_health["core_pid"] or not baseline_health["services"].get("openclash"):
        fail("OPENCLASH_NOT_RUNNING")
    script = "set -eu\nset --\n"
    for path in ARCHIVE_ROOTS:
        quoted = shlex.quote(path)
        script += f'[ ! -e {quoted} ] || set -- "$@" {quoted}\n'
    script += "for p in " + " ".join(ARCHIVE_GLOBS) + '; do [ ! -e "$p" ] || set -- "$@" "$p"; done\n'
    script += 'tar -czf - "$@"\n'
    archive = run(client, "sh -s", data=script.encode(), timeout=240)[1]
    after = snapshot(client, runtime)
    after_health = health(client, runtime)
    after_identity = identity(client, host)
    if report_backup_changes(before, after, baseline_health, after_health, ident, after_identity):
        fail("BASELINE_CHANGED_DURING_BACKUP")
    encrypted = dpapi(archive)
    if dpapi(encrypted, True) != archive:
        fail("BACKUP_DPAPI_ROUNDTRIP_FAILED")
    stamp = datetime.now(TZ).strftime("%Y%m%d-%H%M%S-%f")
    manifest = {"host": host, "created": datetime.now(TZ).isoformat(), "identity": ident,
                "runtime": runtime, "snapshot": before, "health": baseline_health,
                "archive_sha256": digest(archive), "cipher_sha256": digest(encrypted),
                "archive_bytes": len(archive)}
    tf, members = archive_members(archive)
    manifest["archive_entries"] = len(members)
    tf.close()
    checked = validate_archive(archive, manifest)
    drill = restore_drill(archive, manifest)
    BACKUPS.mkdir(parents=True, exist_ok=True)
    path = BACKUPS / f"router-backup-{stamp}-{host}-before-chatgpt.tar.gz.dpapi"
    with path.open("xb") as stream:
        stream.write(encrypted)
    envelope = {"format": "r3mini-chatgpt-dpapi-v1", "archive_sha256": digest(archive),
                "payload_dpapi": base64.b64encode(dpapi(json.dumps(manifest, ensure_ascii=False).encode())).decode()}
    with manifest_path(path).open("x", encoding="utf-8") as stream:
        json.dump(envelope, stream, ensure_ascii=False, indent=2)
    loaded, _ = load_backup(path)
    if loaded != manifest:
        fail("BACKUP_MANIFEST_ROUNDTRIP_FAILED")
    print(f"BACKUP_OK entries={manifest['archive_entries']} hashes={checked} scoped={drill}", flush=True)
    print("BACKUP_SHA256=" + digest(archive), flush=True)
    print("BACKUP_PATH=" + str(path), flush=True)
    print("SCOPED_RESTORE_DRILL_OK permission_metadata=tar link_metadata=tar", flush=True)
    return path, manifest, archive


def latest_backup(host):
    matches = sorted(BACKUPS.glob(f"router-backup-*-{host}-before-chatgpt.tar.gz.dpapi"))
    if not matches:
        fail("BACKUP_NOT_FOUND")
    return matches[-1]


def check_backup(path):
    manifest, archive = load_backup(path)
    count = restore_drill(archive, manifest)
    print(f"BACKUP_CHECK_OK entries={manifest['archive_entries']} scoped={count} sha256={digest(archive)}", flush=True)
    print("SCOPED_RESTORE_DRILL_OK permission_metadata=tar link_metadata=tar", flush=True)


def hook_without_block(original):
    if original.count(BEGIN) != original.count(END) or original.count(BEGIN) > 1:
        fail("HOOK_MARKER_INVALID")
    base = re.sub(rb"(?m)^" + re.escape(BEGIN) + rb"\r?\n.*?^" + re.escape(END) + rb"(?:\r?\n|$)",
                  b"", original, flags=re.S)
    if BEGIN in base or END in base:
        fail("HOOK_MARKER_INVALID")
    return base


def hook_with_block(original):
    base = hook_without_block(original)
    exits = list(re.finditer(rb"(?m)^[ \t]*exit[ \t]+0[ \t]*(?:\r?\n|$)", base))
    if not exits or base[exits[-1].end():].strip():
        fail("HOOK_FINAL_EXIT_ZERO_MISSING")
    index = exits[-1].start()
    return base[:index] + HOOK_BLOCK + base[index:]


def upload(client, path, data, mode, runtime):
    if not scope_path(path, runtime) or path == STATE:
        fail("UNMANAGED_WRITE_REFUSED")
    directory = str(PurePosixPath(path).parent)
    quoted = shlex.quote(path)
    script = f'''set -eu
umask 077
mkdir -p {shlex.quote(directory)}
t={quoted}.r3mini-chatgpt.$$.new
trap 'rm -f "$t"' EXIT HUP INT TERM
cat > "$t"
[ "$(sha256sum "$t" | cut -d' ' -f1)" = {shlex.quote(digest(data))} ]
chmod {mode} "$t"
mv -f "$t" {quoted}
trap - EXIT HUP INT TERM
'''
    run(client, "sh -c " + shlex.quote(script), data=data)


def clear_luci(client):
    run(client, '''for p in /tmp/luci-indexcache* /tmp/luci-modulecache/*; do
  if [ -f "$p" ] || [ -L "$p" ]; then rm -f "$p"; fi
done
/etc/init.d/rpcd reload >/dev/null 2>&1''')


def outside(snapshot_data, runtime):
    return {path: item for path, item in snapshot_data.items() if not scope_path(path, runtime)}


def assert_outside(before, after, runtime):
    if outside(before, runtime) != outside(after, runtime):
        fail("PROTECTED_FILES_CHANGED")


def require_backup(client, host, path, fresh=False):
    manifest, archive = load_backup(path)
    if manifest["host"] != host or identity(client, host) != manifest["identity"]:
        fail("BACKUP_IDENTITY_MISMATCH")
    if runtime_path(client) != manifest["runtime"]:
        fail("BACKUP_RUNTIME_CHANGED")
    if fresh:
        age = time.time() - datetime.fromisoformat(manifest["created"]).timestamp()
        if age < -300 or age > 7200:
            fail("BACKUP_TOO_OLD")
        if snapshot(client, manifest["runtime"]) != manifest["snapshot"] or health(client, manifest["runtime"]) != manifest["health"]:
            fail("BACKUP_NO_LONGER_MATCHES_PRODUCTION")
    return manifest, archive


def controller_reload(client, runtime):
    # Reuse the shipped backend's packaged-Ruby/curl implementation, even after removing it remotely.
    ruby = r'''backend_source,benchmark_source=STDIN.read.split("\n__R3MINI_DEPLOY_BENCHMARK__\n",2)
raise 'missing deployment helper' unless benchmark_source
eval(benchmark_source, TOPLEVEL_BINDING, '(deployment-benchmark)')
eval(backend_source, TOPLEVEL_BINDING, '(deployment-backend)')
app=R3MiniChatGPT::App.new
# The installed helper may correctly be absent after restoring a pre-install snapshot.
# Use the same trusted helper implementation already loaded from this deployment bundle.
app.define_singleton_method(:core_gid) { R3MiniSiteBench.new.core_gid }
p=ARGV.fetch(0)
c=YAML.safe_load(File.binread(p), permitted_classes: [], permitted_symbols: [], aliases: true)
app.validate(p)
app.reload(c,p)
'''
    source = (HERE / "router" / BACKEND.lstrip("/")).read_bytes()
    helper = (HERE / "router" / BENCHMARK.lstrip("/")).read_bytes()
    source += b"\n__R3MINI_DEPLOY_BENCHMARK__\n" + helper
    command = "unset R3MINI_CHATGPT_ROOT RUBYOPT RUBYLIB; exec ruby -e " + shlex.quote(ruby) + " -- " + shlex.quote(runtime) + " >/dev/null 2>&1"
    run(client, command, data=source, timeout=90)


def guard_restore(client, manifest, archive):
    """Whole-file replay is permitted only while all non-module bytes/semantics still match."""
    tf, members = archive_members(archive)
    try:
        runtime = manifest["runtime"]
        baseline = archive_data(tf, members, runtime)
        source = (HERE / "router" / BACKEND.lstrip("/")).read_bytes()
        ruby = r'''source,saved=STDIN.read.split("\n__R3MINI_DEPLOY_DATA__\n",2)
eval(source, TOPLEVEL_BINDING, '(deployment-guard)')
app=R3MiniChatGPT::App.new
old=YAML.safe_load(saved, permitted_classes: [], permitted_symbols: [], aliases: true)
now=app.runtime(ARGV.fetch(0))
disabled={'enabled'=>false,'rules'=>[]}
exit(app.transform(old,disabled) == app.transform(now,disabled) ? 0 : 42)
'''
        command = "unset R3MINI_CHATGPT_ROOT RUBYOPT RUBYLIB; exec ruby -e " + shlex.quote(ruby) + " -- " + shlex.quote(runtime)
        payload = source + b"\n__R3MINI_DEPLOY_DATA__\n" + baseline
        if run(client, command, data=payload, check=False, timeout=60)[0]:
            fail("ROLLBACK_NONMODULE_RUNTIME_CONFLICT")
        current_hook = run(client, "cat " + shlex.quote(HOOK), check=False)[1]
        old_hook = archive_data(tf, members, HOOK) if manifest["snapshot"][HOOK]["kind"] != "N" else b"#!/bin/sh\n\nexit 0\n"
        current_base = hook_without_block(current_hook)
        allowed = (hook_without_block(old_hook),)
        if manifest["snapshot"][HOOK]["kind"] == "N":
            allowed += (b"",)
        if current_base not in allowed:
            fail("ROLLBACK_NONMODULE_HOOK_CONFLICT")
    finally:
        tf.close()


def restore_scoped(client, manifest, archive, disable=True):
    runtime = manifest["runtime"]
    before = snapshot(client, runtime)
    old_health = health(client, runtime)
    guard_restore(client, manifest, archive)
    if disable and before.get(CLI, {}).get("kind") == "F":
        run(client, shlex.quote(CLI) + " disable >/dev/null 2>&1", timeout=90)
    guard_restore(client, manifest, archive)
    tf, members = archive_members(archive)
    scoped = scoped_snapshot(manifest)
    # This fixed directory belongs exclusively to this module, including transaction backups.
    run(client, "rm -rf -- /etc/r3mini-chatgpt")
    try:
        for path, item in sorted(scoped.items(), key=lambda entry: (entry[0].count("/"), entry[0])):
            quoted = shlex.quote(path)
            if item["kind"] == "N":
                if path != STATE:
                    run(client, "rm -f -- " + quoted)
            elif item["kind"] == "D":
                run(client, f"mkdir -p {quoted}; chmod {item['mode']} {quoted}")
            elif item["kind"] == "L":
                run(client, "mkdir -p " + shlex.quote(str(PurePosixPath(path).parent)) + "; rm -f -- " + quoted +
                    "; ln -s " + shlex.quote(item["value"]) + " " + quoted)
            elif item["kind"] == "F":
                upload(client, path, archive_data(tf, members, path), item["mode"], runtime)
            else:
                fail("BACKUP_SCOPED_KIND_UNSUPPORTED")
    finally:
        tf.close()
    controller_reload(client, runtime)
    clear_luci(client)
    after = snapshot(client, runtime)
    assert_outside(before, after, runtime)
    actual = {p: v for p, v in after.items() if scope_path(p, runtime)}
    if actual != scoped:
        fail("SCOPED_ROLLBACK_BASELINE_MISMATCH")
    if health(client, runtime) != old_health:
        fail("ROLLBACK_SERVICE_OR_CORE_CHANGED")
    print(f"SCOPED_ROLLBACK_OK items={len(scoped)} baseline_sha256={digest(json.dumps(scoped, sort_keys=True).encode())}", flush=True)


def menu_node(data):
    node = data
    for component in ("admin", "services", "r3mini-chatgpt"):
        node = node.get("children", {}).get(component, {})
    return node


def luci_checks(client):
    expected = (HERE / "router" / VIEW.lstrip("/")).read_bytes()
    remote = run(client, "curl -fsS --max-time 15 http://127.0.0.1/luci-static/resources/view/services/r3mini-chatgpt.js")[1]
    if digest(remote) != digest(expected):
        fail("LUCI_VIEW_FETCH_MISMATCH")
    output = text(client, '''curl -sS --max-time 15 -o /dev/null http://127.0.0.1/cgi-bin/luci/
for p in /tmp/luci-indexcache.*.json; do [ ! -f "$p" ] || { printf '@@INDEX\\n'; cat "$p"; printf '\\n'; }; done''')
    nodes = []
    for block in output.split("@@INDEX\n")[1:]:
        try:
            nodes.append(menu_node(json.loads(block)))
        except json.JSONDecodeError:
            continue
    if not any(n.get("action", {}).get("path") == "services/r3mini-chatgpt" and
               "luci-app-r3mini-chatgpt" in n.get("depends", {}).get("acl", []) for n in nodes):
        fail("LUCI_MENU_NOT_REGISTERED")
    acl = json.loads((HERE / "router" / ACL.lstrip("/")).read_text(encoding="utf-8"))
    session = json.loads(text(client, "ubus call session create '{\"timeout\":60}'"))["ubus_rpc_session"]

    def ubus(method, params):
        output = text(client, "ubus call session " + method + " " + shlex.quote(json.dumps(params)))
        return json.loads(output or "{}")

    try:
        for group, spec in acl.items():
            for mode in ("read", "write"):
                ubus("grant", {"ubus_rpc_session": session, "scope": "access-group", "objects": [[group, mode]]})
                for scope, objects in spec.get(mode, {}).items():
                    pairs = [[p, f] for p, functions in objects.items() for f in functions]
                    ubus("grant", {"ubus_rpc_session": session, "scope": scope, "objects": pairs})
        for command, allowed in ((CLI + " status", True), (CLI + " apply source.yaml " + "a" * 16, True),
                                 (CLI + " benchmark source.yaml", True), (CLI + " benchmark-status source.yaml", True),
                                 (CLI + " save {}", True), (CLI + " remove " + "a" * 12, True),
                                 (CLI + " set-enabled " + "a" * 12 + " 0", True),
                                 (CLI + " disable", True), (CLI + " hook x.yaml", False), ("/bin/true", False)):
            access = ubus("access", {"ubus_rpc_session": session, "scope": "file", "object": command, "function": "exec"})
            if bool(access.get("access")) != allowed:
                fail("LUCI_ACL_SCOPE_MISMATCH")
        payload = {"jsonrpc": "2.0", "id": 1, "method": "call", "params": [session, "file", "exec", {"command": CLI, "params": ["status"]}]}
        result = json.loads(text(client, "curl -fsS --max-time 30 http://127.0.0.1/ubus -H 'Content-Type: application/json' --data-binary @-", data=json.dumps(payload).encode()))
        values = result.get("result", [])
        if len(values) != 2 or values[0] != 0 or values[1].get("code") != 0:
            fail("LUCI_ACL_STATUS_EXEC_FAILED")
        json.loads(values[1]["stdout"])
    finally:
        ubus("destroy", {"ubus_rpc_session": session})
    print("LUCI_VIEW_MENU_ACL_OK", flush=True)


def local_files():
    files = []
    for path in OWNED:
        local = HERE / "router" / path.lstrip("/")
        if not local.is_file():
            fail("LOCAL_MODULE_FILE_MISSING")
        files.append((path, local.read_bytes(), "755" if path in (CLI, BACKEND, BENCHMARK) else "644"))
    return files


def verify(client, host, args, manifest=None):
    if manifest is None:
        manifest, _ = require_backup(client, host, args.backup or latest_backup(host))
    runtime = manifest["runtime"]
    now = snapshot(client, runtime)
    assert_outside(manifest["snapshot"], now, runtime)
    for path, data, mode in local_files():
        expected = {"kind": "F", "mode": mode, "value": digest(data)}
        if now.get(path) != expected:
            fail("INSTALLED_MODULE_HASH_OR_MODE_MISMATCH")
    hook = run(client, "cat " + shlex.quote(HOOK))[1]
    if hook_with_block(hook) != hook:
        fail("INSTALLED_HOOK_MISMATCH")
    settings = json.loads(text(client, "cat " + SETTINGS))
    if not isinstance(settings.get("enabled"), bool):
        fail("SETTINGS_SCHEMA_INVALID")
    status = json.loads(text(client, CLI + " status", timeout=60))
    if not isinstance(status, dict) or not status.get("ok") or status.get("enabled") != settings["enabled"]:
        fail("STATUS_SCHEMA_INVALID")
    if status.get("error") or bool(status.get("applied")) != settings["enabled"]:
        fail("LIVE_ROUTING_STATE_MISMATCH")
    if health(client, runtime) != manifest["health"]:
        fail("ORIGINAL_SERVICES_OR_CORE_CHANGED")
    luci_checks(client)
    print("PROTECTED_FILES_AND_CORE_OK", flush=True)
    print("VERIFY_OK files=" + str(len(OWNED)) + " enabled=" + str(settings["enabled"]).lower(), flush=True)


def install(client, host, args):
    files = local_files()
    if args.backup:
        manifest, archive = require_backup(client, host, args.backup, fresh=True)
    else:
        _, manifest, archive = backup(client, host)
    runtime = manifest["runtime"]
    original_hook = run(client, "cat " + shlex.quote(HOOK), check=False)[1]
    if manifest["snapshot"][HOOK]["kind"] == "N":
        original_hook = b"#!/bin/sh\n\nexit 0\n"
    hook = hook_with_block(original_hook)
    try:
        for path, data, mode in files:
            upload(client, path, data, mode, runtime)
        run(client, "ruby -c " + BACKEND + " >/dev/null && sh -n " + CLI)
        if manifest["snapshot"][STATE]["kind"] == "N":
            run(client, "mkdir -p " + STATE + "; chmod 700 " + STATE)
        elif manifest["snapshot"][STATE]["kind"] != "D":
            fail("STATE_DIRECTORY_UNEXPECTED_TYPE")
        if run(client, "test -e " + SETTINGS, check=False)[0]:
            initial = {"version": 2, "rules": [], "enabled": False, "source": "lian_li.yaml", "selected": None, "last_action": None, "last_time": None}
            upload(client, SETTINGS, (json.dumps(initial) + "\n").encode(), "600", runtime)
        mode = manifest["snapshot"][HOOK]["mode"] if manifest["snapshot"][HOOK]["kind"] != "N" else "755"
        upload(client, HOOK, hook, mode, runtime)
        run(client, "sh -n " + shlex.quote(HOOK))
        clear_luci(client)
        # Installation never invokes the routing hook or restarts OpenClash.
        after = snapshot(client, runtime)
        if after[runtime] != manifest["snapshot"][runtime]:
            fail("INSTALL_CHANGED_RUNTIME")
        verify(client, host, args, manifest)
        print("INSTALL_OK", flush=True)
    except Exception as install_error:
        code = str(install_error)
        print("INSTALL_FAILED_ROLLBACK_STARTED kind=" + (code if re.fullmatch(r"[A-Z_]+", code) else type(install_error).__name__), flush=True)
        try:
            restore_scoped(client, manifest, archive, disable=False)
        except Exception as rollback_error:
            code = str(rollback_error)
            print("INSTALL_ROLLBACK_FAILED kind=" + (code if re.fullmatch(r"[A-Z_]+", code) else type(rollback_error).__name__), flush=True)
            fail("INSTALL_FAILED_AND_ROLLBACK_FAILED")
        raise


def rollback(client, host, args):
    manifest, archive = require_backup(client, host, args.backup or latest_backup(host))
    restore_drill(archive, manifest)
    guard_restore(client, manifest, archive)
    backup(client, host)
    print("PRE_ROLLBACK_CHECKPOINT_OK", flush=True)
    restore_scoped(client, manifest, archive)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog="Outputs contain safe markers/hashes only. Credentials are read only when connecting. See README.md for the restore boundary.")
    parser.add_argument("action", choices=("backup", "install", "verify", "rollback", "check-backup"))
    parser.add_argument("targets", nargs="*", help="explicit IPv4 HOST...; check-backup also accepts .tar.gz.dpapi paths")
    parser.add_argument("--host", action="append", default=[], help="explicit IPv4 target; repeat for a batch")
    parser.add_argument("--backup", type=Path, help="specific local backup for one target; install checks age and unchanged baseline")
    parser.add_argument("--expected-mac", help="optional additional eth0 identity constraint (one target)")
    args = parser.parse_args(argv)
    targets = args.targets + args.host
    if not targets:
        parser.error("TARGET_REQUIRED: supply HOST... or --host; no default device is selected")
    if args.backup and len(targets) != 1:
        parser.error("BACKUP_REQUIRES_ONE_TARGET")
    if args.expected_mac and len(targets) != 1:
        parser.error("MAC_REQUIRES_ONE_TARGET")
    for target in targets:
        if args.action == "check-backup":
            path = Path(target) if target.endswith(".tar.gz.dpapi") else args.backup or latest_backup(str(ipaddress.IPv4Address(target)))
            check_backup(path)
            continue
        host = str(ipaddress.IPv4Address(target))
        client = connect(host)
        try:
            if args.expected_mac and identity(client, host)["mac"] != args.expected_mac.lower():
                fail("EXPECTED_MAC_MISMATCH")
            if args.action == "backup":
                backup(client, host)
            else:
                globals()[args.action](client, host, args)
        finally:
            client.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        reason = str(error) if isinstance(error, RuntimeError) and re.fullmatch(r"[A-Z0-9_]+", str(error)) else type(error).__name__
        print("OPERATION_FAILED kind=" + reason, flush=True)
        raise SystemExit(1)
