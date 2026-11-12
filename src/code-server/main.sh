#!/data/data/com.termux/files/usr/bin/bash
# Install and run code-server (VS Code in the browser) on Termux, with the
# Android fixes and Claude Code support.
#
#   code-server.sh install      install and configure code-server, then start it
#   code-server.sh start        start it (re-reads the settings file)
#   code-server.sh stop         stop it
#   code-server.sh restart      restart it
#   code-server.sh status       tell whether it is running
#   code-server.sh log [n]      follow the log (last n lines, default 50)
#   code-server.sh uninstall    remove code-server (asks before deleting your data)
#   code-server.sh reinstall    uninstall (keeping your data), then install again
#
# Settings: ~/code-server.conf (or the file in $CS_CONF), read by every command.
# `set -e` is deliberately NOT used: every step checks its own result so the
# script can explain what went wrong and try alternatives.
set -uo pipefail

# tpf:include core
# tpf:include cmd
# tpf:include pkg
# tpf:include ./common.sh
# tpf:include ./settings.sh
# tpf:include ./manage.sh
# tpf:include ./claude.sh
# tpf:include ./install.sh
# tpf:include ./uninstall.sh

METHOD="auto"
PORT="" # empty = keep the saved value (or the default)
BIND_HOST=""
AUTH_MODE=""
PURGE_DATA=0
NEW_PASSWORD=0
SKIP_UPDATE=0
CLAUDE_OPT="" # "" = ask / saved value | 1 | 0
DO_RESET=0    # install keeps a working install; reinstall removes first

TOOL_OPTIONS_HELP='      --method M         install: auto (default), tur or npm
      --port N           install: port to listen on (saved in the settings file)
      --bind ADDR        install: address to listen on (127.0.0.1 or 0.0.0.0)
      --auth MODE        install: none or password
      --new-password     install: generate a new password
      --claude-code      install: enable Claude Code support without asking
      --no-claude-code   install: disable it without asking
      --skip-update      install: skip `apt update` / `apt upgrade` (faster)
      --purge-data       uninstall: also delete the editor settings, extensions and user data'

tool_opt() {
    case "$1" in
        --method)
            need_value "$1" $#
            METHOD="$2"
            TOOL_SHIFT=2
            ;;
        --method=*) METHOD="${1#*=}" ;;
        --port)
            need_value "$1" $#
            PORT="$2"
            TOOL_SHIFT=2
            ;;
        --port=*) PORT="${1#*=}" ;;
        --bind)
            need_value "$1" $#
            BIND_HOST="$2"
            TOOL_SHIFT=2
            ;;
        --bind=*) BIND_HOST="${1#*=}" ;;
        --auth)
            need_value "$1" $#
            AUTH_MODE="$2"
            TOOL_SHIFT=2
            ;;
        --auth=*) AUTH_MODE="${1#*=}" ;;
        --new-password) NEW_PASSWORD=1 ;;
        --purge-data) PURGE_DATA=1 ;;
        --skip-update) SKIP_UPDATE=1 ;;
        --claude-code) CLAUDE_OPT=1 ;;
        --no-claude-code) CLAUDE_OPT=0 ;;
        --detached) DETACHED=1 ;;
        *) return 1 ;;
    esac
    case "$METHOD" in auto | tur | npm) ;; *) die "--method must be auto, tur or npm (got: $METHOD)" ;; esac
    case "$AUTH_MODE" in '' | none | password) ;; *) die "--auth must be none or password (got: $AUTH_MODE)" ;; esac
    [ -z "$PORT" ] || is_port "$PORT" || die "--port must be a number between 1 and 65535 (got: $PORT)"
    case "$BIND_HOST" in
        *:* | *[[:space:]]* | *\"* | *\'*) die "--bind must be an IPv4 address or a host name (got: $BIND_HOST)" ;;
    esac
}

tool_usage() {
    printf 'Settings: %s   (port, address, authentication, start-up timeout and retries)\n' "$CONF"
}

add_command install "Install and configure code-server, then start it"
add_command start "Start code-server"
add_command stop "Stop code-server"
add_command restart "Restart code-server"
add_command status "Tell whether it is running"
add_command log "Follow the log: log [lines]"
add_command uninstall "Remove code-server (asks before deleting your data)"

tpf_main "$@"
