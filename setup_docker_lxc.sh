#!/bin/bash
set -e

USERNAME="dockeruser"
REQUIRED_PACKAGES="curl ca-certificates apt-transport-https" # Thêm apt-transport-https
UTILITY_PACKAGES="htop git ufw bash-completion"

# Hàm kiểm tra xem một lệnh có tồn tại hay không
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Hàm cài đặt các gói, kiểm tra xem chúng đã được cài đặt hay chưa
install_packages() {
    local packages="$1"
    for package in $packages; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            echo "📦 Cài đặt $package..."
            apt-get install -y "$package"
        else
            echo "✅ $package đã được cài đặt."
        fi
    done
}

echo "🔧 Cập nhật hệ thống..."
apt update && apt upgrade -y

# Kiểm tra và cài đặt các gói cần thiết
echo "🔍 Kiểm tra các gói cần thiết: $REQUIRED_PACKAGES"
install_packages "$REQUIRED_PACKAGES"

# Kiểm tra curl trước khi sử dụng
if ! command_exists curl; then
    echo "❌ curl chưa được cài đặt. Vui lòng cài đặt curl trước khi tiếp tục."
    exit 1
fi

# Kiểm tra user trước khi tạo
if id "$USERNAME" &>/dev/null; then
    echo "✅ User '$USERNAME' đã tồn tại."
else
    echo "👤 Tạo user '$USERNAME'..."
    useradd -m -s /bin/bash "$USERNAME"
fi

# Cài Docker
echo "🐳 Cài Docker..."
if curl -fsSL https://get.docker.com | bash; then
    echo "✅ Docker đã được cài đặt."
else
    echo "❌ Cài Docker thất bại." >&2
    exit 1
fi

echo "➕ Thêm user vào nhóm docker..."
usermod -aG docker "$USERNAME"

# Đảm bảo cập nhật thông tin nhóm người dùng
#newgrp docker

echo "🔒 Bảo mật: chặn root login qua SSH..."
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
# Khởi động lại SSH an toàn
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh || true
elif service ssh status &>/dev/null; then
    service ssh restart || true
else
    echo "⚠️ Không tìm thấy SSH service để restart."
fi

# Cài đặt các tiện ích bổ sung
echo "🔍 Kiểm tra các tiện ích: $UTILITY_PACKAGES"
install_packages "$UTILITY_PACKAGES"

echo "🛡️ Kích hoạt firewall cơ bản..."
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw --force enable
# Cảnh báo nếu đang chạy trong LXC (ufw)
if grep -qa 'container=lxc' /proc/1/environ; then
    echo "⚠️ Đang chạy trong container LXC. 'ufw' có thể không hoạt động đúng do giới hạn kernel."
    if ! lsmod | grep -qE 'nft|xt'; then
        echo "❌ Thiếu module firewall (nftables/xtables). 'ufw' có thể không hoạt động."
    fi
fi


echo "✅ Hoàn tất! Bạn có thể đăng nhập với: su - $USERNAME"
echo "Sau khi đăng nhập, hãy chạy 'newgrp docker' để cập nhật quyền."
