#!/usr/bin/env python3
"""Unit tests for bin/cdx's pure functions.

The suite next door drives cdx as a subprocess: it builds a throwaway HOME,
puts a fake codex on PATH, and reads rendered output. That is the right shape
for "does the command work", and the wrong shape for "does this mapping handle
a null balance" — reaching one branch of parse_usage that way costs a
sandboxed process and a file:// fixture.

These are the functions where every bug this month actually lived: the payload
that decides whether an account can run, the percentage parsed back out of a
rendered cell, and the search that picks where to send you. Table-driven, no
processes, no filesystem.

bin/cdx has no .py extension because it is a command, so it is loaded by path
rather than imported by name.
"""

import importlib.machinery
import importlib.util
import io
import json
import sys
import tempfile
import time
import urllib.error
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "bin" / "cdx"
spec = importlib.util.spec_from_loader(
    "cdx", importlib.machinery.SourceFileLoader("cdx", str(SRC)))
cdx = importlib.util.module_from_spec(spec)
# Registered before it runs: @dataclass resolves a class's module through
# sys.modules while the class body is being processed, so Row cannot be built
# in a module that is not there yet.
sys.modules["cdx"] = cdx
spec.loader.exec_module(cdx)

PASS = FAIL = 0


def check(name: str, got, want) -> None:
    global PASS, FAIL
    if got == want:
        PASS += 1
        print(f"  \033[32m✓\033[0m {name}")
    else:
        FAIL += 1
        print(f"  \033[31m✗\033[0m {name}\n     expected {want!r}, got {got!r}")


# ── pct_of ───────────────────────────────────────────────────────────────────
# The USED cell carries more than a number — a '~' when the figure could not be
# refreshed, and the window it belongs to. Two hand-rolled trims of this in the
# shell version diverged and silently disabled the quota warning for weeks.
print("pct_of")
for cell, want in [
    ("52%", 52),
    ("52% wk", 52),
    ("96%~ wk", 96),
    ("0% 5h", 0),
    ("100% wk", 100),
    ("spend limit", None),      # a state took the cell over
    ("re-login", None),
    ("rate limited", None),
    ("", None),
    ("wk", None),
    ("███░░░ 52% wk", None),    # a rendered cell is not data — see below
]:
    check(f"pct_of({cell!r})", cdx.pct_of(cell), want)

# That last case is deliberate. Prepending the bar to r.used made pct_of return
# None and silently killed the recommendation line minutes after it was
# written. The cell is now built beside the row; this pins that pct_of does not
# quietly learn to parse rendered output instead.

# ── span_label ───────────────────────────────────────────────────────────────
# 16% of a week and 16% of five hours are not the same news, so the label
# travels with the number everywhere it is shown.
print("span_label")
for seconds, want in [(604800, "wk"), (1209600, "wk"), (86400, "1d"),
                      (259200, "3d"), (18000, "5h"), (3600, "1h")]:
    check(f"span_label({seconds})", cdx.span_label(seconds), want)

# ── reset_phrase ─────────────────────────────────────────────────────────────
# A window closing in five hours renders as today's date, which reads as
# already reset — hence the countdown alongside the clock time.
print("reset_phrase")
now = time.time()
check("a reset in the past reads 'now'", cdx.reset_phrase(now - 60), "now")
check("minutes are minutes", cdx.reset_phrase(now + 1800).endswith("(in 30m)"), True)
check("hours are hours", cdx.reset_phrase(now + 5 * 3600).endswith("(in 5h)"), True)
check("days are days", cdx.reset_phrase(now + 6 * 86400).endswith("(in 6d)"), True)
check("the clock time is kept too",
      len(cdx.reset_phrase(now + 6 * 86400).split(" (")[0].split()) == 3, True)

# ── bar ──────────────────────────────────────────────────────────────────────
print("bar")
check("empty is all track", cdx.bar(0.0, 6), "░░░░░░")
check("full is all fill", cdx.bar(1.0, 6), "██████")
check("half of six", cdx.bar(0.5, 6), "███░░░")
check("small values leave a clean track", cdx.bar(0.03, 6), "░░░░░░")
check("whole cells round to the nearest", cdx.bar(0.25, 6), "██░░░░")
check("half cells consistently round up", cdx.bar(0.75, 6), "█████░")
# Precision belongs to the percentage printed beside the approximate bar.
check("twenty percent rounds cleanly", cdx.bar(0.2, 6), "█░░░░░")
check("over 1.0 clamps", cdx.bar(4.0, 6), "██████")
check("below 0 clamps", cdx.bar(-1.0, 6), "░░░░░░")
check("width is honoured", len(cdx.bar(0.37, 10)), 10)

# ── parse_usage ──────────────────────────────────────────────────────────────
# The layer that decides whether an account can run at all. Every fixture here
# is a shape the real endpoint returned today.
print("parse_usage")


def body(**kw):
    base = {"email": "t@example.com", "plan_type": "plus",
            "rate_limit": {"allowed": True, "limit_reached": False,
                           "primary_window": {"used_percent": 12,
                                              "limit_window_seconds": 604800,
                                              "reset_at": now + 86400}}}
    base.update(kw)
    return base


check("a healthy account is ok", cdx.parse_usage(body())["state"], "ok")
check("and reports its percentage", cdx.parse_usage(body())["used"], 12)
check("and its window", cdx.parse_usage(body())["window"], 604800)

# The binding window is whichever is closest to its limit, not whichever the
# payload happened to call 'primary'. This is the real snu shape: idle on the
# five-hour window, 16% into the week.
two = cdx.parse_usage(body(rate_limit={
    "allowed": True, "limit_reached": False,
    "primary_window": {"used_percent": 0, "limit_window_seconds": 18000,
                       "reset_at": now + 3600},
    "secondary_window": {"used_percent": 16, "limit_window_seconds": 604800,
                         "reset_at": now + 6 * 86400}}))
check("the fuller window is reported", two["used"], 16)
check("with its own span", two["window"], 604800)
check("and the other is kept", len(two["windows"]), 2)

# spend_control is the only field that catches an admin-set budget: every
# rate-limit field says 'fine' while the account refuses to run.
spent = cdx.parse_usage(body(spend_control={"individual_limit": None, "reached": True}))
check("a reached spend limit wins", spent["state"], "spendlimit")
check("even though the window is low", spent["used"], 12)
check("a budget with room is ok",
      cdx.parse_usage(body(spend_control={"reached": False}))["state"], "ok")

# 'has_credits: false' means "this plan does not use credits", not "spent" —
# it is what both subscriptions report while working perfectly.
subscription = cdx.parse_usage(body(credits={
    "has_credits": False, "unlimited": False, "balance": "0"}))
check("a subscription is not 'spent'", subscription["state"], "ok")
check("but its credits are recorded",
      subscription["credits"]["has_credits"], False)

check("rate limiting is its own state",
      cdx.parse_usage(body(rate_limit={"allowed": True, "limit_reached": True}))["state"],
      "blocked")
check("so is being disallowed",
      cdx.parse_usage(body(rate_limit={"allowed": False, "limit_reached": False}))["state"],
      "blocked")
check("an empty payload does not explode", cdx.parse_usage({})["state"], "ok")
check("and reports no figure", cdx.parse_usage({})["used"], None)

# ── roomiest ─────────────────────────────────────────────────────────────────
# The listing grew its own copy of this and immediately recommended a fuller
# account than the one you were on; there is one search now.
print("roomiest")


def rows(*specs):
    return [cdx.Row(name, used=used, state=state) for name, used, state in specs]


check("picks the emptiest usable account",
      cdx.roomiest(rows(("a", "80% wk", "ok"), ("b", "10% wk", "ok")), "")[0], "b")
check("skips the excluded one",
      cdx.roomiest(rows(("a", "80% wk", "ok"), ("b", "10% wk", "ok")), "b")[0], "a")
# An account that cannot run reads low precisely *because* it cannot run.
check("never picks a spend-limited account",
      cdx.roomiest(rows(("a", "80% wk", "ok"), ("b", "2% wk", "spendlimit")), "")[0], "a")
check("nor one needing re-login",
      cdx.roomiest(rows(("a", "80% wk", "ok"), ("b", "0% wk", "relogin")), "")[0], "a")
check("nor a rate-limited one",
      cdx.roomiest(rows(("a", "80% wk", "ok"), ("b", "1% wk", "blocked")), "")[0], "a")
check("returns nothing when nothing qualifies",
      cdx.roomiest(rows(("b", "2% wk", "spendlimit")), "")[0], "")
check("and a percentage nothing can beat",
      cdx.roomiest(rows(), "")[1], 101)
check("ignores an account with no figure",
      cdx.roomiest(rows(("a", "", "ok"), ("b", "50% wk", "ok")), "")[0], "b")

# ── stop_bound_to ────────────────────────────────────────────────────────────
# The one decision that cannot be sandboxed by an environment variable: pgrep
# sees the whole user's process table, so a mistake in the path filter reaches
# real sessions. Every end-to-end test therefore runs with CDX_NO_KILL=1, which
# means the signalling path has never executed under test. Behind the seam it
# can be handed a table that does not exist.
print("stop_bound_to")

OLD = "/home/u/.codex-profiles/old"


class FakeProcesses:
    def __init__(self, table):
        # pid -> (cmdline, [open paths])
        self.table = table
        self.signalled: list[int] = []
        self.stubborn: set[int] = set()

    def matching(self, pattern):
        return sorted(self.table)

    def username(self):
        return "u"

    def cmdline(self, pid):
        return self.table[pid][0]

    def open_paths(self, pid):
        return self.table[pid][1]

    def terminate(self, pid):
        self.signalled.append(pid)

    def alive(self, pid):
        return pid in self.stubborn


def run_stop(table, **kw):
    """stop_bound_to against a synthetic table, returning (rc, output, fake)."""
    import io
    import contextlib
    fake = FakeProcesses(table)
    real, cdx.PROCS = cdx.PROCS, fake
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = cdx.stop_bound_to(OLD, **kw)
    finally:
        cdx.PROCS = real
    return rc, buf.getvalue(), fake


BOUND = ("codex app-server --listen unix://x", [f"{OLD}/app-server-control/sock"])
ELSEWHERE = ("codex app-server --listen unix://y", ["/home/u/.codex-profiles/other/log"])
PROXY = ("ssh host codex app-server proxy", [])

rc, text, fake = run_stop({100: BOUND})
check("a bound process is signalled", fake.signalled, [100])
check("and said so", "Stopping 1 process(es)" in text, True)
check("and exits clean", rc, 0)

rc, text, fake = run_stop({100: ELSEWHERE})
check("a process bound elsewhere is spared", fake.signalled, [])
check("and the run says nothing happened",
      "No running processes were bound" in text, True)

# 'use' changes the account, so every cached remote connection is stale
# whether or not anything else was stopped.
rc, text, fake = run_stop({100: ELSEWHERE, 200: PROXY})
check("'always' takes proxies regardless", fake.signalled, [200])
check("and counts the disconnect", "Would disconnect" in text or
      "Disconnecting 1 SSH remote proxy" in text, True)

# 'rename' does not change the account: an idle machine keeps its sessions.
rc, text, fake = run_stop({100: ELSEWHERE, 200: PROXY}, proxy_policy="if-stale")
check("'if-stale' spares an idle proxy", fake.signalled, [])

# ...but once something it could be fronting dies, it is a dead end.
rc, text, fake = run_stop({100: BOUND, 200: PROXY}, proxy_policy="if-stale")
check("'if-stale' escalates when something died", fake.signalled, [100, 200])
check("without listing the proxy twice", len(fake.signalled), 2)

rc, text, fake = run_stop({100: BOUND}, dry_run=True)
check("a dry run signals nothing", fake.signalled, [])
check("but names what it would stop", "Would stop 1 process(es): 100" in text, True)

# A path that merely starts with the same characters is a different profile:
# '/…/old-backup' must not match '/…/old'.
rc, text, fake = run_stop({100: ("codex", [f"{OLD}-backup/app-server-control/s"])})
check("a prefix is not a parent", fake.signalled, [])

# A process that ignores SIGTERM is reported rather than force-killed, and the
# command fails so 'rename' aborts instead of moving a directory underneath it.
import os as _os
_os.environ["CDX_USAGE"] = "off"
fake = FakeProcesses({100: BOUND})
fake.stubborn = {100}
# The wait is 20 real seconds by design — an app-server closes sqlite handles
# and tears down sessions before it goes. Nothing here is testing the clock,
# so the sleep is stubbed rather than served.
_slept, cdx.time.sleep = cdx.time.sleep, lambda _s: None
real, cdx.PROCS = cdx.PROCS, fake
import io as _io
import contextlib as _ctx
_buf = _io.StringIO()
try:
    with _ctx.redirect_stdout(_buf), _ctx.redirect_stderr(_io.StringIO()):
        rc = cdx.stop_bound_to(OLD)
finally:
    cdx.PROCS = real
    cdx.time.sleep = _slept
check("a survivor makes the command fail", rc, 1)
check("and it waited the full run", len(fake.signalled), 1)

# CDX_NO_KILL is what makes the end-to-end suite safe to run at all: pgrep
# sees the whole user's process table, so without it a test that stops "the
# old profile's" processes reaches live sessions. It belongs here, against a
# fake, and not in a live experiment — checking whether the guard was
# load-bearing by removing it and running the real suite terminated nine of
# this machine's processes, which is precisely what it guards against.
_saved = _os.environ.get("CDX_NO_KILL")
_os.environ["CDX_NO_KILL"] = "1"
try:
    rc, text, fake = run_stop({100: BOUND})
finally:
    if _saved is None:
        _os.environ.pop("CDX_NO_KILL", None)
    else:
        _os.environ["CDX_NO_KILL"] = _saved
check("CDX_NO_KILL signals nothing", fake.signalled, [])
check("and says why", "signalling nothing" in text, True)
check("while still reporting the selection", "Stopping 1 process(es)" in text, True)

# A forced multi-account refresh arrives as a short request burst. A healthy
# account throttled by that burst must get another chance instead of silently
# keeping an old cache while a neighbouring account refreshes successfully.
class QuotaOpener:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = 0

    def open(self, _req, timeout=0):
        self.calls += 1
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return io.BytesIO(json.dumps(reply).encode())


throttled = urllib.error.HTTPError(
    cdx.USAGE_ENDPOINT, 429, "slow down", {"Retry-After": "0"}, None)
healthy = {"plan_type": "pro", "rate_limit": {
    "primary_window": {"used_percent": 9, "limit_window_seconds": 604800}}}
real_opener, real_mode, real_force = (
    cdx._opener, _os.environ.get("CDX_USAGE"), cdx._quota.force)
fake_opener = QuotaOpener([throttled, healthy])
try:
    cdx._opener = fake_opener
    _os.environ.pop("CDX_USAGE", None)
    cdx._quota.force = True
    with tempfile.TemporaryDirectory() as tmp:
        rec, source = cdx._quota(Path(tmp), "healthy-token")
finally:
    cdx._opener = real_opener
    cdx._quota.force = real_force
    if real_mode is None:
        _os.environ.pop("CDX_USAGE", None)
    else:
        _os.environ["CDX_USAGE"] = real_mode
check("a throttled account is retried", fake_opener.calls, 2)
check("the retry refreshes its quota", (rec["used"], source), (9, "live"))

print()
print(f"{PASS} passed" if not FAIL else f"{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
