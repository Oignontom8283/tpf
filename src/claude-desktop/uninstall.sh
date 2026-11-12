# Removal. "reinstall" calls this with TPF_KEEP_DATA=1 to keep the download cache.

PURGE=0

cmd_uninstall() {
    step "Uninstall"
    if state_load 2>/dev/null; then cmd_stop >/dev/null 2>&1; fi
    if [ "$TPF_KEEP_DATA" = 1 ]; then
        find "$BASE" -mindepth 1 -maxdepth 1 ! -name "$(basename "$WORK")" -exec rm -rf {} + 2>/dev/null
        ok "Program and libraries removed (the download cache was kept)."
    else
        rm -rf "$BASE"
        ok "Program, libraries and download cache removed."
    fi
    rm -f "$APP_LOG"
    if [ "$PURGE" = 1 ]; then
        rm -rf "$HOME/.config/Claude"
        ok "App data deleted (including the sign-in)."
    fi
    info "Termux packages such as glibc-runner were kept."
}
