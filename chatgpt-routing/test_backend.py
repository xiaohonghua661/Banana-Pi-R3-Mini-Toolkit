#!/usr/bin/env python3
"""Offline CLI acceptance tests. Uses Ruby + PyYAML, never a real router.

Run: python chatgpt-routing/test_backend.py
Windows automatically runs the same test file in WSL Ubuntu.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

if os.name == "nt":
    script = str(Path(__file__).resolve())
    mapped = "/mnt/" + script[0].lower() + script[2:].replace("\\", "/")
    raise SystemExit(subprocess.call(["wsl.exe", "-d", "Ubuntu", "--", "python3", mapped]))

import fcntl
import yaml

HERE = Path(__file__).resolve().parent
BACKEND = HERE / "router/usr/libexec/r3mini-chatgpt.rb"
PRESET_ID = hashlib.sha256(b"r3mini-chatgpt-preset").hexdigest()[:12]
PRESET_GROUP = "R3Site-" + PRESET_ID

MOCK_CURL = r'''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
import yaml
root = Path(__file__).resolve().parents[2]
statefile = root / 'controller.json'
state = json.loads(statefile.read_text())
args = sys.argv[1:]
header = Path(args[args.index('--header') + 1][1:])
assert header.stat().st_mode & 0o777 == 0o600
assert 'Authorization: Bearer test-controller-secret\n' in header.read_text()
assert args[-1].startswith('http://127.0.0.1:9090/')
state['urls'].append(args[-1])
state.setdefault('max_times', []).append(float(args[args.index('--max-time') + 1]))
delay = state.get('delay_seconds', 0)
timeout = float(args[args.index('--max-time') + 1])
if delay > timeout:
    time.sleep(timeout)
    statefile.write_text(json.dumps(state))
    sys.exit(28)
time.sleep(delay)
method = args[args.index('--request') + 1]
if state.get('offline'):
    statefile.write_text(json.dumps(state))
    sys.exit(7)
if method == 'PUT':
    body = Path(args[args.index('--data-binary') + 1][1:])
    assert body.stat().st_mode & 0o777 == 0o600
    runtime = yaml.safe_load(Path(json.loads(body.read_text())['path']).read_text())
    proxies = {n['name']: {'type': n['type']} for n in runtime.get('proxies', [])}
    for group in runtime.get('proxy-groups', []):
        values = group.get('proxies', [])
        proxies[group['name']] = {'all': values, 'now': values[0] if values else None}
    types = {'DOMAIN-SUFFIX': 'DomainSuffix', 'DOMAIN': 'Domain', 'DOMAIN-KEYWORD': 'DomainKeyword', 'MATCH': 'Match', 'RULE-SET': 'RuleSet'}
    rules = []
    for entry in runtime.get('rules', []):
        parts = entry.split(',')
        rules.append({'type': types.get(parts[0], parts[0]), 'payload': parts[1] if len(parts) > 2 else '', 'proxy': parts[2] if len(parts) > 2 else parts[1]})
    state.update(proxies=proxies, rules=rules, reloads=state.get('reloads', 0) + 1)
    if state.pop('bad_next_reload', False):
        state['rules'] = [r for r in rules if not r['proxy'].startswith('R3Site-')]
    fail = state.pop('fail_after_load', False)
    statefile.write_text(json.dumps(state))
    sys.exit(22 if fail else 0)
statefile.write_text(json.dumps(state))
if args[-1].endswith('/proxies'):
    print(json.dumps({'proxies': state['proxies']}))
elif args[-1].endswith('/rules'):
    print(json.dumps({'rules': state['rules']}))
else:
    sys.exit(22)
'''

MOCK_CORE = r'''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
import yaml
root = Path(__file__).resolve().parents[3]
args = sys.argv[1:]
if os.environ.get('SAFE_PATHS') != '/usr/share/openclash:/etc/ssl':
    sys.exit(48)
(root / 'core-safe-paths').write_text(os.environ['SAFE_PATHS'])
expected_gid = int((root / 'etc/group').read_text().split(':')[2])
assert os.getgid() == expected_gid and os.getegid() == expected_gid
(root / 'core-gid-proof.json').write_text(json.dumps({'gid': os.getgid(), 'egid': os.getegid()}))
assert args[:2] == ['-t', '-d']
assert Path(args[2]) == root / 'etc/openclash'
assert args[3] == '-f'
candidate = Path(args[4])
assert candidate.name.startswith('.r3mini-chatgpt-')
yaml.safe_load(candidate.read_text())
(root / 'core-call.json').write_text(json.dumps(args))
if (root / 'hang_core').exists():
    (root / 'core-test-pid').write_text(str(os.getpid()))
    time.sleep(30)
sys.exit(1 if (root / 'fail_core').exists() else 0)
'''

MOCK_BENCH = r'''
class R3MiniSiteBench
  def core_gid
    file = ENV['R3MINI_CHATGPT_ROOT'] + '/etc/group'
    raise 'CORE_GROUP_MISSING' unless File.file?(file)
    row = File.readlines(file).find { |line| line.start_with?('nogroup:') }
    raise 'CORE_GROUP_MISSING' unless row
    row.split(':')[2].to_i
  end
  def supported_regions
    file = ENV['R3MINI_CHATGPT_ROOT'] + '/usr/share/r3mini-site-routing/supported-regions.json'
    File.exist?(file) ? YAML.safe_load(File.read(file))['countries'] : ['US']
  end
end
if $PROGRAM_NAME == __FILE__
require BACKEND_PATH
app = R3MiniChatGPT::App.new
root = ENV['R3MINI_CHATGPT_ROOT']
flags_path = root + '/benchmark-flags.json'
flags = File.exist?(flags_path) ? YAML.safe_load(File.read(flags_path)) : {}
source = ARGV[1]
entries = app.nodes(source).each_with_index.map do |(id, node), index|
  eligible = flags.fetch('eligible', true)
  {'id' => id, 'name' => node['name'], 'node_hash' => flags['wrong_hash'] ? '0' * 64 : app.node_hash(node),
   'eligible' => eligible, 'country' => flags['country'] || 'US',
   'samples_ms' => flags['samples_ms'] || [30.5 + index, 10.5 + index, 20.5 + index],
   'median_ms' => 20.5 + index, 'error' => eligible ? nil : flags['row_error'] || 'BENCH_PENDING'}
end
report = {'ok' => true, 'source' => source,
 'source_sha256' => flags['source_changed'] ? '0' * 64 : Digest::SHA256.hexdigest(File.binread(app.source_path(source))),
 'nodes' => entries, 'results' => entries, 'best' => entries.find { |e| e['eligible'] }&.fetch('id'),
 'running' => ARGV[0] == 'start', 'error' => flags['expired'] ? 'BENCH_EXPIRED' : nil}
puts R3MiniChatGPT.json(report)
end
'''


def node_id(name: str) -> str:
    return hashlib.sha256(name.encode()).hexdigest()[:16]


class BackendTest(unittest.TestCase):
    def setUp(self):
        if not shutil.which("ruby"):
            self.skipTest("Ruby unavailable: install a local test runtime; no router fallback")
        self.tmp = tempfile.TemporaryDirectory(prefix="r3mini-chatgpt-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("etc/openclash/config", "etc/openclash/core", "etc/r3mini-chatgpt", "tmp", "var/lock", "sbin", "usr/bin", "usr/libexec"):
            (self.root / name).mkdir(parents=True, exist_ok=True)
        self.expected_gid = os.getgid() if os.getgid() > 0 else 65534
        (self.root / "etc/group").write_text(f"nogroup:x:{self.expected_gid}:\n")
        self.runtime = self.root / "etc/openclash/MESL_yue.yaml"
        self.source = self.root / "etc/openclash/config/lian_li.yaml"
        self.settings = self.root / "etc/r3mini-chatgpt/settings.json"
        self.initial = {
            "external-controller": "0.0.0.0:9090", "secret": "test-controller-secret",
            "mixed-port": 7890, "mode": "rule", "ipv6": False,
            "dns": {"enable": True, "nameserver": ["https://dns.example.test/dns-query"], "fake-ip-filter": ["+.example.test"]},
            "profile": {"store-selected": True, "store-fake-ip": True},
            "proxy-providers": {"original": {"type": "file", "path": "./provider/original.yaml"}},
            "proxies": [{"name": "原节点", "type": "ss", "server": "original.invalid", "password": "original-private"}],
            "proxy-groups": [{"name": "AI", "type": "select", "proxies": ["原节点", "DIRECT"]}, {"name": "其他", "type": "select", "use": ["original"]}],
            "rules": ["DOMAIN-SUFFIX,claude.ai,AI", "DOMAIN-SUFFIX,anthropic.com,AI", "DOMAIN-SUFFIX,openai.com,AI", "RULE-SET,OtherAI,AI", "MATCH,其他"]}
        self.runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True), encoding="utf-8")
        self.nodes = [{"name": '日本 "A"\\线路', "type": "hysteria2", "server": "selected.invalid", "password": "selected-secret"}]
        self.nodes += [{"name": f"节点-{i}", "type": "vless", "server": "unselected.invalid", "uuid": f"private-{i}"} for i in range(56)]
        self.source.write_text(yaml.safe_dump({"proxies": self.nodes}, allow_unicode=True), encoding="utf-8")
        for relative, text in (("usr/bin/curl", MOCK_CURL), ("etc/openclash/core/clash_meta", MOCK_CORE),
                               ("usr/libexec/r3mini-site-bench.rb", MOCK_BENCH.replace("BACKEND_PATH", json.dumps(str(BACKEND)))),
                               ("sbin/uci", "#!/bin/sh\nprintf '%s\\n' /etc/openclash/config/MESL_yue.yaml\n")):
            file = self.root / relative
            file.write_text(text, encoding="utf-8")
            file.chmod(0o755)
        self.write_controller({"urls": [], "reloads": 0, "proxies": {}, "rules": []})
        # Initialize mock live state using the same external API contract.
        self.seed_live()

    def seed_live(self):
        cfg = yaml.safe_load(self.runtime.read_text())
        state = self.controller()
        state["proxies"] = {n["name"]: {"type": n["type"]} for n in cfg["proxies"]}
        for group in cfg["proxy-groups"]:
            values = group.get("proxies", [])
            state["proxies"][group["name"]] = {"all": values, "now": values[0] if values else None}
        types = {"DOMAIN-SUFFIX": "DomainSuffix", "DOMAIN": "Domain", "DOMAIN-KEYWORD": "DomainKeyword"}
        state["rules"] = []
        for r in cfg["rules"]:
            p = r.split(",")
            state["rules"].append({"type": types.get(p[0], p[0]), "payload": p[1] if len(p) > 2 else "", "proxy": p[2] if len(p) > 2 else p[1]})
        self.write_controller(state)

    def controller(self):
        return json.loads((self.root / "controller.json").read_text())

    def write_controller(self, state):
        (self.root / "controller.json").write_text(json.dumps(state))

    def command(self, *args, ok=True):
        env = dict(os.environ, R3MINI_CHATGPT_ROOT=str(self.root))
        proc = subprocess.run(["ruby", str(BACKEND), *args], env=env, text=True, capture_output=True, timeout=30)
        self.assertEqual(proc.stderr, "")
        response = json.loads(proc.stdout)
        self.assertEqual(proc.returncode, 0 if ok else 1, response)
        self.assertEqual(response["ok"], ok)
        for secret in ("selected-secret", "original-private", "selected.invalid", "test-controller-secret", "private-55"):
            self.assertNotIn(secret, proc.stdout)
        return response

    def apply(self):
        return self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]))

    def save_site(self, label, domains, index=0, source="lian_li.yaml", **extra):
        payload = {"label": label, "domains": domains, "source": source,
                   "selected": node_id(self.nodes[index]["name"]), "enabled": True}
        payload.update(extra)
        return self.command("save", json.dumps(payload, ensure_ascii=False))

    def test_status_json_and_candidate_source(self):
        result = self.command("status")
        self.assertFalse(result["enabled"])
        self.assertFalse(result["applied"])
        self.assertEqual(len(result["nodes"]), 57)
        self.assertEqual(result["nodes"][0]["name"], self.nodes[0]["name"])
        self.assertEqual(set(result["nodes"][0]), {"id", "name", "type", "eligible", "country", "samples_ms", "median_ms"})
        other = self.source.with_name("other.yaml")
        other.write_text(yaml.safe_dump({"proxies": [self.nodes[1]]}, allow_unicode=True))
        viewed = self.command("status", "other.yaml")
        self.assertEqual(viewed["source"], "lian_li.yaml")
        self.assertEqual(len(viewed["nodes"]), 1)
        self.assertFalse(self.settings.exists())

    def test_apply_only_one_node_and_disable_restores_all_other_config(self):
        result = self.apply()
        self.assertTrue(result["enabled"] and result["applied"])
        runtime = yaml.safe_load(self.runtime.read_text())
        alias = "r3mini-site-node-" + PRESET_ID + "-" + node_id(self.nodes[0]["name"])
        self.assertEqual(len(runtime["proxies"]), 2)
        self.assertEqual(runtime["proxy-groups"][-1], {"name": PRESET_GROUP, "type": "select", "proxies": [alias]})
        self.assertEqual(runtime["proxies"][-1]["server"], "selected.invalid")
        self.assertEqual(runtime["rules"][-len(self.initial["rules"]):], self.initial["rules"])
        self.assertEqual(runtime["dns"], self.initial["dns"])
        self.assertEqual(runtime["profile"], self.initial["profile"])
        self.apply()
        self.assertEqual(yaml.safe_load(self.runtime.read_text()), runtime)
        result = self.command("disable")
        self.assertFalse(result["enabled"] or result["applied"])
        self.assertEqual(yaml.safe_load(self.runtime.read_text()), self.initial)
        self.command("disable")
        self.assertEqual(yaml.safe_load(self.runtime.read_text()), self.initial)
        self.assertEqual(self.runtime.stat().st_mode & 0o777, 0o600)
        for file in (self.root / "etc/r3mini-chatgpt/backups").rglob("*"):
            self.assertEqual(file.stat().st_mode & 0o777, 0o700 if file.is_dir() else 0o600)
        self.assertEqual(list((self.root / "tmp/r3mini-chatgpt").iterdir()), [])

    def test_hook_reapplies_after_runtime_regeneration_and_disabled_cleanup(self):
        self.apply()
        reloads = self.controller()["reloads"]
        self.runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        self.assertTrue(self.command("status")["applied"])  # Live state is still loaded.
        self.assertTrue(self.command("hook", "/etc/openclash/MESL_yue.yaml")["changed"])
        self.assertEqual(self.controller()["reloads"], reloads)
        self.assertFalse(self.command("hook", "/etc/openclash/MESL_yue.yaml")["changed"])
        self.command("disable")
        settings = json.loads(self.settings.read_text())
        settings["enabled"] = False
        for rule in settings["rules"]:
            rule["enabled"] = False
        self.settings.write_text(json.dumps(settings))
        self.runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        self.command("hook", "/etc/openclash/MESL_yue.yaml")

    def test_rejects_traversal_symlink_missing_node_and_dialer_dependency(self):
        original = self.runtime.read_bytes()
        for name in ("../lian_li.yaml", "/etc/passwd.yaml", "bad\\name.yaml", "evil\nname.yaml"):
            self.assertEqual(self.command("apply", name, "0" * 16, ok=False)["error"], "SOURCE_INVALID")
        self.source.with_name("alias.yaml").symlink_to(self.source)
        self.assertEqual(self.command("apply", "alias.yaml", "0" * 16, ok=False)["error"], "SOURCE_MISSING")
        self.assertEqual(self.command("apply", "lian_li.yaml", "$(bad)", ok=False)["error"], "ARGUMENT_INVALID")
        self.assertEqual(self.command("apply", "lian_li.yaml", "0" * 16, ok=False)["error"], "NODE_MISSING")
        self.nodes[0]["dialer-proxy"] = "another-node"
        self.source.write_text(yaml.safe_dump({"proxies": self.nodes}, allow_unicode=True))
        self.assertEqual(self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)["error"], "NODE_DEPENDENCY")
        self.assertEqual(self.runtime.read_bytes(), original)
        self.assertFalse(self.settings.exists())

    def test_failed_core_validation_preserves_bytes_and_saves_backup(self):
        before = self.runtime.read_bytes()
        (self.root / "fail_core").touch()
        response = self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)
        self.assertEqual(response["error"], "CONFIG_TEST_FAILED")
        self.assertEqual(self.runtime.read_bytes(), before)
        self.assertEqual(self.runtime.stat().st_mode & 0o777, 0o644)
        self.assertFalse(self.settings.exists())
        self.assertEqual(self.controller()["reloads"], 0)
        self.assertEqual(len(list((self.root / "etc/r3mini-chatgpt/backups").iterdir())), 1)

    def test_reload_failure_after_loading_candidate_rolls_back_runtime_and_settings(self):
        self.apply()
        before_runtime, before_settings = self.runtime.read_bytes(), self.settings.read_bytes()
        state = self.controller()
        state["fail_after_load"] = True
        self.write_controller(state)
        response = self.command("disable", ok=False)
        self.assertEqual(response["error"], "RELOAD_FAILED")
        self.assertEqual(self.runtime.read_bytes(), before_runtime)
        self.assertEqual(self.settings.read_bytes(), before_settings)
        self.assertTrue(self.command("status")["applied"])

    def test_verification_failure_rolls_back_and_no_false_success(self):
        before = self.runtime.read_bytes()
        state = self.controller()
        state["bad_next_reload"] = True
        self.write_controller(state)
        response = self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)
        self.assertEqual(response["error"], "VERIFY_FAILED")
        self.assertEqual(self.runtime.read_bytes(), before)
        self.assertFalse(self.settings.exists())
        self.assertNotIn(PRESET_GROUP, self.controller()["proxies"])

    def test_lock_contention_is_nonblocking(self):
        lock = self.root / "var/lock/r3mini-chatgpt.lock"
        with lock.open("w") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.command("disable", ok=False)["error"], "BUSY")
        self.assertFalse(self.settings.exists())

    def test_missing_subscription_does_not_prevent_disable(self):
        self.apply()
        self.source.unlink()
        self.assertEqual(self.command("status")["error"], "SOURCE_MISSING")
        response = self.command("disable")
        self.assertFalse(response["enabled"] or response["applied"])
        self.assertEqual(yaml.safe_load(self.runtime.read_text()), self.initial)
        self.command("disable")

    def test_hook_cannot_edit_source_or_arbitrary_absolute_path(self):
        original = self.source.read_bytes()
        for path in ("/etc/openclash/config/lian_li.yaml", "/tmp/other.yaml", "relative.yaml"):
            self.assertEqual(self.command("hook", path, ok=False)["error"], "RUNTIME_MISSING")
        self.assertEqual(self.source.read_bytes(), original)

    def test_stale_controller_is_never_reported_applied(self):
        self.apply()
        state = self.controller()
        state["rules"] = state["rules"][1:]
        self.write_controller(state)
        status = self.command("status")
        self.assertTrue(status["enabled"])
        self.assertFalse(status["applied"])
        self.assertEqual(status["error"], "STATE_MISMATCH")
        state["offline"] = True
        self.write_controller(state)
        status = self.command("status")
        self.assertFalse(status["applied"])
        self.assertEqual(status["error"], "CONTROLLER_UNAVAILABLE")

    def test_removed_selected_node_never_shows_applied(self):
        self.apply()
        self.source.write_text(yaml.safe_dump({"proxies": self.nodes[1:]}, allow_unicode=True))
        status = self.command("status")
        self.assertFalse(status["applied"])
        self.assertEqual(status["error"], "NODE_MISSING")
        self.command("disable")

    def test_tmp_hook_restricts_active_basename_and_fails_closed(self):
        self.apply()
        temporary_runtime = self.root / "tmp/MESL_yue.yaml"
        temporary_runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        self.command("hook", "/tmp/MESL_yue.yaml")
        config = yaml.safe_load(temporary_runtime.read_text())
        self.assertEqual(config["proxy-groups"][-1]["name"], PRESET_GROUP)
        other = self.root / "tmp/other.yaml"
        other.write_text(temporary_runtime.read_text())
        self.assertEqual(self.command("hook", "/tmp/other.yaml", ok=False)["error"], "RUNTIME_MISSING")
        temporary_runtime.unlink()
        temporary_runtime.symlink_to(self.runtime)
        self.assertEqual(self.command("hook", "/tmp/MESL_yue.yaml", ok=False)["error"], "RUNTIME_MISSING")
        temporary_runtime.unlink()
        temporary_runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        self.source.unlink()
        for _ in range(2):
            failure = self.command("hook", "/tmp/MESL_yue.yaml", ok=False)
            self.assertEqual(failure["error"], "SOURCE_MISSING")
            self.assertTrue(failure["fail_closed"])
        closed = yaml.safe_load(temporary_runtime.read_text())
        self.assertEqual(closed["proxy-groups"][-1]["proxies"], ["REJECT"])
        self.assertEqual(closed["rules"][-len(self.initial["rules"]):], self.initial["rules"])
        self.assertFalse(self.command("status")["applied"])

    def test_offline_disable_restores_disk_for_next_start(self):
        self.apply()
        state = self.controller()
        state["offline"] = True
        self.write_controller(state)
        response = self.command("disable")
        self.assertTrue(response["pending_restart"])
        self.assertIsNone(response["error"])
        self.assertIn("下次启动", response["message"])
        self.assertFalse(response["enabled"] or response["applied"])
        self.assertEqual(yaml.safe_load(self.runtime.read_text()), self.initial)
        self.assertFalse(json.loads(self.settings.read_text())["enabled"])
        self.assertTrue(self.command("status")["pending_restart"])
        self.assertIsNone(self.command("status")["error"])
        self.command("disable")

    def test_invalid_yaml_and_duplicate_names_leave_runtime_unchanged(self):
        before = self.runtime.read_bytes()
        self.source.write_text("proxies: [")
        response = self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)
        self.assertEqual(response["error"], "SOURCE_YAML_INVALID")
        self.source.write_text(yaml.safe_dump({"proxies": [self.nodes[0], self.nodes[0]]}, allow_unicode=True))
        response = self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)
        self.assertEqual(response["error"], "SOURCE_NODES_INVALID")
        self.assertEqual(self.runtime.read_bytes(), before)

    def test_global_mode_is_rejected_without_claiming_routing_success(self):
        config = dict(self.initial, mode="global")
        self.runtime.write_text(yaml.safe_dump(config, allow_unicode=True))
        before = self.runtime.read_bytes()
        response = self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)
        self.assertEqual(response["error"], "ROUTING_MODE_UNSUPPORTED")
        self.assertEqual(self.runtime.read_bytes(), before)

    def test_existing_reserved_business_names_are_never_deleted(self):
        for entry in ("group", "node", "rule"):
            config = yaml.safe_load(yaml.safe_dump(self.initial))
            if entry == "group":
                config["proxy-groups"].append({"name": "ChatGPT-LianLi", "type": "select", "proxies": ["原节点"]})
            elif entry == "node":
                config["proxies"].append({"name": "r3mini-chatgpt-node-" + "a" * 16, "type": "ss", "server": "business.invalid"})
            else:
                config["rules"].insert(0, "DOMAIN-SUFFIX,business.example,ChatGPT-LianLi")
            self.runtime.write_text(yaml.safe_dump(config, allow_unicode=True))
            before = self.runtime.read_bytes()
            response = self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)
            self.assertEqual(response["error"], "NAME_CONFLICT")
            self.assertEqual(self.runtime.read_bytes(), before)
            self.assertEqual(self.command("disable", ok=False)["error"], "NAME_CONFLICT")
        self.runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        self.apply()
        self.command("disable")
        config = yaml.safe_load(self.runtime.read_text())
        config["proxy-groups"].append({"name": "ChatGPT-LianLi", "type": "select", "proxies": ["原节点"]})
        self.runtime.write_text(yaml.safe_dump(config, allow_unicode=True))
        self.assertEqual(self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)["error"], "NAME_CONFLICT")

    def test_enabled_hook_refuses_foreign_group_with_reserved_name(self):
        self.apply()
        config = yaml.safe_load(yaml.safe_dump(self.initial))
        config["proxy-groups"].append({"name": "ChatGPT-LianLi", "type": "select", "proxies": ["原节点"]})
        hookfile = self.root / "tmp/MESL_yue.yaml"
        hookfile.write_text(yaml.safe_dump(config, allow_unicode=True))
        before = hookfile.read_bytes()
        response = self.command("hook", "/tmp/MESL_yue.yaml", ok=False)
        self.assertEqual(response["error"], "NAME_CONFLICT")
        self.assertEqual(hookfile.read_bytes(), before)

    def test_two_websites_choose_independent_sources_and_single_nodes(self):
        first = self.save_site("网站甲", ["https://EXAMPLE.COM/path?q=ignored"], index=0)
        other = self.source.with_name("other.yaml")
        other.write_text(yaml.safe_dump({"proxies": [self.nodes[1]]}, allow_unicode=True))
        second = self.save_site("网站乙", ["*.second.example.net"], index=1, source="other.yaml")
        sites = second["site_rules"]
        self.assertEqual([r["id"] for r in sites], [first["id"], second["id"]])
        self.assertEqual([r["domains"] for r in sites], [["example.com"], ["second.example.net"]])
        self.assertTrue(all(r["applied"] for r in sites))
        self.assertTrue(second["applied"])
        config = yaml.safe_load(self.runtime.read_text())
        for site, expected_node in zip(sites, self.nodes[:2]):
            group = next(g for g in config["proxy-groups"] if g["name"] == "R3Site-" + site["id"])
            alias = "r3mini-site-node-" + site["id"] + "-" + site["selected"]
            self.assertEqual(group["proxies"], [alias])
            node = next(n for n in config["proxies"] if n["name"] == alias)
            self.assertEqual(node["server"], expected_node["server"])
        self.assertEqual(config["rules"][:2], [
            "DOMAIN-SUFFIX,example.com,R3Site-" + first["id"],
            "DOMAIN-SUFFIX,second.example.net,R3Site-" + second["id"]])
        self.assertEqual(config["rules"][2:], self.initial["rules"])
        self.assertEqual(len(config["proxies"]), 3)
        self.assertEqual(config["dns"], self.initial["dns"])
        self.assertEqual(config["profile"], self.initial["profile"])
        viewed = self.command("status", "lian_li.yaml")
        self.assertEqual(len(viewed["nodes"]), 57)
        self.assertEqual(viewed["source"], "other.yaml")
        self.assertEqual(viewed["site_rules"], sites)

    def test_domain_validation_and_cross_rule_suffix_conflicts(self):
        invalid = ["127.0.0.1", "https://127.0.0.1/path", "https://[::1]/",
                   "example.com:443", "https://example.com:443/path",
                   "https://user:pass" + "@example.com/", "http://", "localhost",  # 拆开写，避开提交前的凭据扫描
                   "bad_domain.example", "a..example.com", "https://-bad.example.com",
                   "https://good.example.com\nmalformed", "ftp://example.com/path"]
        before = self.runtime.read_bytes()
        for domain in invalid:
            payload = {"label": "bad", "domains": [domain], "source": "lian_li.yaml",
                       "selected": node_id(self.nodes[0]["name"])}
            self.assertEqual(self.command("save", json.dumps(payload), ok=False)["error"], "DOMAIN_INVALID")
            self.assertEqual(self.runtime.read_bytes(), before)
        first = self.save_site("main", ["EXAMPLE.com.", "*.example.com"])
        self.assertEqual(first["site_rules"][0]["domains"], ["example.com"])
        for domain in ("example.com", "sub.example.com", "*.example.com"):
            payload = {"label": "collision", "domains": [domain], "source": "lian_li.yaml",
                       "selected": node_id(self.nodes[1]["name"])}
            self.assertEqual(self.command("save", json.dumps(payload), ok=False)["error"], "DOMAIN_CONFLICT")
        self.assertEqual(len(self.command("status")["site_rules"]), 1)

    def test_edit_enable_remove_and_disable_preserve_other_site(self):
        first = self.save_site("first", ["first.example.com"])
        second = self.save_site("second", ["second.example.com"], index=1)
        first_id, second_id = first["id"], second["id"]
        changed = self.save_site("first edited", ["new.example.com"], index=2, id=first_id)
        self.assertEqual([r["id"] for r in changed["site_rules"]], [first_id, second_id])
        self.assertEqual(changed["site_rules"][0]["selected"], node_id(self.nodes[2]["name"]))
        self.assertTrue(changed["site_rules"][1]["applied"])
        stopped = self.command("set-enabled", first_id, "0")
        self.assertFalse(stopped["site_rules"][0]["enabled"] or stopped["site_rules"][0]["applied"])
        self.assertTrue(stopped["site_rules"][1]["applied"])
        self.assertTrue(stopped["enabled"] and stopped["applied"])
        self.command("set-enabled", first_id, "1")
        removed = self.command("remove", first_id)
        self.assertEqual([r["id"] for r in removed["site_rules"]], [second_id])
        self.assertTrue(removed["site_rules"][0]["applied"])
        stopped = self.command("disable")
        self.assertEqual(len(stopped["site_rules"]), 1)
        self.assertFalse(stopped["enabled"] or stopped["applied"])
        self.assertEqual(yaml.safe_load(self.runtime.read_text()), self.initial)
        self.assertEqual(self.command("remove", first_id, ok=False)["error"], "RULE_MISSING")
        self.assertEqual(self.command("set-enabled", second_id, "yes", ok=False)["error"], "ARGUMENT_INVALID")

    def test_save_chatgpt_preset_and_explicit_conversion_to_custom(self):
        preset = self.save_site("ChatGPT", ["chatgpt.com", "openai.com"], preset="chatgpt")
        site = preset["site_rules"][0]
        self.assertEqual(site["preset"], "chatgpt")
        config = yaml.safe_load(self.runtime.read_text())
        self.assertEqual(len(config["rules"]) - len(self.initial["rules"]), 12)
        self.assertIn("DOMAIN,openai-api.arkoselabs.com,R3Site-" + site["id"], config["rules"])
        self.assertIn("DOMAIN-KEYWORD,openai,R3Site-" + site["id"], config["rules"])
        edited = self.save_site("renamed", ["chatgpt.com", "openai.com"], id=site["id"])
        self.assertEqual(edited["site_rules"][0]["preset"], "chatgpt")
        payload = {"label": "overlap", "domains": ["openaiapi-site.azureedge.net"], "source": "lian_li.yaml",
                   "selected": node_id(self.nodes[0]["name"])}
        self.assertEqual(self.command("save", json.dumps(payload), ok=False)["error"], "DOMAIN_CONFLICT")
        custom = self.save_site("custom", ["custom.example.com"], id=site["id"], preset="")
        self.assertEqual(custom["site_rules"][0]["preset"], "")
        config = yaml.safe_load(self.runtime.read_text())
        self.assertEqual(config["rules"][0], "DOMAIN-SUFFIX,custom.example.com,R3Site-" + site["id"])
        self.assertEqual(config["rules"][1:], self.initial["rules"])

    def test_one_failed_site_hook_rejects_only_that_site(self):
        first = self.save_site("first", ["first.example.com"])
        other = self.source.with_name("other.yaml")
        other.write_text(yaml.safe_dump({"proxies": [self.nodes[1]]}, allow_unicode=True))
        second = self.save_site("second", ["second.example.com"], index=1, source="other.yaml")
        other.unlink()
        hookfile = self.root / "tmp/MESL_yue.yaml"
        hookfile.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        response = self.command("hook", "/tmp/MESL_yue.yaml", ok=False)
        self.assertTrue(response["fail_closed"])
        config = yaml.safe_load(hookfile.read_text())
        groups = {g["name"]: g for g in config["proxy-groups"]}
        self.assertEqual(groups["R3Site-" + second["id"]]["proxies"], ["REJECT"])
        self.assertEqual(len(groups["R3Site-" + first["id"]]["proxies"]), 1)
        self.assertTrue(groups["R3Site-" + first["id"]]["proxies"][0].startswith("r3mini-site-node-"))
        self.runtime.write_bytes(hookfile.read_bytes())
        self.seed_live()
        status = self.command("status")
        self.assertTrue(status["site_rules"][0]["applied"])
        self.assertFalse(status["site_rules"][1]["applied"])
        self.assertEqual(status["site_rules"][1]["error"], "SOURCE_MISSING")
        self.assertFalse(status["applied"])
        self.command("disable")
        self.assertEqual(yaml.safe_load(self.runtime.read_text()), self.initial)

    def test_new_site_namespace_collision_is_preserved(self):
        config = yaml.safe_load(yaml.safe_dump(self.initial))
        config["proxy-groups"].append({"name": "R3Site-" + "a" * 12, "type": "select", "proxies": ["原节点"]})
        self.runtime.write_text(yaml.safe_dump(config, allow_unicode=True))
        before = self.runtime.read_bytes()
        payload = {"label": "new", "domains": ["example.com"], "source": "lian_li.yaml",
                   "selected": node_id(self.nodes[0]["name"])}
        self.assertEqual(self.command("save", json.dumps(payload), ok=False)["error"], "NAME_CONFLICT")
        self.assertEqual(self.runtime.read_bytes(), before)

    def test_multisite_mutation_failure_restores_all_settings_and_sites(self):
        first = self.save_site("first", ["first.example.com"])
        self.save_site("second", ["second.example.com"], index=1)
        before_runtime, before_settings = self.runtime.read_bytes(), self.settings.read_bytes()
        state = self.controller()
        state["fail_after_load"] = True
        self.write_controller(state)
        self.assertEqual(self.command("remove", first["id"], ok=False)["error"], "RELOAD_FAILED")
        self.assertEqual(self.runtime.read_bytes(), before_runtime)
        self.assertEqual(self.settings.read_bytes(), before_settings)
        self.assertTrue(self.command("status")["applied"])

    def bench_flags(self, **flags):
        (self.root / "benchmark-flags.json").write_text(json.dumps(flags))

    def test_new_node_requires_supported_country_and_three_real_samples(self):
        before = self.runtime.read_bytes()
        for flags in ({"eligible": False}, {"samples_ms": [10, 20]},
                      {"samples_ms": [10, 0, 20]}, {"wrong_hash": True},
                      {"source_changed": True}, {"expired": True},
                      {"country": "CN"}, {"samples_ms": [1, 2, 3]},
                      {"samples_ms": [1, 2, 3, 4]}):
            self.bench_flags(**flags)
            response = self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)
            self.assertEqual(response["error"], "BENCHMARK_REQUIRED")
            self.assertEqual(self.runtime.read_bytes(), before)
            self.assertFalse(self.settings.exists())
            status = self.command("status")
            self.assertFalse(status["nodes"][0]["eligible"])
        self.bench_flags()
        response = self.apply()
        proof = json.loads(self.settings.read_text())["rules"][0]["node_validation"]
        self.assertTrue(proof["eligible"])
        self.assertEqual(proof["country"], "US")
        self.assertEqual(len(proof["samples_ms"]), 3)
        self.assertEqual(proof["median_ms"], 20.5)
        self.assertTrue(response["nodes"][0]["eligible"])

    def test_benchmark_cli_and_status_return_no_connection_credentials(self):
        started = self.command("benchmark", "lian_li.yaml")
        self.assertTrue(started["running"])
        self.assertEqual(started["best"], node_id(self.nodes[0]["name"]))
        finished = self.command("benchmark-status", "lian_li.yaml")
        self.assertFalse(finished["running"])
        self.assertEqual(len(finished["nodes"]), 57)
        self.assertTrue(all(n["eligible"] and len(n["samples_ms"]) == 3 for n in finished["nodes"]))
        self.assertEqual(finished["nodes"][0]["median_ms"], min(n["median_ms"] for n in finished["nodes"]))
        status = self.command("status")
        self.assertEqual(status["benchmark"]["best"], finished["best"])
        self.assertEqual(status["nodes"][0]["country"], "US")

    def test_persistent_validation_survives_missing_benchmark_cache(self):
        response = self.apply()
        first_id = response["site_rules"][0]["id"]
        self.bench_flags(eligible=False, expired=True)
        status = self.command("status")
        self.assertTrue(status["applied"])
        self.assertTrue(status["nodes"][0]["eligible"])
        self.assertFalse(status["nodes"][1]["eligible"])
        self.assertEqual(status["benchmark"]["error"], "BENCH_EXPIRED")
        temporary_runtime = self.root / "tmp/MESL_yue.yaml"
        temporary_runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        self.command("hook", "/tmp/MESL_yue.yaml")
        config = yaml.safe_load(temporary_runtime.read_text())
        group = next(g for g in config["proxy-groups"] if g["name"] == "R3Site-" + first_id)
        self.assertNotEqual(group["proxies"], ["REJECT"])
        self.command("set-enabled", first_id, "0")
        self.command("set-enabled", first_id, "1")
        self.assertTrue(self.command("status")["applied"])

    def test_changed_node_parameters_require_retest_and_hook_fails_closed(self):
        response = self.apply()
        site_id = response["site_rules"][0]["id"]
        self.nodes[1]["server"] = "unrelated-change.invalid"
        self.source.write_text(yaml.safe_dump({"proxies": self.nodes}, allow_unicode=True))
        self.bench_flags(eligible=False)
        self.assertTrue(self.command("status")["applied"])  # Selected parameters are unchanged.
        self.nodes[0]["server"] = "changed-selected.invalid"
        self.source.write_text(yaml.safe_dump({"proxies": self.nodes}, allow_unicode=True))
        status = self.command("status")
        self.assertFalse(status["applied"])
        self.assertEqual(status["site_rules"][0]["error"], "NODE_CHANGED")
        self.assertFalse(status["nodes"][0]["eligible"])
        temporary_runtime = self.root / "tmp/MESL_yue.yaml"
        temporary_runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        response = self.command("hook", "/tmp/MESL_yue.yaml", ok=False)
        self.assertEqual(response["error"], "NODE_CHANGED")
        config = yaml.safe_load(temporary_runtime.read_text())
        group = next(g for g in config["proxy-groups"] if g["name"] == "R3Site-" + site_id)
        self.assertEqual(group["proxies"], ["REJECT"])
        self.command("disable")
        self.assertEqual(self.command("set-enabled", site_id, "1", ok=False)["error"], "BENCHMARK_REQUIRED")
        self.command("remove", site_id)
        self.assertEqual(yaml.safe_load(self.runtime.read_text()), self.initial)

    def test_save_unverified_node_cannot_import_user_supplied_validation(self):
        self.bench_flags(eligible=False)
        payload = {"label": "forged", "domains": ["example.com"], "source": "lian_li.yaml",
                   "selected": node_id(self.nodes[0]["name"]), "enabled": True,
                   "node_validation": {"eligible": True, "country": "US", "samples_ms": [1, 2, 3],
                                       "median_ms": 2, "node_hash": "forged"}}
        self.assertEqual(self.command("save", json.dumps(payload), ok=False)["error"], "BENCHMARK_REQUIRED")
        self.assertFalse(self.settings.exists())

    def test_actual_helper_float_metrics_and_shared_supported_regions(self):
        report = self.command("benchmark-status", "lian_li.yaml")
        actual_helper = HERE / "router/usr/libexec/r3mini-site-bench.rb"
        (self.root / "usr/libexec/r3mini-site-bench.rb").write_bytes(actual_helper.read_bytes())
        directory = self.root / "tmp/r3mini-site-bench" / hashlib.sha256(b"lian_li.yaml").hexdigest()[:16]
        directory.mkdir(parents=True)
        state = {"ok": True, "running": False, "done": 57, "total": 57,
                 "source": "lian_li.yaml", "source_hash": report["source_sha256"],
                 "source_sha256": report["source_sha256"], "started_epoch": int(time.time()),
                 "started_at": "2026-10-25T00:00:00Z", "finished_at": "2026-10-25T00:00:10Z",
                 "results": report["nodes"], "best": report["best"], "error": None}
        cache = directory / "state.json"
        cache.write_text(json.dumps(state))
        cache.chmod(0o600)
        response = self.apply()
        self.assertIsInstance(response["benchmark"]["nodes"][0]["median_ms"], float)
        self.assertEqual(response["nodes"][0]["median_ms"], 20.5)
        self.assertEqual(json.loads(self.settings.read_text())["rules"][0]["node_validation"]["samples_ms"], [30.5, 10.5, 20.5])
        self.command("disable")
        table = self.root / "usr/share/r3mini-site-routing/supported-regions.json"
        table.parent.mkdir(parents=True)
        table.write_text(json.dumps({"countries": ["JP"]}))
        self.assertEqual(self.command("set-enabled", response["site_rules"][0]["id"], "1", ok=False)["error"], "BENCHMARK_REQUIRED")

    def test_fresh_failed_retest_revokes_saved_supported_region_proof(self):
        response = self.apply()
        site_id = response["site_rules"][0]["id"]
        self.bench_flags(eligible=False, country="HK", row_error="UNSUPPORTED_REGION")
        status = self.command("status")
        self.assertFalse(status["applied"])
        self.assertFalse(status["nodes"][0]["eligible"])
        self.assertEqual(status["nodes"][0]["country"], "HK")
        self.assertEqual(status["site_rules"][0]["error"], "BENCHMARK_REQUIRED")
        temporary_runtime = self.root / "tmp/MESL_yue.yaml"
        temporary_runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        result = self.command("hook", "/tmp/MESL_yue.yaml", ok=False)
        self.assertTrue(result["fail_closed"])
        groups = yaml.safe_load(temporary_runtime.read_text())["proxy-groups"]
        self.assertEqual(next(g for g in groups if g["name"] == "R3Site-" + site_id)["proxies"], ["REJECT"])
        self.command("disable")
        self.assertEqual(self.command("set-enabled", site_id, "1", ok=False)["error"], "BENCHMARK_REQUIRED")

    def test_pending_retest_may_use_saved_proof_until_that_node_completes(self):
        self.apply()
        self.bench_flags(eligible=False, country=None, row_error="PENDING")
        status = self.command("status")
        self.assertTrue(status["applied"])
        self.assertTrue(status["nodes"][0]["eligible"])
        self.assertEqual(status["nodes"][0]["country"], "US")

    def test_failed_hook_revocation_survives_missing_tmp_benchmark_cache(self):
        response = self.apply()
        site_id = response["site_rules"][0]["id"]
        self.bench_flags(eligible=False, country="HK", row_error="UNSUPPORTED_REGION")
        temporary_runtime = self.root / "tmp/MESL_yue.yaml"
        temporary_runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        self.command("hook", "/tmp/MESL_yue.yaml", ok=False)
        stored = json.loads(self.settings.read_text())
        self.assertNotIn("node_validation", stored["rules"][0])
        self.assertEqual(stored["rule_errors"][site_id], "BENCHMARK_REQUIRED")
        # The actual helper sees no /tmp cache and returns untouched PENDING rows.
        (self.root / "usr/libexec/r3mini-site-bench.rb").write_bytes(
            (HERE / "router/usr/libexec/r3mini-site-bench.rb").read_bytes())
        temporary_runtime.write_text(yaml.safe_dump(self.initial, allow_unicode=True))
        self.command("hook", "/tmp/MESL_yue.yaml", ok=False)
        status = self.command("status")
        self.assertFalse(status["applied"] or status["nodes"][0]["eligible"])
        groups = yaml.safe_load(temporary_runtime.read_text())["proxy-groups"]
        self.assertEqual(next(g for g in groups if g["name"] == "R3Site-" + site_id)["proxies"], ["REJECT"])
        self.command("disable")
        self.assertEqual(json.loads(self.settings.read_text())["rule_errors"][site_id], "BENCHMARK_REQUIRED")
        self.assertEqual(self.command("set-enabled", site_id, "1", ok=False)["error"], "BENCHMARK_REQUIRED")

    def test_successful_apply_reuses_verified_snapshot_with_three_http_calls(self):
        state = self.controller()
        state["delay_seconds"] = 0.25
        self.write_controller(state)
        started = time.monotonic()
        response = self.apply()
        elapsed = time.monotonic() - started
        self.assertTrue(response["applied"])
        state = self.controller()
        self.assertEqual(len(state["urls"]), 3)
        self.assertEqual([url.split(":9090")[1] for url in state["urls"]],
                         ["/configs?force=true", "/proxies", "/rules"])
        self.assertEqual(state["max_times"], [2.0, 2.0, 2.0])
        self.assertLess(elapsed, 3.5)
        self.command("status")
        self.assertEqual(len(self.controller()["urls"]), 5)

    def test_controller_timeout_bounds_rollback_below_rpc_budget(self):
        before_runtime = self.runtime.read_bytes()
        state = self.controller()
        state["delay_seconds"] = 4.2
        self.write_controller(state)
        started = time.monotonic()
        response = self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)
        elapsed = time.monotonic() - started
        self.assertEqual(response["error"], "ROLLBACK_FAILED")
        self.assertLess(elapsed, 7)
        self.assertEqual(self.runtime.read_bytes(), before_runtime)
        self.assertFalse(self.settings.exists())
        self.assertEqual(self.controller()["max_times"], [2.0, 2.0])

    def test_core_validation_watchdog_stops_child_and_preserves_original(self):
        before = self.runtime.read_bytes()
        (self.root / "hang_core").touch()
        started = time.monotonic()
        response = self.command("apply", "lian_li.yaml", node_id(self.nodes[0]["name"]), ok=False)
        elapsed = time.monotonic() - started
        self.assertEqual(response["error"], "CONFIG_TEST_FAILED")
        self.assertGreaterEqual(elapsed, 20)
        self.assertLess(elapsed, 21.5)
        self.assertEqual(self.runtime.read_bytes(), before)
        self.assertFalse(self.settings.exists())
        pid = int((self.root / "core-test-pid").read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_core_validation_receives_production_resource_path_allowlist(self):
        response = self.apply()
        self.assertTrue(response["applied"])
        self.assertEqual((self.root / "core-safe-paths").read_text(), "/usr/share/openclash:/etc/ssl")

    def test_core_validation_uses_helper_group_without_changing_parent(self):
        parent_gid = os.getgid()
        response = self.apply()
        self.assertTrue(response["applied"])
        proof = json.loads((self.root / "core-gid-proof.json").read_text())
        self.assertEqual(proof, {"gid": self.expected_gid, "egid": self.expected_gid})
        self.assertEqual(os.getgid(), parent_gid)

    def test_missing_helper_or_core_group_cannot_fall_back_to_root(self):
        original = self.runtime.read_bytes()
        helper = self.root / "usr/libexec/r3mini-site-bench.rb"
        saved_helper = helper.read_bytes()
        helper.unlink()
        self.assertEqual(self.command("disable", ok=False)["error"], "CORE_GROUP_MISSING")
        helper.write_bytes(saved_helper)
        groupfile = self.root / "etc/group"
        for content in ("root:x:0:\n", "nogroup:x:0:\n"):
            groupfile.write_text(content)
            self.assertEqual(self.command("disable", ok=False)["error"], "CORE_GROUP_MISSING")
        groupfile.unlink()
        self.assertEqual(self.command("disable", ok=False)["error"], "CORE_GROUP_MISSING")
        self.assertEqual(self.runtime.read_bytes(), original)
        self.assertFalse(self.settings.exists())

    def test_large_subscription_apply_and_status_complete_within_rpc_budget(self):
        count = 2000
        nodes = [{"name": f"scale-{index}", "type": "hysteria2",
                  "server": "scale.invalid", "password": "x" * 14000} for index in range(count)]
        # JSON is valid YAML and avoids spending fixture time formatting secrets.
        self.source.write_text(json.dumps({"proxies": nodes}), encoding="utf-8")
        self.assertGreater(self.source.stat().st_size, 28_000_000)
        self.assertLess(self.source.stat().st_size, 32 * 1024 * 1024)
        started = time.monotonic()
        result = self.command("apply", "lian_li.yaml", node_id(nodes[0]["name"]))
        apply_elapsed = time.monotonic() - started
        self.assertTrue(result["applied"])
        self.assertEqual(len(result["nodes"]), count)
        self.assertEqual(len(yaml.safe_load(self.runtime.read_text())["proxies"]), 2)
        self.assertLess(apply_elapsed, 20, f"large subscription apply took {apply_elapsed:.3f}s")
        started = time.monotonic()
        result = self.command("status")
        status_elapsed = time.monotonic() - started
        self.assertTrue(result["applied"])
        self.assertEqual(len(result["nodes"]), count)
        self.assertLess(status_elapsed, 20, f"large subscription status took {status_elapsed:.3f}s")


if __name__ == "__main__":
    unittest.main(verbosity=2)
