#!/usr/bin/env bash
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$LAB_ROOT/.env"
source "$ENV_FILE"

VM_DIR="$LAB_ROOT/vms/windows-11"
VMX_PATH="$VM_DIR/win11-workstation.vmx"
VMDK_PATH="$VM_DIR/win11-workstation.vmdk"
ANSWER_DIR="$LAB_ROOT/packer/windows-11/answer-files"
ANSWER_ISO="$VM_DIR/answer.iso"
WIN_ISO=$(find "$LAB_ROOT/packer/windows-11/iso" -iname "*.iso" | head -n1)

log()  { echo -e "\e[1;32m[+]\e[0m $1"; }
die()  { echo -e "\e[1;31m[x]\e[0m $1"; exit 1; }

[ -f "$WIN_ISO" ] || die "Windows 11 ISO not found: please place it in packer/windows-11/iso/."
[ -f "$ANSWER_DIR/autounattend.xml" ] || die "autounattend.xml not found: $ANSWER_DIR"

if [ -f "$VMX_PATH" ] && [ "${1:-}" != "--force" ]; then
    log "Windows 11 VM already exists ($VMX_PATH); skipping creation."
    exit 0
fi

mkdir -p "$VM_DIR"

log "Creating a minimal CD-ROM (ISO) for autounattend.xml..."

sed -i "s/\${WINRM_PASSWORD}/$WINRM_PASSWORD/g" "$ANSWER_DIR/autounattend.xml"
command -v genisoimage >/dev/null 2>&1 || die "genisoimage not found. Please install: sudo dnf install genisoimage"
genisoimage -o "$ANSWER_ISO" -V "cidata" -J -r "$ANSWER_DIR" >/dev/null 2>&1 \
    || die "Failed to create answer ISO."

# Create NVMe disk
if [ ! -f "$VMDK_PATH" ]; then
    log "Creating virtual disk (60GB, NVMe)..."
    vmware-vdiskmanager -c -s 60GB -a nvme -t 1 "$VMDK_PATH" \
        || die "Failed to create virtual disk."
else
    log "Virtual disk already exists ($VMDK_PATH); skipping disk creation."
fi

log "Generating VMX configuration file..."
cat > "$VMX_PATH" <<EOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "20"
displayName = "win11-workstation"
guestOS = "windows11-64"
firmware = "efi"
memsize = "4096"
numvcpus = "2"
vvtd.enable = "TRUE"
vpmc.enable = "TRUE"

# Virtual PCIe Bridge configuration 
pciBridge0.present = "TRUE"
pciBridge0.pciSlotNumber = "17"
pciBridge1.present = "TRUE"
pciBridge2.present = "TRUE"
pciBridge3.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge4.pciSlotNumber = "21"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge5.pciSlotNumber = "22"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge6.pciSlotNumber = "23"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
pciBridge7.pciSlotNumber = "24"

nvme0.present = "TRUE"
nvme0:0.present = "TRUE"
nvme0:0.fileName = "win11-workstation.vmdk"

sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.fileName = "${WIN_ISO}"
sata0:0.deviceType = "cdrom-image"
sata0:0.startConnected = "TRUE"

sata0:1.present = "TRUE"
sata0:1.fileName = "${ANSWER_ISO}"
sata0:1.deviceType = "cdrom-image"
sata0:1.startConnected = "TRUE"

ethernet0.present = "TRUE"
ethernet0.connectionType = "custom"
ethernet0.vnet = "${LAN_VMNET}"
ethernet0.virtualDev = "e1000e"
ethernet0.startConnected = "TRUE"

bios.bootDelay = "3000"
bios.bootOrder = "cdrom,hdd"
floppy0.present = "FALSE"
EOF

log "Windows 11 VM successfully created: $VMX_PATH"
log "Installation is  (autounattend.xml) "
