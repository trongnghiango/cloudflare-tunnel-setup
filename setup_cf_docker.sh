#!/usr/bin/env bash
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
# Check dependencies
#-----------------------------------
command -v docker >/dev/null 2>&1 || error "Docker is required but not installed."
command -v jq >/dev/null 2>&1 || error "jq is required but not installed."

# Kiểm tra dig (tùy chọn, cho kiểm tra DNS)
DIG_AVAILABLE=0
command -v dig >/dev/null 2>&1 && DIG_AVAILABLE=1

########## 1. Kiểm tra root ##########
if [[ $(id -u) -ne 0 ]]; then
    error "Please run as root or via sudo"
fi

########## 2. Biến môi trường ##########
TUNNEL_NAME="${TUNNEL_NAME:-}"
DOMAIN="${DOMAIN:-}"
SUBDOMAINS="${SUBDOMAINS:-}"
HOSTS="${HOSTS:-}"
TIMESTAMP=$(date +%s)
CONTAINER_NAME="${CONTAINER_NAME:-cloudflared-${TUNNEL_NAME}-${TIMESTAMP}}"
DOCKER_IMAGE="${DOCKER_IMAGE:-cloudflare/cloudflared:latest}"
CFG_DIR="/etc/cloudflared"

# Trim whitespace từ các biến
TUNNEL_NAME=$(echo "${TUNNEL_NAME}" | xargs)
DOMAIN=$(echo "${DOMAIN}" | xargs)
SUBDOMAINS=$(echo "${SUBDOMAINS}" | xargs)
HOSTS=$(echo "${HOSTS}" | xargs)

# Debug: In giá trị biến
log "Input values: TUNNEL_NAME='$TUNNEL_NAME', HOSTS='$HOSTS', SUBDOMAINS='$SUBDOMAINS', DOMAIN='$DOMAIN'"

# Kiểm tra TUNNEL_NAME
if [[ -z "$TUNNEL_NAME" ]]; then
    read -rp "Enter tunnel name: " TUNNEL_NAME
    TUNNEL_NAME=$(echo "${TUNNEL_NAME}" | xargs)
fi
[[ -z "$TUNNEL_NAME" ]] && error "Tunnel name cannot be empty."

# Input validation
if [[ -n "$HOSTS" ]]; then
    # Kiểm tra định dạng HOSTS
    IFS=',' read -ra hosts_array <<< "$HOSTS"
    for host in "${hosts_array[@]}"; do
        host=$(echo "${host}" | xargs)
        [[ -z "$host" ]] && continue
        if [[ ! "$host" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            error "Invalid hostname format: $host"
        fi
        # Kiểm tra DNS (tùy chọn)
        if [[ $DIG_AVAILABLE -eq 1 ]]; then
            if ! dig +short "$host" >/dev/null; then
                log "Warning: Hostname $host not found in DNS (NXDOMAIN). Ensure it is configured in Cloudflare."
            fi
        fi
    done
    # Nếu HOSTS được cung cấp, SUBDOMAINS và DOMAIN không được set
    if [[ -n "$SUBDOMAINS" || -n "$DOMAIN" ]]; then
        error "Cannot use both HOSTS and SUBDOMAINS/DOMAIN. Choose one method."
    fi
else
    # Yêu cầu SUBDOMAINS và DOMAIN
    if [[ -z "$SUBDOMAINS" ]]; then
        read -rp "Enter subdomains (comma-separated, e.g. app,monitor): " SUBDOMAINS
        SUBDOMAINS=$(echo "${SUBDOMAINS}" | xargs)
    fi
    if [[ -z "$DOMAIN" ]]; then
        read -rp "Enter domain (e.g. example.com): " DOMAIN
        DOMAIN=$(echo "${DOMAIN}" | xargs)
    fi
    [[ -z "$SUBDOMAINS" ]] && error olmas "Subdomains cannot be empty."
    [[ -z "$DOMAIN" ]] && error "Domain cannot be empty."
    # Validate domain format
    if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        error "Invalid domain format: $DOMAIN"
    fi
fi

########## 3. Tạo thư mục và gán quyền ##########
log "Creating configuration directory..."
mkdir -p "$CFG_DIR" || error "Failed to create directory: $CFG_DIR"
chown 65532:65532 "$CFG_DIR" || error "Failed to chown directory: $CFG_DIR"
chmod 700 "$CFG_DIR" || error "Failed to chmod directory: $CFG_DIR"

# Xóa các file cụ thể
rm -f "$CFG_DIR/cert.pem" "$CFG_DIR/*.json" "$CFG_DIR/config.yml" 2>/dev/null || true

sleep 1

########## 4. Đăng nhập Cloudflare (sinh cert.pem) ##########
log "Running tunnel login..."
docker run --rm \
    -v "$CFG_DIR:/home/nonroot/.cloudflared" \
    --user 65532:65532 \
    "$DOCKER_IMAGE" tunnel login || error "Tunnel login failed"

# Kiểm tra cert.pem
if [[ ! -f "$CFG_DIR/cert.pem" ]]; then
    error "cert.pem not found after login: $CFG_DIR/cert.pem"
fi
log "cert.pem created in $CFG_DIR"

########## 5. Tạo tunnel (sinh credentials JSON) ##########
log "Creating tunnel '$TUNNEL_NAME'..."
json_output=$(docker run --rm \
    -v "$CFG_DIR:/home/nonroot/.cloudflared" \
    --user 65532:65532 \
    "$DOCKER_IMAGE" tunnel create --output json "$TUNNEL_NAME") || error "Failed to create tunnel"

# Trích xuất TUNNEL_ID
TUNNEL_ID=$(echo "$json_output" | jq -r .id) || error "Failed to parse tunnel ID"
[[ -n "$TUNNEL_ID" ]] || error "Tunnel ID is empty"

# Đường dẫn file credentials
CRED_BASENAME="${TUNNEL_ID}.json"
CREDS_HOST_PATH="$CFG_DIR/$CRED_BASENAME"

# Kiểm tra file credentials
if [[ ! -f "$CREDS_HOST_PATH" ]]; then
    error "Credentials file not found: $CREDS_HOST_PATH"
fi

# Phân quyền file credentials
chown 65532:65532 "$CREDS_HOST_PATH" || error "Failed to chown credentials file"
chmod 600 "$CREDS_HOST_PATH" || error "Failed to chmod credentials file"

log "Tunnel ID: $TUNNEL_ID"
log "Credentials file: $CREDS_HOST_PATH"

########## 6. Tạo file config.yml ##########
# Danh sách TLD phổ biến
TLD_LIST=("com.vn" "co.uk" "org.vn" "net.vn" "edu.vn" "gov.vn" "com" "net" "org" "vn" "uk")

# Hàm xác định domain và subdomain
extract_domain_subdomain() {
    local fqdn="$1"
    for tld in "${TLD_LIST[@]}"; do
        if [[ "$fqdn" == *.$tld ]]; then
            domain="${fqdn##*.${tld}}.${tld}"
            subdomain="${fqdn%.$domain}"
            echo "$subdomain|$domain"
            return
        fi
    done
    domain=$(echo "$fqdn" | awk -F. '{print $(NF-1)"."$NF}')
    subdomain="${fqdn%.$domain}"
    echo "$subdomain|$domain"
}

# Đường dẫn file config
CFG_FILE="$CFG_DIR/config.yml"

# Khởi tạo file config
{
    echo "tunnel: $TUNNEL_ID"
    echo "credentials-file: /home/nonroot/.cloudflared/$TUNNEL_ID.json"
    echo ""
    echo "ingress:"
} > "$CFG_FILE" || error "Failed to create config.yml"

# Tạo danh sách hostname và service
declare -A HOSTS_SERVICES

if [[ -n "$HOSTS" ]]; then
    # Parse HOSTS
    IFS=',' read -ra hosts_array <<< "$HOSTS"
    for host in "${hosts_array[@]}"; do
        host=$(echo "${host}" | xargs)
        [[ -z "$host" ]] && continue
        log "Processing hostname: $host"
        # Kiểm tra định dạng hostname
        if [[ ! "$host" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            error "Invalid hostname format: $host"
        fi
        # Yêu cầu nhập service URL
        read -rp "Enter service URL for $host (default: http://localhost:8080): " service
        service=${service:-http://localhost:8080}
        # Kiểm tra định dạng service URL
        if [[ ! "$service" =~ ^http(s)?://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
            error "Invalid service URL format: $service"
        fi
        HOSTS_SERVICES["$host"]="$service"
    done
else
    # Parse SUBDOMAINS và ghép với DOMAIN
    IFS=',' read -ra subdomains_array <<< "$SUBDOMAINS"
    for subdomain in "${subdomains_array[@]}"; do
        subdomain=$(echo "${subdomain}" | xargs)
        [[ -z "$subdomain" ]] && continue
        host="${subdomain}.${DOMAIN}"
        log "Processing hostname: $host"
        # Kiểm tra định dạng hostname
        if [[ ! "$host" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            error "Invalid hostname format: $host"
        fi
        # Kiểm tra DNS (tùy chọn)
        if [[ $DIG_AVAILABLE -eq 1 ]]; then
            if ! dig +short "$host" >/dev/null; then
                log "Warning: Hostname $host not found in DNS (NXDOMAIN). Ensure it is configured in Cloudflare."
            fi
        fi
        # Yêu cầu nhập service URL
        read -rp "Enter service URL for $host (default: http://localhost:8080): " service
        service=${service:-http://localhost:8080}
        # Kiểm tra định dạng service URL
        if [[ ! "$service" =~ ^http(s)?://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
            error "Invalid service URL format: $service"
        fi
        HOSTS_SERVICES["$host"]="$service"
    done
fi

# Kiểm tra xem có hostname nào được định nghĩa không
if [[ ${#HOSTS_SERVICES[@]} -eq 0 ]]; then
    error "No valid hostnames defined"
fi

# Thêm ingress rules
for host in "${!HOSTS_SERVICES[@]}"; do
    service="${HOSTS_SERVICES[$host]}"
    echo "  - hostname: $host" >> "$CFG_FILE"
    echo "    service: $service" >> "$CFG_FILE"
done

# Thêm rule catch-all
echo "  - service: http_status:404" >> "$CFG_FILE"

# Phân quyền file config
chmod 600 "$CFG_FILE" || log "Warning: chmod config.yml failed"
chown 65532:65532 "$CFG_FILE" || log "Warning: chown config.yml failed"

log "Generated configuration:"
cat "$CFG_FILE"
log "------------------------"

########## 7. Chạy container tunnel ##########
log "Pulling latest Docker image $DOCKER_IMAGE..."
docker pull "$DOCKER_IMAGE" || log "Warning: Failed to pull latest image, using cached version"

log "Starting Docker container '$CONTAINER_NAME'..."
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -u 65532:65532 \
    -v "$CFG_DIR:/home/nonroot/.cloudflared" \
    --network host \
    "$DOCKER_IMAGE" tunnel --no-autoupdate --config /home/nonroot/.cloudflared/config.yml run || error "Failed to start container"

log "Waiting for tunnel to initialize..."
sleep 3

if docker ps -f name="$CONTAINER_NAME" --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
    log "[SUCCESS] Tunnel container is up and running."
else
    error seven "Container failed to start. Check logs with: docker logs -f $CONTAINER_NAME"
fi
