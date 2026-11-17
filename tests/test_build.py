"""Tests of the packager (tools/tpfbuild). Run: python3 -m unittest discover -s tests"""

import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from tpfbuild import __version__, cli, core  # noqa: E402
from tpfbuild.core import Project, TpfError, strip_volatile  # noqa: E402

SHEBANG = "#!/usr/bin/env bash\n"
HAS_SHELLCHECK = shutil.which("shellcheck") is not None


class ProjectCase(unittest.TestCase):
    """A throw-away repository in a temporary directory."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="tpf-test-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        (self.root / "src" / "lib").mkdir(parents=True)

    def put(self, rel, text, binary=False):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if binary:
            path.write_bytes(text)
        else:
            path.write_text(text, encoding="utf-8", newline="")
        return path

    def script(self, key, body, version="1.0", extra="", main_name="main.sh"):
        self.put(f"src/{key}/tpf.toml", f'version = "{version}"\ndescription = "test {key}"\n{extra}')
        self.put(f"src/{key}/{main_name}", SHEBANG + body)

    def project(self):
        return Project(self.root)

    def build_text(self, key):
        return self.project().build(key).text

    def run_script(self, text, *args):
        path = self.root / "run.sh"
        path.write_text(text, encoding="utf-8")
        done = subprocess.run(["bash", str(path), *args], capture_output=True, text=True)
        return done.returncode, done.stdout, done.stderr


class IncludeTests(ProjectCase):
    def test_module_inserted_once_before_its_users(self):
        self.put("src/lib/base.sh", 'base() { echo base; }\n')
        self.put("src/lib/top.sh", "# tpf:include base\ntop() { base; echo top; }\n")
        self.script("demo", "# tpf:include top\n# tpf:include base\ntop\n")
        text = self.build_text("demo")
        self.assertEqual(text.count("base() { echo base; }"), 1)
        self.assertLess(text.index("base() {"), text.index("top() {"))
        code, out, _ = self.run_script(text)
        self.assertEqual((code, out), (0, "base\ntop\n"))

    def test_relative_include(self):
        self.put("src/demo/part.sh", "part() { echo part; }\n")
        self.script("demo", "# tpf:include ./part.sh\npart\n")
        code, out, _ = self.run_script(self.build_text("demo"))
        self.assertEqual((code, out), (0, "part\n"))

    def test_include_from_a_sibling_folder_with_dotdot(self):
        self.put("src/shared/mod.sh", "mod() { echo shared; }\n")
        self.script("demo", "# tpf:include ../shared/mod.sh\nmod\n")
        code, out, _ = self.run_script(self.build_text("demo"))
        self.assertEqual((code, out), (0, "shared\n"))
        self.script("demo", "# tpf:include ../../outside.sh\n")
        with self.assertRaisesRegex(TpfError, "outside src/"):
            self.build_text("demo")

    def test_unknown_module_reports_file_and_line(self):
        self.script("demo", "echo hi\n# tpf:include nope\n")
        with self.assertRaisesRegex(TpfError, r"src/demo/main\.sh:3: unknown module 'nope'"):
            self.build_text("demo")

    def test_typo_in_directive_is_an_error(self):
        self.script("demo", "# tpf:includ ui\n")
        with self.assertRaisesRegex(TpfError, r"unknown directive 'tpf:includ'"):
            self.build_text("demo")

    def test_indented_directive_text_is_left_alone(self):
        self.script("demo", "echo '  # tpf:include nope'\n    # tpf:include nope\n")
        self.assertIn("    # tpf:include nope", self.build_text("demo"))

    def test_include_cycle(self):
        self.put("src/lib/a.sh", "# tpf:include b\n")
        self.put("src/lib/b.sh", "# tpf:include a\n")
        self.script("demo", "# tpf:include a\n")
        with self.assertRaisesRegex(TpfError, "include cycle"):
            self.build_text("demo")

    def test_include_of_the_main_file_is_a_cycle(self):
        self.script("demo", "# tpf:include ./main.sh\n")
        with self.assertRaisesRegex(TpfError, "include cycle"):
            self.build_text("demo")

    def test_path_outside_src_is_refused(self):
        self.put("outside.sh", "echo no\n")
        self.script("demo", "# tpf:include ./../../outside.sh\n")
        with self.assertRaisesRegex(TpfError, "outside src/"):
            self.build_text("demo")

    def test_symlink_escaping_src_is_refused(self):
        self.put("outside.sh", "echo no\n")
        link = self.root / "src" / "demo" / "link.sh"
        self.script("demo", "# tpf:include ./link.sh\n")
        os.symlink(self.root / "outside.sh", link)
        with self.assertRaisesRegex(TpfError, "outside src/"):
            self.build_text("demo")

    def test_lib_module_symlinked_outside_src_is_refused(self):
        self.put("elsewhere.sh", "echo no\n")
        os.symlink(self.root / "elsewhere.sh", self.root / "src" / "lib" / "sneaky.sh")
        self.script("demo", "# tpf:include sneaky\n")
        with self.assertRaisesRegex(TpfError, "outside src/"):
            self.build_text("demo")

    def test_module_with_shebang_and_main_without(self):
        self.put("src/lib/bad.sh", "#!/bin/bash\necho x\n")
        self.script("demo", "# tpf:include bad\n")
        with self.assertRaisesRegex(TpfError, "must not have a #!"):
            self.build_text("demo")
        self.put("src/demo/main.sh", "echo no shebang\n")
        with self.assertRaisesRegex(TpfError, "must start with a #!"):
            self.build_text("demo")


class SourceFileTests(ProjectCase):
    def test_rejects_corrupting_content(self):
        cases = {
            "crlf": SHEBANG + "echo a\r\n",
            "nofinalnewline": SHEBANG + "echo a",
        }
        for label, text in cases.items():
            with self.subTest(label):
                self.put("src/demo/tpf.toml", 'version = "1"\ndescription = "d"\n')
                self.put("src/demo/main.sh", text)
                with self.assertRaises(TpfError):
                    self.build_text("demo")
        self.put("src/demo/main.sh", SHEBANG.encode() + b"echo \0 a\n", binary=True)
        with self.assertRaisesRegex(TpfError, "NUL"):
            self.build_text("demo")
        self.put("src/demo/main.sh", SHEBANG.encode() + b"echo \xff\n", binary=True)
        with self.assertRaisesRegex(TpfError, "UTF-8"):
            self.build_text("demo")

    def test_metadata_validation(self):
        bad = {
            "unknown key": 'version = "1"\ndescription = "d"\nfoo = 1\n',
            "no version": 'description = "d"\n',
            "multiline description": 'version = "1"\ndescription = "a\\nb"\n',
            "bad shellcheck level": 'version = "1"\ndescription = "d"\nshellcheck = "loud"\n',
            "output with slash": 'version = "1"\ndescription = "d"\noutput = "a/b.sh"\n',
            "invalid toml": "version = \n",
        }
        for label, toml in bad.items():
            with self.subTest(label):
                self.put("src/demo/tpf.toml", toml)
                self.put("src/demo/main.sh", SHEBANG + "echo a\n")
                with self.assertRaises(TpfError):
                    self.project().load("demo")

    def test_two_scripts_cannot_share_an_output_file(self):
        self.script("one", "echo 1\n", extra='output = "same.sh"\n')
        self.script("two", "echo 2\n", extra='output = "same.sh"\n')
        with self.assertRaisesRegex(TpfError, "both write dist/same.sh"):
            self.project().load_all()


class EmbedTests(ProjectCase):
    NASTY = (
        "plain line\n"
        "quotes ' \" and $HOME and $(rm -rf /) and `date`\n"
        "back\\slash \\n \\\\ \\$\n"
        "\tleading tab\n"
        "    trailing spaces   \n"
        "\n\n"
        "EOF\n"
        "unicode: éàü 日本 🙂\n"
        "# tpf:include nope\n"
        "last line\n"
    )

    def roundtrip(self, content):
        self.put("src/demo/data.txt", content)
        self.script("demo", "# tpf:embed ./data.txt as data_text\ndata_text\n")
        code, out, err = self.run_script(self.build_text("demo"))
        self.assertEqual(code, 0, err)
        return out

    def test_content_comes_back_byte_for_byte(self):
        self.assertEqual(self.roundtrip(self.NASTY), self.NASTY)

    def test_empty_file(self):
        self.assertEqual(self.roundtrip(""), "")

    def test_delimiter_collision_is_avoided(self):
        content = "a\nTPF_EOF_ABABABABABAB\nb\nTPF_EOF_ABABABABABAB_1\nc\n"
        with mock.patch.object(core, "sha256_hex", return_value="ab" * 32):
            function = core.heredoc_function("f", content)
        self.assertIn("TPF_EOF_ABABABABABAB_2", function)
        path = self.root / "f.sh"
        path.write_text(function + "f\n", encoding="utf-8")
        done = subprocess.run(["bash", str(path)], capture_output=True, text=True)
        self.assertEqual(done.stdout, content)

    def test_embed_validation(self):
        self.put("src/demo/d.txt", "x\n")
        for line, pattern in {
            "# tpf:embed ./d.txt": "usage",
            "# tpf:embed ./d.txt as 9bad": "invalid function name",
            "# tpf:embed ./missing.txt as m": "no such file",
        }.items():
            with self.subTest(line):
                self.script("demo", line + "\n")
                with self.assertRaisesRegex(TpfError, pattern):
                    self.build_text("demo")
        self.script("demo", "# tpf:embed ./d.txt as same\n# tpf:embed ./d.txt as same\n")
        with self.assertRaisesRegex(TpfError, "already defined"):
            self.build_text("demo")

    def test_embed_dist_embeds_the_built_script(self):
        self.put("src/lib/hello.sh", "hello() { echo hello; }\n")
        self.script("inner", "# tpf:include hello\nhello\n")
        self.script("outer", "# tpf:embed-dist inner as inner_script\ninner_script\n")
        with mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "1000"}):  # the header holds the build time
            outer = self.build_text("outer")
            inner = self.build_text("inner")
        code, out, err = self.run_script(outer)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(out, inner)

    def test_embed_dist_tracks_the_inner_sources(self):
        self.put("src/lib/hello.sh", "hello() { echo hello; }\n")
        self.script("inner", "# tpf:include hello\nhello\n")
        self.script("outer", "# tpf:embed-dist inner as inner_script\n")
        before = self.build_text("outer")
        self.put("src/lib/hello.sh", "hello() { echo changed; }\n")
        self.assertNotEqual(before, self.build_text("outer"))

    def test_embed_dist_cycle(self):
        self.script("one", "# tpf:embed-dist two as t\n")
        self.script("two", "# tpf:embed-dist one as o\n")
        with self.assertRaisesRegex(TpfError, "embed-dist cycle"):
            self.build_text("one")


class OutputTests(ProjectCase):
    def test_output_is_deterministic_and_tracks_sources(self):
        self.put("src/lib/m.sh", "m() { :; }\n")
        self.script("demo", "# tpf:include m\nm\n")
        first = self.build_text("demo")
        self.assertEqual(strip_volatile(first), strip_volatile(self.build_text("demo")))
        self.assertIn('TPF_NAME=demo', first)
        self.assertIn("TPF_VERSION=1.0", first)
        self.put("src/lib/m.sh", "m() { echo changed; }\n")
        self.assertNotEqual(strip_volatile(first), strip_volatile(self.build_text("demo")))

    def test_version_comes_from_the_metadata(self):
        self.script("demo", 'echo "$TPF_NAME $TPF_VERSION"\n', version="2.5")
        code, out, _ = self.run_script(self.build_text("demo"))
        self.assertEqual((code, out), (0, "demo 2.5\n"))

    def test_built_script_is_standalone(self):
        self.put("src/lib/m.sh", "m() { echo from-module; }\n")
        self.script("demo", "# tpf:include m\nm\n")
        text = self.build_text("demo")
        shutil.rmtree(self.root / "src")
        code, out, _ = self.run_script(text)
        self.assertEqual((code, out), (0, "from-module\n"))
        self.assertNotIn("# tpf:", text)


class HeaderTests(ProjectCase):
    def header(self, key="demo"):
        return self.build_text(key).split("# shellcheck disable=SC2034")[0]

    def test_header_tells_where_the_script_comes_from_and_how_it_was_built(self):
        self.put("project.toml", 'name = "proj"\ntitle = "Big Project"\nrepository = "https://example.org/p"\nlicense = "MIT"\n')
        self.put("src/lib/m.sh", "m() { :; }\n")
        self.script("demo", "# tpf:include m\nm\n", version="2.5")
        head = self.header()
        for expected in ("#   Project    : proj - Big Project", "#   Repository : https://example.org/p",
                         "#   License    : MIT", "#   Tool       : demo 2.5   (src/demo/)", "#   Modules    : m",
                         f"#   Packager   : tpf.py {__version__}"):
            self.assertIn(expected, head)
        self.assertRegex(head, r"#   Sources    : sha256:[0-9a-f]{16}\n")
        self.assertRegex(head, r"#   Built      : \d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC\n")
        self.assertIn(f"#   Python     : {platform.python_version()} (", head)
        self.assertIn("do not edit", head)

    def test_project_name_defaults_to_the_folder_and_optional_lines_are_left_out(self):
        self.script("demo", "echo x\n")
        head = self.header()
        self.assertIn(f"#   Project    : {self.root.name}\n", head)
        self.assertNotIn("Repository", head)
        self.assertNotIn("License", head)
        self.assertIn("#   Modules    : -\n", head)

    def test_project_toml_is_validated(self):
        for text in ('unknown = "x"\n', 'name = 3\n', "name = \n"):
            with self.subTest(text=text):
                self.put("project.toml", text)
                self.script("demo", "echo x\n")
                with self.assertRaises(TpfError):
                    Project(self.root)

    def test_source_date_epoch_fixes_the_build_date(self):
        self.script("demo", "echo x\n")
        with mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "86400"}):
            self.assertIn("#   Built      : 1970-01-02 00:00:00 UTC\n", self.header())
            first = self.build_text("demo")
            self.assertEqual(first, self.build_text("demo"))  # fully reproducible with a fixed date

    def test_strip_volatile_removes_only_the_lines_that_change(self):
        self.script("demo", "echo x\n")
        with mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "1"}):
            one = self.build_text("demo")
        with mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "999999999"}):
            two = self.build_text("demo")
        self.assertNotEqual(one, two)
        self.assertEqual(strip_volatile(one), strip_volatile(two))
        stripped = strip_volatile(one)
        for gone in ("#   Built", "#   Python", "#   Git"):
            self.assertNotIn(gone, stripped)
        for kept in ("#   Tool", "#   Sources", "#   Packager", "#   Project"):
            self.assertIn(kept, stripped)

    def test_check_and_build_ignore_the_volatile_lines(self):
        self.script("demo", "echo x\n")
        run = CommandTests.run_cli
        with mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "100"}):
            self.assertEqual(run(self, "build")[0], 0)
        target = self.root / "dist" / "demo.sh"
        before = target.read_bytes()
        with mock.patch.dict(os.environ, {"SOURCE_DATE_EPOCH": "200"}):
            self.assertEqual(run(self, "check", "--dist")[0], 0)  # a later date is not "stale"
            code, out, _ = run(self, "build")
            self.assertEqual(code, 0)
            self.assertIn("same", out)
            self.assertEqual(target.read_bytes(), before)  # and nothing was rewritten
            self.put("src/demo/main.sh", SHEBANG + "echo changed\n")
            self.assertIn("STALE", run(self, "check", "--dist")[1])  # a real change still is
            self.assertEqual(run(self, "build")[0], 0)
            self.assertIn("1970-01-01 00:03:20 UTC", target.read_text())  # rewritten with the new date

    def test_no_git_line_outside_a_repository(self):
        self.script("demo", "echo x\n")
        self.assertNotIn("#   Git", self.header())

    @unittest.skipUnless(shutil.which("git"), "git not installed")
    def test_git_line_with_commit_and_branch(self):
        git = lambda *a: subprocess.run(["git", *a], cwd=self.root, check=True, capture_output=True)  # noqa: E731
        self.script("demo", "echo x\n")
        git("init", "-q", "-b", "trunk")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@example.org", "commit", "-q", "-m", "first")
        head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=self.root, capture_output=True, text=True).stdout.strip()
        self.assertIn(f"#   Git        : {head} on trunk\n", self.header())
        self.put("src/demo/main.sh", SHEBANG + "echo edited\n")  # uncommitted changes are not reported
        self.assertIn(f"#   Git        : {head} on trunk\n", self.header())


class CommandTests(ProjectCase):
    def run_cli(self, *argv):
        out, err = [], []
        with mock.patch("sys.stdout.write", side_effect=out.append), \
                mock.patch("sys.stderr.write", side_effect=err.append):
            code = cli.main(["--root", str(self.root), *argv])
        return code, "".join(out), "".join(err)

    def test_build_then_check_dist_then_stale_missing_orphan(self):
        self.script("demo", "echo ok\n")
        self.assertEqual(self.run_cli("build")[0], 0)
        target = self.root / "dist" / "demo.sh"
        self.assertTrue(os.access(target, os.X_OK))
        self.assertEqual(self.run_cli("check", "--dist")[0], 0)
        self.put("src/demo/main.sh", SHEBANG + "echo changed\n")
        code, out, _ = self.run_cli("check", "--dist")
        self.assertEqual(code, 1)
        self.assertIn("STALE", out)
        self.assertEqual(self.run_cli("build")[0], 0)
        target.unlink()
        self.assertIn("MISSING", self.run_cli("check", "--dist")[1])
        self.run_cli("build")
        self.put("dist/orphan.sh", "#!/bin/sh\n")
        code, _, err = self.run_cli("check", "--dist")
        self.assertEqual(code, 1)
        self.assertIn("ORPHAN", err)

    def test_check_alone_needs_no_dist_and_writes_nothing(self):
        # dist/ is not committed: a fresh checkout has none, and check must still work.
        self.script("demo", "echo ok\n")
        code, out, _ = self.run_cli("check")
        self.assertEqual(code, 0)
        self.assertIn("ok       demo", out)
        self.assertFalse((self.root / "dist").exists())
        self.put("dist/orphan.sh", "#!/bin/sh\n")      # leftovers are only reported with --dist
        self.assertEqual(self.run_cli("check")[0], 0)

    def test_check_still_rejects_an_invalid_script_without_dist(self):
        self.script("demo", "if then fi (\n")
        code, _, err = self.run_cli("check")
        self.assertEqual(code, 1)
        self.assertIn("bash -n failed", err)

    def test_build_out_writes_to_another_directory_and_leaves_dist_alone(self):
        self.script("demo", "echo ok\n")
        out = self.root / "release"
        code, text, _ = self.run_cli("build", "--out", str(out))
        self.assertEqual(code, 0)
        self.assertIn(str(out), text)
        self.assertTrue(os.access(out / "demo.sh", os.X_OK))
        self.assertFalse((self.root / "dist").exists())
        code, text, _ = self.run_cli("build", "-o", str(out))
        self.assertIn("same", text)       # an unchanged script is not rewritten there either

    def test_build_out_does_not_write_when_a_script_is_invalid(self):
        self.script("good", "echo ok\n")
        self.script("bad", "if then fi (\n")
        out = self.root / "release"
        code, _, err = self.run_cli("build", "--out", str(out))
        self.assertEqual(code, 1)
        self.assertIn("Nothing was written", err)
        self.assertFalse(out.exists())

    def test_smoke_runs_the_built_script(self):
        self.put("src/lib/cmdlike.sh", 'case "${1:-}" in --version) echo "$TPF_NAME $TPF_VERSION" ;; --help) echo usage ;; esac\n')
        self.script("demo", "# tpf:include cmdlike\n", version="3.2")
        code, out, err = self.run_cli("check", "--smoke")
        self.assertEqual(code, 0, out + err)

    def test_smoke_catches_a_script_that_crashes_when_it_starts(self):
        # Valid syntax, so bash -n and shellcheck are happy: only running it shows the problem.
        self.script("demo", "undefined_function_call\n", extra='shellcheck = "off"\n')
        self.assertEqual(self.run_cli("check")[0], 0)
        code, out, err = self.run_cli("check", "--smoke")
        self.assertEqual(code, 1)
        self.assertIn("CRASHES", out)
        self.assertIn("--version", err)

    def test_smoke_catches_a_wrong_version_answer(self):
        self.script("demo", 'echo "something else"\n')
        code, out, err = self.run_cli("check", "--smoke")
        self.assertEqual(code, 1)
        self.assertIn("unexpected output", err)

    def test_broken_script_never_replaces_a_good_dist_file(self):
        self.script("good", "echo good\n")
        self.script("bad", "echo good\n")
        self.assertEqual(self.run_cli("build")[0], 0)
        before = (self.root / "dist" / "good.sh").read_text()
        self.put("src/good/main.sh", SHEBANG + "echo changed\n")
        self.put("src/bad/main.sh", SHEBANG + "if then fi (\n")
        code, _, err = self.run_cli("build")
        self.assertEqual(code, 1)
        self.assertIn("bash -n failed", err)
        self.assertEqual((self.root / "dist" / "good.sh").read_text(), before)

    @unittest.skipUnless(HAS_SHELLCHECK, "shellcheck not installed")
    def test_shellcheck_errors_fail_the_build_unless_disabled(self):
        self.script("lint", 'echo "unterminated\n')
        self.assertEqual(self.run_cli("build")[0], 1)
        self.script("lint", "[[ a = b ]] && ( echo x\n")
        self.assertEqual(self.run_cli("build")[0], 1)
        self.script("lint", "if [ 1 = 1 ]; then echo $unquoted ; fi\n", extra='shellcheck = "error"\n')
        self.assertEqual(self.run_cli("build")[0], 0)
        self.script("lint", "if [ 1 = 1 ]; then echo $unquoted ; fi\n", extra='shellcheck = "style"\n')
        self.assertEqual(self.run_cli("build")[0], 1)
        self.script("lint", "if [ 1 = 1 ]; then echo $unquoted ; fi\n", extra='shellcheck = "off"\n')
        self.assertEqual(self.run_cli("build")[0], 0)

    def test_dist_false_is_not_published(self):
        self.script("internal", "echo x\n", extra="dist = false\n")
        self.assertEqual(self.run_cli("build")[0], 0)
        self.assertFalse((self.root / "dist" / "internal.sh").exists())
        self.assertEqual(self.run_cli("check")[0], 0)

    def test_unknown_script_name(self):
        self.script("demo", "echo x\n")
        code, _, err = self.run_cli("build", "nope")
        self.assertEqual(code, 1)
        self.assertIn("unknown script", err)

    def test_new_creates_a_script_and_refuses_bad_names(self):
        self.assertEqual(self.run_cli("new", "my-tool", "-d", "does things")[0], 0)
        self.assertTrue((self.root / "src" / "my-tool" / "main.sh").is_file())
        self.assertEqual(self.run_cli("new", "my-tool")[0], 1)
        self.assertEqual(self.run_cli("new", "Bad_Name")[0], 1)
        self.assertEqual(self.run_cli("new", "lib")[0], 1)

    def test_clean_removes_only_generated_files(self):
        self.script("demo", "echo x\n")
        self.run_cli("build")
        self.put("dist/.gitkeep", "")
        self.run_cli("clean")
        self.assertFalse((self.root / "dist" / "demo.sh").exists())
        self.assertTrue((self.root / "dist" / ".gitkeep").exists())


if __name__ == "__main__":
    unittest.main()
