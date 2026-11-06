#!/data/data/com.termux/files/usr/bin/bash
# claude-wrap-binary.sh [--once | --watch]
ENV_FILE="$(dirname "$(readlink -f "$0")")/claude-compat.env"
. "$ENV_FILE" || exit 1
MARK="# claude-termux-wrapper"

wrap_one() {
    local f="$1" magic
    [ -f "$f" ] || return 0
    magic="$(head -c 4 "$f" 2>/dev/null | tr -d '\0')"
    if [ "$magic" = $'\x7fELF' ]; then
        mv -f "$f" "$f.real" || return 0
        chmod +x "$f.real" 2>/dev/null
    else
        return 0     # already our launcher, or not a binary: nothing to do
    fi
    cat > "$f" <<'W_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# claude-termux-wrapper — starts Claude Code's glibc binary on Android
. "__ENV_FILE__"
HERE="$(dirname "$(readlink -f "$0")")"
REAL="$HERE/claude.real"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# The original environment is kept for the relay shell (see claude-shell/bash).
export CT_ORIG_LD_PRELOAD="${LD_PRELOAD:-}"
export CT_REAL_EXE="$REAL"
# Termux's LD_PRELOAD (termux-exec) is built for Bionic and breaks glibc.
unset LD_PRELOAD
export SHELL="$CC_RELAY"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
chmod +x "$REAL" 2>/dev/null

interp=""
command -v readelf >/dev/null 2>&1 && \
    interp="$(readelf -l "$REAL" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)\]/\1/p')"
case "$interp" in
    *musl*)
        loader=""
        for c in "$PREFIX"/lib/ld-musl-*.so.1 "$PREFIX"/musl/lib/ld-musl-*.so.1 "$PREFIX"/lib/musl/ld-musl-*.so.1; do
            [ -x "$c" ] && { loader="$c"; break; }
        done
        [ -n "$loader" ] || { echo "musl loader not found (try: pkg install musl)" >&2; exit 127; }
        exec "$loader" "$REAL" "$@" ;;
    *)
        # The glibc loader is called directly (not through grun) so that
        # --preload applies to this program only, not to the commands it runs.
        args=(--library-path "$PREFIX/glibc/lib")
        [ -f "$CC_SELFEXE" ] && args+=(--preload "$CC_SELFEXE")
        exec "$CC_GLIBC_LD" "${args[@]}" "$REAL" "$@" ;;
esac
W_EOF
    sed -i "s|__ENV_FILE__|$ENV_FILE|" "$f"
    chmod +x "$f"
}

scan() {
    local f
    for f in "$CC_EXT_DIR"/anthropic.claude-code-*/resources/native-binary/claude; do
        wrap_one "$f"
    done
}

case "${1:---once}" in
    --watch)
        while pgrep -f 'code-server([[:space:]]|$)|code-server/out/node/entry' >/dev/null 2>&1; do
            scan
            sleep 5
        done ;;
    *) scan ;;
esac
