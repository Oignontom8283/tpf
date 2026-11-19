# Developing

## How a script is built

A tool is a folder `src/<name>/` with a `tpf.toml` and a `main.sh`. `./tpf.py build`
glues `main.sh`, the shared modules and the other files it names into one script
in `dist/`, checks it, and writes it. `dist/` is generated and ignored by git: the
CI builds the scripts and the releases publish them.

```sh
./tpf.py build [NAME...]          # scripts -> dist/ (a script that fails its checks writes nothing)
./tpf.py build --out DIR          # ... into DIR instead of dist/
./tpf.py check [NAME...]          # build in memory and validate; writes nothing
./tpf.py check --smoke            # ... and run each result (--version, --help)
./tpf.py check --strict           # ... failing when shellcheck is not installed
./tpf.py check --dist             # ... and require a local dist/ to be up to date
```

`tpf.toml`:

```toml
version = "1.0"                 # required
description = "One line"        # required
output = "name.sh"              # default: <folder>.sh
shellcheck = "error"            # error | warning | info | style | off
dist = true                     # false: built and checked, not published
```

### Directives

They start in column 0 of a source line; a mistyped one is an error.

| Directive | Effect |
|---|---|
| `# tpf:include NAME` | insert `src/lib/NAME.sh` |
| `# tpf:include ./part.sh` | insert a file next to the current one (`../dir/part.sh` too) |
| `# tpf:embed ./file as NAME` | define a function `NAME` that prints the file, byte for byte |
| `# tpf:embed-dist KEY as NAME` | same, with the built script `src/KEY` |

A module is inserted once, at its first inclusion, after the modules it needs.
Includes cannot form a cycle and cannot leave `src/` (symbolic links included).
Sources must be UTF-8, LF, without NUL, and end with a newline. Only `main.sh`
starts with `#!`.

The output is a pure function of the sources, apart from three header lines
that depend on the moment or the machine. Every script starts with:

```
#   Project    : tpf - Termux Pocket Forge          (from project.toml)
#   Repository : https://github.com/Oignontom8283/tpf
#   License    : MIT
#   Tool       : code-server 4.0   (src/code-server/)
#   Modules    : core, cmd, pkg                      (shared modules used)
#   Sources    : sha256:...                          (hash of every source file used)
#   Packager   : tpf.py 1.1
#   Built      : 2026-11-13 09:07:23 UTC             volatile
#   Python     : 3.14.10 (CPython) on Android aarch64   volatile
#   Git        : 0c9a7a6 on main                     volatile; omitted outside a git checkout
```

`Git` is the commit (and branch) the build started from. The three volatile lines are ignored when
`build` and `check --dist` compare a script with its `dist/` file without them: a
later date is never "stale", and `build` does not rewrite a file that only differs
by them. Set
`SOURCE_DATE_EPOCH` to fix the build date (reproducible output).

`project.toml` at the root is optional: `name`, `title`, `repository`, `license`
(single-line strings; the name defaults to the folder). `TPF_NAME`, `TPF_VERSION`
and `TPF_SOURCE_HASH` are available to the script itself. `build` validates every
script (`bash -n`, then `shellcheck` at the level of the toml) before writing
anything, so a broken source never replaces a good file in `dist/`.

## The modules (`src/lib/`)

| Module | Provides |
|---|---|
| `ui` | `info ok warn err detail step banner die`, questions, `task`, `spin_run` |
| `core` | `have is_uint is_port require_termux require_aarch64`, `on_exit`, `wake_lock`, signal handling |
| `args` | `std_opt`, `std_usage`, `need_value`: the options common to all tools |
| `log` | `log_init`: the log directory and `run.log` |
| `pkg` | `pkg_update pkg_install apt_install apt_repair dpkg_installed` |
| `cmd` | `add_command add_alias tpf_main`, `help`, `version`, `reinstall` |

### Writing a tool with `cmd`

```sh
#!/data/data/com.termux/files/usr/bin/bash
set -uo pipefail
# tpf:include core
# tpf:include cmd
# tpf:include pkg
# tpf:include ./install.sh

cmd_status() { ok "all good"; }
add_command install   "Install the tool"
add_command status    "Show the state"
add_alias   setup install          # another word for a command

tool_opt() { case "$1" in --port) need_value "$1" $#; PORT="$2"; TOOL_SHIFT=2 ;; *) return 1 ;; esac; }
TOOL_OPTIONS_HELP='      --port N     port to use'
TOOL_RAW_COMMANDS="linker"         # these take their own options after the command name

tpf_main "$@"
```

`reinstall` appears by itself when `cmd_install` and `cmd_uninstall` exist
(`TPF_KEEP_DATA=1` while the removal runs). `status` is expected from every tool;
a test checks the shared contract of every tool built on `cmd`.

## Tests

Two kinds, run on your machine (the CI only checks and builds):

```sh
python3 -m unittest discover -s tests     # the packager, the modules, the contract of the tools
python3 tpf.py test                       # every tool: checked, then its shell tests
```

| File | Covers |
|---|---|
| `test_build.py` | the packager: includes, embeds, errors, headers, determinism, `check`, `build --out` |
| `test_runner.py` | `tpf.py test` and its harness |
| `test_lib.py`, `test_pkg.py`, `test_cmd.py` | the modules, under a real pseudo-terminal where it matters |
| `test_tools.py` | the contract every tool built on `cmd` must keep |
| `test_code_server.py` | the commands of code-server.sh, with a fake server |
| `test_ci.py` | the shape of the GitHub workflows |

Tests never touch the device they run on. `test_code_server.py` starts a fake
server and gives the script a process pattern (`TPF_CS_PROC_PATTERN`) that only
matches that fake, so a real code-server can never be seen or stopped; it also
replaces `termux-wake-lock` and `termux-wake-unlock`.

What is **not** run by the tests: the `install`, `reinstall` and `uninstall` flows
(they change packages, system files and root settings). They are checked by
`bash -n`, `shellcheck` and by running them on a device.

### `tpf.py test`

It works on **any** shell script, not only the tools of this repository.

```sh
./tpf.py test                       # every tool of src/
./tpf.py test code-server           # one tool
./tpf.py test path/to/script.sh     # any script
./tpf.py test path/to/x.test.sh     # one test file
```

For each target it runs, in this order:

1. **the check**: `bash -n`, then `shellcheck` (`--shellcheck LEVEL`, default `error` for a
   plain script, the level of its `tpf.toml` for a tool; `--no-lint` skips it);
2. **`--smoke`** (optional): the script must answer `--version` and `--help`;
3. **its test files**: `script.test.sh` and `script.*.test.sh` next to a plain script,
   or `src/<tool>/tests/*.test.sh` for a tool (the tool is built to a temporary file first).

`-k TEXT` runs only the tests whose name contains TEXT, `-v` lists the passing tests too,
`--timeout S` limits a test file. The status is 1 if anything failed.

A test file is plain bash that defines functions named `test_*`:

```sh
setup() { stub tool 'echo "stubbed"'; }          # before each test (optional; teardown: after)

test_greets() {
    run_script Ada                               # runs the script under test
    assert_status 0
    assert_eq "hello, Ada" "$OUT"
}

test_needs_a_network() { skip "no network here"; }
```

Each test runs in its own subshell, in a **fresh empty HOME** (its XDG folders inside it,
no `TPF_*` variable, no terminal), with stubs first in the `PATH`: nothing leaks from one
test to the next and the real home is never touched. Available in a test:

| Name | Use |
|---|---|
| `SCRIPT`, `TEST_HOME`, `STUBS` | the script under test, the fresh home, the folder of stubs |
| `run CMD...`, `run_script ARG...` | run a command (stdin closed); sets `OUT`, `ERR`, `STATUS` |
| `stub NAME 'BODY'` | a command that replaces the real one (or `stub NAME <<'EOF'`) |
| `assert_eq`, `assert_ne`, `assert_status`, `assert_contains`, `assert_not_contains`, `assert_match` | comparisons, with a readable report |
| `assert_file`, `assert_no_file`, `assert_file_contains` | files |
| `fail MESSAGE`, `skip REASON` | fail or skip the test |

`tools/tpfbuild/harness.sh` documents them all. Tests that depend on the compiler of the
machine are fragile: give the script a stub instead (see
`src/rustc-termux/tests/manage.test.sh`).

## Habits

- Edit `src/`, run `./tpf.py check --smoke` and the tests, commit the sources. `dist/` is
  never committed.
- Do not edit `dist/` by hand: the next build replaces it.
- Keep one commit to one idea; run the tests before committing.
- Run long steps through `task` (foreground, logged), and say what they need
  (network, storage) before starting them.

## CI and releases

Two workflows live in `.github/workflows/`.

**`ci.yml`** runs on every push and every pull request, with two jobs:

| Job | What it does |
|---|---|
| `check` | `tpf.py check --strict --smoke`: `bash -n` and `shellcheck` on every script, then runs `--version` and `--help` of each |
| `build` | `tpf.py build`: the real compilation into `dist/`; the scripts are kept as a workflow artifact for 7 days |

**`release.yml`** starts when a release is **published** on GitHub (a tag such as
`v1.2.0`): it repeats the check, compiles every script (the header date
is the date of the commit, so the same tag always gives the same files) and attaches
the scripts and a `SHA256SUMS` file **to that release**. To attach them again (after a
failed run, for example), start it by hand from the Actions tab with the tag.

### Required checks

The workflows can only report; making the checks **mandatory for a pull request** is a
setting of the repository (a workflow file cannot change it). Run this once, with an
account that administers the repository, after the first CI run (the check names only
exist after a first run):

```sh
gh api -X PUT repos/Oignontom8283/tpf/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["check", "build"] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

`strict` also requires the branch to be up to date with `main` before it is merged.
Add `"required_pull_request_reviews": {"required_approving_review_count": 1}` to require
a review too. The same can be done in *Settings -> Branches -> Add rule*.

A pull request is therefore accepted only if `check` (the syntax and a first run of every
script) and `build` (a real compilation) pass. The tests are **not** part of the CI: run them
on your machine before pushing (`python3 -m unittest discover -s tests` and
`python3 tpf.py test`).

The CI cannot be run on a phone: `tests/test_ci.py` checks the shape of the workflows,
and the commands of their steps were run locally.
