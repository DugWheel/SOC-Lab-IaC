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
  default = "./iso/SERVER_EVAL_x64FRE_en-us.iso"
}

variable "iso_checksum" {
  type    = string
  default = "none" # enter real SHA256 in production
}

variable "vm_name" {
  type    = string
  default = "winserver-ad"
}

variable "winrm_password" {
  type      = string
  default   = "ChangeMe123!"
  sensitive = true
}

variable "lan_vmnet" {
  type    = string
  default = "vmnet2"
}
variable "dmz_vmnet" {
  type    = string
  default = "vmnet3"
}
source "vmware-iso" "winserver" {
  iso_url               = var.iso_url
  iso_checksum          = var.iso_checksum
  vm_name               = var.vm_name
  guest_os_type         = "windows2019srv-64"
  headless              = false
  cpus                  = 2
  memory                = 4096
  disk_size             = 61440
  disk_adapter_type     = "nvme"
  network_adapter_type  = "e1000e"
  network               = "nat" 


  vnc_bind_address      = "0.0.0.0"
  vnc_disable_password  = true

  cd_content = {
    "autounattend.xml" = templatefile("./answer-files/autounattend.xml", { WINRM_PASSWORD = var.winrm_password })
  }
  cd_label = "cidata"

  
  boot_wait    = "3s"
  boot_command = ["<spacebar><spacebar>"]

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.winrm_password
  winrm_timeout  = "6h"
  winrm_port     = 5985

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1"

  vmx_data = {
    "firmware" = "efi" 
  }

  output_directory = "../../vms/windows-server-2022"
}

build {
  sources = ["source.vmware-iso.winserver"]

  provisioner "powershell" {
    inline = [
      "Write-Host 'WinRM is already active via autounattend, performing additional verification...'",
      "winrm get winrm/config/service"
    ]
  }
}
