#!/data/data/com.termux/files/usr/bin/bash
# Rust on Termux (Android) with a "fake rustup".
#
#   rustc-termux.sh install      install Rust, the fake rustup/cargo/rustc, targets and linker packs
#   rustc-termux.sh reinstall    remove the fake rustup and install again from scratch
#   rustc-termux.sh uninstall    remove everything this tool wrote (asks before sharing/personal files)
#   rustc-termux.sh status       what is installed and its state
#   rustc-termux.sh doctor       check everything (--fix repairs, --full also compiles programs)
#   rustc-termux.sh test         compile and run a native program
#   rustc-termux.sh targets      list | add T | remove T
#   rustc-termux.sh packs        list | add NAME... | remove NAME...   (zig msvc ndk wasm)
#   rustc-termux.sh linker       list | add T --ndk|--clang TRIPLE|--zig ZT|-- CMD... | remove T | test T
#   rustc-termux.sh jobs N|off   limit parallel build jobs
#   rustc-termux.sh nightly on|off   simulated `cargo +nightly`
#   rustc-termux.sh log [NAME]   install logs
#
# Why a fake one?
#   The real rustup cannot run on Android, and the Rust package from Termux
#   ships the phone's own target only. The fake rustup sits on top of that
#   package and lets cargo rebuild the standard library for any other target
#   (WebAssembly, ...) from the official Rust sources.
#
# Everything that is written on the device:
#     ~/.rustup-fake/                  the fake tools and their state
#     ~/.bashrc  (~/.zshrc if used)    one PATH block between markers
#     $PREFIX/lib/rustlib/src          the Rust sources
#     ~/rust-termux.conf               saved choices (defaults for the next install)
#     ~/.cache/rust-termux-install/    logs
#   With root and only if you agree (each value is saved, then restored by
#   uninstall): Android settings (phantom process killer, Doze/background
#   exemption), kernel inotify limits, an optional swap file in /data/local,
#   the CPU governor until reboot, and a boot script in /data/adb/service.d
#   (or ~/.termux/boot). SELinux is never touched.
#
# `set -e` is deliberately NOT used: every step checks its own result so the
# script can explain what went wrong and carry on or stop cleanly.
set -uo pipefail

# tpf:include core
# tpf:include cmd
# tpf:include pkg
# tpf:include ./compat.sh
# tpf:include ./common.sh
# tpf:include ./packs.sh
# tpf:include ./uninstall.sh
# tpf:include ./install.sh
# tpf:include ./manage.sh

TARGETS_ARG=""
NO_TARGETS=0
ROOT_MODE="" # "" = ask | yes | no
ROOT_TWEAKS_ARG=""
SWAP_ARG=""
PACKS_ARG=""
MSVC_LICENSE_ARG=0
NIGHTLY_ARG="" # "" = ask | 1 | 0
JOBS_ARG=""    # "" = ask | N
DO_RESET=0     # install keeps what works; reinstall cleans first
SKIP_UPDATE=0
NO_TEST=0
ADD_PACKS=0 # (kept for the install code: "packs add" works in place now)
LIST_PACKS=0

TOOL_RAW_COMMANDS="doctor targets packs linker"

TOOL_OPTIONS_HELP='      --targets LIST       install: targets to add, comma-separated (default: the saved ones)
      --no-targets         install: add no target now
      --nightly            install: enable the simulated nightly mode (cargo +nightly ...)
      --no-nightly         install: disable it
      --jobs N             install: limit parallel build jobs (0 = no limit; too many can make Android kill Termux)
      --root               install: use root (if available) for the SAFE tweaks, without asking
      --no-root            install: never use root, never ask for it
      --root-tweaks LIST   install: phantom,doze,inotify,oom,swap,perf (implies --root; swap and perf are never enabled by --yes alone)
      --swap-size MB       install: size of the swap file (default 2048)
      --toolchains LIST    install: linker packs among zig,msvc,ndk,wasm (or all, none)
      --accept-msvc-license  install: accept Microsoft'"'"'s licence for the msvc pack without asking
      --skip-update        install: skip `apt update` / `apt upgrade`
      --no-test            install: skip the compile tests at the end
      --purge-data         uninstall: also delete ~/.cargo and the saved settings'

tool_opt() {
    case "$1" in
        --targets)
            need_value "$1" $#
            TARGETS_ARG="$2"
            TOOL_SHIFT=2
            ;;
        --targets=*) TARGETS_ARG="${1#*=}" ;;
        --no-targets) NO_TARGETS=1 ;;
        --nightly) NIGHTLY_ARG=1 ;;
        --no-nightly) NIGHTLY_ARG=0 ;;
        --jobs)
            need_value "$1" $#
            JOBS_ARG="$2"
            TOOL_SHIFT=2
            ;;
        --jobs=*) JOBS_ARG="${1#*=}" ;;
        --purge-data) PURGE_DATA=1 ;;
        --root) ROOT_MODE="yes" ;;
        --no-root) ROOT_MODE="no" ;;
        --root-tweaks)
            need_value "$1" $#
            ROOT_TWEAKS_ARG="$2"
            ROOT_MODE="yes"
            TOOL_SHIFT=2
            ;;
        --root-tweaks=*)
            ROOT_TWEAKS_ARG="${1#*=}"
            ROOT_MODE="yes"
            ;;
        --swap-size)
            need_value "$1" $#
            SWAP_ARG="$2"
            TOOL_SHIFT=2
            ;;
        --swap-size=*) SWAP_ARG="${1#*=}" ;;
        --toolchains)
            need_value "$1" $#
            PACKS_ARG="$2"
            TOOL_SHIFT=2
            ;;
        --toolchains=*) PACKS_ARG="${1#*=}" ;;
        --accept-msvc-license) MSVC_LICENSE_ARG=1 ;;
        --skip-update) SKIP_UPDATE=1 ;;
        --no-test) NO_TEST=1 ;;
        *) return 1 ;;
    esac
}

# Checks the values given to the install options.
validate_options() {
    local t
    case "$TARGETS_ARG" in
        *[!A-Za-z0-9_.,-]*) die "--targets takes target names separated by commas (got: $TARGETS_ARG)" ;;
    esac
    [ -z "$JOBS_ARG" ] || is_uint "$JOBS_ARG" || die "--jobs must be a number (got: $JOBS_ARG)"
    [ -z "$SWAP_ARG" ] || { is_uint "$SWAP_ARG" && [ "$SWAP_ARG" -ge 256 ]; } || die "--swap-size must be a number of MB, at least 256 (got: $SWAP_ARG)"
    case "$ROOT_TWEAKS_ARG" in *[!a-z,]*) die "--root-tweaks takes names separated by commas (got: $ROOT_TWEAKS_ARG)" ;; esac
    ROOT_TWEAKS_ARG="${ROOT_TWEAKS_ARG//,/ }"
    for t in $ROOT_TWEAKS_ARG; do
        case " $ROOT_ALL " in *" $t "*) ;; *) die "Unknown root tweak: $t (known: ${ROOT_ALL// /,})" ;; esac
    done
    case "$PACKS_ARG" in *[!a-z,]*) die "--toolchains takes names separated by commas (got: $PACKS_ARG)" ;; esac
    case "$PACKS_ARG" in all) PACKS_ARG="${PACK_ALL// /,}" ;; none) PACKS_ARG="none" ;; esac
    for t in ${PACKS_ARG//,/ }; do
        [ "$t" = none ] || pack_known "$t" || die "Unknown toolchain pack: $t (known: ${PACK_ALL// /,})"
    done
}

# reinstall = remove the fake rustup and its leftovers, then install (the saved
# choices, ~/.cargo and the Termux packages are kept).
cmd_reinstall() {
    DO_RESET=1
    cmd_install "$@"
}

tool_usage() {
    printf 'Without --yes / --no, each install question defaults to the choice saved by the\nprevious run, or to a sensible value on a first install.\n'
}

add_command install "Install Rust, the fake rustup/cargo/rustc, targets and linker packs"
add_command reinstall "Remove the fake rustup, then install again from scratch"
add_command uninstall "Remove everything this tool wrote"
add_command status "What is installed and its state"
add_command doctor "Check everything (--fix repairs, --full also compiles programs)"
add_command test "Compile and run a native program"
add_command targets "list | add T | remove T"
add_command packs "list | add NAME... | remove NAME...   (zig msvc ndk wasm)"
add_command linker "list | add T --ndk|--clang TRIPLE|--zig ZT|-- CMD... | remove T | test T"
add_command jobs "N | off: limit parallel build jobs"
add_command nightly "on | off: simulated cargo +nightly"
add_command log "List the install logs, or show one: log NAME [lines]"

tpf_main "$@"
