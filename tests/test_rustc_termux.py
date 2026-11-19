"""Functional tests of the management commands of rustc-termux.sh, in a throw-away HOME."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))

from tpfbuild.core import Project  # noqa: E402

PREFIX = os.environ.get("PREFIX", "")


# The tests never use the compiler of the machine they run on (it may be a rustup proxy that
# needs a real HOME, or the fake rustc of ~/.rustup-fake): they give the script a stub that
# answers what the management commands ask, the same way everywhere.
STUB_RUSTC = """#!{bash}
case "$*" in
    "--version") echo "rustc 1.99.0 (stub)" ;;
    "-vV") printf 'rustc 1.99.0 (stub)\\nbinary: rustc\\nhost: aarch64-linux-android\\nrelease: 1.99.0\\n' ;;
    "--print sysroot") echo "{sysroot}" ;;
    "--print target-list") printf '%s\\n' aarch64-linux-android armv7-linux-androideabi i686-linux-android \\
        x86_64-linux-android wasm32-unknown-unknown thumbv7em-none-eabihf x86_64-unknown-linux-gnu ;;
    *) echo "stub rustc: unexpected arguments: $*" >&2; exit 1 ;;
esac
"""
STUB_CARGO = """#!{bash}
case "$*" in
    "--version") echo "cargo 1.99.0 (stub)" ;;
    *) echo "stub cargo: unexpected arguments: $*" >&2; exit 1 ;;
esac
"""


class ManageCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script_text = Project(REPO).build("rustc-termux").text

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="tpf-rt-")
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name)
        self.base = self.home / ".rustup-fake"
        (self.base / "toolchains" / "linkers").mkdir(parents=True)
        (self.base / "settings").write_text("nightly=0\njobs=2\noom=\n")
        (self.base / "targets").write_text("wasm32-unknown-unknown\n")
        self.conf = self.home / "rust-termux.conf"
        self.conf.write_text("# saved choices\nRT_JOBS=2\nRT_NIGHTLY=0\nRT_PACKS=zig\\ msvc\nRT_OTHER='keep me'\n")
        self.script = self.home / "rustc-termux.sh"
        self.script.write_text(self.script_text)
        stubs = self.home / "stubs"
        stubs.mkdir()
        sysroot = self.home / "sysroot"
        sysroot.mkdir()
        bash = shutil.which("bash")
        self.rustc = stubs / "rustc"
        self.rustc.write_text(STUB_RUSTC.format(bash=bash, sysroot=sysroot))
        self.cargo = stubs / "cargo"
        self.cargo.write_text(STUB_CARGO.format(bash=bash))
        for stub in (self.rustc, self.cargo):
            stub.chmod(0o755)

    def run_rt(self, *args):
        env = {**{k: v for k, v in os.environ.items() if not k.startswith("TPF_")}, "HOME": str(self.home), "TERM": "dumb"}
        env["RUSTUP_FAKE_REAL_RUSTC"] = str(self.rustc)
        env["RUSTUP_FAKE_REAL_CARGO"] = str(self.cargo)
        done = subprocess.run(["bash", str(self.script), *args], capture_output=True, text=True, env=env,
                              stdin=subprocess.DEVNULL, timeout=120)
        return done.returncode, done.stdout, done.stderr

    def settings(self):
        return dict(line.split("=", 1) for line in (self.base / "settings").read_text().splitlines() if "=" in line)


class SettingsCommands(ManageCase):
    def test_without_an_install_the_commands_explain_what_to_do(self):
        os.rename(self.base, self.home / "moved")
        code, _, err = self.run_rt("status")
        self.assertEqual(code, 1)
        self.assertIn("rustc-termux.sh install", err)

    def test_jobs_updates_the_tool_settings_and_the_saved_choices(self):
        code, out, _ = self.run_rt("jobs", "4")
        self.assertEqual(code, 0)
        self.assertIn("limited to 4", out)
        self.assertEqual(self.settings()["jobs"], "4")
        saved = self.conf.read_text()
        self.assertIn("RT_JOBS=4\n", saved)
        # the other saved choices are untouched, quoting included
        self.assertIn("# saved choices\n", saved)
        self.assertIn("RT_PACKS=zig\\ msvc\n", saved)
        self.assertIn("RT_OTHER=keep\\ me\n", saved.replace("'keep me'", "keep\\ me"))
        code, out, _ = self.run_rt("jobs", "off")
        self.assertEqual(code, 0)
        self.assertEqual(self.settings()["jobs"], "")

    def test_jobs_rejects_garbage(self):
        code, _, err = self.run_rt("jobs", "many")
        self.assertEqual(code, 1)
        self.assertIn("usage: jobs", err)
        self.assertEqual(self.settings()["jobs"], "2")

    def test_nightly_switch(self):
        self.assertEqual(self.run_rt("nightly", "on")[0], 0)
        self.assertEqual(self.settings()["nightly"], "1")
        self.assertIn("RT_NIGHTLY=1\n", self.conf.read_text())
        self.assertEqual(self.run_rt("nightly", "off")[0], 0)
        self.assertEqual(self.settings()["nightly"], "0")
        self.assertEqual(self.run_rt("nightly", "maybe")[0], 1)

    def test_status_reports_the_targets_and_packs(self):
        code, out, _ = self.run_rt("status")
        self.assertEqual(code, 0)
        self.assertIn("wasm32-unknown-unknown", out)
        self.assertIn("== Linker packs ==", out)
        self.assertIn("jobs    : 2", out)

    def test_packs_list_and_unknown_pack(self):
        code, out, _ = self.run_rt("packs", "list")
        self.assertEqual(code, 0)
        for pack in ("zig", "msvc", "ndk", "wasm"):
            self.assertRegex(out, rf"(?m)^\s+{pack}\s+-")
        code, _, err = self.run_rt("packs", "add", "nonsense")
        self.assertEqual(code, 1)
        self.assertIn("Unknown pack: nonsense", err)

    def test_log_command(self):
        code, out, _ = self.run_rt("log")
        self.assertEqual(code, 0)
        self.assertIn("log NAME", out)
        code, _, err = self.run_rt("log", "no-such-log")
        self.assertEqual(code, 1)
        self.assertIn("No such log", err)


class LinkerCommands(ManageCase):
    def linker_file(self, target):
        return self.base / "toolchains" / "linkers" / target

    def test_custom_command_linker(self):
        code, out, err = self.run_rt("linker", "add", "armv7-linux-androideabi", "--", "my-cc", "--flag", "a b")
        self.assertEqual(code, 0, out + err)
        text = self.linker_file("armv7-linux-androideabi").read_text()
        self.assertTrue(text.startswith("#!"))
        self.assertIn('my-cc --flag a\\ b "$@"', text)
        self.assertTrue(os.access(self.linker_file("armv7-linux-androideabi"), os.X_OK))
        self.assertIn("armv7-linux-androideabi", (self.base / "targets").read_text().split())

    def test_clang_linker_with_sysroot(self):
        code, out, err = self.run_rt("linker", "add", "aarch64-linux-android", "--clang", "aarch64-linux-android24",
                                     "--sysroot", str(self.home))
        self.assertEqual(code, 0, out + err)
        text = self.linker_file("aarch64-linux-android").read_text()
        self.assertIn("exec clang --target=aarch64-linux-android24", text)
        self.assertIn(f"--sysroot={self.home}", text)
        self.assertIn('-fuse-ld=lld "$@"', text)

    def test_list_flags_a_linker_that_points_to_missing_files(self):
        (self.home / "lib").mkdir()  # the sysroot the first linker refers to
        self.run_rt("linker", "add", "aarch64-linux-android", "--clang", "aarch64-linux-android24", "--sysroot", str(self.home))
        code, out, _ = self.run_rt("linker", "list")
        self.assertIn("aarch64-linux-android", out)
        self.assertNotIn("missing", out)
        gone = self.home / "gone"
        self.run_rt("linker", "add", "x86_64-linux-android", "--clang", "x86_64-linux-android24", "--sysroot", str(gone))
        _, out, _ = self.run_rt("linker", "list")
        self.assertRegex(out, r"x86_64-linux-android: missing: .*gone")

    def test_remove_and_errors(self):
        self.run_rt("linker", "add", "armv7-linux-androideabi", "--", "my-cc")
        self.assertEqual(self.run_rt("linker", "remove", "armv7-linux-androideabi")[0], 0)
        self.assertFalse(self.linker_file("armv7-linux-androideabi").exists())
        code, _, err = self.run_rt("linker", "remove", "armv7-linux-androideabi")
        self.assertEqual(code, 1)
        self.assertIn("No linker", err)
        code, _, err = self.run_rt("linker", "add", "not-a-real-target", "--", "cc")
        self.assertEqual(code, 1)
        self.assertIn("unknown target", err)
        code, _, err = self.run_rt("linker", "add", "armv7-linux-androideabi")
        self.assertEqual(code, 1)
        self.assertIn("choose how to link", err)

    @unittest.skipUnless(PREFIX and Path(PREFIX, "arm-linux-androideabi").is_dir(), "no NDK sysroot (ndk-multilib)")
    def test_ndk_linker_adds_the_compiler_builtins(self):
        code, out, err = self.run_rt("linker", "add", "armv7-linux-androideabi", "--ndk")
        self.assertEqual(code, 0, out + err)
        text = self.linker_file("armv7-linux-androideabi").read_text()
        self.assertIn("--target=armv7a-linux-androideabi24", text)
        self.assertIn("libclang_rt.builtins-arm-android.a", text)  # needed: rustc links with -nodefaultlibs


if __name__ == "__main__":
    unittest.main()
