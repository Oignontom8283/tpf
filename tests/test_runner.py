"""Tests of `tpf.py test`: the generic script check and the shell test harness."""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))

from tpfbuild import cli  # noqa: E402


class RunnerCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="tpf-runner-")
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        (self.dir / "src" / "lib").mkdir(parents=True)

    def write(self, rel, text, mode=None):
        path = self.dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        if mode:
            path.chmod(mode)
        return path

    def run_test(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["--root", str(self.dir), "test", *argv])
        return code, out.getvalue(), err.getvalue()


class GenericScript(RunnerCase):
    SCRIPT = '#!/usr/bin/env bash\necho "hello, ${1:-world}"\n[ "${1:-}" != boom ] || exit 3\n'

    def test_any_script_is_checked_and_its_tests_run(self):
        script = self.write("hello.sh", self.SCRIPT)
        self.write("hello.test.sh", 'test_a() { run_script; assert_eq "hello, world" "$OUT"; }\n')
        code, out, _ = self.run_test(str(script))
        self.assertEqual(code, 0, out)
        self.assertIn("lint   ok", out)
        self.assertIn("1 passed, 0 failed", out)

    def test_several_test_files_next_to_the_script_are_found(self):
        script = self.write("tool.sh", self.SCRIPT)
        self.write("tool.test.sh", "test_one() { :; }\n")
        self.write("tool.extra.test.sh", "test_two() { :; }\ntest_three() { :; }\n")
        self.write("other.test.sh", "test_not_mine() { fail 'must not run'; }\n")
        code, out, _ = self.run_test(str(script))
        self.assertEqual(code, 0, out)
        self.assertIn("3 passed", out)

    def test_a_test_file_can_be_given_directly(self):
        self.write("hello.sh", self.SCRIPT)
        test = self.write("hello.test.sh", "test_a() { :; }\n")
        code, out, _ = self.run_test(str(test))
        self.assertEqual(code, 0, out)
        self.assertIn("== hello.sh", out)

    def test_a_script_without_tests_is_only_checked(self):
        script = self.write("lonely.sh", self.SCRIPT)
        code, out, _ = self.run_test(str(script))
        self.assertEqual(code, 0)
        self.assertIn("(no test file next to it)", out)

    def test_a_syntax_error_fails_the_lint(self):
        script = self.write("broken.sh", "#!/usr/bin/env bash\nif then fi (\n")
        code, out, _ = self.run_test(str(script))
        self.assertEqual(code, 1)
        self.assertIn("lint   FAILED", out)
        self.assertIn("bash -n failed", out)

    def test_no_lint_skips_the_check(self):
        script = self.write("broken.sh", "#!/usr/bin/env bash\nif then fi (\n")
        code, out, _ = self.run_test("--no-lint", str(script))
        self.assertEqual(code, 0)
        self.assertNotIn("lint", out)

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck not installed")
    def test_shellcheck_level_is_a_parameter(self):
        script = self.write("quoting.sh", "#!/usr/bin/env bash\necho $(date)\n")   # SC2046: a warning, not an error
        self.assertEqual(self.run_test(str(script))[0], 0)                       # only warnings: fine at "error"
        self.assertEqual(self.run_test("--shellcheck", "warning", str(script))[0], 1)
        self.assertEqual(self.run_test("--shellcheck", "off", str(script))[0], 0)

    def test_smoke_runs_the_script_with_version_and_help(self):
        good = self.write("good.sh", "#!/usr/bin/env bash\necho ok\n")
        self.assertEqual(self.run_test("--smoke", str(good))[0], 0)
        bad = self.write("bad.sh", "#!/usr/bin/env bash\ncase \"$1\" in --help) exit 2 ;; esac\n")
        code, out, _ = self.run_test("--smoke", str(bad))
        self.assertEqual(code, 1)
        self.assertIn("smoke  FAILED", out)

    def test_unknown_target_is_an_error(self):
        code, _, err = self.run_test("no-such-thing")
        self.assertEqual(code, 1)
        self.assertIn("not a tool of src/", err)


class Harness(RunnerCase):
    def run_tests(self, body, *argv, script="#!/usr/bin/env bash\necho \"hello, ${1:-world}\"\n"):
        path = self.write("subject.sh", script)
        self.write("subject.test.sh", body)
        return self.run_test(*argv, str(path))

    def test_pass_fail_and_skip_are_counted_and_the_exit_status_follows(self):
        code, out, _ = self.run_tests(
            'test_ok() { :; }\n'
            'test_bad() { assert_eq a b "mismatch here"; }\n'
            'test_skipped() { skip "no network"; }\n')
        self.assertEqual(code, 1)
        self.assertIn("1 passed, 1 failed, 1 skipped", out)
        self.assertIn("FAILED test_bad", out)
        self.assertIn("mismatch here", out)
        self.assertIn("skip   test_skipped  (no network)", out)

    def test_all_green_returns_zero(self):
        self.assertEqual(self.run_tests("test_a() { :; }\ntest_b() { :; }\n")[0], 0)

    def test_run_script_captures_output_error_and_status(self):
        code, out, _ = self.run_tests(
            'test_x() { run_script Ada; assert_status 0; assert_eq "hello, Ada" "$OUT"; }\n'
            'test_y() { run bash -c "echo out; echo err >&2; exit 4"; assert_status 4; assert_eq out "$OUT"; assert_eq err "$ERR"; }\n')
        self.assertEqual(code, 0, out)

    def test_a_wrong_status_shows_both_streams(self):
        code, out, _ = self.run_tests('test_x() { run bash -c "echo shown; echo oops >&2; exit 2"; assert_status 0; }\n')
        self.assertEqual(code, 1)
        for text in ("exit status is 2, expected 0", "shown", "oops"):
            self.assertIn(text, out)

    def test_each_test_gets_a_fresh_empty_home(self):
        code, out, _ = self.run_tests(
            'test_first() { touch "$HOME/leftover"; echo data > "$HOME/file"; }\n'
            'test_second() { run bash -c "ls -A \\"\\$HOME\\" | wc -l"; assert_eq 0 "$OUT"; }\n')
        self.assertEqual(code, 0, out)

    def test_the_real_home_and_xdg_folders_are_never_used(self):
        os.environ["REAL_HOME_FOR_TEST"] = str(Path.home())
        self.addCleanup(os.environ.pop, "REAL_HOME_FOR_TEST", None)
        decoy = self.dir / "decoy"
        decoy.mkdir()
        with unittest.mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(decoy), "XDG_DATA_HOME": str(decoy),
                                                   "TPF_LOG_DIR": str(decoy), "TPF_ASSUME": "yes",
                                                   "XDG_STATE_HOME": str(decoy), "XDG_RUNTIME_DIR": str(decoy)}):
            code, out, _ = self.run_tests(
                'test_x() {\n'
                '  assert_ne "$HOME" "$REAL_HOME_FOR_TEST"\n'
                '  assert_contains "$XDG_CONFIG_HOME" "$TEST_HOME"\n'
                '  assert_contains "$XDG_DATA_HOME" "$TEST_HOME"\n'
                '  assert_eq "" "${TPF_LOG_DIR:-}${TPF_ASSUME:-}${XDG_STATE_HOME:-}${XDG_RUNTIME_DIR:-}"\n'
                '  mkdir -p "$XDG_CONFIG_HOME/x"; touch "$XDG_CONFIG_HOME/x/y"\n'
                '}\n')
        self.assertEqual(code, 0, out)
        self.assertEqual(list(decoy.iterdir()), [], "a test wrote into the XDG folder of the environment")

    def test_the_harness_alone_also_clears_the_variables_of_this_tool(self):
        # tpf.py removes TPF_* before starting the harness; the harness must not rely on it.
        script = self.write("subject.sh", "#!/usr/bin/env bash\n")
        test = self.write("subject.test.sh", 'test_x() { assert_eq "" "${TPF_ASSUME:-}${TPF_LOG_DIR:-}"; }\n')
        harness = REPO / "tools" / "tpfbuild" / "harness.sh"
        done = subprocess.run(["bash", str(harness), str(test), str(script)], capture_output=True, text=True,
                              env={**os.environ, "TPF_ASSUME": "yes", "TPF_LOG_DIR": "/somewhere"}, stdin=subprocess.DEVNULL)
        self.assertEqual(done.returncode, 0, done.stdout)
        self.assertIn("@@RESULT pass=1 fail=0 skip=0", done.stdout)

    def test_stubs_come_first_in_the_path_and_do_not_leak_to_the_next_test(self):
        code, out, _ = self.run_tests(
            'test_a() { stub date "echo FIXED"; run date; assert_eq FIXED "$OUT"; }\n'
            'test_b() { run date; assert_ne FIXED "$OUT"; }\n'
            'test_c() { stub tool <<\'EOF\'\necho "from stdin: $*"\nEOF\n  run tool 1 2; assert_eq "from stdin: 1 2" "$OUT"; }\n')
        self.assertEqual(code, 0, out)

    def test_setup_and_teardown_wrap_every_test(self):
        code, out, _ = self.run_tests(
            'setup() { echo ready > "$HOME/state"; }\n'
            'teardown() { echo done >> "$TEST_HOME/../trace"; }\n'
            'test_a() { assert_file_contains "$HOME/state" ready; }\n'
            'test_b() { assert_file_contains "$HOME/state" ready; }\n')
        self.assertEqual(code, 0, out)

    def test_a_failing_setup_fails_the_test(self):
        code, out, _ = self.run_tests('setup() { fail "setup broke"; }\ntest_a() { :; }\n')
        self.assertEqual(code, 1)
        self.assertIn("setup broke", out)

    def test_assertions(self):
        body = (
            'test_contains() { assert_contains "hello world" "lo wo"; assert_not_contains "abc" "z"; }\n'
            'test_match() { assert_match "version 1.2.3" "[0-9]+\\.[0-9]+"; }\n'
            'test_files() { echo x > f; assert_file f; assert_no_file nope; assert_file_contains f x; }\n'
            'test_fail_contains() { assert_contains "abc" "z"; }\n'
            'test_fail_match() { assert_match "abc" "^[0-9]+$"; }\n'
            'test_fail_file() { assert_file nope; }\n'
            'test_fail_no_file() { touch f; assert_no_file f; }\n'
            'test_fail_ne() { assert_ne a a; }\n'
            'test_fail_not_contains() { assert_not_contains abc b; }\n')
        code, out, _ = self.run_tests(body)
        self.assertEqual(code, 1)
        self.assertIn("3 passed, 6 failed", out)

    def test_filter_runs_only_matching_tests(self):
        code, out, _ = self.run_tests('test_apple() { :; }\ntest_banana() { fail "must not run"; }\n', "-k", "apple")
        self.assertEqual(code, 0, out)
        self.assertIn("1 passed", out)

    def test_verbose_lists_passing_tests_too(self):
        _, quiet, _ = self.run_tests("test_a() { :; }\n")
        self.assertNotIn("ok     test_a", quiet)
        _, loud, _ = self.run_tests("test_a() { :; }\n", "-v")
        self.assertIn("ok     test_a", loud)

    def test_a_test_file_without_tests_fails(self):
        code, out, _ = self.run_tests("helper() { :; }\n")
        self.assertEqual(code, 1)
        self.assertIn("no test_* function found", out)

    def test_a_test_file_that_cannot_be_loaded_fails(self):
        code, out, err = self.run_tests("if then fi (\n")
        self.assertEqual(code, 1)
        self.assertIn("FAILED", out)

    def test_a_test_that_hangs_is_stopped_by_the_timeout(self):
        code, out, _ = self.run_tests("test_hang() { sleep 30; }\n", "--timeout", "2")
        self.assertEqual(code, 1)
        self.assertIn("did not finish within 2 s", out)

    def test_set_e_in_a_test_does_not_hide_the_failure(self):
        code, out, _ = self.run_tests('test_a() { set -e; false; echo "not reached" >&2; }\n')
        self.assertEqual(code, 1)

    def test_tests_do_not_run_the_script_unless_asked(self):
        marker = self.dir / "marker"
        code, out, _ = self.run_tests("test_a() { :; }\n", script=f"#!/usr/bin/env bash\ntouch {marker}\n")
        self.assertEqual(code, 0, out)
        self.assertFalse(marker.exists())


class ToolTargets(RunnerCase):
    def make_tool(self, tests=True, broken_test=False):
        shutil.copytree(REPO / "src" / "lib", self.dir / "src" / "lib", dirs_exist_ok=True)
        self.write("src/demo/tpf.toml", 'version = "1.2"\ndescription = "demo tool"\nshellcheck = "off"\n')
        self.write("src/demo/main.sh", "#!/usr/bin/env bash\nset -uo pipefail\n# tpf:include core\n# tpf:include cmd\n"
                   "cmd_status() { echo fine; }\nadd_command status \"State\"\ntpf_main \"$@\"\n")
        if tests:
            self.write("src/demo/tests/basic.test.sh",
                       'test_status() { run_script status; assert_status 0; assert_eq fine "$OUT"; }\n'
                       + ('test_broken() { assert_eq 1 2; }\n' if broken_test else ''))

    def test_a_tool_is_built_then_checked_and_tested(self):
        self.make_tool()
        code, out, _ = self.run_test("demo")
        self.assertEqual(code, 0, out)
        self.assertIn("== demo", out)
        self.assertIn("lint   ok", out)
        self.assertIn("1 passed", out)

    def test_without_arguments_every_tool_is_tested(self):
        self.make_tool()
        code, out, _ = self.run_test()
        self.assertEqual(code, 0, out)
        self.assertIn("== demo", out)

    def test_a_failing_tool_test_fails_the_run(self):
        self.make_tool(broken_test=True)
        code, out, _ = self.run_test("demo")
        self.assertEqual(code, 1)
        self.assertIn("FAILED test_broken", out)

    def test_a_test_file_of_a_tool_can_be_given_directly(self):
        self.make_tool()
        code, out, _ = self.run_test(str(self.dir / "src" / "demo" / "tests" / "basic.test.sh"))
        self.assertEqual(code, 0, out)
        self.assertIn("== demo", out)

    def test_smoke_of_a_tool_checks_its_version_answer(self):
        self.make_tool(tests=False)
        code, out, _ = self.run_test("--smoke", "demo")
        self.assertEqual(code, 0, out)
        self.assertIn("smoke  ok", out)

    def test_the_built_script_under_test_is_not_written_into_dist(self):
        self.make_tool()
        self.run_test("demo")
        self.assertFalse((self.dir / "dist").exists())


import unittest.mock  # noqa: E402  (used by Harness.test_the_real_home_and_xdg_folders_are_never_used)

if __name__ == "__main__":
    unittest.main()
