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
source "$SCRIPT_DIR/heal.sh"

PKG_FAMILY="$(detect_distro_family)"
export PKG_FAMILY
load_tier_config

# --install-cron: adds a weekly (Sunday 04:00) crontab entry that runs this
# script non-interactively, then exits. Doesn't touch anything else.
if [[ "${1:-}" == "--install-cron" ]]; then
  CRON_MARKER="# gameify weekly update"
  CRON_LINE="0 4 * * 0 $SCRIPT_DIR/update.sh >> \"$HOME/.local/share/gameify/cron.log\" 2>&1 $CRON_MARKER"
  mkdir -p "$HOME/.local/share/gameify"
  existing="$(crontab -l 2>/dev/null || true)"
  if echo "$existing" | grep -qF "$CRON_MARKER"; then
    echo "A gameify cron job is already installed:"
    echo "$existing" | grep -F "$CRON_MARKER"
    exit 0
  fi
  { echo "$existing"; echo "$CRON_LINE"; } | grep -v '^$' | crontab -
  echo "Installed weekly cron job (Sundays at 04:00):"
  echo "  $CRON_LINE"
  echo "Output will be appended to ~/.local/share/gameify/cron.log"
  echo ""
  echo "Note: cron jobs run non-interactively and can't use sudo without a"
  echo "password prompt, so the scheduled run only does the password-free parts"
  echo "(Flatpak updates, GE-Proton refresh, log-based auto-heal). Run"
  echo "'./update.sh' by hand periodically for the full system/driver upgrade,"
  echo "or see README.md for a systemd --user timer alternative that can."
  exit 0
fi

if [[ "${1:-}" == "--remove-cron" ]]; then
  CRON_MARKER="# gameify weekly update"
  crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" | crontab - || true
  echo "Removed gameify's cron job (if it was present)."
  exit 0
fi

INTERACTIVE=false
if [[ -t 0 ]]; then
  INTERACTIVE=true
fi

{
  echo ""
  echo "=================================================="
  echo " gameify update — $(date '+%Y-%m-%d %H:%M:%S')"
  echo " Tiers: Standard (always), Advanced=$ENABLE_ADVANCED, Experimental=$ENABLE_EXPERIMENTAL"
  echo "=================================================="

  echo "==> Updating Flatpak apps..."
  if command -v flatpak >/dev/null 2>&1; then
    flatpak update -y && log_change "Updated all Flatpak apps" || \
      echo "  Flatpak update failed or needs an interactive polkit prompt — skipped."
  else
    echo "  Flatpak not installed, skipping."
  fi

  if tier_enabled advanced; then
    echo "==> [Advanced] Refreshing GE-Proton..."
    install_or_update_proton_ge || echo "  GE-Proton refresh failed — will retry next run."
  else
    echo "==> Advanced tier disabled — skipping GE-Proton refresh."
    echo "    Run 'gameify.sh --tiers' to enable it."
  fi

  echo "==> Running auto-heal log scan..."
  if [[ "$INTERACTIVE" == true ]]; then
    run_auto_heal || echo "  Auto-heal scan hit an error — see above."
  else
    # Non-interactive: scan and auto-fix, but skip anything that would
    # otherwise prompt (e.g. clearing shader cache), logging it instead.
    run_auto_heal </dev/null || echo "  Auto-heal scan hit an error — see above."
  fi

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
