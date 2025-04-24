#!/usr/bin/env bash

# --- Cấu hình Script An Toàn ---
set -eo pipefail
IFS=$'\n\t'
trap 'error "Lỗi tại dòng $LINENO. Thoát script."' ERR

#-----------------------------------
# Biến Cấu Hình
#-----------------------------------
NODE_VERSION="${NODE_VERSION:-"--lts"}"
INSTALL_YARN=true
INSTALL_PNPM=true
INSTALL_NEST_CLI=true
NVM_VERSION="v0.39.3"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

#-----------------------------------
# Logging Functions
#-----------------------------------
log() { printf '\e[1;32m[INFO]\e[0m  %s\n' "$*"; }
error() { 
    printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2 
    exit 1
}
warn() { printf '\e[1;33m[WARN]\e[0m  %s\n' "$*"; }

#-----------------------------------
# Hàm Phụ Trợ
#-----------------------------------
check_command() {
    command -v "$1" >/dev/null 2>&1
}

validate_environment() {
    # Kiểm tra biến HOME
    [[ -z "$HOME" ]] && error "Biến môi trường HOME không xác định!"
    [[ ! -d "$HOME" ]] && error "Thư mục HOME không tồn tại: $HOME"
    
    # Kiểm tra quyền ghi vào HOME
    touch "$HOME/nvm_test_file" &>/dev/null || error "Không có quyền ghi vào HOME"
    rm -f "$HOME/nvm_test_file"
}

ensure_nvm_dir() {
    log "Kiểm tra thư mục NVM: $NVM_DIR"
    
    if [[ ! -d "$NVM_DIR" ]]; then
        log "Tạo thư mục NVM..."
        mkdir -p "$NVM_DIR" || error "Không thể tạo thư mục NVM tại: $NVM_DIR"
        chmod 755 "$NVM_DIR" || warn "Không thể thay đổi quyền thư mục"
    fi
}

#-----------------------------------
# Hàm Cài Đặt Phụ Thuộc
#-----------------------------------
install_package() {
    local pkg=$1
    log "Kiểm tra gói: $pkg..."
    
    if check_command "$pkg"; then
        log "'$pkg' đã được cài đặt."
        return 0
    fi

    log "Cài đặt $pkg..."
    local installer
    case true in
        $(check_command apt-get))  installer="sudo apt-get install -y" ;;
        $(check_command yum))      installer="sudo yum install -y" ;;
        $(check_command dnf))      installer="sudo dnf install -y" ;;
        $(check_command pacman))   installer="sudo pacman -Syu --noconfirm" ;;
        $(check_command brew))     installer="brew install" ;;
        *)                        warn "Không thể xác định trình quản lý gói"; return 1 ;;
    esac

    $installer "$pkg" || return 1
}

setup_dependencies() {
    log "Thiết lập các phụ thuộc hệ thống..."
    install_package curl || error "Không thể cài đặt curl"
    install_package git || error "Không thể cài đặt git"
}

#-----------------------------------
# Hàm Quản Lý NVM
#-----------------------------------
install_nvm() {
    log "Kiểm tra NVM..."
    
    # Clean environment
    unset NVM_DIR &>/dev/null || true
    export NVM_DIR="$HOME/.nvm"

    ensure_nvm_dir

    log "Cài đặt NVM phiên bản $NVM_VERSION..."
    curl -sS -o- "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash || {
        error "Lỗi trong quá trình cài đặt NVM"
    }

    # Nạp NVM
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    
    # Xác nhận cài đặt
    command -v nvm &>/dev/null || error "NVM không khả dụng sau cài đặt"
}

#-----------------------------------
# Hàm Cấu Hình Shell
#-----------------------------------
detect_zshrc() {
    local possible_paths=(
        "${ZDOTDIR:-$HOME}/.zshrc"
        "$HOME/.config/zsh/.zshrc"
        "$HOME/.config/zsh/rc"
        "$HOME/.zshrc"
        "$HOME/.zsh/init.zsh"
    )

    for path in "${possible_paths[@]}"; do
        [[ -f "$path" ]] && {
            ZSHRC_FILE="$path"
            log "Phát hiện file Zshrc tại: $ZSHRC_FILE"
            return 0
        }
    done

    # Fallback
    ZSHRC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
    log "Tạo file Zshrc mới tại: $ZSHRC_FILE"
    touch "$ZSHRC_FILE" || error "Không thể tạo file Zshrc"
}

update_rc_file() {
    local rc_file="$1"
    log "Cập nhật file cấu hình: $rc_file"

    # Backup và làm sạch cấu hình cũ
    cp -f "$rc_file" "${rc_file}.pre-nvm" && log "Backup file: ${rc_file}.pre-nvm"
    sed -i '/NVM_DIR/d;/nvm.sh/d;/bash_completion/d' "$rc_file"

    # Thêm cấu hình mới
    cat <<EOF >> "$rc_file"

# NVM Configuration
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"
EOF
}

configure_shell() {
    case "$(basename "$SHELL")" in
        zsh)    detect_zshrc; update_rc_file "$ZSHRC_FILE" ;;
        bash)   update_rc_file "$HOME/.bashrc" ;;
        *)      warn "Shell không được hỗ trợ: $SHELL"; return 1 ;;
    esac

    log "Cấu hình shell hoàn tất!"
}

#-----------------------------------
# Hàm Quản Lý Node.js
#-----------------------------------
setup_node() {
    log "Cài đặt Node.js $NODE_VERSION..."
    nvm install "$NODE_VERSION" || error "Lỗi cài đặt Node.js"

    local node_version=$(nvm current)
    log "Đặt phiên bản mặc định: $node_version"
    nvm alias default "$node_version"
    nvm use default >/dev/null
}

setup_package_managers() {
    [[ "$INSTALL_YARN" = true ]] && {
        log "Cài đặt Yarn..."
        npm install -g yarn || warn "Lỗi cài đặt Yarn"
    }

    [[ "$INSTALL_PNPM" = true ]] && {
        log "Cài đặt pnpm..."
        npm install -g pnpm || warn "Lỗi cài đặt pnpm"
    }
}

setup_nest_cli() {
    [[ "$INSTALL_NEST_CLI" = true ]] && {
        log "Cài đặt NestJS CLI..."
        npm install -g @nestjs/cli || warn "Lỗi cài đặt Nest CLI"
    }
}

#-----------------------------------
# Hàm Hiển Thị Thông Tin
#-----------------------------------
display_versions() {
    log "\nPhiên bản đã cài đặt:"
    printf "%-12s: %s\n" "NVM" "$(nvm --version)"
    printf "%-12s: %s\n" "Node.js" "$(node --version)"
    printf "%-12s: %s\n" "npm" "$(npm --version)"
    
    [[ "$INSTALL_YARN" = true ]] && check_command yarn && 
        printf "%-12s: %s\n" "Yarn" "$(yarn --version)"
    
    [[ "$INSTALL_PNPM" = true ]] && check_command pnpm && 
        printf "%-12s: %s\n" "pnpm" "$(pnpm --version)"
    
    [[ "$INSTALL_NEST_CLI" = true ]] && check_command nest && 
        printf "%-12s: %s\n" "Nest CLI" "$(nest -v)"
}

#-----------------------------------
# Hàm Chính
#-----------------------------------
main() {
    validate_environment
    setup_dependencies
    install_nvm
    configure_shell
    setup_node
    setup_package_managers
    setup_nest_cli
    display_versions
    
    log "\nTHÀNH CÔNG! Thực hiện một trong các bước sau:"
    log "1. Khởi động lại terminal"
    log "2. Chạy lệnh: source ${ZSHRC_FILE:-$HOME/.bashrc}"
    log "3. Hoặc chạy: exec \$SHELL"
}

#-----------------------------------
# Khởi chạy Script
#-----------------------------------
main
exit 0
