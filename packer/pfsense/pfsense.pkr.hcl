packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.10"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

# IMPORTANT CHANGE: pfSense is now distributed not as a classic single-file ISO,
# but with the "Netgate Installer" (e.g., netgate-installer-v1.2-
# RELEASE-amd64.iso.gz). This installer connects to the internet and downloads pfSense
# packages, meaning the ISO itself is small (~327MB), but
# the installation can take longer as it pulls data from the internet, and
# the VM's WAN adapter needs to be operational during installation.
#
# Before use: decompress the downloaded file with gunzip
#   gunzip netgate-installer-v1.2-RELEASE-amd64.iso.gz
# and place the resulting .iso file into the 'iso/' subdirectory of this folder.

variable "iso_url" {
  type    = string
  default = "./iso/netgate-installer-v1.2-RELEASE-amd64.iso"
}

variable "winrm_password" {
  type    = string
  default = ""
}
variable "iso_checksum" {
  type    = string
  default = "none" # Obtain from Netgate's "pfSense Plus Installer Checksums" page (calculated from the .gz file)
}

variable "lan_vmnet" {
  type    = string
  default = "vmnet2"
}

variable "dmz_vmnet" {
  type    = string
  default = "vmnet3"
}

source "vmware-iso" "pfsense" {
  iso_url       = var.iso_url
  iso_checksum  = var.iso_checksum
  vm_name       = "pfsense-fw"
  guest_os_type = "freebsd-64"
  headless      = false
  cpus          = 1
  memory        = 1024
  disk_size     = 8192

  network_adapter_type = "e1000"

  # The Netgate Installer also lacks an official answer-file mechanism,
  # WinRM/SSH cannot be used as a communicator, hence "none" and
  # key press simulation via boot_command.
  # Packer will not shut down the machine; it will wait up to 1 hour for SSH to become available.
  communicator = "ssh"
  ssh_username = "admin"
  ssh_password = "pfsense"
  ssh_timeout  = "1h"
  ssh_port     = 22
  
  boot_wait = "5s"
  boot_command = []

  # Once the installation is complete and SSH is enabled, Packer will use this command to cleanly shut down the system
  shutdown_command = "halt -p"

  output_directory = "../../vms/pfsense"

  vmx_data = {
    "ethernet0.present"          = "TRUE"
    "ethernet0.connectionType"   = "nat"
    "ethernet1.present"          = "TRUE"
    "ethernet1.connectionType"   = "custom"
    "ethernet1.vnet"             = "${var.lan_vmnet}"
    "ethernet2.present"          = "TRUE"
    "ethernet2.connectionType"   = "custom"
    "ethernet2.vnet"             = "${var.dmz_vmnet}"
    "RemoteDisplay.vnc.enabled"  = "TRUE"
    "RemoteDisplay.vnc.port"     = "5900"
    "bios.bootOrder"             = "CDROM,HDD,FLOPPY"
  }
}

build {
  sources = ["source.vmware-iso.pfsense"]
}
