"""Tests of the pkg module, with stub apt-get / dpkg programs in the PATH."""

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))

from tpfbuild.core import Project  # noqa: E402


class PkgCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="tpf-pkg-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "src").mkdir()
        shutil.copytree(REPO / "src" / "lib", self.root / "src" / "lib")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)

    def run_script(self, body):
        directory = self.root / "src" / "demo"
        directory.mkdir(exist_ok=True)
        (directory / "tpf.toml").write_text('version = "1"\ndescription = "d"\nshellcheck = "off"\n')
        (directory / "main.sh").write_text(
            "#!/usr/bin/env bash\nset -uo pipefail\n# tpf:include pkg\nlog_dir=$HOME/logs; mkdir -p \"$log_dir\"; TPF_LOG_DIR=$log_dir\n" + body)
        script = self.root / "demo.sh"
        script.write_text(Project(self.root).build("demo").text)
        env = {**{k: v for k, v in os.environ.items() if not k.startswith("TPF_")}, "HOME": str(self.root), "PATH": f"{self.bin}:{os.environ['PATH']}", "TERM": "xterm"}
        env.pop("NO_COLOR", None)
        done = subprocess.run(["bash", str(script)], capture_output=True, text=True, env=env,
                              stdin=subprocess.DEVNULL, timeout=30)
        return done.returncode, done.stdout, done.stderr


class PkgTests(PkgCase):
    def test_install_succeeds(self):
        self.stub("apt-get", 'echo "apt-get $*" >> "$HOME/calls"; exit 0')
        code, out, _ = self.run_script("pkg_install clang lld; echo rc=$?\n")
        self.assertIn("rc=0", out)
        self.assertIn("[ OK ] Installing clang lld", out)
        calls = (self.root / "calls").read_text()
        self.assertIn("install clang lld", calls)
        self.assertIn("-y", calls)

    def test_failure_is_repaired_once_and_retried(self):
        self.stub("dpkg", 'echo "dpkg $*" >> "$HOME/calls"; exit 0')
        self.stub("apt-get", (
            'echo "apt-get $*" >> "$HOME/calls"\n'
            'if [ ! -e "$HOME/failed-once" ] && [[ "$*" == *install\\ clang* ]]; then touch "$HOME/failed-once"; exit 100; fi\n'
            "exit 0"))
        code, out, _ = self.run_script("pkg_install clang; echo rc=$?\n")
        self.assertIn("rc=0", out)
        calls = (self.root / "calls").read_text()
        self.assertIn("dpkg --configure -a", calls)
        self.assertEqual(calls.count("install clang"), 2)

    def test_persistent_failure_is_reported(self):
        self.stub("dpkg", "exit 0")
        self.stub("apt-get", 'echo "E: Unable to locate package nope"; exit 100')
        code, out, err = self.run_script("pkg_install nope; echo rc=$?\n")
        self.assertIn("rc=100", out)
        self.assertIn("[ERROR] Installing nope", err)
        self.assertIn("Unable to locate package nope", err)

    def test_apt_install_is_quiet_and_logs(self):
        self.stub("apt-get", 'echo "log line for $*"; exit 0')
        code, out, _ = self.run_script("apt_install deps tar make; echo rc=$?\n")
        self.assertEqual(out, "rc=0\n")
        self.assertIn("install tar make", (self.root / "logs" / "deps.log").read_text())

    def test_pkg_update(self):
        self.stub("apt-get", 'echo "apt-get $*" >> "$HOME/calls"; exit 0')
        code, out, _ = self.run_script("pkg_update\n")
        self.assertIn("[ OK ] Updating the package lists", out)
        self.assertIn("update", (self.root / "calls").read_text())

    def test_dpkg_installed(self):
        self.stub("dpkg-query", 'case "$3" in good) printf "install ok installed";; *) printf "unknown ok not-installed"; exit 1;; esac')
        _, out, _ = self.run_script("dpkg_installed good && echo yes1; dpkg_installed bad || echo no2\n")
        self.assertEqual(out.split(), ["yes1", "no2"])


if __name__ == "__main__":
    unittest.main()
