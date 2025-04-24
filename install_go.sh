#!/usr/bin/env bash

# --- Cấu hình Script An Toàn ---
# -e: Thoát ngay nếu có lệnh nào trả về lỗi (exit code khác 0)
# -u: Báo lỗi nếu sử dụng biến chưa được khai báo
# -o pipefail: Exit code của một pipeline (|) là exit code của lệnh cuối cùng thất bại (hoặc 0 nếu thành công)
set -euo pipefail
# - IFS: Ngăn chặn word splitting dựa trên khoảng trắng và globbing không mong muốn
IFS=$'\n\t'

#-----------------------------------
# Logging Functions
#-----------------------------------
# Hàm ghi log thông tin (màu xanh lá)
log() {
    # Sử dụng printf để đảm bảo tính tương thích và xử lý định dạng tốt hơn echo -e
    printf '\e[1;32m[INFO]\e[0m  %s\n' "$*"
}

# Hàm ghi log lỗi (màu đỏ) và thoát script
error() {
    printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2 # Ghi vào standard error
    exit 1
}

#-----------------------------------
# Kiểm tra quyền Root
#-----------------------------------
log "Kiểm tra quyền thực thi..."
if [[ $(id -u) -ne 0 ]]; then
  error "Vui lòng chạy script này với quyền root hoặc thông qua 'sudo ./script_name.sh'"
fi
log "Đang chạy với quyền root."

# --- Cấu hình Cài đặt Go ---
# Để trống GO_VERSION để tự động lấy bản mới nhất (cần cập nhật logic lấy tự động nếu muốn)
# Hoặc đặt cụ thể, ví dụ: "1.22.2"
GO_VERSION="1.22.2" # <-- CẬP NHẬT PHIÊN BẢN MỚI NHẤT Ở ĐÂY NẾU CẦN
# Thư mục cài đặt Go (chuẩn là /usr/local)
INSTALL_DIR="/usr/local"
# Thư mục Go Workspace (tùy chọn, nếu bạn vẫn muốn dùng GOPATH)
GOPATH_DIR="$HOME/go" # Lưu ý: $HOME có thể trỏ đến /root/go nếu chạy bằng sudo trực tiếp
                     # Nếu muốn thư mục go của người dùng gốc, cần xử lý phức tạp hơn
                     # Ví dụ: REAL_USER=$(logname); GOPATH_DIR="/home/$REAL_USER/go"
                     # Tuy nhiên, script chạy với root nên việc cấu hình GOPATH cho user thường
                     # nên được user đó tự làm sau khi Go được cài.
                     # Tạm thời bỏ qua GOPATH trong script root này để đơn giản.
# File cấu hình shell (áp dụng cho user mới đăng nhập hoặc source lại)
# Cấu hình hệ thống thường nằm trong /etc/profile hoặc /etc/profile.d/
PROFILE_SYSTEM_WIDE="/etc/profile.d/golang.sh"
# --- Kết thúc cấu hình ---

log "Bắt đầu quá trình cài đặt Golang..."

# Xác định OS và Kiến trúc
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
GO_ARCH=""

case $ARCH in
  x86_64)
    GO_ARCH="amd64"
    ;;
  aarch64 | arm64)
    GO_ARCH="arm64"
    ;;
  *)
    error "Kiến trúc không được hỗ trợ: $ARCH"
    ;;
esac

log "Hệ điều hành: $OS"
log "Kiến trúc: $GO_ARCH"

# Lấy phiên bản Go (hiện tại đang hardcode)
if [ -z "$GO_VERSION" ]; then
  log "Đang tìm phiên bản Go mới nhất... (Chức năng này cần được cài đặt thêm)"
  # Logic phức tạp để lấy version mới nhất từ web, ví dụ dùng curl + grep/sed/awk
  # Tạm thời báo lỗi nếu không được đặt
  error "Biến GO_VERSION chưa được đặt. Vui lòng chỉ định phiên bản Go cần cài."
fi

GO_FILENAME="go${GO_VERSION}.${OS}-${GO_ARCH}.tar.gz"
DOWNLOAD_URL="https://dl.google.com/go/${GO_FILENAME}"
GO_INSTALL_PATH="${INSTALL_DIR}/go"
TMP_DOWNLOAD_PATH="/tmp/${GO_FILENAME}"

log "Phiên bản Go sẽ cài đặt: $GO_VERSION"
log "URL tải về: $DOWNLOAD_URL"
log "Đường dẫn cài đặt: $GO_INSTALL_PATH"

# Kiểm tra các công cụ cần thiết
log "Kiểm tra các công cụ cần thiết (curl, tar)..."
command -v curl >/dev/null 2>&1 || error "Lệnh 'curl' không tồn tại. Vui lòng cài đặt curl."
command -v tar >/dev/null 2>&1 || error "Lệnh 'tar' không tồn tại. Vui lòng cài đặt tar."
log "Các công cụ cần thiết đã có."

# Tải Go
log "Đang tải xuống ${GO_FILENAME} vào ${TMP_DOWNLOAD_PATH}..."
# curl: -f fail silently on server error, -s silent mode, -S show error, -L follow redirects, -o output file
curl -fsSL -o "$TMP_DOWNLOAD_PATH" "$DOWNLOAD_URL"
log "Tải về hoàn tất: ${TMP_DOWNLOAD_PATH}"

# Cài đặt Go
log "Đang cài đặt Go vào ${GO_INSTALL_PATH}..."
if [ -d "$GO_INSTALL_PATH" ]; then
    log "Phát hiện cài đặt Go cũ tại ${GO_INSTALL_PATH}. Đang xóa bỏ..."
    # Không cần sudo vì đã kiểm tra root ở đầu script
    rm -rf "$GO_INSTALL_PATH"
    log "Đã xóa cài đặt cũ."
fi

log "Giải nén ${TMP_DOWNLOAD_PATH} vào ${INSTALL_DIR}..."
# Không cần sudo
tar -C "$INSTALL_DIR" -xzf "$TMP_DOWNLOAD_PATH"
log "Giải nén hoàn tất."

# Dọn dẹp file tải về
log "Dọn dẹp file tạm: ${TMP_DOWNLOAD_PATH}..."
rm "$TMP_DOWNLOAD_PATH"
log "Dọn dẹp hoàn tất."

# Thiết lập biến môi trường hệ thống
log "Đang cấu hình biến môi trường PATH cho toàn hệ thống..."
GO_BIN_PATH="${GO_INSTALL_PATH}/bin"
EXPORT_PATH_CMD="export PATH=\$PATH:${GO_BIN_PATH}"

# Tạo file cấu hình trong /etc/profile.d/
# Cách này tốt hơn là sửa trực tiếp /etc/profile
log "Tạo/Cập nhật file cấu hình: ${PROFILE_SYSTEM_WIDE}"
# Ghi đè hoặc tạo mới file
cat << EOF > "$PROFILE_SYSTEM_WIDE"
# GoLang Path Configuration (managed by script)
export PATH=\$PATH:${GO_BIN_PATH}
EOF
# Đặt quyền phù hợp cho file cấu hình
chmod 644 "$PROFILE_SYSTEM_WIDE"
log "Đã cấu hình PATH trong ${PROFILE_SYSTEM_WIDE}."

# Ghi chú về GOPATH (nếu cần)
# if [ -n "$GOPATH_DIR" ]; then
#     log "Lưu ý: Script này không tự động cấu hình GOPATH cho từng người dùng."
#     log "Người dùng cần tự thêm 'export GOPATH=\$HOME/go' và 'export PATH=\$PATH:\$GOPATH/bin' vào file ~/.profile hoặc ~/.bashrc của họ nếu muốn sử dụng GOPATH."
# fi

log ""
log "--------------------------------------------------"
log " Cài đặt Go ${GO_VERSION} thành công! "
log "--------------------------------------------------"
log "Phiên bản vừa cài đặt:"
# Chạy lệnh go version trực tiếp từ đường dẫn cài đặt
"${GO_BIN_PATH}/go" version
log ""
log "QUAN TRỌNG:"
log "Biến môi trường PATH đã được cập nhật trong '${PROFILE_SYSTEM_WIDE}'."
log "Để áp dụng thay đổi cho phiên làm việc hiện tại, bạn có thể chạy:"
log "  source ${PROFILE_SYSTEM_WIDE}"
log "Hoặc, các thay đổi sẽ có hiệu lực cho người dùng khi họ đăng nhập lại."
log "--------------------------------------------------"

exit 0
