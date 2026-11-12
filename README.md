# tpf

Termux Pocket Forge

Installers and managers for Termux (Android). Each tool is **one standalone
script** with the same commands and the same look. The scripts in `dist/` are
generated from shared building blocks in `src/`.

## The tools

| Script | What it does |
|---|---|
| `dist/code-server.sh` | VS Code in the browser (code-server) with the Android fixes and Claude Code support |
| `dist/claude-desktop.sh` | The official Claude Desktop (Electron) running on Termux, without proot or root |
| `dist/rustc-termux.sh` | Rust with a "fake rustup": extra targets, linker packs (zig, MSVC, NDK, WASM), optional root tweaks |
| `dist/termux-keepalive.sh` | Keeps Android from killing Termux (phantom process killer, Doze, lmkd), with root or adb |

Copy a script from `dist/` anywhere on your device and run it. Nothing else from
this repository is needed: every script contains what it uses.

```sh
bash code-server.sh install
bash code-server.sh start
bash code-server.sh status
```

## Same words everywhere

```
tool.sh [options] <command> [arguments]

install      install the tool
reinstall    remove it (keeping your data), then install again
uninstall    remove it
status       tell what is installed / running
start  stop  restart  log      for tools that run something
help  version
```

Not every tool has every command (`help` always lists the real ones), but a
word always means the same thing. Options that exist everywhere:

```
-y, --yes       answer "yes" to every question
-n, --no        answer "no" to every question
    --no-color  plain output
    --log-dir D where to write the logs
-V, --version   -h, --help
```

Questions read from the terminal, so `curl ... | bash` works too; without a
terminal the default answer is used.

## What the output means

```
[INFO] information          [ OK ] done          [ ?? ] a question
[WARN] careful              [ERROR] something failed (on stderr)
[.   ] [..  ] [... ] ...    a task that is running
```

All tags have the same width, except `[ERROR]`, which is longer on purpose.
See [docs/STYLE.md](docs/STYLE.md).

## How to build the scripts

You only need to build when you change something in `src/`. The scripts of
`dist/` are already built, and they are the only thing to copy to a device.

```sh
pkg install python shellcheck   # once (shellcheck is optional but recommended)
python3 tpf.py build            # src/  ->  dist/   (or: ./tpf.py build, or: make build)
python3 tpf.py check            # is dist/ up to date, and is every script valid?
```

`build` glues each tool's `main.sh`, its parts and the shared modules into one
standalone script, checks it (`bash -n`, then `shellcheck`) and only then writes
it to `dist/`. If a check fails nothing is written. `tpf.py build code-server`
builds one tool; `tpf.py list` shows the tools and the modules they use.

## Working on the repository

```sh
./tpf.py build      # rebuild dist/ from src/
./tpf.py check      # dist/ up to date? every script valid (bash -n, shellcheck)?
./tpf.py list       # scripts and the modules they use
./tpf.py new NAME   # start a new tool from a template
python3 -m unittest discover -s tests
```

```
src/lib/        shared modules: ui, core, args, log, pkg, cmd
src/<tool>/     tpf.toml + main.sh + the parts of the tool (+ files it embeds)
dist/           the generated scripts: never edit them by hand
tools/tpfbuild/ the packager (Python, standard library only)
tests/          tests of the packager, the modules and the tools
docs/           style and developer documentation
```

See [docs/DEVELOPING.md](docs/DEVELOPING.md) for how the packager works, the API
of the modules and how to add a tool. A change to `src/` is always committed
together with the rebuilt `dist/` so that `./tpf.py check` passes at every commit.

## License

MIT, see [LICENSE](LICENSE).
