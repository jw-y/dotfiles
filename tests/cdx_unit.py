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
import sys
import time
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
# 0.1 of six cells is 4.8 eighths, which truncates to four — half a block.
check("partials resolve below a block", cdx.bar(0.1, 6), "▌░░░░░")
check("and round down, never up", cdx.bar(0.166, 6), "▉░░░░░")
# A partial only appears where a whole block cannot: 0.2 of six is nine
# eighths, so one full block and one eighth over.
check("a full block plus a sliver", cdx.bar(0.2, 6), "█▏░░░░")
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

print()
print(f"{PASS} passed" if not FAIL else f"{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
