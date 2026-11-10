# Directory containing this justfile (the installed llm-sandbox root)
root := justfile_directory()

# Absolute path of the running `just`, so recipes don't depend on PATH (the systemd service has a minimal one)
just := just_executable()

# Run startup maintenance: prune sandbox caches and rebuild all images
startup:
    {{root}}/bin/common-sandbox.sh --prune
    {{just}} --justfile {{root}}/justfile update-agent-sandbox

# Build and update the container images (with podman, else docker; see backend/selector.sh).
# An agent's image is only built when its config directory (~/.bob, ~/.claude, ~/.gemini, ~/.codex) exists.
update-agent-sandbox:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{root}}/backend/selector.sh"
    select_backend
    echo "📦 Container backend: $SANDBOX_BACKEND"
    backend_cli pull docker.io/library/fedora:latest
    backend_cli build -t agent-base-sandbox:latest -f "{{root}}/images/Dockerfile.agent-base" "{{root}}/images"
    for entry in "bob:${BOB_DIR:-$HOME/.bob}" "gemini:${GEMINI_DIR:-$HOME/.gemini}" "claude:${CLAUDE_DIR:-$HOME/.claude}" "codex:${CODEX_DIR:-$HOME/.codex}"; do
        agent="${entry%%:*}" dir="${entry#*:}"
        if [ -d "$dir" ]; then
            echo "✅ Found $dir — building $agent-dev-sandbox"
            backend_cli build -t "$agent-dev-sandbox:latest" -f "{{root}}/images/Dockerfile.$agent-base" "{{root}}/images"
        else
            echo "⏭️  No $dir found — skipping $agent-dev-sandbox"
        fi
    done
    backend_cli image prune -f
