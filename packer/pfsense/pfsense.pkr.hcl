packer {
  required_plugins {
    vmware = {
      version = ">= 1.0.10"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "iso_url" {
  type    = string
  default = "./iso/pfSense-CE-2.7.2-RELEASE-amd64.iso"
}

variable "iso_checksum" {
  type    = string
  default = "none"
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

  # Primary adapter (ethernet0) becomes em0 (WAN)
  network_adapter_type = "e1000"

  # Mount docs/config-pfSense.xml as /conf/config.xml on secondary CD-ROM
  cd_content = {
    "/conf/config.xml" = file("../../docs/config-pfSense.xml")
  }
  cd_label = "PFSENSE_CFG"

  communicator = "ssh"
  ssh_host     = "192.168.10.254"
  ssh_username = "admin"
  ssh_password = "pfsense"
  ssh_timeout  = "20m"
  ssh_port     = 22

  # Wait 12s for the FreeBSD boot menu, then press Enter immediately
  boot_wait = "12s"

  boot_command = [
    "<enter><wait35s>",                # Boot menu -> Boot immediately, wait 35s for Copyright screen
    "<enter><wait3s>",                 # 1. Copyright notice -> Accept
    "<enter><wait3s>",                 # 2. Welcome to pfSense -> Install pfSense
    "<enter><wait3s>",                 # 3. Keymap Selection -> Continue with default keymap
    "<enter><wait3s>",                 # 4. Partitioning -> Auto (ZFS)
    "<enter><wait3s>",                 # 5. ZFS Configuration -> Proceed with Installation                 # 6. ZFS Pool Type -> stripe
    "<spacebar><enter><wait3s>",       # 7. Disk Selection -> Spacebar selects [*] da0, Enter continues
    "<left><enter><wait45s>",          # 8. Confirm disk wipe -> Left selects YES, Enter starts extraction (wait 45s)
    "<enter>"                          # 9. Complete (Reboot / Shell) -> Enter selects Reboot
  ]

  shutdown_command = "16\ny\n"

  output_directory = "../../vms/pfsense"

  vmx_data = {
    "ethernet0.present"        = "TRUE"
    "ethernet0.connectionType" = "nat"
    # ethernet1 and ethernet2 default to vlance (le0 and le1 in FreeBSD), matching config-pfSense.xml!
    "ethernet1.present"        = "TRUE"
    "ethernet1.connectionType" = "custom"
    "ethernet1.vnet"           = "${var.lan_vmnet}"
    "ethernet2.present"        = "TRUE"
    "ethernet2.connectionType" = "custom"
    "ethernet2.vnet"           = "${var.dmz_vmnet}"
    "bios.bootOrder"           = "hdd,cdrom"
  }
}

build {
  sources = ["source.vmware-iso.pfsense"]
}
