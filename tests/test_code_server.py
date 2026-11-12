"""Functional tests of code-server.sh (start/stop/status/...) with a fake code-server.

SAFETY: the script finds the server by a process-name pattern. These tests give
it a pattern (TPF_CS_PROC_PATTERN) that only matches the fake server started
here, so a real code-server running on the same device can never be seen by the
script, and therefore never be stopped.
"""

import os
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))

from tpfbuild.core import Project  # noqa: E402

FAKE_ENTRY = r'''
import http.server, re, sys
args = sys.argv[1:]
config = args[args.index("--config") + 1]
bind = re.search(r"^bind-addr: (.*)$", open(config).read(), re.M).group(1)
host, port = bind.rsplit(":", 1)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer((host, int(port)), H).serve_forever()
'''


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class CodeServerCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script_text = Project(REPO).build("code-server").text

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="tpf-cs-")
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        self.port = free_port()
        bindir = self.home / "bin"
        entry_dir = self.home / "fake" / "code-server" / "out" / "node"
        bindir.mkdir()
        entry_dir.mkdir(parents=True)
        (entry_dir / "entry").write_text(FAKE_ENTRY)
        launcher = bindir / "code-server"
        launcher.write_text(f'#!/usr/bin/env bash\nexec python3 "{entry_dir / "entry"}" "$@"\n')
        launcher.chmod(0o755)
        self.fake_bin = str(launcher)
        # start/stop call these; the real ones would change the device's wake lock.
        for name in ("termux-wake-lock", "termux-wake-unlock"):
            (bindir / name).write_text("#!/usr/bin/env bash\nexit 0\n")
            (bindir / name).chmod(0o755)
        self.pattern = re.escape(str(entry_dir / "entry"))
        # The safety net: nothing on the device may match the isolated pattern yet.
        self.assertEqual(subprocess.run(["pgrep", "-f", self.pattern], capture_output=True).stdout, b"")
        self.conf = self.home / "code-server.conf"
        self.write_conf()
        self.script = self.home / "code-server.sh"
        self.script.write_text(self.script_text)
        self.addCleanup(self.stop_quietly)

    def write_conf(self, **overrides):
        # CS_BIN is always the fake: the real code-server can never be started by a test.
        values = {"CS_PORT": self.port, "CS_IP": "127.0.0.1", "CS_AUTH": "none", "CS_START_TIMEOUT": 20,
                  "CS_START_RETRIES": 1, "CS_BIN": self.fake_bin, **overrides}
        self.conf.write_text("".join(f"{k}={shlex.quote(str(v))}\n" for k, v in values.items()))

    def run_cs(self, *args, timeout=60):
        env = {**{k: v for k, v in os.environ.items() if not k.startswith("TPF_")}, "HOME": str(self.home), "CS_CONF": str(self.conf), "TERM": "dumb",
               "TPF_CS_PROC_PATTERN": self.pattern, "PATH": f"{self.home / 'bin'}:{os.environ['PATH']}"}
        env.pop("VSCODE_IPC_HOOK_CLI", None)
        env.pop("TERM_PROGRAM", None)
        done = subprocess.run(["bash", str(self.script), *args], capture_output=True, text=True, env=env,
                              stdin=subprocess.DEVNULL, timeout=timeout)
        return done.returncode, done.stdout, done.stderr

    def stop_quietly(self):
        try:
            self.run_cs("stop", timeout=30)
        except Exception:  # noqa: BLE001
            pass

    def reachable(self):
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=1):
                return True
        except OSError:
            return False


class StartStopTests(CodeServerCase):
    def test_full_cycle(self):
        code, out, err = self.run_cs("status")
        self.assertEqual(code, 3, out + err)
        self.assertIn("not running", out)
        self.assertFalse(self.reachable())

        code, out, err = self.run_cs("start")
        self.assertEqual(code, 0, out + err)
        self.assertIn("code-server started", out)
        self.assertIn(f"http://127.0.0.1:{self.port}/", out)
        self.assertTrue(self.reachable())

        code, out, _ = self.run_cs("status")
        self.assertEqual(code, 0)
        self.assertIn("is running", out)

        code, out, _ = self.run_cs("start")
        self.assertEqual(code, 0)
        self.assertIn("already running", out)

        code, out, _ = self.run_cs("restart")
        self.assertEqual(code, 0, out)
        self.assertTrue(self.reachable())

        code, out, _ = self.run_cs("stop")
        self.assertEqual(code, 0)
        self.assertIn("code-server stopped", out)
        time.sleep(0.5)
        self.assertFalse(self.reachable())
        self.assertEqual(self.run_cs("status")[0], 3)
        self.assertIn("was not running", self.run_cs("stop")[1])

    def test_config_yaml_is_generated_from_the_settings(self):
        self.write_conf(CS_AUTH="password", CS_PASSWORD='p"w\\d')
        self.assertEqual(self.run_cs("start")[0], 0)
        yaml = (self.home / ".config" / "code-server" / "config.yaml").read_text()
        self.assertIn(f"bind-addr: 127.0.0.1:{self.port}", yaml)
        self.assertIn("auth: password", yaml)
        self.assertIn(r'password: "p\"w\\d"', yaml)

    def test_a_password_is_generated_and_saved_when_missing(self):
        self.write_conf(CS_AUTH="password", CS_PASSWORD="")
        code, out, _ = self.run_cs("start")
        self.assertEqual(code, 0, out)
        saved = [line for line in self.conf.read_text().splitlines() if line.startswith("CS_PASSWORD=")][-1]
        password = saved.split("=", 1)[1].strip('"')
        self.assertRegex(password, r"^[0-9a-f]{32}$")
        self.assertIn(f"Password : {password}", out)

    def test_port_already_in_use_is_reported(self):
        with socket.socket() as busy:
            busy.bind(("127.0.0.1", self.port))
            busy.listen(1)

            def serve():
                conn, _ = busy.accept()
                conn.recv(1024)
                conn.sendall(b"HTTP/1.0 200 OK\r\n\r\nx")
                conn.close()

            threading.Thread(target=serve, daemon=True).start()
            code, _, err = self.run_cs("start")
        self.assertEqual(code, 1)
        self.assertIn("Another program already answers", err)

    def test_server_that_never_answers_fails_cleanly(self):
        launcher = self.home / "bin" / "code-server"
        launcher.write_text('#!/usr/bin/env bash\necho "starting but never listening"\nexec sleep 60\n')
        self.write_conf(CS_START_TIMEOUT=2, CS_START_RETRIES=2)
        code, out, err = self.run_cs("start", timeout=60)
        self.assertEqual(code, 1)
        self.assertIn("did not start after 2 attempt", err)
        self.assertIn("starting but never listening", out)

    def test_cs_bin_setting_is_used_instead_of_the_path(self):
        # The real code-server may be in the PATH; the setting must win.
        self.write_conf(CS_BIN=self.fake_bin)
        code, out, err = self.run_cs("start")
        self.assertEqual(code, 0, out + err)
        self.assertTrue(self.reachable())


class SettingsTests(CodeServerCase):
    def test_default_settings_file_is_created(self):
        self.conf.unlink()
        code, out, _ = self.run_cs("status")
        self.assertEqual(code, 3)
        self.assertIn("Settings file created", out)
        self.assertIn("CS_PORT=8080", self.conf.read_text())
        self.assertEqual(oct(self.conf.stat().st_mode & 0o777), "0o600")

    def test_invalid_settings_stop_the_command(self):
        for key, value, message in (("CS_PORT", "99999", "CS_PORT must be"), ("CS_PORT", "abc", "CS_PORT must be"),
                                    ("CS_AUTH", "maybe", "CS_AUTH must be"), ("CS_IP", "::1", "CS_IP must be")):
            with self.subTest(key=key, value=value):
                self.write_conf(**{key: value})
                code, _, err = self.run_cs("status")
                self.assertEqual(code, 1)
                self.assertIn(message, err)

    def test_bad_numbers_fall_back_to_defaults_with_a_warning(self):
        self.write_conf(CS_START_TIMEOUT="soon")
        _, out, _ = self.run_cs("status")
        self.assertIn("CS_START_TIMEOUT='soon' is invalid", out)

    def test_log_command(self):
        code, _, err = self.run_cs("log")
        self.assertEqual(code, 1)
        self.assertIn("No log yet", err)
        code, _, err = self.run_cs("log", "abc")
        self.assertEqual(code, 2)
        self.assertIn("positive number", err)


if __name__ == "__main__":
    unittest.main()
