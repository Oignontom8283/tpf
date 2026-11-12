# Paths and saved state of the Claude Desktop install.

BASE="$HOME/.local/share/claude-desktop-termux"
WORK="$BASE/download"    # downloaded .deb files (a cache: kept by reinstall)
APP_ROOT="$BASE/app"     # unpacked official .deb
LIB_ROOT="$BASE/libs"    # unpacked Debian libraries
ETC_DIR="$BASE/etc"      # fonts.conf
STATE_FILE="$BASE/state" # what start/stop/status need (written by install)
SHIM="$BASE/x11fix.so"   # LD_PRELOAD library that fixes the X11 socket path
APP_LOG="$HOME/.claude-desktop.log"
LOG_DIR="$HOME/.cache/claude-desktop-install"
TOOL_LOG_DIR="$LOG_DIR"
GLIBC_LD="${PREFIX:-/data/data/com.termux/files/usr}/glibc/lib/ld-linux-aarch64.so.1"
DISPLAY_ID=":0"

# state_save: record what install found (read again by start, stop, status).
state_save() {
    {
        printf 'MAIN_BIN=%q\n' "$MAIN_BIN"
        printf 'APPDIR=%q\n' "$APPDIR"
        printf 'APP_VERSION=%q\n' "${APP_VERSION:-unknown}"
    } >"$STATE_FILE"
}

# state_load: sets MAIN_BIN, APPDIR and APP_VERSION. Fails when not installed.
state_load() {
    [ -f "$STATE_FILE" ] || return 1
    # shellcheck source=/dev/null
    . "$STATE_FILE"
}
