# Linker packs: what is needed to LINK programs for other platforms.

# ---------------------------------------------------------------------------
# Toolchain packs: what is needed to LINK programs for platforms other than the
# phone. Each pack is installed (compiled from source when needed), then checked
# by really building a program for one of its targets; a pack that fails the
# check is removed again, so nothing half-working is left.
# Everything lives in ~/.rustup-fake/toolchains (removed with the fake rustup).
# ---------------------------------------------------------------------------
TOOLS="$BASE/toolchains"
PACK_ALL="zig msvc ndk wasm"
PACKS_OK="" # packs installed AND verified in this run
PK_I=1
PK_N=1

pack_known() {
    case " $PACK_ALL " in *" $1 "*) return 0 ;; esac
    return 1
}

pack_describe() {
    case "$1" in
        zig)
            plain "   Zig + cargo-zigbuild: Linux (glibc and musl) and Windows (-gnu) programs from"
            plain "   the phone, macOS for pure-Rust code. Zig carries its own C libraries."
            plain "   Cost: the zig package (or the official tarball) + compiling cargo-zigbuild"
            plain "         (about 5-15 min), then one check build."
            ;;
        msvc)
            plain "   cargo-xwin: Windows MSVC programs (x86_64 / aarch64 *-pc-windows-msvc), linked"
            plain "   with clang + lld against the official Windows SDK/CRT, downloaded from Microsoft."
            plain "   Cost: compiling cargo-xwin (about 10-20 min) + a download of roughly 1 GB"
            plain "         (kept in ~/.rustup-fake/xwin-cache) + one check build."
            plain "   Requires accepting Microsoft's licence (asked separately)."
            ;;
        ndk)
            plain "   Termux's NDK multilib: Android programs for the OTHER CPU families"
            plain "   (armv7, x86, x86_64) linked with Termux's clang. EXPERIMENTAL: whether it"
            plain "   works depends on the files that package ships; the check build decides and"
            plain "   the pack is removed again if it fails."
            ;;
        wasm)
            plain "   WebAssembly tools: binaryen (wasm-opt), wabt (wasm2wat, ...), wasm-bindgen-cli."
            plain "   Cost: wasm-bindgen-cli is compiled from source (about 5-15 min)."
            ;;
    esac
}

# Targets registered (rustup target add) by each pack
pack_targets() {
    case "$1" in
        zig) echo "x86_64-unknown-linux-musl aarch64-unknown-linux-musl x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-pc-windows-gnu" ;;
        msvc) echo "x86_64-pc-windows-msvc aarch64-pc-windows-msvc" ;;
        ndk)
            local t
            for t in armv7-linux-androideabi i686-linux-android x86_64-linux-android aarch64-linux-android; do
                [ "$t" = "$HOST" ] || printf '%s ' "$t"
            done
            echo
            ;;
        *) echo "" ;;
    esac
}

pk_pct() { pct_at $(((PK_I - 1) * 10 + $1)) $((PK_N * 10)); } # step 1..10 of the current pack

# One Termux package for a pack. Remembers it if the installer is the one adding it.
pack_apt_one() { # pkg step [required]
    local p="$1" step="$2" had=1
    dpkg_installed "$p" || had=0
    if run_logged "$(pk_pct "$step")" 20 "$LOG_DIR/pack_apt_$p.log" apt-get "${APT_OPTS[@]}" install "$p"; then
        [ "$had" = 1 ] || PKGS_ADDED="${PKGS_ADDED:+$PKGS_ADDED }$p"
        ok "Package installed: $p"
        return 0
    fi
    return 1
}

pack_cargo_install() { # crate step expected_seconds [extra cargo install options]
    local crate="$1" step="$2" exp="$3"
    shift 3
    if run_logged "$(pk_pct "$step")" "$exp" "$LOG_DIR/pack_cargo_$crate.log" \
        env RUSTC="$REAL_RUSTC" ${JOBS:+CARGO_BUILD_JOBS=$JOBS} "$REAL_CARGO" install --locked --root "$TOOLS" "$@" "$crate"; then
        ok "Compiled and installed: $crate"
        return 0
    fi
    denied "Could not build $crate (see $LOG_DIR/pack_cargo_$crate.log):"
    tail -n 5 "$LOG_DIR/pack_cargo_$crate.log" 2>/dev/null | while IFS= read -r l; do plain "    $l"; done
    return 1
}

pack_add_targets() { # pack
    # Registered only: the standard library of these targets is built by cargo
    # at the first build (so the install does not build five of them for nothing).
    local t
    for t in $(pack_targets "$1"); do
        "$REAL_RUSTC" --print target-list | grep -qxF "$t" || continue
        grep -qxF "$t" "$BASE/targets" 2>/dev/null || echo "$t" >>"$BASE/targets"
    done
}

# Builds a hello-world for TARGET through the fake cargo and checks the file type.
#   pack_verify NAME TARGET magic(ELF|MZ) STEP EXPECTED_SECONDS
pack_verify() {
    local name="$1" t="$2" magic="$3" step="$4" exp="$5" bin got
    TEST_DIR="$(mktemp -d "$HOME/.rust-termux-test.XXXXXX")" || {
        warn "Cannot create a test directory."
        return 1
    }
    bin="$TEST_DIR/hello/target/$t/debug/hello"
    [ "$magic" = MZ ] && bin="$bin.exe"
    info "Check build for $t: the standard library is compiled, this takes several minutes."
    if run_logged "$(pk_pct "$step")" "$exp" "$LOG_DIR/pack_check_$name.log" \
        bash -c 'cd "$1" && env -u CARGO_TARGET_DIR cargo new --vcs none --quiet hello && cd hello && env -u CARGO_TARGET_DIR cargo build --quiet --target "$2"' _ "$TEST_DIR" "$t"; then
        if [ "$magic" = ELF ]; then got="$(head -c4 "$bin" 2>/dev/null | tail -c3)"; else got="$(head -c2 "$bin" 2>/dev/null)"; fi
        if [ "$got" = "$magic" ]; then
            ok "Check build passed: $t -> $(basename "$bin") ($magic)"
            rm -rf "$TEST_DIR"
            TEST_DIR=""
            return 0
        fi
        denied "The build for $t produced no valid $magic file."
    else
        denied "The check build for $t failed (see $LOG_DIR/pack_check_$name.log):"
        tail -n 8 "$LOG_DIR/pack_check_$name.log" 2>/dev/null | while IFS= read -r l; do plain "    $l"; done
    fi
    rm -rf "$TEST_DIR"
    TEST_DIR=""
    return 1
}

# A pack that failed its check leaves nothing behind.
pack_rollback() {
    local name="$1" t c
    for t in $(pack_targets "$name"); do
        grep -vxF "$t" "$BASE/targets" >"$BASE/targets.tmp" 2>/dev/null
        mv -f "$BASE/targets.tmp" "$BASE/targets" 2>/dev/null
    done
    case "$name" in
        zig) c="cargo-zigbuild" ;; msvc) c="cargo-xwin" ;; wasm) c="wasm-bindgen-cli" ;; *) c="" ;;
    esac
    [ -n "$c" ] && env RUSTC="$REAL_RUSTC" "$REAL_CARGO" uninstall --root "$TOOLS" "$c" >/dev/null 2>&1
    case "$name" in
        zig) rm -rf "$TOOLS/zig-dist" "$TOOLS/bin/zig" "$BASE/zig-cache" "$BASE/zigbuild-cache" ;;
        msvc) rm -rf "$BASE/xwin-cache" ;;
        ndk) rm -f "$TOOLS"/linkers/* ;;
    esac
    rm -f "$TOOLS/$name.installed"
}

# ---------------------------------------------------------------- zig ---------
# Termux's own package first; if it does not exist on this mirror, the official
# static tarball (checksum verified) is used.
pack_zig_tarball() {
    local plat idx ver url sum tmp got
    have jq || pack_apt_one jq 2 || {
        warn "jq is missing: cannot read ziglang.org's download index."
        return 1
    }
    case "$(uname -m)" in aarch64 | arm64) plat=aarch64-linux ;; x86_64) plat=x86_64-linux ;; armv7l | armv8l) plat=arm-linux ;; *) return 1 ;; esac
    tmp="$(mktemp -d)" || return 1
    if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp/index.json" https://ziglang.org/download/index.json; then
        rm -rf "$tmp"
        warn "ziglang.org is unreachable."
        return 1
    fi
    ver="$(jq -r 'keys[]' "$tmp/index.json" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)"
    url="$(jq -r --arg v "$ver" --arg p "$plat" '.[$v][$p].tarball // empty' "$tmp/index.json" 2>/dev/null)"
    sum="$(jq -r --arg v "$ver" --arg p "$plat" '.[$v][$p].shasum // empty' "$tmp/index.json" 2>/dev/null)"
    if [ -z "$ver" ] || [ -z "$url" ] || [ -z "$sum" ]; then
        rm -rf "$tmp"
        warn "No Zig build listed for $plat."
        return 1
    fi
    info "Downloading Zig $ver ($plat)..."
    if ! run_logged "$(pk_pct 3)" 60 "$LOG_DIR/pack_zig_download.log" curl -fL --retry 3 --connect-timeout 20 -o "$tmp/zig.tar.xz" "$url"; then
        rm -rf "$tmp"
        warn "Zig download failed."
        return 1
    fi
    got="$(sha256sum "$tmp/zig.tar.xz" | awk '{print $1}')"
    if [ "$got" != "$sum" ]; then
        rm -rf "$tmp"
        denied "Zig checksum mismatch: download discarded."
        return 1
    fi
    ok "Zig checksum verified"
    mkdir -p "$TOOLS/zig-dist" "$TOOLS/bin"
    if ! tar -xJf "$tmp/zig.tar.xz" -C "$TOOLS/zig-dist" --strip-components=1; then
        rm -rf "$tmp" "$TOOLS/zig-dist"
        return 1
    fi
    ln -sf "$TOOLS/zig-dist/zig" "$TOOLS/bin/zig"
    rm -rf "$tmp"
    "$TOOLS/bin/zig" version >/dev/null 2>&1 || {
        rm -rf "$TOOLS/zig-dist" "$TOOLS/bin/zig"
        denied "The Zig binary does not run on this device."
        return 1
    }
    return 0
}

pack_install_zig() {
    local v
    export ZIG_GLOBAL_CACHE_DIR="$BASE/zig-cache" CARGO_ZIGBUILD_CACHE_DIR="$BASE/zigbuild-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$CARGO_ZIGBUILD_CACHE_DIR"
    if ! have zig; then
        pack_apt_one zig 2 || {
            info "No 'zig' package here: trying the official tarball."
            pack_zig_tarball || return 1
        }
    fi
    v="$(PATH="$TOOLS/bin:$PATH" zig version 2>/dev/null)" || {
        denied "zig is installed but does not run."
        return 1
    }
    ok "Zig works: $v"
    pack_cargo_install cargo-zigbuild 7 900 || return 1
    : >"$TOOLS/zig.installed"
    pack_add_targets zig
    pack_verify zig x86_64-unknown-linux-musl ELF 9 300 || return 1
    return 0
}

# ---------------------------------------------------------------- msvc --------
pack_install_msvc() {
    local p tool
    for p in clang lld openssl; do dpkg_installed "$p" || pack_apt_one "$p" 1 || {
        denied "Package '$p' is needed."
        return 1
    }; done
    pack_apt_one llvm 2 || warn "Package 'llvm' not installed: llvm-lib may be missing."
    mkdir -p "$TOOLS/bin"
    # clang and lld choose their personality from their file name
    have clang-cl || ln -sf "$(command -v clang)" "$TOOLS/bin/clang-cl"
    have lld-link || ln -sf "$(command -v lld)" "$TOOLS/bin/lld-link"
    if ! have llvm-lib; then have llvm-ar && ln -sf "$(command -v llvm-ar)" "$TOOLS/bin/llvm-lib"; fi
    for tool in clang-cl lld-link; do
        PATH="$TOOLS/bin:$PATH" command -v "$tool" >/dev/null 2>&1 && ok "Found: $tool" || {
            denied "$tool is missing."
            return 1
        }
    done
    # cargo-xwin's default TLS (rustls-platform-verifier) panics on Android: use the system OpenSSL.
    pack_cargo_install cargo-xwin 6 1200 --no-default-features --features native-tls ||
        {
            warn "native-tls build failed: trying the default features."
            pack_cargo_install cargo-xwin 6 1200 || return 1
        }
    export XWIN_CACHE_DIR="$BASE/xwin-cache"
    mkdir -p "$XWIN_CACHE_DIR"
    info "Downloading the Windows SDK and CRT from Microsoft (about 1 GB)..."
    if run_logged "$(pk_pct 8)" 300 "$LOG_DIR/pack_xwin_cache.log" \
        env PATH="$TOOLS/bin:$PATH" XWIN_CACHE_DIR="$XWIN_CACHE_DIR" RUSTC="$REAL_RUSTC" "$TOOLS/bin/cargo-xwin" xwin cache xwin; then
        ok "Windows SDK and CRT downloaded"
    else
        warn "SDK pre-download failed (see $LOG_DIR/pack_xwin_cache.log): it will be retried at the first build."
    fi
    : >"$TOOLS/msvc.installed"
    pack_add_targets msvc
    pack_verify msvc x86_64-pc-windows-msvc MZ 10 600 || return 1
    return 0
}

# ---------------------------------------------------------------- ndk ---------
ndk_clang_triple() {
    case "$1" in
        armv7-linux-androideabi) echo armv7a-linux-androideabi24 ;;
        *) echo "${1}24" ;;
    esac
}
ndk_dirname() {
    case "$1" in armv7-linux-androideabi) echo arm-linux-androideabi ;; *) echo "$1" ;; esac
}
pack_install_ndk() {
    local t d n=0 first=""
    pack_apt_one ndk-multilib 3 || {
        denied "The 'ndk-multilib' package is not available on this mirror."
        return 1
    }
    dpkg_installed ndk-sysroot || pack_apt_one ndk-sysroot 4 || true
    mkdir -p "$TOOLS/linkers"
    for t in $(pack_targets ndk); do
        d="$PREFIX/$(ndk_dirname "$t")"
        if [ ! -d "$d/lib" ] && [ ! -d "$d" ]; then
            warn "No libraries found for $t (expected $d)."
            continue
        fi
        {
            echo '#!/data/data/com.termux/files/usr/bin/bash'
            # rustc links with -nodefaultlibs: clang would not add the compiler-rt
            # builtins, which hold __emutls_get_address (std on 32-bit Android
            # uses emulated TLS). They are appended explicitly, after the objects.
            echo "exec clang --target=$(ndk_clang_triple "$t") --sysroot=$d -B$d/lib -L$d/lib -fuse-ld=lld \"\$@\" \"$(clang --target="$(ndk_clang_triple "$t")" --rtlib=compiler-rt --print-libgcc-file-name)\""
        } >"$TOOLS/linkers/$t"
        chmod +x "$TOOLS/linkers/$t"
        ok "Linker created for $t"
        n=$((n + 1))
        [ -n "$first" ] || first="$t"
    done
    [ "$n" -gt 0 ] || {
        denied "ndk-multilib installed nothing usable for cross-linking."
        return 1
    }
    : >"$TOOLS/ndk.installed"
    pack_add_targets ndk
    pack_verify ndk "$first" ELF 9 300 || return 1
    return 0
}

# ---------------------------------------------------------------- wasm --------
pack_install_wasm() {
    local good=0
    pack_apt_one binaryen 2 || warn "Package 'binaryen' (wasm-opt) is not available."
    pack_apt_one wabt 3 || warn "Package 'wabt' is not available."
    pack_cargo_install wasm-bindgen-cli 8 900 || return 1
    export PATH="$TOOLS/bin:$PATH"
    if "$TOOLS/bin/wasm-bindgen" --version >/dev/null 2>&1; then
        ok "wasm-bindgen: $("$TOOLS/bin/wasm-bindgen" --version 2>/dev/null)"
        good=1
    fi
    have wasm-opt && ok "wasm-opt: $(wasm-opt --version 2>/dev/null | head -n1)"
    [ "$good" = 1 ] || {
        denied "wasm-bindgen does not run."
        return 1
    }
    : >"$TOOLS/wasm.installed"
    return 0
}

# install_packs NAME...: installs and verifies each pack; a pack that fails its
# check is removed again. Adds the good ones to PACKS_OK and sets FAILED on failure.
install_packs() {
    local t
    mkdir -p "$TOOLS/bin" "$TOOLS/linkers"
    PK_N=$#
    PK_I=0
    for t in "$@"; do
        PK_I=$((PK_I + 1))
        plain ""
        plain "  ${C_INFO}Pack: $t${C_RESET}"
        if "pack_install_$t"; then
            ok "Pack ready and verified: $t"
            PACKS_OK="$PACKS_OK $t"
        else
            denied "Pack '$t' failed and was removed again."
            pack_rollback "$t"
            FAILED=1
        fi
    done
    PACKS_OK="${PACKS_OK# }"
}

# packs_add NAME... [--accept-msvc-license]: install packs into the existing
# install and change nothing else (settings, root tweaks, targets, other packs).
packs_add() {
    local t list="" licensed=0
    for t in "$@"; do
        case "$t" in
            --accept-msvc-license) licensed=1 ;;
            *)
                pack_known "$t" || die "Unknown pack: $t (known: $PACK_ALL)"
                if has_pack "$t"; then info "Pack already installed: $t"; else list="$list $t"; fi
                ;;
        esac
    done
    list="${list# }"
    [ -n "$list" ] || return 0
    [ -d "$(sysroot_dir)/lib/rustlib/src" ] || die "The Rust sources are missing: run '$TPF_SCRIPT reinstall' first."
    case " $list " in
        *" msvc "*)
            if [ "$licensed" = 1 ] || ask_yes_no "Do you accept Microsoft's licence (the Windows SDK and CRT are downloaded)?" no; then
                MSVC_LICENSE=1
            else
                warn "Licence not accepted: the 'msvc' pack is skipped."
                list="$(printf '%s' " $list " | sed 's/ msvc / /; s/^ *//; s/ *$//')"
            fi
            ;;
    esac
    [ -n "$list" ] || return 0
    wake_lock
    mkdir -p "$LOG_DIR"
    JOBS="$(setting jobs)"
    PACKS_OK=""
    PKGS_ADDED=""
    FAILED=0
    # shellcheck disable=SC2086
    install_packs $list
    conf_load_quiet
    local now added
    now="$(installed_packs)"
    conf_set RT_PACKS "${now% }"
    added="$(conf_get RT_PKGS_ADDED) $PKGS_ADDED"
    conf_set RT_PKGS_ADDED "$(printf '%s\n' $added | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')"
    [ "$FAILED" = 0 ]
}
