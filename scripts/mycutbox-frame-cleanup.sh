#!/usr/bin/env bash
# Remove stale frame PNG cache files (composite-print / usbPrint).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="${MY_CUTBOX_FRAME_CACHE_DIR:-$PI_DIR/cache/frames}"
MAX_DAYS="${MY_CUTBOX_FRAME_MAX_DAYS:-30}"

if [ ! -d "$CACHE_DIR" ]; then
  exit 0
fi

find "$CACHE_DIR" \
  -type f \
  -mtime "+$MAX_DAYS" \
  -name "*.png" \
  -print \
  -delete
