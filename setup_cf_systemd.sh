#!/usr/bin/env bash
# Cloudflare Tunnel Setup (systemd mode)
# Version: 1.1
# Description: Installs and configures Cloudflare Tunnel on Linux using systemd

set -euo pipefail
IFS=$'\n\t'

#-----------------------------------
# Logging
#-----------------------------------
log() { echo -e "\e[1;32m[INFO]\e[0m  $*"; }
error() {
    echo -e "\e[1;31m[ERROR]\e[0m $*" >&2
    exit 1
}

#-----------------------------------
# Root check
#-----------------------------------
[[ $(id -u) -eq 0 ]] || error "This script must be run as root."

#-----------------------------------
# Environment variables
#-----------------------------------
TUNNEL_NAME="${TUNNEL_NAME:-}"
DOMAIN="${DOMAIN:-}"
SUBDOMAINS="${SUBDOMAINS:-}"
HOSTS="${HOSTS:-}"

#-----------------------------------
# Input validation
#-----------------------------------
if [[ -n "$HOSTS" && (-n "$SUBDOMAINS" || -n "$DOMAIN") ]]; then
    error "Cannot use both HOSTS and SUBDOMAINS/DOMAIN. Choose one method."
fi

# Prompt for tunnel name if not set
[[ -n "$TUNNEL_NAME" ]] || read -rp "Enter tunnel name: " TUNNEL_NAME

# Prompt for required inputs
if [[ -z "$HOSTS" ]]; then
    if [[ -n "$SUBDOMAINS" && -z "$DOMAIN" ]]; then
        read -rp "Enter your domain (e.g. example.com): " DOMAIN
    elif [[ -z "$SUBDOMAINS" && -z "$DOMAIN" ]]; then
        error "You must define either HOSTS or SUBDOMAINS + DOMAIN."
    fi
fi

#-----------------------------------
# Setup directories and user
#-----------------------------------
CFG_DIR="/etc/cloudflared"
mkdir -p "$CFG_DIR" || error "Failed to create config directory"
log "Creating system user and setting permissions"
id cloudflared &>/dev/null || useradd --system --shell /usr/sbin/nologin --home-dir "$CFG_DIR" cloudflared
chown -R cloudflared:cloudflared "$CFG_DIR"
chmod 700 "$CFG_DIR"

#-----------------------------------
# Install dependencies
#-----------------------------------
log "Installing dependencies"
if command -v apt-get &>/dev/null; then
    apt-get update && apt-get install -y wget curl jq
elif command -v yum &>/dev/null; then
    yum install -y wget curl jq
elif command -v dnf &>/dev/null; then
    dnf install -y wget curl jq
else
    error "Unsupported package manager"
fi

#-----------------------------------
# Download cloudflared
#-----------------------------------
ARCH=$(uname -m)
case "$ARCH" in
x86_64) ARCH=amd64 ;;
aarch64 | arm64) ARCH=arm64 ;;
armv7l | armhf) ARCH=arm ;;
*) error "Unsupported architecture: $ARCH" ;;
esac

log "Fetching latest cloudflared release"
resp=$(curl -sL -w "%{http_code}" -o /tmp/cf.json https://api.github.com/repos/cloudflare/cloudflared/releases/latest)
[[ "$resp" -eq 200 ]] || error "Failed to fetch release info"
VER=$(jq -r .tag_name /tmp/cf.json)
rm -f /tmp/cf.json

bin="/usr/local/bin/cloudflared"
log "Downloading cloudflared $VER ($ARCH)"
wget -q "https://github.com/cloudflare/cloudflared/releases/download/$VER/cloudflared-linux-$ARCH" -O "$bin" || error "Download failed"
chmod +x "$bin"

#-----------------------------------
# Authenticate
#-----------------------------------
log "Authenticating with Cloudflare"
sudo -u cloudflared "$bin" tunnel login || error "Authentication failed"

#-----------------------------------
# Create tunnel
#-----------------------------------
log "Creating tunnel '$TUNNEL_NAME'"
json=$(sudo -u cloudflared "$bin" tunnel create --output json "$TUNNEL_NAME") || error "Tunnel creation failed"
TUNNEL_ID=$(jq -r .id <<<"$json")
[[ -n "$TUNNEL_ID" && "$TUNNEL_ID" != "null" ]] || error "Failed to get Tunnel ID"
log "Tunnel ID: $TUNNEL_ID"

#-----------------------------------
# Generate config
#-----------------------------------
CFG="$CFG_DIR/config.yml"
CREDS="$CFG_DIR/$TUNNEL_ID.json"

log "Generating config: $CFG"
{
    echo "tunnel: $TUNNEL_ID"
    echo "credentials-file: $CREDS"
    echo "ingress:"

    if [[ -n "$HOSTS" ]]; then
        IFS=',' read -ra HOST_ENTRIES <<<"$HOSTS"
        for entry in "${HOST_ENTRIES[@]}"; do
            IFS=':' read -r host service <<<"$entry"
            echo "  - hostname: $host"
            echo "    service: $service"
        done
    else
        IFS=',' read -ra SUBDOMAINS <<<"$SUBDOMAINS"
        for sub in "${SUBDOMAINS[@]}"; do
            [[ -n "$sub" ]] || continue
            echo "  - hostname: $sub.$DOMAIN"
            echo "    service: http://localhost:${sub##*:}" # Simple port detection
        done
    fi

    echo "  - service: http_status:404"
} >"$CFG"

chown cloudflared:cloudflared "$CFG"
chmod 600 "$CFG"

#-----------------------------------
# Setup systemd service
#-----------------------------------
SVC_FILE="/etc/systemd/system/cloudflared.service"
log "Creating systemd service"
cat >"$SVC_FILE" <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
User=cloudflared
ExecStart=$bin tunnel --config $CFG run
Restart=always
RestartSec=5
EnvironmentFile=/etc/default/cloudflared

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloudflared || error "Service setup failed"

#-----------------------------------
# DNS Routing
#-----------------------------------
if [[ -n "$SUBDOMAINS" ]]; then
    log "Setting up DNS records"
    IFS=',' read -ra SUBDOMAINS <<<"$SUBDOMAINS"
    for sub in "${SUBDOMAINS[@]}"; do
        [[ -n "$sub" ]] || continue
        fqdn="$sub.$DOMAIN"
        log "Creating DNS record for $fqdn"
        sudo -u cloudflared "$bin" tunnel route dns "$TUNNEL_ID" "$fqdn" || error "DNS routing failed for $fqdn"
    done
fi

#-----------------------------------
# Completion
#-----------------------------------
cat <<EOF

✅ Setup completed successfully!
Tunnel Name: $TUNNEL_NAME
Tunnel ID:  $TUNNEL_ID
Config File: $CFG

To check service status:
sudo systemctl status cloudflared

To view logs:
journalctl -u cloudflared -f
EOF
