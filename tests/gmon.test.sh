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
        if [ -n "${GMON_FAKE_NO_FAN:-}" ]; then
            echo 'NVIDIA H200, GPU-aaaa, 0, 0, 12, 143771, 31, [N/A]'
            echo 'NVIDIA H200, GPU-bbbb, 1, 97, 120000, 143771, 84, [N/A]'
            exit 0
        fi
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
# Five hosts of four GPUs was 31 lines for 21 of data — a third of a short
# terminal spent on separators. The grouping survives on the hostname column
# and the per-host accent colour, so the rows themselves carry it.
it "spends no line on a rule";       assert_eq "$(printf %s "$out" | grep -c '───')" "0"
# One blank row between hosts and nowhere else: not needed to parse the table,
# but wanted to read it. With one host in this sandbox there is nothing to
# separate, so the count is zero here and one for a second host.
it "a single host needs no spacer";  assert_eq "$(printf %s "$out" | grep -c '^[[:space:]]*$')" "0"
it "two hosts get one between them"; assert_eq "$(printf 'alpha\nbeta\n' > "$CONFIG"; gmon --once | grep -c '^[[:space:]]*$'; printf 'alpha\n' > "$CONFIG")" "1"
it "chrome is two lines";            assert_eq "$(printf %s "$out" | grep -cE 'GPU Monitor|GPUs? free|no free GPUs|HOST +GPU')" "2"
# The clock and the free list share a line when they fit, and split when they
# do not — two header rows for one sentence is a lot on a short terminal, but
# a wrapped line is worse than two clean ones.
it "wide terminals get one line";    assert_eq "$(COLUMNS=200 gmon --once | grep -c 'GPU Monitor')" "0"
# One host with two GPUs still fits in 40 columns here, so the split has to be
# forced with a width no real terminal would have.
it "narrow ones split it";           assert_eq "$(COLUMNS=20 gmon --once | grep -c 'GPU Monitor')" "1"
it "and the clock survives either";  assert_eq "$(COLUMNS=20 gmon --once | grep -cE '[0-9]{2}:[0-9]{2}:[0-9]{2}')" "1"
# The live frame must not end in a newline: the cursor would sit on the row
# below the table, and with it hidden that reads as a bottom margin. One-shot
# output keeps it, or the shell prompt resumes on top of the last row. Checked
# against render() directly, since only a terminal shows the difference.
frame_check() {
    python3 - "$GMON" <<'PYEOF'
import importlib.machinery, importlib.util, sys
spec = importlib.util.spec_from_loader(
    "gmon", importlib.machinery.SourceFileLoader("gmon", sys.argv[1]))
gmon = importlib.util.module_from_spec(spec)
sys.modules["gmon"] = gmon
spec.loader.exec_module(gmon)
rows = [("alpha", [{"name": "A100", "idx": "0", "util": 0, "mem_used": 0,
                    "mem_total": 81920, "temp": 40, "fan": 30, "users": []}], None, None)]
print("live-newline" if gmon.render(rows, live=True).endswith("\n") else "live-clean",
      "once-newline" if gmon.render(rows, live=False).endswith("\n") else "once-clean")
PYEOF
}
it "the live frame has no bottom row"; assert_eq "$(frame_check)" "live-clean once-newline"
# 'contains H200' would pass on the undropped name too, so assert the absence.
it "drops the NVIDIA name prefix";   assert_missing "$out" "NVIDIA H200"
it "shows utilisation";              assert_contains "$out" "97%"
it "shows memory used and total";    assert_contains "$out" "120000/143771"
it "shows temperature";              assert_contains "$out" "84°C"
# A fan reading of [N/A] is normal on datacentre cards; it must render as a
# dash rather than crashing the int conversion or printing 'None'.
it "renders an absent fan reading";  assert_contains "$out" "—"
it "never prints a bare None";       assert_missing "$out" "None"

# Datacentre cards report no fan, so on a fleet of them the column is five
# characters of '—' per row. It appears only when something on screen has a
# reading — here one card does.
it "fan shows when one card has it"; assert_contains "$out" "FAN%"
nofan="$(GMON_FAKE_NO_FAN=1 gmon --once)"
it "and vanishes when none do";      assert_missing "$nofan" "FAN%"
it "taking its dashes with it";      assert_missing "$nofan" "—"
it "while the rest still renders";   assert_contains "$nofan" "120000/143771"

# Utilisation and memory do not change colour with their value: a GPU at 97%
# is working, not in trouble, and a number that shifts hue as it climbs reads
# as an alarm. Temperature keeps its colouring, because that one is a warning.
raw="$("$GMON" --once 2>&1)"
it "a loaded GPU is not highlighted"; assert_eq "$(printf %s "$raw" | grep -c $'\033\[38;2;245;224;220m')" "0"
it "but a hot one still is";          assert_eq "$(printf %s "$raw" | grep -cE $'\033\[38;2;(250;179;135|243;139;168)m')" "1"

# Compute processes are correlated to their GPU by UUID, then to a username by
# pid. Both users of the busy card must appear, and only on that card's row.
it "maps processes to users";        assert_contains "$out" "alice, bob"
it "an unused GPU reads idle";       assert_contains "$out" "idle"

# The free-GPU summary is what the tool is for: index 0 has no processes and
# 12 MiB used, so it is grabbable; index 1 is not.
it "counts the free GPU";            assert_contains "$out" "1 GPU free"
it "names host and index";           assert_contains "$out" "alpha:0"
# Consecutive cards collapse to a range: an idle four-GPU host is the common
# case, and spelling every index out is what pushes the list onto its own line.
ranges() {
    python3 - "$GMON" <<'PYEOF'
import importlib.machinery, importlib.util, sys
spec = importlib.util.spec_from_loader(
    "gmon", importlib.machinery.SourceFileLoader("gmon", sys.argv[1]))
gmon = importlib.util.module_from_spec(spec)
sys.modules["gmon"] = gmon
spec.loader.exec_module(gmon)
print(*(gmon.compress_indices(c) for c in
        (["0", "1", "2", "3"], ["0", "2", "3"], ["1"], ["0", "2", "4"], [])))
PYEOF
}
it "runs of cards become ranges";    assert_eq "$(ranges)" "0-3 0,2-3 1 0,2,4 "
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
