# SOC-Lab-IaC: Automated Security Operations Center Lab

![Tested With Packer](https://img.shields.io/badge/Tested_With_Packer-1.10+-blue)
![Tested With Ansible](https://img.shields.io/badge/Tested_With_Ansible-2.15+-red)
![VMware](https://img.shields.io/badge/VMware-Workstation_Pro-green)
![Wazuh](https://img.shields.io/badge/SIEM-Wazuh_4.7-00a9e0)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

An automated Infrastructure-as-Code (IaC) SOC and Purple Team lab built for a Fedora Linux host running VMware Workstation Pro. It automatically builds a segmented security environment behind a **pfSense** firewall, provisions an Active Directory domain populated with synthetic adversarial data via **BadBlood**, deploys endpoint telemetry and behavioral defense with **Sysmon** and **CrowdSec**, and centralizes detection engineering on a dedicated **Wazuh SIEM** server in the DMZ. It also integrates a **Kali Linux** attacker VM (Bring Your Own VM) on the LAN for end-to-end Active Directory attack simulations.

The entire lab is orchestrated through a single `./setup.sh` workflow: **Packer** handles unattended image provisioning (pfSense, Windows Server 2022, and Ubuntu Server for Wazuh), `create-win11-vm.sh` handles Windows 11 unattended installation, and **Ansible** handles all post-install domain, SACL auditing, telemetry, and custom SIEM rule configurations.

![Network Topology](docs/soc-lab-network-topology.png)

> **Lab Environment Only**
>
> This project is designed to run inside an isolated VMware environment for security research, detection engineering, and SOC practice. Do not expose the Windows/Active Directory lab networks directly to untrusted networks or the public Internet. The generated Active Directory data is intentionally synthetic and adversarial-looking.

---

## Table of Contents

* [Overview](#overview)
  * [Core Components](#core-components)
* [Purple Team Walkthrough & Detection Engineering](#purple-team-walkthrough--detection-engineering)
* [Architecture](#architecture)
  * [Machines](#machines)
  * [Network Flow](#network-flow)
* [Lab Workflow](#lab-workflow)
* [Prerequisites](#prerequisites)
  * [Download Required ISO Files](#download-required-iso-files)
* [Directory Structure](#directory-structure)
* [Quick Start](#quick-start)
* [What's Actually Configured](#whats-actually-configured)
  * [pfSense Firewall Configuration](#pfsense-firewall-configuration)
  * [Active Directory & BadBlood](#active-directory--badblood)
  * [Ansible Playbooks](#ansible-playbooks)
  * [Sysmon & CrowdSec](#sysmon--crowdsec)
  * [Wazuh SIEM & Custom Detection Rules](#wazuh-siem--custom-detection-rules)
  * [Kali Attacker VM (BYOVM)](#kali-attacker-vm-byovm)
* [Known Limitations](#known-limitations)
* [Troubleshooting](#troubleshooting)
* [Teardown](#teardown)
* [License & Credits](#license--credits)

---

## Overview

**SOC-Lab-IaC** is a reproducible blue-team and purple-team security operations lab designed for:

* Windows and Active Directory security monitoring (`Event ID 4624`, `4625`, `4662`, `4720`, `4724`, `4738`, `4768`, `4769`, `5136`)
* Centralized log collection, threat hunting, and SIEM analysis with Wazuh
* Custom detection engineering (`docs/local_rules.xml`) mapped to MITRE ATT&CK
* Endpoint telemetry collection with Sysmon (`Event ID 1`, `10`, etc.) and behavioral defense with CrowdSec
* Active Directory attack path simulation (BloodHound, `bloodyAD`, Impacket, NetExec)
* Network segmentation and firewall rule testing across LAN and DMZ
* Zero-touch security automation with Packer and Ansible

### Core Components

| Component                  | Purpose                                                              |
| -------------------------- | -------------------------------------------------------------------- |
| **pfSense CE 2.7.2**       | Firewall, router, and LAN/DMZ network segmentation                   |
| **Windows Server 2022**    | Active Directory Domain Controller (`soclab.local`)                  |
| **Windows 11 Enterprise**  | Domain-joined workstation endpoint                                   |
| **Wazuh SIEM (Ubuntu)**    | Centralized SIEM, log aggregation, and XDR platform in the DMZ       |
| **BadBlood**               | Synthetic/adversarial Active Directory population                    |
| **Sysmon**                 | Process, network, and LSASS memory access endpoint telemetry         |
| **CrowdSec**               | Log-based behavioral detection and host firewall remediation         |
| **Kali Linux (Optional)**  | Bring-Your-Own attacker VM on the LAN for purple-team simulations    |
| **Packer**                 | Unattended VM image provisioning (pfSense, Windows Server, Ubuntu)   |
| **Ansible**                | Post-install configuration and SIEM/agent orchestration              |
| **VMware Workstation Pro** | Host virtualization platform                                         |

---

## Purple Team Walkthrough & Detection Engineering

This repository includes full documentation covering both offensive execution from Kali Linux and defensive telemetry/rule engineering in Wazuh:

* **[Active Directory Purple Team Walkthrough (`docs/pentest.md`)](docs/pentest.md):** Step-by-step offensive execution and real-time Wazuh alerts for SMB Password Spraying & Brute Force, BloodHound ACL Abuse Chains (`GenericAll` password resets), AS-REP Roasting, Targeted Kerberoasting, Shadow Credentials (`msDS-KeyCredentialLink`), DCSync Replication, Pass-the-Hash (`wmiexec`), and LSASS Memory Dumping (`comsvcs.dll`).
* **[Detection Engineering & Architecture Notes (`docs/purple-team-notes.md`)](docs/purple-team-notes.md):** Deep dive into the custom Wazuh detection ruleset (`100010`–`100080`), Active Directory SACL auditing requirements, event correlation logic, and troubleshooting lessons learned.
* **[Custom Wazuh Ruleset (`docs/local_rules.xml`)](docs/local_rules.xml):** Production-ready custom XML rules deployed automatically to `/var/ossec/etc/rules/local_rules.xml`.

---

## Architecture

The lab is segmented into three VMware virtual networks:

| Zone    | vmnet  | Subnet            | Host Adapter IP | pfSense Gateway  | Purpose                                   |
| ------- | ------ | ----------------- | --------------- | ---------------- | ----------------------------------------- |
| **WAN** | vmnet8 | DHCP (`172.16.x`) | Auto (NAT)      | DHCP             | Host's internet connection                |
| **LAN** | vmnet2 | `192.168.10.0/24` | `192.168.10.1`  | `192.168.10.254` | Windows AD network + Kali attacker        |
| **DMZ** | vmnet3 | `192.168.20.0/24` | `192.168.20.1`  | `192.168.20.254` | Isolated Wazuh SIEM & monitoring network  |

### Machines

| Machine               | Role                                    | Network         | IP                                   | Provisioning Method                              |
| --------------------- | --------------------------------------- | --------------- | ------------------------------------ | ------------------------------------------------ |
| **pfSense-fw**        | Firewall / Router (LAN + DMZ gateway)   | WAN / LAN / DMZ | `192.168.10.254` / `192.168.20.254`  | Packer (`pfsense.pkr.hcl` + ECI XML)             |
| **winserver-ad**      | Windows Server 2022 / Domain Controller | LAN (`vmnet2`)  | `192.168.10.10`                      | Packer (`winserver.pkr.hcl`)                     |
| **win11-workstation** | Windows 11 / Domain-joined endpoint     | LAN (`vmnet2`)  | `192.168.10.11`                      | Bash + `autounattend.xml` (`create-win11-vm.sh`) |
| **wazuh-siem**        | Ubuntu Server 22.04 / Wazuh SIEM        | DMZ (`vmnet3`)  | `192.168.20.10`                      | Packer (`wazuh.pkr.hcl` + Cloud-Init)            |
| **kali-attacker**     | Kali Linux / Offensive testing          | LAN (`vmnet2`)  | `192.168.10.20`                      | Optional / Bring Your Own VM                     |

### Network Flow

```text
                         Internet
                            │
                            ▼
                       VMware vmnet8
                         (WAN/NAT)
                            │
                            ▼
                     ┌──────────────┐
                     │   pfSense    │
                     │   Firewall   │
                     └──────┬───────┘
                            │
              ┌─────────────┴─────────────┐
              │                           │
              ▼                           ▼
       VMware vmnet2                VMware vmnet3
      192.168.10.0/24              192.168.20.0/24
     GW: 192.168.10.254           GW: 192.168.20.254
              │                           │
      ┌───────┼──────────┐                ▼
      │       │          │         ┌────────────┐
      ▼       ▼          ▼         │   Wazuh    │
   Windows Windows     Kali        │    SIEM    │
   Server    11      Attacker      │ (Ubuntu)   │
     .10     .11    .20 (BYOVM)    │192.168.20.10│
      │       │                    └─────▲──────┘
      └───────┼──────────┐               │
              │          │         Sysmon & AD Security
              ▼          │         telemetry (Wazuh Agents:
       soclab.local AD   │          1514/1515 TCP)
              │          │               │
      ┌───────┴────────┐ │               │
      │                │ │               │
      ▼                ▼ ▼               │
   Sysmon ─────────────┴─────────────────┘
      │
      ▼
   CrowdSec
```

---

## Lab Workflow

The complete deployment runs end-to-end without manual intervention:

```text
   ./setup.sh
       │
       ▼
Configure VMware VMnets (vmnet2 LAN, vmnet3 DMZ)
       │
       ▼
1/4 Build & start pfSense (Packer + automated config-pfSense.xml import)
       │
       ▼
2/4 Build & start Windows Server 2022 (Packer + autounattend.xml)
       │
       ▼
3/4 Create & start Windows 11 VM (create-win11-vm.sh + answer.iso)
       │
       ▼
4/4 Build & start Wazuh Ubuntu Server in DMZ (Packer + Cloud-Init + Netplan)
       │
       ▼
Discover Windows WinRM IPs & generate ansible/inventory/hosts.ini
       │
       ▼
Execute Ansible Playbooks
       │
       ├──► 02-ad-domain.yml        (Promote Windows Server to DC)
       ├──► 03-badblood.yml         (Populate AD with BadBlood)
       ├──► 04-workstation-join.yml (Join Windows 11 to soclab.local)
       ├──► 05-sysmon.yml           (Install/configure Sysmon)
       ├──► 06-crowdsec.yml         (Install/configure CrowdSec)
       └──► 07-wazuh.yml            (Deploy Wazuh SIEM & enroll Windows agents)
       │
       ▼
   SOC Lab Ready!
```

---

## Prerequisites

### Host Requirements

* Fedora Linux or compatible Linux distribution
* VMware Workstation Pro installed and available in `PATH`
* **16 GB+ RAM** (32 GB recommended when running all 4 core VMs + Kali simultaneously)
* **120 GB+ free disk space**
* Active internet connection

### Required Tools

Ensure the following packages and binaries are installed on your Fedora host:

* `packer`
* `ansible-playbook` (and `python3-winrm`)
* `sshpass` (`sudo dnf install sshpass` — required for Ansible SSH authentication to the Wazuh server)
* `genisoimage` or `xorriso` (`sudo dnf install genisoimage xorriso` — required for unattended answer ISOs)
* `vmware-vdiskmanager` and `vmrun` (bundled with VMware Workstation Pro)

Run `./check_prereqs.sh` at any time to validate your environment before building:

```bash
./check_prereqs.sh
```

---

## Download Required ISO Files

Download the following installation media and place them in their corresponding Packer `iso/` directories before running `./setup.sh`:

| Operating System          | Download Source                                                                                          | Target Directory                  | Notes                                                                                      |
| ------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------ |
| **pfSense CE 2.7.2**      | [Netgate Official Mirror](https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz) | `packer/pfsense/iso/`   | Use the classic **Offline DVD ISO** (`pfSense-CE-2.7.2-RELEASE-amd64.iso.gz`) and `gunzip` it. |
| **Windows Server 2022**   | [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server-2022) | `packer/windows-server-2022/iso/` | 180-day Evaluation ISO (64-bit English).                                         |
| **Windows 11 Enterprise** | [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise) | `packer/windows-11/iso/` | 90-day Evaluation ISO. Keep **only one** `.iso` file in this directory.          |
| **Ubuntu Server 22.04**   | [Ubuntu Releases](https://releases.ubuntu.com/22.04/)                                                    | `packer/wazuh/iso/`               | Live Server (`ubuntu-22.04.5-live-server-amd64.iso`) for the Wazuh SIEM node.              |

### Quick Download for pfSense CE 2.7.2 Offline ISO

Netgate's main store page distributes the online installer by default. For reliable zero-touch Packer automation, download the offline CE 2.7.2 ISO directly into `packer/pfsense/iso/`:

```bash
cd packer/pfsense/iso/
curl -LO [https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz](https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz)
gunzip pfSense-CE-2.7.2-RELEASE-amd64.iso.gz
cd ../../..
```

---

## Directory Structure

```text
.
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml
│   ├── inventory/
│   │   └── hosts.ini
│   └── playbooks/
│       ├── 02-ad-domain.yml
│       ├── 03-badblood.yml
│       ├── 04-workstation-join.yml
│       ├── 05-sysmon.yml
│       ├── 06-crowdsec.yml
│       └── 07-wazuh.yml
│
├── docs/
│   ├── config-pfSense.xml
│   ├── soc-lab-network-topology.png
│   ├── purple-team-notes.md
│   ├── pentest.md
│   └── local_rules.xml 
│
├── network/
│   ├── create-win11-vm.sh
│   └── vmnet-config.sh
│
├── packer/
│   ├── pfsense/
│   │   ├── pfsense.pkr.hcl
│   │   └── iso/
│   ├── wazuh/
│   │   ├── wazuh.pkr.hcl
│   │   └── iso/
│   ├── windows-11/
│   │   ├── answer-files/
│   │   │   └── autounattend.xml
│   │   └── iso/
│   └── windows-server-2022/
│       ├── winserver.pkr.hcl
│       ├── answer-files/
│       │   └── autounattend.xml
│       └── iso/
│
├── vms/
├── .env.example
├── check_prereqs.sh
├── setup.sh
└── teardown.sh
```

---

## Quick Start

### 1. Clone the repository

```bash
git clone [https://github.com/DugWheel/SOC-Lab-IaC.git](https://github.com/DugWheel/SOC-Lab-IaC.git)
cd SOC-Lab-IaC
```

### 2. Configure environment variables

```bash
cp .env.example .env
```

Review `.env` and adjust credentials if desired.

> **Security:** `.env` holds your lab passwords and is ignored by Git. Never commit `.env` to version control.

### 3. Install Ansible collections

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

### 4. Verify prerequisites

```bash
./check_prereqs.sh
```

### 5. Deploy the lab

```bash
./setup.sh
```

`setup.sh` executes the entire build pipeline automatically:
1. Configures VMware host-only networks `vmnet2` (LAN) and `vmnet3` (DMZ)
2. Builds `pfSense-fw` via Packer with `docs/config-pfSense.xml` automatically injected via ECI, detaches installer media, and boots the firewall
3. Builds `winserver-ad` (Windows Server 2022) via Packer and attaches it to `vmnet2`
4. Creates `win11-workstation` via `network/create-win11-vm.sh` and boots it on `vmnet2`
5. Builds `wazuh-siem` (Ubuntu Server) via Packer with Cloud-Init, switches its adapter to `vmnet3` (DMZ `192.168.20.10`), and waits for SSH readiness
6. Discovers the Windows hosts over WinRM and writes `ansible/inventory/hosts.ini`
7. Runs Ansible playbooks `02` through `07` to promote the Domain Controller, run BadBlood, join Windows 11 to the domain, deploy Sysmon & CrowdSec, install the Wazuh SIEM stack, and enroll the Windows Wazuh agents[

---

## What's Actually Configured

### pfSense Firewall Configuration
After installing pfSense and assigning the initial **WAN (`em0`)** and **LAN (`em1` / `le0`)** interfaces in the console, import [`docs/config-pfSense.xml`](docs/config-pfSense.xml) via **Diagnostics -> Backup & Restore** in the WebGUI (`https://192.168.10.254`). This automatically configures all interfaces, DHCP, and firewall rules:
* **WAN (`em0`):** NAT (`vmnet8`, DHCP)
* **LAN (`le0`):** `192.168.10.254/24` (`vmnet2`)
* **DMZ (`le1`):** `192.168.20.254/24` (`vmnet3`)
* **WebGUI:** Accessible from the host at `https://192.168.10.254`



### Active Directory & BadBlood

The lab provisions an Active Directory forest (`soclab.local`) on `winserver-ad` (`192.168.10.10`) and populates it via **BadBlood** with approximately **2,500 users**, **500 groups**, and **100 computers**, creating a realistic enterprise attack surface for BloodHound and detection engineering.

### Ansible Playbooks

| Playbook                  | Function                                                                          |
| ------------------------- | --------------------------------------------------------------------------------- |
| `02-ad-domain.yml`        | Promotes Windows Server to a Domain Controller and sets pfSense as DNS forwarder |
| `03-badblood.yml`         | Populates Active Directory with synthetic objects and ACL misconfigurations |
| `04-workstation-join.yml` | Joins Windows 11 (`win11-workstation`) to `soclab.local`                |
| `05-sysmon.yml`           | Installs and configures Sysmon with the SwiftOnSecurity ruleset         |
| `06-crowdsec.yml`         | Installs CrowdSec and configures Windows Security & Firewall collections |
| `07-wazuh.yml`            | Deploys Wazuh SIEM on Ubuntu (`192.168.20.10`), installs Windows Wazuh agents, and forwards Sysmon logs |

### Sysmon & CrowdSec

* **Sysmon:** Installed on both Windows machines using the SwiftOnSecurity configuration. All `Microsoft-Windows-Sysmon/Operational` events are collected by the Wazuh agent and shipped to the Wazuh manager.
* **CrowdSec:** Installed on both Windows machines to monitor Windows Security (`4624`, `4625`) and Firewall logs.

### Wazuh SIEM & Custom Detection Rules

The Wazuh SIEM all-in-one stack (wazuh-manager, wazuh-indexer, wazuh-dashboard) is deployed on an Ubuntu Server VM isolated in the DMZ (vmnet3):
* **Dashboard URL:** `https://192.168.20.10`
* **Default Username:** `admin` (the generated password is displayed at the end of `07-wazuh.yml` and stored in `/root/wazuh-install-files.tar` on the Wazuh server)
* **Custom Detection Rules:** `docs/local_rules.xml` adds high-fidelity detections for Brute Force/Password Spraying (100010–100020), LSASS Dumping (100031–100032), Impacket wmiexec user creation (100040–100042), DCSync (100050–100052), Kerberoasting & AS-REP Roasting (100060–100063), ACL Password Reset Chains (100070–100073), Shadow Credentials (100075), and Pass-the-Hash (100080).
* **Enrolled Agents:** `WINSERVER-AD` (`192.168.10.10`) and `WIN11-WKS` (`192.168.10.11`)

### Kali Attacker VM (BYOVM)

Rather than forcing a fresh Kali Linux build during `./setup.sh`, the architecture supports **Bring Your Own VM (BYOVM)** for offensive testing:
1. Open your existing Kali Linux VM settings in VMware Workstation.
2. Set its Network Adapter to **Custom (`vmnet2` / LAN)**.
3. Assign it the static IP `192.168.10.20/24`, gateway `192.168.10.254`, and DNS `192.168.10.10` (the Domain Controller).

---

## Known Limitations

### Windows 11 Provisioning vs. Windows Server

While Windows Server 2022, pfSense, and Ubuntu Server provision via Packer, Windows 11 exhibits WinRM timeouts during automated sysprep phases. To guarantee a smooth build, Windows 11 is created directly via `network/create-win11-vm.sh` using `vmrun` and an `autounattend.xml` answer ISO.

### BadBlood Idempotency

BadBlood execution is guarded by `C:\BadBlood_Run.log` on the Domain Controller. Once this file exists, `03-badblood.yml` skips re-running BadBlood. Delete `C:\BadBlood_Run.log` if you want to re-run it.

---

## Troubleshooting

### VMnet Host-Only Adapter Fails

If `vmnet2`/`vmnet3` interfaces fail to start on Fedora, verify that VMware kernel modules are loaded:

```bash
lsmod | grep -E "vmmon|vmnet"
```

If missing, rebuild them:

```bash
sudo vmware-modconfig --console --install-all
sudo vmware-networks --stop
sudo vmware-networks --start
```

### Ansible WinRM or SSH Timeouts

Verify host reachability from Fedora:

```bash
nc -zv 192.168.10.254 443    # pfSense WebGUI
nc -zv 192.168.10.10 5985    # Windows Server WinRM (User: Administrator)
nc -zv 192.168.10.11 5985    # Windows 11 WinRM (User: Admin)
nc -zv 192.168.20.10 22      # Wazuh Ubuntu SSH
nc -zv 192.168.20.10 1514    # Wazuh Agent events
nc -zv 192.168.20.10 443     # Wazuh Dashboard
```

---

## Teardown

To stop all lab VMs and clean up generated artifacts (`vms/`, Packer caches, and dynamic inventory):

```bash
./teardown.sh
```

The script asks for confirmation before reverting `/etc/vmware/networking` or deleting downloaded ISO files.

---

## License & Credits

This project is released under the **MIT License**. See [`LICENSE`](LICENSE).

Third-party technologies integrated into this lab (pfSense, VMware Workstation Pro, Microsoft Windows, Ubuntu, Ansible, Packer, BadBlood, Sysmon, SwiftOnSecurity Sysmon config, CrowdSec, Wazuh, Kali Linux) are governed by their respective licenses.
