"""Offline deployment boundary tests; never imports credentials or opens SSH."""
import contextlib
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
