#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# code-server.sh — manage code-server on Termux
#
#   ./code-server.sh start      start the server
#   ./code-server.sh stop       stop it
#   ./code-server.sh restart    stop, then start
#   ./code-server.sh status     tell whether it is running
#   ./code-server.sh log [n]    follow the log (last n lines, default 50)
#
# Settings: code-server.conf next to this script (or the file in $CS_CONF).
# ============================================================================
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
CONF="${CS_CONF:-$(dirname "$SELF")/code-server.conf}"

# --- Defaults (used when the settings file is missing or incomplete) -------
CS_PORT=8080
CS_IP=127.0.0.1
CS_AUTH=none
CS_PASSWORD=""
CS_LOG_LINES=25
CS_START_TIMEOUT=45
CS_START_RETRIES=2
CS_BIN=""
CS_LOG_FILE="$HOME/.code-server.log"
CS_PID_FILE="$HOME/.code-server.pid"
CS_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/code-server"
CS_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/code-server"
CS_LINUX_SPOOF=0
CS_MS_MARKETPLACE=0
CS_ROOT_INOTIFY=0
CS_INOTIFY_WATCHES=524288
CS_ROOT_HELPER=""
CS_EXTRA_ARGS=""

# tpf:include core

say()  { echo -e "$*"; }

write_default_conf() {
    ( umask 077; cat > "$CONF" <<EOF
# Settings for code-server.sh — edit, then run: ./code-server.sh restart
CS_PORT=8080
CS_IP=127.0.0.1
# none | password
CS_AUTH=none
CS_PASSWORD=""
# Log lines shown when start-up fails
CS_LOG_LINES=25
# Maximum seconds to wait at start-up
CS_START_TIMEOUT=45
# Start attempts before giving up
CS_START_RETRIES=2
CS_BIN=""
CS_LOG_FILE="\$HOME/.code-server.log"
CS_PID_FILE="\$HOME/.code-server.pid"
CS_CONFIG_DIR="\${XDG_CONFIG_HOME:-\$HOME/.config}/code-server"
CS_DATA_DIR="\${XDG_DATA_HOME:-\$HOME/.local/share}/code-server"
CS_LINUX_SPOOF=0
CS_MS_MARKETPLACE=0
CS_ROOT_INOTIFY=0
CS_INOTIFY_WATCHES=524288
CS_ROOT_HELPER=""
CS_EXTRA_ARGS=""
EOF
    )
    warn "Settings file created with default values: $CONF"
}

[ -f "$CONF" ] || write_default_conf
# shellcheck disable=SC1090
. "$CONF" || { err "Cannot read the settings file: $CONF"; exit 1; }

# --- Validation: a typo must never silently weaken security ----------------
if ! is_uint "$CS_PORT" || [ "$CS_PORT" -lt 1 ] || [ "$CS_PORT" -gt 65535 ]; then
    err "CS_PORT must be a number between 1 and 65535 (got '$CS_PORT') in $CONF"; exit 1
fi
case "$CS_AUTH" in
    none|password) ;;
    *) err "CS_AUTH must be 'none' or 'password' (got '$CS_AUTH') in $CONF"; exit 1 ;;
esac
case "$CS_IP" in
    ''|*:*|*[[:space:]]*) err "CS_IP must be an IPv4 address or a host name (got '$CS_IP') in $CONF"; exit 1 ;;
esac
fix_number() {   # $1 = variable name, $2 = default, $3 = minimum
    local v="${!1}"
    if ! is_uint "$v" || [ "$v" -lt "$3" ]; then
        warn "$1='$v' is invalid in $CONF: $2 used."
        printf -v "$1" '%s' "$2"
    fi
}
fix_number CS_LOG_LINES 25 0
fix_number CS_START_TIMEOUT 45 1
fix_number CS_START_RETRIES 2 1

CONFIG_FILE="$CS_CONFIG_DIR/config.yaml"
SPOOF_FILE="$CS_CONFIG_DIR/android-as-linux.js"

BIN="$CS_BIN"
{ [ -n "$BIN" ] && [ -x "$BIN" ]; } || BIN="$(command -v code-server 2>/dev/null)"

CHECK_HOST="$CS_IP"
[ "$CS_IP" = "0.0.0.0" ] && CHECK_HOST="127.0.0.1"
URL="http://$CHECK_HOST:$CS_PORT/"

# --- Processes -------------------------------------------------------------
# Strict pattern: `pkill -f code-server` would also kill this script.
CS_PROC_PATTERN='code-server([[:space:]]|$)|code-server/out/node/entry'

is_cs_pid() {
    local pid="${1:-}" cmd
    is_uint "$pid" || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    printf '%s\n' "$cmd" | grep -Eq "$CS_PROC_PATTERN"
}

server_pid() {
    local pid
    if [ -s "$CS_PID_FILE" ]; then
        pid="$(cat "$CS_PID_FILE" 2>/dev/null)"
        is_cs_pid "$pid" && { echo "$pid"; return 0; }
    fi
    for pid in $(pgrep -f "$CS_PROC_PATTERN" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "${PPID:-0}" ] && continue
        is_cs_pid "$pid" && { echo "$pid"; return 0; }
    done
    return 1
}

pid_tree() {
    local p
    echo "$1"
    for p in $(pgrep -P "$1" 2>/dev/null); do pid_tree "$p"; done
}

stop_pid() {
    local pids p i alive=""
    pids="$(pid_tree "$1")"
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null
    for i in 1 2 3 4 5; do
        alive=""
        for p in $pids; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
        [ -z "$alive" ] && return 0
        sleep 1
    done
    # shellcheck disable=SC2086
    kill -KILL $alive 2>/dev/null
    sleep 1
    for p in $alive; do kill -0 "$p" 2>/dev/null && return 1; done
    return 0
}

# --- Helpers ---------------------------------------------------------------
http_code() {
    # --noproxy: a proxy set in the environment must not intercept localhost.
    curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 "$URL" 2>/dev/null
}

gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
    fi
}

# Generates a password when CS_AUTH=password and none is set, and saves it.
ensure_password() {
    [ "$CS_AUTH" = "password" ] || return 0
    [ -z "$CS_PASSWORD" ] || return 0
    CS_PASSWORD="$(gen_password)"
    if grep -q '^CS_PASSWORD=' "$CONF"; then
        ( umask 077; sed "s|^CS_PASSWORD=.*|CS_PASSWORD=\"$CS_PASSWORD\"|" "$CONF" > "$CONF.tmp" ) \
            && mv -f "$CONF.tmp" "$CONF"
    else
        echo "CS_PASSWORD=\"$CS_PASSWORD\"" >> "$CONF"
    fi
    ok "Password generated and saved in $CONF"
}

# Escapes a value for a double-quoted YAML string.
yaml_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

# code-server's config.yaml is generated from the settings file.
write_code_server_config() {
    mkdir -p "$CS_CONFIG_DIR" || return 1
    (
        umask 077
        {
            echo "bind-addr: $CS_IP:$CS_PORT"
            if [ "$CS_AUTH" = "password" ]; then
                echo "auth: password"
                echo "password: \"$(yaml_escape "$CS_PASSWORD")\""
            else
                echo "auth: none"
            fi
            echo "cert: false"
        } > "$CONFIG_FILE.tmp"
    ) && mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

apply_environment() {
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock >/dev/null 2>&1

    if [ "${CS_ROOT_INOTIFY:-0}" = "1" ]; then
        if [ "$(id -u)" = "0" ]; then
            echo "$CS_INOTIFY_WATCHES" > /proc/sys/fs/inotify/max_user_watches 2>/dev/null
        elif [ -n "$CS_ROOT_HELPER" ] && [ -x "$CS_ROOT_HELPER" ]; then
            "$CS_ROOT_HELPER" -c "echo $CS_INOTIFY_WATCHES > /proc/sys/fs/inotify/max_user_watches" >/dev/null 2>&1
        fi
    fi

    if [ "${CS_LINUX_SPOOF:-0}" = "1" ] && [ -f "$SPOOF_FILE" ]; then
        export NODE_OPTIONS="--require $SPOOF_FILE ${NODE_OPTIONS:-}"
    fi

    if [ "${CS_MS_MARKETPLACE:-0}" = "1" ]; then
        export EXTENSIONS_GALLERY='{"serviceUrl":"https://marketplace.visualstudio.com/_apis/public/gallery","itemUrl":"https://marketplace.visualstudio.com/items","resourceUrlTemplate":"https://{publisher}.vscode-unpkg.net/{publisher}/{name}/{version}/{path}","controlUrl":"","recommendationsUrl":""}'
    fi
}

# True when this script runs inside code-server's own terminal.
in_code_server_terminal() {
    [ -n "${VSCODE_IPC_HOOK_CLI:-}" ] || [ "${TERM_PROGRAM:-}" = "vscode" ]
}

# --- Commands --------------------------------------------------------------
cmd_start() {
    local pid attempt code deadline
    if [ -z "$BIN" ]; then
        err "code-server not found. Run the install script again."
        exit 1
    fi
    command -v curl >/dev/null 2>&1 || { err "curl is required: pkg install curl"; exit 1; }

    if pid="$(server_pid)"; then
        say "code-server is already running (PID $pid) — $URL"
        exit 0
    fi
    rm -f "$CS_PID_FILE" 2>/dev/null

    code="$(http_code)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        err "Another program already answers on $CHECK_HOST:$CS_PORT (HTTP $code)."
        err "Stop it, or change CS_PORT in $CONF."
        exit 1
    fi

    ensure_password
    write_code_server_config || { err "Cannot write $CONFIG_FILE"; exit 1; }
    apply_environment

    # Claude Code support: wrap the extension's binary now, and keep watching
    # while the server runs (the extension may download a new binary).
    if [ -x "$CS_CONFIG_DIR/claude-wrap-binary.sh" ]; then
        "$CS_CONFIG_DIR/claude-wrap-binary.sh" --once >/dev/null 2>&1
        pgrep -f 'claude-wrap-binary.sh --watch' >/dev/null 2>&1 || \
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
        echo "$pid" > "$CS_PID_FILE"

        deadline=$((SECONDS + CS_START_TIMEOUT))
        while [ "$SECONDS" -lt "$deadline" ]; do
            kill -0 "$pid" 2>/dev/null || break
            code="$(http_code)"
            case "$code" in 200|302|303|401)
                ok "code-server started (PID $pid)"
                say "  URL      : $URL"
                if [ "$CS_AUTH" = "password" ]; then
                    say "  Password : $CS_PASSWORD"
                else
                    say "  Auth     : none"
                fi
                say "  Log      : $CS_LOG_FILE   (./code-server.sh log)"
                exit 0 ;;
            esac
            sleep 1
        done

        stop_pid "$pid"
        rm -f "$CS_PID_FILE" 2>/dev/null
        attempt=$((attempt+1))
    done

    err "code-server did not start after $CS_START_RETRIES attempt(s)."
    say "Last $CS_LOG_LINES lines of $CS_LOG_FILE:"
    tail -n "$CS_LOG_LINES" "$CS_LOG_FILE" 2>/dev/null | sed 's/^/    /'
    exit 1
}

cmd_stop() {
    local pid stopped=0 tries=0
    while pid="$(server_pid)"; do
        tries=$((tries+1))
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
    # Inside code-server's terminal, stopping the server also kills this
    # terminal — and this script with it. The restart then continues as a
    # detached background process.
    if [ "${1:-}" != "--detached" ] && in_code_server_terminal; then
        warn "Running inside code-server's terminal: the restart continues in the background."
        say "Reload the browser page in a few seconds. Output: $CS_LOG_FILE.restart"
        nohup "$SELF" restart --detached >"$CS_LOG_FILE.restart" 2>&1 </dev/null &
        disown 2>/dev/null || true
        exit 0
    fi
    cmd_stop || exit 1
    sleep 1
    cmd_start
}

cmd_status() {
    local pid
    if pid="$(server_pid)"; then
        ok "code-server is running (PID $pid) — $URL"
        exit 0
    fi
    say "code-server is not running."
    exit 3
}

cmd_log() {
    local n="${1:-50}"
    is_uint "$n" || { err "The number of lines must be a positive number (got '$n')."; exit 2; }
    [ -f "$CS_LOG_FILE" ] || { err "No log yet: $CS_LOG_FILE"; exit 1; }
    exec tail -n "$n" -f "$CS_LOG_FILE"
}

cmd_help() {
    cat <<EOF
Usage: ./code-server.sh <command>

  start        Start code-server (re-reads $CONF)
  stop         Stop code-server
  restart      Restart it
  status       Tell whether it is running
  log [n]      Follow the log, last n lines (default 50)
  help         This help

Settings: $CONF
  CS_PORT=$CS_PORT   CS_IP=$CS_IP   CS_AUTH=$CS_AUTH
EOF
}

case "${1:-help}" in
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    restart)        cmd_restart "${2:-}" ;;
    status)         cmd_status ;;
    log|logs)       cmd_log "${2:-50}" ;;
    help|-h|--help) cmd_help ;;
    *)              err "Unknown command: $1"; cmd_help; exit 2 ;;
esac
