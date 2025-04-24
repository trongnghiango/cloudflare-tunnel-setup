#!/bin/bash

# Cài đặt Neovim vào thư mục dùng chung
VERSION="v0.10.0"
INSTALL_DIR="/opt/shared-tools"
BIN_LINK="/usr/local/bin/nvim"

# Tải và giải nén
sudo mkdir -p $INSTALL_DIR
sudo curl -L -o $INSTALL_DIR/nvim-linux64.tar.gz \
    https://github.com/neovim/neovim/releases/download/$VERSION/nvim-linux64.tar.gz
sudo tar -zxvf $INSTALL_DIR/nvim-linux64.tar.gz -C $INSTALL_DIR
sudo mv $INSTALL_DIR/nvim-linux64 $INSTALL_DIR/nvim
sudo rm $INSTALL_DIR/nvim-linux64.tar.gz

# Cấu hình quyền
sudo chmod -R 755 $INSTALL_DIR/nvim
sudo ln -sf $INSTALL_DIR/nvim/bin/nvim $BIN_LINK
sudo chmod 755 $BIN_LINK

# Thêm vào PATH
#echo 'export PATH="/opt/shared-tools/nvim/bin:$PATH"' | sudo tee -a /etc/profile

echo "Neovim $VERSION đã được cài đặt cho tất cả user!"
