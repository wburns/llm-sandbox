#!/usr/bin/env bash
# deps/darwin.sh - macOS dependency check, run by install.sh. Exits non-zero if
# a required dependency is missing. Fix hints assume Homebrew (https://brew.sh).
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

check_macos_version() {
    dep_label "macOS ≥ 12.3 (readlink -f)"
    local version
    version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    if readlink -f / >/dev/null 2>&1; then
        dep_ok "macOS $version"
    else
        dep_fail "macOS $version has no 'readlink -f'" "update macOS, or: brew install coreutils and put its gnubin first on PATH"
    fi
}
check_brew()   { check_command "Homebrew" brew optional "https://brew.sh" "the fix hints below use it"; }
check_bash_4() { check_bash "brew install bash (and put $(brew --prefix 2>/dev/null || echo /opt/homebrew)/bin before /bin on PATH)"; }
check_git()    { check_command "git" git required "xcode-select --install  (or: brew install git)"; }
check_just()   { check_command "just" just required "brew install just"; }
check_runtime() {
    check_container_runtime "brew install podman && podman machine init && podman machine start" \
        "Docker Desktop / Rancher Desktop / brew install colima docker" \
        "podman machine start"
}
check_gh()     { check_command "gh" gh optional "brew install gh" "its token is forwarded into containers"; }
check_fzf()    { check_command "fzf" fzf optional "brew install fzf" "sandbox-attach picker"; }

run_checks "macOS" \
    check_macos_version check_brew check_bash_4 check_git check_just check_runtime check_gh check_fzf
