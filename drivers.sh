#!/usr/bin/env bash
# drivers.sh — GPU driver install, adapted per distro family, with
# hybrid-GPU (Optimus/PRIME) laptop support and Flatpak fallback when a
# native package isn't available.
set -euo pipefail

_install_nvidia_debian() {
  if command -v ubuntu-drivers >/dev/null 2>&1; then
    echo "  Ubuntu-based system detected — using ubuntu-drivers autoinstall (auto-picks the right version)."
    sudo ubuntu-drivers autoinstall
  else
    echo "  Plain Debian detected. This needs the 'contrib' and 'non-free' repos enabled"
    echo "  in /etc/apt/sources.list before this will work. Attempting install anyway..."
    pkg_install nvidia-driver firmware-misc-nonfree || {
      echo "  Install failed — most likely contrib/non-free isn't enabled yet."
      echo "  See: https://wiki.debian.org/NvidiaGraphicsDrivers"
      return 1
    }
  fi
}

_install_nvidia_fedora() {
  if ! dnf repolist 2>/dev/null | grep -qi rpmfusion-nonfree; then
    echo "  Enabling RPM Fusion (free + nonfree) — required for NVIDIA on Fedora..."
    local fedver
    fedver="$(rpm -E %fedora)"
    pkg_install \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedver}.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm"
  else
    echo "  RPM Fusion already enabled (Nobara ships with this by default)."
  fi
  pkg_install akmod-nvidia xorg-x11-drv-nvidia-cuda
  echo "  Kernel module will build via akmods — this can take a few minutes on first boot."
}

_install_nvidia_arch() {
  echo "  Installing NVIDIA driver + utils via pacman..."
  pkg_install nvidia nvidia-utils nvidia-settings
}

_install_nvidia_opensuse() {
  echo "  openSUSE NVIDIA install varies by version (Leap vs Tumbleweed) and needs a"
  echo "  community repo added first. Attempting the common Tumbleweed path..."
  sudo zypper addrepo --refresh https://download.nvidia.com/opensuse/tumbleweed nvidia-repo 2>/dev/null || true
  sudo zypper refresh || true
  pkg_install x11-video-nvidiaG06 || {
    echo "  Automatic install didn't complete. Follow the official guide instead:"
    echo "  https://en.opensuse.org/SDB:NVIDIA_drivers"
    return 1
  }
}

install_nvidia() {
  echo "==> Installing NVIDIA driver..."
  if pkg_installed nvidia-driver 2>/dev/null || pkg_installed nvidia 2>/dev/null || pkg_installed akmod-nvidia 2>/dev/null; then
    echo "  An NVIDIA driver package already appears installed — will still check for updates."
  fi
  case "$PKG_FAMILY" in
    debian) _install_nvidia_debian && log_change "Installed/updated NVIDIA driver (Debian/Ubuntu path)" ;;
    fedora) _install_nvidia_fedora && log_change "Installed/updated NVIDIA driver (Fedora/RPM Fusion path)" ;;
    arch) _install_nvidia_arch && log_change "Installed/updated NVIDIA driver (Arch path)" ;;
    opensuse) _install_nvidia_opensuse && log_change "Installed/updated NVIDIA driver (openSUSE path)" ;;
    *) echo "  Unsupported distro family for automatic NVIDIA install."; return 1 ;;
  esac
}

install_amd() {
  echo "==> Installing/updating AMD graphics stack (Mesa + Vulkan)..."
  case "$PKG_FAMILY" in
    debian) pkg_install mesa-vulkan-drivers libgl1-mesa-dri firmware-amd-graphics vulkan-tools ;;
    fedora) pkg_install mesa-vulkan-drivers mesa-dri-drivers vulkan-tools ;;
    arch) pkg_install vulkan-radeon mesa vulkan-tools ;;
    opensuse) pkg_install Mesa-vulkan-device-select vulkan-tools ;;
    *) echo "  Unsupported distro family for automatic AMD install."; return 1 ;;
  esac
  log_change "Installed/updated AMD Mesa/Vulkan stack"
  echo "  Note: the amdgpu kernel driver itself is already built into the Linux kernel —"
  echo "  this just installs the userspace Mesa/Vulkan pieces games actually talk to."
}

install_intel() {
  echo "==> Installing Intel graphics stack (Mesa + media driver)..."
  case "$PKG_FAMILY" in
    debian) pkg_install mesa-vulkan-drivers intel-media-va-driver vulkan-tools ;;
    fedora) pkg_install mesa-vulkan-drivers intel-media-driver vulkan-tools ;;
    arch) pkg_install vulkan-intel intel-media-driver vulkan-tools ;;
    opensuse) pkg_install Mesa-vulkan-device-select libva-intel-driver vulkan-tools ;;
    *) echo "  Unsupported distro family for automatic Intel install."; return 1 ;;
  esac
  log_change "Installed/updated Intel Mesa/Vulkan stack"
}

# ---------- Hybrid GPU (Optimus/PRIME) ----------

install_prime_tools() {
  echo "==> Hybrid-GPU (Optimus/PRIME) setup..."
  if tier_enabled advanced; then
    echo "[Advanced] Auto-configuring PRIME/Optimus tooling..."
    case "$PKG_FAMILY" in
      debian)
        pkg_install nvidia-prime 2>/dev/null && log_change "Installed nvidia-prime (GPU switching)" || \
          echo "  nvidia-prime not available here — you can still force offload manually (see below)."
        ;;
      arch)
        pkg_install nvidia-prime 2>/dev/null && log_change "Installed nvidia-prime (GPU switching)" || \
          echo "  nvidia-prime not available here — you can still force offload manually (see below)."
        ;;
      fedora|opensuse)
        echo "  No dedicated PRIME package path automated for this distro yet."
        echo "  Modern NVIDIA driver + Mesa handle render-offload without extra tooling on most setups."
        ;;
      *) : ;;
    esac
  else
    echo "  [Advanced tier disabled] Skipping automatic PRIME package install and"
    echo "  the default-GPU diagnostic/prime-run wrapper — enable Advanced via"
    echo "  './gameify.sh --tiers' for that. Showing the manual fallback instead:"
  fi

  echo ""
  echo "  Regardless of distro, you can force a specific game/app onto the discrete GPU"
  echo "  by prefixing its launch command (e.g. in a Steam game's launch options):"
  echo ""
  echo "    __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only %command%"
  echo ""
  echo "  For AMD hybrid setups (integrated + discrete AMD/Intel), the equivalent is:"
  echo "    DRI_PRIME=1 %command%"
  log_change "Printed PRIME/Optimus manual offload launch-option tip"

  if tier_enabled advanced; then
    echo ""
    fix_default_gpu_selection || true
  fi
}

# Installs a tiny `prime-run` wrapper into ~/.local/bin so any command can be
# forced onto the discrete GPU with `prime-run %command%`, without the user
# needing to remember the raw env-var incantation every time.
install_prime_run_wrapper() {
  local bindir="$HOME/.local/bin"
  local wrapper="$bindir/prime-run"
  mkdir -p "$bindir"
  local vendors
  vendors="$(detect_gpu_vendors)"

  if [[ -f "$wrapper" ]]; then
    echo "  ~/.local/bin/prime-run already exists, leaving it as-is."
  else
    if echo "$vendors" | grep -qw nvidia; then
      cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
# Forces the following command onto the NVIDIA discrete GPU (Optimus/PRIME).
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
exec "$@"
EOF
    else
      cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
# Forces the following command onto the discrete GPU render node (AMD hybrid setups).
export DRI_PRIME=1
exec "$@"
EOF
    fi
    chmod +x "$wrapper"
    log_change "Installed ~/.local/bin/prime-run wrapper"
  fi

  case ":$PATH:" in
    *":$bindir:"*) : ;;
    *)
      echo "  NOTE: $bindir isn't on your PATH in this shell. Add it in your"
      echo "  ~/.bashrc or ~/.profile (most distros already do this for new sessions):"
      echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
      ;;
  esac
  echo "  Usage: prime-run glxinfo | grep vendor    (or as a Steam launch option: prime-run %command%)"
}

# Diagnoses the classic hybrid-laptop bug where games/apps silently render on
# the weaker integrated GPU instead of the discrete NVIDIA/AMD one, and offers
# concrete, per-cause fixes instead of just restating the launch-option tip.
fix_default_gpu_selection() {
  if ! detect_hybrid_gpu; then
    echo "  Not a hybrid-GPU system — nothing to fix here."
    return 0
  fi
  echo "==> Checking which GPU actually renders by default on this hybrid laptop..."

  local renderer=""
  if command -v glxinfo >/dev/null 2>&1; then
    renderer="$(glxinfo 2>/dev/null | awk -F': ' '/OpenGL renderer string/ {print $2}')"
  fi

  if [[ -z "$renderer" ]]; then
    echo "  'glxinfo' not found — installing mesa-utils to check the active renderer..."
    case "$PKG_FAMILY" in
      debian) pkg_install mesa-utils ;;
      fedora) pkg_install glx-utils ;;
      arch) pkg_install mesa-utils ;;
      opensuse) pkg_install Mesa-demo-x ;;
      *) : ;;
    esac
    renderer="$(glxinfo 2>/dev/null | awk -F': ' '/OpenGL renderer string/ {print $2}')"
  fi

  echo "  Default renderer: ${renderer:-unknown}"

  if echo "$renderer" | grep -qiE 'intel|iGPU'; then
    echo ""
    echo "  Default render path is the Intel iGPU, not your discrete GPU. This is"
    echo "  normal at the desktop level (saves battery) but games launched without"
    echo "  an offload prefix will inherit it and run at iGPU performance. Fixes:"
    echo "    1. Per-game: launch via 'prime-run %command%' (installed below) or the"
    echo "       Steam launch-option env vars from install_prime_tools."
    echo "    2. NVIDIA laptops with 'nvidia' power-management mode (not"
    echo "       on-demand) can instead run everything on the dGPU by setting the"
    echo "       NVIDIA X Server Settings PRIME profile to 'NVIDIA (Performance Mode)'."
    echo "    3. If a specific Steam game still won't pick it up, check its own"
    echo "       in-game GPU-selection setting — some games ignore env vars and pick"
    echo "       a device index directly."
    log_change "Diagnosed hybrid-GPU default-renderer issue (Intel iGPU active by default)"
  else
    echo "  Default renderer already looks like your discrete/expected GPU — good."
  fi

  install_prime_run_wrapper
}

# Installs drivers for every vendor detected automatically (used in --auto mode)
install_detected_drivers() {
  local vendors="$1"
  for v in $vendors; do
    case "$v" in
      nvidia) install_nvidia || echo "  NVIDIA driver install failed — see message above." ;;
      amd) install_amd || echo "  AMD driver install failed — see message above." ;;
      intel) install_intel || echo "  Intel driver install failed — see message above." ;;
    esac
  done
  if detect_hybrid_gpu; then
    install_prime_tools || true
  fi
}

drivers_menu() {
  local detected="$1"
  echo ""
  echo "Detected GPU(s): ${detected:-none found}"
  echo "Which driver(s) do you want to install? [Standard]"
  local -a opts=("Install detected ($detected)" "NVIDIA only" "AMD only" "Intel only")
  if detect_hybrid_gpu; then
    opts+=("[Advanced] Fix wrong default GPU (hybrid laptop)")
  fi
  opts+=("Skip")
  select opt in "${opts[@]}"; do
    case "$opt" in
      "Install detected ($detected)") install_detected_drivers "$detected"; break ;;
      "NVIDIA only") install_nvidia; break ;;
      "AMD only") install_amd; break ;;
      "Intel only") install_intel; break ;;
      "[Advanced] Fix wrong default GPU (hybrid laptop)")
        if ! tier_enabled advanced; then
          echo "  This is an Advanced-tier feature. Running it anyway since you picked it"
          echo "  explicitly (tier gating only affects what runs automatically)."
        fi
        fix_default_gpu_selection
        break
        ;;
      "Skip") echo "Skipping driver install."; break ;;
      *) echo "Invalid choice, pick a number from the list." ;;
    esac
  done
}
