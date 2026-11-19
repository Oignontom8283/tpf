# Installation of Claude Desktop (steps run in this order by cmd_install).

# Files written into the install folder (embedded at build time).
# tpf:embed ./fetch.py as embed_fetch_py
# tpf:embed ./relay.sh as embed_relay_sh
# tpf:embed ./watcher.sh as embed_watcher_sh
# tpf:embed ./x11fix.c as embed_x11fix_c
# tpf:embed ./x11proxy.py as embed_x11proxy_py

unpack_deb() { # unpack_deb file.deb target-dir
    local deb="$1" dest="$2"
    if dpkg-deb -x "$deb" "$dest" 2>>"$LOG_DIR/unpack.log"; then return 0; fi
    # Fallback: ar + tar (handles data.tar.xz / .gz; .zst needs zstd)
    local tmp
    tmp="$(mktemp -d "$WORK/ar.XXXXXX")" || return 1
    (cd "$tmp" && ar x "$deb") >>"$LOG_DIR/unpack.log" 2>&1 || {
        rm -rf "$tmp"
        return 1
    }
    local data
    data="$(ls "$tmp"/data.tar.* 2>/dev/null | head -n1)"
    [ -n "$data" ] && tar -xf "$data" -C "$dest" >>"$LOG_DIR/unpack.log" 2>&1
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

is_elf() { [ "$(head -c4 "$1" 2>/dev/null | tr -d '\0')" = $'\x7fELF' ]; }

cmd_install() {
    require_termux
    require_aarch64
    mkdir -p "$BASE" || die "Cannot create $BASE"
    wake_lock
    banner "Claude Desktop for Termux" "install v$TPF_VERSION"

    # ---------------------------------------------------------------------------
    # 1. Termux packages
    # ---------------------------------------------------------------------------
    step "Termux packages"
    if [ "$SKIP_UPDATE" = "1" ]; then
        info "Update skipped (--skip-update)."
    else
        apt_repair
        pkg_update || warn "apt update failed (see $LOG_DIR): run 'termux-change-repo' if a mirror is down."
    fi

    pkg_install glibc-repo x11-repo || die "Cannot enable the glibc / X11 repositories."
    apt-get "${APT_OPTS[@]}" update >"$LOG_DIR/apt_update2.log" 2>&1 || true

    pkg_install python curl binutils patchelf coreutils procps findutils glibc-runner termux-x11-nightly ||
        die "Package installation failed."
    # Nice to have: a window manager (windows need a title bar and resizing),
    # audio server, X11 helpers.
    for pkg in openbox pulseaudio xorg-xrandr; do
        pkg_install "$pkg" || warn "Optional package '$pkg' not installed."
    done
    have python3 || die "python3 not found."
    have patchelf || die "patchelf not found."
    [ -x "$GLIBC_LD" ] || die "glibc loader missing: $GLIBC_LD (see $LOG_DIR)."
    "$GLIBC_LD" --version >"$LOG_DIR/glibc_loader.log" 2>&1 ||
        die "The glibc loader does not run (see $LOG_DIR/glibc_loader.log)."
    ok "glibc loader works."

    AVAIL_MB="$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
    case "${AVAIL_MB:-}" in '' | *[!0-9]*) ;; *)
        [ "$AVAIL_MB" -lt 2500 ] && warn "Low free space: ${AVAIL_MB} MB. Claude Desktop + libraries need about 1.5-2 GB."
        ;;
    esac

    # ---------------------------------------------------------------------------
    # 2. Download: official .deb + Debian libraries (python helper)
    # ---------------------------------------------------------------------------
    mkdir -p "$WORK/debs" "$APP_ROOT" "$LIB_ROOT" "$ETC_DIR" || die "Cannot create folders in $BASE"

    HELPER="$WORK/fetch.py"
    embed_fetch_py >"$HELPER"

    step "Downloading Claude Desktop and its libraries"
    info "This downloads several hundred MB. Keep Termux in the foreground."
    python3 "$HELPER" "$WORK" "$DEBIAN_RELEASE" 2>&1 | tee "$LOG_DIR/fetch.log"
    [ "${PIPESTATUS[0]}" = "0" ] || die "Download step failed. See $LOG_DIR/fetch.log"
    [ -s "$WORK/claude-desktop.deb" ] && [ -s "$WORK/libs.list" ] || die "Download incomplete."
    APP_VERSION="$(cat "$WORK/version.txt" 2>/dev/null)"

    # ---------------------------------------------------------------------------
    # 3. Unpack
    # ---------------------------------------------------------------------------
    step "Unpacking"
    : >"$LOG_DIR/unpack.log"
    rm -rf "$APP_ROOT" "$LIB_ROOT"
    mkdir -p "$APP_ROOT" "$LIB_ROOT"
    unpack_deb "$WORK/claude-desktop.deb" "$APP_ROOT" || die "Cannot unpack the Claude Desktop .deb (see $LOG_DIR/unpack.log)."
    n=0
    bad=0
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        n=$((n + 1))
        unpack_deb "$d" "$LIB_ROOT" || {
            bad=$((bad + 1))
            warn "Could not unpack $(basename "$d")"
        }
    done <"$WORK/libs.list"
    ok "Unpacked the app and $((n - bad)) library packages."

    APPDIR="$APP_ROOT/usr/lib/claude-desktop"
    [ -d "$APPDIR" ] || APPDIR="$(find "$APP_ROOT/usr/lib" "$APP_ROOT/opt" -maxdepth 2 -type d -iname 'claude*' 2>/dev/null | head -n1)"
    [ -n "$APPDIR" ] && [ -d "$APPDIR" ] || die "Cannot find the app folder inside the .deb (look in $APP_ROOT)."
    info "App folder: $APPDIR"

    # The main program is the big ELF executable at the top of the app folder
    # (the Electron binary, 100+ MB).
    MAIN_BIN=""
    while IFS= read -r f; do
        if is_elf "$f"; then
            MAIN_BIN="$f"
            break
        fi
    done < <(find "$APPDIR" -maxdepth 2 -type f -size +40M ! -name '*.so*' ! -name '*.pak' ! -name '*.asar' ! -name '*.bin' 2>/dev/null | sort)
    if [ -z "$MAIN_BIN" ]; then
        for c in claude-desktop electron claude; do
            [ -f "$APPDIR/$c" ] && is_elf "$APPDIR/$c" && {
                MAIN_BIN="$APPDIR/$c"
                break
            }
        done
    fi
    [ -n "$MAIN_BIN" ] || {
        ls -la "$APPDIR" >&2
        die "Cannot find the Electron binary in $APPDIR."
    }
    info "Main binary: $MAIN_BIN"

    # ---------------------------------------------------------------------------
    # 4. Libraries: search path + patching
    # ---------------------------------------------------------------------------
    step "Preparing libraries"
    # Every folder holding shared libraries in the unpacked Debian packages.
    find "$LIB_ROOT" \( -name '*.so' -o -name '*.so.*' \) -printf '%h\n' 2>/dev/null | sort -u >"$BASE/libdirs.txt"
    LIBPATH="\$ORIGIN"
    while IFS= read -r d; do [ -n "$d" ] && LIBPATH="$LIBPATH:$d"; done <"$BASE/libdirs.txt"
    LIBPATH="$LIBPATH:$PREFIX/glibc/lib"

    # Patch every ELF executable at the top of the app folder (main binary and
    # helpers such as the crash handler). Electron re-launches itself through
    # /proc/self/exe, which is why the interpreter is patched into the binary
    # instead of starting it through `ld.so binary`.
    PATCHED=0
    while IFS= read -r f; do
        is_elf "$f" || continue
        case "$f" in *.so | *.so.*) continue ;; esac
        # Statically linked programs have no loader to replace: nothing to patch.
        patchelf --print-interpreter "$f" >/dev/null 2>&1 || continue
        chmod +x "$f" 2>/dev/null
        if patchelf --set-interpreter "$GLIBC_LD" --force-rpath --set-rpath "$LIBPATH" "$f" >>"$LOG_DIR/patchelf.log" 2>&1; then
            PATCHED=$((PATCHED + 1))
        else
            warn "patchelf failed on $f (see $LOG_DIR/patchelf.log)"
        fi
    done < <(find "$APPDIR" -maxdepth 2 -type f -perm -u+x 2>/dev/null)
    [ "$PATCHED" -gt 0 ] || die "No binary could be patched. See $LOG_DIR/patchelf.log"
    ok "$PATCHED executable(s) patched."

    # GSettings schemas (GTK file dialogs, settings): compile them if possible.
    SCHEMA_DIR="$LIB_ROOT/usr/share/glib-2.0/schemas"
    if [ -d "$SCHEMA_DIR" ] && have glib-compile-schemas; then
        glib-compile-schemas "$SCHEMA_DIR" >"$LOG_DIR/gschemas.log" 2>&1 &&
            ok "GSettings schemas compiled." || warn "glib-compile-schemas failed (see $LOG_DIR/gschemas.log)."
    fi

    # Libraries the app loads with dlopen() (invisible to the dependency check).
    for l in libX11.so.6 libX11-xcb.so.1 libxcb.so.1; do
        if [ -z "$(find "$LIB_ROOT" -name "$l" -print -quit 2>/dev/null)" ]; then
            warn "$l is missing: the app will crash at start-up."
            echo "$l" >>"$LOG_DIR/missing_libs.log"
        fi
    done

    # Missing libraries check (informative).
    if have ldd; then :; fi
    MISSING="$(LD_LIBRARY_PATH="$(tr '\n' ':' <"$BASE/libdirs.txt")$PREFIX/glibc/lib" LD_PRELOAD= \
        "$GLIBC_LD" --list "$MAIN_BIN" 2>&1 | grep -i 'not found' | sort -u)"
    if [ -n "$MISSING" ]; then
        warn "Some libraries are still missing (the app may fail to start):"
        echo "$MISSING" | sed 's/^/    /'
        echo "$MISSING" >"$LOG_DIR/missing_libs.log"
    else
        ok "All libraries needed by the main binary were found."
    fi

    # ---------------------------------------------------------------------------
    # 5. Fonts, DNS, certificates
    # ---------------------------------------------------------------------------
    step "Fonts, network, certificates"
    FONT_DIRS="$LIB_ROOT/usr/share/fonts"
    cat >"$ETC_DIR/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$FONT_DIRS</dir>
  <dir>$PREFIX/share/fonts</dir>
  <dir>/system/fonts</dir>
  <cachedir>$HOME/.cache/fontconfig</cachedir>
</fontconfig>
EOF
    ok "fontconfig file written."

    # glibc resolves names through its own resolv.conf; Android has none.
    GLIBC_RESOLV="$PREFIX/glibc/etc/resolv.conf"
    if [ ! -s "$GLIBC_RESOLV" ]; then
        mkdir -p "$(dirname "$GLIBC_RESOLV")"
        if [ -s "$PREFIX/etc/resolv.conf" ]; then
            cp "$PREFIX/etc/resolv.conf" "$GLIBC_RESOLV"
        else
            printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"$GLIBC_RESOLV"
            warn "No DNS file existed: Cloudflare and Google resolvers written to $GLIBC_RESOLV (edit it to change them)."
        fi
        ok "DNS file created for glibc programs."
    fi

    # ---------------------------------------------------------------------------
    # 5b. Normal Termux shell for the terminal and for Claude Code
    #     The app itself runs in a modified (glibc) environment. Everything it
    #     starts for you — the integrated terminal, Claude Code's shell commands —
    #     must run in your NORMAL Termux environment instead. The app is told
    #     to use SHELL=$BASE/shell/bash, a tiny relay that restores the original
    #     environment (LD_PRELOAD for /bin/sh and #! lines, XDG_DATA_DIRS, ...)
    #     and then starts the real Termux bash. It is named "bash" on purpose:
    #     programs choose their shell behaviour from that name.
    # ---------------------------------------------------------------------------
    step "Normal terminal for Claude"
    mkdir -p "$BASE/shell"
    embed_relay_sh >"$BASE/shell/bash"
    chmod +x "$BASE/shell/bash" || die "Cannot create the shell relay."
    ok "Shell relay: $BASE/shell/bash"

    # Claude Code, when started by the desktop app, is another glibc program that
    # the app downloads by itself AFTER installation (so it cannot be patched
    # now). A small watcher patches it as soon as it appears.
    embed_watcher_sh >"$BASE/patch-claude-code.sh"
    chmod +x "$BASE/patch-claude-code.sh"
    ok "Claude Code watcher: $BASE/patch-claude-code.sh"

    # ---------------------------------------------------------------------------
    # 5c. X11 connection fix
    #     Debian's X11 libraries connect to /tmp/.X11-unix/X0. On Android that
    #     folder does not exist: Termux:X11 puts its socket in $PREFIX/tmp.
    #     Without a fix the app stops with "Missing X server or $DISPLAY".
    #     Fix 1 (preferred): a tiny LD_PRELOAD library, built here, that rewrites
    #                        the socket path in connect().
    #     Fix 2 (fallback)  : a local TCP forwarder (127.0.0.1:6001 -> the socket).
    # ---------------------------------------------------------------------------
    step "X11 connection fix"
    rm -f "$SHIM" "$BASE/x11proxy.py"
    embed_x11fix_c >"$BASE/x11fix.c"

    X11_MODE="proxy"
    if pkg_install clang lld; then
        if clang --target=aarch64-linux-gnu -shared -fPIC -O2 -nostdlib -nostdinc \
            -fno-builtin -fno-stack-protector -fuse-ld=lld \
            -DTERMUX_TMP="\"$PREFIX/tmp\"" -o "$SHIM" "$BASE/x11fix.c" \
            >"$LOG_DIR/x11fix_build.log" 2>&1 && [ -s "$SHIM" ]; then
            X11_MODE="shim"
            ok "Display library built: $SHIM"
        else
            warn "Could not build the display library (see $LOG_DIR/x11fix_build.log)."
        fi
    else
        warn "clang / lld not installed (see $LOG_DIR/x11fix_pkgs.log)."
    fi

    if [ "$X11_MODE" = "proxy" ]; then
        warn "Using the fallback: a local TCP forwarder on 127.0.0.1:6001."
        warn "Any app on this phone could then talk to the X server while it runs."
        embed_x11proxy_py >"$BASE/x11proxy.py"
        chmod +x "$BASE/x11proxy.py"
    fi

    state_save
    ok "State saved: $STATE_FILE"

    # ---------------------------------------------------------------------------
    # 7. Start-up self-test (no display needed)
    # ---------------------------------------------------------------------------
    step "Self-test"
    # --no-sandbox: same as the launcher (Android cannot run Chromium's sandbox).
    if [ -f "$SHIM" ]; then PRE="$SHIM"; else PRE=""; fi
    TEST_OUT="$(env LD_PRELOAD="$PRE" timeout 60 "$MAIN_BIN" --no-sandbox --version 2>&1)"
    rc=$?
    printf '%s\n' "$TEST_OUT" >"$LOG_DIR/selftest.log"
    if [ $rc -eq 0 ]; then
        ok "The Electron binary runs: $(printf '%s' "$TEST_OUT" | tail -n1)"
        SELFTEST=1
    else
        SELFTEST=0
        warn "The Electron binary did not run (exit $rc):"
        printf '%s\n' "$TEST_OUT" | head -n 8 | sed 's/^/    /'
        warn "Full output: $LOG_DIR/selftest.log"
    fi

    # The terminal check mimics what the app does: a glibc-side environment
    # (no LD_PRELOAD, modified variables) starts the relay, which must give back
    # a normal Termux shell.
    SH_ORIG_PRELOAD="${LD_PRELOAD:-}"
    SH_OUT="$(env -u LD_PRELOAD CT_ORIG_LD_PRELOAD="$SH_ORIG_PRELOAD" GDK_BACKEND=x11 FONTCONFIG_FILE=/nonexistent \
        "$BASE/shell/bash" -c 'printf "LD_PRELOAD=%s\nGDK_BACKEND=%s\nFONTCONFIG_FILE=%s\nPATH_OK=%s\n" "${LD_PRELOAD:-}" "${GDK_BACKEND:-}" "${FONTCONFIG_FILE:-}" "$(command -v pkg >/dev/null && echo yes || echo no)"; echo hello | /bin/sh -c "cat" 2>&1' 2>&1)"
    printf '%s\n' "$SH_OUT" >"$LOG_DIR/shell_test.log"
    if printf '%s' "$SH_OUT" | grep -q '^GDK_BACKEND=$' && printf '%s' "$SH_OUT" | grep -q '^PATH_OK=yes' &&
        printf '%s' "$SH_OUT" | grep -q '^hello$'; then
        ok "Terminal check passed: normal Termux shell (PATH, /bin/sh, clean environment)."
    else
        warn "Terminal check failed (see $LOG_DIR/shell_test.log):"
        printf '%s\n' "$SH_OUT" | head -n 8 | sed 's/^/    /'
        SELFTEST=0
    fi

    if [ "$SELFTEST" = "1" ]; then
        banner "Installation complete" "Claude Desktop ${APP_VERSION:-unknown}"
    else
        banner "Installation complete - self-test FAILED" "see the messages above"
    fi
    detail "Start it:  $TPF_SCRIPT start   (then open the Termux:X11 app, it shows the window)"
    detail "Stop / log / state:  $TPF_SCRIPT stop | log | status"
    detail "Install logs: $LOG_DIR"
    detail "Not available on Android: Cowork (needs KVM), Computer Use, GPU acceleration;"
    detail "the sign-in is asked again at each start if the app cannot store it."
    [ "$SELFTEST" = "1" ]
}
