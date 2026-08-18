#!/usr/bin/env bash
# Regression tests for bin/cdc.
#
# Every test builds a throwaway CLAUDE_PROFILES tree with CDC_CLAUDE_LINK and
# CDC_CLAUDE_JSON_LINK pointed into a tmpdir, so nothing here reads or writes
# the real ~/.claude or ~/.claude.json. Run with:
#   make test          (or)   bash tests/cdc.test.sh
#
# SAFETY — stale-connection detection is the one thing CLAUDE_PROFILES cannot
# sandbox by itself: it finds candidate PIDs with pgrep over the whole user's
# process table. It stays safe here because the *second* filter — "does this
# PID have an open file resolving under this sandbox's CLAUDE_PROFILES" — can
# never match a real production process, since real ones live under the real
# ~/.claude-profiles, not this test's tmpdir. That second filter is exactly
# the code under test, so the fake process below is what proves it works
# without ever being able to reach something real.
set -uo pipefail

CDC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/cdc"
[ -x "$CDC" ] || { echo "cannot find bin/cdc next to tests/" >&2; exit 1; }

PASS=0 FAIL=0 CURRENT=""
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cdc-test.XXXXXX")"
SPAWNED=()
cleanup() {
    local pid
    if [ ${#SPAWNED[@]} -gt 0 ]; then
        kill "${SPAWNED[@]}" 2>/dev/null
        sleep 0.3
        for pid in "${SPAWNED[@]}"; do kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; done
    fi
    rm -rf "$ROOT"
}
trap cleanup EXIT

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }

it()   { CURRENT="$1"; }
ok()   { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$CURRENT"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n     %s\n' "$RED" "$OFF" "$CURRENT" "$1"; }

assert_eq()       { [ "$1" = "$2" ] && ok || bad "expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ok ;; *) bad "expected to contain '$2', got: $(printf %s "$1" | head -3 | tr '\n' ' ')" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) bad "expected NOT to contain '$2'" ;; *) ok ;; esac; }
assert_link()     { local got; got="$(readlink "$1" 2>/dev/null || echo '<not a link>')"; [ "$got" = "$2" ] && ok || bad "$1 -> $got, expected $2"; }
assert_fails()    { if "$@" >/dev/null 2>&1; then bad "expected failure, but it succeeded"; else ok; fi; }

# ── sandbox setup ────────────────────────────────────────────────────────────
export CLAUDE_PROFILES="$ROOT/profiles"
export CDC_CLAUDE_LINK="$ROOT/.claude"
export CDC_CLAUDE_JSON_LINK="$ROOT/.claude.json"

fresh_install() {
    rm -rf "$ROOT/.claude" "$ROOT/.claude.json" "$ROOT/profiles"
    mkdir -p "$ROOT/.claude"
    echo '{"model":"opus"}' > "$ROOT/.claude/settings.json"
    echo '{"claudeAiOauth":{"accessToken":"tok-main"}}' > "$ROOT/.claude/.credentials.json"
    echo '{"oauthAccount":{"emailAddress":"main@example.com","organizationType":"team"}}' \
        > "$ROOT/.claude.json"
}

echo "cdc regression tests"

# ── init ─────────────────────────────────────────────────────────────────────
fresh_install
it "init moves the existing account into 'main' and symlinks both paths"
out="$("$CDC" init -y 2>&1)"
assert_link "$ROOT/.claude" "$ROOT/profiles/main/home"
it "init: claude.json symlinked too"
assert_link "$ROOT/.claude.json" "$ROOT/profiles/main/claude.json"
it "init: settings.json hoisted into the shared store"
assert_link "$ROOT/.claude/settings.json" "$ROOT/profiles/.store/settings.json"
it "init: credentials preserved"
assert_contains "$(cat "$ROOT/profiles/main/home/.credentials.json")" "tok-main"
it "init: second call is a no-op, not an error"
assert_contains "$("$CDC" init -y 2>&1)" "already set up"

# ── list / status ────────────────────────────────────────────────────────────
it "list shows main as active"
assert_contains "$("$CDC" list)" "* main"
it "bare cdc defaults to list"
assert_contains "$("$CDC")" "main"
it "bare --refresh applies to the default list"
assert_contains "$(CDC_USAGE=off "$CDC" --refresh)" "main"
it "bare --no-usage applies to the default list"
assert_contains "$("$CDC" --no-usage)" "main"
it "cdc ls is an alias for list"
assert_contains "$("$CDC" ls)" "main"
it "status reports links consistent"
assert_contains "$("$CDC" status)" "links look consistent"

# ── add ──────────────────────────────────────────────────────────────────────
it "add creates an empty profile"
"$CDC" add work >/dev/null
assert_eq "$([ -d "$ROOT/profiles/work/home" ] && echo yes)" "yes"
it "add: new profile's settings.json shares the same store"
assert_link "$ROOT/profiles/work/home/settings.json" "$ROOT/profiles/.store/settings.json"
it "add: duplicate name fails"
assert_fails "$CDC" add work

# ── use, and the reclaim problem ─────────────────────────────────────────────
echo '{"claudeAiOauth":{"accessToken":"tok-work"}}' > "$ROOT/profiles/work/home/.credentials.json"
echo '{"oauthAccount":{"emailAddress":"work@example.com"}}' > "$ROOT/profiles/work/claude.json"

it "use switches the active profile"
out="$("$CDC" use work 2>&1)"
assert_contains "$out" "switched to 'work'"
it "use: credentials.json now resolves to work's"
assert_contains "$(cat "$ROOT/.claude/.credentials.json")" "tok-work"
it "use: already-active is a no-op"
assert_contains "$("$CDC" use work)" "already active"

it "use: reclaims a clobbered claude.json before switching away"
# Simulate Claude Code's temp-file-then-rename replacing the symlink with a
# real file mid-session (the exact failure mode 'reclaim' exists for).
rm -f "$ROOT/.claude.json"
echo '{"oauthAccount":{"emailAddress":"work@example.com"},"numStartups":99}' > "$ROOT/.claude.json"
"$CDC" use main >/dev/null
assert_contains "$(cat "$ROOT/profiles/work/claude.json")" "numStartups"

# ── shared history merge ─────────────────────────────────────────────────────
# Profiles built directly on disk (not via 'cdc add'), so history.jsonl/
# projects/ start as real, independent content instead of already being
# symlinked into the (empty) store — matching how this actually happens in
# practice: two accounts that had their own history before either was ever
# under cdc. Writing through an add'd profile's already-shared paths would
# just write into the one store file both aliased, proving nothing.
mkdir -p "$ROOT/profiles/alpha/home/projects/p1" "$ROOT/profiles/alpha/home/projects/p2"
mkdir -p "$ROOT/profiles/beta/home/projects/p1" "$ROOT/profiles/beta/home/projects/p2"
echo "line from alpha" > "$ROOT/profiles/alpha/home/history.jsonl"
echo "line from beta" > "$ROOT/profiles/beta/home/history.jsonl"
echo "same content" > "$ROOT/profiles/alpha/home/projects/p1/same.jsonl"
echo "same content" > "$ROOT/profiles/beta/home/projects/p1/same.jsonl"
echo "alpha's version" > "$ROOT/profiles/alpha/home/projects/p2/x.jsonl"
echo "beta's version" > "$ROOT/profiles/beta/home/projects/p2/x.jsonl"
"$CDC" link >/dev/null

it "link merges history.jsonl across profiles (append, not overwrite)"
merged="$(cat "$ROOT/profiles/.store/history.jsonl" 2>/dev/null)"
case "$merged" in
    *"line from alpha"*"line from beta"*|*"line from beta"*"line from alpha"*) ok ;;
    *) bad "expected both lines, got: $merged" ;;
esac

it "link: identical files across profiles are deduped, not duplicated"
count="$(find "$ROOT/profiles/.store/projects/p1" -maxdepth 1 -name "same*" | wc -l | tr -d ' ')"
assert_eq "$count" "1"

it "link: diverged files across profiles are kept under both names"
count="$(find "$ROOT/profiles/.store/projects/p2" -maxdepth 1 -name "x*" | wc -l | tr -d ' ')"
assert_eq "$count" "2"
it "link: neither diverged copy was silently dropped"
all="$(cat "$ROOT/profiles/.store/projects/p2"/x* 2>/dev/null)"
case "$all" in
    *"alpha's version"*"beta's version"*|*"beta's version"*"alpha's version"*) ok ;;
    *) bad "expected both versions present, got: $all" ;;
esac
it "link: both profiles now read the merged history through a symlink"
assert_link "$ROOT/profiles/alpha/home/history.jsonl" "$ROOT/profiles/.store/history.jsonl"
assert_link "$ROOT/profiles/beta/home/history.jsonl" "$ROOT/profiles/.store/history.jsonl"

# ── rename ───────────────────────────────────────────────────────────────────
it "rename repoints the symlinks when renaming the active profile"
"$CDC" use main >/dev/null
"$CDC" rename main primary >/dev/null
assert_link "$ROOT/.claude" "$ROOT/profiles/primary/home"
it "rename: inactive profile just moves, no symlink change needed"
"$CDC" rename work secondary >/dev/null
assert_eq "$([ -d "$ROOT/profiles/secondary/home" ] && echo yes)" "yes"

# ── rm ───────────────────────────────────────────────────────────────────────
it "rm refuses to delete the active profile"
assert_fails "$CDC" rm primary -y
it "rm deletes an inactive profile"
"$CDC" rm secondary -y >/dev/null
assert_eq "$([ -d "$ROOT/profiles/secondary" ] && echo yes || echo no)" "no"

# ── import ───────────────────────────────────────────────────────────────────
it "import copies a CLAUDE_CONFIG_DIR-shaped directory without touching the source"
src="$ROOT/external-config"
mkdir -p "$src"
echo '{"claudeAiOauth":{"accessToken":"tok-ext"}}' > "$src/.credentials.json"
echo '{"oauthAccount":{"emailAddress":"ext@example.com"}}' > "$src/.claude.json"
"$CDC" import imported "$src" >/dev/null
assert_contains "$("$CDC" list)" "ext@example.com"
it "import: source directory is untouched"
assert_eq "$([ -f "$src/.claude.json" ] && echo yes)" "yes"

it "import: skips runtime IPC files instead of failing"
mkdir -p "$ROOT/external-with-ipc"
echo '{"claudeAiOauth":{"accessToken":"tok-ipc"}}' > "$ROOT/external-with-ipc/.credentials.json"
echo '{"oauthAccount":{"emailAddress":"ipc@example.com"}}' > "$ROOT/external-with-ipc/.claude.json"
mkfifo "$ROOT/external-with-ipc/remote.pipe"
out="$("$CDC" import withipc "$ROOT/external-with-ipc" 2>&1)"
assert_contains "$out" "skipped runtime file"
it "import: completes after skipping runtime IPC files"
assert_contains "$out" "imported 'withipc'"

# ── stale remote-control connections ─────────────────────────────────────────
it "use disconnects a fake remote-control server bound to the outgoing profile"
"$CDC" use primary >/dev/null
mkdir -p "$ROOT/profiles/primary/home/remote/srv/fakehash"
touch "$ROOT/profiles/primary/home/marker"
( exec -a "$ROOT/profiles/primary/home/remote/srv/fakehash/server --serve --socket x" \
    bash -c 'exec 3< "'"$ROOT"'/profiles/primary/home/marker"; while :; do sleep 1; done' \
) >/dev/null 2>&1 &
FAKE_PID=$!
SPAWNED+=("$FAKE_PID")
sleep 0.3
out="$("$CDC" use imported 2>&1)"
sleep 0.3
if kill -0 "$FAKE_PID" 2>/dev/null; then
    bad "fake remote server for 'primary' was still running after switching away"
else
    ok
fi
it "use: reported the disconnect"
assert_contains "$out" "disconnected 1 stale remote-control connection"

# ── summary ──────────────────────────────────────────────────────────────────
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
