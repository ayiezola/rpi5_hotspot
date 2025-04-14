#!/bin/bash

set -e

# Define network settings
SSID="VRoom"
PASSWORD="okmijn123"
WLAN_INTERFACE="wlan0"
ETH_INTERFACE="eth0"  # Change if using another interface for internet access
STATIC_IP="192.168.4.1/24"

echo "Updating package list..."
apt update

echo "Installing required packages..."
apt install -y hostapd dnsmasq iptables-persistent network-manager

echo "Configuring hostapd..."
cat > /etc/hostapd/hostapd.conf <<EOF
interface=$WLAN_INTERFACE
ssid=$SSID
hw_mode=g
channel=7
auth_algs=1
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

# Set hostapd config file path
sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd

echo "Disabling auto-connect for WiFi and setting static IP using NetworkManager..."
nmcli connection show | grep "$WLAN_INTERFACE" || nmcli device connect $WLAN_INTERFACE

CONN_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep "$WLAN_INTERFACE" | cut -d: -f1)

nmcli connection modify "$CONN_NAME" \
  ipv4.addresses "$STATIC_IP" \
  ipv4.method manual \
  connection.autoconnect yes \
  ipv4.gateway "" \
  ipv4.dns ""

nmcli connection down "$CONN_NAME"
nmcli connection up "$CONN_NAME"

echo "Configuring dnsmasq..."
cat > /etc/dnsmasq.conf <<EOF
interface=$WLAN_INTERFACE
dhcp-range=192.168.4.10,192.168.4.100,255.255.255.0,24h
EOF

echo "Enabling IP forwarding..."
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

echo "Setting up NAT..."
iptables -t nat -A POSTROUTING -o $ETH_INTERFACE -j MASQUERADE
iptables -A FORWARD -i $ETH_INTERFACE -o $WLAN_INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i $WLAN_INTERFACE -o $ETH_INTERFACE -j ACCEPT

echo "Saving iptables rules..."
iptables-save > /etc/iptables/rules.v4

echo "Setting up rc.local fallback IP assignment..."

# Create /etc/rc.local if it doesn't exist
if [ ! -f /etc/rc.local ]; then
    cat > /etc/rc.local <<EOF
#!/bin/bash
exit 0
EOF
fi

# Insert static IP assignment before 'exit 0'
sed -i "/^exit 0/i ip link set $WLAN_INTERFACE up\nip addr add $STATIC_IP dev $WLAN_INTERFACE" /etc/rc.local

chmod +x /etc/rc.local

# Enable rc.local service if needed
if ! systemctl is-enabled rc-local >/dev/null 2>&1; then
    cat > /etc/systemd/system/rc-local.service <<EOF
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local

[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable rc-local
    systemctl start rc-local
fi

echo "Restarting services..."
systemctl unmask hostapd
systemctl restart hostapd
systemctl restart dnsmasq
systemctl enable hostapd
systemctl enable dnsmasq

echo "WiFi Access Point setup complete!"
echo "SSID: $SSID"
echo "Password: $PASSWORD"
echo "Static IP assigned to $WLAN_INTERFACE: $STATIC_IP (with rc.local fallback)"
