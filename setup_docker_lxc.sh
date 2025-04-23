#!/bin/bash
set -e

USERNAME="dockeruser"

echo "🔧 Cập nhật hệ thống..."
apt update && apt upgrade -y

echo "🐳 Cài Docker..."
curl -fsSL https://get.docker.com | bash

echo "👤 Tạo user '$USERNAME'..."
useradd -m -s /bin/bash "$USERNAME"

echo "➕ Thêm user vào nhóm docker..."
usermod -aG docker "$USERNAME"

echo "🔒 Bảo mật: chặn root login qua SSH..."
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh || true

echo "📦 Cài thêm tiện ích..."
apt install -y htop curl git ufw bash-completion

echo "🛡️ Kích hoạt firewall cơ bản..."
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw --force enable

echo "✅ Hoàn tất! Bạn có thể đăng nhập với: su - $USERNAME"
