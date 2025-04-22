#!/usr/bin/env bash
# Cloudflare Tunnel Setup (Docker mode)
# Version: 1.2 (Added Arch Linux support)
# Description: Installs and configures Cloudflare Tunnel on Linux (Debian/Ubuntu, CentOS/Fedora/RHEL, Arch) using Docker

# USAGE
#
# 1. **Quản lý quyền truy cập tốt hơn**:
#    - Thêm `-u "$(id -u):$(id -g)"` để chạy container với UID/GID của host
#    - Đảm bảo file cấu hình và credentials có quyền phù hợp
#
# 2. **Cài đặt Docker thông minh**:
#    - Tự động phát hiện và cài Docker nếu chưa có (Hỗ trợ apt, yum, pacman)
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
# 1. Script sẽ tự động cài Docker nếu chưa có (bao gồm cả Arch Linux)
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
# No specific user needed inside container when using host UID/GID
# DOCKER_USER="cloudflared" # Removed for simplicity with UID/GID mapping

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

#-----------------------------------
# Setup directories and permissions
#-----------------------------------
log "Creating config directory: $CFG_DIR"
mkdir -p "$CFG_DIR" || error "Failed to create config directory $CFG_DIR"
chmod 700 "$CFG_DIR"

#-----------------------------------
# Install Docker and dependencies
#-----------------------------------
install_docker() {
    if ! command -v docker &>/dev/null; then
        log "Docker not found. Attempting installation..."
        if command -v apt-get &>/dev/null; then
            log "Detected Debian/Ubuntu based system. Installing Docker using official script."
            curl -fsSL https://get.docker.com -o get-docker.sh || error "Failed to download Docker installation script."
            sh get-docker.sh || error "Docker installation failed using get.docker.com script."
            rm get-docker.sh
        elif command -v yum &>/dev/null; then
            log "Detected RHEL/CentOS/Fedora based system. Installing Docker using official script."
            curl -fsSL https://get.docker.com -o get-docker.sh || error "Failed to download Docker installation script."
            sh get-docker.sh || error "Docker installation failed using get.docker.com script."
            rm get-docker.sh
        elif command -v pacman &>/dev/null; then
            log "Detected Arch Linux based system. Installing Docker using pacman."
            pacman -Syu --noconfirm docker || error "Docker installation failed using pacman."
        else
            error "Cannot automatically install Docker on this OS. Please install Docker manually and re-run the script."
        fi

        log "Enabling and starting Docker service..."
        systemctl enable --now docker || error "Failed to enable or start Docker service."
        log "Docker installed and started successfully."
    else
        log "Docker is already installed."
    fi

    # Verify docker is running
    if ! docker info >/dev/null 2>&1; then
        error "Docker daemon is not running. Please start it manually (e.g., systemctl start docker)."
    fi
}

log "Checking and installing system dependencies..."
if command -v apt-get &>/dev/null; then
    apt-get update >/dev/null || log "Warning: apt-get update failed, proceeding anyway."
    apt-get install -y curl jq || error "Failed to install dependencies (curl, jq) using apt-get."
elif command -v yum &>/dev/null; then
    yum install -y curl jq || error "Failed to install dependencies (curl, jq) using yum."
elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm curl jq || error "Failed to install dependencies (curl, jq) using pacman."
else
    error "Unsupported package manager. Please install 'curl' and 'jq' manually."
fi

install_docker

#-----------------------------------
# Authenticate via container
#-----------------------------------
log "Authenticating with Cloudflare (using Docker)"
log "Please follow the URL displayed below to authenticate:"
if ! docker run --rm \
    -v "$CFG_DIR:/home/nonroot/.cloudflared" \
    "$DOCKER_IMAGE" tunnel login; then # cloudflared now stores cert in /home/nonroot/.cloudflared by default in container
    error "Cloudflare authentication failed. Check the output above."
fi
log "Authentication successful."

# Correct potential permission issues after login if cert.pem was created by root inside container before
# The login command above should handle this now, but as a fallback:
find "$CFG_DIR" -name 'cert.pem' -exec chmod 600 {} \;
find "$CFG_DIR" -name 'cert.pem' -exec chown "$(id -u):$(id -g)" {} \;

#-----------------------------------
# Create tunnel with proper ownership
#-----------------------------------
TUNNEL_CRED_FILE="" # Will be set after tunnel creation
log "Creating tunnel '$TUNNEL_NAME' (using Docker)"
json_output=$(docker run --rm \
    -v "$CFG_DIR:/home/nonroot/.cloudflared" \
    "$DOCKER_IMAGE" tunnel create --output json "$TUNNEL_NAME")

if [[ $? -ne 0 || -z "$json_output" ]]; then
    error "Tunnel creation command failed or produced no output."
fi

TUNNEL_ID=$(echo "$json_output" | jq -r .id)
TUNNEL_CRED_FILE_BASENAME=$(echo "$json_output" | jq -r .credentials_file_basename) # Get the expected filename

if [[ -z "$TUNNEL_ID" || "$TUNNEL_ID" == "null" ]]; then
    error "Failed to get Tunnel ID from Cloudflare API response."
fi
if [[ -z "$TUNNEL_CRED_FILE_BASENAME" || "$TUNNEL_CRED_FILE_BASENAME" == "null" ]]; then
    error "Failed to get Tunnel credentials filename from Cloudflare API response."
fi

# Construct the expected path inside the *host* directory
CREDS_FILE_HOST_PATH="$CFG_DIR/$TUNNEL_CRED_FILE_BASENAME"

log "Tunnel ID: $TUNNEL_ID"
log "Expected credentials file: $CREDS_FILE_HOST_PATH"

# Verify the credentials file exists on the host
if [[ ! -f "$CREDS_FILE_HOST_PATH" ]]; then
    # Sometimes the file might be in the root of the mapped volume if permissions were odd
    ALT_CREDS_PATH="$CFG_DIR/${TUNNEL_ID}.json"
    if [[ -f "$ALT_CREDS_PATH" ]]; then
        log "Warning: Credentials file found at $ALT_CREDS_PATH instead of expected $TUNNEL_CRED_FILE_BASENAME. Using it."
        CREDS_FILE_HOST_PATH="$ALT_CREDS_PATH"
        TUNNEL_CRED_FILE_BASENAME="${TUNNEL_ID}.json" # Update basename
    else
        error "Tunnel credentials file ($CREDS_FILE_HOST_PATH or $ALT_CREDS_PATH) not found after tunnel creation. Check Docker volume mapping and permissions."
    fi
fi

# Ensure correct ownership and permissions for the credentials file
chown "$(id -u):$(id -g)" "$CREDS_FILE_HOST_PATH" || log "Warning: Failed to chown credentials file."
chmod 600 "$CREDS_FILE_HOST_PATH" || log "Warning: Failed to chmod credentials file."

#-----------------------------------
# Generate config.yml with validation
#-----------------------------------
CFG_FILE_HOST_PATH="$CFG_DIR/config.yml"
# Path *inside* the container
CREDS_FILE_CONTAINER_PATH="/home/nonroot/.cloudflared/$TUNNEL_CRED_FILE_BASENAME"

log "Generating config file: $CFG_FILE_HOST_PATH"
{
    # Note: credentials-file path is relative to the container's working dir or absolute inside it
    echo "tunnel: $TUNNEL_ID"
    echo "credentials-file: $CREDS_FILE_CONTAINER_PATH"
    echo ""
    echo "# Optional: Add warp-routing, logging, or other tunnel config here"
    echo "# See: https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/configuration/"
    echo "log: "
    echo "  level: info # Can be debug, info, warn, error, fatal"
    echo "  format: text # or json"
    echo ""
    echo "ingress:"

    ingress_rules_added=0
    if [[ -n "$HOSTS" ]]; then
        IFS=',' read -ra HOST_ENTRIES <<<"$HOSTS"
        for entry in "${HOST_ENTRIES[@]}"; do
            entry=$(echo "$entry" | xargs) # Trim whitespace
            if [[ -z "$entry" ]]; then continue; fi

            # Improved parsing: handle host:proto://ip:port
            if [[ "$entry" =~ ^([^:]+):(.+)$ ]]; then
                host="${BASH_REMATCH[1]}"
                service="${BASH_REMATCH[2]}"
                # Basic validation for service format
                if [[ ! "$service" =~ ^https?://.+:[0-9]+$ && ! "$service" =~ ^tcp://.+:[0-9]+$ && ! "$service" =~ ^unix:.+$ ]]; then
                    log "Warning: Service format for '$entry' seems invalid. Expected proto://host:port or unix:/path. Skipping."
                    continue
                fi
                echo "  - hostname: ${host}"
                echo "    service: ${service}"
                ((ingress_rules_added++))
            else
                log "Warning: Invalid format in HOSTS entry: '$entry'. Expected 'hostname:service'. Skipping."
            fi
        done
    elif [[ -n "$SUBDOMAINS" && -n "$DOMAIN" ]]; then
        IFS=',' read -ra SUBDOMAIN_ENTRIES <<<"$SUBDOMAINS"
        for sub in "${SUBDOMAIN_ENTRIES[@]}"; do
            sub=$(echo "$sub" | xargs) # Trim whitespace
            if [[ -z "$sub" ]]; then continue; fi

            port="80" # Default port
            name="$sub"
            if [[ "$sub" == *":"* ]]; then
                IFS=':' read -r name port_val <<<"$sub"
                # Validate port is a number
                if [[ "$port_val" =~ ^[0-9]+$ ]]; then
                    port="$port_val"
                else
                    log "Warning: Invalid port specified for subdomain '$name'. Using default port 80."
                fi
            fi
            [[ -z "$name" ]] && {
                log "Warning: Empty subdomain name found. Skipping."
                continue
            }
            echo "  - hostname: ${name}.${DOMAIN}"
            echo "    service: http://localhost:${port}" # Assuming http on localhost
            ((ingress_rules_added++))
        done
    fi

    if [[ $ingress_rules_added -eq 0 ]]; then
        error "No valid ingress rules were generated. Check SUBDOMAINS or HOSTS variable."
    fi

    # Catch-all rule MUST be last
    echo "  - service: http_status:404"
} >"$CFG_FILE_HOST_PATH"

chmod 600 "$CFG_FILE_HOST_PATH" || log "Warning: Failed to chmod config file."
chown "$(id -u):$(id -g)" "$CFG_FILE_HOST_PATH" || log "Warning: Failed to chown config file."

log "Generated configuration:"
cat "$CFG_FILE_HOST_PATH"
log "------------------------"

#-----------------------------------
# Deploy Docker container
#-----------------------------------
log "Stopping and removing existing container '$CONTAINER_NAME' if it exists..."
docker rm -f "$CONTAINER_NAME" &>/dev/null || true # Suppress error if container doesn't exist

log "Deploying container '$CONTAINER_NAME'..."
# Run container as non-root using the host's UID/GID for volume permissions
# Mount the config dir to the default location cloudflared checks inside container
docker run -d \
    --name "$CONTAINER_NAME" \
    --restart=unless-stopped \
    -u "$(id -u):$(id -g)" \
    -v "$CFG_DIR:/home/nonroot/.cloudflared" \
    --network=host `# Use host network for easy access to localhost services by default` \
    "$DOCKER_IMAGE" tunnel --no-autoupdate run --config /home/nonroot/.cloudflared/config.yml "$TUNNEL_NAME" || error "Failed to start the cloudflared Docker container."
# Explicitly pass tunnel name or ID for clarity, though config file is primary
# Added --no-autoupdate as updates should be managed by pulling new Docker images

# Wait a few seconds for the container to potentially start and connect
sleep 5

# Check if container is running
if ! docker ps -f name="$CONTAINER_NAME" --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    log "Container $CONTAINER_NAME failed to stay running. Checking logs..."
    docker logs "$CONTAINER_NAME"
    error "Container $CONTAINER_NAME did not start correctly. See logs above."
fi

log "Container '$CONTAINER_NAME' started successfully."

#-----------------------------------
# DNS Routing with retries
#-----------------------------------
# DNS Routing is only needed if SUBDOMAINS were used (HOSTS requires manual DNS setup usually)
if [[ -n "$SUBDOMAINS" && -n "$DOMAIN" ]]; then
    log "Setting up DNS records (max 3 attempts per record)"
    IFS=',' read -ra SUBDOMAIN_ENTRIES <<<"$SUBDOMAINS" # Re-read in case of modification/validation
    dns_success_count=0
    dns_failure_count=0

    for sub in "${SUBDOMAIN_ENTRIES[@]}"; do
        sub=$(echo "$sub" | xargs) # Trim whitespace
        [[ -n "$sub" ]] || continue

        name="$sub"
        if [[ "$sub" == *":"* ]]; then
            IFS=':' read -r name _ <<<"$sub" # Extract only the name part
        fi
        [[ -z "$name" ]] && continue # Skip if name is empty after split

        fqdn="${name}.$DOMAIN"
        record_created=false

        for attempt in {1..3}; do
            log "Attempt $attempt: Creating DNS CNAME record for $fqdn -> $TUNNEL_ID.cfargotunnel.com"
            # Use the same volume mount and user as other commands
            if docker run --rm \
                -v "$CFG_DIR:/home/nonroot/.cloudflared" \
                -u "$(id -u):$(id -g)" \
                "$DOCKER_IMAGE" tunnel route dns "$TUNNEL_NAME" "$fqdn"; then # Use TUNNEL_NAME here as it's more user-friendly and works
                log "Successfully created DNS record for $fqdn."
                record_created=true
                ((dns_success_count++))
                break # Exit retry loop on success
            elif [[ $attempt -eq 3 ]]; then
                log "\e[1;33m[WARNING]\e[0m Failed to create DNS record for $fqdn after 3 attempts. Please check Cloudflare dashboard or create it manually."
                ((dns_failure_count++))
                # Don't exit the whole script, just log a warning
            else
                log "Attempt $attempt failed. Retrying in $((attempt * 3)) seconds..."
                sleep $((attempt * 3))
            fi
        done
    done

    if [[ $dns_failure_count -gt 0 ]]; then
        log "\e[1;33m[WARNING]\e[0m $dns_failure_count DNS record(s) failed to be created automatically. Manual intervention might be required."
    fi
    if [[ $dns_success_count -eq 0 && $dns_failure_count -eq 0 && ${#SUBDOMAIN_ENTRIES[@]} -gt 0 ]]; then
        log "\e[1;33m[WARNING]\e[0m No valid subdomains found to create DNS records for, even though SUBDOMAINS variable was set."
    elif [[ $dns_success_count -gt 0 ]]; then
        log "Finished processing DNS records."
    fi

elif [[ -n "$HOSTS" ]]; then
    log "Using HOSTS configuration. DNS records must be configured manually in Cloudflare."
    log "Ensure you have CNAME records pointing your hostnames to '${TUNNEL_ID}.cfargotunnel.com'."
fi

#-----------------------------------
# Completion
#-----------------------------------
cat <<EOF

✅ Cloudflare Tunnel Docker setup process finished!

Tunnel Name:       $TUNNEL_NAME
Tunnel ID:         $TUNNEL_ID
Config File:       $CFG_FILE_HOST_PATH (on host)
Credentials File:  $CREDS_FILE_HOST_PATH (on host)
Container Name:    $CONTAINER_NAME

Ingress Rules Configured (check $CFG_FILE_HOST_PATH for details):
$(grep -E "^ +- hostname:" "$CFG_FILE_HOST_PATH" || echo "  (No hostnames found in config - check for errors)")

$(if [[ $dns_failure_count -gt 0 ]]; then echo -e "\e[1;33mWARNING:\e[0m Some DNS records failed automatic creation. Check logs and Cloudflare dashboard."; fi)
$(if [[ -n "$HOSTS" ]]; then echo -e "\e[1;33mACTION REQUIRED:\e[0m Manually create CNAME records in Cloudflare pointing your hostnames to \e[1m${TUNNEL_ID}.cfargotunnel.com\e[0m"; fi)

To check container status:
  docker ps -f name=$CONTAINER_NAME

To view live logs:
  docker logs -f $CONTAINER_NAME

To list tunnels known by the running container:
  docker exec $CONTAINER_NAME cloudflared tunnel list

EOF

exit 0 # Ensure script exits with success code if it reaches here
