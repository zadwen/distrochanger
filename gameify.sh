#!/usr/bin/env bash
# gameify.sh — analyze your Linux system and turn it into a gaming-ready desktop
# Supports Debian/Ubuntu, Fedora/Nobara, Arch/Manjaro, openSUSE.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

source "$SCRIPT_DIR/detect.sh"
source "$SCRIPT_DIR/pkgmanager.sh"
source "$SCRIPT_DIR/drivers.sh"
source "$SCRIPT_DIR/gaming-stack.sh"
source "$SCRIPT_DIR/tweaks.sh"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run this as a normal user, not root/sudo directly."
  echo "It calls sudo itself only for the specific commands that need it."
  exit 1
fi

echo "=================================================="
echo " Gameify — turn any Linux distro into a gaming rig"
echo "=================================================="
echo ""

print_system_report

PKG_FAMILY="$(detect_distro_family)"
export PKG_FAMILY
GPU_VENDORS="$(detect_gpu_vendors)"

if [[ "$PKG_FAMILY" == "unknown" ]]; then
  echo ""
  read -r -p "Your distro family wasn't recognized. Continue anyway? [y/N] " force_go
  if [[ ! "$force_go" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""
read -r -p "Proceed with setup? [Y/n] " go
go=${go:-Y}
if [[ ! "$go" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "==> Updating system packages..."
pkg_update
pkg_upgrade

drivers_menu "$GPU_VENDORS"

gaming_stack_menu
system_tweaks_menu

echo ""
echo "=================================================="
echo " All done!"
echo "=================================================="
echo "A reboot is recommended, especially after installing/updating a GPU driver."
read -r -p "Reboot now? [y/N] " reboot_now
if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
  sudo reboot
fi
