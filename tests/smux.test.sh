#!/usr/bin/env bash
set -euo pipefail

SMUX="$(cd "$(dirname "$0")/.." && pwd)/bin/smux"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
file_mode() {
    python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"
}

HOME="$T/home"
mkdir -p "$HOME" "$T/fakebin"

cat > "$T/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
host=""
for arg in "$@"; do
    case "$arg" in
        -*) ;;
        BatchMode=*|ConnectTimeout=*|ServerAliveInterval=*|yes|[0-9]*) ;;
        *) host="$arg"; break ;;
    esac
done
cmd="${*: -1}"
printf '%s|%s\n' "$host" "$cmd" >> "${SMUX_FAKE_LOG:?}"
if [[ "$cmd" == *"__SMUX_SCHEDULER__"* ]]; then
    cat <<EOF
__SMUX_SCHEDULER__
slurm 23.11.1
__SMUX_PARTITIONS__
gpu*|up|2:00:00|1|gpu:4
__SMUX_GPUS__
0|NVIDIA A100|0|81920|0|8.0|550.54
1|NVIDIA A100|4096|81920|75|8.0|550.54
__SMUX_GRES_MAP__
0|debug
1|gpu
__SMUX_JOBS__
42|gpu|smoke|RUNNING|0:12|node1
EOF
elif [[ "$cmd" == *"sbatch --parsable"* ]]; then
    echo '4321;cluster'
elif [[ "$cmd" == scontrol* ]]; then
    echo 'JobId=4321 JobState=RUNNING'
elif [[ "$cmd" == squeue* ]]; then
    :
elif [[ "$cmd" == sacct* ]]; then
    echo 'COMPLETED|'
else
    echo "unexpected fake ssh command: $cmd" >&2
    exit 2
fi
SH
chmod +x "$T/fakebin/ssh"

export HOME SMUX_FAKE_LOG="$T/ssh.log"
export PATH="$T/fakebin:/usr/bin:/bin"
export SMUX_HOSTS="$HOME/.config/smux/hosts"
export SMUX_STATE="$HOME/.local/state/smux/jobs.jsonl"

"$SMUX" --help | grep -q 'independent Slurm controllers' || fail help
pass help

"$SMUX" init >/dev/null
[ "$(file_mode "$SMUX_HOSTS")" = 600 ] || fail 'private config mode'
grep -qx local "$SMUX_HOSTS" || fail 'local default'
pass init

printf 'alpha\nbeta\n' > "$SMUX_HOSTS"
chmod 600 "$SMUX_HOSTS"
status="$($SMUX status)"
grep -q 'alpha' <<<"$status" || fail 'status alpha'
grep -q 'beta' <<<"$status" || fail 'status beta'
grep -q '1R/0P' <<<"$status" || fail 'status job count'
pass status

# An ERROR column on every row says nothing when the clusters are healthy,
# which is the usual case; it appears only when a host actually failed.
grep -q 'ERROR' <<<"$status" && fail 'ERROR column on a healthy listing'
pass 'no ERROR column when healthy'

mkdir -p "$T/failbin"
cat > "$T/failbin/ssh" <<'SH'
#!/usr/bin/env bash
echo 'ssh: Could not resolve hostname' >&2
exit 255
SH
chmod +x "$T/failbin/ssh"
down="$(PATH="$T/failbin:/usr/bin:/bin" "$SMUX" status || true)"
grep -q 'ERROR' <<<"$down" || fail 'ERROR column missing when a host failed'
grep -q 'error' <<<"$down" || fail 'failed host not marked'
pass 'ERROR column appears when needed'

# A config of nothing but comments leaves no hosts to probe. It must say so
# rather than reaching the thread pool, which rejects max_workers=0.
printf '# only comments\n' > "$T/empty-hosts"
empty="$(SMUX_HOSTS="$T/empty-hosts" "$SMUX" status 2>&1 || true)"
grep -q 'no hosts configured' <<<"$empty" || fail "empty config: $empty"
pass 'empty config is explained'

gpus="$($SMUX gpus)"
grep -Eq 'alpha +0 +debug +0/81920 MiB +0% +yes' <<<"$gpus" || fail 'gpus idle debug mapping'
grep -Eq 'alpha +1 +gpu +4096/81920 MiB +75% +no' <<<"$gpus" || fail 'gpus busy mapping'
pass gpus

jobs="$($SMUX jobs --json)"
grep -q '"job_id": "42"' <<<"$jobs" || fail 'jobs json'
grep -q '"host": "alpha"' <<<"$jobs" || fail 'jobs host'
pass jobs

submitted="$($SMUX submit alpha jobs/smoke.sbatch --chdir /work/project)"
[ "$submitted" = 'alpha:4321' ] || fail "submit output: $submitted"
[ "$(file_mode "$SMUX_STATE")" = 600 ] || fail 'private state mode'
grep -q '"host":"alpha"' "$SMUX_STATE" || fail 'state host'
grep -q '"job_id":"4321"' "$SMUX_STATE" || fail 'state job'
pass submit

show="$($SMUX show alpha 4321)"
grep -q 'JobState=RUNNING' <<<"$show" || fail show
pass show

"$SMUX" wait alpha 4321 --interval 0.01 >/dev/null || fail wait
pass wait

if "$SMUX" submit private-host jobs/smoke.sbatch >/dev/null 2>&1; then
    fail 'unknown host accepted'
fi
pass 'unknown host rejected'

echo 'all smux tests passed'
