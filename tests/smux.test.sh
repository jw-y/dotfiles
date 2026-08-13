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
42|gpu|smoke|RUNNING|0:12|1:47:48|2026-08-13T00:15:43|node1
EOF
elif [[ "$cmd" == *"__SMUX_UPLOAD__"* ]]; then
    # The real upload script writes the file, re-hashes it and dies if the
    # digest differs; these two knobs stand in for those failures.
    if [ -n "${SMUX_FAKE_UPLOAD_FAIL:-}" ]; then
        echo 'sha256 mismatch after write' >&2
        exit 1
    fi
    if [ -n "${SMUX_FAKE_UPLOAD_WRONG:-}" ]; then
        echo 'not-an-absolute-path'
        exit 0
    fi
    echo '/remote/smux/verified-smoke.sbatch'
elif [[ "$cmd" == *"sha256sum -- /shared/jobs/gone.sbatch"* ]]; then
    echo "sha256sum: /shared/jobs/gone.sbatch: No such file or directory" >&2
    exit 1
elif [[ "$cmd" == *"sha256sum -- /shared/jobs/existing.sbatch"* ]]; then
    printf '%064d  /shared/jobs/existing.sbatch\n' 0
elif [[ "$cmd" == *"sbatch --parsable"* ]]; then
    echo '4321;cluster'
elif [[ "$cmd" == scontrol* ]]; then
    echo 'JobId=4321 JobState=RUNNING StdOut=/logs/4321.out'
elif [[ "$cmd" == tail* ]]; then
    echo 'hello from slurm'
elif [[ "$cmd" == scancel* ]]; then
    :
elif [[ "$cmd" == *'find "$directory"'* ]]; then
    echo '/home/test/.local/state/smux/scripts/old-job.sbatch'
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
grep -q '"time_left": "1:47:48"' <<<"$jobs" || fail 'jobs time left'
grep -q '"end_time": "2026-08-13T00:15:43"' <<<"$jobs" || fail 'jobs end time'
pass jobs

mkdir -p "$T/project/jobs"
printf '#!/bin/sh\n#SBATCH --job-name=smoke\n' > "$T/project/jobs/smoke.sbatch"
cd "$T/project"
submitted="$($SMUX submit alpha jobs/smoke.sbatch --chdir /work/project)"
[ "$submitted" = 'alpha:4321' ] || fail "submit output: $submitted"
[ "$(file_mode "$SMUX_STATE")" = 600 ] || fail 'private state mode'
grep -q '"host":"alpha"' "$SMUX_STATE" || fail 'state host'
grep -q '"job_id":"4321"' "$SMUX_STATE" || fail 'state job'
grep -q '"submitted_script":"/remote/smux/verified-smoke.sbatch"' "$SMUX_STATE" \
    || fail 'verified remote script not recorded'
grep -Eq '"script_sha256":"[0-9a-f]{64}"' "$SMUX_STATE" \
    || fail 'script checksum not recorded'
grep -q '__SMUX_UPLOAD__' "$SMUX_FAKE_LOG" || fail 'local script was not uploaded'
grep -q 'sbatch --parsable /remote/smux/verified-smoke.sbatch' "$SMUX_FAKE_LOG" \
    || fail 'sbatch did not use uploaded script'
pass submit

before_uploads="$(grep -c '__SMUX_UPLOAD__' "$SMUX_FAKE_LOG")"
remote="$($SMUX submit alpha /shared/jobs/existing.sbatch --remote)"
[ "$remote" = 'alpha:4321' ] || fail "remote submit output: $remote"
after_uploads="$(grep -c '__SMUX_UPLOAD__' "$SMUX_FAKE_LOG")"
[ "$before_uploads" = "$after_uploads" ] || fail '--remote unexpectedly uploaded'
grep -q 'sbatch --parsable /shared/jobs/existing.sbatch' "$SMUX_FAKE_LOG" \
    || fail '--remote path was not submitted'
pass 'explicit remote submit'

logs="$($SMUX logs alpha 4321 --lines 10)"
grep -q 'hello from slurm' <<<"$logs" || fail logs
grep -q 'tail -n 10 /logs/4321.out' "$SMUX_FAKE_LOG" || fail 'logs tail command'
pass logs

if "$SMUX" logs alpha 4321 --lines 0 >/dev/null 2>&1; then
    fail 'non-positive log line count accepted'
fi
pass 'logs validates line count'

cancelled="$($SMUX cancel alpha 4321)"
[ "$cancelled" = 'alpha:4321 CANCELLED' ] || fail "cancel output: $cancelled"
grep -q 'scancel 4321' "$SMUX_FAKE_LOG" || fail 'cancel command'
pass cancel

cleanup="$($SMUX cleanup alpha --older-than-days 7)"
grep -q 'would remove:' <<<"$cleanup" || fail 'cleanup is not dry-run by default'
cleanup_apply="$($SMUX cleanup alpha --older-than-days 7 --apply)"
grep -q 'removed:' <<<"$cleanup_apply" || fail 'cleanup apply output'
pass cleanup

show="$($SMUX show alpha 4321)"
grep -q 'JobState=RUNNING' <<<"$show" || fail show
pass show

"$SMUX" wait alpha 4321 --interval 0.01 >/dev/null || fail wait
pass wait

if "$SMUX" submit private-host "$T/project/jobs/smoke.sbatch" >/dev/null 2>&1; then
    fail 'unknown host accepted'
fi
pass 'unknown host rejected'

# Failure paths for the upload. A submit that half-worked is worse than one
# that refused: the job either runs the script you wrote or does not run.
if "$SMUX" submit alpha jobs/absent.sbatch >/dev/null 2>&1; then
    fail 'missing local script accepted'
fi
# Captured, not piped: this command exits non-zero by design, and under
# 'pipefail' that fails the pipeline however well grep matched.
absent_out="$("$SMUX" submit alpha jobs/absent.sbatch 2>&1 || true)"
grep -q 'local script not found' <<<"$absent_out" \
    || fail "missing local script not named: $absent_out"
pass 'a missing local script is refused'

before_state="$(wc -l < "$SMUX_STATE")"
if SMUX_FAKE_UPLOAD_FAIL=1 "$SMUX" submit alpha jobs/smoke.sbatch >/dev/null 2>&1; then
    fail 'failed upload still submitted'
fi
[ "$(wc -l < "$SMUX_STATE")" = "$before_state" ] || fail 'failed upload recorded a job'
grep -q 'sbatch --parsable jobs/smoke.sbatch' "$SMUX_FAKE_LOG" \
    && fail 'sbatch ran with the un-uploaded path'
pass 'a failed upload submits nothing'

# The digest is the point of uploading rather than trusting a path: a remote
# copy that does not match what was sent must not be submitted.
if SMUX_FAKE_UPLOAD_WRONG=1 "$SMUX" submit alpha jobs/smoke.sbatch >/dev/null 2>&1; then
    fail 'unverified upload accepted'
fi
pass 'an upload that fails verification is refused'

# --remote trusts a path that is already over there, so the only thing
# standing between a typo and a job that runs nothing is the hash.
gone_out="$("$SMUX" submit alpha /shared/jobs/gone.sbatch --remote 2>&1 || true)"
grep -q 'could not hash remote script' <<<"$gone_out" \
    || fail "unhashable remote path not refused: $gone_out"
grep -q 'sbatch --parsable /shared/jobs/gone.sbatch' "$SMUX_FAKE_LOG" \
    && fail 'submitted a remote script it could not verify'
pass 'an unverifiable remote path is refused'

echo 'all smux tests passed'
