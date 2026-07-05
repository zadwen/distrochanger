#!/usr/bin/env bash
# apps.sh — everyday gamer apps that aren't strictly "the gaming stack":
# Discord, OBS Studio, Spotify, and (optionally) Battle.net / EA App, which
# only run on Linux via Wine/Proton through Lutris install scripts.
# All installed via Flatpak where possible — one install path across every
# distro, auto-updates through the normal Flatpak update flow, and sandboxed.
set -euo pipefail

install_discord() {
  echo "==> Installing Discord..."
  ensure_flatpak
  flatpak_install com.discordapp.Discord && log_change "Installed Discord (Flatpak)"
}

install_obs() {
  echo "==> Installing OBS Studio..."
  ensure_flatpak
  flatpak_install com.obsproject.Studio && log_change "Installed OBS Studio (Flatpak)"
  echo "  Tip: for game-capture on Wayland you may also want the 'OBS Vulkan/EGL"
  echo "  capture' hint — Wayland screen capture requires PipeWire, which most"
  echo "  modern desktop environments already ship."
}

install_spotify() {
  echo "==> Installing Spotify..."
  ensure_flatpak
  flatpak_install com.spotify.Client && log_change "Installed Spotify (Flatpak)"
}

# Battle.net and the EA App have no native Linux build and no Flatpak either
# — the only realistic path is Lutris running the Windows installer under a
# tuned Wine/Proton runner, using Lutris's own maintained install scripts.
# We don't try to reimplement that logic (it changes with every client
# update); instead we make sure Lutris is present and hand off to its
# install-script protocol handler, same as clicking "Install" on lutris.net.
_lutris_install_via_protocol() {
  local slug="$1" label="$2"
  if ! command -v lutris >/dev/null 2>&1 && ! flatpak list --app 2>/dev/null | grep -q net.lutris.Lutris; then
    echo "  Lutris isn't installed yet — installing it first..."
    install_lutris || { echo "  Lutris install failed, can't continue with $label."; return 1; }
  fi
  echo "  Launching Lutris's installer for $label (lutris:install/$slug)..."
  echo "  This opens Lutris, which downloads the official $label installer and"
  echo "  runs it under a Wine/Proton runner it manages — gameify doesn't touch"
  echo "  that installer directly, since Lutris keeps these scripts current."
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "lutris:install/$slug" >/dev/null 2>&1 &
  elif command -v lutris >/dev/null 2>&1; then
    lutris "lutris:install/$slug" >/dev/null 2>&1 &
  else
    flatpak run net.lutris.Lutris "lutris:install/$slug" >/dev/null 2>&1 &
  fi
  log_change "Launched Lutris installer for $label"
  echo "  Follow the prompts in the Lutris window that just opened."
}

install_battlenet() {
  echo "==> Setting up Battle.net (via Lutris)..."
  _lutris_install_via_protocol "battlenet" "Battle.net"
}

install_ea_app() {
  echo "==> Setting up EA App (via Lutris)..."
  _lutris_install_via_protocol "ea-app" "EA App"
}

apps_menu() {
  echo ""
  echo "[Standard] Optional everyday apps (Flatpak, auto-update with your other Flatpaks):"
  local -a want=()
  read -r -p "Install Discord? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] && want+=("discord")
  read -r -p "Install OBS Studio? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] && want+=("obs")
  read -r -p "Install Spotify? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] && want+=("spotify")

  if tier_enabled experimental; then
    echo ""
    echo "[Experimental] Battle.net and EA App have no native Linux client or Flatpak —"
    echo "installing them hands off to Lutris, which runs the official Windows"
    echo "installer under Wine. This works well in practice but is a less"
    echo "officially-supported path than anything else in this menu."
    read -r -p "Set up Battle.net via Lutris? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] && want+=("battlenet")
    read -r -p "Set up EA App via Lutris? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] && want+=("ea_app")
  else
    echo ""
    echo "[Experimental tier disabled] Skipping Battle.net/EA App (Lutris-based)."
    echo "Enable Experimental via './gameify.sh --tiers' if you want those offered."
  fi

  if [[ "${#want[@]}" -eq 0 ]]; then
    echo "No optional apps selected."
    return
  fi

  for item in "${want[@]}"; do
    case "$item" in
      discord) install_discord || echo "  Discord install failed — skipping." ;;
      obs) install_obs || echo "  OBS install failed — skipping." ;;
      spotify) install_spotify || echo "  Spotify install failed — skipping." ;;
      battlenet) install_battlenet || echo "  Battle.net setup failed — skipping." ;;
      ea_app) install_ea_app || echo "  EA App setup failed — skipping." ;;
    esac
  done
  echo "==> Optional apps step finished."
}
