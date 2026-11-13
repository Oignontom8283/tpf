"""Resolve, render and validate tpf scripts.

A script lives in ``src/<key>/`` (a ``tpf.toml`` and a ``main.sh``). Its
sources may contain directives, which must start in column 0:

    # tpf:include NAME            insert the shared module src/lib/NAME.sh
    # tpf:include ./file.sh       insert a file relative to the current one (../ too)
    # tpf:embed PATH as NAME      define the function NAME that prints PATH
    # tpf:embed-dist KEY as NAME  same, with the built script src/KEY

Every module is inserted once, at its first inclusion. The result is a single
standalone script: no file of the repository is needed to run it.

The header of a generated script records where it comes from and how it was
built. The lines that depend on the moment or the machine (Built, Python, Git)
are "volatile": ``strip_volatile`` removes them, and ``build`` and ``check``
compare scripts without them. Everything else is a pure function of the sources,
so a rebuild gives the same script and ``check`` can detect a stale ``dist/``.
``SOURCE_DATE_EPOCH`` fixes the build date (reproducible builds).
"""

from __future__ import annotations

import datetime
import hashlib
import os
import platform
import re
import shlex
import shutil
import subprocess
import tempfile
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from . import __version__

DIRECTIVE_PREFIX = "# tpf:"
NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
KEY_RE = re.compile(r"^[a-z][a-z0-9-]*$")
MODULE_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
SHELLCHECK_LEVELS = ("error", "warning", "info", "style", "off")
META_KEYS = {"name", "version", "description", "main", "output", "shellcheck", "dist"}
PROJECT_KEYS = {"name", "title", "repository", "license"}
# Header lines that depend on the moment or the machine of the build.
VOLATILE_RE = re.compile(r"(?m)^#   (?:Built|Python|Git)\s*:[^\n]*\n")


def strip_volatile(text: str) -> str:
    """The script without the header lines that change from build to build."""
    return VOLATILE_RE.sub("", text)


class TpfError(Exception):
    """A problem in the sources or the project layout (message is user-facing)."""


# --------------------------------------------------------------------------
# Reading sources
# --------------------------------------------------------------------------
def read_text(path: Path) -> str:
    """Read a source file, refusing anything that could corrupt a script."""
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise TpfError(f"{path}: cannot read ({exc.strerror})") from exc
    if b"\0" in data:
        raise TpfError(f"{path}: contains a NUL byte")
    if b"\r" in data:
        raise TpfError(f"{path}: contains a carriage return (use LF line endings)")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise TpfError(f"{path}: not valid UTF-8 ({exc.reason})") from exc
    if text and not text.endswith("\n"):
        raise TpfError(f"{path}: must end with a newline")
    return text


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --------------------------------------------------------------------------
# Project model
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class Script:
    key: str
    directory: Path
    name: str
    version: str
    description: str
    main: Path
    output: str
    shellcheck: str
    publish: bool


@dataclass
class BuildResult:
    script: Script
    text: str
    files: list[Path] = field(default_factory=list)  # every source used, in order
    modules: list[str] = field(default_factory=list)  # shared modules inserted


@dataclass
class _Context:
    included: set[Path] = field(default_factory=set)
    stack: list[Path] = field(default_factory=list)
    files: list[Path] = field(default_factory=list)
    modules: list[str] = field(default_factory=list)
    embed_names: set[str] = field(default_factory=set)
    building: tuple[str, ...] = ()

    def use(self, path: Path) -> None:
        if path not in self.files:
            self.files.append(path)


@dataclass(frozen=True)
class ProjectInfo:
    name: str
    title: str = ""
    repository: str = ""
    license: str = ""


class Project:
    """A repository checkout: ``root/src`` (sources) and ``root/dist`` (output)."""

    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.src = self.root / "src"
        self.dist = self.root / "dist"
        self.lib = self.src / "lib"
        self.info = self._load_info()

    def _load_info(self) -> ProjectInfo:
        """``project.toml`` at the root (optional): name, title, repository, license."""
        path = self.root / "project.toml"
        if not path.is_file():
            return ProjectInfo(name=self.root.name)
        try:
            data = tomllib.loads(read_text(path))
        except tomllib.TOMLDecodeError as exc:
            raise TpfError(f"{path}: invalid TOML ({exc})") from exc
        unknown = set(data) - PROJECT_KEYS
        if unknown:
            raise TpfError(f"{path}: unknown key(s): {', '.join(sorted(unknown))}")
        for key, value in data.items():
            if not isinstance(value, str) or "\n" in value:
                raise TpfError(f"{path}: '{key}' must be a single-line string")
        return ProjectInfo(name=data.get("name") or self.root.name, title=data.get("title", ""),
                           repository=data.get("repository", ""), license=data.get("license", ""))

    # -- discovery ---------------------------------------------------------
    def script_keys(self) -> list[str]:
        if not self.src.is_dir():
            raise TpfError(f"{self.src}: no src/ directory")
        keys = []
        for entry in sorted(self.src.iterdir()):
            if entry.name == "lib" or not entry.is_dir():
                continue
            if (entry / "tpf.toml").is_file():
                keys.append(entry.name)
        return keys

    def load(self, key: str) -> Script:
        if not KEY_RE.match(key):
            raise TpfError(f"invalid script name: {key!r}")
        directory = self.src / key
        meta_path = directory / "tpf.toml"
        if not meta_path.is_file():
            raise TpfError(f"unknown script: {key} (no {meta_path.relative_to(self.root)})")
        try:
            meta = tomllib.loads(read_text(meta_path))
        except tomllib.TOMLDecodeError as exc:
            raise TpfError(f"{meta_path}: invalid TOML ({exc})") from exc
        unknown = set(meta) - META_KEYS
        if unknown:
            raise TpfError(f"{meta_path}: unknown key(s): {', '.join(sorted(unknown))}")
        for required in ("version", "description"):
            if not isinstance(meta.get(required), str) or not meta[required].strip():
                raise TpfError(f"{meta_path}: '{required}' is required (non-empty string)")
        for field_name in ("version", "description"):
            if "\n" in meta[field_name]:
                raise TpfError(f"{meta_path}: '{field_name}' must be a single line")
        name = meta.get("name", key)
        if not isinstance(name, str) or not KEY_RE.match(name):
            raise TpfError(f"{meta_path}: invalid 'name': {name!r}")
        main_rel = meta.get("main", "main.sh")
        output = meta.get("output", f"{name}.sh")
        if not isinstance(output, str) or "/" in output or output in ("", ".", ".."):
            raise TpfError(f"{meta_path}: 'output' must be a plain file name")
        level = meta.get("shellcheck", "error")
        if level not in SHELLCHECK_LEVELS:
            raise TpfError(f"{meta_path}: 'shellcheck' must be one of {', '.join(SHELLCHECK_LEVELS)}")
        publish = meta.get("dist", True)
        if not isinstance(publish, bool):
            raise TpfError(f"{meta_path}: 'dist' must be true or false")
        main = self._inside(directory, str(main_rel), f"{meta_path}: 'main'")
        return Script(key, directory, name, meta["version"].strip(), meta["description"].strip(),
                      main, output, level, publish)

    def load_all(self) -> list[Script]:
        scripts = [self.load(key) for key in self.script_keys()]
        seen: dict[str, str] = {}
        for script in scripts:
            if script.publish:
                if script.output in seen:
                    raise TpfError(f"scripts {seen[script.output]} and {script.key} "
                                   f"both write dist/{script.output}")
                seen[script.output] = script.key
        return scripts

    # -- path safety -------------------------------------------------------
    def _inside(self, base: Path, rel: str, what: str) -> Path:
        """Resolve ``rel`` against ``base``; it must be a file inside src/."""
        candidate = (base / rel).resolve()
        src = self.src.resolve()
        try:
            candidate.relative_to(src)
        except ValueError:
            raise TpfError(f"{what}: {rel!r} points outside src/") from None
        if not candidate.is_file():
            raise TpfError(f"{what}: no such file: {candidate.relative_to(self.root)}")
        return candidate

    def rel(self, path: Path) -> str:
        return path.relative_to(self.root).as_posix()

    # -- building ----------------------------------------------------------
    def build(self, key: str, _building: tuple[str, ...] = ()) -> BuildResult:
        if key in _building:
            chain = " -> ".join((*_building, key))
            raise TpfError(f"embed-dist cycle: {chain}")
        script = self.load(key)
        ctx = _Context(building=(*_building, key))
        ctx.included.add(script.main)
        ctx.use(script.directory / "tpf.toml")
        body = self._expand(script.main, ctx, is_main=True)
        shebang, body = body
        digest = self._digest(ctx.files)
        text = self._render(script, shebang, body, digest, ctx.modules)
        return BuildResult(script, text, list(ctx.files), list(ctx.modules))

    def _digest(self, files: list[Path]) -> str:
        h = hashlib.sha256()
        for path in sorted(files, key=self.rel):
            h.update(self.rel(path).encode() + b"\0" + path.read_bytes() + b"\0")
        return h.hexdigest()

    def _git_line(self) -> str | None:
        """Where the sources come from, or None when the project is not a git checkout."""
        def git(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run(["git", *args], cwd=self.root, capture_output=True, text=True, timeout=15)
        try:
            top = git("rev-parse", "--show-toplevel")
            if top.returncode != 0 or Path(top.stdout.strip()).resolve() != self.root:
                return None
            rev = git("rev-parse", "--short", "HEAD")
            if rev.returncode != 0:
                return None
            branch = git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip() or "?"
            dirty = git("status", "--porcelain", "--", "src", "tools", "project.toml").stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
        return f"{rev.stdout.strip()} on {branch} ({'with uncommitted changes' if dirty else 'clean'})"

    @staticmethod
    def _build_date() -> str:
        epoch = os.environ.get("SOURCE_DATE_EPOCH", "")
        moment = (datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc) if epoch.isdigit()
                  else datetime.datetime.now(datetime.timezone.utc))
        return moment.strftime("%Y-%m-%d %H:%M:%S UTC")

    def _render(self, script: Script, shebang: str, body: str, digest: str, modules: list[str]) -> str:
        bar = "# " + "=" * 76
        info = self.info
        rows = [("Project", f"{info.name} - {info.title}" if info.title else info.name)]
        if info.repository:
            rows.append(("Repository", info.repository))
        if info.license:
            rows.append(("License", info.license))
        rows += [
            ("Tool", f"{script.name} {script.version}   (src/{script.key}/)"),
            ("Modules", ", ".join(modules) or "-"),
            ("Sources", f"sha256:{digest[:16]}"),
            ("Packager", f"tpf.py {__version__}"),
            # -- volatile: ignored when comparing (see strip_volatile) --
            ("Built", self._build_date()),
            ("Python", f"{platform.python_version()} ({platform.python_implementation()}) "
                       f"on {platform.system()} {platform.machine()}"),
        ]
        git_line = self._git_line()
        if git_line:
            rows.append(("Git", git_line))
        header = [shebang, bar, f"# {script.description}", "#"]
        header += [f"#   {label:<10} : {value}" for label, value in rows]
        header += [
            "#",
            "# Generated file: do not edit. Change src/ and run ./tpf.py build.",
            bar,
            "# shellcheck disable=SC2034  # available to the script, not always used",
            f"TPF_NAME={shlex.quote(script.name)}",
            f"TPF_VERSION={shlex.quote(script.version)}",
            f"TPF_SOURCE_HASH={digest[:16]}",
        ]
        return "\n".join(header) + "\n" + body

    def _expand(self, path: Path, ctx: _Context, is_main: bool = False):
        """Return the text of ``path`` with directives expanded.

        For the main file the result is ``(shebang, body)``; for modules, text.
        """
        ctx.use(path)
        label = self.rel(path)
        lines = read_text(path).split("\n")[:-1]
        shebang = ""
        if is_main:
            if not lines or not lines[0].startswith("#!"):
                raise TpfError(f"{label}:1: the main file must start with a #! line")
            shebang, lines = lines[0], lines[1:]
            offset = 2
        else:
            if lines and lines[0].startswith("#!"):
                raise TpfError(f"{label}:1: a module must not have a #! line")
            offset = 1
        ctx.stack.append(path)
        out: list[str] = []
        for number, line in enumerate(lines, start=offset):
            if not line.startswith(DIRECTIVE_PREFIX):
                out.append(line)
                continue
            where = f"{label}:{number}"
            verb, _, arg = line[len(DIRECTIVE_PREFIX):].partition(" ")
            arg = arg.strip()
            if verb == "include":
                out.extend(self._include(path, arg, where, ctx))
            elif verb == "embed":
                out.extend(self._embed(path, arg, where, ctx, built=False))
            elif verb == "embed-dist":
                out.extend(self._embed(path, arg, where, ctx, built=True))
            else:
                raise TpfError(f"{where}: unknown directive 'tpf:{verb}'")
        ctx.stack.pop()
        text = "\n".join(out) + "\n"
        return (shebang, text) if is_main else text

    def _include(self, current: Path, arg: str, where: str, ctx: _Context) -> list[str]:
        if not arg or " " in arg:
            raise TpfError(f"{where}: usage: # tpf:include NAME | ./relative.sh | ../relative.sh")
        if arg.startswith(("./", "../")):
            target = self._inside(current.parent, arg, where)
            module = None
        else:
            if not MODULE_RE.match(arg):
                raise TpfError(f"{where}: invalid module name {arg!r}")
            if not (self.lib / f"{arg}.sh").is_file():
                raise TpfError(f"{where}: unknown module {arg!r} (no src/lib/{arg}.sh)")
            target = self._inside(self.lib, f"{arg}.sh", where)
            module = arg
        if target in ctx.stack:
            chain = " -> ".join(self.rel(p) for p in (*ctx.stack, target))
            raise TpfError(f"{where}: include cycle: {chain}")
        if target in ctx.included:
            return []
        ctx.included.add(target)
        if module:
            ctx.modules.append(module)
        body = self._expand(target, ctx)
        label = self.rel(target)
        return [f"# --- tpf: begin {label} ---", *body.rstrip("\n").split("\n"),
                f"# --- tpf: end {label} ---"]

    def _embed(self, current: Path, arg: str, where: str, ctx: _Context, built: bool) -> list[str]:
        match = re.fullmatch(r"(\S+) as (\S+)", arg)
        if not match:
            verb = "embed-dist KEY" if built else "embed PATH"
            raise TpfError(f"{where}: usage: # tpf:{verb} as NAME")
        source, name = match.groups()
        if not NAME_RE.match(name):
            raise TpfError(f"{where}: invalid function name {name!r}")
        if name in ctx.embed_names:
            raise TpfError(f"{where}: function {name!r} is already defined by another embed")
        ctx.embed_names.add(name)
        if built:
            if not KEY_RE.match(source):
                raise TpfError(f"{where}: invalid script name {source!r}")
            inner = self.build(source, ctx.building)
            content = inner.text
            for used in inner.files:
                ctx.use(used)
        else:
            target = self._inside(current.parent, source, where)
            ctx.use(target)
            content = read_text(target)
        return heredoc_function(name, content).split("\n")[:-1]


def heredoc_function(name: str, content: str) -> str:
    """A bash function that prints ``content`` byte for byte.

    The here-document delimiter is derived from the content and is guaranteed
    not to appear as a line of it.
    """
    if content and not content.endswith("\n"):
        raise TpfError(f"embedded content for {name} must end with a newline")
    digest = sha256_hex(content.encode()).upper()[:12]
    lines = set(content.split("\n"))
    delimiter, n = f"TPF_EOF_{digest}", 0
    while delimiter in lines:
        n += 1
        delimiter = f"TPF_EOF_{digest}_{n}"
    return f"{name}() {{\n    cat <<'{delimiter}'\n{content}{delimiter}\n}}\n"


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------
@dataclass
class Validation:
    errors: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors


def validate(result: BuildResult) -> Validation:
    """Check a built script: structure, bash syntax and shellcheck."""
    out = Validation()
    text = result.text
    for number, line in enumerate(text.split("\n"), start=1):
        if line.startswith(DIRECTIVE_PREFIX):
            out.errors.append(f"line {number}: a tpf directive was left in the output")
    if not text.startswith("#!"):
        out.errors.append("line 1: no #! line")
    if out.errors:
        return out
    bash = shutil.which("bash")
    if not bash:
        out.errors.append("bash not found: cannot check the syntax")
        return out
    with tempfile.TemporaryDirectory(prefix="tpf-check-") as tmp:
        probe = Path(tmp) / f"{result.script.name}.sh"
        probe.write_text(text, encoding="utf-8")
        syntax = subprocess.run([bash, "-n", str(probe)], capture_output=True, text=True)
        if syntax.returncode != 0:
            out.errors.append("bash -n failed: " + syntax.stderr.strip().replace(str(probe), "script"))
            return out
        level = result.script.shellcheck
        if level == "off":
            out.notes.append("shellcheck disabled for this script")
            return out
        checker = shutil.which("shellcheck")
        if not checker:
            out.notes.append("shellcheck not installed: skipped")
            return out
        lint = subprocess.run([checker, "-s", "bash", "-S", level, "-f", "gcc", str(probe)],
                              capture_output=True, text=True)
        if lint.returncode != 0:
            detail = lint.stdout.strip().replace(str(probe), "script")
            out.errors.append(f"shellcheck ({level}) reported problems:\n{detail}")
    return out


# --------------------------------------------------------------------------
# Writing
# --------------------------------------------------------------------------
def write_atomic(path: Path, text: str) -> None:
    """Write ``text`` to ``path`` so that a reader never sees a partial file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.chmod(tmp_name, 0o755)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise
