#!/usr/bin/env bash
# Exercise persistent sessions with a fake SSH executable; never contact hosts.
set -eu
python3 - "$(cd "$(dirname "$0")/.." && pwd)/bin/gmon" "$@" <<'PY'
import importlib.machinery
import importlib.util
import ctypes
import os
import re
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
  drop) printf 'NVIDIA A100, GPU-a, 0, 0, 12, 40000, 35\\n---\\n\\n__GMON_FRAME_END__\\n'; exit 0 ;;
esac
exec bash -c "${@: -1}"
''')
        ssh.chmod(0o700)
        self.env = patch.dict(os.environ, {
            'PATH': str(self.root) + os.pathsep + os.environ['PATH'],
            'SESSION_TEST_LOG': str(self.log), 'SESSION_TEST_MODE': '',
            'SESSION_DISK_LOG': str(self.root / 'df.log'), 'SESSION_DISK_FAIL': '',
        })
        self.env.start()
        smi = self.root / 'nvidia-smi'
        smi.write_text("""#!/usr/bin/env bash
case "$*" in
  *--query-gpu=*) echo 'NVIDIA A100, GPU-a, 0, 0, 12, 40000, 35' ;;
  *--query-compute-apps=*) echo 'GPU-a, 4242' ;;
esac
""")
        smi.chmod(0o700)
        ps = self.root / 'ps'
        ps.write_text('#!/usr/bin/env bash\necho 4242 alice\n')
        ps.chmod(0o700)
        df = self.root / 'df'
        df.write_text("""#!/usr/bin/env bash
printf '%s\\n' "$@" > "$SESSION_DISK_LOG"
[ -n "$SESSION_DISK_FAIL" ] && exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/test 2446677333 2006275413 440401920 82%% /home\\n'
""")
        df.chmod(0o700)
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
            if not gpus.gpus:
                return
            frames.append(gpus)
            if len(frames) == 4:
                stop.set()
        gmon.monitor_host('fake-host', [], stop, update)
        self.assertEqual(len(frames), 4)
        self.assertEqual(frames[-1].gpus[0]['users'], ['alice'])
        self.assertEqual(frames[-1].disk_available_kib, 440401920)
        self.assertEqual(len(self.sessions()), 1)

    def test_local_stream_never_uses_ssh(self):
        stop = threading.Event()
        frames = []
        def update(gpus, err):
            if gpus.gpus:
                frames.append(gpus)
                stop.set()
        gmon.monitor_host('local', [], stop, update)
        self.assertEqual(frames[0].gpus[0]['name'], 'A100')
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

    def test_system_metrics_from_linux_counters(self):
        stat = self.root / 'stat'
        mem = self.root / 'meminfo'
        stat.write_text('cpu 10000000001 0 0 10000000001 0 0 0 0 0 0\n')
        mem.write_text('MemTotal: 8388608 kB\nMemAvailable: 2097152 kB\n')
        smi = self.root / 'nvidia-smi'
        script = smi.read_text().replace("case \"$*\" in",
            "printf 'cpu 10000000051 0 0 10000000051 0 0 0 0 0 0\\n' > " + gmon.shlex.quote(str(stat)) + "\ncase \"$*\" in")
        smi.write_text(script)
        cmd = gmon.CMD.replace('/proc/stat', gmon.shlex.quote(str(stat))).replace(
            '/proc/meminfo', gmon.shlex.quote(str(mem)))
        with patch.object(gmon, 'CMD', cmd):
            _, snapshot, err = gmon.query_host('local', [])
        self.assertIsNone(err)
        self.assertEqual(snapshot.cpu, 50.0)
        self.assertEqual(snapshot.mem_used_kib, 6291456)
        self.assertEqual(snapshot.mem_total_kib, 8388608)
        self.assertEqual(snapshot.gpus[0]['users'], ['alice'])

    def test_missing_or_invalid_system_metrics_preserve_gpu_data(self):
        gpu = 'A100,GPU-a,0,0,12,40000,35\n---\nGPU-a,alice\n'
        for system in ('', 'garbage', 'nan,-1,0', '101,500,100'):
            snapshot = gmon.parse_snapshot(gpu + '---system---\n' + system)
            self.assertIsNone(snapshot.cpu)
            self.assertIsNone(snapshot.mem_total_kib)
            self.assertEqual(snapshot.gpus[0]['users'], ['alice'])

    def test_order_and_host_metrics_in_live_and_once_views(self):
        snapshot = gmon.Snapshot([{'name': 'A100', 'idx': '0', 'util': 0,
            'mem_used': 0, 'mem_total': 40000, 'temp': 35,
            'users': []}], 24, 6291456, 8388608)
        def query(host, opts):
            if host == 'zeta':
                __import__('time').sleep(0.02)
            return host, snapshot, None
        with patch.object(gmon, 'query_host', query):
            rows = [(h, snap, err, None) for h, snap, err in gmon.poll(['zeta', 'alpha'], [])]
        self.assertEqual([r[0] for r in rows], ['zeta', 'alpha'])
        for live in (True, False):
            view = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", gmon.render(rows, live=live))
            self.assertLess(view.index('zeta:0'), view.index('alpha:0'))
            self.assertLess(view.index('zeta '), view.index('alpha '))
            self.assertEqual(view.count('CPU  24%   RAM 6.0/8.0 GiB'), 2)

    def test_host_metrics_align_with_different_values_and_missing_data(self):
        rows = [('short', gmon.Snapshot([], 1, 1048576, 8388608, 1048576, 1), None, None),
                ('longer-host', gmon.Snapshot([], 100, 128*1048576, 512*1048576,
                                               420*1048576, 82), None, 100),
                ('unknown', gmon.Snapshot([]), None, None)]
        for live in (True, False):
            view = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", gmon.render(rows, live=live))
            summaries = [line for line in view.splitlines() if 'CPU ' in line]
            self.assertEqual(len(summaries), 3)
            for label in ('CPU ', 'RAM ', 'DISK home '):
                self.assertEqual(len({line.index(label) for line in summaries}), 1)
            self.assertIn('100%', summaries[1])
            self.assertIn('128.0/512.0 GiB', summaries[1])

    def test_disk_path_is_quoted_and_home_resolves_on_host(self):
        home = str(self.root / 'remote home')
        for path, expected in [('~', home), ('~/scratch space', home + '/scratch space'),
                               ('/data/a;$(touch bad)', '/data/a;$(touch bad)'),
                               ('-test', './-test')]:
            with self.subTest(path=path), patch.object(gmon, 'DISK_PATH', path), patch.dict(os.environ, HOME=home):
                _, snapshot, err = gmon.query_host('fake-host', [])
                self.assertIsNone(err)
                self.assertEqual(snapshot.disk_available_kib, 440401920)
                self.assertEqual(snapshot.disk_used_percent, 82)
                self.assertEqual((self.root / 'df.log').read_text().splitlines(), ['-Pk', expected])
        self.assertEqual(gmon.parse_args(['--disk-path', '/scratch']).disk_path, '/scratch')

    def test_disk_failure_does_not_hide_other_metrics(self):
        with patch.dict(os.environ, SESSION_DISK_FAIL='1'):
            _, snapshot, err = gmon.query_host('fake-host', [])
        self.assertIsNone(err)
        self.assertIsNone(snapshot.disk_available_kib)
        self.assertEqual(snapshot.gpus[0]['name'], 'A100')
        view = gmon.render([('alpha', snapshot, None, None)])
        self.assertIn('DISK home ?', view)

    def test_disk_display_and_invalid_data(self):
        snapshot = gmon.Snapshot([], disk_available_kib=440401920, disk_used_percent=82)
        view = gmon.render([('alpha', snapshot, None, None)])
        self.assertIn('DISK home 420.0 GiB free (82% used)', view)
        for data in ('garbage', '-1,50%', '100,101%', '100,NaN'):
            self.assertIsNone(gmon.parse_snapshot('---disk---\n' + data).disk_available_kib)

    def test_allocated_or_active_gpu_without_owner_is_not_idle(self):
        for used, util in [(48941, 0), (12, 95), (None, 0), (12, None)]:
            with self.subTest(used=used, util=util):
                gpu = dict(name='H100', idx='7', util=util, mem_used=used,
                           mem_total=81559, temp=29, users=[])
                self.assertFalse(gmon.is_free(gpu))
                self.assertEqual(gmon.gpu_users_label(gpu), 'unknown')
                view = gmon.render([('keti1', gmon.Snapshot([gpu]), None, None)])
                self.assertIn('unknown', view)
                self.assertNotIn('keti1:7', view)

    def test_unresolved_process_keeps_its_pid(self):
        (self.root / 'ps').write_text('#!/usr/bin/env bash\nexit 0\n')
        _, snapshot, err = gmon.query_host('fake-host', [])
        self.assertIsNone(err)
        self.assertEqual(snapshot.gpus[0]['users'], ['unknown (PID 4242)'])
        self.assertFalse(gmon.is_free(snapshot.gpus[0]))

    def test_graphics_process_owner_in_modern_and_legacy_tables(self):
        smi = self.root / 'nvidia-smi'
        ps = self.root / 'ps'
        ps.write_text('#!/usr/bin/env bash\necho 3225204 minjaeoh\n')
        for process_row in [
            '|    7   N/A  N/A         3225204      G   .../venv/bin/python      48926MiB |',
            '|    7   3225204      G   .../venv/bin/python      48926MiB |',
            '|    7   N/A  N/A         3225204      C+G   python      48926MiB |',
            '|    7   N/A  N/A         3225204      M+C   python      48926MiB |',
        ]:
            smi.write_text("""#!/usr/bin/env bash
case "$*" in
  *--query-gpu=*) echo 'NVIDIA H100, GPU-g, 7, 0, 48941, 81559, 29' ;;
  *--query-compute-apps=*) exit 0 ;;
  *) printf '%s\\n' '| Processes: |' """ + gmon.shlex.quote(process_row) + """ ;;
esac
""")
            _, snapshot, err = gmon.query_host('fake-host', [])
            self.assertIsNone(err)
            self.assertEqual(snapshot.gpus[0]['users'], ['minjaeoh'])
            self.assertFalse(gmon.is_free(snapshot.gpus[0]))

    def test_compute_and_full_table_records_deduplicate_users(self):
        smi = self.root / 'nvidia-smi'
        script = smi.read_text().replace('esac', """  *) printf '%s\\n' '| Processes: |' '| 0 N/A N/A 4242 C python 12MiB |' ;;
esac""")
        smi.write_text(script)
        _, snapshot, err = gmon.query_host('fake-host', [])
        self.assertIsNone(err)
        self.assertEqual(snapshot.gpus[0]['users'], ['alice'])

    def test_stalled_gpu_probes_return_host_metrics_without_reconnecting(self):
        (self.root / 'nvidia-smi').write_text(
            "#!/usr/bin/env bash\nexec python3 -c 'import time; time.sleep(60)'\n")
        stat, mem = self.root / 'stat', self.root / 'meminfo'
        stat.write_text('cpu 100 0 0 100 0 0 0 0 0 0\n')
        mem.write_text('MemTotal: 8388608 kB\nMemAvailable: 2097152 kB\n')
        cmd = gmon.CMD.replace('/proc/stat', gmon.shlex.quote(str(stat))).replace(
            '/proc/meminfo', gmon.shlex.quote(str(mem)))
        stop, frames = threading.Event(), []
        def update(snapshot, err):
            self.assertIsNone(err)
            if not any("timed out" in warning for warning in snapshot.warnings):
                return
            frames.append(snapshot)
            if len(frames) == 2:
                stop.set()
        with patch.object(gmon, 'CMD', cmd), patch.object(gmon, 'GPU_TIMEOUT', 0.3):
            gmon.monitor_host('fake-host', [], stop, update)
        self.assertEqual(len(self.sessions()), 1)
        self.assertEqual(len(frames), 2)
        snapshot = frames[-1]
        self.assertFalse(snapshot.gpu_available)
        self.assertEqual(snapshot.mem_total_kib, 8388608)
        self.assertEqual(snapshot.disk_available_kib, 440401920)
        self.assertIn('GPU collection timed out', snapshot.warnings)
        view = gmon.render([('keti1', snapshot, None, None)])
        self.assertIn('RAM 6.0/8.0 GiB', view)
        self.assertIn('GPU collection timed out', view)
        self.assertNotIn('no GPUs', view)

    def test_owner_timeout_preserves_gpu_data_and_pid(self):
        (self.root / 'ps').write_text(
            "#!/usr/bin/env bash\nexec python3 -c 'import time; time.sleep(60)'\n")
        _, snapshot, err = gmon.query_host('fake-host', [])
        self.assertIsNone(err)
        self.assertEqual(snapshot.gpus[0]['name'], 'A100')
        self.assertEqual(snapshot.gpus[0]['users'], ['unknown (PID 4242)'])
        self.assertIn('Owner lookup timed out', snapshot.warnings)
        self.assertFalse(gmon.is_free(snapshot.gpus[0]))

    def test_disk_timeout_preserves_gpu_data(self):
        (self.root / 'df').write_text(
            "#!/usr/bin/env bash\nexec python3 -c 'import time; time.sleep(60)'\n")
        _, snapshot, err = gmon.query_host('fake-host', [])
        self.assertIsNone(err)
        self.assertEqual(snapshot.gpus[0]['users'], ['alice'])
        self.assertIsNone(snapshot.disk_available_kib)
        self.assertIn('Disk timed out', snapshot.warnings)

    def test_slow_gpu_query_finishes_while_host_metrics_keep_refreshing(self):
        smi = self.root / 'nvidia-smi'
        smi.write_text(smi.read_text().replace('case "$*" in', 'sleep 0.3\ncase "$*" in'))
        stop, frames = threading.Event(), []
        deadline = threading.Timer(5, stop.set)
        def update(snapshot, err):
            self.assertIsNone(err)
            frames.append(snapshot)
            if snapshot.gpus:
                stop.set()
        deadline.start()
        try:
            gmon.monitor_host('fake-host', [], stop, update)
        finally:
            deadline.cancel()
        self.assertEqual(len(self.sessions()), 1)
        self.assertGreater(len(frames), 1)
        self.assertFalse(frames[0].gpus)
        self.assertTrue(all(frame.disk_available_kib for frame in frames))
        self.assertEqual(frames[-1].gpus[0]['users'], ['alice'])

    def test_owner_lookup_batches_all_pids_once(self):
        smi = self.root / 'nvidia-smi'
        smi.write_text(smi.read_text().replace("echo 'GPU-a, 4242'",
            "printf 'GPU-a, 4242\\nGPU-a, 4243\\n'"))
        ps = self.root / 'ps'
        log = self.root / 'ps.log'
        ps.write_text("""#!/usr/bin/env bash
printf '%s\\n' "$*" >> """ + gmon.shlex.quote(str(log)) + """
printf '4242 alice\\n4243 bob\\n'
""")
        _, snapshot, err = gmon.query_host('fake-host', [])
        self.assertIsNone(err)
        self.assertEqual(snapshot.gpus[0]['users'], ['alice', 'bob'])
        self.assertEqual(len(log.read_text().splitlines()), 1)
        self.assertIn('4242,4243', log.read_text())

    def test_last_gpu_snapshot_survives_a_later_probe_timeout(self):
        smi = self.root / 'nvidia-smi'
        marker = self.root / 'slow'
        smi.write_text(smi.read_text().replace('case "$*" in',
            'if [ -f ' + gmon.shlex.quote(str(marker))
            + " ]; then exec python3 -c 'import time; time.sleep(60)'; fi\ncase \"$*\" in"))
        stop, frames = threading.Event(), []
        deadline = threading.Timer(6, stop.set)
        def update(snapshot, err):
            self.assertIsNone(err)
            if snapshot.gpus and not marker.exists():
                marker.touch()
            if snapshot.gpus and snapshot.warnings:
                frames.append(snapshot)
                stop.set()
        deadline.start()
        try:
            with patch.object(gmon, 'GPU_TIMEOUT', 0.8):
                gmon.monitor_host('fake-host', [], stop, update)
        finally:
            deadline.cancel()
        self.assertEqual(len(self.sessions()), 1)
        self.assertTrue(frames)
        self.assertEqual(frames[0].gpus[0]['name'], 'A100')
        self.assertEqual(frames[0].disk_available_kib, 440401920)
        self.assertGreater(frames[0].gpu_age, 0)

    def test_nvml_collector_includes_graphics_processes_and_uses_v2_layout(self):
        namespace = {'__name__': 'nvml_test'}
        exec(gmon.NVML_WORKER, namespace)
        calls = {}
        def callback(name, args):
            calls[name] = calls.get(name, 0) + 1
            if name == 'nvmlDeviceGetCount_v2':
                args[0]._obj.value = 1
            elif name == 'nvmlDeviceGetHandleByIndex_v2':
                args[1]._obj.value = 1234
            elif name == 'nvmlDeviceGetName':
                args[1].value = b'NVIDIA H100'
            elif name == 'nvmlDeviceGetUUID':
                args[1].value = b'GPU-a'
            elif name == 'nvmlDeviceGetMemoryInfo':
                args[1]._obj.total, args[1]._obj.used = 81559*1048576, 48941*1048576
            elif name == 'nvmlDeviceGetUtilizationRates':
                args[1]._obj.gpu = 35
            elif name == 'nvmlDeviceGetTemperature':
                args[2]._obj.value = 42
            elif name.endswith('RunningProcesses_v2'):
                args[1]._obj.value = 1
                args[2][0].pid = 3225204 if 'Graphics' in name else 4242
            return 0
        class Func:
            def __init__(self, name): self.name = name
            def __call__(self, *args): return callback(self.name, args)
        class Library:
            def __getattr__(self, name):
                func = Func(name)
                setattr(self, name, func)
                return func
        with patch.object(ctypes, 'CDLL', return_value=Library()):
            collector = namespace['Nvml']()
        with patch.object(collector, 'owner', side_effect=lambda pid: 'minjaeoh' if pid == 3225204 else 'alice'):
            first = gmon.parse_snapshot(collector.snapshot())
            second = gmon.parse_snapshot(collector.snapshot())
        self.assertEqual(calls['nvmlInit_v2'], 1)
        self.assertEqual(calls['nvmlDeviceGetName'], 1)
        self.assertEqual(first.gpus[0]['users'], ['alice', 'minjaeoh'])
        self.assertEqual(second.gpus[0]['mem_used'], 48941)
        self.assertEqual(ctypes.sizeof(namespace['Process']), 24)

    def test_default_backend_reuses_one_nvml_worker(self):
        starts = self.root / 'nvml-starts'
        worker = ("import sys\nopen(" + repr(str(starts)) + ", 'a').write('start\\n')\n"
                  "for line in sys.stdin:\n"
                  " print('H100,GPU-a,7,0,48941,81559,42\\n---\\nGPU-a,minjaeoh\\n\\n__GMON_FRAME_END__', flush=True)\n")
        stop, frames = threading.Event(), []
        def update(snapshot, err):
            self.assertIsNone(err)
            if snapshot.gpus:
                frames.append(snapshot)
                if len(frames) == 3:
                    stop.set()
        with patch.object(gmon, 'NVML_WORKER', worker):
            gmon.monitor_host('fake-host', [], stop, update)
        self.assertEqual(starts.read_text().splitlines(), ['start'])
        self.assertEqual(len(self.sessions()), 1)
        self.assertEqual(frames[-1].gpus[0]['users'], ['minjaeoh'])

    def test_nvml_unavailable_falls_back_to_smi(self):
        worker = "print('!gmon:nvml:127\\n\\n__GMON_FRAME_END__', flush=True)"
        stop, frames = threading.Event(), []
        def update(snapshot, err):
            self.assertIsNone(err)
            if snapshot.gpus:
                frames.append(snapshot)
                stop.set()
        with patch.object(gmon, 'NVML_WORKER', worker):
            gmon.monitor_host('fake-host', [], stop, update)
        self.assertEqual(frames[0].gpus[0]['users'], ['alice'])
        self.assertEqual(len(self.sessions()), 1)

    def topology_stub(self):
        log = self.root / 'topology.log'
        smi = self.root / 'nvidia-smi'
        smi.write_text(smi.read_text().replace('case "$*" in', """case "$*" in
  'topo -m') echo queried >> """ + gmon.shlex.quote(str(log)) + """
    printf 'GPU0 GPU1 NIC0 CPU Affinity NUMA Affinity\\nGPU0 X NV12 PIX 0-31 0\\nGPU1 NV12 X PXB 0-31 0\\nNIC0 PIX PXB X\\n'
    exit 0 ;;
"""))
        return log

    def test_topology_parser_omits_nics_and_affinity_columns(self):
        matrix = gmon.parse_topology(
            '\x1b[4mGPU0 GPU1 NIC0 CPU Affinity NUMA Affinity\x1b[0m\n'
            'GPU0 X NV12 PIX 0-31 0\nGPU1 NV12 X PXB 0-31 0\nNIC0 PIX PXB X\n')
        self.assertEqual(len(matrix), 3)
        self.assertEqual(matrix[0].split(), ['GPU0', 'GPU1'])
        self.assertEqual(matrix[1].split(), ['GPU0', 'X', 'NV12'])
        self.assertEqual(matrix[2].split(), ['GPU1', 'NV12', 'X'])
        self.assertNotIn('NIC0', ' '.join(matrix))
        self.assertEqual(gmon.parse_topology('GPU0 GPU1\nGPU0 X SYS\n'), [])

    def test_topology_is_cached_once_per_persistent_session(self):
        log = self.topology_stub()
        stop, frames = threading.Event(), []
        def update(snapshot, err):
            self.assertIsNone(err)
            if snapshot.topology:
                frames.append(snapshot)
                if len(frames) == 3:
                    stop.set()
        with patch.object(gmon, 'SHOW_TOPOLOGY', True):
            gmon.monitor_host('fake-host', [], stop, update)
            view = gmon.render([('alpha', frames[-1], None, None)])
        self.assertEqual(log.read_text().splitlines(), ['queried'])
        self.assertEqual(len(self.sessions()), 1)
        self.assertIn('NV12', view)
        self.assertIn('GPU links', view)
        self.assertNotIn('NIC0', view)

    def test_topology_once_keeps_host_metrics_and_gpu_owners(self):
        self.topology_stub()
        with patch.object(gmon, 'SHOW_TOPOLOGY', True):
            _, snapshot, err = gmon.query_host('fake-host', [])
        self.assertIsNone(err)
        self.assertEqual(snapshot.gpus[0]['users'], ['alice'])
        self.assertEqual(snapshot.disk_available_kib, 440401920)
        self.assertEqual(len(snapshot.topology), 3)

    def test_once_uses_nvml_by_default(self):
        (self.root / 'nvidia-smi').write_text('#!/usr/bin/env bash\nexit 1\n')
        worker = ("import sys\nfor line in sys.stdin:\n"
                  " print('H100,GPU-a,7,0,48941,81559,42\\n---\\nGPU-a,minjaeoh\\n\\n__GMON_FRAME_END__', flush=True)\n")
        with patch.object(gmon, 'NVML_WORKER', worker):
            _, snapshot, err = gmon.query_host('fake-host', [])
        self.assertIsNone(err)
        self.assertEqual(snapshot.gpus[0]['users'], ['minjaeoh'])
        self.assertEqual(snapshot.disk_available_kib, 440401920)
        self.assertFalse(snapshot.warnings)

    def test_invalid_intervals_are_rejected(self):
        for value in ('0', '-1', 'nan', 'inf'):
            with self.subTest(value=value), patch('sys.stderr'):
                with self.assertRaises(SystemExit):
                    gmon.parse_args(['--refresh', value])


unittest.main(argv=['gmon persistent sessions', *sys.argv[2:]])
PY
