# Command line options common to every installer.
#
#   -y, --yes   -n, --no   --no-color   --log-dir DIR   -V, --version   -h, --help
#
# In the option loop of a script:
#
#   while [ $# -gt 0 ]; do
#       case "$1" in
#           --my-option) MY=1 ;;
#           *) std_opt "$@" || die "Unknown option: $1 (try --help)"; shift "$STD_SHIFT"; continue ;;
#       esac
#       shift
#   done
#
# The script defines usage() and may print std_usage inside it.
# tpf:include core

STD_SHIFT=1
TPF_ASSUME="${TPF_ASSUME:-}"

# need_value OPTION ARGC   -> dies when an option that takes a value has none
need_value() {
    [ "$2" -ge 2 ] || die "Option $1 needs a value (try --help)"
}

std_usage() {
    cat <<'USAGE'
  -y, --yes        Answer "yes" to every question
  -n, --no         Answer "no" to every question
      --no-color   Plain output without colours
      --log-dir D  Write the logs to D
  -V, --version    Print the version and exit
  -h, --help       Show this help
USAGE
}

# std_opt "$@": handles the first argument if it is a common option.
# Returns 1 when it is not one. Sets STD_SHIFT to the number of arguments used.
std_opt() {
    STD_SHIFT=1
    case "$1" in
        -y | --yes) TPF_ASSUME=yes ;;
        -n | --no) TPF_ASSUME=no ;;
        --no-color) ui_colors off ;;
        --log-dir)
            need_value "$1" $#
            TPF_LOG_DIR="$2"
            STD_SHIFT=2
            ;;
        --log-dir=*) TPF_LOG_DIR="${1#*=}" ;;
        -V | --version)
            printf '%s %s\n' "$TPF_NAME" "$TPF_VERSION"
            exit 0
            ;;
        -h | --help)
            if declare -F usage >/dev/null; then usage; else printf 'Usage: %s [options]\n' "$TPF_NAME"; fi
            exit 0
            ;;
        *) return 1 ;;
    esac
}
