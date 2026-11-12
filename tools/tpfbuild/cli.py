"""Command line of the packager: build, check, list, new, clean."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .core import (KEY_RE, BuildResult, Project, Script, TpfError, validate,
                   write_atomic)

MAIN_TEMPLATE = """#!/data/data/com.termux/files/usr/bin/bash
# {name} - {description}
set -uo pipefail

# tpf:include core
# tpf:include args
# tpf:include log

usage() {{
    printf 'Usage: %s [options]\\n\\nOptions:\\n' "$TPF_NAME"
    std_usage
}}

while [ $# -gt 0 ]; do
    case "$1" in
        *) std_opt "$@" || die "Unknown option: $1 (try --help)"; shift "$STD_SHIFT"; continue ;;
    esac
    shift
done

require_termux
log_init
step "{name}"
ok "Nothing to do yet."
"""

TOML_TEMPLATE = """version = "0.1"
description = "{description}"
"""


def _select(project: Project, names: list[str]) -> list[Script]:
    scripts = project.load_all()
    if not names:
        return scripts
    by_key = {s.key: s for s in scripts}
    missing = [n for n in names if n not in by_key]
    if missing:
        raise TpfError(f"unknown script(s): {', '.join(missing)} (see ./tpf.py list)")
    return [by_key[n] for n in names]


def _build_all(project: Project, scripts: list[Script]) -> list[tuple[Script, BuildResult]]:
    return [(s, project.build(s.key)) for s in scripts]


def _report(label: str, validation) -> None:
    for note in validation.notes:
        print(f"  note: {note}")
    for error in validation.errors:
        for line in error.split("\n"):
            print(f"  {label}: {line}", file=sys.stderr)


def cmd_build(project: Project, args: argparse.Namespace) -> int:
    scripts = _select(project, args.names)
    built = _build_all(project, scripts)
    # Validate everything first: a broken script never replaces a good one.
    failed = False
    for script, result in built:
        validation = validate(result)
        if not validation.ok:
            print(f"FAIL  {script.key}", file=sys.stderr)
            _report("error", validation)
            failed = True
    if failed:
        print("Nothing was written to dist/.", file=sys.stderr)
        return 1
    for script, result in built:
        if not script.publish:
            print(f"skip  {script.key} (dist = false)")
            continue
        target = project.dist / script.output
        unchanged = target.is_file() and target.read_text(encoding="utf-8") == result.text
        if not unchanged:
            write_atomic(target, result.text)
        print(f"{'same' if unchanged else 'built'}  dist/{script.output}  ({script.name} {script.version})")
    return 0


def cmd_check(project: Project, args: argparse.Namespace) -> int:
    scripts = _select(project, args.names)
    problems = 0
    expected: set[str] = set()
    for script, result in _build_all(project, scripts):
        validation = validate(result)
        status = "ok"
        if not validation.ok:
            status = "INVALID"
            problems += 1
        elif script.publish:
            target = project.dist / script.output
            if not target.is_file():
                status = "MISSING dist file"
                problems += 1
            elif target.read_text(encoding="utf-8") != result.text:
                status = "STALE dist file (run ./tpf.py build)"
                problems += 1
        if script.publish:
            expected.add(script.output)
        print(f"{status:<8} {script.key}")
        _report("error", validation)
        if args.strict and any("skipped" in n for n in validation.notes):
            print(f"  error: {script.key}: --strict needs every checker installed", file=sys.stderr)
            problems += 1
    if not args.names and project.dist.is_dir():
        for entry in sorted(project.dist.iterdir()):
            if entry.name.startswith(".") or entry.name in expected:
                continue
            print(f"ORPHAN   dist/{entry.name} (no source produces it)", file=sys.stderr)
            problems += 1
    if problems:
        print(f"{problems} problem(s).", file=sys.stderr)
        return 1
    print("All good.")
    return 0


def cmd_list(project: Project, args: argparse.Namespace) -> int:
    for script in project.load_all():
        result = project.build(script.key)
        out = f"dist/{script.output}" if script.publish else "(not published)"
        mods = ", ".join(result.modules) or "-"
        print(f"{script.key:<18} {script.version:<8} {out}")
        print(f"{'':<18} modules: {mods}")
    return 0


def cmd_new(project: Project, args: argparse.Namespace) -> int:
    if not KEY_RE.match(args.name):
        raise TpfError("name must be lowercase letters, digits and dashes, starting with a letter")
    if args.name == "lib":
        raise TpfError("'lib' is reserved for the shared modules")
    directory = project.src / args.name
    if directory.exists():
        raise TpfError(f"{directory} already exists")
    directory.mkdir(parents=True)
    (directory / "tpf.toml").write_text(TOML_TEMPLATE.format(description=args.description), encoding="utf-8")
    (directory / "main.sh").write_text(
        MAIN_TEMPLATE.format(name=args.name, description=args.description), encoding="utf-8")
    print(f"created src/{args.name}/ (edit it, then run ./tpf.py build {args.name})")
    return 0


def cmd_clean(project: Project, args: argparse.Namespace) -> int:
    removed = 0
    for script in project.load_all():
        target = project.dist / script.output
        if script.publish and target.is_file():
            target.unlink()
            removed += 1
            print(f"removed dist/{script.output}")
    print(f"{removed} file(s) removed.")
    return 0


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="tpf.py", description="Package the shell installers of this repository.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2],
                        help="repository root (default: the checkout containing this tool)")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("build", help="rebuild dist/ from src/")
    p.add_argument("names", nargs="*")
    p.set_defaults(func=cmd_build)
    p = sub.add_parser("check", help="verify dist/ is current and every script is valid")
    p.add_argument("names", nargs="*")
    p.add_argument("--strict", action="store_true", help="fail if a checker (shellcheck) is missing")
    p.set_defaults(func=cmd_check)
    p = sub.add_parser("list", help="list the scripts and the modules they use")
    p.set_defaults(func=cmd_list)
    p = sub.add_parser("new", help="create a new installer from a template")
    p.add_argument("name")
    p.add_argument("-d", "--description", default="describe this installer")
    p.set_defaults(func=cmd_new)
    p = sub.add_parser("clean", help="remove the generated files of dist/")
    p.set_defaults(func=cmd_clean)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = make_parser().parse_args(argv)
    try:
        return args.func(Project(args.root), args)
    except TpfError as exc:
        print(f"tpf: {exc}", file=sys.stderr)
        return 1
