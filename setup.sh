#!/usr/bin/env bash
set -euo pipefail

# TeamSpeak 6 Server - Hetzner VPS Setup Script
# Run as root on a fresh Ubuntu 24.04 LTS server
#
# Usage: ssh root@YOUR_SERVER_IP 'bash -s' < setup.sh

echo "=== TeamSpeak 6 Server Setup ==="

# --- System updates ---
echo "[1/6] Updating system..."
apt-get update -qq && apt-get upgrade -y -qq

# --- Create non-root user ---
echo "[2/6] Creating ts-admin user..."
if ! id "ts-admin" &>/dev/null; then
    adduser --disabled-password --gecos "" ts-admin
    usermod -aG sudo ts-admin
    # Copy SSH keys from root so you can still log in
    mkdir -p /home/ts-admin/.ssh
    cp /root/.ssh/authorized_keys /home/ts-admin/.ssh/authorized_keys
    chown -R ts-admin:ts-admin /home/ts-admin/.ssh
    chmod 700 /home/ts-admin/.ssh
    chmod 600 /home/ts-admin/.ssh/authorized_keys
    # Allow passwordless sudo for initial setup
    echo "ts-admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ts-admin
fi

# --- Install Docker ---
echo "[3/6] Installing Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ts-admin
fi

# --- Firewall ---
echo "[4/6] Configuring UFW firewall..."
apt-get install -y -qq ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 9987/udp comment 'TeamSpeak Voice'
ufw allow 30033/tcp comment 'TeamSpeak File Transfer'
ufw --force enable

# --- Fail2ban ---
echo "[5/6] Installing fail2ban..."
apt-get install -y -qq fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# --- Harden SSH ---
echo "[6/6] Hardening SSH..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Log in as: ssh ts-admin@$(curl -s ifconfig.me)"
echo "  2. Copy docker-compose.yaml to the server"
echo "  3. Run: docker compose up -d"
echo "  4. Get your admin token: docker logs teamspeak-server"
echo ""
echo "IMPORTANT: Root login is now disabled. Use ts-admin from now on."
