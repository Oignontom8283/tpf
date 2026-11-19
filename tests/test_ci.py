"""Guards the GitHub Actions workflows (they cannot run on a phone, so their shape is checked)."""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WORKFLOWS = REPO / ".github" / "workflows"

try:  # PyYAML is not installed everywhere: the text checks below do not need it
    import yaml
except ImportError:  # pragma: no cover
    yaml = None


def load(name):
    return (WORKFLOWS / name).read_text(encoding="utf-8")


def parsed(name):
    data = yaml.safe_load(load(name))
    data["on"] = data.pop(True, data.get("on"))  # PyYAML reads the key `on` as the boolean True
    return data


class CiWorkflow(unittest.TestCase):
    def test_runs_on_every_push_and_pull_request(self):
        text = load("ci.yml")
        self.assertRegex(text, r"(?m)^on:\n  push:\n  pull_request:\n")
        self.assertNotRegex(text, r"(?m)^\s+branches:", "a branch filter would skip pushes")

    def test_the_jobs_that_can_be_required_have_stable_names(self):
        # These names are the status checks that branch protection requires for a pull request.
        names = re.findall(r"(?m)^    name: (\S+)$", load("ci.yml"))
        self.assertEqual(names, ["check", "build"])

    def test_check_job_is_strict_and_runs_the_scripts(self):
        self.assertIn("python3 tpf.py check --strict --smoke", load("ci.yml"))

    def test_build_job_really_compiles_into_dist(self):
        text = load("ci.yml")
        self.assertRegex(text, r"(?m)run: python3 tpf\.py build$")
        self.assertIn("path: dist/*.sh", text)
        self.assertNotIn("build/", text.replace("tpf.py build", ""))

    def test_there_is_no_test_job(self):
        # The tests run on a developer's machine (python3 -m unittest discover -s tests, tpf.py test);
        # the CI only checks and builds.
        for name in ("ci.yml", "release.yml"):
            self.assertNotIn("unittest", load(name))
            self.assertNotIn("tpf.py test", load(name))

    def test_least_privilege(self):
        self.assertRegex(load("ci.yml"), r"(?m)^permissions:\n  contents: read\n")

    @unittest.skipUnless(yaml, "PyYAML not installed")
    def test_it_is_valid_yaml_with_the_expected_jobs(self):
        data = parsed("ci.yml")
        self.assertEqual(list(data["jobs"]), ["check", "build"])
        for job in data["jobs"].values():
            self.assertEqual(job["runs-on"], "ubuntu-latest")
            self.assertTrue(job["steps"])


class ReleaseWorkflow(unittest.TestCase):
    def test_starts_when_a_release_is_published_or_by_hand(self):
        text = load("release.yml")
        self.assertRegex(text, r"(?m)^on:\n  release:\n    types: \[published\]\n  workflow_dispatch:")

    def test_attaches_the_scripts_to_the_release_that_started_it(self):
        text = load("release.yml")
        self.assertIn("github.event.release.tag_name", text)
        self.assertIn('gh release upload "$TAG" dist/*.sh dist/SHA256SUMS --clobber', text)

    def test_checks_before_compiling(self):
        text = load("release.yml")
        order = [text.index(s) for s in ("tpf.py check --strict --smoke", "tpf.py build")]
        self.assertEqual(order, sorted(order))

    def test_dates_come_from_the_commit_so_a_rebuild_gives_the_same_files(self):
        self.assertIn('SOURCE_DATE_EPOCH="$(git log -1 --format=%ct)"', load("release.yml"))

    def test_writes_checksums(self):
        self.assertIn("sha256sum -- *.sh > SHA256SUMS", load("release.yml"))

    def test_only_this_workflow_can_write(self):
        self.assertRegex(load("release.yml"), r"(?m)^permissions:\n  contents: write\n")
        self.assertNotIn("contents: write", load("ci.yml"))

    @unittest.skipUnless(yaml, "PyYAML not installed")
    def test_it_is_valid_yaml(self):
        data = parsed("release.yml")
        self.assertEqual(set(data["on"]), {"release", "workflow_dispatch"})
        self.assertEqual(list(data["jobs"]), ["publish"])


class Repository(unittest.TestCase):
    def test_dist_is_generated_and_not_committed(self):
        lines = (REPO / ".gitignore").read_text().split("\n")
        self.assertIn("dist/", lines)


if __name__ == "__main__":
    unittest.main()
