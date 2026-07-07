#!/usr/bin/env bash
# gaming-stack.sh — core gaming apps, adapted per distro family, plus
# Proton-GE (with real auto-update via GitHub releases), Gamescope, vkBasalt.
set -euo pipefail

enable_32bit() {
  echo "==> Enabling 32-bit library support (needed for many older/Proton games)..."
  case "$PKG_FAMILY" in
    debian)
      if [[ "$DRY_RUN" == true ]]; then
        dry_run_note "dpkg --add-architecture i386"
      else
        sudo dpkg --add-architecture i386
      fi
      pkg_update
      ;;
    arch)
      if ! grep -q '^\[multilib\]' /etc/pacman.conf; then
        if [[ "$DRY_RUN" == true ]]; then
          dry_run_note "enable [multilib] in /etc/pacman.conf"
        else
          echo "  Enabling [multilib] repo in /etc/pacman.conf..."
          sudo sed -i "/^#\[multilib\]/,/^#Include/ s/^#//" /etc/pacman.conf
        fi
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

  if [[ "$DRY_RUN" == true ]]; then
    dry_run_note "download + extract GE-Proton $tag into $compat_dir"
    return 0
  fi

  echo "  Installing GE-Proton $tag into $compat_dir ..."
  tmpfile="$(mktemp --suffix=.tar.gz)"
  curl -fsSL "$url" -o "$tmpfile"
  tar -xzf "$tmpfile" -C "$compat_dir"
  rm -f "$tmpfile"
  log_change "Installed/updated GE-Proton to $tag"
  echo "  Restart Steam, then enable it per-game under Properties > Compatibility."
}

# ---------- Per-game Proton selection ----------

_steam_config_vdf() {
  local native="$HOME/.steam/root/config/config.vdf"
  local native_alt="$HOME/.local/share/Steam/config/config.vdf"
  local flat="$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/config/config.vdf"
  if [[ -f "$native" ]]; then echo "$native"
  elif [[ -f "$native_alt" ]]; then echo "$native_alt"
  elif [[ -f "$flat" ]]; then echo "$flat"
  else echo ""
  fi
}

list_installed_proton_versions() {
  local compat_dir
  compat_dir="$(_steam_compat_dir)"
  echo "Custom builds in $compat_dir:"
  if [[ -d "$compat_dir" ]]; then
    find "$compat_dir" -mindepth 1 -maxdepth 1 -type d -printf '  - %f\n' 2>/dev/null
  fi
  echo "Steam-shipped builds (proton_experimental, proton_9, etc.) are managed by"
  echo "Steam itself and don't need to be listed here."
}

# set_proton_for_game <appid> <tool-name>
# Writes/updates the CompatToolMapping entry for one AppID in Steam's
# config.vdf so a specific game always launches with a specific Proton
# build, without having to click through Properties > Compatibility in the
# Steam UI. Steam must be closed while this runs, since it rewrites the
# file on exit and would otherwise clobber this change.
set_proton_for_game() {
  local appid="$1" tool="$2"
  if [[ -z "$appid" || -z "$tool" ]]; then
    echo "  Usage: set_proton_for_game <appid> <proton-tool-name>"
    return 1
  fi
  local vdf
  vdf="$(_steam_config_vdf)"
  if [[ -z "$vdf" ]]; then
    echo "  Couldn't find Steam's config.vdf — has Steam been launched at least once?"
    return 1
  fi
  if pgrep -x steam >/dev/null 2>&1; then
    echo "  Steam is currently running — close it first, or this change will be"
    echo "  overwritten when Steam next exits and rewrites config.vdf."
    if [[ "$(ask_yn "  Continue anyway?" N)" != y ]]; then
      return 1
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    dry_run_note "back up $vdf and set CompatToolMapping[$appid] = $tool"
    return 0
  fi

  cp "$vdf" "$vdf.gameify.bak"

  local result=0
  python3 - "$vdf" "$appid" "$tool" <<'PYEOF' || result=$?
import re, sys
path, appid, tool = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
    data = f.read()

entry = f'\t\t\t\t"{appid}"\n\t\t\t\t{{\n\t\t\t\t\t"name"\t\t"{tool}"\n\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t}}\n'

# Replace an existing block for this appid if present, else insert one
# right after the CompatToolMapping opening brace.
pattern = re.compile(
    r'(\t{4}"' + re.escape(appid) + r'"\s*\n\t{4}\{)[^}]*?(\n\t{4}\})',
    re.DOTALL,
)
if re.search(r'"CompatToolMapping"', data):
    if pattern.search(data):
        data = pattern.sub(lambda m: entry.rstrip("\n"), data)
    else:
        data = re.sub(
            r'("CompatToolMapping"\s*\n\t*\{)',
            lambda m: m.group(1) + "\n" + entry.rstrip("\n"),
            data,
            count=1,
        )
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(data)
    print("ok")
else:
    print("no-section")
PYEOF
  if [[ $result -ne 0 ]] || ! command -v python3 >/dev/null 2>&1; then
    echo "  python3 not available — can't safely edit config.vdf automatically."
    echo "  Fallback: set it manually in Steam under the game's Properties >"
    echo "  Compatibility tab (this is the officially supported way)."
    cp "$vdf.gameify.bak" "$vdf" 2>/dev/null
    return 1
  fi
  log_change "Set Proton override for AppID $appid -> $tool"
  echo "  Backup saved as $vdf.gameify.bak"
  echo "  Restart Steam for the change to take effect."
}

per_game_proton_menu() {
  if ! is_interactive; then
    echo "  (non-interactive — skipping per-game Proton override; run interactively"
    echo "  or call set_proton_for_game <appid> <tool> directly)"
    return 0
  fi
  echo ""
  echo "Per-game Proton selection (edits Steam's config.vdf directly)."
  list_installed_proton_versions
  echo ""
  local appid tool
  read -r -p "AppID to configure (find it on steamdb.info or the store URL, blank to skip): " appid || appid=""
  [[ -z "$appid" ]] && { echo "Skipped."; return; }
  read -r -p "Proton build name exactly as Steam shows it (e.g. GE-Proton9-20, proton_experimental): " tool || tool=""
  [[ -z "$tool" ]] && { echo "Skipped."; return; }
  set_proton_for_game "$appid" "$tool"
}

gaming_stack_menu() {
  echo ""
  echo "[Standard] Core gaming stack: Steam, Wine, GameMode, Lutris, MangoHud, ProtonUp-Qt"
  if tier_enabled advanced; then
    echo "[Advanced] Also included: Proton-GE (auto-installed/updated from GitHub),"
    echo "           Gamescope, vkBasalt"
  else
    echo "[Advanced tier disabled] Proton-GE auto-update, Gamescope, and vkBasalt will"
    echo "be skipped — enable Advanced via './gameify.sh --tiers' to include them."
  fi
  local want_heroic
  want_heroic="$(ask_yn "Also install Heroic Games Launcher (Epic/GOG/Amazon)?" N)"
  if [[ "$(ask_yn "Proceed with install?" Y)" != y ]]; then
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
  if tier_enabled advanced; then
    install_or_update_proton_ge || echo "  GE-Proton refresh failed — skipping, continuing with the rest."
    install_gamescope || true
    install_vkbasalt || echo "  vkBasalt install failed — skipping, continuing with the rest."
  fi
  if [[ "$want_heroic" == y ]]; then
    install_heroic || echo "  Heroic install failed — skipping."
  fi
  echo "==> Gaming stack installed."

  if tier_enabled advanced; then
    echo ""
    if [[ "$(ask_yn "[Advanced] Set a specific Proton build for a specific game now?" N)" == y ]]; then
      per_game_proton_menu
    fi
  fi
}
