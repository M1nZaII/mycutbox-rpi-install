#!/usr/bin/env bash
# Test Slack Incoming Webhook (same style as mycutbox-ota-update).
#
# Loads SLACK_WEBHOOK_URL from (first match wins after optional override):
#   1) First argument, if it looks like an https URL
#   2) Environment variable SLACK_WEBHOOK_URL (already exported)
#   3) File ENV_FILE (default: <pi>/.env next to agent — see below)
#
# Default .env path (rp3 layout):
#   Script at /home/rp3/.pi/agent/scripts/this-file.sh  ->  /home/rp3/.pi/.env
#   Script at /home/rp3/.pi/agent/this-file.sh           ->  /home/rp3/.pi/.env
# If that file is missing, falls back to $HOME/.pi/.env
#
# Usage:
#   bash scripts/slack-webhook-test.sh
#
#   ENV_FILE=/path/to/.env bash scripts/slack-webhook-test.sh
#   bash scripts/slack-webhook-test.sh 'https://hooks.slack.com/services/...'

set -euo pipefail

# Resolve <user>/.pi/.env: on device, repo is .../.pi/agent (clone) and .env is .../.pi/.env
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_parent="$(dirname "$_script_dir")"
if [ "$(basename "$_script_dir")" = "scripts" ] && [ "$(basename "$_parent")" = "agent" ]; then
  _pi_dir="$(cd "$_script_dir/../.." && pwd)"
elif [ "$(basename "$_script_dir")" = "agent" ]; then
  _pi_dir="$(cd "$_script_dir/.." && pwd)"
else
  _pi_dir="${HOME}/.pi"
fi
_default_env="${_pi_dir}/.env"
if [ -z "${ENV_FILE:-}" ]; then
  if [ -f "$_default_env" ]; then
    ENV_FILE="$_default_env"
  elif [ -f "${HOME}/pi/.env" ]; then
    ENV_FILE="${HOME}/pi/.env"
  else
    ENV_FILE="$_default_env"
  fi
fi
unset _script_dir _parent _pi_dir _default_env

load_dotenv() {
  local f="$1"
  [ -f "$f" ] || return 1
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
}

WEBHOOK=""
if [ -n "${1:-}" ] && [[ "$1" =~ ^https:// ]]; then
  WEBHOOK="$1"
elif [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
  WEBHOOK="$SLACK_WEBHOOK_URL"
elif [ -f "$ENV_FILE" ]; then
  load_dotenv "$ENV_FILE"
  WEBHOOK="${SLACK_WEBHOOK_URL:-}"
fi

if [ -z "$WEBHOOK" ]; then
  echo "SLACK_WEBHOOK_URL not found. Set it in ${ENV_FILE} or export SLACK_WEBHOOK_URL, or pass the webhook URL as the first argument." >&2
  exit 1
fi

SERIAL="test"
if [ -f /sys/firmware/devicetree/base/serial-number ]; then
  SERIAL="$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null | tr -d '\n' | head -c 80 || echo test)"
fi
[ -n "$SERIAL" ] || SERIAL="unknown"

HOST="$(hostname 2>/dev/null || echo unknown-host)"
TS="$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"
LEVEL="TEST"
TRIGGER="manual"
BODY="$(printf 'Slack webhook test *OK*\n• Host: `%s`\n• Env: `%s`' "$HOST" "$ENV_FILE")"

echo "Posting to Slack..."
if command -v python3 >/dev/null 2>&1; then
  PAYLOAD="$(LEVEL="$LEVEL" BODY="$BODY" SERIAL="$SERIAL" TRIGGER="$TRIGGER" TS="$TS" python3 - <<'PY'
import json, os
level = os.environ["LEVEL"]
body = os.environ["BODY"]
serial = os.environ["SERIAL"]
trigger = os.environ["TRIGGER"]
ts = os.environ["TS"]
meta = (
    f"*Level:* {level}\n"
    f"*Serial:* `{serial}`\n"
    f"*Trigger:* {trigger}\n"
    f"*Time (KST):* {ts}\n\n"
    f"---\n{body}"
)
payload = {
    "text": f"MyCutBox OTA [{level}] serial={serial}",
    "blocks": [
        {"type": "header", "text": {"type": "plain_text", "text": "MyCutBox OTA", "emoji": True}},
        {"type": "section", "text": {"type": "mrkdwn", "text": meta}},
    ],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)"
  curl -sS -X POST -H 'Content-Type: application/json' --data-binary "$PAYLOAD" "$WEBHOOK"
else
  ESC="$(printf '%s\n\n%s' "MyCutBox OTA [${LEVEL}]  serial: ${SERIAL}  trigger: ${TRIGGER}  time (KST): ${TS}" "${BODY}")"
  ESC="${ESC//\\/\\\\}"
  ESC="${ESC//\"/\\\"}"
  ESC="${ESC//$'\n'/\\n}"
  ESC="${ESC//$'\r'/\\r}"
  curl -sS -X POST -H 'Content-Type: application/json' --data "{\"text\":\"${ESC}\"}" "$WEBHOOK"
fi
echo ""
echo "Done. Check your Slack channel."
