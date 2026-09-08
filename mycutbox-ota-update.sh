#!/usr/bin/env bash
set -Eeuo pipefail

# 이 파일만 바뀔 때 올려 주세요 (컨테이너 AGENT_VERSION 과 별개).
OTA_UPDATE_SCRIPT_VERSION="1.2.4.8"
SELF_REEXEC_ARGS=("$@")

TRIGGER="manual"
case "${1:-}" in
  --auto)
    TRIGGER="auto"
    shift || true
    ;;
  --boot)
    TRIGGER="boot"
    shift || true
    ;;
  --network-online)
    TRIGGER="network-online"
    shift || true
    ;;
  --network-down)
    TRIGGER="network-down"
    shift || true
    ;;
  --fleet)
    TRIGGER="fleet"
    shift || true
    ;;
esac

PRINTER_NAME="${PRINTER_NAME:-RX1}"
USB_PRINT_SERVICE="${USB_PRINT_SERVICE:-mycutbox-usb-print.service}"
CONNECT_WIFI_SERVICE="${CONNECT_WIFI_SERVICE:-mycutbox-connect-wifi.service}"
COMPOSITE_SERVICE="${COMPOSITE_SERVICE:-composite-print}"

# $HOME/pi 는 파일탐색기에서 바로 보여서 $HOME/.pi(숨김 폴더)로 옮긴다. 이미 설치된 기기는
# 예전 $HOME/pi 로 돌고 있으므로, PROJECT_DIR 를 명시적으로 override 하지 않은 한 여기서 감지해
# 1회 마이그레이션한다. 서비스가 그 경로를 물고 있는 채로 mv 하면 위험하니 잠깐 멈췄다 옮기고
# 다시 올린다. 실패하면 이번 실행은 예전 경로로 계속 진행하고 다음 실행에서 재시도한다(서비스가
# 죽은 채로 남지 않도록).
migrate_legacy_project_dir() {
  # Called from a `$(...)` command substitution (resolve_project_dir) — stdout must carry
  # ONLY the final path, so every log line here goes to stderr, not stdout.
  local old="$1" new="$2"
  echo "[OTA] One-time migration: ${old} -> ${new} (hide from casual file-manager browsing)" >&2
  systemctl --user stop "$USB_PRINT_SERVICE" >/dev/null 2>&1 || true
  systemctl --user stop "$CONNECT_WIFI_SERVICE" >/dev/null 2>&1 || true
  (cd "$old" && docker compose stop "$COMPOSITE_SERVICE" >/dev/null 2>&1) || true
  if mv "$old" "$new" 2>/dev/null; then
    echo "[OTA] Migration OK: ${new}" >&2
    # Already-installed unit files (usb-print, connect-wifi, fleet-heartbeat, fleet-watch)
    # have the old WorkingDirectory= baked in from install time; sync_ota_user_units() only
    # regenerates the OTA/fleet timers, not these, and only on an actual update pass. Patch
    # them in place now so services don't restart-loop on CHDIR until the next update.
    local unit_dir="${HOME}/.config/systemd/user"
    if [ -d "$unit_dir" ] && grep -rlq "$old" "$unit_dir"/*.service 2>/dev/null; then
      sed -i "s#${old}#${new}#g" "$unit_dir"/*.service 2>/dev/null || true
      systemctl --user daemon-reload 2>/dev/null || true
    fi
    systemctl --user start "$USB_PRINT_SERVICE" >/dev/null 2>&1 || true
    systemctl --user start "$CONNECT_WIFI_SERVICE" >/dev/null 2>&1 || true
    # Docker 는 마운트 소스 파일이 없으면 그 자리에 빈 디렉터리를 자동 생성해 마운트가 깨진다
    # (컨테이너가 Firestore 키를 못 읽음). 잘못 생긴 디렉터리면 제거해 올바른 파일이 마운트되게 한다.
    [ -d "${new}/data/mycutbox110.json" ] && rmdir "${new}/data/mycutbox110.json" 2>/dev/null || true
    (cd "$new" && docker compose up -d "$COMPOSITE_SERVICE" >/dev/null 2>&1) || true
    return 0
  fi
  echo "[OTA] Migration failed (mv ${old} -> ${new}); staying on ${old} this run, will retry next time." >&2
  systemctl --user start "$USB_PRINT_SERVICE" >/dev/null 2>&1 || true
  systemctl --user start "$CONNECT_WIFI_SERVICE" >/dev/null 2>&1 || true
  [ -d "${old}/data/mycutbox110.json" ] && rmdir "${old}/data/mycutbox110.json" 2>/dev/null || true
  (cd "$old" && docker compose up -d "$COMPOSITE_SERVICE" >/dev/null 2>&1) || true
  return 1
}

resolve_project_dir() {
  if [ -n "${PROJECT_DIR:-}" ]; then
    printf '%s' "$PROJECT_DIR"
    return
  fi
  local new="$HOME/.pi" old="$HOME/pi"
  if [ -d "$new" ]; then
    printf '%s' "$new"
    return
  fi
  if [ -d "$old" ]; then
    if migrate_legacy_project_dir "$old" "$new"; then
      printf '%s' "$new"
    else
      printf '%s' "$old"
    fi
    return
  fi
  printf '%s' "$new"
}

PROJECT_DIR="$(resolve_project_dir)"
COMPOSE_FILE="${COMPOSE_FILE:-$PROJECT_DIR/docker-compose.yml}"
AGENT_DIR="${AGENT_DIR:-$PROJECT_DIR/agent}"
GVFS_BASE="${GVFS_BASE:-/run/user/$(id -u)/gvfs}"
OTA_STATE_DIR="${OTA_STATE_DIR:-$PROJECT_DIR/.ota-state}"
FLEET_STATE_REVISION_FILE="${FLEET_STATE_REVISION_FILE:-$OTA_STATE_DIR/fleet-revision}"
NETWORK_ONLINE_DEBOUNCE_SECONDS="${NETWORK_ONLINE_DEBOUNCE_SECONDS:-1800}"
NETWORK_ONLINE_DEBOUNCE_FILE="${NETWORK_ONLINE_DEBOUNCE_FILE:-$OTA_STATE_DIR/network-online.last}"
NETWORK_OFFLINE_RETRY_COUNT="${NETWORK_OFFLINE_RETRY_COUNT:-6}"
NETWORK_OFFLINE_RETRY_DELAY_SECONDS="${NETWORK_OFFLINE_RETRY_DELAY_SECONDS:-10}"
NETWORK_OFFLINE_ALERT_COOLDOWN_SECONDS="${NETWORK_OFFLINE_ALERT_COOLDOWN_SECONDS:-900}"
NETWORK_OFFLINE_ALERT_FILE="${NETWORK_OFFLINE_ALERT_FILE:-$OTA_STATE_DIR/network-offline.last}"
NETWORK_OFFLINE_ACTIVE_FILE="${NETWORK_OFFLINE_ACTIVE_FILE:-$OTA_STATE_DIR/network-offline.active}"
NETWORK_CHECK_TARGETS="${NETWORK_CHECK_TARGETS:-1.1.1.1 8.8.8.8}"

# Set by fleet_fetch_into_vars / resolve_target_agent_tag (global for Slack + ack).
FLEET_DESIRED_TAG=""
FLEET_REVISION="0"
FLEET_REASON=""
FLEET_TAG_SOURCE=""
PILOT_ACTIVE="0"
PILOT_BRANCH="pilot"
AGENT_GIT_BRANCH="${AGENT_GIT_BRANCH:-main}"
OTA_TAG_SOURCE="AGENT_VERSION"
OTA_TARGET_TAG=""

# 토큰리스 OTA: 호스트 파일(install.sh·ota-update.sh·compose·fleet-*.mjs·usbPrint.cjs)을
# 공개 설치 repo에서 받는다. 런타임(print.mjs 등)은 공개 GHCR 이미지로만 배포되므로 여기 없음.
# 공개 repo/이미지 준비 전이거나 다운로드 실패 시엔 기존 private git pull 로 자동 폴백한다.
INSTALLER_REPO="${INSTALLER_REPO:-https://github.com/m1nzaii/mycutbox-rpi-install}"
INSTALLER_BRANCH="${INSTALLER_BRANCH:-main}"

# 보안 env 파일. OTA 는 rp3 (systemctl --user) 로 돌면서 AGENT_IMAGE_TAG 를 읽고 "쓰기"까지 해야
# 한다. 그런데 install.sh 가 만드는 /etc/mycutbox/env 는 root:600 이라, 유저 OTA 가 읽지도 쓰지도
# 못한다(→ read_env_agent_tag 가 빈 값 → fleet skip 실패, 매시간 재적용). 게다가 이 파일이 아예 없고
# docker compose 는 ~/.pi/.env 를 쓰는 Pi 도 있다. 그래서 "현재 프로세스가 읽을 수 있는" env 를
# 우선 선택한다: /etc/mycutbox/env 가 읽히면 그대로, 아니면 유저 소유 ${PROJECT_DIR}/.env 로 폴백.
resolve_env_file() {
  # 명시적으로 지정됐으면 존중
  if [ -n "${ENV_FILE:-}" ]; then printf '%s' "$ENV_FILE"; return; fi
  local sys="/etc/mycutbox/env" usr="${PROJECT_DIR}/.env"
  if [ -r "$sys" ]; then printf '%s' "$sys"; return; fi   # 읽을 수 있을 때만 시스템 env 사용
  if [ -f "$usr" ]; then printf '%s' "$usr"; return; fi     # 유저 소유 env 폴백 (rp3 읽기/쓰기 가능)
  printf '%s' "$sys"                                         # 둘 다 없으면 레거시 경로 유지
}
ENV_FILE="$(resolve_env_file)"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
# Optional: same Slack app에 Bot Token + 채널 ID를 넣으면 chat.postMessage로 보내 스레드(ts)가 동작합니다.
# Incoming Webhook만 쓰면 응답에 ts가 없어 스레드 답글을 붙일 수 없습니다 (Slack 문서).
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_CHANNEL_ID="${SLACK_CHANNEL_ID:-}"

LOCK_FILE="${LOCK_FILE:-/tmp/mycutbox-ota.lock}"

# Must be global (not `local`): nested cleanup_and_restart + trap must see these under `set -u`.
STOPPED_USB=0
STOPPED_COMPOSITE=0

# First Slack message ts for this run; follow-ups post in thread (no repeated metadata).
SLACK_OTA_THREAD_TS="${SLACK_OTA_THREAD_TS:-}"
OTA_REEXEC_SKIP_START_NOTIFY="${OTA_REEXEC_SKIP_START_NOTIFY:-0}"

log() { echo "[OTA] $*"; }

is_aux_trigger() {
  [ "$TRIGGER" = "boot" ] || [ "$TRIGGER" = "network-online" ] || [ "$TRIGGER" = "network-down" ] || [ "$TRIGGER" = "fleet" ]
}

should_notify_aux_start_and_skip() {
  [ "$OTA_REEXEC_SKIP_START_NOTIFY" = "1" ] && return 1
  ! is_aux_trigger
}

# AGENT_IMAGE_TAG from secure env file (file wins over stale shell after sed).
read_env_agent_tag() {
  local f="${ENV_FILE}"
  local v=""
  if [ -f "$f" ]; then
    v="$(grep -m1 '^AGENT_IMAGE_TAG=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  fi
  if [ -z "$v" ]; then
    v="${AGENT_IMAGE_TAG:-}"
  fi
  printf '%s' "$v"
}

read_repo_agent_version_tag() {
  local f="${AGENT_DIR}/AGENT_VERSION"
  if [ -f "$f" ]; then
    tr -d ' \n\r\t' < "$f"
  fi
}

resolve_firestore_credentials() {
  local c=""
  for c in \
    "${GOOGLE_APPLICATION_CREDENTIALS:-}" \
    "${FLEET_OTA_CREDENTIALS:-}" \
    "/etc/mycutbox/secrets/mycutbox110.json" \
    "${PROJECT_DIR}/data/mycutbox110.json" \
    "${PROJECT_DIR}/mycutbox110.json"; do
    [ -n "$c" ] && [ -f "$c" ] && { chmod 600 "$c" 2>/dev/null || true; printf '%s' "$c"; return 0; }
  done
  return 1
}

fleet_fetch_into_vars() {
  local helper="${AGENT_DIR}/scripts/fleet-ota-fetch.mjs"
  local cred out line key val
  FLEET_DESIRED_TAG=""
  FLEET_REVISION="0"
  FLEET_REASON=""
  FLEET_TAG_SOURCE=""
  PILOT_ACTIVE="0"
  PILOT_BRANCH="pilot"

  [ -f "$helper" ] || return 1
  cred="$(resolve_firestore_credentials)" || return 1

  set +e
  out="$(cd "$AGENT_DIR" && GOOGLE_APPLICATION_CREDENTIALS="$cred" node "$helper" read 2>/dev/null)"
  local e=$?
  set -e
  [ "$e" -eq 0 ] || return 1

  while IFS='=' read -r key val; do
    case "$key" in
      DESIRED_TAG) FLEET_DESIRED_TAG="$val" ;;
      REVISION) FLEET_REVISION="$val" ;;
      REASON) FLEET_REASON="$val" ;;
      TAG_SOURCE) FLEET_TAG_SOURCE="$val" ;;
      PILOT_ACTIVE) PILOT_ACTIVE="$val" ;;
      PILOT_BRANCH) PILOT_BRANCH="$val" ;;
    esac
  done <<< "$out"
  return 0
}

# 토큰리스 1순위: 공개 설치 repo(mycutbox-rpi-install)에서 호스트 파일을 tarball 로 받아 덮어쓴다.
# private 인증이 전혀 필요 없다. 성공하면 0, 실패(미준비/네트워크 등)하면 1 → 호출부가 폴백한다.
refresh_from_public_installer() {
  local branch tarball tmp
  if [ "${PILOT_ACTIVE:-0}" = "1" ]; then branch="${PILOT_BRANCH:-pilot}"; else branch="${INSTALLER_BRANCH:-main}"; fi
  tarball="${INSTALLER_REPO/github.com/codeload.github.com}/tar.gz/refs/heads/${branch}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/mycutbox-installer.XXXXXX")" || return 1

  log "Tokenless refresh: ${INSTALLER_REPO} (branch ${branch})"
  if ! curl -fsSL --retry 2 --retry-delay 2 "$tarball" | tar -xz -C "$tmp" --strip-components=1 2>/dev/null; then
    log "Public installer tarball fetch failed (${tarball}); will fall back to private git."
    rm -rf "$tmp"; return 1
  fi
  # 필수 파일이 있어야 신뢰 (repo 미준비 시 폴백)
  if [ ! -f "$tmp/mycutbox-ota-update.sh" ] || [ ! -f "$tmp/install.sh" ]; then
    log "Public installer bundle incomplete; falling back to private git."
    rm -rf "$tmp"; return 1
  fi

  mkdir -p "$AGENT_DIR/scripts"
  # 호스트에서 도는 파일만 골라 덮어쓴다 (print.mjs 등 런타임은 이미지가 담당).
  local f
  for f in mycutbox-ota-update.sh install.sh docker-compose.yml AGENT_VERSION usbPrint.cjs connectWifi.cjs package.json; do
    [ -f "$tmp/$f" ] && cp -f "$tmp/$f" "$AGENT_DIR/$f"
  done
  for f in "$tmp"/scripts/*.mjs "$tmp"/scripts/*.sh; do
    [ -e "$f" ] && cp -f "$f" "$AGENT_DIR/scripts/"
  done
  # Screen-lock assets (gtklock UI template + theme + launcher)
  if [ -d "$tmp/lock" ]; then
    mkdir -p "$AGENT_DIR/lock"
    cp -f "$tmp"/lock/* "$AGENT_DIR/lock/" 2>/dev/null || true
  fi
  rm -rf "$tmp"
  log "Tokenless refresh applied from public installer repo."
  return 0
}

# Apply staged screen-lock assets to their live locations (runs in the rp3 user
# context: PROJECT_DIR=$HOME/.pi). Fresh installs seed these via install.sh; this
# keeps the fleet's lock UI/theme/launcher current on every OTA. No root needed.
apply_lock_assets() {
  local src="$AGENT_DIR/lock"
  [ -d "$src" ] || return 0
  local gtk_cfg="$HOME/.config/gtklock"
  mkdir -p "$gtk_cfg"
  [ -f "$src/gtklock.ui.tmpl" ] && cp -f "$src/gtklock.ui.tmpl" "$gtk_cfg/gtklock.ui.tmpl"
  [ -f "$src/style.css" ]       && cp -f "$src/style.css"       "$gtk_cfg/style.css"
  if [ -f "$src/mycutbox-lock.sh" ]; then
    cp -f "$src/mycutbox-lock.sh" "$PROJECT_DIR/mycutbox-lock.sh"
    chmod +x "$PROJECT_DIR/mycutbox-lock.sh" 2>/dev/null || true
  fi
  log "Screen-lock assets refreshed (gtklock)."
}

update_agent_repo() {
  # 1순위: 토큰 없는 공개 경로. 실패하면 기존 private git 경로로 폴백(하위호환·안전망).
  if refresh_from_public_installer; then
    apply_lock_assets
    return 0
  fi
  update_agent_repo_private
  apply_lock_assets
}

# 폴백: 기존 private repo git pull (토큰/credential helper 필요). 공개 경로가 준비되면 거의 안 쓰임.
update_agent_repo_private() {
  local branch=""
  if [ "${PILOT_ACTIVE:-0}" = "1" ]; then
    branch="${PILOT_BRANCH:-pilot}"
    log "Pilot active: updating agent repo (git branch ${branch})..."
  else
    branch="${AGENT_GIT_BRANCH:-main}"
    log "Updating agent repo (git branch ${branch})..."
  fi

  if ! (cd "$AGENT_DIR" && git fetch origin "$branch"); then
    log "git fetch origin ${branch} failed (continuing with local clone)."
    notify "ERROR" "OTA git fetch 실패 (branch=${branch}). Pi에서 확인: cd ${AGENT_DIR} && git fetch origin ${branch}"
    return 1
  fi

  # 브랜치마다 package-lock.json 추적 여부가 달랐던 적이 있어(main엔 미추적, pilot엔 추적),
  # npm install로 로컬에 생성된 이 파일이 untracked 상태로 남아있으면 다른 브랜치로 체크아웃할 때
  # "덮어씀" 에러로 막힌다. 재생 가능한 빌드 산출물이라 안전하게 지우고 재시도한다.
  if ! (cd "$AGENT_DIR" && git checkout "$branch" 2>/tmp/mycutbox-ota-checkout-err); then
    log "git checkout ${branch} failed; retrying after clearing regenerable untracked files."
    (cd "$AGENT_DIR" && git clean -fd -- package-lock.json node_modules) >/dev/null 2>&1 || true
    if ! (cd "$AGENT_DIR" && git checkout "$branch" 2>/tmp/mycutbox-ota-checkout-err); then
      log "git checkout ${branch} still failing (continuing with local clone)."
      notify "ERROR" "OTA git checkout 실패 (branch=${branch}), untracked 파일 정리 후에도 실패. Pi에서 확인: cd ${AGENT_DIR} && git status && cat /tmp/mycutbox-ota-checkout-err"
      return 1
    fi
    log "git checkout ${branch} succeeded after cleanup."
  fi

  if ! (cd "$AGENT_DIR" && git pull --rebase origin "$branch" 2>/tmp/mycutbox-ota-pull-err); then
    log "git pull origin ${branch} failed (continuing with local clone)."
    notify "ERROR" "OTA git pull 실패 (branch=${branch}). Pi에서 확인: cd ${AGENT_DIR} && git status && cat /tmp/mycutbox-ota-pull-err"
    return 1
  fi
  return 0
}

read_fleet_state_revision() {
  if [ -f "$FLEET_STATE_REVISION_FILE" ]; then
    tr -d ' \n\r\t' < "$FLEET_STATE_REVISION_FILE" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

write_fleet_state_revision() {
  local rev="${1:-0}"
  ensure_ota_state_dir
  printf '%s\n' "$rev" > "$FLEET_STATE_REVISION_FILE"
}

fleet_effective_desired_tag() {
  if [ -n "${FLEET_DESIRED_TAG:-}" ]; then
    printf '%s' "$FLEET_DESIRED_TAG"
  else
    read_repo_agent_version_tag
  fi
}

should_skip_fleet_poll() {
  [ "$TRIGGER" = "fleet" ] || return 1
  fleet_fetch_into_vars || {
    log "Fleet poll: Firestore unavailable; skipping."
    return 0
  }

  local local_tag effective last_rev
  local_tag="$(read_env_agent_tag)"
  effective="$(fleet_effective_desired_tag)"
  last_rev="$(read_fleet_state_revision)"

  if [ -z "$effective" ]; then
    log "Fleet poll: no desired tag (fleet doc empty and no AGENT_VERSION)."
    return 0
  fi
  if [ "$local_tag" = "$effective" ] && [ "${FLEET_REVISION:-0}" = "$last_rev" ]; then
    log "Fleet poll: already on ${local_tag} (fleet revision ${FLEET_REVISION})."
    return 0
  fi
  return 1
}

resolve_target_agent_tag() {
  local repo_tag=""
  repo_tag="$(read_repo_agent_version_tag)"
  fleet_fetch_into_vars || true

  OTA_TARGET_TAG="$repo_tag"
  OTA_TAG_SOURCE="AGENT_VERSION"
  if [ -n "${FLEET_DESIRED_TAG:-}" ]; then
    OTA_TARGET_TAG="$FLEET_DESIRED_TAG"
    OTA_TAG_SOURCE="${FLEET_TAG_SOURCE:-fleet/ota}"
  fi
  if [ -n "${OTA_TARGET_TAG:-}" ]; then
    OTA_TARGET_TAG="$(normalize_agent_image_tag "$OTA_TARGET_TAG")"
  fi
}

# GHCR tags look like v1.2.2.1 — not v.1.2.2.1 (common Admin typo).
normalize_agent_image_tag() {
  local t="$1"
  if [[ "$t" =~ ^v\.(.+)$ ]]; then
    log "Correcting image tag typo: ${t} -> v${BASH_REMATCH[1]}"
    t="v${BASH_REMATCH[1]}"
  fi
  printf '%s' "$t"
}

agent_image_tag_is_valid() {
  local t="$1"
  [ -n "$t" ] || return 1
  [[ "$t" == "pilot" ]] && return 0
  [[ "$t" =~ ^v[0-9][0-9A-Za-z._-]*$ ]]
}

apply_agent_image_tag_to_env() {
  local _tag="$1"
  local _env="${ENV_FILE}"
  [ -n "$_tag" ] || return 0

  if [ -f "$_env" ]; then
    if grep -q '^AGENT_IMAGE_TAG=' "$_env" 2>/dev/null; then
      local _ev_tmp
      _ev_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota-env.XXXXXX")"
      sed "s|^AGENT_IMAGE_TAG=.*|AGENT_IMAGE_TAG=${_tag}|" "$_env" > "$_ev_tmp"
      cat "$_ev_tmp" > "$_env"
      rm -f "$_ev_tmp"
    else
      echo "AGENT_IMAGE_TAG=${_tag}" >> "$_env"
    fi
  else
    umask 077
    echo "AGENT_IMAGE_TAG=${_tag}" > "$_env" 2>/dev/null || true
  fi
  export AGENT_IMAGE_TAG="${_tag}"
}

fleet_report_applied() {
  local helper="${AGENT_DIR}/scripts/fleet-ota-fetch.mjs"
  local cred tag rev
  [ -f "$helper" ] || return 0
  cred="$(resolve_firestore_credentials)" || return 0
  tag="$(read_env_agent_tag)"
  rev="${FLEET_REVISION:-0}"
  (cd "$AGENT_DIR" && GOOGLE_APPLICATION_CREDENTIALS="$cred" node "$helper" ack "$SERIAL" "$tag" "$rev" "${OTA_TAG_SOURCE:-AGENT_VERSION}" >/dev/null 2>&1) || true
  write_fleet_state_revision "$rev"
}

fleet_record_ota_history() {
  local changed="${1:-0}"
  local success="${2:-1}"
  local helper="${AGENT_DIR}/scripts/fleet-ota-fetch.mjs"
  local cred
  [ -f "$helper" ] || return 0
  cred="$(resolve_firestore_credentials)" || return 0

  (
    cd "$AGENT_DIR" && \
      GOOGLE_APPLICATION_CREDENTIALS="$cred" \
      OTA_HISTORY_SERIAL="$SERIAL" \
      OTA_HISTORY_TRIGGER="$TRIGGER" \
      OTA_HISTORY_TAG_BEFORE="${OTA_TAG_BEFORE:-}" \
      OTA_HISTORY_TAG_AFTER="${OTA_TAG_AFTER:-}" \
      OTA_HISTORY_TAG_SOURCE="${OTA_TAG_SOURCE:-AGENT_VERSION}" \
      OTA_HISTORY_FLEET_REVISION="${FLEET_REVISION:-0}" \
      OTA_HISTORY_FLEET_REASON="${FLEET_REASON:-}" \
      OTA_HISTORY_HEAD_BEFORE="${OTA_HEAD_BEFORE:-}" \
      OTA_HISTORY_HEAD_AFTER="${OTA_HEAD_AFTER:-}" \
      OTA_HISTORY_CHANGED="$changed" \
      OTA_HISTORY_SUCCESS="$success" \
      node "$helper" history >/dev/null 2>&1
  ) || true
}

get_serial() {
  local s=""
  if [ -f /sys/firmware/devicetree/base/serial-number ]; then
    # serial-number may contain NUL bytes
    s="$(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null || true)"
  fi
  if [ -z "$s" ]; then
    s="$(awk -F: '/Serial/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
  fi
  # sanitize
  s="$(echo "${s:-unknown}" | tr -d '\n' | tr -d '\r' | sed 's/[^A-Za-z0-9._-]/_/g' | cut -c1-80)"
  [ -n "$s" ] || s="unknown"
  echo "$s"
}

SERIAL="$(get_serial)"

json_escape() {
  # Escapes a string so it can be embedded inside JSON string value (fallback when python3 is missing).
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

# Human-readable time in Korea (KST), e.g. 2026-03-24 12:57:18 KST
kst_timestamp() {
  TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
}

# chat.postMessage: 응답에 ts가 있어 이후 알림을 스레드로 붙일 수 있음.
slack_post_via_api() {
  local level="$1"
  local body="$2"
  local ts
  ts="$(kst_timestamp)"
  local had_parent_ts="$SLACK_OTA_THREAD_TS"
  local out
  local e
  set +e
  out="$(
    SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" SLACK_CHANNEL_ID="$SLACK_CHANNEL_ID" \
      LEVEL="$level" BODY="$body" SERIAL="$SERIAL" TRIGGER="$TRIGGER" KST="$ts" VERSION="$OTA_UPDATE_SCRIPT_VERSION" \
      THREAD_TS="${SLACK_OTA_THREAD_TS:-}" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request
level = os.environ["LEVEL"]
body = os.environ["BODY"]
serial = os.environ["SERIAL"]
trigger = os.environ["TRIGGER"]
kst = os.environ["KST"]
version = os.environ.get("VERSION", "")
thread_ts = (os.environ.get("THREAD_TS") or "").strip()
token = os.environ["SLACK_BOT_TOKEN"]
channel = os.environ["SLACK_CHANNEL_ID"]

def trunc(s: str, n: int) -> str:
    if len(s) <= n:
        return s
    return s[: n // 2] + "\n...\n" + s[-(n // 2) :]

def payload():
    if thread_ts:
        b = trunc(body, 2900)
        return {
            "channel": channel,
            "thread_ts": thread_ts,
            "text": b,
            "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": b}}],
        }
    if level == "DONE":
        return {
            "channel": channel,
            "text": body,
            "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": body}}],
        }
    b = trunc(body, 2400)
    meta = (
        f"*Level:* {level}\n"
        f"*Serial:* `{serial}`\n"
        f"*Trigger:* {trigger}\n"
        f"*OTA script:* `{version}`\n"
        f"*Time (KST):* {kst}\n\n"
        f"---\n{b}"
    )
    return {
        "channel": channel,
        "text": f"MyCutBox OTA [{level}] serial={serial}",
        "blocks": [
            {"type": "header", "text": {"type": "plain_text", "text": "MyCutBox OTA", "emoji": True}},
            {"type": "section", "text": {"type": "mrkdwn", "text": meta}},
        ],
    }

data = json.dumps(payload(), ensure_ascii=False).encode("utf-8")
req = urllib.request.Request(
    "https://slack.com/api/chat.postMessage",
    data=data,
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json; charset=utf-8",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=45) as r:
        resp = json.loads(r.read().decode())
except urllib.error.HTTPError as e:
    print(e.read().decode()[:500], file=sys.stderr)
    sys.exit(1)
except OSError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
if not resp.get("ok"):
    print(resp.get("error", "?"), file=sys.stderr)
    sys.exit(1)
print(resp.get("ts") or "")
PY
  )"
  e=$?
  set -e
  if [ "$e" -ne 0 ]; then
    return 0
  fi
  if [ -z "$had_parent_ts" ] && [ "$level" != "DONE" ] && [ -n "$out" ]; then
    SLACK_OTA_THREAD_TS="$out"
  fi
}

# Incoming Webhook: 응답이 plain text ok 뿐이라 ts 없음 → 스레드 불가.
slack_post_via_webhook() {
  local level="$1"
  local body="$2"
  local ts
  ts="$(kst_timestamp)"
  local payload

  if command -v python3 >/dev/null 2>&1; then
    if [ "$level" = "DONE" ]; then
      payload="$(BODY="$body" python3 - <<'PY'
import json, os
body = os.environ["BODY"]
payload = {
    "text": body,
    "blocks": [{"type": "section", "text": {"type": "mrkdwn", "text": body}}],
}
print(json.dumps(payload, ensure_ascii=False))
PY
)"
    else
      payload="$(LEVEL="$level" BODY="$body" SERIAL="$SERIAL" TRIGGER="$TRIGGER" TS="$ts" VERSION="$OTA_UPDATE_SCRIPT_VERSION" python3 - <<'PY'
import json, os
level = os.environ["LEVEL"]
body = os.environ["BODY"]
serial = os.environ["SERIAL"]
trigger = os.environ["TRIGGER"]
ts = os.environ["TS"]
version = os.environ.get("VERSION", "")
if len(body) > 2400:
    body = body[:1200] + "\n...\n" + body[-1000:]
meta = (
    f"*Level:* {level}\n"
    f"*Serial:* `{serial}`\n"
    f"*Trigger:* {trigger}\n"
    f"*OTA script:* `{version}`\n"
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
    fi
  else
    if [ "$level" = "DONE" ]; then
      payload="{\"text\":\"$(json_escape "$body")\"}"
    else
      local full_text
      full_text="$(printf '%s\n\n---\n%s' "MyCutBox OTA [${level}]  serial: ${SERIAL}  trigger: ${TRIGGER}  OTA script: ${OTA_UPDATE_SCRIPT_VERSION}  time (KST): ${ts}" "${body}")"
      payload="{\"text\":\"$(json_escape "$full_text")\"}"
    fi
  fi

  curl -sS -X POST -H 'Content-Type: application/json' --data-binary "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
}

slack_post() {
  local level="$1"
  local body="$2"
  if [ -n "$SLACK_BOT_TOKEN" ] && [ -n "$SLACK_CHANNEL_ID" ]; then
    SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN" SLACK_CHANNEL_ID="$SLACK_CHANNEL_ID" slack_post_via_api "$level" "$body"
    return 0
  fi
  if [ -z "$WEBHOOK_URL" ]; then
    return 0
  fi
  slack_post_via_webhook "$level" "$body"
}

notify() {
  local level="$1"; shift
  local msg="$*"
  slack_post "$level" "$msg"
}

# Truncate for Slack (keep head + tail if very long)
slack_safe_body() {
  local s="$1"
  local max=3500
  if [ "${#s}" -le "$max" ]; then
    printf '%s' "$s"
    return
  fi
  printf '%s\n...\n%s' "${s:0:2000}" "${s: -1000}"
}

on_error() {
  local lineno="$1"
  local cmd="$2"
  local status="$3"
  notify "ERROR" "step failed (exit=${status}) at line ${lineno}\ncmd: ${cmd}"
}

trap 'on_error $LINENO "$BASH_COMMAND" $?' ERR

acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 200>"$LOCK_FILE"
    flock -n 200 || {
      log "Lock held; skipping run."
      if should_notify_aux_start_and_skip; then
        notify "SKIP" "Another OTA run is in progress (lock held)."
      fi
      exit 0
    }
  else
    mkdir "$LOCK_FILE" 2>/dev/null || {
      log "Lock dir exists; skipping run."
      if should_notify_aux_start_and_skip; then
        notify "SKIP" "Another OTA run is in progress (lock held)."
      fi
      exit 0
    }
    trap 'rmdir "$LOCK_FILE" 2>/dev/null || true' EXIT
  fi
}

has_cups_not_completed() {
  # We detect any in-flight job for the target printer.
  # `lpstat -W not-completed -o` output format: first token is often `${printer}-${id}`.
  local out
  out="$(lpstat -W not-completed -o 2>/dev/null | awk '{print $1}' | grep -F "${PRINTER_NAME}-" || true)"
  [ -n "$out" ]
}

has_usb_processing_jobs() {
  # usbPrint marks files by renaming to `processing_*`.
  shopt -s nullglob
  local files=(
    "$GVFS_BASE"/afc:host=*/com.mycutbox/MyCutBox/processing_printThis_*.png
    "$GVFS_BASE"/afc:host=*/com.mycutbox.kiosk/MyCutBox/processing_printThis_*.png
  )
  shopt -u nullglob
  [ "${#files[@]}" -gt 0 ]
}

# systemd timer runs /usr/local/bin/mycutbox-ota-update; keep it in sync with the cloned repo after git pull.
# ~/.pi/ensure-rx1-cups.sh — git pull 후 OTA가 최신 스크립트로 갱신 (install.sh 8c 와 동일 경로)
sync_ensure_rx1_cups() {
  local src="${AGENT_DIR}/scripts/ensure-rx1-cups.sh"
  local dst="${PROJECT_DIR}/ensure-rx1-cups.sh"
  [ -f "$src" ] || return 0
  if [ -f "$dst" ] && cmp -s "$src" "$dst" 2>/dev/null; then
    return 0
  fi
  log "Syncing ensure-rx1-cups.sh to ${dst}..."
  if sudo -n cp "$src" "$dst" 2>/dev/null \
    && sudo -n chown root:root "$dst" 2>/dev/null \
    && sudo -n chmod 755 "$dst" 2>/dev/null; then
    :
  elif cp "$src" "$dst" 2>/dev/null && chmod 755 "$dst" 2>/dev/null; then
    log "ensure-rx1-cups.sh updated (run: sudo chown root:root ${dst})"
  else
    log "Could not update ${dst} (need write access or passwordless sudo)."
    return 0
  fi
  if systemctl is-enabled ensure-rx1-cups.service >/dev/null 2>&1; then
    sudo -n systemctl start ensure-rx1-cups.service 2>/dev/null \
      || systemctl start ensure-rx1-cups.service 2>/dev/null \
      || log "ensure-rx1-cups.service not started (printer may be unplugged)."
  fi
}

sync_ota_system_launcher() {
  local dst="/usr/local/bin/mycutbox-ota-update"
  local src="${AGENT_DIR}/mycutbox-ota-update.sh"
  [ -f "$src" ] || return 0
  if cmp -s "$src" "$dst" 2>/dev/null; then
    return 0
  fi
  log "Syncing OTA launcher to ${dst}..."
  if sudo -n cp "$src" "$dst" 2>/dev/null && sudo -n chmod +x "$dst" 2>/dev/null; then
    sudo -n chown "$(id -un):$(id -gn)" "$dst" 2>/dev/null || true
    log "OTA launcher updated for next runs (timer uses ${dst})."
    return 0
  fi
  if cp "$src" "$dst" 2>/dev/null && chmod +x "$dst" 2>/dev/null; then
    log "OTA launcher updated for next runs (timer uses ${dst})."
    return 0
  fi
  log "Could not write ${dst} (need passwordless sudo for cp, or run once: sudo cp ${src} ${dst} && sudo chmod +x ${dst}). Timer may stay on an old copy."
}

maybe_reexec_latest_ota_script() {
  [ "${OTA_SELF_REEXEC_DONE:-0}" = "1" ] && return 0

  local latest="${AGENT_DIR}/mycutbox-ota-update.sh"
  [ -f "$latest" ] || return 0
  cmp -s "$0" "$latest" 2>/dev/null && return 0

  log "OTA script updated by git pull; re-executing latest version before docker update..."

  if command -v flock >/dev/null 2>&1; then
    flock -u 200 2>/dev/null || true
  fi

  exec env \
    OTA_SELF_REEXEC_DONE=1 \
    OTA_REEXEC_SKIP_START_NOTIFY=1 \
    SLACK_OTA_THREAD_TS="$SLACK_OTA_THREAD_TS" \
    bash "$latest" "${SELF_REEXEC_ARGS[@]}"
}

write_if_changed() {
  local target="$1"
  local tmp="$2"
  if [ -f "$target" ] && cmp -s "$target" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$target"
  return 0
}

sync_ota_user_units() {
  local user_svc_dir="${HOME}/.config/systemd/user"
  local ota_dst="/usr/local/bin/mycutbox-ota-update"
  local uid
  local changed=0
  uid="$(id -u)"

  mkdir -p "$user_svc_dir"

  local service_tmp timer_tmp boot_service_tmp boot_timer_tmp network_service_tmp network_down_service_tmp fleet_service_tmp fleet_timer_tmp fleet_watch_tmp heartbeat_service_tmp heartbeat_timer_tmp
  service_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota.service.XXXXXX")"
  timer_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota.timer.XXXXXX")"
  boot_service_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota-boot.service.XXXXXX")"
  boot_timer_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota-boot.timer.XXXXXX")"
  network_service_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota-network.service.XXXXXX")"
  network_down_service_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota-network-down.service.XXXXXX")"
  fleet_service_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota-fleet.service.XXXXXX")"
  fleet_timer_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota-fleet.timer.XXXXXX")"
  fleet_watch_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-ota-fleet-watch.service.XXXXXX")"
  heartbeat_service_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-fleet-heartbeat.service.XXXXXX")"
  heartbeat_timer_tmp="$(mktemp "${TMPDIR:-/tmp}/mycutbox-fleet-heartbeat.timer.XXXXXX")"

  cat > "$service_tmp" <<EOF
[Unit]
Description=MyCutBox OTA update controller (docker + usb agent)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$uid
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$ota_dst --auto
EOF

  cat > "$timer_tmp" <<EOF
[Unit]
Description=Run MyCutBox OTA update monthly on day 1 at 04:00

[Timer]
OnCalendar=*-*-01 04:00:00
Persistent=true
Unit=mycutbox-ota.service

[Install]
WantedBy=timers.target
EOF

  cat > "$boot_service_tmp" <<EOF
[Unit]
Description=MyCutBox OTA update controller after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$uid
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$ota_dst --boot
EOF

  cat > "$boot_timer_tmp" <<EOF
[Unit]
Description=Run MyCutBox OTA update 5 minutes after boot

[Timer]
OnBootSec=5min
Unit=mycutbox-ota-boot.service

[Install]
WantedBy=timers.target
EOF

  cat > "$network_service_tmp" <<EOF
[Unit]
Description=MyCutBox OTA update controller after network reconnect
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$uid
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$ota_dst --network-online
EOF

  cat > "$network_down_service_tmp" <<EOF
[Unit]
Description=MyCutBox network-down retry/alert helper
After=network.target
Wants=network.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$uid
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$ota_dst --network-down
EOF

  cat > "$fleet_service_tmp" <<EOF
[Unit]
Description=MyCutBox fleet OTA poll (Firestore desiredAgentTag)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$uid
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$ota_dst --fleet
EOF

  cat > "$fleet_timer_tmp" <<EOF
[Unit]
Description=Fallback fleet OTA poll (if snapshot watch is down)

[Timer]
OnBootSec=5min
OnUnitActiveSec=60min
Persistent=true
Unit=mycutbox-ota-fleet.service

[Install]
WantedBy=timers.target
EOF

  cat > "$fleet_watch_tmp" <<EOF
[Unit]
Description=MyCutBox fleet OTA Firestore listener (instant rollback)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$AGENT_DIR
Environment=XDG_RUNTIME_DIR=/run/user/$uid
EnvironmentFile=-/etc/mycutbox/env
ExecStart=/usr/bin/node $AGENT_DIR/scripts/fleet-ota-watch.mjs
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
EOF

  cat > "$heartbeat_service_tmp" <<EOF
[Unit]
Description=MyCutBox fleet heartbeat writer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$AGENT_DIR
Environment=XDG_RUNTIME_DIR=/run/user/$uid
EnvironmentFile=-/etc/mycutbox/env
ExecStart=/usr/bin/node $AGENT_DIR/scripts/fleet-heartbeat.mjs
EOF

  cat > "$heartbeat_timer_tmp" <<EOF
[Unit]
Description=Run MyCutBox fleet heartbeat every 30 seconds

[Timer]
OnBootSec=30sec
OnUnitActiveSec=30sec
Persistent=true
Unit=mycutbox-fleet-heartbeat.service

[Install]
WantedBy=timers.target
EOF

  if write_if_changed "$user_svc_dir/mycutbox-ota.service" "$service_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-ota.timer" "$timer_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-ota-boot.service" "$boot_service_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-ota-boot.timer" "$boot_timer_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-ota-network.service" "$network_service_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-ota-network-down.service" "$network_down_service_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-ota-fleet.service" "$fleet_service_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-ota-fleet.timer" "$fleet_timer_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-ota-fleet-watch.service" "$fleet_watch_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-fleet-heartbeat.service" "$heartbeat_service_tmp"; then changed=1; fi
  if write_if_changed "$user_svc_dir/mycutbox-fleet-heartbeat.timer" "$heartbeat_timer_tmp"; then changed=1; fi

  if [ "$changed" -eq 1 ]; then
    log "Syncing OTA user systemd units..."
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable mycutbox-ota.timer >/dev/null 2>&1 || true
    systemctl --user enable mycutbox-ota-boot.timer >/dev/null 2>&1 || true
    systemctl --user enable mycutbox-ota-fleet.timer >/dev/null 2>&1 || true
    systemctl --user enable mycutbox-ota-fleet-watch.service >/dev/null 2>&1 || true
    systemctl --user enable mycutbox-fleet-heartbeat.timer >/dev/null 2>&1 || true
    systemctl --user restart mycutbox-ota.timer >/dev/null 2>&1 || true
    systemctl --user restart mycutbox-ota-boot.timer >/dev/null 2>&1 || true
    systemctl --user restart mycutbox-ota-fleet.timer >/dev/null 2>&1 || true
    systemctl --user restart mycutbox-ota-fleet-watch.service >/dev/null 2>&1 || true
    systemctl --user restart mycutbox-fleet-heartbeat.timer >/dev/null 2>&1 || true
  fi
}

sync_network_dispatcher_hook() {
  local target="/etc/NetworkManager/dispatcher.d/90-mycutbox-ota-online"
  local uid user tmp changed=0
  uid="$(id -u)"
  user="$(id -un)"
  tmp="$(mktemp "${TMPDIR:-/tmp}/90-mycutbox-ota-online.XXXXXX")"

  cat > "$tmp" <<EOF
#!/usr/bin/env bash
set -eu

IFACE="\${1:-}"
STATE="\${2:-}"

case "\$STATE" in
  up|connectivity-change|dhcp4-change|dhcp6-change)
    EVENT="online"
    ;;
  down|disconnected)
    EVENT="down"
    ;;
  *)
    exit 0
    ;;
esac

if [ ! -S "/run/user/$uid/bus" ]; then
  exit 0
fi

if [ "\$EVENT" = "online" ]; then
  su - "$user" -c "XDG_RUNTIME_DIR=/run/user/$uid systemctl --user start mycutbox-ota-network.service" >/dev/null 2>&1 || true
else
  su - "$user" -c "XDG_RUNTIME_DIR=/run/user/$uid systemctl --user start mycutbox-ota-network-down.service" >/dev/null 2>&1 || true
fi
EOF

  chmod 0755 "$tmp" 2>/dev/null || true
  if [ -f "$target" ] && cmp -s "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi

  if sudo -n cp "$tmp" "$target" 2>/dev/null && sudo -n chmod 0755 "$target" 2>/dev/null; then
    changed=1
  elif cp "$tmp" "$target" 2>/dev/null && chmod 0755 "$target" 2>/dev/null; then
    changed=1
  else
    log "Could not update NetworkManager dispatcher hook (${target})."
  fi
  rm -f "$tmp"
  [ "$changed" -eq 1 ] && log "Network reconnect/disconnect hook synced."
}

ensure_ota_state_dir() {
  mkdir -p "$OTA_STATE_DIR"
}

network_is_online() {
  if command -v nm-online >/dev/null 2>&1; then
    if nm-online -q --timeout=3 >/dev/null 2>&1; then
      return 0
    fi
  fi

  local target
  for target in $NETWORK_CHECK_TARGETS; do
    if ping -c1 -W2 "$target" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

network_try_reconnect() {
  command -v nmcli >/dev/null 2>&1 || return 0
  nmcli networking on >/dev/null 2>&1 || true
  while IFS=: read -r dev type state; do
    [ "$type" = "wifi" ] || continue
    [ -n "$dev" ] || continue
    case "$state" in
      connected|connecting)
        ;;
      *)
        nmcli device connect "$dev" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null || true)
}

network_should_send_offline_alert() {
  ensure_ota_state_dir
  local now last delta
  now="$(date +%s)"
  last=""
  if [ -f "$NETWORK_OFFLINE_ALERT_FILE" ]; then
    last="$(cat "$NETWORK_OFFLINE_ALERT_FILE" 2>/dev/null || true)"
  fi
  if [ -n "$last" ] && [[ "$last" =~ ^[0-9]+$ ]]; then
    delta=$(( now - last ))
    [ "$delta" -lt "$NETWORK_OFFLINE_ALERT_COOLDOWN_SECONDS" ] && return 1
  fi
  printf '%s\n' "$now" > "$NETWORK_OFFLINE_ALERT_FILE"
  return 0
}

network_mark_offline() {
  ensure_ota_state_dir
  printf '%s\n' "$(date +%s)" > "$NETWORK_OFFLINE_ACTIVE_FILE"
}

NETWORK_JUST_RECOVERED=0
network_mark_online_if_needed() {
  [ -f "$NETWORK_OFFLINE_ACTIVE_FILE" ] || return 0
  rm -f "$NETWORK_OFFLINE_ACTIVE_FILE"
  NETWORK_JUST_RECOVERED=1
  notify "DONE" "네트워크가 복구되었습니다. (trigger=${TRIGGER})"
}

handle_network_down() {
  if network_is_online; then
    return 0
  fi

  local tries delay i
  tries="$NETWORK_OFFLINE_RETRY_COUNT"
  delay="$NETWORK_OFFLINE_RETRY_DELAY_SECONDS"
  if ! [[ "$tries" =~ ^[0-9]+$ ]]; then tries=6; fi
  if ! [[ "$delay" =~ ^[0-9]+$ ]]; then delay=10; fi
  [ "$tries" -gt 0 ] || tries=1
  [ "$delay" -gt 0 ] || delay=1

  for i in $(seq 1 "$tries"); do
    network_try_reconnect
    sleep "$delay"
    if network_is_online; then
      network_mark_online_if_needed
      notify "DONE" "네트워크 재연결 성공 (${i}/${tries}회 시도 후, trigger=${TRIGGER})."
      return 0
    fi
  done

  network_mark_offline
  if network_should_send_offline_alert; then
    notify "ERROR" "네트워크가 완전히 끊긴 상태입니다. 자동 재연결 ${tries}회 시도 후에도 실패했습니다. (trigger=${TRIGGER})"
  else
    log "Network offline alert suppressed by cooldown."
  fi
}

should_skip_network_online_due_to_debounce() {
  [ "$TRIGGER" = "network-online" ] || return 1
  ensure_ota_state_dir

  local now last delta
  now="$(date +%s)"
  last=""
  if [ -f "$NETWORK_ONLINE_DEBOUNCE_FILE" ]; then
    last="$(cat "$NETWORK_ONLINE_DEBOUNCE_FILE" 2>/dev/null || true)"
  fi
  if [ -n "$last" ] && [[ "$last" =~ ^[0-9]+$ ]]; then
    delta=$(( now - last ))
    if [ "$delta" -lt "$NETWORK_ONLINE_DEBOUNCE_SECONDS" ]; then
      log "Network-online OTA debounced (${delta}s < ${NETWORK_ONLINE_DEBOUNCE_SECONDS}s)."
      return 0
    fi
  fi

  printf '%s\n' "$now" > "$NETWORK_ONLINE_DEBOUNCE_FILE"
  return 1
}

main() {
  if [ "$TRIGGER" = "network-down" ]; then
    handle_network_down
    exit 0
  fi

  if [ "$TRIGGER" = "network-online" ] && network_is_online; then
    network_mark_online_if_needed
  fi

  if should_skip_network_online_due_to_debounce; then
    exit 0
  fi

  acquire_lock

  if should_skip_fleet_poll; then
    exit 0
  fi

  log "OTA script version ${OTA_UPDATE_SCRIPT_VERSION}"

  if should_notify_aux_start_and_skip; then
    notify "START" "OTA update started."
  fi

  # Preconditions: skip OTA if print job is running.
  if has_cups_not_completed; then
    log "CUPS has not-completed jobs for ${PRINTER_NAME}. Skipping OTA."
    if should_notify_aux_start_and_skip; then
      notify "SKIP" "CUPS not-completed jobs detected for printer '${PRINTER_NAME}'."
    fi
    exit 0
  fi
  if has_usb_processing_jobs; then
    log "usbPrint has processing files in GVFS. Skipping OTA."
    if should_notify_aux_start_and_skip; then
      notify "SKIP" "usbPrint processing files detected in '${GVFS_BASE}'."
    fi
    exit 0
  fi

  # Snapshot for Slack summary (already latest vs updated, tag/commit/image).
  OTA_TAG_BEFORE="$(read_env_agent_tag)"
  OTA_HEAD_BEFORE=""
  [ -d "$AGENT_DIR" ] && OTA_HEAD_BEFORE="$(cd "$AGENT_DIR" && git rev-parse --short HEAD 2>/dev/null || true)"
  OTA_COMPOSE_IMAGE=""
  if [ -f "$COMPOSE_FILE" ]; then
    OTA_COMPOSE_IMAGE="$(cd "$PROJECT_DIR" && docker compose -f "$COMPOSE_FILE" config --images "$COMPOSITE_SERVICE" 2>/dev/null | head -n1 || true)"
  fi
  OTA_IMG_ID_BEFORE=""
  [ -n "$OTA_COMPOSE_IMAGE" ] && OTA_IMG_ID_BEFORE="$(docker image inspect -f '{{.Id}}' "$OTA_COMPOSE_IMAGE" 2>/dev/null || true)"

  # Fleet/pilot branch selection before git pull so AGENT_VERSION / compose match intended track.
  fleet_fetch_into_vars || true
  if [ -d "$AGENT_DIR" ]; then
    update_agent_repo || true
    if (cd "$AGENT_DIR" && npm install --production); then
      :
    else
      log "npm install failed (continuing)."
    fi
  else
    log "Agent dir not found: $AGENT_DIR (skipping git pull)."
  fi

  OTA_HEAD_AFTER=""
  [ -d "$AGENT_DIR" ] && OTA_HEAD_AFTER="$(cd "$AGENT_DIR" && git rev-parse --short HEAD 2>/dev/null || true)"
  maybe_reexec_latest_ota_script

  # Keep local docker-compose in sync with the agent repo (ensures watchtower removal).
  if [ -d "$AGENT_DIR" ] && [ -f "$AGENT_DIR/docker-compose.yml" ]; then
    log "Syncing docker-compose.yml from agent repo..."
    cp -f "$AGENT_DIR/docker-compose.yml" "$COMPOSE_FILE" || true
  fi
  # AGENT_VERSION (repo) or fleet/ota desiredAgentTag → secure env AGENT_IMAGE_TAG
  resolve_target_agent_tag
  if [ -n "$OTA_TARGET_TAG" ]; then
    if ! agent_image_tag_is_valid "$OTA_TARGET_TAG"; then
      log "Invalid agent image tag: ${OTA_TARGET_TAG}"
      notify "ERROR" "Invalid AGENT_IMAGE_TAG \`${OTA_TARGET_TAG}\`. Use GHCR format \`v1.2.2.1\` (not \`v.1.2.2.1\`). Check Fleet Admin desiredAgentTag."
      exit 1
    fi
    log "Applying agent image tag ${OTA_TARGET_TAG} (source: ${OTA_TAG_SOURCE})..."
    if [ -n "$FLEET_REASON" ] && { [ "$OTA_TAG_SOURCE" = "fleet/ota" ] || [ "$OTA_TAG_SOURCE" = "fleet/ota/pilot" ]; }; then
      log "Fleet reason (${OTA_TAG_SOURCE}): ${FLEET_REASON}"
    fi
    apply_agent_image_tag_to_env "$OTA_TARGET_TAG"
  fi
  OTA_TAG_AFTER="$(read_env_agent_tag)"
  sync_ota_system_launcher
  sync_ota_user_units
  sync_ensure_rx1_cups
  sync_network_dispatcher_hook
  # Remove old watchtower container if it still exists.
  docker rm -f mycutbox-watchtower >/dev/null 2>&1 || true

  # Stop services for the update window.
  STOPPED_USB=0
  STOPPED_CONNECT_WIFI=0
  STOPPED_COMPOSITE=0
  DOCKER_PULL_FAILED=0
  DOCKER_UP_FAILED=0

  cleanup_and_restart() {
    set +e
    set +u
    if [ "${STOPPED_USB:-0}" -eq 1 ]; then
      log "Restarting usb-print service..."
      systemctl --user start "$USB_PRINT_SERVICE" >/dev/null 2>&1 || true
    fi
    if [ "${STOPPED_CONNECT_WIFI:-0}" -eq 1 ]; then
      log "Restarting connect-wifi service..."
      systemctl --user start "$CONNECT_WIFI_SERVICE" >/dev/null 2>&1 || true
    fi
    if [ "${STOPPED_COMPOSITE:-0}" -eq 1 ]; then
      log "Restarting composite-print container..."
      (cd "$PROJECT_DIR" && docker compose up -d "$COMPOSITE_SERVICE" >/dev/null 2>&1) || true
    fi
    set -u
  }
  trap cleanup_and_restart EXIT

  log "Stopping usb-print..."
  systemctl --user stop "$USB_PRINT_SERVICE" >/dev/null 2>&1 || true
  STOPPED_USB=1

  log "Stopping connect-wifi..."
  systemctl --user stop "$CONNECT_WIFI_SERVICE" >/dev/null 2>&1 || true
  STOPPED_CONNECT_WIFI=1

  # Docker 는 마운트 소스 파일이 없으면 그 자리에 빈 디렉터리를 자동 생성해 마운트가 깨진다
  # (컨테이너가 Firestore 키를 못 읽음). 잘못 생긴 디렉터리면 제거해 올바른 파일이 마운트되게 한다.
  [ -d "${PROJECT_DIR}/data/mycutbox110.json" ] && rmdir "${PROJECT_DIR}/data/mycutbox110.json" 2>/dev/null || true

  log "Stopping composite-print..."
  (cd "$PROJECT_DIR" && docker compose stop "$COMPOSITE_SERVICE" >/dev/null 2>&1) || true
  STOPPED_COMPOSITE=1

  # Update Docker (composite-print). Do not rely on `set -e` here — send Slack on failure.
  log "Pulling composite-print image (per docker-compose.yml)..."
  PULL_LOG=""
  if PULL_LOG="$(cd "$PROJECT_DIR" && docker compose pull "$COMPOSITE_SERVICE" 2>&1)"; then
    :
  else
    DOCKER_PULL_FAILED=1
    log "docker compose pull failed; continuing to restart services."
    notify "ERROR" "Docker compose pull failed (image missing or GHCR auth?).\n$(slack_safe_body "$PULL_LOG")"
  fi

  OTA_IMG_ID_AFTER=""
  if [ "$DOCKER_PULL_FAILED" -eq 0 ] && [ -n "$OTA_COMPOSE_IMAGE" ]; then
    OTA_IMG_ID_AFTER="$(docker image inspect -f '{{.Id}}' "$OTA_COMPOSE_IMAGE" 2>/dev/null || true)"
  fi

  log "Starting composite-print..."
  UP_LOG=""
  if UP_LOG="$(cd "$PROJECT_DIR" && docker compose up -d "$COMPOSITE_SERVICE" 2>&1)"; then
    :
  else
    DOCKER_UP_FAILED=1
    log "docker compose up failed."
    notify "ERROR" "Docker compose up failed.\n$(slack_safe_body "$UP_LOG")"
  fi

  # usb-print uses host agent code (already updated above).
  log "Restarting usb-print service..."
  systemctl --user start "$USB_PRINT_SERVICE"

  log "Restarting connect-wifi service..."
  systemctl --user start "$CONNECT_WIFI_SERVICE"

  log "OTA update finished."
  local ota_changed=0
  [ "${OTA_TAG_BEFORE:-}" != "${OTA_TAG_AFTER:-}" ] && ota_changed=1
  [ "${OTA_HEAD_BEFORE:-}" != "${OTA_HEAD_AFTER:-}" ] && ota_changed=1
  [ "${OTA_IMG_ID_BEFORE:-}" != "${OTA_IMG_ID_AFTER:-}" ] && ota_changed=1

  # network-online 트리거는 실제 단절 없이도 NetworkManager의 connectivity-change/DHCP 갱신마다
  # 들어와서(디바운스만 통과하면) 매번 전체 플로우를 도는데, 아무것도 안 바뀌었고 실제 복구도
  # 아니면(NETWORK_JUST_RECOVERED=0) fleet 이력에 쌓을 가치가 없다 — 진짜 복구/버전 변경만 남긴다.
  local is_noise_network_online=0
  if [ "$TRIGGER" = "network-online" ] && [ "$ota_changed" -eq 0 ] && [ "$NETWORK_JUST_RECOVERED" -ne 1 ]; then
    is_noise_network_online=1
  fi

  if [ "$DOCKER_PULL_FAILED" -eq 0 ] && [ "$DOCKER_UP_FAILED" -eq 0 ]; then
    fleet_report_applied
    [ "$is_noise_network_online" -eq 1 ] || fleet_record_ota_history "$ota_changed" 1
    # 읽기 쉬운 여러 줄 형식(제목 + 불릿). 시리얼/호스트/트리거/시각을 항상 포함한다.
    local done_host done_kst
    done_host="$(hostname 2>/dev/null || echo '?')"
    done_kst="$(kst_timestamp)"
    local done_body=""
    if [ "$ota_changed" -eq 0 ]; then
      done_body="$(printf '✅ *이미 최신 상태입니다*\n• *에이전트 이미지 태그:* `%s`\n• *커밋:* `%s`\n• *Serial:* `%s`\n• *Host:* `%s`\n• *Time:* %s' \
        "${OTA_TAG_AFTER:-없음}" "${OTA_HEAD_AFTER:-?}" "${SERIAL:-?}" "$done_host" "$done_kst")"
    else
      # 제목 줄 (fleet 배포면 소스·사유 표기)
      local done_title="✅ *OTA 완료*"
      if [ "$OTA_TAG_SOURCE" = "fleet/ota" ] || [ "$OTA_TAG_SOURCE" = "fleet/ota/pilot" ]; then
        done_title+="  ·  ${OTA_TAG_SOURCE}"
        [ -n "$FLEET_REASON" ] && done_title+=" · ${FLEET_REASON}"
      fi
      # 이미지 태그 전환 줄
      local done_img
      if [ "${OTA_TAG_BEFORE:-}" != "${OTA_TAG_AFTER:-}" ]; then
        done_img="• *에이전트 이미지:* \`${OTA_TAG_BEFORE:-—}\` → \`${OTA_TAG_AFTER:-—}\`"
      else
        done_img="• *에이전트 이미지 태그:* \`${OTA_TAG_AFTER:-—}\` (동일)"
      fi
      done_body="$(printf '%s\n%s\n• *Serial:* `%s`\n• *Host:* `%s`\n• *Trigger:* `%s`\n• *Time:* %s' \
        "$done_title" "$done_img" "${SERIAL:-?}" "$done_host" "${TRIGGER:-?}" "$done_kst")"
      # 선택 줄: 커밋 전환 / 태그 동일하지만 이미지 갱신됨
      if [ "${OTA_HEAD_BEFORE:-}" != "${OTA_HEAD_AFTER:-}" ]; then
        done_body+=$'\n'"• *커밋:* \`${OTA_HEAD_BEFORE:-—}\` → \`${OTA_HEAD_AFTER:-—}\`"
      fi
      if [ "${OTA_IMG_ID_BEFORE:-}" != "${OTA_IMG_ID_AFTER:-}" ] && [ "${OTA_TAG_BEFORE:-}" = "${OTA_TAG_AFTER:-}" ]; then
        done_body+=$'\n'"• *Docker 이미지 갱신됨* (태그 동일)"
      fi
    fi
    if [ "$ota_changed" -eq 1 ] || should_notify_aux_start_and_skip; then
      notify "DONE" "$done_body"
    fi
  else
    fleet_record_ota_history "$ota_changed" 0
    notify "ERROR" "OTA finished with Docker errors (pull_failed=${DOCKER_PULL_FAILED}, up_failed=${DOCKER_UP_FAILED}). Services were restarted where possible."
  fi
  trap - EXIT
}

main "$@"
