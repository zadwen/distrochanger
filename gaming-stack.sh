#!/usr/bin/env bash
# gaming-stack.sh — core gaming apps, adapted per distro family, plus
# Proton-GE (with real auto-update via GitHub releases), Gamescope, vkBasalt.
set -euo pipefail

enable_32bit() {
  echo "==> Enabling 32-bit library support (needed for many older/Proton games)..."
  case "$PKG_FAMILY" in
    debian)
      sudo dpkg --add-architecture i386
      pkg_update
      ;;
    arch)
      if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
        echo "  Enabling [multilib] repo in /etc/pacman.conf..."
        sudo sed -i "/^#\[multilib\]/,/^#Include/ s/^#//" /etc/pacman.conf
        pkg_update
      else
        echo "  [multilib] already enabled."
      fi
      ;;
    fedora|opensuse)
      echo "  Nothing to do — Mesa on this distro already ships 32-bit compat as needed."
      ;;
    *) echo "  (skip: unsupported distro family)" ;;
  esac
}

install_steam() {
  echo "==> Installing Steam..."
  if command -v steam >/dev/null 2>&1; then
    echo "  Steam already installed, skipping."
    return 0
  fi
  case "$PKG_FAMILY" in
    debian) pkg_install steam-installer || pkg_install steam ;;
    fedora)
      if ! dnf repolist 2>/dev/null | grep -qi rpmfusion-nonfree; then
        echo "  Steam on Fedora needs RPM Fusion nonfree — installing that first..."
        local fedver; fedver="$(rpm -E %fedora)"
        pkg_install "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm"
      fi
      pkg_install steam
      ;;
    arch) pkg_install steam ;;
    opensuse)
      echo "  Steam on openSUSE needs the Packman repo. Falling back to Flatpak instead"
      echo "  to keep this simple and reliable:"
      ensure_flatpak
      flatpak_install com.valvesoftware.Steam
      ;;
    *) ensure_flatpak; flatpak_install com.valvesoftware.Steam ;;
  esac
  log_change "Installed Steam"
}

install_wine() {
  echo "==> Installing Wine..."
  if pkg_installed wine 2>/dev/null || command -v wine >/dev/null 2>&1; then
    echo "  Wine already installed, skipping."
    return 0
  fi
  pkg_install wine winetricks && log_change "Installed Wine + Winetricks"
}

install_gamemode() {
  echo "==> Installing GameMode (performance daemon)..."
  if pkg_installed gamemode 2>/dev/null; then
    echo "  GameMode already installed, skipping."
    return 0
  fi
  pkg_install gamemode && log_change "Installed GameMode" || echo "  GameMode package not found for this distro — skipping."
}

install_lutris() {
  echo "==> Installing Lutris (via Flatpak — consistent across every distro)..."
  ensure_flatpak
  flatpak_install net.lutris.Lutris && log_change "Installed Lutris (Flatpak)"
}

install_mangohud() {
  echo "==> Installing MangoHud (FPS/performance overlay)..."
  pkg_install_or_flatpak mangohud org.freedesktop.Platform.VulkanLayer.MangoHud "MangoHud"
}

install_protonup() {
  echo "==> Installing ProtonUp-Qt (GUI manager for custom Proton-GE / Wine-GE builds)..."
  ensure_flatpak
  flatpak_install net.davidotek.pupgui2 && log_change "Installed ProtonUp-Qt (Flatpak)"
}

install_heroic() {
  echo "==> Installing Heroic Games Launcher (Epic/GOG/Amazon on Linux)..."
  ensure_flatpak
  flatpak_install com.heroicgameslauncher.hgl && log_change "Installed Heroic Games Launcher (Flatpak)"
}

install_gamescope() {
  echo "==> Installing Gamescope (SteamOS-style micro-compositor, useful for handhelds/couch setups)..."
  if pkg_installed gamescope 2>/dev/null || command -v gamescope >/dev/null 2>&1; then
    echo "  Gamescope already installed, skipping."
    return 0
  fi
  case "$PKG_FAMILY" in
    debian) pkg_install gamescope && log_change "Installed Gamescope" ;;
    fedora) pkg_install gamescope && log_change "Installed Gamescope" ;;
    arch) pkg_install gamescope && log_change "Installed Gamescope" ;;
    opensuse) pkg_install gamescope && log_change "Installed Gamescope" ;;
    *) : ;;
  esac || echo "  Gamescope isn't in your distro's default repos yet — skipping. Check your distro's wiki/COPR/AUR."
}

install_vkbasalt() {
  echo "==> Installing vkBasalt (Vulkan post-processing: sharpening, color, etc.)..."
  ensure_flatpak
  flatpak_install org.freedesktop.Platform.VulkanLayer.vkBasalt && log_change "Installed vkBasalt (Flatpak layer)"
}

# ---------- Proton-GE: real install + auto-update via GitHub releases ----------

_steam_compat_dir() {
  # Prefer a native Steam install location; fall back to Flatpak's location.
  local native="$HOME/.steam/root/compatibilitytools.d"
  local native_alt="$HOME/.local/share/Steam/compatibilitytools.d"
  local flat="$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/compatibilitytools.d"
  if [[ -d "$HOME/.steam/root" ]] || [[ -d "$HOME/.local/share/Steam" ]]; then
    mkdir -p "$native_alt"
    echo "$native_alt"
  else
    mkdir -p "$flat"
    echo "$flat"
  fi
}

# Fetches latest GE-Proton release tag + download URL from the GitHub API.
_latest_proton_ge_url() {
  curl -fsSL "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest" \
    | grep -m1 '"browser_download_url".*\.tar\.gz"' \
    | sed -E 's/.*"([^"]+)".*/\1/'
}

_latest_proton_ge_tag() {
  curl -fsSL "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest" \
    | grep -m1 '"tag_name"' \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

install_or_update_proton_ge() {
  echo "==> Checking Proton-GE (GE-Proton) version..."
  local compat_dir tag url tmpfile
  compat_dir="$(_steam_compat_dir)"
  tag="$(_latest_proton_ge_tag)" || { echo "  Couldn't reach GitHub to check the latest release — skipping."; return 1; }

  if [[ -d "$compat_dir/$tag" ]]; then
    echo "  Already on the latest GE-Proton ($tag), skipping."
    return 0
  fi

  url="$(_latest_proton_ge_url)"
  if [[ -z "$url" ]]; then
    echo "  Couldn't resolve a download URL for the latest release — skipping."
    return 1
  fi

  echo "  Installing GE-Proton $tag into $compat_dir ..."
  tmpfile="$(mktemp --suffix=.tar.gz)"
  curl -fsSL "$url" -o "$tmpfile"
  tar -xzf "$tmpfile" -C "$compat_dir"
  rm -f "$tmpfile"
  log_change "Installed/updated GE-Proton to $tag"
  echo "  Restart Steam, then enable it per-game under Properties > Compatibility."
}

gaming_stack_menu() {
  echo ""
  echo "Core gaming stack: Steam, Wine, GameMode, Lutris, MangoHud, ProtonUp-Qt,"
  echo "Proton-GE (auto-installed direct from GitHub), Gamescope, vkBasalt"
  read -r -p "Also install Heroic Games Launcher (Epic/GOG/Amazon)? [y/N] " want_heroic
  read -r -p "Proceed with install? [Y/n] " answer
  answer=${answer:-Y}
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Skipping gaming stack install."
    return
  fi
  # Each step is independent — one failing (e.g. a network hiccup on the
  # GitHub API call, or a distro missing one package) shouldn't abort the
  # rest of the stack under `set -e`.
  enable_32bit || true
  install_steam || echo "  Steam install failed — skipping, continuing with the rest."
  install_wine || echo "  Wine install failed — skipping, continuing with the rest."
  install_gamemode || true
  install_lutris || echo "  Lutris install failed — skipping, continuing with the rest."
  install_mangohud || true
  install_protonup || echo "  ProtonUp-Qt install failed — skipping, continuing with the rest."
  install_or_update_proton_ge || echo "  GE-Proton refresh failed — skipping, continuing with the rest."
  install_gamescope || true
  install_vkbasalt || echo "  vkBasalt install failed — skipping, continuing with the rest."
  if [[ "$want_heroic" =~ ^[Yy]$ ]]; then
    install_heroic || echo "  Heroic install failed — skipping."
  fi
  echo "==> Gaming stack installed."
}
