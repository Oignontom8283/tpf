# tpf

Termux Pocket Forge

Installers for Termux (Android), written from shared building blocks and
packaged into standalone scripts.

```
src/lib/        shared shell modules (output style, questions, apt helpers, ...)
src/<name>/     one folder per installer: tpf.toml + main.sh (+ extra files)
dist/           generated standalone scripts, one per installer (do not edit)
tools/tpfbuild/ the packager (Python, standard library only)
tests/          tests for the packager and the shared modules
docs/           conventions
```

Everything in `dist/` is produced from `src/`:

```
./tpf build      # rebuild dist/ from src/
./tpf check      # verify dist/ is up to date and the scripts are valid
```

This file is completed as the repository grows.
