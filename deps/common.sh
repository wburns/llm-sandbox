#!/usr/bin/env bash
# deps/common.sh - helpers for the dependency checks that install.sh runs
# (deps/darwin.sh, deps/linux.sh). Sourced, not run.
#
# A check is a function that calls dep_ok, dep_warn or dep_fail exactly once.
# run_checks runs a list of them, numbering each line [n/total], and returns
# non-zero if any required dependency failed.
#
# Keep this bash 3.2 compatible (no associative arrays, mapfile, ${x,,}, ...):
# it has to run on stock macOS bash to report that bash itself is too old.

_DEP_N=0
_DEP_TOTAL=0
_DEP_FAILED=0
_DEP_WARNED=0
_DEP_LABEL=""

# dep_label <text> - names the line the current check reports on
dep_label() {
    _DEP_LABEL="$1"
}

_dep_line() {
    local status="$1" detail="$2" dots
    dots="$(printf '%*s' $((30 - ${#_DEP_LABEL})) '' | tr ' ' '.')"
    printf '  [%d/%d] %s %s %s %s\n' "$_DEP_N" "$_DEP_TOTAL" "$_DEP_LABEL" "$dots" "$status" "$detail"
}

# dep_ok <detail>                 - present and usable
# dep_warn <detail> [fix hint]    - optional dependency missing, or a problem that doesn't block install
# dep_fail <detail> [fix hint]    - required dependency missing; install.sh stops
dep_ok() {
    _dep_line "✅" "$1"
}
dep_warn() {
    _DEP_WARNED=$((_DEP_WARNED + 1))
    _dep_line "⚠️ " "$1${2:+ → $2}"
}
dep_fail() {
    _DEP_FAILED=$((_DEP_FAILED + 1))
    _dep_line "❌" "$1${2:+ → $2}"
}

# version_of <command> [args...] - first x.y[.z] in the command's output (empty if none)
version_of() {
    "$@" 2>&1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1 || true
}

# check_command <label> <command> <required|optional> <fix hint> [why it is needed]
check_command() {
    dep_label "$1"
    local cmd="$2" need="$3" hint="$4" why="${5:-}" version
    if command -v "$cmd" >/dev/null 2>&1; then
        version="$(version_of "$cmd" --version)"
        dep_ok "${version:-found}"
    elif [ "$need" = required ]; then
        dep_fail "not found" "$hint"
    else
        dep_warn "not found (optional${why:+, $why})" "$hint"
    fi
}

# check_bash <fix hint> - the launchers run `#!/usr/bin/env bash` and need bash 4+
check_bash() {
    dep_label "bash ≥ 4 (first on PATH)"
    local path version major
    path="$(command -v bash || true)"
    if [ -z "$path" ]; then
        dep_fail "not found" "$1"
        return
    fi
    version="$(bash -c 'echo "$BASH_VERSION"' 2>/dev/null)"
    major="${version%%.*}"
    if [ -n "$major" ] && [ "$major" -ge 4 ] 2>/dev/null; then
        dep_ok "${version%%(*} ($path)"
    else
        dep_fail "${version%%(*} at $path is too old" "$1"
    fi
}

# check_container_runtime <podman install hint> <docker install hint> <podman start hint>
# Required: podman or docker installed. Not running is only a warning, since
# installing doesn't need it (launching and building images do).
check_container_runtime() {
    dep_label "container runtime"
    local rt found=""
    for rt in podman docker; do
        command -v "$rt" >/dev/null 2>&1 || continue
        found="$rt"
        if "$rt" info >/dev/null 2>&1; then
            dep_ok "$rt $(version_of "$rt" --version) (running)"
            return
        fi
    done
    case "$found" in
        "")     dep_fail "neither podman nor docker found" "$1 (or: $2)" ;;
        podman) dep_warn "podman $(version_of podman --version) installed but not running" "$3" ;;
        docker) dep_warn "docker $(version_of docker --version) installed but not running" "start your Docker service" ;;
    esac
}

# run_checks <os name> <check function>... - runs the checks and prints a summary
run_checks() {
    local os="$1" check
    shift
    _DEP_TOTAL=$#
    # install.sh prints its own section header instead
    [ -n "${LLM_SANDBOX_INSTALLER:-}" ] || echo "🔍 Checking dependencies for $os..."
    for check in "$@"; do
        _DEP_N=$((_DEP_N + 1))
        "$check"
    done

    if [ "$_DEP_FAILED" -gt 0 ]; then
        echo "" >&2
        echo "  ❌ $_DEP_FAILED required dependenc$([ "$_DEP_FAILED" -eq 1 ] && echo y || echo ies) missing. Install and re-run ./install.sh." >&2
        return 1
    fi
    echo ""
    if [ "$_DEP_WARNED" -gt 0 ]; then
        echo "  ✅ All required dependencies found ($_DEP_WARNED warning(s) above)."
    else
        echo "  ✅ All dependencies found."
    fi
}
