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
  # Kendi indirdiğin Ubuntu Server ISO dosyasının adıyla eşleştiğinden emin ol:
  default = "./iso/ubuntu-22.04.5-live-server-amd64.iso"
}

variable "iso_checksum" {
  type    = string
  default = "none"
}

variable "ssh_username" {
  type    = string
  default = "labadmin"
}

variable "ssh_password" {
  type    = string
  default = "ChangeMe123!"
}

variable "wazuh_ip" {
  type    = string
  default = "192.168.20.10"
}

variable "dmz_gw" {
  type    = string
  default = "192.168.20.254"
}

variable "dmz_vmnet" {
  type    = string
  default = "vmnet3"
}

source "vmware-iso" "wazuh" {
  iso_url       = var.iso_url
  iso_checksum  = var.iso_checksum
  vm_name       = "wazuh-siem"
  guest_os_type = "ubuntu-64"
  headless      = false
  cpus          = 2
  memory        = 4096      # Wazuh Indexer (OpenSearch) için minimum 4GB, önerilen 8GB RAM
  disk_size     = 51200     # 50 GB Disk
  disk_type_id  = "0"

  network_adapter_type = "e1000"

  # Cloud-Init (NoCloud) ikincil CD-ROM ile tam otomatik kurulum (Subiquity Autoinstall)
  cd_label = "cidata"
  cd_content = {
    "meta-data" = "instance-id: wazuh-siem\nlocal-hostname: wazuh-siem\n"
    "user-data" = <<-EOF
      #cloud-config
      autoinstall:
        version: 1
        locale: en_US.UTF-8
        keyboard:
          layout: tr
        identity:
          hostname: wazuh-siem
          username: ${var.ssh_username}
          password: "${bcrypt(var.ssh_password)}"
        ssh:
          install-server: true
          allow-pw: true
        storage:
          layout:
            name: direct
        packages:
          - openssh-server
          - curl
          - tar
          - ufw
          - python3
        user-data:
          disable_root: false
        late-commands:
          # Passwordless sudo for Ansible automation
          - echo '${var.ssh_username} ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/${var.ssh_username}
          - chmod 440 /target/etc/sudoers.d/${var.ssh_username}
          # Write static DMZ Netplan configuration so it takes effect on next boot when attached to vmnet3
          - |
            cat << 'NETEOF' > /target/etc/netplan/00-installer-config.yaml
            network:
              version: 2
              ethernets:
                eth-dmz:
                  match:
                    name: "e*"
                  dhcp4: false
                  addresses:
                    - ${var.wazuh_ip}/24
                  routes:
                    - to: default
                      via: ${var.dmz_gw}
                  nameservers:
                    addresses:
                      - ${var.dmz_gw}
                      - 8.8.8.8
            NETEOF
          - chmod 600 /target/etc/netplan/00-installer-config.yaml
    EOF
  }

  communicator = "ssh"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "30m"
  ssh_port     = 22

  boot_wait = "6s"
  boot_keygroup_interval = "50ms"

  boot_command = [
    "c<wait3s>",
    "linux /casper/vmlinuz quiet autoinstall ds=nocloud ---<enter><wait15s>",
    "initrd /casper/initrd<enter><wait15s>",
    "boot<enter>"
  ]
  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"

  output_directory = "../../vms/wazuh-siem"

  vmx_data = {
    "ethernet0.present"        = "TRUE"
    "ethernet0.connectionType" = "nat"
  }
}

build {
  sources = ["source.vmware-iso.wazuh"]

  # Kurulum bitip sistem açıldıktan sonra (kapanmadan hemen önce) çalışır.
  # Eski DHCP netplan dosyalarını siler ve kalıcı DMZ statik IP ayarını yazar!
  provisioner "shell" {
    inline = [
      "sudo rm -f /etc/netplan/*.yaml",
      "sudo bash -c 'cat << EOF > /etc/netplan/01-dmz-static.yaml\nnetwork:\n  version: 2\n  ethernets:\n    eth-dmz:\n      match:\n        name: \"e*\"\n      dhcp4: false\n      addresses:\n        - ${var.wazuh_ip}/24\n      routes:\n        - to: default\n          via: ${var.dmz_gw}\n      nameservers:\n        addresses:\n          - ${var.dmz_gw}\n          - 8.8.8.8\nEOF'",
      "sudo chmod 600 /etc/netplan/01-dmz-static.yaml",
      "sudo bash -c 'echo \"network: {config: disabled}\" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'"
    ]
  }
}
