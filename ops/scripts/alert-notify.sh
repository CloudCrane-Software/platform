#!/usr/bin/env bash
# alert-notify.sh — single notification gateway for the ops alert system
# (batch D, alerting layer). All alert producers funnel through here so
# delivery behavior changes in exactly one place.
#
# Usage: alert-notify.sh <SEVERITY> <message>
#   SEVERITY : CRITICAL | WARNING (anything else is passed through verbatim)
#   message  : single-line text (newlines are flattened)
#
# Delivery is controlled by ALERT_WEBHOOK_URL in ops/compose/.env:
#   set (non-empty) -> POST {"text":"[SEVERITY] message"} to the webhook
#   empty / absent  -> log-only: append to /var/log/company-alerts.log
#
# Never blocks the caller longer than ~10s (curl --max-time). Token-free:
# this script handles no credentials, only the optional webhook URL.
set -uo pipefail

SEVERITY="${1:-WARNING}"
MESSAGE="${2:-no message}"
LOG_FILE="/var/log/company-alerts.log"
ENV_FILE="/opt/company/platform/ops/compose/.env"

# URL from .env; tolerate optional surrounding quotes; empty -> log-only.
URL="$(grep -E '^ALERT_WEBHOOK_URL=' "$ENV_FILE" 2>/dev/null \
  | tail -1 | cut -d= -f2- | tr -d '"' | tr -d '[:space:]')"

# Flatten newlines/tabs and escape for a JSON string literal.
esc() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' \
    | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/ /g'
}
PAYLOAD="$(printf '{"text":"[%s] %s"}' "$(esc "$SEVERITY")" "$(esc "$MESSAGE")")"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LINE="[$TS] [$SEVERITY] $MESSAGE"
touch "$LOG_FILE" 2>/dev/null || true

if [ -n "$URL" ]; then
  if curl -sS --max-time 10 -X POST "$URL" \
      -H 'Content-Type: application/json' -d "$PAYLOAD" >/dev/null 2>&1; then
    echo "$LINE delivered=webhook" >> "$LOG_FILE"
    echo "$LINE (webhook POST ok)"
  else
    # Webhook broken: still persist to the log so the event is not lost.
    echo "$LINE delivered=none webhook_error=fallback-to-log" >> "$LOG_FILE"
    echo "$LINE (webhook POST FAILED — logged only)"
  fi
else
  echo "$LINE delivered=log ALERT_WEBHOOK_URL_empty" >> "$LOG_FILE"
  echo "$LINE (log-only; ALERT_WEBHOOK_URL empty)"
fi
exit 0
