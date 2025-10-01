#!/bin/bash

# Configuration Variables
VPN_SUBNET="10.0.0.0/24"
SERVER_WG_IP="10.0.0.1"
CLIENT_WG_IP="10.0.0.2"
WG_PORT="51820"
DNS_SERVERS="1.1.1.1,1.0.0.1"

# Automatically detect external network interface
EXT_NIC=$(ip -o -4 route show to default | awk '{print $5}')
if [ -z "$EXT_NIC" ]; then
    echo "Error: Could not automatically determine the external network interface."
    exit 1
fi

echo "--- Starting WireGuard installation and configuration ---"

# Install WireGuard and dependencies
echo "1. Installing WireGuard and dependencies..."
sudo dnf install -y wireguard-tools qrencode
sudo dnf install -y iptables-legacy

# Generate Server and Client Keys
echo "2. Generating server and client keys..."
umask 077
wg genkey | sudo tee /etc/wireguard/server_private.key > /dev/null
sudo chmod 600 /etc/wireguard/server_private.key
sudo cat /etc/wireguard/server_private.key | wg pubkey | sudo tee /etc/wireguard/server_public.key > /dev/null

wg genkey | sudo tee /etc/wireguard/client_private.key > /dev/null
sudo chmod 600 /etc/wireguard/client_private.key
sudo cat /etc/wireguard/client_private.key | wg pubkey | sudo tee /etc/wireguard/client_public.key > /dev/null

SERVER_PRIVATE_KEY=$(sudo cat /etc/wireguard/server_private.key)
SERVER_PUBLIC_KEY=$(sudo cat /etc/wireguard/server_public.key)
CLIENT_PUBLIC_KEY=$(sudo cat /etc/wireguard/client_public.key)

# Configure the WireGuard Server
echo "3. Creating server configuration file (/etc/wireguard/wg0.conf)..."
sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
Address = $SERVER_WG_IP/24
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVATE_KEY
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $EXT_NIC -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $EXT_NIC -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_WG_IP/32
EOF

# Enable IP Forwarding
echo "4. Enabling IP forwarding..."
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
sudo sh -c 'echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-wireguard.conf'
sudo sysctl -p

# Enable and Start the WireGuard Service
echo "5. Enabling and starting WireGuard service..."
sudo systemctl enable --now wg-quick@wg0
sudo systemctl start wg-quick@wg0

echo "WireGuard server setup complete."
sudo wg show wg0

# Generate Client Configuration
echo "6. Generating client configuration..."
EC2_PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)

sudo tee /etc/wireguard/client1.conf > /dev/null << EOF
[Interface]
PrivateKey = $(sudo cat /etc/wireguard/client_private.key)
Address = $CLIENT_WG_IP/32
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $EC2_PUBLIC_IP:$WG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

echo "--- Client Configuration QR Code ---"
echo "Scan this QR code with your WireGuard client app to connect."
qrencode -t ansiutf8 < /etc/wireguard/client1.conf

echo "--- Client Configuration File ---"
echo "The client configuration file is located at /etc/wireguard/client1.conf"
echo "Copy its contents for desktop clients."
