#!/usr/bin/env bash
# Regression tests for bin/gmon.
#
# gmon has no sandbox environment variables — its config path is
# ~/.config/gmon/hosts — so HOME is redirected instead, and a fake ssh and
# nvidia-smi are put on PATH ahead of anything real. Nothing here touches a
# real host: the fake ssh refuses to be a network client and only replays
# canned nvidia-smi output.
#
# Output is rendered with truecolor escapes unconditionally, so every
# assertion runs against a de-escaped copy.
set -uo pipefail

GMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/gmon"
[ -x "$GMON" ] || { echo "cannot find bin/gmon next to tests/" >&2; exit 1; }

PASS=0 FAIL=0 CURRENT=""
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gmon-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }

it()   { CURRENT="$1"; }
ok()   { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$CURRENT"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n     %s\n' "$RED" "$OFF" "$CURRENT" "$1"; }

assert_eq()       { [ "$1" = "$2" ] && ok || bad "expected '$2', got '$1'"; }
assert_contains() { case "$1" in *"$2"*) ok ;; *) bad "expected to contain '$2', got: $(printf %s "$1" | tr '\n' ' ' | cut -c1-160)" ;; esac; }
assert_missing()  { case "$1" in *"$2"*) bad "expected NOT to contain '$2'" ;; *) ok ;; esac; }

# Every assertion reads the rendered table, and the renderer always emits
# truecolor escapes — there is no NO_COLOR path to turn them off.
plain() { sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'; }

BIN="$ROOT/bin"; mkdir -p "$BIN"

# Two GPUs: index 0 idle and nearly empty (free by gmon's rule), index 1 busy
# with two processes owned by different users. The UUIDs are what ties the
# compute-apps list back to a GPU, since gpu_index is not queryable on every
# driver — that correlation is the part worth pinning.
cat > "$BIN/nvidia-smi" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *--query-gpu=*)
        if [ -n "${GMON_FAKE_NO_GPUS:-}" ]; then exit 0; fi
        echo 'NVIDIA H200, GPU-aaaa, 0, 0, 12, 143771, 31, [N/A]'
        echo 'NVIDIA H200, GPU-bbbb, 1, 97, 120000, 143771, 84, 61'
        ;;
    *--query-compute-apps=*)
        [ -n "${GMON_FAKE_NO_GPUS:-}" ] && exit 0
        echo 'GPU-bbbb, 4242'
        echo 'GPU-bbbb, 4243'
        ;;
esac
STUB
chmod +x "$BIN/nvidia-smi"

# gmon resolves a pid to an owner with 'ps -o user= -p'. Answering from a table
# keeps the test independent of what is actually running on this machine.
cat > "$BIN/ps" <<'STUB'
#!/usr/bin/env bash
pid=""
while [ $# -gt 0 ]; do
    case "$1" in -p) pid="$2"; shift ;; esac
    shift
done
case "$pid" in
    4242) echo alice ;;
    4243) echo bob ;;
esac
STUB
chmod +x "$BIN/ps"

# Records its argv so the jump-host flags can be asserted on, then runs the
# command it was given locally — which is exactly what a real ssh does, minus
# the network.
cat > "$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GMON_SSH_LOG:?}"
if [ -n "${GMON_SSH_FAIL:-}" ]; then
    echo "ssh: connect to host port 22: Connection refused" >&2
    exit 255
fi
bash -c "${@: -1}"
STUB
chmod +x "$BIN/ssh"

export HOME="$ROOT/home"
export PATH="$BIN:/usr/bin:/bin"
export GMON_SSH_LOG="$ROOT/ssh.log"
mkdir -p "$HOME/.config/gmon"
CONFIG="$HOME/.config/gmon/hosts"

gmon() { : > "$GMON_SSH_LOG"; "$GMON" "$@" 2>&1 | plain; }

echo "gmon regression tests"

# ------------------------------------------------------------- arguments -----
echo "${DIM}arguments${OFF}"
it "help describes the tool";        assert_contains "$(gmon --help)" "polls nvidia-smi across SSH hosts"
it "help documents the config path"; assert_contains "$(gmon --help)" "$CONFIG"
# An empty config is the first-run state, and the message has to name both the
# file to write and the command that writes it.
it "no hosts is explained";          assert_contains "$(gmon)" "No hosts found"
it "and points at --edit";           assert_contains "$(gmon)" "gmon --edit"
it "no hosts exits non-zero";        assert_eq "$("$GMON" >/dev/null 2>&1; echo $?)" "1"

# ---------------------------------------------------------------- config -----
echo "${DIM}config${OFF}"
printf '# a comment\n\nalpha  # trailing comment\nbeta\n' > "$CONFIG"
out="$(gmon --once)"
it "reads one host per line";        assert_contains "$out" "alpha"
it "and the second";                 assert_contains "$out" "beta"
it "strips inline comments";         assert_missing "$out" "trailing comment"
it "ignores comment-only lines";     assert_missing "$out" "a comment"
it "arguments override the config";  assert_missing "$(gmon --once gamma)" "alpha"

# ----------------------------------------------------------------- table -----
echo "${DIM}table${OFF}"
printf 'alpha\n' > "$CONFIG"
out="$(gmon --once)"
it "renders the header";             assert_contains "$out" "MEMORY (MiB)"
# 'contains H200' would pass on the undropped name too, so assert the absence.
it "drops the NVIDIA name prefix";   assert_missing "$out" "NVIDIA H200"
it "shows utilisation";              assert_contains "$out" "97%"
it "shows memory used and total";    assert_contains "$out" "120000/143771"
it "shows temperature";              assert_contains "$out" "84°C"
# A fan reading of [N/A] is normal on datacentre cards; it must render as a
# dash rather than crashing the int conversion or printing 'None'.
it "renders an absent fan reading";  assert_contains "$out" "—"
it "never prints a bare None";       assert_missing "$out" "None"

# Compute processes are correlated to their GPU by UUID, then to a username by
# pid. Both users of the busy card must appear, and only on that card's row.
it "maps processes to users";        assert_contains "$out" "alice, bob"
it "an unused GPU reads idle";       assert_contains "$out" "idle"

# The free-GPU summary is what the tool is for: index 0 has no processes and
# 12 MiB used, so it is grabbable; index 1 is not.
it "counts the free GPU";            assert_contains "$out" "1 GPU free"
it "names host and index";           assert_contains "$out" "alpha:0"
it "a busy GPU is not free";         assert_missing "$out" "alpha:0,1"
# --free-mem is the knob for a card that idles with a few hundred MiB resident.
it "--free-mem can exclude it";      assert_contains "$(gmon --once --free-mem 8)" "no free GPUs"

# ------------------------------------------------------------------ ssh -----
echo "${DIM}ssh${OFF}"
gmon --once >/dev/null
it "polls a remote host over ssh";   assert_eq "$(grep -c 'nvidia-smi' "$GMON_SSH_LOG")" "1"
it "keeps the connection warm";      assert_contains "$(cat "$GMON_SSH_LOG")" "ControlPersist=30s"
it "never prompts for a password";   assert_contains "$(cat "$GMON_SSH_LOG")" "BatchMode=yes"

printf 'jump=thor\nalpha\n' > "$CONFIG"
gmon --once >/dev/null
it "uses the configured jump host";  assert_contains "$(cat "$GMON_SSH_LOG")" "-J thor"
gmon --once --no-jump >/dev/null
it "--no-jump drops it";             assert_missing "$(cat "$GMON_SSH_LOG")" "-J"
gmon --once --jump loki >/dev/null
it "--jump overrides it";            assert_contains "$(cat "$GMON_SSH_LOG")" "-J loki"
it "jump= is not a host";            assert_missing "$(gmon --once)" "jump="

# A host that cannot be reached must not take the table down with it: the row
# says why, and the rest of the run still renders.
printf 'alpha\nbeta\n' > "$CONFIG"
out="$(GMON_SSH_FAIL=1 gmon --once)"
it "an unreachable host says so";    assert_contains "$out" "error:"
it "and does not stop the others";   assert_contains "$out" "beta"

# ---------------------------------------------------------------- local -----
echo "${DIM}local${OFF}"
# 'local' means this machine. SSH-ing to yourself works only if sshd is up and
# the alias resolves from here, and it spends a connection on data already at
# hand — so the keyword must bypass ssh entirely.
printf 'local\n' > "$CONFIG"
out="$(gmon --once)"
it "polls this machine directly";    assert_eq "$(wc -l < "$GMON_SSH_LOG")" "0"
it "and still renders its GPUs";     assert_contains "$out" "H200"
# Writing the box's own hostname is the obvious thing to try, and it must mean
# the same thing rather than quietly opening a connection to ourselves.
printf '%s\n' "$(hostname)" > "$CONFIG"
gmon --once >/dev/null
it "the real hostname is local too"; assert_eq "$(wc -l < "$GMON_SSH_LOG")" "0"
printf '%s\n' "$(hostname | cut -d. -f1)" > "$CONFIG"
gmon --once >/dev/null
it "so is its short form";           assert_eq "$(wc -l < "$GMON_SSH_LOG")" "0"

# ------------------------------------------------------------- no GPUs -----
echo "${DIM}degraded hosts${OFF}"
printf 'alpha\n' > "$CONFIG"
out="$(GMON_FAKE_NO_GPUS=1 gmon --once)"
it "a host without GPUs says so";    assert_contains "$out" "no GPUs / nvidia-smi not found"
it "and is not counted as free";     assert_contains "$out" "no free GPUs"

printf '\n%s\n' "$([ "$FAIL" -eq 0 ] && echo "$PASS passed" || echo "$PASS passed, $FAIL failed")"
[ "$FAIL" -eq 0 ]
