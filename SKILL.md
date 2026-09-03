---
name: away
description: 離席モード。セッション内 cron で定期的に ping してプロンプトキャッシュを延命する。ユーザーが明示的に /away と打ったときだけ使う。自発的に呼び出さない。
argument-hint: "[duration, default 3h] | off"
disable-model-invocation: true
allowed-tools: Bash(bash "${CLAUDE_SKILL_DIR}/arm.sh" *) CronCreate CronDelete CronList
hooks:
  UserPromptSubmit:
    - hooks:
        - type: command
          command: "bash \"${CLAUDE_PLUGIN_ROOT}/prompt.sh\""
          timeout: 10
---
!`bash "${CLAUDE_SKILL_DIR}/arm.sh" "$ARGUMENTS"`

上の出力に従って動く。

`AWAY_PING_CRON=` と `AWAY_EXPIRY_CRON=` の行がある場合（離席モード開始）:
1. `CronCreate` を 2 回呼ぶ
   - cron: `AWAY_PING_CRON` の値、prompt: `[away ping]`、recurring: true
   - cron: `AWAY_EXPIRY_CRON` の値、prompt: `[away expired]`、recurring: false
2. 出力の 1 行目（「離席モード: …」）をそのままユーザーに伝えて停止。他には何も言わない

`AWAY_DISARM` の行がある場合（解除）:
1. `CronList` で prompt が `[away ping]` または `[away expired]` のジョブをすべて `CronDelete`
2. 出力の 1 行目をそのままユーザーに伝えて停止

以後のルール:
- prompt が `[away ping]` のターン: 「ack」とだけ返す。考察なし、ツール不使用
- prompt が `[away expired]` のターン: `CronList` で prompt が `[away ping]` および `[away expired]` のジョブをすべて `CronDelete` し（発火済みの one-shot も一覧に残るので自分自身も消す）、「離席モード終了」とだけ返す
- hook から `[away] ユーザーが戻った…` の指示が来たターン: 指示どおり `CronList` と `CronDelete` で `[away ping]` / `[away expired]` のジョブを消し、その後はユーザーの入力に通常どおり対応する。離席モードには言及しない
