# Day-to-day commands: start, stop, status, log.

app_pids() { pgrep -f "$APPDIR" 2>/dev/null; }

_need_install() {
    state_load || die "Claude Desktop is not installed. Run: $TPF_SCRIPT install"
}

cmd_status() {
    if ! state_load; then
        warn "Claude Desktop is not installed. Run: $TPF_SCRIPT install"
        return 3
    fi
    local pids
    pids="$(app_pids | tr '\n' ' ')"
    printf '%-18s : %s\n' "Version" "$APP_VERSION"
    printf '%-18s : %s\n' "Program" "$MAIN_BIN"
    printf '%-18s : %s\n' "Display fix" "$([ -f "$SHIM" ] && echo "x11fix.so (LD_PRELOAD)" || echo "TCP proxy")"
    printf '%-18s : %s\n' "Termux:X11 server" "$(pgrep -f "termux-x11 $DISPLAY_ID" >/dev/null 2>&1 && echo running || echo stopped)"
    if [ -n "$pids" ]; then
        ok "Claude Desktop is running (PID ${pids% })."
        return 0
    fi
    info "Claude Desktop is not running."
    return 3
}

cmd_stop() {
    _need_install
    local pids
    pids="$(app_pids)"
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null
        sleep 2
        # shellcheck disable=SC2046
        kill -9 $(app_pids) 2>/dev/null
        ok "Claude Desktop stopped."
    else
        info "Claude Desktop was not running."
    fi
    pkill -f "termux-x11 $DISPLAY_ID" 2>/dev/null
    pkill -f x11proxy.py 2>/dev/null
    pkill -x openbox 2>/dev/null
    if have termux-wake-unlock; then termux-wake-unlock >/dev/null 2>&1; fi
    return 0
}

cmd_log() {
    [ -f "$APP_LOG" ] || die "No log yet ($APP_LOG)."
    exec tail -n "${1:-80}" -f "$APP_LOG"
}

cmd_start() {
    _need_install
    [ -x "$MAIN_BIN" ] || die "Main binary missing: $MAIN_BIN (run: $TPF_SCRIPT reinstall)"
    if [ -n "$(app_pids)" ]; then
        info "Claude Desktop is already running."
        return 0
    fi
    local flags=(--no-sandbox --disable-gpu --disable-dev-shm-usage --ozone-platform=x11 --password-store=basic)
    local app_pid

    if have termux-wake-lock; then termux-wake-lock >/dev/null 2>&1; fi

    # 1. X server (Termux:X11). The Android app "Termux:X11" must be opened.
    if ! pgrep -f "termux-x11 $DISPLAY_ID" >/dev/null 2>&1; then
        termux-x11 "$DISPLAY_ID" >/dev/null 2>&1 &
        sleep 3
    fi
    export DISPLAY="$DISPLAY_ID"
    if have am; then am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1; fi

    # 2. Audio (optional) and window manager (optional)
    if have pulseaudio && ! pgrep -x pulseaudio >/dev/null 2>&1; then
        pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
    fi
    if have openbox && ! pgrep -x openbox >/dev/null 2>&1; then
        openbox >/dev/null 2>&1 &
        sleep 1
    fi

    # 3. The app, through the glibc loader patched into its binaries.
    # The original environment is saved first: the shell relay restores it for
    # everything the app starts (terminal, Claude Code commands).
    export CT_ORIG_LD_PRELOAD="${LD_PRELOAD:-}"
    export CT_ORIG_XDG_DATA_DIRS="${XDG_DATA_DIRS:-}"
    export CT_ORIG_DBUS="${DBUS_SESSION_BUS_ADDRESS:-}"
    # LD_PRELOAD (libtermux-exec) is built for Bionic and breaks glibc programs.
    unset LD_PRELOAD
    # Terminal and Claude Code use a NORMAL Termux bash (see the relay script).
    export SHELL="$BASE/shell/bash"
    # X11 connection fix: Debian's X libraries look for the X server in
    # /tmp/.X11-unix, which does not exist on Android.
    if [ -f "$SHIM" ]; then
        export LD_PRELOAD="$SHIM" # rewrites the socket path (glibc programs only)
    elif [ -f "$BASE/x11proxy.py" ]; then
        pgrep -f x11proxy.py >/dev/null 2>&1 ||
            nohup python3 "$BASE/x11proxy.py" "$PREFIX/tmp/.X11-unix/X0" 6001 >/dev/null 2>&1 </dev/null &
        sleep 1
        export DISPLAY=127.0.0.1:1
    fi
    export FONTCONFIG_FILE="$ETC_DIR/fonts.conf"
    export GSETTINGS_SCHEMA_DIR="$LIB_ROOT/usr/share/glib-2.0/schemas"
    export XDG_DATA_DIRS="$LIB_ROOT/usr/share:$PREFIX/share"
    export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
    export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$TMPDIR/runtime-$(id -u)}"
    mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-disabled:}"
    export ELECTRON_DISABLE_SANDBOX=1
    export GTK_USE_PORTAL=0
    export GDK_BACKEND=x11
    # Debug option: CLAUDE_USE_LD_LIBRARY_PATH=1 also exports the library folders
    # (not the default: the variable would leak into programs the app starts).
    if [ "${CLAUDE_USE_LD_LIBRARY_PATH:-0}" = "1" ]; then
        LD_LIBRARY_PATH="$(tr '\n' ':' <"$BASE/libdirs.txt")$PREFIX/glibc/lib"
        export LD_LIBRARY_PATH
    fi

    cd "$APPDIR" || die "Cannot enter $APPDIR"
    # Extra Chromium flags can be given through CLAUDE_FLAGS.
    # shellcheck disable=SC2086
    nohup "$MAIN_BIN" "${flags[@]}" ${CLAUDE_FLAGS:-} >"$APP_LOG" 2>&1 </dev/null &
    app_pid=$!
    # The watcher is a normal Termux script: it must not get the glibc LD_PRELOAD.
    LD_PRELOAD="$CT_ORIG_LD_PRELOAD" nohup "$BASE/patch-claude-code.sh" >/dev/null 2>&1 </dev/null &
    # Root (when available): protect Termux and the app against Android's killers.
    # Does nothing when the keepalive script is not in the home folder.
    if [ -x "$HOME/termux-keepalive.sh" ]; then
        (
            sleep 8
            LD_PRELOAD="$CT_ORIG_LD_PRELOAD" TERMUX_KEEPALIVE_MODE=root "$HOME/termux-keepalive.sh" on
        ) >"$HOME/.termux-keepalive.log" 2>&1 </dev/null &
    fi
    ok "Claude Desktop starting (PID $app_pid). Switch to the Termux:X11 app to see it."
    detail "Log: $APP_LOG   ($TPF_SCRIPT log)"
}
