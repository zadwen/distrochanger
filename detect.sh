#!/usr/bin/env bash
# detect.sh — full system profiling: distro, CPU, GPU(s), RAM, disk type,
# Secure Boot, kernel, session type. Everything else in the project reads
# from these functions instead of guessing.
set -euo pipefail

detect_distro_family() {
  local id="" id_like=""
  if [[ -f /etc/os-release ]]; then
    id="$(. /etc/os-release; echo "${ID:-}")"
    id_like="$(. /etc/os-release; echo "${ID_LIKE:-}")"
  fi
  local combined="$id $id_like"
  case "$combined" in
    *ubuntu*|*debian*|*mint*|*zorin*|*pop*|*elementary*|*neon*) echo "debian" ;;
    *fedora*|*rhel*|*centos*|*nobara*|*rocky*|*alma*) echo "fedora" ;;
    *arch*|*manjaro*|*endeavour*) echo "arch" ;;
    *suse*) echo "opensuse" ;;
    *) echo "unknown" ;;
  esac
}

distro_pretty_name() {
  if [[ -f /etc/os-release ]]; then
    (. /etc/os-release; echo "${PRETTY_NAME:-Unknown Linux}")
  else
    echo "Unknown Linux"
  fi
}

# ---------- CPU ----------

detect_cpu_vendor() {
  if [[ -f /proc/cpuinfo ]]; then
    grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}'
  else
    echo "unknown"
  fi
}

detect_cpu_model() {
  if [[ -f /proc/cpuinfo ]]; then
    grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//'
  else
    echo "unknown"
  fi
}

detect_cpu_cores() {
  nproc --all 2>/dev/null || echo "unknown"
}

# ---------- GPU ----------

detect_gpu_lines() {
  if command -v lspci >/dev/null 2>&1; then
    lspci -nnk 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller' || true
  fi
}

# Prints space-separated vendor tags, e.g. "nvidia intel" for a hybrid laptop
detect_gpu_vendors() {
  local lines vendors=""
  lines="$(detect_gpu_lines)"
  if [[ -z "$lines" ]]; then
    echo "unknown"
    return
  fi
  if echo "$lines" | grep -qi nvidia; then vendors="$vendors nvidia"; fi
  if echo "$lines" | grep -Eqi 'amd|ati|radeon'; then vendors="$vendors amd"; fi
  if echo "$lines" | grep -qi intel; then vendors="$vendors intel"; fi
  if [[ -z "$vendors" ]]; then
    echo "unknown"
  else
    echo "$vendors" | xargs
  fi
}

# Returns 0 (true) if this looks like an Optimus/PRIME hybrid-GPU laptop
# (an Intel or AMD integrated GPU alongside a discrete NVIDIA/AMD GPU).
detect_hybrid_gpu() {
  local vendors count
  vendors="$(detect_gpu_vendors)"
  count=$(echo "$vendors" | wc -w)
  [[ "$count" -ge 2 ]]
}

detect_gpu_model_names() {
  detect_gpu_lines | sed -E 's/^[0-9a-f:.]+ //' | cut -d'[' -f1
}

# ---------- RAM / disk ----------

detect_ram() {
  free -h 2>/dev/null | awk '/Mem:/ {print $2}' || echo "unknown"
}

detect_disk_free_root() {
  df -h / 2>/dev/null | awk 'NR==2 {print $4 " free"}' || echo "unknown"
}

# Detects whether the disk holding / is an SSD/NVMe or a spinning HDD.
detect_disk_type() {
  local root_dev rotational base_dev
  if ! command -v lsblk >/dev/null 2>&1; then
    echo "unknown"
    return
  fi
  root_dev="$(df / 2>/dev/null | awk 'NR==2 {print $1}')"
  base_dev="$(lsblk -no PKNAME "$root_dev" 2>/dev/null | head -n1)"
  [[ -z "$base_dev" ]] && base_dev="$(basename "$root_dev" 2>/dev/null | sed -E 's/p?[0-9]+$//')"
  if [[ -f "/sys/block/$base_dev/queue/rotational" ]]; then
    rotational="$(cat "/sys/block/$base_dev/queue/rotational" 2>/dev/null)"
    if [[ "$base_dev" == nvme* ]]; then
      echo "NVMe SSD"
    elif [[ "$rotational" == "0" ]]; then
      echo "SSD"
    else
      echo "HDD (spinning)"
    fi
  else
    echo "unknown"
  fi
}

# ---------- Display ----------

# Prints one line per connected output, e.g. "eDP-1 144.00" — tries every
# available source since not all of these exist on every session type.
detect_refresh_rates() {
  local out=""

  # X11 — xrandr marks the active mode with '*'.
  if command -v xrandr >/dev/null 2>&1 && [[ "${XDG_SESSION_TYPE:-}" != "wayland" ]]; then
    out="$(xrandr --query 2>/dev/null | awk '
      /connected/ {name=$1}
      /\*/ {
        for (i=1;i<=NF;i++) if ($i ~ /\*/) {
          gsub(/[*+]/,"",$i); print name, $i
        }
      }')"
  fi

  # Hyprland — hyprctl is the reliable source here; Hyprland's wlr-output-
  # management support is partial/version-dependent, so don't rely on
  # wlr-randr first on this compositor specifically.
  if [[ -z "$out" ]] && command -v hyprctl >/dev/null 2>&1; then
    if command -v jq >/dev/null 2>&1; then
      out="$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | "\(.name) \(.refreshRate)"' 2>/dev/null)"
    else
      out="$(hyprctl monitors 2>/dev/null | awk '
        /^Monitor/ {name=$2}
        /@ /       {for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+$/) print name, $i}')"
    fi
  fi

  # Sway and other wlroots-based compositors that implement wlr-randr.
  # (Does NOT work on GNOME/KDE Wayland — those don't expose this protocol;
  # there's no universal CLI for them, so we're honest about "unknown" below
  # rather than guessing.)
  if [[ -z "$out" ]] && command -v wlr-randr >/dev/null 2>&1; then
    out="$(wlr-randr 2>/dev/null | awk '
      /^[A-Za-z]/ {name=$1}
      /current/ {
        for (i=1;i<=NF;i++) if ($i ~ /Hz/) { gsub(/Hz.*/,"",$i); print name, $i }
      }')"
  fi

  if [[ -z "$out" ]] && command -v swaymsg >/dev/null 2>&1; then
    out="$(swaymsg -t get_outputs 2>/dev/null | awk -F'[:,]' '
      /"name"/ {gsub(/[" ]/,"",$2); name=$2}
      /"refresh"/ {gsub(/[^0-9]/,"",$2); if ($2!="") print name, $2/1000}')"
  fi

  # Deliberately no resolution-based fallback here — a previous version of
  # this function fell back to /sys/class/drm/*/modes, which lists
  # supported *resolutions* (e.g. "1920x1080") with no refresh-rate field
  # at all. Parsing "1920" out of "1920x1080" and reporting it as Hz was a
  # real bug (a 1920x1080@60 panel would misreport as "1920 Hz"). Better to
  # say "unknown" than to fabricate a confident-looking wrong number.

  echo "$out" | sed '/^$/d'
}

detect_max_refresh_rate() {
  local rates hz max=0
  rates="$(detect_refresh_rates)"
  [[ -z "$rates" ]] && { echo "unknown"; return; }
  while IFS= read -r line; do
    hz="$(awk '{print $2}' <<< "$line" | grep -oE '^[0-9]+')"
    [[ -n "$hz" ]] && [[ "$hz" -gt "$max" ]] && max="$hz"
  done <<< "$rates"
  if [[ "$max" -eq 0 ]]; then echo "unknown"; else echo "${max} Hz"; fi
}

# ---------- Session / boot ----------

detect_session_type() {
  echo "${XDG_SESSION_TYPE:-unknown}"
}

detect_secure_boot() {
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null | head -n1 || echo "unknown"
  else
    echo "unknown (mokutil not installed)"
  fi
}

detect_kernel_version() {
  uname -r
}

# ---------- Report ----------

print_system_report() {
  local family gpus gpu_models cpu_vendor cpu_model cpu_cores session secureboot ram disk disktype refresh

  family="$(detect_distro_family)"
  gpus="$(detect_gpu_vendors)"
  gpu_models="$(detect_gpu_model_names)"
  cpu_vendor="$(detect_cpu_vendor)"
  cpu_model="$(detect_cpu_model)"
  cpu_cores="$(detect_cpu_cores)"
  session="$(detect_session_type)"
  secureboot="$(detect_secure_boot)"
  ram="$(detect_ram)"
  disk="$(detect_disk_free_root)"
  disktype="$(detect_disk_type)"
  refresh="$(detect_max_refresh_rate)"

  echo "=================================================="
  echo " System Report"
  echo "=================================================="
  printf "  %-18s %s\n" "Distro:" "$(distro_pretty_name)"
  printf "  %-18s %s\n" "Family:" "$family"
  printf "  %-18s %s\n" "Kernel:" "$(detect_kernel_version)"
  printf "  %-18s %s (%s cores)\n" "CPU:" "${cpu_model:-unknown}" "$cpu_cores"
  printf "  %-18s %s\n" "CPU vendor:" "$cpu_vendor"
  printf "  %-18s %s\n" "GPU(s) detected:" "$gpus"
  if [[ -n "$gpu_models" ]]; then
    while IFS= read -r line; do
      printf "  %-18s %s\n" "" "$line"
    done <<< "$gpu_models"
  fi
  if detect_hybrid_gpu; then
    printf "  %-18s %s\n" "Hybrid GPU:" "Yes (Optimus/PRIME-style laptop)"
  fi
  printf "  %-18s %s\n" "Max refresh rate:" "$refresh"
  printf "  %-18s %s\n" "Session type:" "$session"
  printf "  %-18s %s\n" "Secure Boot:" "$secureboot"
  printf "  %-18s %s\n" "RAM:" "$ram"
  printf "  %-18s %s\n" "Disk (/) type:" "$disktype"
  printf "  %-18s %s\n" "Free disk (/):" "$disk"
  echo "=================================================="

  if [[ "$family" == "unknown" ]]; then
    echo ""
    echo "WARNING: could not identify your distro family from /etc/os-release."
    echo "This tool supports Debian/Ubuntu, Fedora/Nobara, Arch/Manjaro, and openSUSE."
    echo "Continuing may not work correctly."
  fi

  if [[ "$gpus" == "unknown" ]]; then
    echo ""
    echo "WARNING: could not detect your GPU via lspci. Driver install will be skipped"
    echo "unless you pick one manually."
  fi

  if [[ "$secureboot" == *"enabled"* ]]; then
    echo ""
    echo "NOTE: Secure Boot is enabled. NVIDIA/AMD kernel modules (DKMS/akmods) may"
    echo "need to be signed, or you'll be prompted to enroll a MOK key on reboot."
  fi

  if detect_hybrid_gpu; then
    echo ""
    echo "NOTE: hybrid GPU laptop detected. drivers.sh will offer PRIME/Optimus"
    echo "setup so you can switch between integrated and discrete GPU per game."
  fi

  if [[ "$refresh" == "unknown" ]]; then
    if [[ "$session" == "wayland" ]]; then
      echo ""
      echo "NOTE: couldn't read refresh rate under Wayland. If you're on Hyprland,"
      echo "make sure 'hyprctl' is on PATH (it should be by default). On Sway,"
      echo "'swaymsg' should already work. GNOME/KDE Wayland don't expose a CLI"
      echo "for this, so 'unknown' there is expected, not a bug."
    fi
  else
    local hz_num="${refresh%% Hz}"
    if [[ "$hz_num" =~ ^[0-9]+$ ]] && [[ "$hz_num" -ge 120 ]]; then
      echo ""
      echo "NOTE: high refresh-rate display detected (${refresh}). MangoHud/Gamescope"
      echo "can cap frame rate to match it, avoiding wasted GPU work above the panel's limit."
    fi
  fi
}
