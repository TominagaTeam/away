#!/usr/bin/env bash
# Runs via prompt expansion (the `!` line) when /away is invoked.
# Writes the state file and prints the cron expressions Claude passes to CronCreate,
# plus a status line for the user.
# Usage: arm.sh "<duration>"
#   duration: 90m / 3h / 2h30m  (default 3h, capped at 12h)
#   off | stop | cancel: disarm
# The ping interval is fixed at 30 minutes: the longest period expressible as a cron
# minute list, with enough margin against the 1-hour cache TTL.
# An undocumented second argument shortens it for testing (rounded down to 10/12/15/20 min).
# State file is per session: <skill dir>/state/away.<session_id>.state
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$DIR/state"
LOG="$DIR/away.log"
SID="${CLAUDE_CODE_SESSION_ID:-}"
HARD_CAP_SEC=$((12 * 3600))

if [[ -z "$SID" ]]; then
  echo "Cannot enter away mode: CLAUDE_CODE_SESSION_ID is not set"
  exit 0
fi
STATE="$STATE_DIR/away.$SID.state"
mkdir -p "$STATE_DIR"
# Remove orphaned state files: anything not updated for 12h is dead
find "$STATE_DIR" -name 'away.*.state' -mmin +720 -delete 2>/dev/null

LOG_KEEP=500
if [[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > LOG_KEEP )); then
  tail -n "$LOG_KEEP" "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi

to_sec() {
  # "2h30m" "90m" "45s" "300" -> seconds
  local s="$1" total=0 num unit
  [[ -z "$s" ]] && return 1
  if [[ "$s" =~ ^[0-9]+$ ]]; then echo "$s"; return 0; fi
  while [[ "$s" =~ ^([0-9]+)([hms]) ]]; do
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "$unit" in
      h) total=$((total + num * 3600));;
      m) total=$((total + num * 60));;
      s) total=$((total + num));;
    esac
    s="${s#${BASH_REMATCH[0]}}"
  done
  [[ -n "$s" ]] && return 1
  echo "$total"
}

fmt() {  # seconds -> "2h30m"
  local s=$1 out=""
  (( s >= 3600 )) && { out+="$((s / 3600))h"; s=$((s % 3600)); }
  (( s >= 60 ))   && { out+="$((s / 60))m";   s=$((s % 60)); }
  if (( s > 0 )) || [[ -z "$out" ]]; then out+="${s}s"; fi
  echo "$out"
}

read -r DUR_ARG INT_ARG _ <<< "${1:-}"
DUR_ARG="${DUR_ARG:-3h}"
INT_ARG="${INT_ARG:-30m}"

# Disarm: remove the state file and tell Claude to delete the cron jobs. Also used on argument errors
disarm() {
  if [[ -f "$STATE" ]]; then
    rm -f "$STATE"
    echo "$(date '+%F %T') /away $1 -> state removed (disarm) (sid=$SID)" >> "$LOG"
    echo "Away mode disarmed"
  else
    echo "Away mode is not active"
  fi
  echo "AWAY_DISARM"
  exit 0
}
case "$DUR_ARG" in
  off|stop|cancel) disarm "$DUR_ARG";;
esac
DUR=$(to_sec "$DUR_ARG") || { echo "Invalid duration: $DUR_ARG (e.g. 90m, 3h, 2h30m)"; disarm "$DUR_ARG"; }
INT=$(to_sec "$INT_ARG") || { echo "Invalid interval: $INT_ARG"; disarm "$DUR_ARG $INT_ARG"; }
(( DUR > HARD_CAP_SEC )) && DUR=$HARD_CAP_SEC

# Round the interval down to a divisor of 60 (minutes) so cron can express it. Max 30 min to stay under the 1h cache TTL
INT_MIN=$(( INT / 60 ))
PICKED=10
for c in 10 12 15 20 30; do (( INT_MIN >= c )) && PICKED=$c; done
INT_NOTE=""
(( INT_MIN != PICKED )) && INT_NOTE=" (rounded $(fmt "$INT") to ${PICKED}m)"
INT_MIN=$PICKED

NOW=$(date +%s)
EXPIRES=$((NOW + DUR))
(( DUR < INT_MIN * 60 )) && { echo "Duration is shorter than the interval: $DUR_ARG < ${INT_MIN}m"; disarm "$DUR_ARG"; }
PINGS=$(( DUR / (INT_MIN * 60) ))

# Ping cron: minute list starting INT_MIN minutes from now, stepping by INT_MIN across the hour
NOW_MIN=$(( 10#$(date '+%M') ))
mins=""
for (( k = 0; k < 60 / INT_MIN; k++ )); do
  m=$(( (NOW_MIN + INT_MIN + k * INT_MIN) % 60 ))
  mins+="$m "
done
PING_CRON="$(echo $mins | tr ' ' '\n' | sort -n | paste -sd, -) * * * *"

# Expiry one-shot cron: expiry time as "M H DoM Mon *"
if date -d "@$EXPIRES" '+%M' >/dev/null 2>&1; then
  read -r eM eH eD eMo <<< "$(date -d "@$EXPIRES" '+%M %H %d %m')"
  END_LOCAL=$(date -d "@$EXPIRES" '+%H:%M')
else
  read -r eM eH eD eMo <<< "$(date -r "$EXPIRES" '+%M %H %d %m')"
  END_LOCAL=$(date -r "$EXPIRES" '+%H:%M')
fi
EXPIRY_CRON="$((10#$eM)) $((10#$eH)) $((10#$eD)) $((10#$eMo)) *"

cat > "$STATE" <<EOF
armed_at=$NOW
expires=$EXPIRES
interval_min=$INT_MIN
ping_cron=$PING_CRON
expiry_cron=$EXPIRY_CRON
EOF

echo "$(date '+%F %T') armed dur=${DUR}s interval=${INT_MIN}m expires=${END_LOCAL} ping_cron=[$PING_CRON] expiry_cron=[$EXPIRY_CRON] (sid=$SID)" >> "$LOG"

echo "Away mode: until ${END_LOCAL} ($(fmt "$DUR")). Pinging every ${INT_MIN}m (about ${PINGS} times)${INT_NOTE}. Type any prompt when you're back to disarm"
echo "AWAY_PING_CRON=$PING_CRON"
echo "AWAY_EXPIRY_CRON=$EXPIRY_CRON"
