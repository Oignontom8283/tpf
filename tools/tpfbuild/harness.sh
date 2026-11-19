#!/usr/bin/env bash
# Test harness of `tpf.py test`.   Usage: bash harness.sh TESTFILE SCRIPT [FILTER]
#
# TESTFILE is a bash file that defines functions named test_*. SCRIPT is the file under
# test. Every test runs in its own subshell, in a fresh empty HOME, with stub commands
# first in the PATH, so tests cannot leak into each other or touch the real home.
#
# Variables a test can use
#   SCRIPT       the script under test
#   TEST_HOME    its fresh HOME (also the current directory)
#   STUBS        folder of stub commands, first in the PATH
#   OUT ERR STATUS   set by run / run_script (trailing newlines are removed from OUT and ERR)
#
# Commands a test can use
#   run CMD...            run a command (stdin closed), capture OUT ERR STATUS
#   run_script ARG...     run SCRIPT with bash and the arguments
#   stub NAME 'BODY'      create a stub command (or pipe the body: stub NAME <<'EOF')
#   assert_eq EXPECTED ACTUAL [MESSAGE]      assert_ne
#   assert_status N                          the status of the last run
#   assert_contains TEXT NEEDLE              assert_not_contains
#   assert_match TEXT REGEX                  (bash regular expression)
#   assert_file PATH   assert_no_file PATH   assert_file_contains PATH NEEDLE
#   fail MESSAGE      skip REASON
# A test file may also define setup (before every test) and teardown (after it).
set -u

TESTFILE="${1:?usage: harness.sh TESTFILE SCRIPT [FILTER]}"
SCRIPT="${2:?usage: harness.sh TESTFILE SCRIPT [FILTER]}"
FILTER="${3:-}"
OUT="" ERR="" STATUS=0
export SCRIPT
STUBS=""
TEST_HOME=""
RUNTMP=""   # outside TEST_HOME, so that the home a test sees is really empty

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

skip() {
    printf 'SKIP: %s\n' "$*" >&2
    exit 77
}

run() {
    local o e
    o="$(mktemp "$RUNTMP/out.XXXXXX")"
    e="$(mktemp "$RUNTMP/err.XXXXXX")"
    "$@" >"$o" 2>"$e" </dev/null
    STATUS=$?
    OUT="$(cat "$o")"
    ERR="$(cat "$e")"
    rm -f "$o" "$e"
    return 0
}

run_script() { run bash "$SCRIPT" "$@"; }

stub() {
    local name="$1" body="${2-}"
    if [ "$#" -lt 2 ]; then body="$(cat)"; fi
    printf '#!%s\n%s\n' "$BASH" "$body" >"$STUBS/$name"
    chmod +x "$STUBS/$name"
}

_show() { printf '%s' "$1" | sed 's/^/        /'; printf '\n'; }

assert_eq() {
    [ "$1" = "$2" ] && return 0
    printf 'FAIL: %s\n      expected:\n' "${3:-values differ}" >&2
    _show "$1" >&2
    printf '      actual:\n' >&2
    _show "$2" >&2
    exit 1
}

assert_ne() {
    [ "$1" != "$2" ] || fail "${3:-values are equal}: $1"
}

assert_status() {
    [ "$STATUS" = "$1" ] && return 0
    printf 'FAIL: exit status is %s, expected %s\n      stdout:\n' "$STATUS" "$1" >&2
    _show "$OUT" >&2
    printf '      stderr:\n' >&2
    _show "$ERR" >&2
    exit 1
}

assert_contains() {
    case "$1" in *"$2"*) return 0 ;; esac
    printf 'FAIL: %s\n      does not contain: %s\n      in:\n' "${3:-text not found}" "$2" >&2
    _show "$1" >&2
    exit 1
}

assert_not_contains() {
    case "$1" in *"$2"*) ;; *) return 0 ;; esac
    printf 'FAIL: %s\n      contains: %s\n      in:\n' "${3:-unexpected text}" "$2" >&2
    _show "$1" >&2
    exit 1
}

assert_match() {
    [[ "$1" =~ $2 ]] && return 0
    printf 'FAIL: %s\n      does not match: %s\n      in:\n' "${3:-no match}" "$2" >&2
    _show "$1" >&2
    exit 1
}

assert_file() { [ -e "$1" ] || fail "${2:-no such file}: $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "${2:-file should not exist}: $1"; }

assert_file_contains() {
    assert_file "$1"
    grep -qF -- "$2" "$1" && return 0
    printf 'FAIL: %s does not contain: %s\n      content:\n' "$1" "$2" >&2
    _show "$(cat "$1")" >&2
    exit 1
}

[ -f "$TESTFILE" ] || { echo "harness: no such test file: $TESTFILE" >&2; exit 2; }
[ -f "$SCRIPT" ] || { echo "harness: no such script: $SCRIPT" >&2; exit 2; }
# shellcheck source=/dev/null
. "$TESTFILE" || { echo "harness: $TESTFILE could not be loaded" >&2; exit 2; }

pass=0 nfail=0 nskip=0 count=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/tpf-test.XXXXXX")" || exit 2
trap 'rm -rf "$workdir"' EXIT

while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then continue; fi
    count=$((count + 1))
    TEST_HOME="$workdir/$count/home"
    STUBS="$workdir/$count/stubs"
    RUNTMP="$workdir/$count/tmp"
    mkdir -p "$TEST_HOME" "$STUBS" "$RUNTMP"
    log="$workdir/$count/log"
    (
        # A fresh world: its own HOME and XDG folders, no variable of this tool, no terminal.
        for var in $(compgen -e); do
            case "$var" in TPF_* | XDG_*) unset "$var" ;; esac
        done
        export HOME="$TEST_HOME" TERM=dumb
        export XDG_CONFIG_HOME="$TEST_HOME/.config" XDG_DATA_HOME="$TEST_HOME/.local/share" XDG_CACHE_HOME="$TEST_HOME/.cache"
        export PATH="$STUBS:$PATH"
        cd "$TEST_HOME" || exit 1
        if declare -F setup >/dev/null; then setup; fi
        "$name"
        status=$?
        if declare -F teardown >/dev/null; then teardown; fi
        exit "$status"
    ) >"$log" 2>&1
    rc=$?
    case "$rc" in
        0) pass=$((pass + 1)); printf '  ok     %s\n' "$name" ;;
        77) nskip=$((nskip + 1)); printf '  skip   %s  (%s)\n' "$name" "$(sed -n 's/^SKIP: //p' "$log" | head -n 1)" ;;
        *)
            nfail=$((nfail + 1))
            printf '  FAILED %s\n' "$name"
            sed 's/^/           /' "$log"
            ;;
    esac
done < <(compgen -A function test_ | sort)

if [ "$count" -eq 0 ]; then
    printf '  FAILED no test_* function found in %s\n' "$TESTFILE"
    nfail=1
fi
printf '@@RESULT pass=%d fail=%d skip=%d\n' "$pass" "$nfail" "$nskip"
[ "$nfail" -eq 0 ]
