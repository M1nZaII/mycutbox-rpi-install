#!/bin/bash
#
# MyCutBox Raspberry Pi Docker-based Installation Script
# Automatically performs all installation steps.
#
# Installation method:
#   curl -L https://github.com/M1nZaII/mycutbox-rpi-agent/releases/latest/download/install.sh | sudo bash
#

set -euo pipefail

# During first-time setup the Pi may not have Korean fonts/locale ready yet, so any
# localized tool output (git/make/apt "fatal" messages, etc.) would show as mojibake.
# Force a C/English locale for this install run so ALL output is readable English.
# (This does not affect the system locale configured for later use.)
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
STEP='\033[1;33m'
NC='\033[0m'

# Log file
LOG_FILE="/var/log/mycutbox-install.log"
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_HOME="/home/${INSTALL_USER}"
# Firestore 키 위치. docker-compose 가 ./data/mycutbox110.json 을 마운트하고, 호스트 fleet
# 스크립트도 여기서 읽으므로 rp3 소유(~/.pi/data)로 통일한다. (물리 접근 차단은 화면잠금이 담당)
# ~/.pi 로 이름에 점을 붙인 건 파일탐색기 기본 보기에서 안 보이게 하려는 것(숨김 폴더 컨벤션) —
# migrate_legacy_pi_dir() 가 기존 ~/pi 를 감지해 1회 옮겨준다.
DATA_DIR="${INSTALL_HOME}/.pi/data"
SECURE_ENV_FILE="/etc/mycutbox/env"
CACHE_DIR="${INSTALL_HOME}/.pi/cache"
# Build directory will be determined dynamically based on available space
BUILD_DIR=""

# Repo root when install.sh lives inside a clone (for AGENT_VERSION, scripts/)
INSTALL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy scripts/ensure-rx1-cups.sh etc. from install bundle or cloned ~/.pi/agent.
resolve_repo_script() {
    local rel="$1"
    if [ -f "${INSTALL_SCRIPT_DIR}/${rel}" ]; then
        echo "${INSTALL_SCRIPT_DIR}/${rel}"
        return 0
    fi
    local agent="${INSTALL_HOME}/.pi/agent/${rel}"
    if [ -f "$agent" ]; then
        echo "$agent"
        return 0
    fi
    return 1
}

install_repo_script() {
    local rel="$1"
    local dest="$2"
    local owner="${3:-root:root}"
    local src
    src="$(resolve_repo_script "$rel")" || {
        log_error "Required script not found: ${rel}"
        exit 1
    }
    install -D -m 755 "$src" "$dest"
    chown "$owner" "$dest" 2>/dev/null || true
}

# Single source for image tag: AGENT_VERSION file (fallback if script is curl-only)
agent_version_tag() {
    local f="${INSTALL_SCRIPT_DIR}/AGENT_VERSION"
    if [ -f "$f" ]; then
        tr -d ' \n\r\t' < "$f"
    else
        echo "v1.1.8"
    fi
}

# Upsert KEY=VALUE into an env file (create if missing, replace if present).
upsert_env_var() {
    local env_file="$1" key="$2" value="$3"
    umask 077
    mkdir -p "$(dirname "$env_file")"
    touch "$env_file" 2>/dev/null || true
    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        echo "${key}=${value}" >> "$env_file"
    fi
    chown root:root "$env_file" 2>/dev/null || true
    chmod 600 "$env_file" 2>/dev/null || true
}

# Merge AGENT_IMAGE_TAG= into secure env file.
upsert_agent_image_tag_in_env() {
    local env_file="$1"
    upsert_env_var "$env_file" "AGENT_IMAGE_TAG" "$(agent_version_tag)"
}

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_step() {
    echo -e "\n${STEP}========================================${NC}"
    echo -e "${STEP}$1${NC}"
    echo -e "${STEP}========================================${NC}\n" | tee -a "$LOG_FILE"
}

# Check root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "This script requires root privileges. Please run with sudo."
        exit 1
    fi
}

# Find directory with enough space
find_build_dir() {
    local required_gb=2
    local candidates=(
        "/var/tmp/mycutbox-build"
        "${INSTALL_HOME}/tmp/mycutbox-build"
        "/tmp/mycutbox-build"
    )
    
    for dir in "${candidates[@]}"; do
        # Get available space in KB
        local available_kb=$(df -k "$(dirname "$dir")" 2>/dev/null | tail -1 | awk '{print $4}')
        if [ -z "$available_kb" ] || [ "$available_kb" = "" ]; then
            continue
        fi
        
        # Convert to GB (rough estimate)
        local available_gb=$((available_kb / 1024 / 1024))
        
        if [ "$available_gb" -ge "$required_gb" ]; then
            BUILD_DIR="$dir"
            log_info "Using build directory: $BUILD_DIR (${available_gb}GB available)"
            return 0
        fi
    done
    
    log_error "Insufficient disk space in all candidate directories!"
    log_error "Required: ${required_gb}GB"
    log_error "Please free up space or manually specify BUILD_DIR environment variable."
    log_error "Example: sudo BUILD_DIR=/path/to/large/disk bash install.sh"
    exit 1
}

# curl|bash 로 실행되면 stdin 이 스크립트 자신을 실어나르는 파이프라 read -p 가 못 먹는다
# (즉시 취소되는 것처럼 보임). 실제 터미널 입력은 /dev/tty 에서 직접 받는다 (rustup/homebrew
# 설치 스크립트와 동일한 트릭). MCB_NONINTERACTIVE=1 이면 그냥 y로 자동 진행(마법사가 이미
# 한 번 확인했으므로 여기서 또 묻지 않음).
confirm_prompt() {
    local msg="$1"
    if [ "${MCB_NONINTERACTIVE:-0}" = "1" ]; then
        log_info "MCB_NONINTERACTIVE=1: auto-confirming '${msg}'"
        REPLY="y"
        return 0
    fi
    if [ -t 0 ]; then
        read -p "$msg" -n 1 -r
    # /dev/tty 노드는 컨트롤링 터미널이 없어도 항상 "존재"해서 -r 테스트로는 못 가른다
    # (열어봐야 ENXIO를 만남). 실제로 열어서 probe 한다 — set -e 아래서도 elif 조건이라 안전.
    elif : 2>/dev/null < /dev/tty; then
        read -p "$msg" -n 1 -r </dev/tty
    else
        log_error "No terminal available to confirm '${msg}'. Set MCB_NONINTERACTIVE=1 to run unattended."
        exit 1
    fi
    echo
}

# Check disk space (if BUILD_DIR is already set)
check_disk_space() {
    local required_gb=2
    local dir_to_check="${BUILD_DIR:-/var/tmp}"
    
    # Get available space in KB
    local available_kb=$(df -k "$dir_to_check" 2>/dev/null | tail -1 | awk '{print $4}')
    if [ -z "$available_kb" ] || [ "$available_kb" = "" ]; then
        log_warn "Cannot check disk space for $dir_to_check, continuing anyway..."
        return 0
    fi
    
    # Convert to GB (rough estimate)
    local available_gb=$((available_kb / 1024 / 1024))
    
    if [ "$available_gb" -lt "$required_gb" ]; then
        log_warn "Low disk space: ${available_gb}GB available (recommended: ${required_gb}GB)"
        log_warn "Installation may fail if space runs out."
        confirm_prompt "Continue anyway? (y/N): "
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled."
            exit 0
        fi
    else
        log_info "Disk space check: ${available_gb}GB available (required: ${required_gb}GB)"
    fi
}

# Confirm installation
confirm_install() {
    log_info "Installation target user: $INSTALL_USER"
    log_info "Data directory: $DATA_DIR"
    
    # Find build directory with enough space (unless already set via env)
    if [ -z "${BUILD_DIR:-}" ]; then
        find_build_dir
    else
        BUILD_DIR="${BUILD_DIR}"
        log_info "Using specified build directory: $BUILD_DIR"
    fi
    
    check_disk_space
    confirm_prompt "Continue? (y/N): "
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled."
        exit 0
    fi
}

# 기존 ~/pi 를 파일탐색기 기본 보기에서 숨겨지는 ~/.pi 로 1회 옮긴다 (재설치 시에만 해당 —
# 완전 새 기기는 ~/pi 가 없어서 바로 return). 서비스가 그 경로를 물고 있는 채로 mv 하면
# 위험하니 잠깐 멈췄다 옮기고 다시 올린다. install.sh 는 사람이 재실행할 수 있는 스크립트라
# 실패하면 그냥 멈춘다 — 이후 나머지 로직이 전부 ~/.pi 를 전제하기 때문에 어설픈 폴백보다는
# 명확히 실패하고 재실행을 유도하는 편이 안전하다.
migrate_legacy_pi_dir() {
    local old="${INSTALL_HOME}/pi"
    local new="${INSTALL_HOME}/.pi"
    [ -d "$new" ] && return 0
    [ -d "$old" ] || return 0

    log_step "Migrating ${old} -> ${new} (hide from casual file-manager browsing)"
    local uid
    uid=$(id -u "$INSTALL_USER")

    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$uid systemctl --user stop mycutbox-usb-print.service" 2>/dev/null || true
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$uid systemctl --user stop mycutbox-connect-wifi.service" 2>/dev/null || true
    su - "$INSTALL_USER" -c "cd '$old' && docker compose stop composite-print" 2>/dev/null || true

    if ! mv "$old" "$new"; then
        log_error "Migration failed: mv ${old} -> ${new}. Fix the issue (permissions/disk space) and re-run install.sh."
        exit 1
    fi
    log_info "Migration OK: ${new}"
}

# 1. Install system packages
install_system_packages() {
    log_step "1. Installing System Packages"
    
    apt update
    apt install -y \
        curl \
        git \
        unzip \
        locales \
        imagemagick \
        fontconfig \
        fonts-unfonts-core \
        fonts-noto-cjk \
        fonts-nanum \
        fonts-nanum-extra \
        fonts-liberation \
        fonts-comic-neue \
        ibus \
        ibus-hangul \
        usbmuxd \
        ipheth-utils \
        libimobiledevice-utils \
        ifuse \
        gtklock \
        swayidle

    # Node.js 18+ (host-run usb-print)
    if ! command -v node &>/dev/null; then
        log_info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt install -y nodejs
    fi
    NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
    if [ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -lt 18 ]; then
        log_info "Upgrading Node.js to v20..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt install -y nodejs
    fi
    log_info "Node.js: $(node -v 2>/dev/null || echo 'not found')"
    
    log_info "System packages installed"
}

# 1c. Fonts for composite-print text (Canvas / @napi-rs/canvas + ImageMagick)
# @napi-rs/canvas 는 Skia 네이티브 바인딩을 npm 으로 포함 — libcairo-dev 등 별도 apt 불필요.
# 운영 composite-print 는 Docker 이미지 안에서 실행(이미지 Dockerfile 에도 동일 폰트 설치).
# 호스트에서 print.mjs 를 직접 돌리거나, fontconfig 캐시를 맞추려면 아래 폰트를 호스트에도 둡니다.
install_composite_print_fonts() {
    log_step "1c. Installing Composite Print Fonts (KoPub, Pretendard, …)"

    local font_root="/usr/share/fonts/truetype/mycutbox"
    mkdir -p \
        "${font_root}/pretendard" \
        "${font_root}/kopubbatang" \
        "${font_root}/jua" \
        "${font_root}/gowunbatang" \
        "${font_root}/maruburi"

    log_info "Pretendard…"
    if curl -sfL --retry 3 --retry-delay 2 \
        "https://github.com/orioncactus/pretendard/releases/download/v1.3.9/Pretendard-1.3.9.zip" \
        -o /tmp/pretendard-mycutbox.zip; then
        unzip -q -o /tmp/pretendard-mycutbox.zip -d /tmp/pretendard-mycutbox
        find /tmp/pretendard-mycutbox -type f \( -name "*.ttf" -o -name "*.otf" \) \
            -exec cp {} "${font_root}/pretendard/" \;
        rm -rf /tmp/pretendard-mycutbox /tmp/pretendard-mycutbox.zip
    else
        log_warn "Pretendard download failed (optional; Noto/Nanum still available)"
    fi

    log_info "KoPub Batang, Jua, Gowun Batang…"
    curl -sfL --retry 3 --retry-delay 2 \
        "https://raw.githubusercontent.com/google/fonts/main/ofl/kopubbatang/KoPubBatang-Regular.ttf" \
        -o "${font_root}/kopubbatang/KoPubBatang-Regular.ttf" || log_warn "KoPub Batang Regular download failed"
    curl -sfL --retry 3 --retry-delay 2 \
        "https://raw.githubusercontent.com/google/fonts/main/ofl/kopubbatang/KoPubBatang-Bold.ttf" \
        -o "${font_root}/kopubbatang/KoPubBatang-Bold.ttf" || true
    curl -sfL --retry 3 --retry-delay 2 \
        "https://raw.githubusercontent.com/google/fonts/main/ofl/kopubbatang/KoPubBatang-Light.ttf" \
        -o "${font_root}/kopubbatang/KoPubBatang-Light.ttf" || true
    curl -sfL --retry 3 --retry-delay 2 \
        "https://raw.githubusercontent.com/google/fonts/main/ofl/jua/Jua-Regular.ttf" \
        -o "${font_root}/jua/Jua-Regular.ttf" || true
    curl -sfL --retry 3 --retry-delay 2 \
        "https://raw.githubusercontent.com/google/fonts/main/ofl/gowunbatang/GowunBatang-Regular.ttf" \
        -o "${font_root}/gowunbatang/GowunBatang-Regular.ttf" || true
    curl -sfL --retry 3 --retry-delay 2 \
        "https://raw.githubusercontent.com/google/fonts/main/ofl/gowunbatang/GowunBatang-Bold.ttf" \
        -o "${font_root}/gowunbatang/GowunBatang-Bold.ttf" || true
    curl -sfL --retry 3 --retry-delay 2 \
        "https://hangeul.pstatic.net/hangeul_static/webfont/MaruBuri/MaruBuri-Regular.ttf" \
        -o "${font_root}/maruburi/MaruBuri-Regular.ttf" || log_warn "MaruBuri Regular download failed"
    curl -sfL --retry 3 --retry-delay 2 \
        "https://hangeul.pstatic.net/hangeul_static/webfont/MaruBuri/MaruBuri-SemiBold.ttf" \
        -o "${font_root}/maruburi/MaruBuri-SemiBold.ttf" || true
    curl -sfL --retry 3 --retry-delay 2 \
        "https://hangeul.pstatic.net/hangeul_static/webfont/MaruBuri/MaruBuri-Bold.ttf" \
        -o "${font_root}/maruburi/MaruBuri-Bold.ttf" || true

    fc-cache -f -v 2>/dev/null || true
    log_info "Composite print fonts installed (fc-cache refreshed)"
    log_info "Canvas npm (@napi-rs/canvas): no extra apt — use 'docker compose pull' for composite-print image updates"
}

# 1b. Setup Korean locale
setup_korean_locale() {
    log_step "1b. Setting Up Korean Locale"
    
    # Ensure ko_KR.UTF-8 is available
    if ! grep -q '^ko_KR.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null; then
        if grep -q '# ko_KR.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null; then
            sed -i 's/# ko_KR.UTF-8 UTF-8/ko_KR.UTF-8 UTF-8/' /etc/locale.gen
        else
            echo 'ko_KR.UTF-8 UTF-8' >> /etc/locale.gen
        fi
    fi
    
    locale-gen
    update-locale LANG=ko_KR.UTF-8 2>/dev/null || true
    
    log_info "Korean locale (ko_KR.UTF-8) configured"
    log_warn "Log out and log back in for locale to take effect system-wide"
}

# 2. Install Gutenprint
install_gutenprint() {
    log_step "2. Installing Gutenprint"
    
    # Create build directory
    mkdir -p "$BUILD_DIR"
    chmod 1777 "$BUILD_DIR" 2>/dev/null || true
    
    # Remove existing packages
    log_info "Removing existing gutenprint packages..."
    apt remove -y *gutenprint* ipp-usb 2>/dev/null || true
    
    # Install required packages
    log_info "Installing required development libraries..."
    apt install -y \
        libusb-1.0-0-dev \
        libcups2-dev \
        pkg-config \
        cups-daemon \
        git-lfs \
        libjpeg-progs
    
    # Download and compile Gutenprint
    log_info "Downloading Gutenprint..."
    GUTENPRINT_VER="5.3.5-pre1-2025-02-13T14-28-b60f1e83"
    GUTENPRINT_TARBALL="gutenprint-${GUTENPRINT_VER}.tar.xz"
    cd "$BUILD_DIR"
    # 이전 실행에서 curl이 (SourceForge 에러 페이지 등을) 그대로 저장해버린 손상 파일이
    # 남아있으면, "파일이 있으니 재다운로드 skip"에 걸려 매번 같은 실패가 반복된다
    # (실측: xz: File format not recognized). 캐시를 쓰기 전에 실제로 유효한지 검증한다.
    if [ -f "$GUTENPRINT_TARBALL" ] && ! tar -tJf "$GUTENPRINT_TARBALL" >/dev/null 2>&1; then
        log_warn "Cached ${GUTENPRINT_TARBALL} is corrupt (previous failed download) — re-fetching"
        rm -f "$GUTENPRINT_TARBALL"
    fi
    if [ ! -f "$GUTENPRINT_TARBALL" ]; then
        # -f: HTTP 에러(404 등)를 성공으로 착각해 에러 페이지를 그대로 저장하지 않게 한다.
        if ! curl -fSL --retry 3 --retry-delay 2 -o "$GUTENPRINT_TARBALL" \
            "https://master.dl.sourceforge.net/project/gimp-print/snapshots/${GUTENPRINT_TARBALL}?viasf=1"; then
            rm -f "$GUTENPRINT_TARBALL"
            log_error "Failed to download Gutenprint from SourceForge"
            exit 1
        fi
    fi

    log_info "Extracting archive..."
    tar -xJf "$GUTENPRINT_TARBALL"
    
    log_info "Compiling... (this may take some time)"
    cd "gutenprint-${GUTENPRINT_VER}"
    ./configure --without-doc --enable-debug
    make -j4
    make install
    cd ..
    
    # Update PPD and restart CUPS
    log_info "Updating PPD..."
    cups-genppdupdate || true
    service cups restart
    
    # Compile selphy_print (선택적 프린터 백엔드; DNP RX1 실제 인쇄에 쓰임).
    # 예전엔 clone 실패나 이전 시도가 남긴 빈 디렉터리 때문에 make 가 "no Makefile" 로 죽어
    # 설치 전체가 중단됐다. Makefile 존재를 직접 확인해 새로 clone 하고, 실패해도 설치를 멈추지 않는다.
    log_info "Installing selphy_print backend (optional)..."
    cd "$BUILD_DIR"
    if [ ! -f "selphy_print/Makefile" ]; then
        rm -rf selphy_print 2>/dev/null || true
        git clone --depth 1 https://git.shaftnet.org/gitea/slp/selphy_print.git \
            || log_warn "selphy_print clone failed (git.shaftnet.org reachable?) — continuing without the backend."
    fi
    if [ -f "selphy_print/Makefile" ]; then
        (
            cd selphy_print || exit 1
            git clean -fd >/dev/null 2>&1 || true
            make -j4
            make install
        ) || log_warn "selphy_print build/install failed — continuing without the backend."
    else
        log_warn "selphy_print Makefile not found — skipping the backend. (If the printer does not print, install it manually.)"
    fi

    # Set library path (gutenprint /usr/local/lib) — 백엔드 유무와 무관하게 항상 실행
    echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local.conf
    ldconfig
    
    log_info "Gutenprint installation complete"
    log_info "Build files are in $BUILD_DIR (can be cleaned up later)"
}

# 3. Install Docker
install_docker() {
    log_step "3. Installing Docker"
    
    if command -v docker &> /dev/null; then
        log_info "Docker is already installed: $(docker --version)"
    else
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
    fi

    # Always run: if Docker was pre-installed, the old script returned early and skipped this.
    usermod -aG docker "$INSTALL_USER"
    usermod -aG lp "$INSTALL_USER"
    log_info "User $INSTALL_USER added to docker and lp groups (log out and back in for docker)"

    # Docker Compose v2 plugin (install if missing)
    if docker compose version >/dev/null 2>&1; then
        log_info "Docker Compose plugin is available"
    else
        log_info "Installing Docker Compose..."
        apt install -y docker-compose-plugin || {
            curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
                -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        }
    fi

    log_info "Docker setup complete: $(docker --version 2>/dev/null || echo 'docker')"
}

# 4. Setup directories and files
setup_directories() {
    log_step "4. Setting Up Directories"
    
    mkdir -p "$DATA_DIR"
    mkdir -p /etc/mycutbox
    mkdir -p "$CACHE_DIR"
    mkdir -p "${CACHE_DIR}/frames"
    
    mkdir -p "${INSTALL_HOME}/.pi/gvfs-stub"
    touch "${INSTALL_HOME}/.pi/gvfs-stub/.gitkeep"
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "${INSTALL_HOME}/.pi"
    chown -R root:root /etc/mycutbox
    chmod 700 /etc/mycutbox   # secure env (GITHUB_TOKEN/Slack) stays root-only

    log_info "Directories created"
    log_warn "You need to place the following file:"
    log_warn "  - ${DATA_DIR}/mycutbox110.json (Firestore service account key)"
}

# 5. Copy docker-compose.yml
setup_docker_compose() {
    log_step "5. Setting Up Docker Compose"
    
    COMPOSE_FILE="${INSTALL_HOME}/.pi/docker-compose.yml"
    
    # Find directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SOURCE_COMPOSE="${SCRIPT_DIR}/docker-compose.yml"
    
    # Use local file if available
    if [ -f "$SOURCE_COMPOSE" ]; then
        log_info "Copying local docker-compose.yml file..."
        cp "$SOURCE_COMPOSE" "$COMPOSE_FILE"
        log_info "Copy complete"
    else
        log_warn "docker-compose.yml file not found."
        log_warn "Creating default template..."
        cat > "$COMPOSE_FILE" << EOF
services:
  composite-print:
    image: ghcr.io/m1nzaii/mycutbox-rpi-agent:\${AGENT_IMAGE_TAG}
    container_name: mycutbox-composite-print
    restart: unless-stopped
    user: "1000:1000"
    environment:
      - GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/mycutbox110.json
      - NODE_ENV=production
      - PRINTER_NAME=\${PRINTER_NAME:-RX1}
      - SLACK_BOT_TOKEN=\${SLACK_BOT_TOKEN:-}
      - SLACK_CHANNEL_ID=\${SLACK_CHANNEL_ID:-}
      - PRINT_ERROR_SLACK_WINDOW_MS=\${PRINT_ERROR_SLACK_WINDOW_MS:-600000}
      - PRINT_ERROR_SLACK_MIN_COUNT=\${PRINT_ERROR_SLACK_MIN_COUNT:-5}
    volumes:
      - /etc/mycutbox/secrets/mycutbox110.json:/run/secrets/mycutbox110.json:ro
      - ./cache:/home/rp3/.cache/mycutbox
      - /var/run/cups/cups.sock:/var/run/cups/cups.sock:ro
    network_mode: host
    command: ["node", "print.mjs"]
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "4"

  # usb-print: host systemd (GVFS); see install.sh
EOF
    fi
    
    # Warn about GitHub repository URL modification if needed
    log_info "Docker Compose uses AGENT_IMAGE_TAG from ${SECURE_ENV_FILE} (tag from AGENT_VERSION: $(agent_version_tag))"
    
    chown "${INSTALL_USER}:${INSTALL_USER}" "$COMPOSE_FILE"
    log_info "Docker Compose setup complete"
}

# Append SLACK_BOT_TOKEN / SLACK_CHANNEL_ID when missing (TTY only). OTA uses these for chat.postMessage + threading.
append_slack_bot_env_if_missing() {
    local ENV_FILE="$1"
    local need_bot=0 need_ch=0
    [ -f "$ENV_FILE" ] || return 0
    grep -q '^SLACK_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null || need_bot=1
    grep -q '^SLACK_CHANNEL_ID=' "$ENV_FILE" 2>/dev/null || need_ch=1
    if [ "$need_bot" -eq 0 ] && [ "$need_ch" -eq 0 ]; then
        return 0
    fi
    if [ ! -t 0 ] || [ "${MCB_NONINTERACTIVE:-0}" = "1" ]; then
        return 0
    fi
    local SLACK_BOT_TOKEN_INPUT=""
    local SLACK_CHANNEL_ID_INPUT=""
    echo ""
    log_info "Optional: Slack OTA alerts via Bot User OAuth Token (Web API chat.postMessage, threaded replies)."
    log_info "Slack app: OAuth & Permissions → Bot Token Scopes → chat:write → reinstall app → copy Bot User OAuth Token."
    log_info "Invite the bot to the channel. Channel: Channel ID (C…) or public channel often as #name."
    if [ "$need_bot" -eq 1 ]; then
        read -p "Enter SLACK_BOT_TOKEN xoxb-... (Enter to skip): " -s SLACK_BOT_TOKEN_INPUT
        echo ""
    fi
    if [ "$need_ch" -eq 1 ]; then
        read -p "Enter SLACK_CHANNEL_ID or #channel (Enter to skip): " SLACK_CHANNEL_ID_INPUT
        echo ""
    fi
    if [ "$need_bot" -eq 1 ] && [ -n "${SLACK_BOT_TOKEN_INPUT:-}" ]; then
        echo "SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN_INPUT}" >> "$ENV_FILE"
    fi
    if [ "$need_ch" -eq 1 ] && [ -n "${SLACK_CHANNEL_ID_INPUT:-}" ]; then
        echo "SLACK_CHANNEL_ID=${SLACK_CHANNEL_ID_INPUT}" >> "$ENV_FILE"
    fi
    if { [ "$need_bot" -eq 1 ] && [ -n "${SLACK_BOT_TOKEN_INPUT:-}" ]; } || { [ "$need_ch" -eq 1 ] && [ -n "${SLACK_CHANNEL_ID_INPUT:-}" ]; }; then
        chown root:root "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        log_info "Slack Bot settings saved to ${ENV_FILE}."
    else
        log_info "Slack Bot settings skipped (edit secure env later)."
    fi
}

# 5b. Setup secure env (GITHUB_TOKEN for private image pull)
setup_env_file() {
    log_step "5b. Setting Up Secure Env (GHCR Token)"
    
    ENV_FILE="${SECURE_ENV_FILE}"

    # Always align image tag with repo AGENT_VERSION (single source of truth).
    upsert_agent_image_tag_in_env "$ENV_FILE"
    # 프린터 종류(RX1/DS620 등)를 설치 시 넘겨받으면 저장 — OTA 스크립트와
    # ensure-rx1-cups.service(EnvironmentFile=-/etc/mycutbox/env)가 여기서 읽는다.
    [ -n "${PRINTER_NAME:-}" ] && upsert_env_var "$ENV_FILE" "PRINTER_NAME" "$PRINTER_NAME"

    if [ -f "$ENV_FILE" ] && grep -q "^GITHUB_TOKEN=." "$ENV_FILE" 2>/dev/null; then
        log_info "Secure env already exists with GITHUB_TOKEN"
        chown root:root "$ENV_FILE"
        chmod 600 "$ENV_FILE"

        append_slack_bot_env_if_missing "$ENV_FILE"

        return 0
    fi
    
    GITHUB_USERNAME="${GITHUB_USERNAME:-m1nzaii}"
    # 공개 이미지 방식에선 GITHUB_TOKEN 불필요. 부트스트랩(비대화형)이 값을 미리 넘겨주면 그걸 쓰고,
    # 그렇지 않은 standalone 대화형 실행일 때만 물어본다 (Slack 도 마찬가지로 중복 프롬프트 방지).
    GITHUB_TOKEN="${GITHUB_TOKEN:-}"
    SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
    SLACK_CHANNEL_ID="${SLACK_CHANNEL_ID:-}"

    if [ -t 0 ] && [ "${MCB_NONINTERACTIVE:-0}" != "1" ]; then
        echo ""
        log_info "Private Docker images require a GitHub PAT with read:packages scope."
        log_info "(Public image: press Enter to skip — no token needed.)"
        read -p "Enter GitHub PAT (or press Enter to skip): " -s GITHUB_TOKEN
        echo ""

        echo ""
        log_info "Optional: Slack OTA via Bot User OAuth Token + channel (threaded DONE/SKIP/ERROR)."
        log_info "Slack app: chat:write scope, install app, invite bot to channel."
        read -p "Enter SLACK_BOT_TOKEN xoxb-... (Enter to skip): " -s SLACK_BOT_TOKEN
        echo ""
        read -p "Enter SLACK_CHANNEL_ID or #channel (Enter to skip): " SLACK_CHANNEL_ID
        echo ""
    fi
    
    umask 077
    {
        echo "GITHUB_USERNAME=${GITHUB_USERNAME}"
        printf '%s\n' "GITHUB_TOKEN=${GITHUB_TOKEN}"
        echo "AGENT_IMAGE_TAG=$(agent_version_tag)"
        echo "# Optional: Watchtower is removed; OTA is handled by systemd timer/service."
        echo "# Slack: prefer SLACK_BOT_TOKEN + SLACK_CHANNEL_ID for OTA (threading). Legacy: SLACK_WEBHOOK_URL= (no threads)."
        if [ -n "$SLACK_BOT_TOKEN" ]; then
            echo "SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN}"
        fi
        if [ -n "$SLACK_CHANNEL_ID" ]; then
            echo "SLACK_CHANNEL_ID=${SLACK_CHANNEL_ID}"
        fi
    } > "$ENV_FILE"
    chown root:root "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    
    if [ -n "$GITHUB_TOKEN" ]; then
        log_info "Logging in to GHCR as ${INSTALL_USER}..."
        TMP_TOKEN=$(mktemp)
        chmod 600 "$TMP_TOKEN"
        printf '%s' "$GITHUB_TOKEN" > "$TMP_TOKEN"
        chown "$INSTALL_USER" "$TMP_TOKEN"
        if su "$INSTALL_USER" -c "docker login ghcr.io -u $GITHUB_USERNAME --password-stdin < $TMP_TOKEN" 2>/dev/null; then
            log_info "GHCR login successful"
        else
            log_warn "docker login failed (run 'newgrp docker' first). Then:"
            log_warn "  echo TOKEN | docker login ghcr.io -u $GITHUB_USERNAME --password-stdin"
        fi
        rm -f "$TMP_TOKEN"
        log_info "Secure env created with GITHUB_TOKEN"
    else
        log_warn "Secure env created with empty GITHUB_TOKEN. Edit ${ENV_FILE} and add token for private images."
    fi
}

# 5c. Operational env → ~/.pi/.env (compose + OTA read this; both run as the user, not root).
# /etc/mycutbox/env stays root:600, but the user-level OTA can't read it, and docker compose
# auto-loads ~/.pi/.env — so the operational vars (image tag + Slack) must live here too.
setup_pi_env() {
    log_step "5c. Writing Operational Env (~/.pi/.env)"
    local pienv="${INSTALL_HOME}/.pi/.env"
    touch "$pienv"
    _upsert_pienv() {
        local k="$1" v="$2"
        if grep -q "^${k}=" "$pienv" 2>/dev/null; then
            sed -i "s|^${k}=.*|${k}=${v}|" "$pienv"
        else
            echo "${k}=${v}" >> "$pienv"
        fi
    }
    _upsert_pienv AGENT_IMAGE_TAG "${AGENT_IMAGE_TAG:-$(agent_version_tag)}"
    # docker-compose.yml의 PRINTER_NAME=${PRINTER_NAME:-RX1}이 여기서 값을 읽는다 — 안 쓰면
    # 항상 기본값 RX1로 떨어져서 DS620 Pi에서도 계속 RX1 큐로 인쇄를 시도하게 된다.
    [ -n "${PRINTER_NAME:-}" ]     && _upsert_pienv PRINTER_NAME     "${PRINTER_NAME}"
    [ -n "${SLACK_BOT_TOKEN:-}" ]  && _upsert_pienv SLACK_BOT_TOKEN  "${SLACK_BOT_TOKEN}"
    [ -n "${SLACK_CHANNEL_ID:-}" ] && _upsert_pienv SLACK_CHANNEL_ID "${SLACK_CHANNEL_ID}"
    chown "${INSTALL_USER}:${INSTALL_USER}" "$pienv"
    chmod 600 "$pienv"
    log_info "~/.pi/.env updated (AGENT_IMAGE_TAG${PRINTER_NAME:+, PRINTER_NAME}${SLACK_BOT_TOKEN:+, SLACK_*})"
}

# 6. Setup CUPS permissions
setup_cups_permissions() {
    log_step "6. Setting Up CUPS Permissions"
    
    # Add user to lp group for CUPS access
    usermod -aG lp "$INSTALL_USER" 2>/dev/null || true
    
    # Add user to lpadmin to prevent "Forbidden" when managing printers
    usermod -aG lpadmin "$INSTALL_USER" 2>/dev/null || true
    
    # Enable remote administration (for web interface)
    cupsctl --remote-admin --remote-any || true

    # CUPS 기본값은 WebInterface=No라서 재설치/새 Pi마다 "Web Interface is Disabled"가
    # 반복됐다 — 매번 켜지도록 고정.
    cupsctl WebInterface=yes || true

    # Allow all users to print (optional; --user-group-any not available on all CUPS versions)
    cupsctl --user-cancel-any 2>/dev/null || true
    
    # Restart CUPS to apply changes
    systemctl restart cups || service cups restart
    
    log_info "CUPS permissions configured"
    log_info "User $INSTALL_USER added to lp and lpadmin groups"
    log_warn "You may need to log out and log back in for CUPS access to work"
    log_warn "Or run: newgrp lp"
}

# 6b. Setup usb-print (host, GVFS)
setup_usb_print_native() {
    log_step "6b. Setting Up USB Print (host)"
    
    AGENT_DIR="${INSTALL_HOME}/.pi/agent"
    ENV_FILE="${SECURE_ENV_FILE}"
    mkdir -p "$AGENT_DIR/scripts"

    # Populate the agent dir from the public installer bundle that sits next to this install.sh
    # (the bootstrap fetched it from the public installer repo). No private git clone, no token.
    # Works standalone too: a private-repo checkout also has these files next to install.sh.
    log_info "Installing host agent files from the installer bundle..."
    local _f _copied=0
    for _f in usbPrint.cjs connectWifi.cjs package.json AGENT_VERSION mycutbox-ota-update.sh docker-compose.yml; do
        if [ -f "${INSTALL_SCRIPT_DIR}/${_f}" ]; then
            cp -f "${INSTALL_SCRIPT_DIR}/${_f}" "${AGENT_DIR}/${_f}"; _copied=1
        fi
    done
    for _f in "${INSTALL_SCRIPT_DIR}"/scripts/*.mjs "${INSTALL_SCRIPT_DIR}"/scripts/*.sh; do
        [ -e "$_f" ] && cp -f "$_f" "${AGENT_DIR}/scripts/"
    done
    [ "$_copied" -eq 1 ] || log_warn "Installer bundle not found next to install.sh — agent files may be incomplete."
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "$AGENT_DIR"

    if [ -f "${AGENT_DIR}/package.json" ]; then
        log_info "Installing npm dependencies..."
        su - "$INSTALL_USER" -c "cd $AGENT_DIR && npm install --production" || log_warn "npm install failed (continuing)."
    else
        log_warn "package.json not found in agent dir — skipping npm install (host scripts may lack deps)."
    fi
    
    # systemd user service (GVFS under /run/user/UID/gvfs)
    USER_SVC_DIR="${INSTALL_HOME}/.config/systemd/user"
    mkdir -p "$USER_SVC_DIR"
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "$USER_SVC_DIR"
    
    INSTALL_UID=$(id -u "$INSTALL_USER")
    cat > "$USER_SVC_DIR/mycutbox-usb-print.service" << EOF
[Unit]
Description=MyCutBox USB Print Watcher (GVFS)
After=network.target

[Service]
Type=simple
WorkingDirectory=$AGENT_DIR
ExecStart=/usr/bin/node usbPrint.cjs
Environment=NODE_ENV=production
Environment=PRINTER_NAME=${PRINTER_NAME:-RX1}
Environment=GVFS_BASE=/run/user/$INSTALL_UID/gvfs
Environment=USB_APP_REL_DIR=com.mycutbox/MyCutBox,com.mycutbox.kiosk/MyCutBox
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
    chown "${INSTALL_USER}:${INSTALL_USER}" "$USER_SVC_DIR/mycutbox-usb-print.service"
    
    # linger: allow user services without login session
    loginctl enable-linger "$INSTALL_USER" 2>/dev/null || true
    
    log_info "Enabling usb-print service..."
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user daemon-reload"
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user enable mycutbox-usb-print.service"
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user start mycutbox-usb-print.service" 2>/dev/null || true
}

# 6c. Setup connect-wifi (host, GVFS) — iPad USB Wi-Fi provisioning
setup_connect_wifi_native() {
    log_step "6c. Setting Up Connect Wi-Fi (host)"

    AGENT_DIR="${INSTALL_HOME}/.pi/agent"
    USER_SVC_DIR="${INSTALL_HOME}/.config/systemd/user"
    INSTALL_UID=$(id -u "$INSTALL_USER")

    if [ ! -f "${AGENT_DIR}/connectWifi.cjs" ]; then
        log_warn "connectWifi.cjs not found in ${AGENT_DIR} — skipping connect-wifi service."
        return 0
    fi

    mkdir -p "$USER_SVC_DIR"
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "$USER_SVC_DIR"

    cat > "$USER_SVC_DIR/mycutbox-connect-wifi.service" << EOF
[Unit]
Description=MyCutBox USB Wi-Fi Provisioning Watcher (GVFS)
After=network.target

[Service]
Type=simple
WorkingDirectory=$AGENT_DIR
ExecStart=/usr/bin/node connectWifi.cjs
Environment=NODE_ENV=production
Environment=GVFS_BASE=/run/user/$INSTALL_UID/gvfs
Environment=USB_APP_REL_DIR=com.mycutbox/MyCutBox,com.mycutbox.kiosk/MyCutBox
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
    chown "${INSTALL_USER}:${INSTALL_USER}" "$USER_SVC_DIR/mycutbox-connect-wifi.service"

    if [ "$(id -u)" -eq 0 ]; then
        cat > /etc/sudoers.d/mycutbox-connect-wifi << EOF
# Allow the MyCutBox agent user to run these for USB Wi-Fi provisioning (connectWifi.cjs):
#   nmcli        - scan/connect/manage connection profiles
#   iw           - disable wifi power-save (brcmfmac drops association mid-handshake otherwise)
#   systemctl    - restart NetworkManager as a one-shot self-heal after a total connect failure
${INSTALL_USER} ALL=(ALL) NOPASSWD: /usr/bin/nmcli, /usr/sbin/iw, /usr/bin/systemctl restart NetworkManager
EOF
        chmod 0440 /etc/sudoers.d/mycutbox-connect-wifi
        if visudo -cf /etc/sudoers.d/mycutbox-connect-wifi >/dev/null 2>&1; then
            log_info "sudoers: /etc/sudoers.d/mycutbox-connect-wifi"
        else
            log_warn "sudoers validation failed for mycutbox-connect-wifi — nmcli may need manual permission."
            rm -f /etc/sudoers.d/mycutbox-connect-wifi
        fi
    else
        log_warn "Not root — skipping sudoers for nmcli (connect-wifi may fail without NetworkManager permissions)."
    fi

    log_info "Enabling connect-wifi service..."
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user daemon-reload"
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user enable mycutbox-connect-wifi.service"
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user start mycutbox-connect-wifi.service" 2>/dev/null || true
}

# 7. Setup OTA controller (replaces watchtower)
setup_ota_controller() {
    log_step "7. Setting Up OTA Controller"

    OTA_DST="/usr/local/bin/mycutbox-ota-update"
    AGENT_HOME="${INSTALL_HOME}/.pi/agent"
    # Prefer cloned agent repo (always correct after step 6b); fallback to directory of this script.
    OTA_SRC=""
    if [ -f "${AGENT_HOME}/mycutbox-ota-update.sh" ]; then
        OTA_SRC="${AGENT_HOME}/mycutbox-ota-update.sh"
    elif [ -f "${INSTALL_SCRIPT_DIR}/mycutbox-ota-update.sh" ]; then
        OTA_SRC="${INSTALL_SCRIPT_DIR}/mycutbox-ota-update.sh"
    fi

    if [ -z "$OTA_SRC" ] || [ ! -f "$OTA_SRC" ]; then
        log_error "OTA update script not found. Checked:"
        log_error "  ${AGENT_HOME}/mycutbox-ota-update.sh"
        log_error "  ${INSTALL_SCRIPT_DIR}/mycutbox-ota-update.sh"
        log_error "Run install.sh from the mycutbox-rpi-agent repository root, or ensure step 6b cloned the agent to ${AGENT_HOME}."
        exit 1
    fi

    cp "$OTA_SRC" "$OTA_DST"
    chmod +x "$OTA_DST"
    chown "${INSTALL_USER}:${INSTALL_USER}" "$OTA_DST" 2>/dev/null || true

    USER_SVC_DIR="${INSTALL_HOME}/.config/systemd/user"
    mkdir -p "$USER_SVC_DIR"
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "$USER_SVC_DIR"

    INSTALL_UID=$(id -u "$INSTALL_USER")

    cat > "$USER_SVC_DIR/mycutbox-ota.service" << EOF
[Unit]
Description=MyCutBox OTA update controller (docker + usb agent)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$INSTALL_UID
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$OTA_DST --auto
EOF

    cat > "$USER_SVC_DIR/mycutbox-ota-boot.service" << EOF
[Unit]
Description=MyCutBox OTA update controller after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$INSTALL_UID
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$OTA_DST --boot
EOF

    cat > "$USER_SVC_DIR/mycutbox-ota-network.service" << EOF
[Unit]
Description=MyCutBox OTA update controller after network reconnect
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$INSTALL_UID
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$OTA_DST --network-online
EOF

    cat > "$USER_SVC_DIR/mycutbox-ota-network-down.service" << EOF
[Unit]
Description=MyCutBox network-down retry/alert helper
After=network.target
Wants=network.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$INSTALL_UID
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$OTA_DST --network-down
EOF

    cat > "$USER_SVC_DIR/mycutbox-ota-fleet.service" << EOF
[Unit]
Description=MyCutBox fleet OTA poll (Firestore desiredAgentTag)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=XDG_RUNTIME_DIR=/run/user/$INSTALL_UID
EnvironmentFile=-/etc/mycutbox/env
ExecStart=$OTA_DST --fleet
EOF

    cat > "$USER_SVC_DIR/mycutbox-ota.timer" << EOF
[Unit]
Description=Run MyCutBox OTA update monthly on day 1 at 04:00

[Timer]
OnCalendar=*-*-01 04:00:00
Persistent=true
Unit=mycutbox-ota.service

[Install]
WantedBy=timers.target
EOF

    cat > "$USER_SVC_DIR/mycutbox-ota-boot.timer" << EOF
[Unit]
Description=Run MyCutBox OTA update 5 minutes after boot

[Timer]
OnBootSec=5min
Unit=mycutbox-ota-boot.service

[Install]
WantedBy=timers.target
EOF

    cat > "$USER_SVC_DIR/mycutbox-ota-fleet.timer" << EOF
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

    AGENT_DIR="${INSTALL_HOME}/.pi/agent"
    cat > "$USER_SVC_DIR/mycutbox-ota-fleet-watch.service" << EOF
[Unit]
Description=MyCutBox fleet OTA Firestore listener (instant rollback)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$AGENT_DIR
Environment=XDG_RUNTIME_DIR=/run/user/$INSTALL_UID
EnvironmentFile=-/etc/mycutbox/env
ExecStart=/usr/bin/node $AGENT_DIR/scripts/fleet-ota-watch.mjs
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
EOF

    cat > "$USER_SVC_DIR/mycutbox-fleet-heartbeat.service" << EOF
[Unit]
Description=MyCutBox fleet heartbeat writer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$AGENT_DIR
Environment=XDG_RUNTIME_DIR=/run/user/$INSTALL_UID
EnvironmentFile=-/etc/mycutbox/env
ExecStart=/usr/bin/node $AGENT_DIR/scripts/fleet-heartbeat.mjs
EOF

    cat > "$USER_SVC_DIR/mycutbox-fleet-heartbeat.timer" << EOF
[Unit]
Description=Run MyCutBox fleet heartbeat every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true
Unit=mycutbox-fleet-heartbeat.service

[Install]
WantedBy=timers.target
EOF

    chown "${INSTALL_USER}:${INSTALL_USER}" \
      "$USER_SVC_DIR/mycutbox-ota.service" \
      "$USER_SVC_DIR/mycutbox-ota.timer" \
      "$USER_SVC_DIR/mycutbox-ota-boot.service" \
      "$USER_SVC_DIR/mycutbox-ota-boot.timer" \
      "$USER_SVC_DIR/mycutbox-ota-network.service" \
      "$USER_SVC_DIR/mycutbox-ota-network-down.service" \
      "$USER_SVC_DIR/mycutbox-ota-fleet.service" \
      "$USER_SVC_DIR/mycutbox-ota-fleet.timer" \
      "$USER_SVC_DIR/mycutbox-ota-fleet-watch.service" \
      "$USER_SVC_DIR/mycutbox-fleet-heartbeat.service" \
      "$USER_SVC_DIR/mycutbox-fleet-heartbeat.timer" 2>/dev/null || true

    install -d -m 0755 /etc/NetworkManager/dispatcher.d
    cat > /etc/NetworkManager/dispatcher.d/90-mycutbox-ota-online << EOF
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

if [ ! -S "/run/user/$INSTALL_UID/bus" ]; then
  exit 0
fi

if [ "\$EVENT" = "online" ]; then
  su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user start mycutbox-ota-network.service" >/dev/null 2>&1 || true
else
  su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user start mycutbox-ota-network-down.service" >/dev/null 2>&1 || true
fi
EOF
    chmod 0755 /etc/NetworkManager/dispatcher.d/90-mycutbox-ota-online

    # Enable linger and timer for offline-proof catch-up.
    loginctl enable-linger "$INSTALL_USER" 2>/dev/null || true

    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user daemon-reload"
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user enable mycutbox-ota.timer --now" 2>/dev/null || true
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user enable mycutbox-ota-boot.timer --now" 2>/dev/null || true
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user enable mycutbox-ota-fleet.timer --now" 2>/dev/null || true
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user enable mycutbox-ota-fleet-watch.service --now" 2>/dev/null || true
    su - "$INSTALL_USER" -c "XDG_RUNTIME_DIR=/run/user/$INSTALL_UID systemctl --user enable mycutbox-fleet-heartbeat.timer --now" 2>/dev/null || true

    log_info "OTA controller enabled:"
    log_info "  - Timer: systemctl --user status mycutbox-ota.timer"
    log_info "  - Boot timer: systemctl --user status mycutbox-ota-boot.timer"
    log_info "  - Fleet watch (instant): systemctl --user status mycutbox-ota-fleet-watch.service"
    log_info "  - Fleet fallback timer (60min): systemctl --user status mycutbox-ota-fleet.timer"
    log_info "  - Fleet heartbeat timer (1min): systemctl --user status mycutbox-fleet-heartbeat.timer"
    log_info "  - Service: systemctl --user status mycutbox-ota.service"
    log_info "  - Network hook: /etc/NetworkManager/dispatcher.d/90-mycutbox-ota-online"
    log_info "Manual run: /usr/local/bin/mycutbox-ota-update"
}

# 8. Setup printer auto-resume
setup_printer_resume() {
    log_step "6. Setting Up Printer Auto-Resume"
    
    cat > /usr/local/bin/resume_printer_all.sh << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/printer_resume.log"
lpstat -p 2>/dev/null | awk '/printer/ && /disabled/ {print $2}' | while read -r printer; do
  echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] Resuming printer: $printer" >> "$LOG_FILE"
  cupsenable "$printer" 2>>"$LOG_FILE"
done
EOF
    chmod +x /usr/local/bin/resume_printer_all.sh
    
    cat > /etc/systemd/system/resume_printer.service << 'EOF'
[Unit]
Description=Resume paused CUPS printers automatically

[Service]
Type=oneshot
ExecStart=/usr/local/bin/resume_printer_all.sh
StandardOutput=journal
StandardError=journal
EOF
    
    cat > /etc/systemd/system/resume_printer.timer << 'EOF'
[Unit]
Description=Run resume_printer_all.sh every 15 sec

[Timer]
OnBootSec=15sec
OnUnitActiveSec=15sec
Unit=resume_printer.service

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now resume_printer.timer
    
    log_info "Printer auto-resume setup complete"
}

# 8b. Rotate printer_resume.log weekly
setup_clear_printer_log() {
    log_step "8b. Setting Up Printer Resume Log Rotation"

    install_repo_script "scripts/clear_printer_log.sh" "/usr/local/bin/clear_printer_log.sh"

    cat > /etc/systemd/system/clear_printer_log.service << 'EOF'
[Unit]
Description=Rotate and clear printer resume log weekly

[Service]
Type=oneshot
ExecStart=/usr/local/bin/clear_printer_log.sh
StandardOutput=journal
StandardError=journal
EOF

    cat > /etc/systemd/system/clear_printer_log.timer << 'EOF'
[Unit]
Description=Run clear_printer_log weekly

[Timer]
OnCalendar=weekly
Persistent=true
Unit=clear_printer_log.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now clear_printer_log.timer
    log_info "Printer resume log rotation enabled (weekly)"
}

# 8c. DNP DS-RX1 CUPS queue auto-reconcile (boot + USB plug)
setup_ensure_rx1_cups() {
    log_step "8c. Setting Up RX1 CUPS Auto-Reconcile"

    PI_DIR="${INSTALL_HOME}/.pi"
    ENSURE_SCRIPT="${PI_DIR}/ensure-rx1-cups.sh"
    install_repo_script "scripts/ensure-rx1-cups.sh" "$ENSURE_SCRIPT" "root:root"

    cat > /etc/systemd/system/ensure-rx1-cups.service << EOF
[Unit]
Description=Ensure DNP dye-sub printer (RX1/DS620) CUPS queue
After=cups.service
Requires=cups.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/mycutbox/env
ExecStart=${ENSURE_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/udev/rules.d/99-dnp-rx1.rules << 'EOF'
# Re-run the CUPS queue reconciler when a DNP DS-RX1 or DS620 USB device is attached.
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="1343", ATTRS{idProduct}=="0005", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ensure-rx1-cups.service"
ACTION=="add", SUBSYSTEM=="usb", ATTRS{product}=="DSRX1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ensure-rx1-cups.service"
ACTION=="add", SUBSYSTEM=="usb", ATTRS{product}=="DS-RX1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ensure-rx1-cups.service"
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="1452", ATTRS{idProduct}=="8b01", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ensure-rx1-cups.service"
ACTION=="add", SUBSYSTEM=="usb", ATTRS{product}=="DS620", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ensure-rx1-cups.service"
EOF

    chown root:root /etc/systemd/system/ensure-rx1-cups.service /etc/udev/rules.d/99-dnp-rx1.rules
    chmod 644 /etc/systemd/system/ensure-rx1-cups.service /etc/udev/rules.d/99-dnp-rx1.rules

    systemctl daemon-reload
    udevadm control --reload-rules
    udevadm trigger 2>/dev/null || true
    systemctl enable ensure-rx1-cups.service
    if systemctl start ensure-rx1-cups.service 2>/dev/null; then
        log_info "Printer queue reconciled"
    else
        log_warn "ensure-rx1-cups skipped for now (connect RX1/DS620 USB and run: sudo ${ENSURE_SCRIPT})"
    fi
    log_info "DNP printer (RX1/DS620) CUPS auto-reconcile enabled (boot + udev)"
}

# 8d. Frame cache cleanup (daily)
setup_frame_cache_cleanup() {
    log_step "8d. Setting Up Frame Cache Cleanup"

    PI_SCRIPTS="${INSTALL_HOME}/.pi/scripts"
    mkdir -p "$PI_SCRIPTS"
    chown "${INSTALL_USER}:${INSTALL_USER}" "$PI_SCRIPTS"
    FRAME_SCRIPT="${PI_SCRIPTS}/mycutbox-frame-cleanup.sh"
    install_repo_script "scripts/mycutbox-frame-cleanup.sh" "$FRAME_SCRIPT" "${INSTALL_USER}:${INSTALL_USER}"

    cat > /etc/systemd/system/mycutbox-frame-cleanup.service << EOF
[Unit]
Description=MyCutBox frame cache cleanup

[Service]
Type=oneshot
ExecStart=${FRAME_SCRIPT}
StandardOutput=journal
StandardError=journal
EOF

    cat > /etc/systemd/system/mycutbox-frame-cleanup.timer << 'EOF'
[Unit]
Description=Daily MyCutBox frame cache cleanup

[Timer]
OnCalendar=daily
Persistent=true
Unit=mycutbox-frame-cleanup.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now mycutbox-frame-cleanup.timer
    log_info "Frame cache cleanup enabled (daily, ${INSTALL_HOME}/.pi/cache/frames)"
}

# 8e. Screen lock (gtklock): casual physical-access defense at the login layer.
# Shows clock/date + colored status (agent / connected networks) + password entry.
# Auto-locks on session start via labwc autostart; re-lock/refresh with `mycutbox-lock`.
setup_screen_lock() {
    log_step "8e. Setting Up Screen Lock (gtklock)"

    # gtklock is installed in install_system_packages; guard in case it is missing.
    if ! command -v gtklock >/dev/null 2>&1; then
        log_warn "gtklock not found — attempting install"
        apt install -y gtklock || { log_warn "gtklock install failed; skipping screen lock setup"; return 0; }
    fi

    local GTK_CFG="${INSTALL_HOME}/.config/gtklock"
    local LOCK_SCRIPT="${INSTALL_HOME}/.pi/mycutbox-lock.sh"
    local tmpl css launcher
    tmpl="$(resolve_repo_script "lock/gtklock.ui.tmpl")" || { log_warn "lock/gtklock.ui.tmpl not found; skipping"; return 0; }
    css="$(resolve_repo_script "lock/style.css")"        || { log_warn "lock/style.css not found; skipping"; return 0; }
    launcher="$(resolve_repo_script "lock/mycutbox-lock.sh")" || { log_warn "lock/mycutbox-lock.sh not found; skipping"; return 0; }

    # gtklock UI template + theme (rp3-owned, read at lock time)
    mkdir -p "$GTK_CFG"
    install -m 644 "$tmpl" "${GTK_CFG}/gtklock.ui.tmpl"
    install -m 644 "$css"  "${GTK_CFG}/style.css"
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "${INSTALL_HOME}/.config" 2>/dev/null || true

    # Launcher + convenience symlink (`mycutbox-lock` from anywhere)
    install -m 755 "$launcher" "$LOCK_SCRIPT"
    chown "${INSTALL_USER}:${INSTALL_USER}" "$LOCK_SCRIPT" 2>/dev/null || true
    ln -sf "$LOCK_SCRIPT" /usr/local/bin/mycutbox-lock

    # Auto-lock on session start via labwc autostart. labwc reads a SINGLE autostart
    # (user overrides system), so seed from the system default first to preserve the
    # desktop/panel, then append our lock line idempotently.
    local AUTOSTART="${INSTALL_HOME}/.config/labwc/autostart"
    mkdir -p "$(dirname "$AUTOSTART")"
    if [ ! -f "$AUTOSTART" ]; then
        if [ -f /etc/xdg/labwc/autostart ]; then
            cp /etc/xdg/labwc/autostart "$AUTOSTART"
        else
            : > "$AUTOSTART"
        fi
    fi
    if ! grep -qF 'mycutbox-lock' "$AUTOSTART"; then
        printf '\n# MyCutBox screen lock on session start\n(sleep 2; /usr/local/bin/mycutbox-lock) &\n' >> "$AUTOSTART"
    fi

    # Auto re-lock after N seconds idle (no input), via swayidle (already present on
    # Raspberry Pi OS / labwc). mycutbox-lock is idempotent — safe to fire repeatedly.
    local IDLE_LOCK_SECONDS="${IDLE_LOCK_SECONDS:-300}"
    if ! command -v swayidle >/dev/null 2>&1; then
        log_warn "swayidle not found — attempting install"
        apt install -y swayidle || log_warn "swayidle install failed; idle auto-lock skipped (boot-time lock still applies)"
    fi
    if command -v swayidle >/dev/null 2>&1 && ! grep -qF 'swayidle' "$AUTOSTART"; then
        printf '\n# MyCutBox: auto re-lock after %ss idle\nswayidle timeout %s "/usr/local/bin/mycutbox-lock" &\n' \
            "$IDLE_LOCK_SECONDS" "$IDLE_LOCK_SECONDS" >> "$AUTOSTART"
    fi
    chown -R "${INSTALL_USER}:${INSTALL_USER}" "${INSTALL_HOME}/.config/labwc" 2>/dev/null || true

    log_info "Screen lock enabled (gtklock). Auto-locks on boot + after ${IDLE_LOCK_SECONDS}s idle; re-lock with: mycutbox-lock"
}

# 9. Start composite-print when credentials are ready
start_docker_compose_if_ready() {
    log_step "9. Starting Docker Compose (if ready)"

    PI_DIR="${INSTALL_HOME}/.pi"
    ENV_FILE="${SECURE_ENV_FILE}"
    # Docker 는 마운트 소스 파일이 없으면 그 자리에 빈 디렉터리를 자동 생성해 마운트가 깨진다.
    # 이전 실행에서 그렇게 생긴 디렉터리가 남아있으면 지워서, 아래 -f 체크와 관리자가 나중에
    # 놓는 실제 파일이 헷갈리지 않게 한다.
    [ -d "${DATA_DIR}/mycutbox110.json" ] && rmdir "${DATA_DIR}/mycutbox110.json" 2>/dev/null || true
    if [ ! -f "${DATA_DIR}/mycutbox110.json" ]; then
        log_warn "Skipping docker compose up: ${DATA_DIR}/mycutbox110.json not found"
        return 0
    fi
    # rp3(uid 1000)만 읽게 잠금 — 컨테이너(uid 1000)와 호스트 fleet 스크립트는 여전히 읽어야
    # 하므로 root 소유는 불가(2bf63a3에서 이미 시도 후 되돌림). world/group readable만 차단.
    chmod 600 "${DATA_DIR}/mycutbox110.json" 2>/dev/null || true
    # 공개 이미지(public GHCR)면 토큰이 필요 없다. 토큰이 있으면 private 도 커버되고,
    # 없으면 공개 이미지로 pull 을 시도한다 (예전엔 토큰 없으면 무조건 건너뛰어, 공개 이미지
    # 방식에선 컨테이너가 아예 안 떴다).
    if [ ! -f "$ENV_FILE" ] || ! grep -q '^GITHUB_TOKEN=.' "$ENV_FILE" 2>/dev/null; then
        log_info "No GITHUB_TOKEN — proceeding with the public image (a private image would fail to pull)."
    fi

    log_info "Pulling and starting composite-print..."
    if su - "$INSTALL_USER" -c "cd '$PI_DIR' && docker compose pull composite-print && docker compose up -d"; then
        log_info "Docker Compose started (mycutbox-composite-print)"
    else
        log_warn "docker compose up failed. After 'newgrp docker' or re-login, run:"
        log_warn "  cd ${PI_DIR} && docker compose up -d"
    fi
}

# Main execution function
main() {
    log_info "MyCutBox Raspberry Pi Docker-based Installation Script Started"
    log_info "Log file: $LOG_FILE"
    
    check_root
    confirm_install
    migrate_legacy_pi_dir

    # Execute installation steps
    install_system_packages
    install_composite_print_fonts
    setup_korean_locale
    install_gutenprint
    install_docker
    setup_directories
    setup_docker_compose
    setup_env_file
    setup_pi_env
    setup_cups_permissions
    setup_usb_print_native
    setup_connect_wifi_native
    setup_ensure_rx1_cups
    setup_printer_resume
    setup_clear_printer_log
    setup_frame_cache_cleanup
    setup_screen_lock
    setup_ota_controller
    start_docker_compose_if_ready
    
    log_step "Installation Complete!"
    log_info "Next steps:"
    log_info "1. Place ${DATA_DIR}/mycutbox110.json file (if not already present)"
    log_info "2. Rebooting automatically below to apply docker group membership (newgrp/re-login is NOT"
    log_info "   enough once linger is enabled: the lingering systemd --user manager keeps running"
    log_info "   across logout and keeps its stale group list, so unattended OTA units inherit it and"
    log_info "   fail on docker.sock). Set MCB_SKIP_REBOOT=1 to skip and reboot manually instead."
    log_info "3. If composite-print did not start, run:"
    log_info "   cd ${INSTALL_HOME}/.pi && docker compose up -d"
    log_info ""
    log_info "4. usb-print: systemctl --user status mycutbox-usb-print"
    log_info "   connect-wifi: systemctl --user status mycutbox-connect-wifi"
    log_info "5. RX1 queue: systemctl status ensure-rx1-cups.service"
    log_info "6. Printer resume: systemctl status resume_printer.timer"
    log_info "7. Frame cache cleanup: systemctl status mycutbox-frame-cleanup.timer"
    log_info "   Screen lock: auto-locks on boot + after idle (gtklock/swayidle, default 300s; set IDLE_LOCK_SECONDS to change); re-lock with 'mycutbox-lock'"
    log_info "8. OTA: monthly timer + boot/network helpers"
    log_info "   - Monthly timer: mycutbox-ota.timer (day 1 at 04:00)"
    log_info "   - Boot timer: mycutbox-ota-boot.timer (5 minutes after boot)"
    log_info "   - Fleet watch: mycutbox-ota-fleet-watch.service (Firestore snapshot → instant OTA)"
    log_info "   - Fleet fallback timer: mycutbox-ota-fleet.timer (60 minute poll if watch down)"
    log_info "   - Fleet heartbeat timer: mycutbox-fleet-heartbeat.timer (1 minute lastSeen heartbeat)"
    log_info "   - Network reconnect hook: NetworkManager dispatcher -> mycutbox-ota-network.service (30 minute debounce)"
    log_info "   - Stops composite-print container and usb-print briefly during update"
    log_info "   - Manual run: /usr/local/bin/mycutbox-ota-update"
    log_info ""
    log_info "GITHUB_TOKEN in /etc/mycutbox/env: required for private GHCR pulls; docker compose may warn if empty."
    log_info "Slack OTA (optional): SLACK_BOT_TOKEN + SLACK_CHANNEL_ID in /etc/mycutbox/env; SLACK_WEBHOOK_URL alone = no threaded replies."

    if [ "${MCB_SKIP_REBOOT:-0}" = "1" ]; then
        log_warn "MCB_SKIP_REBOOT=1: not rebooting. Reboot manually to apply docker group membership."
        return 0
    fi
    log_info ""
    log_info "Rebooting in 10 seconds to apply docker group membership (Ctrl+C to cancel)..."
    sleep 10
    reboot
}

# Run script
main "$@"
