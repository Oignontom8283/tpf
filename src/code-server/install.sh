# Installation of code-server, in phases (run in this order by cmd_install).

# tpf:embed ./android-as-linux.js as embed_android_as_linux_js
# tpf:embed ./claude-relay.sh as embed_claude_relay_sh
# tpf:embed ./claude-selfexe.c as embed_claude_selfexe_c
# tpf:embed ./claude-wrap-binary.sh as embed_claude_wrap_binary_sh

# --- helpers ---------------------------------------------------------------------
cs_install_root() {
    local bin real d
    bin="$(command -v code-server 2>/dev/null)" || return 1
    [ -n "$bin" ] || return 1
    real="$(readlink -f "$bin" 2>/dev/null || echo "$bin")"
    d="$(dirname "$real")"
    while [ "$d" != "/" ] && [ -n "$d" ]; do
        if [ -f "$d/package.json" ] && grep -q '"name"[[:space:]]*:[[:space:]]*"code-server"' "$d/package.json" 2>/dev/null; then
            echo "$d"
            return 0
        fi
        d="$(dirname "$d")"
    done
    return 1
}

# Health check: this is what catches "Cannot find module ..." errors.
cs_health_check() {
    local out rc
    hash -r 2>/dev/null || true
    have code-server || {
        CS_HEALTH_MSG="no code-server binary in PATH"
        return 1
    }
    out="$(env -u NODE_OPTIONS timeout 180 code-server --version 2>&1)"
    rc=$?
    printf '%s\n' "$out" >"$LOG_DIR/health.log"
    if [ $rc -ne 0 ]; then
        if printf '%s' "$out" | grep -q "MODULE_NOT_FOUND\|Cannot find module"; then
            CS_HEALTH_MSG="broken install (missing Node.js modules): $(printf '%s' "$out" | grep -m1 "Cannot find module")"
        elif [ $rc -eq 124 ]; then
            CS_HEALTH_MSG="'code-server --version' timed out"
        else
            CS_HEALTH_MSG="'code-server --version' failed (exit code $rc) — see $LOG_DIR/health.log"
        fi
        return 1
    fi
    CS_VERSION="$(printf '%s' "$out" | head -n1)"
    CS_HEALTH_MSG=""
    return 0
}

cs_supports_flag() {
    [ -n "${CS_HELP_CACHE:-}" ] || CS_HELP_CACHE="$(env -u NODE_OPTIONS timeout 120 code-server --help 2>&1)"
    printf '%s' "$CS_HELP_CACHE" | grep -q -- "$1"
}

install_via_tur() {
    info "TUR method (prebuilt package, fast)..."
    if ! apt-get "${APT_OPTS[@]}" install tur-repo >"$LOG_DIR/tur_repo.log" 2>&1; then
        warn "Could not enable the TUR repository (see $LOG_DIR/tur_repo.log)."
        return 1
    fi
    apt-get "${APT_OPTS[@]}" update >"$LOG_DIR/tur_update.log" 2>&1 || true
    if ! apt-get "${APT_OPTS[@]}" install --reinstall code-server >"$LOG_DIR/tur_install.log" 2>&1; then
        warn "The TUR 'code-server' package could not be installed (see $LOG_DIR/tur_install.log)."
        return 1
    fi
    ok "code-server installed from TUR."
    return 0
}

install_via_npm() {
    info "npm method (builds native modules such as argon2 and node-pty)."
    info "This takes several minutes on a phone. Keep Termux in the foreground."

    local rc=0
    local -a npm_env=()
    : >"$LOG_DIR/npm_install.log"

    npm install --global --no-fund --no-audit code-server >>"$LOG_DIR/npm_install.log" 2>&1 || rc=$?

    if [ $rc -ne 0 ] && grep -qi "requires node\|FORCE_NODE_VERSION\|Unsupported engine" "$LOG_DIR/npm_install.log"; then
        warn "code-server rejects Node.js $NODE_VERSION. Retrying with FORCE_NODE_VERSION=$NODE_MAJOR."
        warn "Not officially supported: unexpected behaviour is possible."
        npm_env=(FORCE_NODE_VERSION="$NODE_MAJOR")
        rc=0
        env "${npm_env[@]}" npm install --global --no-fund --no-audit code-server \
            >>"$LOG_DIR/npm_install.log" 2>&1 || rc=$?
    fi

    if [ $rc -ne 0 ]; then
        warn "npm failed. Cleaning the npm cache and retrying..."
        npm cache clean --force >/dev/null 2>&1 || true
        rm -rf "$PREFIX/lib/node_modules/code-server" 2>/dev/null
        rc=0
        env "${npm_env[@]}" npm install --global --no-fund --no-audit code-server \
            >>"$LOG_DIR/npm_install.log" 2>&1 || rc=$?
    fi

    if [ $rc -ne 0 ]; then
        warn "npm install failed (see $LOG_DIR/npm_install.log):"
        tail -n 15 "$LOG_DIR/npm_install.log" | sed 's/^/    /'
        return 1
    fi
    ok "code-server installed with npm."
    return 0
}

try_method() {
    local m="$1"
    case "$m" in
        tur) install_via_tur || return 1 ;;
        npm) install_via_npm || return 1 ;;
    esac
    info "Checking the installation ($m)..."
    if cs_health_check; then
        ok "Working $m install: $CS_VERSION"
        INSTALL_METHOD="$m"
        return 0
    fi
    warn "BROKEN $m install: $CS_HEALTH_MSG"
    return 1
}

# Reads one variable from the previous settings file, in a subshell so it
# cannot overwrite this script's own variables.
conf_get() {
    [ "$PREV_CONF" = "1" ] || return 0
    (
        set +u
        . "$CONF" >/dev/null 2>&1 </dev/null
        printf '%s' "${!1:-}"
    )
}

prev_or() {
    local v
    v="$(conf_get "$1")"
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

prev_answer() { if [ "$(conf_get "$1")" = "1" ]; then echo yes; else echo no; fi; }

# 1. Shared storage
phase_shared_storage() {
    if [ ! -d "$HOME/storage" ] && have termux-setup-storage; then
        info "Requesting access to shared storage (/sdcard) — accept the Android prompt if it appears."
        termux-setup-storage >/dev/null 2>&1 || warn "termux-setup-storage refused or failed, continuing."
        sleep 1
    fi
}

# 2. Package update
phase_package_update() {
    if [ "$SKIP_UPDATE" = "1" ]; then
        info "Package update skipped (--skip-update)."
    else
        step "Updating Termux packages"
        apt_repair
        if apt-get "${APT_OPTS[@]}" update >"$LOG_DIR/apt_update.log" 2>&1; then
            ok "Repositories updated."
        else
            warn "apt update failed (see $LOG_DIR/apt_update.log)."
            warn "The mirror may be unreachable: run 'termux-change-repo', then run this script again."
        fi
        if apt-get "${APT_OPTS[@]}" upgrade >"$LOG_DIR/apt_upgrade.log" 2>&1; then
            ok "Packages upgraded."
        else
            warn "apt upgrade failed (see $LOG_DIR/apt_upgrade.log), continuing."
        fi
    fi
}

# 3. Dependencies
phase_dependencies() {
    step "Dependencies"
    # Required: Node.js LTS + the toolchain needed to build native npm modules.
    DEPS_REQUIRED=(build-essential binutils pkg-config python nodejs-lts curl procps coreutils)
    # Optional: useful but not blocking.
    DEPS_OPTIONAL=(git ripgrep openssl)

    if dpkg_installed nodejs && ! dpkg_installed nodejs-lts; then
        warn "The 'nodejs' package is installed. It conflicts with 'nodejs-lts' and will be REPLACED."
        warn "Other programs will then use the LTS version of Node.js."
    fi

    info "Installing: ${DEPS_REQUIRED[*]}"
    if ! apt-get "${APT_OPTS[@]}" install "${DEPS_REQUIRED[@]}" >"$LOG_DIR/deps.log" 2>&1; then
        apt_repair
        apt-get "${APT_OPTS[@]}" install "${DEPS_REQUIRED[@]}" >"$LOG_DIR/deps.log" 2>&1 ||
            die "Failed to install the dependencies. See $LOG_DIR/deps.log"
    fi
    ok "Required dependencies installed."

    : >"$LOG_DIR/deps_optional.log"
    for pkg in "${DEPS_OPTIONAL[@]}"; do
        apt-get "${APT_OPTS[@]}" install "$pkg" >>"$LOG_DIR/deps_optional.log" 2>&1 ||
            warn "Optional package '$pkg' could not be installed (see $LOG_DIR/deps_optional.log)."
    done

    # Optional: libandroid-spawn fixes some native builds (posix_spawn).
    if apt-get "${APT_OPTS[@]}" install libandroid-spawn >"$LOG_DIR/libandroid-spawn.log" 2>&1; then
        if [ -f "$PREFIX/lib/libandroid-spawn.so" ] || [ -f "$PREFIX/lib/libandroid-spawn.a" ]; then
            export LDFLAGS="${LDFLAGS:-} -landroid-spawn"
            info "libandroid-spawn available: LDFLAGS adjusted for native modules."
        fi
    fi

    have node || die "node not found after installing nodejs-lts."
    have npm || die "npm not found after installing nodejs-lts."

    NODE_VERSION="$(node -v 2>/dev/null)"
    NODE_MAJOR="$(printf '%s' "$NODE_VERSION" | sed 's/^v//; s/\..*//')"
    info "node: $NODE_VERSION    npm: $(npm -v 2>/dev/null)"

    npm config set python "$(command -v python3 || command -v python)" >/dev/null 2>&1 || true
    npm_config_python="$(command -v python3 || command -v python)"
    export npm_config_python

    AVAIL_MB="$(df -Pm "$PREFIX" 2>/dev/null | awk 'NR==2 {print $4}')"
    if is_uint "${AVAIL_MB:-}" && [ "$AVAIL_MB" -lt 1500 ]; then
        warn "Low free space: ${AVAIL_MB} MB. An npm install needs about 1.5 GB."
    fi
}

# 4. Removal, then installation
phase_removal_then_installation() {
    [ "$PURGE_DATA" = "1" ] && purge_user_data
    [ "$DO_RESET" = "1" ] && purge_code_server

    step "Installing code-server"
    INSTALL_METHOD=""

    if [ "$DO_RESET" = "0" ] && have code-server && cs_health_check; then
        ok "Existing install works: $CS_VERSION (--no-reset)"
        INSTALL_METHOD="existing"
    else
        case "$METHOD" in
            tur) try_method tur || die "TUR install failed or is broken. Try again with --method npm." ;;
            npm) try_method npm || die "npm install failed or is broken. See $LOG_DIR/npm_install.log" ;;
            auto)
                if ! try_method tur; then
                    warn "Switching to the npm method."
                    purge_code_server
                    try_method npm || die "Both methods failed. Logs in $LOG_DIR"
                fi
                ;;
        esac
    fi

    CS_BIN="$(command -v code-server)"
    CS_ROOT="$(cs_install_root || true)"
    info "Binary: $CS_BIN"
    [ -n "$CS_ROOT" ] && info "Install directory: $CS_ROOT"
}

# 5. argon2 native module (used for password authentication)
phase_argon2_native_module_used_fo() {
    if [ -n "$CS_ROOT" ]; then
        ARGON2_DIR=""
        for d in "$CS_ROOT/node_modules/argon2" "$CS_ROOT/lib/vscode/node_modules/argon2"; do
            [ -d "$d" ] && {
                ARGON2_DIR="$d"
                break
            }
        done
        if [ -n "$ARGON2_DIR" ]; then
            if find "$ARGON2_DIR" -name "*.node" 2>/dev/null | grep -q .; then
                ok "argon2 native module present."
            else
                warn "argon2 native binary missing: rebuilding for $ARCH..."
                (cd "$CS_ROOT" && npm rebuild argon2) >"$LOG_DIR/argon2_build.log" 2>&1 ||
                    (cd "$ARGON2_DIR" && npx --yes node-gyp rebuild) >>"$LOG_DIR/argon2_build.log" 2>&1
                if find "$ARGON2_DIR" -name "*.node" 2>/dev/null | grep -q .; then
                    ok "argon2 rebuilt."
                else
                    warn "argon2 rebuild failed (see $LOG_DIR/argon2_build.log)."
                    warn "Password authentication may not work; CS_AUTH=none remains usable."
                fi
            fi
        else
            info "No argon2 directory found (self-contained build): nothing to do."
        fi
    fi

    # ---------------------------------------------------------------------------
    # 6. ripgrep fix (powers "search in files" in the editor)
    #    The bundled rg binary is built for desktop Linux; Termux's own rg is
    #    linked in its place.
    # ---------------------------------------------------------------------------
    step "ripgrep fix"
    RG_BIN="$(command -v rg 2>/dev/null)"
    if [ -z "$RG_BIN" ]; then
        warn "rg not found: searching inside files will not work."
    elif [ -z "$CS_ROOT" ]; then
        warn "Install directory unknown: ripgrep fix skipped."
    else
        RG_PATCHED=0
        while IFS= read -r rg_dir; do
            [ -n "$rg_dir" ] || continue
            mkdir -p "$rg_dir/bin" 2>/dev/null
            ln -sfn "$RG_BIN" "$rg_dir/bin/rg" && RG_PATCHED=$((RG_PATCHED + 1))
        done < <(find "$CS_ROOT" -type d \( -path "*node_modules/@vscode/ripgrep" -o -path "*node_modules/vscode-ripgrep" \) 2>/dev/null)
        if [ "$RG_PATCHED" -gt 0 ]; then
            ok "Termux ripgrep linked in $RG_PATCHED location(s)."
        else
            info "No bundled ripgrep found (build already uses the system rg): nothing to do."
        fi
    fi

    # ---------------------------------------------------------------------------
    # Previous launcher settings (reused as defaults: a reinstall must not
    # silently change the user's choices)
    # ---------------------------------------------------------------------------
    PREV_CONF=0
    if [ -f "$CONF" ]; then
        if bash -n "$CONF" 2>/dev/null; then
            PREV_CONF=1
            info "Previous settings found: $CONF"
        else
            warn "$CONF contains a syntax error: saved as $CONF.bak, defaults used."
            mv -f "$CONF" "$CONF.bak" 2>/dev/null
        fi
    fi

    # ---------------------------------------------------------------------------
    # 7. Root access + inotify limit
    #    The editor watches files with inotify; large projects can exceed
    #    Android's default limit (ENOSPC errors). Raising it requires root.
    # ---------------------------------------------------------------------------
    step "Advanced options"
    IS_ROOT_USER=0
    [ "$(id -u)" = "0" ] && IS_ROOT_USER=1
    ROOT_HELPER="$(find_real_su || true)"
    USE_ROOT_INOTIFY=0
    INOTIFY_WATCHES="$(prev_or CS_INOTIFY_WATCHES 524288)"
    is_uint "$INOTIFY_WATCHES" || INOTIFY_WATCHES=524288

    if [ "$IS_ROOT_USER" = "1" ] || [ -n "$ROOT_HELPER" ]; then
        if [ "$IS_ROOT_USER" = "1" ]; then
            info "This shell already runs as root (uid 0)."
        else
            info "su binary found: $ROOT_HELPER"
        fi
        CURRENT_LIMIT="$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo unknown)"
        info "Current inotify limit: $CURRENT_LIMIT"
        if ask_yes_no "Raise the inotify limit to $INOTIFY_WATCHES (avoids ENOSPC errors on large projects)?" "$(prev_answer CS_ROOT_INOTIFY)"; then
            if [ "$IS_ROOT_USER" = "1" ]; then
                if echo "$INOTIFY_WATCHES" >/proc/sys/fs/inotify/max_user_watches 2>"$LOG_DIR/inotify.log"; then
                    USE_ROOT_INOTIFY=1
                    ok "inotify limit set to $INOTIFY_WATCHES."
                else
                    warn "Direct write refused (see $LOG_DIR/inotify.log)."
                fi
            else
                warn "A root permission prompt will appear: accept it."
                if "$ROOT_HELPER" -c "echo $INOTIFY_WATCHES > /proc/sys/fs/inotify/max_user_watches" >"$LOG_DIR/inotify.log" 2>&1; then
                    USE_ROOT_INOTIFY=1
                    ok "inotify limit set to $INOTIFY_WATCHES until the next reboot."
                else
                    warn "Failed through $ROOT_HELPER (see $LOG_DIR/inotify.log). Root denied?"
                fi
            fi
        fi
    else
        info "No root access detected: inotify tuning skipped (not required)."
    fi
}

# 8. "Android as Linux" workaround (documented by Coder)
phase_android_as_linux_workaround() {
    # ---------------------------------------------------------------------------
    # 7b. Claude Code extension compatibility
    #     The extension ships a native binary built for desktop Linux (glibc).
    #     Android (Bionic) has no glibc loader, so the binary cannot start
    #     ("the file is there, but a program it needs is missing").
    #     Fix: the glibc loader from glibc-runner (Termux glibc repository) runs it.
    #     The extension starts the binary directly in several places, so the
    #     binary itself is renamed claude.real and replaced by a launcher script
    #     (see claude-wrap-binary.sh, kept up to date while code-server runs).
    #     This needs the "Android as Linux" workaround so that the extension
    #     (linux-arm64 build) can be installed at all.
    # ---------------------------------------------------------------------------
    CLAUDE_COMPAT=0
    echo
    warn "Claude Code extension support (runs its Linux binary through glibc-runner)."
    echo "   Adds the Termux glibc repository + glibc-runner (~100-200 MB) and a"
    echo "   launcher wrapper. Forces the \"Android as Linux\" workaround below."
    if [ "$CLAUDE_OPT" = "1" ]; then
        CLAUDE_COMPAT=1
        info "--claude-code: enabled."
    elif [ "$CLAUDE_OPT" = "0" ]; then
        info "--no-claude-code: skipped."
    elif ask_yes_no "Set up Claude Code support?" "$(prev_answer CS_CLAUDE_COMPAT)"; then
        CLAUDE_COMPAT=1
    fi

    # The old claudeProcessWrapper setting is no longer used: it is removed from
    # settings.json below (the extension starts the binary directly in places
    # where that setting does not apply).
    CLAUDE_WRAPPER_ACTIVE=0
    if [ "$CLAUDE_COMPAT" = "1" ]; then
        setup_claude_support ||
            warn "Claude Code support is incomplete: see the messages above and $LOG_DIR."
    fi

    ENABLE_LINUX_SPOOF=0
    echo
    warn "Workaround: make the editor believe Android is Linux."
    echo "   Benefit: regular (non-web) extensions can be installed."
    echo "   Risk   : extensions with native code or that interact with the OS"
    echo "            may crash. Documented by Coder as \"use at your own risk\"."
    if [ "$CLAUDE_COMPAT" = "1" ]; then
        info "Required by Claude Code support: enabled automatically."
        ENABLE_SPOOF_NOW=1
    elif ask_yes_no "Enable this workaround?" "$(prev_answer CS_LINUX_SPOOF)"; then
        ENABLE_SPOOF_NOW=1
    else
        ENABLE_SPOOF_NOW=0
    fi
    if [ "$ENABLE_SPOOF_NOW" = "1" ]; then
        ENABLE_LINUX_SPOOF=1
        mkdir -p "$CONFIG_DIR" || die "Cannot create $CONFIG_DIR"
        embed_android_as_linux_js >"$SPOOF_FILE" || die "Cannot write $SPOOF_FILE"
        ok "Workaround enabled: $SPOOF_FILE"
    else
        rm -f "$SPOOF_FILE" 2>/dev/null
        info "Workaround disabled: only web extensions can be installed."
    fi
}

# 9. Microsoft marketplace (optional, against its terms of use)
phase_microsoft_marketplace_option() {
    ENABLE_MS_MARKETPLACE=0
    echo
    warn "Optional: Microsoft's VS Code marketplace instead of Open VSX."
    echo "   - Against Microsoft's terms of use (reserved for official VS Code"
    echo "     products); Coder explicitly advises against it."
    echo "   - NOT GUARANTEED: Microsoft may block unrecognised clients."
    echo "   - May stop working without notice."
    if ask_yes_no "Configure the Microsoft marketplace anyway?" "$(prev_answer CS_MS_MARKETPLACE)"; then
        ENABLE_MS_MARKETPLACE=1
        ok "Microsoft marketplace enabled (at your own risk)."
    else
        info "Open VSX kept (default, officially supported)."
    fi
}

# 10. settings.json (makes Tab and keyboard shortcuts work on Android)
phase_settings_json_makes_tab_and() {
    step "Editor settings"
    mkdir -p "$CONFIG_DIR" "$DATA_DIR/User" || die "Cannot create the configuration directories."

    if [ -f "$SETTINGS_FILE" ]; then
        if node -e '
const fs = require("fs"), p = process.argv[1];
const raw = fs.readFileSync(p, "utf8").trim();
const o = raw ? JSON.parse(raw) : {};
if (o === null || typeof o !== "object" || Array.isArray(o)) throw new Error("not an object");
o["keyboard.dispatch"] = "keyCode";
const w = process.argv[2], k = "claudeCode.claudeProcessWrapper";
if (w) o[k] = w;                               // enable
else if (typeof o[k] === "string" && o[k].endsWith("claude-code-wrapper.sh")) delete o[k];  // ours only
fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
' "$SETTINGS_FILE" "$([ "$CLAUDE_WRAPPER_ACTIVE" = "1" ] && echo "$CLAUDE_WRAPPER")" 2>/dev/null; then
            ok "settings.json updated (keyboard.dispatch = keyCode$([ "$CLAUDE_WRAPPER_ACTIVE" = "1" ] && echo ", Claude Code wrapper set"))."
        else
            warn "settings.json could not be parsed (comments or trailing commas?): left unchanged."
            warn "Add \"keyboard.dispatch\": \"keyCode\" yourself so that the Tab key works."
        fi
    else
        if [ "$CLAUDE_WRAPPER_ACTIVE" = "1" ]; then
            printf '{\n  "keyboard.dispatch": "keyCode",\n  "claudeCode.claudeProcessWrapper": "%s"\n}\n' "$CLAUDE_WRAPPER" >"$SETTINGS_FILE"
        else
            printf '{\n  "keyboard.dispatch": "keyCode"\n}\n' >"$SETTINGS_FILE"
        fi &&
            ok "settings.json created (Tab key and shortcuts working)."
    fi
}

# 11. ~/code-server.conf — settings read by ~/code-server.sh
phase_code_server_conf_settings_re() {
    step "Launch settings"

    CONF_PORT="$(prev_or CS_PORT 8080)"
    CONF_IP="$(prev_or CS_IP 127.0.0.1)"
    CONF_AUTH="$(prev_or CS_AUTH none)"
    CONF_PASSWORD="$(prev_or CS_PASSWORD "")"
    CONF_LOG_LINES="$(prev_or CS_LOG_LINES 25)"
    CONF_START_TIMEOUT="$(prev_or CS_START_TIMEOUT 45)"
    CONF_START_RETRIES="$(prev_or CS_START_RETRIES 2)"

    # Command-line options take precedence over saved values.
    [ -n "$PORT" ] && CONF_PORT="$PORT"
    [ -n "$BIND_HOST" ] && CONF_IP="$BIND_HOST"
    [ -n "$AUTH_MODE" ] && CONF_AUTH="$AUTH_MODE"
    [ "$NEW_PASSWORD" = "1" ] && CONF_PASSWORD=""

    # Saved values are validated too (the file may have been edited by hand).
    is_port "$CONF_PORT" || {
        warn "Saved port '$CONF_PORT' is invalid: 8080 used."
        CONF_PORT=8080
    }
    case "$CONF_IP" in
        '' | *:* | *[[:space:]]* | *\"* | *\'*)
            warn "Saved address '$CONF_IP' is invalid: 127.0.0.1 used."
            CONF_IP=127.0.0.1
            ;;
    esac
    case "$CONF_AUTH" in
        none | password) ;;
        *)
            warn "Saved authentication mode '$CONF_AUTH' is invalid: 'password' used (safer)."
            CONF_AUTH=password
            ;;
    esac
    is_uint "$CONF_LOG_LINES" || CONF_LOG_LINES=25
    { is_uint "$CONF_START_TIMEOUT" && [ "$CONF_START_TIMEOUT" -ge 1 ]; } || CONF_START_TIMEOUT=45
    { is_uint "$CONF_START_RETRIES" && [ "$CONF_START_RETRIES" -ge 1 ]; } || CONF_START_RETRIES=2

    if [ "$CONF_AUTH" = "password" ] && [ -z "$CONF_PASSWORD" ]; then
        CONF_PASSWORD="$(gen_password)"
        info "Password generated."
    fi

    # Extra arguments: only those supported by the installed version.
    EXTRA_ARGS=""
    cs_supports_flag "--disable-telemetry" && EXTRA_ARGS="$EXTRA_ARGS --disable-telemetry"
    cs_supports_flag "--disable-update-check" && EXTRA_ARGS="$EXTRA_ARGS --disable-update-check"
    EXTRA_ARGS="${EXTRA_ARGS# }"

    (
        umask 077
        cat >"$CONF.tmp" <<EOF
# ============================================================================
# Settings for code-server.sh — edit this file, then run:
#     ./code-server.sh restart
# It is read again by every command. code-server's own config.yaml is
# generated from these values: do not edit config.yaml by hand.
# ============================================================================

# --- Network ---------------------------------------------------------------
CS_PORT=$(q "$CONF_PORT")
# 127.0.0.1 = reachable only from this device
# 0.0.0.0   = reachable from other devices on the local network
# (IPv6 addresses are not supported by this launcher)
CS_IP=$(q "$CONF_IP")

# --- Authentication --------------------------------------------------------
# none     : no password. Note: any app on this device can reach 127.0.0.1,
#            and code-server gives full shell access to Termux.
# password : password required (generated automatically if left empty)
CS_AUTH=$(q "$CONF_AUTH")
CS_PASSWORD=$(q "$CONF_PASSWORD")

# --- Start-up --------------------------------------------------------------
# Log lines shown when start-up fails
CS_LOG_LINES=$(q "$CONF_LOG_LINES")
# Maximum seconds to wait for the server to answer
CS_START_TIMEOUT=$(q "$CONF_START_TIMEOUT")
# Start attempts before giving up
CS_START_RETRIES=$(q "$CONF_START_RETRIES")

# --- Paths -----------------------------------------------------------------
# Empty CS_BIN = look up code-server in the PATH
CS_BIN=$(q "$CS_BIN")
CS_LOG_FILE=$(q "$LOG_FILE")
CS_PID_FILE=$(q "$PID_FILE")
CS_CONFIG_DIR=$(q "$CONFIG_DIR")
CS_DATA_DIR=$(q "$DATA_DIR")

# --- Options chosen at install time ----------------------------------------
# Non-web extensions through the "Android as Linux" workaround (0/1)
CS_LINUX_SPOOF=$ENABLE_LINUX_SPOOF
# Claude Code extension support through glibc-runner (0/1)
CS_CLAUDE_COMPAT=$CLAUDE_COMPAT
# Microsoft marketplace instead of Open VSX (0/1, against its terms, not guaranteed)
CS_MS_MARKETPLACE=$ENABLE_MS_MARKETPLACE
# inotify limit re-applied at each start through root (0/1)
CS_ROOT_INOTIFY=$USE_ROOT_INOTIFY
CS_INOTIFY_WATCHES=$(q "$INOTIFY_WATCHES")
CS_ROOT_HELPER=$(q "$ROOT_HELPER")
# Extra arguments passed to code-server (split on spaces)
CS_EXTRA_ARGS=$(q "$EXTRA_ARGS")
EOF
    ) && mv -f "$CONF.tmp" "$CONF" || die "Cannot write $CONF"
    ok "Settings: $CONF (port $CONF_PORT, address $CONF_IP, auth $CONF_AUTH)"

    if [ "$CONF_AUTH" = "none" ] && [ "$CONF_IP" != "127.0.0.1" ] && [ "$CONF_IP" != "localhost" ]; then
        warn "CS_AUTH=none with CS_IP=$CONF_IP: anyone on the network can open your editor."
        warn "Set CS_AUTH=password in $CONF unless the network is trusted."
    fi
}

# 13. Start at boot (optional, requires the Termux:Boot app)
phase_start_at_boot_optional_requi() {
    BOOT_DEFAULT=no
    [ -f "$BOOT_FILE" ] && BOOT_DEFAULT=yes
    if ask_yes_no "Start code-server automatically when the device boots (requires the Termux:Boot app)?" "$BOOT_DEFAULT"; then
        mkdir -p "$(dirname "$BOOT_FILE")" 2>/dev/null
        cat >"$BOOT_FILE" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock 2>/dev/null
$(printf '%q' "$SELF") start
EOF
        chmod +x "$BOOT_FILE" 2>/dev/null
        ok "Start at boot configured: $BOOT_FILE (install Termux:Boot from F-Droid)."
        info "It runs $SELF: keep the script there, or run install again after moving it."
    else
        rm -f "$BOOT_FILE" 2>/dev/null
    fi
}

# 14. Real start-up test
phase_real_start_up_test() {
    step "Start-up test"
    stop_running_instance
    # The installer's wake lock is released here; start takes its own.
    if cmd_start; then
        STARTED=1
    else
        STARTED=0
        warn "Start-up failed. Diagnosis above, full log: $LOG_FILE"
    fi
}

# Summary
phase_summary() {
    LOCAL_IP="$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
    if [ "$STARTED" = "1" ]; then
        banner "Installation complete and verified" "code-server ${CS_VERSION:-unknown}"
    else
        banner "Installation complete - code-server did not start" "see the messages above"
    fi
    echo " Version       : ${CS_VERSION:-unknown}"
    echo " Method        : $INSTALL_METHOD"
    echo " Local access  : http://127.0.0.1:$CONF_PORT"
    if [ "$CONF_IP" = "0.0.0.0" ] && [ -n "$LOCAL_IP" ]; then
        echo " LAN access    : http://$LOCAL_IP:$CONF_PORT"
    elif [ -n "$LOCAL_IP" ]; then
        echo " LAN access    : set CS_IP=0.0.0.0 in the settings file (current IP: $LOCAL_IP)"
    fi
    if [ "$CONF_AUTH" = "password" ]; then
        echo " Password      : $CONF_PASSWORD"
    else
        echo " Auth          : none (CS_AUTH=none)"
    fi
    echo "------------------------------------------------------------"
    echo " Management    : $TPF_SCRIPT start | stop | restart | status | log"
    echo " Settings      : $CONF"
    echo " Server log    : $LOG_FILE"
    echo " Install logs  : $LOG_DIR"
    echo "------------------------------------------------------------"
    echo " Non-web extensions (Android as Linux) : $([ "$ENABLE_LINUX_SPOOF" = "1" ] && echo ENABLED || echo disabled)"
    echo " Claude Code support (glibc-runner)    : $([ "$CLAUDE_COMPAT" = "1" ] && echo ENABLED || echo disabled)"
    echo " Microsoft marketplace                 : $([ "$ENABLE_MS_MARKETPLACE" = "1" ] && echo "ENABLED (not guaranteed)" || echo "disabled (Open VSX)")"
    echo " inotify limit through root            : $([ "$USE_ROOT_INOTIFY" = "1" ] && echo "ENABLED ($INOTIFY_WATCHES)" || echo disabled)"
    echo "============================================================"
    echo " Notes:"
    echo " - $TPF_SCRIPT reinstall reinstalls code-server cleanly; extensions,"
    echo "   editor settings and $CONF are kept."
    echo " - Port, address, authentication, start-up timeout and retries are all"
    echo "   set in $CONF, then: $TPF_SCRIPT restart"
    echo " - The inotify limit resets when the device reboots;"
    echo "   $TPF_SCRIPT start applies it again automatically."
    echo " - Microsoft marketplace: against its terms of use and not guaranteed."
    echo " - Full help: $TPF_SCRIPT help"
    echo "============================================================"

    [ "$STARTED" = "1" ]
}

cmd_install() {
    require_termux
    ARCH="$(uname -m)"
    banner "code-server for Termux" "install v$TPF_VERSION"
    info "Architecture: $ARCH"
    info "Termux PREFIX: $PREFIX"
    case "$ARCH" in
        aarch64 | arm64) ;;
        armv7l | armv8l | arm) warn "32-bit architecture: the TUR package is often missing, npm fallback likely." ;;
        *) warn "Untested architecture ($ARCH): it may work, no guarantee." ;;
    esac
    [ "$PURGE_DATA" = "1" ] && warn "--purge-data: editor settings, extensions and user data will ALSO be deleted."
    wake_lock
    phase_shared_storage
    phase_package_update
    phase_dependencies
    phase_removal_then_installation
    phase_argon2_native_module_used_fo
    phase_android_as_linux_workaround
    phase_microsoft_marketplace_option
    phase_settings_json_makes_tab_and
    phase_code_server_conf_settings_re
    phase_start_at_boot_optional_requi
    phase_real_start_up_test
    phase_summary
}
