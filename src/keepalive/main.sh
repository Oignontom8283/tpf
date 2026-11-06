#!/data/data/com.termux/files/usr/bin/bash
# Keep Android from killing Termux (Android 12+), with root or without it.
#
#   termux-keepalive.sh setup    install adb and pair the device (once, no root)
#   termux-keepalive.sh on       turn the protection on
#   termux-keepalive.sh off      restore the original Android settings
#   termux-keepalive.sh status   show the current state
#
# What "on" does (with root or adb):
#   1. Disables the "phantom process killer" (Android 12+) that kills the child
#      processes of Termux (servers, Electron, builds). Same as "Disable child
#      process restrictions" in the developer options.
#   2. Sets the phantom process limit to the maximum and stops Android from
#      putting the default back (device_config sync disabled).
#   3. Adds Termux to the battery-saver (Doze) allowlist.
#   4. Allows Termux to run in the background (appops RUN_ANY_IN_BACKGROUND).
#   5. Takes a wake lock, and (root only) starts a guard that keeps
#      oom_score_adj below zero so lmkd, Android's memory killer, skips Termux.
#
# With root, "su" is used instead of adb: no pairing, no Wi-Fi. Without root,
# adb connects to the device itself through "Wireless debugging".
#
# Not handled here (do it by hand): vendor battery managers and "auto-start"
# lists have their own app killer; a reboot resets some settings, run "on" again.
#
# Environment: TERMUX_KEEPALIVE_MODE=root|adb forces the access mode.
set -u

# tpf:include core
# tpf:include args
# tpf:include log

PKG="com.termux"
STATE_DIR="$HOME/.cache/termux-keepalive"
STATE_FILE="$STATE_DIR/state"
MODE=""          # "root" (su) or "adb", chosen by ensure_access
OOM_TARGET=-300
GUARD_PID="$STATE_DIR/guard.pid"
GUARD_SH="$STATE_DIR/guard.sh"

SDK="$(getprop ro.build.version.sdk 2>/dev/null)"
is_uint "$SDK" || SDK=0

usage() {
    cat <<USAGE
Usage: ${0##*/} [options] setup|on|off|status

  setup    install adb and pair the device (once, no root)
  on       turn the protection on
  off      restore the original Android settings
  status   show the current state

Options:
USAGE
    std_usage
}

# ---------------------------------------------------------------------------
# Access to the Android shell: adb to the device itself, or root
# ---------------------------------------------------------------------------
adb_ready() {   # is a "device" (not offline/unauthorized) connected?
    have adb || return 1
    adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {f=1} END {exit !f}'
}

adb_try_mdns() {   # finds the wireless-debugging port by itself
    local svc
    svc="$(adb mdns services 2>/dev/null | awk '/_adb-tls-connect/ {print $NF; exit}')"
    [ -z "$svc" ] || adb connect "$svc" >/dev/null 2>&1
    adb_ready
}

adb_connect() {
    have adb || { err "adb is not installed. Run first: $0 setup"; return 1; }
    adb start-server >/dev/null 2>&1
    adb_ready && return 0
    adb_try_mdns && return 0
    if [ -s "$STATE_DIR/last_endpoint" ]; then
        adb connect "$(cat "$STATE_DIR/last_endpoint")" >/dev/null 2>&1
        adb_ready && return 0
    fi
    warn "No adb connection. Is Wireless debugging on, with Wi-Fi connected?"
    detail "Developer options > Wireless debugging > note \"IP address & Port\"."
    ask_input "Address:port to connect to (empty to cancel)" ""
    [ -n "$ANSWER" ] || return 1
    adb connect "$ANSWER" 2>&1 | tail -n 1
    adb_ready || { err "Cannot connect."; return 1; }
    echo "$ANSWER" > "$STATE_DIR/last_endpoint"
}

root_available() {
    # Termux's own "su" is only a relay: require a real uid=0 answer.
    have su || return 1
    local out
    out="$(timeout 15 su -c id 2>/dev/null)" || return 1
    case "$out" in *"uid=0("*) return 0 ;; esac
    return 1
}

# Run a command in the Android shell (root or adb, depending on MODE).
sh_adb() {
    if [ "$MODE" = "root" ]; then su -c "$*" 2>&1; else adb shell "$@" 2>&1; fi
}

ensure_access() {
    case "${TERMUX_KEEPALIVE_MODE:-auto}" in
        adb) MODE="adb" ;;
        root)
            root_available || { err "Root requested but 'su' does not give uid=0."; return 1; }
            MODE="root"
            ;;
        *) if root_available; then MODE="root"; else MODE="adb"; fi ;;
    esac
    if [ "$MODE" = "root" ]; then
        ok "Root detected: using su (no adb needed)."
        return 0
    fi
    info "No root: using adb (wireless debugging)."
    adb_connect
}

# ---------------------------------------------------------------------------
# Root only: guard against lmkd.
# lmkd never kills a process whose oom_score_adj is NEGATIVE, but Android
# rewrites that value at every state change of the app. The guard puts it back
# every 3 seconds on all processes of Termux (Electron, code-server, builds...).
# -300 is deliberately less extreme than the system (-800/-900): if memory is
# really exhausted, the system stays first.
# ---------------------------------------------------------------------------
guard_running() {
    [ -s "$GUARD_PID" ] || return 1
    sh_adb "kill -0 $(cat "$GUARD_PID") 2>/dev/null && echo yes" | grep -q yes
}

guard_start() {
    [ "$MODE" = "root" ] || return 0
    local uid
    uid="$(id -u)"
    cat > "$GUARD_SH" <<GEOF
#!/system/bin/sh
# Written by termux-keepalive.sh - runs as root, only writes oom_score_adj.
UID_T=$uid; TARGET=$OOM_TARGET
while true; do
    for d in /proc/[0-9]*; do
        [ "\$(stat -c %u "\$d" 2>/dev/null)" = "\$UID_T" ] || continue
        cur="\$(cat "\$d/oom_score_adj" 2>/dev/null)"
        [ -n "\$cur" ] && [ "\$cur" -gt "\$TARGET" ] && echo "\$TARGET" > "\$d/oom_score_adj" 2>/dev/null
    done
    sleep 3
done
GEOF
    chmod 755 "$GUARD_SH"
    guard_stop quiet
    su -c "nohup sh $GUARD_SH >/dev/null 2>&1 & echo \$! > $GUARD_PID" >/dev/null 2>&1
    sleep 1
    if guard_running; then
        ok "lmkd guard running (oom_score_adj = $OOM_TARGET, pid $(cat "$GUARD_PID"))."
    else
        warn "The lmkd guard did not start."
    fi
}

guard_stop() {
    [ "$MODE" = "root" ] || return 0
    if [ -s "$GUARD_PID" ]; then
        sh_adb "kill $(cat "$GUARD_PID") 2>/dev/null" >/dev/null
        rm -f "$GUARD_PID"
        [ "${1:-}" = "quiet" ] || ok "lmkd guard stopped."
    fi
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
do_setup() {
    if [ "${TERMUX_KEEPALIVE_MODE:-auto}" != "adb" ] && root_available; then
        ok "Root available: no adb pairing needed. Run: $0 on"
        return 0
    fi
    task "Installing adb (android-tools)" pkg install -y android-tools || return 1
    cat <<'GUIDE'

Pairing (once):
  1. Settings > About > tap "Build number" 7 times (developer options).
  2. Developer options > turn on "Wireless debugging" (Wi-Fi connected).
  3. Tap "Wireless debugging" > "Pair device with pairing code".
     A window shows an ADDRESS:PORT and a 6-digit CODE.
     Tip: use a floating window or split screen for Termux, or the window
     closes when Termux comes back to the front.

GUIDE
    local pair code
    ask_input "PAIRING address:port (empty to skip)" ""
    pair="$ANSWER"
    if [ -n "$pair" ]; then
        ask_input "6-digit pairing code" ""
        code="$ANSWER"
        adb pair "$pair" "$code" || { err "Pairing failed."; return 1; }
        ok "Device paired."
    fi
    ask_input "CONNECTION address:port (main Wireless debugging screen, empty = automatic)" ""
    if [ -n "$ANSWER" ]; then
        adb connect "$ANSWER" && echo "$ANSWER" > "$STATE_DIR/last_endpoint"
    else
        adb_try_mdns
    fi
    if adb_ready; then
        ok "Connected. You can run: $0 on"
    else
        warn "Not connected yet. Run '$0 setup' or '$0 on' again (the port changes whenever Wi-Fi is toggled)."
    fi
}

# ---------------------------------------------------------------------------
# on / off
# ---------------------------------------------------------------------------
do_on() {
    [ "$SDK" -ge 31 ] || warn "Android < 12: there is no phantom process killer, only steps 3 to 5 apply."
    ensure_access || return 1

    info "Saving the current values..."
    {
        echo "monitor=$(sh_adb settings get global settings_enable_monitor_phantom_procs | tr -d '\r')"
        echo "maxphantom=$(sh_adb device_config get activity_manager max_phantom_processes | tr -d '\r')"
    } > "$STATE_FILE.new"
    # keep the original backup when "on" is run again
    [ -s "$STATE_FILE" ] || mv "$STATE_FILE.new" "$STATE_FILE"
    rm -f "$STATE_FILE.new"

    info "Disabling the phantom process killer..."
    sh_adb settings put global settings_enable_monitor_phantom_procs false >/dev/null
    sh_adb device_config set_sync_disabled_for_tests persistent >/dev/null
    sh_adb device_config put activity_manager max_phantom_processes 2147483647 >/dev/null

    info "Allowlisting Termux (battery saver and background)..."
    sh_adb cmd deviceidle whitelist +"$PKG" >/dev/null
    sh_adb cmd appops set "$PKG" RUN_ANY_IN_BACKGROUND allow >/dev/null
    sh_adb cmd appops set "$PKG" RUN_IN_BACKGROUND allow >/dev/null

    guard_start
    wake_lock
    ok "Protection on."
    do_status
    echo
    warn "Also to do by hand: Settings > Apps > Termux > Battery > \"Unrestricted\","
    warn "and allow auto-start / background in your vendor's battery manager."
}

do_off() {
    ensure_access || return 1
    local monitor="" maxp=""
    if [ -s "$STATE_FILE" ]; then
        monitor="$(sed -n 's/^monitor=//p' "$STATE_FILE")"
        maxp="$(sed -n 's/^maxphantom=//p' "$STATE_FILE")"
    fi

    info "Restoring the Android settings..."
    case "$monitor" in
        true | false) sh_adb settings put global settings_enable_monitor_phantom_procs "$monitor" >/dev/null ;;
        *) sh_adb settings delete global settings_enable_monitor_phantom_procs >/dev/null ;;
    esac
    sh_adb device_config set_sync_disabled_for_tests none >/dev/null
    case "$maxp" in
        '' | null) sh_adb device_config delete activity_manager max_phantom_processes >/dev/null ;;
        *) sh_adb device_config put activity_manager max_phantom_processes "$maxp" >/dev/null ;;
    esac
    sh_adb cmd deviceidle whitelist -"$PKG" >/dev/null
    sh_adb cmd appops set "$PKG" RUN_ANY_IN_BACKGROUND default >/dev/null
    sh_adb cmd appops set "$PKG" RUN_IN_BACKGROUND default >/dev/null
    guard_stop
    if have termux-wake-unlock; then termux-wake-unlock >/dev/null 2>&1; fi
    rm -f "$STATE_FILE"
    ok "Original settings restored. Android can kill Termux again."
    do_status
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
status_line() { printf '%-34s : %s\n' "$1" "$2"; }

do_status() {
    step "State (Android $(getprop ro.build.version.release), SDK $SDK)"
    if [ -z "$MODE" ]; then
        if [ "${TERMUX_KEEPALIVE_MODE:-auto}" != "adb" ] && root_available; then MODE="root"
        elif adb_ready; then MODE="adb"; fi
    fi
    if [ -z "$MODE" ]; then
        warn "Neither root nor adb: the Android state cannot be read ($0 setup / on)."
        return 0
    fi
    local mon max wl bg
    mon="$(sh_adb settings get global settings_enable_monitor_phantom_procs | tr -d '\r')"
    max="$(sh_adb device_config get activity_manager max_phantom_processes | tr -d '\r')"
    wl="$(sh_adb cmd deviceidle whitelist | grep -c "$PKG")"
    bg="$(sh_adb cmd appops get "$PKG" RUN_ANY_IN_BACKGROUND | tr -d '\r' | head -n1)"
    status_line "Access mode" "$MODE"
    status_line "Phantom process killer (monitor)" "${mon:-?}   (false = disabled = protected)"
    status_line "Phantom process limit" "${max:-?}"
    status_line "Doze allowlist" "$([ "${wl:-0}" -ge 1 ] && echo yes || echo no)"
    status_line "RUN_ANY_IN_BACKGROUND" "${bg:-?}"
    if [ "$MODE" = "root" ]; then
        status_line "oom_score_adj (this shell)" "$(cat /proc/$$/oom_score_adj 2>/dev/null)   (negative = skipped by lmkd)"
        status_line "lmkd guard" "$(guard_running && echo running || echo stopped)"
    fi
    if [ "$mon" = "false" ] && [ "${wl:-0}" -ge 1 ]; then
        ok "Protection ACTIVE."
    else
        warn "Protection INACTIVE or partial."
    fi
}

# ---------------------------------------------------------------------------
COMMAND=""
while [ $# -gt 0 ]; do
    case "$1" in
        setup | on | off | status | help) COMMAND="$1" ;;
        *) std_opt "$@" || die "Unknown argument: $1 (try --help)"; shift "$STD_SHIFT"; continue ;;
    esac
    shift
done

mkdir -p "$STATE_DIR"
log_init
case "$COMMAND" in
    setup) do_setup ;;
    on) do_on ;;
    off) do_off ;;
    status) do_status ;;
    help) usage ;;
    *) usage >&2; exit 2 ;;
esac
