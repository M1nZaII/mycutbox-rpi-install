#!/usr/bin/env bash
set -euo pipefail

# Ensure a DNP dye-sub printer (DS-RX1 or DS620) is available as a stable CUPS
# queue name. The app prints to $PRINTER_NAME (env, default "RX1"; "DS620" for
# that model). This script keeps that logical queue pointed at whichever
# supported USB device is currently connected — the model is auto-detected
# from the device itself, not from the queue name.

QUEUE_NAME="${QUEUE_NAME:-${PRINTER_NAME:-RX1}}"
PRINTER_MATCH="${PRINTER_MATCH:-Dai%20Nippon%20Printing/DS-RX1}"
MODEL_NAME="${MODEL_NAME:-}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-30}"

log() {
  printf '[ensure-rx1-cups] %s\n' "$*"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Run as root, for example: sudo $0"
    exit 1
  fi
}

wait_for_cups() {
  local waited=0
  until lpstat -r >/dev/null 2>&1; do
    if [ "$waited" -ge "$MAX_WAIT_SECONDS" ]; then
      log "CUPS is not responding after ${MAX_WAIT_SECONDS}s"
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

find_device_uri() {
  lpinfo -v | awk '
    $1 == "direct" && tolower($2) ~ /usb:\/\// && tolower($2) ~ /(ds-rx1|dsrx1|dnp|citizen)/ {
      print $2
      exit
    }
  '
}

find_model_name() {
  if [ -n "$MODEL_NAME" ]; then
    printf '%s\n' "$MODEL_NAME"
    return
  fi

  # 모델 키워드는 큐 이름이 아니라 실제로 꽂힌 장치의 URI에서 뽑는다 — 큐 이름 문자열
  # 매칭에 의존하면 향후 네이밍이 바뀔 때 같이 깨지므로, 장치 자체를 근거로 삼는다.
  local device_uri="$1"
  local keyword=""
  case "$(printf '%s' "$device_uri" | tr 'A-Z' 'a-z')" in
    *ds-rx1*|*dsrx1*) keyword="rx1" ;;
    *ds620*|*ds-620*) keyword="ds620" ;;
  esac
  if [ -z "$keyword" ]; then
    log "Cannot infer printer model from device URI ($device_uri); pass MODEL_NAME='<model>' explicitly"
    return
  fi

  lpinfo -m | awk -v kw="$keyword" '
    BEGIN { IGNORECASE = 1 }
    $0 ~ /gutenprint/ && $0 ~ kw && $0 ~ /expert/ {
      print $1
      exit
    }
    $0 ~ /gutenprint/ && $0 ~ kw {
      candidate = $1
    }
    END {
      if (candidate != "") print candidate
    }
  '
}

current_queue_uri() {
  lpstat -v "$QUEUE_NAME" 2>/dev/null | sed -E 's/^device for [^:]+: //'
}

require_root
wait_for_cups

DEVICE_URI="$(find_device_uri)"
if [ -z "$DEVICE_URI" ]; then
  log "No matching DNP/Citizen (RX1/DS620) USB printer found in lpinfo -v"
  log "Check: sudo lpinfo -v | grep -i usb"
  exit 2
fi

MODEL="$(find_model_name "$DEVICE_URI")"
if [ -z "$MODEL" ]; then
  log "No matching Gutenprint model found in lpinfo -m for device $DEVICE_URI"
  log "Install the Gutenprint driver for this model, or run with MODEL_NAME='<model>'"
  exit 3
fi

CURRENT_URI="$(current_queue_uri || true)"
if [ "$CURRENT_URI" = "$DEVICE_URI" ]; then
  log "$QUEUE_NAME already points to $DEVICE_URI"
else
  log "Configuring $QUEUE_NAME -> $DEVICE_URI using model $MODEL"
  lpadmin -p "$QUEUE_NAME" -E -v "$DEVICE_URI" -m "$MODEL"
fi

lpadmin -p "$QUEUE_NAME" \
  -o printer-is-shared=false \
  -o PageSize-default=w288h432 \
  -o StpiShrinkOutput-default=Shrink \
  -o Resolution-default=300x600dpi
lpoptions -d "$QUEUE_NAME"
cupsenable "$QUEUE_NAME" >/dev/null 2>&1 || true
cupsaccept "$QUEUE_NAME" >/dev/null 2>&1 || true

log "Ready: $(lpstat -v "$QUEUE_NAME")"
