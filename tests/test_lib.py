"""Tests of the shared shell modules (src/lib), run through real built scripts."""

import contextlib
import io
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "tools"))

from tpfbuild.core import Project, validate  # noqa: E402

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
HAS_SHELLCHECK = shutil.which("shellcheck") is not None


def strip(text):
    return ANSI.sub("", text)


class LibCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="tpf-lib-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        shutil.copytree(REPO / "src" / "lib", self.root / "src" / "lib")

    def build(self, body, includes=("core", "args", "log"), version="3.1"):
        directory = self.root / "src" / "demo"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "tpf.toml").write_text(
            f'version = "{version}"\ndescription = "demo"\nshellcheck = "off"\n', encoding="utf-8")
        lines = "".join(f"# tpf:include {name}\n" for name in includes)
        (directory / "main.sh").write_text("#!/usr/bin/env bash\nset -uo pipefail\n" + lines + body, encoding="utf-8")
        result = Project(self.root).build("demo")
        path = self.root / "demo.sh"
        path.write_text(result.text, encoding="utf-8")
        return path

    def run_plain(self, path, *args, env=None, stdin=None):
        """Run with pipes (no terminal): output is not a TTY."""
        full = {**{k: v for k, v in os.environ.items() if not k.startswith("TPF_")}, "HOME": str(self.root), "TERM": "xterm"}
        full.pop("NO_COLOR", None)
        full.update(env or {})
        done = subprocess.run(["bash", str(path), *args], capture_output=True, text=True,
                              env=full, input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL,
                              timeout=30)
        return done.returncode, done.stdout, done.stderr

    def run_pty(self, path, *args, keys=b"", env=None, timeout=20, interrupt_after=None):
        """Run under a pseudo-terminal; returns (status, output)."""
        full = {**{k: v for k, v in os.environ.items() if not k.startswith("TPF_")}, "HOME": str(self.root), "TERM": "xterm"}
        full.pop("NO_COLOR", None)
        full.update(env or {})
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", str(path), *args], full)
        if keys:
            os.write(fd, keys)
        out, start, interrupted = b"", time.time(), False
        while time.time() - start < timeout:
            if interrupt_after and not interrupted and time.time() - start > interrupt_after:
                os.killpg(pid, signal.SIGINT)
                interrupted = True
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
        _, status = os.waitpid(pid, 0)
        os.close(fd)
        return os.waitstatus_to_exitcode(status), out.decode("utf-8", "replace")


class StyleTests(LibCase):
    SCRIPT = 'info "i"; ok "o"; warn "w"; err "e"; step "S"; detail "d"\n'

    def test_tags_have_fixed_width_and_text_starts_at_column_eight(self):
        code, out, err = self.run_plain(self.build(self.SCRIPT, includes=("ui",)))
        self.assertEqual(code, 0)
        lines = out.split("\n")
        self.assertEqual(lines[0], "[INFO] i")
        self.assertEqual(lines[1], "[ OK ] o")
        self.assertEqual(lines[2], "[WARN] w")
        self.assertEqual(err, "[ERROR] e\n")  # danger: wider, on stderr
        for line in lines[:3]:
            self.assertEqual(line.index("]") + 1, 6)  # the tag is six columns
            self.assertEqual(line[6], " ")
            self.assertNotEqual(line[7], " ")  # the text starts at column 8
        self.assertIn("=== S ===", out)
        self.assertIn("       d", out)

    def test_no_colour_when_not_a_terminal(self):
        _, out, err = self.run_plain(self.build(self.SCRIPT, includes=("ui",)))
        self.assertEqual(strip(out + err), out + err)

    def test_colour_on_a_terminal_and_no_color_variable(self):
        path = self.build(self.SCRIPT, includes=("ui",))
        _, out = self.run_pty(path)
        self.assertRegex(out, r"\x1b\[1;32m\[ OK \]")
        _, out = self.run_pty(path, env={"NO_COLOR": "1"})
        self.assertNotIn("\x1b[", out)

    def test_ui_colors_switch(self):
        path = self.build('ui_colors on; ok "x"; ui_colors off; ok "y"\n', includes=("ui",))
        _, out, _ = self.run_plain(path)
        first, second = out.strip().split("\n")
        self.assertIn("\x1b[", first)
        self.assertNotIn("\x1b[", second)

    def test_run_log_records_messages_without_colours(self):
        path = self.build('log_init; info "hello"; err "bad"; step "S"\n')
        self.run_plain(path)
        text = (self.root / ".cache" / "tpf" / "demo" / "run.log").read_text()
        self.assertRegex(text, r"INFO\s+hello")
        self.assertRegex(text, r"ERROR\s+bad")
        self.assertNotIn("\x1b", text)

    def test_the_log_directory_is_not_exported_to_child_processes(self):
        # A long-running program started by a tool (a server) must not inherit it.
        path = self.build('log_init; bash -c \'echo "child sees: ${TPF_LOG_DIR:-nothing}"\'\n')
        code, out, _ = self.run_plain(path)
        self.assertEqual(out, "child sees: nothing\n")

    def test_die_exits_with_one_and_shows_the_log_directory(self):
        path = self.build('log_init; die "stop here"; echo not-reached\n')
        code, out, err = self.run_plain(path)
        self.assertEqual(code, 1)
        self.assertNotIn("not-reached", out)
        self.assertIn("[ERROR] stop here", err)
        self.assertIn("Logs:", err)


class TaskTests(LibCase):
    def test_success_without_terminal_prints_start_and_result(self):
        path = self.build('log_init; task "Say hi" echo hi-from-task; echo "rc=$?"\n')
        code, out, _ = self.run_plain(path)
        self.assertEqual(code, 0)
        self.assertIn("[ .. ] Say hi", out)
        self.assertIn("[ OK ] Say hi", out)
        self.assertIn("rc=0", out)
        log = (self.root / ".cache" / "tpf" / "demo" / "Say-hi.log").read_text()
        self.assertEqual(log, "hi-from-task\n")

    def test_failure_returns_the_status_and_shows_the_log_tail(self):
        path = self.build('log_init; task "Break" bash -c "echo oops; echo more >&2; exit 7"; echo "rc=$?"\n')
        code, out, err = self.run_plain(path)
        self.assertIn("rc=7", out)
        self.assertIn("[ERROR] Break (exit 7)", err)
        self.assertIn("oops", err)
        self.assertIn("more", err)
        self.assertIn("Full log:", err)

    def test_task_runs_shell_functions(self):
        path = self.build('work() { echo in-function; }\ntask "Fn" work\n')
        code, out, _ = self.run_plain(path)
        self.assertIn("[ OK ] Fn", out)

    def test_animation_on_a_terminal(self):
        path = self.build('log_init; task "Waiting" sleep 1.2\n')
        code, out = self.run_pty(path)
        self.assertEqual(code, 0)
        frames = {f for f in ("[.   ]", "[..  ]", "[... ]", "[ ...]") if f in out}
        self.assertGreaterEqual(len(frames), 2, out)
        self.assertIn("[ OK ] Waiting", strip(out))
        self.assertLess(out.index("\x1b[?25l"), out.index("\x1b[?25h"))  # cursor hidden, then restored

    def test_ctrl_c_stops_the_task_and_restores_the_cursor(self):
        # The task ignores HUP and INT, so only the library can stop it: closing
        # the terminal or the group-wide Ctrl-C would not.
        pidfile = self.root / "task.pid"
        command = f'trap "" HUP INT; echo $$ > {pidfile}; exec sleep 31.7'
        path = self.build(f"log_init; task 'Long' bash -c '{command}'\n")
        started = time.time()
        code, out = self.run_pty(path, interrupt_after=1.0, timeout=15)
        pid = int(pidfile.read_text())
        self.addCleanup(lambda: os.path.exists(f"/proc/{pid}") and os.kill(pid, signal.SIGKILL))
        self.assertEqual(code, 130, out)
        self.assertLess(time.time() - started, 10)
        self.assertIn("Interrupted (INT)", out)
        self.assertIn("\x1b[?25h", out)  # cursor shown again
        for _ in range(20):
            if not os.path.exists(f"/proc/{pid}"):
                break
            time.sleep(0.1)
        self.assertFalse(os.path.exists(f"/proc/{pid}"), "the task process was left running")


    def test_ctrl_c_stops_the_whole_process_tree(self):
        # A task that starts a child which ignores signals, like apt starting dpkg.
        pidfile = self.root / "child.pid"
        tree = self.root / "tree.sh"
        tree.write_text(
            "trap '' HUP INT\n"
            f"bash -c 'trap \"\" HUP INT; echo $$ > {pidfile}; exec sleep 31.9' &\n"
            "wait\n")
        path = self.build(f'log_init; task "Tree" bash {tree}\n')
        code, out = self.run_pty(path, interrupt_after=1.5, timeout=15)
        pid = int(pidfile.read_text())
        self.addCleanup(lambda: os.path.exists(f"/proc/{pid}") and os.kill(pid, signal.SIGKILL))
        self.assertEqual(code, 130, out)
        for _ in range(20):
            if not os.path.exists(f"/proc/{pid}"):
                break
            time.sleep(0.1)
        self.assertFalse(os.path.exists(f"/proc/{pid}"), "a descendant of the task was left running")

    def test_spin_run_prints_nothing_but_the_marker(self):
        path = self.build('spin_run "Quiet" "$HOME/q.log" bash -c "echo hidden; exit 3"; echo "rc=$?"\n', includes=("core",))
        code, out, err = self.run_plain(path)
        self.assertIn("rc=3", out)
        self.assertIn("[ .. ] Quiet", out)
        self.assertNotIn("OK", out)
        self.assertNotIn("hidden", out + err)
        self.assertEqual((self.root / "q.log").read_text(), "hidden\n")
        _, out = self.run_pty(self.build('spin_run "Quiet" "$HOME/q2.log" sleep 0.8; echo "rc=$?"\n', includes=("core",)))
        self.assertIn("rc=0", out)
        self.assertNotIn("[ OK ]", out)
        self.assertEqual(strip(out).strip().split("\r")[-1].strip(), "rc=0")


class QuestionTests(LibCase):
    def test_assume_answers_without_asking(self):
        path = self.build('std_opt "$@"; ask_yes_no "Go?" no && echo YES || echo NO\n', includes=("core", "args"))
        for flag, expected in (("--yes", "YES"), ("--no", "NO")):
            code, out, _ = self.run_plain(path, flag)
            self.assertIn(expected, out)
            self.assertIn("[ ?? ] Go?", out)
            self.assertIn("[auto:", out)

    def test_no_terminal_uses_the_default_with_a_warning(self):
        path = self.build('ask_yes_no "Go?" yes && echo YES || echo NO\n', includes=("core",))
        env_less = subprocess.run(["setsid", "bash", str(path)], capture_output=True, text=True,
                                  stdin=subprocess.DEVNULL, env={**{k: v for k, v in os.environ.items() if not k.startswith("TPF_")}, "HOME": str(self.root)})
        self.assertIn("YES", env_less.stdout)
        self.assertIn("default answer", env_less.stdout)

    def test_interactive_answers(self):
        path = self.build('ask_yes_no "Go?" yes && echo YES || echo NO\n', includes=("core",))
        for keys, expected in ((b"n\n", "NO"), (b"y\n", "YES"), (b"\n", "YES"), (b"oui\n", "YES"), (b"non\n", "NO")):
            with self.subTest(keys=keys):
                _, out = self.run_pty(path, keys=keys)
                self.assertIn(expected, strip(out).split("[Y/n]")[-1])
        path = self.build('ask_yes_no "Go?" no && echo YES || echo NO\n', includes=("core",))
        _, out = self.run_pty(path, keys=b"\n")
        self.assertIn("[y/N]", out)
        self.assertIn("NO", out.split("[y/N]")[-1])

    def test_ask_input_and_choice(self):
        body = ('ask_input "Name?" "bob"; echo "name=$ANSWER"\n'
                'ask_choice "Pick" b a b c; echo "pick=$ANSWER"\n')
        path = self.build(body, includes=("core",))
        _, out = self.run_pty(path, keys=b"alice\n3\n")
        self.assertIn("name=alice", out)
        self.assertIn("pick=c", out)
        _, out = self.run_pty(path, keys=b"\n\n")
        self.assertIn("name=bob", out)
        self.assertIn("pick=b", out)
        _, out, _ = self.run_plain(path, env={})
        self.assertIn("name=bob", out)
        self.assertIn("pick=b", out)


class ArgsAndCoreTests(LibCase):
    def test_common_options(self):
        body = ('usage() { echo "USAGE-TEXT"; std_usage; }\n'
                'while [ $# -gt 0 ]; do case "$1" in\n'
                '  --mine) MINE=1 ;;\n'
                '  *) std_opt "$@" || die "Unknown option: $1"; shift "$STD_SHIFT"; continue ;;\n'
                'esac; shift; done\n'
                'echo "mine=${MINE:-0} assume=$TPF_ASSUME logdir=${TPF_LOG_DIR:-}"\n')
        path = self.build(body)
        self.assertEqual(self.run_plain(path, "--version")[1], "demo 3.1\n")
        self.assertEqual(self.run_plain(path, "-V")[1], "demo 3.1\n")
        out = self.run_plain(path, "--help")[1]
        self.assertIn("USAGE-TEXT", out)
        self.assertIn("--no-color", out)
        self.assertIn("mine=1 assume=yes logdir=/x/y", self.run_plain(path, "--mine", "-y", "--log-dir", "/x/y")[1])
        self.assertIn("assume=no logdir=/z", self.run_plain(path, "--no", "--log-dir=/z")[1])
        code, _, err = self.run_plain(path, "--bogus")
        self.assertEqual(code, 1)
        self.assertIn("Unknown option: --bogus", err)
        code, _, err = self.run_plain(path, "--log-dir")
        self.assertEqual(code, 1)
        self.assertIn("needs a value", err)

    def test_no_color_option(self):
        path = self.build('std_opt "$@"; ok "x"\n')
        _, out = self.run_pty(path, "--no-color")
        self.assertNotIn("\x1b[", out)

    def test_validators(self):
        body = ('is_uint 12 && echo u1; is_uint "" || echo u2; is_uint 1a || echo u3\n'
                'is_port 8080 && echo p1; is_port 0 || echo p2; is_port 70000 || echo p3\n'
                'have bash && echo h1; have no-such-command-xyz || echo h2\n')
        out = self.run_plain(self.build(body, includes=("core",)))[1]
        self.assertEqual(out.split(), ["u1", "u2", "u3", "p1", "p2", "p3", "h1", "h2"])

    def test_on_exit_runs_in_reverse_order_even_after_die(self):
        body = 'on_exit "echo first"; on_exit "echo second"; die "boom"\n'
        code, out, _ = self.run_plain(self.build(body, includes=("core",)))
        self.assertEqual(code, 1)
        self.assertEqual(out.split(), ["second", "first"])

    def test_on_exit_keeps_the_exit_status(self):
        code, out, _ = self.run_plain(self.build('on_exit "echo bye"; exit 5\n', includes=("core",)))
        self.assertEqual((code, out), (5, "bye\n"))

    def test_require_termux_refuses_other_environments(self):
        path = self.build("require_termux; echo fine\n", includes=("core",))
        code, _, err = self.run_plain(path, env={"PREFIX": "/usr"})
        self.assertEqual(code, 1)
        self.assertIn("inside Termux", err)
        code, out, _ = self.run_plain(path, env={"PREFIX": "/data/data/com.termux/files/usr"})
        self.assertEqual((code, out), (0, "fine\n"))


class LintTests(LibCase):
    @unittest.skipUnless(HAS_SHELLCHECK, "shellcheck not installed")
    def test_every_module_passes_shellcheck_at_warning_level(self):
        names = sorted(p.stem for p in (REPO / "src" / "lib").glob("*.sh"))
        directory = self.root / "src" / "demo"
        directory.mkdir(parents=True)
        (directory / "tpf.toml").write_text('version = "1"\ndescription = "all"\nshellcheck = "warning"\n')
        (directory / "main.sh").write_text(
            "#!/usr/bin/env bash\n" + "".join(f"# tpf:include {n}\n" for n in names) + "true\n")
        result = Project(self.root).build("demo")
        validation = validate(result)
        self.assertTrue(validation.ok, "\n".join(validation.errors))

    @unittest.skipUnless(HAS_SHELLCHECK, "shellcheck not installed")
    def test_scaffold_of_tpf_new_builds_and_passes(self):
        from tpfbuild import cli
        project_root = self.root
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["--root", str(project_root), "new", "fresh", "-d", "fresh one"]), 0)
            self.assertEqual(cli.main(["--root", str(project_root), "build", "fresh"]), 0)
        built = project_root / "dist" / "fresh.sh"
        done = subprocess.run(["bash", str(built), "--version"], capture_output=True, text=True)
        self.assertEqual(done.stdout, "fresh 0.1\n")
        done = subprocess.run(["bash", str(built), "--help"], capture_output=True, text=True)
        self.assertIn("Usage: fresh", done.stdout)


if __name__ == "__main__":
    unittest.main()
