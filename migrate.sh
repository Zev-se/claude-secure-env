#!/usr/bin/env bash
# migrate.sh — One-time migration to the new src/-based project structure.
#
# Run this on the HOST (not inside a container).
#
# What it does per project:
#   1. Stops all running Claude containers
#   2. Saves context/, src/, .claude/, CLAUDE.md, TASKS.md, .env to a temp dir
#   3. Deletes the old project folder
#   4. Clones the template fresh and renames it
#   5. Restores saved files into the new layout under src/
#   6. Creates a private Gitea repo and pushes src/ as its own git repo
#   7. Cleans up temp dir

set -euo pipefail

# ── Config — fill these in before running ─────────────────────────────────────
PROJECTS_DIR="${HOME}/projects"
TEMPLATE_REPO="git@github.com:youruser/secure-claude.git"
GITEA_HOST="gitea.yourdomain.internal"
GITEA_USER="youruser"
GITEA_TOKEN="your-token-here"
GITEA_API="https://${GITEA_HOST}/api/v1"
# ──────────────────────────────────────────────────────────────────────────────

# ── Step 0: stop all running Claude containers ────────────────────────────────
echo "Stopping all running Claude containers..."
docker ps --filter "name=claude-" --format "{{.Names}}" | xargs -r docker stop || true

# ── Migrate each project ──────────────────────────────────────────────────────
for project_dir in "$PROJECTS_DIR"/*/; do
  [[ -d "$project_dir" ]] || continue
  project_name=$(basename "$project_dir")
  tmp_dir="/tmp/claude-migrate-${project_name}"

  echo ""
  echo "=== Migrating: $project_name ==="

  # Step 1: stash existing work to temp
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  for item in context src .claude CLAUDE.md TASKS.md .env; do
    [[ -e "$project_dir/$item" ]] && mv "$project_dir/$item" "$tmp_dir/"
  done

  # Step 2: remove old project folder
  rm -rf "$project_dir"

  # Step 3: clone fresh template
  git clone "$TEMPLATE_REPO" "$project_dir"

  # Step 4: restore into new structure

  # Old src/ content → new src/
  if [[ -d "$tmp_dir/src" ]]; then
    cp -r "$tmp_dir/src/." "$project_dir/src/"
  fi

  # Old context/ → src/context/
  if [[ -d "$tmp_dir/context" ]]; then
    mv "$tmp_dir/context" "$project_dir/src/context"
  fi

  # Old .claude/ → src/.claude/
  if [[ -d "$tmp_dir/.claude" ]]; then
    mv "$tmp_dir/.claude" "$project_dir/src/.claude"
  fi

  # CLAUDE.md and TASKS.md → src/ (project-specific versions from root)
  [[ -f "$tmp_dir/CLAUDE.md" ]] && mv "$tmp_dir/CLAUDE.md" "$project_dir/src/CLAUDE.md"
  [[ -f "$tmp_dir/TASKS.md" ]]  && mv "$tmp_dir/TASKS.md"  "$project_dir/src/TASKS.md"

  # .env stays at project root
  [[ -f "$tmp_dir/.env" ]] && mv "$tmp_dir/.env" "$project_dir/.env"

  # src/.gitignore — exclude credentials, track everything else
  echo ".claude/.credentials.json" > "$project_dir/src/.gitignore"

  # Note: src/context/CLAUDE.md and src/context/TASKS.md are the old template
  # stubs — delete them if src/CLAUDE.md already has your project content.

  # Create Gitea repo
  echo "  Creating Gitea repo: $project_name"
  curl -sf -X POST "${GITEA_API}/user/repos" \
    -H "Authorization: token ${GITEA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${project_name}\", \"private\": true}"

  # Init src/ as its own git repo and push
  cd "$project_dir/src"
  git init -b main
  git remote add origin "git@${GITEA_HOST}:${GITEA_USER}/${project_name}.git"
  git add .
  git commit -m "Initial project migration"
  git push -u origin main
  cd "$PROJECTS_DIR"

  # Step 5: clean up temp
  rm -rf "$tmp_dir"

  echo "  ✓ $project_name done"
done

echo ""
echo "Migration complete."
echo ""
echo "For each project, update AGENT_MOUNTS_RW in .env to point to src/:"
echo "  AGENT_MOUNTS_RW=~/projects/<project-name>/src"
