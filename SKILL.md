---
name: away
description: Away mode. Keeps the prompt cache warm by pinging the session periodically via in-session cron. Use only when the user explicitly types /away. Never invoke on your own.
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

Follow the output above.

If the output contains `AWAY_PING_CRON=` and `AWAY_EXPIRY_CRON=` lines (away mode starts):
1. Call `CronCreate` twice
   - cron: the `AWAY_PING_CRON` value, prompt: `[away ping]`, recurring: true
   - cron: the `AWAY_EXPIRY_CRON` value, prompt: `[away expired]`, recurring: false
2. Relay the first line of the output ("Away mode: …") to the user verbatim and stop. Say nothing else.

If the output contains an `AWAY_DISARM` line (disarm):
1. Run `CronList` and `CronDelete` every job whose prompt is `[away ping]` or `[away expired]`
2. Relay the first line of the output to the user verbatim and stop

Rules from then on:
- Turn whose prompt is `[away ping]`: reply with exactly "ack". No reasoning, no tools
- Turn whose prompt is `[away expired]`: run `CronList` and `CronDelete` every job whose prompt is `[away ping]` or `[away expired]` (a fired one-shot job still appears in the list, so delete this job itself too), then reply with exactly "Away mode ended"
- Turn where the hook says `[away] The user is back…`: follow it, delete the `[away ping]` / `[away expired]` jobs with `CronList` and `CronDelete`, then handle the user's input as usual. Do not mention away mode
