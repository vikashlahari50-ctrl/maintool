
#!/usr/bin/env bash
# ================================================================
# NEXORA CLOUD TOOLKIT - ULTRA EDITION
# Version: 3.0.0
# Platform: Debian / Ubuntu
# Type: Interactive Server Management Toolkit
# ================================================================
#
# MODULES
# 01. Cloudflare Tunnel Repair
# 02. Docker Engine Repair
# 03. Pterodactyl Panel Installer
# 04. Pterodactyl Wings Installer
# 05. Tailscale Installer
# 06. Blueprint Documentation
# 07. System Updater
# 08. Server Diagnostics
# 09. Nexora Cloud Utilities
#
# SECURITY
# - Cloudflare token input is hidden.
# - Cloudflare token is never intentionally logged.
# - Existing service configuration is backed up.
# - Destructive operations require confirmation.
# - Installer scripts run only after confirmation.
# ================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP="NEXORA CLOUD"
VERSION="3.0.0"
TOKEN_FILE="/etc/cloudflared/token"
CF_SERVICE="/etc/systemd/system/cloudflared.service"
LOG_FILE="/var/log/nexora-toolkit.log"
BACKUP_DIR="/var/backups/nexora-toolkit"
STATE_DIR="/var/lib/nexora-toolkit"

# ================================================================
# SECTION 01 - TERMINAL COLORS
# ================================================================

if [[ -t 1 ]]; then
    RESET=$'\033[0m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[38;5;196m'
    GREEN=$'\033[38;5;82m'
    YELLOW=$'\033[38;5;220m'
    BLUE=$'\033[38;5;39m'
    CYAN=$'\033[38;5;51m'
    PURPLE=$'\033[38;5;141m'
    WHITE=$'\033[38;5;255m'
    GRAY=$'\033[38;5;245m'
else
    RESET=""
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    PURPLE=""
    WHITE=""
    GRAY=""
fi

# ================================================================
# SECTION 02 - GENERAL HELPERS
# ================================================================

mkdir -p /var/log
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/nexora-toolkit.log"

log() {
    printf '[%s] %s\n' \
        "$(date '+%F %T')" "$*" >> "$LOG_FILE"
}

info() {
    printf '%s[i]%s %s\n' "$CYAN" "$RESET" "$*"
}

success() {
    printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"
}

warning() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"
}

error() {
    printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2
}

separator() {
    printf '%s\n' \
        "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

pause_screen() {
    echo
    read -r -p "  Press ENTER to continue..." _ || true
}

has_command() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "Run with root privileges."
        echo "Command: sudo bash $0"
        return 1
    fi
}

require_apt() {
    if ! has_command apt-get; then
        error "This module requires Debian or Ubuntu."
        return 1
    fi
}

confirm_action() {
    local answer
    read -r -p "  Continue? [y/N]: " answer || return 1
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

confirm_danger() {
    local answer
    echo
    warning "$1"
    read -r -p "  Type YES to continue: " answer || return 1
    [[ "$answer" == "YES" ]]
}

safe_sleep() {
    sleep "${1:-1}"
}

# ================================================================
# SECTION 03 - ANIMATED INTERFACE
# ================================================================

draw_banner() {
    clear 2>/dev/null || true

    printf '%s' "$CYAN"
    cat <<'BANNER'
 _   _ _____  ___  ___  ___  ___
| \ | |  ___|/ _ \/ __|/ _ \/ __|
|  \| | |__ | | | \__ \ | | \__ \
| |\  |  __|| |_| |__) | |_| |__) |
|_| \_|_|    \___/|___/ \___/____/
BANNER
    printf '%s\n' "$RESET"

    printf '  %s%s%s\n' "$BOLD" "$APP TOOLKIT" "$RESET"
    printf '  %sv%s | SERVER OPERATIONS CONSOLE%s\n' \
        "$PURPLE" "$VERSION" "$RESET"

    separator
}

progress_bar() {
    local message="${1:-Loading}"
    local duration="${2:-1}"
    local width=28
    local i filled empty
    local delay

    delay="$(awk -v d="$duration" \
        'BEGIN { printf "%.4f", d/40 }')"

    for ((i=0; i<=40; i++)); do
        filled=$((i * width / 40))
        empty=$((width - filled))

        printf '\r  %s [' "$CYAN"
        printf '%*s' "$filled" '' | tr ' ' '#'
        printf '%*s' "$empty" '' | tr ' ' '-'
        printf '] %3d%% %s' \
            "$((i * 100 / 40))" "$message"
        printf '%s' "$RESET"

        sleep "$delay"
    done

    printf '\n'
}

startup_animation() {
    draw_banner
    progress_bar "INITIALIZING NEXORA CORE" 0.8
    progress_bar "LOADING SECURITY MODULES" 0.6
    progress_bar "CHECKING SERVER ENVIRONMENT" 0.6
    success "Toolkit initialized."
    safe_sleep 0.4
}

# ================================================================
# SECTION 04 - SYSTEM INFORMATION
# ================================================================

show_system_info() {
    echo
    printf '  %sHOST:%s %s\n' "$CYAN" "$RESET" "$(hostname)"
    printf '  %sUSER:%s %s\n' "$CYAN" "$RESET" "$(id -un)"
    printf '  %sTIME:%s %s\n' \
        "$CYAN" "$RESET" "$(date '+%H:%M:%S %Z')"

    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        printf '  %sOS:%s %s\n' "$CYAN" "$RESET" "${PRETTY_NAME:-Linux}"
    fi
}

# ================================================================
# SECTION 05 - BACKUPS
# ================================================================

create_backup_dir() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
}

backup_file() {
    local source="$1"
    local destination

    [[ -f "$source" ]] || return 0

    create_backup_dir

    destination="$BACKUP_DIR/$(basename "$source").$(date +%Y%m%d-%H%M%S).bak"

    cp -a "$source" "$destination"
    chmod 600 "$destination" 2>/dev/null || true

    success "Backup created: $destination"
    log "Backed up $source"
}

# ================================================================
# SECTION 06 - PACKAGE MANAGEMENT
# ================================================================

install_base_packages() {
    require_apt || return 1

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        jq \
        procps \
        iproute2 \
        coreutils
}

# ================================================================
# SECTION 07 - CLOUDFLARED INSTALLATION
# ================================================================

install_cloudflared() {
    local architecture download_url temporary_file

    if has_command cloudflared; then
        success "cloudflared is already installed."
        cloudflared --version || true
        return 0
    fi

    require_apt || return 1
    install_base_packages || return 1

    architecture="$(dpkg --print-architecture)"

    case "$architecture" in
        amd64)
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
            ;;
        arm64)
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb"
            ;;
        armhf)
            download_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm"
            ;;
        *)
            error "Unsupported architecture: $architecture"
            return 1
            ;;
    esac

    temporary_file="$(mktemp /tmp/cloudflared.XXXXXX.deb)"

    info "Downloading Cloudflare connector..."

    if ! curl -fLsS --retry 3 \
        --connect-timeout 15 \
        "$download_url" -o "$temporary_file"; then
        rm -f "$temporary_file"
        error "Download failed. Check network access."
        return 1
    fi

    if ! dpkg -i "$temporary_file"; then
        apt-get install -f -y
    fi

    rm -f "$temporary_file"

    has_command cloudflared || {
        error "cloudflared installation could not be verified."
        return 1
    }

    success "cloudflared installation verified."
}

# ================================================================
# SECTION 08 - CLOUDFLARE TOKEN COLLECTION
# ================================================================

collect_cloudflare_token() {
    local token

    mkdir -p /etc/cloudflared
    chmod 700 /etc/cloudflared

    echo
    echo "Paste the Cloudflare Tunnel token from your dashboard."
    echo "Input is hidden. The token will not be printed."
    echo

    read -r -s -p "  Tunnel token: " token || return 1
    printf '\n'

    if [[ -z "$token" ]]; then
        error "Empty token; operation cancelled."
        unset token
        return 1
    fi

    if [[ "$token" =~ [[:space:]] ]]; then
        error "Whitespace detected in token."
        unset token
        return 1
    fi

    umask 077

    printf '%s' "$token" > "$TOKEN_FILE"
    unset token

    chown root:root "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"

    if [[ ! -s "$TOKEN_FILE" ]]; then
        error "Token file verification failed."
        return 1
    fi

    success "Token stored securely."
    log "Cloudflare token file updated; value omitted."
}

# ================================================================
# SECTION 09 - CLOUDFLARE SERVICE
# ================================================================

write_cloudflare_service() {
    if [[ -f "$CF_SERVICE" ]]; then
        backup_file "$CF_SERVICE"
    fi

    cat > "$CF_SERVICE" <<'UNIT'
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel --protocol http2 run --token-file /etc/cloudflared/token
Restart=always
RestartSec=5
TimeoutStartSec=30
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
UNIT

    chmod 644 "$CF_SERVICE"

    systemctl daemon-reload
    systemctl enable cloudflared
}

cloudflare_status() {
    echo
    echo "===== SERVICE STATE ====="
    systemctl is-active cloudflared || true

    echo
    echo "===== TOKEN FILE ====="

    if [[ -s "$TOKEN_FILE" ]]; then
        stat -c 'Exists | Owner: %U | Mode: %a | Size: %s bytes' \
            "$TOKEN_FILE"
    else
        error "Token file missing or empty."
    fi

    echo
    echo "===== RECENT TUNNEL EVENTS ====="

    journalctl -u cloudflared -n 60 \
        --no-pager -o cat 2>/dev/null |
        grep -iE \
        'connected|connection|registered|error|failed|timeout|retry|unauthorized|401|1033|quic|http2|tunnel' |
        tail -35 || true

    echo
    echo "===== SERVICE COUNTERS ====="

    systemctl show cloudflared \
        -p ActiveState \
        -p SubState \
        -p NRestarts

    echo
    warning "Running status does not guarantee successful tunnel registration."
}

cloudflare_repair() {
    draw_banner
    echo "${BOLD}CLOUDFLARE TUNNEL REPAIR${RESET}"
    separator

    require_root || return
    install_cloudflared || {
        pause_screen
        return
    }

    collect_cloudflare_token || {
        pause_screen
        return
    }

    write_cloudflare_service

    info "Restarting Cloudflare service..."
    systemctl restart cloudflared

    safe_sleep 5
    cloudflare_status

    log "Cloudflare repair routine completed."
    pause_screen
}

# ================================================================
# SECTION 10 - DOCKER INSTALLATION
# ================================================================

docker_install_packages() {
    require_apt || return 1
    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get install -y docker.io

    has_command docker || {
        error "Docker CLI installation failed."
        return 1
    }

    success "Docker CLI installed."
}

docker_standard_repair() {
    docker_install_packages || return 1

    systemctl daemon-reload
    systemctl enable docker
    systemctl restart docker

    safe_sleep 3

    if systemctl is-active --quiet docker; then
        success "Docker service is active."
    else
        error "Docker service did not start."
        systemctl status docker --no-pager -l || true
        return 1
    fi

    docker ps
}

docker_compatibility_repair() {
    echo
    warning "Compatibility mode disables Docker bridge networking."
    echo "Containers may not have normal network connectivity."
    echo "This mode may conflict with a system-managed Docker service."
    echo

    confirm_danger "Replace the Docker service command with restricted networking flags?" ||
        return

    docker_install_packages || return 1

    backup_file /etc/docker/daemon.json

    mkdir -p /etc/docker

    # This mode is explicit and uses a systemd override.
    # It avoids leaving an unmanaged dockerd process running.
    mkdir -p /etc/systemd/system/docker.service.d

    cat > /etc/systemd/system/docker.service.d/nexora-compat.conf <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --iptables=false --bridge=none --ip-forward=false --ip-masq=false
UNIT

    systemctl daemon-reload
    systemctl enable docker
    systemctl restart docker

    safe_sleep 5

    if docker ps; then
        success "Docker daemon responded."
    else
        error "Docker is not responding."
        journalctl -u docker -n 40 --no-pager || true
    fi

    warning "Remove the Nexora override to restore the package default:"
    echo "rm -f /etc/systemd/system/docker.service.d/nexora-compat.conf"
    echo "systemctl daemon-reload && systemctl restart docker"
}

docker_repair() {
    draw_banner
    echo "${BOLD}DOCKER ENGINE REPAIR${RESET}"
    separator

    require_root || return

    echo "  1) Standard systemd Docker repair"
    echo "  2) Restricted networking compatibility mode"
    echo "  3) Show Docker logs"
    echo "  4) Back"

    read -r -p "  Choose [1-4]: " choice || return

    case "$choice" in
        1)
            confirm_action && docker_standard_repair || true
            ;;
        2)
            docker_compatibility_repair
            ;;
        3)
            journalctl -u docker -n 80 --no-pager || true
            tail -40 /var/log/dockerd.log 2>/dev/null || true
            ;;
        4) return ;;
        *) error "Invalid selection." ;;
    esac

    log "Docker repair menu used."
    pause_screen
}

# ================================================================
# SECTION 11 - PTERODACTYL INSTALLER
# ================================================================

pterodactyl_installer() {
    draw_banner

    echo "${BOLD}PTERODACTYL INSTALLER${RESET}"
    separator

    echo "This opens the community installer maintained at:"
    echo "https://github.com/pterodactyl-installer/pterodactyl-installer"
    echo
    warning "Review the repository, supported OS and script before running."
    echo "The installer can modify packages, services, firewall and databases."
    echo

    require_root || return

    if ! has_command curl; then
        install_base_packages || return
    fi

    confirm_danger "Run the upstream Pterodactyl installer?" || return

    # Execute the upstream installer with Bash process substitution.
    # The user can select available panel or Wings actions in its menu.
    bash <(curl -fsSL \
        https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer/master/install.sh)

    log "Pterodactyl upstream installer exited."
    pause_screen
}

pterodactyl_panel() {
    draw_banner
    echo "${BOLD}PTERODACTYL PANEL${RESET}"
    echo
    echo "The upstream installer provides the Panel installation option."
    echo "Ensure you have a supported OS, domain, DNS and database plan."
    echo
    pterodactyl_installer
}

pterodactyl_wings() {
    draw_banner
    echo "${BOLD}PTERODACTYL WINGS${RESET}"
    echo
    echo "Wings requires a configured Panel and node configuration."
    echo "The upstream installer provides the available Wings options."
    echo
    pterodactyl_installer
}

# ================================================================
# SECTION 12 - TAILSCALE
# ================================================================

tailscale_install() {
    draw_banner
    echo "${BOLD}TAILSCALE SECURE NETWORK${RESET}"
    separator

    require_root || return
    require_apt || return

    echo "This uses the official Tailscale installation script."
    echo "Official website: https://tailscale.com/"
    echo

    confirm_action || return

    local temporary_file
    temporary_file="$(mktemp /tmp/nexora-tailscale.XXXXXX.sh)"

    if ! curl -fsSL \
        https://tailscale.com/install.sh -o "$temporary_file"; then
        rm -f "$temporary_file"
        error "Could not download the official installer."
        pause_screen
        return
    fi

    bash "$temporary_file"
    rm -f "$temporary_file"

    systemctl enable --now tailscaled

    echo
    success "Installation step completed."
    echo "Run 'tailscale up' to authenticate this server."
    echo
    tailscale status || true

    log "Tailscale installer completed."
    pause_screen
}

# ================================================================
# SECTION 13 - BLUEPRINT DOCUMENTATION
# ================================================================

blueprint_guide() {
    draw_banner

    echo "${BOLD}BLUEPRINT EXTENSION GUIDE${RESET}"
    separator

    echo "Blueprint is an extension framework for compatible"
    echo "Pterodactyl Panel installations."
    echo
    echo "Documentation:"
    echo "https://blueprint.zip/"
    echo
    echo "Before installation:"
    echo "  - Confirm your Panel version is supported."
    echo "  - Create a Panel backup."
    echo "  - Read the current official installation instructions."
    echo "  - Do not use an outdated command copied from an unknown source."
    echo
    warning "This option does not guess or execute a moving Blueprint installer URL."
    echo

    if has_command curl; then
        echo "Checking documentation website connectivity..."
        curl -IsS --connect-timeout 5 \
            https://blueprint.zip/ | head -5 || true
    fi

    pause_screen
}

# ================================================================
# SECTION 14 - SYSTEM UPDATE
# ================================================================

system_update() {
    draw_banner

    echo "${BOLD}SYSTEM PACKAGE UPDATE${RESET}"
    separator

    require_root || return
    require_apt || return

    echo "This updates packages using APT."
    echo "Major distribution upgrades are not performed."
    echo

    confirm_danger "Install available package updates?" || return

    export DEBIAN_FRONTEND=noninteractive

    apt-get update
    apt-get upgrade -y
    apt-get autoremove -y

    success "Package update sequence finished."
    log "System package update completed."

    pause_screen
}

# ================================================================
# SECTION 15 - SERVER DIAGNOSTICS
# ================================================================

section_title() {
    echo
    printf '%s===== %s =====%s\n' "$PURPLE" "$1" "$RESET"
}

diagnostics_os() {
    section_title "OPERATING SYSTEM"

    if [[ -r /etc/os-release ]]; then
        cat /etc/os-release
    fi

    echo
    uname -a
    systemd-detect-virt 2>/dev/null || true
}

diagnostics_resources() {
    section_title "CPU"
    nproc
    lscpu 2>/dev/null | head -18 || true

    section_title "MEMORY"
    free -h

    section_title "DISK"
    df -hT

    section_title "SWAP"
    swapon --show || true
}

diagnostics_network() {
    section_title "NETWORK INTERFACES"
    ip -brief address 2>/dev/null || true

    section_title "ROUTES"
    ip route 2>/dev/null || true

    section_title "DNS LOOKUP"
    getent hosts github.com cloudflare.com || true

    section_title "LISTENING PORTS"
    ss -tulpn 2>/dev/null || true
}

diagnostics_services() {
    section_title "SERVICE STATES"

    local service
    for service in cloudflared docker tailscaled wings; do
        printf '%-15s ' "$service"
        systemctl is-active "$service" 2>/dev/null || true
    done

    section_title "FAILED SYSTEMD UNITS"
    systemctl --failed --no-pager 2>/dev/null || true
}

diagnostics_cloudflare() {
    section_title "CLOUDFLARE TOKEN FILE"

    if [[ -s "$TOKEN_FILE" ]]; then
        stat -c 'Exists | Mode=%a | Owner=%U:%G | Size=%s' \
            "$TOKEN_FILE"
        echo "Token contents intentionally hidden."
    else
        echo "Token file missing or empty."
    fi

    section_title "CLOUDFLARED LOGS"
    journalctl -u cloudflared -n 35 --no-pager -o cat \
        2>/dev/null || true
}

diagnostics_docker() {
    section_title "DOCKER CLI"

    if has_command docker; then
        docker version 2>&1 | head -35 || true
        docker ps -a 2>&1 | head -30 || true
    else
        echo "Docker CLI not installed."
    fi

    section_title "DOCKER LOGS"
    journalctl -u docker -n 30 --no-pager 2>/dev/null || true

    if [[ -f /var/log/dockerd.log ]]; then
        tail -30 /var/log/dockerd.log
    fi
}

full_diagnostics() {
    draw_banner
    echo "${BOLD}FULL SERVER DIAGNOSTICS${RESET}"
    separator

    diagnostics_os
    diagnostics_resources
    diagnostics_network
    diagnostics_services
    diagnostics_cloudflare
    diagnostics_docker

    log "Full diagnostics viewed."
    pause_screen
}

# ================================================================
# SECTION 16 - NEXORA UTILITIES
# ================================================================

utility_disk() {
    draw_banner
    echo "${BOLD}DISK SPACE${RESET}"
    df -hT
    echo
    echo "Largest top-level directories:"
    du -xhd1 / 2>/dev/null | sort -h | tail -15 || true
    pause_screen
}

utility_memory() {
    draw_banner
    echo "${BOLD}MEMORY AND SWAP${RESET}"
    free -h
    echo
    swapon --show || true
    echo
    ps aux --sort=-%mem | head -15 || true
    pause_screen
}

utility_cpu() {
    draw_banner
    echo "${BOLD}CPU LOAD${RESET}"
    uptime
    echo
    ps aux --sort=-%cpu | head -15 || true
    pause_screen
}

utility_ports() {
    draw_banner
    echo "${BOLD}LISTENING PORTS${RESET}"
    ss -tulpn 2>/dev/null || true
    pause_screen
}

utility_docker_logs() {
    draw_banner
    echo "${BOLD}DOCKER LOGS${RESET}"

    if [[ -f /var/log/dockerd.log ]]; then
        tail -80 /var/log/dockerd.log
    else
        journalctl -u docker -n 80 --no-pager || true
    fi

    pause_screen
}

utility_cloudflare_logs() {
    draw_banner
    echo "${BOLD}CLOUDFLARE LOGS${RESET}"
    journalctl -u cloudflared -n 80 --no-pager -o cat || true
    pause_screen
}

utility_restart_service() {
    draw_banner

    echo "${BOLD}SERVICE RESTART${RESET}"
    echo "  1) cloudflared"
    echo "  2) docker"
    echo "  3) tailscaled"
    echo "  4) Return"

    read -r -p "  Select service: " choice || return

    case "$choice" in
        1) systemctl restart cloudflared ;;
        2) systemctl restart docker ;;
        3) systemctl restart tailscaled ;;
        4) return ;;
        *) error "Invalid choice." ;;
    esac

    success "Restart command sent where applicable."
    pause_screen
}

nexora_utilities() {
    while true; do
        draw_banner

        echo "${BOLD}NEXORA QUICK UTILITIES${RESET}"
        separator

        echo "  1) Disk usage"
        echo "  2) RAM and swap"
        echo "  3) CPU usage"
        echo "  4) Listening ports"
        echo "  5) Docker logs"
        echo "  6) Cloudflare logs"
        echo "  7) Restart a service"
        echo "  8) Return to main menu"

        separator
        read -r -p "  Select [1-8]: " choice || return

        case "$choice" in
            1) utility_disk ;;
            2) utility_memory ;;
            3) utility_cpu ;;
            4) utility_ports ;;
            5) utility_docker_logs ;;
            6) utility_cloudflare_logs ;;
            7) utility_restart_service ;;
            8) return ;;
            *) error "Invalid selection."; safe_sleep 1 ;;
        esac
    done
}

# ================================================================
# SECTION 17 - HEALTH CHECK
# ================================================================

health_check() {
    draw_banner
    echo "${BOLD}QUICK HEALTH CHECK${RESET}"
    separator

    local failed=0

    for command_name in bash systemctl curl; do
        if has_command "$command_name"; then
            success "$command_name available"
        else
            error "$command_name unavailable"
            failed=1
        fi
    done

    for service_name in cloudflared docker tailscaled; do
        printf '%-15s ' "$service_name"

        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            success "active"
        else
            warning "inactive or not installed"
        fi
    done

    echo
    echo "Disk:"
    df -h /

    echo
    echo "Memory:"
    free -h

    echo
    if [[ "$failed" -eq 0 ]]; then
        success "Basic command checks completed."
    else
        warning "Some required commands are unavailable."
    fi

    pause_screen
}

# ================================================================
# SECTION 18 - LOG VIEWER
# ================================================================

view_toolkit_log() {
    draw_banner
    echo "${BOLD}NEXORA TOOLKIT LOG${RESET}"
    separator

    if [[ -f "$LOG_FILE" ]]; then
        tail -100 "$LOG_FILE"
    else
        echo "No toolkit log has been created."
    fi

    pause_screen
}

# ================================================================
# SECTION 19 - MAIN MENU
# ================================================================

main_menu() {
    require_root || exit 1

    while true; do
        draw_banner
        show_system_info
        separator

        echo "  ${GREEN}01${RESET}  Cloudflare Tunnel Repair"
        echo "  ${GREEN}02${RESET}  Docker Engine Repair"
        echo "  ${GREEN}03${RESET}  Pterodactyl Panel Installer"
        echo "  ${GREEN}04${RESET}  Pterodactyl Wings Installer"
        echo "  ${GREEN}05${RESET}  Tailscale Installer"
        echo "  ${GREEN}06${RESET}  Blueprint Extension Guide"
        echo "  ${GREEN}07${RESET}  System Package Updater"
        echo "  ${GREEN}08${RESET}  Full Server Diagnostics"
        echo "  ${GREEN}09${RESET}  Nexora Cloud Utilities"
        echo
        echo "  ${CYAN}H${RESET}   Quick Health Check"
        echo "  ${CYAN}L${RESET}   View Toolkit Log"
        echo "  ${RED}00${RESET}  Exit"
        separator

        read -r -p "  Nexora > " choice || exit 0

        case "$choice" in
            1|01)
                cloudflare_repair
                ;;
            2|02)
                docker_repair
                ;;
            3|03)
                pterodactyl_panel
                ;;
            4|04)
                pterodactyl_wings
                ;;
            5|05)
                tailscale_install
                ;;
            6|06)
                blueprint_guide
                ;;
            7|07)
                system_update
                ;;
            8|08)
                full_diagnostics
                ;;
            9|09)
                nexora_utilities
                ;;
            h|H)
                health_check
                ;;
            l|L)
                view_toolkit_log
                ;;
            0|00)
                echo
                success "Nexora Cloud Toolkit closed."
                exit 0
                ;;
            *)
                error "Invalid option. Choose 00-09, H or L."
                safe_sleep 1
                ;;
        esac
    done
}

# ================================================================
# SECTION 20 - STARTUP AND ERROR HANDLING
# ================================================================

on_error() {
    local exit_code="$?"
    log "Unexpected error: exit=$exit_code line=${BASH_LINENO[0]:-unknown}"
    echo
    error "A command failed. Review the output and toolkit log."
    echo "Log: $LOG_FILE"
    return "$exit_code"
}

on_interrupt() {
    echo
    warning "Operation interrupted by user."
    exit 130
}

trap on_interrupt INT TERM
trap on_error ERR

startup_animation
main_menu
