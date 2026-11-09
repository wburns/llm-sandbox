# llm-sandbox

Run LLM coding agents ([IBM Bob](https://bob.ibm.com), [Claude Code](https://claude.com/claude-code),
[Gemini CLI](https://github.com/google-gemini/gemini-cli)) in **ephemeral Podman (or Docker) containers**, each working in its
own throw-away **git worktree**. When the session ends you choose whether to merge the agent's commits back,
keep the branch, or discard everything.

> **These scripts are opinionated.** They reflect one developer's workflow, not a general-purpose framework.
> Read [Opinionated defaults](#opinionated-defaults) before installing, and fork/edit the Dockerfiles and
> launchers to suit your own setup.

## How it works

```
fedora:latest
   └── agent-base-sandbox   (JDK, Maven, Node, git, gh, podman, ripwire)
          ├── bob-dev-sandbox
          ├── claude-dev-sandbox
          └── gemini-dev-sandbox
```

- `bob-sandbox`, `claude-sandbox`, `gemini-sandbox` – launchers. Each creates a worktree of the current git
  repository on a temporary branch, starts the matching container, and on exit offers to merge the result.
- `review-pr <pr-number> <bob|gemini|claude>` – checks out a GitHub PR with `gh` and starts the chosen launcher
  with a prompt to review the branch.
- `fix-issue <issue-number> <bob|gemini|claude>` – reads the GitHub issue title with `gh`, creates and checks out a
  branch named `<issue-number>_<short_words_from_title>`, and starts the chosen launcher with a prompt to fix the
  issue using the `fix-github` skill.
- `sandbox-attach [<session-branch> | -b <branch>] [command...]` – opens a shell (or runs a command) in `/workspace`
  of a running sandbox container. With a session branch it joins that sandbox; with `-b` it finds the sandboxes that
  were started from `<branch>` (e.g. a PR or issue branch) and joins the only match, or lets you pick with `fzf`
  (numbered menu if `fzf` is missing) when there are several. With no arguments (or without a branch), it matches all
  running sandboxes and attaches directly if there is only one, or opens the interactive picker if there are several.
  Containers are labelled `llm-sandbox.branch` (session branch) and `llm-sandbox.base-branch` at launch.
- `sandbox-resume [-a | --all] [-b <branch>] [<session-id>] [command...]` – resumes a previously closed session with a
  fresh on-demand worktree and mounts the preserved session history (`/root`). When invoked without a session ID, it
  opens an interactive `fzf` picker sorted by last operated date (most recent first) with session details and activity
  in the preview window.
- `sandbox-session pack [-a] [-f] [-o <file.zip>] [<session-id>]` / `sandbox-session unpack [-f] <file.zip>` – moves a
  session to another machine. `pack` picks a session the same way `sandbox-resume` does (`fzf` picker or session ID/prefix)
  and zips **only its conversation history** (bob's `bob.db`, claude's `projects/` and `history.jsonl`, gemini's `tmp/` chats),
  plus `.session-info` and the Logseq run logs. Settings, login files, caches and shell history are never included.
  Copy the zip over and run `unpack`: it restores the history and re-seeds rules, skills and settings from the local machine,
  as a fresh launch would. Then run `sandbox-resume` from inside your checkout of the same repository (the agent logs in
  with the local credentials). The history can still contain secrets the agent saw, so keep the archive private.
- `common-sandbox` – shared engine (worktrees, container flags, cleanup). The launchers source it; it can also be
  run directly for maintenance: `common-sandbox --prune` or `common-sandbox --clean`.
- A systemd **user** service runs at startup, calls `common-sandbox --prune` and rebuilds all images via `just`.

## Repository layout

```
bin/        launcher scripts and common-sandbox.sh
backend/    container runtime selection (selector.sh) and one backend per runtime (podman/, docker/)
deps/       per-OS dependency checks run by install.sh (darwin.sh, linux.sh, shared helpers in common.sh)
images/     Dockerfiles for the base image and each agent image
rules/      default agent rules, installed for each agent found on the host
skills/     default agent skills, installed for each agent found on the host
share/      helper files mounted into containers (claude-setup, bob-prompt, logseq-tracker)
systemd/    service unit template
justfile    image build / startup recipes
install.sh  installer
```

## Requirements

- Linux or macOS (12.3 or later, for `readlink -f`) with `git` and bash 4 or later.
- A container runtime: `podman` (preferred) or `docker`. The first one that is installed **and running** is used;
  set `LLM_SANDBOX_BACKEND=podman` or `=docker` to force one. Rootful Docker on Linux leaves files the agent writes
  owned by root, so use rootless Docker or podman there.
- The containers themselves are Fedora-based, whatever your host OS, and the images build for x86_64 or aarch64.
- [`just`](https://github.com/casey/just) to build the images, and systemd for the automatic image update service
  (Linux only; on macOS run the `just` recipe by hand)
- `gh` (optional, its token is forwarded into containers) and `fzf` (optional, for `sandbox-attach`'s picker)

On macOS with Homebrew:

```bash
brew install bash just          # macOS ships bash 3.2; the scripts need 4+ (first on PATH)
brew install podman && podman machine init && podman machine start
#   ...or use Docker Desktop, Rancher Desktop or colima instead of podman
brew install gh fzf             # optional
```

On macOS the runtime runs in a VM: the SELinux `:z`/`:Z` mount flags are dropped there, and `--network host` is the
VM's network, not the Mac's.

## Install

```bash
./install.sh              # install files, symlinks and the systemd user service
./install.sh --no-service # skip the systemd service
./install.sh --no-agent-config # don't copy rules/skills into ~/.bob, ~/.claude, ~/.gemini
./install.sh --uninstall  # remove everything the installer created
```

The installer first detects the OS and runs its dependency check ([`deps/darwin.sh`](deps/darwin.sh) or
[`deps/linux.sh`](deps/linux.sh)), which prints one line per dependency with its version or a hint for installing
it. If a required one (bash 4+, git, just, podman or docker) is missing it stops before writing anything; optional
ones (gh, fzf, a running container runtime, systemd on Linux) only produce a warning.

By default:

- files are copied to `~/.local/share/llm-sandbox`
- commands are symlinked into `~/.local/bin`: `review-pr`, `fix-issue`, `sandbox-attach` and `common-sandbox`
  always, and `bob-sandbox` / `claude-sandbox` / `gemini-sandbox` only for agents whose config directory exists
  (a link from an earlier install for an agent that is no longer found is removed)
- `rules/` and `skills/` are copied into whichever of `~/.bob`, `~/.claude` and `~/.gemini` already exist (under
  `rules/` and `skills/`); the installer lists which agents it found and skips the rest
- the unit is written to `~/.config/systemd/user/llm-sandbox-update.service`

Override with `INSTALL_DIR`, `BIN_DIR`, `UNIT_DIR`, `BOB_DIR`, `CLAUDE_DIR` and `GEMINI_DIR`.

Build the images for the first time (or trigger an update at any time):

```bash
systemctl --user start llm-sandbox-update.service
# or
just --justfile ~/.local/share/llm-sandbox/justfile update-agent-sandbox
```

To start the service even when you are not logged in, run `loginctl enable-linger $USER`.

## Usage

Run from inside any git repository:

```bash
bob-sandbox
claude-sandbox
gemini-sandbox
```

Maintenance (same flags on every launcher and on `common-sandbox`):

```bash
common-sandbox --prune   # delete cache files older than 14 days
common-sandbox --clean   # wipe all sandbox state and worktrees
```

## Opinionated defaults

- **Ripwire is installed in every image.** The base image downloads
  [ripwire](https://github.com/redhat-et/ripwire) (pinned to v0.6.9) into `/usr/local/bin`, and the default
  rule `rules/ripwire.md` tells the agent to use it for code exploration. If you don't want it, remove the
  install step from `images/Dockerfile.agent-base` and delete `rules/ripwire.md` before installing.
- **Default rules and skills are installed for every agent found on the host** (see below).
- **Agents run with their safety prompts off**: Claude is started with `--dangerously-skip-permissions` and
  Gemini with `--approval-mode=yolo`. The container and throw-away worktree are the safety boundary.
- **Containers use host networking** (`--network host`), run as root, and receive your `gh` token as `GH_TOKEN`
  when `gh auth token` works. Your host `~/.config/gh` is not mounted or copied, so `gh` settings such as aliases
  are not available in the container.
- **The toolchain is Java-centric**: Fedora base image with the latest OpenJDK, Maven, Node.js/npm, git, gh and
  podman, plus a Maven cache shared between sessions.
- **Uncommitted work is auto-committed** in the worktree when a session ends, before you are asked whether to
  merge, keep or discard the branch.
- **Images are rebuilt at every startup** by the systemd user service, which also installs the latest Bob,
  Claude Code and Gemini CLI at that time.

### Default rules and skills

Provided in [`rules/`](rules/) and [`skills/`](skills/). `install.sh` copies them to the install directory, and
every sandbox session is seeded from there; the agent's own config directory (e.g. `~/.claude`) is layered on top,
so a same-named file there wins. Unless you pass `--no-agent-config`, `install.sh` also copies them into each
agent's config directory so host-side runs of the tools use them:

| Path | Purpose |
|---|---|
| `rules/ripwire.md` | Tells the agent to explore code with `ripwire` instead of reading whole files |
| `rules/coding.md` | Coding guidelines |
| `skills/code-review/` | Review a branch/PR against repo coding standards and the originating spec |
| `skills/grill-me/` | Stress-test a plan or decision by questioning the user |
| `skills/fix-github/` | Fix a GitHub issue, logging the run in Logseq format |
| `skills/review-fix/` | Review the branch's changes and fix what is found, logging each finding and fix |
| `skills/review-only/` | Review the branch's changes without editing; prints the findings as a Logseq log |
| `skills/request-change/` | Log a wanted code change as a Logseq `TODO`, then ask whether to implement it now or leave it logged |

The last four use `logseq-tracker` ([`share/logseq-tracker`](share/logseq-tracker)), which every container gets
at `/usr/local/bin/logseq-tracker`. Each session writes its logs to its own directory,
`~/.local/share/llm-sandbox-logs/<agent>_<session>` on the host (override the base with `LOGSEQ_LOG_DIR`; it is
outside `BASE_SANDBOX_DIR`, so `--clean`/`--prune` keep it). When the container ends, the exit trap appends each
`run_*.md` log to the Logseq journal of the day the run started, `$LOGSEQ_GRAPH_DIR/journals/YYYY_MM_DD.md`
(default graph `~/Documents/Logseq`; created if missing). A log whose `id::` is already in the journal is skipped, so
nothing is duplicated. If the graph directory doesn't exist the logs are just kept in the session directory.

### What the containers see

Each session gets its own home directory (`$BASE_SANDBOX_DIR/sessions/<agent>_<id>`) mounted as `/root`. The host's
agent directories (`~/.bob`, `~/.claude`, `~/.gemini`) are **never mounted**. Instead, the launcher copies a small
allow-list of files into the session home before the container starts, and the agent works on those copies. History,
logs, caches and any other changes the agent makes stay in the session home, so concurrent sessions never share a
live file and nothing can modify your host config directly.

| Agent | Authentication | Copied in (discarded on exit) | Generated per session |
|---|---|---|---|
| Bob | Login saved in `~/.bob/settings/auth-secrets.json` (created or updated on exit, **synced back**) | `~/.bob/{rules,skills}`, `~/.bob/settings/settings.json` | – |
| Claude | Vertex AI via gcloud (cache in `$BASE_SANDBOX_DIR/shared_gcloud`), else `ANTHROPIC_*` environment variables (see below) | `~/.claude/{settings.json,skills,CLAUDE.md}`, `~/.claude.json` | `~/.claude/CLAUDE.md` from `rules/` |
| Gemini | `GEMINI_API_KEY` environment variable | `~/.gemini/{settings.json,.env,skills,policies,GEMINI.md}` | `~/.gemini/GEMINI.md` from `rules/` |

Files that don't exist on the host are skipped.

#### Authentication

An agent's image is built when its config directory (`~/.bob`, `~/.claude`, `~/.gemini`, or `BOB_DIR` /
`CLAUDE_DIR` / `GEMINI_DIR`) exists, whatever credentials you have: the `just` recipe and the startup service never
check `CLAUDE_VERTEX_PROJECT_ID`, `ANTHROPIC_*`, `GEMINI_API_KEY` or `auth-secrets.json`. These only matter when you
launch an agent.

Only these authentication setups are supported out of the box. Other modes (Claude or Gemini OAuth/browser
logins, other Bob auth methods, ...) are not wired up; adapt the launchers if you use them.

- **Bob:** `auth-secrets.json` is copied into the session if it exists, and `bob-sandbox` starts either way. If it
  doesn't exist yet, log in at Bob's prompt. When the session ends, the exit trap (`_sync_auth_back` in
  `bin/common-sandbox.sh`) writes the file back to the host if Bob created or changed it (a first login or a token
  refresh), creating `~/.bob/settings` if needed. Unchanged files are left alone. The write is atomic and keeps the
  file's permissions (new files get `600`) and symlinks. If the host copy also changed during the session (another
  sandbox refreshed it), the newer file wins and a warning is printed when the host's is kept. Syncing runs on a
  normal exit, Ctrl-C and `SIGTERM`, but not if the launcher is killed with `SIGKILL`, in which case that
  session's login is lost.
- **Claude:** `claude-sandbox` picks the first of these that is set on the host:
  1. `CLAUDE_VERTEX_PROJECT_ID`: Vertex AI with gcloud Application Default Credentials (ADC) (see
     [Setting the Vertex project](#setting-the-vertex-project)). The credentials live in
     `$BASE_SANDBOX_DIR/shared_gcloud` (mounted read-write, **not** your host's `~/.config/gcloud`), so you only log
     in once across all sandboxes. `ANTHROPIC_*` variables are not forwarded in this mode. `common-sandbox --clean`
     deletes the gcloud cache, and `--prune` deletes files in it that haven't been accessed for 14 days.
  2. `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN`: the Anthropic API, or an LLM gateway when `ANTHROPIC_BASE_URL`
     is set. Every `ANTHROPIC_*` variable exported on the host (key or token, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`,
     `ANTHROPIC_DEFAULT_*_MODEL`, ...) is forwarded into the container by name, and the launcher prints which ones.
     With `ANTHROPIC_API_KEY`, Claude Code asks once whether to use the key unless your host `~/.claude.json`
     already approved it; that answer is not kept after the session.

  With neither set, Claude starts and asks you to log in, but that login is discarded with the session.
- **Gemini:** export `GEMINI_API_KEY` on the host; it is forwarded into every container. If it is unset, nothing is
  forwarded and `gemini-sandbox` still starts without a warning, so Gemini will have no API key. Nothing else needs
  to persist. `settings.json` (which selects the API-key login method) is copied in, but changes made to it inside
  a sandbox are discarded.

##### Setting the Vertex project

```bash
export CLAUDE_VERTEX_PROJECT_ID=my-gcp-project   # add to ~/.bashrc / ~/.zshrc to make it permanent
claude-sandbox
```

`claude-sandbox` forwards the variable into the container, where it *sources* [`share/claude-setup`](share/claude-setup)
with that project ID before starting Claude. The script is only about gcloud and Vertex AI (about 60 lines). It:

- exports `CLAUDE_CODE_USE_VERTEX=1`, `CLOUD_ML_REGION=global` and `ANTHROPIC_VERTEX_PROJECT_ID=<project>` for that
  session only. It does not write shell rc files or any env file;
- reuses the cached ADC login if it is still valid. Otherwise it runs
  `gcloud auth application-default login --no-launch-browser`, which prints a URL to open in your host browser and
  asks for the verification code;
- sets the ADC quota project to the same project ID.

If the login or the quota project can't be set up (for example you lack access to the project), the script prints the
error and `claude-sandbox` exits instead of starting Claude. If `CLAUDE_VERTEX_PROJECT_ID` is unset, `claude-setup`
is skipped: Claude uses the `ANTHROPIC_*` variables (see above) or whatever your copied `~/.claude/settings.json`
provides, and no gcloud login is attempted. That file may already contain the `CLAUDE_CODE_USE_VERTEX` /
`ANTHROPIC_VERTEX_PROJECT_ID` environment values, but it does not create the gcloud login. If your `settings.json`
sets a different project than `CLAUDE_VERTEX_PROJECT_ID`, keep the two consistent.

> **Don't set the Vertex variables in the `env` block of `~/.claude/settings.json`** (`CLAUDE_CODE_USE_VERTEX`,
> `CLOUD_ML_REGION`, `ANTHROPIC_VERTEX_PROJECT_ID`). Claude Code applies that block over the environment variables
> exported by `claude-setup`, so a stale value there silently wins. For example `"CLAUDE_CODE_USE_VERTEX": "0"` keeps
> Vertex AI disabled even though `claude-setup` exported `1`. Remove those keys and let `CLAUDE_VERTEX_PROJECT_ID`
> drive them. Edits made to `settings.json` inside a sandbox are discarded on exit, so fix the host file.

To persist another file a tool writes at login, copy it in with `seed_auth_from_host` instead of `seed_from_host`
in the matching launcher; it is then synced back on exit (and may be absent on the host the first time).

Still shared with the host (bind-mounted read-write): the shared Maven cache (`~/.m2/repository`, all three) and
Claude's gcloud cache described above.

Claude and Gemini have no rules directory of their own, only a single context file. So `claude-sandbox` and
`gemini-sandbox` concatenate every `*.md` and `*.txt` file in the host's `~/.claude/rules` / `~/.gemini/rules`
into `CLAUDE.md` / `GEMINI.md` inside the session home on each launch (see `compile_rules`). The host's own
`CLAUDE.md` / `GEMINI.md` is never modified; the copy is kept as-is when there are no rule files. Skills are plain
`SKILL.md` directories that rely on each tool's own skill discovery; the launchers do not process them.

Notes:

- By default `install.sh` also writes to the host: it copies `rules/` and `skills/` into whichever of `~/.bob`,
  `~/.claude` and `~/.gemini` exist, so host-side runs of those tools pick them up too. Use `--no-agent-config` to leave those directories
  alone; sandboxes still get the rules and skills from the install directory. The launchers never write to those
  directories.
- Re-running `install.sh` overwrites files with the same name; other files you keep in those directories are
  left alone. `--uninstall` removes only the rules and skills that this repo provides.
- If you prefer to maintain a single rules directory yourself, you can replace `~/.claude/rules` or
  `~/.gemini/rules` with a symlink to it (e.g. `ln -s ~/.bob/rules ~/.claude/rules`). Compilation happens on the
  host before the container starts and symlinks are followed when copying, so this works. The installer will then
  write into the symlink target.
- The default skills were written for Bob; `code-review`, for example, expects to spawn parallel sub-agents, which
  other tools may support differently.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `BASE_SANDBOX_DIR` | `~/.local/share/llm_sandbox_homes` | Session homes, worktrees, shared Maven/gcloud caches |
| `GEMINI_API_KEY` | – | Gemini authentication; forwarded to the Gemini container |
| `CLAUDE_VERTEX_PROJECT_ID` | – | Claude authentication: Google Cloud project ID for Vertex AI. See [Setting the Vertex project](#setting-the-vertex-project) |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` | – | Claude authentication when `CLAUDE_VERTEX_PROJECT_ID` is unset; all `ANTHROPIC_*` variables are forwarded |
| `LLM_SANDBOX_BACKEND` | auto | Force the container runtime: `podman` or `docker` (default: podman if running, else docker) |

Bob needs no environment variable: log in at its prompt on first run and `~/.bob/settings/auth-secrets.json` is
saved on exit. See [What the containers see](#what-the-containers-see) for everything else that is read from the host.
