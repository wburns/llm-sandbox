#!/usr/bin/env bash
# deps/linux.sh - Linux dependency check, run by install.sh. Exits non-zero if
# a required dependency is missing. Fix hints use the distro's package manager.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# Package install command for the fix hints
if command -v dnf >/dev/null 2>&1; then
    PKG="sudo dnf install"
elif command -v apt-get >/dev/null 2>&1; then
    PKG="sudo apt-get install"
elif command -v pacman >/dev/null 2>&1; then
    PKG="sudo pacman -S"
elif command -v zypper >/dev/null 2>&1; then
    PKG="sudo zypper install"
else
    PKG="install"
fi

check_bash_4()  { check_bash "$PKG bash"; }
check_git()     { check_command "git" git required "$PKG git"; }
check_just()    { check_command "just" just required "$PKG just  (or: https://github.com/casey/just#installation)"; }
check_runtime() { check_container_runtime "$PKG podman" "https://docs.docker.com/engine/install/" "run 'podman info' to see why it fails"; }
check_systemd() {
    dep_label "systemd user session"
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        dep_ok "$(version_of systemctl --version)"
    else
        dep_warn "not available (optional, the startup service will be skipped)"
    fi
}
check_gh()      { check_command "gh" gh optional "$PKG gh" "its token is forwarded into containers"; }
check_fzf()     { check_command "fzf" fzf optional "$PKG fzf" "sandbox-attach picker"; }

run_checks "Linux" \
    check_bash_4 check_git check_just check_runtime check_systemd check_gh check_fzf
