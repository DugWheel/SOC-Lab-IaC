#!/usr/bin/env bash
# =========================================================
# check_prereqs.sh
# Run BEFORE installation: verifies that all required tools, ISOs and
# network settings exist. Read-only: does not install or change anything.
#
# Usage: ./check_prereqs.sh
# =========================================================

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OK=0
WARN=0
FAIL=0

ok()      { echo -e "  \e[1;32m[OK]\e[0m   $1"; OK=$((OK+1)); }
warn()    { echo -e "  \e[1;33m[WARN]\e[0m $1"; WARN=$((WARN+1)); }
fail()    { echo -e "  \e[1;31m[FAIL]\e[0m $1"; FAIL=$((FAIL+1)); }
section() { echo -e "\n\e[1;36m== $1 ==\e[0m"; }

# ---------------------------------------------------------
section "1) Host / Hypervisor"
# ---------------------------------------------------------

if command -v vmrun >/dev/null 2>&1; then
    ver=$(vmrun 2>&1 | head -n1 || true)
    ok "vmrun found (VMware Workstation installed). $ver"
else
    fail "vmrun not found. VMware Workstation Pro (Linux) not installed or not in PATH."
fi

if command -v VBoxManage >/dev/null 2>&1; then
    warn "VirtualBox (VBoxManage) is also installed on the system. This project uses VMware;"
    warn "  conflicts may occur if both run simultaneously (especially KVM/kernel module)."
fi

if [ -f /etc/vmware/networking ]; then
    ok "/etc/vmware/networking found."
else
    fail "/etc/vmware/networking not found. VMware Workstation network component may not be installed correctly."
fi

if systemctl list-units 2>/dev/null | grep -qi vmware-networks; then
    ok "vmware-networks service defined on system."
elif command -v vmware-networks >/dev/null 2>&1; then
    ok "vmware-networks CLI tool found (as binary instead of service)."
else
    warn "vmware-networks service/binary name could not be detected -> you may need to manually verify"
    warn "  the configure_vmnets() function in setup.sh."
    warn "  For check: ./network/vmnet-config.sh"
fi

if grep -q "VNET_2_HOSTONLY_SUBNET" /etc/vmware/networking 2>/dev/null; then
    ok "VMnet2 (LAN) already defined."
else
    warn "VMnet2 (LAN) not defined yet - will be added automatically when setup.sh runs."
fi
if grep -q "VNET_3_HOSTONLY_SUBNET" /etc/vmware/networking 2>/dev/null; then
    ok "VMnet3 (DMZ) already defined."
else
    warn "VMnet3 (DMZ) not defined yet - will be added automatically when setup.sh runs."
fi

# ---------------------------------------------------------
section "2) IaC & Automation Tools"
# ---------------------------------------------------------

if command -v packer >/dev/null 2>&1; then
    ok "packer found ($(packer --version 2>/dev/null))."
else
    fail "packer not found. https://developer.hashicorp.com/packer/install"
fi

if command -v ansible-playbook >/dev/null 2>&1; then
    ok "ansible-playbook found ($(ansible --version 2>/dev/null | head -n1))."
else
    fail "ansible-playbook not found. Install with: 'sudo dnf install ansible'."
fi

if command -v sshpass >/dev/null 2>&1; then
    ok "sshpass found - required for Ansible SSH connection to Wazuh Ubuntu Server."
else
    fail "sshpass not found. Install with: 'sudo dnf install sshpass'."
fi

if command -v genisoimage >/dev/null 2>&1 || command -v xorriso >/dev/null 2>&1; then
    ok "ISO creation tool (genisoimage/xorriso) found - required for unattended answer ISOs."
else
    fail "genisoimage not found. Install: sudo dnf install genisoimage"
fi

if command -v vmware-vdiskmanager >/dev/null 2>&1; then
    ok "vmware-vdiskmanager found - required for creating virtual disks."
else
    fail "vmware-vdiskmanager not found. Should be part of VMware Workstation installation, check PATH."
fi

if [ -f "$LAB_ROOT/ansible/requirements.yml" ]; then
    missing_collections=0
    for coll in ansible.windows community.windows microsoft.ad; do
        if ansible-galaxy collection list 2>/dev/null | grep -q "$coll"; then
            ok "$coll collection installed."
        else
            fail "$coll collection not installed."
            missing_collections=1
        fi
    done
    [ "$missing_collections" -eq 1 ] && warn "For missing collections: ansible-galaxy collection install -r ansible/requirements.yml"
else
    warn "ansible/requirements.yml not found."
fi

# ---------------------------------------------------------
section "3) .env Configuration File"
# ---------------------------------------------------------

if [ -f "$LAB_ROOT/.env" ]; then
    ok ".env file exists."
    for var in WAZUH_IP WAZUH_SSH_USER KALI_IP KALI_SSH_USER LAN_GW DMZ_GW; do
        if grep -q "^${var}=" "$LAB_ROOT/.env" 2>/dev/null; then
            ok "$var defined in .env."
        else
            warn "$var not defined in .env - the default value from setup.sh will be used."
        fi
    done
else
    fail ".env file missing. Run 'cp .env.example .env' and configure it."
fi

# ---------------------------------------------------------
section "4) ISO Files"
# ---------------------------------------------------------

check_iso_dir() {
    local dir="$1"
    local label="$2"
    local iso_count gz_count

    iso_count=$(find "$dir" -iname "*.iso" 2>/dev/null | wc -l)
    gz_count=$(find "$dir" -iname "*.gz" 2>/dev/null | wc -l)

    if [ "$iso_count" -gt 0 ]; then
        local f
        f=$(find "$dir" -iname "*.iso" 2>/dev/null | head -n1)
        local size
        size=$(du -h "$f" 2>/dev/null | cut -f1)
        ok "$label ISO found: $(basename "$f") ($size)"
    elif [ "$gz_count" -gt 0 ]; then
        fail "$label has .gz file but not decompressed! First: gunzip $dir/*.gz"
    else
        fail "$label ISO not found -> place it in $dir/."
    fi
}

check_iso_dir "$LAB_ROOT/packer/pfsense/iso"             "pfSense CE"
check_iso_dir "$LAB_ROOT/packer/windows-server-2022/iso" "Windows Server 2022"
check_iso_dir "$LAB_ROOT/packer/windows-11/iso"          "Windows 11"
check_iso_dir "$LAB_ROOT/packer/wazuh/iso"               "Ubuntu Server (Wazuh)"

check_iso_matches_hcl() {
    local iso_dir="$1"
    local hcl_file="$2"
    local label="$3"

    [ -f "$hcl_file" ] || return 0
    local iso_file
    iso_file=$(find "$iso_dir" -iname "*.iso" 2>/dev/null | head -n1)
    [ -z "$iso_file" ] && return 0

    local iso_name
    iso_name=$(basename "$iso_file")
    local hcl_default
    hcl_default=$(grep -A3 'variable "iso_url"' "$hcl_file" | grep default | sed -E 's/.*"\.\/iso\/(.*)"/\1/')

    if [ "$iso_name" == "$hcl_default" ]; then
        ok "$label: ISO filename matches $(basename "$hcl_file") default."
    else
        warn "$label: ISO filename ($iso_name) differs from $(basename "$hcl_file") default ($hcl_default)."
        warn "  -> setup.sh passes iso_url dynamically or update default in $hcl_file."
    fi
}

check_iso_matches_hcl "$LAB_ROOT/packer/pfsense/iso" "$LAB_ROOT/packer/pfsense/pfsense.pkr.hcl" "pfSense CE"
check_iso_matches_hcl "$LAB_ROOT/packer/windows-server-2022/iso" "$LAB_ROOT/packer/windows-server-2022/winserver.pkr.hcl" "Windows Server"
check_iso_matches_hcl "$LAB_ROOT/packer/wazuh/iso" "$LAB_ROOT/packer/wazuh/wazuh.pkr.hcl" "Ubuntu Server (Wazuh)"

# ---------------------------------------------------------
section "5) Disk Space"
# ---------------------------------------------------------

avail_gb=$(df --output=avail -BG "$LAB_ROOT" 2>/dev/null | tail -n1 | tr -dc '0-9')
if [ -n "$avail_gb" ]; then
    if [ "$avail_gb" -ge 120 ]; then
        ok "Available disk space sufficient (~${avail_gb}GB)."
    else
        warn "Available disk space low (~${avail_gb}GB). At least 120GB recommended (pfSense + WinServer + Win11 + Wazuh + ISOs)."
    fi
fi

# ---------------------------------------------------------
section "6) Host RAM"
# ---------------------------------------------------------

total_ram_gb=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
if [ -n "$total_ram_gb" ]; then
    if [ "$total_ram_gb" -ge 32 ]; then
        ok "Host RAM sufficient (${total_ram_gb}GB) for the full stack."
    elif [ "$total_ram_gb" -ge 15 ]; then
        warn "Host RAM is ${total_ram_gb}GB. Running pfSense + WinServer + Win11 + Wazuh simultaneously"
        warn "  is tight on 16GB RAM; consider closing heavy host apps during setup."
    else
        warn "Host RAM low (${total_ram_gb}GB). At least 16GB required, 32GB+ recommended."
    fi
fi

# ---------------------------------------------------------
section "7) Optional Attacker VM (Kali Linux)"# ---------------------------------------------------------
echo -e "  \e[1;34m[INFO]\e[0m Kali Linux is optional (Bring Your Own VM). Attach your existing Kali VM to vmnet2 (192.168.10.20) for offensive testing."
# ---------------------------------------------------------
section "Summary"
# ---------------------------------------------------------

echo -e "\n  \e[1;32mOK: $OK\e[0m   \e[1;33mWARN: $WARN\e[0m   \e[1;31mFAIL: $FAIL\e[0m\n"

if [ "$FAIL" -gt 0 ]; then
    echo -e "\e[1;31mSome prerequisites are missing. Fix the [FAIL] lines above and run again.\e[0m"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo -e "\e[1;33mInstallation can be started, but review the warnings above.\e[0m"
    exit 0
else
    echo -e "\e[1;32mEverything looks ready. You can run ./setup.sh.\e[0m"
    exit 0
fi
