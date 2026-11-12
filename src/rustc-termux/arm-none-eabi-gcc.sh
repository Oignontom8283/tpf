#!/data/data/com.termux/files/usr/bin/bash
# GNU-style name for bare-metal ARM, provided by Termux's clang (written by install-fake-rustup-termux.sh).
exec clang --target=arm-none-eabi "$@"
