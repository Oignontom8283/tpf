# The settings file (~/code-server.conf) and what is derived from it.

write_default_conf() {
    (
        umask 077
        cat >"$CONF" <<EOF
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

fix_number() { # $1 = variable name, $2 = default, $3 = minimum
    local v="${!1}"
    if ! is_uint "$v" || [ "$v" -lt "$3" ]; then
        warn "$1='$v' is invalid in $CONF: $2 used."
        printf -v "$1" '%s' "$2"
    fi
}

# Reads and checks the settings file. A typo must never silently weaken security.
load_settings() {
    [ -f "$CONF" ] || write_default_conf
    # shellcheck disable=SC1090
    . "$CONF" || {
        err "Cannot read the settings file: $CONF"
        exit 1
    }

    # --- Validation: a typo must never silently weaken security ----------------
    if ! is_uint "$CS_PORT" || [ "$CS_PORT" -lt 1 ] || [ "$CS_PORT" -gt 65535 ]; then
        err "CS_PORT must be a number between 1 and 65535 (got '$CS_PORT') in $CONF"
        exit 1
    fi
    case "$CS_AUTH" in
        none | password) ;;
        *)
            err "CS_AUTH must be 'none' or 'password' (got '$CS_AUTH') in $CONF"
            exit 1
            ;;
    esac
    case "$CS_IP" in
        '' | *:* | *[[:space:]]*)
            err "CS_IP must be an IPv4 address or a host name (got '$CS_IP') in $CONF"
            exit 1
            ;;
    esac
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
}

server_pid() {
    local pid
    if [ -s "$CS_PID_FILE" ]; then
        pid="$(cat "$CS_PID_FILE" 2>/dev/null)"
        is_cs_pid "$pid" && {
            echo "$pid"
            return 0
        }
    fi
    for pid in $(pgrep -f "$CS_PROC_PATTERN" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "${PPID:-0}" ] && continue
        is_cs_pid "$pid" && {
            echo "$pid"
            return 0
        }
    done
    return 1
}

# --- Helpers ---------------------------------------------------------------
http_code() {
    # --noproxy: a proxy set in the environment must not intercept localhost.
    curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 3 "$URL" 2>/dev/null
}

# Generates a password when CS_AUTH=password and none is set, and saves it.
ensure_password() {
    [ "$CS_AUTH" = "password" ] || return 0
    [ -z "$CS_PASSWORD" ] || return 0
    CS_PASSWORD="$(gen_password)"
    if grep -q '^CS_PASSWORD=' "$CONF"; then
        (
            umask 077
            sed "s|^CS_PASSWORD=.*|CS_PASSWORD=\"$CS_PASSWORD\"|" "$CONF" >"$CONF.tmp"
        ) &&
            mv -f "$CONF.tmp" "$CONF"
    else
        echo "CS_PASSWORD=\"$CS_PASSWORD\"" >>"$CONF"
    fi
    ok "Password generated and saved in $CONF"
}

# Escapes a value for a double-quoted YAML string.
yaml_escape() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

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
        } >"$CONFIG_FILE.tmp"
    ) && mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

apply_environment() {
    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock >/dev/null 2>&1

    if [ "${CS_ROOT_INOTIFY:-0}" = "1" ]; then
        if [ "$(id -u)" = "0" ]; then
            echo "$CS_INOTIFY_WATCHES" >/proc/sys/fs/inotify/max_user_watches 2>/dev/null
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
