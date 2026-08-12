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
# Assertions compare against cdx's rendered output, which contains a literal
# '~' where it has shortened $HOME. Expanding it is exactly what must not
# happen, so the check that warns about unexpanded tildes is off for this file.
# shellcheck disable=SC2088
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
    echo 'memories-db'    > "$d/codex/memories_1.sqlite"
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
        "$CDX" "$@" 2>&1
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
# Every shareable item but one — the list has to stay in step with the fixture,
# since a second leftover puts the braces back and the case goes untested.
for f in config.toml AGENTS.md state_5.sqlite memories_1.sqlite packages; do
    rm -rf "$E/profiles/main/$f"
done
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

# ------------------------------------------- link without codex on PATH -----
# A real install launches codex through ~/.local/bin/codex, a symlink into the
# shared packages/ dir by way of the active profile. So the moment a profile's
# packages link goes stale — which is precisely what a hand-run migration
# leaves behind — codex stops resolving. 'link' is the command that re-points
# it, so requiring codex on PATH would strand the fix behind the breakage.
echo "${DIM}link without codex on PATH${OFF}"
D="$(store_env nolauncher)"
chmod +x "$D/profiles/.store/packages/codex-bin"
ln -sf "$D/codex/packages/codex-bin" "$D/bin/codex"
it "launcher resolves while linked";      assert_eq "$([ -x "$D/bin/codex" ] && echo yes || echo no)" "yes"

# What a migration leaves: the store moved, the profile still points at the old
# path, and every hop through the active profile now dangles.
ln -sfn "$D/profiles/.store/packages-old" "$D/profiles/main/packages"
it "a stale link breaks the launcher";    assert_eq "$([ -x "$D/bin/codex" ] && echo yes || echo no)" "no"
it "other commands still demand codex";   assert_contains "$(cdx "$D" list)" "not on PATH"
it "so does running a profile";           assert_contains "$(cdx "$D" personal)" "not on PATH"

out="$(cdx "$D" link)"
it "link runs without codex on PATH";     assert_contains "$out" "linked main"
it "link re-pointed the stale link";      assert_link "$D/profiles/main/packages" "$D/profiles/.store/packages"
it "the launcher resolves again";         assert_eq "$([ -x "$D/bin/codex" ] && echo yes || echo no)" "yes"
it "and codex is demanded once more";     assert_eq "$(cdx "$D" list | grep -c 'not on PATH')" "0"

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

# memories_1.sqlite is the exception among the sqlite files: Codex rewrites it
# atomically, so a real file here is the app-server having clobbered the link,
# not private data. Guarding it the way state_5.sqlite is guarded left the
# profile permanently unlinked, since the next app-server recreated the file.
echo 'clobbered-by-codex' > "$D/profiles/personal/memories_1.sqlite.tmp"
rm -f "$D/profiles/personal/memories_1.sqlite"
mv "$D/profiles/personal/memories_1.sqlite.tmp" "$D/profiles/personal/memories_1.sqlite"
out="$(cdx "$D" link)"
it "relinks a clobbered memories db";    assert_link "$D/profiles/personal/memories_1.sqlite" "$S/memories_1.sqlite"
it "and says nothing about it";          assert_eq "$(printf %s "$out" | grep -c 'memories_1')" "0"
it "the shared memories db is intact";   assert_eq "$([ -f "$S/memories_1.sqlite" ] && [ ! -L "$S/memories_1.sqlite" ] && echo real)" "real"
it "state_5 is still guarded";           assert_eq "$(cat "$D/profiles/personal/state_5.sqlite")" "private-db"

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
it "columns size to their content";     assert_eq "$(printf %s "$out" | awk '/tester@/{print index($0,"tester@")}' | sort -u | wc -l)" "1"
# How you signed in is 'chatgpt' on every ordinary account, so it earns no
# column — but it still has to be visible when it is something else, or an
# API-key profile would look like a ChatGPT one.
it "no MODE column";                    assert_eq "$(printf %s "$out" | grep -c 'MODE')" "0"
mkdir -p "$U/profiles/apikey-acct"
printf '{"OPENAI_API_KEY": "sk-test"}\n' > "$U/profiles/apikey-acct/auth.json"
it "an API-key login says so";          assert_contains "$(CDX_USAGE=off cdx "$U" list)" "(apikey)"
it "and does not claim to be chatgpt";  assert_eq "$(CDX_USAGE=off cdx "$U" list | grep -c 'chatgpt')" "0"
rm -rf "$U/profiles/apikey-acct"
it "the window is labelled";            assert_contains "$out" "42% wk"
it "list shows the used percentage";     assert_contains "$out" "42%"
it "list shows time until the reset";    assert_contains "$out" "(in 3d)"
it "list shows the wall-clock reset";    assert_contains "$out" "$(python3 -c 'import json,time;print(time.strftime("%b %d %H:%M", time.localtime(json.load(open("'"$U"'/usage.json"))["rate_limit"]["primary_window"]["reset_at"])))')"
it "live plan wins over the token";      assert_contains "$out" "pro"
it "the figure is cached per profile";   assert_eq "$(python3 -c 'import json;print(json.load(open("'"$U"'/profiles/lab/.cdx-usage.json"))["used"])')" "42"
it "the cache is not world-readable";    assert_eq "$(stat -c %a "$U/profiles/lab/.cdx-usage.json")" "600"

# Credits. A subscription reports 'has_credits: false' with a zero balance
# attached — it means "this account does not use credits", NOT "the balance is
# spent". Reading it as exhaustion marked every working account empty, so the
# balance is now recorded and only stated when the payload states one. Until
# the field carrying a real balance is identified, no account is called spent.
python3 -c 'import json,sys,time
json.dump({"email":"tester@example.com","plan_type":"plus",
           "rate_limit":{"primary_window":{"used_percent":16,
                         "limit_window_seconds": 604800,
                         "reset_at": time.time() + 3*86400},
                         "credits":{"has_credits":False,"unlimited":False,
                                    "balance":"0"}}}, open(sys.argv[1],"w"))' "$U/subscription.json"
out="$(CDX_USAGE_ENDPOINT="file://$U/subscription.json" CDX_USAGE_TTL=0 cdx "$U" list)"
it "a subscription is never 'spent'";    assert_eq "$(python3 -c 'import json;print(json.load(open("'"$U"'/profiles/lab/.cdx-usage.json"))["state"])')" "ok"
it "and shows no balance at all";        assert_eq "$(printf %s "$out" | grep -c NOTE)" "0"
# The spelled-out credit line belongs to 'status' alone. It reached the NOTE
# column once, because 'read' packs every remaining field into its last
# variable — so a new column upstream silently lands inside the previous one.
# 'main' is still active here and was never logged in, so ask about the profile
# these fixtures actually wrote to.
cdx "$U" use lab --no-restart >/dev/null
it "status spells the credits out";      assert_contains "$(CDX_USAGE=off cdx "$U" status)" "allowance     not used on this plan"
it "the listing does not";               assert_eq "$(printf %s "$out" | grep -c 'not used on this plan')" "0"
it "the raw credits are kept anyway";    assert_eq "$(python3 -c 'import json;print(json.load(open("'"$U"'/profiles/lab/.cdx-usage.json"))["credits"]["has_credits"])')" "False"
it "the percentage is unaffected";       assert_contains "$out" "16% wk"
# Spend control: an admin-set budget is the third exhaustion axis, and the only
# one that stops an account while every rate-limit field reports fine. This
# fixture is the real payload from an account that could not run: allowed true,
# limit_reached false, 0% on the 5h window and 16% on the week, has_credits
# true with a null balance — nothing but spend_control.reached says so.
python3 -c 'import json,sys,time
json.dump({"email":"tester@example.com","plan_type":"education",
           "rate_limit":{"allowed":True,"limit_reached":False,
                         "primary_window":{"used_percent":0,
                          "limit_window_seconds":18000,
                          "reset_at": time.time() + 3600},
                         "secondary_window":{"used_percent":16,
                          "limit_window_seconds":604800,
                          "reset_at": time.time() + 3*86400},
                         "credits":{"has_credits":True,"unlimited":False,
                                    "balance":None}},
           "spend_control":{"individual_limit":None,"reached":True}},
          open(sys.argv[1],"w"))' "$U/spendlimit.json"
out="$(CDX_USAGE_ENDPOINT="file://$U/spendlimit.json" CDX_USAGE_TTL=0 cdx "$U" list)"
it "a reached spend limit is a state";   assert_eq "$(python3 -c 'import json;print(json.load(open("'"$U"'/profiles/lab/.cdx-usage.json"))["state"])')" "spendlimit"
it "the listing says so";                assert_contains "$out" "spend limit"
# The cell says what stopped the account rather than a percentage that did
# not; the percentage is still there in 'status', which has room for both.
it "the cell drops the percentage";      assert_eq "$(printf %s "$out" | grep -c '16% wk')" "0"
it "status still has both";              assert_contains "$(CDX_USAGE=off cdx "$U" status)" "16% of the weekly limit"
it "the binding window is the weekly one"; assert_eq "$(printf %s "$out" | grep -c '0% 5h')" "0"
it "a null balance prints no number";    assert_eq "$(printf %s "$out" | grep -c 'None')" "0"
out="$(CDX_USAGE=off cdx "$U" use lab --no-restart)"
it "use refuses to stay quiet";          assert_contains "$out" "'lab' is over its spend limit and cannot run"
it "use marks the figure as not the cause"; assert_contains "$out" "which is not what stopped it"
it "status names the real limit";        assert_contains "$(CDX_USAGE=off cdx "$U" status)" "over its spend limit"
# The listing has room for one figure and shows whichever binds; status has
# room for every window the endpoint reported. This account is at 0% of five
# hours and 16% of the week — one number cannot say that.
out="$(CDX_USAGE=off cdx "$U" status)"
it "status breaks the windows out";      assert_contains "$out" "5h"
it "with a bar per window";              assert_contains "$out" "░"
it "the idle window reads zero";         assert_contains "$out" "0%"
it "and the weekly one sixteen";         assert_contains "$out" "16%"
it "the binding window is marked";       assert_eq "$(printf %s "$out" | grep -c '  <$')" "1"
# A single-window account gets no breakdown: it would just repeat the line
# above it.
it "one window means no breakdown";      assert_eq "$(CDX_USAGE_ENDPOINT="file://$U/usage.json" CDX_USAGE_TTL=0 cdx "$U" list >/dev/null; CDX_USAGE=off cdx "$U" status | grep -c '░')" "0"
# That fetch replaced the cache these fixtures set up; put the spend-limited
# figure back for the assertions below.
CDX_USAGE_ENDPOINT="file://$U/spendlimit.json" CDX_USAGE_TTL=0 cdx "$U" list >/dev/null
it "json carries the state";             assert_eq "$(CDX_USAGE=off cdx "$U" status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["quota"]["state"])')" "spendlimit"
# An individual limit does carry numbers; a workspace-level one never does.
python3 -c 'import json,sys,time
json.dump({"email":"tester@example.com","plan_type":"business",
           "rate_limit":{"primary_window":{"used_percent":16,
                         "limit_window_seconds":604800,
                         "reset_at": time.time() + 3*86400}},
           "spend_control":{"reached":False,
                            "individual_limit":{"limit":"7000",
                             "remaining_percent":12,
                             "resets_at": time.time() + 9*86400}}},
          open(sys.argv[1],"w"))' "$U/budget.json"
out="$(CDX_USAGE_ENDPOINT="file://$U/budget.json" CDX_USAGE_TTL=0 cdx "$U" list)"
it "an individual budget shows numbers"; assert_contains "$(CDX_USAGE=off cdx "$U" status)" "12% of the spend budget left (limit 7000)"
it "a budget with room is not a block";  assert_eq "$(python3 -c 'import json;print(json.load(open("'"$U"'/profiles/lab/.cdx-usage.json"))["state"])')" "ok"
it "and does not crowd the listing";     assert_contains "$out" "16% wk"

# A stated balance is shown; 'unlimited' says so rather than printing a number.
python3 -c 'import json,sys,time
json.dump({"email":"tester@example.com","plan_type":"enterprise",
           "rate_limit":{"primary_window":{"used_percent":16,
                         "limit_window_seconds": 604800,
                         "reset_at": time.time() + 3*86400},
                         "credits":{"has_credits":True,"unlimited":True,
                                    "balance":"0"}}}, open(sys.argv[1],"w"))' "$U/unlimited.json"
out="$(CDX_USAGE_ENDPOINT="file://$U/unlimited.json" CDX_USAGE_TTL=0 cdx "$U" list)"
it "unlimited is not a number";          assert_contains "$(CDX_USAGE=off cdx "$U" status)" "allowance     unlimited"
it "unlimited is not spent";             assert_eq "$(python3 -c 'import json;print(json.load(open("'"$U"'/profiles/lab/.cdx-usage.json"))["state"])')" "ok"
# Put the 42% figure back: these fixtures wrote through the same per-profile
# cache the sections below read as their 'last known' value.
CDX_USAGE_ENDPOINT="file://$U/usage.json" CDX_USAGE_TTL=0 cdx "$U" list >/dev/null

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

# The listing as data. Anything consuming this wants to compare numbers, so it
# carries the percentage and the epoch rather than '42% wk' and a countdown —
# re-parsing a cell built for a terminal is the mistake this file has made
# twice already.
js="$(cdx "$U" list --json)"
it "list --json is valid json";          assert_eq "$(printf %s "$js" | python3 -c 'import json,sys;json.load(sys.stdin);print("ok")')" "ok"
it "it names the active profile";        assert_eq "$(printf %s "$js" | python3 -c 'import json,sys;print(json.load(sys.stdin)["active_profile"])')" "lab"
it "one entry per account";              assert_eq "$(printf %s "$js" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["accounts"]))')" "3"
it "the figure is a number, not a cell"; assert_eq "$(printf %s "$js" | python3 -c 'import json,sys;a=json.load(sys.stdin)["accounts"];print(type([x for x in a if x["name"]=="lab"][0]["used_percent"]).__name__)')" "int"
it "and the reset keeps its epoch";      assert_eq "$(printf %s "$js" | python3 -c 'import json,sys;a=json.load(sys.stdin)["accounts"];print(type([x for x in a if x["name"]=="lab"][0]["windows"][0]["reset_at"]).__name__)')" "float"
it "usability is stated outright";       assert_eq "$(printf %s "$js" | python3 -c 'import json,sys;a=json.load(sys.stdin)["accounts"];print([x["usable"] for x in a if x["name"]=="lab"][0])')" "True"
it "and no ANSI leaks into it";          assert_eq "$(printf %s "$js" | grep -c $'\033')" "0"
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

# Asking about an account you are not on is the point: deciding whether to
# switch should not require switching first. Everything below the Account
# section still describes the machine, so the mismatch verdict is unchanged.
write_quota personal 7 >/dev/null 2>&1 || true
out="$(CDX_USAGE=off cdx "$U" status personal)"
it "status can report another account";  assert_contains "$out" "profile       personal"
it "and says it is not the active one";  assert_contains "$out" "(not active — 'lab' is)"
it "the active one says nothing extra";  assert_eq "$(CDX_USAGE=off cdx "$U" status | grep -c 'not active')" "0"
it "json names the reported profile";    assert_eq "$(CDX_USAGE=off cdx "$U" status personal --json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["reported_profile"], d["active_profile"])')" "personal lab"
it "an unknown name is an error";        assert_contains "$(CDX_USAGE=off cdx "$U" status nope)" "no such profile"
it "a near-miss is suggested";           assert_contains "$(CDX_USAGE=off cdx "$U" status personl)" "did you mean 'personal'"
it "two names are refused";              assert_contains "$(CDX_USAGE=off cdx "$U" status lab personal)" "takes one profile name"
it "unknown flags are refused";          assert_contains "$(CDX_USAGE=off cdx "$U" status --bogus)" "unknown option to 'status'"

# Per-command help. 'cdx -h' is a map of the whole tool; the detail for one
# command has to live where anyone would look for it.
it "status has its own help";            assert_contains "$(cdx "$U" status -h)" "cdx status [name] [--json]"
it "help does not run the command";      assert_eq "$(cdx "$U" status -h | grep -c '^Account$')" "0"
it "every command has help";             assert_eq "$(for c in list status use add app ssh rename rm init link; do cdx "$U" "$c" --help | head -1; done | grep -c '^cdx ')" "10"
# 'cdx add work --help' is asking codex login for its help, not cdx for its
# own, so only the word straight after the command counts.
it "help is positional";                 assert_eq "$(cdx "$U" add work --help | grep -c '^cdx add')" "0"

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
#
# 'window' is not optional here. A cache written by cdx itself always carries
# it, and it is what turns the rendered figure into '95% wk' — the form that
# broke the percentage parse in 'use' while a window-less fixture kept every
# assertion green. A fixture that cannot produce the real string cannot catch
# the real bug.
write_quota() {  # <profile> <used_percent> [state] [window_seconds]
    python3 -c 'import json,sys,time
json.dump({"fetched_at": time.time(), "used": int(sys.argv[2]),
           "reset_at": time.time() + 86400, "state": sys.argv[3],
           "window": int(sys.argv[4])},
          open(sys.argv[1] + "/.cdx-usage.json", "w"))' \
        "$U/profiles/$1" "$2" "${3:-ok}" "${4:-604800}"
}
write_quota lab 95; write_quota personal 12; write_quota main 40
out="$(CDX_USAGE=off cdx "$U" use personal --no-restart)"
it "use reports the new account's quota"; assert_contains "$out" "quota: 12% wk used"
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

# The listing answers "where should I work?", so it says something only when
# the account you are on cannot answer it. A healthy active account gets
# silence — the same rule the columns follow.
write_quota lab 10; write_quota personal 20; write_quota main 30
cdx "$U" use lab --no-restart >/dev/null
it "a healthy account is not nagged";    assert_eq "$(CDX_USAGE=off cdx "$U" list | grep -c 'most room')" "0"
# Recommending somewhere fuller than where you already are is worse than
# saying nothing: this is what the listing did the moment it grew its own
# copy of the search instead of sharing one with 'use'.
write_quota lab 95; write_quota personal 99; write_quota main 98
it "never sends you somewhere fuller";   assert_contains "$(CDX_USAGE=off cdx "$U" list)" "no other account has room"
write_quota personal 12
it "names the roomiest when there is one"; assert_contains "$(CDX_USAGE=off cdx "$U" list)" "'personal' has the most room (12% used)"
it "and gives the command";              assert_contains "$(CDX_USAGE=off cdx "$U" list)" "'cdx use personal'"
# A bar in front of the figure, so fullness reads without parsing digits. It
# is plain block characters, not escapes, so it survives NO_COLOR and a pipe.
it "the listing draws a bar";            assert_contains "$(CDX_USAGE=off cdx "$U" list)" "░"
it "and keeps the figure intact";        assert_contains "$(CDX_USAGE=off cdx "$U" list)" "12%"
rm -f "$U"/profiles/*/.cdx-usage.json

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

# The window label is what the percentage has to survive, so vary it: a 5-hour
# window renders '95% 5h', and the warning has to fire on that too. Both the
# listing and 'use' read the same rendered cell, and they used to parse it
# differently — the listing correctly, 'use' not at all.
write_quota lab 95 ok 18000; write_quota personal 12 ok 18000
out="$(CDX_USAGE=off cdx "$U" use lab --no-restart)"
it "warns on a five-hour window too";     assert_contains "$out" "lab is nearly out of quota (95% used)"
it "and labels the window it reports";    assert_contains "$out" "quota: 95% 5h used"
it "the listing agrees on the figure";    assert_contains "$(CDX_USAGE=off cdx "$U" list)" "95% 5h"
it "status spells the window out";        assert_contains "$(CDX_USAGE=off cdx "$U" status)" "of the 5-hour limit"

it "add refuses a logged-in profile";    assert_contains "$(cdx "$D" add work)" "already exists"
rm -f "$D/profiles/work/auth.json"
it "add retries an unfinished login";    assert_contains "$(cdx "$D" add work)" "not logged in — retrying login"
# Credentials are attached to this request, so the destination is checked
# before anything is sent: a plain-http endpoint would put the token on the
# wire in clear.
it "refuses a cleartext endpoint";        assert_contains "$(CDX_USAGE_ENDPOINT=http://example.invalid/u cdx "$U" list)" "refusing to send credentials"
it "refuses a non-http scheme";           assert_contains "$(CDX_USAGE_ENDPOINT=ftp://example.invalid/u cdx "$U" list)" "refusing to send credentials"

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
it "unknown profile is an error";        assert_fails env HOME="$D" PATH="$D/bin:/usr/bin:/bin" CODEX_PROFILES="$D/profiles" CDX_CODEX_LINK="$D/codex" "$CDX" use nope

# ---------------------------------------------------------- dependencies -----
# codex is checked before dispatch, so the failure names the missing program
# instead of surfacing as a listing that dies part-way through.
#
# python3 is no longer checked, and cannot be: cdx is written in it, so a
# machine without it fails at the shebang with env's own message before any
# cdx code runs. That is the one behaviour the port gave up — the bash version
# printed "python3 is not on PATH", which was a kindness to a host that cdx
# was about to be copied onto by 'cdx ssh'. What must still hold is that it
# fails loudly rather than half-working, which is what this asserts.
echo "${DIM}dependencies${OFF}"
dep_env() {
    env -i HOME="$D" PATH="$ROOT/$1" NO_COLOR=1 TERM=dumb \
        CODEX_PROFILES="$D/profiles" CDX_CODEX_LINK="$D/codex" \
        "$CDX" list 2>&1
}
mkdir -p "$ROOT/nopy" "$ROOT/nocodex"
cp "$D/bin/codex" "$ROOT/nopy/codex"
ln -sf "$(command -v python3)" "$ROOT/nocodex/python3"
it "refuses to run without python3";     assert_fails env -i HOME="$D" PATH="$ROOT/nopy" \
    CODEX_PROFILES="$D/profiles" CDX_CODEX_LINK="$D/codex" "$CDX" list
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
