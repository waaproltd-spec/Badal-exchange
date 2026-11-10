#!/usr/bin/env bash
# Sends the coding agent's progress or result to the Developer Bot (functions/dev-bot, route /report).
# The body is signed with HMAC-SHA256 (DEVBOT_REPORT_SECRET): the bot refuses anything else. Never fails the job.
#   devbot_report <progress|done|failed|noop> "message" ['{"extra":"json"}']
devbot_report() {
  local event="$1" message="${2:-}" extra="${3:-{\}}"
  [ -z "${REPORT_URL:-}" ] || [ -z "${REPORT_SECRET:-}" ] && return 0
  local body sig
  body=$(jq -nc --arg taskId "$TASK_ID" --arg event "$event" --arg message "$message" --argjson extra "$extra" \
    '{taskId: $taskId, event: $event, message: $message} + $extra' 2>/dev/null) || return 0
  sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$REPORT_SECRET" | sed 's/^.* //')
  curl -sS -m 30 -X POST "$REPORT_URL" -H 'content-type: application/json' -H "x-devbot-signature: sha256=$sig" --data "$body" >/dev/null || true
  return 0
}
