# Log directory of a script. Everything printed by info/ok/warn/err/step is also
# recorded (without colours) in $TPF_LOG_DIR/run.log; task output goes to one file
# per task in the same directory.
#
# Command: log_init [DIR]   (default: ~/.cache/tpf/$TPF_NAME, or --log-dir)
# tpf:include core

log_init() {
    TPF_LOG_DIR="${TPF_LOG_DIR:-${1:-$HOME/.cache/tpf/$TPF_NAME}}"
    mkdir -p "$TPF_LOG_DIR" 2>/dev/null || { warn "Cannot create the log directory $TPF_LOG_DIR"; TPF_LOG_DIR=""; return 0; }
}
