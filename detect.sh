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
  local family gpus gpu_models cpu_vendor cpu_model cpu_cores session secureboot ram disk disktype hybrid

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
}
