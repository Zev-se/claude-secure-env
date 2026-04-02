#!/usr/bin/env bash
# iptables-setup.sh — Enforce Claude Code sandbox egress on Linux/WSL2
# Idempotent: safe to run multiple times.
# Must be run with sudo.

set -euo pipefail

ALLOWLIST_DOMAIN="api.anthropic.com"
IPSET_NAME="claude-allowlist"

# Optional: accept a project name to target a specific sandbox network.
# Passed by start.sh as the first argument so that multiple running sandboxes
# do not have their rules applied to the wrong subnet.
PROJECT_NAME="${1:-}"

# Discover the agent network dynamically — Docker prefixes the network name
# with the compose project name, which varies per user/project.
if [[ -n "$PROJECT_NAME" ]]; then
  NETWORK_NAME=$(docker network ls --format '{{.Name}}' | grep "^${PROJECT_NAME}_agent-net$" | head -1)
else
  NETWORK_NAME=$(docker network ls --format '{{.Name}}' | grep '_agent-net$' | head -1)
fi

# ── Privilege check ──────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: iptables-setup.sh must be run as root (use sudo)." >&2
  exit 1
fi

# ── Dependency check ─────────────────────────────────────────────────────────
for cmd in ipset iptables docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required command not found: $cmd" >&2
    exit 1
  fi
done

# ── Resolve DNS for allowlisted domain ───────────────────────────────────────
echo "Resolving $ALLOWLIST_DOMAIN (IPv4 only)..."
RESOLVED_IPS=$(getent ahosts "$ALLOWLIST_DOMAIN" 2>/dev/null \
  | awk '{print $1}' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -u)

if [[ -z "$RESOLVED_IPS" ]]; then
  echo "WARNING: Could not resolve $ALLOWLIST_DOMAIN. Retrying with dig..." >&2
  RESOLVED_IPS=$(dig +short A "$ALLOWLIST_DOMAIN" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true)
fi

if [[ -z "$RESOLVED_IPS" ]]; then
  echo "ERROR: Failed to resolve $ALLOWLIST_DOMAIN. Cannot populate allowlist." >&2
  exit 1
fi

echo "Resolved IPs: $RESOLVED_IPS"

# ── Create or flush ipset ────────────────────────────────────────────────────
if ipset list "$IPSET_NAME" &>/dev/null; then
  echo "Flushing existing ipset $IPSET_NAME..."
  ipset flush "$IPSET_NAME"
else
  echo "Creating ipset $IPSET_NAME..."
  ipset create "$IPSET_NAME" hash:ip
fi

# Populate ipset
for ip in $RESOLVED_IPS; do
  ipset add "$IPSET_NAME" "$ip"
  echo "  Added $ip to $IPSET_NAME"
done

# ── Get agent network subnet ─────────────────────────────────────────────────
if [[ -z "$NETWORK_NAME" ]]; then
  echo "ERROR: Could not find any Docker network ending in '_agent-net'." >&2
  echo "       Make sure containers are running: ./start.sh start" >&2
  echo "       Available networks:" >&2
  docker network ls --format '  {{.Name}}' >&2
  exit 1
fi

echo "Found agent network: $NETWORK_NAME"

AGENT_SUBNET=$(docker network inspect "$NETWORK_NAME" \
  --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)

if [[ -z "$AGENT_SUBNET" ]]; then
  echo "WARNING: Could not determine subnet for network $NETWORK_NAME." >&2
  echo "         Skipping DOCKER-USER rule insertion." >&2
  exit 0
fi

echo "Agent network subnet: $AGENT_SUBNET"

# ── Insert DOCKER-USER rules (idempotent) ────────────────────────────────────
# Check if our rules already exist by looking for the comment marker
RULE_MARKER="claude-sandbox-egress"

insert_rule_if_missing() {
  local rule_check="$1"
  local insert_cmd="$2"
  if ! iptables -C DOCKER-USER $rule_check 2>/dev/null; then
    read -ra insert_args <<< "$insert_cmd"
    iptables -I DOCKER-USER "${insert_args[@]}"
    echo "  Inserted: iptables -I DOCKER-USER $insert_cmd"
  else
    echo "  Already present: $rule_check"
  fi
}

# Rule order matters — insert in reverse priority (last inserted = first checked with -I)

# 3. Drop all other traffic from agent subnet (lowest priority — inserted first so it ends up last)
insert_rule_if_missing \
  "-s $AGENT_SUBNET -j DROP -m comment --comment $RULE_MARKER-drop" \
  "1 -s $AGENT_SUBNET -j DROP -m comment --comment $RULE_MARKER-drop"

# 2. Allow agent subnet → allowlisted IPs
insert_rule_if_missing \
  "-s $AGENT_SUBNET -m set --match-set $IPSET_NAME dst -j ACCEPT -m comment --comment $RULE_MARKER-allow" \
  "1 -s $AGENT_SUBNET -m set --match-set $IPSET_NAME dst -j ACCEPT -m comment --comment $RULE_MARKER-allow"

# 1. Allow established/related connections (highest priority)
insert_rule_if_missing \
  "-m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment $RULE_MARKER-established" \
  "1 -m state --state ESTABLISHED,RELATED -j ACCEPT -m comment --comment $RULE_MARKER-established"

echo "iptables rules applied successfully."
echo ""
echo "To refresh DNS allowlist later, run: sudo $0 [compose-project-name]"
