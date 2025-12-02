#!/bin/bash

#================================================================================
# SOCKS5 Proxy Auto-Installer Script (v3)
#
# Description: This script automates the installation and configuration of a
#              SOCKS5 proxy server using 'gost', a lightweight tunnel program.
# Features:
#   - Option to auto-assign a random port or manually specify one.
#   - Automatically generates a secure username and password.
#   - Sets up the proxy as a systemd service for background running and auto-restart.
#   - Creates a powerful 's5' command to start/stop/restart/status/info/update.
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
ARCH="" # Will be determined later

# --- Functions ---

print_success() { echo -e "${GREEN}$1${NC}"; }
print_error() { echo -e "${RED}$1${NC}"; exit 1; }
print_info() { echo -e "${YELLOW}$1${NC}"; }

check_root() {
    [ "$(id -u)" -ne 0 ] && print_error "错误：此脚本必须以 root 权限运行。"
}

get_port() {
    print_info "请选择端口分配方式:"
    echo "1) 自动分配一个随机端口 (推荐)"
    echo "2) 手动指定一个端口"
    read -p "请输入选项 [1-2]: " port_choice

    case $port_choice in
        1)
            print_info "正在寻找一个未被占用的随机端口..."
            while true; do
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

generate_credentials() {
    print_info "正在生成随机用户名和密码..."
    S5_USER="user$(shuf -i 1000-9999 -n 1)"
    S5_PASS=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
    print_success "凭证已生成。"
}

# This function now also sets the global ARCH variable
install_gost() {
    print_info "正在检测系统架构并下载最新版 gost..."
    local arch_raw=$(uname -m)
    case $arch_raw in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) print_error "不支持的系统架构: $arch_raw" ;;
    esac

    LATEST_VERSION=$(curl -s "https://api.github.com/repos/ginuerzh/gost/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c 2-)
    [ -z "$LATEST_VERSION" ] && print_error "无法获取 gost 最新版本号，请检查网络或 GitHub API 限制。"
    
    DOWNLOAD_URL="https://github.com/ginuerzh/gost/releases/download/v${LATEST_VERSION}/gost-linux-${ARCH}-${LATEST_VERSION}.gz"
    
    print_info "正在从 $DOWNLOAD_URL 下载..."
    
    if curl -L -o gost.gz "$DOWNLOAD_URL"; then
        gunzip gost.gz
        mv gost "$GOST_INSTALL_PATH"
        chmod +x "$GOST_INSTALL_PATH"
        print_success "gost v${LATEST_VERSION} 已成功安装到 $GOST_INSTALL_PATH"
    else
        print_error "下载 gost 失败，请检查您的网络连接。"
    fi
}

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
        print_info "未检测到 ufw 或 firewalld。如果您的服务器有防火墙，请手动开放 TCP 端口 $PORT。"
    fi
}

# The ARCH variable from install_gost is now used here
setup_s5_command() {
    PUBLIC_IP=$(curl -s ip.sb)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="<无法自动获取, 请手动查询>"

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
    echo -e "$INFO_CONTENT" > "$INFO_FILE"

    # Create the 's5' management script with update functionality
    cat > "$CMD_FILE" <<EOF
#!/bin/bash
GREEN='\\033[0;32m'
RED='\\033[0;31m'
YELLOW='\\033[1;33m'
NC='\\033[0m'

SERVICE_NAME="${SERVICE_NAME}"
GOST_INSTALL_PATH="${GOST_INSTALL_PATH}"
ARCH="${ARCH}" # The architecture is now saved inside the command

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
    echo "  update    检查并更新 gost 到最新版本"
    echo ""
    echo "如果不带任何命令，将默认显示连接信息和此帮助菜单。"
}

update_gost() {
    echo -e "\${YELLOW}正在检查更新... \${NC}"
    CURRENT_VERSION=\$(${GOST_INSTALL_PATH} -V | awk '{print \$2}' | cut -c 2-)
    if [ -z "\$CURRENT_VERSION" ]; then
        echo -e "\${RED}无法获取当前版本号，请检查 gost 是否安装正确。\${NC}"
        return 1
    fi
    
    LATEST_VERSION=\$(curl -s "https://api.github.com/repos/ginuerzh/gost/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\\1/' | cut -c 2-)
    if [ -z "\$LATEST_VERSION" ]; then
        echo -e "\${RED}无法获取最新版本号，请检查网络或 GitHub API 限制。\${NC}"
        return 1
    fi

    echo "当前版本: \$CURRENT_VERSION"
    echo "最新版本: \$LATEST_VERSION"

    if [ "\$CURRENT_VERSION" == "\$LATEST_VERSION" ]; then
        echo -e "\${GREEN}您已经在使用最新版本！\${NC}"
        return 0
    fi

    echo -e "\${YELLOW}发现新版本，开始更新...\${NC}"
    DOWNLOAD_URL="https://github.com/ginuerzh/gost/releases/download/v\${LATEST_VERSION}/gost-linux-\${ARCH}-\${LATEST_VERSION}.gz"

    echo "正在下载: \$DOWNLOAD_URL"
    TEMP_FILE="/tmp/gost.gz"
    if ! curl -L -o "\$TEMP_FILE" "\$DOWNLOAD_URL"; then
        echo -e "\${RED}下载失败，请重试。\${NC}"
        return 1
    fi

    echo "正在停止服务..."
    systemctl stop \$SERVICE_NAME

    echo "正在替换旧文件..."
    gunzip -c "\$TEMP_FILE" > "\$GOST_INSTALL_PATH"
    chmod +x "\$GOST_INSTALL_PATH"
    rm "\$TEMP_FILE"

    echo "正在启动服务..."
    systemctl start \$SERVICE_NAME
    
    sleep 2 # Wait a moment for service to start
    
    if systemctl is-active --quiet "\$SERVICE_NAME"; then
       NEW_VERSION=\$(${GOST_INSTALL_PATH} -V | awk '{print \$2}' | cut -c 2-)
       echo -e "\${GREEN}更新成功！当前版本: \$NEW_VERSION\${NC}"
    else
       echo -e "\${RED}更新失败，服务未能启动。请检查日志 'journalctl -u \$SERVICE_NAME'\${NC}"
    fi
}

case "\$1" in
    start) systemctl start \${SERVICE_NAME} && echo -e "\${GREEN}服务已启动\${NC}" || echo -e "\${RED}启动失败\${NC}";;
    stop) systemctl stop \${SERVICE_NAME} && echo -e "\${GREEN}服务已停止\${NC}" || echo -e "\${RED}停止失败\${NC}";;
    restart) systemctl restart \${SERVICE_NAME} && echo -e "\${GREEN}服务已重启\${NC}" || echo -e "\${RED}重启失败\${NC}";;
    status) systemctl status \${SERVICE_NAME} --no-pager;;
    info) cat ${INFO_FILE};;
    update) update_gost;;
    *) cat ${INFO_FILE}; show_usage;;
esac
EOF
    chmod +x "$CMD_FILE"

    clear
    print_success "SOCKS5 代理已成功安装并启动！"
    echo -e "$INFO_CONTENT"
    print_info "现在你可以使用 's5' 命令来管理你的服务了。"
    print_info "新增功能: 使用 's5 update' 来一键更新代理程序。"
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

main
