#!/bin/bash
# MyCutBox screen lock (gtklock): clock + colored status (agent / connected networks).
# LIVE: while locked, a background watcher refreshes the status when it actually changes
# (agent up/down, network connect/disconnect/SSID) — so a boot-time lock that shows
# "Agent DOWN" flips to "Agent OK" on its own once the container finishes starting.
# WiFi signal % is shown but excluded from change-detection so it doesn't churn.
# Re-run any time (`mycutbox-lock`) to re-lock.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -n "${WAYLAND_DISPLAY:-}" ] || export WAYLAND_DISPLAY="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -m1 -E '^wayland-[0-9]+$')"
CFG="$HOME/.config/gtklock"

# Compute status → sets AGENT_TEXT/AGENT_CLASS, NET_TEXT/NET_CLASS, and STATE_KEY.
# STATE_KEY intentionally omits the WiFi signal % (which fluctuates) so the watcher
# only relaunches on meaningful changes.
compute_state() {
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q mycutbox-composite-print; then
    AGENT_TEXT="● Agent OK"; AGENT_CLASS="ok"
  else
    AGENT_TEXT="● Agent DOWN"; AGENT_CLASS="bad"
  fi

  local net_items=() net_ids=""
  if nmcli -t -f TYPE,STATE device status 2>/dev/null | grep -q '^ethernet:connected'; then
    net_items+=("● LAN"); net_ids+="LAN;"
  fi
  local wrow; wrow="$(nmcli -t -f IN-USE,SIGNAL,SSID device wifi list --rescan no 2>/dev/null | grep -m1 '^\*')"
  if [ -n "$wrow" ]; then
    local sig ssid; sig="$(echo "$wrow" | cut -d: -f2)"; ssid="$(echo "$wrow" | cut -d: -f3-)"
    net_items+=("● WiFi ${ssid} ${sig}%"); net_ids+="W:${ssid};"
  fi
  NET_TEXT=""; local it
  for it in "${net_items[@]}"; do NET_TEXT="${NET_TEXT:+$NET_TEXT     }$it"; done
  if [ -n "$NET_TEXT" ]; then NET_CLASS="ok"; else NET_TEXT="● Net offline"; NET_CLASS="bad"; fi

  # 실제 떠 있는 컨테이너 이미지 태그(~/.pi/.env의 AGENT_IMAGE_TAG) — git AGENT_VERSION보다
  # "지금 실제로 뭐가 돌고 있는지"를 더 정확히 반영함(OTA 전환 중엔 둘이 잠깐 다를 수 있음).
  VERSION_TEXT="$(grep -m1 '^AGENT_IMAGE_TAG=' "$HOME/.pi/.env" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
  [ -n "$VERSION_TEXT" ] || VERSION_TEXT="$(tr -d ' \n\r\t' < "$HOME/.pi/agent/AGENT_VERSION" 2>/dev/null)"
  [ -n "$VERSION_TEXT" ] || VERSION_TEXT="버전 확인 불가"

  STATE_KEY="${AGENT_CLASS}|${NET_CLASS}|${net_ids}|${VERSION_TEXT}"
}

render_ui() {
  sed -e "s|__AGENT_TEXT__|${AGENT_TEXT}|" -e "s|__AGENT_CLASS__|${AGENT_CLASS}|" \
      -e "s|__NET_TEXT__|${NET_TEXT}|" -e "s|__NET_CLASS__|${NET_CLASS}|" \
      -e "s|__VERSION_TEXT__|${VERSION_TEXT}|" \
      "$CFG/gtklock.ui.tmpl" > "$CFG/gtklock-run.ui"
}

launch_gtklock() {
  gtklock -d -s "$CFG/style.css" -x "$CFG/gtklock-run.ui" -t "%H:%M:%S" -D "%Y-%m-%d (%a)"
}

# Background watcher: relaunch gtklock when STATE_KEY changes. Ends when the user unlocks
# (gtklock exits and we did not relaunch it).
#
# IMPORTANT: kill with SIGKILL, not SIGTERM. On SIGTERM gtklock runs a clean shutdown
# (ext-session-lock unlock_and_destroy) which briefly reveals the desktop before the new
# instance re-locks (~0.5s flash). SIGKILL denies that clean unlock, so labwc keeps the
# session locked (protocol: client crash must NOT unlock) — the new gtklock takes over
# with no desktop exposure. Render the new UI first so the gap between lockers is minimal.
run_watcher() {
  local last="$1"
  while :; do
    sleep 4
    pgrep -x gtklock >/dev/null || break     # user unlocked → stop
    compute_state
    if [ "$STATE_KEY" != "$last" ]; then
      render_ui                               # write new UI before swapping
      pkill -9 -x gtklock 2>/dev/null; sleep 0.3
      launch_gtklock
      last="$STATE_KEY"
      sleep 1                                 # let the new instance register
    fi
  done
}

# Watcher mode (self-reinvoked, detached).
if [ "${1:-}" = "--watch" ]; then
  run_watcher "${2:-}"
  exit 0
fi

# Normal mode: don't stack a second locker.
pgrep -x gtklock >/dev/null && exit 0

compute_state
render_ui
launch_gtklock

# Spawn the detached live-refresh watcher so this command returns immediately.
setsid "$0" --watch "$STATE_KEY" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
