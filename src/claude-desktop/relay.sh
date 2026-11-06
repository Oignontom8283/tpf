#!/data/data/com.termux/files/usr/bin/bash
# Relay: gives programs started by Claude Desktop a normal Termux environment.
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# termux-exec: makes /bin/sh, /usr/bin/env and "#!/bin/bash" lines work.
if [ -n "${CT_ORIG_LD_PRELOAD:-}" ]; then
    export LD_PRELOAD="$CT_ORIG_LD_PRELOAD"
else
    for _l in "$PREFIX"/lib/libtermux-exec*.so; do
        [ -f "$_l" ] && { export LD_PRELOAD="$_l"; break; }
    done
fi
unset _l

# Variables set only for the Electron app.
unset FONTCONFIG_FILE GSETTINGS_SCHEMA_DIR GDK_BACKEND GTK_USE_PORTAL ELECTRON_DISABLE_SANDBOX \
      ELECTRON_RUN_AS_NODE LD_LIBRARY_PATH
if [ -n "${CT_ORIG_XDG_DATA_DIRS:-}" ]; then export XDG_DATA_DIRS="$CT_ORIG_XDG_DATA_DIRS"; else unset XDG_DATA_DIRS; fi
if [ -n "${CT_ORIG_DBUS:-}" ]; then export DBUS_SESSION_BUS_ADDRESS="$CT_ORIG_DBUS"; else unset DBUS_SESSION_BUS_ADDRESS; fi
unset CT_ORIG_LD_PRELOAD CT_ORIG_XDG_DATA_DIRS CT_ORIG_DBUS

case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) export PATH="$PREFIX/bin:$PATH" ;; esac
export SHELL="$PREFIX/bin/bash"
exec "$PREFIX/bin/bash" "$@"
