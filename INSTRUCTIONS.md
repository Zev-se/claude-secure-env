# Claude Code Sandbox — Developer Instructions

## Prerequisites

Ensure the following are installed before proceeding:

- **Docker Engine** (Linux) or **Docker Desktop** (Windows)
- **Docker Compose v2** (`docker compose` — not the legacy `docker-compose`)
- **Bash** (native on Linux; use Git Bash or WSL2 on Windows)
- **sudo access** (Linux/WSL2 only — required for iptables rules)
- **ipset + iptables** (Linux/WSL2 only): `sudo apt install ipset iptables`)

---

## 1. First-Time Setup

### Clone the sandbox template
```bash
git clone <repo-url> my-project
cd my-project
```

### Initialise your project directory

`src/` is where your work lives — source code, context, agent memory.
It is a separate git repo from this sandbox template, pointing at your own private remote.

```bash
# Create the project structure
mkdir -p src/context
mkdir -p src/.claude

# Copy starter templates
cp context/CLAUDE.md src/CLAUDE.md
cp context/TASKS.md  src/TASKS.md

# Create src/.gitignore — exclude credentials, keep everything else
cat > src/.gitignore << 'EOF'
.claude/.credentials.json
EOF

# Initialise the project repo and point it at your private remote
cd src
git init
git remote add origin git@your-gitea:you/my-project.git
git add .
git commit -m "Initial project scaffold"
git push -u origin main
cd ..
```

Edit `src/CLAUDE.md` and `src/TASKS.md` to reflect your actual project before the first session.

> **Nested repos:** `src/` is listed in this template's `.gitignore`, so the outer
> repo (this sandbox) never sees or touches `src/.git`.  The two repos are fully
> independent — `git pull` in the project root gets template updates; `git push`
> inside `src/` backs up your work.

### Create your `.env` file
```bash
cp env.example .env
```

Open `.env` and fill in the required values:

| Variable | How to get it |
|---|---|
| `ANTHROPIC_API_KEY` | [console.anthropic.com](https://console.anthropic.com) → API Keys. **Leave commented out if using a Pro/Max subscription.** |
| `HOST_UID` | Run `id -u` in your terminal |
| `AGENT_MOUNTS_RW` | Colon-separated paths the agent can read **and write** |
| `AGENT_MOUNTS_RO` | Colon-separated paths the agent can only **read** |

**Authentication is either/or — pick one mode:**

*API mode (pay-per-token):*
```env
ANTHROPIC_API_KEY=sk-ant-...
HOST_UID=1000
AGENT_MOUNTS_RW=~/my-project/src
```

*Subscription mode (Pro/Max — no per-token charges):*
```env
# ANTHROPIC_API_KEY is intentionally absent
HOST_UID=1000
AGENT_MOUNTS_RW=~/my-project/src
```

See `SUBSCRIPTION_MODE.md` for full subscription setup instructions. If both are present, the API key takes precedence and you will be billed per token.

### Make scripts executable
```bash
chmod +x start.sh iptables-setup.sh
```

---

## 2. Starting and Stopping

### Start the sandbox
```bash
./start.sh start
```

This will:
1. Detect your platform (Linux, WSL2, or Windows; macOS untested)
2. Validate your mount paths
3. Build the Docker image (first run takes a few minutes)
4. Start the container(s)
5. Apply iptables egress rules (Linux/WSL2 only)
6. Drop you into a shell inside the agent container

### Start with extended thinking enabled
```bash
./start.sh start --think
```

Use this for complex tasks — architectural decisions, hard debugging, multi-step refactors. Claude will spend more time reasoning before responding.

### Detach without stopping the container
```
Ctrl+P  Ctrl+Q
```

### Re-attach to a running container
```bash
./start.sh attach
```

### Stop and tear down all containers
```bash
./start.sh stop
```

### Rebuild the image from scratch
```bash
./start.sh rebuild
```

Use this after editing the `Dockerfile` or when you want a clean slate.

---

## 3. Configuring Mounts

Mounts are set in `.env` as colon-separated host paths.

```env
AGENT_MOUNTS_RW=~/code/project-a/src:~/code/project-b/src
AGENT_MOUNTS_RO=~/code/shared-lib/src
```

Each path is mounted inside the container at `/workspace/<basename>`:

| Host path | Container path | Access |
|---|---|---|
| `~/code/project-a/src` | `/workspace/src` | Read + Write |
| `~/code/shared-lib/lib` | `/workspace/lib` | Read only |

> **Note:** If two mounted paths share the same `basename`, they will collide inside the container. Rename one of the host directories or restructure your mounts to avoid this.

### Mount validation

`start.sh` will refuse to start if any path is:
- Your home directory (`~` or `/home/yourname`)
- A filesystem root (`/`)
- A parent directory of another listed mount

These checks prevent accidentally granting the agent overly broad access.

---

## 4. CLAUDE.md and TASKS.md

These files live in `src/` — inside your project repo, versioned on your private remote.
Inside the container they are at `/workspace/src/CLAUDE.md` and `/workspace/src/TASKS.md`.

### `src/CLAUDE.md` — Project memory
Tells the agent what the project is, how it's structured, what conventions to follow, and what approaches have already failed. Fill this in accurately — it directly affects the quality of the agent's output.

Key sections to keep current:
- **Current Focus** — update this every session
- **Failed Approaches** — add entries whenever something doesn't work out
- **Conventions** — be specific; vague instructions get ignored

### `src/TASKS.md` — Work queue
Tracks what's in progress, what's next, and what's blocked. The agent reads this at the start of every session and proposes updates at the end.

### `src/context/` — Session history and decisions
Use this directory for session notes, decision logs, and anything you want to be able to look back on. This is the long-term record of why things are the way they are.

### `src/.claude/` — Agent memory and settings
Claude Code writes persistent memory here between sessions. Versioned in your project repo so memory survives across machines and time. Credentials are excluded via `src/.gitignore`.

**Workflow per session:**
1. Open `src/TASKS.md` and confirm the current task is still accurate
2. Start the sandbox: `./start.sh start`
3. Let the agent work
4. At session end, review the agent's proposed diffs to `CLAUDE.md` and `TASKS.md` before accepting them
5. Commit and push from `src/`: `cd src && git add -A && git commit -m "..." && git push`

---

## 5. Network Access

The agent can only reach `api.anthropic.com`. All other outbound traffic is blocked.

### Linux / WSL2 (iptables)
Egress is enforced at the kernel level via the `DOCKER-USER` iptables chain. Rules are applied automatically by `start.sh`. To refresh DNS resolution manually:
```bash
sudo ./iptables-setup.sh <compose-project-name>
```
(The project name is printed when you run `./start.sh start`, e.g. `claude-src`.)

To allow an additional domain, add it to `iptables-setup.sh` alongside `api.anthropic.com` and re-run the script.

### Windows / Docker Desktop (Squid proxy)
Egress is enforced by the Squid proxy container. To allow an additional domain, edit `squid.conf`:
```
acl allowed_dst dstdomain api.anthropic.com
acl allowed_dst dstdomain your-new-domain.com   # add this line
```
Then restart the proxy:
```bash
docker compose -f docker-compose.yml -f docker-compose.windows.yml restart proxy
```

---

## 6. Security Guidelines

### What the sandbox contains
- **Read-only root filesystem** — the agent cannot write anywhere except `/tmp`, `/home/agent`, and your explicitly mounted directories
- **Ephemeral home directory** — `/home/agent` is a tmpfs mount; it resets on every container restart. No state persists between sessions.
- **Blocked syscalls** — `ptrace`, `mount`, `unshare`, `keyctl`, `add_key`, `request_key` are all blocked via a seccomp profile to prevent container escape
- **Resource limits** — 4 GB RAM, 2 CPUs, 256 max PIDs

### What the sandbox does NOT prevent

| Risk | Notes |
|---|---|
| **Data sent via the API** | The agent communicates with Anthropic's API to function. Any file it can read, it can send. |
| **API key exposure** | The key is an environment variable inside the container. A compromised agent could read and send it. |
| **Writes to RW mounts** | The agent has full write access to `AGENT_MOUNTS_RW` paths — it can delete or overwrite files. |
| **Windows egress bypass** | Squid is a proxy-layer control. It is less hardened than Linux kernel-level iptables rules. |

### Hard rules for mount hygiene

- **Never mount directories containing secrets** — SSH keys, `.env` production files, `~/.aws`, `~/.gcloud`, browser profiles, `.netrc`
- **Never mount your project root** if it contains a `.env` file with credentials; mount only the `src/` subdirectory
- **Never mount a parent of a directory that contains secrets**

The intended blast radius of a worst-case failure is: contents of `AGENT_MOUNTS_RW` folders, and your Anthropic API credits. Keep both bounded.

---

## Troubleshooting

**`iptables-setup.sh` fails: network not found**
Run `./start.sh start` first — the container network must exist before the script can identify its subnet.

**Permission errors on mounted files**
Confirm `HOST_UID` in `.env` matches `id -u` on your host.

**start.sh rejects a mount path**
You're mounting too broadly. Point to a specific subdirectory, not a home directory or project root.

**Container builds but Claude Code can't call the API (API mode)**
Check two things: (1) `ANTHROPIC_API_KEY` is set correctly in `.env` (no quotes, no trailing whitespace), and (2) the `ANTHROPIC_API_KEY` line is uncommented in `docker-compose.yml` — it is commented out by default. Also verify egress rules are applied (`sudo iptables -L DOCKER-USER -n` on Linux).

**Two mounts have the same basename and collide**
Both `~/project-a/src` and `~/project-b/src` would map to `/workspace/src`. Rename one on the host or restructure your paths.
