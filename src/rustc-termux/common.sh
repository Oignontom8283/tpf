# Paths, saved choices, root helpers and removal functions shared by the commands.

# ---------------------------------------------------------------------------
# Everything this tool writes on the device is listed here. Nothing else
# is ever touched, which is what lets the uninstaller be exhaustive.
# ---------------------------------------------------------------------------
BASE="${HOME:-}/.rustup-fake"               # fake rustup / cargo / rustc
LEGACY_PROOT_BASE="${HOME:-}/.rustup-proot" # left by an older proot-based script
CONF="${HOME:-}/rust-termux.conf"           # saved choices (defaults for the next run)
LOG_DIR="${HOME:-}/.cache/rust-termux-install"
TOOL_LOG_DIR="$LOG_DIR"
TARGETS_FILE="$BASE/targets"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
CARGO_DATA_DIR="${HOME:-}/.cargo"                 # crate cache, tools from `cargo install`
RC_FILES=("${HOME:-}/.bashrc" "${HOME:-}/.zshrc") # PATH is added here, between markers
RC_BEGIN="# >>> rust-termux >>>"
RC_END="# <<< rust-termux <<<"
REAL_RUSTC="${RUSTUP_FAKE_REAL_RUSTC:-${PREFIX:-}/bin/rustc}" # the compiler from the Termux package
REAL_CARGO="${RUSTUP_FAKE_REAL_CARGO:-${PREFIX:-}/bin/cargo}"

DEPS_REQUIRED=(rust clang make binutils pkg-config lld curl tar xz-utils)
DEPS_OPTIONAL=(cmake git openssl)
# Tiny base tools that other things rely on: never removed by the uninstaller.
PROTECTED_PKGS=" curl tar xz-utils coreutils "

PURGE_DATA=0

q() { printf '%q' "$1"; }

# ---------------------------------------------------------------------------
# Saved choices (~/rust-termux.conf), reused as defaults by the next run
# ---------------------------------------------------------------------------
PREV_CONF=0
load_prev_conf() {
    PREV_CONF=0
    [ -f "$CONF" ] || return 0
    if bash -n "$CONF" 2>/dev/null; then
        PREV_CONF=1
        info "Previous settings found: $CONF"
    else
        warn "$CONF contains a syntax error: saved as $CONF.bak, defaults used."
        mv -f "$CONF" "$CONF.bak" 2>/dev/null
    fi
}
# Read in a subshell so the file cannot overwrite this script's own variables.
conf_get() {
    [ "$PREV_CONF" = 1 ] || return 0
    (
        set +u
        . "$CONF" >/dev/null 2>&1 </dev/null
        printf '%s' "${!1:-}"
    )
}
conf_has() { [ "$PREV_CONF" = 1 ] && grep -q "^$1=" "$CONF" 2>/dev/null; }
prev_or() {
    local v
    v="$(conf_get "$1")"
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}
prev_flag() { if conf_has "$1"; then if [ "$(conf_get "$1")" = 1 ]; then echo yes; else echo no; fi; else echo "$2"; fi; }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
check_termux() {
    [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *"com.termux"* ]] ||
        die "This script must be run INSIDE Termux (\$PREFIX missing or unexpected)."
    [ -n "${HOME:-}" ] || die "\$HOME is not set."
}

# Shims left in the PATH of the current shell by a previous install must not
# be picked up by this script: it always talks to the real tools.
strip_shims_from_path() {
    PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF -e "$BASE/bin" -e "$LEGACY_PROOT_BASE/bin" | paste -sd: -)"
    export PATH
    hash -r 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Android facts and ROOT. Shared by the installer and the uninstaller: what the
# installer changes with root is reverted by the very same functions.
#
# Rules followed everywhere below:
#   - nothing is changed without a question (or an explicit option);
#   - the value found BEFORE each change is saved in ~/rust-termux.conf and
#     put back by the uninstaller (or by the next install);
#   - SELinux, the system partition and the boot image are never touched;
#   - every change is read back, and reported as an error if it did not stick.
# ---------------------------------------------------------------------------
ROOT_ALL="phantom doze inotify oom swap perf"
ROOT_RISKY=" swap perf " # never enabled by --yes alone
SU_BIN=""
ROOT_OK=0
ANDROID_SDK=0
ANDROID_REL=""
TREBLE=""
TERMUX_PKG=""
BOOT_SCRIPT_NAME="rust-termux.sh"

android_info() {
    ANDROID_SDK=0
    ANDROID_REL=""
    TREBLE=""
    if have getprop; then
        ANDROID_SDK="$(getprop ro.build.version.sdk 2>/dev/null)"
        ANDROID_REL="$(getprop ro.build.version.release 2>/dev/null)"
        TREBLE="$(getprop ro.treble.enabled 2>/dev/null)"
    fi
    is_uint "${ANDROID_SDK:-}" || ANDROID_SDK=0
    TERMUX_PKG="${PREFIX#/data/data/}"
    TERMUX_PKG="${TERMUX_PKG%%/*}"
    [ -n "$TERMUX_PKG" ] || TERMUX_PKG="com.termux"
}

# Where is su? (Magisk, KernelSU, APatch, older layouts)
find_su() {
    local c p
    SU_BIN=""
    for c in su /system/bin/su /system/xbin/su /sbin/su /debug_ramdisk/su \
        /data/adb/magisk/su /data/adb/ksu/bin/su /data/adb/ap/bin/su; do
        case "$c" in
            /*) [ -x "$c" ] && {
                SU_BIN="$c"
                return 0
            } ;;
            *)
                p="$(command -v "$c" 2>/dev/null)"
                [ -n "$p" ] && {
                    SU_BIN="$p"
                    return 0
                }
                ;;
        esac
    done
    return 1
}

# Runs one command line as root. Termux's LD_LIBRARY_PATH / LD_PRELOAD must not
# leak into the root shell, otherwise Android's own tools (settings, dumpsys...)
# crash on Termux's libraries.
rsu() {
    local cmd="$1" pre
    pre='unset LD_LIBRARY_PATH LD_PRELOAD; export PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:/data/adb/magisk:/data/adb/ksu/bin:$PATH; '
    if [ "$(id -u)" = 0 ]; then
        timeout "${ROOT_TIMEOUT:-30}" sh -c "$pre$cmd"
    else
        [ -n "$SU_BIN" ] || return 127
        timeout "${ROOT_TIMEOUT:-30}" "$SU_BIN" -c "$pre$cmd" </dev/null
    fi
}

# 0 = root works (the root manager may ask the user to confirm, hence the long wait)
detect_root() {
    local out
    ROOT_OK=0
    if [ "$(id -u)" = 0 ]; then
        ROOT_OK=1
        return 0
    fi
    find_su || return 1
    out="$(ROOT_TIMEOUT=60 rsu 'id -u' 2>/dev/null | tr -d '\r\n ')"
    [ "$out" = 0 ] && ROOT_OK=1
    [ "$ROOT_OK" = 1 ]
}

root_tweak_applicable() {
    case "$1" in
        phantom) [ "$ANDROID_SDK" -ge 31 ] ;;
        *) return 0 ;;
    esac
}

root_tweak_describe() { # prints the question's explanation
    case "$1" in
        phantom)
            plain "   Android 12+ kills the 'phantom' child processes of an app (signal 9) when"
            plain "   there are more than 32 or when they use too much CPU: long builds die for it."
            plain "   Benefit: cargo / rustc are no longer killed in the middle of a build."
            plain "   Risk   : none for the phone; Android's protection against runaway apps is off."
            ;;
        doze)
            plain "   Benefit: Android stops pausing Termux in the background (Doze, battery"
            plain "            optimisation), so a build keeps running with the screen off."
            plain "   Risk   : a little more battery use while Termux is busy."
            ;;
        inotify)
            plain "   Benefit: raises the file-watch limits (many tools and editors fail with"
            plain "            'no space left on device' / 'too many open files' on big projects)."
            plain "   Risk   : a few MB of kernel memory; the value returns to normal at reboot"
            plain "            unless a boot script is installed (asked later)."
            ;;
        oom)
            plain "   Benefit: when memory runs low, Android kills other apps before it kills a"
            plain "            running cargo / rustc (their priority is raised for the build)."
            plain "   Risk   : your root manager is asked (or shows a notice) at each build; if"
            plain "            memory is really exhausted, the phone may become sluggish."
            ;;
        swap)
            plain "   Benefit: a swap file gives the linker more room: big links stop being"
            plain "            killed for lack of RAM."
            plain "   Risk   : it uses several GB of storage and wears flash; many Android"
            plain "            kernels refuse swap files (then it is cleanly cancelled)."
            ;;
        perf)
            plain "   Benefit: the CPU runs at full speed ('performance' governor): builds are"
            plain "            faster."
            plain "   Risk   : the phone heats up and the battery drains faster; the system"
            plain "            may throttle anyway. Lasts until the next reboot only."
            ;;
    esac
}

# ---- individual tweaks: each saves the original value, changes, reads back ----
ROOT_ORIG_PHANTOM=""
ROOT_ORIG_PHANTOM_DC=""
ROOT_ORIG_APPOP=""
ROOT_ORIG_DOZE_ADDED=0
ROOT_ORIG_WATCHES=""
ROOT_ORIG_INSTANCES=""
ROOT_SWAP_FILE=""
ROOT_SWAP_MB=""
ROOT_ORIG_GOV=""
ROOT_BOOT_SCRIPT=""
ROOT_OOM_ADJ=""
ROOT_APPLIED="" # tweaks that really succeeded in this run

root_apply_phantom() {
    if [ "$ANDROID_SDK" -ge 32 ]; then
        ROOT_ORIG_PHANTOM="$(rsu 'settings get global settings_enable_monitor_phantom_procs' 2>/dev/null | tr -d '\r\n')"
        rsu 'settings put global settings_enable_monitor_phantom_procs false' >/dev/null 2>&1
        [ "$(rsu 'settings get global settings_enable_monitor_phantom_procs' 2>/dev/null | tr -d '\r\n')" = false ]
    else # Android 12 (API 31): only the "more than 32 processes" limit can be lifted
        ROOT_ORIG_PHANTOM_DC="$(rsu 'device_config get activity_manager max_phantom_processes' 2>/dev/null | tr -d '\r\n')"
        rsu 'device_config put activity_manager max_phantom_processes 2147483647' >/dev/null 2>&1
        [ "$(rsu 'device_config get activity_manager max_phantom_processes' 2>/dev/null | tr -d '\r\n')" = 2147483647 ]
    fi
}
root_revert_phantom() {
    local o dc
    if [ "$(conf_get RT_ORIG_PHANTOM_DC)" != "" ]; then
        dc="$(conf_get RT_ORIG_PHANTOM_DC)"
        if [ "$dc" = null ]; then
            rsu 'device_config delete activity_manager max_phantom_processes' >/dev/null 2>&1
        else rsu "device_config put activity_manager max_phantom_processes $dc" >/dev/null 2>&1; fi
    fi
    o="$(conf_get RT_ORIG_PHANTOM)"
    if [ -n "$o" ]; then
        if [ "$o" = null ]; then
            rsu 'settings delete global settings_enable_monitor_phantom_procs' >/dev/null 2>&1
        else rsu "settings put global settings_enable_monitor_phantom_procs $o" >/dev/null 2>&1; fi
    fi
    return 0
}

root_apply_doze() {
    local wl
    wl="$(rsu 'dumpsys deviceidle whitelist' 2>/dev/null)"
    if printf '%s' "$wl" | grep -q ",$TERMUX_PKG,"; then
        ROOT_ORIG_DOZE_ADDED=0
    else
        rsu "dumpsys deviceidle whitelist +$TERMUX_PKG" >/dev/null 2>&1
        ROOT_ORIG_DOZE_ADDED=1
    fi
    ROOT_ORIG_APPOP="$(rsu "cmd appops get $TERMUX_PKG RUN_ANY_IN_BACKGROUND" 2>/dev/null | head -n1 | sed -n 's/^RUN_ANY_IN_BACKGROUND: *\([a-z_]*\).*/\1/p')"
    [ -n "$ROOT_ORIG_APPOP" ] || ROOT_ORIG_APPOP=default
    rsu "cmd appops set $TERMUX_PKG RUN_ANY_IN_BACKGROUND allow" >/dev/null 2>&1
    rsu 'dumpsys deviceidle whitelist' 2>/dev/null | grep -q ",$TERMUX_PKG,"
}
root_revert_doze() {
    [ "$(conf_get RT_ORIG_DOZE_ADDED)" = 1 ] && rsu "dumpsys deviceidle whitelist -$TERMUX_PKG" >/dev/null 2>&1
    local m
    m="$(conf_get RT_ORIG_APPOP)"
    [ -n "$m" ] && rsu "cmd appops set $TERMUX_PKG RUN_ANY_IN_BACKGROUND $m" >/dev/null 2>&1
    return 0
}

root_apply_inotify() {
    ROOT_ORIG_WATCHES="$(rsu 'cat /proc/sys/fs/inotify/max_user_watches' 2>/dev/null | tr -d '\r\n')"
    ROOT_ORIG_INSTANCES="$(rsu 'cat /proc/sys/fs/inotify/max_user_instances' 2>/dev/null | tr -d '\r\n')"
    is_uint "$ROOT_ORIG_WATCHES" && is_uint "$ROOT_ORIG_INSTANCES" || return 1
    [ "$ROOT_ORIG_WATCHES" -ge 524288 ] || rsu 'echo 524288 > /proc/sys/fs/inotify/max_user_watches' >/dev/null 2>&1
    [ "$ROOT_ORIG_INSTANCES" -ge 1024 ] || rsu 'echo 1024 > /proc/sys/fs/inotify/max_user_instances' >/dev/null 2>&1
    [ "$(rsu 'cat /proc/sys/fs/inotify/max_user_watches' 2>/dev/null | tr -d '\r\n')" -ge 524288 ] 2>/dev/null
}
root_revert_inotify() {
    local w i
    w="$(conf_get RT_ORIG_WATCHES)"
    i="$(conf_get RT_ORIG_INSTANCES)"
    is_uint "$w" && rsu "echo $w > /proc/sys/fs/inotify/max_user_watches" >/dev/null 2>&1
    is_uint "$i" && rsu "echo $i > /proc/sys/fs/inotify/max_user_instances" >/dev/null 2>&1
    return 0
}

# Raised priority is applied by the fake cargo itself, at each build (see its code);
# here we only record the value it must use.
root_apply_oom() {
    ROOT_OOM_ADJ=-300
    return 0
}
root_revert_oom() { return 0; } # lives in ~/.rustup-fake/settings, which is removed

# root_apply_swap SIZE_MB LOGFILE  (slow: run through run_logged)
root_swap_create() {
    local mb="$1" f="/data/local/rust-termux.swap"
    ROOT_TIMEOUT=1800 rsu "swapoff $f 2>/dev/null; rm -f $f; dd if=/dev/zero of=$f bs=1048576 count=$mb && chmod 600 $f && mkswap $f && swapon $f"
}
root_apply_swap() { # after root_swap_create
    local f="/data/local/rust-termux.swap"
    # /proc/swaps shows the path relative to the mount ("/local/rust-termux.swap"), never "/data/local/...": match the file name
    if rsu 'cat /proc/swaps' 2>/dev/null | grep -q "${f##*/}"; then
        ROOT_SWAP_FILE="$f"
        return 0
    fi
    rsu "swapoff $f; rm -f $f" >/dev/null 2>&1
    return 1
}
root_revert_swap() {
    local f
    f="$(conf_get RT_SWAP_FILE)"
    [ -n "$f" ] || return 0
    rsu "swapoff $f; rm -f $f" >/dev/null 2>&1
    return 0
}

root_apply_perf() {
    local out="" p g avail ok=0
    for p in $(rsu 'ls -d /sys/devices/system/cpu/cpufreq/policy*' 2>/dev/null); do
        g="$(rsu "cat $p/scaling_governor" 2>/dev/null | tr -d '\r\n')"
        avail="$(rsu "cat $p/scaling_available_governors" 2>/dev/null)"
        [ -n "$g" ] || continue
        case " $avail " in *" performance "*) ;; *) continue ;; esac
        out="$out ${p##*/}:$g"
        rsu "echo performance > $p/scaling_governor" >/dev/null 2>&1
        [ "$(rsu "cat $p/scaling_governor" 2>/dev/null | tr -d '\r\n')" = performance ] && ok=1
    done
    ROOT_ORIG_GOV="${out# }"
    [ "$ok" = 1 ]
}
root_revert_perf() {
    local e
    for e in $(conf_get RT_ORIG_GOV); do
        rsu "echo ${e#*:} > /sys/devices/system/cpu/cpufreq/${e%%:*}/scaling_governor" >/dev/null 2>&1
    done
    return 0
}

# ---- boot script: re-applies what Android forgets at reboot (inotify, swap) -------
# It is a plain copy of $BASE/root-boot.sh; installed in a root-manager folder
# when one exists, otherwise in Termux:Boot's folder.
root_write_boot_script() { # $1 = list of applied tweaks
    local f="$BASE/root-boot.sh" t
    {
        echo '#!/system/bin/sh'
        echo '# Written by rustc-termux.sh: re-applies the tweaks Android'
        echo '# forgets at reboot. Removed by the uninstaller.'
        echo 'while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 5; done'
        echo 'sleep 20'
        for t in $1; do
            case "$t" in
                inotify)
                    echo '[ "$(cat /proc/sys/fs/inotify/max_user_watches)" -ge 524288 ] || echo 524288 > /proc/sys/fs/inotify/max_user_watches'
                    echo '[ "$(cat /proc/sys/fs/inotify/max_user_instances)" -ge 1024 ] || echo 1024 > /proc/sys/fs/inotify/max_user_instances'
                    ;;
                swap)
                    [ -n "$ROOT_SWAP_FILE" ] && echo "[ -f $ROOT_SWAP_FILE ] && swapon $ROOT_SWAP_FILE"
                    ;;
                phantom)
                    [ "$ANDROID_SDK" -lt 32 ] && echo 'device_config put activity_manager max_phantom_processes 2147483647'
                    ;;
            esac
        done
    } >"$f" 2>/dev/null || return 1
    [ "$(wc -l <"$f")" -gt 5 ] # something besides the header
}
root_install_boot_script() { # prints the destination on success
    local src="$BASE/root-boot.sh" dst
    if rsu '[ -d /data/adb/service.d ]' 2>/dev/null; then
        dst="/data/adb/service.d/$BOOT_SCRIPT_NAME"
        rsu "cp $src $dst && chmod 755 $dst" >/dev/null 2>&1 && rsu "[ -x $dst ]" 2>/dev/null && {
            echo "$dst"
            return 0
        }
    elif [ -d "$HOME/.termux/boot" ]; then
        dst="$HOME/.termux/boot/$BOOT_SCRIPT_NAME"
        {
            printf '#!/data/data/%s/files/usr/bin/bash\n' "$TERMUX_PKG"
            echo "su -c 'sh $src'"
        } >"$dst" 2>/dev/null &&
            chmod 700 "$dst" && {
            echo "$dst"
            return 0
        }
    fi
    return 1
}

# ---- everything applied earlier is put back (clean reinstall and uninstall) ----
# Needs PREV_CONF loaded. Returns 0 when nothing is left to undo by hand.
root_revert_from_conf() {
    local tw t bs rc=0
    tw="$(conf_get RT_ROOT_TWEAKS)"
    bs="$(conf_get RT_BOOT_SCRIPT)"
    [ -n "$tw" ] || [ -n "$bs" ] || return 0
    android_info
    info "Root tweaks applied earlier: ${tw:-none}"
    if ! detect_root; then
        warn "Root access is not available now: the earlier root tweaks cannot be reverted."
        plain "    They only last until the next reboot, except these which are stored by Android:"
        for t in $tw; do
            case "$t" in
                phantom) plain "    - phantom killer: adb/root: settings delete global settings_enable_monitor_phantom_procs" ;;
                doze) plain "    - Doze exemption: Settings > Apps > Termux > Battery > Optimised" ;;
                swap) plain "    - swap file $(conf_get RT_SWAP_FILE): root: swapoff it, then delete it" ;;
            esac
        done
        [ -n "$bs" ] && plain "    - boot script $bs: delete it with root"
        return 1
    fi
    for t in $tw; do
        case "$t" in
            phantom) root_revert_phantom ;;
            doze) root_revert_doze ;;
            inotify) root_revert_inotify ;;
            oom) root_revert_oom ;;
            swap) root_revert_swap ;;
            perf) root_revert_perf ;;
        esac
        ok "Root tweak reverted: $t"
    done
    if [ -n "$bs" ]; then
        case "$bs" in
            /data/adb/*) rsu "rm -f $bs" >/dev/null 2>&1 ;;
            *) rm -f "$bs" ;;
        esac
        ok "Boot script removed: $bs"
    fi
    return $rc
}

# Lines saved in the conf file (values found BEFORE the changes, for the revert)
root_conf_lines() {
    echo "# Root tweaks really applied (the uninstaller reverts them)"
    echo "RT_ROOT_TWEAKS=$(q "$ROOT_APPLIED")"
    echo "RT_ORIG_PHANTOM=$(q "$ROOT_ORIG_PHANTOM")"
    echo "RT_ORIG_PHANTOM_DC=$(q "$ROOT_ORIG_PHANTOM_DC")"
    echo "RT_ORIG_DOZE_ADDED=$ROOT_ORIG_DOZE_ADDED"
    echo "RT_ORIG_APPOP=$(q "$ROOT_ORIG_APPOP")"
    echo "RT_ORIG_WATCHES=$(q "$ROOT_ORIG_WATCHES")"
    echo "RT_ORIG_INSTANCES=$(q "$ROOT_ORIG_INSTANCES")"
    echo "RT_SWAP_FILE=$(q "$ROOT_SWAP_FILE")"
    echo "RT_ORIG_GOV=$(q "$ROOT_ORIG_GOV")"
    echo "RT_BOOT_SCRIPT=$(q "$ROOT_BOOT_SCRIPT")"
}

# ---------------------------------------------------------------------------
# Removal. The same functions serve the clean reinstall (default) and the
# uninstaller, so both erase exactly the same things.
# ---------------------------------------------------------------------------

# Removes our PATH block from the shell start-up files, plus the one-line
# forms written by earlier versions of these scripts.
remove_shell_integration() {
    local rc found=0 hasblock before after
    for rc in "${RC_FILES[@]}"; do
        [ -f "$rc" ] || continue
        grep -qE 'rust-termux|rustup-fake|rustup-proot|^# Faux rustup' "$rc" 2>/dev/null || continue
        found=1
        before="$(wc -l <"$rc")"
        cp -f "$rc" "$rc.rust-termux.bak" 2>/dev/null
        # A block is only removed as a whole when both of its markers are
        # present (a lone marker must never swallow the rest of the file).
        # The blank lines that surrounded our lines go away with them, so the
        # file comes back exactly as it was before the install.
        hasblock=0
        if grep -q '^# >>> rust-termux >>>$' "$rc" && grep -q '^# <<< rust-termux <<<$' "$rc"; then hasblock=1; fi
        awk -v b="$RC_BEGIN" -v e="$RC_END" -v hasblock="$hasblock" '
            function ours(l) { return l ~ /\.rustup-fake\/bin/ || l ~ /\.rustup-proot\/bin/ || l ~ /^# Faux rustup/ }
            {
                if (hasblock == 1) {
                    if (skip) { if ($0 == e) skip = 0; drop = 1; next }
                    if ($0 == b) { skip = 1; drop = 1; next }
                } else if ($0 == b || $0 == e) { drop = 1; next }
                if (ours($0)) { drop = 1; next }
                if ($0 ~ /^[[:space:]]*$/) { held[++run] = $0; next }
                n = run
                if (drop && n > 1) n = 1
                if (drop && !printed) n = 0
                for (i = 1; i <= n; i++) print held[i]
                print; printed = 1; run = 0; drop = 0
            }
            END { if (!drop) for (i = 1; i <= run; i++) print held[i] }
        ' "$rc" >"$rc.rust-termux.tmp" && cat "$rc.rust-termux.tmp" >"$rc"
        rm -f "$rc.rust-termux.tmp"
        after="$(wc -l <"$rc")"
        if grep -qE 'rustup-fake|rustup-proot|# >>> rust-termux >>>' "$rc" 2>/dev/null; then
            warn "Could not fully clean $rc: please check it by hand (backup: $rc.rust-termux.bak)."
        elif [ $((before - after)) -gt 12 ]; then
            warn "$rc lost $((before - after)) lines, more than expected: backup kept ($rc.rust-termux.bak)."
        else
            # Only our own lines went away: the safety copy is no longer needed.
            rm -f "$rc.rust-termux.bak"
            if ! grep -q '[^[:space:]]' "$rc" 2>/dev/null; then
                rm -f "$rc"
                ok "Shell configuration cleaned: $rc was left empty and has been removed"
            else
                ok "Shell configuration cleaned: $rc"
            fi
        fi
    done
    [ "$found" = 1 ] || info "No PATH entry found in the shell start-up files."
}

# Removes everything the installer itself created, except the saved settings,
# ~/.cargo and the Termux packages (those are handled by the callers).
remove_install_files() {
    local d src n=0 f
    # standard libraries the fake rustup built into Termux's own sysroot
    if [ -d "$BASE/std-installed" ]; then
        for f in "$BASE"/std-installed/*; do
            [ -f "$f" ] || continue
            rm -rf "$PREFIX/lib/rustlib/$(basename "$f")" && ok "Removed standard library: $(basename "$f")"
            n=$((n + 1))
        done
    fi
    for d in "$BASE" "$LEGACY_PROOT_BASE"; do
        [ -e "$d" ] || continue
        rm -rf "$d" 2>/dev/null
        if [ -e "$d" ]; then warn "Could not remove: $d"; else ok "Removed: $d"; fi
        n=$((n + 1))
    done

    # Rust sources extracted into Termux's own tree (unless a package owns them).
    src="$PREFIX/lib/rustlib/src"
    if [ -e "$src" ]; then
        if dpkg -S "$src" >/dev/null 2>&1; then
            info "The Rust sources belong to a Termux package: kept ($src)"
        else
            rm -rf "$src" 2>/dev/null
            if [ -e "$src" ]; then warn "Could not remove: $src"; else ok "Removed: $src"; fi
            n=$((n + 1))
        fi
    fi

    # Helper command from the very first script.
    if [ -f "$PREFIX/bin/cargo-wasm" ] && grep -q 'wasm32-unknown-unknown' "$PREFIX/bin/cargo-wasm" 2>/dev/null; then
        rm -f "$PREFIX/bin/cargo-wasm" && ok "Removed: $PREFIX/bin/cargo-wasm" && n=$((n + 1))
    fi

    # Test projects left behind by an interrupted run.
    for d in "$HOME"/.rust-termux-test.* "$HOME"/rust-test.*; do
        [ -d "$d" ] || continue
        case "$d" in
            */.rust-termux-test.*) ;;
            */rust-test.*) [ -d "$d/test-rust" ] || continue ;;
        esac
        rm -rf "$d" && ok "Removed leftover test directory: $d" && n=$((n + 1))
    done

    [ "$n" -gt 0 ] || info "No previous installation found."
    hash -r 2>/dev/null || true
    return 0
}

# Purges one package, but only if nothing else would be removed along with it.
purge_pkg_safe() {
    local p="$1" extra
    dpkg_installed "$p" || return 0
    extra="$(apt-get -s purge "$p" 2>/dev/null | awk '/^Remv /{print $2}' | grep -vxF "$p" | tr '\n' ' ')"
    if [ -n "${extra// /}" ]; then
        warn "Package '$p' is needed by: ${extra}- kept."
        return 2
    fi
    run_logged "$2" 20 "$LOG_DIR/apt_purge_$p.log" apt-get "${APT_OPTS[@]}" purge "$p"
}

# conf_load_quiet: make conf_get work for the commands that only read the settings.
conf_load_quiet() {
    PREV_CONF=0
    if [ -f "$CONF" ] && bash -n "$CONF" 2>/dev/null; then PREV_CONF=1; fi
}

# conf_set KEY VALUE: change (or add) one saved choice, quoted with %q.
conf_set() {
    local key="$1" val="$2" tmp="$CONF.tmp" line found=0
    touch "$CONF"
    : >"$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key="*)
                printf '%s=%q\n' "$key" "$val" >>"$tmp"
                found=1
                ;;
            *) printf '%s\n' "$line" >>"$tmp" ;;
        esac
    done <"$CONF"
    [ "$found" = 1 ] || printf '%s=%q\n' "$key" "$val" >>"$tmp"
    mv -f "$tmp" "$CONF"
}
