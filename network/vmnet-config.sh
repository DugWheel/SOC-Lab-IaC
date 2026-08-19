set -euo pipefail

VMWARE_NET_CONF="/etc/vmware/networking"

echo "[*] Current VMware network service status:"
systemctl list-units | grep -i vmware || true

echo
echo "[*] /etc/vmware/networking içeriği:"
cat "$VMWARE_NET_CONF" 2>/dev/null || echo "File not found!"

echo
echo "[*] VMnet interfaces (host side):"
ip a | grep -i vmnet || echo "No vmnet interface visible yet, the service might need to be started."

echo
echo "To restart the service:"
echo "  sudo systemctl restart vmware-networks   # or"
echo "  sudo vmware-networks --stop && sudo vmware-networks --start"
