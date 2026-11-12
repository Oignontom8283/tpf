"""Tests of the cmd module: the command words and options shared by every tool."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_lib import LibCase  # noqa: E402

TOOL = r'''
cmd_install()   { echo "install args=[$*] keep=$TPF_KEEP_DATA port=${PORT:-none}"; }
cmd_uninstall() { echo "uninstall args=[$*] keep=$TPF_KEEP_DATA"; }
cmd_status()    { echo "status"; return 3; }
cmd_do_thing()  { echo "do-thing [$*]"; }
add_command install   "Install the tool"
add_command uninstall "Remove the tool"
add_command status    "Show the state"
add_command do-thing  "A command with a dash"
TOOL_OPTIONS_HELP="      --port N     Port to use"
tool_opt() {
    case "$1" in
        --port) need_value "$1" $#; PORT="$2"; TOOL_SHIFT=2 ;;
        --flag) FLAG=1 ;;
        *) return 1 ;;
    esac
}
tool_usage() { echo "EXTRA HELP TEXT"; }
tpf_main "$@"
'''


class CmdTests(LibCase):
    def tool(self, body=TOOL):
        return self.build(body, includes=("cmd",))

    def test_help_lists_commands_options_and_extra_text(self):
        code, out, _ = self.run_plain(self.tool(), "help")
        self.assertEqual(code, 0)
        for word in ("install", "uninstall", "reinstall", "status", "do-thing", "help", "version"):
            self.assertRegex(out, rf"(?m)^  {word}\s")
        self.assertIn("Usage: demo.sh", out)
        self.assertIn("EXTRA HELP TEXT", out)
        self.assertIn("--port N", out)
        self.assertIn("--no-color", out)

    def test_no_command_shows_the_help_and_default_command_can_change(self):
        path = self.tool()
        self.assertIn("Commands:", self.run_plain(path)[1])
        path = self.tool('TOOL_DEFAULT_COMMAND=status\n' + TOOL)
        code, out, _ = self.run_plain(path)
        self.assertEqual((code, out), (3, "status\n"))

    def test_dash_in_a_command_name_and_arguments(self):
        code, out, _ = self.run_plain(self.tool(), "do-thing", "a", "b c")
        self.assertEqual((code, out), (0, "do-thing [a b c]\n"))

    def test_options_work_before_and_after_the_command(self):
        path = self.tool()
        for argv in (["--port", "99", "install", "x"], ["install", "--port", "99", "x"], ["install", "x", "--port", "99"]):
            with self.subTest(argv=argv):
                self.assertIn("install args=[x] keep=0 port=99", self.run_plain(path, *argv)[1])

    def test_common_options_are_understood_everywhere(self):
        path = self.tool()
        self.assertEqual(self.run_plain(path, "--version")[1], "demo 3.1\n")
        self.assertEqual(self.run_plain(path, "version")[1], "demo 3.1\n")
        self.assertIn("Commands:", self.run_plain(path, "-h")[1])
        self.assertIn("Commands:", self.run_plain(path, "install", "--help")[1])

    def test_exit_status_of_the_command_is_kept(self):
        self.assertEqual(self.run_plain(self.tool(), "status")[0], 3)

    def test_unknown_command_and_option_exit_with_two(self):
        path = self.tool()
        code, _, err = self.run_plain(path, "frobnicate")
        self.assertEqual(code, 2)
        self.assertIn("Unknown command: frobnicate", err)
        code, _, err = self.run_plain(path, "install", "--bogus")
        self.assertEqual(code, 2)
        self.assertIn("Unknown option: --bogus", err)
        code, _, err = self.run_plain(path, "--port")
        self.assertEqual(code, 1)
        self.assertIn("needs a value", err)

    def test_double_dash_makes_the_rest_arguments(self):
        code, out, _ = self.run_plain(self.tool(), "install", "--", "--port", "-x")
        self.assertIn("install args=[--port -x]", out)

    def test_reinstall_removes_then_installs_and_flags_the_removal(self):
        code, out, _ = self.run_plain(self.tool(), "reinstall", "arg")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["uninstall args=[arg] keep=1", "install args=[arg] keep=0 port=none"])

    def test_reinstall_stops_when_the_removal_fails(self):
        body = TOOL.replace('cmd_uninstall() { echo "uninstall args=[$*] keep=$TPF_KEEP_DATA"; }',
                            'cmd_uninstall() { echo "removing"; return 1; }')
        code, out, err = self.run_plain(self.tool(body), "reinstall")
        self.assertEqual(code, 1)
        self.assertEqual(out, "removing\n")
        self.assertIn("nothing was installed again", err)

    def test_a_tool_can_define_its_own_reinstall(self):
        body = TOOL + ""
        body = body.replace("tpf_main", 'cmd_reinstall() { echo "custom reinstall"; }\nadd_command reinstall "Custom"\ntpf_main')
        self.assertEqual(self.run_plain(self.tool(body), "reinstall")[1], "custom reinstall\n")
        self.assertEqual(self.run_plain(self.tool(body), "help")[1].count("reinstall"), 1)

    def test_no_reinstall_without_install_and_uninstall(self):
        body = 'cmd_status() { echo ok; }\nadd_command status "State"\ntpf_main "$@"\n'
        path = self.tool(body)
        self.assertNotRegex(self.run_plain(path, "help")[1], r"(?m)^  reinstall")
        code, _, err = self.run_plain(path, "reinstall")
        self.assertEqual(code, 2)

    def test_command_registered_without_a_function(self):
        body = 'add_command ghost "No function"\ntpf_main "$@"\n'
        code, _, err = self.run_plain(self.tool(body), "ghost")
        self.assertEqual(code, 2)
        self.assertIn("cmd_ghost is not defined", err)

    def test_aliases_run_the_command_and_show_in_the_help(self):
        body = TOOL.replace("tpf_main", 'add_alias setup install\nadd_alias add install\ntpf_main')
        path = self.tool(body)
        self.assertIn("install args=[x]", self.run_plain(path, "setup", "x")[1])
        self.assertIn("install args=[]", self.run_plain(path, "add")[1])
        self.assertRegex(self.run_plain(path, "help")[1], r"(?m)^  install\s+Install the tool \(also: setup, add\)$")
        self.assertNotRegex(self.run_plain(path, "help")[1], r"(?m)^  setup\s")

    def test_log_directory_is_created_for_real_commands_only(self):
        path = self.tool()
        self.run_plain(path, "help")
        self.assertFalse((self.root / ".cache" / "tpf" / "demo").exists())
        self.run_plain(path, "install")
        self.assertTrue((self.root / ".cache" / "tpf" / "demo").is_dir())


if __name__ == "__main__":
    unittest.main()
