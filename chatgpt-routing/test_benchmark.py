#!/usr/bin/env python3
"""Benchmark-helper cases only: python chatgpt-routing/test_benchmark.py [--local]

Same runner as test_backend.py (router /tmp sandbox by default), limited to the
test_bench_* cases of test_router_suite.rb.
"""
from __future__ import annotations

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_backend  # noqa: E402

if __name__ == "__main__":
    if sys.stdout:
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(test_backend.main(["-k", "bench_"] + sys.argv[1:]))
