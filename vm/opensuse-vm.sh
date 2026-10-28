#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Albert Yau (mwyau)
# License: MIT | https://github.com/community-scripts/DevScripts/raw/main/LICENSE
# Source: https://get.opensuse.org/

COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/DevScripts/main}"
source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/pve/vm-core.func")
load_functions

APP="openSUSE"
APP_TYPE="vm"
NSAPP="opensuse-vm"
var_os="opensuse"
var_version="16.0"
GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/../&:/g; s/:$//')
METHOD=""
THIN="discard=on,ssd=1,"
CLOUDINIT_REQUIRED=1
CLOUDINIT_DEFAULT_USER="${CLOUDINIT_DEFAULT_USER:-opensuse}"

set -Eeo pipefail
shopt -s inherit_errexit
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "130"' SIGINT
trap 'post_update_to_api "failed" "143"' SIGTERM
trap 'post_update_to_api "failed" "129"; exit 129' SIGHUP

vm_require_arch amd64
TEMP_DIR=$(mktemp -d)
pushd "$TEMP_DIR" >/dev/null
vm_preflight
vm_require_tools virt-customize

function select_os() {
  if [[ -n "${1:-}" ]]; then
    var_version="$1"
  elif [[ "${VM_UNATTENDED:-0}" == "1" ]]; then
    var_version="${VM_OS_VERSION:-$var_version}"
  elif vm_dialog radiolist "OPENSUSE VERSION" "Choose the openSUSE edition" --cancel-button Exit-Script 14 72 3 \
    "16.0" "Leap 16.0 (stable)" ON \
    "16.1" "Leap 16.1" OFF \
    "tumbleweed" "Tumbleweed (rolling)" OFF; then
    var_version="$VM_DIALOG_RESULT"
  else
    exit_script
  fi

  case "$var_version" in
    16.0 | 16.1) APP="openSUSE Leap $var_version" ;;
    tumbleweed) APP="openSUSE Tumbleweed" ;;
    *) msg_error "Unsupported openSUSE version '$var_version'"; exit 1 ;;
  esac
}

function default_settings() {
  select_os "${VM_OS_VERSION:-}"
  VMID=$(get_valid_nextid)
  vm_apply_machine_type "q35"
  DISK_SIZE="16G"
  DISK_CACHE=""
  HN="opensuse"
  CPU_TYPE=" -cpu host"
  CORE_COUNT="2"
  RAM_SIZE="2048"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  METHOD="default"
  vm_echo_default_settings
}

function advanced_settings() {
  METHOD="advanced"
  select_os
  vm_prompt_vmid "${VMID:-$(get_valid_nextid)}"
  vm_prompt_machine_type "q35"
  vm_prompt_disk_size "16G" "Set Disk Size in GiB (minimum 16 recommended)"
  vm_prompt_disk_cache "none"
  vm_prompt_hostname "opensuse"
  vm_prompt_cpu_model "host"
  vm_prompt_cpu_cores "2"
  vm_prompt_ram "2048"
  vm_prompt_bridge "vmbr0"
  vm_prompt_mac "$GEN_MAC"
  vm_prompt_vlan
  vm_prompt_mtu
  vm_prompt_keyboard
  vm_prompt_verbose "no"
  vm_prompt_start_vm "yes"

  if vm_confirm_advanced_settings "Ready to create an openSUSE VM?"; then
    echo -e "${CREATING}${BOLD}${DGN}Creating an openSUSE VM using advanced settings${CL}"
  else
    header_info
    advanced_settings
  fi
}

header_info
vm_start_script "Use Default Settings?\n\nDefaults:\n• Leap 16.0\n• 2 CPU Cores\n• 2 GB RAM\n• 16 GB Disk\n• Cloud-Init required" 15 62
VM_CLOUD_INIT="${VM_CLOUD_INIT:-yes}"
vm_prompt_cloud_init "opensuse"
if [[ "$USE_CLOUD_INIT" != "yes" ]]; then
  msg_error "The openSUSE cloud image needs Cloud-Init to configure initial access."
  exit 1
fi
post_to_api_vm
vm_select_storage "$HN"
vm_define_disk_references 2

case "$var_version" in
  16.0 | 16.1)
    URL="https://download.opensuse.org/distribution/leap/${var_version}/appliances/Leap-${var_version}-Minimal-VM.x86_64-Cloud.qcow2"
    ;;
  tumbleweed)
    URL="https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2"
    ;;
esac

# The unversioned build aliases are refreshed upstream. Use their current
# SHA-256 checksums so vm_fetch_image can recheck and replace stale caches.
msg_info "Fetching the openSUSE image checksum"
if ! SHA256=$(curl -fsSL --retry 3 "${URL}.sha256" | grep -oE '[a-fA-F0-9]{64}' | head -n 1); then
  msg_error "Could not retrieve the openSUSE image checksum"
  exit 115
fi
if [[ ! "$SHA256" =~ ^[a-fA-F0-9]{64}$ ]]; then
  msg_error "Could not verify the openSUSE cloud image checksum"
  exit 115
fi
CACHE_FILE="$(vm_image_cache_path "$URL")"
vm_fetch_image "$URL" "$CACHE_FILE" --cache --sha256 "$SHA256" --min-bytes $((100 * 1024 * 1024)) || exit 115

FILE="$(basename "$URL")"
cp "$CACHE_FILE" "$FILE"
if ! vm_prepare_cloud_image "$FILE" "$HN"; then
  msg_warn "Image preparation unavailable; importing the cloud image without host customizations"
fi

vm_claim_vmid
msg_info "Creating an openSUSE VM"
qm create "$VMID" -agent 1${MACHINE} -tablet 0 -bios ovmf${CPU_TYPE} -cores "$CORE_COUNT" -memory "$RAM_SIZE" \
  -name "$HN" -tags community-script -net0 virtio,bridge="$BRG",macaddr="$MAC"${VLAN}${MTU} -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
vm_mark_created
vm_alloc_efi_disk "$DISK0"
vm_import_disk "$VMID" "$FILE" "$STORAGE" "$DISK_IMPORT_FORMAT"
qm set "$VMID" \
  -efidisk0 "${DISK0_REF}${FORMAT}" \
  -scsi0 "${VM_IMPORTED_DISK},${DISK_CACHE}${THIN}size=${DISK_SIZE}" \
  -boot order=scsi0 \
  -serial0 socket >/dev/null
set_description
popd >/dev/null
rm -rf "$TEMP_DIR"

vm_resize_disk
vm_provision "$VMID" || {
  msg_error "Cloud-Init provisioning failed; do not start an inaccessible guest."
  exit 1
}
if [[ "${CLOUDINIT_NETWORK_MODE:-dhcp}" == "static" ]]; then
  setup_cloud_init_network_no_rename \
    "$VMID" "$MAC" "$CLOUDINIT_IP" "$CLOUDINIT_GW" \
    "${CLOUDINIT_DNS:-${CLOUDINIT_DNS_SERVERS:-1.1.1.1 8.8.8.8}}" \
    "${CLOUDINIT_SEARCH_DOMAIN:-local}"
fi

msg_ok "Created an openSUSE VM"
vm_start_vm "$APP"
vm_wait_for_ip 120 || true
if declare -f display_cloud_init_info >/dev/null 2>&1; then
  display_cloud_init_info "$VMID" "$HN"
fi
vm_print_summary "openSUSE Edition=${var_version}" "Cloud-Init=yes"
vm_finish
