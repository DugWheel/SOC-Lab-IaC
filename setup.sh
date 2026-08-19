#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# SOC Lab Orchestrator - Fedora KDE / Linux Host
# Requires: VMware Workstation Pro (Linux), Packer, vmrun, ansible
# =========================================================

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$LAB_ROOT/.env"

log()  { echo -e "\e[1;32m[+]\e[0m $1" >&2; }
warn() { echo -e "\e[1;33m[!]\e[0m $1" >&2; }
die()  { echo -e "\e[1;31m[x]\e[0m $1" >&2; exit 1; }

load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        die ".env file not found. Create and configure it with 'cp .env.example .env'."
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    log ".env loaded (LAN_VMNET=$LAN_VMNET, DMZ_VMNET=$DMZ_VMNET)"
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

    if find "$LAB_ROOT/packer/pfsense/iso" -iname "*.gz" 2>/dev/null | grep -q .; then
        warn "pfSense .iso.gz found but not decompressed! First: gunzip packer/pfsense/iso/*.gz"
        missing=1
    fi
    if ! find "$LAB_ROOT/packer/pfsense/iso" -iname "*.iso" 2>/dev/null | grep -q .; then
        warn "pfSense (Netgate Installer) ISO not found -> place it in packer/pfsense/iso/ and gunzip it."
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

    if ! grep -q "VNET_2_HOSTONLY_SUBNET" "$net_conf" 2>/dev/null; then
        sudo tee -a "$net_conf" >/dev/null <<EOF
answer VNET_2_DHCP no
answer VNET_2_HOSTONLY_NETMASK ${LAN_NETMASK}
answer VNET_2_HOSTONLY_SUBNET ${LAN_SUBNET}
answer VNET_2_VIRTUAL_ADAPTER yes
answer VNET_2_HOSTONLY_HOSTADDR 192.168.10.254

answer VNET_3_DHCP no
answer VNET_3_HOSTONLY_NETMASK ${DMZ_NETMASK}
answer VNET_3_HOSTONLY_SUBNET ${DMZ_SUBNET}
answer VNET_3_VIRTUAL_ADAPTER yes
answer VNET_3_HOSTONLY_HOSTADDR 192.168.20.254
EOF
        log "VMnet2 (LAN) and VMnet3 (DMZ) definitions added."
    else
        warn "VMnet definitions already exist, skipping."
    fi

    sudo systemctl start vmware-networks 2>/dev/null || sudo vmware-networks --start || warn "Network service could not be started, manual check might be required (see README Troubleshooting)."
    log "VMware network services restarted."

    log "Forcing host machine's vmnet2 and vmnet3 IPs to .254..." >&2
    sudo ip addr add 192.168.10.254/24 dev vmnet2 2>/dev/null || true
    sudo ip addr del 192.168.10.1/24 dev vmnet2 2>/dev/null || true
    
    sudo ip addr add 192.168.20.254/24 dev vmnet3 2>/dev/null || true
    sudo ip addr del 192.168.20.1/24 dev vmnet3 2>/dev/null || true
}

build_images() {
    local target="$1"
    log "Starting Packer build: $target"
    pushd "$LAB_ROOT/packer/$target" >/dev/null
    packer init . || warn "packer init might fail."
    # Send password ONLY to Windows machines, not to pfSense
    if [[ "$target" == *"windows"* ]]; then
        packer build \
            -var "winrm_password=${WINRM_PASSWORD}" \
            -var "lan_vmnet=${LAN_VMNET}" \
            -var "dmz_vmnet=${DMZ_VMNET}" \
            . || die "Packer build failed: $target"
    else
        # Build pfSense without password variable
        packer build \
            -var "lan_vmnet=${LAN_VMNET}" \
            -var "dmz_vmnet=${DMZ_VMNET}" \
            . || die "Packer build failed: $target"
    fi
    popd >/dev/null
}

start_vm() {
    local vmx_path="$1"
    [ -f "$vmx_path" ] || die "VMX file not found: $vmx_path (Packer build may have failed)"
    log "Starting VM (in VMware GUI): $vmx_path"
    
    
    vmrun -T ws start "$vmx_path" gui
    sleep 5
}

get_hostname_via_winrm() {
    local ip="$1"
    local username="$2"
    local password="$3"
    
    python3 - << 'EOF' "$ip" "$username" "$password"
import winrm
import sys

ip = sys.argv[1]
username = sys.argv[2]
password = sys.argv[3]

try:
    session = winrm.Session(f'http://{ip}:5985/wsman', auth=(username, password), transport='basic', server_cert_validation='ignore')
    r = session.run_cmd('hostname')
    if r.status_code == 0:
        print(r.std_out.decode().strip())
    else:
        print(f"Error getting hostname for {ip}: {r.std_err.decode().strip()}", file=sys.stderr)
        sys.exit(1)
except winrm.exceptions.WinRMOperationTimeoutError:
    print(f"WinRM operation timed out for {ip}.", file=sys.stderr)
    sys.exit(1)
except winrm.exceptions.WinRMTransportError as e:
    print(f"WinRM transport error for {ip}: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Unexpected WinRM error for {ip}: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

find_all_winrm_ips() {
    local found_ips=()
    local max_attempts=60
    local wait_interval=15
    
    log "Searching for machines with open WinRM on 192.168.10.x network (max ${max_attempts} attempts, each ${wait_interval} seconds)..." >&2
    
    for attempt in $(seq 1 $max_attempts); do
        log "Attempt $attempt/$max_attempts..." >&2
        local current_round_ips=()
        
        for i in {10..50}; do
            local test_ip="192.168.10.$i"
            if timeout 1 bash -c "</dev/tcp/$test_ip/5985" 2>/dev/null; then
                current_round_ips+=("$test_ip")
                if ! printf '%s\n' "${found_ips[@]}" | grep -q -w "$test_ip"; then
                    log "New WinRM IP address found: $test_ip" >&2
                    found_ips+=("$test_ip")
                fi
            fi
        done
        
        if [ "${#found_ips[@]}" -ge 2 ]; then
            log "Found at least two WinRM IP addresses, stopping search." >&2
            printf '%s\n' "${found_ips[@]}" | sort -V
            return 0
        fi
        
        sleep $wait_interval
    done
    
    if [ "${#found_ips[@]}" -eq 0 ]; then
        die "No machine with open WinRM found on the network (Timeout)."
    elif [ "${#found_ips[@]}" -eq 1 ]; then
        warn "Only one machine with open WinRM found. Waiting for the other one to start or WinRM to be ready." >&2
        printf '%s\n' "${found_ips[@]}" | sort -V
        return 0
    fi

    die "Required number of machines with open WinRM not found (Timeout)."
}

run_ansible() {
    local playbook="$1"
    log "Running Ansible: $playbook" >&2
    ansible-playbook -i "$LAB_ROOT/ansible/inventory/hosts.ini" \
        "$LAB_ROOT/ansible/playbooks/$playbook" \
        --extra-vars "domain_name=${DOMAIN_NAME} netbios_name=${NETBIOS_NAME} safe_mode_password=${SAFE_MODE_PASSWORD} winrm_password=${WINRM_PASSWORD} labadmin_password=${LABADMIN_PASSWORD} lan_gw=${LAN_GW}"
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

    log "=== 1/3 pfSense build & start ===" >&2
    if [ ! -f "$LAB_ROOT/vms/pfsense/pfsense-fw.vmx" ]; then
        build_images "pfsense"
    else
        log "pfSense VM already exists, skipping build step." >&2
    fi
    start_vm "$LAB_ROOT/vms/pfsense/pfsense-fw.vmx"
    sleep 60
    
    log "=========================================================" >&2
    log "=== PAUSE POINT: pfSense Configuration ===" >&2
    log "=========================================================" >&2
    log "Machines are up, but for Windows machines to access the internet," >&2
    log "pfSense rules (XML) must be loaded." >&2
    log "" >&2
    log "Please complete the following steps:" >&2
    log "1. Log in to the pfSense interface from your browser (e.g., https://192.168.10.1)." >&2
    log "2. Go to the Diagnostics -> Backup & Restore tab." >&2
    log "3. Upload (Restore) the 'pfsense-lab-config.xml' file from the project folder." >&2
    log "4. Wait 1-2 minutes for pfSense to restart and network rules to become active." >&2
    log "=========================================================" >&2
    
    read -p "If you have successfully loaded the XML backup, press [ENTER] to start Ansible automation..."

    log "=== 2/3 Windows Server (AD) build & start ===" >&2
    if [ ! -f "$LAB_ROOT/vms/windows-server-2022/winserver-ad.vmx" ]; then
        build_images "windows-server-2022"
    else
        log "Windows Server VM already exists, skipping build step." >&2
    fi

    
    log "Setting Windows Server network interface to vmnet2..." >&2
    
    
    sed -i 's/ethernet0.connectiontype = "nat"/ethernet0.connectionType = "custom"/I' "$LAB_ROOT/vms/windows-server-2022/winserver-ad.vmx"
    
   
    if grep -q "ethernet0.vnet" "$LAB_ROOT/vms/windows-server-2022/winserver-ad.vmx"; then
        sed -i 's/ethernet0.vnet = .*/ethernet0.vnet = "vmnet2"/' "$LAB_ROOT/vms/windows-server-2022/winserver-ad.vmx"
    else
        echo 'ethernet0.vnet = "vmnet2"' >> "$LAB_ROOT/vms/windows-server-2022/winserver-ad.vmx"
    fi

    start_vm "$LAB_ROOT/vms/windows-server-2022/winserver-ad.vmx"
    
    sleep 120

    log "=== 3/3 Windows 11 Workstation build & start ===" >&2
    if [ ! -f "$LAB_ROOT/vms/windows-11/win11-workstation.vmx" ]; then
        log "Packer disabled! The VM is being created directly via Bash (create-win11-vm.sh)..." >&2
        bash "$LAB_ROOT/network/create-win11-vm.sh" --force # Force rebuild for VMX changes to take effect
    else
        log "Windows 11 VM already exists; skipping creation step.." >&2
    fi
    
  
    start_vm "$LAB_ROOT/vms/windows-11/win11-workstation.vmx"
    
    log "ATTENTION: If you see 'Press any key...' on the screen, immediately click on the virtual machine and press the Spacebar! (VM starts automatically, but this warning is a precaution.)" >&2

   
    local -a all_winrm_ips
    all_winrm_ips=( $(find_all_winrm_ips) )

    if [ "${#all_winrm_ips[@]}" -lt 2 ]; then
        die "Insufficient WinRM IP addresses found for the AD Server and Workstation. (Found: ${all_winrm_ips[*]})"
    fi

    local FOUND_AD_IP=""
    local FOUND_WS_IP=""

    log "Found WinRM IP addresses: ${all_winrm_ips[*]}" >&2

    
    for ip in "${all_winrm_ips[@]}"; do
        log "Querying hostname for $ip..." >&2
        
        local hostname=$(get_hostname_via_winrm "$ip" "Administrator" "${WINRM_PASSWORD}")
        if [ $? -eq 0 ] && [[ "$hostname" == "WINSERVER-AD"* ]]; then
            FOUND_AD_IP="$ip"
            log "AD Server IP address verified: $FOUND_AD_IP" >&2
        else
            #
            local hostname_ws=$(get_hostname_via_winrm "$ip" "Admin" "${WINRM_PASSWORD}")
            if [ $? -eq 0 ] && [[ "$hostname_ws" == "WIN11-WKS"* ]]; then
                FOUND_WS_IP="$ip"
                log "Workstation IP address verified: $FOUND_WS_IP" >&2
            else
                warn "Could not verify hostname for IP $ip or it did not match the expected user/hostname." >&2
            fi
        fi
    done

    if [ -z "$FOUND_AD_IP" ] || [ -z "$FOUND_WS_IP" ]; then
        die "The AD Server or Workstation IP address could not be correctly identified. Please ensure that the VMs are running and WinRM is enabled."
    fi

    log "AD Server Ready: $FOUND_AD_IP" >&2
    log "Workstation Ready: $FOUND_WS_IP" >&2

    log "Updating Ansible inventory..." >&2
    cat > "$LAB_ROOT/ansible/inventory/hosts.ini" <<EOF
[ad_server]
$FOUND_AD_IP ansible_user=Administrator ansible_password=${WINRM_PASSWORD} ansible_connection=winrm ansible_winrm_transport=basic ansible_winrm_server_cert_validation=ignore ansible_port=5985

[workstation]
$FOUND_WS_IP ansible_user=Admin ansible_password=${WINRM_PASSWORD} ansible_connection=winrm ansible_winrm_transport=basic ansible_winrm_server_cert_validation=ignore ansible_port=5985

[domain_hosts:children]
ad_server
workstation
EOF

    
    log "Performing Ansible connection check..." >&2
    ansible ad_server -m win_ping -i "$LAB_ROOT/ansible/inventory/hosts.ini" --user Administrator --extra-vars "ansible_password=${WINRM_PASSWORD}" || die "AD Server'a Ansible bağlantısı başarısız oldu!" >&2
    
    ansible workstation -m win_ping -i "$LAB_ROOT/ansible/inventory/hosts.ini" --user Admin --extra-vars "ansible_password=${WINRM_PASSWORD}" -e "ansible_winrm_read_timeout=900 ansible_winrm_operation_timeout=600" -T 300 -vvv || die "Workstation'a Ansible bağlantısı başarısız oldu!" >&2
    log "Ansible bağlantıları başarılı." >&2

    log "Ansible playbooks are being executed..." >&2
    run_ansible "02-ad-domain.yml"
    run_ansible "03-badblood.yml"
    run_ansible "04-workstation-join.yml"
    run_ansible "05-sysmon.yml"
    run_ansible "06-crowdsec.yml"

    log "=== Kontrol Komutları ===" >&2
    ansible all -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_shell -a "Get-Service crowdsec | Select-Object Status; cd 'C:\Program Files\CrowdSec'; .\cscli.exe collections list"
    ansible all -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_shell -a "Get-Service crowdsec | Select-Object Status"
    
    ansible all -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_shell -a "Get-Content C:\ProgramData\CrowdSec\log\crowdsec.log -Tail 15"
    ansible all -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_service -a "name=crowdsec state=started"
    ansible all -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_shell -a "Get-Service sysmon64 | Select-Object Status, Name"
    ansible workstation -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_shell -a "(Get-WmiObject Win32_ComputerSystem).Domain"
    ansible ad_server -i "$LAB_ROOT/ansible/inventory/hosts.ini" -m win_shell -a "(Get-ADUser -Filter *).Count"

    log "=========================================================" >&2
    log "The SOC Lab setup has been completed flawlessly!" >&2
    log "=========================================================" >&2
}
main "$@"
