#!/data/data/com.termux/files/usr/bin/bash
# Relay: gives the commands run by Claude Code a normal Termux environment.
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
if [ -n "${CT_ORIG_LD_PRELOAD:-}" ]; then
    export LD_PRELOAD="$CT_ORIG_LD_PRELOAD"
else
    for _l in "$PREFIX"/lib/libtermux-exec*.so; do
        [ -f "$_l" ] && { export LD_PRELOAD="$_l"; break; }
    done
fi
unset _l CT_ORIG_LD_PRELOAD CT_REAL_EXE LD_LIBRARY_PATH
case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) export PATH="$PREFIX/bin:$PATH" ;; esac
export SHELL="$PREFIX/bin/bash"
exec "$PREFIX/bin/bash" "$@"
