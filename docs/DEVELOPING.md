# Developing

## How a script is built

A tool is a folder `src/<name>/` with a `tpf.toml` and a `main.sh`. `./tpf.py build`
glues `main.sh`, the shared modules and the other files it names into one script
in `dist/`, checks it, and writes it. `./tpf.py check` rebuilds in memory and
compares with `dist/`, so a forgotten rebuild is caught.

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

The output is a pure function of the sources (no date, no machine data); its
header carries a hash of them. `TPF_NAME`, `TPF_VERSION` and `TPF_SOURCE_HASH` are
available to the script. `build` validates every script (`bash -n`, then
`shellcheck` at the level of the toml) before writing anything, so a broken
source never replaces a good `dist/` file.

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

```sh
python3 -m unittest discover -s tests
```

| File | Covers |
|---|---|
| `test_build.py` | the packager: includes, embeds, errors, determinism, `check` |
| `test_lib.py`, `test_pkg.py`, `test_cmd.py` | the modules, under a real pseudo-terminal where it matters |
| `test_tools.py` | the contract every tool built on `cmd` must keep |
| `test_code_server.py`, `test_rustc_termux.py` | the commands of those tools, in a throw-away HOME |

Tests never touch the device they run on. `test_code_server.py` starts a fake
server and gives the script a process pattern (`TPF_CS_PROC_PATTERN`) that only
matches that fake, so a real code-server can never be seen or stopped; it also
replaces `termux-wake-lock` and `termux-wake-unlock`.

What is **not** run by the tests: the `install`, `reinstall` and `uninstall` flows
(they change packages, system files and root settings). They are checked by
`bash -n`, `shellcheck` and by running them on a device.

## Habits

- Edit `src/`, run `./tpf.py build`, commit the source and the rebuilt `dist/` together.
- Do not edit `dist/` by hand: `./tpf.py check` will flag it.
- Keep one commit to one idea; run the tests before committing.
- Run long steps through `task` (foreground, logged), and say what they need
  (network, storage) before starting them.
