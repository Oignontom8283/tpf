#!/data/data/com.termux/files/usr/bin/bash
# rustc (fake front-end) - handles `rustc +nightly ...`
BASE="${RUSTUP_FAKE_HOME:-$HOME/.rustup-fake}"
REAL_RUSTC="${RUSTUP_FAKE_REAL_RUSTC:-${PREFIX:-/data/data/com.termux/files/usr}/bin/rustc}"
export PATH="$BASE/bin:$PATH"
args=("$@")
toolchain="$(cat "$BASE/default-toolchain" 2>/dev/null || echo stable)"
if [ "${#args[@]}" -gt 0 ] && [[ "${args[0]}" == +* ]]; then
    toolchain="${args[0]#+}"
    args=("${args[@]:1}")
fi
case "$toolchain" in
    nightly*)
        if [ "$(sed -n 's/^nightly=//p' "$BASE/settings" 2>/dev/null | head -n1)" != 1 ]; then
            echo "rustc (fake rustup): the simulated nightly mode is off. Run the installer again with --nightly." >&2
            exit 1
        fi
        export RUSTC_BOOTSTRAP=1 ;;
esac
exec "$REAL_RUSTC" "${args[@]}"
