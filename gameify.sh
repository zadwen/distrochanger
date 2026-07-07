#!/usr/bin/env bash
# gameify.sh — analyze your Linux system and turn it into a gaming-ready desktop
# Supports Debian/Ubuntu, Fedora/Nobara, Arch/Manjaro, openSUSE.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
GAMEIFY_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")"

print_help() {
  cat <<EOF
gameify $GAMEIFY_VERSION — turn any Linux distro into a gaming rig

Usage: ./gameify.sh [options]

Options:
  --dry-run     Print every command that would run (install, sysctl, file
                write, download) instead of running it. Combine with a
                normal run to audit exactly what gameify would touch.
  --tiers       Just open the Standard/Advanced/Experimental tier picker
                and exit, without running the rest of the setup flow.
  --game-mode on|off|toggle|status
                Instantly flip the global Game Mode switch (CPU governor,
                RAM cache, file-descriptor limits, compositor pause) and
                exit immediately — no report, no menus. This is the fast
                path for "I'm about to play" / "I'm done gaming".
  --version     Print the version and exit.
  --help, -h    Print this help and exit.

With no options, runs the full interactive setup: system report, tier
picker, driver/kernel/gaming-stack/apps/tweaks menus, auto-heal scan, and
a final summary of what changed.

See also: ./update.sh --install-cron / --remove-cron for weekly maintenance.
EOF
}

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --version) echo "gameify $GAMEIFY_VERSION"; exit 0 ;;
    --help|-h) print_help; exit 0 ;;
  esac
done
export DRY_RUN

source "$SCRIPT_DIR/detect.sh"
source "$SCRIPT_DIR/pkgmanager.sh"
source "$SCRIPT_DIR/drivers.sh"
source "$SCRIPT_DIR/kernel.sh"
source "$SCRIPT_DIR/gaming-stack.sh"
source "$SCRIPT_DIR/tweaks.sh"
source "$SCRIPT_DIR/apps.sh"
source "$SCRIPT_DIR/heal.sh"
source "$SCRIPT_DIR/gamemode-toggle.sh"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run this as a normal user, not root/sudo directly."
  echo "It calls sudo itself only for the specific commands that need it."
  exit 1
fi

for arg in "$@"; do
  if [[ "$arg" == "--tiers" ]]; then
    choose_tiers
    exit 0
  fi
done

# Fast path: --game-mode on|off|toggle|status flips the global switch and
# exits immediately, deliberately skipping the report/menus/tier picker —
# this is meant to be a one-second "I'm about to play" / "I'm done" action,
# not a trip through the full setup flow.
GAME_MODE_ACTION=""
prev_arg=""
for arg in "$@"; do
  if [[ "$prev_arg" == "--game-mode" ]]; then
    GAME_MODE_ACTION="$arg"
  fi
  prev_arg="$arg"
done
if [[ -n "$GAME_MODE_ACTION" ]]; then
  case "$GAME_MODE_ACTION" in
    on) gamemode_on ;;
    off) gamemode_off ;;
    toggle) gamemode_toggle ;;
    status) echo "Game Mode is currently: $(gamemode_status)" ;;
    *) echo "Usage: --game-mode on|off|toggle|status"; exit 1 ;;
  esac
  exit 0
fi

echo "=================================================="
echo " Gameify $GAMEIFY_VERSION — turn any Linux distro into a gaming rig"
echo "=================================================="
if [[ "$DRY_RUN" == true ]]; then
  echo " DRY-RUN MODE — nothing will actually be installed or changed."
fi
echo ""

print_system_report

PKG_FAMILY="$(detect_distro_family)"
export PKG_FAMILY
GPU_VENDORS="$(detect_gpu_vendors)"

if [[ "$PKG_FAMILY" == "unknown" ]]; then
  echo ""
  if [[ "$(ask_yn "Your distro family wasn't recognized. Continue anyway?" N)" != y ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""
if [[ "$(ask_yn "Proceed with setup?" Y)" != y ]]; then
  echo "Aborted."
  exit 0
fi

choose_tiers

echo ""
echo "==> Updating system packages..."
pkg_update
pkg_upgrade

drivers_menu "$GPU_VENDORS"
kernel_menu
gaming_stack_menu
apps_menu
system_tweaks_menu
auto_heal_menu
game_mode_menu

echo ""
echo "=================================================="
echo " Summary — what actually changed"
echo "=================================================="
if [[ "$DRY_RUN" == true ]]; then
  echo " DRY-RUN MODE — nothing above was actually changed. Re-run without"
  echo " --dry-run to apply it for real."
fi
echo " Tiers active: Standard (always), Advanced=$ENABLE_ADVANCED, Experimental=$ENABLE_EXPERIMENTAL"
echo ""
if [[ "${#CHANGELOG[@]}" -eq 0 ]]; then
  echo " Nothing needed changing — your system was already set up."
else
  for entry in "${CHANGELOG[@]}"; do
    echo " - $entry"
  done
fi
echo "=================================================="

echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo "Dry-run complete — nothing was installed, changed, or rebooted."
  exit 0
fi
echo "A reboot is recommended, especially after installing/updating a GPU driver"
echo "or performance kernel."
if [[ "$(ask_yn "Reboot now?" N)" == y ]]; then
  sudo reboot
fi
