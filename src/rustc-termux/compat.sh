# The output interface this tool was written with, on top of the shared ui
# module: the code keeps calling denied, plain, title, phase_begin, run_logged...
# The percentage bar is replaced by the animated markers of the shared module.

PHASE_BASE=0
PHASE_W=0
TEST_DIR=""
FAILED=0

denied() { err "$*"; }
plain() { printf '%s\n' "$*"; }
title() { step "$1"; }

bar_start() { :; }
bar_set() { :; }
bar_hide() { :; }
bar_render() { :; }
bar_finish() { :; }

# phase_begin "Title" WEIGHT: a titled step.
phase_begin() {
    PHASE_BASE=$((PHASE_BASE + PHASE_W))
    PHASE_W="$2"
    step "$1"
}
pct_at() { echo $((PHASE_BASE + PHASE_W * $1 / $2)); }

# run_logged HI EXPECTED_SECONDS LOGFILE command...
# Runs the command with its output sent to LOGFILE, showing a running marker
# named after the log file (apt_update.log -> "Apt update").
run_logged() {
    local log="$3" label
    shift 3
    label="$(basename "$log" .log | tr '_-' '  ')"
    spin_run "${label^}" "$log" "$@"
}

rust_cleanup() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then rm -rf "$TEST_DIR"; fi
}
on_exit rust_cleanup
