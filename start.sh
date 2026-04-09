#!/usr/bin/env bash
# start.sh — Claude Code sandbox launcher
# Supports: Linux (native), WSL2, Windows (Docker Desktop). macOS untested.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Load .env ─────────────────────────────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/.env"
  set +a
else
  echo "ERROR: .env file not found. Copy env.example to .env and fill in your values." >&2
  exit 1
fi

# ── Validate authentication ───────────────────────────────────────────────────
# Either ANTHROPIC_API_KEY (API mode) or a credentials file (subscription mode)
CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"
if [[ -n "${SUDO_USER:-}" ]]; then
  CREDENTIALS_FILE="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.claude/.credentials.json"
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" && ! -f "$CREDENTIALS_FILE" ]]; then
  echo "ERROR: No authentication configured." >&2
  echo "       Either set ANTHROPIC_API_KEY in .env (API mode)" >&2
  echo "       or run 'claude' on the host to log in (subscription mode)." >&2
  echo "       See SUBSCRIPTION_MODE.md for details." >&2
  exit 1
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "Auth: subscription mode (credentials from ~/.claude)"
else
  echo "Auth: API key mode"
fi

# ── Platform detection ────────────────────────────────────────────────────────
detect_platform() {
  local kernel
  kernel=$(uname -r 2>/dev/null || echo "unknown")
  local os
  os=$(uname -s 2>/dev/null || echo "unknown")

  if echo "$kernel" | grep -qi "microsoft"; then
    echo "wsl2"
  elif [[ "$os" == "Linux" ]]; then
    echo "linux"
  elif [[ "$os" == "Darwin" ]]; then
    echo "macos"
  else
    echo "windows"
  fi
}

PLATFORM=$(detect_platform)

case "$PLATFORM" in
  linux|wsl2)
    COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.linux.yml)
    USE_IPTABLES=true
    ;;
  macos|windows)
    COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.windows.yml)
    USE_IPTABLES=false
    ;;
esac

# ── Resolve real user's home (survives sudo) ─────────────────────────────────
if [[ -n "${SUDO_USER:-}" ]]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  REAL_HOME="$HOME"
fi

# ── Per-project container naming ──────────────────────────────────────────────
# Derive a unique project name from the first RW mount so that different
# project directories get separate containers, networks, and iptables rules.
derive_project_name() {
  if [[ -n "${AGENT_MOUNTS_RW:-}" ]]; then
    local first_mount
    first_mount="${AGENT_MOUNTS_RW%%:*}"
    # Expand tilde
    first_mount="${first_mount/#\~/$REAL_HOME}"
    # Resolve to absolute path
    first_mount="$(cd "$first_mount" 2>/dev/null && pwd || echo "$first_mount")"
    local name
    name=$(basename "$first_mount")
    # Sanitise for docker compose: lowercase, alphanumeric and hyphens only
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')
    echo "claude-${name}"
  else
    echo "claude-sandbox"
  fi
}

export COMPOSE_PROJECT_NAME=$(derive_project_name)

# ── Mount validation ──────────────────────────────────────────────────────────
expand_path() {
  local p="$1"
  # Expand tilde to the real user's home, not root's
  p="${p/#\~/$REAL_HOME}"
  # Resolve to absolute path
  echo "$(cd "$p" 2>/dev/null && pwd || echo "$p")"
}

is_home_or_root() {
  local p="$1"
  local home_resolved
  home_resolved=$(expand_path "$REAL_HOME")
  [[ "$p" == "/" ]] && return 0
  [[ "$p" == "$home_resolved" ]] && return 0
  # Block known dangerous top-level system paths
  local dangerous_roots=("/etc" "/usr" "/bin" "/sbin" "/lib" "/lib64" "/lib32"
    "/boot" "/sys" "/proc" "/dev" "/root" "/var" "/home" "/run" "/opt" "/snap")
  for root in "${dangerous_roots[@]}"; do
    [[ "$p" == "$root" ]] && return 0
  done
  return 1
}

is_parent_of_another() {
  local candidate="$1"
  shift
  local all_mounts=("$@")
  for other in "${all_mounts[@]}"; do
    [[ "$candidate" == "$other" ]] && continue
    if [[ "$other" == "$candidate/"* ]]; then
      return 0
    fi
  done
  return 1
}

validate_mounts() {
  local all_paths=()

  # Collect all mount paths
  if [[ -n "${AGENT_MOUNTS_RW:-}" ]]; then
    IFS=':' read -ra RW_PATHS <<< "$AGENT_MOUNTS_RW"
    for p in "${RW_PATHS[@]}"; do
      [[ -z "$p" ]] && continue
      all_paths+=("$(expand_path "$p")")
    done
  fi

  if [[ -n "${AGENT_MOUNTS_RO:-}" ]]; then
    IFS=':' read -ra RO_PATHS <<< "$AGENT_MOUNTS_RO"
    for p in "${RO_PATHS[@]}"; do
      [[ -z "$p" ]] && continue
      all_paths+=("$(expand_path "$p")")
    done
  fi

  for p in "${all_paths[@]}"; do
    if is_home_or_root "$p"; then
      echo "ERROR: Refusing to mount dangerous path: $p" >&2
      echo "       Do not mount home directories or filesystem roots." >&2
      exit 1
    fi
    if is_parent_of_another "$p" "${all_paths[@]}"; then
      echo "ERROR: Mount path $p is a parent of another listed mount." >&2
      echo "       This would create overlapping mounts. Please be more specific." >&2
      exit 1
    fi
  done
}

# ── Generate dynamic volume override ──────────────────────────────────────────
MOUNTS_OVERRIDE="$SCRIPT_DIR/.docker-compose.mounts.yml"

# ── Ensure persistent .claude directory exists on the host ───────────────────
# This directory is bind-mounted over /home/agent/.claude inside the container
# so that memory, settings, and (in subscription mode) credentials survive
# container restarts.  The tmpfs on /home/agent remains for everything else.
ensure_claude_dir() {
  mkdir -p "$SCRIPT_DIR/.claude"

  # Subscription mode: bootstrap credentials into the project .claude dir the
  # first time, so the container can authenticate without browser access.
  if [[ -z "${ANTHROPIC_API_KEY:-}" && \
        -f "$REAL_HOME/.claude/.credentials.json" && \
        ! -f "$SCRIPT_DIR/.claude/.credentials.json" ]]; then
    cp "$REAL_HOME/.claude/.credentials.json" "$SCRIPT_DIR/.claude/.credentials.json"
    chmod 600 "$SCRIPT_DIR/.claude/.credentials.json"
    echo "Copied subscription credentials to .claude/ for container use."
  fi
}

generate_mounts_override() {
  local volumes=()

  # Always persist the Claude config / memory directory.
  # This bind mount overlays the /home/agent tmpfs for this one subdirectory,
  # keeping memory and settings across container restarts.
  volumes+=("      - \"${SCRIPT_DIR}/.claude:/home/agent/.claude:rw\"")

  if [[ -n "${AGENT_MOUNTS_RW:-}" ]]; then
    IFS=':' read -ra RW_PATHS <<< "$AGENT_MOUNTS_RW"
    for p in "${RW_PATHS[@]}"; do
      [[ -z "$p" ]] && continue
      local expanded
      expanded=$(expand_path "$p")
      local base
      base=$(basename "$expanded")
      volumes+=("      - \"${expanded}:/workspace/${base}:rw\"")
    done
  fi

  if [[ -n "${AGENT_MOUNTS_RO:-}" ]]; then
    IFS=':' read -ra RO_PATHS <<< "$AGENT_MOUNTS_RO"
    for p in "${RO_PATHS[@]}"; do
      [[ -z "$p" ]] && continue
      local expanded
      expanded=$(expand_path "$p")
      local base
      base=$(basename "$expanded")
      volumes+=("      - \"${expanded}:/workspace/${base}:ro\"")
    done
  fi

  # volumes always has at least the .claude entry, so the override is always written.

  cat > "$MOUNTS_OVERRIDE" <<EOF
services:
  agent:
    volumes:
$(printf '%s\n' "${volumes[@]}")
EOF
  echo "Generated mount override: $MOUNTS_OVERRIDE"
}

# ── Compose helpers ───────────────────────────────────────────────────────────
compose() {
  local files=("${COMPOSE_FILES[@]}")
  if [[ -f "$MOUNTS_OVERRIDE" ]]; then
    files+=(-f "$MOUNTS_OVERRIDE")
  fi
  docker compose "${files[@]}" "$@"
}

is_running() {
  compose ps --services --filter status=running 2>/dev/null | grep -q "^agent$"
}

apply_iptables() {
  if [[ "$USE_IPTABLES" == "true" ]]; then
    if sudo -n true 2>/dev/null; then
      echo "Applying iptables egress rules..."
      sudo "$SCRIPT_DIR/iptables-setup.sh" "$COMPOSE_PROJECT_NAME"
    else
      echo "WARNING: sudo not available without password. iptables rules not applied." >&2
      echo "         Run: sudo $SCRIPT_DIR/iptables-setup.sh $COMPOSE_PROJECT_NAME" >&2
    fi
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_start() {
  local think_flag=""
  [[ "${1:-}" == "--think" ]] && think_flag="--think"

  validate_mounts
  ensure_claude_dir
  generate_mounts_override

  if is_running; then
    echo "Agent container already running. Attaching..."
    cmd_attach
    return
  fi

  echo "Platform: $PLATFORM"
  echo "Project:  $COMPOSE_PROJECT_NAME"
  echo "Starting Claude Code sandbox..."

  # Bring up containers — sleep infinity keeps the agent alive in detached mode
  compose up -d --build

  # Apply iptables after containers are up (Linux only)
  apply_iptables

  # Exec into the running container
  echo ""
  echo "Attaching to agent container (detach with Ctrl+P Ctrl+Q)..."
  if [[ -n "$think_flag" ]]; then
    compose exec agent bash -c "claude --think"
  else
    compose exec agent bash
  fi
}

cmd_stop() {
  echo "Stopping Claude Code sandbox ($COMPOSE_PROJECT_NAME)..."
  compose down
}

cmd_attach() {
  if ! is_running; then
    echo "ERROR: Agent container is not running. Use './start.sh start' first." >&2
    exit 1
  fi
  echo "Attaching to agent container (detach with Ctrl+P Ctrl+Q)..."
  compose exec agent bash
}

cmd_rebuild() {
  local clean=false
  local passthrough=()

  for arg in "$@"; do
    case "$arg" in
      --clean) clean=true ;;
      *)       passthrough+=("$arg") ;;
    esac
  done

  echo "Rebuilding Claude Code sandbox..."
  compose down

  if [[ "$clean" == "true" ]]; then
    echo "Clean rebuild (no cache)..."
    compose build --no-cache
  else
    compose build
  fi

  cmd_start "${passthrough[@]+"${passthrough[@]}"}"
}

cmd_refresh() {
  if [[ "$USE_IPTABLES" != "true" ]]; then
    echo "DNS refresh is only needed on Linux (iptables mode)."
    exit 0
  fi
  echo "Refreshing DNS allowlist..."
  sudo "$SCRIPT_DIR/iptables-setup.sh" "$COMPOSE_PROJECT_NAME"
}

cmd_status() {
  echo "Running Claude Code sandboxes:"
  echo ""
  docker ps --filter "label=com.docker.compose.service=agent" \
    --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
  local count
  count=$(docker ps --filter "label=com.docker.compose.service=agent" -q 2>/dev/null | wc -l)
  echo ""
  echo "$count sandbox(es) running."
}

# ── Entrypoint ────────────────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  start)
    cmd_start "${@}"
    ;;
  stop)
    cmd_stop
    ;;
  attach)
    cmd_attach
    ;;
  rebuild)
    cmd_rebuild "${@}"
    ;;
  refresh)
    cmd_refresh
    ;;
  status)
    cmd_status
    ;;
  help|--help|-h)
    cat <<EOF
Usage: ./start.sh <command> [options]

Project: $COMPOSE_PROJECT_NAME

Commands:
  start            Bring up container(s) and attach terminal
  start --think    Start with extended thinking flag passed to Claude Code
  stop             Tear down container(s)
  attach           Attach to already-running agent container
  rebuild          Rebuild image (cached) and restart
  rebuild --clean  Rebuild image from scratch (no cache) and restart
  refresh          Re-resolve DNS and update iptables allowlist
  status           List all running sandbox containers

Each unique AGENT_MOUNTS_RW path gets its own container.
Detach from running container: Ctrl+P Ctrl+Q
EOF
    ;;
  *)
    echo "ERROR: Unknown command: $COMMAND" >&2
    echo "Run './start.sh help' for usage." >&2
    exit 1
    ;;
esac
