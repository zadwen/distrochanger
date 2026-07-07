#!/usr/bin/env bash
# gamemode-toggle.sh — one global, reversible "Game Mode" switch: forces the
# performance CPU governor, does a one-shot RAM cache clear, raises file-
# descriptor limits (both for future logins AND retroactively on an
# already-running Steam process via prlimit), and pauses whatever desktop
# compositor can be safely paused without ending the session.
#
# This is deliberately separate from Feral's GameMode daemon (the `gamemode`
# package gaming-stack.sh installs) — that's a per-process API individual
# games opt into via gamemoderun. This is a manual, whole-system switch you
# flip yourself right before/after a session, and it remembers your
# previous settings so turning it back off actually restores them instead
# of guessing at a "sane default".
set -euo pipefail

GAMEIFY_STATE_DIR="$GAMEIFY_CONFIG_DIR/gamemode-state"
GOVERNOR_STATE_FILE="$GAMEIFY_STATE_DIR/prev-governor"
ACTIVE_FLAG_FILE="$GAMEIFY_STATE_DIR/active"
LIMITS_DROPIN="/etc/security/limits.d/99-gameify-gamemode.conf"

_cpu_governor_paths() {
  ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
}

_current_governor() {
  local p
  p="$(_cpu_governor_paths | head -n1)"
  if [[ -n "$p" ]]; then cat "$p" 2>/dev/null || echo "unknown"; else echo "unknown"; fi
}

_governor_available() {
  local avail_file="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
  [[ -f "$avail_file" ]] && grep -qw "$1" "$avail_file"
}

_set_governor() {
  local gov="$1" p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    run_priv "set $p to $gov" -- bash -c "echo '$gov' | sudo tee '$p' >/dev/null"
  done < <(_cpu_governor_paths)
}

gamemode_status() {
  mkdir -p "$GAMEIFY_STATE_DIR"
  if [[ -f "$ACTIVE_FLAG_FILE" ]]; then echo "on"; else echo "off"; fi
}

_clear_ram_caches() {
  echo "  Clearing RAM page/dentry/inode caches (frees RAM for the game; the"
  echo "  cache refills naturally from normal use, this is a one-shot, safe action)..."
  run_priv "sync && drop_caches=3" -- bash -c "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null"
}

_raise_fd_limits() {
  echo "  Raising file-descriptor limits..."
  run_priv "write $LIMITS_DROPIN (nofile 1048576, applies to future logins)" -- bash -c \
    "printf '* soft nofile 1048576\n* hard nofile 1048576\n' | sudo tee '$LIMITS_DROPIN' >/dev/null"

  # A limits.d drop-in only applies to *new* login sessions, so on its own
  # it wouldn't be "instant" for a Steam session that's already open.
  # prlimit can raise the limit on an already-running process directly.
  if command -v prlimit >/dev/null 2>&1; then
    local pid found=false
    for pid in $(pgrep -f '(^|/)steam($| )' 2>/dev/null || true); do
      found=true
      run_priv "raise nofile limit on running PID $pid (Steam)" -- \
        sudo prlimit --pid "$pid" --nofile=1048576:1048576 2>/dev/null || true
    done
    [[ "$found" == false ]] && echo "  (Steam isn't running yet — the drop-in above will apply once it starts.)"
  fi
}

_restore_fd_limits() {
  if [[ -f "$LIMITS_DROPIN" ]]; then
    run_priv "remove $LIMITS_DROPIN" -- sudo rm -f "$LIMITS_DROPIN"
    return 0
  fi
  return 1
}

# Compositor pausing is desktop-specific and only done where there's a real,
# safe, reversible mechanism — never by killing the compositor outright.
_pause_compositor() {
  if command -v qdbus >/dev/null 2>&1 && { pgrep -x kwin_x11 >/dev/null 2>&1 || pgrep -x kwin_wayland >/dev/null 2>&1; }; then
    echo "  Suspending KWin compositing (KDE) via its own D-Bus suspend method..."
    run_priv "qdbus org.kde.KWin /Compositor suspend" -- qdbus org.kde.KWin /Compositor suspend 2>/dev/null || true
    return
  fi
  if pgrep -x picom >/dev/null 2>&1; then
    echo "  Pausing picom compositor (SIGSTOP — process is frozen, not killed; fully reversible)..."
    run_priv "pause picom (SIGSTOP)" -- pkill -STOP -x picom || true
    return
  fi
  echo "  No safely-pausable compositor detected here (GNOME/Wayland compositors"
  echo "  can't be suspended without ending the session) — skipping this part."
}

_resume_compositor() {
  if command -v qdbus >/dev/null 2>&1 && { pgrep -x kwin_x11 >/dev/null 2>&1 || pgrep -x kwin_wayland >/dev/null 2>&1; }; then
    echo "  Resuming KWin compositing..."
    run_priv "qdbus org.kde.KWin /Compositor resume" -- qdbus org.kde.KWin /Compositor resume 2>/dev/null || true
    return
  fi
  if pgrep -x picom >/dev/null 2>&1; then
    echo "  Resuming picom compositor (SIGCONT)..."
    run_priv "resume picom (SIGCONT)" -- pkill -CONT -x picom || true
  fi
}

gamemode_on() {
  mkdir -p "$GAMEIFY_STATE_DIR"
  if [[ -f "$ACTIVE_FLAG_FILE" ]]; then
    echo "Game Mode is already ON."
    return 0
  fi
  echo "==> Enabling Game Mode..."

  local gov
  gov="$(_current_governor)"
  if [[ "$gov" != "unknown" ]]; then
    echo "$gov" > "$GOVERNOR_STATE_FILE"
  fi
  if _governor_available performance; then
    _set_governor performance
    log_change "Game Mode: set CPU governor to performance (was: $gov)"
  else
    echo "  'performance' governor isn't available on this CPU/driver — skipping that part."
  fi

  _clear_ram_caches
  log_change "Game Mode: cleared RAM caches"

  _raise_fd_limits
  log_change "Game Mode: raised file-descriptor limits"

  _pause_compositor

  touch "$ACTIVE_FLAG_FILE"
  log_change "Game Mode: ON"
  echo ""
  echo "Game Mode is ON. Run './gameify.sh --game-mode off' when you're done gaming"
  echo "to put everything back the way it was."
}

gamemode_off() {
  mkdir -p "$GAMEIFY_STATE_DIR"
  if [[ ! -f "$ACTIVE_FLAG_FILE" ]]; then
    echo "Game Mode is already OFF."
    return 0
  fi
  echo "==> Disabling Game Mode..."

  local gov="schedutil"
  if [[ -f "$GOVERNOR_STATE_FILE" ]]; then
    gov="$(cat "$GOVERNOR_STATE_FILE")"
  else
    echo "  No saved previous governor found — restoring to '$gov' as a common distro default."
  fi
  if _governor_available "$gov"; then
    _set_governor "$gov"
    log_change "Game Mode: restored CPU governor to $gov"
  fi

  _restore_fd_limits && log_change "Game Mode: restored file-descriptor limits"

  _resume_compositor

  rm -f "$ACTIVE_FLAG_FILE"
  log_change "Game Mode: OFF"
  echo ""
  echo "Game Mode is OFF — desktop settings restored to normal."
}

gamemode_toggle() {
  if [[ "$(gamemode_status)" == on ]]; then
    gamemode_off
  else
    gamemode_on
  fi
}

game_mode_menu() {
  if ! tier_enabled advanced; then
    return 0
  fi
  echo ""
  local current
  current="$(gamemode_status)"
  echo "Game Mode is currently: $current"
  if [[ "$(ask_yn "[Advanced] Toggle Game Mode now (CPU governor, RAM cache, fd limits, compositor)?" N)" == y ]]; then
    gamemode_toggle
  fi
}
