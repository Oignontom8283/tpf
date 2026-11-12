# Claude Code extension support (glibc-runner).

claude_find_binaries() {
    find "$DATA_DIR/extensions" -path '*anthropic.claude-code-*/resources/native-binary/claude' 2>/dev/null
}

setup_claude_support() {
    local loader b out rc found=0 bad=0

    case "$ARCH" in
        aarch64 | arm64) ;;
        *)
            warn "glibc-runner only exists for aarch64: Claude Code support skipped."
            return 1
            ;;
    esac

    info "Enabling the Termux glibc repository..."
    apt-get "${APT_OPTS[@]}" install glibc-repo >"$LOG_DIR/glibc_repo.log" 2>&1 ||
        {
            apt_repair
            apt-get "${APT_OPTS[@]}" install glibc-repo >"$LOG_DIR/glibc_repo.log" 2>&1
        } ||
        {
            warn "glibc-repo failed (see $LOG_DIR/glibc_repo.log)."
            return 1
        }
    apt-get "${APT_OPTS[@]}" update >"$LOG_DIR/glibc_update.log" 2>&1 || true

    info "Installing glibc-runner..."
    apt-get "${APT_OPTS[@]}" install glibc-runner >"$LOG_DIR/glibc_runner.log" 2>&1 ||
        {
            apt_repair
            apt-get "${APT_OPTS[@]}" install glibc-runner >"$LOG_DIR/glibc_runner.log" 2>&1
        } ||
        {
            warn "glibc-runner failed (see $LOG_DIR/glibc_runner.log)."
            return 1
        }
    # Best effort: loader for musl-linked builds of Claude Code.
    apt-get "${APT_OPTS[@]}" install musl >"$LOG_DIR/musl.log" 2>&1 || true
    hash -r 2>/dev/null || true
    have grun || {
        warn "'grun' not found after installing glibc-runner."
        return 1
    }

    loader="$(ls "$PREFIX"/glibc/lib/ld-linux-aarch64.so.1 2>/dev/null | head -n1)"
    if [ -n "$loader" ] && ! "$loader" --version >"$LOG_DIR/glibc_loader.log" 2>&1; then
        warn "The glibc loader does not run (see $LOG_DIR/glibc_loader.log)."
        return 1
    fi
    ok "glibc-runner ready: $(command -v grun)"

    mkdir -p "$CONFIG_DIR" || return 1

    # ---- Library that fixes /proc/self/exe --------------------------------
    # Claude Code's binary is a Bun "standalone" executable: it re-reads its
    # own file to find its embedded code. Started through the glibc loader
    # (as Android requires), /proc/self/exe is the LOADER, and older Bun
    # versions then behave like plain `bun` (they print Bun's help instead of
    # running Claude Code). This tiny library makes /proc/self/exe point to
    # the real file. It is harmless for newer Bun versions.
    SELFEXE_SO="$CONFIG_DIR/claude-selfexe.so"
    rm -f "$SELFEXE_SO"
    embed_claude_selfexe_c >"$CONFIG_DIR/claude-selfexe.c"
    if apt_install apt_extra clang lld; then
        if clang --target=aarch64-linux-gnu -shared -fPIC -O2 -nostdlib -nostdinc \
            -fno-builtin -fno-stack-protector -fuse-ld=lld \
            -o "$SELFEXE_SO" "$CONFIG_DIR/claude-selfexe.c" >"$LOG_DIR/selfexe_build.log" 2>&1 && [ -s "$SELFEXE_SO" ]; then
            ok "Self-path library built: $SELFEXE_SO"
        else
            rm -f "$SELFEXE_SO"
            warn "Could not build the self-path library (see $LOG_DIR/selfexe_build.log): recent Claude Code versions may still work without it."
        fi
    else
        warn "clang / lld could not be installed: self-path library skipped."
    fi

    # ---- Normal Termux shell for Claude Code's commands ---------------------
    # Claude Code runs in a glibc environment (no LD_PRELOAD). The commands it
    # runs for you must be in your NORMAL Termux environment (/bin/sh and
    # "#!/bin/bash" lines need termux-exec). Claude Code is told to use this
    # relay as its shell (SHELL=.../bash): it restores the environment, then
    # starts the real Termux bash.
    CLAUDE_RELAY="$CONFIG_DIR/claude-shell/bash"
    mkdir -p "$CONFIG_DIR/claude-shell" || return 1
    embed_claude_relay_sh >"$CLAUDE_RELAY" || return 1
    chmod +x "$CLAUDE_RELAY" || return 1

    # ---- Settings shared by the scripts below -------------------------------
    CLAUDE_ENV="$CONFIG_DIR/claude-compat.env"
    cat >"$CLAUDE_ENV" <<EOF
CC_EXT_DIR="$DATA_DIR/extensions"
CC_SELFEXE="$SELFEXE_SO"
CC_RELAY="$CLAUDE_RELAY"
CC_GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
EOF

    # ---- Script that wraps the extension's binary ---------------------------
    # The extension starts the binary directly in several places (login check,
    # chat engine...), so the setting claudeCode.claudeProcessWrapper is not
    # enough. The binary itself is renamed claude.real and a small launcher
    # script takes its place: every way of starting it then works.
    # The extension may download a new binary later: with --watch the script
    # keeps checking while code-server runs and wraps it again.
    embed_claude_wrap_binary_sh >"$CLAUDE_WRAP_SCRIPT" || return 1
    chmod +x "$CLAUDE_WRAP_SCRIPT" || return 1
    ok "Claude Code launcher script: $CLAUDE_WRAP_SCRIPT"

    # ---- Wrap what is installed now, and test it ----------------------------
    "$CLAUDE_WRAP_SCRIPT" --once
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        found=1
        out="$(timeout 90 "$b" --version 2>&1)"
        rc=$?
        printf '%s\n' "$out" >>"$LOG_DIR/claude_test.log"
        if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qi 'claude'; then
            ok "Claude Code binary runs: $(printf '%s' "$out" | head -n1)"
        else
            bad=1
            warn "Claude Code binary FAILED (exit $rc): $b"
            printf '%s\n' "$out" | head -n 5 | sed 's/^/    /'
        fi
    done < <(claude_find_binaries)
    if [ "$found" = "0" ]; then
        info "Extension not installed yet: install 'Claude Code' in the editor; it is wrapped automatically within seconds while code-server runs. Then reload the page."
    fi
    [ "$bad" = "0" ]
}
