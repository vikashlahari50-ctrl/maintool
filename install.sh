#!/usr/bin/env bash
# ============================================================================
# NEXORA CLOUD COMMAND CENTER
# Animated Linux administration toolkit
# Supported targets: Debian / Ubuntu
# ============================================================================
# Safety notes:
# - Run as root for system administration tasks.
# - Review this script before running it on production machines.
# - Third-party installers are downloaded from their upstream projects.
# - Cloudflare tunnel tokens are requested silently and stored with mode 600.
# ============================================================================

set -o pipefail
IFS=$'\n\t'

APP_NAME="Nexora Cloud Command Center"
APP_VERSION="2.0.0"
APP_AUTHOR="Nexora Cloud"
LOG_DIR="/var/log/nexora-toolkit"
LOG_FILE="${LOG_DIR}/toolkit.log"
TOKEN_FILE="/etc/cloudflared/token"
SERVICE_FILE="/etc/systemd/system/cloudflared.service"
PANEL_INSTALLER="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer/master/install.sh"
TAILSCALE_INSTALLER="https://tailscale.com/install.sh"
BLUEPRINT_DOCS="https://blueprint.zip/"

# Terminal colours. Empty values keep output readable in limited terminals.
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    BOLD="$(tput bold 2>/dev/null || true)"
    DIM="$(tput dim 2>/dev/null || true)"
    RESET="$(tput sgr0 2>/dev/null || true)"
    RED="$(tput setaf 1 2>/dev/null || true)"
    GREEN="$(tput setaf 2 2>/dev/null || true)"
    YELLOW="$(tput setaf 3 2>/dev/null || true)"
    BLUE="$(tput setaf 4 2>/dev/null || true)"
    PURPLE="$(tput setaf 5 2>/dev/null || true)"
    CYAN="$(tput setaf 6 2>/dev/null || true)"
    WHITE="$(tput setaf 7 2>/dev/null || true)"
else
    BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""
    BLUE=""; PURPLE=""; CYAN=""; WHITE=""
fi

# ----------------------------- Basic helpers -------------------------------
now() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    local level="$1"; shift
    local message="$*"
    if [[ -d "$LOG_DIR" ]]; then
        printf '[%s] [%s] %s\n' "$(now)" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
    fi
    case "$level" in
        ERROR) printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$message" ;;
        WARN)  printf '%s[WARN ]%s %s\n' "$YELLOW" "$RESET" "$message" ;;
        OK)    printf '%s[ OK  ]%s %s\n' "$GREEN" "$RESET" "$message" ;;
        INFO)  printf '%s[INFO ]%s %s\n' "$CYAN" "$RESET" "$message" ;;
        *)     printf '%s\n' "$message" ;;
    esac
}

setup_logging() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        install -d -m 750 "$LOG_DIR" 2>/dev/null || true
        touch "$LOG_FILE" 2>/dev/null || true
        chmod 640 "$LOG_FILE" 2>/dev/null || true
    fi
}

pause_screen() {
    printf '\n%sPress Enter to continue...%s' "$DIM" "$RESET"
    read -r _ || true
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log ERROR "This option needs root privileges. Run: sudo bash $0"
        return 1
    fi
    return 0
}

has_command() { command -v "$1" >/dev/null 2>&1; }

is_debian_family() {
    [[ -r /etc/os-release ]] || return 1
    . /etc/os-release
    [[ "${ID:-}" == "debian" || "${ID:-}" == "ubuntu" || " ${ID_LIKE:-} " == *" debian "* ]]
}

check_platform() {
    if ! is_debian_family; then
        log WARN "This toolkit is designed for Debian/Ubuntu. Some options may not work here."
        return 1
    fi
    return 0
}

need_network_tools() {
    if ! has_command curl; then
        apt-get update -y && apt-get install -y curl ca-certificates || return 1
    fi
    return 0
}

confirm_action() {
    local prompt="${1:-Continue?}"
    local answer
    printf '%s%s [y/N]: %s' "$YELLOW" "$prompt" "$RESET"
    read -r answer || return 1
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# -------------------------- Animated interface -----------------------------
ui_line() {
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$PURPLE" "$RESET"
}

center_text() {
    printf '  %s\n' "$*"
}

spinner() {
    local pid="$1" label="$2"
    local frames='|/-\\' i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  %s[%c]%s %s' "$CYAN" "${frames:i++%4:1}" "$RESET" "$label"
        sleep 0.12
    done
    printf '\r  %s[✓]%s %s\n' "$GREEN" "$RESET" "$label"
}

loading_bar() {
    local label="$1"
    local duration="${2:-0.65}"
    local width=38 frame filled empty percent delay
    delay="$(awk -v d="$duration" 'BEGIN { printf "%.4f", d/38 }')"
    for ((frame=0; frame<=width; frame++)); do
        filled="$frame"
        empty=$((width-filled))
        percent=$((frame*100/width))
        printf '\r  %s%-28s%s [' "$CYAN" "$label" "$RESET"
        printf '%s' "$GREEN"
        printf '%*s' "$filled" '' | tr ' ' '█'
        printf '%s' "$DIM"
        printf '%*s' "$empty" '' | tr ' ' '░'
        printf '%s] %3d%%' "$RESET" "$percent"
        sleep "$delay"
    done
    printf '\n'
}

loading_step() {
    local label="$1" detail="${2:-READY}"
    printf '  %s[WAIT]%s %-30s' "$YELLOW" "$RESET" "$label"
    sleep 0.15
    printf '\r  %s[ OK ]%s %-30s %s\n' "$GREEN" "$RESET" "$label" "$detail"
}

startup_animation() {
    clear 2>/dev/null || true
    printf '\n%s' "$CYAN"
    cat <<'BANNER'
  ███╗   ██╗███████╗██╗  ██╗ ██████╗ ██████╗  █████╗
  ████╗  ██║██╔════╝╚██╗██╔╝██╔═══██╗██╔══██╗██╔══██╗
  ██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║██████╔╝███████║
  ██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║██╔══██╗██╔══██║
  ██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝██║  ██║██║  ██║
  ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝
BANNER
    printf '%s\n' "$RESET"
    ui_line
    center_text "${BOLD}${WHITE}NEXORA CLOUD  /  COMMAND CENTER${RESET}"
    center_text "${DIM}SERVER OPERATIONS • DIAGNOSTICS • AUTOMATION${RESET}"
    ui_line
    printf '\n'
    loading_bar "Initializing interface" 0.75
    loading_bar "Loading system modules" 0.65
    loading_bar "Verifying service status" 0.65
    loading_bar "Rendering command center" 0.75
    printf '\n'
    loading_step "Terminal interface" "READY"
    loading_step "System utilities" "LOADED"
    loading_step "Security checks" "INITIALIZED"
    loading_step "Command router" "ONLINE"
    printf '\n'
    ui_line
    center_text "${GREEN}${BOLD}ALL SYSTEMS INITIALIZED${RESET}"
    center_text "${DIM}Starting Nexora Toolkit...${RESET}"
    ui_line
    sleep 0.45
}

# --------------------------- Cloudflare tools ------------------------------
install_cloudflared() {
    require_root || return 1
    need_network_tools || { log ERROR "curl could not be installed."; return 1; }
    if has_command cloudflared; then
        log OK "cloudflared is already installed: $(cloudflared --version 2>/dev/null | head -n1)"
        return 0
    fi
    log INFO "Detecting architecture for cloudflared..."
    local arch package_url temp_file
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    case "$arch" in
        amd64|x86_64) package_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" ;;
        arm64|aarch64) package_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb" ;;
        armhf|armv7l) package_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-armhf.deb" ;;
        *) log ERROR "Unsupported architecture: $arch"; return 1 ;;
    esac
    temp_file="$(mktemp /tmp/cloudflared.XXXXXX.deb)" || return 1
    if curl -fL --retry 3 --connect-timeout 15 "$package_url" -o "$temp_file"; then
        if dpkg -i "$temp_file"; then
            apt-get -f install -y || true
            rm -f "$temp_file"
            log OK "cloudflared installed."
        else
            rm -f "$temp_file"
            log ERROR "Package installation failed."
            return 1
        fi
    else
        rm -f "$temp_file"
        log ERROR "Could not download cloudflared package."
        return 1
    fi
}

configure_cloudflared_token() {
    require_root || return 1
    has_command cloudflared || install_cloudflared || return 1
    install -d -m 700 /etc/cloudflared || return 1
    local token
    printf '\n%sPaste your Cloudflare Tunnel token (input hidden):%s\n' "$CYAN" "$RESET"
    IFS= read -r -s token || return 1
    printf '\n'
    if [[ -z "$token" ]]; then
        log ERROR "No token provided; nothing was changed."
        unset token
        return 1
    fi
    if [[ "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
        log ERROR "Token contains invalid newline characters."
        unset token
        return 1
    fi
    umask 077
    printf '%s' "$token" > "$TOKEN_FILE" || { unset token; return 1; }
    chmod 600 "$TOKEN_FILE"
    unset token
    log OK "Token stored at $TOKEN_FILE with restricted permissions."
}

configure_cloudflared_service() {
    require_root || return 1
    has_command cloudflared || { log ERROR "Install cloudflared first."; return 1; }
    [[ -s "$TOKEN_FILE" ]] || { log ERROR "Token file missing. Use the token setup option first."; return 1; }
    local backup
    if [[ -f "$SERVICE_FILE" ]]; then
        backup="${SERVICE_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp -a "$SERVICE_FILE" "$backup" && log INFO "Previous service backed up to $backup"
    fi
    cat > "$SERVICE_FILE" <<'SERVICE'
[Unit]
Description=Cloudflare Tunnel client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel --protocol http2 run --token-file /etc/cloudflared/token
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload || return 1
    systemctl enable cloudflared || return 1
    systemctl restart cloudflared || return 1
    sleep 2
    if systemctl is-active --quiet cloudflared; then
        log OK "Cloudflare Tunnel service is active."
    else
        log WARN "Service is not active. Recent logs follow:"
        journalctl -u cloudflared -n 35 --no-pager 2>/dev/null || true
        return 1
    fi
}

cloudflare_status() {
    printf '\n%sCloudflare Tunnel status%s\n' "$BOLD" "$RESET"
    if has_command cloudflared; then cloudflared --version 2>/dev/null || true; else log WARN "cloudflared is not installed."; fi
    if has_command systemctl; then systemctl status cloudflared --no-pager -l 2>/dev/null || true; fi
    printf '\n%sRecent logs%s\n' "$BOLD" "$RESET"
    journalctl -u cloudflared -n 30 --no-pager 2>/dev/null || true
}

cloudflare_fix() {
    require_root || return 1
    printf '\n%sCLOUDFLARE TUNNEL REPAIR%s\n' "$BOLD" "$RESET"
    install_cloudflared || return 1
    if [[ ! -s "$TOKEN_FILE" ]]; then
        configure_cloudflared_token || return 1
    else
        log INFO "Existing token file found; it will not be displayed."
        if confirm_action "Replace the existing token?"; then
            configure_cloudflared_token || return 1
        fi
    fi
    configure_cloudflared_service
}

cloudflare_menu() {
    while true; do
        clear 2>/dev/null || true
        ui_line
        center_text "${BOLD}CLOUDFLARE TUNNEL MANAGER${RESET}"
        ui_line
        printf '  1) Install cloudflared\n'
        printf '  2) Enter / replace tunnel token (hidden input)\n'
        printf '  3) Configure and restart systemd service\n'
        printf '  4) Run complete repair workflow\n'
        printf '  5) View status and recent logs\n'
        printf '  0) Back\n\n'
        read -r -p '  Select: ' choice
        case "$choice" in
            1) install_cloudflared; pause_screen ;;
            2) configure_cloudflared_token; pause_screen ;;
            3) configure_cloudflared_service; pause_screen ;;
            4) cloudflare_fix; pause_screen ;;
            5) cloudflare_status; pause_screen ;;
            0) return ;;
            *) log WARN "Invalid selection."; sleep 1 ;;
        esac
    done
}

# ------------------------------- Docker ------------------------------------
docker_status() {
    if has_command docker; then docker version --format 'Docker client: {{.Client.Version}}' 2>/dev/null || docker --version; else log WARN "Docker CLI not found."; fi
    if has_command systemctl; then systemctl status docker --no-pager -l 2>/dev/null || true; fi
    if [[ -S /var/run/docker.sock ]]; then log OK "Docker socket exists."; else log WARN "Docker socket is absent."; fi
}

docker_install() {
    require_root || return 1
    is_debian_family || { log ERROR "Docker installation option supports Debian/Ubuntu."; return 1; }
    apt-get update -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io containerd || return 1
    systemctl enable --now docker || return 1
    log OK "Docker packages installed and service enabled."
    docker_status
}

docker_repair() {
    require_root || return 1
    if ! has_command docker; then
        if confirm_action "Docker is missing. Install Debian/Ubuntu Docker packages?"; then docker_install || return 1; else return 1; fi
    fi
    systemctl daemon-reload || true
    systemctl enable docker 2>/dev/null || true
    systemctl restart containerd 2>/dev/null || true
    systemctl restart docker || {
        log ERROR "Docker restart failed; displaying recent logs."
        journalctl -u docker -n 50 --no-pager 2>/dev/null || true
        return 1
    }
    sleep 2
    if docker info >/dev/null 2>&1; then
        log OK "Docker daemon is responding."
    else
        log WARN "Docker service started but docker info failed."
        journalctl -u docker -n 40 --no-pager 2>/dev/null || true
    fi
}

docker_restricted_mode() {
    require_root || return 1
    printf '\n%sWARNING:%s Restricted mode disables Docker bridge networking and NAT.\n' "$RED" "$RESET"
    printf 'Containers may lose network access; this is not a universal Docker fix.\n'
    confirm_action "Apply restricted daemon flags?" || return 1
    install -d -m 755 /etc/docker
    if [[ -f /etc/docker/daemon.json ]]; then
        cp -a /etc/docker/daemon.json "/etc/docker/daemon.json.backup.$(date +%Y%m%d%H%M%S)"
        log WARN "Existing daemon.json backed up. The file will be replaced."
        confirm_action "Continue and replace the current Docker daemon configuration?" || return 1
    fi
    cat > /etc/docker/daemon.json <<'DOCKERJSON'
{
  "iptables": false,
  "bridge": "none",
  "ip-forward": false,
  "ip-masq": false
}
DOCKERJSON
    if ! dockerd --validate --config-file=/etc/docker/daemon.json >/dev/null 2>&1; then
        log ERROR "Docker rejected the configuration; restore your backup manually."
        return 1
    fi
    systemctl restart docker || return 1
    log OK "Restricted Docker configuration applied. Container networking may be disabled."
}

docker_menu() {
    while true; do
        clear 2>/dev/null || true
        ui_line; center_text "${BOLD}DOCKER SERVICE TOOLS${RESET}"; ui_line
        printf '  1) Install Docker packages\n'
        printf '  2) Repair / restart Docker service\n'
        printf '  3) Check Docker status\n'
        printf '  4) Apply restricted no-bridge configuration (advanced)\n'
        printf '  0) Back\n\n'
        read -r -p '  Select: ' choice
        case "$choice" in
            1) docker_install; pause_screen ;;
            2) docker_repair; pause_screen ;;
            3) docker_status; pause_screen ;;
            4) docker_restricted_mode; pause_screen ;;
            0) return ;;
            *) log WARN "Invalid selection."; sleep 1 ;;
        esac
    done
}

# -------------------------- Pterodactyl panel ------------------------------
show_pterodactyl_notice() {
    printf '\n%sPTERODACTYL INSTALLER%s\n' "$BOLD" "$RESET"
    printf 'This uses the community pterodactyl-installer project.\n'
    printf 'Review upstream instructions and confirm the OS is supported first.\n'
    printf 'Upstream: %s\n\n' "$PANEL_INSTALLER"
}

run_pterodactyl_installer() {
    require_root || return 1
    need_network_tools || return 1
    show_pterodactyl_notice
    confirm_action "Download and run the upstream interactive installer?" || return 1
    local tmp
    tmp="$(mktemp /tmp/pterodactyl-installer.XXXXXX.sh)" || return 1
    if ! curl -fL --retry 2 --connect-timeout 15 "$PANEL_INSTALLER" -o "$tmp"; then
        rm -f "$tmp"; log ERROR "Installer download failed."; return 1
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"; log ERROR "Downloaded installer failed syntax validation."; return 1
    fi
    chmod 700 "$tmp"
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    if (( rc == 0 )); then log OK "Upstream installer exited successfully."; else log WARN "Installer exited with status $rc."; fi
    return "$rc"
}

pterodactyl_menu() {
    while true; do
        clear 2>/dev/null || true
        ui_line; center_text "${BOLD}PTERODACTYL INSTALLATION${RESET}"; ui_line
        printf '  1) Run upstream interactive installer (Panel / Wings choices)\n'
        printf '  2) Show service status\n'
        printf '  3) Show recent panel / Wings logs\n'
        printf '  0) Back\n\n'
        read -r -p '  Select: ' choice
        case "$choice" in
            1) run_pterodactyl_installer; pause_screen ;;
            2) systemctl --no-pager --type=service --state=running | grep -Ei 'pterodactyl|wings|nginx|redis|maria|mysql' || true; pause_screen ;;
            3) journalctl -u wings -n 30 --no-pager 2>/dev/null || true; journalctl -u pteroq -n 30 --no-pager 2>/dev/null || true; pause_screen ;;
            0) return ;;
            *) log WARN "Invalid selection."; sleep 1 ;;
        esac
    done
}

# -------------------------------- Tailscale -------------------------------
tailscale_install() {
    require_root || return 1
    need_network_tools || return 1
    log INFO "Downloading Tailscale's official installation script."
    local tmp
    tmp="$(mktemp /tmp/tailscale-install.XXXXXX.sh)" || return 1
    if ! curl -fL --retry 2 --connect-timeout 15 "$TAILSCALE_INSTALLER" -o "$tmp"; then
        rm -f "$tmp"; log ERROR "Download failed."; return 1
    fi
    if ! bash -n "$tmp"; then rm -f "$tmp"; log ERROR "Syntax validation failed."; return 1; fi
    chmod 700 "$tmp"
    if confirm_action "Run the official Tailscale installer?"; then bash "$tmp"; else rm -f "$tmp"; return 1; fi
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

tailscale_menu() {
    while true; do
        clear 2>/dev/null || true
        ui_line; center_text "${BOLD}TAILSCALE NETWORK TOOLS${RESET}"; ui_line
        printf '  1) Install Tailscale\n'
        printf '  2) Check status\n'
        printf '  3) Start / enable daemon\n'
        printf '  4) Run tailscale up (interactive login)\n'
        printf '  5) Show IP addresses\n'
        printf '  0) Back\n\n'
        read -r -p '  Select: ' choice
        case "$choice" in
            1) tailscale_install; pause_screen ;;
            2) tailscale status 2>&1 || true; systemctl status tailscaled --no-pager -l 2>/dev/null || true; pause_screen ;;
            3) require_root && systemctl enable --now tailscaled; pause_screen ;;
            4) if has_command tailscale; then tailscale up; else log ERROR "Tailscale is not installed."; fi; pause_screen ;;
            5) tailscale ip 2>&1 || true; pause_screen ;;
            0) return ;;
            *) log WARN "Invalid selection."; sleep 1 ;;
        esac
    done
}

# ----------------------------- Blueprint info -----------------------------
blueprint_info() {
    ui_line
    center_text "${BOLD}BLUEPRINT EXTENSION MANAGER${RESET}"
    ui_line
    printf '\nBlueprint is an extension ecosystem for Pterodactyl Panel.\n'
    printf 'Use its official documentation to select the release compatible with your panel.\n'
    printf 'Official site: %s\n\n' "$BLUEPRINT_DOCS"
    printf 'This toolkit does not install an unverified third-party Blueprint binary.\n'
    printf 'Before installing, back up your panel files and database.\n\n'
    if has_command curl; then
        printf 'Open the documentation URL in your browser, or copy it above.\n'
    fi
    pause_screen
}

# ----------------------------- System updates -----------------------------
system_update() {
    require_root || return 1
    is_debian_family || { log ERROR "System update helper supports Debian/Ubuntu."; return 1; }
    printf '\n%sSYSTEM UPDATE%s\n' "$BOLD" "$RESET"
    printf 'This runs apt update and apt upgrade. A kernel or service restart may be needed.\n'
    confirm_action "Proceed with system package updates?" || return 1
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || return 1
    apt-get upgrade -y || return 1
    apt-get autoremove -y || true
    apt-get autoclean -y || true
    log OK "System package update completed."
    if [[ -f /var/run/reboot-required ]]; then
        log WARN "System reports that a reboot is required."
    fi
}

# ----------------------------- Diagnostics --------------------------------
section_title() { printf '\n%s── %s ──%s\n' "$CYAN" "$*" "$RESET"; }

show_os_info() {
    section_title "OPERATING SYSTEM"
    if [[ -r /etc/os-release ]]; then cat /etc/os-release; else uname -a; fi
    printf 'Kernel: '; uname -r
    printf 'Architecture: '; uname -m
    printf 'Uptime: '; uptime -p 2>/dev/null || uptime
    printf 'Virtualization: '; systemd-detect-virt 2>/dev/null || printf 'unknown\n'
}

show_cpu_memory() {
    section_title "CPU AND MEMORY"
    if has_command lscpu; then lscpu | grep -E '^(Architecture|CPU\(s\)|Model name|Thread|Core|Socket|Virtualization):' || true; fi
    if has_command free; then free -h; fi
    if [[ -r /proc/loadavg ]]; then printf 'Load average: '; cat /proc/loadavg; fi
}

show_disk_info() {
    section_title "DISK AND FILESYSTEMS"
    df -hT -x tmpfs -x devtmpfs 2>/dev/null || df -h
    if has_command lsblk; then lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || true; fi
}

show_network_info() {
    section_title "NETWORK"
    if has_command ip; then ip -brief address 2>/dev/null || ip address; else hostname -I 2>/dev/null || true; fi
    if has_command ip; then ip route 2>/dev/null || true; fi
    if has_command ss; then ss -lntup 2>/dev/null | head -n 35 || true; fi
    printf 'DNS resolver:\n'; cat /etc/resolv.conf 2>/dev/null | head -n 12 || true
}

show_service_info() {
    section_title "IMPORTANT SERVICES"
    if has_command systemctl; then
        for service in ssh sshd docker containerd cloudflared tailscaled wings nginx apache2 mysql mariadb; do
            if systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null | grep -q "${service}.service"; then
                printf '%-15s ' "$service"
                systemctl is-active "$service" 2>/dev/null || true
            fi
        done
    fi
}

show_recent_errors() {
    section_title "RECENT SYSTEM ERRORS"
    if has_command journalctl; then
        journalctl -p err -b -n 35 --no-pager 2>/dev/null || true
    else
        printf 'journalctl is not available.\n'
    fi
}

run_diagnostics() {
    show_os_info
    show_cpu_memory
    show_disk_info
    show_network_info
    show_service_info
    show_recent_errors
}

diagnostics_menu() {
    while true; do
        clear 2>/dev/null || true
        ui_line; center_text "${BOLD}SERVER DIAGNOSTICS${RESET}"; ui_line
        printf '  1) Full report\n'
        printf '  2) CPU / RAM / load\n'
        printf '  3) Disk usage\n'
        printf '  4) Network / listening ports\n'
        printf '  5) Service states\n'
        printf '  6) Recent system errors\n'
        printf '  7) Save full report to /tmp\n'
        printf '  0) Back\n\n'
        read -r -p '  Select: ' choice
        case "$choice" in
            1) run_diagnostics; pause_screen ;;
            2) show_cpu_memory; pause_screen ;;
            3) show_disk_info; pause_screen ;;
            4) show_network_info; pause_screen ;;
            5) show_service_info; pause_screen ;;
            6) show_recent_errors; pause_screen ;;
            7) local report="/tmp/nexora-report-$(date +%Y%m%d-%H%M%S).txt"; run_diagnostics > "$report" 2>&1; log OK "Report saved to $report"; pause_screen ;;
            0) return ;;
            *) log WARN "Invalid selection."; sleep 1 ;;
        esac
    done
}

# ----------------------------- Utilities ----------------------------------
utilities_menu() {
    while true; do
        clear 2>/dev/null || true
        ui_line; center_text "${BOLD}NEXORA UTILITIES${RESET}"; ui_line
        printf '  1) Show public IP (if internet access is available)\n'
        printf '  2) Show local hostname and addresses\n'
        printf '  3) Check common service ports\n'
        printf '  4) Show disk cleanup candidates\n'
        printf '  5) View toolkit log\n'
        printf '  6) Check clock / timezone\n'
        printf '  0) Back\n\n'
        read -r -p '  Select: ' choice
        case "$choice" in
            1) if need_network_tools; then curl -4 -fsS --max-time 8 https://api.ipify.org || log WARN "Could not retrieve public IPv4."; printf '\n'; fi; pause_screen ;;
            2) hostnamectl 2>/dev/null || hostname; hostname -I 2>/dev/null || true; pause_screen ;;
            3) if has_command ss; then ss -lnt 2>/dev/null | awk 'NR==1 || /:22 |:80 |:443 |:3000 |:8080 |:8443 /'; else log WARN "ss command not found."; fi; pause_screen ;;
            4) df -h /; du -sh /var/cache/apt/archives /var/log 2>/dev/null || true; printf '\nNo files were deleted.\n'; pause_screen ;;
            5) if [[ -r "$LOG_FILE" ]]; then tail -n 100 "$LOG_FILE"; else log WARN "Toolkit log is not available."; fi; pause_screen ;;
            6) date; timedatectl 2>/dev/null || true; pause_screen ;;
            0) return ;;
            *) log WARN "Invalid selection."; sleep 1 ;;
        esac
    done
}

# ---------------------------- Main dashboard ------------------------------
show_dashboard() {
    clear 2>/dev/null || true
    printf '\n'
    ui_line
    center_text "${BOLD}${WHITE}NEXORA CLOUD COMMAND CENTER${RESET}"
    center_text "${DIM}Version ${APP_VERSION}  •  Host: $(hostname 2>/dev/null)  •  $(date '+%H:%M:%S')${RESET}"
    ui_line
    printf '\n'
    printf '  %s[01]%s Cloudflare Tunnel repair and token manager\n' "$CYAN" "$RESET"
    printf '  %s[02]%s Docker install / repair / status\n' "$CYAN" "$RESET"
    printf '  %s[03]%s Pterodactyl Panel / Wings installer\n' "$CYAN" "$RESET"
    printf '  %s[04]%s Tailscale install and network tools\n' "$CYAN" "$RESET"
    printf '  %s[05]%s Blueprint information and documentation\n' "$CYAN" "$RESET"
    printf '  %s[06]%s System package update\n' "$CYAN" "$RESET"
    printf '  %s[07]%s Server diagnostics and report\n' "$CYAN" "$RESET"
    printf '  %s[08]%s Nexora utilities\n' "$CYAN" "$RESET"
    printf '  %s[09]%s Show toolkit version and logs path\n' "$CYAN" "$RESET"
    printf '  %s[0 ]%s Exit\n\n' "$RED" "$RESET"
}

show_about() {
    ui_line
    center_text "${BOLD}ABOUT NEXORA TOOLKIT${RESET}"
    ui_line
    printf 'Name:       %s\n' "$APP_NAME"
    printf 'Version:    %s\n' "$APP_VERSION"
    printf 'Maintainer: %s\n' "$APP_AUTHOR"
    printf 'Log file:   %s\n' "$LOG_FILE"
    printf 'Script:     %s\n' "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    printf '\n'
    pause_screen
}

handle_choice() {
    local choice="$1"
    case "$choice" in
        1) cloudflare_menu ;;
        2) docker_menu ;;
        3) pterodactyl_menu ;;
        4) tailscale_menu ;;
        5) blueprint_info ;;
        6) system_update; pause_screen ;;
        7) diagnostics_menu ;;
        8) utilities_menu ;;
        9) show_about ;;
        0) return 10 ;;
        *) log WARN "Invalid selection: $choice"; sleep 1 ;;
    esac
    return 0
}

cleanup() {
    printf '%s\n' "$RESET"
}

main() {
    setup_logging
    trap cleanup EXIT
    if [[ ! -t 0 ]]; then
        printf 'This toolkit needs an interactive terminal. Run: bash %s\n' "$0" >&2
        exit 2
    fi
    startup_animation
    while true; do
        show_dashboard
        printf '%sSelect an option: %s' "$BOLD" "$RESET"
        local choice
        read -r choice || break
        handle_choice "$choice"
        local rc=$?
        if (( rc == 10 )); then break; fi
    done
    printf '\n%sNexora Cloud Toolkit closed. Stay secure!%s\n' "$GREEN" "$RESET"
}

main "$@"

# ============================================================================
# OPERATOR REFERENCE
# ============================================================================
#
# Suggested first checks on a new machine:
#   1. Open Server Diagnostics and save a report.
#   2. Confirm that the OS is Debian or Ubuntu before package installation.
#   3. Use Cloudflare Tunnel Manager to install cloudflared if needed.
#   4. Enter the token only in the hidden token prompt.
#   5. Review the systemd status and journal after a service restart.
#
# Cloudflare troubleshooting checklist:
#   - Confirm the token belongs to the intended tunnel.
#   - Check that the token file is not empty and is mode 600.
#   - Verify that systemd has loaded the current service file.
#   - Review `journalctl -u cloudflared -n 50 --no-pager`.
#   - Check outbound DNS and HTTPS connectivity from the host.
#   - If UDP connectivity is restricted, the configured service uses HTTP/2.
#   - Verify ingress and public-hostname mappings in the Cloudflare dashboard.
#   - Do not print, paste into support tickets, or share tunnel tokens.
#
# Docker troubleshooting checklist:
#   - Check `systemctl status docker --no-pager -l`.
#   - Check `journalctl -u docker -n 80 --no-pager`.
#   - Check `docker info` and `docker ps -a`.
#   - Review `/etc/docker/daemon.json` before changing daemon settings.
#   - Be careful with nested virtualization and unavailable kernel features.
#   - Restricted mode intentionally disables standard bridge networking.
#   - Back up existing daemon configuration before any manual changes.
#
# Pterodactyl guidance:
#   - The upstream installer is interactive and may alter packages/services.
#   - Read upstream project documentation before starting an installation.
#   - Ensure DNS records point to the correct server before enabling TLS.
#   - Back up the panel database and application files before upgrades.
#   - Keep Panel and Wings versions compatible with each other.
#   - Never expose database passwords, application keys, or API tokens.
#
# Tailscale guidance:
#   - `tailscale up` may display an authentication URL.
#   - Approve the device only in the correct tailnet account.
#   - Use `tailscale status` to verify peer connectivity.
#   - Avoid advertising routes or exit nodes without understanding the impact.
#
# System update guidance:
#   - Keep a backup of important application data before upgrades.
#   - Schedule upgrades when a reboot or service restart is acceptable.
#   - Check `/var/run/reboot-required` after package upgrades on Ubuntu.
#   - Review service status after upgrading packages on production systems.
#
# Security principles:
#   - Prefer official upstream repositories and signed packages.
#   - Do not run shell scripts from unknown URLs without inspecting them.
#   - Use SSH keys and restrict administrative access where possible.
#   - Keep secrets out of shell history, process arguments, and logs.
#   - Rotate any credential that may have been exposed.
#   - Minimize open ports and remove unused services.
#   - Use least privilege for application services.
#   - Apply updates regularly and maintain tested backups.
#
# This reference is intentionally included as operator documentation. It is
# not an automated claim that every host or every installation is healthy.
# Always inspect the real output returned by the system.
# ============================================================================

# HELP TOPIC: Cloudflare token handling
# ID: cloudflare-token
# Token input is read with silent terminal input.
# The token is stored at /etc/cloudflared/token with restrictive permissions.
# Do not share it.
#

# HELP TOPIC: Cloudflare systemd service
# ID: cloudflare-service
# The service is restarted through systemctl and its real state is checked.
# Read journal logs when the process is inactive.
#

# HELP TOPIC: Docker daemon
# ID: docker-daemon
# A daemon restart cannot repair missing kernel capabilities or provider restrictions.
# Inspect journal output and daemon configuration.
#

# HELP TOPIC: Docker network mode
# ID: docker-network
# The optional restricted mode removes bridge networking and NAT settings.
# It can break connectivity for existing containers.
#

# HELP TOPIC: Pterodactyl installation
# ID: pterodactyl
# The upstream installer remains interactive.
# Confirm prerequisites, backups, DNS and supported operating system before proceeding.
#

# HELP TOPIC: Tailscale VPN
# ID: tailscale
# Use the official installer, authenticate the node in your own account, and inspect the resulting peer status.
#

# HELP TOPIC: Blueprint extensions
# ID: blueprint
# Choose releases compatible with the installed panel version and follow official instructions.
# Back up files and database first.
#

# HELP TOPIC: Package updates
# ID: apt-update
# Package upgrades may restart services or require a reboot.
# Review output and schedule maintenance for important systems.
#

# HELP TOPIC: Diagnostics reports
# ID: diagnostics
# Reports may include IP addresses, hostnames, mounted disks and service names.
# Review them before sharing publicly.
#

# HELP TOPIC: Log management
# ID: logs
# The toolkit log is stored in /var/log/nexora-toolkit/toolkit.log when root permissions allow it.
#

# COMMAND QUICK REFERENCE
# apt-get update                     Refresh package metadata.
# apt-get upgrade                    Install available package upgrades.
# systemctl status docker            Inspect Docker service state.
# journalctl -u docker -n 50         Inspect recent Docker service logs.
# docker info                        Check whether the Docker daemon responds.
# cloudflared --version              Display installed cloudflared version.
# systemctl status cloudflared       Inspect Cloudflare Tunnel service.
# journalctl -u cloudflared -n 50    Inspect recent tunnel logs.
# tailscale status                   Display Tailscale peer status.
# tailscale ip                       Display Tailscale addresses.
# systemctl status wings             Inspect Pterodactyl Wings service.
# df -hT                             Display filesystem space.
# free -h                            Display memory usage.
# uptime                             Display uptime and load average.
# ss -lntup                          Display listening sockets.
# ip -brief address                  Display interface addresses.
# systemd-detect-virt                Detect virtualization type.
# timedatectl                        Display time and timezone state.

# PRE-FLIGHT CHECKLIST
# [ ] Confirm the server is backed up.
# [ ] Confirm the correct server and account are selected.
# [ ] Confirm internet access and DNS resolution work.
# [ ] Confirm sufficient disk space is available.
# [ ] Confirm the maintenance window allows service restarts.
# [ ] Keep an independent SSH session open during network changes.
# [ ] Never paste secrets into public chat or screenshots.
#

# POST-CHANGE CHECKLIST
# [ ] Check the service state after a restart.
# [ ] Review recent logs for errors or repeated restarts.
# [ ] Confirm expected ports are listening.
# [ ] Confirm applications still reach required networks.
# [ ] Confirm public DNS points to the expected endpoint.
# [ ] Check disk and memory usage after the operation.
# [ ] Record changes and any manual follow-up steps.
#

# INCIDENT TRIAGE
# [ ] Capture the exact error message before changing settings.
# [ ] Check whether the host recently rebooted.
# [ ] Check service logs around the failure timestamp.
# [ ] Check filesystem space and inode usage.
# [ ] Check memory pressure and load average.
# [ ] Check route and DNS configuration.
# [ ] Change one setting at a time when diagnosing a failure.
# [ ] Revert changes that make the incident worse.
#
