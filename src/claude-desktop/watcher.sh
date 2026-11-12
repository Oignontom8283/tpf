#!/data/data/com.termux/files/usr/bin/bash
# Patches Claude Code binaries downloaded by the app so that they start on Android.
# Runs while the app runs; reads the install state saved by "install".
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
# shellcheck source=/dev/null
. "$HOME/.local/share/claude-desktop-termux/state" || exit 1
GLIBC_LD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
GLIBC_LIB="$PREFIX/glibc/lib"
while pgrep -f "$APPDIR" >/dev/null 2>&1; do
    for dir in "$HOME/.config/Claude" "$HOME/.local/share/Claude" "$HOME/.claude"; do
        [ -d "$dir" ] || continue
        find "$dir" -type f -size +20M 2>/dev/null | while IFS= read -r f; do
            interp="$(patchelf --print-interpreter "$f" 2>/dev/null)" || continue
            case "$interp" in
                /lib/* | /lib64/*)
                    chmod +x "$f" 2>/dev/null
                    patchelf --set-interpreter "$GLIBC_LD" --force-rpath --set-rpath "$GLIBC_LIB" "$f" >/dev/null 2>&1 \
                        && echo "patched: $f" >>"$HOME/.claude-desktop.log"
                    ;;
            esac
        done
    done
    sleep 4
done
