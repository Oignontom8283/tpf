# Day-to-day commands: start, stop, restart, status, log.

DETACHED=0

# --- Commands --------------------------------------------------------------
cmd_start() {
    load_settings
    local pid attempt code deadline
    if [ -z "$BIN" ]; then
        err "code-server not found. Run: $TPF_SCRIPT install"
        return 1
    fi
    command -v curl >/dev/null 2>&1 || {
        err "curl is required: pkg install curl"
        return 1
    }

    if pid="$(server_pid)"; then
        say "code-server is already running (PID $pid) — $URL"
        return 0
    fi
    rm -f "$CS_PID_FILE" 2>/dev/null

    code="$(http_code)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        err "Another program already answers on $CHECK_HOST:$CS_PORT (HTTP $code)."
        err "Stop it, or change CS_PORT in $CONF."
        return 1
    fi

    ensure_password
    write_code_server_config || {
        err "Cannot write $CONFIG_FILE"
        return 1
    }
    apply_environment

    # Claude Code support: wrap the extension's binary now, and keep watching
    # while the server runs (the extension may download a new binary).
    if [ -x "$CS_CONFIG_DIR/claude-wrap-binary.sh" ]; then
        "$CS_CONFIG_DIR/claude-wrap-binary.sh" --once >/dev/null 2>&1
        pgrep -f 'claude-wrap-binary.sh --watch' >/dev/null 2>&1 ||
            nohup "$CS_CONFIG_DIR/claude-wrap-binary.sh" --watch >/dev/null 2>&1 </dev/null &
    fi

    if [ "$CS_AUTH" = "none" ] && [ "$CS_IP" != "127.0.0.1" ] && [ "$CS_IP" != "localhost" ]; then
        warn "No authentication and listening on $CS_IP: open to the whole local network."
    fi

    attempt=1
    while [ "$attempt" -le "$CS_START_RETRIES" ]; do
        [ "$attempt" -gt 1 ] && warn "Retrying start-up ($attempt/$CS_START_RETRIES)..."
        [ -f "$CS_LOG_FILE" ] && mv -f "$CS_LOG_FILE" "$CS_LOG_FILE.1" 2>/dev/null

        # Variables that code-server reads from the environment, and which
        # would override the settings file, are removed.
        # shellcheck disable=SC2086
        env -u PORT -u PASSWORD -u HASHED_PASSWORD -u CODE_SERVER_HOST -u VSCODE_IPC_HOOK_CLI \
            nohup "$BIN" --config "$CONFIG_FILE" --user-data-dir "$CS_DATA_DIR" $CS_EXTRA_ARGS \
            >"$CS_LOG_FILE" 2>&1 </dev/null &
        pid=$!
        echo "$pid" >"$CS_PID_FILE"

        deadline=$((SECONDS + CS_START_TIMEOUT))
        while [ "$SECONDS" -lt "$deadline" ]; do
            kill -0 "$pid" 2>/dev/null || break
            code="$(http_code)"
            case "$code" in 200 | 302 | 303 | 401)
                ok "code-server started (PID $pid)"
                say "  URL      : $URL"
                if [ "$CS_AUTH" = "password" ]; then
                    say "  Password : $CS_PASSWORD"
                else
                    say "  Auth     : none"
                fi
                say "  Log      : $CS_LOG_FILE   ($TPF_SCRIPT log)"
                return 0
                ;;
            esac
            sleep 1
        done

        stop_pid "$pid"
        rm -f "$CS_PID_FILE" 2>/dev/null
        attempt=$((attempt + 1))
    done

    err "code-server did not start after $CS_START_RETRIES attempt(s)."
    say "Last $CS_LOG_LINES lines of $CS_LOG_FILE:"
    tail -n "$CS_LOG_LINES" "$CS_LOG_FILE" 2>/dev/null | sed 's/^/    /'
    return 1
}

cmd_stop() {
    load_settings
    local pid stopped=0 tries=0
    while pid="$(server_pid)"; do
        tries=$((tries + 1))
        if [ "$tries" -gt 5 ]; then
            err "Could not stop code-server (PID $pid)."
            return 1
        fi
        stop_pid "$pid" || warn "PID $pid did not stop yet."
        stopped=1
    done
    rm -f "$CS_PID_FILE" 2>/dev/null
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock >/dev/null 2>&1
    if [ "$stopped" = "1" ]; then ok "code-server stopped."; else say "code-server was not running."; fi
    return 0
}

cmd_restart() {
    load_settings
    # Inside code-server's terminal, stopping the server also kills this
    # terminal — and this script with it. The restart then continues as a
    # detached background process.
    if [ "$DETACHED" != "1" ] && in_code_server_terminal; then
        warn "Running inside code-server's terminal: the restart continues in the background."
        say "Reload the browser page in a few seconds. Output: $CS_LOG_FILE.restart"
        nohup "$SELF" restart --detached >"$CS_LOG_FILE.restart" 2>&1 </dev/null &
        disown 2>/dev/null || true
        return 0
    fi
    cmd_stop || return 1
    sleep 1
    cmd_start
}

cmd_status() {
    load_settings
    local pid
    if pid="$(server_pid)"; then
        ok "code-server is running (PID $pid) — $URL"
        return 0
    fi
    say "code-server is not running."
    return 3
}

cmd_log() {
    load_settings
    local n="${1:-50}"
    is_uint "$n" || {
        err "The number of lines must be a positive number (got '$n')."
        return 2
    }
    [ -f "$CS_LOG_FILE" ] || {
        err "No log yet: $CS_LOG_FILE"
        return 1
    }
    exec tail -n "$n" -f "$CS_LOG_FILE"
}
