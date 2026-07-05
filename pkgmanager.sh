#!/usr/bin/env bash
# pkgmanager.sh — thin abstraction so the rest of the code doesn't care
# whether it's running on apt, dnf, pacman, or zypper.
set -euo pipefail

# PKG_FAMILY must be set (debian|fedora|arch|opensuse|unknown) before use.

# Global changelog — every module appends to this so gameify.sh can print
# a "here's what actually happened" summary at the end. Safe across sourced
# files since bash arrays are shared in the same shell process.
declare -a CHANGELOG 2>/dev/null || true

log_change() {
  CHANGELOG+=("$1")
  echo "$1"
}

# ---------- Tiers: Standard / Advanced / Experimental ----------
#
# Every install/tweak in this project falls into one of three risk tiers,
# same idea as the "safe tweaks vs advanced vs experimental" split popular
# Windows tweak-utilities use:
#
#   Standard     — safe, reversible, low-risk. Native drivers, Steam/Wine/
#                  GameMode/Lutris/MangoHud, Vulkan/vm.max_map_count/gamemode
#                  fixes, Wine-prefix repair, Discord/OBS/Spotify. Runs by
#                  default with no extra prompt.
#   Advanced     — optional performance/convenience features that are still
#                  well-tested but touch more of the system: PRIME/Optimus
#                  auto-config, GE-Proton auto-update, Gamescope, vkBasalt,
#                  per-game Proton override, cron automation.
#   Experimental — cutting-edge or higher-risk: performance kernels
#                  (XanMod/Liquorix/zen), Battle.net/EA App via Lutris
#                  (unofficial Wine-based install path). Off unless you
#                  explicitly opt in, and always reversible (old kernel
#                  stays in the bootloader menu, Lutris installs are just
#                  removable prefixes).
#
# ENABLE_ADVANCED / ENABLE_EXPERIMENTAL are plain "true"/"false" strings so
# they survive being sourced across files and saved to the config file.

GAMEIFY_CONFIG_DIR="$HOME/.config/gameify"
GAMEIFY_TIER_CONFIG="$GAMEIFY_CONFIG_DIR/tiers.conf"

ENABLE_ADVANCED="${ENABLE_ADVANCED:-false}"
ENABLE_EXPERIMENTAL="${ENABLE_EXPERIMENTAL:-false}"

load_tier_config() {
  if [[ -f "$GAMEIFY_TIER_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$GAMEIFY_TIER_CONFIG"
  fi
}

save_tier_config() {
  mkdir -p "$GAMEIFY_CONFIG_DIR"
  cat > "$GAMEIFY_TIER_CONFIG" <<EOF
# Written by gameify — which optional tiers to run without asking again.
ENABLE_ADVANCED=$ENABLE_ADVANCED
ENABLE_EXPERIMENTAL=$ENABLE_EXPERIMENTAL
EOF
}

# Interactive tier picker — call once near the start of an interactive run.
choose_tiers() {
  load_tier_config
  echo ""
  echo "=================================================="
  echo " Choose which tiers to enable"
  echo "=================================================="
  echo "  Standard     — always on: safe, reversible fixes and installs."
  echo "  Advanced     — optional performance/convenience features"
  echo "                 (PRIME/Optimus auto-config, GE-Proton auto-update,"
  echo "                 Gamescope, vkBasalt, per-game Proton override, cron)."
  echo "  Experimental — cutting-edge / higher-risk (performance kernels,"
  echo "                 Battle.net/EA App via Lutris). Reversible, but"
  echo "                 further from your distro's tested defaults."
  echo ""
  read -r -p "Enable Advanced tier? [Y/n] " a
  a=${a:-Y}
  [[ "$a" =~ ^[Yy]$ ]] && ENABLE_ADVANCED=true || ENABLE_ADVANCED=false

  read -r -p "Enable Experimental tier? [y/N] " e
  e=${e:-N}
  [[ "$e" =~ ^[Yy]$ ]] && ENABLE_EXPERIMENTAL=true || ENABLE_EXPERIMENTAL=false

  save_tier_config
  echo ""
  echo "Saved to $GAMEIFY_TIER_CONFIG — re-run 'gameify.sh --tiers' any time"
  echo "to change this without going through the whole setup flow again."
}

# tier_enabled standard|advanced|experimental -> 0 if that tier should run
tier_enabled() {
  case "$1" in
    standard) return 0 ;;
    advanced) [[ "$ENABLE_ADVANCED" == true ]] ;;
    experimental) [[ "$ENABLE_EXPERIMENTAL" == true ]] ;;
    *) return 1 ;;
  esac
}

pkg_update() {
  case "$PKG_FAMILY" in
    debian) sudo apt update ;;
    fedora) sudo dnf -y makecache ;;
    arch) sudo pacman -Sy ;;
    opensuse) sudo zypper refresh ;;
    *) echo "  (skip: unsupported package manager)" ;;
  esac
}

pkg_upgrade() {
  case "$PKG_FAMILY" in
    debian) sudo apt upgrade -y ;;
    fedora) sudo dnf -y upgrade ;;
    arch) sudo pacman -Syu --noconfirm ;;
    opensuse) sudo zypper update -y ;;
    *) echo "  (skip: unsupported package manager)" ;;
  esac
}

# pkg_install pkg1 pkg2 ...
pkg_install() {
  if [[ $# -eq 0 ]]; then return 0; fi
  case "$PKG_FAMILY" in
    debian) sudo apt install -y "$@" ;;
    fedora) sudo dnf install -y "$@" ;;
    arch) sudo pacman -S --needed --noconfirm "$@" ;;
    opensuse) sudo zypper install -y "$@" ;;
    *) echo "  (skip: don't know how to install '$*' on this distro)"; return 1 ;;
  esac
}

# pkg_installed pkgname -> returns 0 if installed
pkg_installed() {
  case "$PKG_FAMILY" in
    debian) dpkg -s "$1" >/dev/null 2>&1 ;;
    fedora) rpm -q "$1" >/dev/null 2>&1 ;;
    arch) pacman -Qi "$1" >/dev/null 2>&1 ;;
    opensuse) rpm -q "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# pkg_install_or_flatpak <native-pkg-name> <flatpak-app-or-extension-id> [label]
# Tries the native package first; on failure, falls back to Flatpak.
# This is the "smart fallback" used across drivers/gaming-stack when a
# distro's repos don't have something (or the version is too old).
pkg_install_or_flatpak() {
  local native="$1" flatpak_id="$2" label="${3:-$1}"
  if pkg_installed "$native" 2>/dev/null; then
    echo "  $label already installed natively, skipping."
    return 0
  fi
  if pkg_install "$native" 2>/dev/null; then
    log_change "Installed $label (native package: $native)"
    return 0
  fi
  echo "  Native package '$native' unavailable or failed — falling back to Flatpak..."
  ensure_flatpak
  if flatpak_install "$flatpak_id"; then
    log_change "Installed $label (Flatpak fallback: $flatpak_id)"
    return 0
  fi
  echo "  Could not install $label via native package or Flatpak."
  return 1
}

ensure_flatpak() {
  if ! command -v flatpak >/dev/null 2>&1; then
    echo "  Installing flatpak..."
    pkg_install flatpak
    log_change "Installed flatpak"
  fi
  if ! flatpak remote-list 2>/dev/null | grep -q flathub; then
    echo "  Adding Flathub remote..."
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  fi
}

flatpak_install() {
  # flatpak_install <app-id>
  if flatpak list --app 2>/dev/null | grep -q "$1"; then
    echo "  $1 already installed via Flatpak, skipping."
    return 0
  fi
  flatpak install -y flathub "$1"
}

# Nudge Flatpak to refresh runtime GL/Vulkan extensions matching the
# detected GPU vendor, so Flatpak games/tools get real hardware
# acceleration instead of silently falling back to software rendering.
ensure_flatpak_gpu_runtime() {
  local vendor="$1"
  ensure_flatpak
  echo "  Refreshing Flatpak runtime GL/Vulkan extensions for $vendor..."
  flatpak update -y >/dev/null 2>&1 || true
}
