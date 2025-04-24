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


########## 1. Kiểm tra root ##########
if [[ $(id -u) -ne 0 ]]; then
  error "Please run as root or via sudo"
  exit 1
fi

########## 2. Biến môi trường ##########
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
        error "You must define either HOSTS or (SUBDOMAINS and DOMAIN)."
    fi
fi

# Trim whitespace from inputs
TUNNEL_NAME=$(echo "$TUNNEL_NAME" | xargs)
DOMAIN=$(echo "$DOMAIN" | xargs)
SUBDOMAINS=$(echo "$SUBDOMAINS" | xargs)
HOSTS=$(echo "$HOSTS" | xargs)

[[ -n "$TUNNEL_NAME" ]] || error "Tunnel name cannot be empty."
if [[ -z "$HOSTS" && -z "$DOMAIN" ]]; then
    error "Domain cannot be empty when using SUBDOMAINS."
fi


########## 3. Tạo thư mục và gán quyền ##########
mkdir -p "$CFG_DIR"
chown -R 65532:65532 "$CFG_DIR"

chmod 700    "$CFG_DIR"
rm -rf "$CFG_DIR/*"

sleep 1

########## 4. Đăng nhập Cloudflare (sinh cert.pem) ##########
echo "[INFO] Running tunnel login..."
docker run --rm \
  -v "$CFG_DIR:/home/nonroot/.cloudflared" \
  --user 65532:65532 \
  "$DOCKER_IMAGE" tunnel login

echo "[INFO] cert.pem should now be in $CFG_DIR"

########## 5. Tạo tunnel (sinh credentials JSON) ##########
echo "[INFO] Creating tunnel '$TUNNEL_NAME'..."
# 1. Tạo tunnel và lấy output JSON
json_output=$(docker run --rm \
  -v "$CFG_DIR:/home/nonroot/.cloudflared" \
  --user 65532:65532 \
  "$DOCKER_IMAGE" tunnel create --output json "$TUNNEL_NAME")

# 2. Trích xuất ID (UUID) từ JSON
TUNNEL_ID=$(echo "$json_output" | jq -r .id)    # Lấy UUID của tunnel :contentReference[oaicite:7]{index=7}

# 3. Sinh tên file credentials theo UUID
CRED_BASENAME="${TUNNEL_ID}.json"               # File credentials mặc định là {UUID}.json :contentReference[oaicite:8]{index=8}

# 4. Xác định đường dẫn file credentials trên host
CREDS_HOST_PATH="$CFG_DIR/$CRED_BASENAME"

# 5. Kiểm tra sự tồn tại của file
if [[ ! -f "$CREDS_HOST_PATH" ]]; then
  echo "[ERROR] Credentials file not found: $CREDS_HOST_PATH"
  exit 1
fi

# 6. Phân quyền và chủ sở hữu cho file credentials
chown 65532:65532 "$CREDS_HOST_PATH"
chmod 600    "$CREDS_HOST_PATH"

echo "[INFO] Tunnel ID: $TUNNEL_ID"
echo "[INFO] Credentials file: $CREDS_HOST_PATH"

### APPP

#-----------------------------------
# Generate config.yml with validation
#-----------------------------------




# Danh sách các domain cấp cao phổ biến
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
  # Nếu không khớp với TLD nào, giả định domain là hai phần cuối
  domain=$(echo "$fqdn" | awk -F. '{print $(NF-1)"."$NF}')
  subdomain="${fqdn%.$domain}"
  echo "$subdomain|$domain"
}

# Đường dẫn đến file config
CFG_FILE="/etc/cloudflared/config.yml"

# Khởi tạo file config
{
  echo "tunnel: $TUNNEL_ID"
  echo "credentials-file: /home/nonroot/.cloudflared/$TUNNEL_ID.json"
  echo ""
  echo "ingress:"
} > "$CFG_FILE"

# Danh sách các host và service tương ứng
declare -A HOSTS_SERVICES=(
  ["aki.com.vn"]="http://localhost:8080"
  ["monitor.aki.com.vn"]="http://localhost:8081"
)

# Thêm ingress rules cho từng host
for host in "${!HOSTS_SERVICES[@]}"; do
  service="${HOSTS_SERVICES[$host]}"
  echo "  - hostname: $host" >> "$CFG_FILE"
  echo "    service: $service" >> "$CFG_FILE"
done

# Thêm rule catch-all
echo "  - service: http_status:404" >> "$CFG_FILE"



# 4) (Tuỳ chọn) hiển thị lại
chmod 600 "$CFG_FILE"
cat "$CFG_FILE"



# 5) Phân quyền và hiển thị kết quả
chmod 600 "$CFG_FILE" || log "Warning: chmod config.yml failed."
chown "$(id -u):$(id -g)" "$CFG_FILE" || \
    log "Warning: chown config.yml failed."

log "Generated configuration:"
cat "$CFG_FILE"
log "------------------------"

### APPP


########## 7. Chạy container tunnel ##########
echo "[INFO] Starting Docker container '$CONTAINER_NAME'..."
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

#-v "$CFG_DIR/config.yml:/etc/cloudflared/config.yml" \
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -u 65532:65532 \
  -v "$CFG_DIR:/home/nonroot/.cloudflared" \
  --network host \
  "$DOCKER_IMAGE" tunnel --no-autoupdate --config /home/nonroot/.cloudflared/config.yml run 

echo "[INFO] Waiting for tunnel to initialize..."
sleep 5

if docker ps -f name="$CONTAINER_NAME" --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
  echo "[SUCCESS] Tunnel container is up and running."
else
  echo "[ERROR] Container failed to start. Check logs with:"
  echo "  docker logs -f $CONTAINER_NAME"
  exit 1
fi

