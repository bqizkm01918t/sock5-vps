#!/bin/bash

#================================================================================
# SOCKS5 Proxy Auto-Installer Script (v2)
#
# Description: This script automates the installation and configuration of a
#              SOCKS5 proxy server using 'gost', a lightweight tunnel program.
# Features:
#   - Option to auto-assign a random port or manually specify one.
#   - Automatically generates a secure username and password.
#   - Sets up the proxy as a systemd service for background running and auto-restart.
#   - Creates a powerful 's5' command to start/stop/restart/status/info.
#   - Automatically configures the firewall (ufw or firewalld).
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

# 2. Get user input for the port (auto or manual)
get_port() {
    print_info "请选择端口分配方式:"
    echo "1) 自动分配一个随机端口 (推荐)"
    echo "2) 手动指定一个端口"
    read -p "请输入选项 [1-2]: " port_choice

    case $port_choice in
        1)
            print_info "正在寻找一个未被占用的随机端口..."
            while true; do
                # Generate a random port between 10000 and 60000
                PORT=$(shuf -i 10000-60000 -n 1)
                if ! ss -tuln | grep -q ":$PORT\b"; then
                    print_success "已自动选择端口: $PORT"
                    break
                fi
            done
            ;;
        2)
            while true; do
                read -p "请输入您想使用的 SOCKS5 端口 (1-65535): " PORT
                if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
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
            ;;
        *)
            print_error "无效的选项，脚本退出。"
            ;;
    esac
}

# 3. Generate random credentials
generate_credentials() {
    print_info "正在生成随机用户名和密码..."
    S5_USER="user$(shuf -i 1000-9999 -n 1)"
    S5_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
    print_success "凭证已生成。"
}

# 4. Download and install 'gost'
install_gost() {
    print_info "正在检测系统架构并下载最新版 gost..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) print_error "不支持的系统架构: $ARCH" ;;
    esac

    LATEST_VERSION=$(curl -s "https://api.github.com/repos/ginuerzh/gost/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c 2-)
    [ -z "$LATEST_VERSION" ] && print_error "无法获取 gost 最新版本号，请检查网络或 GitHub API 限制。"
    
    DOWNLOAD_URL="https://github.com/ginuerzh/gost/releases/download/v${LATEST_VERSION}/gost-linux-${ARCH}-${LATEST_VERSION}.gz"
    
    print_info "正在从 $DOWNLOAD_URL 下载..."
    
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

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

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
        firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        print_success "firewalld 端口 $PORT 已开放。"
    elif command -v ufw &> /dev/null; then
        print_info "检测到 ufw，正在开放端口 $PORT..."
        ufw allow ${PORT}/tcp >/dev/null 2>&1
        ufw reload >/dev/null 2>&1
        print_success "ufw 端口 $PORT 已开放。"
    else
        print_warning "未检测到 ufw 或 firewalld。如果您的服务器有防火墙，请手动开放 TCP 端口 $PORT。"
    fi
}

# 7. Create convenience command 's5' and display info
setup_s5_command() {
    # Get public IP
    PUBLIC_IP=$(curl -s ip.sb)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="<无法自动获取, 请手动查询>"

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
"
    # Save info to file
    echo -e "$INFO_CONTENT" > "$INFO_FILE"

    # Create the 's5' management script
    cat > "$CMD_FILE" <<EOF
#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

show_usage() {
    echo "SOCKS5 代理服务管理工具"
    echo "--------------------------------"
    echo "用法: s5 [命令]"
    echo ""
    echo "可用命令:"
    echo "  start     启动服务"
    echo "  stop      停止服务"
    echo "  restart   重启服务"
    echo "  status    查看服务状态"
    echo "  info      显示连接信息"
    echo ""
    echo "如果不带任何命令，将默认显示连接信息和此帮助菜单。"
}

case "\$1" in
    start)
        echo "正在启动 SOCKS5 服务..."
        systemctl start ${SERVICE_NAME}
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            echo -e "\${GREEN}服务已成功启动。\${NC}"
        else
            echo -e "\${RED}服务启动失败。\${NC}"
        fi
        ;;
    stop)
        echo "正在停止 SOCKS5 服务..."
        systemctl stop ${SERVICE_NAME}
        if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
            echo -e "\${GREEN}服务已成功停止。\${NC}"
        else
            echo -e "\${RED}服务停止失败。\${NC}"
        fi
        ;;
    restart)
        echo "正在重启 SOCKS5 服务..."
        systemctl restart ${SERVICE_NAME}
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            echo -e "\${GREEN}服务已成功重启。\${NC}"
        else
            echo -e "\${RED}服务重启失败。\${NC}"
        fi
        ;;
    status)
        systemctl status ${SERVICE_NAME} --no-pager
        ;;
    info)
        cat ${INFO_FILE}
        ;;
    *)
        cat ${INFO_FILE}
        show_usage
        ;;
esac
EOF
    chmod +x "$CMD_FILE"

    # Display final info to user
    clear
    print_success "SOCKS5 代理已成功安装并启动！"
    echo -e "$INFO_CONTENT"
    print_info "现在你可以使用 's5' 命令来管理你的服务了。"
    print_info "例如: 's5 status', 's5 stop', 's5 start'"
}

# --- Main Execution ---
main() {
    check_root
    get_port
    generate_credentials
    install_gost
    create_service
    configure_firewall
    setup_s5_command
}

# Run the main function
main
