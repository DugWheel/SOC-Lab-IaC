#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# SOC Lab Teardown Script
# Stops all lab VMs, cleans generated VM files & Packer caches,
# resets Ansible inventory, and optionally reverts VMnet / ISOs.
# =========================================================

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMWARE_NET_CONF="/etc/vmware/networking"

log()  { echo -e "\e[1;32m[+]\e[0m $1"; }
warn() { echo -e "\e[1;33m[!]\e[0m $1"; }
die()  { echo -e "\e[1;31m[x]\e[0m $1"; exit 1; }

VM_LIST=(
    "$LAB_ROOT/vms/pfsense/pfsense-fw.vmx"
    "$LAB_ROOT/vms/windows-server-2022/winserver-ad.vmx"
    "$LAB_ROOT/vms/windows-11/win11-workstation.vmx"
    "$LAB_ROOT/vms/wazuh-siem/wazuh-siem.vmx"
)

confirm() {
    read -r -p "$1 [y/N]: " ans
    [[ "${ans:-}" =~ ^[Yy]$ ]]
}

stop_vms() {
    log "Stopping running VMs..."
    for vmx in "${VM_LIST[@]}"; do
        if [ -f "$vmx" ]; then
            if vmrun list 2>/dev/null | grep -q "$vmx"; then
                log "Stopping: $vmx"
                vmrun -T ws stop "$vmx" hard 2>/dev/null || warn "Could not stop: $vmx"
            else
                warn "Already stopped: $vmx"
            fi
        else
            warn "VMX file not found, skipping: $vmx"
        fi
    done
}

remove_vm_files() {
    log "Deleting generated VM files (vms/ folder)..."
    if [ -d "$LAB_ROOT/vms" ]; then
        rm -rf "${LAB_ROOT:?}/vms"/*
        log "vms/ folder cleaned."
    else
        warn "vms/ folder does not exist."
    fi
}

remove_packer_cache() {
    log "Cleaning Packer cache and output folders..."
    find "$LAB_ROOT/packer" -type d -name "output-*" -exec rm -rf {} + 2>/dev/null || true
    find "$LAB_ROOT/packer" -type d -name ".packer_cache" -exec rm -rf {} + 2>/dev/null || true
}

revert_vmnets() {
    if confirm "Do you also want to remove VMnet2/VMnet3 definitions from /etc/vmware/networking?"; then
        log "Reverting VMnet definitions..."
        sudo systemctl stop vmware-networks 2>/dev/null || sudo vmware-networks --stop 2>/dev/null || true

        if [ -f "$VMWARE_NET_CONF" ]; then
            sudo cp "$VMWARE_NET_CONF" "${VMWARE_NET_CONF}.bak.$(date +%s)"
            sudo sed -i '/VNET_2_/d; /VNET_3_/d' "$VMWARE_NET_CONF"
            log "VMnet2 and VMnet3 lines removed (backup created)."
        fi

        sudo systemctl start vmware-networks 2>/dev/null || sudo vmware-networks --start 2>/dev/null || true
        log "VMware network service restarted."
    else
        warn "Network settings preserved."
    fi
}

clean_ansible_inventory() {
    log "Resetting Ansible inventory to template state..."
    cat > "$LAB_ROOT/ansible/inventory/hosts.ini" <<'EOF'
[ad_server]

[workstation]

[wazuh_server]

[kali_attacker]

[domain_hosts:children]
ad_server
workstation
EOF
}

clean_downloaded_isos() {
    if confirm "Do you also want to delete the downloaded ISO files? (You will have to download them again)"; then
        find "$LAB_ROOT/packer" -type f -iname "*.iso" -delete
        log "ISO files deleted."
    else
        warn "ISO files preserved."
    fi
}

main() {
    warn "=== SOC Lab Teardown ==="
    warn "This operation will stop all VMs and delete generated files!"
    if ! confirm "Are you sure you want to proceed?"; then
        log "Cancelled."
        exit 0
    fi

    stop_vms
    remove_vm_files
    remove_packer_cache
    clean_ansible_inventory
    revert_vmnets
    clean_downloaded_isos

    log "Teardown completed. You can run './setup.sh' for a fresh installation."
}

main "$@"
