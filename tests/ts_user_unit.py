#!/usr/bin/env python3
"""Network-free checks for downloads, host isolation, and daemon ownership."""
import hashlib
import io
import json
from pathlib import Path
import runpy
import socket
import tarfile
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

MODULE = runpy.run_path(str(Path(__file__).resolve().parents[1] / "bin/ts-user"))
Tailscale, Error = MODULE["Tailscale"], MODULE["Error"]
TEST_VERSION = "1.2.4"


class TailscaleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.home_patch = patch("pathlib.Path.home", return_value=self.home)
        self.home_patch.start()
        self.addCleanup(self.home_patch.stop)
        with patch("socket.gethostname", return_value="server1.example.org"):
            self.ts = Tailscale()
        self.ts.root.mkdir(parents=True)
        ready_patch = patch.object(self.ts, "wait_ready")
        ready_patch.start()
        self.addCleanup(ready_patch.stop)

    def archive(self, link=False):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as tar:
            for name in ("tailscale", "tailscaled"):
                member = tarfile.TarInfo("tailscale_" + TEST_VERSION + "_amd64/" + name)
                content = b"binary"
                member.size = len(content)
                if link:
                    member.type = tarfile.SYMTYPE
                    member.linkname = "/tmp/unwanted"
                tar.addfile(member, io.BytesIO(content))
        return stream.getvalue()

    def install_with(self, data, checksum):
        with patch("platform.machine", return_value="x86_64"), patch(
            "urllib.request.urlopen", side_effect=[
                io.BytesIO(json.dumps({"TarballsVersion": TEST_VERSION}).encode()),
                io.BytesIO(data), io.BytesIO(checksum)]
        ) as fetch:
            self.ts.install()
        self.assertEqual(fetch.call_args_list[0].args[0], MODULE["PACKAGE_URL"] + "?mode=json")
        self.assertIn("tailscale_" + TEST_VERSION + "_amd64.tgz", fetch.call_args_list[1].args[0])

    def test_version_override_skips_release_lookup(self):
        data = self.archive()
        checksum = hashlib.sha256(data).hexdigest().encode()
        with patch("platform.machine", return_value="x86_64"), patch(
            "urllib.request.urlopen", side_effect=[io.BytesIO(data), io.BytesIO(checksum)]
        ) as fetch:
            self.ts.install(TEST_VERSION)
        self.assertEqual(fetch.call_count, 2)
        self.assertTrue(fetch.call_args_list[0].args[0].endswith(
            "tailscale_" + TEST_VERSION + "_amd64.tgz"))

    def test_invalid_release_metadata_installs_nothing(self):
        for metadata in ({}, {"TarballsVersion": "../../bad"}, []):
            with self.subTest(metadata=metadata), patch("platform.machine", return_value="x86_64"), patch(
                "urllib.request.urlopen", return_value=io.BytesIO(json.dumps(metadata).encode())
            ) as fetch:
                with self.assertRaisesRegex(Error, "release version"):
                    self.ts.install()
                self.assertEqual(fetch.call_count, 1)
                self.assertFalse(self.ts.bins.exists())

    def test_shared_home_has_separate_state(self):
        with patch("socket.gethostname", return_value="server2.example.org"):
            other = Tailscale()
        self.assertNotEqual(self.ts.root, other.root)
        self.assertNotEqual(self.ts.sock, other.sock)

    def test_bad_checksum_installs_nothing(self):
        with self.assertRaisesRegex(Error, "checksum"):
            self.install_with(self.archive(), b"0" * 64)
        self.assertFalse(self.ts.bins.exists())

    def test_verified_install_and_rerun(self):
        data = self.archive()
        self.install_with(data, hashlib.sha256(data).hexdigest().encode())
        self.assertEqual((self.ts.bins / "tailscaled").read_bytes(), b"binary")
        self.assertEqual((self.ts.bins / "tailscaled").stat().st_mode & 0o777, 0o700)
        with patch("urllib.request.urlopen", side_effect=AssertionError("unexpected download")):
            self.ts.install()

    def test_archive_links_rejected(self):
        data = self.archive(link=True)
        with self.assertRaisesRegex(Error, "regular file"):
            self.install_with(data, hashlib.sha256(data).hexdigest().encode())
        self.assertFalse(self.ts.bins.exists())

    def test_untracked_socket_is_preserved(self):
        self.ts.sock.touch()
        with patch.object(self.ts, "pid", return_value=None), patch("subprocess.Popen") as spawn:
            with self.assertRaisesRegex(Error, "Socket already exists"):
                self.ts.start()
        spawn.assert_not_called()
        self.assertTrue(self.ts.sock.exists())

    def test_stop_refuses_unverified_pid(self):
        with patch.object(self.ts, "pid", side_effect=Error("PID does not identify this daemon")), patch(
            "os.kill"
        ) as kill:
            with self.assertRaisesRegex(Error, "PID"):
                self.ts.stop()
        kill.assert_not_called()

    def test_pid_rejects_reused_process(self):
        self.ts.pidfile.write_text("12345\n")
        with patch("pathlib.Path.read_bytes", return_value=b"unrelated\0"), patch(
            "pathlib.Path.stat", return_value=SimpleNamespace(st_uid=MODULE["os"].getuid())
        ):
            with self.assertRaisesRegex(Error, "PID does not identify"):
                self.ts.pid()

    def test_cli_help_is_forwarded(self):
        with patch("sys.argv", ["ts-user", "cli", "--help"]), patch(
            "platform.system", return_value="Linux"
        ), patch("socket.gethostname", return_value="server1.example.org"), patch(
            "subprocess.run", return_value=SimpleNamespace(returncode=0)
        ) as run:
            self.assertEqual(MODULE["main"](), 0)
        self.assertEqual(run.call_args.args[0][-1], "--help")

    def test_failed_daemon_clears_pid(self):
        with patch.object(self.ts, "pid", return_value=None), patch("subprocess.Popen") as spawn:
            spawn.return_value.pid = 12345
            spawn.return_value.poll.return_value = 1
            with self.assertRaisesRegex(Error, "Daemon exited"):
                self.ts.start()
        self.assertFalse(self.ts.pidfile.exists())

    def test_cli_always_uses_private_socket(self):
        with patch("subprocess.run") as run:
            self.ts.cli("status")
        self.assertEqual(run.call_args.args[0], [str(self.ts.bins / "tailscale"),
                         "--socket=" + str(self.ts.sock), "status"])

    def prepare_binaries(self):
        self.ts.bins.mkdir()
        for name in ("tailscale", "tailscaled"):
            (self.ts.bins / name).touch()

    def test_autostart_requires_lingering_before_writing_unit(self):
        self.prepare_binaries()
        with patch.object(self.ts, "systemctl", return_value=SimpleNamespace(returncode=0)), patch(
            "subprocess.run", return_value=SimpleNamespace(returncode=1, stdout="no\n")
        ), patch.object(self.ts, "stop") as stop:
            with self.assertRaisesRegex(Error, "administrator"):
                self.ts.enable_autostart()
        self.assertFalse(self.ts.unit.exists())
        stop.assert_not_called()

    def test_autostart_unit_is_host_scoped_and_supervises_daemon(self):
        self.prepare_binaries()
        with patch.object(self.ts, "systemctl", return_value=SimpleNamespace(returncode=0)) as ctl, patch(
            "subprocess.run", return_value=SimpleNamespace(returncode=0, stdout="yes\n")
        ), patch.object(self.ts, "stop") as stop:
            self.ts.enable_autostart()
        text = self.ts.unit.read_text()
        self.assertIn("ConditionHost=server1.example.org\n", text)
        self.assertIn("Restart=on-failure\n", text)
        self.assertIn("UMask=0077\n", text)
        self.assertIn("_prepare-service", text)
        self.assertIn(str(self.ts.root / "state"), text)
        self.assertIn("--tun=userspace-networking", text)
        self.assertEqual(ctl.call_args.args, ("enable", "--now", self.ts.unit_name))
        stop.assert_not_called()  # Migration belongs to systemd, not the SSH caller.

    def test_autostart_enables_lingering_when_permitted(self):
        self.prepare_binaries()
        with patch.object(self.ts, "systemctl", return_value=SimpleNamespace(returncode=0)), patch(
            "subprocess.run", side_effect=[SimpleNamespace(returncode=0, stdout="no\n"),
                                          SimpleNamespace(returncode=0),
                                          SimpleNamespace(returncode=0, stdout="yes\n")]
        ) as run:
            self.ts.enable_autostart()
        self.assertEqual(run.call_args_list[1].args[0],
                         ["loginctl", "--no-ask-password", "enable-linger"])

    def test_autostart_requires_user_manager(self):
        self.prepare_binaries()
        with patch.object(self.ts, "systemctl", return_value=SimpleNamespace(returncode=1)):
            with self.assertRaisesRegex(Error, "user manager"):
                self.ts.enable_autostart()
        self.assertFalse(self.ts.unit.exists())

    def test_start_stop_delegate_to_installed_service(self):
        self.ts.unit.parent.mkdir(parents=True)
        self.ts.unit.touch()
        for command in ("start", "stop"):
            with self.subTest(command=command), patch("sys.argv", ["ts-user", command]), patch(
                "platform.system", return_value="Linux"
            ), patch("socket.gethostname", return_value="server1.example.org"), patch(
                "subprocess.run", return_value=SimpleNamespace(returncode=0)
            ) as run, patch.object(Tailscale, "start") as start, patch.object(Tailscale, "stop") as stop:
                self.assertEqual(MODULE["main"](), 0)
                self.assertEqual(run.call_args.args[0], ["systemctl", "--user", command, self.ts.unit_name])
                start.assert_not_called()
                stop.assert_not_called()

    def test_setup_enables_autostart_before_login_without_manual_daemon(self):
        events = []
        with patch("sys.argv", ["ts-user", "setup"]), patch(
            "platform.system", return_value="Linux"
        ), patch("socket.gethostname", return_value="server1.example.org"), patch.object(
            Tailscale, "require_autostart", side_effect=lambda: events.append("preflight")
        ), patch.object(Tailscale, "install", side_effect=lambda version: events.append("install")), patch.object(
            Tailscale, "enable_autostart", side_effect=lambda: events.append("service")
        ), patch.object(Tailscale, "cli", side_effect=lambda *a: (
            events.append("login") or SimpleNamespace(returncode=0)
        )), patch.object(Tailscale, "start") as manual:
            self.assertEqual(MODULE["main"](), 0)
        self.assertEqual(events, ["preflight", "install", "service", "login"])
        manual.assert_not_called()

    def test_setup_stops_before_install_if_autostart_unavailable(self):
        with patch("sys.argv", ["ts-user", "setup"]), patch(
            "platform.system", return_value="Linux"
        ), patch("socket.gethostname", return_value="server1.example.org"), patch.object(
            Tailscale, "require_autostart", side_effect=Error("administrator needed")
        ), patch.object(Tailscale, "install") as install, patch.object(
            Tailscale, "enable_autostart"
        ) as enable, patch.object(Tailscale, "cli") as cli:
            with self.assertRaisesRegex(Error, "administrator"):
                MODULE["main"]()
        install.assert_not_called()
        enable.assert_not_called()
        cli.assert_not_called()

    def test_wait_ready_accepts_daemon_needing_login(self):
        self.ts.sock.touch()
        with patch.object(self.ts, "cli", return_value=SimpleNamespace(
            returncode=1, stdout='{"BackendState": "NeedsLogin"}'
        )):
            Tailscale.wait_ready(self.ts)

    def test_wait_ready_reports_service_failure(self):
        with patch("time.sleep"):
            with self.assertRaisesRegex(Error, "Service is not ready"):
                Tailscale.wait_ready(self.ts)

    def test_disable_preserves_credentials(self):
        self.ts.unit.parent.mkdir(parents=True)
        self.ts.unit.write_text("# Managed by ts-user enable-autostart\n")
        state = self.ts.root / "state"
        state.write_text("credentials")
        with patch.object(self.ts, "systemctl", return_value=SimpleNamespace(returncode=0)) as ctl:
            self.ts.disable_autostart()
        self.assertEqual(ctl.call_args_list[0].args, ("disable", "--now", self.ts.unit_name))
        self.assertFalse(self.ts.unit.exists())
        self.assertEqual(state.read_text(), "credentials")

    def test_stale_socket_after_crash_is_removed(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.bind(str(self.ts.sock))
        self.ts.clear_stale_socket()
        self.assertFalse(self.ts.sock.exists())

    def test_untracked_live_daemon_socket_is_preserved(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.bind(str(self.ts.sock))
            sock.listen(1)
            with self.assertRaisesRegex(Error, "Socket already exists"):
                self.ts.clear_stale_socket()
        self.assertTrue(self.ts.sock.exists())


if __name__ == "__main__":
    unittest.main()
