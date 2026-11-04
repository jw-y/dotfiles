#!/usr/bin/env python3
"""Network-free checks for downloads, host isolation, and daemon ownership."""
import hashlib
import io
import json
from pathlib import Path
import runpy
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


if __name__ == "__main__":
    unittest.main()
