"""Contract shared by every tool built on the cmd module (the real scripts of src/)."""

import re
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))

from tpfbuild.core import Project  # noqa: E402


def command_tools():
    """Scripts of src/ that use the cmd module."""
    project = Project(REPO)
    tools = {}
    for script in project.load_all():
        result = project.build(script.key)
        if "cmd" in result.modules:
            tools[script.key] = result
    return tools


TOOLS = command_tools()


class ToolContract(unittest.TestCase):
    def run_tool(self, key, *args):
        path = Path(self._tmp) / f"{key}.sh"
        path.write_text(TOOLS[key].text, encoding="utf-8")
        done = subprocess.run(["bash", str(path), *args], capture_output=True, text=True,
                              env={"PATH": "/usr/bin:/bin:" + __import__("os").environ["PATH"],
                                   "HOME": self._tmp, "TERM": "xterm", "PREFIX": "/data/data/com.termux/files/usr"},
                              stdin=subprocess.DEVNULL, timeout=30)
        return done.returncode, done.stdout, done.stderr

    def setUp(self):
        import tempfile
        self._dir = tempfile.TemporaryDirectory(prefix="tpf-tools-")
        self.addCleanup(self._dir.cleanup)
        self._tmp = self._dir.name

    def test_at_least_one_tool_uses_the_command_module(self):
        self.assertTrue(TOOLS)

    def test_every_tool_speaks_the_common_words(self):
        for key in TOOLS:
            with self.subTest(tool=key):
                code, out, _ = self.run_tool(key, "help")
                self.assertEqual(code, 0)
                self.assertIn("Commands:", out)
                self.assertRegex(out, r"(?m)^  help\s")
                self.assertRegex(out, r"(?m)^  version\s")
                self.assertRegex(out, r"(?m)^  status\s", "every tool has a status command")
                self.assertIn("--no-color", out)
                text = TOOLS[key].text
                defines = lambda name: re.search(rf"(?m)^{name}\(\)", text) is not None  # noqa: E731
                if defines("cmd_install") and defines("cmd_uninstall"):
                    self.assertRegex(out, r"(?m)^  reinstall\s")
                else:
                    self.assertNotRegex(out, r"(?m)^  reinstall\s")

    def test_version_and_help_options(self):
        for key, result in TOOLS.items():
            with self.subTest(tool=key):
                expected = f"{result.script.name} {result.script.version}\n"
                self.assertEqual(self.run_tool(key, "version")[1], expected)
                self.assertEqual(self.run_tool(key, "--version")[1], expected)
                self.assertIn("Commands:", self.run_tool(key, "--help")[1])

    def test_unknown_command_and_option_are_usage_errors(self):
        for key in TOOLS:
            with self.subTest(tool=key):
                code, _, err = self.run_tool(key, "no-such-command")
                self.assertEqual(code, 2)
                self.assertIn("Unknown command", err)
                code, _, err = self.run_tool(key, "status", "--no-such-option")
                self.assertEqual(code, 2)
                self.assertIn("Unknown option", err)

    def test_no_message_uses_the_old_markers(self):
        for key, result in TOOLS.items():
            with self.subTest(tool=key):
                for old in ('"[*]', '"[OK]', '"[!]', "[ DENIED ]", "[ WARNING ]"):
                    self.assertNotIn(old, result.text)


if __name__ == "__main__":
    unittest.main()
