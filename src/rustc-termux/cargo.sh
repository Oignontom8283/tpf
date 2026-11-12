#!/data/data/com.termux/files/usr/bin/bash
# cargo (fake front-end) - installed by install-fake-rustup-termux.sh
# Runs Termux's cargo. For a target added with `rustup target add`, it also
# asks cargo to rebuild the standard library for that target.
BASE="${RUSTUP_FAKE_HOME:-$HOME/.rustup-fake}"
# A target's standard library is usable only if its real .rlib files are there.
# Termux's rust package ships some Android targets (armv7, i686, x86_64) with
# .rmeta metadata files only: rustc then fails with "required to be available
# in rlib format". A bare directory is NOT enough.
std_ready() { compgen -G "$1/libcore-*.rlib" >/dev/null 2>&1; }
REAL_CARGO="${RUSTUP_FAKE_REAL_CARGO:-${PREFIX:-/data/data/com.termux/files/usr}/bin/cargo}"
REAL_RUSTC="${RUSTUP_FAKE_REAL_RUSTC:-${PREFIX:-/data/data/com.termux/files/usr}/bin/rustc}"
setting() { sed -n "s/^$1=//p" "$BASE/settings" 2>/dev/null | head -n1; }

export PATH="$BASE/bin:$BASE/toolchains/bin:$PATH"   # "rust-lld", zig, cargo-zigbuild, cargo-xwin...
export RUSTC="$REAL_RUSTC"         # cargo uses the real rustc, not the fake one
# caches of the packs stay inside ~/.rustup-fake (removed with it)
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$BASE/zig-cache}"
export CARGO_ZIGBUILD_CACHE_DIR="${CARGO_ZIGBUILD_CACHE_DIR:-$BASE/zigbuild-cache}"
export XWIN_CACHE_DIR="${XWIN_CACHE_DIR:-$BASE/xwin-cache}"

if [ -z "${CARGO_BUILD_JOBS:-}" ]; then
    jobs="$(setting jobs)"
    [ -n "$jobs" ] && export CARGO_BUILD_JOBS="$jobs"
fi

args=("$@")
toolchain="$(cat "$BASE/default-toolchain" 2>/dev/null || echo stable)"
if [ "${#args[@]}" -gt 0 ] && [[ "${args[0]}" == +* ]]; then
    toolchain="${args[0]#+}"
    args=("${args[@]:1}")
fi
case "$toolchain" in
    nightly*)
        if [ "$(setting nightly)" != 1 ]; then
            echo "cargo (fake rustup): the simulated nightly mode is off. Run the installer again with --nightly." >&2
            exit 1
        fi
        export RUSTC_BOOTSTRAP=1 ;;
    stable*|beta*|"") ;;
    *) echo "cargo (fake rustup): toolchain '$toolchain' unavailable, Termux's stable is used." >&2 ;;
esac

# 1) find the sub-command (build, run, check...) past the global options
sub_i=-1; i=0
while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[$i]}" in
        -C|--config|-Z|--color) i=$((i+2)) ;;
        -*) i=$((i+1)) ;;
        *) sub_i=$i; break ;;
    esac
done

# 2) list the requested targets (--target X or --target=X)
targets=()
if [ "$sub_i" -ge 0 ]; then
    case "${args[$sub_i]}" in
        build|b|check|c|run|r|test|t|bench|doc|d|rustc|rustdoc|clippy|fix|zigbuild|xwin)
            j=$((sub_i+1))
            while [ "$j" -lt "${#args[@]}" ]; do
                a="${args[$j]}"
                case "$a" in
                    --) break ;;
                    --target) targets+=("${args[$((j+1))]:-}"); j=$((j+2)); continue ;;
                    --target=*) targets+=("${a#--target=}") ;;
                esac
                j=$((j+1))
            done
            if [ "${#targets[@]}" -eq 0 ] && [ -n "${CARGO_BUILD_TARGET:-}" ]; then
                targets=("$CARGO_BUILD_TARGET")
            fi
            ;;
    esac
fi

# 3) for each target: native? added by 'rustup target add'? unknown?
need_std=()
if [ "${#targets[@]}" -gt 0 ]; then
    sysroot="$("$REAL_RUSTC" --print sysroot)"
    for t in "${targets[@]}"; do
        [ -z "$t" ] && continue
        case "$t" in *.json) need_std+=("$t"); continue ;; esac     # custom target file
        std_ready "$sysroot/lib/rustlib/$t/lib" && continue          # already available (real rlibs)
        if grep -qxF "$t" "$BASE/targets" 2>/dev/null; then
            need_std+=("$t")
        else
            echo "error: target '$t' is not installed." >&2
            echo "       Run first:  rustup target add $t" >&2
            exit 1
        fi
    done
fi

# 3b) linker packs: `cargo build --target X` goes through the right wrapper command
ins=$((sub_i+1))
if [ "$sub_i" -ge 0 ] && [ "${#targets[@]}" -gt 0 ]; then
    t0="${targets[0]}"
    case "${args[$sub_i]}" in
        build|b)
            case "$t0" in
                *-unknown-linux-gnu|*-unknown-linux-musl|*-pc-windows-gnu*|*-apple-darwin)
                    if [ -e "$BASE/toolchains/zig.installed" ] && [ -x "$BASE/toolchains/bin/cargo-zigbuild" ]; then
                        args[$sub_i]=zigbuild
                    fi ;;
                *-pc-windows-msvc)
                    if [ -e "$BASE/toolchains/msvc.installed" ] && [ -x "$BASE/toolchains/bin/cargo-xwin" ]; then
                        args=("${args[@]:0:$sub_i}" xwin build "${args[@]:$((sub_i+1))}"); ins=$((sub_i+2))
                    fi ;;
            esac ;;
        xwin) ins=$((sub_i+2)) ;;      # cargo xwin build ...
    esac
    # a standard library built for an older compiler would be rejected: rebuild it
    for t in "${targets[@]}"; do
        if [ -f "$BASE/std-installed/$t" ] && [ "$(cat "$BASE/std-installed/$t")" != "$("$REAL_RUSTC" --version)" ]; then
            "$BASE/bin/rustup" target add "$t" || exit 1
        fi
        # Zig supplies the C start-up files and libraries itself
        if [ -e "$BASE/toolchains/zig.installed" ]; then
            case "$t" in
                *-linux-musl*|*-windows-gnu*)
                    v="CARGO_TARGET_$(printf '%s' "$t" | tr 'a-z-' 'A-Z_')_RUSTFLAGS"
                    [ -n "${!v:-}" ] || export "$v=-Clink-self-contained=no" ;;
            esac
        fi
    done
    # linkers provided by a pack (one executable per target)
    for t in "${targets[@]}"; do
        [ -x "$BASE/toolchains/linkers/$t" ] || continue
        v="CARGO_TARGET_$(printf '%s' "$t" | tr 'a-z-' 'A-Z_')_LINKER"
        [ -n "${!v:-}" ] || export "$v=$BASE/toolchains/linkers/$t"
    done
fi

# 3c) root: raise the build's priority so Android kills other apps first
if [ "$sub_i" -ge 0 ]; then
    oomadj="$(setting oom)"
    if [ -n "$oomadj" ]; then
        case "${args[$sub_i]}" in
            build|b|check|c|run|r|test|t|bench|rustc|clippy|install|zigbuild|xwin)
                su_bin="$(command -v su 2>/dev/null)"
                [ -n "$su_bin" ] && timeout 10 env -u LD_LIBRARY_PATH -u LD_PRELOAD "$su_bin" -c "echo $oomadj > /proc/$$/oom_score_adj" >/dev/null 2>&1 </dev/null
                ;;
        esac
    fi
fi

# 4) added targets: cargo rebuilds the standard library itself
if [ "${#need_std[@]}" -gt 0 ]; then
    crates="std,panic_abort"; extra=()
    for t in "${need_std[@]}"; do
        if RUSTC_BOOTSTRAP=1 "$REAL_RUSTC" --print cfg --target "$t" 2>/dev/null | grep -q '^target_os="none"'; then
            crates="core,alloc"                                     # no operating system: no std
            extra=("-Zbuild-std-features=compiler-builtins-mem")
        fi
    done
    export RUSTC_BOOTSTRAP=1
    args=("${args[@]:0:$ins}" "-Zbuild-std=$crates" "${extra[@]}" "${args[@]:$ins}")
fi

exec "$REAL_CARGO" "${args[@]}"
