#!/data/data/com.termux/files/usr/bin/bash
# Run the OFFICIAL Claude Desktop for Linux (arm64 .deb published by Anthropic)
# on Termux, WITHOUT proot-distro and WITHOUT root.
#
#   claude-desktop.sh install     download, unpack and patch the app
#   claude-desktop.sh start       start Termux:X11, a window manager and the app
#   claude-desktop.sh stop        stop the app (and the X server it started)
#   claude-desktop.sh status      tell whether it is installed and running
#   claude-desktop.sh log         follow the app's log
#   claude-desktop.sh uninstall   remove everything (--purge-data: also the sign-in)
#   claude-desktop.sh reinstall   uninstall (keeping the download cache), then install
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
#   5. "start" runs Termux:X11, a window manager and the app.
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
#   not the modified environment the app itself needs.
set -uo pipefail

# tpf:include core
# tpf:include cmd
# tpf:include pkg
# tpf:include ./common.sh
# tpf:include ./install.sh
# tpf:include ./manage.sh
# tpf:include ./uninstall.sh

SKIP_UPDATE=0
DEBIAN_RELEASE="bookworm"

TOOL_OPTIONS_HELP='      --skip-update      install: skip `apt update` (faster)
      --debian RELEASE   install: Debian release the libraries come from (default: bookworm)
      --purge-data       uninstall: also delete the app'"'"'s own data (~/.config/Claude, the sign-in)'

tool_opt() {
    case "$1" in
        --skip-update) SKIP_UPDATE=1 ;;
        --debian)
            need_value "$1" $#
            DEBIAN_RELEASE="$2"
            TOOL_SHIFT=2
            ;;
        --debian=*) DEBIAN_RELEASE="${1#*=}" ;;
        --purge-data) PURGE=1 ;;
        *) return 1 ;;
    esac
    case "$DEBIAN_RELEASE" in *[!a-z0-9-]* | '') die "--debian: invalid release name" ;; esac
}

tool_usage() {
    printf 'Open the Termux:X11 app after "start": it shows the window.\n'
}

add_command install "Download, unpack and patch the app"
add_command start "Start the app (Termux:X11, window manager, Claude Desktop)"
add_command stop "Stop the app and the X server it started"
add_command status "Show whether it is installed and running"
add_command log "Follow the app's log"
add_command uninstall "Remove everything"

tpf_main "$@"
