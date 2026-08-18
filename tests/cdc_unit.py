#!/usr/bin/env python3
"""Focused tests for cdc's per-profile quota cache and failure handling."""

import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
import urllib.error
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "bin" / "cdc"
spec = importlib.util.spec_from_loader(
    "cdc", importlib.machinery.SourceFileLoader("cdc", str(SRC)))
cdc = importlib.util.module_from_spec(spec)
sys.modules["cdc"] = cdc
spec.loader.exec_module(cdc)

PASS = FAIL = 0


def check(name, got, want):
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"  \033[32m✓\033[0m {name}")
    else:
        FAIL += 1
        print(f"  \033[31m✗\033[0m {name}\n     expected {want!r}, got {got!r}")


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class Opener:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = 0

    def open(self, _req, timeout=0):
        self.calls += 1
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return Response(json.dumps(reply).encode())


def cached(home, used, age=0):
    rec = {"fetched_at": time.time() - age, "used": used,
           "label": "wk", "windows": []}
    (home / ".cdc-usage.json").write_text(json.dumps(rec))


body = {"limits": [{"kind": "weekly_all", "percent": 9,
                    "resets_at": "2099-01-01T00:00:00+00:00"}]}
saved_opener = cdc._usage_opener
saved_mode = os.environ.pop("CDC_USAGE", None)
saved_force = cdc._quota.force
saved_sleep = cdc.time.sleep
cdc._quota.force = False
cdc.time.sleep = lambda _seconds: None

try:
    with tempfile.TemporaryDirectory() as root:
        root = Path(root)
        fresh, stale, dead = root / "fresh", root / "stale", root / "dead"
        for home in (fresh, stale, dead):
            home.mkdir()
        cached(fresh, 20)
        cached(stale, 30, age=901)
        cached(dead, 40, age=901)

        opener = Opener([])
        cdc._usage_opener = opener
        rec, src = cdc._quota(fresh, "fresh-token")
        check("fresh profile keeps its own cache", (rec["used"], src, opener.calls),
              (20, "cache", 0))

        opener = Opener([body])
        cdc._usage_opener = opener
        rec, src = cdc._quota(stale, "stale-token")
        check("default mode refreshes a stale profile", (rec["used"], src), (9, "live"))

        throttled = urllib.error.HTTPError(
            cdc.USAGE_ENDPOINT, 429, "slow down", {"Retry-After": "0"}, None)
        opener = Opener([throttled, body])
        cdc._usage_opener = opener
        cdc._quota.force = True
        rec, src = cdc._quota(stale, "stale-token")
        check("transient throttling is retried", (rec["used"], src, opener.calls),
              (9, "live", 2))

        rejected = urllib.error.HTTPError(
            cdc.USAGE_ENDPOINT, 401, "rejected", {}, None)
        opener = Opener([rejected, body])
        cdc._usage_opener = opener
        bad, bad_src = cdc._quota(dead, "dead-token")
        good, good_src = cdc._quota(stale, "healthy-token")
        check("one rejected account is isolated", (bad["state"], bad_src),
              ("relogin", "live"))
        check("the next available account still refreshes", (good["used"], good_src),
              (9, "live"))

        opener = Opener([OSError("offline")])
        cdc._usage_opener = opener
        rec, src = cdc._quota(stale, "healthy-token")
        check("offline refresh preserves that profile's cache", (rec["used"], src),
              (9, "offline"))
finally:
    cdc._usage_opener = saved_opener
    cdc._quota.force = saved_force
    cdc.time.sleep = saved_sleep
    if saved_mode is not None:
        os.environ["CDC_USAGE"] = saved_mode
    else:
        os.environ.pop("CDC_USAGE", None)

print()
print(f"{PASS} passed" if not FAIL else f"{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
