# Output style shared by every installer (see docs/STYLE.md).
#
#   [INFO] [ OK ] [ ?? ] [WARN]    six columns: the text always starts at column 8
#   [ERROR]                        danger: seven columns, written to stderr
#   [.   ] [..  ] [... ] ...       a task that is running (see task)
#
# Commands: info ok warn err detail step banner die
#           ask_yes_no ask_input ask_choice task
# Variable: TPF_ASSUME=yes|no answers every question without asking.

_UI_FRAMES=('[.   ]' '[..  ]' '[... ]' '[ ...]' '[  ..]' '[   .]')
_UI_CURSOR_HIDDEN=0
_TASK_PID=""

# ui_colors on|off|auto
ui_colors() {
    local mode="${1:-auto}"
    if [ "$mode" = auto ]; then
        if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ]; then mode=on; else mode=off; fi
    fi
    if [ "$mode" = on ]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
        C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'
        C_ERR=$'\033[1;31m'; C_ASK=$'\033[1;36m'
    else
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_ASK=""
    fi
}
ui_colors auto

# True when a running task can be animated in place.
_ui_animated() {
    [ -t 1 ] && [ "${TERM:-}" != dumb ] && [ -z "${TPF_NO_ANIM:-}" ]
}

# Everything printed is also appended, without colours, to $TPF_LOG_DIR/run.log.
_ui_log() {
    [ -n "${TPF_LOG_DIR:-}" ] && [ -d "${TPF_LOG_DIR}" ] || return 0
    printf '%s %-5s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >>"$TPF_LOG_DIR/run.log" 2>/dev/null || true
}

_ui_line() {   # colour tag text
    printf '%s%s%s %s\n' "$1" "$2" "$C_RESET" "$3"
}

info() { _ui_line "$C_INFO" '[INFO]' "$*"; _ui_log INFO "$*"; }
ok()   { _ui_line "$C_OK" '[ OK ]' "$*"; _ui_log OK "$*"; }
warn() { _ui_line "$C_WARN" '[WARN]' "$*"; _ui_log WARN "$*"; }
err()  { _ui_line "$C_ERR" '[ERROR]' "$*" >&2; _ui_log ERROR "$*"; }

# A dimmed line aligned with the text of the lines above.
detail() { printf '       %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

step() {
    printf '\n%s=== %s ===%s\n' "$C_INFO" "$*" "$C_RESET"
    _ui_log STEP "$*"
}

# banner TITLE [SUBTITLE]
banner() {
    local bar="============================================================"
    printf '\n%s%s\n %s\n' "$C_OK" "$bar" "$1"
    [ -z "${2:-}" ] || printf ' %s\n' "$2"
    printf '%s%s\n' "$bar" "$C_RESET"
}

die() {
    err "$*"
    if [ -n "${TPF_LOG_DIR:-}" ] && [ -d "${TPF_LOG_DIR}" ]; then
        printf '       %sLogs: %s%s\n' "$C_DIM" "$TPF_LOG_DIR" "$C_RESET" >&2
    fi
    exit 1
}

# ---------------------------------------------------------------------------
# Questions. They read /dev/tty, so they also work with `curl ... | bash`.
# The answer of ask_input / ask_choice is left in $ANSWER.
# ---------------------------------------------------------------------------
_ui_have_tty() { ( : </dev/tty ) 2>/dev/null; }

_ui_prompt() {   # text; reads one line from the terminal into $_UI_REPLY
    _UI_REPLY=""
    printf '%s[ ?? ]%s %s' "$C_ASK" "$C_RESET" "$1" >/dev/tty
    IFS= read -r _UI_REPLY </dev/tty || _UI_REPLY=""
}

# ask_yes_no "question" [yes|no]   -> status 0 for yes
ask_yes_no() {
    local question="$1" def="${2:-no}" hint
    case "${TPF_ASSUME:-}" in
        yes) _ui_line "$C_ASK" '[ ?? ]' "$question ${C_DIM}[auto: yes]${C_RESET}"; return 0 ;;
        no)  _ui_line "$C_ASK" '[ ?? ]' "$question ${C_DIM}[auto: no]${C_RESET}"; return 1 ;;
    esac
    if [ "$def" = yes ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    if _ui_have_tty; then
        _ui_prompt "$question $hint "
        case "$_UI_REPLY" in
            y|Y|yes|Yes|YES|o|O|oui|Oui|OUI) return 0 ;;
            n|N|no|No|NO|non|Non|NON) return 1 ;;
            *) [ "$def" = yes ]; return ;;
        esac
    fi
    warn "No terminal available: default answer \"$def\" used ($question)"
    [ "$def" = yes ]
}

# ask_input "question" "default"   -> $ANSWER
ask_input() {
    local question="$1" def="${2:-}"
    ANSWER="$def"
    if [ -n "${TPF_ASSUME:-}" ]; then
        _ui_line "$C_ASK" '[ ?? ]' "$question ${C_DIM}[auto: ${def:-empty}]${C_RESET}"
        return 0
    fi
    if _ui_have_tty; then
        _ui_prompt "$question${def:+ [$def]} "
        [ -z "$_UI_REPLY" ] || ANSWER="$_UI_REPLY"
        return 0
    fi
    warn "No terminal available: default \"${def:-empty}\" used ($question)"
}

# ask_choice "question" DEFAULT option...   -> $ANSWER (one of the options)
ask_choice() {
    local question="$1" def="$2" opt n=0
    shift 2
    ANSWER="$def"
    if [ -n "${TPF_ASSUME:-}" ] || ! _ui_have_tty; then
        _ui_line "$C_ASK" '[ ?? ]' "$question ${C_DIM}[auto: $def]${C_RESET}"
        return 0
    fi
    _ui_line "$C_ASK" '[ ?? ]' "$question"
    for opt in "$@"; do
        n=$((n + 1))
        printf '       %s%d)%s %s%s\n' "$C_BOLD" "$n" "$C_RESET" "$opt" "$([ "$opt" = "$def" ] && printf ' (default)')"
    done
    _ui_prompt "Choice [1-$n or name] "
    n=0
    for opt in "$@"; do
        n=$((n + 1))
        if [ "$_UI_REPLY" = "$n" ] || [ "$_UI_REPLY" = "$opt" ]; then ANSWER="$opt"; return 0; fi
    done
    [ -z "$_UI_REPLY" ] || warn "\"$_UI_REPLY\" is not an option: default \"$def\" used"
}

# ---------------------------------------------------------------------------
# task "message" command [args...]
#
# Runs the command with its output sent to a log file and shows an animated
# [.   ] [..  ] [... ] marker while it runs, then replaces it by [ OK ] or
# [ERROR]. Returns the status of the command; on failure the last lines of the
# log are shown. The command runs in a subshell: variables it sets are lost.
# ---------------------------------------------------------------------------
_ui_cleanup() {
    if [ "$_UI_CURSOR_HIDDEN" = 1 ]; then printf '\033[?25h'; _UI_CURSOR_HIDDEN=0; fi
}

_task_logfile() {
    local slug
    slug="$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-' | tr -s '-' | sed 's/^-//; s/-$//' | cut -c1-48)"
    printf '%s/%s.log' "${TPF_LOG_DIR:-${TMPDIR:-/tmp}}" "${slug:-task}"
}

task() {
    local msg="$1" log rc=0 i=0 started=$SECONDS took=""
    shift
    [ -z "${TPF_LOG_DIR:-}" ] || mkdir -p "$TPF_LOG_DIR" 2>/dev/null || true
    log="$(_task_logfile "$msg")"
    if _ui_animated; then
        "$@" >"$log" 2>&1 </dev/null &
        _TASK_PID=$!
        printf '\033[?25l'; _UI_CURSOR_HIDDEN=1
        while kill -0 "$_TASK_PID" 2>/dev/null; do
            printf '\r\033[K%s%s%s %s' "$C_INFO" "${_UI_FRAMES[i % ${#_UI_FRAMES[@]}]}" "$C_RESET" "$msg"
            i=$((i + 1))
            sleep 0.15
        done
        wait "$_TASK_PID"; rc=$?
        _TASK_PID=""
        printf '\r\033[K'
        _ui_cleanup
    else
        _ui_line "$C_INFO" '[ .. ]' "$msg"
        "$@" >"$log" 2>&1 </dev/null; rc=$?
    fi
    [ $((SECONDS - started)) -lt 2 ] || took=" ${C_DIM}($((SECONDS - started))s)${C_RESET}"
    if [ "$rc" -eq 0 ]; then
        _ui_line "$C_OK" '[ OK ]' "$msg$took"
        _ui_log OK "$msg"
    else
        _ui_line "$C_ERR" '[ERROR]' "$msg (exit $rc)$took" >&2
        _ui_log ERROR "$msg (exit $rc)"
        if [ -s "$log" ]; then
            tail -n 8 "$log" | sed "s/^/       ${C_DIM}/; s/\$/${C_RESET}/" >&2
            printf '       %sFull log: %s%s\n' "$C_DIM" "$log" "$C_RESET" >&2
        fi
    fi
    return "$rc"
}
