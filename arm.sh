#!/usr/bin/env bash
# /away の起動時にプロンプト展開 (`!` 行) で実行される。
# 状態ファイルを書き、Claude が CronCreate に渡す cron 式と、ユーザー向けの案内文を出す。
# 使い方: arm.sh "<duration>"
#   duration: 90m / 3h / 2h30m  (省略時 3h、上限 12h)
#   off | stop | cancel: 解除
# ping の間隔は 30 分固定 (cron の分リストで表せる最長で、キャッシュ TTL 1h に対して余裕がある)。
# 動作確認用に第 2 引数で短くできる (10/12/15/20 分に切り下げ)。README には書かない。
# 状態ファイルはセッション単位: <skill dir>/state/away.<session_id>.state
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$DIR/state"
LOG="$DIR/away.log"
SID="${CLAUDE_CODE_SESSION_ID:-}"
HARD_CAP_SEC=$((12 * 3600))

if [[ -z "$SID" ]]; then
  echo "CLAUDE_CODE_SESSION_ID が取れないため離席モードに入れない"
  exit 0
fi
STATE="$STATE_DIR/away.$SID.state"
mkdir -p "$STATE_DIR"
# 孤児 state の掃除: 12h 以上更新が無ければ死んでいる
find "$STATE_DIR" -name 'away.*.state' -mmin +720 -delete 2>/dev/null

LOG_KEEP=500
if [[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > LOG_KEEP )); then
  tail -n "$LOG_KEEP" "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi

to_sec() {
  # "2h30m" "90m" "45s" "300" -> 秒
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

fmt() {  # 秒 -> "2h30m" 形式
  local s=$1 out=""
  (( s >= 3600 )) && { out+="$((s / 3600))h"; s=$((s % 3600)); }
  (( s >= 60 ))   && { out+="$((s / 60))m";   s=$((s % 60)); }
  if (( s > 0 )) || [[ -z "$out" ]]; then out+="${s}s"; fi
  echo "$out"
}

read -r DUR_ARG INT_ARG _ <<< "${1:-}"
DUR_ARG="${DUR_ARG:-3h}"
INT_ARG="${INT_ARG:-30m}"

# 解除。state を消し、Claude に cron ジョブの削除を指示する。引数エラー時も同様
disarm() {
  if [[ -f "$STATE" ]]; then
    rm -f "$STATE"
    echo "$(date '+%F %T') /away $1 -> state removed (disarm) (sid=$SID)" >> "$LOG"
    echo "離席モード解除"
  else
    echo "離席モードは動いていない"
  fi
  echo "AWAY_DISARM"
  exit 0
}
case "$DUR_ARG" in
  off|stop|cancel) disarm "$DUR_ARG";;
esac
DUR=$(to_sec "$DUR_ARG") || { echo "duration の形式が不正: $DUR_ARG (例: 90m, 3h, 2h30m)"; disarm "$DUR_ARG"; }
INT=$(to_sec "$INT_ARG") || { echo "interval の形式が不正: $INT_ARG"; disarm "$DUR_ARG $INT_ARG"; }
(( DUR > HARD_CAP_SEC )) && DUR=$HARD_CAP_SEC

# interval は cron で表現できる 60 の約数 (分) に切り下げ。上限 30 分 (キャッシュ TTL 1h に余裕を持たせる)
INT_MIN=$(( INT / 60 ))
PICKED=10
for c in 10 12 15 20 30; do (( INT_MIN >= c )) && PICKED=$c; done
INT_NOTE=""
(( INT_MIN != PICKED )) && INT_NOTE="（$(fmt "$INT") を ${PICKED}m に丸め）"
INT_MIN=$PICKED

NOW=$(date +%s)
EXPIRES=$((NOW + DUR))
(( DUR < INT_MIN * 60 )) && { echo "duration が interval より短い: $DUR_ARG < ${INT_MIN}m"; disarm "$DUR_ARG"; }
PINGS=$(( DUR / (INT_MIN * 60) ))

# ping 用 cron: 今から INT_MIN 分後を起点に、60 分を INT_MIN で割った分のリスト
NOW_MIN=$(( 10#$(date '+%M') ))
mins=""
for (( k = 0; k < 60 / INT_MIN; k++ )); do
  m=$(( (NOW_MIN + INT_MIN + k * INT_MIN) % 60 ))
  mins+="$m "
done
PING_CRON="$(echo $mins | tr ' ' '\n' | sort -n | paste -sd, -) * * * *"

# 期限用 one-shot cron: 期限時刻を "M H DoM Mon *" に
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

echo "離席モード: ${END_LOCAL} まで（$(fmt "$DUR")）。${INT_MIN}m ごとに ping（約 ${PINGS} 回）${INT_NOTE}。戻ったらそのままプロンプトを打てば解除"
echo "AWAY_PING_CRON=$PING_CRON"
echo "AWAY_EXPIRY_CRON=$EXPIRY_CRON"
