#!/usr/bin/env bash
# backend/podman/backend.sh - Podman container backend (the default).
# Sourced by backend/selector.sh; see there for the interface.
#
# Rootless podman maps root in the container to your user on the host, so files
# the agent writes to the worktree and session home are owned by you.

backend_available() {
    command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1
}

backend_cli() {
    podman "$@"
}

backend_preflight() {
    return 0
}
