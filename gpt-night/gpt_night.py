"""GPT 夜间省流：夜里把 ChatGPT 分流切到便宜订阅的 0.1 倍节点，早上恢复原规则。
本机守护盯 Codex 的真实大请求：变慢或断连就立刻停用规则回原分流（🤖 AI），再恢复切换前的节点。

  python gpt-night/gpt_night.py night [--trial 分钟]   计划任务 00:00：测速夜间源 → 切到第一个通过的夜间节点 → 守护到 07:20
  python gpt-night/gpt_night.py day                    计划任务 07:30：恢复切换前的规则
  python gpt-night/gpt_night.py rollback [原因]        立刻回退并恢复切换前的规则
  python gpt-night/gpt_night.py status                 规则、夜间标记、计划任务、路由器夜间日志
  python gpt-night/gpt_night.py install | uninstall    路由器兜底（cron 08:30）与本机两个计划任务

改路由只经 r3mini-chatgpt 模块自己的命令（benchmark / save / set-enabled），不直接改 OpenClash 配置。
--trial 忽略夜间时段，守护指定分钟后结束（试运行用，之后运行 day 恢复）。
"""
from __future__ import annotations

import json
import pathlib
import re
import shlex
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta
from datetime import time as dtime

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
LOG_DIR = ROOT / "tmp" / "gpt-night"
CODEX_HOME = pathlib.Path.home() / ".codex"

HOST = "192.168.0.242"
RULE_ID = "6c30a15270ea"
CLI = "/usr/sbin/r3mini-chatgpt"
MARKER = "/etc/r3mini-gpt-night.json"
ROUTER_LOG = "/mnt/mmcblk0p6/r3mini-gpt-night.log"
FAILSAFE = "/usr/sbin/r3mini-gpt-night-failsafe"
FAILSAFE_LOCAL = HERE / "router" / "usr" / "sbin" / "r3mini-gpt-night-failsafe"
CRON_TAG = "#r3mini-gpt-night"
CRON_LINE = f"30 8 * * * {FAILSAFE} >/dev/null 2>&1 {CRON_TAG}"
NIGHT_SOURCE = "peiqian_lv.yaml"
# 按优先级。都是 0.1 倍计费的 vless（TCP）；东京09 测速通过但 2026-10-25 上传实测失败，不用。
NIGHT_NODES = {"ec534e9910c8f868": "日本东京07-0.1倍", "fd14ad7e7dbad6f9": "日本东京08-0.1倍"}
WINDOW_START, WINDOW_END, GUARD_UNTIL = dtime(23, 30), dtime(7, 0), dtime(7, 20)
STALE = 12 * 3600           # 标记比这更旧：上一晚没收尾
BIG = 10 * 1048576          # Codex 每次带全量上下文；>10 MB 的请求才拿来判断上传
HEADER_TIMEOUT = 45         # 同期 MESL 31 个大请求都在 7–21 秒内拿到响应头
FAIL_LIMIT, FAIL_WINDOW = 2, 600
GRACE = 30                  # 切换并断开旧连接后，正在飞的请求会失败一次，不算
PROBE_EVERY, MARKER_EVERY, TICK = 300, 60, 10
TASKS = {"r3mini-gpt-night": ("00:00", "night", 9), "r3mini-gpt-day": ("07:30", "day", 1)}

# 断开规则域名上不走当前分流的旧连接（路由切换只影响新连接，Codex 会长时间复用旧连接）：
# 组存在时保留组成员上的连接；规则停用、组已移除时断开本规则专属节点上的连接。参数：域名（逗号分隔）[dry]
CLOSE_SCRIPT = r"""
T=$(mktemp -d /tmp/r3gn.XXXXXX) || exit 1; umask 077; H=$T/h
printf 'Authorization: Bearer %s\n' "$(uci -q get openclash.config.dashboard_password)" > $H
P=$(uci -q get openclash.config.cn_port || echo 9090)
curl -s -m 10 -H @$H "http://127.0.0.1:$P/proxies/R3Site-RULE_ID" > $T/g.json
curl -s -m 10 -H @$H "http://127.0.0.1:$P/connections" > $T/c.json
cat > $T/c.uc <<'UC'
let fs = require('fs'), g = {}, d = {}, keep = {}, doms = split(ARGV[2], ',');
try { g = json(fs.readfile(ARGV[0])); } catch (e) {}
try { d = json(fs.readfile(ARGV[1])); } catch (e) {}
for (let n in g.all || []) keep[n] = true;
let grouped = length(keys(keep)) > 0;
function ours(h) {
	for (let s in doms)
		if (h == s || (length(h) > length(s) && substr(h, length(h) - length(s) - 1) == '.' + s)) return true;
	return false;
}
for (let x in d.connections || []) {
	let m = x.metadata || {}, h = m.host || m.sniffHost || '', ch = (x.chains || [])[0] || '';
	if (ours(h) && (grouped ? !keep[ch] : index(ch, 'r3mini-site-node-RULE_ID-') == 0)) print(x.id, '\n');
}
UC
n=0
for id in $(ucode $T/c.uc $T/g.json $T/c.json "$1"); do
	[ "$2" = dry ] || curl -s -m 5 -o /dev/null -X DELETE -H @$H "http://127.0.0.1:$P/connections/$id"
	n=$((n+1))
done
echo $n; rm -rf $T
""".replace("RULE_ID", RULE_ID)

# 当前组选中的节点经 chatgpt.com 能否连通；规则停用（没有组）时输出 NO_GROUP
PROBE_SCRIPT = r"""
T=$(mktemp -d /tmp/r3gn.XXXXXX) || exit 1; umask 077; H=$T/h
printf 'Authorization: Bearer %s\n' "$(uci -q get openclash.config.dashboard_password)" > $H
P=$(uci -q get openclash.config.cn_port || echo 9090)
now=$(curl -s -m 10 -H @$H "http://127.0.0.1:$P/proxies/R3Site-RULE_ID" | jsonfilter -e '@.now' 2>/dev/null)
if [ -z "$now" ]; then echo NO_GROUP
else curl -s -m 15 -H @$H "http://127.0.0.1:$P/proxies/$now/delay?timeout=8000&expected=200&url=https%3A%2F%2Fchatgpt.com%2Fcdn-cgi%2Ftrace" | jsonfilter -e '@.delay' 2>/dev/null || echo FAIL
fi
rm -rf $T
""".replace("RULE_ID", RULE_ID)


def log_local(msg: str) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    line = f"{datetime.now():%Y-%m-%dT%H:%M:%S} {msg}"
    with (LOG_DIR / "gpt-night.log").open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")
    print(line, flush=True)  # pythonw 下 sys.stdout 为 None，print 什么也不做


class Clock:
    def now(self) -> datetime:
        return datetime.now()

    def epoch(self) -> int:
        return int(time.time())

    def monotonic(self) -> float:
        return time.monotonic()

    def sleep(self, s: float) -> None:
        time.sleep(s)


class Router:
    """路由器上的全部动作；测试用假对象替换。"""

    def __init__(self, host: str = HOST):
        self.host, self.client = host, None

    def _run(self, command: str, data: bytes | None = None, timeout: int = 180) -> tuple[int, str]:
        if str(ROOT / "chatgpt-routing") not in sys.path:
            sys.path.insert(0, str(ROOT / "chatgpt-routing"))
        import manage  # noqa: E402 — 网站分流部署器的 SSH 连接：固定主机密钥，口令从私密文档在内存解析
        for attempt in (1, 2):
            try:
                if self.client is None:
                    self.client = manage.connect(self.host)
                rc, out, _ = manage.run(self.client, command, data=data, timeout=timeout, check=False)
                return rc, out.decode("utf-8", "replace")
            except Exception:  # noqa: BLE001 — 路由器重启或断网：重连一次
                self.client = None
                if attempt == 2:
                    raise
        raise AssertionError("unreachable")

    def cli(self, *args: str) -> dict:
        _, out = self._run(" ".join([CLI] + [shlex.quote(a) for a in args]))
        try:
            return json.loads(out or "{}")
        except ValueError:
            return {"ok": False, "error": "BAD_JSON"}

    def marker(self) -> dict | None:
        rc, out = self._run(f"cat {MARKER} 2>/dev/null")
        try:
            return json.loads(out) if rc == 0 and out.strip() else None
        except ValueError:
            return None

    def put_marker(self, m: dict) -> None:
        self._run(f"umask 077; cat > {MARKER}.tmp && mv {MARKER}.tmp {MARKER}", data=json.dumps(m, ensure_ascii=False).encode())

    def remove_marker(self) -> None:
        self._run(f"rm -f {MARKER}")

    def log(self, msg: str) -> None:
        log_local("router: " + msg)
        self._run("msg=$(cat); logger -t r3mini-gpt-night -- \"$msg\"; [ -d /mnt/mmcblk0p6 ] && "
                  f"printf '%s %s\\n' \"$(date '+%Y-%m-%dT%H:%M:%S')\" \"$msg\" >> {ROUTER_LOG}; true", data=msg.encode())

    def close_stale(self, domains: list[str], dry: bool = False) -> int:
        _, out = self._run(f"sh -s {shlex.quote(','.join(domains))}{' dry' if dry else ''}", data=CLOSE_SCRIPT.encode())
        return int(out.strip()) if out.strip().isdigit() else 0

    def probe(self) -> bool:
        _, out = self._run("sh -s", data=PROBE_SCRIPT.encode(), timeout=60)
        out = out.strip()
        return out == "NO_GROUP" or out.isdigit() and int(out) > 0


def find_rule(status: dict | None) -> dict | None:
    return next((r for r in (status or {}).get("site_rules") or [] if r.get("id") == RULE_ID), None)


def payload(before: dict, source: str | None = None, selected: str | None = None) -> str:
    p = {"id": RULE_ID, "label": before["label"], "domains": before["domains"],
         "source": source or before["source"], "selected": selected or before["selected"], "enabled": True}
    if before.get("preset"):
        p["preset"] = before["preset"]
    return json.dumps(p, ensure_ascii=False)


def live(rule: dict | None) -> bool:
    return bool(rule and rule.get("enabled") and rule.get("applied") and not rule.get("error"))


def applied(result: dict | None) -> bool:
    return bool(result and result.get("ok") and live(find_rule(result)))


def in_window(t: dtime) -> bool:
    return t >= WINDOW_START or t < WINDOW_END


def guard_end(now: datetime) -> datetime:
    end = datetime.combine(now.date(), GUARD_UNTIL)
    return end + timedelta(days=1) if now.time() >= WINDOW_START else end


def run_benchmark(router, clock, source: str, minutes: int) -> dict | None:
    """重新测速 source（测速助手全局一次只跑一个源，忙时等待），测完返回该源的 status。"""
    deadline, started = clock.monotonic() + minutes * 60, False
    while clock.monotonic() < deadline:
        if not started:
            r = router.cli("benchmark", source)
            started = bool(r.get("ok"))
            if not started and r.get("error") != "BENCH_BUSY":
                router.log(f"测速 {source} 启动失败：{r.get('error')}")
                return None
        clock.sleep(15)
        if started and not router.cli("benchmark-status", source).get("running"):
            return router.cli("status", source)
    router.log(f"测速 {source} {minutes} 分钟内没有完成")
    return None


def restore(router, clock, before: dict) -> bool:
    """把规则恢复为 before。模块要求所选节点有测速证明：先直接保存，缺证明就测速后再存；仍失败则停用规则回原分流。"""
    if applied(router.cli("save", payload(before))):
        return True
    if run_benchmark(router, clock, before["source"], 20) and applied(router.cli("save", payload(before))):
        return True
    router.cli("set-enabled", RULE_ID, "0")
    return False


class Judge:
    """增量读 Codex 日志库，按真实请求判断夜间线路；返回回退原因，合格时返回 None。"""

    def __init__(self, db: pathlib.Path, start_id: int, grace_until: float):
        self.db, self.last_id, self.grace_until = db, start_id, grace_until
        self.pending: dict[str, float] = {}
        self.fails: list[int] = []

    def feed(self, now: float) -> str | None:
        con = sqlite3.connect(f"file:{self.db.as_posix()}?mode=ro", uri=True, timeout=5)
        try:
            rows = con.execute("""select id, ts, ts_nanos, thread_id, feedback_log_body from logs where id > ? and
                (feedback_log_body like '%Compressed request body%'
                 or feedback_log_body like '%Request completed method=POST url=https://chatgpt.com/backend-api/codex/responses%'
                 or feedback_log_body like '%Request failed method=POST url=https://chatgpt.com/backend-api/codex/responses%')
                order by id""", (self.last_id,)).fetchall()
        finally:
            con.close()
        for rid, ts, ns, th, body in rows:
            self.last_id = rid
            t = ts + ns / 1e9
            if "Compressed request body" in body:
                m = re.search(r"post_compression_bytes=(\d+)", body)
                if m and int(m[1]) > BIG:
                    self.pending[th] = t
            elif "Request completed" in body:
                start = self.pending.pop(th, None)
                if start is not None and t - start > HEADER_TIMEOUT:
                    return f"大请求 {t - start:.0f} 秒才拿到响应头（上限 {HEADER_TIMEOUT} 秒）"
            else:
                self.pending.pop(th, None)
                if ts >= self.grace_until:
                    self.fails.append(ts)
        self.fails = [f for f in self.fails if f >= now - FAIL_WINDOW]
        if len(self.fails) >= FAIL_LIMIT:
            return f"{FAIL_WINDOW // 60} 分钟内 chatgpt.com 请求失败 {len(self.fails)} 次"
        stuck = max((now - s for s in self.pending.values()), default=0)
        if stuck > HEADER_TIMEOUT:
            return f"大请求 {stuck:.0f} 秒没有响应头（上限 {HEADER_TIMEOUT} 秒）"
        return None


def codex_logs() -> pathlib.Path | None:
    found = sorted(CODEX_HOME.glob("logs_*.sqlite"), key=lambda p: p.stat().st_mtime)
    return found[-1] if found else None


def max_log_id(db: pathlib.Path | None) -> int:
    if not db:
        return 0
    con = sqlite3.connect(f"file:{db.as_posix()}?mode=ro", uri=True, timeout=5)
    try:
        return con.execute("select coalesce(max(id), 0) from logs").fetchone()[0]
    finally:
        con.close()


def rollback(router, clock, reason: str) -> str:
    m = router.marker()
    if not m or m.get("mode") not in ("night", "rolled_back"):   # rolled_back：上次回退中途出错，接着恢复
        log_local(f"rollback: 不在夜间模式（标记 {m and m.get('mode')}），不动规则")
        return "NOT_IN_NIGHT_MODE"
    before = m["before"]
    r = router.cli("set-enabled", RULE_ID, "0")   # 立刻回原分流 🤖 AI，不等测速
    closed = router.close_stale(before["domains"])
    m.update(mode="rolled_back", reason=reason, at=clock.epoch())
    router.put_marker(m)
    router.log(f"rollback: {reason}；停用规则回原分流 ok={bool(r.get('ok'))}，断开旧连接 {closed} 条")
    if not restore(router, clock, before):
        router.log(f"rollback: 恢复 {before['source']}:{before['selected_name']} 失败，保持原分流，等白天任务再试")
        return "ROLLED_BACK"
    closed = router.close_stale(before["domains"])
    m.update(mode="restored", at=clock.epoch())
    router.put_marker(m)                        # 留着标记：今晚不再切换，白天任务清理
    router.log(f"rollback: 已恢复 {before['source']}:{before['selected_name']}，断开旧连接 {closed} 条")
    return "RESTORED"


def guard(router, clock, end: datetime, judge: Judge | None) -> str:
    last_probe = last_marker = clock.monotonic()
    probe_fails = 0
    while clock.now() < end:
        clock.sleep(TICK)
        t = clock.monotonic()
        try:
            reason = judge.feed(clock.epoch()) if judge else None
            if reason:
                return rollback(router, clock, "本机守护：" + reason)
            if t - last_probe >= PROBE_EVERY:
                last_probe = t
                probe_fails = 0 if router.probe() else probe_fails + 1
                if probe_fails >= 2:
                    return rollback(router, clock, "本机守护：经夜间节点连续 2 次连不上 chatgpt.com")
            if t - last_marker >= MARKER_EVERY:
                last_marker = t
                m = router.marker()
                if not m or m.get("mode") != "night":
                    log_local(f"guard: 夜间标记变成 {m and m.get('mode')}，守护结束")
                    return "MARKER_CHANGED"
        except Exception as e:  # noqa: BLE001 — 路由器重启、日志库忙：记下来，下一轮再试
            log_local(f"guard: {type(e).__name__}: {e}")
    router.log("night: 守护到点结束，等 07:30 白天任务恢复原规则")
    return "GUARD_DONE"


def night(router, clock, logs: pathlib.Path | None = None, trial_minutes: int | None = None) -> str:
    now = clock.now()
    if trial_minutes is None and not in_window(now.time()):
        log_local(f"night: 现在 {now:%H:%M} 不在 23:30–07:00，跳过")
        return "OUTSIDE_WINDOW"
    end = now + timedelta(minutes=trial_minutes) if trial_minutes is not None else guard_end(now)
    db = logs or codex_logs()
    m = router.marker()
    if m and clock.epoch() - m.get("since", 0) > STALE:
        router.log("night: 上一晚没有收尾，先恢复原规则")
        day(router, clock)
        m = router.marker()
        if m:
            return "STALE_MARKER_KEPT"
    if m:
        if m.get("mode") == "night":
            router.log("night: 已在夜间模式，继续守护")
            return guard(router, clock, end, Judge(db, max_log_id(db), 0) if db else None)
        log_local(f"night: 今晚已经 {m.get('mode')}（{m.get('reason')}），不再切换")
        return "ALREADY_" + str(m.get("mode")).upper()
    rule = find_rule(router.cli("status"))
    if not live(rule):
        router.log("night: ChatGPT 规则没启用或没生效，不切换")
        return "RULE_NOT_ACTIVE"
    if rule.get("source") == NIGHT_SOURCE and rule.get("selected") in NIGHT_NODES:
        log_local("night: 规则已在夜间节点上，不切换")
        return "ALREADY_ON_NIGHT_NODE"
    before = {k: rule.get(k) for k in ("source", "selected", "selected_name", "label", "domains", "preset")}
    nodes = {n.get("id"): n for n in (run_benchmark(router, clock, NIGHT_SOURCE, 15) or {}).get("nodes") or []}
    node = next((i for i in NIGHT_NODES if nodes.get(i, {}).get("eligible")), None)
    if not node:
        router.log(f"night: {NIGHT_SOURCE} 的夜间节点测速都没通过，今晚不切换")
        return "NO_ELIGIBLE_NIGHT_NODE"
    start_id = max_log_id(db)
    marker = {"mode": "night", "rule": RULE_ID, "since": clock.epoch(), "before": before,
              "night": {"source": NIGHT_SOURCE, "selected": node, "name": NIGHT_NODES[node]}}
    router.put_marker(marker)   # 先写标记：保存中途出错时，兜底脚本与白天任务仍知道原规则
    result = router.cli("save", payload(before, NIGHT_SOURCE, node))
    if not applied(result):
        error = result.get("error") or (find_rule(result) or {}).get("error")
        cur = find_rule(router.cli("status")) or {}
        if (cur.get("source"), cur.get("selected")) == (before["source"], before["selected"]) and live(cur) or restore(router, clock, before):
            router.remove_marker()
            router.log(f"night: 切到 {NIGHT_NODES[node]} 失败（{error}），保持原规则")
        else:                   # 标记留给白天任务再恢复
            router.log(f"night: 切到 {NIGHT_NODES[node]} 失败（{error}），原规则也没恢复，已停用规则回原分流")
        return "SAVE_FAILED"
    closed = router.close_stale(before["domains"])
    router.log(f"night: ChatGPT 分流切到 {NIGHT_SOURCE} {NIGHT_NODES[node]}，断开旧连接 {closed} 条；"
               f"原规则 {before['source']}:{before['selected_name']}；守护到 {end:%m-%d %H:%M}")
    return guard(router, clock, end, Judge(db, start_id, clock.epoch() + GRACE) if db else None)


def day(router, clock) -> str:
    m = router.marker()
    if not m:
        log_local("day: 没有夜间标记，不用恢复")
        return "NOTHING"
    before, nightly = m.get("before") or {}, m.get("night") or {}
    rule = find_rule(router.cli("status")) or {}
    where = (rule.get("source"), rule.get("selected"))
    if m.get("mode") == "restored" or where == (before.get("source"), before.get("selected")) and live(rule):
        router.remove_marker()
        router.log(f"day: 规则已是原样 {before.get('source')}:{before.get('selected_name')}，清理夜间标记")
        return "ALREADY_RESTORED"
    if where != (nightly.get("source"), nightly.get("selected")):
        router.remove_marker()
        router.log(f"day: 规则已被改成 {where[0]}:{rule.get('selected_name')}，不覆盖，清理夜间标记")
        return "USER_CHANGED"
    ok = restore(router, clock, before)
    closed = router.close_stale(before["domains"])
    if ok:
        router.remove_marker()
        router.log(f"day: 恢复为 {before['source']}:{before['selected_name']}，断开旧连接 {closed} 条")
        return "RESTORED"
    router.log(f"day: 恢复 {before['source']}:{before['selected_name']} 失败，已停用规则回原分流（🤖 AI），标记保留待下次重试")
    return "DISABLED"


def install(router) -> None:
    data = FAILSAFE_LOCAL.read_bytes()
    if b"\r" in data:
        raise SystemExit("CRLF_IN_FAILSAFE")
    backup = LOG_DIR / f"backup-{datetime.now():%Y%m%d-%H%M%S}"
    backup.mkdir(parents=True)
    _, cron = router._run("cat /etc/crontabs/root 2>/dev/null")
    _, settings = router._run("cat /etc/r3mini-chatgpt/settings.json")
    (backup / "crontab-root").write_text(cron, encoding="utf-8", newline="\n")
    (backup / "r3mini-chatgpt-settings.json").write_text(settings, encoding="utf-8", newline="\n")
    rc, out = router._run(f"umask 022; cat > {FAILSAFE}.new && sh -n {FAILSAFE}.new && chmod 755 {FAILSAFE}.new && "
                          f"mv {FAILSAFE}.new {FAILSAFE} && sha256sum {FAILSAFE}", data=data)
    if rc != 0:
        raise SystemExit(f"FAILSAFE_INSTALL_FAILED {out.strip()}")
    lines = [line for line in cron.splitlines() if CRON_TAG not in line] + [CRON_LINE]
    router._run("umask 077; cat > /etc/crontabs/root.r3gn && mv /etc/crontabs/root.r3gn /etc/crontabs/root && /etc/init.d/cron restart",
                data=("\n".join(lines) + "\n").encode())
    _, after = router._run("cat /etc/crontabs/root")
    if after.splitlines() != lines:
        raise SystemExit(f"CRON_MISMATCH {after!r}")
    print(f"ROUTER_OK {out.split()[0][:16]} cron: {CRON_LINE}  backup: {backup}")
    pyw = pathlib.Path(sys.executable).with_name("pythonw.exe")
    for name, (at, cmd, hours) in TASKS.items():
        ps = (f"$a = New-ScheduledTaskAction -Execute '{pyw}' -Argument '\"{HERE / 'gpt_night.py'}\" {cmd}' -WorkingDirectory '{ROOT}';"
              f"$t = New-ScheduledTaskTrigger -Daily -At {at};"
              f"$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries "
              f"-MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours {hours});"
              f"Register-ScheduledTask -TaskName '{name}' -Action $a -Trigger $t -Settings $s -Force | Out-Null;"
              f"(Get-ScheduledTask -TaskName '{name}').State")
        out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], capture_output=True, text=True)
        print(f"TASK {name} {at} {cmd}: {out.stdout.strip() or out.stderr.strip()[:300]}")


def uninstall(router, clock) -> None:
    if router.marker():
        print("day:", day(router, clock))
    _, cron = router._run("cat /etc/crontabs/root 2>/dev/null")
    lines = [line for line in cron.splitlines() if CRON_TAG not in line]
    router._run("umask 077; cat > /etc/crontabs/root.r3gn && mv /etc/crontabs/root.r3gn /etc/crontabs/root && /etc/init.d/cron restart; "
                f"rm -f {FAILSAFE}", data=("\n".join(lines) + "\n").encode())
    for name in TASKS:
        subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                        f"Unregister-ScheduledTask -TaskName '{name}' -Confirm:$false -ErrorAction SilentlyContinue"])
    print("UNINSTALLED")


def status(router) -> None:
    rule = find_rule(router.cli("status")) or {}
    print("规则:", {k: rule.get(k) for k in ("source", "selected_name", "enabled", "applied", "error")})
    print("夜间标记:", router.marker())
    names = ",".join(f"'{n}'" for n in TASKS)
    out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                          f"foreach ($n in @({names})) {{ $i = Get-ScheduledTaskInfo -TaskName $n -ErrorAction SilentlyContinue; "
                          f"if ($i) {{ '{{0}} 上次 {{1}} 结果 {{2}} 下次 {{3}}' -f $n, $i.LastRunTime, $i.LastTaskResult, $i.NextRunTime }} "
                          f"else {{ \"$n 未注册\" }} }}"], capture_output=True, text=True)
    print(out.stdout.strip())
    _, log = router._run(f"tail -n 15 {ROUTER_LOG} 2>/dev/null")
    print("路由器夜间日志:\n" + log.strip())


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else ""
    router, clock = Router(), Clock()
    try:
        if cmd == "night":
            trial = int(argv[2]) if argv[1:2] == ["--trial"] and len(argv) > 2 else None
            log_local("night: " + night(router, clock, trial_minutes=trial))
        elif cmd == "day":
            log_local("day: " + day(router, clock))
        elif cmd == "rollback":
            log_local("rollback: " + rollback(router, clock, "手动：" + (" ".join(argv[1:]) or "未注明")))
        elif cmd == "status":
            status(router)
        elif cmd == "install":
            install(router)
        elif cmd == "uninstall":
            uninstall(router, clock)
        else:
            print(__doc__)
            return 2
    except Exception as e:  # noqa: BLE001 — 计划任务没有控制台，原因写进日志
        log_local(f"{cmd}: ERROR {type(e).__name__}: {e}")
        raise
    return 0


if __name__ == "__main__":
    if sys.stdout:
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main(sys.argv[1:]))
