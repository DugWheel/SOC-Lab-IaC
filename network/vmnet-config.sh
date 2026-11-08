#!/usr/bin/env bash
# =========================================================
# vmnet-config.sh
# Read-only diagnostics for the VMware host-only networks
# (vmnet2 = LAN, vmnet3 = DMZ). Shows the service status, the contents of
# /etc/vmware/networking and the host-side vmnet interfaces.
#
# Usage: ./network/vmnet-config.sh
# =========================================================
set -euo pipefail

VMWARE_NET_CONF="/etc/vmware/networking"

echo "[*] VMware network service status:"
systemctl list-units 2>/dev/null | grep -i vmware || echo "  (no vmware-networks unit found)"

echo
echo "[*] Contents of ${VMWARE_NET_CONF}:"
cat "$VMWARE_NET_CONF" 2>/dev/null || echo "  File not found (run with sudo to read it)."

echo
echo "[*] Host-side vmnet interfaces:"
ip -brief addr show 2>/dev/null | grep -i vmnet \
    || echo "  (no vmnet interface visible yet; the service may need to be started)"

echo
echo "To (re)start the VMware network service:"
echo "  sudo systemctl restart vmware-networks   # or"
echo "  sudo vmware-networks --stop && sudo vmware-networks --start"
