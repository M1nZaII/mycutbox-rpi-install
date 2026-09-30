#!/bin/bash
#
# MyCutBox Raspberry Pi Uninstall Script
# Removes all installed components and resets the system
#

set -euo pipefail

# Force English/C locale so tool output is readable during teardown (no Korean mojibake).
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
STEP='\033[1;33m'
NC='\033[0m'

# Configuration
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_HOME="/home/${INSTALL_USER}"
DATA_DIR="${INSTALL_HOME}/.pi/data"
CACHE_DIR="${INSTALL_HOME}/.pi/cache"
PI_DIR="${INSTALL_HOME}/.pi"
LEGACY_PI_DIR="${INSTALL_HOME}/pi"

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${STEP}========================================${NC}"
    echo -e "${STEP}$1${NC}"
    echo -e "${STEP}========================================${NC}\n"
}

# Check root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "This script requires root privileges. Please run with sudo."
        exit 1
    fi
}

# Confirm uninstall
confirm_uninstall() {
    log_warn "This will remove all MyCutBox components:"
    log_warn "  - Docker containers and images"
    log_warn "  - Application directories"
    log_warn "  - Systemd services"
    log_warn "  - CUPS configuration changes"
    log_warn "  - User group memberships (docker, lp)"
    echo ""
    log_warn "This action CANNOT be undone!"
    echo ""
    read -p "Are you sure you want to uninstall? (type 'yes' to confirm): " -r
    echo
    if [[ ! $REPLY == "yes" ]]; then
        log_info "Uninstall cancelled."
        exit 0
    fi
}

# Step 1: Stop and remove Docker containers
remove_docker_containers() {
    log_step "Step 1: Removing Docker Containers"
    
    if [ -d "$PI_DIR" ]; then
        cd "$PI_DIR"
        if [ -f "docker-compose.yml" ]; then
            log_info "Stopping Docker containers..."
            docker compose down -v 2>/dev/null || true
            log_info "✅ Docker containers stopped and removed"
        fi
    fi
    
    # Remove containers by name (in case compose file is missing)
    log_info "Removing containers by name..."
    docker rm -f mycutbox-composite-print mycutbox-usb-print mycutbox-watchtower 2>/dev/null || true
    
    # Remove Docker images
    log_info "Removing Docker images..."
    mapfile -t _imgs < <(docker images -q ghcr.io/m1nzaii/mycutbox-rpi-agent 2>/dev/null || true)
    if [ "${#_imgs[@]}" -gt 0 ]; then
        docker rmi "${_imgs[@]}" 2>/dev/null || true
    fi
    docker rmi containrrr/watchtower 2>/dev/null || true
    
    # Clean up Docker system
    log_info "Cleaning up Docker system..."
    docker system prune -f 2>/dev/null || true
}

# Step 2: Remove systemd services
remove_systemd_services() {
    log_step "Step 2: Removing Systemd Services"
    
    log_info "Removing printer / RX1 / cleanup systemd units..."

    systemctl stop resume_printer.timer 2>/dev/null || true
    systemctl disable resume_printer.timer 2>/dev/null || true
    systemctl stop resume_printer.service 2>/dev/null || true

    systemctl stop clear_printer_log.timer 2>/dev/null || true
    systemctl disable clear_printer_log.timer 2>/dev/null || true
    systemctl stop clear_printer_log.service 2>/dev/null || true

    systemctl stop mycutbox-frame-cleanup.timer 2>/dev/null || true
    systemctl disable mycutbox-frame-cleanup.timer 2>/dev/null || true
    systemctl stop mycutbox-frame-cleanup.service 2>/dev/null || true

    systemctl stop ensure-rx1-cups.service 2>/dev/null || true
    systemctl disable ensure-rx1-cups.service 2>/dev/null || true

    rm -f /etc/systemd/system/resume_printer.service
    rm -f /etc/systemd/system/resume_printer.timer
    rm -f /usr/local/bin/resume_printer_all.sh
    rm -f /etc/systemd/system/clear_printer_log.service
    rm -f /etc/systemd/system/clear_printer_log.timer
    rm -f /usr/local/bin/clear_printer_log.sh
    rm -f /etc/systemd/system/mycutbox-frame-cleanup.service
    rm -f /etc/systemd/system/mycutbox-frame-cleanup.timer
    rm -f /etc/systemd/system/ensure-rx1-cups.service
    rm -f /etc/udev/rules.d/99-dnp-rx1.rules
    rm -f "${PI_DIR}/ensure-rx1-cups.sh" "${LEGACY_PI_DIR}/ensure-rx1-cups.sh"
    rm -f "${PI_DIR}/scripts/mycutbox-frame-cleanup.sh" "${LEGACY_PI_DIR}/scripts/mycutbox-frame-cleanup.sh"

    udevadm control --reload-rules 2>/dev/null || true
    systemctl daemon-reload
    
    log_info "✅ Systemd services removed"
}

# Step 2b: Remove new-architecture components (OTA / fleet / usb-print USER units, hooks, secrets)
remove_new_components() {
    log_step "Step 2b: Removing OTA / Fleet / USB-Print Components"

    local uid; uid="$(id -u "$INSTALL_USER" 2>/dev/null || echo "")"
    local USER_UNITS=(
        mycutbox-ota.service mycutbox-ota.timer
        mycutbox-ota-boot.service mycutbox-ota-boot.timer
        mycutbox-ota-network.service mycutbox-ota-network-down.service
        mycutbox-ota-fleet.service mycutbox-ota-fleet.timer
        mycutbox-ota-fleet-watch.service
        mycutbox-fleet-heartbeat.service mycutbox-fleet-heartbeat.timer
        mycutbox-usb-print.service
        mycutbox-connect-wifi.service
    )
    local usd="${INSTALL_HOME}/.config/systemd/user"
    if [ -n "$uid" ]; then
        log_info "Stopping and disabling user services (as ${INSTALL_USER})..."
        local u
        for u in "${USER_UNITS[@]}"; do
            sudo -u "$INSTALL_USER" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user disable --now "$u" >/dev/null 2>&1 || true
            rm -f "${usd}/${u}"
        done
        sudo -u "$INSTALL_USER" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi

    log_info "Removing OTA launcher, network hook, agent dir, OTA state..."
    rm -f /etc/sudoers.d/mycutbox-connect-wifi
    rm -f /usr/local/bin/mycutbox-ota-update
    rm -rf "${PI_DIR}/agent" "${PI_DIR}/.ota-state" "${LEGACY_PI_DIR}/agent" "${LEGACY_PI_DIR}/.ota-state"

    # Screen lock (gtklock): kill any running locker, remove launcher/symlink/config,
    # and strip the auto-lock line from labwc autostart (leave the rest intact).
    log_info "Removing screen lock (gtklock) config..."
    pkill -x gtklock 2>/dev/null || true
    rm -f /usr/local/bin/mycutbox-lock
    rm -f "${PI_DIR}/mycutbox-lock.sh" "${LEGACY_PI_DIR}/mycutbox-lock.sh"
    rm -rf "${INSTALL_HOME}/.config/gtklock"
    if [ -f "${INSTALL_HOME}/.config/labwc/autostart" ]; then
        sed -i '/# MyCutBox screen lock on session start/d; /# MyCutBox: auto re-lock after/d; /mycutbox-lock/d' \
            "${INSTALL_HOME}/.config/labwc/autostart" 2>/dev/null || true
    fi

    # Stop auto-start of user services without a login session
    loginctl disable-linger "$INSTALL_USER" 2>/dev/null || true

    # Secure env + secrets (Firestore key + Slack token) — ask before removing
    if [ -d /etc/mycutbox ]; then
        read -p "Remove /etc/mycutbox (env + Firestore key + Slack token)? (y/N): " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf /etc/mycutbox
            log_info "Removed /etc/mycutbox"
        else
            log_info "Keeping /etc/mycutbox (secrets retained)"
        fi
    fi

    systemctl daemon-reload 2>/dev/null || true
    log_info "✅ OTA / fleet / usb-print components removed"
}

# Step 3: Remove application directories
remove_directories() {
    log_step "Step 3: Removing Application Directories"
    
    read -p "Remove application data directory (${PI_DIR})? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing ${PI_DIR}..."
        rm -rf "$PI_DIR"
        # Legacy pre-migration path, in case this device never ran the ~/pi -> ~/.pi migration.
        rm -rf "$LEGACY_PI_DIR"
        log_info "✅ Application directory removed"
    else
        log_info "Keeping application directory"
    fi
    
    # Remove build directories
    log_info "Removing build directories..."
    rm -rf /var/tmp/mycutbox-build
    rm -rf /tmp/mycutbox-build
    rm -rf "${INSTALL_HOME}/tmp/mycutbox-build"
    log_info "✅ Build directories removed"
}

# Step 4: Remove user from groups (optional)
remove_user_groups() {
    log_step "Step 4: User Group Memberships"
    
    read -p "Remove user from docker and lp groups? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing user from groups..."
        gpasswd -d "$INSTALL_USER" docker 2>/dev/null || true
        gpasswd -d "$INSTALL_USER" lp 2>/dev/null || true
        log_info "✅ User removed from groups"
        log_warn "You may need to log out and log back in for changes to take effect"
    else
        log_info "Keeping user group memberships"
    fi
}

# Step 5: Remove CUPS configuration changes (optional)
remove_cups_config() {
    log_step "Step 5: CUPS Configuration"
    
    read -p "Remove CUPS configuration changes? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Restoring CUPS configuration..."
        
        # Remove our custom configuration
        if [ -f /etc/cups/cupsd.conf ]; then
            # Remove our custom Location blocks
            sed -i '/# MyCutBox CUPS Web Access Configuration/,/^<\/Location>$/d' /etc/cups/cupsd.conf 2>/dev/null || true
            # Remove cupsd.conf.local if exists
            rm -f /etc/cups/cupsd.conf.local
        fi
        
        # Reset CUPS settings
        cupsctl --no-remote-admin 2>/dev/null || true
        
        systemctl restart cups || service cups restart
        
        log_info "✅ CUPS configuration restored"
    else
        log_info "Keeping CUPS configuration changes"
    fi
}

# Step 6: Remove Docker authentication (optional)
remove_docker_auth() {
    log_step "Step 6: Docker Authentication"
    
    read -p "Remove Docker authentication credentials? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing Docker credentials..."
        rm -f /root/.docker/config.json
        rm -f "${INSTALL_HOME}/.docker/config.json"
        log_info "✅ Docker credentials removed"
    else
        log_info "Keeping Docker credentials"
    fi
}

# Step 7: Remove SSH key (optional)
remove_ssh_key() {
    log_step "Step 7: SSH Key"
    
    read -p "Remove SSH key? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing SSH key..."
        rm -f "${INSTALL_HOME}/.ssh/id_ed25519"
        rm -f "${INSTALL_HOME}/.ssh/id_ed25519.pub"
        
        # Remove GitHub config from SSH config
        if [ -f "${INSTALL_HOME}/.ssh/config" ]; then
            sed -i '/Host github.com/,/StrictHostKeyChecking no/d' "${INSTALL_HOME}/.ssh/config" 2>/dev/null || true
        fi
        
        log_info "✅ SSH key removed"
        log_warn "Don't forget to remove the SSH key from GitHub!"
    else
        log_info "Keeping SSH key"
    fi
}

# Step 8: Clean up logs
cleanup_logs() {
    log_step "Step 8: Cleaning Up Logs"
    
    rm -f /var/log/mycutbox-install.log
    rm -f /var/log/mycutbox-setup.log
    rm -f /var/log/printer_resume.log
    
    log_info "✅ Logs cleaned up"
}

# Main uninstall function
main() {
    log_step "MyCutBox Raspberry Pi Uninstall"
    log_info "This will remove all MyCutBox components from the system"
    echo ""
    
    check_root
    confirm_uninstall
    
    # Execute uninstall steps
    remove_docker_containers
    remove_systemd_services
    remove_new_components
    remove_directories
    remove_user_groups
    remove_cups_config
    remove_docker_auth
    remove_ssh_key
    cleanup_logs
    
    log_step "Uninstall Complete!"
    log_info ""
    log_info "All MyCutBox components have been removed."
    log_info ""
    log_info "Note:"
    log_info "  - Gutenprint and selphy_print are still installed"
    log_info "  - Docker is still installed (if you want to remove it, run: apt remove docker.io docker-compose)"
    log_info "  - System packages are still installed"
    log_info ""
    log_info "To completely remove everything, you may also want to:"
    log_info "  - Remove Gutenprint: sudo apt remove gutenprint"
    log_info "  - Remove Docker: sudo apt remove docker.io docker-compose"
    log_info "  - Remove SSH key from GitHub (if you removed it locally)"
}

# Run main function
main "$@"
