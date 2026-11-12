# Removal of everything this tool wrote (cmd_uninstall) and of the root changes.

run_uninstall() {
    local added="" p list="" rm_pkgs=0 rm_rust=0 rm_conf=0 rm_data=0 n i hi

    phase_begin "Checking the environment" 5
    info "Mode: full UNINSTALL"
    mkdir -p "$LOG_DIR" 2>/dev/null
    strip_shims_from_path
    load_prev_conf
    added="$(conf_get RT_PKGS_ADDED)"
    [ -d "$BASE" ] && info "Fake rustup found: $BASE" || info "No fake rustup directory (leftovers will still be cleaned)."

    # ---- questions, all asked up front -----------------------------------
    phase_begin "Choosing what to remove" 5
    for p in $added; do
        case "$PROTECTED_PKGS" in *" $p "*) continue ;; esac
        dpkg_installed "$p" && list="$list $p"
    done
    list="${list# }"
    if [ -n "$list" ]; then
        info "Packages added by the installer and still installed: $list"
        ask_yes_no "Also remove these packages?" no && rm_pkgs=1
    else
        info "The installer added no package that is still installed."
    fi
    if dpkg_installed rust && ! { [ "$rm_pkgs" = 1 ] && [[ " $list " == *" rust "* ]]; }; then
        ask_yes_no "Also remove Termux's 'rust' package (compiler and cargo)?" no && rm_rust=1
    fi
    if [ "$PURGE_DATA" = 1 ]; then
        warn "--purge-data: saved settings and $CARGO_DATA_DIR will be deleted."
        if ask_yes_no "Confirm PERMANENT deletion of this data?" no; then
            rm_conf=1
            rm_data=1
        else info "Deletion cancelled, data kept."; fi
    else
        [ -f "$CONF" ] && ask_yes_no "Also delete the saved settings ($CONF)?" no && rm_conf=1
        if [ -d "$CARGO_DATA_DIR" ]; then
            warn "$CARGO_DATA_DIR holds the downloaded crates and the tools installed with 'cargo install'."
            ask_yes_no "Also delete $CARGO_DATA_DIR?" no && rm_data=1
        fi
    fi

    # ---- removal -----------------------------------------------------------
    phase_begin "Removing the fake rustup and its leftovers" 35
    # root changes first: the saved settings (and root access) are still needed for it
    root_revert_from_conf || warn "Some root changes could not be reverted automatically (see above)."
    remove_install_files
    phase_begin "Cleaning the shell configuration" 10
    remove_shell_integration

    phase_begin "Removing packages and data" 40
    if [ "$rm_pkgs" = 1 ] || [ "$rm_rust" = 1 ]; then
        # `rust` first: the other packages may be needed by it.
        local todo=()
        { [ "$rm_rust" = 1 ] || [[ " $list " == *" rust "* ]]; } && [ "$rm_pkgs$rm_rust" != "00" ] && todo+=(rust)
        if [ "$rm_pkgs" = 1 ]; then for p in $list; do [ "$p" = rust ] || todo+=("$p"); done; fi
        n=${#todo[@]}
        i=0
        for p in "${todo[@]}"; do
            i=$((i + 1))
            hi=$(pct_at "$i" "$n")
            if ! dpkg_installed "$p"; then continue; fi
            if purge_pkg_safe "$p" "$hi"; then ok "Package removed: $p"; else
                [ "$?" = 2 ] || { warn "Could not remove package '$p' (see $LOG_DIR/apt_purge_$p.log)."; }
            fi
        done
        apt_repair
    else
        info "Termux packages kept."
    fi
    if [ "$rm_data" = 1 ]; then rm -rf "$CARGO_DATA_DIR" && ok "Removed: $CARGO_DATA_DIR"; fi
    if [ "$rm_conf" = 1 ]; then rm -f "$CONF" "$CONF.bak" "$CONF.tmp" && ok "Removed: $CONF"; fi
    [ "$rm_conf" = 1 ] || [ ! -f "$CONF" ] || info "Settings kept: $CONF (used as defaults by a future install)"

    phase_begin "Finishing" 5
    rm -rf "$LOG_DIR"
    rmdir "$(dirname "$LOG_DIR")" 2>/dev/null || true # ~/.cache, only if it is now empty
    bar_set 100
    bar_finish
    plain ""
    plain "============================================================"
    plain " Uninstall complete"
    plain "============================================================"
    plain " Close and reopen Termux so that the PATH of the current session"
    plain " forgets ~/.rustup-fake/bin (or run: hash -r; exec bash)."
    if dpkg_installed rust; then
        plain " Termux's own 'rust' package is still installed: rustc and cargo"
        plain " keep working, without rustup or extra targets."
    fi
    plain "============================================================"
}

cmd_uninstall() {
    # "reinstall" keeps the saved settings and ~/.cargo: TPF_KEEP_DATA=1
    if [ "$TPF_KEEP_DATA" = 1 ]; then PURGE_DATA=0; fi
    wake_lock
    run_uninstall
}
