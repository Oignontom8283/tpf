# Command dispatcher shared by every tool, so that all of them speak the same way:
#
#   tool.sh [options] install | reinstall | uninstall | status | start | stop | restart | log | help
#
# A tool defines one function cmd_<name> per command (dashes become underscores),
# registers them, and calls tpf_main:
#
#   cmd_install()   { ...; }
#   cmd_uninstall() { ...; }
#   add_command install   "Install the tool"
#   add_command uninstall "Remove the tool"
#   tpf_main "$@"
#
# Optional hooks and variables:
#   tool_opt "$@"            handle a tool option: return 0 and set TOOL_SHIFT (default 1)
#   tool_usage               extra help text, printed after the list of commands
#   TOOL_OPTIONS_HELP        text for the tool's own options, printed with the common ones
#   TOOL_DEFAULT_COMMAND     command used when none is given (default: help)
#   TOOL_LOG_DIR             log directory (default: ~/.cache/tpf/<name>)
#
# "reinstall" exists as soon as install and uninstall do: uninstall (TPF_KEEP_DATA=1
# tells it to keep the user's data), then install. A tool may define its own.
# "help" and "version" always exist. The command words after the first one are
# passed to the command as arguments.
# tpf:include core
# tpf:include args
# tpf:include log

_TPF_CMDS=()
_TPF_CMD_HELP=()
TOOL_SHIFT=1
TPF_KEEP_DATA=0
CMD_ARGS=()

# add_command NAME "one line description"
add_command() {
    _TPF_CMDS+=("$1")
    _TPF_CMD_HELP+=("$2")
}

_cmd_known() {
    local name
    for name in "${_TPF_CMDS[@]}"; do [ "$name" = "$1" ] && return 0; done
    return 1
}

cmd_help() {
    local i
    printf 'Usage: %s [options] <command> [arguments]\n\nCommands:\n' "${TPF_SCRIPT:-$TPF_NAME}"
    for i in "${!_TPF_CMDS[@]}"; do
        printf '  %-12s %s\n' "${_TPF_CMDS[i]}" "${_TPF_CMD_HELP[i]}"
    done
    printf '  %-12s %s\n' help "Show this help"
    printf '  %-12s %s\n' version "Print the version"
    if declare -F tool_usage >/dev/null; then
        printf '\n'
        tool_usage
    fi
    printf '\nOptions:\n'
    if [ -n "${TOOL_OPTIONS_HELP:-}" ]; then printf '%s\n' "$TOOL_OPTIONS_HELP"; fi
    std_usage
}

cmd_version() { printf '%s %s\n' "$TPF_NAME" "$TPF_VERSION"; }

cmd_reinstall() {
    TPF_KEEP_DATA=1
    cmd_uninstall "$@" || die "The removal step failed: nothing was installed again."
    TPF_KEEP_DATA=0
    cmd_install "$@"
}

# std_opt calls usage() for -h/--help.
usage() { cmd_help; }

tpf_main() {
    local command_word="" fn status=0 only_args=0
    TPF_SCRIPT="${0##*/}"
    CMD_ARGS=()
    while [ $# -gt 0 ]; do
        if [ "$only_args" = 1 ] || [ "${1#-}" = "$1" ]; then
            if [ -z "$command_word" ]; then command_word="$1"; else CMD_ARGS+=("$1"); fi
            shift
            continue
        fi
        if [ "$1" = "--" ]; then only_args=1; shift; continue; fi
        TOOL_SHIFT=1
        if declare -F tool_opt >/dev/null && tool_opt "$@"; then
            shift "$TOOL_SHIFT"
        elif std_opt "$@"; then
            shift "$STD_SHIFT"
        else
            err "Unknown option: $1 (try: $TPF_SCRIPT help)"
            exit 2
        fi
    done

    if declare -F cmd_install >/dev/null && declare -F cmd_uninstall >/dev/null && ! _cmd_known reinstall; then
        add_command reinstall "Remove (keeping your data), then install again"
    fi
    command_word="${command_word:-${TOOL_DEFAULT_COMMAND:-help}}"
    case "$command_word" in
        help | version) ;;
        *)
            if ! _cmd_known "$command_word"; then
                err "Unknown command: $command_word (try: $TPF_SCRIPT help)"
                exit 2
            fi
            ;;
    esac
    fn="cmd_${command_word//-/_}"
    if ! declare -F "$fn" >/dev/null; then
        err "The command $command_word is registered but $fn is not defined."
        exit 2
    fi
    case "$command_word" in help | version) ;; *) log_init "${TOOL_LOG_DIR:-}" ;; esac
    "$fn" "${CMD_ARGS[@]}" || status=$?
    exit "$status"
}
