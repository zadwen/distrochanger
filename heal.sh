#!/usr/bin/env bash
# heal.sh — scans journalctl and Steam's own logs for a known set of
# recurring Linux-gaming error signatures, and where a safe automatic fix
# exists, applies it (reusing the same functions drivers.sh/tweaks.sh use).
# Anything without a safe automatic fix is reported with a clear next step
# instead of touched, since guessing wrong here can make things worse.
set -euo pipefail

_steam_log_dirs() {
  local -a dirs=()
  [[ -d "$HOME/.steam/steam/logs" ]] && dirs+=("$HOME/.steam/steam/logs")
  [[ -d "$HOME/.local/share/Steam/logs" ]] && dirs+=("$HOME/.local/share/Steam/logs")
  [[ -d "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/logs" ]] && \
    dirs+=("$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/logs")
  printf '%s\n' "${dirs[@]}"
}

_journal_recent() {
  # Last 24h of user-session journal, quietly no-op if journalctl/logind
  # aren't available (some minimal/container setups).
  if command -v journalctl >/dev/null 2>&1; then
    journalctl --user -S -1d -p warning 2>/dev/null || true
    journalctl -S -1d -p warning 2>/dev/null || true
  fi
}

_steam_logs_recent() {
  local dir
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    find "$dir" -maxdepth 1 -type f -mtime -2 -print0 2>/dev/null \
      | xargs -0 -r cat -- 2>/dev/null
  done < <(_steam_log_dirs)
}

HEAL_FOUND=0
HEAL_FIXED=0

_heal_report() {
  local desc="$1"
  HEAL_FOUND=$((HEAL_FOUND + 1))
  echo "  [found] $desc"
}

_heal_fixed() {
  local desc="$1"
  HEAL_FIXED=$((HEAL_FIXED + 1))
  echo "  [fixed] $desc"
}

# Each check below is independent and non-fatal: a missing log source or a
# pattern that doesn't match just means "nothing to do" for that check.

heal_check_vulkan() {
  local combined="$1"
  if echo "$combined" | grep -qiE 'vkCreateInstance|ICD.*not.*found|no vulkan.*driver|vulkan.*loader.*error'; then
    _heal_report "Vulkan loader/ICD errors in logs"
    if command -v fix_missing_vulkan >/dev/null 2>&1; then
      fix_missing_vulkan && _heal_fixed "Reinstalled/verified Vulkan tools + drivers"
    fi
  fi
}

heal_check_map_count() {
  local combined="$1"
  if echo "$combined" | grep -qiE 'vm\.max_map_count|failed to reserve memory|out of memory.*mmap|too many open.*map'; then
    _heal_report "Signs of vm.max_map_count being too low for a game/engine (common with UE4/5, some Proton titles)"
    if command -v tweak_vm_max_map_count >/dev/null 2>&1; then
      tweak_vm_max_map_count && _heal_fixed "Raised vm.max_map_count"
    fi
  fi
}

heal_check_gamemode() {
  local combined="$1"
  if echo "$combined" | grep -qiE 'gamemode.*not.*install|could not.*request.*gamemode|gamemoded.*not.*running|libgamemode.*not found'; then
    _heal_report "GameMode requested by a game but unavailable"
    if ! pkg_installed gamemode 2>/dev/null; then
      pkg_install gamemode && _heal_fixed "Installed GameMode"
    fi
    if command -v tweak_gamemode_group >/dev/null 2>&1; then
      tweak_gamemode_group && _heal_fixed "Fixed gamemode group membership"
    fi
  fi
}

heal_check_wine_prefix() {
  local combined="$1"
  if echo "$combined" | grep -qiE 'wine:.*could not load|0x[0-9a-f]+ \(exception|fixme:.*wineboot|corrupt.*prefix|wineserver.*fatal'; then
    _heal_report "Signs of a corrupted Wine/Proton prefix"
    if command -v fix_broken_wine_prefixes >/dev/null 2>&1; then
      fix_broken_wine_prefixes && _heal_fixed "Checked/repaired Wine prefixes (see prompts above)"
    fi
  fi
}

heal_check_shader_cache() {
  local combined="$1"
  if echo "$combined" | grep -qiE 'shader cache.*corrupt|failed to.*compile.*shader.*cache|VkPipelineCache.*invalid'; then
    _heal_report "Corrupted shader cache signature in logs"
    local shader_dir="$HOME/.cache/mesa_shader_cache"
    if [[ -d "$shader_dir" ]]; then
      local go="n"
      if [[ -t 0 ]]; then
        read -r -p "  Clear Mesa's shader cache at $shader_dir? Safe — it just rebuilds on next launch. [y/N] " go || go="n"
      else
        echo "  (non-interactive run — skipping shader-cache clear prompt)"
      fi
      if [[ "$go" =~ ^[Yy]$ ]]; then
        rm -rf "${shader_dir:?}"/*
        _heal_fixed "Cleared Mesa shader cache"
      fi
    fi
  fi
}

heal_check_gpu_reset() {
  local combined="$1"
  if echo "$combined" | grep -qiE 'amdgpu.*(gpu reset|ring.*timeout)|nvidia.*xid|nvrm.*xid'; then
    _heal_report "GPU reset/Xid errors — this usually points to a driver, power-limit, or"
    echo "         overclock/undervolt issue rather than something a script should"
    echo "         auto-repair. Consider: reseating any overclock/undervolt, updating"
    echo "         to the latest stable driver (drivers.sh), and checking dmesg -T"
    echo "         around the time of the crash for the specific fault code."
  fi
}

heal_check_32bit_missing() {
  local combined="$1"
  if echo "$combined" | grep -qiE 'wine.*failed to load.*32-bit|cannot open shared object file.*i386|32-bit.*library.*missing'; then
    _heal_report "A 32-bit library a game/Wine needed appears to be missing"
    if command -v enable_32bit >/dev/null 2>&1; then
      enable_32bit && _heal_fixed "Enabled/refreshed 32-bit library support"
    fi
  fi
}

run_auto_heal() {
  echo "==> Scanning journalctl + Steam logs for known gaming error patterns (last ~24-48h)..."
  local combined
  combined="$( { _journal_recent; echo; _steam_logs_recent; } || true )"

  if [[ -z "${combined// /}" ]]; then
    echo "  No recent logs available to scan (journalctl/Steam log dirs empty or missing)."
    return 0
  fi

  HEAL_FOUND=0
  HEAL_FIXED=0

  heal_check_vulkan "$combined" || true
  heal_check_map_count "$combined" || true
  heal_check_gamemode "$combined" || true
  heal_check_wine_prefix "$combined" || true
  heal_check_shader_cache "$combined" || true
  heal_check_gpu_reset "$combined" || true
  heal_check_32bit_missing "$combined" || true

  echo ""
  if [[ "$HEAL_FOUND" -eq 0 ]]; then
    echo "  No known error signatures found — logs look clean."
  else
    echo "  $HEAL_FOUND known issue signature(s) found, $HEAL_FIXED auto-fixed."
    if [[ "$HEAL_FIXED" -lt "$HEAL_FOUND" ]]; then
      echo "  The rest need a manual look — see the notes above."
    fi
  fi
}

auto_heal_menu() {
  echo ""
  read -r -p "[Standard] Scan logs for known gaming bugs and auto-fix what's safe to fix? [Y/n] " answer
  answer=${answer:-Y}
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Skipping auto-heal scan."
    return
  fi
  run_auto_heal
}
