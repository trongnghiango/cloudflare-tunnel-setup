#!/bin/bash

set -e

# === Thông tin cấu hình ===
APP_DIR="$HOME/projects/aki_com_vn"
DB_NAME="aki_wp"
DB_USER="aki_wp"
DB_PASS=$(openssl rand -hex 12)
ROOT_PASS=$(openssl rand -hex 16)
PORT=8080

echo "🚀 Đang tạo thư mục WordPress tại $APP_DIR..."
mkdir -p "$APP_DIR"
cd "$APP_DIR"

echo "🔐 Tạo file .env với mật khẩu ngẫu nhiên..."
cat > .env <<EOF
MYSQL_ROOT_PASSWORD=$ROOT_PASS
MYSQL_DATABASE=$DB_NAME
MYSQL_USER=$DB_USER
MYSQL_PASSWORD=$DB_PASS
EOF

echo "🧱 Tạo file docker-compose.yml..."
cat > docker-compose.yml <<EOF
version: '3.7'

services:
  db:
    container_name: wp_db
    image: mariadb:10.6
    restart: unless-stopped
    volumes:
      - db_data:/var/lib/mysql
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}

  wordpress:
    container_name: wp_app
    image: wordpress:6.4-php8.1-apache
    depends_on:
      - db
    ports:
      - "${PORT}:80"
    restart: unless-stopped
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: \${MYSQL_DATABASE}
      WORDPRESS_DB_USER: \${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - wp_data:/var/www/html

volumes:
  db_data:
  wp_data:
EOF

echo "🐳 Khởi động Docker Compose..."
docker compose up -d

echo ""
echo "✅ WordPress đã sẵn sàng tại: http://localhost:${PORT}"
echo "🔑 Thông tin MySQL được lưu trong: $APP_DIR/.env"
echo "📁 Dữ liệu WordPress nằm trong Docker Volume"

