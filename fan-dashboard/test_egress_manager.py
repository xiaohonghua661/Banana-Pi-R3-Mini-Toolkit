from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import contextlib
import hashlib
import importlib.util
import io
import json
from types import SimpleNamespace
from pathlib import Path


ROOT = Path(__file__).resolve().parent
MANAGER = ROOT / "router" / "usr" / "sbin" / "r3mini-egress-manager"
WEB = ROOT / "router" / "usr" / "sbin" / "r3mini-hotspot-web"
UI = ROOT / "router" / "www" / "luci-static" / "resources" / "view" / "network" / "r3mini-hotspot.js"
DEPLOY = ROOT / "deploy-hotspot-router.sh"
ACL = ROOT / "router" / "usr" / "share" / "rpcd" / "acl.d" / "luci-app-r3mini-hotspot.json"
HOTPLUG = ROOT / "router" / "etc" / "hotplug.d" / "iface" / "95-r3mini-egress"
NODE = Path(r"C:\Users\Newland\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe")
VERIFY = ROOT / "verify_egress.py"
VERIFY_ROUTER = ROOT / "verify-egress-router.sh"


def bash_path() -> str:
    git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if os.name == "nt" and git_bash.is_file():
        return str(git_bash)
    found = shutil.which("bash")
    if found and "WindowsApps" not in found:
        return found
    if git_bash.is_file():
        return str(git_bash)
    raise SystemExit("BASH_NOT_FOUND")


def shell_path(path: Path) -> str:
    return path.resolve().as_posix()


def behavioral_test() -> str:
    with tempfile.TemporaryDirectory(prefix="r3mini-egress-") as raw:
        tmp = Path(raw)
        web_stub = tmp / "web-stub"
        calls = tmp / "calls"
        runtime = tmp / "runtime"
        state = tmp / "state"
        lock = tmp / "probe-lock"
        web_stub.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$2\" >> \"$R3_TEST_CALLS\"\n",
            encoding="utf-8",
        )
        web_stub.chmod(0o755)
        harness = tmp / "test.sh"
        harness.write_text(
            f"""#!/bin/sh
set -eu
export R3MINI_EGRESS_LIB=1
export R3MINI_STATE='{shell_path(state)}'
export R3MINI_RUNTIME='{shell_path(runtime)}'
export R3MINI_WEB='{shell_path(web_stub)}'
export R3_TEST_CALLS='{shell_path(calls)}'
export R3MINI_LOCK='{shell_path(lock)}'
. '{shell_path(MANAGER)}'

jsonfilter() {{
    local file='' expr='' key
    while [ "$#" -gt 0 ]; do
        case "$1" in -i) file="$2"; shift 2;; -e) expr="$2"; shift 2;; *) shift;; esac
    done
    key="${{expr#@.}}"
    case "$key" in
        candidate) sed -n 's/.*"candidate":"\\([^"]*\\)".*/\\1/p' "$file" ;;
        candidate_count) sed -n 's/.*"candidate_count":\\([0-9][0-9]*\\).*/\\1/p' "$file" ;;
        last_switch) sed -n 's/.*"last_switch":\\([0-9][0-9]*\\).*/\\1/p' "$file" ;;
        current_failures) sed -n 's/.*"current_failures":\\([0-9][0-9]*\\).*/\\1/p' "$file" ;;
        active_target) sed -n 's/.*"active_target":"\\([^"]*\\)".*/\\1/p' "$file" ;;
    esac
}}

PREFERRED='auto'
cfg() {{
    case "$1" in
        preferred_egress) printf '%s' "$PREFERRED" ;;
        auto_hold_seconds) printf 30 ;;
        auto_min_improvement_ms) printf 20 ;;
        auto_min_improvement_pct) printf 15 ;;
        auto_confirmations) printf 2 ;;
    esac
}}
ONLINE='wan hotspot'
CURRENT='wan'
kind_online() {{ case " $ONLINE " in *" $1 "*) return 0;; *) return 1;; esac; }}
current_kind() {{ printf '%s' "$CURRENT"; }}
write_state() {{ printf '%s|%s|%s\\n' "$1" "$2" "$3" > "$R3MINI_STATE"; }}
cached_delay() {{ case "$1" in wan) printf 100;; cellular) printf 80;; hotspot) printf 60;; esac; }}

wan_ms=100; cellular_ms=''; hotspot_ms=60
auto_reconcile
test ! -s "$R3_TEST_CALLS"
grep -q '"candidate":"hotspot"' "$R3MINI_RUNTIME"
auto_reconcile
test "$(tail -n 1 "$R3_TEST_CALLS")" = hotspot
echo HYSTERESIS_SWITCH=PASS

: > "$R3_TEST_CALLS"; rm -f "$R3MINI_RUNTIME"
wan_ms=100; hotspot_ms=90
auto_reconcile
test ! -s "$R3_TEST_CALLS"
echo SMALL_ADVANTAGE_HOLD=PASS

: > "$R3_TEST_CALLS"; rm -f "$R3MINI_RUNTIME"
CURRENT='wan'; ONLINE='hotspot'
event_reconcile
test "$(tail -n 1 "$R3_TEST_CALLS")" = hotspot
echo HARD_DOWN_FAILOVER=PASS

: > "$R3_TEST_CALLS"; rm -f "$R3MINI_RUNTIME"
PREFERRED=''; CURRENT='wan'; ONLINE='hotspot'
event_reconcile
test "$(tail -n 1 "$R3_TEST_CALLS")" = hotspot
echo DEFAULT_AUTO_FAILOVER=PASS

: > "$R3_TEST_CALLS"; CURRENT='wan'; ONLINE='wan hotspot'
PREFERRED='auto'
candidate=''; candidate_count=0; last_switch=0; current_failures=0; active_target='hotspot'; save_runtime
event_reconcile
test "$(tail -n 1 "$R3_TEST_CALLS")" = hotspot
echo ACTIVE_TARGET_REPLAY=PASS

: > "$R3_TEST_CALLS"; CURRENT='wan'; ONLINE=''
event_reconcile
test ! -s "$R3_TEST_CALLS"
grep -q '^unavailable|' "$R3MINI_STATE"
echo NO_EGRESS_SAFE=PASS

: > "$R3_TEST_CALLS"; CURRENT='wan'; ONLINE='wan hotspot'; PREFERRED='wan'
probe_all() {{ wan_ms=100; hotspot_ms=40; return 0; }}
run_probe
test ! -s "$R3_TEST_CALLS"
grep -q '^manual|' "$R3MINI_STATE"
echo MANUAL_PRIORITY=PASS

: > "$R3_TEST_CALLS"; PREFERRED='auto'; CURRENT='wan'; ONLINE='wan hotspot'
wan_ms=''; hotspot_ms=60
candidate=''; candidate_count=0; last_switch="$(date +%s)"; current_failures=0; save_runtime
auto_reconcile
auto_reconcile
test ! -s "$R3_TEST_CALLS"
grep -q '"current_failures":2' "$R3MINI_RUNTIME"
echo PROBE_FAILURE_HOLD=PASS

marker='{shell_path(tmp / "marker")}'
printf '%s\n' 'touch "'$marker'"' > "$R3MINI_RUNTIME"
load_runtime
test ! -e "$marker"
echo RUNTIME_DATA_ONLY=PASS

printf 999999 > "$R3MINI_LOCK"
with_lock sh -c 'printf stale-recovered > "'$marker'"'
test "$(cat "$marker")" = stale-recovered
test ! -e "$R3MINI_LOCK"
rm -f "$marker"
printf '%s\n' "$$" > "$R3MINI_LOCK"
with_lock sh -c 'printf should-not-run > "'$marker'"'
test ! -e "$marker"
rm -f "$R3MINI_LOCK"
echo LOCK_RECOVERY_AND_CONTENTION=PASS

preclaim="${{R3MINI_LOCK}}.999998"; printf 999998 > "$preclaim"
take_lock "$R3MINI_LOCK"
if ln "$preclaim" "$R3MINI_LOCK" 2>/dev/null; then exit 1; fi
drop_lock "$R3MINI_LOCK"; rm -f "$preclaim"
echo ATOMIC_LOCK_CLAIM=PASS

event_lock="${{R3MINI_LOCK}}-event"
printf '%s\n' "$$" > "$event_lock"
(sleep 0.1; rm -f "$event_lock") &
with_event_lock sh -c 'printf event-ran > "'$marker'"'
test "$(cat "$marker")" = event-ran
rm -f "$marker"
echo EVENT_LOCK_RETRY=PASS

tmp="/tmp/r3mini-probe-cleanup-$$"
mkdir -p "$tmp"; sleep 30 & probe_pid=$!; unrelated_pid="$probe_pid"
cleanup_probe
test ! -d "$tmp"; test -z "$probe_pid"
kill "$unrelated_pid" 2>/dev/null || true; wait "$unrelated_pid" 2>/dev/null || true
echo PROBE_CLEANUP=PASS

yq() {{ printf '%s\n' 'providers/missing.yaml'; }}
provider_tmp="/tmp/r3mini-provider-test-$$"; mkdir -p "$provider_tmp"
if copy_provider_files unused /tmp "$provider_tmp"; then exit 1; fi
rm -rf "$provider_tmp"
echo MISSING_PROVIDER_FAIL_CLOSED=PASS

curl() {{
    case "$*" in
        *https://claude.ai/*) printf '%s\n' '200 0.120' ;;
        *https://api.anthropic.com/*) printf '%s\n' '401 0.350' ;;
        *) printf '%s\n' '429 0.010' ;;
    esac
}}
test "$(probe_endpoint 21000 probe:secret https://claude.ai/)" = 120
test "$(probe_endpoint 21000 probe:secret https://api.anthropic.com/)" = 350
if probe_endpoint 21000 probe:secret https://invalid.example/; then exit 1; else test "$?" -eq 2; fi
echo CLAUDE_ENDPOINT_POLICY=PASS

PENDING='{shell_path(tmp / "pending")}'
probe_count='{shell_path(tmp / "probe-count")}'
take_lock() {{ return 0; }}
drop_lock() {{ return 0; }}
run_probe() {{ printf x >> "$probe_count"; }}
mkdir "$PENDING"
mkdir "$PENDING" 2>/dev/null || true
drain_probe_queue
test "$(cat "$probe_count")" = x
test ! -d "$PENDING"
echo PROBE_WAKE_COALESCED=PASS

ss() {{ printf '%s\n' 'LISTEN 0 4096 127.0.0.1:21042 0.0.0.0:* users:(("clash",pid=4242,fd=9))'; }}
port_owned_by_pid 21042 4242
if port_owned_by_pid 21042 9999; then exit 1; fi
if port_owned_by_pid 21043 4242; then exit 1; fi
echo MIXED_PORT_OWNER_CHECK=PASS

event_capture='{shell_path(tmp / "event-capture")}'
monotonic_ms() {{ printf 1123; }}
write_event_timing() {{ printf '%s|%s|%s\n' "$1" "$2" "$3" > "$event_capture"; }}
with_event_lock() {{ "$@"; }}
event_reconcile() {{ event_processed=1; }}
R3MINI_EVENT_STARTED_MS=1000 R3MINI_EVENT_ACTION=ifdown R3MINI_EVENT_INTERFACE=wan event_main
test "$(cat "$event_capture")" = '1000|ifdown|wan'
echo EVENT_MILLISECOND_TIMING=PASS
""",
            encoding="utf-8",
            newline="\n",
        )
        result = subprocess.run(
            [bash_path(), shell_path(harness)],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            env={**os.environ, "LC_ALL": "C.UTF-8"},
            check=False,
        )
        if result.returncode:
            raise AssertionError(f"behavioral shell failed\n{result.stdout}\n{result.stderr}\n{harness.read_text(encoding='utf-8')}")
        return result.stdout.strip()


def static_contracts() -> None:
    manager = MANAGER.read_text(encoding="utf-8")
    web = WEB.read_text(encoding="utf-8")
    ui = UI.read_text(encoding="utf-8")
    deploy = DEPLOY.read_text(encoding="utf-8")
    hotplug = HOTPLUG.read_text(encoding="utf-8")
    acl = json.loads(ACL.read_text(encoding="utf-8"))
    assert '"$core" -d "$tmp/home" -f "$tmp/config.yaml"' in manager
    assert '"$probe_base/configs"' not in manager
    assert "-X PATCH" not in manager
    assert '"$main_base/configs"' not in manager
    assert '"$main_base" "$discovery/main.header"' in manager
    assert 'Authorization: Bearer $secret"' not in manager
    assert '[ -r "$RUNTIME" ] && . "$RUNTIME"' not in manager
    assert 'del(.port, .["socks-port"]' in manager
    assert "PROBE_URL_CLAUDE='https://claude.ai/'" in manager
    assert "PROBE_URL_ANTHROPIC='https://api.anthropic.com/'" in manager
    assert '--proxy-user "$auth"' in manager and "--noproxy '' --proto '=https'" in manager
    assert 'port_owned_by_pid "$controller_port" "$probe_pid"' in manager
    assert 'port_owned_by_pid "$mixed_port" "$probe_pid"' in manager
    assert '.["interface-name"] = strenv(PROBE_DEVICE)' in manager
    assert '.authentication = [strenv(PROBE_AUTH)]' in manager
    assert 'del(.proxies[]?."interface-name", .proxies[]?."routing-mark"' in manager
    assert 'selected="$(api_get "$probe_base"' in manager
    assert 'probe_score=\'\'; probe_kind "$core"' in manager
    assert "probe_url" not in (ROOT / "router" / "etc" / "config" / "r3mini_hotspot").read_text(encoding="utf-8")
    assert "auto_min_improvement_ms" in manager and "auto_confirmations" in manager
    assert "auto-select) shift; lock_write auto_select" in web
    assert '*) preferred=auto;; esac' in web
    assert 'set_egress "$1" auto 0' in web
    assert 'if [ "$persist" = 1 ]; then' in web
    assert "智能自动" in ui and "Claude 业务出口探针" in ui
    assert "setInterval(function()" in ui and "}, 250);" in ui and "poll.add" not in ui
    assert "实时出口状态未知" in ui and "routes[i].classList.remove('active')" in ui
    assert ".rh-probe.error" in ui and ".rh-probe.warn" in ui
    assert ".rh-prefer{min-height:44px" in ui
    assert ".r3hotspot-app{box-sizing:border-box}" in ui
    assert "热点未连接，正在重连" in ui
    assert "fs.write(keyFile, password, 384)" in ui and "['apply-file', '1', ssid, keyFile]" in ui
    assert "['apply', enabled ? '1' : '0', ssid, password]" not in ui
    assert 'stage_secret "$backup" "wireless.$STA.key" "$key"' in web
    assert 'stage_set "$backup" "wireless.$STA.key=$key"' not in web
    assert "apply 0 <热点SSID>" in web and "apply <0|1> <热点SSID> <热点密码>" not in web
    assert "AutoAddPolicy" not in (ROOT / "deploy_hotspot.py").read_text(encoding="utf-8")
    assert "/tmp/r3mini-hotspot-key-*" in acl["luci-app-r3mini-hotspot"]["write"]["file"]
    assert '[ -n "$(if_ip wan)" ]' in web
    assert "MANAGED_FILES=8" in deploy
    assert "r3mini-egress-manager wake" in hotplug
    assert "R3MINI_EVENT_STARTED_MS" in hotplug and "R3MINI_EVENT_ACTION" in hotplug
    assert "monotonic_ms()" in manager and "write_event_timing()" in manager
    assert 'json_add_int started_ms "$started"' in manager
    assert 'json_add_string proof_id "${proof_id:-}"' in manager
    assert "write_probe_proof" in manager and "record_probe_proof" in manager
    assert "wan_leaf_sha" in manager and "hotspot_leaf_sha" in manager
    assert "event_elapsed_ms" in web and "event_age" in web
    assert "最近链路事件" in ui and "eventTiming(status)" in ui
    verify = VERIFY.read_text(encoding="utf-8")
    verify_router = VERIFY_ROUTER.read_text(encoding="utf-8")
    assert "updated_mono_ms" in manager and "updated_mono_ms" in verify_router
    assert "transport.connect()" in verify and "AutoAddPolicy" not in verify
    assert "--allow-runtime-change" in verify and "--allow-config-change" in verify
    assert "production_openclash_changed" in verify_router
    assert "manual_restore_failed" in verify_router and "AUTO_VERIFY=PASS" in verify_router and "TIMING_VERIFY=PASS" in verify_router
    assert "verify_probe_proof" in verify_router and "probe_pid_reused" in verify_router
    assert "timing_requires_auto_preference" in verify_router and "timing_wan_failover_missing" in verify_router
    assert 'restored=1\n\t}' in verify_router
    assert "timeout = 900" in verify


def ui_behavior_test() -> str:
    node = str(NODE) if NODE.is_file() else shutil.which("node")
    if not node:
        raise SystemExit("NODE_NOT_FOUND")
    script = r"""
const fs = require('fs');
let source = fs.readFileSync(process.argv[2], 'utf8');
source = source.replace('return view.extend({', 'globalThis.__routeDelay = routeDelay; globalThis.__eventTiming = eventTiming; return view.extend({');
const mod = new Function('view', 'fs', 'ui', 'E', 'TextEncoder', 'setInterval', 'clearInterval', 'setTimeout', 'clearTimeout', source)(
  { extend: x => x }, {}, {}, () => ({}), TextEncoder, setInterval, clearInterval, setTimeout, clearTimeout
);
if (globalThis.__routeDelay({ probe_stale: true, probe_wan_ms: '42' }, 'wan') !== '已过期') throw new Error('stale delay');
if (globalThis.__routeDelay({ probe_stale: false, probe_wan_ms: '42' }, 'wan') !== '42 ms') throw new Error('fresh delay');
if (globalThis.__eventTiming({ event_elapsed_ms: 123, event_action: 'ifdown', event_interface: 'wan', event_age: 2 }) !== '123 ms · ifdown / wan · 2 秒前') throw new Error('event timing');
if (globalThis.__eventTiming({ event_elapsed_ms: -1 }) !== '等待首次链路事件') throw new Error('event idle');
const nodes = new Map();
function classList() {
  const values = new Set();
  return { add(x) { values.add(x); }, remove(x) { values.delete(x); }, toggle(x, on) { on ? values.add(x) : values.delete(x); }, contains(x) { return values.has(x); } };
}
function node(key) { if (!nodes.has(key)) nodes.set(key, { textContent: '', disabled: false, classList: classList() }); return nodes.get(key); }
function route(key) { const detail = node(key + '-detail'); const value = node(key); value.querySelector = () => detail; return value; }
const routes = [route('r1'), route('r2'), route('r3')];
const preferences = [node('p1'), node('p2'), node('p3'), node('p4')];
const target = Object.assign({}, mod, {
  statusRequest: null,
  statusFailures: 0,
  call() { return Promise.reject(new Error('offline')); },
  message() {},
  root: { querySelector: node, querySelectorAll(selector) { return selector === '.rh-route' ? routes : preferences; } }
});
(async () => {
  await target.refreshStatus();
  await target.refreshStatus();
  if (routes.some(x => x.querySelector().textContent !== '状态未知')) throw new Error('rpc stale state');
  if (routes.some(x => x.classList.contains('active') || !x.classList.contains('unknown'))) throw new Error('rpc stale highlight');
  if (node('#rh-egress').textContent !== '实时出口状态未知') throw new Error('rpc stale title');
  if (preferences.some(x => !x.disabled)) throw new Error('rpc stale controls');
  if (!node('#rh-probe-card').classList.contains('error')) throw new Error('rpc probe color');
  if (node('#rh-egress-meta').textContent.indexOf('实时状态已过期') < 0) throw new Error('rpc stale hint');
  console.log('STALE_DELAY_RENDER=PASS');
  console.log('RPC_FAILURE_STATE=PASS');
})().catch(error => { console.error(error); process.exit(1); });
"""
    with tempfile.TemporaryDirectory(prefix="r3mini-ui-") as raw:
        path = Path(raw) / "test.js"
        path.write_text(script, encoding="utf-8", newline="\n")
        result = subprocess.run(
            [node, str(path), str(UI)],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
    if result.returncode:
        raise AssertionError(f"UI behavior failed\n{result.stdout}\n{result.stderr}")
    return result.stdout.strip()


def deploy_rollback_test() -> str:
    path = ROOT / "deploy_hotspot.py"
    spec = importlib.util.spec_from_file_location("r3mini_deploy_hotspot_test", path)
    if spec is None or spec.loader is None:
        raise AssertionError("deploy module spec unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original_run, original_put = module.run, module.put
    backup_marker = "BACKUP=/root/r3mini-hotspot-backup-20260719235959\n"

    def exercise(mode: str) -> None:
        rolled_back: list[str] = []

        def fake_put(*_args: object, **_kwargs: object) -> None:
            return None

        def fake_run(_client: object, command: str, timeout: int = 60) -> str:
            if "ubus call system board" in command:
                return "bananapi,bpi-r3-mini\n"
            if command.startswith("sh '/tmp/deploy-hotspot-"):
                return backup_marker
            if command.startswith("sha256sum "):
                if mode == "hash-command-error":
                    raise RuntimeError("sha256 unavailable")
                return "\n".join(
                    f"{hashlib.sha256((module.ROOT / 'router' / Path(relative)).read_bytes()).hexdigest()}  /{relative}"
                    for relative in module.MANAGED_FILES
                )
            if command == "test -s /etc/config/r3mini_hotspot && echo preserved":
                return "" if mode == "config-missing" else "preserved\n"
            if command.startswith("set -e; b='/root/r3mini-hotspot-backup-"):
                rolled_back.append(command)
                return ""
            raise AssertionError(f"unexpected remote command: {command}")

        module.put, module.run = fake_put, fake_run
        with contextlib.redirect_stdout(io.StringIO()):
            try:
                module.deploy(object())
            except RuntimeError:
                pass
            else:
                raise AssertionError(f"{mode} should fail")
        if len(rolled_back) != 1:
            raise AssertionError(f"{mode} rollback count={len(rolled_back)}")

    try:
        exercise("hash-command-error")
        exercise("config-missing")
    finally:
        module.run, module.put = original_run, original_put
    return "DEPLOY_POSTCHECK_ROLLBACK=PASS"


def web_secret_test() -> str:
    with tempfile.TemporaryDirectory(prefix="r3mini-web-secret-") as raw:
        tmp = Path(raw)
        argv = tmp / "argv"
        stdin = tmp / "stdin"
        harness = tmp / "secret.sh"
        harness.write_text(
            f"""#!/bin/sh
set -eu
export R3MINI_HOTSPOT_LIB=1
. '{shell_path(WEB)}'
uci() {{ printf '%s\\n' "$@" > '{shell_path(argv)}'; cat > '{shell_path(stdin)}'; }}
rollback_apply() {{ exit 90; }}
stage_secret unused wireless.test_key "abc'def"
test "$(tr '\\n' ' ' < '{shell_path(argv)}')" = '-q batch '
! grep -q 'abc\\|def' '{shell_path(argv)}'
grep -q '^set wireless.test_key=' '{shell_path(stdin)}'
grep -q 'abc' '{shell_path(stdin)}'
grep -q 'def' '{shell_path(stdin)}'
echo PASSWORD_UCI_STDIN_ONLY=PASS
""",
            encoding="utf-8",
            newline="\n",
        )
        result = subprocess.run(
            [bash_path(), shell_path(harness)],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise AssertionError(f"web secret test failed\n{result.stdout}\n{result.stderr}")
        return result.stdout.strip()


def verify_cli_test() -> str:
    spec = importlib.util.spec_from_file_location("r3mini_verify_egress_test", VERIFY)
    if spec is None or spec.loader is None:
        raise AssertionError("verify module spec unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.remote_args(SimpleNamespace(mode="preflight")) == ["preflight"]
    assert module.remote_args(SimpleNamespace(mode="timing", trials=10, action="ifdown")) == ["timing", "10", "ifdown"]
    try:
        module.remote_args(SimpleNamespace(mode="probe", allow_runtime_change=False))
    except SystemExit as error:
        assert "allow-runtime-change" in str(error)
    else:
        raise AssertionError("probe gate missing")
    try:
        module.remote_args(SimpleNamespace(mode="manual", target="wan", allow_config_change=False))
    except SystemExit as error:
        assert "allow-config-change" in str(error)
    else:
        raise AssertionError("manual gate missing")
    try:
        module.remote_args(SimpleNamespace(mode="auto", allow_config_change=False))
    except SystemExit as error:
        assert "allow-config-change" in str(error)
    else:
        raise AssertionError("auto gate missing")
    assert module.remote_args(SimpleNamespace(mode="probe", allow_runtime_change=True)) == ["probe"]
    assert module.remote_args(SimpleNamespace(mode="manual", target="hotspot", allow_config_change=True)) == ["manual", "hotspot"]
    assert module.remote_args(SimpleNamespace(mode="auto", allow_config_change=True)) == ["auto"]
    calls: list[tuple[str, int]] = []

    class FakeClient:
        def close(self) -> None:
            return None

    original_connect, original_put, original_run = module.transport.connect, module.transport.put, module.transport.run

    def fake_connect() -> FakeClient:
        return FakeClient()

    def fake_put(*_args: object, **_kwargs: object) -> None:
        return None

    def fake_run(_client: object, command: str, timeout: int = 60) -> str:
        calls.append((command, timeout))
        return "AUTO_VERIFY=PASS\n" if "'auto'" in command else ""

    module.transport.connect, module.transport.put, module.transport.run = fake_connect, fake_put, fake_run
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            assert module.verify(SimpleNamespace(host="192.0.2.1", mode="auto", allow_config_change=True)) == 0
    finally:
        module.transport.connect, module.transport.put, module.transport.run = original_connect, original_put, original_run
    assert any("'auto'" in command and timeout == 900 for command, timeout in calls)
    return "VERIFY_CLI_GATES=PASS\nAUTO_TIMEOUT_BUDGET=PASS"


def verify_router_behavior_test() -> str:
    with tempfile.TemporaryDirectory(prefix="r3mini-verify-router-") as raw:
        harness = Path(raw) / "verify.sh"
        harness.write_text(
            f"""#!/bin/sh
set -eu
export R3MINI_VERIFY_LIB=1
. '{shell_path(VERIFY_ROUTER)}'
test "$(auto_decision wan wan 100 100 20 15)" = lowest-delay
test "$(auto_decision wan hotspot 100 90 20 15)" = hysteresis-hold
if auto_decision wan hotspot 100 50 20 15 >/dev/null; then exit 1; else test "$?" -eq 1; fi
if auto_decision wan hotspot invalid 50 20 15 >/dev/null; then exit 1; else test "$?" -eq 2; fi
timing_event_matches 1123 1000 123 ifdown wan ifdown
if timing_event_matches 1123 1000 122 ifdown wan ifdown; then exit 1; fi
if timing_event_matches 1123 1000 123 ifdown wwan ifdown; then exit 1; fi
echo AUTO_VERIFY_POLICY=PASS
echo TIMING_EVENT_FORMULA=PASS

PROOF_ID=0123456789abcdef0123456789abcdef
LEAF_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WAN_PID=101
HOTSPOT_PID=102
HOTSPOT_LEAF="$LEAF_SHA"
CURRENT_KIND=hotspot
HOTSPOT_UP=true
status_value() {{ case "$1" in egress_kind) printf '%s' "$CURRENT_KIND";; wired_wan_up) printf true;; wwan_up) printf '%s' "$HOTSPOT_UP";; cellular_up) printf false;; esac; }}
kind_dev() {{ case "$1" in wan) printf eth1;; hotspot) printf phy1-sta0;; esac; }}
jsonfilter() {{
    local expr=''
    while [ "$#" -gt 0 ]; do case "$1" in -e) expr="$2"; shift 2;; *) shift;; esac; done
    case "$expr" in
        '@.proof_id') printf '%s' "$PROOF_ID";;
        '@.leaf_sha') printf '%s' "$LEAF_SHA";;
        '@.wan_pid') printf '%s' "$WAN_PID";;
        '@.wan_device') printf eth1;;
        '@.wan_ms') printf 80;;
        '@.wan_leaf_sha') printf '%s' "$LEAF_SHA";;
        '@.hotspot_pid') printf '%s' "$HOTSPOT_PID";;
        '@.hotspot_device') printf phy1-sta0;;
        '@.hotspot_ms') printf 70;;
        '@.hotspot_leaf_sha') printf '%s' "$HOTSPOT_LEAF";;
    esac
}}
verify_probe_proof
if (HOTSPOT_PID=101; verify_probe_proof >/dev/null 2>&1); then exit 1; fi
if (HOTSPOT_LEAF=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; verify_probe_proof >/dev/null 2>&1); then exit 1; fi
echo PROBE_PROOF_CONTRACT=PASS
verify_wan_failover
if (CURRENT_KIND=wan; verify_wan_failover >/dev/null 2>&1); then exit 1; fi
if (HOTSPOT_UP=false; verify_wan_failover >/dev/null 2>&1); then exit 1; fi
echo WAN_FAILOVER_CONTRACT=PASS
""",
            encoding="utf-8",
            newline="\n",
        )
        result = subprocess.run(
            [bash_path(), shell_path(harness)],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise AssertionError(f"verify router behavior failed\n{result.stdout}\n{result.stderr}")
        return result.stdout.strip()


def restore_signal_test() -> str:
    with tempfile.TemporaryDirectory(prefix="r3mini-restore-signal-") as raw:
        tmp = Path(raw)
        pref = tmp / "preference"
        fail_once = tmp / "restore-failed-once"
        web = tmp / "web"
        harness = tmp / "signal.sh"
        pref.write_text("wan\n", encoding="utf-8")
        web.write_text(
            """#!/bin/sh
target="$2"
if [ "$target" = hotspot ]; then
    printf 'hotspot\n' > "$PREF_FILE"
    sleep 0.5
    printf '{"egress_kind":"hotspot"}\n'
    exit 0
fi
if [ "$target" = wan ] && [ ! -e "$FAIL_ONCE" ]; then
    : > "$FAIL_ONCE"
    exit 1
fi
printf '%s\n' "$target" > "$PREF_FILE"
printf '{"egress_kind":"%s"}\n' "$target"
""",
            encoding="utf-8",
            newline="\n",
        )
        web.chmod(0o755)
        harness.write_text(
            f"""#!/bin/sh
set -eu
export R3MINI_VERIFY_LIB=1
export R3MINI_WEB='{shell_path(web)}'
export PREF_FILE='{shell_path(pref)}'
export FAIL_ONCE='{shell_path(fail_once)}'
. '{shell_path(VERIFY_ROUTER)}'
preflight() {{ :; }}
status_value() {{ printf true; }}
uci() {{ cat "$PREF_FILE"; }}
jsonfilter() {{ sed -n 's/.*"egress_kind":"\\([^"]*\\)".*/\\1/p'; }}
manual_check hotspot & check_pid=$!
sleep 0.1
kill -HUP "$check_pid"
set +e
wait "$check_pid"
rc=$?
set -e
test "$rc" -eq 130
test "$(cat "$PREF_FILE")" = wan
test -e "$FAIL_ONCE"
echo SIGNAL_RESTORE_RETRY=PASS
""",
            encoding="utf-8",
            newline="\n",
        )
        result = subprocess.run(
            [bash_path(), shell_path(harness)],
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise AssertionError(f"signal restore failed\n{result.stdout}\n{result.stderr}\n{harness.read_text(encoding='utf-8')}")
        return result.stdout.strip()


if __name__ == "__main__":
    static_contracts()
    print("STATIC_CONTRACTS=PASS")
    print(behavioral_test())
    print(ui_behavior_test())
    print(deploy_rollback_test())
    print(web_secret_test())
    print(verify_cli_test())
    print(verify_router_behavior_test())
    print(restore_signal_test())
