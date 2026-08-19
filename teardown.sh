#!/usr/bin/env bash
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VMWARE_NET_CONF="/etc/vmware/networking"

log()  { echo -e "\e[1;32m[+]\e[0m $1"; }
warn() { echo -e "\e[1;33m[!]\e[0m $1"; }
die()  { echo -e "\e[1;31m[x]\e[0m $1"; exit 1; }

VM_LIST=(
    "$LAB_ROOT/vms/pfsense/pfsense-fw.vmx"
    "$LAB_ROOT/vms/windows-server-2022/winserver-ad.vmx"
    "$LAB_ROOT/vms/windows-11/win11-workstation.vmx"
)

confirm() {
    read -rp "$1 [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

stop_vms() {
    log "Stopping running VMs..."
    for vmx in "${VM_LIST[@]}"; do
        if [ -f "$vmx" ]; then
            if vmrun list | grep -q "$vmx"; then
                log "Stopping: $vmx"
                vmrun -T ws stop "$vmx" hard 2>/dev/null || warn "$vmx could not be stopped."
            else
                warn "$vmx is not running, skipping."
            fi
        fi
    done
}

remove_vm_files() {
    log "Deleting VM files (vms/ folder)..."
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
    if confirm "Do you also want to revert VMnet2/VMnet3 network definitions from /etc/vmware/networking?"; then
        log "Reverting VMnet definitions..."
        sudo systemctl stop vmware-networks 2>/dev/null || sudo vmware-networks --stop || true

        if [ -f "$VMWARE_NET_CONF" ]; then
            sudo cp "$VMWARE_NET_CONF" "${VMWARE_NET_CONF}.bak.$(date +%s)"
            sudo sed -i '/VNET_2_/d; /VNET_3_/d' "$VMWARE_NET_CONF"
            log "VMnet2/VMnet3 lines deleted (backup: ${VMWARE_NET_CONF}.bak.*)"
        fi

        sudo systemctl start vmware-networks 2>/dev/null || sudo vmware-networks --start || true
        log "VMware network services restarted."
    else
        warn "Network settings preserved, skipping."
    fi
}

clean_ansible_inventory() {
    log "Resetting Ansible inventory file..."
    cat > "$LAB_ROOT/ansible/inventory/hosts.ini" <<EOF
[pfsense]

[ad_server]

[workstation]

[linux_hosts]
EOF
}

clean_downloaded_isos() {
    if confirm "Do you also want to delete the downloaded ISO files? (You will need to download them again for re-installation)"; then
        find "$LAB_ROOT/packer" -type f -iname "*.iso" -delete
        log "ISO files deleted."
    else
        warn "ISO files preserved."
    fi
}

main() {
    warn "=== SOC Lab Teardown ==="
    warn "This operation will stop all VMs and delete lab files."
    if ! confirm "Are you sure you want to proceed?"; then
        log "Operation cancelled."
        exit 0
    fi

    stop_vms
    remove_vm_files
    remove_packer_cache
    clean_ansible_inventory
    revert_vmnets
    clean_downloaded_isos

    log "Teardown completed. Lab is in a clean state, you can install again with './setup.sh'."
}

main "$@"
