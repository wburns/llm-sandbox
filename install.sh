#!/usr/bin/env bash
# install.sh - Install llm-sandbox for the current user.
#
#   - detects the OS and runs its dependency check (deps/darwin.sh or deps/linux.sh);
#     stops if a required dependency (bash 4+, git, just, podman or docker) is missing
#   - copies bin/, backend/, images/, share/, rules/, skills/ and the justfile to
#     $INSTALL_DIR. The launchers seed every sandbox session with the rules/ and
#     skills/ found there; the agent config directories below are layered on top.
#   - symlinks the commands into $BIN_DIR: review-pr, fix-issue, sandbox-attach and
#     common-sandbox always, and bob-sandbox, claude-sandbox, gemini-sandbox, codex-sandbox only for
#     agents whose config directory ($BOB_DIR, $CLAUDE_DIR, $GEMINI_DIR, $CODEX_DIR) exists
#   - unless --no-agent-config is given, also copies the shared rules/ and skills/
#     into the config directory of each agent ($BOB_DIR, $CLAUDE_DIR, $GEMINI_DIR, $CODEX_DIR)
#     that already exists, so host-side runs of those tools pick them up. Agents
#     without a config directory are skipped. Files with the same name are
#     overwritten, other files are left alone. claude-sandbox and gemini-sandbox
#     compile the rules into CLAUDE.md / GEMINI.md when they start.
#   - installs and enables a systemd *user* service that prunes sandbox caches
#     (via common-sandbox) and rebuilds the container images at login/startup
#
# Usage: ./install.sh [--uninstall] [--no-service] [--no-agent-config]
#
# Overridable environment variables:
#   INSTALL_DIR  default: ${XDG_DATA_HOME:-$HOME/.local/share}/llm-sandbox
#   BIN_DIR      default: $HOME/.local/bin
#   UNIT_DIR     default: ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
#   BOB_DIR      default: $HOME/.bob
#   CLAUDE_DIR   default: $HOME/.claude
#   GEMINI_DIR   default: $HOME/.gemini
#   CODEX_DIR    default: $HOME/.codex
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/llm-sandbox}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
UNIT_DIR="${UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
BOB_DIR="${BOB_DIR:-$HOME/.bob}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
GEMINI_DIR="${GEMINI_DIR:-$HOME/.gemini}"
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
SERVICE_NAME="llm-sandbox-update.service"

# command name -> script in bin/
LINKS=(
    "bob-sandbox:bob-sandbox"
    "claude-sandbox:claude-sandbox"
    "gemini-sandbox:gemini-sandbox"
    "codex-sandbox:codex-sandbox"
    "review-pr:review-pr"
    "fix-issue:fix-issue"
    "common-sandbox:common-sandbox.sh"
    "sandbox-attach:sandbox-attach"
    "sandbox-resume:sandbox-resume"
    "sandbox-session:sandbox-session"
)

# agent name:config directory. Existing ones receive the shared rules/ and skills/
AGENTS=(
    "bob:$BOB_DIR"
    "claude:$CLAUDE_DIR"
    "gemini:$GEMINI_DIR"
    "codex:$CODEX_DIR"
)

UNINSTALL=false
INSTALL_SERVICE=true
INSTALL_AGENT_CONFIG=true
for arg in "$@"; do
    case "$arg" in
        --uninstall)       UNINSTALL=true ;;
        --no-service)      INSTALL_SERVICE=false ;;
        --no-agent-config) INSTALL_AGENT_CONFIG=false ;;
        -h|--help)
            sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

have_systemd_user() {
    command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

# --- Output helpers (same layout as the dependency check in deps/common.sh) ---
if [ -t 1 ]; then BOLD=$'\033[1m' RESET=$'\033[0m'; else BOLD="" RESET=""; fi
OK="✅" SKIP="⏭️ " WARN="⚠️ " FAIL="❌"
STEP=0
STEPS=6

# section <title> - numbered section header, e.g. "━━ 2/6  AI agents ━━━━━━"
section() {
    STEP=$((STEP + 1))
    local rule
    rule="$(printf '%*s' $((46 - ${#1})) '' | tr ' ' '-' | sed 's/-/━/g')"
    printf '\n%s━━ %d/%d  %s %s%s\n' "$BOLD" "$STEP" "$STEPS" "$1" "$rule" "$RESET"
}

# item <status> <label> [detail] - "  label ....... status detail". The status
# comes after the dots so the columns line up whatever width the emoji renders at.
item() {
    local dots
    dots="$(printf '%*s' $((22 - ${#2})) '' | tr ' ' '.')"
    printf '  %s %s %s %s\n' "$2" "$dots" "$1" "${3:-}"
}

# tilde <path> - the path with $HOME shown as ~
tilde() {
    case "$1" in
        "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
        *)         printf '%s' "$1" ;;
    esac
}

uninstall() {
    echo "Uninstalling llm-sandbox..."
    if have_systemd_user; then
        systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
    fi
    rm -f "$UNIT_DIR/$SERVICE_NAME"
    have_systemd_user && systemctl --user daemon-reload || true

    local entry
    for entry in "${LINKS[@]}"; do
        local link="$BIN_DIR/${entry%%:*}"
        # Only remove symlinks that point into our install dir
        if [ -L "$link" ] && [[ "$(readlink "$link")" == "$INSTALL_DIR"/* ]]; then
            rm -f "$link"
        fi
    done
    rm -rf "$INSTALL_DIR"

    # Remove only the rules/skills that this repo provides
    local agent agent_dir item
    for agent in "${AGENTS[@]}"; do
        agent_dir="${agent#*:}"
        for item in "$REPO_DIR"/rules/*; do
            [ -e "$item" ] && rm -f "${agent_dir:?}/rules/$(basename "$item")"
        done
        for item in "$REPO_DIR"/skills/*; do
            [ -e "$item" ] && rm -rf "${agent_dir:?}/skills/$(basename "$item")"
        done
    done
    echo "Done."
}

install() {
    # Detect the OS, then run its dependency check (deps/<os>.sh), which prints
    # one line per dependency and fails if a required one is missing.
    local os os_name
    case "$(uname -s)" in
        Darwin) os=darwin os_name=macOS ;;
        Linux)  os=linux  os_name=Linux ;;
        *)
            echo "$FAIL Unsupported OS '$(uname -s)'; llm-sandbox supports Linux and macOS." >&2
            exit 1
            ;;
    esac
    printf '%s🧰 Installing llm-sandbox%s\n' "$BOLD" "$RESET"

    # --- 1. Dependencies ---
    section "Dependencies ($os_name)"
    if ! LLM_SANDBOX_INSTALLER=1 "$BASH" "$REPO_DIR/deps/$os.sh"; then
        exit 1
    fi

    # --- 2. Which agents are set up on this host (decides which launchers are
    # linked, where rules/skills go, and which images the justfile builds) ---
    section "AI agents"
    local agent agent_name agent_dir found_agents=()
    for agent in "${AGENTS[@]}"; do
        agent_name="${agent%%:*}" agent_dir="${agent#*:}"
        if [ -d "$agent_dir" ]; then
            item "$OK" "$agent_name" "found $(tilde "$agent_dir")"
            found_agents+=("$agent")
        else
            item "$SKIP" "$agent_name" "skipped (no $(tilde "$agent_dir"))"
        fi
    done
    if [ "${#found_agents[@]}" -eq 0 ]; then
        item "$WARN" "no agents" "create ~/.claude, ~/.gemini, ~/.codex or ~/.bob and re-run to get a launcher"
    fi

    # --- 3. Files ---
    section "Files"
    mkdir -p "$INSTALL_DIR" "$BIN_DIR"
    rm -rf "${INSTALL_DIR:?}/bin" "${INSTALL_DIR:?}/backend" "${INSTALL_DIR:?}/images" "${INSTALL_DIR:?}/share" \
           "${INSTALL_DIR:?}/rules" "${INSTALL_DIR:?}/skills"
    cp -R "$REPO_DIR/bin" "$REPO_DIR/backend" "$REPO_DIR/images" "$REPO_DIR/share" "$REPO_DIR/rules" "$REPO_DIR/skills" "$INSTALL_DIR/"
    cp "$REPO_DIR/justfile" "$INSTALL_DIR/justfile"
    chmod +x "$INSTALL_DIR"/bin/* "$INSTALL_DIR"/share/claude-setup "$INSTALL_DIR"/share/bob-prompt "$INSTALL_DIR"/share/logseq-tracker
    item "$OK" "installed to" "$(tilde "$INSTALL_DIR")"

    # --- 4. Commands. Agent launchers (<agent>-sandbox) are only linked for
    # agents found above; the shared commands always are. A launcher link left
    # by an earlier install for an agent that is no longer found is removed
    # (only if it is ours). ---
    section "Commands → $(tilde "$BIN_DIR")"
    local entry name link found launchers=()
    for entry in "${LINKS[@]}"; do
        name="${entry%%:*}" link="$BIN_DIR/${entry%%:*}"
        for agent in "${AGENTS[@]}"; do
            [ "$name" = "${agent%%:*}-sandbox" ] || continue
            found=false
            for found_agent in ${found_agents[@]+"${found_agents[@]}"}; do
                [ "$found_agent" = "$agent" ] && found=true
            done
            if [ "$found" = false ]; then
                item "$SKIP" "$name" "skipped (no $(tilde "${agent#*:}"))"
                if [ -L "$link" ] && [[ "$(readlink "$link")" == "$INSTALL_DIR"/* ]]; then
                    rm -f "$link"
                fi
                continue 2
            fi
            launchers+=("$name")
        done
        ln -sfn "$INSTALL_DIR/bin/${entry#*:}" "$link"
        item "$OK" "$name" "linked"
    done
    local path_ok=true
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) path_ok=false; item "$WARN" "PATH" "$(tilde "$BIN_DIR") is not in your PATH" ;;
    esac

    # --- 5. Optional: also put the rules and skills in the agents' own config
    # dirs (real copies, not symlinks) so host-side runs of the tools use them.
    # Only agents whose config dir already exists (found above) are touched. ---
    section "Agent rules & skills"
    if [ "$INSTALL_AGENT_CONFIG" = false ]; then
        item "$SKIP" "agent config dirs" "skipped (--no-agent-config); sandboxes use the copies in $(tilde "$INSTALL_DIR")"
    elif [ "${#found_agents[@]}" -eq 0 ]; then
        item "$SKIP" "agent config dirs" "none found; sandboxes use the copies in $(tilde "$INSTALL_DIR")"
    fi
    if [ "$INSTALL_AGENT_CONFIG" = true ]; then
        for agent in ${found_agents[@]+"${found_agents[@]}"}; do
            agent_dir="${agent#*:}"
            mkdir -p "$agent_dir/rules" "$agent_dir/skills"
            cp -R "$REPO_DIR/rules/." "$agent_dir/rules/"
            cp -R "$REPO_DIR/skills/." "$agent_dir/skills/"
            item "$OK" "${agent%%:*}" "copied to $(tilde "$agent_dir")/{rules,skills}"
        done
    fi

    # --- 6. Startup service (prunes caches and rebuilds images at login) ---
    section "Startup service"
    local service_enabled=false just_bin
    just_bin="$(command -v just || true)"
    if [ "$INSTALL_SERVICE" = false ]; then
        item "$SKIP" "systemd service" "skipped (--no-service)"
    elif [ -z "$just_bin" ]; then
        item "$WARN" "systemd service" "skipped ('just' not found; install it and re-run)"
    elif ! have_systemd_user; then
        item "$SKIP" "systemd service" "skipped (no systemd user session)"
    else
        mkdir -p "$UNIT_DIR"
        sed -e "s|@JUST@|$just_bin|g" \
            -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
            "$REPO_DIR/systemd/$SERVICE_NAME.in" > "$UNIT_DIR/$SERVICE_NAME"
        systemctl --user daemon-reload
        systemctl --user enable --quiet "$SERVICE_NAME"
        service_enabled=true
        item "$OK" "systemd service" "enabled ($(tilde "$UNIT_DIR/$SERVICE_NAME"))"
    fi

    # --- Summary ---
    printf '\n%s✨ llm-sandbox is installed.%s\n\nNext steps:\n' "$BOLD" "$RESET"
    local n=1
    if [ "$path_ok" = false ]; then
        local bin_for_shell="$BIN_DIR"  # $HOME, not ~, since ~ isn't expanded inside quotes
        case "$BIN_DIR" in "$HOME"/*) bin_for_shell="\$HOME/${BIN_DIR#"$HOME"/}" ;; esac
        echo "  $n. Add $(tilde "$BIN_DIR") to your PATH (e.g. in ~/.bash_profile):  export PATH=\"$bin_for_shell:\$PATH\""
        n=$((n + 1))
    fi
    if [ "$service_enabled" = true ]; then
        echo "  $n. Build the images:  systemctl --user start $SERVICE_NAME"
    else
        echo "  $n. Build the images:  just --justfile $(tilde "$INSTALL_DIR")/justfile update-agent-sandbox"
    fi
    n=$((n + 1))
    if [ "${#launchers[@]}" -gt 0 ]; then
        echo "  $n. From inside any git repository, run:  $(printf '%s / ' "${launchers[@]}" | sed 's| / $||')"
    fi
}

if [ "$UNINSTALL" = true ]; then
    uninstall
else
    install
fi
