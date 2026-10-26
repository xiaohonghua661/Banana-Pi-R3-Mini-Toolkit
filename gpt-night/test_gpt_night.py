"""gpt_night 离线测试：假路由器（模拟 r3mini-chatgpt 的测速证明规则）+ 假时钟 + 合成的 Codex 日志库。
运行：python gpt-night/test_gpt_night.py
"""
import json
import pathlib
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import gpt_night as g  # noqa: E402

g.log_local = lambda msg: None
TW01, TOKYO07, TOKYO08 = "bd7cdc171723bbdd", "ec534e9910c8f868", "fd14ad7e7dbad6f9"
NAMES = {TW01: "台湾 01 [0.3X]", TOKYO07: "东京07", TOKYO08: "东京08"}
MESL, NIGHT = "MESL_yue.yaml", g.NIGHT_SOURCE


class FakeRouter:
    """save 只接受有测速证明的节点；测速跑两轮状态查询后完成，给 eligible 里的节点发证明。"""

    def __init__(self):
        self.rule = {"id": g.RULE_ID, "label": "ChatGPT", "domains": ["chatgpt.com", "openai.com"], "preset": "",
                     "source": MESL, "selected": TW01, "selected_name": NAMES[TW01], "enabled": True, "applied": True, "error": None}
        self.mark = None
        self.eligible = {NIGHT: {TOKYO07, TOKYO08}, MESL: {TW01}}
        self.proof = {(MESL, TW01)}
        self.running = {}
        self.calls, self.logs, self.closes = [], [], []
        self.probe_ok = True
        self.save_error = None
        self.flaky = {}     # 命令 → 依次返回的偶发错误码，如 {"save": ["CONFIG_TEST_FAILED"]}

    def view(self):
        return {"ok": True, "site_rules": [dict(self.rule)]}

    def cli(self, *args):
        self.calls.append(args)
        cmd = args[0]
        if self.flaky.get(cmd):
            return {"ok": False, "error": self.flaky[cmd].pop(0)}
        if cmd == "status":
            src = args[1] if len(args) > 1 else self.rule["source"]
            ids = [TOKYO07, TOKYO08] if src == NIGHT else [TW01]
            return dict(self.view(), nodes=[{"id": i, "eligible": (src, i) in self.proof} for i in ids])
        if cmd == "benchmark":
            self.running[args[1]] = 2
            return {"ok": True, "running": True}
        if cmd == "benchmark-status":
            left = self.running.get(args[1], 0) - 1
            self.running[args[1]] = left
            if left == 0:
                self.proof |= {(args[1], i) for i in self.eligible.get(args[1], ())}
            return {"ok": True, "running": left > 0}
        if cmd == "save":
            p = json.loads(args[1])
            if self.save_error or (p["source"], p["selected"]) not in self.proof:
                return {"ok": False, "error": self.save_error or "BENCHMARK_REQUIRED"}
            self.rule.update(source=p["source"], selected=p["selected"], selected_name=NAMES[p["selected"]],
                             enabled=True, applied=True, error=None)
            return self.view()
        if cmd == "set-enabled":
            on = args[2] == "1"
            self.rule.update(enabled=on, applied=on)
            return self.view()
        raise AssertionError(args)

    def marker(self):
        return json.loads(json.dumps(self.mark)) if self.mark else None

    def put_marker(self, m):
        self.mark = json.loads(json.dumps(m))

    def remove_marker(self):
        self.mark = None

    def log(self, msg):
        self.logs.append(msg)

    def close_stale(self, domains, dry=False):
        self.closes.append((self.rule["source"], self.rule["selected"], self.rule["enabled"]))
        return 1

    def probe(self):
        return self.probe_ok

    def where(self):
        return self.rule["source"], self.rule["selected"], self.rule["enabled"]


class FakeClock:
    def __init__(self, start: datetime):
        self.start, self.t, self.events = start, 0.0, []

    def now(self):
        return self.start + timedelta(seconds=self.t)

    def epoch(self):
        return int(self.start.timestamp() + self.t)

    def monotonic(self):
        return self.t

    def sleep(self, s):
        self.t += s
        for ev in [e for e in self.events if e[0] <= self.t]:
            self.events.remove(ev)
            ev[1]()

    def at(self, seconds, fn):
        self.events.append((seconds, fn))


class CodexLogs:
    def __init__(self, path: pathlib.Path):
        self.path = path
        con = sqlite3.connect(path)
        con.execute("""create table logs (id integer primary key autoincrement, ts integer not null, ts_nanos integer not null,
                       level text not null, target text not null, feedback_log_body text, thread_id text)""")
        con.execute("insert into logs (ts, ts_nanos, level, target, feedback_log_body) values (0, 0, 'INFO', 'x', 'old')")
        con.commit()
        con.close()

    def add(self, clock, body, thread="t1"):
        con = sqlite3.connect(self.path)
        con.execute("insert into logs (ts, ts_nanos, level, target, feedback_log_body, thread_id) values (?, 0, 'INFO', 'codex', ?, ?)",
                    (clock.epoch(), body, thread))
        con.commit()
        con.close()

    def big(self, clock, thread="t1"):
        self.add(clock, f"Compressed request body with zstd pre_compression_bytes=60000000 post_compression_bytes={45 * 1048576}", thread)

    def done(self, clock, thread="t1"):
        self.add(clock, "Request completed method=POST url=https://chatgpt.com/backend-api/codex/responses status=200", thread)

    def failed(self, clock, thread="t1"):
        self.add(clock, "Request failed method=POST url=https://chatgpt.com/backend-api/codex/responses error=connection closed", thread)


MIDNIGHT = datetime(2026, 10, 26, 0, 0, 0)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = CodexLogs(pathlib.Path(self.tmp.name) / "logs.sqlite")
        self.r = FakeRouter()
        self.c = FakeClock(MIDNIGHT)

    def tearDown(self):
        self.tmp.cleanup()

    def night(self, **kw):
        return g.night(self.r, self.c, logs=self.db.path, **kw)

    def switched_at(self):
        """测速两轮状态查询各等 15 秒，切换发生在第 30 秒。"""
        return 30


class TimeWindow(unittest.TestCase):
    def test_window_and_guard_end(self):
        t = datetime(2026, 10, 25, 23, 40)
        self.assertTrue(g.in_window(t.time()))
        self.assertEqual(g.guard_end(t), datetime(2026, 10, 26, 7, 20))
        self.assertEqual(g.guard_end(MIDNIGHT), datetime(2026, 10, 26, 7, 20))
        self.assertFalse(g.in_window(datetime(2026, 10, 26, 7, 0).time()))
        self.assertFalse(g.in_window(datetime(2026, 10, 26, 21, 0).time()))


class Night(Base):
    def test_outside_window_does_nothing(self):
        self.c = FakeClock(datetime(2026, 10, 25, 21, 0))
        self.assertEqual(self.night(), "OUTSIDE_WINDOW")
        self.assertEqual(self.r.calls, [])

    def test_quiet_night_switches_and_guards_until_0720(self):
        self.assertEqual(self.night(), "GUARD_DONE")
        self.assertEqual(self.r.where(), (NIGHT, TOKYO07, True))
        self.assertEqual(self.r.mark["mode"], "night")
        self.assertEqual(self.r.mark["before"]["selected"], TW01)
        self.assertEqual(self.r.mark["night"], {"source": NIGHT, "selected": TOKYO07, "name": g.NIGHT_NODES[TOKYO07]})
        self.assertEqual(self.c.now().strftime("%H:%M"), "07:20")
        self.assertEqual(self.r.closes[0], (NIGHT, TOKYO07, True))

    def test_second_choice_when_first_fails_benchmark(self):
        self.r.eligible[NIGHT] = {TOKYO08}
        self.c.at(60, lambda: self.r.mark.update(mode="restored"))   # 结束守护，免得跑满一夜
        self.assertEqual(self.night(), "MARKER_CHANGED")
        self.assertEqual(self.r.where(), (NIGHT, TOKYO08, True))

    def test_no_eligible_night_node_keeps_rule(self):
        self.r.eligible[NIGHT] = set()
        self.assertEqual(self.night(), "NO_ELIGIBLE_NIGHT_NODE")
        self.assertEqual(self.r.where(), (MESL, TW01, True))
        self.assertIsNone(self.r.mark)

    def test_disabled_rule_is_left_alone(self):
        self.r.rule.update(enabled=False, applied=False)
        self.assertEqual(self.night(), "RULE_NOT_ACTIVE")
        self.assertFalse(any(c[0] in ("benchmark", "save") for c in self.r.calls))

    def test_night_switch_retries_transient_failure(self):
        self.r.flaky["save"] = ["CONFIG_TEST_FAILED"]
        self.c.at(200, lambda: self.r.mark.update(mode="restored"))
        self.assertEqual(self.night(), "MARKER_CHANGED")
        self.assertEqual(self.r.where(), (NIGHT, TOKYO07, True))

    def test_save_failure_removes_marker_and_keeps_rule(self):
        self.r.save_error = "CORE_CHECK_FAILED"
        self.assertEqual(self.night(), "SAVE_FAILED")
        self.assertEqual(self.r.where(), (MESL, TW01, True))
        self.assertIsNone(self.r.mark)

    def test_save_failure_that_broke_rule_keeps_marker_when_restore_fails(self):
        real = self.r.cli

        def broken(*args):
            if args[0] == "save":
                self.r.rule.update(enabled=False, applied=False)
                return {"ok": False, "error": "RELOAD_FAILED"}
            return real(*args)
        self.r.cli = broken
        self.assertEqual(self.night(), "SAVE_FAILED")
        self.assertEqual(self.r.where(), (MESL, TW01, False))
        self.assertEqual(self.r.mark["before"]["selected"], TW01)

    def test_already_restored_tonight_does_not_switch_again(self):
        self.r.mark = {"mode": "restored", "since": self.c.epoch() - 3600, "before": {}, "night": {}}
        self.assertEqual(self.night(), "ALREADY_RESTORED")
        self.assertEqual(self.r.where(), (MESL, TW01, True))

    def test_stale_marker_is_restored_before_switching(self):
        self.r.rule.update(source=NIGHT, selected=TOKYO07, selected_name=NAMES[TOKYO07], enabled=False, applied=False)
        self.r.mark = {"mode": "night", "rule": g.RULE_ID, "since": self.c.epoch() - 20 * 3600,
                       "before": {"source": MESL, "selected": TW01, "selected_name": NAMES[TW01], "label": "ChatGPT",
                                  "domains": ["chatgpt.com", "openai.com"], "preset": ""},
                       "night": {"source": NIGHT, "selected": TOKYO07}}
        self.c.at(200, lambda: self.r.mark.update(mode="restored"))
        self.assertEqual(self.night(), "MARKER_CHANGED")
        self.assertEqual(self.r.mark["before"]["selected"], TW01)   # 原规则仍是 MESL，不是上一晚的夜间节点
        self.assertEqual(self.r.where(), (NIGHT, TOKYO07, True))


class Guard(Base):
    def assert_restored(self, result):
        self.assertEqual(result, "RESTORED")
        self.assertEqual(self.r.where(), (MESL, TW01, True))
        self.assertEqual(self.r.mark["mode"], "restored")
        calls = [c[0] for c in self.r.calls]
        last_save = len(calls) - 1 - calls[::-1].index("save")
        self.assertIn("set-enabled", calls[:last_save], "先停用规则立刻回原分流，再恢复原节点")

    def test_slow_big_request_rolls_back_to_mesl(self):
        self.c.at(100, lambda: self.db.big(self.c))
        self.c.at(148, lambda: self.db.done(self.c))     # 第 140 秒那轮还没超时，下一轮读到 50 秒才完成
        self.assert_restored(self.night())
        self.assertIn("秒才拿到响应头", self.r.mark["reason"])

    def test_stuck_big_request_rolls_back(self):
        self.c.at(100, lambda: self.db.big(self.c))
        self.assert_restored(self.night())
        self.assertLess(self.c.t, 100 + g.HEADER_TIMEOUT + 2 * g.TICK)

    def test_two_failures_roll_back(self):
        self.c.at(100, lambda: self.db.failed(self.c))
        self.c.at(200, lambda: self.db.failed(self.c))
        self.assert_restored(self.night())
        self.assertIn("失败 2 次", self.r.mark["reason"])

    def test_failures_inside_grace_are_ignored(self):
        self.c.at(35, lambda: self.db.failed(self.c))      # 切换在第 30 秒，宽限到第 60 秒
        self.c.at(45, lambda: self.db.failed(self.c))
        self.c.at(300, lambda: self.r.mark.update(mode="restored"))
        self.assertEqual(self.night(), "MARKER_CHANGED")
        self.assertEqual(self.r.where(), (NIGHT, TOKYO07, True))

    def test_big_request_started_inside_grace_is_still_tracked(self):
        self.c.at(40, lambda: self.db.big(self.c))
        self.assert_restored(self.night())

    def test_fast_big_requests_keep_night_node(self):
        for k in range(6):
            self.c.at(100 + k * 60, lambda: self.db.big(self.c))
            self.c.at(115 + k * 60, lambda: self.db.done(self.c))
        self.c.at(1000, lambda: self.r.mark.update(mode="restored"))
        self.assertEqual(self.night(), "MARKER_CHANGED")
        self.assertEqual(self.r.where(), (NIGHT, TOKYO07, True))

    def test_small_requests_are_not_timed(self):
        self.c.at(100, lambda: self.db.add(self.c, "Compressed request body with zstd pre_compression_bytes=900 post_compression_bytes=300"))
        self.c.at(1000, lambda: self.r.mark.update(mode="restored"))
        self.assertEqual(self.night(), "MARKER_CHANGED")

    def test_probe_failing_twice_rolls_back(self):
        self.c.at(60, lambda: setattr(self.r, "probe_ok", False))
        self.assert_restored(self.night())
        self.assertIn("连不上", self.r.mark["reason"])

    def test_restore_benchmarks_when_mesl_proof_expired(self):
        self.c.at(50, lambda: self.r.proof.discard((MESL, TW01)))
        self.c.at(100, lambda: self.db.big(self.c))
        self.assert_restored(self.night())
        self.assertIn(("benchmark", MESL), self.r.calls)

    def test_core_check_timeouts_are_retried_without_benchmark(self):
        """2026-10-26 00:09：模块核心校验超时（CONFIG_TEST_FAILED），恢复不该去测速，也不该放弃。"""
        self.c.at(100, lambda: self.db.big(self.c))
        self.c.at(101, lambda: self.r.flaky.update({"save": ["CONFIG_TEST_FAILED", "CONFIG_TEST_FAILED"]}))
        self.assert_restored(self.night())
        self.assertNotIn(("benchmark", MESL), self.r.calls)
        self.assertTrue(any("CONFIG_TEST_FAILED" in line for line in self.r.logs))

    def test_disable_is_retried_when_core_check_times_out(self):
        self.c.at(100, lambda: self.db.big(self.c))
        self.c.at(101, lambda: self.r.flaky.update({"set-enabled": ["CONFIG_TEST_FAILED"]}))
        self.assert_restored(self.night())
        self.assertIn("ok=True", next(line for line in self.r.logs if "停用规则回原分流" in line))

    def test_missing_proof_is_not_retried(self):
        self.c.at(50, lambda: self.r.proof.discard((MESL, TW01)))
        self.c.at(100, lambda: self.db.big(self.c))
        self.assert_restored(self.night())
        calls = [c[0] for c in self.r.calls]
        bench = calls.index("benchmark", calls.index("set-enabled"))
        self.assertEqual(calls[calls.index("set-enabled"):bench].count("save"), 1)

    def test_restore_failure_leaves_rule_disabled(self):
        def break_mesl():
            self.r.proof.discard((MESL, TW01))
            self.r.eligible[MESL] = set()
        self.c.at(50, break_mesl)
        self.c.at(100, lambda: self.db.big(self.c))
        self.assertEqual(self.night(), "ROLLED_BACK")
        self.assertEqual(self.r.where(), (NIGHT, TOKYO07, False))
        self.assertEqual(self.r.mark["mode"], "rolled_back")

    def test_guard_survives_router_errors(self):
        calls = {"n": 0}
        real = self.r.marker

        def flaky():
            calls["n"] += 1
            if calls["n"] == 3:
                raise OSError("ssh reset")
            return real()
        self.r.marker = flaky
        self.c.at(400, lambda: self.r.mark.update(mode="restored"))
        self.assertEqual(self.night(), "MARKER_CHANGED")

    def test_trial_ignores_window_and_stops_after_minutes(self):
        self.c = FakeClock(datetime(2026, 10, 25, 21, 0))
        self.assertEqual(self.night(trial_minutes=10), "GUARD_DONE")
        self.assertEqual(self.r.where(), (NIGHT, TOKYO07, True))
        self.assertLessEqual(self.c.t, 10 * 60 + g.TICK)


class Day(Base):
    def switched(self):
        self.r.eligible[NIGHT] = {TOKYO07}
        self.c.at(60, lambda: self.r.mark.update(mode="night_stop"))
        self.night()
        self.r.mark["mode"] = "night"
        self.assertEqual(self.r.where(), (NIGHT, TOKYO07, True))

    def test_no_marker(self):
        self.assertEqual(g.day(self.r, self.c), "NOTHING")
        self.assertEqual(self.r.calls, [])

    def test_restores_and_clears_marker(self):
        self.switched()
        self.assertEqual(g.day(self.r, self.c), "RESTORED")
        self.assertEqual(self.r.where(), (MESL, TW01, True))
        self.assertIsNone(self.r.mark)
        self.assertEqual(self.r.closes[-1], (MESL, TW01, True))

    def test_restores_after_failsafe_disabled_rule(self):
        self.switched()
        self.r.rule.update(enabled=False, applied=False)
        self.r.proof.discard((MESL, TW01))
        self.assertEqual(g.day(self.r, self.c), "RESTORED")
        self.assertEqual(self.r.where(), (MESL, TW01, True))

    def test_user_change_is_not_overwritten(self):
        self.switched()
        self.r.proof.add((NIGHT, TOKYO08))
        self.r.cli("save", g.payload(self.r.mark["before"], NIGHT, TOKYO08))
        self.r.calls.clear()
        self.assertEqual(g.day(self.r, self.c), "USER_CHANGED")
        self.assertEqual(self.r.where(), (NIGHT, TOKYO08, True))
        self.assertFalse(any(c[0] in ("save", "set-enabled") for c in self.r.calls))
        self.assertIsNone(self.r.mark)

    def test_restored_marker_is_just_cleared(self):
        self.switched()
        self.r.mark["mode"] = "restored"
        self.r.cli("save", g.payload(self.r.mark["before"]))
        self.assertEqual(g.day(self.r, self.c), "ALREADY_RESTORED")
        self.assertIsNone(self.r.mark)

    def test_failed_restore_disables_and_keeps_marker(self):
        self.switched()
        self.r.proof.discard((MESL, TW01))
        self.r.eligible[MESL] = set()
        self.assertEqual(g.day(self.r, self.c), "DISABLED")
        self.assertEqual(self.r.where(), (NIGHT, TOKYO07, False))
        self.assertIsNotNone(self.r.mark)

    def test_rollback_resumes_after_interrupted_attempt(self):
        self.switched()
        self.r.rule.update(enabled=False, applied=False)
        self.r.mark.update(mode="rolled_back", reason="上次回退时 SSH 断开")
        self.assertEqual(g.rollback(self.r, self.c, "手动"), "RESTORED")
        self.assertEqual(self.r.where(), (MESL, TW01, True))

    def test_manual_rollback_outside_night_mode_does_nothing(self):
        self.assertEqual(g.rollback(self.r, self.c, "手动"), "NOT_IN_NIGHT_MODE")
        self.assertEqual(self.r.calls, [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
