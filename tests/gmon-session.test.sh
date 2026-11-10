#!/usr/bin/env bash
# Exercise persistent sessions with a fake SSH executable; never contact hosts.
set -eu
python3 - "$(cd "$(dirname "$0")/.." && pwd)/bin/gmon" <<'PY'
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_loader('gmon', importlib.machinery.SourceFileLoader('gmon', sys.argv[1]))
gmon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gmon)


class Sessions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.log = self.root / 'ssh.log'
        ssh = self.root / 'ssh'
        ssh.write_text('''#!/usr/bin/env bash
printf 'session\\n' >> "$SESSION_TEST_LOG"
case "${SESSION_TEST_MODE:-}" in
  fail) echo 'test connection refused' >&2; exit 255 ;;
  hang) exec python3 -c 'import time; time.sleep(60)' ;;
  drop) printf 'NVIDIA A100, GPU-a, 0, 0, 12, 40000, 35, 0\\n---\\n\\n__GMON_FRAME_END__\\n'; exit 0 ;;
esac
exec bash -c "${@: -1}"
''')
        ssh.chmod(0o700)
        self.env = patch.dict(os.environ, {
            'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
            'SESSION_TEST_LOG': str(self.log), 'SESSION_TEST_MODE': '',
        })
        self.env.start()
        smi = self.root / 'nvidia-smi'
        smi.write_text("""#!/usr/bin/env bash
case "$*" in
  *--query-gpu=*) echo 'NVIDIA A100, GPU-a, 0, 0, 12, 40000, 35, 0' ;;
  *--query-compute-apps=*) echo 'GPU-a, 4242' ;;
esac
""")
        smi.chmod(0o700)
        ps = self.root / 'ps'
        ps.write_text('#!/usr/bin/env bash\necho alice\n')
        ps.chmod(0o700)
        self.constants = patch.multiple(gmon, REFRESH_SECONDS=0.01, SSH_TIMEOUT=5)
        self.constants.start()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.env.stop)
        self.addCleanup(self.constants.stop)

    def sessions(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_many_refreshes_use_one_session_and_exit(self):
        stop = threading.Event()
        frames = []
        def update(gpus, err):
            self.assertIsNone(err)
            frames.append(gpus)
            if len(frames) == 4:
                stop.set()
        gmon.monitor_host('fake-host', [], stop, update)
        self.assertEqual(len(frames), 4)
        self.assertEqual(frames[-1][0]['users'], ['alice'])
        self.assertEqual(len(self.sessions()), 1)

    def test_local_stream_never_uses_ssh(self):
        stop = threading.Event()
        frames = []
        def update(gpus, err):
            frames.append(gpus)
            stop.set()
        gmon.monitor_host('local', [], stop, update)
        self.assertEqual(frames[0][0]['name'], 'A100')
        self.assertEqual(self.sessions(), [])

    def test_disconnect_reconnects_then_reuses_session(self):
        os.environ['SESSION_TEST_MODE'] = 'drop'
        class FastStop:
            stopped = False
            waits = []
            def is_set(self): return self.stopped
            def wait(self, delay):
                self.waits.append(delay)
                return self.stopped
        stop = FastStop()
        frames, errors = [], []
        def update(gpus, err):
            if err:
                errors.append(err)
                os.environ['SESSION_TEST_MODE'] = ''
            else:
                frames.append(gpus)
                if len(frames) == 3:
                    stop.stopped = True
        gmon.monitor_host('fake-host', [], stop, update)
        self.assertEqual(len(self.sessions()), 2, errors)
        self.assertEqual(len(errors), 1)
        self.assertIn(5, stop.waits)
        self.assertEqual(len(frames), 3)

    def test_failed_connections_back_off_to_one_minute(self):
        os.environ['SESSION_TEST_MODE'] = 'fail'
        class FastStop:
            waits = []
            def is_set(self): return len(self.waits) == 6
            def wait(self, delay):
                self.waits.append(delay)
                return self.is_set()
        errors = []
        stop = FastStop()
        gmon.monitor_host('fake-host', [], stop, lambda gpus, err: errors.append(err))
        self.assertEqual(stop.waits, [5, 10, 20, 40, 60, 60])
        self.assertEqual(len(self.sessions()), 6)
        self.assertTrue(all('test connection refused' in err for err in errors))

    def test_stalled_session_times_out_and_is_reaped(self):
        os.environ['SESSION_TEST_MODE'] = 'hang'
        stop = threading.Event()
        errors, children = [], []
        popen = subprocess.Popen
        def launch(*args, **kwargs):
            proc = popen(*args, **kwargs)
            children.append(proc)
            return proc
        def update(gpus, err):
            errors.append(err)
            stop.set()
        with patch.object(gmon, 'SSH_TIMEOUT', 0.1), patch.object(gmon.subprocess, 'Popen', launch):
            gmon.monitor_host('fake-host', [], stop, update)
        self.assertIn('timeout', errors[0])
        self.assertTrue(all(proc.poll() is not None for proc in children))

    def test_stop_interrupts_wait_for_a_stalled_session(self):
        os.environ['SESSION_TEST_MODE'] = 'hang'
        stop = threading.Event()
        timer = threading.Timer(0.1, stop.set)
        timer.start()
        try:
            gmon.monitor_host('fake-host', [], stop,
                              lambda gpus, err: self.fail('stopping should not report failure'))
        finally:
            timer.join()
        self.assertEqual(len(self.sessions()), 1)

    def test_invalid_intervals_are_rejected(self):
        for value in ('0', '-1', 'nan', 'inf'):
            with self.subTest(value=value), patch('sys.stderr'):
                with self.assertRaises(SystemExit):
                    gmon.parse_args(['--refresh', value])


unittest.main(argv=['gmon persistent sessions'])
PY
