#!/bin/bash

# Thanks AI.. No, seriously, don't trust this as is. It's a helpful start on what needs to be run

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (e.g., sudo bash $0)"
  exit 1
fi

echo "=== NUT Server & PeaNUT Backend Automated Setup ==="
echo ""

# Prompt for configuration variables (with sensible defaults)
read -p "Enter a short name for your UPS [myups]: " UPS_NAME
UPS_NAME=${UPS_NAME:-myups}

read -p "Enter a friendly description [My UPS]: " UPS_DESC
UPS_DESC=${UPS_DESC:-"My UPS"}

read -p "Enter the NUT username for PeaNUT [observer]: " NUT_USER
NUT_USER=${NUT_USER:-observer}

read -s -p "Enter a password for '$NUT_USER': " NUT_PASS
echo ""
if [ -z "$NUT_PASS" ]; then
    echo "Error: Password cannot be empty."
    exit 1
fi

read -s -p "Enter an admin password (for NUT management): " ADMIN_PASS
echo ""
ADMIN_PASS=${ADMIN_PASS:-$NUT_PASS}

echo ""
echo "[1/6] Updating packages and installing NUT..."
apt-get update -qq
apt-get install -y nut nut-client nut-server usbutils

echo "[2/6] Scanning for connected USB UPS..."
# Run nut-scanner to automatically extract driver, vendorid, and productid
SCAN_OUTPUT=$(nut-scanner -Uu 2>/dev/null)

DRIVER=$(echo "$SCAN_OUTPUT" | grep -m1 "driver =" | awk -F'"' '{print $2}')
VENDORID=$(echo "$SCAN_OUTPUT" | grep -m1 "vendorid =" | awk -F'"' '{print $2}')
PRODUCTID=$(echo "$SCAN_OUTPUT" | grep -m1 "productid =" | awk -F'"' '{print $2}')

# Fallback to generic usbhid-ups if scanner doesn't return explicit IDs
DRIVER=${DRIVER:-usbhid-ups}

echo " -> Detected Driver: $DRIVER"
[ -n "$VENDORID" ] && echo " -> Vendor ID: $VENDORID"
[ -n "$PRODUCTID" ] && echo " -> Product ID: $PRODUCTID"

echo "[3/6] Backing up existing configuration files..."
BACKUP_DIR="/etc/nut/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/nut/*.conf /etc/nut/upsd.users "$BACKUP_DIR/" 2>/dev/null

echo "[4/6] Writing NUT configuration files..."

# 1. Configure nut.conf
cat <<EOF > /etc/nut/nut.conf
MODE=netserver
EOF

# 2. Configure ups.conf
cat <<EOF > /etc/nut/ups.conf
maxretry = 3

[$UPS_NAME]
    driver = $DRIVER
    port = auto
    desc = "$UPS_DESC"
EOF

# Append Vendor/Product IDs if they were detected
[ -n "$VENDORID" ] && echo "    vendorid = $VENDORID" >> /etc/nut/ups.conf
[ -n "$PRODUCTID" ] && echo "    productid = $PRODUCTID" >> /etc/nut/ups.conf

# 3. Configure upsd.conf
cat <<EOF > /etc/nut/upsd.conf
LISTEN 0.0.0.0 3493
EOF

# 4. Configure upsd.users
cat <<EOF > /etc/nut/upsd.users
[$NUT_USER]
    password = $NUT_PASS
    upsmon primary

[admin]
    password = $ADMIN_PASS
    actions = set
    instcmd = all
EOF

# 5. Configure upsmon.conf
cat <<EOF > /etc/nut/upsmon.conf
MONITOR $UPS_NAME@localhost 1 $NUT_USER $NUT_PASS primary
MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h +0"
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower
NOTIFYFLAG ONLINE   SYSLOG+WALL
NOTIFYFLAG ONBATT   SYSLOG+WALL
NOTIFYFLAG LOWBATT  SYSLOG+WALL
NOTIFYFLAG FSD      SYSLOG+WALL
NOTIFYFLAG COMMOK   SYSLOG+WALL
NOTIFYFLAG COMMBAD  SYSLOG+WALL
NOTIFYFLAG SHUTDOWN SYSLOG+WALL
NOTIFYFLAG REPLBATT SYSLOG+WALL
NOTIFYFLAG NOCOMM   SYSLOG+WALL
NOTIFYFLAG NOPARENT SYSLOG+WALL
RBWARNTIME 43200
NOCOMMWARNTIME 300
FINALDELAY 5
EOF

echo "[5/6] Setting secure file permissions..."
chown root:nut /etc/nut/*
chmod 640 /etc/nut/*

echo "[6/6] Restarting and enabling NUT services..."
# Restart udev to ensure USB permissions are applied to the UPS device
udevadm control --reload-rules && udevadm trigger

upsdrvctl stop >/dev/null 2>&1
upsdrvctl start

systemctl restart nut-server
systemctl restart nut-client
systemctl restart nut-monitor

systemctl enable nut-server nut-client nut-monitor >/dev/null 2>&1

# Get local IP address for user convenience
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "====================================================="
echo "Setup Complete! Verify your UPS status below:"
echo "====================================================="
upsc "$UPS_NAME@localhost" | head -n 10
echo "..."
echo "====================================================="
echo "PeaNUT Connection Details:"
echo "  Server IP: $SERVER_IP"
echo "  Port:      3493"
echo "  Username:  $NUT_USER"
echo "  Password:  (the password you entered)"
echo "====================================================="
