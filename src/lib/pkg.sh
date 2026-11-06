# Termux package helpers (apt).
#
# Commands: pkg_update  pkg_install PKG...  apt_install LOGNAME PKG...
#           apt_repair  dpkg_installed PKG
# Variable: APT_OPTS (non-interactive options for apt-get)
# tpf:include core

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Finish interrupted installs and fix broken dependencies.
apt_repair() {
    dpkg --configure -a >/dev/null 2>&1 || true
    apt-get "${APT_OPTS[@]}" -f install >/dev/null 2>&1 || true
}

# Install packages; if that fails, repair apt once and try again.
_apt_install_run() {
    apt-get "${APT_OPTS[@]}" install "$@" && return 0
    apt_repair
    apt-get "${APT_OPTS[@]}" install "$@"
}

# apt_install LOGNAME PKG...   quiet: the output goes to $TPF_LOG_DIR/LOGNAME.log
apt_install() {
    local name="$1"
    shift
    _apt_install_run "$@" >"${TPF_LOG_DIR:-${TMPDIR:-/tmp}}/$name.log" 2>&1
}

# pkg_install PKG...   shows a running marker, then [ OK ] or [ERROR]
pkg_install() { task "Installing $*" _apt_install_run "$@"; }

pkg_update() { task "Updating the package lists" apt-get "${APT_OPTS[@]}" update; }

dpkg_installed() {
    [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ]
}
