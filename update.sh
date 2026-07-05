#!/usr/bin/env bash
# update.sh — weekly maintenance: refresh Flatpaks, GE-Proton, and (when run
# interactively) system packages/drivers. Meant to be run either by hand or
# via cron/systemd timer.
#
# IMPORTANT — read this before wiring up cron:
# Package manager upgrades and driver installs need sudo. A plain cron job
# has no terminal to type a password into, so this script auto-detects
# whether it's running interactively (a real terminal) or not (cron/systemd).
#   - Interactive run:  does everything, including sudo-requiring steps.
#   - Non-interactive:  only does the parts that don't need a password
#                        (Flatpak updates, GE-Proton refresh) and logs a
#                        reminder for anything it skipped.
#
# If you want the sudo-requiring parts to run unattended too, you have two
# options (see README.md for details):
#   1. A systemd --user timer, which runs inside your logged-in session and
#      can use polkit for authentication — the more "correct" option.
#   2. A narrowly-scoped NOPASSWD sudoers rule for just the package-manager
#      commands this script runs (never NOPASSWD ALL). This trades some
#      security for convenience — make that choice deliberately.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
LOG_DIR="$HOME/.local/share/gameify"
LOG_FILE="$LOG_DIR/update.log"
mkdir -p "$LOG_DIR"

source "$SCRIPT_DIR/detect.sh"
source "$SCRIPT_DIR/pkgmanager.sh"
source "$SCRIPT_DIR/drivers.sh"
source "$SCRIPT_DIR/gaming-stack.sh"
source "$SCRIPT_DIR/tweaks.sh"

PKG_FAMILY="$(detect_distro_family)"
export PKG_FAMILY

INTERACTIVE=false
if [[ -t 0 ]]; then
  INTERACTIVE=true
fi

{
  echo ""
  echo "=================================================="
  echo " gameify update — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "=================================================="

  echo "==> Updating Flatpak apps..."
  if command -v flatpak >/dev/null 2>&1; then
    flatpak update -y && log_change "Updated all Flatpak apps" || \
      echo "  Flatpak update failed or needs an interactive polkit prompt — skipped."
  else
    echo "  Flatpak not installed, skipping."
  fi

  echo "==> Refreshing GE-Proton..."
  install_or_update_proton_ge || echo "  GE-Proton refresh failed — will retry next run."

  if [[ "$INTERACTIVE" == true ]]; then
    echo "==> Interactive session detected — updating system packages and drivers..."
    pkg_update
    pkg_upgrade
    GPU_VENDORS="$(detect_gpu_vendors)"
    for v in $GPU_VENDORS; do
      case "$v" in
        nvidia) install_nvidia || true ;;
        amd) install_amd || true ;;
        intel) install_intel || true ;;
      esac
    done
  else
    echo "==> Running non-interactively (cron/systemd) — skipping sudo-requiring steps:"
    echo "    system package upgrade, driver refresh."
    echo "    Run './update.sh' by hand periodically, or see README.md for how to"
    echo "    enable this safely under cron/systemd."
  fi

  echo ""
  echo "=================================================="
  echo " Update summary"
  echo "=================================================="
  if [[ "${#CHANGELOG[@]}" -eq 0 ]]; then
    echo " Everything was already up to date — no changes made."
  else
    for entry in "${CHANGELOG[@]}"; do
      echo " - $entry"
    done
  fi
  echo "=================================================="
} 2>&1 | tee -a "$LOG_FILE"
