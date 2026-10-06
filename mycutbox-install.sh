#!/usr/bin/env bash
#
# MyCutBox Raspberry Pi — one-click install bootstrap
# ------------------------------------------------------------------
# This is the "download-and-run install wizard". It contains no secrets, so it
# is safe to publish. It can be run two ways:
#
#   1) SSH / terminal (headless):  curl -fsSL https://install.mycutbox.com/rp | bash
#   2) Pi desktop click install:   double-click mycutbox-installer.desktop → runs this in a terminal
#
# What it does:
#   - Interactive menu: Install / update  OR  Uninstall (same launcher does both)
#   - Install: installs Docker if missing, pulls the public GHCR image (no token),
#     fetches host files from the public installer repo, collects settings via a
#     whiptail wizard, runs install.sh → systemd user units + linger → auto-start on boot
#   - Uninstall: runs uninstall.sh → removes containers/services/OTA/screen lock
#
# Non-interactive (unattended): pre-set these env vars to skip the wizard.
#   MCB_ACTION=install|uninstall            (default install; unattended never uninstalls unless set)
#   MCB_STORE_NAME, MCB_CREDENTIALS_PATH, MCB_SLACK_BOT_TOKEN, MCB_SLACK_CHANNEL_ID, MCB_ASSUME_YES=1
#   MCB_LEGACY_ACTION=disable|remove|skip   (how to handle old manual installs; unattended default = disable)
#
# NOTE: all user-facing output here is intentionally English — during first-time
# setup the Pi may not have Korean fonts/locale yet, so Korean would show as mojibake.
#
set -euo pipefail

# Force a C/English locale so sub-tools (git/docker/curl) print readable English during
# first-time setup (the Pi may not have Korean fonts/locale ready yet → mojibake otherwise).
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# ---- distribution constants (public resources only) --------------------------
IMAGE="${MCB_IMAGE:-ghcr.io/m1nzaii/mycutbox-rpi-agent}"       # public GHCR image
# Initial tag: use MCB_IMAGE_TAG if set, otherwise resolve from the public installer
# repo's AGENT_VERSION (= release version) inside pull_image. (:latest is no longer
# produced — the build-and-push workflow that made it was removed.)
IMAGE_TAG="${MCB_IMAGE_TAG:-}"
INSTALLER_REPO="${MCB_INSTALLER_REPO:-https://github.com/m1nzaii/mycutbox-rpi-install}"
INSTALLER_BRANCH="${MCB_INSTALLER_BRANCH:-main}"
# Host-files tarball (codeload fallback so it works without git)
INSTALLER_TARBALL="${MCB_INSTALLER_TARBALL:-${INSTALLER_REPO/github.com/codeload.github.com}/tar.gz/refs/heads/${INSTALLER_BRANCH}}"

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
# ~/pi is visible in the desktop file manager; ~/.pi (dotfile) is hidden by default.
# If a legacy ~/pi already exists (re-run on a previously-provisioned device) and hasn't
# been migrated yet, stage into it as-is — install.sh's own migration step moves everything
# (including whatever this wizard writes here) to ~/.pi in one atomic step, so we don't want
# to split the device's files across both locations by guessing wrong here.
if [ -d "${TARGET_HOME}/pi" ] && [ ! -d "${TARGET_HOME}/.pi" ]; then
  PROJECT_DIR="${TARGET_HOME}/pi"
else
  PROJECT_DIR="${TARGET_HOME}/.pi"
fi
WORK_DIR="$(mktemp -d /tmp/mycutbox-install.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---- output helpers ----------------------------------------------------------
c_reset=$'\033[0m'; c_blue=$'\033[1;34m'; c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'
step() { printf '%s▶ %s%s\n' "$c_blue" "$1" "$c_reset"; }
ok()   { printf '%s✔ %s%s\n' "$c_green" "$1" "$c_reset"; }
warn() { printf '%s! %s%s\n' "$c_yellow" "$1" "$c_reset"; }
die()  { printf '%s✗ %s%s\n' "$c_red" "$1" "$c_reset" >&2; exit 1; }

HAVE_WHIPTAIL=0
command -v whiptail >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ] && HAVE_WHIPTAIL=1
INTERACTIVE=0
[ -t 0 ] && [ -t 1 ] && INTERACTIVE=1
[ "${MCB_ASSUME_YES:-0}" = "1" ] && INTERACTIVE=0

# sudo (needed for Docker install, /etc, systemd)
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "Root privileges required. Install sudo or run as root."
  SUDO="sudo"
fi

# ---- wizard UI ---------------------------------------------------------------
ask() { # ask <title> <desc> <default> → stdout value
  local title="$1" desc="$2" def="${3:-}"
  if [ "$HAVE_WHIPTAIL" = "1" ]; then
    whiptail --title "MyCutBox Install" --inputbox "$desc" 11 70 "$def" 3>&1 1>&2 2>&3 || echo "$def"
  elif [ "$INTERACTIVE" = "1" ]; then
    local v; read -r -p "$desc [$def]: " v; echo "${v:-$def}"
  else
    echo "$def"
  fi
}
ask_secret() { # ask_secret <desc> → stdout (no echo)
  local desc="$1"
  if [ "$HAVE_WHIPTAIL" = "1" ]; then
    whiptail --title "MyCutBox Install" --passwordbox "$desc" 11 70 3>&1 1>&2 2>&3 || echo ""
  elif [ "$INTERACTIVE" = "1" ]; then
    local v; read -r -s -p "$desc: " v; echo >&2; echo "$v"
  else
    echo ""
  fi
}
confirm() { # confirm <message> → 0(yes)/1(no)
  local msg="$1"
  [ "$INTERACTIVE" = "0" ] && return 0
  if [ "$HAVE_WHIPTAIL" = "1" ]; then
    whiptail --title "MyCutBox Install" --yesno "$msg" 12 70
  else
    local v; read -r -p "$msg (Y/n): " v; [[ ! "$v" =~ ^[Nn] ]]
  fi
}
splash() {
  if [ "$HAVE_WHIPTAIL" = "1" ]; then
    whiptail --title "MyCutBox Install Wizard" --msgbox \
"Starting the MyCutBox Pi install.\n\n- Installs Docker and the printer agent\n- Configures auto-start on boot\n- Updates automatically afterwards (OTA)\n\nPress OK to continue." 15 66
  else
    printf '\n%s╔══════════════════════════════════════╗\n' "$c_blue"
    printf '║      MyCutBox Pi Install Wizard       ║\n'
    printf '╚══════════════════════════════════════╝%s\n\n' "$c_reset"
  fi
}

# ---- 1. preflight ------------------------------------------------------------
preflight() {
  step "Checking environment"
  local arch; arch="$(uname -m)"
  case "$arch" in
    aarch64|armv7l|armv6l) ok "Architecture ${arch}" ;;
    x86_64) warn "x86_64 detected — continuing (dev/test)." ;;
    *) warn "Unexpected architecture (${arch}) — trying anyway." ;;
  esac
  if ! grep -qiE "raspberry|debian|ubuntu" /etc/os-release 2>/dev/null; then
    warn "This does not look like Raspberry Pi OS / Debian. Trying anyway."
  fi
}

# ---- 2. Docker ---------------------------------------------------------------
ensure_docker() {
  step "Checking Docker"
  if command -v docker >/dev/null 2>&1; then
    ok "Docker installed ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
  else
    warn "Docker not installed → installing (this can take a few minutes)"
    $SUDO sh -c 'curl -fsSL https://get.docker.com | sh' || die "Docker install failed"
    ok "Docker installed"
  fi
  # Add the target user to the docker group (this session still uses sudo docker)
  if ! id -nG "$TARGET_USER" 2>/dev/null | grep -qw docker; then
    $SUDO usermod -aG docker "$TARGET_USER" 2>/dev/null || true
    warn "Added ${TARGET_USER} to the docker group (sudo-less docker from next login)."
  fi
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
}

# ---- 3. pull public image (no token) -----------------------------------------
# If no tag is set, use the public installer repo's AGENT_VERSION (= release). Called after fetch_host_files.
pull_image() {
  if [ -z "$IMAGE_TAG" ]; then
    if [ -n "${HOST_FILES_DIR:-}" ] && [ -f "${HOST_FILES_DIR}/AGENT_VERSION" ]; then
      IMAGE_TAG="$(tr -d ' \n\r\t' < "${HOST_FILES_DIR}/AGENT_VERSION")"
    fi
    [ -z "$IMAGE_TAG" ] && IMAGE_TAG="latest"   # last-resort fallback
  fi
  step "Pulling the agent image (${IMAGE}:${IMAGE_TAG})"
  if $SUDO docker pull "${IMAGE}:${IMAGE_TAG}"; then
    ok "Image ready"
  else
    die "Image pull failed. Check the GHCR package is public and the tag '${IMAGE_TAG}' exists: ${IMAGE}"
  fi
}

# ---- 4. fetch host files (public installer repo) -----------------------------
fetch_host_files() {
  step "Fetching install files (${INSTALLER_REPO})"
  local dest="${WORK_DIR}/installer"
  if command -v git >/dev/null 2>&1 && git clone --depth 1 --branch "$INSTALLER_BRANCH" "$INSTALLER_REPO" "$dest" >/dev/null 2>&1; then
    ok "Install files cloned"
  else
    warn "git clone unavailable/failed → downloading tarball"
    mkdir -p "$dest"
    curl -fsSL "$INSTALLER_TARBALL" | tar -xz -C "$dest" --strip-components=1 \
      || die "Failed to download install files: ${INSTALLER_TARBALL}"
    ok "Install files downloaded"
  fi
  HOST_FILES_DIR="$dest"
  [ -f "${HOST_FILES_DIR}/install.sh" ] || die "install.sh not found in the installer repo."
}

# ---- 5. wizard: collect settings ---------------------------------------------
collect_config() {
  splash
  STORE_NAME="${MCB_STORE_NAME:-}"
  CREDENTIALS_PATH="${MCB_CREDENTIALS_PATH:-}"
  SLACK_BOT_TOKEN="${MCB_SLACK_BOT_TOKEN:-}"
  SLACK_CHANNEL_ID="${MCB_SLACK_CHANNEL_ID:-}"

  if [ "$INTERACTIVE" = "1" ]; then
    STORE_NAME="$(ask "Store" "Store / device name for this Pi (shown in admin)" "${STORE_NAME:-$(hostname)}")"
    CREDENTIALS_PATH="$(ask "Firestore key" "Path to the Firestore service-account JSON (mycutbox110.json) if you have it; leave blank to place it after install" "${CREDENTIALS_PATH}")"
    if confirm "Set up Slack update alerts now? (optional)"; then
      SLACK_BOT_TOKEN="$(ask_secret "SLACK_BOT_TOKEN (xoxb-...)")"
      SLACK_CHANNEL_ID="$(ask "Slack channel" "SLACK_CHANNEL_ID (e.g. C0...)" "${SLACK_CHANNEL_ID}")"
    fi
  fi

  # Summary confirmation
  local summary="Install summary\n\nStore: ${STORE_NAME:-(unset)}\nImage: ${IMAGE}:${IMAGE_TAG}\nFirestore key: ${CREDENTIALS_PATH:-place after install}\nSlack: ${SLACK_BOT_TOKEN:+configured}${SLACK_BOT_TOKEN:-not set}\n\nProceed with the install?"
  confirm "$summary" || die "Install cancelled."
}

# ---- 6. run install.sh -------------------------------------------------------
run_installer() {
  step "Running the installer"
  mkdir -p "$PROJECT_DIR"
  # Pass wizard inputs to install.sh as env vars (GITHUB_TOKEN unneeded — public image).
  # MCB_NONINTERACTIVE=1 makes install.sh skip its own prompts and use these values.
  local -a env_pass=(
    "MCB_STORE_NAME=${STORE_NAME}"
    "AGENT_IMAGE=${IMAGE}"
    "AGENT_IMAGE_TAG=${IMAGE_TAG}"
    "GITHUB_TOKEN="            # public image: empty → docker login skipped
    "SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN}"
    "SLACK_CHANNEL_ID=${SLACK_CHANNEL_ID}"
    "MCB_NONINTERACTIVE=1"
  )
  # If a Firestore key path was given, copy it into place (where install.sh expects it)
  if [ -n "${CREDENTIALS_PATH}" ] && [ -f "${CREDENTIALS_PATH}" ]; then
    mkdir -p "${PROJECT_DIR}/data"
    cp -f "${CREDENTIALS_PATH}" "${PROJECT_DIR}/data/mycutbox110.json"
    ok "Firestore key placed"
  fi

  ( cd "$HOST_FILES_DIR" && $SUDO env "${env_pass[@]}" bash ./install.sh )
  ok "Installer finished"
}

# ---- 6.5 detect & handle old manual installs ---------------------------------
# Old hand-made print.mjs/usbPrint.cjs (in other paths) or custom systemd units/timers can
# conflict with the new install. Detect them and let the user choose [disable / remove / skip].
# All of OUR units are named mycutbox-*, so anything NOT starting with that prefix is "legacy"
# (prevents false positives on our own units).
LEGACY_FILES=(); LEGACY_SYS_UNITS=(); LEGACY_USER_UNITS=()

detect_legacy() {
  local th="$TARGET_HOME" d f u base
  LEGACY_FILES=(); LEGACY_SYS_UNITS=(); LEGACY_USER_UNITS=()

  # 1) print.mjs/usbPrint.cjs outside our managed path (~/.pi/agent) — direct locations only
  for d in "$th/pi" "/mycutbox620" "$th/mycutbox620" "$th/Desktop/pi" "$th/Desktop" \
           "$th/mycutbox" "/opt/mycutbox"; do
    [ -d "$d" ] || continue
    for f in print.mjs usbPrint.cjs legacyprint.mjs; do
      [ -f "$d/$f" ] && LEGACY_FILES+=("$d/$f")
    done
  done

  # 2) systemd units (system): reference print.mjs/usbPrint.cjs/legacy paths AND not named mycutbox-*
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    base="$(basename "$u")"
    case "$base" in mycutbox-*) continue ;; esac
    LEGACY_SYS_UNITS+=("$base")
  done < <(grep -rliE "print\.mjs|usbPrint\.cjs|/mycutbox620|/Desktop/pi" /etc/systemd/system 2>/dev/null | sort -u)

  # 3) systemd units (user)
  local usd="$th/.config/systemd/user"
  if [ -d "$usd" ]; then
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      base="$(basename "$u")"
      case "$base" in mycutbox-*) continue ;; esac
      LEGACY_USER_UNITS+=("$base")
    done < <(grep -rliE "print\.mjs|usbPrint\.cjs|/mycutbox620|/Desktop/pi" "$usd" 2>/dev/null | sort -u)
  fi
}

legacy_apply() {
  local mode="$1"   # disable | remove
  local backup="$TARGET_HOME/mycutbox-legacy-backup-$(date +%Y%m%d-%H%M%S)"
  local uid u; uid="$(id -u "$TARGET_USER")"

  for u in ${LEGACY_USER_UNITS[@]+"${LEGACY_USER_UNITS[@]}"}; do
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user disable --now "$u" >/dev/null 2>&1 || true
    if [ "$mode" = "remove" ]; then
      mkdir -p "$backup/user-units"
      mv -f "$TARGET_HOME/.config/systemd/user/$u" "$backup/user-units/" 2>/dev/null || true
    fi
  done
  [ ${#LEGACY_USER_UNITS[@]} -gt 0 ] && sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user daemon-reload >/dev/null 2>&1 || true

  for u in ${LEGACY_SYS_UNITS[@]+"${LEGACY_SYS_UNITS[@]}"}; do
    $SUDO systemctl disable --now "$u" >/dev/null 2>&1 || true
    if [ "$mode" = "remove" ]; then
      $SUDO mkdir -p "$backup/system-units"
      $SUDO mv -f "/etc/systemd/system/$u" "$backup/system-units/" 2>/dev/null || true
    fi
  done
  [ ${#LEGACY_SYS_UNITS[@]} -gt 0 ] && $SUDO systemctl daemon-reload >/dev/null 2>&1 || true

  if [ "$mode" = "remove" ]; then
    $SUDO mkdir -p "$backup/files"
    for u in ${LEGACY_FILES[@]+"${LEGACY_FILES[@]}"}; do
      $SUDO mv -f "$u" "$backup/files/" 2>/dev/null || true
    done
    $SUDO chown -R "$TARGET_USER:$TARGET_USER" "$backup" 2>/dev/null || true
    ok "Old installs disabled + moved to backup → $backup"
  else
    ok "Old installs disabled (files kept in place)."
  fi
}

handle_legacy() {
  step "Checking for old manual installs"
  detect_legacy
  local total=$(( ${#LEGACY_FILES[@]} + ${#LEGACY_SYS_UNITS[@]} + ${#LEGACY_USER_UNITS[@]} ))
  if [ "$total" -eq 0 ]; then
    ok "No old manual installs — clean."
    return 0
  fi

  local list=""
  [ ${#LEGACY_USER_UNITS[@]} -gt 0 ] && list+="[user services]\n$(printf '  - %s\n' "${LEGACY_USER_UNITS[@]}")"
  [ ${#LEGACY_SYS_UNITS[@]}  -gt 0 ] && list+="[system services]\n$(printf '  - %s\n' "${LEGACY_SYS_UNITS[@]}")"
  [ ${#LEGACY_FILES[@]}      -gt 0 ] && list+="[files]\n$(printf '  - %s\n' "${LEGACY_FILES[@]}")"

  warn "Found ${total} item(s) that look like an old manual install:"
  printf '%b\n' "$list"

  local choice="${MCB_LEGACY_ACTION:-}"
  if [ -z "$choice" ]; then
    if [ "$HAVE_WHIPTAIL" = "1" ]; then
      choice="$(whiptail --title "Handle old installs" --menu \
        "Choose how to avoid conflicts with the new install.\n\n${list}" 24 76 3 \
        disable "Disable only — keep files, only new install runs [recommended]" \
        remove  "Remove — disable + move to a backup folder" \
        skip    "Leave as-is — risk of conflicts" \
        3>&1 1>&2 2>&3)" || choice="disable"
    elif [ "$INTERACTIVE" = "1" ]; then
      echo "  1) Disable only — keep files, only new install runs [recommended]"
      echo "  2) Remove — disable + move to a backup folder"
      echo "  3) Leave as-is — risk of conflicts"
      local r; read -r -p "Choose [1]: " r
      case "$r" in 2) choice=remove ;; 3) choice=skip ;; *) choice=disable ;; esac
    else
      choice="disable"   # unattended default: safely disable only
    fi
  fi

  case "$choice" in
    skip)   warn "Leaving old installs as-is — manual cleanup may be needed if there are conflicts." ;;
    remove) legacy_apply "remove" ;;
    *)      legacy_apply "disable" ;;
  esac
}

# ---- action selection (install vs uninstall) --------------------------------
# Same launcher/one-liner does both — pick here. Non-interactive default = install
# (unattended runs must never uninstall). Override with MCB_ACTION=install|uninstall.
choose_action() {
  ACTION="${MCB_ACTION:-}"
  [ -n "$ACTION" ] && return 0
  if [ "$HAVE_WHIPTAIL" = "1" ]; then
    ACTION="$(whiptail --title "MyCutBox" --menu \
      "What would you like to do on this Pi?" 15 68 2 \
      install   "Install / update the MyCutBox agent" \
      uninstall "Uninstall — remove the agent from this Pi" \
      3>&1 1>&2 2>&3)" || ACTION="install"
  elif [ "$INTERACTIVE" = "1" ]; then
    echo "What would you like to do on this Pi?"
    echo "  1) Install / update the MyCutBox agent  [default]"
    echo "  2) Uninstall — remove the agent from this Pi"
    local r; read -r -p "Choose [1]: " r
    case "$r" in 2) ACTION=uninstall ;; *) ACTION=install ;; esac
  else
    ACTION="install"
  fi
}

# ---- uninstall ---------------------------------------------------------------
run_uninstaller() {
  step "Uninstalling MyCutBox"
  [ -f "${HOST_FILES_DIR}/uninstall.sh" ] || die "uninstall.sh not found in the installer repo."
  # uninstall.sh is standalone: it does its own root check, confirmation prompts,
  # and English teardown output. Hand off to it (needs root).
  ( cd "$HOST_FILES_DIR" && $SUDO bash ./uninstall.sh )
  ok "Uninstall finished"
}

# ---- 7. done -----------------------------------------------------------------
finish() {
  local msg="Install complete.\n\n- The agent now auto-starts on every boot.\n- Updates apply automatically via OTA."
  if [ -z "${CREDENTIALS_PATH}" ] || [ ! -f "${PROJECT_DIR}/data/mycutbox110.json" ]; then
    msg+="\n\nTODO: place the Firestore key at ${PROJECT_DIR}/data/mycutbox110.json, then reboot."
  fi
  if [ "$HAVE_WHIPTAIL" = "1" ]; then
    whiptail --title "Install complete" --msgbox "$msg" 14 66
  else
    printf '\n'; ok "Install complete"; printf '%b\n' "$msg"
  fi
}

finish_uninstall() {
  local msg="MyCutBox has been uninstalled.\n\n- Agent container/services stopped and removed.\n- Screen lock and OTA removed.\n\nA reboot is recommended."
  if [ "$HAVE_WHIPTAIL" = "1" ]; then
    whiptail --title "Uninstall complete" --msgbox "$msg" 13 66
  else
    printf '\n'; ok "Uninstall complete"; printf '%b\n' "$msg"
  fi
}

main() {
  preflight
  choose_action
  fetch_host_files          # tarball has both install.sh and uninstall.sh
  if [ "$ACTION" = "uninstall" ]; then
    run_uninstaller
    finish_uninstall
    return 0
  fi
  ensure_docker
  pull_image
  collect_config
  handle_legacy
  run_installer
  finish
}
main "$@"
