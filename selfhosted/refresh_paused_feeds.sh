#!/usr/bin/env bash
# Regenerates the feeds upstream (Olshansk/rss-feeds) paused because its GitHub runners
# get blocked, and pushes them to this fork so blog-watcher can read them from
# raw.githubusercontent.com/tobrun/rss-feeds. Upstream changes are merged first, upstream
# winning conflicts, so this fork never drifts from it except for the paused feeds.
#
# Logs to selfhosted/logs/refresh-<date>.log (30-day retention, gitignored); on any
# failure sends a Telegram message through the Hermes bot script.
#
# Called by selfhosted/rss-paused-feeds.service; run by hand:
#   bash selfhosted/refresh_paused_feeds.sh
#   NOTIFY_CMD  notify command (default the Hermes send_telegram.sh)
#   NO_PUSH=1   regenerate and commit, but do not push
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PAUSED_GENERATORS=(
  deeplearningai_the_batch.py
  perplexity_hub.py
  xainews_blog.py
)
NOTIFY_CMD="${NOTIFY_CMD:-$HOME/.claude/skills/send-telegram-message/scripts/send_telegram.sh}"
UV="${UV:-$HOME/.local/bin/uv}"
LOG_DIR="selfhosted/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/refresh-$(date +%F).log"
find "$LOG_DIR" -maxdepth 1 -name "refresh-*.log" -type f -mtime +30 -delete 2>/dev/null || true

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"; }

failures=()

fail_and_exit() {
  log "ERROR: $1"
  "$NOTIFY_CMD" "rss-feeds paused-feed refresh failed: $1
see $REPO_ROOT/$LOG_FILE" || log "WARNING: telegram notification failed"
  exit 1
}

log "refresh: start"

git fetch --quiet --multiple upstream origin>>"$LOG_FILE" 2>&1 || fail_and_exit "git fetch"
git checkout --quiet main >>"$LOG_FILE" 2>&1 || fail_and_exit "git checkout main"
git merge --quiet --ff-only origin/main >>"$LOG_FILE" 2>&1 || fail_and_exit "fast-forward to origin/main"
git merge --quiet --no-edit -X theirs upstream/main >>"$LOG_FILE" 2>&1 || fail_and_exit "merge upstream/main"

"$UV" sync --quiet >>"$LOG_FILE" 2>&1 || fail_and_exit "uv sync"

for generator in "${PAUSED_GENERATORS[@]}"; do
  log "run $generator"
  if ! timeout 10m "$UV" run python "feed_generators/$generator" >>"$LOG_FILE" 2>&1; then
    failures+=("$generator")
    log "FAILED $generator"
  fi
done

git add feeds cache >>"$LOG_FILE" 2>&1
if git diff --cached --quiet; then
  log "no feed changes"
else
  git commit --quiet -m "Update paused feeds (self-hosted)" >>"$LOG_FILE" 2>&1 || fail_and_exit "git commit"
  log "committed $(git rev-parse --short HEAD)"
fi

if [ "${NO_PUSH:-0}" != "1" ]; then
  git push --quiet origin main >>"$LOG_FILE" 2>&1 || fail_and_exit "git push"
  log "pushed"
fi

if [ "${#failures[@]}" -gt 0 ]; then
  fail_and_exit "generators failed: ${failures[*]}"
fi

log "refresh: done"
