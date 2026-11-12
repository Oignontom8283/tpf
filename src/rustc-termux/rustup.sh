#!/data/data/com.termux/files/usr/bin/bash
# rustup (fake) - installed by install-fake-rustup-termux.sh
# The real rustup cannot run on Android. This one offers the usual commands on
# top of the 'rust' package from Termux. Remove everything with:
#     rustup self uninstall
BASE="${RUSTUP_FAKE_HOME:-$HOME/.rustup-fake}"
# A target's standard library is usable only if its real .rlib files are there.
# Termux's rust package ships some Android targets (armv7, i686, x86_64) with
# .rmeta metadata files only: rustc then fails with "required to be available
# in rlib format". A bare directory is NOT enough.
std_ready() { compgen -G "$1/libcore-*.rlib" >/dev/null 2>&1; }
REAL_RUSTC="${RUSTUP_FAKE_REAL_RUSTC:-${PREFIX:-/data/data/com.termux/files/usr}/bin/rustc}"
REAL_CARGO="${RUSTUP_FAKE_REAL_CARGO:-${PREFIX:-/data/data/com.termux/files/usr}/bin/cargo}"
TARGETS_FILE="$BASE/targets"
STD_DIR="$BASE/std-installed"      # one marker per target whose standard library we built
mkdir -p "$BASE/bin" "$STD_DIR"
touch "$TARGETS_FILE"

err()     { printf 'rustup (fake): %s\n' "$*" >&2; }
setting() { sed -n "s/^$1=//p" "$BASE/settings" 2>/dev/null | head -n1; }
host_triple() { "$REAL_RUSTC" -vV | sed -n 's/^host: //p'; }
sysroot_dir() { "$REAL_RUSTC" --print sysroot; }

# rustc looks for "rust-lld" to link WebAssembly and bare-metal targets.
# Termux ships "lld": it is simply given the expected name.
ensure_lld() {
    local sr hostt lld
    sr="$(sysroot_dir)"; hostt="$(host_triple)"
    [ -x "$sr/lib/rustlib/$hostt/bin/rust-lld" ] && return 0
    [ -e "$BASE/bin/rust-lld" ] && return 0
    lld="$(command -v lld 2>/dev/null || true)"
    if [ -n "$lld" ]; then ln -sf "$lld" "$BASE/bin/rust-lld"; return 0; fi
    err "lld not found: install it with 'pkg install lld'."
    return 1
}

# The sources of the standard library, in the SAME version as rustc. Cargo
# rebuilds the standard library from them for every non-native target.
ensure_src() {
    local sr ver marker dist url tmp want got
    sr="$(sysroot_dir)"
    ver="$("$REAL_RUSTC" --version | awk '{print $2}')"
    marker="$BASE/rust-src-version"
    if [ -d "$sr/lib/rustlib/src/rust/library/core" ]; then
        if dpkg -S "$sr/lib/rustlib/src" >/dev/null 2>&1; then return 0; fi   # shipped by a package
        [ "$(cat "$marker" 2>/dev/null)" = "$ver" ] && return 0
    fi
    dist="${RUSTUP_DIST_SERVER:-https://static.rust-lang.org}"
    url="$dist/dist/rust-src-${ver}.tar.xz"
    tmp="$(mktemp -d)" || { err "cannot create a temporary directory"; return 1; }
    echo "Downloading the Rust ${ver} sources (a few tens of MB)..."
    if ! curl -fL -sS --retry 3 --connect-timeout 20 -o "$tmp/src.tar.xz" "$url"; then
        rm -rf "$tmp"; err "download failed: $url"; return 1
    fi
    if curl -fsSL --retry 2 --connect-timeout 20 -o "$tmp/src.sha256" "$url.sha256" 2>/dev/null; then
        want="$(awk '{print $1; exit}' "$tmp/src.sha256")"
        got="$(sha256sum "$tmp/src.tar.xz" | awk '{print $1}')"
        if [ -z "$want" ] || [ "$want" != "$got" ]; then
            rm -rf "$tmp"; err "checksum mismatch: the download is corrupted, try again"; return 1
        fi
        echo "Checksum verified."
    else
        echo "warning: no checksum available, integrity not verified" >&2
    fi
    if ! tar -xJf "$tmp/src.tar.xz" -C "$tmp"; then
        rm -rf "$tmp"; err "unreadable archive"; return 1
    fi
    rm -rf "$sr/lib/rustlib/src"
    mkdir -p "$sr/lib/rustlib"
    cp -r "$tmp"/rust-src-*/rust-src/lib/rustlib/src "$sr/lib/rustlib/"
    rm -rf "$tmp"
    if [ ! -d "$sr/lib/rustlib/src/rust/library/core" ]; then
        err "sources copied but not found where expected"; return 1
    fi
    echo "$ver" > "$marker"
    echo "Rust sources installed."
}

# Says honestly how far each kind of target can go on Termux.
has_pack() { [ -e "$BASE/toolchains/$1.installed" ]; }
target_hint() {
    local t="$1"
    case "$t" in
        *-unknown-linux-gnu|*-unknown-linux-musl|*-pc-windows-gnu*)
            if has_pack zig; then echo "  -> linked by Zig: 'cargo build --target $t' uses cargo-zigbuild automatically."; return; fi ;;
        *-apple-darwin|*-apple-ios*)
            if has_pack zig; then echo "  -> Zig can link pure-Rust code for macOS; system frameworks need a macOS SDK (set SDKROOT)."; return; fi ;;
        *-pc-windows-msvc)
            if has_pack msvc; then echo "  -> linked with clang/lld + the Windows SDK: 'cargo build --target $t' uses cargo-xwin automatically."; return; fi ;;
        armv7-linux-androideabi|i686-linux-android|x86_64-linux-android|aarch64-linux-android)
            if has_pack ndk; then echo "  -> linked with Termux's clang and ndk-multilib."; return; fi ;;
    esac
    case "$t" in
        wasm32-unknown-emscripten)
            echo "  -> needs Emscripten (emcc), not available on Termux: 'cargo check' works, linking does not." ;;
        wasm32-wasi*|wasm32-wasip*)
            echo "  -> needs a WASI C library that Termux does not provide: 'cargo check' works, linking may fail." ;;
        wasm32*|*-none|*-none-*)
            echo "  -> linked with lld: compiling and linking should both work." ;;
        x86_64-pc-windows-gnu|i686-pc-windows-gnu)
            echo "  -> no linker: 'cargo check' works, linking does not. Install the 'zig' pack to link it" \
                 "(re-run the installer with --toolchains zig)." ;;
        *-linux-android*)
            echo "  -> linking works for this phone's architecture only; other Android targets need the NDK." ;;
        *)
            echo "  -> no linker or system libraries for this target: 'cargo check --target $t' works,"
            echo "     the final link of 'cargo build' will fail (see the packs: installer --list-toolchains)." ;;
    esac
}

# Builds the standard library of a target from the Rust sources ONCE and puts it
# in the compiler's own sysroot, exactly where the real rustup puts it. Every
# tool then finds it (cargo, build scripts, wasm-pack...) without any special flag.
build_target_std() {
    local t="$1" sr ver tmp crates extra="" f n=0 dest jobs
    sr="$(sysroot_dir)"; ver="$("$REAL_RUSTC" --version)"
    tmp="$(mktemp -d)" || { err "cannot create a temporary directory"; return 1; }
    mkdir -p "$tmp/src"
    printf '[package]\nname = "rtstdprobe"\nversion = "0.0.0"\nedition = "2021"\n\n[lib]\npath = "src/lib.rs"\n\n[workspace]\n' > "$tmp/Cargo.toml"
    crates="std,panic_abort"
    if RUSTC_BOOTSTRAP=1 "$REAL_RUSTC" --print cfg --target "$t" 2>/dev/null | grep -q '^target_os="none"'; then
        crates="core,alloc"; extra="-Zbuild-std-features=compiler-builtins-mem"
        echo '#![no_std]' > "$tmp/src/lib.rs"
    else
        echo 'pub fn probe() {}' > "$tmp/src/lib.rs"
    fi
    echo "Building the standard library for $t (several minutes, once)..."
    jobs="$(setting jobs)"
    # The standard library must carry LLVM bitcode, like the one rustup ships: projects
    # that set `lto = true` fail otherwise ("Can't find section .llvmbc").
    if ! ( cd "$tmp" && env PATH="$BASE/bin:$PATH" RUSTC_BOOTSTRAP=1 RUSTC="$REAL_RUSTC" CARGO_TARGET_DIR="$tmp/target" \
             RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-Cembed-bitcode=yes" \
             ${jobs:+CARGO_BUILD_JOBS=$jobs} "$REAL_CARGO" build --release --quiet --target "$t" "-Zbuild-std=$crates" $extra ) >"$tmp/build.log" 2>&1; then
        tail -n 15 "$tmp/build.log" >&2
        rm -rf "$tmp"; err "the standard library for $t could not be built"; return 1
    fi
    dest="$sr/lib/rustlib/$t/lib"
    rm -rf "$sr/lib/rustlib/$t"; mkdir -p "$dest"
    for f in "$tmp"/target/"$t"/release/deps/*.rlib; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in librtstdprobe*) continue ;; esac
        cp "$f" "$dest/" && n=$((n+1))
    done
    rm -rf "$tmp"
    if [ "$n" -eq 0 ]; then rm -rf "$sr/lib/rustlib/$t"; err "no library was produced for $t"; return 1; fi
    echo "$ver" > "$STD_DIR/$t"
    echo "Standard library for $t installed ($n libraries)."
}

cmd_target() {
    local sub="${1:-}"; shift || true
    local sr t list=() skip=0 a
    sr="$(sysroot_dir)"
    case "$sub" in
        add)
            for a in "$@"; do
                if [ "$skip" = 1 ]; then skip=0; continue; fi
                case "$a" in --toolchain) skip=1 ;; -*) ;; *) list+=("$a") ;; esac
            done
            [ "${#list[@]}" -gt 0 ] || { err "give a target: rustup target add TARGET_NAME"; return 1; }
            ensure_src || return 1
            ensure_lld || true
            for t in "${list[@]}"; do
                if ! "$REAL_RUSTC" --print target-list | grep -qxF "$t"; then
                    err "unknown target: $t  (see 'rustup target list')"; return 1
                fi
                if std_ready "$sr/lib/rustlib/$t/lib" && [ ! -f "$STD_DIR/$t" ]; then
                    echo "info: target $t is already available natively"; continue
                fi
                if [ "$(cat "$STD_DIR/$t" 2>/dev/null)" != "$("$REAL_RUSTC" --version)" ]; then
                    build_target_std "$t" || return 1
                fi
                grep -qxF "$t" "$TARGETS_FILE" || echo "$t" >> "$TARGETS_FILE"
                echo "info: target $t installed"
                target_hint "$t"
            done ;;
        remove)
            for t in "$@"; do
                case "$t" in -*) continue ;; esac
                grep -vxF "$t" "$TARGETS_FILE" > "$TARGETS_FILE.tmp" || true
                mv "$TARGETS_FILE.tmp" "$TARGETS_FILE"
                if [ -f "$STD_DIR/$t" ]; then rm -rf "$sr/lib/rustlib/$t"; rm -f "$STD_DIR/$t"; fi
                echo "info: target $t removed"
            done ;;
        list)
            if [ "${1:-}" = "--installed" ]; then
                for d in "$sr"/lib/rustlib/*/lib; do [ -d "$d" ] && basename "$(dirname "$d")"; done
                cat "$TARGETS_FILE"
            else
                while IFS= read -r t; do
                    if std_ready "$sr/lib/rustlib/$t/lib" || grep -qxF "$t" "$TARGETS_FILE"; then
                        echo "$t (installed)"
                    else
                        echo "$t"
                    fi
                done < <("$REAL_RUSTC" --print target-list)
            fi ;;
        *) err "usage: rustup target add|remove|list [--installed]"; return 1 ;;
    esac
}

cmd_toolchain() {
    local sub="${1:-}"; shift || true
    local a
    case "$sub" in
        list)
            echo "stable-$(host_triple) (default: provided by the Termux package)"
            if [ "$(setting nightly)" = 1 ]; then echo "nightly (simulated: stable compiler + RUSTC_BOOTSTRAP=1)"; fi ;;
        install)
            for a in "$@"; do
                case "$a" in
                    -*) ;;
                    stable*) echo "stable: already provided by Termux (update with 'rustup update')" ;;
                    nightly*)
                        if [ "$(setting nightly)" = 1 ]; then
                            echo "nightly: simulated mode is on. It is NOT a real nightly: it is the stable compiler"
                            echo "  of Termux with the flag that allows unstable features present in its version."
                            echo "  Use it with: cargo +nightly build"
                        else
                            err "the simulated nightly mode is off: run the installer again with --nightly"; return 1
                        fi ;;
                    beta*) echo "beta: not available on Termux, stable is used." ;;
                    *) err "toolchain '$a' unavailable: only stable and a simulated nightly exist here."; return 1 ;;
                esac
            done ;;
        uninstall) echo "Nothing to uninstall: the toolchain comes from the Termux package 'rust'." ;;
        *) err "usage: rustup toolchain list|install"; return 1 ;;
    esac
}

cmd_component() {
    local sub="${1:-}"; shift || true
    local c
    case "$sub" in
        add)
            for c in "$@"; do
                case "$c" in
                    -*|--toolchain) ;;
                    rust-src) ensure_src && echo "info: rust-src ready" ;;
                    rustfmt|rustfmt-preview)
                        if command -v rustfmt >/dev/null 2>&1; then echo "info: rustfmt already present"
                        else err "rustfmt is not part of the Termux 'rust' package on this device"; fi ;;
                    clippy|clippy-preview)
                        if command -v cargo-clippy >/dev/null 2>&1; then echo "info: clippy already present"
                        else err "clippy is not part of the Termux 'rust' package on this device"; fi ;;
                    rust-analyzer)
                        if command -v rust-analyzer >/dev/null 2>&1; then echo "info: rust-analyzer already present"
                        else err "rust-analyzer is not installed: try 'pkg install rust-analyzer'"; fi ;;
                    *) err "component '$c' not handled" ;;
                esac
            done ;;
        list) echo "rust-src (if installed)"; command -v cargo-clippy rustfmt rust-analyzer 2>/dev/null || true ;;
        *) err "usage: rustup component add rust-src|rustfmt|clippy|rust-analyzer"; return 1 ;;
    esac
}

cmd_self() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        uninstall)
            local tool; tool="$(setting tool)"
            if [ -n "$tool" ] && [ -f "$tool" ]; then exec bash "$tool" uninstall "$@"; fi
            err "The rustc-termux.sh that installed this was not found: run '"'"'rustc-termux.sh uninstall'"'"' from where you saved it."; return 1 ;;
        update)
            echo "Run: rustc-termux.sh reinstall (it reinstalls everything cleanly)." ;;
        *) err "usage: rustup self uninstall|update"; return 1 ;;
    esac
}

case "${1:-}" in
    target)    shift; cmd_target "$@" ;;
    toolchain) shift; cmd_toolchain "$@" ;;
    component) shift; cmd_component "$@" ;;
    self)      shift; cmd_self "$@" ;;
    update)
        apt-get update >/dev/null 2>&1
        apt-get install -y --only-upgrade rust && ensure_src && ensure_lld
        for f in "$STD_DIR"/*; do
            [ -f "$f" ] || continue
            [ "$(cat "$f")" = "$("$REAL_RUSTC" --version)" ] || build_target_std "$(basename "$f")"
        done
        echo "Rust: $("$REAL_RUSTC" --version)" ;;
    default)
        shift
        case "${1:-}" in
            stable*|nightly*) echo "${1%%-*}" > "$BASE/default-toolchain"; echo "info: default toolchain: $1" ;;
            "") cat "$BASE/default-toolchain" 2>/dev/null || echo stable ;;
            *) err "unknown toolchain: $1"; exit 1 ;;
        esac ;;
    show)
        echo "Host: $(host_triple)"
        echo "Default toolchain: $(cat "$BASE/default-toolchain" 2>/dev/null || echo stable)"
        echo "Simulated nightly: $([ "$(setting nightly)" = 1 ] && echo on || echo off)"
        echo "Build jobs limit: $(setting jobs | sed 's/^$/none/')"
        echo "Raised build priority (root): $([ -n "$(setting oom)" ] && echo "on ($(setting oom))" || echo off)"
        echo "Linker packs: $(for p in zig msvc ndk wasm; do has_pack $p && printf '%s ' $p; done | sed 's/^$/none/')"
        echo "Targets added (standard library rebuilt when needed):"
        sed 's/^/  /' "$TARGETS_FILE"
        "$REAL_RUSTC" --version ;;
    run)
        shift
        tc="${1:-}"; shift || true
        case "$tc" in nightly*) export RUSTC_BOOTSTRAP=1 ;; esac
        exec "$@" ;;
    which) shift; command -v "${1:-rustc}" ;;
    --version|-V|version) echo "rustup 0.0.1 (fake rustup for Termux)" ;;
    ""|help|--help|-h)
        cat <<'EOT'
Fake rustup for Termux
  rustup target add|remove|list [--installed]
  rustup toolchain list|install nightly
  rustup component add rust-src|rustfmt|clippy|rust-analyzer
  rustup default stable|nightly
  rustup run nightly COMMAND
  rustup update | show | which
  rustup self uninstall
  (linker packs are chosen at install time: installer --list-toolchains)
EOT
        ;;
    *) err "unknown command: $1  (see 'rustup help')"; exit 1 ;;
esac
