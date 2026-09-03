#!/usr/bin/env bash
# UserPromptSubmit hook。
#   - cron からの ping / 期限プロンプト ([away ping] / [away expired] に完全一致) はそのまま通す
#   - /away の入力自身は無視する (arm.sh 側で処理)
#   - それ以外 = ユーザーが戻った。state を消し、Claude に cron ジョブの削除を指示する
#   - state が無いのに [away ping] / [away expired] が来たら、取り残されたジョブなので削除を指示する
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$DIR/state"
LOG="$DIR/away.log"

INPUT=$(cat 2>/dev/null || true)
SID=$(printf '%s' "$INPUT" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -1)
[[ -n "$SID" ]] || exit 0
STATE="$STATE_DIR/away.$SID.state"
PROMPT=$(printf '%s' "$INPUT" | sed -n 's/.*"prompt" *: *"\([^"]*\)".*/\1/p' | head -1)

CLEANUP="CronList で prompt が [away ping] または [away expired] のジョブをすべて CronDelete する"

case "$PROMPT" in
  "[away ping]"|"[away expired]")   # cron からの prompt は必ずこの文字列ちょうど (完全一致で人間の入力と区別)
    if [[ -f "$STATE" ]]; then
      # 期限到来なら フラグを下ろす (ping ジョブの削除は Claude が行う)
      if [[ "$PROMPT" == "[away expired]" ]]; then
        rm -f "$STATE"
        echo "$(date '+%F %T') expired -> state removed (sid=$SID)" >> "$LOG"
      fi
      exit 0
    fi
    echo "$(date '+%F %T') stray away prompt without state -> cleanup (sid=$SID)" >> "$LOG"
    echo "[away] 離席モードは解除済み。${CLEANUP}。その後「ack」とだけ返す"
    exit 0;;
  /away*) exit 0;;
esac

[[ -f "$STATE" ]] || exit 0
rm -f "$STATE"
echo "$(date '+%F %T') user prompt -> state removed (auto disarm) (sid=$SID)" >> "$LOG"
echo "[away] ユーザーが戻ったので離席モード終了。まず ${CLEANUP}（削除については言及しない）。その後、通常どおり対応する"
exit 0
