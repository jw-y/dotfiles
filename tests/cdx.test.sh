#!/usr/bin/env bash
# Regression tests for bin/cdx.
#
# Every test builds a throwaway CODEX_PROFILES tree with a stub 'codex' on
# PATH, so nothing here reads or writes the real ~/.codex. Run with:
#   make test          (or)   bash tests/cdx.test.sh
#
# SAFETY — process selection is the one thing CODEX_PROFILES cannot sandbox.
# cdx finds work to stop with pgrep over the whole user's process table and
# then filters by open path, so isolation depends on that filter being correct.
# It is exactly the code under test, and a broken build reaches real sessions:
# during development a mutation that made the filter match everything killed a
# live app-server and its SSH proxies.
#
# Two defences, both required:
#   1. CDX_NO_KILL=1 in the sandbox env below — cdx reports what it would stop
#      and signals nothing, so even a broken build cannot touch real work.
#   2. --no-restart on every 'cdx use'. 'use' disconnects every proxy it sees
#      by command name regardless of path, which is correct in production
#      (a changed account makes cached connections stale) and unwanted here.
set -uo pipefail

CDX="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/cdx"
[ -x "$CDX" ] || { echo "cannot find bin/cdx next to tests/" >&2; exit 1; }

PASS=0 FAIL=0 CURRENT=""
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cdx-test.XXXXXX")"
SPAWNED=()
# TERM first, then make sure: a leaked fake would sit in the user's process
# table looking like a real Codex proxy, and the next 'cdx use' would try to
# kill it. Wait for the loop's current 'sleep' to return before escalating.
cleanup() {
    local pid
    if [ ${#SPAWNED[@]} -gt 0 ]; then
        kill "${SPAWNED[@]}" 2>/dev/null
        sleep 1.2
        for pid in "${SPAWNED[@]}"; do kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null; done
    fi
    rm -rf "$ROOT"
}
trap cleanup EXIT

# Sets SPAWN_PID rather than printing it. Calling this through $(...) would run
# it in a subshell, where the SPAWNED bookkeeping is discarded on return and
# every fake process leaks past cleanup.
SPAWN_PID=""

# Fake Codex processes for the process-matching tests. Two details are load
# bearing: the loop stops bash from exec-replacing itself with a trailing
# command (which would discard the argv[0] we set, hiding it from cdx's pgrep),
# and redirecting the child's output stops $(spawn_named ...) from blocking —
# a background process inherits the command substitution's pipe and holds it
# open for as long as it runs.
spawn_named() {
    local name="$1" script="${2:-}"
    ( exec -a "$name" bash -c "${script}while :; do sleep 1; done" ) >/dev/null 2>&1 &
    SPAWN_PID=$!
    SPAWNED+=("$SPAWN_PID")
}

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }

it()   { CURRENT="$1"; }
ok()   { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$CURRENT"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n     %s\n' "$RED" "$OFF" "$CURRENT" "$1"; }

assert_eq()       { [ "$1" = "$2" ] && ok || bad "expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ok ;; *) bad "expected to contain '$2', got: $(printf %s "$1" | head -2 | tr '\n' ' ')" ;; esac; }
assert_link()     { local got; got="$(readlink "$1" 2>/dev/null || echo '<not a link>')"; [ "$got" = "$2" ] && ok || bad "$1 -> $got, expected $2"; }
assert_fails()    { if "$@" >/dev/null 2>&1; then bad "expected failure, but it succeeded"; else ok; fi; }

# A stub codex: 'login' mints a plausible auth.json (id_token is a real,
# unsigned JWT so the email/plan decoding in 'describe' is exercised) and
# records the flags it was handed so tests can assert on them.
make_stub() {
    local bin="$1"; mkdir -p "$bin"
    cat > "$bin/codex" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = login ]; then
    shift
    printf '%s\n' "$*" > "${CODEX_HOME:?}/.login-args"
    python3 - "$CODEX_HOME" <<'PY'
import base64, json, sys
home = sys.argv[1]
claims = {"email": "tester@example.com",
          "https://api.openai.com/auth": {"chatgpt_plan_type": "plus"}}
b = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b"=").decode()
json.dump({"auth_mode": "chatgpt", "last_refresh": "2026-08-10T00:00:00Z",
           "tokens": {"account_id": "acct1234xyz", "id_token": f"h.{b}.s",
                      "access_token": "stub-access-token"}},
          open(home + "/auth.json", "w"))
PY
fi
exit 0
STUB
    chmod +x "$bin/codex"
}

# A brand-new machine: ~/.codex is a real directory, no profiles yet.
new_env() {
    local d="$ROOT/$1"; rm -rf "$d"; mkdir -p "$d/codex/sessions" "$d/codex/packages"
    make_stub "$d/bin"
    echo 'model="gpt-5"'  > "$d/codex/config.toml"
    echo 'agents-content' > "$d/codex/AGENTS.md"
    echo 'state-db'       > "$d/codex/state_5.sqlite"
    echo 'transcript'     > "$d/codex/sessions/s1.jsonl"
    echo 'binary-blob'    > "$d/codex/packages/codex-bin"
    echo "$d"
}

# The pre-store layout: 'main' holds the real files, others link into it.
legacy_env() {
    local d; d="$(new_env "$1")"
    mkdir -p "$d/profiles"
    mv "$d/codex" "$d/profiles/main"
    echo 'creds-main' > "$d/profiles/main/auth.json"
    ln -s "$d/profiles/main" "$d/codex"
    local p f
    for p in lab personal; do
        mkdir -p "$d/profiles/$p"
        echo "creds-$p" > "$d/profiles/$p/auth.json"
        for f in config.toml AGENTS.md state_5.sqlite sessions packages; do
            ln -s "$d/profiles/main/$f" "$d/profiles/$p/$f"
        done
    done
    echo "$d"
}

# Run cdx inside a sandbox. NO_COLOR keeps assertions on plain text.
# CDX_USAGE=off by default so no test can reach the network; the usage section
# below opts back in against a file:// endpoint it controls.
cdx() {
    local d="$1"; shift
    env -i HOME="$d" PATH="$d/bin:/usr/bin:/bin" NO_COLOR=1 TERM=dumb \
        CDX_NO_KILL=1 CDX_USAGE="${CDX_USAGE:-off}" \
        ${CDX_USAGE_ENDPOINT+CDX_USAGE_ENDPOINT="$CDX_USAGE_ENDPOINT"} \
        ${CDX_USAGE_TTL+CDX_USAGE_TTL="$CDX_USAGE_TTL"} \
        ${CDX_QUOTA_WARN+CDX_QUOTA_WARN="$CDX_QUOTA_WARN"} \
        CODEX_PROFILES="$d/profiles" CDX_CODEX_LINK="$d/codex" \
        bash "$CDX" "$@" 2>&1
}

md5of() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# A fully set-up machine: store in place, three logged-in profiles. This is
# what 'cdx init' produces, so it is built by running init rather than by
# hand-assembling a layout the code might never actually create.
store_env() {
    local d p; d="$(new_env "$1")"
    cdx "$d" init -y >/dev/null
    for p in lab personal; do cdx "$d" add "$p" >/dev/null; done
    echo "$d"
}

echo "cdx regression tests"

# ---------------------------------------------------------------- init -----
echo "${DIM}init${OFF}"
D="$(new_env init)"
out="$(cdx "$D" init -y)"
it "init reports the new symlink";        assert_contains "$out" "$D/codex -> $D/profiles/main"
it "init creates the shared store";       assert_contains "$out" "shared store:"
it "init leaves no stray output";         assert_eq "$(printf %s "$out" | wc -l)" "1"
it "store holds the real sessions dir";   assert_eq "$([ -d "$D/profiles/.store/sessions" ] && [ ! -L "$D/profiles/.store/sessions" ] && echo real)" "real"
it "main links into the store";           assert_link "$D/profiles/main/sessions" "$D/profiles/.store/sessions"
it "active pointer targets a profile";    assert_link "$D/codex" "$D/profiles/main"
it "session data survives init";          assert_eq "$(cat "$D/profiles/main/sessions/s1.jsonl")" "transcript"
it "init is idempotent";                  assert_contains "$(cdx "$D" init)" "already set up"
it "init hoists data out of main";        assert_eq "$(md5of "$D/profiles/.store/sessions/s1.jsonl")" "$(md5of "$D/profiles/main/sessions/s1.jsonl")"
it "every profile shares one dataset";    assert_eq "$(cdx "$D" add other >/dev/null; md5of "$D/profiles/other/sessions/s1.jsonl")" "$(md5of "$D/profiles/.store/sessions/s1.jsonl")"
it "no link points into a profile";       assert_eq "$(find "$D/profiles" -type l -exec readlink {} \; | grep -cv '/\.store/')" "0"

# A real ~/.codex next to an existing 'main' is not a fresh machine: it happens
# when the symlink is deleted (Codex recreates the directory) or setup was
# interrupted. 'mv' would bury the real home at profiles/main/.codex and leave
# the stale profile active, so init must refuse instead.
D="$(new_env clash)"
mkdir -p "$D/profiles/main"; echo 'stale-creds' > "$D/profiles/main/auth.json"
out="$(cdx "$D" init -y)"
it "init refuses to bury a real ~/.codex"; assert_contains "$out" "$D/profiles/main already exists"
it "the real home stays put";              assert_eq "$(cat "$D/codex/config.toml")" 'model="gpt-5"'
it "nothing was nested inside main";       assert_eq "$([ -e "$D/profiles/main/.codex" ] && echo nested || echo clean)" "clean"
it "the pointer was not created";          assert_eq "$([ -L "$D/codex" ] && echo linked || echo untouched)" "untouched"
it "the stale profile is untouched";       assert_eq "$(cat "$D/profiles/main/auth.json")" "stale-creds"

# ---------------------------------------------------- legacy detection -----
# cdx carries no converter for installs that predate the store. It must instead
# recognise one and print instructions precise enough to follow by hand.
echo "${DIM}legacy layout detection${OFF}"
D="$(legacy_env old)"
it "detects it in the listing";           assert_contains "$(cdx "$D" list)" "no shared store"
it "status names the missing store";      assert_contains "$(cdx "$D" status)" "predates the store"
it "init explains rather than no-ops";    assert_contains "$(cdx "$D" init)" "predates the shared store"

out="$(cdx "$D" init)"
it "instructions create the store";       assert_contains "$out" "mkdir -p $D/profiles/.store"
it "instructions move the real items";    assert_contains "$out" "sessions"
it "instructions handle sqlite sidecars"; assert_contains "$out" "sqlite-wal"
it "instructions finish with cdx link";   assert_contains "$out" "cdx link"
it "instructions stop Codex first";       assert_contains "$out" "app-server"

# Brace expansion needs a comma, so a lone leftover must be printed as a plain
# path — '{sessions}' would be copied out of the terminal and fail.
E="$(legacy_env one)"
for f in config.toml AGENTS.md state_5.sqlite packages; do rm -rf "$E/profiles/main/$f"; done
out="$(cdx "$E" init)"
it "single leftover is a usable path";    assert_contains "$out" "mv $E/profiles/main/sessions"
it "no unexpandable braces are printed";  assert_eq "$(printf %s "$out" | grep -c '{')" "0"

it "rename refuses on legacy layout";     assert_contains "$(cdx "$D" rename main school)" "predates the shared store"
it "link refuses on legacy layout";       assert_contains "$(cdx "$D" link)" "predates the shared store"
it "rename really did nothing";           assert_eq "$([ -d "$D/profiles/main" ] && echo intact)" "intact"
it "listing still works";                 assert_contains "$(cdx "$D" list)" "main"
it "switching still works";               assert_contains "$(cdx "$D" use lab --no-restart)" "lab is now active"
it "no store was created behind our back"; assert_eq "$([ -d "$D/profiles/.store" ] && echo created || echo absent)" "absent"
it "'migrate' explains instead of 404ing"; assert_contains "$(cdx "$D" migrate)" "predates the shared store"

# Following the printed instructions by hand must actually fix the install.
mkdir -p "$D/profiles/.store"
for f in config.toml AGENTS.md state_5.sqlite sessions packages; do
    [ -e "$D/profiles/main/$f" ] && [ ! -L "$D/profiles/main/$f" ] && mv "$D/profiles/main/$f" "$D/profiles/.store/$f"
done
out="$(cdx "$D" link)"
it "manual fix + cdx link repairs it";    assert_contains "$out" "linked"
it "profiles now link to the store";      assert_link "$D/profiles/lab/sessions" "$D/profiles/.store/sessions"
it "former main links to the store too";  assert_link "$D/profiles/main/sessions" "$D/profiles/.store/sessions"
it "data survived the manual path";       assert_eq "$(cat "$D/profiles/personal/sessions/s1.jsonl")" "transcript"
it "listing stops warning";               assert_eq "$(cdx "$D" list | grep -c 'no shared store')" "0"
it "'migrate' says it is gone";           assert_contains "$(cdx "$D" migrate)" "already uses the store"

# ------------------------------------------------------- link (repair) -----
echo "${DIM}link — reconstruction${OFF}"
D="$(store_env rep)"
S="$D/profiles/.store"
rm -f "$D/profiles/lab/config.toml"; echo 'clobbered' > "$D/profiles/lab/config.toml"  # Codex overwrote the link
ln -sfn "$D/profiles/nowhere/sessions" "$D/profiles/lab/sessions"                       # dangling
ln -sfn "$D/profiles/main/state_5.sqlite" "$D/profiles/lab/state_5.sqlite"              # stale, points at a profile
rm -f "$D/profiles/lab/AGENTS.md"                                                        # missing entirely
cdx "$D" link >/dev/null
it "repairs a link Codex overwrote";      assert_link "$D/profiles/lab/config.toml" "$S/config.toml"
it "repairs a dangling link";             assert_link "$D/profiles/lab/sessions" "$S/sessions"
it "repairs a stale link";                assert_link "$D/profiles/lab/state_5.sqlite" "$S/state_5.sqlite"
it "recreates a missing link";            assert_link "$D/profiles/lab/AGENTS.md" "$S/AGENTS.md"
it "repaired data reads correctly";       assert_eq "$(cat "$D/profiles/lab/config.toml")" 'model="gpt-5"'

echo 'private-db' > "$D/profiles/personal/state_5.sqlite.tmp"
rm -f "$D/profiles/personal/state_5.sqlite"
mv "$D/profiles/personal/state_5.sqlite.tmp" "$D/profiles/personal/state_5.sqlite"
out="$(cdx "$D" link)"
it "refuses to clobber private history"; assert_contains "$out" "is this profile's own"
it "private history survives link";      assert_eq "$(cat "$D/profiles/personal/state_5.sqlite")" "private-db"

# -------------------------------------------------------------- rename -----
echo "${DIM}rename${OFF}"
D="$(store_env ren)"
it "renames the former shared profile";  assert_contains "$(cdx "$D" rename main school)" "renamed main to school"
it "renamed profile stays active";       assert_link "$D/codex" "$D/profiles/school"
it "shared data still reachable";        assert_eq "$(cat "$D/profiles/school/sessions/s1.jsonl")" "transcript"
it "other profiles are unaffected";      assert_eq "$(cat "$D/profiles/lab/sessions/s1.jsonl")" "transcript"
it "renames an inactive profile";        assert_contains "$(cdx "$D" rename lab work)" "renamed lab to work"
it "rejects a name collision";           assert_contains "$(cdx "$D" rename work school)" "already exists"
it "suggests a near-miss name";          assert_contains "$(cdx "$D" rename scool x)" "did you mean 'school'"

# ------------------------------------------------------------------ rm -----
echo "${DIM}rm${OFF}"
it "refuses to delete the active one";   assert_contains "$(cdx "$D" rm school -y)" "refusing to delete the active profile"
it "needs a tty without -y";             assert_contains "$(cdx "$D" rm work </dev/null)" "not a terminal"
it "rejects unknown flags";              assert_contains "$(cdx "$D" rm work --force)" "unknown option"
it "suggests a near-miss name";          assert_contains "$(cdx "$D" rm wrok -y)" "did you mean 'work'"
it "deletes with -y";                    assert_contains "$(cdx "$D" rm work -y)" "removed work"
it "shared history outlives a profile";  assert_eq "$(cat "$D/profiles/school/sessions/s1.jsonl")" "transcript"

# Pre-init, 'main' resolves to ~/.codex itself, and nothing has been hoisted
# into the store yet — so deleting it destroys every profile's data at once.
# The guard used to be skipped entirely on an uninitialised install.
# Its own sandbox variable: the sections below still expect $D to be the
# set-up install built above.
PRE="$(new_env rm-preinit)"
it "refuses to delete pre-init main";    assert_contains "$(cdx "$PRE" rm main -y)" "before 'cdx init' it is $PRE/codex itself"
it "pre-init ~/.codex survives";         assert_eq "$(cat "$PRE/codex/sessions/s1.jsonl")" "transcript"

# ------------------------------------------------------ reserved names -----
echo "${DIM}reserved names${OFF}"
it "rm cannot name the store";           assert_contains "$(cdx "$D" rm .store -y)" "reserved for cdx"
it "use cannot name the store";          assert_contains "$(cdx "$D" use .store)" "reserved for cdx"
it "rename cannot name the store";       assert_contains "$(cdx "$D" rename .store evil)" "reserved for cdx"
it "store survives those attempts";      assert_eq "$([ -d "$D/profiles/.store" ] && echo intact)" "intact"
it "rejects a path separator";           assert_contains "$(cdx "$D" add ../escape)" "invalid profile name"

# --------------------------------------------------------------- usage -----
# Quota comes from a live call, so the endpoint is pointed at a local file:
# the parsing, the cache and the failure paths are all exercised without ever
# touching the network (the default CDX_USAGE=off guarantees the rest of the
# suite cannot either).
echo "${DIM}usage${OFF}"
U="$(store_env usage)"
# reset_at is generated three days out rather than hardcoded: the column is
# rendered relative to now, so a fixed timestamp would quietly start reading
# 'now' once that date passed and the assertion would rot.
python3 -c 'import json,sys,time
json.dump({"email":"tester@example.com","plan_type":"pro",
           "rate_limit":{"primary_window":{"used_percent":42,
                         "limit_window_seconds": 604800,
                         "reset_at": time.time() + 3*86400}}}, open(sys.argv[1],"w"))' "$U/usage.json"
export CDX_USAGE=auto CDX_USAGE_ENDPOINT="file://$U/usage.json"
out="$(cdx "$U" list)"
it "list shows the quota column";        assert_contains "$out" "USED"
# Widths follow the content, so a long account name must not be truncated and
# must not leave the columns ragged: every row is the same length as the header.
it "columns size to their content";     assert_eq "$(printf %s "$out" | awk '/chatgpt/{print index($0,"chatgpt")}' | sort -u | wc -l)" "1"
it "the window is labelled";            assert_contains "$out" "42% wk"
it "list shows the used percentage";     assert_contains "$out" "42%"
it "list shows time until the reset";    assert_contains "$out" "(in 3d)"
it "list shows the wall-clock reset";    assert_contains "$out" "$(python3 -c 'import json,time;print(time.strftime("%b %d %H:%M", time.localtime(json.load(open("'"$U"'/usage.json"))["rate_limit"]["primary_window"]["reset_at"])))')"
it "live plan wins over the token";      assert_contains "$out" "pro"
it "the figure is cached per profile";   assert_eq "$(python3 -c 'import json;print(json.load(open("'"$U"'/profiles/lab/.cdx-usage.json"))["used"])')" "42"
it "the cache is not world-readable";    assert_eq "$(stat -c %a "$U/profiles/lab/.cdx-usage.json")" "600"

# An unreadable endpoint must not blank the column or fail the command: the
# last known figure is shown, marked stale.
export CDX_USAGE_ENDPOINT="file://$U/gone.json" CDX_USAGE_TTL=0
out="$(cdx "$U" list)"; rc=$?
it "offline falls back to the cache";    assert_contains "$out" "42%~"
it "offline listing still succeeds";     assert_eq "$rc" "0"
unset CDX_USAGE_TTL
export CDX_USAGE_ENDPOINT="file://$U/usage.json"

# --no-usage and CDX_USAGE=off must never call out, even with a live endpoint
# configured — that is what makes the flag usable on a plane.
rm -f "$U"/profiles/*/.cdx-usage.json
out="$(cdx "$U" list --no-usage)"
it "--no-usage skips the lookup";        assert_eq "$(printf %s "$out" | grep -c '42%')" "0"
it "--no-usage leaves no cache behind";  assert_eq "$(ls "$U"/profiles/*/.cdx-usage.json 2>/dev/null | wc -l)" "0"
it "--refresh is accepted bare";         assert_contains "$(cdx "$U" --refresh)" "42%"
it "rejects unknown list options";       assert_contains "$(cdx "$U" list --bogus)" "unknown option to 'list'"
# status must read the cache rather than call out, so it works offline —
# and 'main' here was never logged in, so switch to an account that has creds.
cdx "$U" use lab --no-restart >/dev/null
it "status reports the cached quota";    assert_contains "$(CDX_USAGE=off cdx "$U" status)" "quota         42% of the weekly limit"
out="$(CDX_USAGE=off cdx "$U" status)"
it "status groups its facts";            assert_eq "$(printf %s "$out" | grep -c '^\(Account\|Storage\|Clients\)$')" "3"
it "status calls shared data shared";    assert_contains "$out" "conversations shared"
it "status shortens paths to ~";         assert_contains "$out" "~/profiles/.store"
it "status still keeps full paths in json"; assert_contains "$(CDX_USAGE=off cdx "$U" status --json)" "$U/profiles/.store/sessions"
it "status --json carries the quota";    assert_eq "$(CDX_USAGE=off cdx "$U" status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["quota"]["used_percent"])')" "42"
it "json quota keeps the raw epoch";     assert_eq "$(CDX_USAGE=off cdx "$U" status --json | python3 -c 'import json,sys;print(type(json.load(sys.stdin)["quota"]["reset_at"]).__name__)')" "float"

# The default mode fills an empty cache once and then stays local: a stale
# figure is reused rather than re-fetched, so the everyday listing never waits
# on the network. 'auto' is what re-fetches on a TTL.
rm -f "$U"/profiles/*/.cdx-usage.json
CDX_USAGE=cache cdx "$U" list >/dev/null
it "the default fills an empty cache";   assert_eq "$([ -f "$U/profiles/lab/.cdx-usage.json" ] && echo cached)" "cached"
out="$(CDX_USAGE=cache CDX_USAGE_TTL=0 CDX_USAGE_ENDPOINT="file://$U/gone.json" cdx "$U" list)"
it "the default never re-fetches";       assert_contains "$out" "42%"
it "so it is never marked stale";        assert_eq "$(printf %s "$out" | grep -c '42%~')" "0"
out="$(CDX_USAGE=auto CDX_USAGE_TTL=0 CDX_USAGE_ENDPOINT="file://$U/gone.json" cdx "$U" list)"
it "'auto' does re-fetch on the TTL";    assert_contains "$out" "42%~"

# An unlabelled percentage reads as current however old it is.
python3 -c 'import json,sys,time
p = sys.argv[1]; d = json.load(open(p)); d["fetched_at"] = time.time() - 7200
json.dump(d, open(p, "w"))' "$U/profiles/lab/.cdx-usage.json"
it "old figures state their age";        assert_contains "$(CDX_USAGE=cache cdx "$U" list)" "quota measured 2h ago"
unset CDX_USAGE CDX_USAGE_ENDPOINT

# Switching is driven by quota, so 'use' reports where you landed — from the
# cache, since activating an account must never wait on the network. The cache
# files are written directly here: that is the format cdx itself writes, and
# it lets each account be pinned to a known figure.
write_quota() {  # <profile> <used_percent> [state]
    python3 -c 'import json,sys,time
json.dump({"fetched_at": time.time(), "used": int(sys.argv[2]),
           "reset_at": time.time() + 86400, "state": sys.argv[3]},
          open(sys.argv[1] + "/.cdx-usage.json", "w"))' \
        "$U/profiles/$1" "$2" "${3:-ok}"
}
write_quota lab 95; write_quota personal 12; write_quota main 40
out="$(CDX_USAGE=off cdx "$U" use personal --no-restart)"
it "use reports the new account's quota"; assert_contains "$out" "quota: 12% used"
it "a healthy account draws no warning";  assert_eq "$(printf %s "$out" | grep -c 'nearly out')" "0"
out="$(CDX_USAGE=off cdx "$U" use lab --no-restart)"
it "use warns near the limit";            assert_contains "$out" "lab is nearly out of quota (95% used)"
it "use names the roomiest account";      assert_contains "$out" "'personal' has the most room (12% used)"
it "the warning threshold is tunable";    assert_eq "$(CDX_QUOTA_WARN=99 CDX_USAGE=off cdx "$U" use lab --no-restart | grep -c 'nearly out')" "0"
write_quota personal 12 relogin
it "use refuses to stay quiet on a dead token"; assert_contains "$(CDX_USAGE=off cdx "$U" use personal --no-restart)" "refresh token is dead"
it "and says how to fix it";              assert_contains "$(CDX_USAGE=off cdx "$U" use personal --no-restart)" "cdx add personal"
rm -f "$U"/profiles/*/.cdx-usage.json
it "no cached figure means no noise";     assert_eq "$(CDX_USAGE=off cdx "$U" use lab --no-restart | grep -c quota)" "0"

# ---------------------------------------------------------------- app -----
# Launching is macOS-only, but the argument parsing is not: [dir] is optional,
# so '--stock' must be recognised in either position. It used to be read only
# as the third word, which made 'cdx app work --stock' pass the flag through
# as the workspace path — and launch non-stock anyway.
echo "${DIM}app${OFF}"
APP="$(store_env app)"
# Reaching the macOS check means the words were parsed as flag/name, not
# rejected as a bad profile name or swallowed as the workspace path.
it "--stock is a flag, not a name";      assert_contains "$(cdx "$APP" app --stock)" "macOS-only"
it "--stock is a flag, not a workspace"; assert_contains "$(cdx "$APP" app lab --stock)" "macOS-only"
it "still rejects unknown options";      assert_contains "$(cdx "$APP" app lab --bogus)" "unknown option to 'app'"
it "rejects a third positional";         assert_contains "$(cdx "$APP" app lab /tmp extra)" "unexpected argument"

# ----------------------------------------------------------------- add -----
echo "${DIM}add${OFF}"
D="$(new_env add)"; cdx "$D" init -y >/dev/null
out="$(cdx "$D" add work)"
it "add logs in";                        assert_contains "$out" "logging in to 'work'"
it "add links the new profile";          assert_link "$D/profiles/work/sessions" "$D/profiles/.store/sessions"
it "add refuses a logged-in profile";    assert_contains "$(cdx "$D" add work)" "already exists"
rm -f "$D/profiles/work/auth.json"
it "add retries an unfinished login";    assert_contains "$(cdx "$D" add work)" "not logged in — retrying login"
it "add passes flags to codex login";    assert_eq "$(cdx "$D" add other --device-auth >/dev/null; cat "$D/profiles/other/.login-args")" "--device-auth"

# ---------------------------------------------------------------- list -----
echo "${DIM}list and use${OFF}"
it "list decodes the account email";     assert_contains "$(cdx "$D" list)" "tester@example.com"
it "list shows the plan";                assert_contains "$(cdx "$D" list)" "plus"
it "list marks the active profile";      assert_contains "$(cdx "$D" list)" " * main"
it "use switches the pointer";           assert_contains "$(cdx "$D" use work --no-restart)" "work is now active"
it "pointer really moved";               assert_link "$D/codex" "$D/profiles/work"
mkdir -p "$D/profiles/blank"
it "use warns when not logged in";       assert_contains "$(cdx "$D" use blank --no-restart)" "not logged in yet"
it "use suggests a near-miss name";      assert_contains "$(cdx "$D" use wrok)" "did you mean 'work'"
it "unknown profile is an error";        assert_fails env HOME="$D" PATH="$D/bin:/usr/bin:/bin" CODEX_PROFILES="$D/profiles" CDX_CODEX_LINK="$D/codex" bash "$CDX" use nope

# ---------------------------------------------------------- dependencies -----
# Both are checked before dispatch, so the failure names the missing program
# instead of surfacing as a listing that dies inside a heredoc.
echo "${DIM}dependencies${OFF}"
# bash by absolute path: these sandboxes exist to omit programs, and env
# resolves the interpreter itself through the same stripped PATH.
dep_env() {
    env -i HOME="$D" PATH="$ROOT/$1" NO_COLOR=1 TERM=dumb \
        CODEX_PROFILES="$D/profiles" CDX_CODEX_LINK="$D/codex" \
        "$(command -v bash)" "$CDX" list 2>&1
}
mkdir -p "$ROOT/nopy" "$ROOT/nocodex"
cp "$D/bin/codex" "$ROOT/nopy/codex"
ln -sf "$(command -v python3)" "$ROOT/nocodex/python3"
it "names a missing python3";            assert_contains "$(dep_env nopy)" "python3 is not on PATH"
it "names a missing codex";              assert_contains "$(dep_env nocodex)" "codex is not on PATH"

# ---------------------------------------------------- process matching -----
# 'rename' is the surviving user of the if-stale proxy policy, so it is what
# exercises this. These runs are real, not dry — CDX_NO_KILL=1 (set in the cdx
# helper) makes cdx report its selection and signal nothing, which is what
# keeps a broken build from reaching the real Codex processes that pgrep can
# also see. The holder opens a file genuinely inside the profile: everything
# shared resolves into the store, which is deliberately not under a profile.
echo "${DIM}process matching${OFF}"
D="$(store_env proc)"
# Per-profile file: after init, everything else in a profile is a symlink whose
# fd resolves into the store, which is intentionally outside every profile.
echo log > "$D/profiles/main/codex-tui.log"
spawn_named codex-test-holder 'exec 9<"'"$D"'/profiles/main/codex-tui.log"; '; holder="$SPAWN_PID"
spawn_named 'codex app-server proxy';                                        proxy="$SPAWN_PID"
sleep 0.5

out="$(cdx "$D" rename main one)"
it "finds a process bound to the profile"; assert_contains "$out" "$holder"
it "escalates to proxies when stale";      assert_contains "$out" "$proxy"
it "announces the disconnect";             assert_contains "$out" "Disconnecting"
it "CDX_NO_KILL suppresses the signal";    assert_contains "$out" "signalling nothing"
it "nothing was actually killed";          assert_eq "$(kill -0 "$holder" 2>/dev/null && kill -0 "$proxy" 2>/dev/null && echo both-alive)" "both-alive"

kill "$holder" 2>/dev/null; sleep 1.3
out="$(cdx "$D" rename one two)"
it "spares proxies when nothing is stale"; assert_contains "$out" "No running processes were bound"
it "idle proxy is left alone";             assert_eq "$(kill -0 "$proxy" 2>/dev/null && echo alive)" "alive"

# A process bound to a different sandbox must not be dragged in.
D2="$(store_env proc2)"
echo log > "$D2/profiles/main/codex-tui.log"
spawn_named codex-other-holder 'exec 9<"'"$D2"'/profiles/main/codex-tui.log"; '; other="$SPAWN_PID"
sleep 0.5
it "ignores processes bound elsewhere";    assert_contains "$(cdx "$D" rename two three)" "No running processes were bound"
it "matches them in their own sandbox";    assert_contains "$(cdx "$D2" rename main other)" "$other"

printf '\n%s%d passed%s' "$GREEN" "$PASS" "$OFF"
[ "$FAIL" -gt 0 ] && printf ', %s%d failed%s' "$RED" "$FAIL" "$OFF"
printf '\n'
[ "$FAIL" -eq 0 ]
