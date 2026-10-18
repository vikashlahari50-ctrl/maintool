#!/usr/bin/env bash
# =============================================================================
# NEXORA CLOUD COMMAND CENTER
# Single-file Linux VPS maintenance and diagnostics toolkit
# Version: 1.0.0
# Supported: Debian / Ubuntu with systemd
#
# SECURITY NOTES
# - Run only on systems you own or are authorized to administer.
# - Review this script before running it as root.
# - Cloudflare tunnel tokens are read silently and never intentionally printed.
# - Backups are made before replacing the Cloudflare systemd unit.
# - Pterodactyl installer is downloaded from a community-maintained repository.
# - This tool cannot guarantee uptime or provider-side recovery.
# =============================================================================

set -o pipefail
umask 077

APP_NAME="NEXORA CLOUD"
APP_VERSION="1.0.0"
APP_DIR="/var/lib/nexora-command-center"
LOG_DIR="/var/log/nexora-command-center"
BACKUP_DIR="/var/backups/nexora-command-center"
CF_TOKEN_FILE="/etc/cloudflared/token"
CF_SERVICE_FILE="/etc/systemd/system/cloudflared.service"
DOCKER_OVERRIDE_DIR="/etc/systemd/system/docker.service.d"
DOCKER_OVERRIDE_FILE="${DOCKER_OVERRIDE_DIR}/override.conf"
PTERO_INSTALLER_URL="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer/master/install.sh"
TAILSCALE_INSTALL_URL="https://tailscale.com/install.sh"
CURRENT_LOG=""
LAST_ACTION=""
LAST_EXIT_CODE=0
DRY_RUN=0
NO_COLOR=0
QUIET=0
SPINNER_PID=""
WATCH_PID=""
TASK_START=0
TASK_LABEL=""
TASK_LOG=""
TASK_PID=""
TASK_RC=0
TERM_WIDTH=80

# -----------------------------------------------------------------------------
# Terminal palette
# -----------------------------------------------------------------------------
if [[ ! -t 1 || "${TERM:-dumb}" == "dumb" || "${NO_COLOR:-0}" == "1" ]]; then
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW=""
    C_BLUE="" C_MAGENTA="" C_CYAN="" C_WHITE="" C_GRAY="" C_ORANGE=""
    C_BG="" C_BRIGHT_CYAN="" C_BRIGHT_GREEN="" C_BRIGHT_WHITE=""
else
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[38;2;255;75;100m'
    C_GREEN=$'\033[38;2;60;255;170m'
    C_YELLOW=$'\033[38;2;255;205;80m'
    C_BLUE=$'\033[38;2;80;150;255m'
    C_MAGENTA=$'\033[38;2;210;100;255m'
    C_CYAN=$'\033[38;2;0;225;255m'
    C_WHITE=$'\033[38;2;245;248;255m'
    C_GRAY=$'\033[38;2;120;135;155m'
    C_ORANGE=$'\033[38;2;255;145;75m'
    C_BG=$'\033[48;2;5;8;15m'
    C_BRIGHT_CYAN=$'\033[1;38;2;0;245;255m'
    C_BRIGHT_GREEN=$'\033[1;38;2;0;255;150m'
    C_BRIGHT_WHITE=$'\033[1;38;2;255;255;255m'
fi

# -----------------------------------------------------------------------------
# Basic output and logging
# -----------------------------------------------------------------------------
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

ensure_dirs() {
    mkdir -p "$APP_DIR" "$LOG_DIR" "$BACKUP_DIR" 2>/dev/null || true
    chmod 700 "$APP_DIR" "$LOG_DIR" "$BACKUP_DIR" 2>/dev/null || true
}

new_log() {
    ensure_dirs
    CURRENT_LOG="${LOG_DIR}/session-$(date '+%Y%m%d-%H%M%S')-$$.log"
    : > "$CURRENT_LOG"
    chmod 600 "$CURRENT_LOG" 2>/dev/null || true
    printf '%s\n' "NEXORA session started at $(timestamp)" >> "$CURRENT_LOG"
}

log_line() {
    local level="${1:-INFO}"
    shift || true
    local msg="$*"
    [[ -n "$CURRENT_LOG" ]] && printf '[%s] [%s] %s\n' "$(timestamp)" "$level" "$msg" >> "$CURRENT_LOG"
}

say() {
    printf '%b\n' "$*"
    log_line INFO "$(printf '%s' "$*" | sed -E 's/\x1B\[[0-9;]*[mK]//g')"
}

info() { say "${C_CYAN}◆${C_RESET} $*"; }
success() { say "${C_BRIGHT_GREEN}✔${C_RESET} $*"; }
warn() { say "${C_YELLOW}▲${C_RESET} $*"; }
error() { say "${C_RED}✖${C_RESET} $*"; }
muted() { say "${C_GRAY}$*${C_RESET}"; }
section() {
    printf '\n%b\n' "${C_CYAN}${C_BOLD}━━━ $* ━━━${C_RESET}"
    log_line INFO "SECTION: $*"
}
rule() {
    local width="${1:-64}"
    printf '%*s\n' "$width" '' | tr ' ' '─'
}
clear_screen() {
    if [[ -t 1 ]]; then printf '\033[2J\033[H'; fi
}
hide_cursor() { [[ -t 1 ]] && printf '\033[?25l'; }
show_cursor() { [[ -t 1 ]] && printf '\033[?25h'; }
cleanup() {
    [[ -n "$SPINNER_PID" ]] && kill "$SPINNER_PID" 2>/dev/null || true
    [[ -n "$WATCH_PID" ]] && kill "$WATCH_PID" 2>/dev/null || true
    show_cursor
    printf '%b' "$C_RESET"
}
trap cleanup EXIT
trap 'show_cursor; printf "\n"; exit 130' INT
trap 'show_cursor; printf "\n"; exit 143' TERM

# -----------------------------------------------------------------------------
# Environment and permission checks
# -----------------------------------------------------------------------------
is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

require_root() {
    if ! is_root; then
        error "This operation needs root permissions."
        muted "Run: sudo bash code.sh"
        return 1
    fi
}

detect_os() {
    OS_ID="unknown"
    OS_NAME="Unknown Linux"
    OS_VERSION="unknown"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-${NAME:-Unknown Linux}}"
        OS_VERSION="${VERSION_ID:-unknown}"
    fi
}

is_debian_family() {
    [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" || "$OS_ID" == "linuxmint" || "$OS_ID" == "pop" ]]
}

has_command() { command -v "$1" >/dev/null 2>&1; }

need_command() {
    local cmd="$1"
    if ! has_command "$cmd"; then
        error "Required command not found: $cmd"
        return 1
    fi
}

safe_read() {
    local prompt="$1"
    local varname="$2"
    local value=""
    read -r -p "$prompt" value
    printf -v "$varname" '%s' "$value"
}

confirm() {
    local prompt="${1:-Continue?}"
    local answer=""
    printf '%b' "${C_YELLOW}${prompt} [y/N]: ${C_RESET}"
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

confirm_destructive() {
    local prompt="${1:-This action changes system configuration. Continue?}"
    warn "$prompt"
    confirm "Proceed with this system change?"
}

require_debian() {
    detect_os
    if ! is_debian_family; then
        error "This feature currently supports Debian/Ubuntu family only."
        muted "Detected: $OS_NAME"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Animated UI engine
# -----------------------------------------------------------------------------
spinner_frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spinner_ascii=('|' '/' '-' '\')
spinner() {
    local message="${1:-Working}"
    local i=0
    while :; do
        printf '\r%b%s%b %s' "$C_BRIGHT_CYAN" "${spinner_frames[i]}" "$C_RESET" "$message"
        i=$(((i + 1) % ${#spinner_frames[@]}))
        sleep 0.08
    done
}

# Draw a gradient-like bar using truecolor terminal sequences.
draw_progress() {
    local percent="${1:-0}"
    local label="${2:-Processing}"
    local width="${3:-38}"
    local filled=$((percent * width / 100))
    local i r g b
    ((percent < 0)) && percent=0
    ((percent > 100)) && percent=100
    printf '\r%b%-26.26s%b %3d%% [' "$C_WHITE" "$label" "$C_RESET" "$percent"
    for ((i=0; i<width; i++)); do
        if ((i < filled)); then
            r=$((15 + (i * 200 / width)))
            g=$((100 + (i * 130 / width)))
            b=$((255 - (i * 100 / width)))
            printf '\033[38;2;%d;%d;%dm█' "$r" "$g" "$b"
        elif ((i == filled && percent < 100)); then
            printf '%b◆%b' "$C_BRIGHT_WHITE" "$C_RESET"
        else
            printf '%b░%b' "$C_GRAY" "$C_RESET"
        fi
    done
    printf '%b]' "$C_RESET"
}

animate_demo() {
    local title="${1:-Initializing interface}"
    local duration="${2:-3}"
    local total=$((duration * 12))
    local i percent
    ((total < 1)) && total=1
    hide_cursor
    for ((i=0; i<=total; i++)); do
        percent=$((i * 100 / total))
        draw_progress "$percent" "$title" 38
        sleep 0.08
    done
    printf '\n'
    show_cursor
}

# Task wrapper: runs real command in the background, shows a live spinner,
# stores output to a protected log, and prints useful error lines on failure.
run_task() {
    local label="$1"
    shift
    local logfile="${WORK_DIR:-/tmp}/nexora-task-$$-$RANDOM.log"
    local rc=0
    mkdir -p "$(dirname "$logfile")" 2>/dev/null || true
    TASK_LABEL="$label"
    TASK_LOG="$logfile"
    TASK_START=$SECONDS
    section "$label"
    info "Executing operation. Live output is saved to the session log."
    log_line INFO "TASK START: $label"
    "$@" >"$logfile" 2>&1 &
    TASK_PID=$!
    hide_cursor
    local i=0
    while kill -0 "$TASK_PID" 2>/dev/null; do
        printf '\r%b%s%b %s  %s' "$C_BRIGHT_CYAN" "${spinner_frames[i % ${#spinner_frames[@]}]}" "$C_RESET" "$label" "$(printf '%02ds' "$((SECONDS-TASK_START))")"
        i=$((i + 1))
        sleep 0.12
    done
    wait "$TASK_PID" || rc=$?
    show_cursor
    printf '\r%*s\r' 100 ''
    TASK_RC=$rc
    LAST_ACTION="$label"
    LAST_EXIT_CODE="$rc"
    if ((rc == 0)); then
        success "$label completed in $((SECONDS-TASK_START))s."
        log_line INFO "TASK SUCCESS: $label"
    else
        error "$label failed with exit code $rc."
        log_line ERROR "TASK FAILURE: $label (exit $rc)"
        printf '\n%bRecent output:%b\n' "$C_YELLOW" "$C_RESET"
        tail -n 35 "$logfile" 2>/dev/null || true
    fi
    return "$rc"
}

# -----------------------------------------------------------------------------
# Banner and dashboard
# -----------------------------------------------------------------------------
draw_logo() {
    printf '%b' "$C_BRIGHT_WHITE"
    cat <<'ART'
███╗   ██╗███████╗██╗  ██╗ ██████╗ ██████╗  █████╗
████╗  ██║██╔════╝╚██╗██╔╝██╔═══██╗██╔══██╗██╔══██╗
██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║██████╔╝███████║
██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║██╔══██╗██╔══██║
██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝██║  ██║██║  ██║
╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝
ART
    printf '%b' "$C_RESET"
}

draw_header() {
    clear_screen
    draw_logo
    printf '\n%b  COMMAND CENTER  %b  VERSION %s\n' "$C_CYAN" "$C_GRAY" "$APP_VERSION"
    printf '%b  SYSTEM CONTROL • REPAIR • DIAGNOSTICS%b\n' "$C_GRAY" "$C_RESET"
    rule 72
    detect_os
    printf '%b Host%b      : %s\n' "$C_CYAN" "$C_RESET" "$(hostname 2>/dev/null || echo unknown)"
    printf '%b Platform%b  : %s\n' "$C_CYAN" "$C_RESET" "$OS_NAME"
    printf '%b Kernel%b    : %s\n' "$C_CYAN" "$C_RESET" "$(uname -r)"
    printf '%b Uptime%b    : %s\n' "$C_CYAN" "$C_RESET" "$(uptime -p 2>/dev/null || uptime 2>/dev/null | cut -d, -f1)"
    printf '%b Privilege%b : %s\n' "$C_CYAN" "$C_RESET" "$(if is_root; then echo ROOT; else echo USER; fi)"
    rule 72
}

show_system_cards() {
    local cpu ram disk load
    cpu="$(nproc 2>/dev/null || echo '?')"
    ram="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 " / " $2}')"
    disk="$(df -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}')"
    load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')"
    printf '\n%b SYSTEM SNAPSHOT%b\n' "$C_MAGENTA" "$C_RESET"
    printf '  CPU threads : %-12s RAM: %-22s\n' "$cpu" "${ram:-unknown}"
    printf '  Root disk   : %-20s Load: %s\n' "${disk:-unknown}" "$load"
}

menu_line() {
    printf '  %b[%02d]%b %-31s %b%s%b\n' "$C_CYAN" "$1" "$C_RESET" "$2" "$C_GRAY" "$3" "$C_RESET"
}

draw_menu() {
    printf '\n%b  MODULE SELECTOR%b\n' "$C_BRIGHT_WHITE" "$C_RESET"
    menu_line 1 "Cloudflare Tunnel Repair" "TOKEN / HTTP2 / SYSTEMD"
    menu_line 2 "Docker Install / Repair" "DOCKERD / SERVICE / LOGS"
    menu_line 3 "Pterodactyl Panel Installer" "COMMUNITY INSTALLER"
    menu_line 4 "Pterodactyl Wings Installer" "NODE / WINGS WORKFLOW"
    menu_line 5 "Tailscale Installer" "PRIVATE MESH VPN"
    menu_line 6 "Linux Package Update" "APT / DEPENDENCIES"
    menu_line 7 "Network & DNS Diagnostics" "ROUTES / DNS / HTTPS"
    menu_line 8 "Docker Diagnostics" "STATUS / INFO / JOURNAL"
    menu_line 9 "Live VPS Monitor" "CPU / RAM / DISK / SERVICES"
    menu_line 10 "Cloudflare Diagnostics" "STATUS / LOGS / CONNECTIVITY"
    menu_line 11 "System Health Report" "RESOURCE / DISK / OOM"
    menu_line 12 "Service Manager" "RESTART / STATUS / LOGS"
    menu_line 13 "Firewall Status" "UFW / NFT / IPTABLES"
    menu_line 14 "Disk Cleanup Preview" "SAFE CACHE CLEANUP"
    menu_line 15 "Backup Configuration" "SERVICE / NETWORK CONFIG"
    menu_line 16 "View Session Logs" "LOCAL TROUBLESHOOTING"
    menu_line 17 "Animation Preview" "NEON UI DEMO"
    menu_line 18 "About / Help" "USAGE / SAFETY"
    printf '\n  %b[Q]%b Quit command center\n' "$C_RED" "$C_RESET"
    rule 72
}

# -----------------------------------------------------------------------------
# Cloudflare Tunnel repair
# -----------------------------------------------------------------------------
cf_install_package() {
    require_debian || return 1
    run_task "Install Cloudflared package" bash -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y ca-certificates curl gnupg
        install -d -m 0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
          -o /usr/share/keyrings/cloudflare-main.gpg
        chmod 0644 /usr/share/keyrings/cloudflare-main.gpg
        printf "%s\n" \
          "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
          > /etc/apt/sources.list.d/cloudflared.list
        apt-get update
        apt-get install -y cloudflared
        command -v cloudflared
    '
}

cf_collect_token() {
    local token=""
    printf '\n%bCloudflare tunnel token setup%b\n' "$C_CYAN" "$C_RESET"
    muted "Paste the complete tunnel token. Input will remain hidden."
    read -r -s -p "Tunnel token: " token
    printf '\n'
    if [[ -z "${token//[[:space:]]/}" ]]; then
        unset token
        error "Token cannot be empty."
        return 1
    fi
    install -d -m 0750 /etc/cloudflared
    local tmp_token
    tmp_token="$(mktemp /etc/cloudflared/.token.XXXXXX)"
    chmod 600 "$tmp_token"
    printf '%s' "$token" > "$tmp_token"
    unset token
    if [[ -s "$CF_TOKEN_FILE" ]]; then
        cp -a "$CF_TOKEN_FILE" "${BACKUP_DIR}/cloudflared-token.$(date +%s)" 2>/dev/null || true
        chmod 600 "${BACKUP_DIR}"/cloudflared-token.* 2>/dev/null || true
    fi
    install -m 600 "$tmp_token" "$CF_TOKEN_FILE"
    rm -f "$tmp_token"
    success "Token stored with restrictive permissions."
    log_line INFO "Cloudflare token updated; value intentionally omitted."
}

cf_write_service() {
    require_root || return 1
    if [[ -f "$CF_SERVICE_FILE" ]]; then
        cp -a "$CF_SERVICE_FILE" "${BACKUP_DIR}/cloudflared.service.$(date +%s)"
    fi
    cat > "$CF_SERVICE_FILE" <<'UNIT'
[Unit]
Description=Nexora Cloud - Cloudflare Tunnel
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
    chmod 644 "$CF_SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable cloudflared
}

cf_diagnostics() {
    section "Cloudflare Tunnel Diagnostics"
    printf '%bService state%b: ' "$C_CYAN" "$C_RESET"
    systemctl is-active cloudflared 2>/dev/null || true
    printf '%bToken file%b: ' "$C_CYAN" "$C_RESET"
    if [[ -s "$CF_TOKEN_FILE" ]]; then
        echo "exists and non-empty (contents hidden)"
        stat -c 'Permissions: %a  Owner: %U:%G  Size: %s bytes' "$CF_TOKEN_FILE" 2>/dev/null || true
    else
        echo "missing or empty"
    fi
    printf '\n%bRecent matching log lines%b\n' "$C_CYAN" "$C_RESET"
    journalctl -u cloudflared -n 100 --no-pager -o cat 2>/dev/null |
        grep -iE 'connected|connection|registered|error|failed|timeout|retry|unauthorized|401|1033|quic|http2|tunnel' |
        tail -n 50 || true
    printf '\n%bConnectivity%b\n' "$C_CYAN" "$C_RESET"
    getent hosts region1.v2.argotunnel.com || true
    curl -fsS --connect-timeout 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
        sed -n '1,6p' || warn "Cloudflare HTTPS check did not succeed."
    printf '\n%bService summary%b\n' "$C_CYAN" "$C_RESET"
    systemctl show cloudflared -p ActiveState -p SubState -p NRestarts 2>/dev/null || true
}

cloudflare_repair() {
    require_root || return 1
    confirm_destructive "This replaces the Cloudflare systemd unit after backing it up." || return 0
    if ! has_command cloudflared; then
        cf_install_package || return 1
    else
        info "Cloudflared is already installed: $(cloudflared --version 2>/dev/null | head -n1)"
    fi
    cf_collect_token || return 1
    cf_write_service || return 1
    run_task "Restart Cloudflare Tunnel" systemctl restart cloudflared || {
        cf_diagnostics
        return 1
    }
    sleep 4
    cf_diagnostics
    if systemctl is-active --quiet cloudflared; then
        success "Cloudflared service is active."
        if journalctl -u cloudflared --since "-2 minutes" --no-pager -o cat 2>/dev/null |
            grep -qiE 'Registered tunnel connection|connection.*registered'; then
            success "Recent tunnel registration message detected."
        else
            warn "Service is active, but registration is not confirmed by recent logs."
        fi
    else
        error "Tunnel service is not active; inspect logs above."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Docker repair and diagnostics
# -----------------------------------------------------------------------------
docker_show_diagnostics() {
    section "Docker Diagnostics"
    systemctl status docker --no-pager -l 2>&1 | head -n 45 || true
    printf '\n%bDocker version%b\n' "$C_CYAN" "$C_RESET"
    docker version 2>&1 | head -n 30 || true
    printf '\n%bDocker info%b\n' "$C_CYAN" "$C_RESET"
    docker info 2>&1 | head -n 70 || true
    printf '\n%bJournal%b\n' "$C_CYAN" "$C_RESET"
    journalctl -u docker -n 50 --no-pager 2>/dev/null || true
    printf '\n%bDaemon log%b\n' "$C_CYAN" "$C_RESET"
    tail -n 50 /var/log/dockerd.log 2>/dev/null || true
}

docker_repair() {
    require_root || return 1
    require_debian || return 1
    warn "Requested mode disables bridge networking, IP forwarding, IP masquerading and Docker-managed iptables."
    warn "Normal bridge networks, published ports and container networking may stop working."
    confirm_destructive "Install Docker and set the requested restricted dockerd flags?" || return 0

    run_task "Install Docker package" bash -c '
        set -e
        apt-get update
        apt-get install -y docker.io
    ' || return 1

    mkdir -p "$DOCKER_OVERRIDE_DIR"
    if [[ -f "$DOCKER_OVERRIDE_FILE" ]]; then
        cp -a "$DOCKER_OVERRIDE_FILE" "${BACKUP_DIR}/docker-override.$(date +%s)"
    fi
    cat > "$DOCKER_OVERRIDE_FILE" <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --iptables=false --bridge=none --ip-forward=false --ip-masq=false
UNIT
    systemctl daemon-reload
    systemctl enable docker || return 1
    run_task "Restart Docker daemon" systemctl restart docker || {
        docker_show_diagnostics
        return 1
    }
    sleep 3
    docker_show_diagnostics
    if systemctl is-active --quiet docker; then
        success "Docker service is active."
        docker ps || true
    else
        error "Docker service failed to start."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Pterodactyl community installer
# -----------------------------------------------------------------------------
ptero_download_installer() {
    need_command curl || return 1
    run_task "Download Pterodactyl community installer" curl -fL --retry 2 \
        "$PTERO_INSTALLER_URL" -o "${WORK_DIR}/pterodactyl-installer.sh" || return 1
    if [[ ! -s "${WORK_DIR}/pterodactyl-installer.sh" ]]; then
        error "Installer download was empty."
        return 1
    fi
    if ! head -n 1 "${WORK_DIR}/pterodactyl-installer.sh" | grep -qE '^#!'; then
        error "Downloaded file does not look like a shell script."
        return 1
    fi
    chmod 700 "${WORK_DIR}/pterodactyl-installer.sh"
}

pterodactyl_panel_install() {
    require_root || return 1
    require_debian || return 1
    section "Pterodactyl Panel Installer"
    warn "This invokes a third-party community installer as root."
    warn "Review the source repository before proceeding; take a VPS backup."
    confirm "Download and execute the community installer?" || return 0
    ptero_download_installer || return 1
    bash "${WORK_DIR}/pterodactyl-installer.sh"
}

pterodactyl_wings_install() {
    require_root || return 1
    require_debian || return 1
    section "Pterodactyl Wings Workflow"
    warn "Wings needs a working Panel, node configuration, allocation and valid TLS setup."
    warn "This menu does not invent node credentials or allocation values."
    confirm "Open the community installer menu and select Wings yourself?" || return 0
    ptero_download_installer || return 1
    bash "${WORK_DIR}/pterodactyl-installer.sh"
}

# -----------------------------------------------------------------------------
# Tailscale installation
# -----------------------------------------------------------------------------
tailscale_install() {
    require_root || return 1
    require_debian || return 1
    warn "This installs the Tailscale client and starts tailscaled."
    confirm "Continue with the official Tailscale install script?" || return 0
    run_task "Download Tailscale installer" curl -fL --retry 2 \
        "$TAILSCALE_INSTALL_URL" -o "${WORK_DIR}/tailscale-install.sh" || return 1
    if [[ ! -s "${WORK_DIR}/tailscale-install.sh" ]]; then
        error "Tailscale installer download is empty."
        return 1
    fi
    if ! confirm "Execute downloaded Tailscale installer as root?"; then
        return 0
    fi
    run_task "Install Tailscale" bash "${WORK_DIR}/tailscale-install.sh" || return 1
    systemctl enable --now tailscaled || return 1
    section "Tailscale Status"
    tailscale status 2>&1 || true
    if ! tailscale status >/dev/null 2>&1; then
        muted "If this device is not authenticated, run: tailscale up"
    fi
}

# -----------------------------------------------------------------------------
# Package update
# -----------------------------------------------------------------------------
system_update() {
    require_root || return 1
    require_debian || return 1
    warn "This updates packages from configured APT repositories."
    confirm "Run apt-get update and apt-get upgrade?" || return 0
    run_task "Refresh APT package index" apt-get update || return 1
    run_task "Repair interrupted package dependencies" apt-get --fix-broken install -y || return 1
    run_task "Upgrade installed packages" apt-get upgrade -y
    local rc=$?
    section "APT Summary"
    apt-get -s upgrade 2>/dev/null | tail -n 8 || true
    return "$rc"
}

# -----------------------------------------------------------------------------
# Network diagnostics
# -----------------------------------------------------------------------------
network_diagnostics() {
    section "Network & DNS Diagnostics"
    printf '%bInterface addresses%b\n' "$C_CYAN" "$C_RESET"
    ip -brief address 2>/dev/null || ip address 2>/dev/null || true
    printf '\n%bRouting table%b\n' "$C_CYAN" "$C_RESET"
    ip route 2>/dev/null || route -n 2>/dev/null || true
    printf '\n%bDNS resolver%b\n' "$C_CYAN" "$C_RESET"
    cat /etc/resolv.conf 2>/dev/null || true
    printf '\n%bDNS lookups%b\n' "$C_CYAN" "$C_RESET"
    local host
    for host in cloudflare.com github.com google.com region1.v2.argotunnel.com; do
        printf '\n%s\n' "$host"
        getent ahosts "$host" 2>/dev/null | head -n 4 || echo "DNS lookup failed"
    done
    printf '\n%bHTTPS probe%b\n' "$C_CYAN" "$C_RESET"
    curl -sS --connect-timeout 5 --max-time 10 \
        https://www.cloudflare.com/cdn-cgi/trace 2>&1 | head -n 10 || true
    printf '\n%bListening sockets%b\n' "$C_CYAN" "$C_RESET"
    ss -lntup 2>/dev/null | head -n 60 || true
    printf '\n%bFirewall status%b\n' "$C_CYAN" "$C_RESET"
    if has_command ufw; then ufw status verbose 2>/dev/null || true; fi
    if has_command nft; then nft list ruleset 2>/dev/null | head -n 50 || true; fi
}

# -----------------------------------------------------------------------------
# System health report
# -----------------------------------------------------------------------------
health_report() {
    section "System Health Report"
    printf '%bHost identity%b\n' "$C_CYAN" "$C_RESET"
    hostnamectl 2>/dev/null || hostname
    printf '\n%bUptime and load%b\n' "$C_CYAN" "$C_RESET"
    uptime
    printf '\n%bCPU%b\n' "$C_CYAN" "$C_RESET"
    nproc 2>/dev/null || true
    lscpu 2>/dev/null | grep -E 'Architecture|CPU|Model name|Thread|Core|Socket|Virtualization' || true
    printf '\n%bMemory%b\n' "$C_CYAN" "$C_RESET"
    free -h
    printf '\n%bFilesystems%b\n' "$C_CYAN" "$C_RESET"
    df -hT
    printf '\n%bInodes%b\n' "$C_CYAN" "$C_RESET"
    df -ih
    printf '\n%bTop CPU processes%b\n' "$C_CYAN" "$C_RESET"
    ps -eo pid,ppid,comm,%cpu,%mem --sort=-%cpu | head -n 16
    printf '\n%bTop memory processes%b\n' "$C_CYAN" "$C_RESET"
    ps -eo pid,ppid,comm,%cpu,%mem --sort=-%mem | head -n 16
    printf '\n%bOOM / kernel warnings%b\n' "$C_CYAN" "$C_RESET"
    journalctl -k -b --no-pager 2>/dev/null |
        grep -iE 'out of memory|oom-kill|killed process|kernel panic|watchdog|I/O error' |
        tail -n 30 || true
    printf '\n%bFailed systemd units%b\n' "$C_CYAN" "$C_RESET"
    systemctl --failed --no-pager 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Service manager
# -----------------------------------------------------------------------------
service_manager() {
    section "Service Manager"
    echo "Enter a service name, for example: cloudflared, docker, tailscaled"
    local service action
    read -r -p "Service name: " service
    [[ "$service" =~ ^[a-zA-Z0-9_.@-]+$ ]] || {
        error "Invalid service name."
        return 1
    }
    echo "1) Status"
    echo "2) Restart"
    echo "3) Start"
    echo "4) Stop"
    echo "5) Recent logs"
    echo "6) Enable at boot"
    read -r -p "Action: " action
    case "$action" in
        1) systemctl status "$service" --no-pager -l ;;
        2) confirm_destructive "Restart $service?" && systemctl restart "$service" ;;
        3) confirm "Start $service?" && systemctl start "$service" ;;
        4) confirm_destructive "Stop $service? This can cause downtime." && systemctl stop "$service" ;;
        5) journalctl -u "$service" -n 100 --no-pager ;;
        6) systemctl enable "$service" ;;
        *) error "Unknown action."; return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Firewall status
# -----------------------------------------------------------------------------
firewall_status() {
    section "Firewall Status"
    if has_command ufw; then
        printf '\n%bUFW%b\n' "$C_CYAN" "$C_RESET"
        ufw status verbose 2>&1 || true
    else
        muted "UFW is not installed."
    fi
    if has_command nft; then
        printf '\n%bnftables%b\n' "$C_CYAN" "$C_RESET"
        nft list ruleset 2>&1 | head -n 100 || true
    else
        muted "nft command is not installed."
    fi
    if has_command iptables; then
        printf '\n%biptables filter%b\n' "$C_CYAN" "$C_RESET"
        iptables -S 2>&1 | head -n 80 || true
        printf '\n%biptables NAT%b\n' "$C_CYAN" "$C_RESET"
        iptables -t nat -S 2>&1 | head -n 80 || true
    else
        muted "iptables is not installed."
    fi
    warn "This module only reports firewall state; it does not open ports automatically."
}

# -----------------------------------------------------------------------------
# Disk cleanup with preview and confirmation
# -----------------------------------------------------------------------------
disk_cleanup() {
    require_root || return 1
    section "Disk Cleanup Preview"
    printf '%bBefore cleanup%b\n' "$C_CYAN" "$C_RESET"
    df -h /
    echo
    echo "The cleanup removes cached APT package files and rotates no logs."
    echo "It does not remove Docker volumes, user files, or container data."
    confirm "Clean APT package cache?" || return 0
    run_task "Clean APT cache" apt-get clean || return 1
    run_task "Remove unused APT package files" apt-get autoclean || return 1
    printf '\n%bAfter cleanup%b\n' "$C_CYAN" "$C_RESET"
    df -h /
}

# -----------------------------------------------------------------------------
# Configuration backup
# -----------------------------------------------------------------------------
backup_config() {
    require_root || return 1
    ensure_dirs
    local dest="${BACKUP_DIR}/config-$(date '+%Y%m%d-%H%M%S').tar.gz"
    section "Configuration Backup"
    local items=()
    [[ -f "$CF_SERVICE_FILE" ]] && items+=("etc/systemd/system/cloudflared.service")
    [[ -f "$DOCKER_OVERRIDE_FILE" ]] && items+=("etc/systemd/system/docker.service.d/override.conf")
    [[ -f /etc/docker/daemon.json ]] && items+=("etc/docker/daemon.json")
    [[ -f /etc/hosts ]] && items+=("etc/hosts")
    [[ -f /etc/resolv.conf ]] && items+=("etc/resolv.conf")
    [[ -d /etc/systemd/system ]] && items+=("etc/systemd/system")
    if ((${#items[@]} == 0)); then
        warn "No selected configuration files found."
        return 0
    fi
    warn "Backup may contain sensitive configuration. Token file is intentionally excluded."
    confirm "Create protected configuration archive?" || return 0
    tar -czf "$dest" -C / "${items[@]}" 2>"${WORK_DIR}/backup.err" || {
        error "Backup failed."
        cat "${WORK_DIR}/backup.err"
        return 1
    }
    chmod 600 "$dest"
    success "Backup created: $dest"
    ls -lh "$dest"
}

# -----------------------------------------------------------------------------
# Session log viewer
# -----------------------------------------------------------------------------
view_logs() {
    section "Session Logs"
    ensure_dirs
    local files=()
    mapfile -t files < <(find "$LOG_DIR" -maxdepth 1 -type f -name 'session-*.log' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}')
    if ((${#files[@]} == 0)); then
        warn "No session logs found yet."
        return 0
    fi
    local index=1 file
    for file in "${files[@]:0:15}"; do
        printf '  %2d) %s\n' "$index" "$(basename "$file")"
        index=$((index + 1))
    done
    read -r -p "Choose log number (0 to cancel): " index
    [[ "$index" =~ ^[0-9]+$ ]] || return 1
    ((index == 0)) && return 0
    ((index >= 1 && index <= ${#files[@]})) || {
        error "Invalid selection."
        return 1
    }
    less -R "${files[index-1]}" 2>/dev/null || cat "${files[index-1]}"
}

# -----------------------------------------------------------------------------
# Live monitor
# -----------------------------------------------------------------------------
live_monitor() {
    section "Live VPS Monitor"
    muted "Press Ctrl+C to return to the menu."
    while :; do
        clear_screen
        printf '%bNEXORA CLOUD • LIVE TELEMETRY%b\n' "$C_BRIGHT_CYAN" "$C_RESET"
        printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        rule 72
        printf '\n%bCPU / LOAD%b\n' "$C_CYAN" "$C_RESET"
        uptime
        printf '\n%bMEMORY%b\n' "$C_CYAN" "$C_RESET"
        free -h
        printf '\n%bDISK%b\n' "$C_CYAN" "$C_RESET"
        df -hT / /var 2>/dev/null | awk '!seen[$1 FS $7]++'
        printf '\n%bTOP PROCESSES%b\n' "$C_CYAN" "$C_RESET"
        ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 12
        printf '\n%bSERVICE STATES%b\n' "$C_CYAN" "$C_RESET"
        local svc
        for svc in cloudflared docker tailscaled wings; do
            printf '  %-14s : ' "$svc"
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                printf '%bACTIVE%b\n' "$C_GREEN" "$C_RESET"
            else
                printf '%bINACTIVE%b\n' "$C_RED" "$C_RESET"
            fi
        done
        printf '\n%bRefresh: 3 seconds • Ctrl+C to exit%b\n' "$C_GRAY" "$C_RESET"
        sleep 3
    done
}

# -----------------------------------------------------------------------------
# UI preview
# -----------------------------------------------------------------------------
animation_preview() {
    section "Neon Animation Preview"
    animate_demo "Initializing interface" 2
    animate_demo "Loading system modules" 2
    animate_demo "Verifying service status" 2
    animate_demo "Rendering command center" 2
    success "Animation preview completed."
}

# -----------------------------------------------------------------------------
# Help and usage
# -----------------------------------------------------------------------------
about_help() {
    section "NEXORA CLOUD Command Center"
    cat <<'HELP'
PURPOSE
  Single-file terminal toolkit for common Linux VPS operations.

HOW TO RUN
  chmod +x code.sh
  sudo ./code.sh

MODULES
  1  Cloudflare Tunnel repair:
     Installs cloudflared if needed, reads the token without echoing it,
     writes a systemd service using HTTP/2, restarts it and checks logs.

  2  Docker install / repair:
     Installs docker.io and configures dockerd with the requested flags:
     --iptables=false --bridge=none --ip-forward=false --ip-masq=false
     Those flags can disable standard Docker bridge networking.

  3  Pterodactyl Panel:
     Downloads and runs the community installer after confirmation.

  4  Pterodactyl Wings:
     Opens the same installer workflow so the operator can select Wings.
     A valid Panel node configuration is still required.

  5  Tailscale:
     Downloads the Tailscale installer, installs it and enables tailscaled.
     Authentication may still be needed using `tailscale up`.

  6  Linux package update:
     Runs APT index refresh, dependency repair and package upgrade.

  7  Network diagnostics:
     Reports interface addresses, routes, DNS lookups, HTTPS connectivity,
     listening ports and selected firewall state.

  8  Docker diagnostics:
     Reports Docker service state, CLI version, engine info and logs.

  9  Live monitor:
     Refreshes CPU/load, memory, disk, process and service information.

 10  Cloudflare diagnostics:
     Checks the service, token-file metadata, recent logs and connectivity.

 11  System health:
     Reports OS, resources, filesystem/inodes, top processes, kernel OOM
     messages and failed systemd units.

 12  Service manager:
     Allows status, restart, start, stop, logs and enable operations.

 13  Firewall status:
     Reads UFW, nftables and iptables state. It does not alter firewall rules.

 14  Disk cleanup:
     Cleans APT cache only after confirmation. Does not delete user files.

 15  Configuration backup:
     Archives selected system configuration. The Cloudflare token is excluded.

 16  Session logs:
     Opens local session logs to assist troubleshooting.

 17  Animation preview:
     Demonstrates the animated interface.

 18  About / help:
     Displays this help page.

SECURITY
  - Never paste secrets into public issue reports.
  - Never commit /etc/cloudflared/token to GitHub.
  - Verify downloaded third-party installer source before executing it.
  - Back up important VPS data before service changes.
  - This utility cannot prevent provider-side reboots or guarantee uptime.

LIMITATIONS
  - Service active does not necessarily mean a remote tunnel is connected.
  - A successful package installation does not guarantee application readiness.
  - Progress spinners represent activity, not an exact percentage of apt work.
  - The program does not automatically open firewall ports.
  - Installer behavior depends on OS version and upstream repository changes.
HELP
}

# -----------------------------------------------------------------------------
# Menu dispatch and error handling
# -----------------------------------------------------------------------------
run_selected() {
    local choice="$1"
    case "$choice" in
        1) cloudflare_repair ;;
        2) docker_repair ;;
        3) pterodactyl_panel_install ;;
        4) pterodactyl_wings_install ;;
        5) tailscale_install ;;
        6) system_update ;;
        7) network_diagnostics ;;
        8) docker_show_diagnostics ;;
        9) live_monitor ;;
        10) cf_diagnostics ;;
        11) health_report ;;
        12) service_manager ;;
        13) firewall_status ;;
        14) disk_cleanup ;;
        15) backup_config ;;
        16) view_logs ;;
        17) animation_preview ;;
        18) about_help ;;
        *) error "Unknown menu option: $choice"; return 2 ;;
    esac
}

show_result_footer() {
    printf '\n'
    if ((LAST_EXIT_CODE == 0)); then
        success "Last action: ${LAST_ACTION:-menu operation}"
    else
        error "Last action failed: ${LAST_ACTION:-menu operation}"
        muted "Review output above and session logs in ${LOG_DIR}."
    fi
}

wait_for_enter() {
    printf '\n%bPress ENTER to return to the main menu...%b' "$C_GRAY" "$C_RESET"
    read -r _
}

main() {
    WORK_DIR="$(mktemp -d)"
    chmod 700 "$WORK_DIR"
    new_log
    detect_os

    while :; do
        draw_header
        show_system_cards
        draw_menu
        printf '%bNEXORA%b > ' "$C_BRIGHT_CYAN" "$C_RESET"
        local choice=""
        read -r choice
        case "${choice,,}" in
            q|quit|exit)
                success "NEXORA CLOUD session closed."
                log_line INFO "Session closed by operator."
                return 0
                ;;
            help|h|?)
                about_help
                wait_for_enter
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]{1,2}$ ]] && ((choice >= 1 && choice <= 18)); then
                    LAST_ACTION="Menu option $choice"
                    LAST_EXIT_CODE=0
                    run_selected "$choice"
                    LAST_EXIT_CODE=$?
                    show_result_footer
                    wait_for_enter
                else
                    error "Enter a menu number from 1 to 18, or Q to quit."
                    sleep 1
                fi
                ;;
        esac
    done
}

main "$@"
