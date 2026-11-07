#!/usr/bin/env bash
# backend/docker/backend.sh - Docker container backend (used when podman is not available).
# Sourced by backend/selector.sh; see there for the interface.
#
# The run options are the same as podman's. The one difference that matters is
# file ownership: rootful Docker on Linux runs the container as the real root,
# so files the agent writes to the worktree end up owned by root on the host.
# Docker Desktop / Rancher Desktop / colima on macOS and rootless Docker on
# Linux map them to your user, like rootless podman does.

backend_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

backend_cli() {
    docker "$@"
}

backend_preflight() {
    [ "$(uname -s)" = Linux ] || return 0
    if ! docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
        echo "⚠️ Docker is running rootful: files the agent writes to the worktree will be owned by root on the host."
        echo "   Use rootless Docker or podman to avoid this."
    fi
    return 0
}
