#!/usr/bin/env python3
"""Offline isolated-core acceptance: python chatgpt-routing/test_benchmark.py.

Fake curl emits deterministic HTTPS observations; fake core opens a real localhost
LISTEN socket. No router, subscription, internet or additional Ruby gems are used.
"""
from __future__ import annotations

import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

if os.name == "nt":
    name = str(Path(__file__).resolve())
    mapped = "/mnt/" + name[0].lower() + name[2:].replace("\\", "/")
    raise SystemExit(subprocess.call(["wsl.exe", "-d", "Ubuntu", "--", "python3", mapped]))

import yaml

HERE = Path(__file__).resolve().parent
HELPER = HERE / "router/usr/libexec/r3mini-site-bench.rb"

MOCK_CORE = r'''#!/usr/bin/python3
import json, os, signal, socket, sys, time
from pathlib import Path
import yaml
root = Path(__file__).resolve().parents[3]
expected_gid = int((root / 'etc/group').read_text().split(':')[2])
assert os.getgid() == expected_gid and os.getegid() == expected_gid
(root / 'core-gid-proof.json').write_text(json.dumps({'gid': os.getgid(), 'egid': os.getegid()}))
args = sys.argv[1:]
assert args[0] == '-d' and args[2] == '-f'
scratch = Path(args[1])
assert scratch.stat().st_mode & 0o777 == 0o700
assert Path(args[3]).stat().st_mode & 0o777 == 0o600
assert (scratch / 'core.log').stat().st_mode & 0o777 == 0o600
cfg = yaml.safe_load(Path(args[3]).read_text())
assert 'external-controller' not in cfg
assert not cfg['allow-lan'] and cfg['bind-address'] == '127.0.0.1'
assert not cfg['tun']['enable'] and not cfg['geo-auto-update']
assert cfg['dns']['listen'] == '127.0.0.1:0'
assert not cfg['dns']['fallback-filter']['geoip']
expected_bootstrap_file = root / 'mock-bootstrap.json'
expected_bootstrap = json.loads(expected_bootstrap_file.read_text()) if expected_bootstrap_file.exists() else ['1.1.1.1']
assert cfg['dns']['proxy-server-nameserver'] == expected_bootstrap
if 'default-nameserver' in cfg['dns'] and not cfg['dns']['default-nameserver']:
    print('default nameserver should have at least one nameserver', file=sys.stderr)
    sys.exit(1)
plain_bootstrap = [entry for entry in expected_bootstrap if not entry.startswith('https:')]
if plain_bootstrap:
    assert cfg['dns']['default-nameserver'] == plain_bootstrap
else:
    assert 'default-nameserver' not in cfg['dns']
(root / 'core-dns-proof.json').write_text(json.dumps(cfg['dns']))
assert cfg['rules'] == ['MATCH,probe-node']
assert len(cfg['proxies']) == 1
assert (scratch / 'Country.mmdb').is_symlink()
port = cfg['mixed-port']
manifest = root / 'mock-ports' / str(port)
node = cfg['proxies'][0]
time.sleep(node.get('mock-start-delay', 0.15))
sock = socket.socket()
sock.bind(('127.0.0.1', port))
sock.listen()
manifest.write_text(json.dumps({'node': node, 'pid': os.getpid(), 'calls': 0, 'listening': True}))
def stop(*_):
    manifest.unlink(missing_ok=True)
    sock.close()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
while True:
    time.sleep(0.1)
'''

MOCK_CURL = r'''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
root = Path(__file__).resolve().parents[2]
assert os.getgid() == int((root / 'helper-gid').read_text())
assert os.getegid() == int((root / 'helper-gid').read_text())
args = sys.argv[1:]
if '--fresh-connect' in args:
    print('curl: option --fresh-connect: is unknown', file=sys.stderr)
    sys.exit(2)
assert args[0] == '-q' and '--no-keepalive' in args
assert args[args.index('--noproxy') + 1] == ''
url = args[-1]
assert url.startswith('https://') and '?r3mini=' in url
port = args[args.index('--proxy') + 1].rsplit(':', 1)[1]
manifest = root / 'mock-ports' / port
assert manifest.exists(), 'curl was called before core LISTEN'
state = json.loads(manifest.read_text())
assert state['listening']
assert (Path('/proc') / str(state['pid'])).exists()
node = state['node']
call = state['calls']
state['calls'] += 1
manifest.write_text(json.dumps(state))
time.sleep(node.get('mock-curl-delay', 0))
if node.get('mock-tls-fail'):
    sys.exit(35)
if 'api.openai.com' in url:
    code = node.get('mock-api-code', 401)
    body = '{"error":{"code":"unsupported_country_region_territory"}}' if code == 403 else '{"error":"invalid_api_key"}'
else:
    code = node.get('mock-trace-code', 200)
    country = node.get('mock-country', 'US')
    if isinstance(country, list):
        country = country[min(call, len(country) - 1)]
    body = 'ip=192.0.2.8\nloc=' + country + '\n'
Path(args[args.index('--output') + 1]).write_text(body)
samples = node.get('mock-samples', [0.3, 0.1, 0.2])
print(str(code) + '\n' + str(samples[min(call, 2)]))
'''


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:16]


class BenchmarkTest(unittest.TestCase):
    def setUp(self):
        if not shutil.which("ruby"):
            self.skipTest("Ruby unavailable; no real-router fallback")
        self.temp = tempfile.TemporaryDirectory(prefix="r3mini-bench-test-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.cleanup)
        for relative in ("etc/openclash/core", "etc/openclash/config", "tmp", "usr/bin", "mock-ports"):
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        for relative, content in (("usr/bin/curl", MOCK_CURL), ("etc/openclash/core/clash_meta", MOCK_CORE)):
            dest = self.root / relative
            dest.write_text(content, encoding="utf-8")
            dest.chmod(0o755)
        (self.root / "etc/openclash/Country.mmdb").write_text("fake-geodata")
        # A normal unprivileged test uses its own group; the root acceptance
        # run proves the actual child-only transition to nogroup 65534.
        self.core_gid = 65534 if os.geteuid() == 0 else os.getgid()
        (self.root / "etc/group").write_text(f"nogroup:x:{self.core_gid}:\n")
        (self.root / "helper-gid").write_text(str(os.getgid()))
        self.env = dict(os.environ, R3MINI_CHATGPT_ROOT=str(self.root))
        self.source = self.root / "etc/openclash/config/lian_li.yaml"
        self.write_nodes([{"name": '美国 "A"\\测试', "type": "vless", "server": "secret.invalid", "uuid": "private-secret"}])

    def cleanup(self):
        for manifest in (self.root / "mock-ports").glob("*"):
            try:
                os.kill(json.loads(manifest.read_text())["pid"], signal.SIGTERM)
            except (ProcessLookupError, FileNotFoundError):
                pass
        for state in (self.root / "tmp/r3mini-site-bench").glob("*/state.json"):
            value = json.loads(state.read_text())
            if value.get("running"):
                try:
                    os.kill(value["pid"], signal.SIGTERM)
                except ProcessLookupError:
                    pass
        time.sleep(0.05)
        self.temp.cleanup()

    def write_nodes(self, nodes):
        self.source.write_text(yaml.safe_dump({"proxies": nodes, "dns": {"proxy-server-nameserver": ["1.1.1.1", "https://invalid.test/dns-query#PROXY"]}}, allow_unicode=True), encoding="utf-8")

    def cli(self, *args, ok=True):
        proc = subprocess.run(["ruby", str(HELPER), *args], env=self.env, text=True, capture_output=True, timeout=5)
        self.assertEqual(proc.stderr, "")
        result = json.loads(proc.stdout)
        self.assertEqual(result["ok"], ok, result)
        self.assertEqual(proc.returncode, 0 if ok else 1, result)
        for secret in ("secret.invalid", "private-secret", "192.0.2.8", "uuid", '"server"'):
            self.assertNotIn(secret, proc.stdout)
        return result

    def finish(self):
        started = time.monotonic()
        result = self.cli("start", self.source.name)
        self.assertLess(time.monotonic() - started, 2)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            result = self.cli("status", self.source.name)
            if not result["running"]:
                self.assertEqual(result.get("error"), None, result)
                return result
            time.sleep(0.1)
        self.fail("async benchmark did not complete")

    def statefile(self):
        return next((self.root / "tmp/r3mini-site-bench").glob("*/state.json"))

    def test_actual_country_three_samples_and_private_cleanup(self):
        result = self.finish()
        row = result["results"][0]
        self.assertEqual(row["country"], "US")
        self.assertEqual(row["samples_ms"], [300.0, 100.0, 200.0])
        self.assertEqual(row["median_ms"], 200.0)
        self.assertTrue(row["eligible"])
        self.assertEqual(result["best"], row["id"])
        self.assertEqual(result["source_sha256"], hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.assertEqual(result["nodes"], result["results"])
        self.assertEqual(self.statefile().stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.statefile().parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(self.statefile().parent.glob("run-*")), [])
        self.assertEqual(list((self.root / "mock-ports").glob("*")), [])
        proof = json.loads((self.root / "core-gid-proof.json").read_text())
        self.assertEqual(proof, {"gid": self.core_gid, "egid": self.core_gid})

    def test_https_only_bootstrap_omits_empty_default_nameserver(self):
        bootstrap = ["https://dns.example.test/dns-query", "https://resolver.example.test/dns-query"]
        config = yaml.safe_load(self.source.read_text())
        config["dns"]["proxy-server-nameserver"] = bootstrap
        self.source.write_text(yaml.safe_dump(config, allow_unicode=True), encoding="utf-8")
        (self.root / "mock-bootstrap.json").write_text(json.dumps(bootstrap))
        result = self.finish()
        row = result["results"][0]
        self.assertTrue(row["eligible"], row)
        self.assertEqual(row["samples_ms"], [300.0, 100.0, 200.0])
        self.assertEqual(row["median_ms"], 200.0)
        dns = json.loads((self.root / "core-dns-proof.json").read_text())
        self.assertEqual(dns["proxy-server-nameserver"], bootstrap)
        self.assertEqual(dns["nameserver"], bootstrap)
        self.assertNotIn("default-nameserver", dns)

    def test_missing_proxy_server_nameserver_falls_back_to_default_nameserver(self):
        # A subscription that only sets default-nameserver must still resolve node
        # hostnames through it, never through the router's fake-ip resolver.
        plain = ["223.5.5.5", "119.29.29.29"]
        config = yaml.safe_load(self.source.read_text())
        config["dns"] = {"default-nameserver": plain, "nameserver": ["https://provider.example.test/api-query"]}
        self.source.write_text(yaml.safe_dump(config, allow_unicode=True), encoding="utf-8")
        (self.root / "mock-bootstrap.json").write_text(json.dumps(plain))
        result = self.finish()
        self.assertTrue(result["results"][0]["eligible"], result["results"][0])
        dns = json.loads((self.root / "core-dns-proof.json").read_text())
        self.assertTrue(dns["enable"])
        self.assertEqual(dns["proxy-server-nameserver"], plain)
        self.assertEqual(dns["nameserver"], plain)
        self.assertEqual(dns["default-nameserver"], plain)

    def test_country_not_node_name_determines_eligibility_and_median_best(self):
        self.write_nodes([
            {"name": "香港名称但美国出口", "mock-country": "US", "mock-samples": [.9, .1, .2]},
            {"name": "美国名称但香港出口", "mock-country": "HK"},
            {"name": "日本稳定较快", "mock-country": "JP", "mock-samples": [.15, .16, .17]},
            {"name": "country-changes", "mock-country": ["US", "JP", "US"]},
            {"name": "api-blocked", "mock-api-code": 403},
            {"name": "tls-fails", "mock-tls-fail": True},
        ])
        result = self.finish()
        rows = {row["name"]: row for row in result["results"]}
        self.assertEqual(result["best"], ident("日本稳定较快"))
        self.assertTrue(rows["香港名称但美国出口"]["eligible"])
        self.assertEqual(rows["美国名称但香港出口"]["error"], "UNSUPPORTED_REGION")
        self.assertEqual(rows["country-changes"]["error"], "REGION_CHANGED")
        self.assertEqual(rows["api-blocked"]["error"], "UNSUPPORTED_REGION")
        self.assertEqual(rows["tls-fails"]["error"], "TLS_FAILED")

    def test_source_change_expires_proof(self):
        self.finish()
        self.source.write_text(self.source.read_text() + "\n# subscription refreshed\n")
        result = self.cli("status", self.source.name)
        self.assertEqual(result["error"], "SOURCE_CHANGED")
        self.assertIsNone(result["best"])
        self.assertFalse(result["results"][0]["eligible"])

    def test_expired_result_and_node_fingerprint(self):
        self.finish()
        state = json.loads(self.statefile().read_text())
        state["started_epoch"] = int(time.time()) - 86401
        self.statefile().write_text(json.dumps(state))
        result = self.cli("status", self.source.name)
        self.assertEqual(result["error"], "BENCH_EXPIRED")
        self.assertIsNone(result["best"])
        script = "require ARGV.shift; a={'name'=>'a','type'=>'vless','x'=>{'z'=>1,'a'=>2}}; b={'x'=>{'a'=>2,'z'=>1},'type'=>'vless','name'=>'b'}; puts R3MiniSiteBench.node_hash(a)==R3MiniSiteBench.node_hash(b)"
        proc = subprocess.run(["ruby", "-e", script, str(HELPER)], text=True, capture_output=True)
        self.assertEqual(proc.stdout.strip(), "true")

    def test_duplicate_start_and_global_concurrency(self):
        self.write_nodes([{"name": f"node-{i}", "mock-curl-delay": .15} for i in range(5)])
        first = self.cli("start", self.source.name)
        self.assertTrue(first["running"])
        again = self.cli("start", self.source.name)
        self.assertTrue(again["already_running"])
        second = self.source.with_name("other.yaml")
        shutil.copyfile(self.source, second)
        other = self.cli("start", second.name, ok=False)
        self.assertEqual(other["error"], "BENCH_BUSY")
        maximum = 0
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            maximum = max(maximum, len(list((self.root / "mock-ports").glob("*"))))
            if not self.cli("status", self.source.name)["running"]:
                break
            time.sleep(.1)
        self.assertEqual(maximum, 2)

    def test_paths_and_symlink_are_rejected(self):
        for name in ("../secret.yaml", "/etc/a.yaml", "a\\b.yaml", "foo.json", "a\nyaml.yaml"):
            self.assertEqual(self.cli("status", name, ok=False)["error"], "SOURCE_INVALID")
        target = self.source.with_name("link.yaml")
        target.symlink_to(self.source)
        self.assertEqual(self.cli("status", target.name, ok=False)["error"], "SOURCE_MISSING")

    def test_configured_region_allowlist_and_dependent_node(self):
        regions = self.root / "usr/share/r3mini-site-routing"
        regions.mkdir(parents=True)
        (regions / "supported-regions.json").write_text(json.dumps({"countries": ["JP"]}))
        self.write_nodes([{"name": "actual-us"}, {"name": "actual-jp", "mock-country": "JP"},
                          {"name": "dependent", "dialer-proxy": "production-node"}])
        result = self.finish()
        rows = {row["name"]: row for row in result["results"]}
        self.assertFalse(rows["actual-us"]["eligible"])
        self.assertTrue(rows["actual-jp"]["eligible"])
        self.assertEqual(rows["dependent"]["error"], "NODE_DEPENDENCY")
        self.assertEqual(result["best"], ident("actual-jp"))

    def test_real_curl_cli_flags_and_curlrc_ignored(self):
        actual_curl = shutil.which("curl")
        if not actual_curl:
            self.skipTest("Real curl unavailable")
        shutil.copy2(actual_curl, self.root / "usr/bin/curl")
        seen = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, self.headers.get("Cache-Control")))
                body = b"loc=US\n"
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        with http.server.HTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            scratch = self.root / "curl-smoke"
            scratch.mkdir()
            curl_home = self.root / "curl-home"
            curl_home.mkdir()
            (curl_home / ".curlrc").write_text("this-option-must-not-exist\n")
            script = "require ARGV.shift; a=R3MiniSiteBench.new; puts R3MiniSiteBench.json(a.curl_probe(ARGV[0].to_i,ARGV[1],ARGV[2]))"
            env = dict(self.env, HOME=str(curl_home), CURL_HOME=str(curl_home))
            proc = subprocess.run(["ruby", "-e", script, str(HELPER), str(server.server_port), str(scratch),
                                   "http://local-benchmark.invalid/trace?r3mini=real-curl-smoke"],
                                  env=env, text=True, capture_output=True, timeout=5)
            server.shutdown()
            thread.join(timeout=2)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        code, milliseconds, body = json.loads(proc.stdout)
        self.assertEqual(code, 200)
        self.assertGreater(milliseconds, 0)
        self.assertEqual(body, "loc=US\n")
        self.assertEqual(seen, [("http://local-benchmark.invalid/trace?r3mini=real-curl-smoke", "no-cache")])

    def test_dead_coordinator_is_detected_and_orphan_core_cleaned(self):
        self.write_nodes([{"name": "slow", "mock-curl-delay": 1.0}])
        self.cli("start", self.source.name)
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline and not list((self.root / "mock-ports").glob("*")):
            time.sleep(.05)
        state = json.loads(self.statefile().read_text())
        os.kill(state["pid"], signal.SIGKILL)
        time.sleep(.1)
        result = self.cli("status", self.source.name)
        self.assertEqual(result["error"], "BENCH_INTERRUPTED")
        self.assertFalse(result["running"])
        self.assertEqual(list(self.statefile().parent.glob("run-*")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
