#!/usr/bin/env bash
# tweaks.sh — optional gaming-related tweaks + auto-fixes for common bugs.
# Every function here checks state first so it's safe to re-run repeatedly.
set -euo pipefail

tweak_vm_max_map_count() {
  local conf="/etc/sysctl.d/80-gamecompat.conf"
  local target=2147483642
  local current
  current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if [[ -f "$conf" ]] && [[ "$current" -ge "$target" ]]; then
    echo "  vm.max_map_count already raised ($current), skipping."
    return 0
  fi
  echo "==> Raising vm.max_map_count (needed by some Proton/Steam titles, e.g. certain UE4/5 games)..."
  echo "vm.max_map_count=$target" | sudo tee "$conf" >/dev/null
  sudo sysctl --system >/dev/null
  log_change "Raised vm.max_map_count to $target"
}

tweak_gamemode_group() {
  if ! getent group gamemode >/dev/null 2>&1; then
    echo "  'gamemode' group doesn't exist yet — install GameMode first (gaming stack step)."
    return 0
  fi
  if id -nG "$USER" 2>/dev/null | grep -qw gamemode; then
    echo "  $USER already in the gamemode group, skipping."
    return 0
  fi
  echo "==> Adding your user to the 'gamemode' group so GameMode can adjust performance..."
  sudo usermod -aG gamemode "$USER" || true
  log_change "Added $USER to the gamemode group (log out/in to apply)"
}

# Checks for a working Vulkan ICD/loader and installs whatever's missing.
fix_missing_vulkan() {
  echo "==> Checking Vulkan support..."
  if ! command -v vulkaninfo >/dev/null 2>&1; then
    echo "  vulkaninfo not found — installing Vulkan tools..."
    case "$PKG_FAMILY" in
      debian) pkg_install vulkan-tools mesa-vulkan-drivers ;;
      fedora) pkg_install vulkan-tools mesa-vulkan-drivers ;;
      arch) pkg_install vulkan-tools ;;
      opensuse) pkg_install vulkan-tools Mesa-vulkan-device-select ;;
      *) echo "  (skip: unsupported distro family)"; return 1 ;;
    esac
    log_change "Installed missing Vulkan tools/loader"
  fi

  if command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary >/dev/null 2>&1; then
      echo "  Vulkan is working — at least one ICD was found."
    else
      echo "  vulkaninfo ran but found no usable ICD — this usually means the GPU driver"
      echo "  itself (not just Vulkan tools) is missing. Run the driver step first."
    fi
  fi
}

# Scans common Wine/Proton prefix locations and offers to repair any that
# look broken (missing drive_c or system.reg — a classic sign of an
# interrupted install or a crashed first run).
_find_wine_prefixes() {
  local -a found=()
  [[ -d "$HOME/.wine" ]] && found+=("$HOME/.wine")
  if [[ -d "$HOME/.steam/steam/steamapps/compatdata" ]]; then
    while IFS= read -r -d '' d; do
      found+=("$d/pfx")
    done < <(find "$HOME/.steam/steam/steamapps/compatdata" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi
  if [[ -d "$HOME/.local/share/lutris/runners/wine" ]]; then
    : # Lutris prefixes are user-defined paths; nothing standard to scan here.
  fi
  printf '%s\n' "${found[@]}"
}

_wine_prefix_is_broken() {
  local prefix="$1"
  [[ -d "$prefix" ]] || return 1
  [[ -f "$prefix/system.reg" ]] || return 0
  [[ -d "$prefix/drive_c" ]] || return 0
  return 1
}

fix_broken_wine_prefixes() {
  echo "==> Scanning known Wine/Proton prefix locations for corruption..."
  local prefixes broken_any=false
  prefixes="$(_find_wine_prefixes)"
  if [[ -z "$prefixes" ]]; then
    echo "  No Wine/Proton prefixes found to check."
    return 0
  fi
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if _wine_prefix_is_broken "$p"; then
      broken_any=true
      echo "  Broken prefix found: $p"
      local fix_it="n"
      if [[ -t 0 ]]; then
        read -r -p "  Attempt repair with 'wineboot -u'? [y/N] " fix_it || fix_it="n"
      else
        echo "  (non-interactive run — skipping repair prompt; re-run by hand to fix)"
      fi
      if [[ "$fix_it" =~ ^[Yy]$ ]]; then
        WINEPREFIX="$p" wineboot -u 2>/dev/null && \
          log_change "Repaired Wine prefix: $p" || \
          echo "  Repair attempt failed — this prefix may need to be deleted and recreated."
      fi
    fi
  done <<< "$prefixes"
  [[ "$broken_any" == false ]] && echo "  No broken prefixes found."
}

system_tweaks_menu() {
  echo ""
  read -r -p "[Standard] Apply system tweaks + auto-fixes (Vulkan check, vm.max_map_count, gamemode group, Wine prefix scan)? [Y/n] " answer
  answer=${answer:-Y}
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Skipping system tweaks."
    return
  fi
  fix_missing_vulkan || true
  tweak_vm_max_map_count || true
  tweak_gamemode_group || true
  fix_broken_wine_prefixes || true
  echo "==> Tweaks applied."
}
