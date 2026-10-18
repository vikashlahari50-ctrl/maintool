#!/usr/bin/env bash
# Nexora Cloud animated GitHub installer launcher
# Downloads the configured installer, displays an 8-second animated loading bar,
# then launches it. The bar is a visual pre-launch animation, not real install progress.

set -Eeuo pipefail

URL="${NEXORA_INSTALL_URL:-https://raw.githubusercontent.com/vikashlahari50-ctrl/maintool/refs/heads/main/install.sh}"
TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required. Install curl and run this script again."
  exit 1
fi

printf '\033[?25l'
restore_cursor() { printf '\033[?25h'; }
trap 'restore_cursor; cleanup' EXIT

printf '\033[2J\033[H'
printf '\033[1;96m'
cat <<'BANNER'
 _   _ _____  _____  ___  ____      _    ____  ___   _   _
| \ | | ____|/ ___/ / _ \|  _ \    / \  / ___|/ _ \ | \ | |
|  \| |  _|  | |    | | | | |_) |  / _ \| |   | | | ||  \| |
| |\  | |___ | |___ | |_| |  _ <  / ___ \ |___| |_| || |\  |
|_| \_|_____|\____| \___/|_| \_\/_/   \_\____|\___/ |_| \_|
BANNER
printf '\033[0m\n'
printf '\033[90m             GitHub Installer • Secure Download Check\033[0m\n\n'
printf '\033[1;97m[1/2]\033[0m Downloading installer from GitHub...\n'

if ! curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 "$URL" -o "$TMP"; then
  printf '\n\033[1;31m✖ Download failed. Check the URL/network and try again.\033[0m\n'
  exit 1
fi

if [[ ! -s "$TMP" ]]; then
  printf '\n\033[1;31m✖ Downloaded file is empty; refusing to run it.\033[0m\n'
  exit 1
fi

printf '\033[1;32m✔ Download complete\033[0m  \033[90m(%s bytes)\033[0m\n\n' "$(wc -c < "$TMP" | tr -d ' ')"
printf '\033[1;97m[2/2]\033[0m Preparing Nexora Cloud...\n\n'

duration=8
steps=80
bar_width=36
for ((i=0; i<=steps; i++)); do
  percent=$((i * 100 / steps))
  filled=$((i * bar_width / steps))
  empty=$((bar_width - filled))
  case $((i % 4)) in
    0) spinner='◐' ;;
    1) spinner='◓' ;;
    2) spinner='◑' ;;
    3) spinner='◒' ;;
  esac

  printf '\r\033[1;96m  %s  \033[0m[' "$spinner"
  printf '\033[1;96m%*s\033[0m' "$filled" '' | tr ' ' '█'
  printf '\033[90m%*s\033[0m' "$empty" '' | tr ' ' '░'
  printf '] \033[1;97m%3d%%\033[0m  \033[1;35m%s\033[0m' "$percent" "$spinner"
  sleep "$(awk -v d="$duration" -v s="$steps" 'BEGIN { printf "%.4f", d/s }')"
done

printf '\n\n\033[1;32m  ✔ READY — Launching installer now...\033[0m\n\n'
restore_cursor
bash "$TMP"
