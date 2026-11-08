#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# SOC Lab Orchestrator - Fedora / Linux Host
# Requires: VMware Workstation Pro (Linux), Packer, vmrun, ansible
# =========================================================

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$LAB_ROOT/.env"

# Default IPs & SSH users for DMZ / LAN additions (can be overridden in .env)
AD_IP="${AD_IP:-192.168.10.10}"
WIN11_IP="${WIN11_IP:-192.168.10.11}"
WAZUH_IP="${WAZUH_IP:-192.168.20.10}"
WAZUH_SSH_USER="${WAZUH_SSH_USER:-labadmin}"
KALI_IP="${KALI_IP:-192.168.10.20}"
KALI_SSH_USER="${KALI_SSH_USER:-kali}"
LAN_GW="${LAN_GW:-192.168.10.254}"
DMZ_GW="${DMZ_GW:-192.168.20.254}"

export ANSIBLE_CONFIG="$LAB_ROOT/ansible/ansible.cfg"
export ANSIBLE_HOST_KEY_CHECKING=False

log()  { echo -e "\e[1;32m[+]\e[0m $1" >&2; }
warn() { echo -e "\e[1;33m[!]\e[0m $1" >&2; }
die()  { echo -e "\e[1;31m[x]\e[0m $1" >&2; exit 1; }

load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        die ".env file not found. Create and configure it with 'cp .env.example .env'."
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    AD_IP="${AD_IP:-192.168.10.10}"
    WIN11_IP="${WIN11_IP:-192.168.10.11}"
    WAZUH_IP="${WAZUH_IP:-192.168.20.10}"
    WAZUH_SSH_USER="${WAZUH_SSH_USER:-labadmin}"
    KALI_IP="${KALI_IP:-192.168.10.20}"
    KALI_SSH_USER="${KALI_SSH_USER:-kali}"
    LAN_GW="${LAN_GW:-192.168.10.254}"
    DMZ_GW="${DMZ_GW:-192.168.20.254}"
    log ".env loaded (LAN_VMNET=$LAN_VMNET, DMZ_VMNET=$DMZ_VMNET, AD_IP=$AD_IP, WIN11_IP=$WIN11_IP, WAZUH_IP=$WAZUH_IP)"
}

check_dependencies() {
    log "Checking required tools..."
    command -v vmrun >/dev/null 2>&1 || die "vmrun not found. Is VMware Workstation installed? (usually /usr/bin/vmrun)"
    command -v packer >/dev/null 2>&1 || die "packer not found. https://developer.hashicorp.com/packer/install"
    command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook not found. Install with: 'sudo dnf install ansible'."
    ansible-galaxy collection install -r "$LAB_ROOT/ansible/requirements.yml" >/dev/null 2>&1 || warn "Ansible collections could not be installed."
    [ -f /etc/vmware/networking ] || die "/etc/vmware/networking not found, VMware may not be installed correctly."
    log "Dependencies met."
}

check_isos() {
    log "Checking ISO files..."
    local missing=0

    if ! find "$LAB_ROOT/packer/wazuh/iso" -iname "*.iso" 2>/dev/null | grep -q .; then
        warn "Ubuntu Server (Wazuh) ISO not found -> place it in packer/wazuh/iso/."
        missing=1
    fi
    if find "$LAB_ROOT/packer/pfsense/iso" -iname "*.gz" 2>/dev/null | grep -q .; then
        warn "pfSense .iso.gz found but not decompressed! First: gunzip packer/pfsense/iso/*.gz"
        missing=1
    fi
    if ! find "$LAB_ROOT/packer/pfsense/iso" -iname "*.iso" 2>/dev/null | grep -q .; then
        warn "pfSense CE ISO not found -> place it in packer/pfsense/iso/ and gunzip it."
        missing=1
    fi
    if ! find "$LAB_ROOT/packer/windows-server-2022/iso" -iname "*.iso" 2>/dev/null | grep -q .; then
        warn "Windows Server ISO not found -> place it in packer/windows-server-2022/iso/."
        missing=1
    fi
    if ! find "$LAB_ROOT/packer/windows-11/iso" -iname "*.iso" 2>/dev/null | grep -q .; then
        warn "Windows 11 ISO not found -> place it in packer/windows-11/iso/."
        missing=1
    fi

    [ "$missing" -eq 1 ] && die "Some ISO files are missing, follow the warnings above."
    log "All ISO files are present."
}

configure_vmnets() {
    local net_conf="/etc/vmware/networking"
    log "Configuring VMnet networks ($LAN_VMNET=LAN, $DMZ_VMNET=DMZ)..."

    sudo systemctl stop vmware-networks 2>/dev/null || sudo vmware-networks --stop 2>/dev/null || warn "VMware network service may already be stopped."

    # Host adapter takes .1 automatically; .254 is reserved for pfSense LAN/DMZ gateways
    if ! grep -q "VNET_2_HOSTONLY_SUBNET" "$net_conf" 2>/dev/null; then
        sudo tee -a "$net_conf" >/dev/null <<EOF
answer VNET_2_DHCP no
answer VNET_2_HOSTONLY_NETMASK ${LAN_NETMASK}
answer VNET_2_HOSTONLY_SUBNET ${LAN_SUBNET}
answer VNET_2_VIRTUAL_ADAPTER yes
answer VNET_2_HOSTONLY_HOSTADDR 192.168.10.1

answer VNET_3_DHCP no
answer VNET_3_HOSTONLY_NETMASK ${DMZ_NETMASK}
answer VNET_3_HOSTONLY_SUBNET ${DMZ_SUBNET}
answer VNET_3_VIRTUAL_ADAPTER yes
answer VNET_3_HOSTONLY_HOSTADDR 192.168.20.1
EOF
        log "VMnet2 (LAN) and VMnet3 (DMZ) definitions added."
    else
        # If previously set to .254 in /etc/vmware/networking, update to .1 so it doesn't collide with pfSense
        sudo sed -i 's/VNET_2_HOSTONLY_HOSTADDR 192\.168\.10\.254/VNET_2_HOSTONLY_HOSTADDR 192.168.10.1/' "$net_conf" 2>/dev/null || true
        sudo sed -i 's/VNET_3_HOSTONLY_HOSTADDR 192\.168\.20\.254/VNET_3_HOSTONLY_HOSTADDR 192.168.20.1/' "$net_conf" 2>/dev/null || true
        log "VMnet definitions verified."
    fi

    sudo systemctl start vmware-networks 2>/dev/null || sudo vmware-networks --start || warn "Network service could not be started, manual check might be required (see README Troubleshooting)."
    log "VMware network services restarted."
}

build_images() {
    local target="$1"
    log "Starting Packer build: $target"
    pushd "$LAB_ROOT/packer/$target" >/dev/null
    packer init . || warn "packer init might fail."
    if [[ "$target" == *"windows"* ]]; then
        packer build \
            -var "winrm_password=${WINRM_PASSWORD}" \
            -var "ad_ip=${AD_IP}" \
            -var "lan_gw=${LAN_GW}" \
            -var "lan_vmnet=${LAN_VMNET}" \
            -var "dmz_vmnet=${DMZ_VMNET}" \
            . || die "Packer build failed: $target"
    elif [[ "$target" == "wazuh" ]]; then
        local ubuntu_iso
        ubuntu_iso=$(find ./iso -iname "*.iso" | head -n1)
        packer build \
            -var "iso_url=${ubuntu_iso}" \
            -var "ssh_username=${WAZUH_SSH_USER}" \
            -var "ssh_password=${LABADMIN_PASSWORD}" \
            -var "wazuh_ip=${WAZUH_IP}" \
            -var "dmz_gw=${DMZ_GW}" \
            . || die "Packer build failed: $target"
    else
        packer build \
            -var "lan_vmnet=${LAN_VMNET}" \
            -var "dmz_vmnet=${DMZ_VMNET}" \
            . || die "Packer build failed: $target"
    fi
    popd >/dev/null
}

detach_vm_isos() {
    local vmx_path="$1"
    [ -f "$vmx_path" ] || return 0
    sed -i 's/^\(ide[0-9]:[0-9]\.startConnected\s*=\s*\).*/\1"FALSE"/I' "$vmx_path"
    sed -i 's/^\(sata[0-9]:[0-9]\.startConnected\s*=\s*\).*/\1"FALSE"/I' "$vmx_path"
}

wait_for_pfsense() {
    log "Waiting for pfSense LAN gateway (${LAN_GW}:443 / :22) to become ready..." >&2
    local max_attempts=30
    for attempt in $(seq 1 "$max_attempts"); do
        if timeout 2 bash -c "</dev/tcp/${LAN_GW}/443" 2>/dev/null || timeout 2 bash -c "</dev/tcp/${LAN_GW}/22" 2>/dev/null; then
            log "pfSense is up and reachable at https://${LAN_GW}!" >&2
            return 0
        fi
        sleep 4
    done
    warn "pfSense (${LAN_GW}) did not respond on port 443/22 within timeout; continuing anyway." >&2
}

start_vm() {
    local vmx_path="$1"
    [ -f "$vmx_path" ] || die "VMX file not found: $vmx_path (Packer build may have failed)"
    log "Starting VM (in VMware GUI): $vmx_path"
    vmrun -T ws start "$vmx_path" gui
    sleep 5
}

setup_wazuh_vm() {
    local wazuh_vmx="$LAB_ROOT/vms/wazuh-siem/wazuh-siem.vmx"
    log "=== 4/4 Wazuh SIEM (Ubuntu Server, DMZ ${WAZUH_IP}) build & start ===" >&2

    if [ ! -f "$wazuh_vmx" ]; then
        build_images "wazuh"
    else
        log "Wazuh Ubuntu VM already exists, skipping Packer build step." >&2
    fi

    # Detach installer & cidata CD-ROMs and switch NIC from NAT to DMZ (vmnet3)
    detach_vm_isos "$wazuh_vmx"
    sed -i 's/ethernet0.connectiontype = "nat"/ethernet0.connectionType = "custom"/I' "$wazuh_vmx"
    if grep -q "ethernet0.vnet" "$wazuh_vmx"; then
        sed -i "s/ethernet0.vnet = .*/ethernet0.vnet = \"${DMZ_VMNET}\"/" "$wazuh_vmx"
    else
        echo "ethernet0.vnet = \"${DMZ_VMNET}\"" >> "$wazuh_vmx"
    fi

    start_vm "$wazuh_vmx"

    log "Waiting for Wazuh Ubuntu Server SSH (${WAZUH_IP}:22) on DMZ..." >&2
    local max_attempts=30
    for attempt in $(seq 1 "$max_attempts"); do
        if timeout 2 bash -c "</dev/tcp/${WAZUH_IP}/22" 2>/dev/null; then
            log "Wazuh Ubuntu Server SSH is reachable at ${WAZUH_IP}!" >&2
            return 0
        fi
        sleep 5
    done

    warn "Wazuh SSH (${WAZUH_IP}:22) did not become reachable in time; check VM network settings." >&2
}

run_ansible() {
    local playbook="$1"
    log "Running Ansible: $playbook" >&2
    ansible-playbook -i "$LAB_ROOT/ansible/inventory/hosts.ini" \
        "$LAB_ROOT/ansible/playbooks/$playbook" \
        --extra-vars "domain_name=${DOMAIN_NAME} netbios_name=${NETBIOS_NAME} safe_mode_password=${SAFE_MODE_PASSWORD} winrm_password=${WINRM_PASSWORD} labadmin_password=${LABADMIN_PASSWORD} lan_gw=${LAN_GW} dmz_gw=${DMZ_GW} wazuh_ip=${WAZUH_IP} wazuh_ssh_user=${WAZUH_SSH_USER} kali_ip=${KALI_IP}"
}

main() {
    if [ -x "$LAB_ROOT/check_prereqs.sh" ]; then
        log "Running pre-check (check_prereqs.sh)..." >&2
        if ! "$LAB_ROOT/check_prereqs.sh"; then
            die "Pre-check failed. Fix the [FAIL] lines above and try again."
        fi
        echo ""
    fi

    load_env
    check_dependencies
    check_isos
    configure_vmnets

    log "=== 1/4 pfSense automated build & start ===" >&2
    local pfsense_vmx="$LAB_ROOT/vms/pfsense/pfsense-fw.vmx"
    if [ ! -f "$pfsense_vmx" ]; then
        build_images "pfsense"
    else
        log "pfSense VM already exists, skipping build step." >&2
    fi
    detach_vm_isos "$pfsense_vmx"
    start_vm "$pfsense_vmx"
    wait_for_pfsense

    log "=== 2/4 Windows Server (AD) build & start ===" >&2
    local ws_vmx="$LAB_ROOT/vms/windows-server-2022/winserver-ad.vmx"
    if [ ! -f "$ws_vmx" ]; then
        build_images "windows-server-2022"
    else
        log "Windows Server VM already exists, skipping build step." >&2
    fi

    log "Setting Windows Server network interface to ${LAN_VMNET}..." >&2
    detach_vm_isos "$ws_vmx"
    sed -i 's/ethernet0.connectiontype = "nat"/ethernet0.connectionType = "custom"/I' "$ws_vmx"
    if grep -q "ethernet0.vnet" "$ws_vmx"; then
        sed -i "s/ethernet0.vnet = .*/ethernet0.vnet = \"${LAN_VMNET}\"/" "$ws_vmx"
    else
        echo "ethernet0.vnet = \"${LAN_VMNET}\"" >> "$ws_vmx"
    fi

    start_vm "$ws_vmx"

    log "=== 3/4 Windows 11 Workstation build & start ===" >&2
    local w11_vmx="$LAB_ROOT/vms/windows-11/win11-workstation.vmx"
    if [ ! -f "$w11_vmx" ]; then
        log "Packer disabled! The VM is being created directly via Bash (create-win11-vm.sh)..." >&2
        bash "$LAB_ROOT/network/create-win11-vm.sh" --force
    else
        log "Windows 11 VM already exists; skipping creation step." >&2
    fi
    start_vm "$w11_vmx"
    log "ATTENTION: If you see 'Press any key...' on the screen, immediately click on the virtual machine and press the Spacebar!" >&2

    setup_wazuh_vm

    local FOUND_AD_IP="${AD_IP}"
    local FOUND_WS_IP="${WIN11_IP}"

    log "Waiting for Windows Server WinRM (${FOUND_AD_IP}:5985) and Windows 11 WinRM (${FOUND_WS_IP}:5985)..." >&2
    for target_ip in "$FOUND_AD_IP" "$FOUND_WS_IP"; do
        local reachable=0
        for attempt in $(seq 1 90); do
            if timeout 2 bash -c "</dev/tcp/${target_ip}/5985" 2>/dev/null; then
                log "WinRM is reachable at ${target_ip}:5985!" >&2
                reachable=1
                break
            fi
            sleep 10
        done
        if [ "$reachable" -eq 0 ]; then
            die "Timeout waiting for WinRM on ${target_ip}:5985. Ensure the VM booted properly and static IP is applied."
        fi
    done

    log "AD Server Ready: $FOUND_AD_IP" >&2
    log "Workstation Ready: $FOUND_WS_IP" >&2

    log "Updating Ansible inventory..." >&2
    cat > "$LAB_ROOT/ansible/inventory/hosts.ini" <<EOF
[ad_server]
$FOUND_AD_IP ansible_user=Administrator ansible_password=${WINRM_PASSWORD} ansible_connection=winrm ansible_winrm_transport=basic ansible_winrm_server_cert_validation=ignore ansible_port=5985

[workstation]
$FOUND_WS_IP ansible_user=Admin ansible_password=${WINRM_PASSWORD} ansible_connection=winrm ansible_winrm_transport=basic ansible_winrm_server_cert_validation=ignore ansible_port=5985

[wazuh_server]
${WAZUH_IP} ansible_user=${WAZUH_SSH_USER} ansible_password=${LABADMIN_PASSWORD} ansible_connection=ssh ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" ansible_become=true ansible_become_password=${LABADMIN_PASSWORD} ansible_python_interpreter=/usr/bin/python3

[kali_attacker]
${KALI_IP} ansible_user=${KALI_SSH_USER} ansible_password=${LABADMIN_PASSWORD} ansible_connection=ssh ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

[domain_hosts:children]
ad_server
workstation
EOF

    log "Performing Ansible connection check..." >&2
    ansible ad_server -m win_ping -i "$LAB_ROOT/ansible/inventory/hosts.ini" --user Administrator --extra-vars "ansible_password=${WINRM_PASSWORD}" || die "Ansible connection to AD Server failed!"
    ansible workstation -m win_ping -i "$LAB_ROOT/ansible/inventory/hosts.ini" --user Admin --extra-vars "ansible_password=${WINRM_PASSWORD}" -e "ansible_winrm_read_timeout=900 ansible_winrm_operation_timeout=600" -T 300 || die "Ansible connection to Workstation failed!"
    log "Windows Ansible connections successful." >&2

    if ! ansible wazuh_server -m ping -i "$LAB_ROOT/ansible/inventory/hosts.ini"; then
        warn "SSH connection to Wazuh Ubuntu Server (${WAZUH_IP}) failed; 07-wazuh.yml may fail. Ensure sshpass is installed on Fedora and SSH is enabled on Ubuntu." >&2
    else
        log "SSH connection to Wazuh Ubuntu Server successful." >&2
    fi

    log "Executing Ansible playbooks..." >&2
    run_ansible "02-ad-domain.yml"
    run_ansible "03-badblood.yml"
    run_ansible "04-workstation-join.yml"
    run_ansible "05-sysmon.yml"
    run_ansible "06-crowdsec.yml"
    run_ansible "07-wazuh.yml"

    log "=== Verification Commands ===" >&2
    ansible domain_hosts -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_shell -a "Get-Service sysmon64, crowdsec, WazuhSvc | Select-Object Status, Name"
    ansible workstation -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_shell -a "(Get-WmiObject Win32_ComputerSystem).Domain"
    ansible ad_server -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_shell -a "(Get-ADUser -Filter *).Count"

    log "=========================================================" >&2
    log "The SOC Lab setup has been completed flawlessly!" >&2
    log "pfSense WebGUI : https://${LAN_GW}" >&2
    log "Wazuh Dashboard: https://${WAZUH_IP}" >&2
    log "=========================================================" >&2
}
main "$@"
