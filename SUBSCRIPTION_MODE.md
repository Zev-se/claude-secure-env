# Using the Sandbox with a Pro/Max Subscription

This guide covers running Claude Code in the Docker sandbox using your Claude Pro or Max subscription instead of API credits.

## How It Works

Claude Code on Linux stores OAuth credentials in `~/.claude/.credentials.json`. The approach is:

1. Authenticate Claude Code on your **host** machine (where you have a browser)
2. Mount the credential file **read-only** into the container
3. Remove `ANTHROPIC_API_KEY` from the container environment so Claude Code uses the subscription

This is important: if `ANTHROPIC_API_KEY` is set, Claude Code uses it **instead of** your subscription, which means API charges. You must make sure the API key is not passed into the container when using subscription mode.

## One-Time Setup: Authenticate on the Host

Install Claude Code on your host if you haven't already:

```bash
npm install -g @anthropic-ai/claude-code
```

Run the login flow:

```bash
claude
```

This opens a browser for OAuth. Log in with your Claude Pro/Max account. Once complete, verify the credential file exists:

```bash
ls -la ~/.claude/.credentials.json
```

You should see a JSON file owned by your user with `600` permissions. This file contains your OAuth token and is the only thing the container needs.

## Configure .env for Subscription Mode

Edit your `.env` file. **Comment out or remove** `ANTHROPIC_API_KEY` and add the subscription mount:

```bash
# Claude Code Sandbox — Environment Configuration

# IMPORTANT: Comment out ANTHROPIC_API_KEY when using subscription mode.
# If both are present, the API key takes precedence and you get billed per-token.
#ANTHROPIC_API_KEY=sk-ant-api03-...

HOST_UID=1000

# Point Claude Code at the mounted credentials directory
CLAUDE_CONFIG_DIR=/workspace/.claude

# Add your host ~/.claude credentials directory to the read-only mounts.
# This passes your subscription OAuth token into the container.
AGENT_MOUNTS_RO=~/.claude

# Your project mounts (adjust to your needs)
AGENT_MOUNTS_RW=~/projects/my-project/src
```

The key changes: `ANTHROPIC_API_KEY` is commented out, `~/.claude` is added to `AGENT_MOUNTS_RO`, and `CLAUDE_CONFIG_DIR` points to where the credentials land inside the container (`/workspace/.claude`).

## docker-compose.yml

No changes needed — the compose file reads `CLAUDE_CONFIG_DIR` from `.env` automatically. Just make sure you're not hardcoding `ANTHROPIC_API_KEY` in the compose environment section.

## Switching Between API and Subscription Mode

To switch between modes, you only need to change `.env`:

**API mode** (pay-per-token, no rate limits):
```bash
ANTHROPIC_API_KEY=sk-ant-api03-...
#CLAUDE_CONFIG_DIR=/workspace/.claude
#AGENT_MOUNTS_RO=~/.claude
```

**Subscription mode** (Pro/Max included usage):
```bash
#ANTHROPIC_API_KEY=sk-ant-api03-...
CLAUDE_CONFIG_DIR=/workspace/.claude
AGENT_MOUNTS_RO=~/.claude
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

You should see your subscription account listed, not an API key. If it says "API key", double-check that `ANTHROPIC_API_KEY` is not set:

```bash
echo $ANTHROPIC_API_KEY
```

This should be empty. If it's not, the env var is leaking in from somewhere — check `docker-compose.yml` and `.env`.

## Token Refresh

OAuth tokens expire periodically. When they do, Claude Code will fail to authenticate inside the container. To refresh:

1. On your **host**, run `claude` (or `claude /login` if it prompts you)
2. Restart the container: `./start.sh stop && ./start.sh start`

The mounted credential file is read-only from the container's perspective, so the container can never modify or corrupt your host credentials. Refreshing always happens on the host where you have browser access.

## Rate Limits

Pro and Max plans have daily usage limits (unlike API which is pay-as-you-go). If you hit the limit, Claude Code will tell you. This is normal — it resets daily. For heavy agentic workloads that burn through context fast, API mode may still be preferable. For conversational coding, reviews, and lighter editing work, subscription mode saves money.

## Security Notes

- The credential file is mounted **read-only** — the container cannot modify it
- Never commit `.credentials.json` to version control
- The OAuth token grants access to your Claude subscription — treat it like a password
- If you suspect the token was exposed, run `claude /logout` on your host to revoke it, then `claude /login` to get a fresh one
