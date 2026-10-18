#!/usr/bin/env bash
# Nexora Cloud branded launcher for the maintool installer
set -Eeuo pipefail

URL="https://raw.githubusercontent.com/vikashlahari50-ctrl/maintool/refs/heads/main/install.sh"
TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

# Colors
CYAN=$'\033[1;96m'
BLUE=$'\033[1;34m'
PURPLE=$'\033[1;35m'
WHITE=$'\033[1;97m'
GREEN=$'\033[1;92m'
GRAY=$'\033[90m'
RED=$'\033[1;91m'
RESET=$'\033[0m'

clear 2>/dev/null || true
printf '%s' "$CYAN"
cat <<'BANNER'
███╗   ██╗███████╗██╗  ██╗ ██████╗ ██████╗  █████╗
████╗  ██║██╔════╝╚██╗██╔╝██╔═══██╗██╔══██╗██╔══██╗
██╔██╗ ██║█████╗   ╚███╔╝ ██║   ██║██████╔╝███████║
██║╚██╗██║██╔══╝   ██╔██╗ ██║   ██║██╔══██╗██╔══██║
██║ ╚████║███████╗██╔╝ ██╗╚██████╔╝██║  ██║██║  ██║
╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝
BANNER
printf '%s' "$RESET"
printf '%s\n' "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
printf '  %sN E X O R A   C L O U D%s  %s•%s  %sINSTALLER LAUNCHER%s\n' "$WHITE" "$RESET" "$CYAN" "$RESET" "$GRAY" "$RESET"
printf '  %sSecure • Fast • Community Powered%s\n' "$GRAY" "$RESET"
printf '%s\n\n' "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

if ! command -v curl >/dev/null 2>&1; then
  printf '%s[ERROR]%s curl is required. Install it first (apt install curl).\n' "$RED" "$RESET"
  exit 1
fi

printf '  %s[1/3]%s Downloading installer from GitHub...\n' "$CYAN" "$RESET"
if ! curl --fail --location --silent --show-error "$URL" --output "$TMP"; then
  printf '\n%s[ERROR]%s Download failed. Check your internet connection and URL.\n' "$RED" "$RESET"
  exit 1
fi
if [[ ! -s "$TMP" ]]; then
  printf '%s[ERROR]%s The downloaded installer is empty.\n' "$RED" "$RESET"
  exit 1
fi

printf '  %s[2/3]%s Initializing Nexora interface...\n\n' "$CYAN" "$RESET"
BAR_WIDTH=36
FRAMES=('◜' '◠' '◝' '◞' '◡' '◟')
for ((i=0; i<=100; i++)); do
  filled=$((i * BAR_WIDTH / 100))
  empty=$((BAR_WIDTH - filled))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '█')"
  rest="$(printf '%*s' "$empty" '' | tr ' ' '░')"
  frame="${FRAMES[i % ${#FRAMES[@]}]}"
  printf '\r  %s%s%s [%s%s%s] %s%3d%%%s %s%s%s' \
    "$BLUE" "$frame" "$RESET" "$CYAN" "$bar" "$GRAY$rest$RESET" "$WHITE" "$i" "$RESET" "$PURPLE" "LOADING" "$RESET"
  sleep 0.08
done
printf '\n\n  %s[3/3]%s Launching downloaded installer...\n\n' "$GREEN" "$RESET"

# Display the downloaded source before execution only when explicitly requested.
if [[ "${NEXORA_REVIEW_ONLY:-0}" == "1" ]]; then
  printf '%sReview-only mode: installer was downloaded but not executed.%s\n' "$CYAN" "$RESET"
  printf 'File saved temporarily for this run only; exiting.\n'
  exit 0
fi

bash "$TMP"
