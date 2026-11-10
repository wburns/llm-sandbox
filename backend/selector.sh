#!/usr/bin/env bash
# backend/selector.sh - pick the container runtime the sandboxes run on.
#
# Sourced by common-sandbox.sh, the llm-sandbox command and the justfile. Each runtime
# lives in backend/<name>/backend.sh and defines:
#   backend_available   true if the runtime is installed and its service answers
#   backend_cli ARGS... run the runtime's CLI (run, ps, exec, build, pull, ...)
#   backend_preflight   runtime-specific checks/warnings before `run`
#
# select_backend tries podman, then docker, and keeps the first one that works.
# Set LLM_SANDBOX_BACKEND=podman or =docker to force one.

_BACKEND_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# select_backend
# Sources the chosen backend and sets SANDBOX_BACKEND to its name. Does nothing
# if a backend was already selected. Returns non-zero (with a message) if none works.
select_backend() {
    [ -n "${SANDBOX_BACKEND:-}" ] && return 0
    local candidates=(podman docker) name
    [ -n "${LLM_SANDBOX_BACKEND:-}" ] && candidates=("$LLM_SANDBOX_BACKEND")

    for name in "${candidates[@]}"; do
        if [ ! -f "$_BACKEND_DIR/$name/backend.sh" ]; then
            echo "ERROR: unknown container backend '$name' (LLM_SANDBOX_BACKEND must be podman or docker)." >&2
            return 1
        fi
        # shellcheck source=/dev/null
        source "$_BACKEND_DIR/$name/backend.sh"
        if backend_available; then
            SANDBOX_BACKEND="$name"
            return 0
        fi
    done

    if [ -n "${LLM_SANDBOX_BACKEND:-}" ]; then
        echo "ERROR: $LLM_SANDBOX_BACKEND (from LLM_SANDBOX_BACKEND) is not installed or not running." >&2
    else
        echo "ERROR: no working container backend. Install podman or docker and make sure it is running" >&2
        echo "       (on macOS: 'podman machine start', or start Docker Desktop / Rancher Desktop / colima)." >&2
    fi
    return 1
}

# adapt_run_options <run option>...
# Copies the options into ADAPTED_RUN_OPTIONS, adjusted for this host. The
# launchers write volume mounts with SELinux relabel flags (:z / :Z), which
# Linux needs. On macOS the runtime lives in a VM and host files arrive over a
# shared filesystem, where relabeling does nothing or fails, so the flags are
# dropped there ("-v a:b:ro,z" -> "-v a:b:ro", "-v a:b:Z" -> "-v a:b").
adapt_run_options() {
    ADAPTED_RUN_OPTIONS=()
    local strip=false prev="" arg
    [ "$(uname -s)" = Darwin ] && strip=true
    for arg in "$@"; do
        if [ "$strip" = true ] && { [ "$prev" = -v ] || [ "$prev" = --volume ]; }; then
            arg="$(_strip_selinux_flags "$arg")"
        fi
        ADAPTED_RUN_OPTIONS+=("$arg")
        prev="$arg"
    done
}

# _strip_selinux_flags <src:dst[:opts]> - prints the spec without z / Z in opts
_strip_selinux_flags() {
    local spec="$1" opts rest opt kept=()
    case "$spec" in
        *:*:*) ;;
        *) printf '%s\n' "$spec"; return 0 ;;
    esac
    opts="${spec##*:}"
    rest="${spec%:*}"
    local IFS=,
    for opt in $opts; do
        case "$opt" in
            z|Z) ;;
            *) kept+=("$opt") ;;
        esac
    done
    if [ "${#kept[@]}" -eq 0 ]; then
        printf '%s\n' "$rest"
    else
        printf '%s\n' "$rest:${kept[*]}"
    fi
}
