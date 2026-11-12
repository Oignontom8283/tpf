# Installation, in phases (run in this order by cmd_install).

# tpf:embed ./rustup.sh as embed_rustup_sh
# tpf:embed ./cargo.sh as embed_cargo_sh
# tpf:embed ./rustc.sh as embed_rustc_sh
# tpf:embed ./arm-none-eabi-gcc.sh as embed_gcc_sh

# --- Bare-metal ARM tools ------------------------------------------------------------
# Many embedded projects expect GNU-named ARM tools (arm-none-eabi-gcc, -ar, ...) for the
# C code of their build scripts. Termux has no GNU ARM toolchain, so these names point to
# clang / llvm (which are installed anyway).
write_baremetal_tools() {
    local t
    mkdir -p "$BASE/bin" || return 1
    embed_gcc_sh >"$BASE/bin/arm-none-eabi-gcc"
    sed 's/exec clang /exec clang++ /' "$BASE/bin/arm-none-eabi-gcc" >"$BASE/bin/arm-none-eabi-g++"
    chmod +x "$BASE/bin/arm-none-eabi-gcc" "$BASE/bin/arm-none-eabi-g++"
    for t in ar ranlib objcopy objdump nm strip size readelf; do
        [ -x "$PREFIX/bin/llvm-$t" ] && ln -sf "$PREFIX/bin/llvm-$t" "$BASE/bin/arm-none-eabi-$t"
    done
    return 0
}

# --- PATH ---------------------------------------------------------------------------
# The fake tools must come first in the PATH. One marked block per start-up
# file, so that it can be removed exactly.
write_rc_block() {
    local rc="$1"
    [ -f "$rc" ] || : >"$rc"
    {
        echo ""
        echo "$RC_BEGIN"
        echo 'export PATH="$HOME/.rustup-fake/bin:$PATH"'
        echo "$RC_END"
    } >>"$rc"
}

# Checking the environment
phase_checking_the_environment() {
    ARCH="$(uname -m)"
    info "Architecture: $ARCH"
    info "Termux PREFIX: $PREFIX"
    if [ "$DO_RESET" = 1 ]; then
        info "Mode: clean reinstall (the current install is removed, then installed again)"
    else
        info "Mode: soft repair (--no-reset: what already works is kept)"
    fi
    [ "$PURGE_DATA" = 1 ] && warn "--purge-data: ~/.cargo and the saved settings will ALSO be deleted."

    case "$ARCH" in
        aarch64 | arm64) ok "Supported architecture ($ARCH)" ;;
        x86_64 | i686 | i386) ok "Architecture $ARCH (Termux on an emulator or a Chromebook)" ;;
        armv7l | armv8l | arm) warn "32-bit ARM: it should work, but builds are slow and memory-hungry." ;;
        *) warn "Untested architecture ($ARCH): it may work, no guarantee." ;;
    esac

    android_info
    if [ "$ANDROID_SDK" -gt 0 ]; then
        info "Android ${ANDROID_REL:-?} (API $ANDROID_SDK), Project Treble: ${TREBLE:-unknown}"
        if [ "$ANDROID_SDK" -lt 29 ]; then
            warn "Android older than 10: this installer targets recent devices (Treble, Android 10+); it may not work."
        elif [ "$TREBLE" = true ]; then
            ok "Recent Treble-compatible Android"
        else
            warn "Project Treble is not reported by this device: the script is designed for Treble devices."
        fi
    fi
    case "${TERMUX_APK_RELEASE:-}" in
        GOOGLE_PLAY_STORE) warn "This Termux comes from the Play Store (outdated, unmaintained): install the F-Droid or GitHub build." ;;
        "") [ -n "${TERMUX_VERSION:-}" ] || warn "Termux version unknown: an old Termux may lack recent packages. Update it from F-Droid/GitHub." ;;
        *) ok "Termux build: $TERMUX_APK_RELEASE ${TERMUX_VERSION:+(version $TERMUX_VERSION)}" ;;
    esac

    AVAIL_MB="$(df -Pm "$PREFIX" 2>/dev/null | awk 'NR==2 {print $4}')"
    if is_uint "${AVAIL_MB:-}"; then
        if [ "$AVAIL_MB" -lt 800 ]; then
            die "Not enough free space: ${AVAIL_MB} MB (about 2500 MB recommended)."
        elif [ "$AVAIL_MB" -lt 2500 ]; then
            warn "Low free space: ${AVAIL_MB} MB (about 2500 MB recommended; each target adds a few hundred MB)."
        else
            ok "Free space: ${AVAIL_MB} MB"
        fi
    fi

    if have curl; then
        if curl -sS -I --max-time 10 -o /dev/null https://static.rust-lang.org/ 2>"$LOG_DIR/network.log"; then
            ok "static.rust-lang.org is reachable"
        else
            warn "static.rust-lang.org is unreachable (see $LOG_DIR/network.log): the Rust sources cannot be downloaded."
        fi
    else
        info "curl is not installed yet: network check skipped."
    fi

    # Which packages are missing BEFORE anything changes: the uninstaller removes
    # only what this installer added, never what was already on the device.
    PRE_MISSING=""
    for p in "${DEPS_REQUIRED[@]}" "${DEPS_OPTIONAL[@]}"; do
        dpkg_installed "$p" || PRE_MISSING="$PRE_MISSING $p"
    done
    if [ -d "$BASE" ] || [ -d "$LEGACY_PROOT_BASE" ] || [ -f "$CONF" ]; then
        info "A previous installation was found."
    else
        info "No previous installation found."
    fi
}

# Choosing options
phase_choosing_options() {
    load_prev_conf

    PKGS_ADDED="$({
        for p in $(conf_get RT_PKGS_ADDED); do echo "$p"; done
        for p in $PRE_MISSING; do echo "$p"; done
    } |
        awk 'NF && !seen[$0]++' | tr '\n' ' ')"
    PKGS_ADDED="${PKGS_ADDED% }"

    # --- old proot-based script ---------------------------------------------------
    REMOVE_DEBIAN=0
    if [ -d "$LEGACY_PROOT_BASE" ] && have proot-distro; then
        warn "An older proot-based script left a Debian container behind (named 'debian')."
        plain "    This version does not use it. Removing it frees several GB."
        ask_yes_no "Remove it with 'proot-distro remove debian'?" no && REMOVE_DEBIAN=1
    fi

    # --- targets --------------------------------------------------------------------
    DEFAULT_TARGETS="wasm32-unknown-unknown"
    if [ "$NO_TARGETS" = 1 ]; then
        TARGETS=""
    elif [ -n "$TARGETS_ARG" ]; then
        TARGETS="$TARGETS_ARG"
    else
        cand="$DEFAULT_TARGETS"
        def=yes
        if conf_has RT_TARGETS; then
            saved="$(conf_get RT_TARGETS)"
            if [ -n "$saved" ]; then cand="$saved"; else def=no; fi
        fi
        plain "    Targets other than the phone's own use a standard library that is"
        plain "    rebuilt from source: the first build of each takes a few minutes."
        if ask_yes_no "Add the target(s) $cand now?" "$def"; then TARGETS="$cand"; else TARGETS=""; fi
    fi

    # --- simulated nightly -----------------------------------------------------------
    if [ "$ADD_PACKS" = 1 ]; then
        NIGHTLY="$(conf_get RT_NIGHTLY)"
        NIGHTLY="${NIGHTLY:-0}" # --add-packs changes nothing else
    elif [ -n "$NIGHTLY_ARG" ]; then
        NIGHTLY="$NIGHTLY_ARG"
    else
        plain ""
        warn "Optional: simulated nightly mode (\`cargo +nightly ...\`)."
        plain "   Benefit: unstable options (-Z...) and #![feature(...)] work."
        plain "   Risk   : it is NOT a real nightly, only Termux's compiler with the"
        plain "            RUSTC_BOOTSTRAP flag. Crates that detect \"nightly\" may switch on"
        plain "            code that this compiler does not have."
        if ask_yes_no "Enable the simulated nightly mode?" "$(prev_flag RT_NIGHTLY yes)"; then NIGHTLY=1; else NIGHTLY=0; fi
    fi

    # --- build jobs -------------------------------------------------------------------
    CPUS="$(nproc 2>/dev/null || echo 1)"
    is_uint "$CPUS" || CPUS=1
    MEM_MB="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    is_uint "${MEM_MB:-}" || MEM_MB=4096
    SUGGEST=$((MEM_MB / 1500))
    [ "$SUGGEST" -lt 1 ] && SUGGEST=1
    [ "$SUGGEST" -gt "$CPUS" ] && SUGGEST="$CPUS"
    SAVED_JOBS="$(conf_get RT_JOBS)"
    is_uint "${SAVED_JOBS:-}" && [ "$SAVED_JOBS" -ge 1 ] && SUGGEST="$SAVED_JOBS"
    JOBS=""
    if [ -n "$JOBS_ARG" ]; then
        [ "$JOBS_ARG" = 0 ] || JOBS="$JOBS_ARG"
    elif [ "$SUGGEST" -lt "$CPUS" ]; then
        jdef=yes
        if conf_has RT_JOBS && [ -z "$SAVED_JOBS" ]; then jdef=no; fi
        if ask_yes_no "Limit parallel build jobs to $SUGGEST ($CPUS cores, $MEM_MB MB RAM; too many jobs can make Android kill Termux)?" "$jdef"; then
            JOBS="$SUGGEST"
        fi
    else
        info "Build jobs: no limit needed ($CPUS cores, $MEM_MB MB RAM)."
    fi

    # --- root ---------------------------------------------------------------------------
    ROOT_SEL=""
    ROOT_BOOT=0
    SWAP_MB=""
    if [ "$ADD_PACKS" = 1 ]; then
        info "Root settings kept exactly as they are (--add-packs)."
    elif [ "$ROOT_MODE" = no ]; then
        info "Root not used (--no-root)."
    elif ! find_su && [ "$(id -u)" != 0 ]; then
        info "No root access on this device: normal, nothing is lost. Everything works without it."
    else
        info "A root manager was found. Checking access (it may ask you to allow Termux)..."
        if ! detect_root; then
            warn "Root was not granted (denied, or no answer): continuing without root."
        else
            ok "Root access granted ($([ "$(id -u)" = 0 ] && echo uid 0 || echo "$SU_BIN"))"
            saved_tw="$(conf_get RT_ROOT_TWEAKS)"
            plain "    Root can lift limits Android puts on long builds. Each tweak is explained,"
            plain "    can be refused, and is REVERTED by the uninstaller (the original values are"
            plain "    saved). SELinux and the system partition are never touched."
            if [ -n "$ROOT_TWEAKS_ARG" ]; then
                for t in $ROOT_TWEAKS_ARG; do
                    root_tweak_applicable "$t" && ROOT_SEL="$ROOT_SEL $t" || warn "Tweak '$t' does not apply to this Android (API $ANDROID_SDK): skipped."
                done
            elif [ "$ROOT_MODE" = yes ] || ask_yes_no "Use root to lift Android's limits for builds?" "$(prev_flag RT_USE_ROOT yes)"; then
                for t in $ROOT_ALL; do
                    root_tweak_applicable "$t" || {
                        info "Tweak '$t' does not apply to Android API $ANDROID_SDK."
                        continue
                    }
                    case "$ROOT_RISKY" in *" $t "*) risky=1 ;; *) risky=0 ;; esac
                    if [ "$ROOT_MODE" = yes ]; then # --root: the safe set only
                        [ "$risky" = 0 ] && ROOT_SEL="$ROOT_SEL $t"
                        continue
                    fi
                    plain ""
                    plain "  ${C_INFO}Root tweak: $t${C_RESET}"
                    root_tweak_describe "$t"
                    if [ "$risky" = 1 ] && [ "$TPF_ASSUME" = yes ]; then
                        info "'$t' is risky: --yes does not enable it (use --root-tweaks $t)."
                        continue
                    fi
                    if [ -n "$saved_tw" ]; then
                        case " $saved_tw " in *" $t "*) tdef=yes ;; *) tdef=no ;; esac
                    else [ "$risky" = 1 ] && tdef=no || tdef=yes; fi
                    ask_yes_no "Apply the '$t' tweak?" "$tdef" && ROOT_SEL="$ROOT_SEL $t"
                done
            fi
            ROOT_SEL="${ROOT_SEL# }"
            case " $ROOT_SEL " in
                *" swap "*)
                    FREE_DATA="$(df -Pm /data 2>/dev/null | awk 'NR==2 {print $4}')"
                    SWAP_MB="${SWAP_ARG:-2048}"
                    if is_uint "${FREE_DATA:-}" && [ "$FREE_DATA" -lt $((SWAP_MB + 3000)) ]; then
                        warn "Not enough free storage for a ${SWAP_MB} MB swap file (${FREE_DATA} MB free): swap skipped."
                        ROOT_SEL="$(printf '%s' " $ROOT_SEL " | sed 's/ swap / /; s/^ *//; s/ *$//')"
                    else info "Swap file size: ${SWAP_MB} MB"; fi
                    ;;
            esac
            # tweaks Android forgets at reboot
            case " $ROOT_SEL " in
                *" inotify "* | *" swap "*) need_boot=1 ;;
                *" phantom "*) [ "$ANDROID_SDK" -lt 32 ] && need_boot=1 || need_boot=0 ;;
                *) need_boot=0 ;;
            esac
            if [ "${need_boot:-0}" = 1 ]; then
                plain "    Some of these tweaks are forgotten by Android at reboot. A small boot script"
                plain "    (Magisk/KernelSU service.d, else Termux:Boot) can re-apply them."
                if [ "$TPF_ASSUME" = no ]; then ROOT_BOOT=0; else ask_yes_no "Re-apply them at every boot?" "$(prev_flag RT_ROOT_BOOT yes)" && ROOT_BOOT=1; fi
            fi
        fi
    fi
    [ -z "$ROOT_SEL" ] || info "Root tweaks chosen: $ROOT_SEL"

    # --- toolchain packs (linkers for other platforms) ------------------------------------
    PACKS=""
    MSVC_LICENSE=0
    SAVED_PACKS="$(conf_get RT_PACKS)"
    plain ""
    plain "  ${C_INFO}Linker packs${C_RESET}: link programs for other platforms (compiled from source if needed)."
    plain "  Not offered: Emscripten and the WASI C library (no native route on Android;"
    plain "  Emscripten would need a virtualised Linux, which this installer refuses to use)."
    if [ -n "$PACKS_ARG" ]; then
        [ "$PACKS_ARG" = none ] || PACKS="${PACKS_ARG//,/ }"
    elif [ "$TPF_ASSUME" = yes ]; then
        info "--yes does not install packs by itself (they are big): use --toolchains LIST."
    else
        for t in $PACK_ALL; do
            plain ""
            plain "  ${C_INFO}Pack: $t${C_RESET}"
            pack_describe "$t"
            case " $SAVED_PACKS " in *" $t "*) pdef=yes ;; *) pdef=no ;; esac
            ask_yes_no "Install the '$t' pack?" "$pdef" && PACKS="$PACKS $t"
        done
    fi
    PACKS="${PACKS# }"
    case " $PACKS " in
        *" msvc "*)
            plain ""
            warn "The 'msvc' pack downloads the Windows SDK and CRT from Microsoft."
            plain "    By using it you accept Microsoft's licence terms:"
            plain "    https://go.microsoft.com/fwlink/?LinkId=2086102 (Visual Studio) and the Windows SDK licence."
            if [ "$MSVC_LICENSE_ARG" = 1 ]; then
                MSVC_LICENSE=1
                info "Microsoft licence accepted (--accept-msvc-license)."
            elif [ "$TPF_ASSUME" != yes ] && ask_yes_no "Do you accept Microsoft's licence?" no; then MSVC_LICENSE=1; fi
            if [ "$MSVC_LICENSE" = 0 ]; then
                warn "Licence not accepted: the 'msvc' pack is skipped."
                PACKS="$(printf '%s' " $PACKS " | sed 's/ msvc / /; s/^ *//; s/ *$//')"
            fi
            ;;
    esac
    [ -z "$PACKS" ] || info "Packs chosen: $PACKS"

    # --- delete user data (only with --purge-data) -------------------------------------
    if [ "$PURGE_DATA" = 1 ]; then
        warn "This deletes: $CARGO_DATA_DIR (crate cache, tools from 'cargo install') and $CONF."
        if ask_yes_no "Confirm PERMANENT deletion of this data?" no; then :; else
            info "Deletion cancelled, data kept."
            PURGE_DATA=0
        fi
    fi

    info "Root tweaks: ${ROOT_SEL:-none}   Packs: ${PACKS:-none}"
    info "Targets: ${TARGETS:-none}   Nightly: $([ "$NIGHTLY" = 1 ] && echo simulated || echo off)   Build jobs: ${JOBS:-no limit}"
}

# Cleaning previous installations
phase_cleaning_previous_installation() {
    ROOT_CARRY=""
    if [ "$ADD_PACKS" = 1 ]; then
        ROOT_CARRY="$(grep -E '^(RT_ROOT_TWEAKS|RT_ORIG_[A-Z_]*|RT_SWAP_FILE|RT_BOOT_SCRIPT)=' "$CONF" 2>/dev/null)"
    elif ! root_revert_from_conf; then ROOT_CARRY="$(grep -E '^(RT_ROOT_TWEAKS|RT_ORIG_[A-Z_]*|RT_SWAP_FILE|RT_BOOT_SCRIPT)=' "$CONF" 2>/dev/null)"; fi
    if [ "$PURGE_DATA" = 1 ]; then
        rm -rf "$CARGO_DATA_DIR" && ok "Removed: $CARGO_DATA_DIR"
        rm -f "$CONF" "$CONF.bak" && ok "Removed: $CONF"
        PREV_CONF=0
    fi
    if [ "$DO_RESET" = 1 ]; then
        remove_shell_integration
        remove_install_files
    else
        info "Existing files kept (--no-reset)."
    fi
    if [ "$REMOVE_DEBIAN" = 1 ]; then
        if run_logged "$(pct_at 9 10)" 60 "$LOG_DIR/proot_remove.log" proot-distro remove debian; then
            ok "Debian container removed."
        else
            warn "Could not remove the Debian container (see $LOG_DIR/proot_remove.log)."
        fi
    fi
    mkdir -p "$BASE/bin" || die "Cannot create $BASE/bin"
    ok "Clean state ready"
}

# Updating Termux packages
phase_updating_termux_packages() {
    if [ "$SKIP_UPDATE" = 1 ]; then
        info "Package update skipped (--skip-update)."
    else
        apt_repair
        if run_logged "$(pct_at 1 3)" 25 "$LOG_DIR/apt_update.log" apt-get "${APT_OPTS[@]}" update; then
            ok "Repositories updated."
        else
            warn "apt update failed (see $LOG_DIR/apt_update.log)."
            warn "The mirror may be unreachable: run 'termux-change-repo', then run this script again."
        fi
        if run_logged "$(pct_at 3 3)" 60 "$LOG_DIR/apt_upgrade.log" apt-get "${APT_OPTS[@]}" upgrade; then
            ok "Packages upgraded."
        else
            warn "apt upgrade failed (see $LOG_DIR/apt_upgrade.log), continuing."
        fi
    fi
}

# Installing dependencies
phase_installing_dependencies() {
    n=$((${#DEPS_REQUIRED[@]} + ${#DEPS_OPTIONAL[@]}))
    i=0
    for p in "${DEPS_REQUIRED[@]}"; do
        i=$((i + 1))
        opts=()
        expected=15
        if [ "$p" = rust ]; then
            expected=90
            [ "$DO_RESET" = 1 ] && opts=(--reinstall)
        fi
        if ! run_logged "$(pct_at "$i" "$n")" "$expected" "$LOG_DIR/deps_$p.log" apt-get "${APT_OPTS[@]}" install "${opts[@]}" "$p"; then
            apt_repair
            run_logged "$(pct_at "$i" "$n")" "$expected" "$LOG_DIR/deps_$p.log" apt-get "${APT_OPTS[@]}" install "${opts[@]}" "$p" ||
                die "Failed to install '$p'. See $LOG_DIR/deps_$p.log"
        fi
        ok "Package installed: $p"
    done
    for p in "${DEPS_OPTIONAL[@]}"; do
        i=$((i + 1))
        if run_logged "$(pct_at "$i" "$n")" 15 "$LOG_DIR/deps_$p.log" apt-get "${APT_OPTS[@]}" install "$p"; then
            ok "Package installed: $p (optional)"
        else
            warn "Optional package '$p' could not be installed (see $LOG_DIR/deps_$p.log)."
        fi
    done

    hash -r 2>/dev/null || true
    RUST_VER="$("$REAL_RUSTC" --version 2>"$LOG_DIR/rustc_health.log")" ||
        die "The Termux 'rust' package is broken: $(head -n1 "$LOG_DIR/rustc_health.log" 2>/dev/null)"
    CARGO_VER="$("$REAL_CARGO" --version 2>>"$LOG_DIR/rustc_health.log")" ||
        die "cargo does not run (see $LOG_DIR/rustc_health.log)"
    HOST="$("$REAL_RUSTC" -vV 2>/dev/null | sed -n 's/^host: //p')"
    ok "Compiler works: $RUST_VER"
    ok "Cargo works: $CARGO_VER"
    info "Host target: $HOST"
}

# Creating the fake rustup
phase_creating_the_fake_rustup() {
    # --- rustup ---------------------------------------------------------------------
    embed_rustup_sh >"$BASE/bin/rustup" || die "Cannot write $BASE/bin/rustup"

    # --- cargo ----------------------------------------------------------------------
    embed_cargo_sh >"$BASE/bin/cargo" || die "Cannot write $BASE/bin/cargo"

    # --- rustc ----------------------------------------------------------------------
    embed_rustc_sh >"$BASE/bin/rustc" || die "Cannot write $BASE/bin/rustc"

    chmod +x "$BASE/bin/rustup" "$BASE/bin/cargo" "$BASE/bin/rustc" || die "Cannot make the fake tools executable."
    OOM_ADJ=""
    case " $ROOT_SEL " in *" oom "*) OOM_ADJ=-300 ;; esac
    [ "$ADD_PACKS" != 1 ] || OOM_ADJ="$(sed -n 's/^oom=//p' "$BASE/settings" 2>/dev/null | head -n1)" # keep the value of the earlier install
    printf 'nightly=%s\njobs=%s\noom=%s\ntool=%s\n' "$NIGHTLY" "$JOBS" "$OOM_ADJ" "$SELF" >"$BASE/settings" || die "Cannot write $BASE/settings"
    if have lld; then ln -sf "$(command -v lld)" "$BASE/bin/rust-lld"; else warn "lld not found: WebAssembly linking will not work."; fi
    ok "Fake rustup, cargo and rustc: $BASE/bin"

    if have clang && write_baremetal_tools; then
        ok "Bare-metal ARM tools: arm-none-eabi-gcc / ar / objcopy ... (clang + llvm)"
    else
        warn "Could not create the arm-none-eabi-* tools (clang missing?)."
    fi
    bar_set "$(pct_at 1 2)"

    remove_shell_integration >/dev/null # no duplicates, whatever the previous state was
    for rc in "${RC_FILES[@]}"; do
        case "$rc" in
            */.zshrc) if [ -f "$rc" ] || have zsh; then write_rc_block "$rc" && ok "PATH added to $rc"; fi ;;
            *) write_rc_block "$rc" && ok "PATH added to $rc" || warn "Could not write $rc" ;;
        esac
    done
    export PATH="$BASE/bin:$PATH"
    hash -r 2>/dev/null || true
}

# Installing the Rust standard library sources
phase_installing_the_rust_standard_l() {
    RUST_SRC_OK=1
    if run_logged "$(pct_at 1 1)" 40 "$LOG_DIR/rust_src.log" "$BASE/bin/rustup" component add rust-src; then
        ok "Rust sources installed (they match $RUST_VER)"
    else
        RUST_SRC_OK=0
        FAILED=1
        denied "The Rust sources could not be installed (see $LOG_DIR/rust_src.log):"
        tail -n 5 "$LOG_DIR/rust_src.log" 2>/dev/null | while IFS= read -r l; do plain "    $l"; done
        warn "Without them, only the phone's own target works. Run 'rustup target add ...' later to retry."
    fi
}

# Adding targets
phase_adding_targets() {
    ADDED_TARGETS=""
    if [ -z "$TARGETS" ]; then
        info "No target requested."
    elif [ "$RUST_SRC_OK" = 0 ]; then
        denied "Targets skipped: the Rust sources are missing."
    else
        IFS=',' read -r -a tlist <<<"$TARGETS"
        n=${#tlist[@]}
        i=0
        for t in "${tlist[@]}"; do
            [ -n "$t" ] || continue
            i=$((i + 1))
            if run_logged "$(pct_at "$i" "$n")" 240 "$LOG_DIR/target_$t.log" "$BASE/bin/rustup" target add "$t"; then
                ok "Target added: $t"
                ADDED_TARGETS="$ADDED_TARGETS $t"
                grep -- '->' "$LOG_DIR/target_$t.log" 2>/dev/null | while IFS= read -r l; do plain "   ${C_DIM}${l#  }${C_RESET}"; done
            else
                denied "Target refused: $t ($(tail -n 1 "$LOG_DIR/target_$t.log" 2>/dev/null))"
            fi
        done
    fi
    ADDED_TARGETS="${ADDED_TARGETS# }"
}

# Applying root tweaks
phase_applying_root_tweaks() {
    ROOT_GOOD=""
    if [ -z "$ROOT_SEL" ]; then
        info "No root tweak requested."
    else
        n=$(echo $ROOT_SEL | wc -w)
        i=0
        for t in $ROOT_SEL; do
            i=$((i + 1))
            ROOT_APPLIED="$ROOT_APPLIED $t" # recorded even if it fails: the revert is harmless
            if [ "$t" = swap ]; then
                info "Creating the ${SWAP_MB} MB swap file (this can take a few minutes)..."
                if run_logged "$(pct_at "$i" "$n")" 120 "$LOG_DIR/root_swap.log" root_swap_create "$SWAP_MB" && root_apply_swap; then
                    ok "Root tweak applied: swap (${SWAP_MB} MB, $ROOT_SWAP_FILE)"
                    ROOT_SWAP_MB="$SWAP_MB"
                    ROOT_GOOD="$ROOT_GOOD $t"
                else
                    denied "swap: this kernel refused the swap file (see $LOG_DIR/root_swap.log); it was removed again."
                    tail -n 3 "$LOG_DIR/root_swap.log" 2>/dev/null | while IFS= read -r l; do plain "    $l"; done
                    ROOT_APPLIED="${ROOT_APPLIED% swap}"
                fi
                continue
            fi
            if "root_apply_$t"; then
                ok "Root tweak applied: $t"
                ROOT_GOOD="$ROOT_GOOD $t"
            else denied "Root tweak not applied: $t (the value did not change; nothing kept)"; fi
            bar_set "$(pct_at "$i" "$n")"
        done
        ROOT_APPLIED="${ROOT_APPLIED# }"
        ROOT_GOOD="${ROOT_GOOD# }"
        if [ "$ROOT_BOOT" = 1 ] && [ -n "$ROOT_GOOD" ]; then
            if root_write_boot_script "$ROOT_GOOD"; then
                if dst="$(root_install_boot_script)"; then
                    ROOT_BOOT_SCRIPT="$dst"
                    ok "Boot script installed: $dst"
                else
                    warn "No boot-script folder found (/data/adb/service.d or ~/.termux/boot): the tweaks last until reboot."
                    plain "    Re-apply by hand with:  su -c 'sh $BASE/root-boot.sh'"
                fi
            else info "Nothing to re-apply at boot."; fi
        fi
    fi
}

# Installing linker packs
phase_installing_linker_packs() {
    if [ -z "$PACKS" ]; then
        info "No pack requested."
    elif [ "$RUST_SRC_OK" = 0 ]; then
        denied "Packs skipped: they need the Rust sources, which are missing."
        FAILED=1
    else
        install_packs $PACKS
    fi
    if [ "$ADD_PACKS" = 1 ]; then # packs installed earlier stay recorded
        for t in $SAVED_PACKS; do
            case " $PACKS_OK " in *" $t "*) ;; *) [ -e "$TOOLS/$t.installed" ] && PACKS_OK="${PACKS_OK:+$PACKS_OK }$t" ;; esac
        done
    fi

    # --- save the choices as defaults for the next run ---------------------------------------
    # Only packages that are really installed now are recorded for the uninstaller.
    PKGS_RECORDED=""
    for p in $PKGS_ADDED; do dpkg_installed "$p" && PKGS_RECORDED="$PKGS_RECORDED $p"; done
    PKGS_ADDED="${PKGS_RECORDED# }"
    (
        umask 077
        cat >"$CONF.tmp" <<EOF
# ============================================================================
# Choices saved by $TPF_SCRIPT $TPF_VERSION
# The next run of the installer uses them as its defaults.
# The fake tools read their own copy in ~/.rustup-fake/settings instead.
# ============================================================================

# Targets added at install time (comma-separated, empty = none)
RT_TARGETS=$(q "${TARGETS}")
# Simulated nightly mode (0/1)
RT_NIGHTLY=$NIGHTLY
# Limit on parallel build jobs (empty = no limit)
RT_JOBS=$(q "$JOBS")
# Termux packages added by the installer: the uninstaller removes only these
RT_PKGS_ADDED=$(q "$PKGS_ADDED")
# Linker packs installed and verified
RT_PACKS=$(q "$PACKS_OK")
# Root was used (0/1) and the boot script was wanted (0/1)
RT_USE_ROOT=$(if [ "$ADD_PACKS" = 1 ]; then
            conf_get RT_USE_ROOT
            [ -n "$(conf_get RT_USE_ROOT)" ] || echo 0
        elif [ -n "$ROOT_SEL" ]; then echo 1; else echo 0; fi)
RT_ROOT_BOOT=$(if [ "$ADD_PACKS" = 1 ]; then
            conf_get RT_ROOT_BOOT
            [ -n "$(conf_get RT_ROOT_BOOT)" ] || echo 0
        else echo $ROOT_BOOT; fi)

$(if [ -n "$ROOT_CARRY" ]; then
            echo "# Earlier root changes that could not be reverted (kept for the uninstaller)"
            echo "$ROOT_CARRY"
        else root_conf_lines; fi)
EOF
    ) && mv -f "$CONF.tmp" "$CONF" && ok "Choices saved: $CONF" || warn "Could not write $CONF"
}

# Testing the installation
phase_testing_the_installation() {
    for t in rustup cargo rustc; do
        if [ "$(command -v "$t")" = "$BASE/bin/$t" ]; then
            ok "'$t' resolves to the fake one"
        else
            warn "'$t' resolves to $(command -v "$t" || echo nothing): open a new Termux session."
        fi
    done
    if "$BASE/bin/cargo" +nightly --version >/dev/null 2>&1; then
        ok "cargo +nightly: $("$BASE/bin/cargo" +nightly --version 2>/dev/null)"
    elif [ "$NIGHTLY" = 1 ]; then
        denied "cargo +nightly does not work."
        FAILED=1
    else
        info "Simulated nightly mode is off."
    fi

    if [ "$NO_TEST" = 1 ]; then
        info "Compile tests skipped (--no-test)."
    else
        TEST_DIR="$(mktemp -d "$HOME/.rust-termux-test.XXXXXX")" || die "Cannot create a test directory in $HOME"
        if run_logged "$(pct_at 1 3)" 60 "$LOG_DIR/test_native.log" \
            bash -c 'cd "$1" && env -u CARGO_TARGET_DIR cargo new --vcs none --quiet hello && cd hello && env -u CARGO_TARGET_DIR cargo run --quiet' _ "$TEST_DIR" &&
            grep -q 'Hello, world!' "$LOG_DIR/test_native.log"; then
            ok "Native build and run: Hello, world!"
        else
            denied "The native test failed (see $LOG_DIR/test_native.log):"
            tail -n 8 "$LOG_DIR/test_native.log" 2>/dev/null | while IFS= read -r l; do plain "    $l"; done
            FAILED=1
        fi

        T1="${ADDED_TARGETS%% *}"
        if [ -z "$T1" ]; then
            info "No target to test."
        else
            case "$T1" in
                *-none | *-none-*)
                    info "Target $T1 has no standard library: build test skipped."
                    T1=""
                    ;;
            esac
        fi
        if [ -n "$T1" ] && [ "$FAILED" = 0 ]; then
            case "$T1" in wasm32-unknown-unknown) mode=build ;; *) mode=check ;; esac
            info "Testing target $T1 ('cargo $mode'): the standard library is compiled, this takes several minutes."
            if run_logged "$(pct_at 3 3)" 240 "$LOG_DIR/test_target.log" \
                bash -c 'cd "$1/hello" && env -u CARGO_TARGET_DIR cargo "$2" --quiet --target "$3"' _ "$TEST_DIR" "$mode" "$T1"; then
                if [ "$mode" = build ]; then
                    if ls "$TEST_DIR"/hello/target/"$T1"/debug/*.wasm >/dev/null 2>&1; then
                        ok "Target $T1: compiled and linked ($(ls "$TEST_DIR"/hello/target/"$T1"/debug/*.wasm | head -n1 | xargs basename))"
                    else
                        warn "Target $T1: the build succeeded but no .wasm file was produced."
                    fi
                else
                    ok "Target $T1: 'cargo check' passed (linking is not available on Termux for this target)"
                fi
            else
                denied "The test for target $T1 failed (see $LOG_DIR/test_target.log):"
                tail -n 8 "$LOG_DIR/test_target.log" 2>/dev/null | while IFS= read -r l; do plain "    $l"; done
                FAILED=1
            fi
        fi
        rm -rf "$TEST_DIR"
        TEST_DIR=""
    fi

    # ---------------------------------------------------------------------------
    # Summary
    # ---------------------------------------------------------------------------
    bar_set 100
    if [ "$FAILED" = 0 ]; then
        banner "Installation complete and verified" "$RUST_VER"
    else
        banner "Installation finished WITH PROBLEMS" "see the lines above"
    fi
    echo " Compiler      : $RUST_VER"
    echo " Cargo         : $CARGO_VER"
    echo " Host          : $HOST"
    echo " Targets added : ${ADDED_TARGETS:-none}"
    echo " Nightly mode  : $([ "$NIGHTLY" = 1 ] && echo "ENABLED (simulated)" || echo disabled)"
    echo " Build jobs    : ${JOBS:-no limit}"
    echo " Root tweaks   : ${ROOT_GOOD:-none}"
    echo " Linker packs  : ${PACKS_OK:-none}"
    echo "------------------------------------------------------------"
    echo " Commands      : rustup | cargo | rustc   ($BASE/bin)"
    echo " Choices       : $CONF"
    echo " Manage        : $TPF_SCRIPT status | doctor | packs | linker | targets | log"
    echo " Uninstall     : $TPF_SCRIPT uninstall    (or: rustup self uninstall)"
    echo " Install logs  : $LOG_DIR"
    echo "------------------------------------------------------------"
    echo " Notes:"
    echo " - Open a new Termux session (or run: source ~/.bashrc) so that the"
    echo "   PATH change takes effect."
    echo " - Running this script again cleanly reinstalls everything; your choices"
    echo "   are kept as defaults, and ~/.cargo is kept (unless --purge-data)."
    echo " - The first build for each added target compiles the standard library"
    echo "   (several minutes); later builds are fast."
    echo " - Add targets later:  rustup target add TARGET_NAME"
    [ -z "$PACKS_OK" ] || echo " - Cross builds: cargo build --target TARGET (the right linker is chosen for you)"
    echo " - Not provided: Emscripten (would need a virtualised Linux) and WASI linking."
    [ -z "$ROOT_GOOD" ] || echo " - Root changes are undone by the uninstaller (original values are saved)."
    echo " - Full help: $TPF_SCRIPT help"
    echo "============================================================"

    [ "$FAILED" = 0 ]
}

cmd_install() {
    validate_options
    check_termux
    mkdir -p "$LOG_DIR" || die "Cannot create $LOG_DIR"
    chmod 700 "$LOG_DIR" 2>/dev/null || true
    rm -f "$LOG_DIR"/*.log 2>/dev/null
    strip_shims_from_path
    banner "Rust for Termux (fake rustup)" "install v$TPF_VERSION"
    wake_lock
    phase_checking_the_environment
    phase_choosing_options
    phase_cleaning_previous_installation
    phase_updating_termux_packages
    phase_installing_dependencies
    phase_creating_the_fake_rustup
    phase_installing_the_rust_standard_l
    phase_adding_targets
    phase_applying_root_tweaks
    phase_installing_linker_packs
    phase_testing_the_installation
}
