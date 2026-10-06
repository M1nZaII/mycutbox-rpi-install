#!/usr/bin/env bash
set -euo pipefail

# RX1/DS620 CUPS 큐 워치독 (root, systemd timer ~15s 주기).
# 큐에 미완료 job이 있을 때만 동작한다:
#   - 장치 URI == 큐 URI 이고 프린터가 idle  -> 최근(MAX_JOB_AGE_SEC 이내) job 자동 resume
#   - 장치 serial이 NONE_UNKNOWN(USB 불안정) -> 큐는 건드리지 않고, idle이면 USB soft re-enumerate (최대 3회)
# 오래된 job은 건드리지 않는다. re-enumerate 끄기: RX1_WATCHDOG_REENUM=0 (/etc/mycutbox/env)

QUEUE_NAME="${QUEUE_NAME:-${PRINTER_NAME:-RX1}}"
MAX_JOB_AGE_SEC="${MAX_JOB_AGE_SEC:-1800}"
REENUM_ENABLED="${RX1_WATCHDOG_REENUM:-1}"
REENUM_MAX="${RX1_WATCHDOG_REENUM_MAX:-3}"
REENUM_GAP_SEC="${RX1_WATCHDOG_REENUM_GAP_SEC:-60}"
STATE_DIR=/run/rx1-usb-watchdog
ENSURE_SCRIPT="$(dirname "$(readlink -f "$0")")/ensure-rx1-cups.sh"

export LC_ALL=C
mkdir -p "$STATE_DIR"

log() { printf '[rx1-usb-watchdog] %s\n' "$*"; }

# 15초마다 같은 줄이 저널을 채우지 않도록, 직전과 같은 상태 메시지는 한 번만 남긴다.
note() {
  [ "$(cat "$STATE_DIR/last" 2>/dev/null || true)" = "$*" ] && return 0
  printf '%s' "$*" > "$STATE_DIR/last"
  log "$*"
}

uri_serial() { local s="${1##*/}"; printf '%s' "${s%%\?*}"; }

# lpinfo -v 전체는 모든 백엔드(dnssd 등)를 훑어 ~4초 걸려 타이머 주기가 밀린다. USB 스킴만 먼저 조회하고,
# 못 찾을 때만(백엔드 이름이 다른 Pi 대비) 전체 조회로 폴백한다.
find_device_uri() {
  local out
  out="$(lpinfo --include-schemes usb,gutenprint53+usb -v 2>/dev/null | awk '
    $1 == "direct" && tolower($2) ~ /usb:\/\// && tolower($2) ~ /(ds-rx1|dsrx1|dnp|citizen)/ { print $2; exit }
  ')"
  [ -n "$out" ] || out="$(lpinfo -v | awk '
    $1 == "direct" && tolower($2) ~ /usb:\/\// && tolower($2) ~ /(ds-rx1|dsrx1|dnp|citizen)/ { print $2; exit }
  ')"
  printf '%s' "$out"
}

# 1343:0005 (RX1), 1452:8b01 (DS620) — 장치 노드의 authorized를 0->1로 토글해 재열거한다.
# ponytail: 효과 미검증(실기 확인 필요). 안 먹히면 RX1_WATCHDOG_REENUM=0 으로 끄고 프린터 전원 재투입.
reenumerate() {
  local d vp
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    vp="$(cat "$d/idVendor"):$(cat "$d/idProduct")"
    case "$vp" in 1343:0005|1452:8b01) ;; *) continue ;; esac
    log "re-enumerate $vp at $(basename "$d")"
    echo 0 > "$d/authorized"
    sleep 2
    echo 1 > "$d/authorized"
    return 0
  done
  log "re-enumerate: DNP USB device not found in sysfs"
  return 1
}

JOBS="$(lpstat -W not-completed -o "$QUEUE_NAME" 2>/dev/null || true)"
if [ -z "$JOBS" ]; then
  rm -f "$STATE_DIR/last" "$STATE_DIR/tries" "$STATE_DIR/stamp"
  exit 0
fi

# 인쇄 중이면 건드리지 않는다.
if lpstat -p "$QUEUE_NAME" 2>/dev/null | grep -q 'now printing'; then
  exit 0
fi

DEVICE_URI="$(find_device_uri || true)"
if [ -z "$DEVICE_URI" ]; then
  note "jobs pending but no DNP USB device in lpinfo (printer off/unplugged?)"
  exit 0
fi

SERIAL="$(uri_serial "$DEVICE_URI")"
if [ "$SERIAL" = "NONE_UNKNOWN" ]; then
  tries="$(cat "$STATE_DIR/tries" 2>/dev/null || echo 0)"
  if [ "$REENUM_ENABLED" != "1" ]; then
    note "serial unreadable (NONE_UNKNOWN), re-enumerate disabled — power-cycle the printer"
  elif [ "$tries" -ge "$REENUM_MAX" ]; then
    note "serial still NONE_UNKNOWN after $tries re-enumerations — power-cycle the printer (check PSU/USB cable)"
  elif [ -f "$STATE_DIR/stamp" ] && [ $(( $(date +%s) - $(stat -c %Y "$STATE_DIR/stamp") )) -lt "$REENUM_GAP_SEC" ]; then
    :
  else
    tries=$((tries + 1))
    printf '%s' "$tries" > "$STATE_DIR/tries"
    touch "$STATE_DIR/stamp"
    log "serial unreadable (NONE_UNKNOWN), attempt $tries/$REENUM_MAX"
    reenumerate || true
  fi
  exit 0
fi

rm -f "$STATE_DIR/tries" "$STATE_DIR/stamp"

QUEUE_URI="$(lpstat -v "$QUEUE_NAME" 2>/dev/null | sed -E 's/^device for [^:]+: //')"
if [ "$QUEUE_URI" != "$DEVICE_URI" ]; then
  note "queue URI ($QUEUE_URI) != device URI ($DEVICE_URI), running ensure-rx1-cups"
  "$ENSURE_SCRIPT" || true
fi

cupsenable "$QUEUE_NAME" >/dev/null 2>&1 || true

now="$(date +%s)"
printf '%s\n' "$JOBS" | while read -r jobid _ _ datestr; do
  [ -n "$jobid" ] || continue
  # "Mon 05 Oct 2026 16:28:48 KST" — GNU date는 KST 약어를 못 읽으므로 로컬시각으로 해석
  ts="$(date -d "${datestr% *}" +%s 2>/dev/null || echo 0)"
  age=$((now - ts))
  if [ "$ts" -eq 0 ] || [ "$age" -gt "$MAX_JOB_AGE_SEC" ]; then
    note "skip $jobid (age ${age}s > ${MAX_JOB_AGE_SEC}s or unparsable)"
    continue
  fi
  log "resume $jobid (age ${age}s)"
  lp -i "${jobid##*-}" -H resume >/dev/null 2>&1 || true
done
