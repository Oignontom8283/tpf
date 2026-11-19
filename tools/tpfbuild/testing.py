"""``tpf.py test``: check any shell script and run the shell tests written next to it.

Targets
    (none)              every tool of src/, built to a temporary file
    TOOL                one tool of src/ (for example ``code-server``)
    path/to/script.sh   any shell script
    path/to/x.test.sh   one test file (its script is found next to it, or it is the tool
                        whose src/<tool>/tests/ folder holds it)

For a script ``foo.sh`` the tests are ``foo.test.sh`` and ``foo.*.test.sh`` in the same
folder; for a tool they are ``src/<tool>/tests/*.test.sh``. A test file defines functions
named ``test_*`` and is run by ``harness.sh`` (see its header for the helpers).
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from .core import Project, TpfError, lint_file, smoke, validate

HARNESS = Path(__file__).resolve().with_name("harness.sh")
RESULT_RE = re.compile(r"^@@RESULT pass=(\d+) fail=(\d+) skip=(\d+)$", re.M)


@dataclass
class Target:
    name: str
    script: Path
    tests: list[Path]
    tool_key: str | None = None
    problems: list[str] = field(default_factory=list)


def test_files_for(script: Path) -> list[Path]:
    stem = script.name[:-3] if script.name.endswith(".sh") else script.name
    found = [script.with_name(f"{stem}.test.sh")] + sorted(script.parent.glob(f"{stem}.*.test.sh"))
    return [f for f in dict.fromkeys(found) if f.is_file()]


def tool_tests(project: Project, key: str) -> list[Path]:
    return sorted((project.src / key / "tests").glob("*.test.sh"))


def resolve(project: Project, names: list[str], build_dir: Path) -> list[Target]:
    keys = project.script_keys()
    if not names:
        names = keys
    targets: list[Target] = []
    for name in names:
        path = Path(name)
        if name in keys and not path.exists():
            targets.append(_tool_target(project, name, build_dir))
        elif path.is_file() and path.name.endswith(".test.sh"):
            targets.append(_from_test_file(project, path.resolve(), keys, build_dir))
        elif path.is_file():
            script = path.resolve()
            targets.append(Target(script.name, script, test_files_for(script)))
        else:
            raise TpfError(f"{name}: not a tool of src/ ({', '.join(keys)}) and not an existing file")
    return targets


def _tool_target(project: Project, key: str, build_dir: Path) -> Target:
    result = project.build(key)
    out = build_dir / key
    out.mkdir(parents=True, exist_ok=True)
    script = out / result.script.output
    script.write_text(result.text, encoding="utf-8")
    script.chmod(0o755)
    return Target(key, script, tool_tests(project, key), tool_key=key)


def _from_test_file(project: Project, test: Path, keys: list[str], build_dir: Path) -> Target:
    if test.parent.name == "tests" and test.parent.parent.name in keys and test.parent.parent.parent == project.src:
        target = _tool_target(project, test.parent.parent.name, build_dir)
        target.tests = [test]
        return target
    stem = test.name[: -len(".test.sh")].split(".")[0]
    script = test.with_name(f"{stem}.sh")
    if not script.is_file():
        raise TpfError(f"{test}: the script under test ({script.name}) was not found next to it")
    return Target(script.name, script, [test])


def run_test_file(test: Path, script: Path, pattern: str, timeout: int, verbose: bool) -> tuple[int, int, int, bool]:
    """Runs one test file; returns (passed, failed, skipped, crashed)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("TPF_")}
    try:
        done = subprocess.run(["bash", str(HARNESS), str(test), str(script), pattern], capture_output=True,
                              text=True, env=env, stdin=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        partial = (exc.stdout or b"")
        text = partial.decode("utf-8", "replace") if isinstance(partial, bytes) else partial
        print(text, end="")
        print(f"  FAILED the test file did not finish within {timeout} s")
        return 0, 1, 0, True
    out = done.stdout
    shown = RESULT_RE.sub("", out)
    if verbose or done.returncode != 0:
        print(shown, end="" if shown.endswith("\n") or not shown else "\n")
    else:
        for line in shown.splitlines():
            if line.startswith("  skip"):
                print(line)
    if done.stderr.strip():
        print("  " + done.stderr.strip().replace("\n", "\n  "), file=sys.stderr)
    match = RESULT_RE.search(out)
    if not match:
        print(f"  FAILED the harness stopped without a result (exit status {done.returncode})")
        return 0, 1, 0, True
    passed, failed, skipped = (int(g) for g in match.groups())
    return passed, failed, skipped, False


def run(project: Project, names: list[str], *, lint: bool, level: str | None, do_smoke: bool,
        pattern: str, timeout: int, verbose: bool) -> int:
    problems = 0
    totals = [0, 0, 0]
    with tempfile.TemporaryDirectory(prefix="tpf-test-") as tmp:
        targets = resolve(project, names, Path(tmp))
        for target in targets:
            print(f"== {target.name}")
            if lint:
                if target.tool_key:
                    validation = validate(project.build(target.tool_key))
                    how = "bash -n, shellcheck (level of its tpf.toml)"
                else:
                    validation = lint_file(target.script, level or "error")
                    how = f"bash -n, shellcheck ({level or 'error'})"
                if validation.ok:
                    print(f"  lint   ok ({how})")
                    for note in validation.notes:
                        print(f"         note: {note}")
                else:
                    problems += 1
                    print("  lint   FAILED")
                    for error in validation.errors:
                        print("         " + error.replace("\n", "\n         "))
            if do_smoke:
                if target.tool_key:
                    crashed = smoke(project.build(target.tool_key))
                else:
                    done = [subprocess.run(["bash", str(target.script), opt], capture_output=True, text=True,
                                           env={**os.environ, "HOME": tmp}, stdin=subprocess.DEVNULL, timeout=30)
                            for opt in ("--version", "--help")]
                    crashed = [f"{opt}: exit status {d.returncode}" for opt, d in zip(("--version", "--help"), done)
                               if d.returncode != 0]
                if crashed:
                    problems += 1
                    print("  smoke  FAILED")
                    for line in crashed:
                        print("         " + line)
                else:
                    print("  smoke  ok (--version, --help)")
            for test in target.tests:
                print(f"  -- {test.name}")
                passed, failed, skipped, crashed = run_test_file(test, target.script, pattern, timeout, verbose)
                totals[0] += passed
                totals[1] += failed
                totals[2] += skipped
                if failed or crashed:
                    problems += 1
                print(f"  => {passed} passed, {failed} failed, {skipped} skipped")
            if not target.tests:
                print("  (no test file next to it)")
    print()
    print(f"{totals[0]} passed, {totals[1]} failed, {totals[2]} skipped in the test files; "
          f"{problems} target(s) with a problem.")
    return 1 if problems else 0
