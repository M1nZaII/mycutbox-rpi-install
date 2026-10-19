#!/usr/bin/env bash
# Rotate /var/log/printer_resume.log (weekly timer).

set -euo pipefail

LOG_FILE="/var/log/printer_resume.log"

if [ -f "$LOG_FILE" ]; then
  TS="$(date '+%Y%m%d-%H%M%S')"
  ARCHIVE="${LOG_FILE}.${TS}"
  mv "$LOG_FILE" "$ARCHIVE"
fi

: > "$LOG_FILE"
chmod 664 "$LOG_FILE"
chown root:adm "$LOG_FILE" 2>/dev/null || true
