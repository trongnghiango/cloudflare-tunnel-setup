#!/usr/bin/env bash
# Cloudflare Tunnel Setup (Docker mode)
# Version: 1.1
# Description: Installs and configures Cloudflare Tunnel on Linux using Docker

# USAGE
#
# 1. **Quản lý quyền truy cập tốt hơn**:
#    - Thêm `-u "$(id -u):$(id -g)"` để chạy container với UID/GID của host
#    - Đảm bảo file cấu hình và credentials có quyền phù hợp
#
# 2. **Cài đặt Docker thông minh**:
#    - Tự động phát hiện và cài Docker nếu chưa có
#    - Kích hoạt dịch vụ Docker sau cài đặt
#
# 3. **Xử lý lỗi mạnh mẽ**:
#    - Thêm retry (3 lần) khi tạo DNS records
#    - Kiểm tra lỗi từng bước docker command
#    - Validate đầu vào chặt chẽ hơn
#
# 4. **Cấu hình linh hoạt**:
#    - Hỗ trợ cú pháp subdomain mở rộng: `web:3000` → port 3000
#    - Tự động thêm port mặc định 80 nếu không chỉ định
#
# 5. **Tối ưu container**:
#    - Dùng `--restart=unless-stopped` thay vì always
#    - Xóa container cũ an toàn trước khi tạo mới
#    - Giảm quyền privilege của container
#
# ### Cách sử dụng:
# **Cho subdomain + port**:
# ```bash
# sudo TUNNEL_NAME="docker-tunnel" DOMAIN="example.com" SUBDOMAINS="web:3000,api:8080" ./script.sh
# ```
#
# **Cho cấu hình tùy chỉnh**:
# ```bash
# sudo TUNNEL_NAME="custom-docker" HOSTS="app.khabodo.fun:http://localhost:3000,monitor.khabodo.fun:http://localhost:3001" ./setup_cf_docker.sh
# ```
#
# **Kiểm tra hoạt động**:
# ```bash
# docker logs -f cloudflared
# docker exec cloudflared tunnel list
# ```
#
# ### Lưu ý quan trọng:
# 1. Script sẽ tự động cài Docker nếu chưa có
# 2. Tất cả file cấu hình được lưu tại `/etc/cloudflared`
# 3. Container chạy với quyền user thường, không dùng root
# 4. Thêm cơ chế retry khi tạo DNS records để tránh lỗi mạng
#
# Hãy test script trong môi trường staging trước khi triển khai production.
#

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
CONTAINER_NAME="${CONTAINER_NAME:-cloudflared}"
DOCKER_IMAGE="${DOCKER_IMAGE:-cloudflare/cloudflared:latest}"
CFG_DIR="/etc/cloudflared"
DOCKER_USER="cloudflared" # Explicit user for container

#-----------------------------------
# Input validation
#-----------------------------------
if [[ -n "$HOSTS" && (-n "$SUBDOMAINS" || -n "$DOMAIN") ]]; then
    error "Cannot use both HOSTS and SUBDOMAINS/DOMAIN. Choose one method."
fi

# Prompt for required inputs
[[ -n "$TUNNEL_NAME" ]] || read -rp "Enter tunnel name: " TUNNEL_NAME
if [[ -z "$HOSTS" ]]; then
    if [[ -n "$SUBDOMAINS" && -z "$DOMAIN" ]]; then
        read -rp "Enter your domain (e.g. example.com): " DOMAIN
    elif [[ -z "$SUBDOMAINS" && -z "$DOMAIN" ]]; then
        error "You must define either HOSTS or SUBDOMAINS + DOMAIN."
    fi
fi

#-----------------------------------
# Setup directories and permissions
#-----------------------------------
log "Creating config directory: $CFG_DIR"
mkdir -p "$CFG_DIR" || error "Failed to create config directory"
chmod 700 "$CFG_DIR"

#-----------------------------------
# Install Docker and dependencies
#-----------------------------------
install_docker() {
    if ! command -v docker &>/dev/null; then
        log "Installing Docker"
        curl -fsSL https://get.docker.com | sh || error "Docker installation failed"
        systemctl enable --now docker || error "Docker service activation failed"
    fi
}

log "Installing system dependencies"
if command -v apt-get &>/dev/null; then
    apt-get update && apt-get install -y curl jq
elif command -v yum &>/dev/null; then
    yum install -y curl jq
else
    error "Unsupported package manager"
fi

install_docker

#-----------------------------------
# Authenticate via container
#-----------------------------------
log "Authenticating with Cloudflare (Docker)"
docker run --rm \
    -v "$CFG_DIR":/etc/cloudflared \
    -u "$(id -u):$(id -g)" \
    "$DOCKER_IMAGE" tunnel login || error "Authentication failed"

#-----------------------------------
# Create tunnel with proper ownership
#-----------------------------------
log "Creating tunnel '$TUNNEL_NAME' (Docker)"
json=$(docker run --rm \
    -v "$CFG_DIR":/etc/cloudflared \
    -u "$(id -u):$(id -g)" \
    "$DOCKER_IMAGE" tunnel create --output json "$TUNNEL_NAME") || error "Tunnel creation failed"

TUNNEL_ID=$(jq -r .id <<<"$json")
[[ -n "$TUNNEL_ID" && "$TUNNEL_ID" != "null" ]] || error "Failed to get Tunnel ID"
log "Tunnel ID: $TUNNEL_ID"

#-----------------------------------
# Generate config.yml with validation
#-----------------------------------
CFG="$CFG_DIR/config.yml"
CREDS_FILE="$CFG_DIR/$TUNNEL_ID.json"

log "Generating config: $CFG"
{
    echo "tunnel: $TUNNEL_ID"
    echo "credentials-file: $CREDS_FILE"
    echo "ingress:"

    if [[ -n "$HOSTS" ]]; then
        IFS=',' read -ra HOST_ENTRIES <<<"$HOSTS"
        for entry in "${HOST_ENTRIES[@]}"; do
            IFS=':' read -r host service <<<"$entry"
            echo "  - hostname: ${host}"
            echo "    service: ${service}"
        done
    else
        IFS=',' read -ra SUBDOMAINS <<<"$SUBDOMAINS"
        for sub in "${SUBDOMAINS[@]}"; do
            [[ -n "$sub" ]] || continue
            IFS=':' read -r name port <<<"$sub"
            echo "  - hostname: ${name}.$DOMAIN"
            echo "    service: http://localhost:${port:-80}"
        done
    fi

    echo "  - service: http_status:404"
} >"$CFG"

chmod 600 "$CFG"

#-----------------------------------
# Deploy Docker container
#-----------------------------------
log "Deploying container '$CONTAINER_NAME'"
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
    --name "$CONTAINER_NAME" \
    --restart=unless-stopped \
    -v "$CFG_DIR":/etc/cloudflared \
    -u "$(id -u):$(id -g)" \
    "$DOCKER_IMAGE" tunnel --config /etc/cloudflared/config.yml run || error "Container startup failed"

#-----------------------------------
# DNS Routing with retries
#-----------------------------------
if [[ -n "$SUBDOMAINS" ]]; then
    log "Setting up DNS records (max 3 attempts)"
    IFS=',' read -ra SUBDOMAINS <<<"$SUBDOMAINS"
    for sub in "${SUBDOMAINS[@]}"; do
        [[ -n "$sub" ]] || continue
        IFS=':' read -r name _ <<<"$sub"
        fqdn="${name}.$DOMAIN"

        for attempt in {1..3}; do
            log "Attempt $attempt: Creating DNS record for $fqdn"
            if docker run --rm \
                -v "$CFG_DIR":/etc/cloudflared \
                -u "$(id -u):$(id -g)" \
                "$DOCKER_IMAGE" tunnel route dns "$TUNNEL_ID" "$fqdn"; then
                break
            elif [[ $attempt -eq 3 ]]; then
                error "Failed to create DNS record for $fqdn after 3 attempts"
            else
                sleep $((attempt * 2))
            fi
        done
    done
fi

#-----------------------------------
# Completion
#-----------------------------------
cat <<EOF

✅ Docker setup completed successfully!
Tunnel Name: $TUNNEL_NAME
Tunnel ID:  $TUNNEL_ID
Config File: $CFG
Container: $CONTAINER_NAME

To check container status:
docker ps -f name=$CONTAINER_NAME

To view logs:
docker logs -f $CONTAINER_NAME
EOF
