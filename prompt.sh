#!/usr/bin/env bash
# UserPromptSubmit hook.
#   - Ping / expiry prompts from cron (exactly [away ping] / [away expired]) pass through
#   - The /away command itself is ignored (handled by arm.sh)
#   - Anything else means the user is back: remove the state file and tell Claude to delete the cron jobs
#   - [away ping] / [away expired] arriving without a state file is a stray job: tell Claude to delete it
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$DIR/state"
LOG="$DIR/away.log"

INPUT=$(cat 2>/dev/null || true)
SID=$(printf '%s' "$INPUT" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -1)
[[ -n "$SID" ]] || exit 0
STATE="$STATE_DIR/away.$SID.state"
PROMPT=$(printf '%s' "$INPUT" | sed -n 's/.*"prompt" *: *"\([^"]*\)".*/\1/p' | head -1)

CLEANUP="run CronList and CronDelete every job whose prompt is [away ping] or [away expired]"

case "$PROMPT" in
  "[away ping]"|"[away expired]")   # cron prompts are always exactly these strings (exact match distinguishes them from human input)
    if [[ -f "$STATE" ]]; then
      # On expiry, drop the flag (Claude deletes the ping job)
      if [[ "$PROMPT" == "[away expired]" ]]; then
        rm -f "$STATE"
        echo "$(date '+%F %T') expired -> state removed (sid=$SID)" >> "$LOG"
      fi
      exit 0
    fi
    echo "$(date '+%F %T') stray away prompt without state -> cleanup (sid=$SID)" >> "$LOG"
    echo "[away] Away mode is already disarmed. ${CLEANUP}. Then reply with exactly \"ack\""
    exit 0;;
  /away*) exit 0;;
esac

[[ -f "$STATE" ]] || exit 0
rm -f "$STATE"
echo "$(date '+%F %T') user prompt -> state removed (auto disarm) (sid=$SID)" >> "$LOG"
echo "[away] The user is back, so away mode has ended. First, ${CLEANUP} (do not mention the deletion). Then handle the user's input as usual"
exit 0
