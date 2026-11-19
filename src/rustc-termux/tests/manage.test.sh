# Tests of the management commands of rustc-termux.sh (run them with: ./tpf.py test rustc-termux).
#
# They never use the compiler of the machine: a stub rustc and cargo answer what the commands
# ask, the same way everywhere. An install is faked in the fresh HOME of each test.

setup() {
    BASE="$HOME/.rustup-fake"
    CONF="$HOME/rust-termux.conf"
    mkdir -p "$BASE/toolchains/linkers" "$HOME/sysroot"
    printf 'nightly=0\njobs=2\noom=\n' >"$BASE/settings"
    printf 'wasm32-unknown-unknown\n' >"$BASE/targets"
    printf '# saved choices\nRT_JOBS=2\nRT_NIGHTLY=0\nRT_PACKS=zig\\ msvc\nRT_OTHER=%s\n' "'keep me'" >"$CONF"
    stub rustc '
case "$*" in
    "--version") echo "rustc 1.99.0 (stub)" ;;
    "-vV") printf "rustc 1.99.0 (stub)\nbinary: rustc\nhost: aarch64-linux-android\nrelease: 1.99.0\n" ;;
    "--print sysroot") echo "'"$HOME"'/sysroot" ;;
    "--print target-list")
        printf "%s\n" aarch64-linux-android armv7-linux-androideabi i686-linux-android \
            x86_64-linux-android wasm32-unknown-unknown thumbv7em-none-eabihf x86_64-unknown-linux-gnu
        # A long list, like the real compiler: the answer must not depend on how much is left to print.
        seq 1 30000 | sed "s/^/filler-target-/" ;;
    *) echo "stub rustc: unexpected arguments: $*" >&2; exit 1 ;;
esac'
    stub cargo 'case "$*" in "--version") echo "cargo 1.99.0 (stub)" ;; *) exit 1 ;; esac'
    export RUSTUP_FAKE_REAL_RUSTC="$STUBS/rustc" RUSTUP_FAKE_REAL_CARGO="$STUBS/cargo"
}

setting() { sed -n "s/^$1=//p" "$BASE/settings" | head -n 1; }
linker_file() { printf '%s/toolchains/linkers/%s' "$BASE" "$1"; }

# ---------------------------------------------------------------- settings commands
test_without_an_install_the_commands_explain_what_to_do() {
    rm -rf "$BASE"
    run_script status
    assert_status 1
    assert_contains "$ERR" "rustc-termux.sh install"
}

test_jobs_updates_the_tool_settings_and_the_saved_choices() {
    run_script jobs 4
    assert_status 0
    assert_contains "$OUT" "limited to 4"
    assert_eq 4 "$(setting jobs)"
    assert_file_contains "$CONF" "RT_JOBS=4"
    # the other saved choices are untouched, quoting included
    assert_file_contains "$CONF" "# saved choices"
    assert_file_contains "$CONF" 'RT_PACKS=zig\ msvc'
    assert_file_contains "$CONF" "RT_OTHER='keep me'"   # a line it did not change stays exactly as written
    run_script jobs off
    assert_status 0
    assert_eq "" "$(setting jobs)"
}

test_jobs_rejects_garbage() {
    run_script jobs many
    assert_status 1
    assert_contains "$ERR" "usage: jobs"
    assert_eq 2 "$(setting jobs)"
}

test_nightly_switch() {
    run_script nightly on
    assert_status 0
    assert_eq 1 "$(setting nightly)"
    assert_file_contains "$CONF" "RT_NIGHTLY=1"
    run_script nightly off
    assert_eq 0 "$(setting nightly)"
    run_script nightly maybe
    assert_status 1
}

test_status_reports_the_targets_and_packs() {
    run_script status
    assert_status 0
    assert_contains "$OUT" "wasm32-unknown-unknown"
    assert_contains "$OUT" "== Linker packs =="
    assert_contains "$OUT" "jobs    : 2"
}

test_packs_list_and_unknown_pack() {
    run_script packs list
    assert_status 0
    for pack in zig msvc ndk wasm; do
        assert_match "$OUT" "(^|"$'\n'")[[:space:]]+$pack[[:space:]]+-"
    done
    run_script packs add nonsense
    assert_status 1
    assert_contains "$ERR" "Unknown pack: nonsense"
}

test_log_command() {
    run_script log
    assert_status 0
    assert_contains "$OUT" "log NAME"
    run_script log no-such-log
    assert_status 1
    assert_contains "$ERR" "No such log"
}

# ---------------------------------------------------------------- linker commands
test_custom_command_linker() {
    run_script linker add armv7-linux-androideabi -- my-cc --flag "a b"
    assert_status 0
    assert_file_contains "$(linker_file armv7-linux-androideabi)" 'my-cc --flag a\ b "$@"'
    [ -x "$(linker_file armv7-linux-androideabi)" ] || fail "the linker is not executable"
    assert_file_contains "$BASE/targets" "armv7-linux-androideabi"
}

test_clang_linker_with_sysroot() {
    run_script linker add aarch64-linux-android --clang aarch64-linux-android24 --sysroot "$HOME"
    assert_status 0
    f="$(linker_file aarch64-linux-android)"
    assert_file_contains "$f" "exec clang --target=aarch64-linux-android24"
    assert_file_contains "$f" "--sysroot=$HOME"
    assert_file_contains "$f" '-fuse-ld=lld "$@"'
}

test_list_flags_a_linker_that_points_to_missing_files() {
    mkdir -p "$HOME/lib"   # the sysroot of the first linker
    run_script linker add aarch64-linux-android --clang aarch64-linux-android24 --sysroot "$HOME"
    run_script linker list
    assert_contains "$OUT" "aarch64-linux-android"
    assert_not_contains "$OUT" "missing"
    run_script linker add x86_64-linux-android --clang x86_64-linux-android24 --sysroot "$HOME/gone"
    run_script linker list
    assert_match "$OUT" "x86_64-linux-android: missing: .*gone"
}

test_remove_and_errors() {
    run_script linker add armv7-linux-androideabi -- my-cc
    run_script linker remove armv7-linux-androideabi
    assert_status 0
    assert_no_file "$(linker_file armv7-linux-androideabi)"
    run_script linker remove armv7-linux-androideabi
    assert_status 1
    assert_contains "$ERR" "No linker"
    run_script linker add not-a-real-target -- cc
    assert_status 1
    assert_contains "$ERR" "unknown target"
    run_script linker add armv7-linux-androideabi
    assert_status 1
    assert_contains "$ERR" "choose how to link"
}

test_ndk_linker_adds_the_compiler_builtins() {
    [ -d "${PREFIX:-/nonexistent}/arm-linux-androideabi" ] || skip "no NDK sysroot (ndk-multilib)"
    run_script linker add armv7-linux-androideabi --ndk
    assert_status 0
    f="$(linker_file armv7-linux-androideabi)"
    assert_file_contains "$f" "--target=armv7a-linux-androideabi24"
    assert_file_contains "$f" "libclang_rt.builtins-arm-android.a"   # needed: rustc links with -nodefaultlibs
}

# ---------------------------------------------------------------- regression
# "rustc --print target-list | grep -q TARGET" under pipefail: grep leaves at the first match,
# rustc is killed by SIGPIPE, and a valid target was refused at random. The stub's list is long
# on purpose, with the wanted target first, so this fails every time with the old code.
test_a_valid_target_is_never_refused_because_of_a_long_compiler_list() {
    for i in 1 2 3 4 5 6; do
        run_script linker add x86_64-linux-android -- my-cc
        assert_status 0
        run_script linker remove x86_64-linux-android
        assert_status 0
    done
}
