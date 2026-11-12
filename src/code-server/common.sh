# Paths, defaults and process helpers shared by every command.

SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
# Settings file (edited by the user). CS_CONF points to another one.
CONF="${CS_CONF:-$HOME/code-server.conf}"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/code-server"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/code-server"
SPOOF_FILE="$CONFIG_DIR/android-as-linux.js"
OLD_PREFS_FILE="$CONFIG_DIR/install-prefs.env" # left by versions < 3.1
SETTINGS_FILE="$DATA_DIR/User/settings.json"
LOG_FILE="$HOME/.code-server.log"
PID_FILE="$HOME/.code-server.pid"
LOG_DIR="$HOME/.cache/code-server-install"
BOOT_FILE="$HOME/.termux/boot/50-code-server.sh"
CLAUDE_WRAPPER="$CONFIG_DIR/claude-code-wrapper.sh" # old approach, only cleaned up
CLAUDE_WRAP_SCRIPT="$CONFIG_DIR/claude-wrap-binary.sh"
TOOL_LOG_DIR="$LOG_DIR"

CS_LOCATIONS=(
    "$PREFIX/lib/node_modules/code-server"
    "$HOME/.config/yarn/global/node_modules/code-server"
)

# --- Defaults (used when the settings file is missing or incomplete) -----------
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

say() { echo -e "$*"; }

# Strict pattern: `pkill -f code-server` would also kill this script.
# (The tests set TPF_CS_PROC_PATTERN so that they can never match a real server.)
CS_PROC_PATTERN="${TPF_CS_PROC_PATTERN:-code-server([[:space:]]|\$)|code-server/out/node/entry}"

# True if $1 is a live code-server process (protects against reused PIDs
# from a stale PID file).
is_cs_pid() {
    local pid="${1:-}" cmd
    is_uint "$pid" || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)"
    printf '%s\n' "$cmd" | grep -Eq "$CS_PROC_PATTERN"
}

cs_pids() {
    local pid
    for pid in $(pgrep -f "$CS_PROC_PATTERN" 2>/dev/null); do
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "${PPID:-0}" ] && continue
        is_cs_pid "$pid" && echo "$pid"
    done
}

# A process and all its descendants (code-server starts child processes).
pid_tree() {
    local p
    echo "$1"
    for p in $(pgrep -P "$1" 2>/dev/null); do pid_tree "$p"; done
}

# Stops a process tree: SIGTERM, wait up to 5 s, then SIGKILL.
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

stop_running_instance() {
    local pid
    if [ -s "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        if is_cs_pid "$pid"; then
            info "Stopping code-server (PID $pid)..."
            stop_pid "$pid" || warn "PID $pid did not stop."
        fi
        rm -f "$PID_FILE"
    fi
    for pid in $(cs_pids); do
        info "Stopping leftover code-server process (PID $pid)..."
        stop_pid "$pid" || warn "PID $pid did not stop."
    done
    return 0
}

# Looks for a REAL su binary. Termux ships its own `su` wrapper in $PREFIX/bin
# that exists even on non-rooted devices, so `command -v su` is not proof of root.
find_real_su() {
    local c
    for c in /system/bin/su /system/xbin/su /sbin/su /su/bin/su /debug_ramdisk/su; do
        [ -x "$c" ] && {
            echo "$c"
            return 0
        }
    done
    return 1
}

gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
    fi
}

# Values are shell-quoted (%q) so that any character is stored safely.
q() { printf '%q' "$1"; }
