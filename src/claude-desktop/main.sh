#!/data/data/com.termux/files/usr/bin/bash
#
# install-claude-desktop-termux.sh
# ============================================================================
# Runs the OFFICIAL Claude Desktop for Linux (arm64 .deb published by
# Anthropic) on Termux, WITHOUT proot-distro and WITHOUT root.
#
# How it works
#   1. glibc-runner (Termux glibc repository) provides the glibc loader that
#      Android lacks.
#   2. The official arm64 .deb is downloaded from Anthropic's apt repository
#      and unpacked into a private folder (no apt, no dpkg database).
#   3. The Debian libraries that the app depends on (GTK, NSS, ALSA, ...)
#      are downloaded from Debian's archive, resolved from the .deb's own
#      "Depends" line, and unpacked into a private folder too.
#   4. The Electron binaries are patched (patchelf) to use the Termux glibc
#      loader and the private libraries.
#   5. ~/claude-desktop.sh starts Termux:X11, a window manager and the app.
#
# You also need the "Termux:X11" Android app (APK from
# https://github.com/termux/termux-x11/releases), installed and opened
# when you start Claude Desktop.
#
# Known limits (Android, not this script)
#   - no sandbox: the app is started with --no-sandbox (Android blocks the
#     kernel features Chromium's sandbox needs);
#   - no GPU acceleration: software rendering is used;
#   - Cowork (needs KVM / QEMU) and Computer Use do not work;
#   - the sign-in is not saved in a keyring (--password-store=basic).
#
# Terminal access
#   The integrated terminal and the commands run by Claude Code in the app
#   use a NORMAL Termux bash (your usual PATH, packages, /bin/sh support),
#   not the modified environment the app itself needs. See "Normal terminal
#   for Claude" below.
#
# Run `bash install-claude-desktop-termux.sh --help` for the options.
# ============================================================================

set -uo pipefail

# tpf:include core
# tpf:include args
# tpf:include log
# tpf:include pkg

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: bash install-claude-desktop-termux.sh [options]

Options:
  --reinstall          Delete the installed app and libraries, install again
  --skip-update        Skip `apt update` / `apt upgrade` (faster)
  --debian RELEASE     Debian release the libraries come from
                       (default: bookworm)
  --uninstall          Remove everything installed by this script and exit
  --purge-data         With --uninstall: also delete the app's own data
                       (~/.config/Claude, which holds the sign-in)
  -h, --help           Show this help

Afterwards:   ~/claude-desktop.sh            start Claude Desktop
              ~/claude-desktop.sh stop       stop it
              ~/claude-desktop.sh log        show the log

Common options:
EOF
    std_usage
    exit 0
}

REINSTALL=0; SKIP_UPDATE=0; DEBIAN_RELEASE="bookworm"; UNINSTALL=0; PURGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --reinstall)   REINSTALL=1 ;;
        --skip-update) SKIP_UPDATE=1 ;;
        --debian)      [ $# -ge 2 ] || { err "--debian needs a value"; exit 2; }; DEBIAN_RELEASE="$2"; shift ;;
        --debian=*)    DEBIAN_RELEASE="${1#*=}" ;;
        --uninstall)   UNINSTALL=1 ;;
        --purge-data)  PURGE=1 ;;
        *)             std_opt "$@" || die "Unknown option: $1 (try --help)"; shift "$STD_SHIFT"; continue ;;
    esac
    shift
done
case "$DEBIAN_RELEASE" in *[!a-z0-9-]*|'') die "--debian: invalid release name" ;; esac

# ---------------------------------------------------------------------------
# Environment and paths
# ---------------------------------------------------------------------------
require_termux

require_aarch64

BASE="$HOME/.local/share/claude-desktop-termux"
WORK="$BASE/download"
APP_ROOT="$BASE/app"          # unpacked official .deb
LIB_ROOT="$BASE/libs"         # unpacked Debian libraries
ETC_DIR="$BASE/etc"           # fonts.conf, resolv helpers
LAUNCHER="$HOME/claude-desktop.sh"
LOG_DIR="$HOME/.cache/claude-desktop-install"
GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
mkdir -p "$BASE" || die "Cannot create $BASE"
log_init "$LOG_DIR"

# Keeps Android from suspending Termux during the long steps.
wake_lock

banner "Claude Desktop for Termux" "installer v$TPF_VERSION"

# ---------------------------------------------------------------------------
# --uninstall
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
    step "Uninstall"
    "$LAUNCHER" stop >/dev/null 2>&1
    rm -rf "$BASE" "$LAUNCHER" "$HOME/.claude-desktop.log" 2>/dev/null
    if [ "$PURGE" = "1" ]; then
        rm -rf "$HOME/.config/Claude" 2>/dev/null
        ok "App data deleted."
    fi
    ok "Claude Desktop removed. (Termux packages such as glibc-runner were kept.)"
    exit 0
fi

# ---------------------------------------------------------------------------
# 1. Termux packages
# ---------------------------------------------------------------------------
step "Termux packages"
if [ "$SKIP_UPDATE" = "1" ]; then
    info "Update skipped (--skip-update)."
else
    apt_repair
    pkg_update || warn "apt update failed (see $LOG_DIR): run 'termux-change-repo' if a mirror is down."
fi

pkg_install glibc-repo x11-repo || die "Cannot enable the glibc / X11 repositories."
apt-get "${APT_OPTS[@]}" update >"$LOG_DIR/apt_update2.log" 2>&1 || true

pkg_install python curl binutils patchelf coreutils procps findutils glibc-runner termux-x11-nightly \
    || die "Package installation failed."
# Nice to have: a window manager (windows need a title bar and resizing),
# audio server, X11 helpers.
for pkg in openbox pulseaudio xorg-xrandr; do
    pkg_install "$pkg" || warn "Optional package '$pkg' not installed."
done
have python3 || die "python3 not found."
have patchelf || die "patchelf not found."
[ -x "$GLIBC_LD" ] || die "glibc loader missing: $GLIBC_LD (see $LOG_DIR)."
"$GLIBC_LD" --version >"$LOG_DIR/glibc_loader.log" 2>&1 \
    || die "The glibc loader does not run (see $LOG_DIR/glibc_loader.log)."
ok "glibc loader works."

AVAIL_MB="$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
case "${AVAIL_MB:-}" in ''|*[!0-9]*) ;; *)
    [ "$AVAIL_MB" -lt 2500 ] && warn "Low free space: ${AVAIL_MB} MB. Claude Desktop + libraries need about 1.5-2 GB."
esac

# ---------------------------------------------------------------------------
# 2. Download: official .deb + Debian libraries (python helper)
# ---------------------------------------------------------------------------
if [ "$REINSTALL" = "1" ]; then
    step "Removing the previous installation (--reinstall)"
    "$LAUNCHER" stop >/dev/null 2>&1
    rm -rf "$WORK" "$APP_ROOT" "$LIB_ROOT" "$ETC_DIR"
fi
mkdir -p "$WORK/debs" "$APP_ROOT" "$LIB_ROOT" "$ETC_DIR" || die "Cannot create folders in $BASE"

HELPER="$WORK/fetch.py"
# tpf:embed ./fetch.py as embed_fetch_py
embed_fetch_py > "$HELPER"

step "Downloading Claude Desktop and its libraries"
info "This downloads several hundred MB. Keep Termux in the foreground."
python3 "$HELPER" "$WORK" "$DEBIAN_RELEASE" 2>&1 | tee "$LOG_DIR/fetch.log"
[ "${PIPESTATUS[0]}" = "0" ] || die "Download step failed. See $LOG_DIR/fetch.log"
[ -s "$WORK/claude-desktop.deb" ] && [ -s "$WORK/libs.list" ] || die "Download incomplete."
APP_VERSION="$(cat "$WORK/version.txt" 2>/dev/null)"

# ---------------------------------------------------------------------------
# 3. Unpack
# ---------------------------------------------------------------------------
unpack_deb() {   # unpack_deb file.deb target-dir
    local deb="$1" dest="$2"
    if dpkg-deb -x "$deb" "$dest" 2>>"$LOG_DIR/unpack.log"; then return 0; fi
    # Fallback: ar + tar (handles data.tar.xz / .gz; .zst needs zstd)
    local tmp; tmp="$(mktemp -d "$WORK/ar.XXXXXX")" || return 1
    ( cd "$tmp" && ar x "$deb" ) >>"$LOG_DIR/unpack.log" 2>&1 || { rm -rf "$tmp"; return 1; }
    local data; data="$(ls "$tmp"/data.tar.* 2>/dev/null | head -n1)"
    [ -n "$data" ] && tar -xf "$data" -C "$dest" >>"$LOG_DIR/unpack.log" 2>&1
    local rc=$?
    rm -rf "$tmp"; return $rc
}

step "Unpacking"
: > "$LOG_DIR/unpack.log"
rm -rf "$APP_ROOT" "$LIB_ROOT"; mkdir -p "$APP_ROOT" "$LIB_ROOT"
unpack_deb "$WORK/claude-desktop.deb" "$APP_ROOT" || die "Cannot unpack the Claude Desktop .deb (see $LOG_DIR/unpack.log)."
n=0; bad=0
while IFS= read -r d; do
    [ -n "$d" ] || continue
    n=$((n+1))
    unpack_deb "$d" "$LIB_ROOT" || { bad=$((bad+1)); warn "Could not unpack $(basename "$d")"; }
done < "$WORK/libs.list"
ok "Unpacked the app and $((n-bad)) library packages."

APPDIR="$APP_ROOT/usr/lib/claude-desktop"
[ -d "$APPDIR" ] || APPDIR="$(find "$APP_ROOT/usr/lib" "$APP_ROOT/opt" -maxdepth 2 -type d -iname 'claude*' 2>/dev/null | head -n1)"
[ -n "$APPDIR" ] && [ -d "$APPDIR" ] || die "Cannot find the app folder inside the .deb (look in $APP_ROOT)."
info "App folder: $APPDIR"

is_elf() { [ "$(head -c4 "$1" 2>/dev/null | tr -d '\0')" = $'\x7fELF' ]; }

# The main program is the big ELF executable at the top of the app folder
# (the Electron binary, 100+ MB).
MAIN_BIN=""
while IFS= read -r f; do
    if is_elf "$f"; then MAIN_BIN="$f"; break; fi
done < <(find "$APPDIR" -maxdepth 2 -type f -size +40M ! -name '*.so*' ! -name '*.pak' ! -name '*.asar' ! -name '*.bin' 2>/dev/null | sort)
if [ -z "$MAIN_BIN" ]; then
    for c in claude-desktop electron claude; do
        [ -f "$APPDIR/$c" ] && is_elf "$APPDIR/$c" && { MAIN_BIN="$APPDIR/$c"; break; }
    done
fi
[ -n "$MAIN_BIN" ] || { ls -la "$APPDIR" >&2; die "Cannot find the Electron binary in $APPDIR."; }
info "Main binary: $MAIN_BIN"

# ---------------------------------------------------------------------------
# 4. Libraries: search path + patching
# ---------------------------------------------------------------------------
step "Preparing libraries"
# Every folder holding shared libraries in the unpacked Debian packages.
find "$LIB_ROOT" \( -name '*.so' -o -name '*.so.*' \) -printf '%h\n' 2>/dev/null | sort -u > "$BASE/libdirs.txt"
LIBPATH="\$ORIGIN"
while IFS= read -r d; do [ -n "$d" ] && LIBPATH="$LIBPATH:$d"; done < "$BASE/libdirs.txt"
LIBPATH="$LIBPATH:$PREFIX/glibc/lib"

# Patch every ELF executable at the top of the app folder (main binary and
# helpers such as the crash handler). Electron re-launches itself through
# /proc/self/exe, which is why the interpreter is patched into the binary
# instead of starting it through `ld.so binary`.
PATCHED=0
while IFS= read -r f; do
    is_elf "$f" || continue
    case "$f" in *.so|*.so.*) continue ;; esac
    # Statically linked programs have no loader to replace: nothing to patch.
    patchelf --print-interpreter "$f" >/dev/null 2>&1 || continue
    chmod +x "$f" 2>/dev/null
    if patchelf --set-interpreter "$GLIBC_LD" --force-rpath --set-rpath "$LIBPATH" "$f" >>"$LOG_DIR/patchelf.log" 2>&1; then
        PATCHED=$((PATCHED+1))
    else
        warn "patchelf failed on $f (see $LOG_DIR/patchelf.log)"
    fi
done < <(find "$APPDIR" -maxdepth 2 -type f -perm -u+x 2>/dev/null)
[ "$PATCHED" -gt 0 ] || die "No binary could be patched. See $LOG_DIR/patchelf.log"
ok "$PATCHED executable(s) patched."

# GSettings schemas (GTK file dialogs, settings): compile them if possible.
SCHEMA_DIR="$LIB_ROOT/usr/share/glib-2.0/schemas"
if [ -d "$SCHEMA_DIR" ] && have glib-compile-schemas; then
    glib-compile-schemas "$SCHEMA_DIR" >"$LOG_DIR/gschemas.log" 2>&1 \
        && ok "GSettings schemas compiled." || warn "glib-compile-schemas failed (see $LOG_DIR/gschemas.log)."
fi

# Libraries the app loads with dlopen() (invisible to the dependency check).
for l in libX11.so.6 libX11-xcb.so.1 libxcb.so.1; do
    if ! find "$LIB_ROOT" -name "$l" 2>/dev/null | grep -q .; then
        warn "$l is missing: the app will crash at start-up."
        echo "$l" >> "$LOG_DIR/missing_libs.log"
    fi
done

# Missing libraries check (informative).
if have ldd; then :; fi
MISSING="$(LD_LIBRARY_PATH="$(tr '\n' ':' < "$BASE/libdirs.txt")$PREFIX/glibc/lib" LD_PRELOAD= \
    "$GLIBC_LD" --list "$MAIN_BIN" 2>&1 | grep -i 'not found' | sort -u)"
if [ -n "$MISSING" ]; then
    warn "Some libraries are still missing (the app may fail to start):"
    echo "$MISSING" | sed 's/^/    /'
    echo "$MISSING" > "$LOG_DIR/missing_libs.log"
else
    ok "All libraries needed by the main binary were found."
fi

# ---------------------------------------------------------------------------
# 5. Fonts, DNS, certificates
# ---------------------------------------------------------------------------
step "Fonts, network, certificates"
FONT_DIRS="$LIB_ROOT/usr/share/fonts"
cat > "$ETC_DIR/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>$FONT_DIRS</dir>
  <dir>$PREFIX/share/fonts</dir>
  <dir>/system/fonts</dir>
  <cachedir>$HOME/.cache/fontconfig</cachedir>
</fontconfig>
EOF
ok "fontconfig file written."

# glibc resolves names through its own resolv.conf; Android has none.
GLIBC_RESOLV="$PREFIX/glibc/etc/resolv.conf"
if [ ! -s "$GLIBC_RESOLV" ]; then
    mkdir -p "$(dirname "$GLIBC_RESOLV")"
    if [ -s "$PREFIX/etc/resolv.conf" ]; then
        cp "$PREFIX/etc/resolv.conf" "$GLIBC_RESOLV"
    else
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$GLIBC_RESOLV"
        warn "No DNS file existed: Cloudflare and Google resolvers written to $GLIBC_RESOLV (edit it to change them)."
    fi
    ok "DNS file created for glibc programs."
fi

# ---------------------------------------------------------------------------
# 5b. Normal Termux shell for the terminal and for Claude Code
#     The app itself runs in a modified (glibc) environment. Everything it
#     starts for you — the integrated terminal, Claude Code's shell commands —
#     must run in your NORMAL Termux environment instead. The app is told
#     to use SHELL=$BASE/shell/bash, a tiny relay that restores the original
#     environment (LD_PRELOAD for /bin/sh and #! lines, XDG_DATA_DIRS, ...)
#     and then starts the real Termux bash. It is named "bash" on purpose:
#     programs choose their shell behaviour from that name.
# ---------------------------------------------------------------------------
step "Normal terminal for Claude"
mkdir -p "$BASE/shell"
# tpf:embed ./relay.sh as embed_relay_sh
embed_relay_sh > "$BASE/shell/bash"
chmod +x "$BASE/shell/bash" || die "Cannot create the shell relay."
ok "Shell relay: $BASE/shell/bash"

# Claude Code, when started by the desktop app, is another glibc program that
# the app downloads by itself AFTER installation (so it cannot be patched
# now). A small watcher patches it as soon as it appears.
cat > "$BASE/patch-claude-code.sh" <<PC_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Patches Claude Code binaries downloaded by the app so that they start on Android.
GLIBC_LD="$GLIBC_LD"
GLIBC_LIB="$PREFIX/glibc/lib"
while pgrep -f "$APPDIR" >/dev/null 2>&1; do
    for dir in "\$HOME/.config/Claude" "\$HOME/.local/share/Claude" "\$HOME/.claude"; do
        [ -d "\$dir" ] || continue
        find "\$dir" -type f -size +20M 2>/dev/null | while IFS= read -r f; do
            interp="\$(patchelf --print-interpreter "\$f" 2>/dev/null)" || continue
            case "\$interp" in
                /lib/*|/lib64/*)
                    chmod +x "\$f" 2>/dev/null
                    patchelf --set-interpreter "\$GLIBC_LD" --force-rpath --set-rpath "\$GLIBC_LIB" "\$f" >/dev/null 2>&1 \\
                        && echo "patched: \$f" >> "\$HOME/.claude-desktop.log" ;;
            esac
        done
    done
    sleep 4
done
PC_EOF
chmod +x "$BASE/patch-claude-code.sh"
ok "Claude Code watcher: $BASE/patch-claude-code.sh"

# ---------------------------------------------------------------------------
# 5c. X11 connection fix
#     Debian's X11 libraries connect to /tmp/.X11-unix/X0. On Android that
#     folder does not exist: Termux:X11 puts its socket in $PREFIX/tmp.
#     Without a fix the app stops with "Missing X server or $DISPLAY".
#     Fix 1 (preferred): a tiny LD_PRELOAD library, built here, that rewrites
#                        the socket path in connect().
#     Fix 2 (fallback)  : a local TCP forwarder (127.0.0.1:6001 -> the socket).
# ---------------------------------------------------------------------------
step "X11 connection fix"
SHIM="$BASE/x11fix.so"
rm -f "$SHIM" "$BASE/x11proxy.py"
# tpf:embed ./x11fix.c as embed_x11fix_c
embed_x11fix_c > "$BASE/x11fix.c"

X11_MODE="proxy"
if pkg_install clang lld; then
    if clang --target=aarch64-linux-gnu -shared -fPIC -O2 -nostdlib -nostdinc \
        -fno-builtin -fno-stack-protector -fuse-ld=lld \
        -DTERMUX_TMP="\"$PREFIX/tmp\"" -o "$SHIM" "$BASE/x11fix.c" \
        >"$LOG_DIR/x11fix_build.log" 2>&1 && [ -s "$SHIM" ]; then
        X11_MODE="shim"
        ok "Display library built: $SHIM"
    else
        warn "Could not build the display library (see $LOG_DIR/x11fix_build.log)."
    fi
else
    warn "clang / lld not installed (see $LOG_DIR/x11fix_pkgs.log)."
fi

if [ "$X11_MODE" = "proxy" ]; then
    warn "Using the fallback: a local TCP forwarder on 127.0.0.1:6001."
    warn "Any app on this phone could then talk to the X server while it runs."
# tpf:embed ./x11proxy.py as embed_x11proxy_py
    embed_x11proxy_py > "$BASE/x11proxy.py"
    chmod +x "$BASE/x11proxy.py"
fi

# ---------------------------------------------------------------------------
# 6. Launcher
# ---------------------------------------------------------------------------
step "Launcher"
cat > "$LAUNCHER" <<LAUNCH_EOF
#!/data/data/com.termux/files/usr/bin/bash
# claude-desktop.sh — start / stop Claude Desktop (generated by the installer)
#   ./claude-desktop.sh [start]   start Termux:X11, a window manager and the app
#   ./claude-desktop.sh stop      stop the app (and the X server it started)
#   ./claude-desktop.sh log       follow the log
#   ./claude-desktop.sh status    tell whether the app is running
set -u
PREFIX="\${PREFIX:-/data/data/com.termux/files/usr}"
MAIN_BIN="$MAIN_BIN"
APPDIR="$APPDIR"
LOG="\$HOME/.claude-desktop.log"
DISPLAY_ID=":0"
# Extra Chromium flags can be added here or through CLAUDE_FLAGS.
FLAGS=(--no-sandbox --disable-gpu --disable-dev-shm-usage --ozone-platform=x11 --password-store=basic)

app_pids() { pgrep -f "\$APPDIR" 2>/dev/null; }

case "\${1:-start}" in
  stop)
    pids="\$(app_pids)"
    if [ -n "\$pids" ]; then kill \$pids 2>/dev/null; sleep 2; kill -9 \$(app_pids) 2>/dev/null; echo "Claude Desktop stopped."; else echo "Claude Desktop was not running."; fi
    pkill -f "termux-x11 \$DISPLAY_ID" 2>/dev/null
    pkill -f x11proxy.py 2>/dev/null
    pkill -x openbox 2>/dev/null
    command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock >/dev/null 2>&1
    exit 0 ;;
  status)
    if [ -n "\$(app_pids)" ]; then echo "Claude Desktop is running."; exit 0; fi
    echo "Claude Desktop is not running."; exit 3 ;;
  log)
    exec tail -n 80 -f "\$LOG" ;;
  start) ;;
  *) echo "Usage: \$0 [start|stop|status|log]"; exit 2 ;;
esac

[ -x "\$MAIN_BIN" ] || { echo "Main binary missing: \$MAIN_BIN (run the installer again with --reinstall)"; exit 1; }
if [ -n "\$(app_pids)" ]; then echo "Claude Desktop is already running."; exit 0; fi

command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock >/dev/null 2>&1

# 1. X server (Termux:X11). The Android app "Termux:X11" must be opened.
if ! pgrep -f "termux-x11 \$DISPLAY_ID" >/dev/null 2>&1; then
    termux-x11 "\$DISPLAY_ID" >/dev/null 2>&1 &
    sleep 3
fi
export DISPLAY="\$DISPLAY_ID"
command -v am >/dev/null 2>&1 && am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1

# 2. Audio (optional) and window manager (optional)
if command -v pulseaudio >/dev/null 2>&1 && ! pgrep -x pulseaudio >/dev/null 2>&1; then
    pulseaudio --start --exit-idle-time=-1 >/dev/null 2>&1
fi
if command -v openbox >/dev/null 2>&1 && ! pgrep -x openbox >/dev/null 2>&1; then
    openbox >/dev/null 2>&1 &
    sleep 1
fi

# 3. The app, through the glibc loader patched into its binaries.
# The original environment is saved first: the shell relay restores it for
# everything the app starts (terminal, Claude Code commands).
export CT_ORIG_LD_PRELOAD="\${LD_PRELOAD:-}"
export CT_ORIG_XDG_DATA_DIRS="\${XDG_DATA_DIRS:-}"
export CT_ORIG_DBUS="\${DBUS_SESSION_BUS_ADDRESS:-}"
# LD_PRELOAD (libtermux-exec) is built for Bionic and breaks glibc programs.
unset LD_PRELOAD
# Terminal and Claude Code use a NORMAL Termux bash (see the relay script).
export SHELL="$BASE/shell/bash"
# X11 connection fix: Debian's X libraries look for the X server in
# /tmp/.X11-unix, which does not exist on Android.
if [ -f "$SHIM" ]; then
    export LD_PRELOAD="$SHIM"      # rewrites the socket path (glibc programs only)
elif [ -f "$BASE/x11proxy.py" ]; then
    pgrep -f x11proxy.py >/dev/null 2>&1 || \\
        nohup python3 "$BASE/x11proxy.py" "\$PREFIX/tmp/.X11-unix/X0" 6001 >/dev/null 2>&1 </dev/null &
    sleep 1
    export DISPLAY=127.0.0.1:1
fi
export FONTCONFIG_FILE="$ETC_DIR/fonts.conf"
export GSETTINGS_SCHEMA_DIR="$LIB_ROOT/usr/share/glib-2.0/schemas"
export XDG_DATA_DIRS="$LIB_ROOT/usr/share:\$PREFIX/share"
export SSL_CERT_FILE="\${SSL_CERT_FILE:-\$PREFIX/etc/tls/cert.pem}"
export TMPDIR="\${TMPDIR:-\$PREFIX/tmp}"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-\$TMPDIR/runtime-\$(id -u)}"
mkdir -p "\$XDG_RUNTIME_DIR" && chmod 700 "\$XDG_RUNTIME_DIR"
export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-disabled:}"
export ELECTRON_DISABLE_SANDBOX=1
export GTK_USE_PORTAL=0
export GDK_BACKEND=x11
# Debug option: CLAUDE_USE_LD_LIBRARY_PATH=1 also exports the library folders
# (not the default: the variable would leak into programs the app starts).
if [ "\${CLAUDE_USE_LD_LIBRARY_PATH:-0}" = "1" ]; then
    export LD_LIBRARY_PATH="\$(tr '\n' ':' < "$BASE/libdirs.txt")\$PREFIX/glibc/lib"
fi

cd "\$APPDIR" || exit 1
# shellcheck disable=SC2086
nohup "\$MAIN_BIN" "\${FLAGS[@]}" \${CLAUDE_FLAGS:-} >"\$LOG" 2>&1 </dev/null &
APP_PID=\$!
# The watcher is a normal Termux script: it must not get the glibc LD_PRELOAD.
LD_PRELOAD="\$CT_ORIG_LD_PRELOAD" nohup "$BASE/patch-claude-code.sh" >/dev/null 2>&1 </dev/null &
# Root (si disponible) : protège Termux et l'app contre les kills Android.
# Silencieux et sans effet si l'appareil n'est pas rooté.
if [ -x "\$HOME/termux-keepalive.sh" ]; then
    ( sleep 8; LD_PRELOAD="\$CT_ORIG_LD_PRELOAD" TERMUX_KEEPALIVE_MODE=root "\$HOME/termux-keepalive.sh" on ) >"\$HOME/.termux-keepalive.log" 2>&1 </dev/null &
fi
echo "Claude Desktop starting (PID \$APP_PID). Switch to the Termux:X11 app to see it."
echo "Log: \$LOG   (./claude-desktop.sh log)"
LAUNCH_EOF
chmod +x "$LAUNCHER" || die "Cannot make $LAUNCHER executable."
ok "Launcher: $LAUNCHER"

# ---------------------------------------------------------------------------
# 7. Start-up self-test (no display needed)
# ---------------------------------------------------------------------------
step "Self-test"
# --no-sandbox: same as the launcher (Android cannot run Chromium's sandbox).
if [ -f "$SHIM" ]; then PRE="$SHIM"; else PRE=""; fi
TEST_OUT="$(env LD_PRELOAD="$PRE" timeout 60 "$MAIN_BIN" --no-sandbox --version 2>&1)"; rc=$?
printf '%s\n' "$TEST_OUT" > "$LOG_DIR/selftest.log"
if [ $rc -eq 0 ]; then
    ok "The Electron binary runs: $(printf '%s' "$TEST_OUT" | head -n1)"
    SELFTEST=1
else
    SELFTEST=0
    warn "The Electron binary did not run (exit $rc):"
    printf '%s\n' "$TEST_OUT" | head -n 8 | sed 's/^/    /'
    warn "Full output: $LOG_DIR/selftest.log"
fi

# The terminal check mimics what the app does: a glibc-side environment
# (no LD_PRELOAD, modified variables) starts the relay, which must give back
# a normal Termux shell.
SH_ORIG_PRELOAD="${LD_PRELOAD:-}"
SH_OUT="$(env -u LD_PRELOAD CT_ORIG_LD_PRELOAD="$SH_ORIG_PRELOAD" GDK_BACKEND=x11 FONTCONFIG_FILE=/nonexistent \
    "$BASE/shell/bash" -c 'printf "LD_PRELOAD=%s\nGDK_BACKEND=%s\nFONTCONFIG_FILE=%s\nPATH_OK=%s\n" "${LD_PRELOAD:-}" "${GDK_BACKEND:-}" "${FONTCONFIG_FILE:-}" "$(command -v pkg >/dev/null && echo yes || echo no)"; echo hello | /bin/sh -c "cat" 2>&1' 2>&1)"
printf '%s\n' "$SH_OUT" > "$LOG_DIR/shell_test.log"
if printf '%s' "$SH_OUT" | grep -q '^GDK_BACKEND=$' && printf '%s' "$SH_OUT" | grep -q '^PATH_OK=yes' \
   && printf '%s' "$SH_OUT" | grep -q '^hello$'; then
    ok "Terminal check passed: normal Termux shell (PATH, /bin/sh, clean environment)."
else
    warn "Terminal check failed (see $LOG_DIR/shell_test.log):"
    printf '%s\n' "$SH_OUT" | head -n 8 | sed 's/^/    /'
    SELFTEST=0
fi

echo
echo -e "${C_OK}============================================================${C_RESET}"
if [ "$SELFTEST" = "1" ]; then
    echo -e "${C_OK} Installation complete${C_RESET}"
else
    echo -e "${C_WARN} Installation complete — self-test FAILED (see above)${C_RESET}"
fi
echo "============================================================"
echo " Claude Desktop : ${APP_VERSION:-unknown}"
echo " Start          : $LAUNCHER"
echo "                  (open the Termux:X11 app, it shows the window)"
echo " Stop / log     : $LAUNCHER stop | log | status"
echo " Install logs   : $LOG_DIR"
echo "------------------------------------------------------------"
echo " Not available on Android: Cowork (needs KVM), Computer Use,"
echo " GPU acceleration, keyring (sign-in is asked again at each start"
echo " if the app cannot store it)."
echo "============================================================"
[ "$SELFTEST" = "1" ] || exit 1
exit 0
