"""Offline deployment boundary tests; never imports credentials or opens SSH."""
import contextlib
import fnmatch
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("chatgpt_manage", Path(__file__).with_name("manage.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def fixture():
    payloads = {"/etc/config/openclash": b"config openclash\n", "/etc/init.d/openclash": b"#!/bin/sh\n",
                "/etc/openclash/core/clash_meta": b"fixture-core", m.HOOK: b"#!/bin/sh\nexit 0\n",
                "/etc/openclash/fixture.yaml": b"proxies: []\nrules: []\n"}
    snap = {}
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz") as tf:
        for path, data in payloads.items():
            mode = 0o755 if path == "/etc/init.d/openclash" else 0o644
            info = tarfile.TarInfo(path.lstrip("/"))
            info.mode, info.size = mode, len(data)
            tf.addfile(info, io.BytesIO(data))
            snap[path] = {"kind": "F", "mode": format(mode, "o"), "value": m.digest(data)}
    for path in (*m.OWNED, m.STATE):
        snap[path] = {"kind": "N", "mode": "-", "value": "-"}
    archive = buffer.getvalue()
    manifest = {"archive_sha256": m.digest(archive), "archive_entries": len(payloads),
                "snapshot": snap, "runtime": "/etc/openclash/fixture.yaml"}
    return archive, manifest


R3MINI, PI5 = "bananapi,bpi-r3-mini", "raspberrypi,5-model-b"


def fake_device(board, proto, ipaddr, br_lan, mac="88:a2:9e:00:00:01"):
    """run() stand-in for the identity commands. Unset uci options and a missing br-lan exit 1 like
    on the device; br-lan lines copy the Pi's real `ip -4 -o addr show dev br-lan` output."""
    lines = "".join(f"4: br-lan    inet {a}/24 brd 192.0.2.255 scope global br-lan\\       "
                    "valid_lft forever preferred_lft forever\n" for a in br_lan or ())
    outputs = {"ubus call system board": (0, json.dumps({"board_name": board})),
               "uci -q get network.lan.proto": (0, proto) if proto else (1, ""),
               "uci -q get network.lan.ipaddr": (0, ipaddr) if ipaddr else (1, ""),
               "ip -4 -o addr show dev br-lan": (0, lines) if br_lan is not None else (1, ""),
               "cat /sys/class/net/eth0/address": (0, mac)}

    def run(client, command, *, data=None, timeout=45, check=True):
        code, out = outputs[command]
        if check and code:
            m.fail("REMOTE_COMMAND_FAILED")
        return code, (out + "\n").encode(), b""
    return run


def device_client():
    client = mock.MagicMock()
    client.get_transport.return_value.get_remote_server_key.return_value.asbytes.return_value = b"host-key"
    return client


class DeploymentTests(unittest.TestCase):
    def test_fixture_restore_and_hash_tamper(self):
        archive, manifest = fixture()
        self.assertEqual(m.validate_archive(archive, manifest), 5)
        self.assertGreater(m.restore_drill(archive, manifest), 5)
        with self.assertRaisesRegex(RuntimeError, "BACKUP_HASH_MISMATCH"):
            m.validate_archive(archive + b"tampered", manifest)

    def test_missing_explicit_target_fails_before_ssh(self):
        with mock.patch.object(m, "connect", side_effect=AssertionError("unexpected SSH")):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
                m.main(["install"])
        self.assertEqual(result.exception.code, 2)

    def test_scope_excludes_other_configs(self):
        runtime = "/etc/openclash/fixture.yaml"
        for path in ("/etc/config/network", "/etc/config/openclash", "/usr/sbin/r3mini-traffic",
                     "/etc/r3mini-chatgpt-other/settings.json"):
            self.assertFalse(m.scope_path(path, runtime))
        self.assertTrue(m.scope_path(m.STATE + "/backups/example/runtime.yaml", runtime))

    def test_hook_preserves_all_other_bytes_and_is_idempotent(self):
        original = b'#!/bin/sh\n# existing DNS repair\nrepair_dns "$CONFIG_FILE"\n\nexit 0\n'
        installed = m.hook_with_block(original)
        self.assertEqual(m.hook_without_block(installed), original)
        self.assertEqual(m.hook_with_block(installed), installed)
        self.assertLess(installed.index(m.BEGIN), installed.rindex(b"exit 0"))
        with self.assertRaisesRegex(RuntimeError, "HOOK_MARKER_INVALID"):
            m.hook_with_block(original + m.BEGIN)
        with self.assertRaisesRegex(RuntimeError, "HOOK_FINAL_EXIT_ZERO_MISSING"):
            m.hook_with_block(b"#!/bin/sh\necho test\n")

    def test_unmanaged_upload_is_rejected_before_remote_command(self):
        with mock.patch.object(m, "run", side_effect=AssertionError("unexpected command")):
            with self.assertRaisesRegex(RuntimeError, "UNMANAGED_WRITE_REFUSED"):
                m.upload(None, "/etc/config/network", b"changed", "644", "/etc/openclash/fixture.yaml")

    def test_runtime_conflict_aborts_before_any_mutation(self):
        archive, manifest = fixture()
        with mock.patch.object(m, "run", return_value=(42, b"", b"")) as remote:
            with self.assertRaisesRegex(RuntimeError, "ROLLBACK_NONMODULE_RUNTIME_CONFLICT"):
                m.guard_restore(None, manifest, archive)
        self.assertEqual(remote.call_count, 1)
        self.assertIn("deployment-guard", remote.call_args.args[1])
        self.assertNotIn("rm -", remote.call_args.args[1])

    def test_hook_conflict_aborts_without_deleting_files(self):
        archive, manifest = fixture()
        def remote(client, command, **kwargs):
            return (0, b"#!/bin/sh\nnew_user_hook\nexit 0\n", b"") if command.startswith("cat ") else (0, b"", b"")
        with mock.patch.object(m, "run", side_effect=remote) as calls:
            with self.assertRaisesRegex(RuntimeError, "ROLLBACK_NONMODULE_HOOK_CONFLICT"):
                m.guard_restore(None, manifest, archive)
        self.assertTrue(all("rm -" not in call.args[1] for call in calls.call_args_list))

    def test_controller_reload_uses_shipped_curl_backend(self):
        with mock.patch.object(m, "run", return_value=(0, b"", b"")) as calls:
            m.controller_reload(None, "/etc/openclash/fixture.yaml")
        call = calls.call_args
        self.assertIn("unset R3MINI_CHATGPT_ROOT RUBYOPT RUBYLIB", call.args[1])
        self.assertIn("app.validate(p)", call.args[1])
        self.assertIn("app.reload(c,p)", call.args[1])
        self.assertIn(b"require 'yaml'", call.kwargs["data"])
        self.assertIn(b"class R3MiniSiteBench", call.kwargs["data"])

    @unittest.skipUnless(os.name == "nt" and shutil.which("wsl.exe"), "WSL required for real Ruby reload fixture")
    def test_controller_reload_after_both_installed_modules_are_absent(self):
        with mock.patch.object(m, "run", return_value=(0, b"", b"")) as remote:
            m.controller_reload(None, "/etc/openclash/fixture.yaml")
        call = remote.call_args
        command = shlex.split(call.args[1])
        ruby_code = command[command.index("-e") + 1]
        source = call.kwargs["data"].decode("utf-8")
        code = r'''import json, os, pathlib, subprocess, sys, tempfile
payload=json.load(sys.stdin)
with tempfile.TemporaryDirectory(prefix='r3mini-reload-dependency-') as temp:
    root=pathlib.Path(temp)
    for name in ['etc/openclash/core','usr/bin','tmp']:
        (root/name).mkdir(parents=True,exist_ok=True)
    gid=os.getgid() or 65534
    (root/'etc/group').write_text('nogroup:x:'+str(gid)+':\n')
    (root/'expected-gid').write_text(str(gid))
    runtime=root/'etc/openclash/fixture.yaml'
    runtime.write_text(json.dumps({'external-controller':'127.0.0.1:9090','secret':'fixture-secret','proxies':[],'rules':['MATCH,DIRECT']}))
    core=root/'etc/openclash/core/clash_meta'
    core.write_text("""#!/usr/bin/python3
import json, os, sys
from pathlib import Path
root=Path(__file__).resolve().parents[3]
assert os.getgid()==int((root/'expected-gid').read_text())
assert sys.argv[1]=='-t' and sys.argv[2]=='-d' and sys.argv[4]=='-f'
assert Path(sys.argv[5]).is_file()
(root/'validation-proof.json').write_text(json.dumps({'gid':os.getgid(),'egid':os.getegid()}))
""")
    core.chmod(0o755)
    curl=root/'usr/bin/curl'
    curl.write_text("""#!/usr/bin/python3
import json, sys
from pathlib import Path
root=Path(__file__).resolve().parents[2]
args=sys.argv[1:]
assert args[args.index('--request')+1]=='PUT'
header=Path(args[args.index('--header')+1][1:])
body=Path(args[args.index('--data-binary')+1][1:])
assert header.stat().st_mode&0o777==0o600
assert body.stat().st_mode&0o777==0o600
assert 'Authorization: Bearer fixture-secret' in header.read_text()
assert json.loads(body.read_text())['path']==str(root/'etc/openclash/fixture.yaml')
(root/'reload-proof.json').write_text('{"ok":true}')
""")
    curl.chmod(0o755)
    helper=root/'usr/libexec/r3mini-site-bench.rb'
    backend=root/'usr/libexec/r3mini-chatgpt.rb'
    assert not helper.exists() and not backend.exists()
    ruby="ENV['R3MINI_CHATGPT_ROOT']=ARGV.shift\n"+payload['ruby']
    result=subprocess.run(['ruby','-e',ruby,'--',str(root),str(runtime)],input=payload['source'],text=True,capture_output=True,timeout=20)
    assert result.returncode==0, result.stderr
    assert (root/'validation-proof.json').is_file() and (root/'reload-proof.json').is_file()
    assert not helper.exists() and not backend.exists(), 'deployment helper was written to disk'
    print('RELOAD_WITHOUT_INSTALLED_MODULES_REAL_RUBY_OK')
'''
        result = subprocess.run(["wsl.exe", "-d", "Ubuntu", "--", "python3", "-c", code],
                                input=json.dumps({"ruby": ruby_code, "source": source}), text=True,
                                capture_output=True, timeout=35)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("RELOAD_WITHOUT_INSTALLED_MODULES_REAL_RUBY_OK", result.stdout)

    def test_protected_changes_are_not_masked(self):
        archive, manifest = fixture()
        before = manifest["snapshot"]
        changed = dict(before)
        changed["/etc/config/network"] = {"kind": "F", "mode": "644", "value": "changed"}
        with self.assertRaisesRegex(RuntimeError, "PROTECTED_FILES_CHANGED"):
            m.assert_outside(before, changed, manifest["runtime"])

    def test_backup_change_diagnostic_never_outputs_file_or_link_contents(self):
        before = {"/safe/link": {"kind": "L", "mode": "777", "value": "private-target-secret"},
                  "/safe/file": {"kind": "F", "mode": "600", "value": "a" * 64}}
        after = {"/safe/link": {"kind": "L", "mode": "777", "value": "new-target-secret"},
                 "/safe/file": {"kind": "F", "mode": "640", "value": "b" * 64}}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertTrue(m.report_backup_changes(before, after, {"core_pid": ["1"]}, {"core_pid": ["2"]},
                                                     {"credential": "old-secret"}, {"credential": "new-secret"}))
        self.assertNotIn("private-target-secret", output.getvalue())
        self.assertNotIn("new-target-secret", output.getvalue())
        self.assertNotIn("old-secret", output.getvalue())
        self.assertIn("BACKUP_SNAPSHOT_CHANGED", output.getvalue())
        self.assertIn("BACKUP_HEALTH_CHANGED", output.getvalue())
        self.assertIn("BACKUP_IDENTITY_CHANGED", output.getvalue())

    def test_benchmark_helper_is_executable_managed_file(self):
        files = {path: mode for path, _, mode in m.local_files()}
        self.assertEqual(files[m.BENCHMARK], "755")
        self.assertEqual(len(files), 6)

    def test_production_pid_probe_filters_exact_runtime_without_global_pidof(self):
        with mock.patch.object(m, "text", return_value="123 456") as remote:
            self.assertEqual(m.production_core_pids(None, "/etc/openclash/fixture.yaml"), ["123", "456"])
        command = remote.call_args.args[1]
        self.assertIn("args[index+1] == runtime", command)
        self.assertIn("/proc/[0-9]*/cmdline", command)
        self.assertNotIn("pidof", command)
        with mock.patch.object(m, "text", return_value="not-a-pid"):
            with self.assertRaisesRegex(RuntimeError, "PRODUCTION_CORE_PID_INVALID"):
                m.production_core_pids(None, "/etc/openclash/fixture.yaml")

    @unittest.skipUnless(os.name == "nt" and shutil.which("wsl.exe"), "WSL required for real /proc fixture")
    def test_production_pid_probe_with_real_isolated_proc_fixture(self):
        runtime = "/etc/openclash/offline-fixture.yaml"
        with mock.patch.object(m, "text", return_value="") as remote:
            m.production_core_pids(None, runtime)
        command = remote.call_args.args[1]
        code = '''import json, subprocess, sys
command=json.load(sys.stdin)
children=[]
try:
    for runtime in ['/etc/openclash/offline-fixture.yaml','/tmp/isolated/config.yaml']:
        children.append(subprocess.Popen(['/etc/openclash/clash','-c','import time; time.sleep(15)','-f',runtime], executable=sys.executable))
    result=subprocess.check_output(['sh','-c',command],text=True).split()
    assert str(children[0].pid) in result, 'production fixture missing'
    assert str(children[1].pid) not in result, 'isolated fixture included'
    print('PRODUCTION_CORE_PROC_FIXTURE_OK')
finally:
    for child in children:
        child.terminate(); child.wait(timeout=3)
'''
        result = subprocess.run(["wsl.exe", "-d", "Ubuntu", "--", "python3", "-c", code],
                                input=json.dumps(command), text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PRODUCTION_CORE_PROC_FIXTURE_OK", result.stdout)

    def test_backup_dpapi_disk_roundtrip_and_drill(self):
        archive, base = fixture()
        health = {"services": {"openclash": 1}, "core_pid": ["123"]}
        identity = {"board": "bananapi,bpi-r3-mini", "mac": "00:00:00:00:00:01",
                    "lan": "192.0.2.1", "host_key_sha256": "f" * 64}
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(m, "BACKUPS", Path(temp)), \
                mock.patch.object(m, "identity", return_value=identity), \
                mock.patch.object(m, "runtime_path", return_value=base["runtime"]), \
                mock.patch.object(m, "snapshot", return_value=base["snapshot"]), \
                mock.patch.object(m, "health", return_value=health), \
                mock.patch.object(m, "run", return_value=(0, archive, b"")), \
                mock.patch.object(m, "connect", side_effect=AssertionError("unexpected SSH")):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                path, manifest, data = m.backup(None, "192.0.2.1")
                m.check_backup(path)
            self.assertEqual(data, archive)
            self.assertEqual(m.load_backup(path)[0], manifest)
            envelope = m.manifest_path(path).read_text(encoding="utf-8")
            self.assertNotIn("192.0.2.1", envelope)
            self.assertNotIn("fixture.yaml", envelope)
            self.assertIn("BACKUP_CHECK_OK", output.getvalue())
            self.assertIn("SCOPED_RESTORE_DRILL_OK", output.getvalue())

    @contextlib.contextmanager
    def ssh_fixture(self, pinned=True):
        """Throwaway home with known_hosts and a fresh test key; the private delivery doc does not exist."""
        import paramiko
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ed25519
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / ".ssh").mkdir()
            (home / ".ssh/known_hosts").write_text("pinned-by-test\n")
            key = home / "id_ed25519_test"
            key.write_bytes(ed25519.Ed25519PrivateKey.generate().private_bytes(
                serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH, serialization.NoEncryption()))
            client = mock.MagicMock()
            with mock.patch.object(Path, "home", return_value=home), mock.patch.object(m, "ROOT", home / "no-project"), \
                    mock.patch("paramiko.HostKeys", return_value={"192.0.2.1": object()} if pinned else {}), \
                    mock.patch("paramiko.SSHClient", return_value=client):
                yield home, key, client

    def test_key_login_uses_only_that_key_and_keeps_pinned_host_policy(self):
        import paramiko
        with self.ssh_fixture() as (home, key, client):
            self.assertIs(m.connect("192.0.2.1", key), client)
        self.assertEqual(client.connect.call_count, 1)
        self.assertEqual(client.connect.call_args.args, ("192.0.2.1",))
        kwargs = client.connect.call_args.kwargs
        self.assertEqual((kwargs["username"], kwargs["key_filename"], kwargs["look_for_keys"], kwargs["allow_agent"]),
                         ("root", str(key), False, False))
        self.assertFalse({"password", "passphrase", "pkey"} & set(kwargs))
        client.load_host_keys.assert_called_once_with(str(home / ".ssh/known_hosts"))
        self.assertIsInstance(client.set_missing_host_key_policy.call_args.args[0], paramiko.RejectPolicy)

    def test_key_login_failures_never_fall_back_to_passwords(self):
        import paramiko
        with self.ssh_fixture() as (home, key, client):
            garbage = home / "not-a-key"
            garbage.write_text("not a private key\n")
            client.connect.side_effect = paramiko.AuthenticationException("denied")
            for path, token in ((home / "missing", "SSH_KEY_MISSING"), (garbage, "SSH_KEY_INVALID"), (key, "SSH_KEY_LOGIN_FAILED")):
                with self.assertRaisesRegex(RuntimeError, "^" + token + "$"):
                    m.connect("192.0.2.1", path)
            self.assertEqual(client.connect.call_count, 1)
            client.connect.side_effect = paramiko.SSHException("Server '192.0.2.1' not found in known_hosts")
            with self.assertRaisesRegex(RuntimeError, "^SSH_CONNECTION_OR_PIN_FAILED$"):
                m.connect("192.0.2.1", key)
            self.assertEqual(client.connect.call_count, 2)
            self.assertEqual(client.close.call_count, 2)
        with self.ssh_fixture(pinned=False) as (home, key, client):
            with self.assertRaisesRegex(RuntimeError, "^PINNED_HOST_KEY_MISSING$"):
                m.connect("192.0.2.1", key)
            client.connect.assert_not_called()

    def test_every_device_subcommand_uses_key_option_or_env(self):
        key = Path("keys") / "id_ed25519_test"
        env = {k: v for k, v in os.environ.items() if k != "R3MINI_SSH_KEY"}
        for action in ("backup", "install", "verify", "rollback"):
            client = mock.MagicMock()
            with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(m, "connect", return_value=client) as connect, \
                    mock.patch.object(m, action) as handler:
                self.assertEqual(m.main([action, "192.0.2.1", "--key", str(key)]), 0)
            connect.assert_called_once_with("192.0.2.1", key)
            handler.assert_called_once()
            client.close.assert_called_once()
        with mock.patch.dict(os.environ, dict(env, R3MINI_SSH_KEY=str(key)), clear=True), \
                mock.patch.object(m, "connect", return_value=mock.MagicMock()) as connect, mock.patch.object(m, "verify"):
            m.main(["verify", "192.0.2.1", "--host", "192.0.2.2"])
            self.assertEqual(connect.call_args_list, [mock.call("192.0.2.1", key), mock.call("192.0.2.2", key)])
            connect.reset_mock()
            m.main(["verify", "192.0.2.1", "--key", "other-key"])
            connect.assert_called_once_with("192.0.2.1", Path("other-key"))
        with mock.patch.dict(os.environ, dict(env, R3MINI_SSH_KEY=""), clear=True), \
                mock.patch.object(m, "connect", return_value=mock.MagicMock()) as connect, mock.patch.object(m, "verify"):
            m.main(["verify", "192.0.2.1"])
            connect.assert_called_once_with("192.0.2.1", None)

    def verify_fixture(self, settings, steam, uu=None):
        local = {path: {"kind": "F", "mode": mode, "value": m.digest(data)} for path, data, mode in m.local_files()}
        manifest = {"runtime": "/etc/openclash/fixture.yaml", "snapshot": {"/etc/config/network": {"kind": "F", "mode": "644", "value": "a" * 64}},
                    "health": {"services": {"openclash": 1}, "core_pid": ["1"]}}
        status = {"ok": True, "enabled": settings["enabled"], "applied": settings["enabled"], "error": None}
        if steam is not None:
            status["steam_direct"] = steam
        status["uu_direct"] = uu or {"enabled": settings.get("uu_direct", False), "applied": settings.get("uu_direct", False)}
        hook = m.hook_with_block(b"#!/bin/sh\nexit 0\n")

        def text(client, command, **kwargs):
            return json.dumps(settings) if command == "cat " + m.SETTINGS else json.dumps(status)
        return manifest, mock.patch.multiple(m, snapshot=mock.DEFAULT, run=mock.DEFAULT, text=mock.DEFAULT, health=mock.DEFAULT,
                                             luci_checks=mock.DEFAULT), dict(manifest["snapshot"], **local), hook, text

    def test_verify_checks_saved_steam_switch_against_runtime(self):
        cases = (({"enabled": False}, {"enabled": False, "applied": False}, "steam_direct=false"),
                 ({"enabled": False, "steam_direct": True}, {"enabled": True, "applied": True}, "steam_direct=true"),
                 ({"enabled": False, "steam_direct": True}, {"enabled": True, "applied": False}, "LIVE_ROUTING_STATE_MISMATCH"),
                 ({"enabled": False}, {"enabled": True, "applied": True}, "STATUS_SCHEMA_INVALID"),
                 ({"enabled": False}, None, "STATUS_SCHEMA_INVALID"))
        for settings, steam, expected in cases:
            manifest, patches, snap, hook, text = self.verify_fixture(settings, steam)
            output = io.StringIO()
            with patches as fake, contextlib.redirect_stdout(output):
                fake["snapshot"].return_value = snap
                fake["run"].return_value = (0, hook, b"")
                fake["text"].side_effect = text
                fake["health"].return_value = manifest["health"]
                if expected.startswith("steam_direct="):
                    m.verify(None, "192.0.2.1", None, manifest)
                    self.assertIn("VERIFY_OK files=6 enabled=false " + expected + " uu_direct=false", output.getvalue())
                else:
                    with self.assertRaisesRegex(RuntimeError, "^" + expected + "$"):
                        m.verify(None, "192.0.2.1", None, manifest)

    def test_verify_checks_saved_uu_switch_against_runtime(self):
        cases = (({"enabled": False, "uu_direct": True}, {"enabled": True, "applied": True}, "uu_direct=true"),
                 ({"enabled": False, "uu_direct": True}, {"enabled": True, "applied": False}, "LIVE_ROUTING_STATE_MISMATCH"),
                 ({"enabled": False}, {"enabled": True, "applied": True}, "STATUS_SCHEMA_INVALID"))
        for settings, uu, expected in cases:
            manifest, patches, snap, hook, text = self.verify_fixture(settings, {"enabled": False, "applied": False}, uu)
            output = io.StringIO()
            with patches as fake, contextlib.redirect_stdout(output):
                fake["snapshot"].return_value = snap
                fake["run"].return_value = (0, hook, b"")
                fake["text"].side_effect = text
                fake["health"].return_value = manifest["health"]
                if expected.startswith("uu_direct="):
                    m.verify(None, "192.0.2.1", None, manifest)
                    self.assertIn("VERIFY_OK files=6 enabled=false steam_direct=false " + expected, output.getvalue())
                else:
                    with self.assertRaisesRegex(RuntimeError, "^" + expected + "$"):
                        m.verify(None, "192.0.2.1", None, manifest)

    def test_luci_acl_check_grants_exactly_the_two_steam_commands(self):
        acl = json.loads((m.HERE / "router" / m.ACL.lstrip("/")).read_text(encoding="utf-8"))["luci-app-r3mini-chatgpt"]
        granted = [pattern for mode in ("read", "write") for pattern in acl[mode]["file"]]
        menu = {"children": {"admin": {"children": {"services": {"children": {"r3mini-chatgpt": {
            "action": {"path": "services/r3mini-chatgpt"}, "depends": {"acl": ["luci-app-r3mini-chatgpt"]}}}}}}}}
        asked = {}

        def text(client, command, **kwargs):
            if "luci-indexcache" in command:
                return "@@INDEX\n" + json.dumps(menu)
            if command.startswith("ubus call session access "):
                target = json.loads(shlex.split(command)[-1])["object"]
                # rpcd matches file exec ACL entries with fnmatch on "command arg ...".
                asked[target] = any(fnmatch.fnmatchcase(target, pattern) for pattern in granted)
                return json.dumps({"access": asked[target]})
            if command.startswith("ubus call session create"):
                return json.dumps({"ubus_rpc_session": "fixture"})
            if command.startswith("ubus call session "):
                return "{}"
            return json.dumps({"result": [0, {"code": 0, "stdout": "{}"}]})
        view = (m.HERE / "router" / m.VIEW.lstrip("/")).read_bytes()
        with mock.patch.object(m, "run", return_value=(0, view, b"")), mock.patch.object(m, "text", side_effect=text), \
                contextlib.redirect_stdout(io.StringIO()):
            m.luci_checks(None)
        self.assertEqual({k: v for k, v in asked.items() if "steam-direct" in k},
                         {m.CLI + " steam-direct 0": True, m.CLI + " steam-direct 1": True, m.CLI + " steam-direct 2": False})
        self.assertEqual({k: v for k, v in asked.items() if "uu-direct" in k},
                         {m.CLI + " uu-direct 0": True, m.CLI + " uu-direct 1": True, m.CLI + " uu-direct 2": False})
        self.assertFalse(asked[m.CLI + " hook x.yaml"])

    def test_identity_accepts_static_r3mini_and_dhcp_or_static_pi(self):
        host = "192.0.2.1"
        for board, proto, ipaddr, br_lan in ((R3MINI, "static", host, [host]),
                                             (PI5, "dhcp", None, ["192.0.2.9", host]),
                                             (PI5, "static", host, [host])):
            with self.subTest(board=board, proto=proto), \
                    mock.patch.object(m, "run", side_effect=fake_device(board, proto, ipaddr, br_lan)):
                # Same keys as before, so R3 Mini backup manifests made by the old check still match.
                self.assertEqual(m.identity(device_client(), host),
                                 {"board": board, "mac": "88:a2:9e:00:00:01", "lan": host,
                                  "host_key_sha256": m.digest(b"host-key")})

    def test_identity_rejects_wrong_board_or_address(self):
        host = "192.0.2.1"
        cases = (("unknown board", "bananapi,bpi-r3mini", "static", host, [host]),
                 ("dhcp, host not on br-lan", PI5, "dhcp", None, ["192.0.2.9"]),
                 ("dhcp, host is only a prefix", PI5, "dhcp", None, ["192.0.2.10"]),
                 ("dhcp, no br-lan", PI5, "dhcp", None, None),
                 ("dhcp ignores a stale lan.ipaddr", PI5, "dhcp", host, ["192.0.2.9"]),
                 ("static, lan.ipaddr unset", R3MINI, "static", None, [host]),
                 ("static, other lan.ipaddr", R3MINI, "static", "192.0.2.9", [host]),
                 ("static ignores br-lan", PI5, "static", "192.0.2.9", [host]),
                 ("proto unset is checked like static", R3MINI, None, "192.0.2.9", [host]))
        for name, board, proto, ipaddr, br_lan in cases:
            with self.subTest(name), mock.patch.object(m, "run", side_effect=fake_device(board, proto, ipaddr, br_lan)):
                with self.assertRaisesRegex(RuntimeError, "^ROUTER_IDENTITY_MISMATCH$"):
                    m.identity(device_client(), host)

    def test_backup_identity_of_dhcp_pi_matches_on_reconnect(self):
        host = "192.0.2.1"
        with mock.patch.object(m, "run", side_effect=fake_device(PI5, "dhcp", None, [host])):
            saved = json.loads(json.dumps(m.identity(device_client(), host)))
        manifest = {"host": host, "identity": saved, "runtime": "/etc/openclash/fixture.yaml"}
        with mock.patch.object(m, "load_backup", return_value=(manifest, b"")), \
                mock.patch.object(m, "runtime_path", return_value=manifest["runtime"]):
            with mock.patch.object(m, "run", side_effect=fake_device(PI5, "dhcp", None, [host])):
                self.assertEqual(m.require_backup(device_client(), host, "fixture")[0], manifest)
            with mock.patch.object(m, "run", side_effect=fake_device(PI5, "dhcp", None, [host], mac="88:a2:9e:00:00:02")):
                with self.assertRaisesRegex(RuntimeError, "^BACKUP_IDENTITY_MISMATCH$"):
                    m.require_backup(device_client(), host, "fixture")


if __name__ == "__main__":
    unittest.main(verbosity=2)
