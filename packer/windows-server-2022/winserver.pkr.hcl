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
  default = "none"
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

variable "ad_ip" {
  type    = string
  default = "192.168.10.10"
}

variable "lan_gw" {
  type    = string
  default = "192.168.10.254"
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
  iso_url              = var.iso_url
  iso_checksum         = var.iso_checksum
  vm_name              = var.vm_name
  guest_os_type        = "windows2019srv-64"
  headless             = false
  cpus                 = 2
  memory               = 4096
  disk_size            = 61440
  disk_adapter_type    = "nvme"
  network_adapter_type = "e1000e"
  network              = "nat"

  vnc_bind_address     = "0.0.0.0"
  vnc_disable_password = true

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

  # Standart kapanma komutu (Ağa dokunmadığı için WSMan onay paketi anında döner)
  shutdown_command = "shutdown /s /t 15 /f /d p:4:1"

  vmx_data = {
    "firmware" = "efi"
  }

  output_directory = "../../vms/windows-server-2022"
}

build {
  sources = ["source.vmware-iso.winserver"]

  provisioner "powershell" {
    inline = [
      "Write-Host 'WinRM is active. Registering startup task to configure static IP (${var.ad_ip}) on next boot...'",
      "$lines = @(",
      "  'netsh interface ip set address name=\"Ethernet0\" static ${var.ad_ip} 255.255.255.0 ${var.lan_gw} 1',",
      "  'netsh interface ip set dns name=\"Ethernet0\" static ${var.lan_gw} primary',",
      "  'netsh interface ip add dns name=\"Ethernet0\" 8.8.8.8 index=2',",
      "  'Unregister-ScheduledTask -TaskName \"SetStaticIP\" -Confirm:$false -ErrorAction SilentlyContinue'",
      ")",
      "Set-Content -Path 'C:\\set-ip.ps1' -Value $lines -Encoding Ascii -Force",
      "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\\set-ip.ps1'",
      "$trigger = New-ScheduledTaskTrigger -AtStartup",
      "$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\\SYSTEM' -LogonType ServiceAccount -RunLevel Highest",
      "Register-ScheduledTask -TaskName 'SetStaticIP' -Action $action -Trigger $trigger -Principal $principal -Force"
    ]
  }

  post-processor "shell-local" {
    inline = [
      "echo 'Switching VM network adapter from NAT to ${var.lan_vmnet}...'",
      "VMX_FILE=\"../../vms/windows-server-2022/${var.vm_name}.vmx\"",
      "sed -i 's/ethernet0.connectionType = \"nat\"/ethernet0.connectionType = \"custom\"/g' \"$VMX_FILE\"",
      "grep -q 'ethernet0.vnet' \"$VMX_FILE\" && sed -i 's|ethernet0.vnet = .*|ethernet0.vnet = \"/dev/${var.lan_vmnet}\"|g' \"$VMX_FILE\" || echo 'ethernet0.vnet = \"/dev/${var.lan_vmnet}\"' >> \"$VMX_FILE\""
    ]
  }
}
