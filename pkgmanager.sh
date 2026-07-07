#!/usr/bin/env bash
# pkgmanager.sh — thin abstraction so the rest of the code doesn't care
# whether it's running on apt, dnf, pacman, or zypper.
set -euo pipefail

# PKG_FAMILY must be set (debian|fedora|arch|opensuse|unknown) before use.

# ---------- Dry-run support ----------
#
# DRY_RUN=true makes every mutating operation print what it *would* do
# instead of doing it, so a stranger cloning this repo can see exactly what
# a full run touches before trusting it with sudo. Set via `--dry-run` on
# gameify.sh/update.sh; every module checks it at the point where it would
# otherwise change something (package install, file write, sysctl, cron).
DRY_RUN="${DRY_RUN:-false}"

dry_run_note() {
  echo "  [DRY-RUN] would: $*"
}

# run_priv "description" -- actual command args...
# For mutating commands that aren't a plain package install (usermod,
# sysctl, crontab, mkdir+file writes, curl|extract). Anything before the
# literal "--" is just a human-readable description for the dry-run line;
# everything after is executed for real otherwise.
run_priv() {
  local desc="$1"; shift
  if [[ "${1:-}" == "--" ]]; then shift; fi
  if [[ "$DRY_RUN" == true ]]; then
    dry_run_note "$desc"
    return 0
  fi
  "$@"
}

# ---------- Changelog ----------
#
# Every module appends to this so gameify.sh can print a "here's what
# actually happened" summary at the end. Safe across sourced files since
# bash arrays are shared in the same shell process.
#
# NOTE: must be initialized as CHANGELOG=() rather than `declare -a
# CHANGELOG` with no assignment — some bash versions treat a declared-but-
# never-assigned array as "unbound" under `set -u` the first time
# something references ${#CHANGELOG[@]}, even though it's a perfectly
# valid empty array. Explicit assignment avoids that gotcha entirely.
CHANGELOG=()

log_change() {
  local msg="$1"
  if [[ "$DRY_RUN" == true ]]; then
    msg="[DRY-RUN] $msg"
  fi
  CHANGELOG+=("$msg")
  echo "$msg"
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
  if ! is_interactive; then
    echo "  (non-interactive — using saved/default tiers: Advanced=$ENABLE_ADVANCED, Experimental=$ENABLE_EXPERIMENTAL)"
    echo "  Run './gameify.sh --tiers' interactively to change this."
    return 0
  fi
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
  local a e
  a="$(ask_yn "Enable Advanced tier?" Y)"
  [[ "$a" == y ]] && ENABLE_ADVANCED=true || ENABLE_ADVANCED=false

  e="$(ask_yn "Enable Experimental tier?" N)"
  [[ "$e" == y ]] && ENABLE_EXPERIMENTAL=true || ENABLE_EXPERIMENTAL=false

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

# ---------- Interactive-prompt safety ----------
#
# Every yes/no prompt in the project goes through ask_yn instead of a raw
# `read -r -p`, so that running under cron, CI, or any piped/non-tty
# context automatically falls back to a stated default instead of hanging
# or (worse) spinning forever on a `select` menu fed garbage by a pipe.

is_interactive() {
  [[ -t 0 ]]
}

# prompt_skip_countdown "message" seconds key
# Shows a countdown and returns 0 (skip) if `key` is pressed before time
# runs out, 1 (proceed) otherwise — no Enter key needed. Used to bail out
# of a scan/loop that's about to take a while, without forcing a yes/no
# prompt for something that defaults to "just proceed" anyway. Piped/
# non-interactive contexts can't read a keypress at all, so they skip the
# wait and proceed immediately rather than blocking forever on `read`.
prompt_skip_countdown() {
  local prompt="$1" seconds="${2:-5}" key="${3:-s}" i ans
  if ! is_interactive; then
    return 1
  fi
  for ((i=seconds; i>0; i--)); do
    printf '\r  %s (press "%s" to skip — %ds) ' "$prompt" "$key" "$i"
    if read -r -s -n 1 -t 1 ans 2>/dev/null; then
      if [[ "${ans,,}" == "$key" ]]; then
        printf '\n  Skipped.\n'
        return 0
      fi
    fi
  done
  printf '\n'
  return 1
}

# ask_yn "Prompt text" Y|N -> prints "y" or "n" (also honors DRY_RUN=false;
# this only affects prompting, not whether the resulting action runs for
# real — pair with `tier_enabled`/`$DRY_RUN` checks as usual).
ask_yn() {
  local prompt="$1" default="${2:-Y}" ans
  local hint="[y/N]"
  [[ "$default" =~ ^[Yy]$ ]] && hint="[Y/n]"
  if ! is_interactive; then
    echo "  $prompt $hint (non-interactive — using default: $default)" >&2
    ans="$default"
  else
    read -r -p "$prompt $hint " ans
    ans="${ans:-$default}"
  fi
  if [[ "$ans" =~ ^[Yy]$ ]]; then echo y; else echo n; fi
}

pkg_update() {
  if [[ "$DRY_RUN" == true ]]; then
    dry_run_note "refresh package metadata ($PKG_FAMILY)"
    return 0
  fi
  case "$PKG_FAMILY" in
    debian) sudo apt update ;;
    fedora) sudo dnf -y makecache ;;
    arch) sudo pacman -Sy ;;
    opensuse) sudo zypper refresh ;;
    *) echo "  (skip: unsupported package manager)" ;;
  esac
}

pkg_upgrade() {
  if [[ "$DRY_RUN" == true ]]; then
    dry_run_note "upgrade all system packages ($PKG_FAMILY)"
    return 0
  fi
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
  if [[ "$DRY_RUN" == true ]]; then
    dry_run_note "install package(s) via $PKG_FAMILY: $*"
    return 0
  fi
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
    if [[ "$DRY_RUN" == true ]]; then
      dry_run_note "add the Flathub remote"
      return 0
    fi
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
  if [[ "$DRY_RUN" == true ]]; then
    dry_run_note "flatpak install flathub $1"
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
  if [[ "$DRY_RUN" == true ]]; then
    dry_run_note "refresh Flatpak GL/Vulkan runtime extensions for $vendor"
    return 0
  fi
  echo "  Refreshing Flatpak runtime GL/Vulkan extensions for $vendor..."
  flatpak update -y >/dev/null 2>&1 || true
}
