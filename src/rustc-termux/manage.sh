manage_init() {
    [ -d "$BASE" ] || die "No fake rustup install found in $BASE. Run: $TPF_SCRIPT install"
    HOST="$("$REAL_RUSTC" -vV 2>/dev/null | sed -n 's/^host: //p')"
    conf_load_quiet
}

# Output lines of the checks (problems are shown on stdout, in order).
bad() { _ui_line "$C_ERR" '[ERROR]' "$*"; }

# Day-to-day commands: status, doctor, test, targets, packs, linker, jobs, nightly, log.

set_setting() { # key value
    local k="$1" v="$2" cur
    touch "$BASE/settings"
    if grep -q "^$k=" "$BASE/settings"; then
        sed -i "s|^$k=.*|$k=$v|" "$BASE/settings"
    else printf '%s=%s\n' "$k" "$v" >>"$BASE/settings"; fi
    cur="$(setting "$k")"
    [ "$cur" = "$v" ]
}

setting() { sed -n "s/^$1=//p" "$BASE/settings" 2>/dev/null | head -n1; }

sysroot_dir() { "$REAL_RUSTC" --print sysroot; }

# A target's standard library is usable only with real .rlib files (Termux's
# package ships some Android targets with .rmeta metadata only).
std_ready() { compgen -G "$1/libcore-*.rlib" >/dev/null 2>&1; }

has_pack() { [ -e "$TOOLS/$1.installed" ]; }

installed_packs() {
    local p
    for p in $PACK_ALL; do has_pack "$p" && printf '%s ' "$p"; done
}

# The list is read first: with "rustc | grep -q", grep leaves at the first match, rustc is
# killed by SIGPIPE and, under pipefail, the answer would randomly be "unknown target".
target_valid() {
    local list
    list="$("$REAL_RUSTC" --print target-list 2>/dev/null)" || return 1
    grep -qxF "$1" <<<"$list"
}

target_register() { grep -qxF "$1" "$TARGETS_FILE" 2>/dev/null || echo "$1" >>"$TARGETS_FILE"; }

target_unregister() {
    [ -f "$TARGETS_FILE" ] || return 0
    grep -vxF "$1" "$TARGETS_FILE" >"$TARGETS_FILE.tmp"
    mv -f "$TARGETS_FILE.tmp" "$TARGETS_FILE"
}

# NDK naming (same rules as the installer)
ndk_triple() { case "$1" in armv7-linux-androideabi) echo armv7a-linux-androideabi24 ;; *) echo "${1}24" ;; esac }

write_clang_linker() { # target triple [sysroot]
    local t="$1" triple="$2" sysroot="${3:-}" out="$TOOLS/linkers/$1" lib
    mkdir -p "$TOOLS/linkers"
    # rustc links with -nodefaultlibs: the compiler-rt builtins (for example
    # __emutls_get_address on 32-bit Android) must be appended explicitly.
    lib="$(clang --target="$triple" --rtlib=compiler-rt --print-libgcc-file-name 2>/dev/null)"
    [ -f "$lib" ] || lib=""
    {
        echo '#!/data/data/com.termux/files/usr/bin/bash'
        printf 'exec clang --target=%s' "$triple"
        [ -z "$sysroot" ] || printf ' --sysroot=%s -B%s/lib -L%s/lib' "$sysroot" "$sysroot" "$sysroot"
        printf ' -fuse-ld=lld "$@"'
        [ -z "$lib" ] || printf ' "%s"' "$lib"
        echo
    } >"$out"
    chmod +x "$out"
}

linker_paths_ok() { # every absolute path written in a linker script must exist
    local f="$1" p missing=0
    for p in $(grep -oE '/data/data/[^ "]+' "$f" | sed 's/^-[A-Za-z]*//' | sort -u); do
        [ -e "$p" ] || {
            echo "$p"
            missing=1
        }
    done
    return $missing
}

cmd_status() {
    manage_init
    echo -e "${C_INFO}== Toolchain ==${C_RESET}"
    echo "rustc   : $("$REAL_RUSTC" --version 2>&1)"
    echo "cargo   : $("$REAL_CARGO" --version 2>&1)"
    echo "host    : $HOST"
    echo "rustup  : $(command -v rustup || echo 'not in PATH')"
    echo "nightly : $([ "$(setting nightly)" = 1 ] && echo 'simulated (on)' || echo off)"
    echo "jobs    : $(setting jobs | sed 's/^$/no limit/')"
    echo -e "${C_INFO}== Targets ==${C_RESET}"
    local sr t st
    sr="$(sysroot_dir)"
    if [ -s "$TARGETS_FILE" ]; then
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            if std_ready "$sr/lib/rustlib/$t/lib"; then st="std ready"; else st="std built by cargo on first use"; fi
            printf '  %-34s %s%s\n' "$t" "$st" "$([ -x "$TOOLS/linkers/$t" ] && echo ', linker: yes')"
        done <"$TARGETS_FILE"
    else echo "  (none added)"; fi
    echo -e "${C_INFO}== Linker packs ==${C_RESET}"
    local p
    for p in $PACK_ALL; do printf '  %-6s %s\n' "$p" "$(has_pack "$p" && echo installed || echo '-')"; done
    echo -e "${C_INFO}== Root ==${C_RESET}"
    if [ "$(conf_get RT_USE_ROOT)" = 1 ]; then
        echo "tweaks  : $(conf_get RT_ROOT_TWEAKS)"
        echo "swap    : $(conf_get RT_SWAP_FILE)"
        echo "boot    : $(conf_get RT_BOOT_SCRIPT)"
    else echo "  root not used"; fi
    echo -e "${C_INFO}== Disk ==${C_RESET}"
    echo "free in \$HOME : $(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {printf "%d MB", $4/1024}')   Rust files: $(du -sh "$BASE" 2>/dev/null | cut -f1)"
}

cmd_linker() {
    manage_init
    local sub="${1:-list}"
    shift || true
    case "$sub" in
        list)
            local f t any=0 miss
            for f in "$TOOLS"/linkers/*; do
                [ -e "$f" ] || continue
                any=1
                t="$(basename "$f")"
                if [ ! -x "$f" ]; then
                    bad "$t: not executable"
                    continue
                fi
                if miss="$(linker_paths_ok "$f")"; then
                    ok "$t   ${C_DIM}$(tail -n1 "$f" | cut -c1-110)${C_RESET}"
                else bad "$t: missing: $(echo $miss | tr '\n' ' ')"; fi
            done
            [ "$any" = 1 ] || echo "No linker yet. Add one:  $TPF_SCRIPT linker add TARGET --ndk | --clang TRIPLE | --zig ZIGTARGET | -- CMD ARGS"
            ;;
        add)
            local t="${1:-}"
            shift || true
            [ -n "$t" ] || die "usage: linker add TARGET --ndk | --clang TRIPLE [--sysroot DIR] | --zig ZIGTARGET | -- CMD ARGS..."
            target_valid "$t" || die "unknown target: $t (see: rustup target list)"
            case "${1:-}" in
                --ndk)
                    local d="$PREFIX/$(ndk_dirname "$t")"
                    [ -d "$d" ] || die "No NDK sysroot at $d. Install it first:  pkg install ndk-multilib   (or: $TPF_SCRIPT packs add ndk)"
                    write_clang_linker "$t" "$(ndk_triple "$t")" "$d"
                    ;;
                --clang)
                    local triple="${2:-}" sysroot=""
                    [ -n "$triple" ] || die "--clang needs a triple (example: aarch64-linux-gnu)"
                    [ "${3:-}" = "--sysroot" ] && sysroot="${4:-}"
                    write_clang_linker "$t" "$triple" "$sysroot"
                    ;;
                --zig)
                    local zt="${2:-}" z
                    [ -n "$zt" ] || die "--zig needs a zig target (example: x86_64-linux-musl)"
                    z="$TOOLS/bin/zig"
                    [ -x "$z" ] || z="$(command -v zig || true)"
                    [ -n "$z" ] || die "zig not found (install the pack:  $TPF_SCRIPT packs add zig)"
                    mkdir -p "$TOOLS/linkers"
                    printf '#!/data/data/com.termux/files/usr/bin/bash\nexec "%s" cc -target %s "$@"\n' "$z" "$zt" >"$TOOLS/linkers/$t"
                    chmod +x "$TOOLS/linkers/$t"
                    ;;
                --)
                    shift
                    [ $# -gt 0 ] || die "give the command after --"
                    mkdir -p "$TOOLS/linkers"
                    {
                        echo '#!/data/data/com.termux/files/usr/bin/bash'
                        printf 'exec'
                        printf ' %q' "$@"
                        echo ' "$@"'
                    } >"$TOOLS/linkers/$t"
                    chmod +x "$TOOLS/linkers/$t"
                    ;;
                *) die "choose how to link: --ndk | --clang TRIPLE | --zig ZIGTARGET | -- CMD ARGS" ;;
            esac
            target_register "$t"
            ok "Linker for $t: $TOOLS/linkers/$t"
            info "The standard library for $t is built at the first build (or now:  rustup target add $t)."
            info "Check it:  $TPF_SCRIPT linker test $t"
            ;;
        remove)
            local t="${1:-}"
            [ -n "$t" ] || die "usage: linker remove TARGET"
            [ -e "$TOOLS/linkers/$t" ] || die "No linker for $t."
            rm -f "$TOOLS/linkers/$t"
            ok "Linker for $t removed (the target stays registered; remove it with: rustup target remove $t)."
            ;;
        test)
            local t="${1:-}" dir bin magic got
            [ -n "$t" ] || die "usage: linker test TARGET"
            dir="$(mktemp -d "$HOME/.rust-termux-test.XXXXXX")" || die "cannot create a test directory"
            info "Building a hello-world for $t (first time: the standard library is built, several minutes)..."
            if (cd "$dir" && env -u CARGO_TARGET_DIR cargo new --vcs none --quiet hello && cd hello && env -u CARGO_TARGET_DIR cargo build --quiet --target "$t"); then
                bin="$dir/hello/target/$t/debug/hello"
                magic=ELF
                case "$t" in *windows*)
                    bin="$bin.exe"
                    magic=MZ
                    ;;
                *wasm*)
                    bin="$dir/hello/target/$t/debug/hello.wasm"
                    magic=WASM
                    ;;
                esac
                case "$magic" in
                    ELF) got="$(head -c4 "$bin" 2>/dev/null | tail -c3)" ;;
                    MZ) got="$(head -c2 "$bin" 2>/dev/null)" ;;
                    WASM)
                        got="$(head -c4 "$bin" 2>/dev/null | tail -c3)"
                        [ "$got" = "asm" ] && got=WASM
                        ;;
                esac
                if [ "$got" = "$magic" ]; then
                    ok "$t: build works ($magic file)"
                    rm -rf "$dir"
                    return 0
                fi
                bad "$t: the build produced no valid $magic file"
            else bad "$t: the build failed (cargo output above)"; fi
            rm -rf "$dir"
            return 1
            ;;
        *) die "usage: linker list | add | remove | test" ;;
    esac
}

cmd_targets() {
    manage_init
    local sub="${1:-list}"
    shift || true
    case "$sub" in
        list) "$BASE/bin/rustup" target list --installed ;;
        add | remove)
            [ $# -gt 0 ] || die "usage: targets $sub TARGET..."
            "$BASE/bin/rustup" target "$sub" "$@"
            ;;
        *) die "usage: targets [list|add T...|remove T...]" ;;
    esac
}

pack_summary() {
    case "$1" in
        zig) echo "cross-link Linux (gnu/musl) and Windows-gnu with Zig + cargo-zigbuild" ;;
        msvc) echo "Windows MSVC targets with cargo-xwin (downloads the Windows SDK, Microsoft licence)" ;;
        ndk) echo "Android programs for the OTHER CPU families (armv7, i686, x86_64) with ndk-multilib" ;;
        wasm) echo "WebAssembly tools: binaryen (wasm-opt), wabt, wasm-bindgen-cli (compiled, 5-15 min)" ;;
    esac
}

cmd_packs() {
    manage_init
    local sub="${1:-list}"
    shift || true
    case "$sub" in
        list)
            local p
            for p in $PACK_ALL; do
                printf '  %-5s %-10s %s\n' "$p" "$(has_pack "$p" && echo installed || echo '-')" "$(pack_summary "$p")"
            done
            ;;
        add)
            [ $# -gt 0 ] || die "usage: packs add NAME... (among: $PACK_ALL)"
            packs_add "$@"
            ;;
        remove)
            [ $# -gt 0 ] || die "usage: packs remove NAME..."
            local p t c
            for p in "$@"; do
                pack_known "$p" || die "unknown pack: $p"
                has_pack "$p" || {
                    warn "$p is not installed."
                    continue
                }
                case "$p" in
                    zig)
                        for t in x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-pc-windows-gnu; do
                            target_unregister "$t"
                            rm -f "$TOOLS/linkers/$t"
                        done
                        env RUSTC="$REAL_RUSTC" "$REAL_CARGO" uninstall --root "$TOOLS" cargo-zigbuild >/dev/null 2>&1
                        rm -rf "$TOOLS/zig-dist" "$TOOLS/bin/zig" "$BASE/zig-cache" "$BASE/zigbuild-cache"
                        ;;
                    msvc)
                        for t in x86_64-pc-windows-msvc aarch64-pc-windows-msvc; do
                            target_unregister "$t"
                            rm -f "$TOOLS/linkers/$t"
                        done
                        env RUSTC="$REAL_RUSTC" "$REAL_CARGO" uninstall --root "$TOOLS" cargo-xwin >/dev/null 2>&1
                        rm -rf "$BASE/xwin-cache"
                        ;;
                    ndk) for t in armv7-linux-androideabi i686-linux-android x86_64-linux-android aarch64-linux-android; do
                        [ "$t" = "$HOST" ] && continue
                        target_unregister "$t"
                        rm -f "$TOOLS/linkers/$t"
                    done ;;
                    wasm) env RUSTC="$REAL_RUSTC" "$REAL_CARGO" uninstall --root "$TOOLS" wasm-bindgen-cli >/dev/null 2>&1 ;;
                esac
                rm -f "$TOOLS/$p.installed"
                ok "Pack removed: $p"
            done
            # keep the saved list in step with what is on disk
            if [ -f "$CONF" ]; then
                local now
                now="$(installed_packs)"
                now="${now% }"
                conf_set RT_PACKS "$now"
            fi
            info "Termux packages (ndk-multilib, binaryen, wabt, ...) were kept; remove them with pkg if you want."
            ;;
        *) die "usage: packs list | add NAME... | remove NAME..." ;;
    esac
}

cmd_jobs() {
    manage_init
    case "${1:-}" in
        off | 0 | "") set_setting jobs "" && ok "No limit on parallel build jobs." ;;
        *[!0-9]*) die "usage: jobs N|off" ;;
        *) set_setting jobs "$1" && ok "Parallel build jobs limited to $1 (too many can make Android kill Termux)." ;;
    esac
    [ -f "$CONF" ] && conf_set RT_JOBS "$(setting jobs)"
}

cmd_nightly() {
    manage_init
    case "${1:-}" in
        on) set_setting nightly 1 && ok "Simulated nightly mode enabled (cargo +nightly)." ;;
        off) set_setting nightly 0 && ok "Simulated nightly mode disabled." ;;
        *) die "usage: nightly on|off" ;;
    esac
    [ -f "$CONF" ] && conf_set RT_NIGHTLY "$(setting nightly)"
}

cmd_test() {
    manage_init
    local dir out
    dir="$(mktemp -d "$HOME/.rust-termux-test.XXXXXX")" || die "cannot create a test directory"
    if (cd "$dir" && env -u CARGO_TARGET_DIR cargo new --vcs none --quiet hello && cd hello && env -u CARGO_TARGET_DIR cargo run --quiet) >"$dir/out.log" 2>&1; then
        out="$(tail -n1 "$dir/out.log")"
        ok "Native build and run work: $out"
        rm -rf "$dir"
        return 0
    fi
    bad "Native build failed:"
    tail -n 12 "$dir/out.log"
    rm -rf "$dir"
    return 1
}

d_ok() {
    N_OK=$((N_OK + 1))
    ok "$*"
}

d_warn() {
    N_WARN=$((N_WARN + 1))
    warn "$*"
}

d_bad() {
    N_BAD=$((N_BAD + 1))
    bad "$*"
}

d_fixed() {
    N_FIXED=$((N_FIXED + 1))
    echo -e "      ${C_OK}-> fixed:${C_RESET} $*"
}

d_hint() { echo -e "      ${C_DIM}-> $*${C_RESET}"; }

cmd_doctor() {
    manage_init
    N_OK=0 N_WARN=0 N_BAD=0 N_FIXED=0
    local fix=0 full=0 a
    for a in "$@"; do case "$a" in --fix) fix=1 ;; --full) full=1 ;; *) die "usage: doctor [--fix] [--full]" ;; esac done
    local sr t f p ver

    echo -e "${C_INFO}== Compiler ==${C_RESET}"
    if ver="$("$REAL_RUSTC" --version 2>&1)"; then d_ok "rustc: $ver"; else
        d_bad "rustc does not run: $ver"
        d_hint "pkg reinstall rust"
    fi
    if "$REAL_CARGO" --version >/dev/null 2>&1; then d_ok "cargo runs"; else d_bad "cargo does not run"; fi
    for t in rustup cargo rustc; do
        if [ "$(command -v "$t")" = "$BASE/bin/$t" ]; then
            d_ok "'$t' resolves to the fake one"
        else
            d_warn "'$t' resolves to $(command -v "$t" || echo nothing)"
            d_hint "open a new Termux session or: source ~/.bashrc"
        fi
    done
    for t in clang lld make; do have "$t" && d_ok "$t present" || {
        d_bad "$t missing"
        d_hint "pkg install $t"
        if [ "$fix" = 1 ] && pkg install -y "$t" >/dev/null 2>&1; then d_fixed "installed $t"; fi
    }; done
    if [ ! -e "$BASE/bin/rust-lld" ] && have lld; then
        d_warn "rust-lld link missing (WebAssembly linking)"
        [ "$fix" = 1 ] && ln -sf "$(command -v lld)" "$BASE/bin/rust-lld" && d_fixed "rust-lld -> lld"
    fi

    echo -e "${C_INFO}== Rust sources ==${C_RESET}"
    sr="$(sysroot_dir)"
    if [ -d "$sr/lib/rustlib/src/rust/library" ] || [ -d "$sr/lib/rustlib/src" ]; then
        if [ "$(cat "$BASE/rust-src-version" 2>/dev/null)" = "$("$REAL_RUSTC" --version | awk '{print $2}')" ]; then
            d_ok "rust-src matches the compiler"
        else
            d_warn "rust-src was made for another compiler version"
            d_hint "$TPF_SCRIPT reinstall   (rebuilds everything cleanly)"
        fi
    else
        d_bad "Rust sources missing (needed to build the standard library of extra targets)"
        d_hint "$TPF_SCRIPT reinstall"
    fi

    echo -e "${C_INFO}== Targets ==${C_RESET}"
    if [ -s "$TARGETS_FILE" ]; then
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            if std_ready "$sr/lib/rustlib/$t/lib"; then
                if [ -f "$BASE/std-installed/$t" ] && [ "$(cat "$BASE/std-installed/$t")" != "$("$REAL_RUSTC" --version)" ]; then
                    d_warn "$t: standard library built by another compiler version"
                    if [ "$fix" = 1 ] && "$BASE/bin/rustup" target add "$t" >/dev/null 2>&1; then d_fixed "rebuilt std for $t"; else d_hint "rustup target add $t"; fi
                else d_ok "$t: standard library ready"; fi
            elif [ -d "$sr/lib/rustlib/$t/lib" ]; then
                d_warn "$t: only .rmeta metadata files from the Termux package (no .rlib): the standard library is built at the first build (several minutes)"
                if [ "$fix" = 1 ]; then
                    rm -f "$BASE/std-installed/$t"
                    if "$BASE/bin/rustup" target add "$t" >/dev/null 2>&1; then d_fixed "std built for $t"; else d_hint "rustup target add $t  (see the output)"; fi
                else d_hint "build it now with: rustup target add $t   (or: doctor --fix). Not tested for this target yet."; fi
            else d_ok "$t: registered, standard library built at the first build"; fi
            if [ -e "$TOOLS/linkers/$t" ]; then :; else
                case "$t" in
                    "$HOST" | wasm32-* | *-none-* | *-none) ;; # bare metal and wasm: rustc uses lld alone
                    *-pc-windows-msvc) has_pack msvc || {
                        d_warn "$t: no linker (msvc pack not installed)"
                        d_hint "$TPF_SCRIPT packs add msvc"
                    } ;;
                    *-linux-gnu | *-linux-musl | *-windows-gnu) has_pack zig || {
                        d_warn "$t: no linker (zig pack not installed)"
                        d_hint "$TPF_SCRIPT packs add zig"
                    } ;;
                    *)
                        d_warn "$t: no linker registered (a link may use the wrong one)"
                        d_hint "$TPF_SCRIPT linker add $t ..."
                        ;;
                esac
            fi
        done <"$TARGETS_FILE"
    else d_ok "no extra target registered"; fi

    echo -e "${C_INFO}== Linkers ==${C_RESET}"
    for f in "$TOOLS"/linkers/*; do
        [ -e "$f" ] || continue
        t="$(basename "$f")"
        if [ ! -x "$f" ]; then
            d_bad "$t: linker not executable"
            [ "$fix" = 1 ] && chmod +x "$f" && d_fixed "chmod +x $t"
            continue
        fi
        if miss="$(linker_paths_ok "$f")"; then
            d_ok "$t: linker files exist"
        else
            d_bad "$t: linker refers to missing files: $(echo $miss | tr '\n' ' ')"
            case "$t" in
                armv7-linux-androideabi | i686-linux-android | x86_64-linux-android | aarch64-linux-android)
                    if [ "$fix" = 1 ] && [ -d "$PREFIX/$(ndk_dirname "$t")" ]; then
                        write_clang_linker "$t" "$(ndk_triple "$t")" "$PREFIX/$(ndk_dirname "$t")" && d_fixed "linker for $t regenerated"
                    else d_hint "pkg install ndk-multilib, then doctor --fix"; fi
                    ;;
                *) d_hint "$TPF_SCRIPT packs add <pack> or $TPF_SCRIPT linker add $t ..." ;;
            esac
        fi
    done

    echo -e "${C_INFO}== Packs ==${C_RESET}"
    for p in $PACK_ALL; do
        has_pack "$p" || continue
        case "$p" in
            zig) { [ -x "$TOOLS/bin/zig" ] || have zig; } && [ -x "$TOOLS/bin/cargo-zigbuild" ] && d_ok "zig: zig and cargo-zigbuild present" || {
                d_bad "zig: pack incomplete"
                d_hint "$TPF_SCRIPT packs remove zig && $TPF_SCRIPT packs add zig"
            } ;;
            msvc) [ -x "$TOOLS/bin/cargo-xwin" ] && [ -d "$BASE/xwin-cache" ] && d_ok "msvc: cargo-xwin and SDK cache present" || {
                d_bad "msvc: pack incomplete"
                d_hint "$TPF_SCRIPT packs remove msvc && $TPF_SCRIPT packs add msvc"
            } ;;
            ndk) have clang && dpkg -s ndk-multilib >/dev/null 2>&1 && d_ok "ndk: ndk-multilib installed" || {
                d_bad "ndk: ndk-multilib missing"
                d_hint "pkg install ndk-multilib"
            } ;;
            wasm) have wasm-opt && have wasm2wat && [ -x "$TOOLS/bin/wasm-bindgen" ] && d_ok "wasm: wasm-opt, wasm2wat, wasm-bindgen present" || {
                d_bad "wasm: pack incomplete"
                d_hint "$TPF_SCRIPT packs remove wasm && $TPF_SCRIPT packs add wasm"
            } ;;
        esac
    done
    [ -n "$(installed_packs)" ] || d_ok "no pack installed (optional)"

    echo -e "${C_INFO}== Bare metal and LTO ==${C_RESET}"
    local c any_std=0
    for f in "$BASE"/std-installed/*; do
        [ -f "$f" ] || continue
        any_std=1
        t="$(basename "$f")"
        c="$(ls "$sr/lib/rustlib/$t/lib"/libcore-*.rlib 2>/dev/null | head -n1)"
        [ -n "$c" ] || continue
        if grep -q llvmbc "$c" 2>/dev/null; then
            d_ok "$t: standard library carries LLVM bitcode (lto = true works)"
        else
            d_warn "$t: standard library built without LLVM bitcode: projects with 'lto = true' fail (Can't find section .llvmbc)"
            if [ "$fix" = 1 ]; then
                rm -rf "$sr/lib/rustlib/$t" "$f"
                if "$BASE/bin/rustup" target add "$t" >/dev/null 2>&1; then d_fixed "std rebuilt for $t with bitcode"; else d_hint "rustup target add $t (see the output)"; fi
            else d_hint "doctor --fix rebuilds it (a few minutes)"; fi
        fi
    done
    [ "$any_std" = 1 ] || d_ok "no standard library built by the fake rustup yet"
    if [ -x "$BASE/bin/arm-none-eabi-gcc" ] && [ -x "$BASE/bin/arm-none-eabi-ar" ]; then
        d_ok "arm-none-eabi-gcc / ar available (clang + llvm)"
    else
        d_warn "arm-none-eabi-* tools missing (build scripts of embedded projects expect them)"
        d_hint "$TPF_SCRIPT reinstall"
    fi

    echo -e "${C_INFO}== Root and system ==${C_RESET}"
    if [ "$(conf_get RT_USE_ROOT)" = 1 ]; then
        local sw
        sw="$(conf_get RT_SWAP_FILE)"
        if [ -n "$sw" ]; then
            if su -c "grep -q '${sw##*/}' /proc/swaps" 2>/dev/null; then
                d_ok "swap file active: $sw"
            else
                d_bad "swap file not active: $sw"
                if [ "$fix" = 1 ] && su -c "[ -f $sw ] && swapon $sw" >/dev/null 2>&1; then d_fixed "swapon $sw"; else d_hint "su -c 'swapon $sw'  (or doctor --fix)"; fi
            fi
        fi
        local bs
        bs="$(conf_get RT_BOOT_SCRIPT)"
        if [ -n "$bs" ]; then su -c "[ -f $bs ]" 2>/dev/null && d_ok "boot script present: $bs" || {
            d_bad "boot script missing: $bs"
            d_hint "$TPF_SCRIPT reinstall (root tweaks are asked again)"
        }; fi
        local w
        w="$(su -c 'cat /proc/sys/fs/inotify/max_user_watches' 2>/dev/null)"
        [ -n "$w" ] && { [ "$w" -ge 65536 ] && d_ok "inotify watches: $w" || d_warn "inotify watches only $w"; }
    else d_ok "root not used"; fi
    local free
    free="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}')"
    case "$free" in '' | *[!0-9]*) ;; *) [ "$free" -ge 1500 ] && d_ok "free space: ${free} MB" || d_warn "low free space: ${free} MB (standard libraries and linkers need room)" ;; esac
    [ -f "$CONF" ] && d_ok "settings file: $CONF" || d_warn "settings file missing: $CONF"

    if [ "$full" = 1 ]; then
        echo -e "${C_INFO}== Full test (compiles programs) ==${C_RESET}"
        cmd_test && d_ok "native build" || d_bad "native build"
        for t in $(cat "$TARGETS_FILE" 2>/dev/null); do
            if cmd_linker test "$t" >/dev/null 2>&1; then d_ok "$t builds"; else
                d_bad "$t does not build"
                d_hint "$TPF_SCRIPT linker test $t   (shows the error)"
            fi
        done
    else
        echo -e "${C_DIM}(add --full to also compile a program for every target; it can take minutes)${C_RESET}"
    fi

    echo
    echo -e "Result: ${C_OK}$N_OK ok${C_RESET}, ${C_WARN}$N_WARN warning(s)${C_RESET}, ${C_ERR}$N_BAD problem(s)${C_RESET}$([ "$fix" = 1 ] && echo ", $N_FIXED fixed")"
    [ "$N_BAD" -eq 0 ] || {
        [ "$fix" = 1 ] || echo "Try:  $TPF_SCRIPT doctor --fix"
        return 1
    }
    return 0
}

cmd_log() {
    local name="${1:-}" n="${2:-60}"
    [ -d "$LOG_DIR" ] || die "No install logs ($LOG_DIR)."
    if [ -z "$name" ]; then
        ls -1 "$LOG_DIR" | sed 's/\.log$//'
        echo "-> $TPF_SCRIPT log NAME [lines]"
        return 0
    fi
    [ -f "$LOG_DIR/$name.log" ] || [ -f "$LOG_DIR/$name" ] || die "No such log: $name"
    tail -n "$n" "$LOG_DIR/$name.log" 2>/dev/null || tail -n "$n" "$LOG_DIR/$name"
}
