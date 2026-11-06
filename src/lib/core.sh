# Basics shared by every installer: checks, clean exit, signals, wake lock.
#
# Commands: have is_uint is_port require_termux require_aarch64
#           on_exit wake_lock
# tpf:include ui

have()    { command -v "$1" >/dev/null 2>&1; }
is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; }
is_port() { is_uint "${1:-}" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

require_termux() {
    case "${PREFIX:-}" in
        *com.termux*) ;;
        *) die "This script must be run inside Termux." ;;
    esac
    [ -n "${HOME:-}" ] || die "\$HOME is not set."
}

require_aarch64() {
    case "$(uname -m)" in
        aarch64 | arm64) ;;
        *) die "Only 64-bit ARM (aarch64) is supported (this device: $(uname -m))." ;;
    esac
}

# ---------------------------------------------------------------------------
# Clean exit. Register cleanup commands with on_exit; they run in reverse
# order when the script ends, whatever the reason (end, die, Ctrl-C).
# ---------------------------------------------------------------------------
_TPF_EXIT_CMDS=()

on_exit() { _TPF_EXIT_CMDS+=("$1"); }

_tpf_exit() {
    local status=$? i
    trap - EXIT
    if [ -n "${_TASK_PID:-}" ]; then _ui_kill_tree "$_TASK_PID"; fi
    _ui_cleanup
    for ((i = ${#_TPF_EXIT_CMDS[@]} - 1; i >= 0; i--)); do
        eval "${_TPF_EXIT_CMDS[i]}" || true
    done
    exit "$status"
}

_tpf_signal() {   # name status
    printf '\n' >&2
    err "Interrupted ($1)."
    exit "$2"
}

trap _tpf_exit EXIT
trap '_tpf_signal INT 130' INT
trap '_tpf_signal TERM 143' TERM

# wake_lock: keep Android from suspending Termux until the script ends.
_TPF_WAKE=0
wake_lock() {
    [ "$_TPF_WAKE" = 0 ] || return 0
    if have termux-wake-lock && termux-wake-lock >/dev/null 2>&1; then
        _TPF_WAKE=1
        on_exit 'termux-wake-unlock >/dev/null 2>&1'
    fi
    return 0
}
