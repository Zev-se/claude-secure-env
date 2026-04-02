# Claude Code Sandbox

A Docker-based sandbox that runs Claude Code in an isolated environment with controlled filesystem access, network restrictions, and security hardening. Works on Linux (native), WSL2, and Windows (Docker Desktop). macOS is untested — it may work via the Squid proxy path but is not officially supported.

---

## Prerequisites

### All Platforms
- Docker Engine / Docker Desktop (recent version with Compose v2)
- Bash (Git Bash on Windows works; WSL2 preferred)

### Linux (native)
- `ipset` and `iptables` packages installed
- `sudo` access for iptables rule management

### WSL2
- Docker Desktop for Windows with WSL2 backend enabled, **or** Docker Engine installed directly in WSL2
- `ipset` and `iptables` available inside WSL2

### Windows (Docker Desktop)
- Docker Desktop with WSL2 or Hyper-V backend
- Git Bash or any POSIX-compatible shell for running `start.sh`

---

## First-Time Setup

1. **Clone or copy this repo to your machine.**

2. **Copy the example env file:**
   ```bash
   cp env.example .env
   ```

3. **Fill in `.env`:**
   - `ANTHROPIC_API_KEY` — optional; only needed for API mode (pay-per-token). If using a Pro/Max subscription, leave it commented out and follow `SUBSCRIPTION_MODE.md` instead. If using API mode, also uncomment the matching line in `docker-compose.yml`.
   - `HOST_UID` to your host user ID (`id -u`)
   - `AGENT_MOUNTS_RW` and/or `AGENT_MOUNTS_RO` to the paths you want the agent to access

4. **Make `start.sh` executable:**
   ```bash
   chmod +x start.sh iptables-setup.sh
   ```

5. **Start the sandbox:**
   ```bash
   ./start.sh start
   ```

---

## Usage

```
./start.sh start          # Build and start containers, attach terminal
./start.sh start --think  # Start with extended thinking enabled in Claude Code
./start.sh stop           # Tear down all containers
./start.sh attach         # Attach to an already-running agent container
./start.sh rebuild        # Rebuild the Docker image from scratch and restart
```

**Detach from a running container without stopping it:** `Ctrl+P Ctrl+Q`

---

## Mounting Folders (AGENT_MOUNTS_RW / AGENT_MOUNTS_RO)

Edit your `.env` file to control what the agent can access:

```env
# Read-write mounts — agent can read and write these
AGENT_MOUNTS_RW=~/code/my-project/src:~/code/another-project/src

# Read-only mounts — agent can only read these
AGENT_MOUNTS_RO=~/code/shared-lib/src
```

Each path is mounted inside the container at `/workspace/<basename>`.  
For example, `~/code/my-project/src` becomes `/workspace/src` inside the container.

### ⚠️ Security Warning: Never Mount Directories Containing Secrets

The agent can read everything in mounted directories and can send content to the Anthropic API. **Never mount directories that contain:**
- SSH keys, GPG keys, or other credentials
- `.env` files with production secrets
- Git configs with embedded tokens
- Cloud provider credential files (`~/.aws`, `~/.gcloud`, etc.)
- Browser profiles or password stores

**Always mount the smallest, most specific subdirectory you need** — not project roots that might contain secrets.

### Validation

`start.sh` will refuse to start if any mount path is:
- Your home directory (`~`)
- A filesystem root (`/`)
- A parent of another listed mount (overlapping mounts)

---

## Extending the Network Allowlist

The sandbox restricts outbound network access to `api.anthropic.com` only. To allow additional domains:

### Linux / WSL2 (iptables)

1. Resolve the new domain and add its IPs to the ipset:
   ```bash
   sudo ipset add claude-allowlist <ip-address>
   ```
2. For persistent refresh, edit `iptables-setup.sh` and add the new domain alongside `api.anthropic.com`.

### Windows (Squid proxy)

Edit `squid.conf` and add the domain to the ACL:
```
acl allowed_dst dstdomain api.anthropic.com
acl allowed_dst dstdomain your-new-domain.com
```
Then restart the proxy container:
```bash
docker compose -f docker-compose.yml -f docker-compose.windows.yml restart proxy
```

---

## Adding MCP Servers

Claude Code supports MCP (Model Context Protocol) servers. To configure them:

1. The agent's `~/.claude` directory is ephemeral (tmpfs) — it resets on every container restart.
2. To persist MCP config, mount a host directory over the config location, or pre-populate via a startup script.
3. The `~/.claude/config.json` file is where Claude Code reads MCP server definitions. Refer to the [Claude Code MCP documentation](https://docs.anthropic.com/claude-code) for the exact schema.

A common pattern is to add MCP config to your `CLAUDE.md` as a comment and have the agent write it to `~/.claude/config.json` at the start of each session.

---

## The CLAUDE.md / TASKS.md Convention

Every project should have a `CLAUDE.md` and `TASKS.md` in its root (templates are in `context/`).

- **`CLAUDE.md`** — Persistent context for the agent: project architecture, conventions, failed approaches, external constraints, and current focus. Think of it as the agent's "memory."
- **`TASKS.md`** — The work queue: what's in progress, what's next, what's blocked, what's done.

The agent is instructed (via `CLAUDE.md`) to:
- Read `TASKS.md` at the start of every session
- Propose updates to both files at the end of every session (never silently)
- Never modify files outside `/workspace/`

Copy the templates into each project you mount:
```bash
cp context/CLAUDE.md ~/code/my-project/CLAUDE.md
cp context/TASKS.md ~/code/my-project/TASKS.md
```

---

## Extended Thinking Sessions (`--think`)

Pass `--think` to enable Claude's extended thinking mode, which allocates more compute to reasoning before responding. Useful for complex architectural decisions, debugging hard problems, or planning multi-step refactors.

```bash
./start.sh start --think
```

---

## Security Boundary

### What this sandbox protects against

| Threat | Linux/iptables | Windows/Squid |
|--------|---------------|---------------|
| Agent exfiltrating data to arbitrary internet hosts | ✅ Blocked at kernel level | ✅ Blocked at proxy level |
| Agent writing files outside mounted directories | ✅ Read-only root filesystem | ✅ Read-only root filesystem |
| Agent escaping to host filesystem | ✅ No host paths mounted except explicit mounts | ✅ Same |
| Agent using dangerous syscalls (ptrace, mount, etc.) | ✅ seccomp profile | ✅ seccomp profile |
| Agent consuming excessive host resources | ✅ 4GB RAM, 2 CPU, 256 PID limits | ✅ Same |
| Agent persisting malicious state between sessions | ✅ Ephemeral /home/agent (tmpfs) | ✅ Same |

### ⚠️ What this sandbox does NOT protect against

- **Data exfiltration via the API channel:** The agent communicates with `api.anthropic.com` to function. Any file content in mounted directories can be read by the agent and sent as part of an API request. **This is intentional and unavoidable — never mount directories containing secrets.**

- **Windows/Squid boundary is softer than Linux/iptables:** On Linux, egress is enforced at the kernel level in the `DOCKER-USER` iptables chain — it cannot be bypassed from inside the container. On Windows, enforcement is at the Squid proxy layer. A sophisticated agent could potentially try to bypass the proxy (though the internal-only network makes this difficult). For highest assurance, use Linux.

- **API key theft:** The API key is injected as an environment variable. A compromised agent could read and exfiltrate it via the API channel.

- **Host kernel exploits:** The seccomp profile blocks the most common container escape syscalls, but a zero-day kernel vulnerability could theoretically escape the sandbox. This is a residual risk inherent to any containerized sandbox.

- **Resource exhaustion within limits:** The agent could legitimately use all 4GB of RAM and 2 CPUs granted to it.

### Intended blast radius

The sandbox is designed so that the maximum damage from a compromised or misbehaving agent is limited to:
1. **Contents of `AGENT_MOUNTS_RW` folders** — files can be read, modified, or deleted
2. **API credits** — the agent can make API calls until your key's limit is reached

Everything else on your host system is out of reach.

---

## Troubleshooting

**`iptables-setup.sh` fails with "network not found"**  
Make sure you run `./start.sh start` before running the iptables script manually. The script needs the container network to exist.

**Container starts but Claude Code can't reach the API**  
Check that `api.anthropic.com` resolves correctly and that the iptables/Squid rules are applied. On Linux, run `sudo iptables -L DOCKER-USER -n` to inspect rules.

**Permission errors on mounted files**  
Make sure `HOST_UID` in `.env` matches your actual user ID (`id -u`).

**`start.sh` rejects my mount path**  
Ensure you're mounting a specific project subdirectory, not your home directory or a filesystem root.
