# Using the Sandbox with a Pro/Max Subscription

This guide covers running Claude Code in the Docker sandbox using your Claude Pro or Max subscription instead of API credits.

## How It Works

Claude Code stores OAuth credentials in `~/.claude/.credentials.json`.  The sandbox
automatically creates a persistent `src/.claude/` directory and bind-mounts it into
the container at `/home/agent/.claude`.

On the **first start in subscription mode** the script copies your host credentials
into `src/.claude/` so the container can authenticate.  After that the directory
persists across container restarts, keeping credentials, agent memory, and settings
intact.  Because `src/.claude/` lives inside your project's `src/` git repo, agent
memory and settings are versioned alongside your code — only the credentials file
should be excluded from commits (see `.gitignore` in `src/`).

## One-Time Setup: Authenticate on the Host

Install Claude Code on your host if you haven't already:

```bash
npm install -g @anthropic-ai/claude-code
```

Run the login flow:

```bash
claude
```

This opens a browser for OAuth.  Log in with your Claude Pro/Max account.  Once
complete, verify the credential file exists:

```bash
ls -la ~/.claude/.credentials.json
```

## Configure .env for Subscription Mode

Edit your `.env` file.  **Comment out or remove** `ANTHROPIC_API_KEY` — that is all:

```bash
# Claude Code Sandbox — Environment Configuration

# IMPORTANT: Comment out ANTHROPIC_API_KEY when using subscription mode.
# If both are present, the API key takes precedence and you get billed per-token.
#ANTHROPIC_API_KEY=sk-ant-api03-...

HOST_UID=1000

# Your project mounts (adjust to your needs)
AGENT_MOUNTS_RW=~/projects/my-project/src
```

No `CLAUDE_CONFIG_DIR` or `AGENT_MOUNTS_RO=~/.claude` entries are needed.
The script handles credential bootstrapping automatically.

## What Gets Persisted

`src/.claude/` is bind-mounted into the container and survives container restarts.
It contains:

| Path | Contents |
|------|----------|
| `src/.claude/.credentials.json` | OAuth token (copied from host on first start) |
| `src/.claude/settings.json` | Claude Code settings |
| `src/.claude/projects/` | Agent memory written during sessions |

`src/` is your project's git repo — commit memory and settings, but exclude
credentials.  Add this to `src/.gitignore`:
```
.claude/.credentials.json
```

## Switching Between API and Subscription Mode

**API mode** (pay-per-token, no rate limits):
```bash
ANTHROPIC_API_KEY=sk-ant-api03-...
```

**Subscription mode** (Pro/Max included usage):
```bash
#ANTHROPIC_API_KEY=sk-ant-api03-...
```

After switching, restart the container:

```bash
./start.sh stop
./start.sh start
```

## Verify Inside the Container

Once attached, check which auth method is active:

```bash
claude /status
```

You should see your subscription account listed, not an API key.

## Token Refresh

OAuth tokens expire periodically.  To refresh:

1. On your **host**, run `claude` (or `claude /login` if it prompts you)
2. Copy the refreshed credentials into the project directory:
   ```bash
   cp ~/.claude/.credentials.json <sandbox-dir>/src/.claude/.credentials.json
   chmod 600 <sandbox-dir>/src/.claude/.credentials.json
   ```
3. Restart the container: `./start.sh stop && ./start.sh start`

The auto-copy in step 2 only runs on first start (when `.claude/.credentials.json`
is absent), so refreshes must be done manually.

## Migrating from the Old Setup

If your `.env` contains the old subscription-mode settings, remove them:

```diff
-CLAUDE_CONFIG_DIR=/workspace/.claude
-AGENT_MOUNTS_RO=~/.claude
```

The persistent `.claude/` mount now handles everything those settings did, without
the read-only limitation that prevented memory from being written.

## Security Notes

- `src/.claude/.credentials.json` must be in `src/.gitignore` — never commit it
- The OAuth token grants access to your Claude subscription — treat it like a password
- If you suspect the token was exposed, run `claude /logout` on your host to revoke it,
  then `claude /login` to get a fresh one and copy it into `src/.claude/`

## Rate Limits

Pro and Max plans have daily usage limits (unlike API which is pay-as-you-go).  If
you hit the limit, Claude Code will tell you.  For heavy agentic workloads that burn
through context fast, API mode may still be preferable.
