#!/usr/bin/env bash
# kernel.sh — optional performance kernel install (XanMod/Liquorix on
# Debian/Ubuntu, linux-zen on Arch). This is opt-in and skipped by default
# since swapping kernels carries more risk than installing an app.
set -euo pipefail

_xanmod_psabi_level() {
  # XanMod ships x64v1/v2/v3/v4 builds tuned to CPU instruction level.
  # Default to v1 (safest, works everywhere) unless we can confirm higher.
  if command -v /lib/x86-64-level.sh >/dev/null 2>&1; then
    /lib/x86-64-level.sh 2>/dev/null || echo "1"
    return
  fi
  if grep -qm1 -E '\bavx512' /proc/cpuinfo 2>/dev/null; then
    echo "4"
  elif grep -qm1 -E '\bavx2\b' /proc/cpuinfo 2>/dev/null; then
    echo "3"
  elif grep -qm1 -E '\bsse4_2\b' /proc/cpuinfo 2>/dev/null; then
    echo "2"
  else
    echo "1"
  fi
}

_kernel_secure_boot_check() {
  local sb
  sb="$(detect_secure_boot 2>/dev/null || echo "unknown")"
  if [[ "$sb" == *"enabled"* ]]; then
    echo ""
    echo "  WARNING: Secure Boot is ENABLED."
    echo "  XanMod/Liquorix/linux-zen packages are community-built and are NOT signed"
    echo "  with a key your firmware already trusts. With Secure Boot on, the new"
    echo "  kernel will likely fail to boot (or the bootloader will silently fall"
    echo "  back to your current kernel) unless you either:"
    echo "    1) Disable Secure Boot in firmware/UEFI settings, or"
    echo "    2) Sign the kernel modules yourself and enroll a MOK key (mokutil)."
    echo ""
    if command -v mokutil >/dev/null 2>&1; then
      read -r -p "  Continue installing anyway? [y/N] " sb_go
      [[ "$sb_go" =~ ^[Yy]$ ]] || { echo "  Skipping kernel install."; return 1; }
    else
      echo "  ('mokutil' isn't installed, so gameify can't offer to enroll a MOK key"
      echo "  for you automatically — you'd need to do that by hand.)"
      read -r -p "  Continue installing anyway? [y/N] " sb_go
      [[ "$sb_go" =~ ^[Yy]$ ]] || { echo "  Skipping kernel install."; return 1; }
    fi
  fi
  return 0
}

install_xanmod() {
  _kernel_secure_boot_check || return 1
  if [[ "$PKG_FAMILY" != "debian" ]]; then
    echo "  XanMod's official repo only covers Debian/Ubuntu-based distros."
    echo "  See https://xanmod.org for other install methods on your distro."
    return 1
  fi
  if uname -r | grep -qi xanmod; then
    echo "  Already running a XanMod kernel ($(uname -r)), skipping install."
    return 0
  fi
  echo "==> Installing XanMod kernel..."
  local level
  level="$(_xanmod_psabi_level)"
  echo "  Detected CPU instruction level: x64v${level}"
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://dl.xanmod.org/archive.key | sudo gpg --dearmor -o /etc/apt/keyrings/xanmod-archive-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" \
    | sudo tee /etc/apt/sources.list.d/xanmod-release.list >/dev/null
  pkg_update
  pkg_install "linux-xanmod-x64v${level}"
  log_change "Installed XanMod kernel (x64v${level})"
  echo "  Reboot and select the XanMod kernel from your bootloader menu if it isn't default."
}

install_liquorix() {
  _kernel_secure_boot_check || return 1
  if [[ "$PKG_FAMILY" != "debian" ]]; then
    echo "  Liquorix's official repo only covers Debian/Ubuntu-based distros."
    echo "  See https://liquorix.net for other install methods on your distro."
    return 1
  fi
  if uname -r | grep -qi liquorix; then
    echo "  Already running a Liquorix kernel ($(uname -r)), skipping install."
    return 0
  fi
  echo "==> Installing Liquorix kernel..."
  curl -fsSL 'https://liquorix.net/add-liquorix-repo.gpg.key' | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/liquorix-keyring.gpg
  echo "deb http://liquorix.net/debian $(lsb_release -cs 2>/dev/null || echo sid) main" \
    | sudo tee /etc/apt/sources.list.d/liquorix.list >/dev/null
  pkg_update
  pkg_install linux-image-liquorix-amd64 linux-headers-liquorix-amd64
  log_change "Installed Liquorix kernel"
  echo "  Reboot and select the Liquorix kernel from your bootloader menu if it isn't default."
}

install_linux_zen() {
  _kernel_secure_boot_check || return 1
  if [[ "$PKG_FAMILY" != "arch" ]]; then
    echo "  linux-zen is an official Arch repo package — not applicable to this distro."
    return 1
  fi
  if uname -r | grep -qi zen; then
    echo "  Already running linux-zen ($(uname -r)), skipping install."
    return 0
  fi
  echo "==> Installing linux-zen kernel (official Arch repo, no AUR needed)..."
  pkg_install linux-zen linux-zen-headers
  log_change "Installed linux-zen kernel"
  echo "  Update your bootloader config (grub-mkconfig / update or reinstall your"
  echo "  bootloader hook) and reboot to select it."
}

kernel_menu() {
  echo ""
  echo "[Experimental] Performance-tuned kernel (XanMod/Liquorix/linux-zen)"
  if ! tier_enabled experimental; then
    echo "  Experimental tier isn't enabled — skipping. Enable it with"
    echo "  './gameify.sh --tiers' if you want to install a performance kernel."
    return 0
  fi
  echo "Optional: install a performance-tuned kernel? This is opt-in — the stock"
  echo "kernel your distro ships is fine for most people, but these offer lower"
  echo "latency scheduling and other tweaks some gamers prefer."
  echo "(You can always boot back into your original kernel from the bootloader menu.)"
  echo "  Secure Boot: $(detect_secure_boot 2>/dev/null || echo unknown)"

  case "$PKG_FAMILY" in
    debian)
      select opt in "XanMod" "Liquorix" "Skip"; do
        case "$REPLY" in
          1) install_xanmod || echo "  XanMod install failed — see message above."; break ;;
          2) install_liquorix || echo "  Liquorix install failed — see message above."; break ;;
          3) echo "Skipping performance kernel."; break ;;
          *) echo "Invalid choice." ;;
        esac
      done
      ;;
    arch)
      select opt in "linux-zen" "Skip"; do
        case "$REPLY" in
          1) install_linux_zen || echo "  linux-zen install failed — see message above."; break ;;
          2) echo "Skipping performance kernel."; break ;;
          *) echo "Invalid choice." ;;
        esac
      done
      ;;
    *)
      echo "  No automated performance-kernel path for this distro yet — skipping."
      echo "  Fedora users: consider the stock kernel's built-in tuned profiles instead"
      echo "  ('tuned-adm profile throughput-performance')."
      ;;
  esac
}
