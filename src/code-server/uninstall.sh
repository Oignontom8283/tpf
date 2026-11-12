# Removal. "reinstall" calls cmd_uninstall with TPF_KEEP_DATA=1: the editor
# settings, extensions and $CONF are then kept.

purge_code_server() {
    step "Removing existing installations"
    stop_running_instance

    if dpkg_installed code-server; then
        info "apt package 'code-server' found: purging..."
        apt-get "${APT_OPTS[@]}" purge code-server >"$LOG_DIR/apt_purge.log" 2>&1 &&
            ok "apt package removed." ||
            warn "apt purge failed (see $LOG_DIR/apt_purge.log), cleaning up manually."
        apt_repair
    fi

    if have npm; then
        if npm ls -g --depth=0 code-server >/dev/null 2>&1; then
            info "Global npm install found: uninstalling..."
            npm uninstall -g code-server >"$LOG_DIR/npm_uninstall.log" 2>&1 &&
                ok "npm package removed." ||
                warn "npm uninstall failed (see $LOG_DIR/npm_uninstall.log), cleaning up manually."
        fi
        local nroot
        nroot="$(npm root -g 2>/dev/null)"
        [ -n "$nroot" ] && [ -d "$nroot/code-server" ] && rm -rf "$nroot/code-server"
    fi

    local p
    for p in "${CS_LOCATIONS[@]}"; do
        [ -e "$p" ] && {
            info "Removing: $p"
            rm -rf "$p"
        }
    done
    for p in "$HOME"/.local/lib/code-server-*; do
        [ -e "$p" ] && {
            info "Removing: $p"
            rm -rf "$p"
        }
    done
    rm -f "$PREFIX/bin/code-server" "$HOME/.local/bin/code-server" \
        "$HOME/.yarn/bin/code-server" \
        "$HOME/.config/yarn/global/node_modules/.bin/code-server" 2>/dev/null

    # Helper scripts from older versions of this installer, replaced by
    # ~/code-server.sh: removed so only one set of commands remains.
    rm -f "$PREFIX/bin/code-server-start" "$PREFIX/bin/code-server-stop" \
        "$PREFIX/bin/code-server-restart" "$PREFIX/bin/code-server-status" \
        "$PREFIX/bin/code-server-logs" \
        "$HOME/bin/code-server-start" "$HOME/bin/code-server-stop" \
        "$HOME/bin/code-server-restart" "$HOME/bin/code-server-status" \
        "$OLD_PREFS_FILE" 2>/dev/null

    hash -r 2>/dev/null || true
    if have code-server; then
        warn "A 'code-server' binary is still in the PATH: $(command -v code-server)"
        warn "It was not installed by a known method; it will be overridden if possible."
    else
        ok "No code-server installation left."
    fi
}

purge_user_data() {
    step "Deleting user data (--purge-data)"
    warn "This deletes: $CONFIG_DIR, $DATA_DIR (extensions, settings, password) and $CONF."
    if ask_yes_no "Confirm PERMANENT deletion of this data?" no; then
        stop_running_instance
        rm -rf "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null
        rm -f "$LOG_FILE" "$LOG_FILE.1" "$CONF" "$CONF.bak" 2>/dev/null
        ok "User data deleted."
    else
        info "Deletion cancelled, data kept."
        PURGE_DATA=0
    fi
}

cmd_uninstall() {
    ARCH="$(uname -m)"
    purge_code_server
    rm -f "$BOOT_FILE" "$PID_FILE" 2>/dev/null
    if have termux-wake-unlock; then termux-wake-unlock >/dev/null 2>&1; fi
    if [ "$PURGE_DATA" = "1" ]; then
        purge_user_data
    elif [ "$TPF_KEEP_DATA" = "0" ] && ask_yes_no "Also delete $CONF, the editor settings and the extensions?" no; then
        rm -f "$CONF" "$CONF.bak" "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
        rm -rf "$CONFIG_DIR" "$DATA_DIR" 2>/dev/null
        ok "Settings, configuration and data deleted."
    fi
    ok "Uninstall complete."
}
