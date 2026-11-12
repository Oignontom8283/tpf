# Output style

Every tool prints the same way. The code lives in `src/lib/ui.sh`; use its
functions instead of `echo` so that the style stays identical.

## Tags

| Tag | Function | Meaning |
|---|---|---|
| `[INFO]` | `info` | something the user should know |
| `[ OK ]` | `ok` | a step succeeded |
| `[ ?? ]` | `ask_yes_no`, `ask_input`, `ask_choice` | a question |
| `[WARN]` | `warn` | careful, but the script goes on |
| `[ERROR]` | `err`, `die` | danger: something failed (stderr) |

The first four are **exactly six columns wide**, so the text always starts in
column 8. `[ERROR]` is seven columns wide on purpose: danger stands out.

`detail "text"` prints a dimmed line aligned with the text above, and
`step "Title"` prints a `=== Title ===` header. `banner "Title" "subtitle"` frames
the start or the end of a script.

## Running tasks

```sh
task "Installing clang lld" pkg install -y clang lld
```

While the command runs (its output goes to a log file) the line shows an
animated marker of the same width as the tags:

```
[.   ] Installing clang lld
[..  ] Installing clang lld
[... ] Installing clang lld
[ ...] Installing clang lld
[  ..] Installing clang lld
[   .] Installing clang lld
```

then it is replaced by `[ OK ] Installing clang lld (12s)`, or by `[ERROR]`
followed by the last lines of the log and its path. Without a terminal nothing
is animated: `[ .. ] message` is printed, then the result.

`spin_run LABEL LOGFILE command...` is the marker alone (the caller prints the
result). A task runs in a subshell, so it cannot set variables for the script.
When the script is interrupted, the task and every process it started are
stopped.

## Questions

```sh
ask_yes_no "Raise the limit?" yes     # status 0 = yes; [Y/n] or [y/N]
ask_input "Port?" 8080                # answer in $ANSWER
ask_choice "Method" auto auto tur npm # answer in $ANSWER
```

They read `/dev/tty`. `--yes` / `--no` (`TPF_ASSUME`) answer without asking and say
so (`[auto: yes]`); without any terminal the default is used, with a warning.

## Colours

Colours are used on a terminal only. `NO_COLOR`, `--no-color` or `ui_colors off`
remove them; the log file never contains colours.

## Rules for a tool

- Print through `info ok warn err detail step banner task`, never with raw `echo` tags.
- Messages are in English, one sentence, no trailing full stop in titles.
- Errors go to stderr (`err`, `die`); everything else to stdout.
- Exit status: 0 success, 1 failure, 2 wrong usage (the `cmd` module does this).
- A long command goes through `task` so the user sees something is happening.
- Never leave a tag-like marker (`[*]`, `[OK]`, `[!]`) in a message: a test checks it.
