#!/bin/bash

#================================================================================
# SOCKS5 Proxy Auto-Installer Script
#
# Description: This script automates the installation and configuration of a
#              SOCKS5 proxy server using 'gost', a lightweight tunnel program.
# Features:
#   - Asks for a port
#   - Automatically generates a secure username and password
#   - Sets up the proxy as a systemd service for background running and auto-restart
#   - Creates a convenient 's5' command to display proxy info
#   - Automatically configures the firewall (ufw or firewalld)
#
# GitHub: https://github.com/your-username/your-repo
#================================================================================

# --- Colors for output ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- Global Variables ---
SERVICE_NAME="gost"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GOST_INSTALL_PATH="/usr/local/bin/gost"
INFO_FILE="/etc/s5_info"
CMD_FILE="/usr/local/bin/s5"

# --- Functions ---

# Function to print success message
print_success() {
    echo -e "${GREEN}$1${NC}"
}

# Function to print error message and exit
print_error() {
    echo -e "${RED}$1${NC}"
    exit 1
}

# Function to print warning/info message
print_info() {
    echo -e "${YELLOW}$1${NC}"
}

# 1. Check for root privileges
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "错误：此脚本必须以 root 权限运行。"
    fi
}

# 2. Get user input for the port
get_port() {
    while true; do
        read -p "请输入您想使用的 SOCKS5 端口 (1-65535): " PORT
        # Check if input is a number and within the valid range
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            # Check if port is in use
            if ss -tuln | grep -q ":$PORT\b"; then
                print_error "错误：端口 $PORT 已被占用，请选择其他端口。"
            else
                print_success "端口 $PORT 可用。"
                break
            fi
        else
            print_error "错误：请输入一个 1 到 65535 之间的有效数字。"
        fi
    done
}

# 3. Generate random credentials
generate_credentials() {
    print_info "正在生成随机用户名和密码..."
    # Generate a more human-readable username
    S5_USER="user$(shuf -i 1000-9999 -n 1)"
    # Generate a secure random password
    S5_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
    print_success "凭证已生成。"
}

# 4. Download and install 'gost'
install_gost() {
    print_info "正在检测系统架构并下载最新版 gost..."
    # Detect architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        *)
            print_error "不支持的系统架构: $ARCH"
            ;;
    esac

    # Get the latest release version
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/ginuerzh/gost/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c 2-)
    if [ -z "$LATEST_VERSION" ]; then
        print_error "无法获取 gost 最新版本号，请检查网络或 GitHub API 限制。"
    fi
    
    DOWNLOAD_URL="https://github.com/ginuerzh/gost/releases/download/v${LATEST_VERSION}/gost-linux-${ARCH}-${LATEST_VERSION}.gz"
    
    print_info "正在从 $DOWNLOAD_URL 下载..."
    
    # Download and extract
    if curl -L -o gost.gz "$DOWNLOAD_URL"; then
        gunzip gost.gz
        mv gost "$GOST_INSTALL_PATH"
        chmod +x "$GOST_INSTALL_PATH"
        print_success "gost 已成功安装到 $GOST_INSTALL_PATH"
    else
        print_error "下载 gost 失败，请检查您的网络连接。"
    fi
}

# 5. Create and configure the systemd service
create_service() {
    print_info "正在创建 systemd 服务..."
    
    # Create the service file
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GO Simple Tunnel
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${GOST_INSTALL_PATH} -L="socks5://${S5_USER}:${S5_PASS}@:${PORT}"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd, enable and start the service
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    # Check service status
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "gost 服务已成功启动并设置为开机自启。"
    else
        print_error "gost 服务启动失败，请运行 'journalctl -u ${SERVICE_NAME}' 查看日志。"
    fi
}

# 6. Configure firewall
configure_firewall() {
    print_info "正在配置防火墙..."
    if command -v firewall-cmd &> /dev/null; then
        print_info "检测到 firewalld，正在开放端口 $PORT..."
        firewall-cmd --permanent --add-port=${PORT}/tcp
        firewall-cmd --reload
        print_success "firewalld 端口 $PORT 已开放。"
    elif command -v ufw &> /dev/null; then
        print_info "检测到 ufw，正在开放端口 $PORT..."
        ufw allow ${PORT}/tcp
        ufw reload
        print_success "ufw 端口 $PORT 已开放。"
    else
        print_warning "未检测到 ufw 或 firewalld。如果您的服务器有防火墙，请手动开放 TCP 端口 $PORT。"
    fi
}

# 7. Create convenience command 's5' and display info
show_info() {
    # Get public IP
    PUBLIC_IP=$(curl -s ip.sb)
    if [ -z "$PUBLIC_IP" ]; then
        PUBLIC_IP="<无法自动获取, 请手动查询>"
    fi

    # Prepare info content
    INFO_CONTENT="
=================================================
 SOCKS5 代理配置信息
=================================================
 地址 (Address):   ${PUBLIC_IP}
 端口 (Port):      ${PORT}
 用户名 (Username): ${S5_USER}
 密码 (Password):   ${S5_PASS}
=================================================
 你可以随时输入 's5' 命令再次查看此信息。
"

    # Save info to file
    echo -e "$INFO_CONTENT" > "$INFO_FILE"

    # Create 's5' command
    cat > "$CMD_FILE" <<EOF
#!/bin/bash
cat ${INFO_FILE}
EOF
    chmod +x "$CMD_FILE"

    # Display info to user
    clear
    echo -e "${GREEN}SOCKS5 代理已成功安装并启动！${NC}"
    echo -e "$INFO_CONTENT"
}

# --- Main Execution ---
main() {
    check_root
    get_port
    generate_credentials
    install_gost
    create_service
    configure_firewall
    show_info
}

# Run the main function
main
