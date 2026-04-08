#!/bin/bash
#===============================================================================
#
#          FILE: hy2-install.sh
# 
#         USAGE: ./hy2-install.sh
#
#   DESCRIPTION: Hysteria 2 一键安装、配置、维护脚本（带配置导出）
#
#   OPTIONS: 
#       install   - 安装 Hysteria 2
#       start     - 启动服务
#       stop      - 停止服务
#       restart   - 重启服务
#       status    - 查看状态
#       config    - 显示配置
#       uninstall - 卸载服务
#       update    - 更新到最新版本
#       firewall  - 配置防火墙
#       log       - 查看日志
#       export    - 导出配置（多种格式）
#
#       AUTHOR: wuguang828
#      VERSION: 3.0
#      CREATED: 2026-04-08
#     REVISION: 2.0
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量
SERVICE_NAME="hysteria-server"
CONFIG_FILE="/etc/hysteria/config.yaml"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HYSTERIA_BIN="/usr/bin/hysteria"
CERT_DIR="/etc/hysteria"
LOG_FILE="/var/log/hysteria.log"
CONFIG_BACKUP_DIR="/root/hy2-config-backup"

# 打印信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "必须使用root权限运行！"
        exit 1
    fi
    print_success "Root权限检查通过"
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi
    
    print_info "检测到系统：${OS} ${VER}"
    
    if command -v apt-get &> /dev/null; then
        PM="apt"
    elif command -v yum &> /dev/null; then
        PM="yum"
    elif command -v dnf &> /dev/null; then
        PM="dnf"
    else
        print_error "不支持的包管理器"
        exit 1
    fi
    
    print_info "包管理器：${PM}"
}

# 检查依赖
check_dependencies() {
    print_info "检查依赖..."
    
    local deps=("curl" "wget" "openssl" "qrencode")
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            print_warning "$dep 未安装，正在安装..."
            if [ "$PM" = "apt" ]; then
                apt-get update && apt-get install -y $dep 2>/dev/null
            elif [ "$PM" = "yum" ]; then
                yum install -y $dep 2>/dev/null
            elif [ "$PM" = "dnf" ]; then
                dnf install -y $dep 2>/dev/null
            fi
        fi
    done
    
    print_success "依赖检查完成"
}

# 获取服务器IP
get_server_ip() {
    local IP=$(curl -s -4 icanhazip.com 2>/dev/null)
    if [ -z "$IP" ]; then
        IP=$(curl -s -6 icanhazip.com 2>/dev/null)
    fi
    echo "$IP"
}

# 生成随机配置
generate_config() {
    PORT=${HY2_PORT:-$((RANDOM % 55535 + 10000))}
    PASS=${HY2_PASSWORD:-$(openssl rand -hex 16)}
    HOSTNAME=${HY2_HOSTNAME:-"Hysteria2-$(hostname)"}
    
    print_info "生成配置..."
    print_info "端口：$PORT"
    print_info "密码：$PASS"
    print_info "主机名：$HOSTNAME"
}

# 下载 Hysteria 2
download_hysteria() {
    print_info "下载 Hysteria 2..."
    
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c2-)
    
    if [ -z "$LATEST_VERSION" ]; then
        print_error "无法获取最新版本号"
        exit 1
    fi
    
    print_info "最新版本：v${LATEST_VERSION}"
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
        *) print_error "不支持的架构：$ARCH"; exit 1 ;;
    esac
    
    print_info "系统架构：$ARCH"
    
    local DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/v${LATEST_VERSION}/hysteria-linux-${ARCH}"
    
    wget -q --show-progress -O ${HYSTERIA_BIN} ${DOWNLOAD_URL}
    
    if [ ! -f ${HYSTERIA_BIN} ]; then
        print_error "下载失败"
        exit 1
    fi
    
    chmod +x ${HYSTERIA_BIN}
    
    print_success "Hysteria 2 下载完成 (v${LATEST_VERSION})"
}

# 生成 TLS 证书
generate_cert() {
    print_info "生成 TLS 证书..."
    
    mkdir -p ${CERT_DIR}
    
    local SERVER_IP=$(get_server_ip)
    
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout ${CERT_DIR}/server.key \
        -out ${CERT_DIR}/server.crt \
        -days 3650 \
        -subj "/CN=${SERVER_IP}" \
        -addext "subjectAltName=IP:${SERVER_IP}" \
        2>/dev/null
    
    if [ ! -f ${CERT_DIR}/server.crt ] || [ ! -f ${CERT_DIR}/server.key ]; then
        print_error "证书生成失败"
        exit 1
    fi
    
    print_success "TLS 证书生成完成"
}

# 创建配置文件
create_config() {
    print_info "创建配置文件..."
    
    cat > ${CONFIG_FILE} << EOF
# Hysteria 2 配置文件
# 生成时间：$(date)
# 主机名：${HOSTNAME}

listen: :${PORT}

tls:
  cert: ${CERT_DIR}/server.crt
  key: ${CERT_DIR}/server.key

auth:
  type: password
  password: ${PASS}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024

speedTest: true
disableUDP: false

log:
  level: info
  output: ${LOG_FILE}
EOF

    print_success "配置文件创建完成：${CONFIG_FILE}"
}

# 创建 systemd 服务
create_service() {
    print_info "创建 systemd 服务..."
    
    cat > ${SERVICE_FILE} << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${HYSTERIA_BIN} server -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}
    
    print_success "systemd 服务创建完成"
}

# 配置防火墙
configure_firewall() {
    print_info "配置防火墙..."
    
    if command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=${PORT}/udp
            firewall-cmd --permanent --add-port=${PORT}/tcp
            firewall-cmd --reload
            print_success "firewalld 配置完成"
        else
            print_warning "firewalld 未运行，跳过配置"
        fi
    elif command -v ufw &> /dev/null; then
        if systemctl is-active --quiet ufw; then
            ufw allow ${PORT}/udp
            ufw allow ${PORT}/tcp
            print_success "ufw 配置完成"
        else
            print_warning "ufw 未运行，跳过配置"
        fi
    elif command -v iptables &> /dev/null; then
        iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
        
        if [ -f /etc/redhat-release ]; then
            service iptables save 2>/dev/null || iptables-save > /etc/sysconfig/iptables
        elif [ -f /etc/debian_version ]; then
            iptables-save > /etc/iptables/rules.v4
        fi
        
        print_success "iptables 配置完成"
    else
        print_warning "未检测到防火墙工具，请手动配置"
    fi
}

# 启动服务
start_service() {
    print_info "启动服务..."
    
    systemctl start ${SERVICE_NAME}
    sleep 2
    
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        print_success "服务启动成功"
    else
        print_error "服务启动失败，查看日志："
        journalctl -u ${SERVICE_NAME} -n 20 --no-pager
        exit 1
    fi
}

# 导出配置（多种格式）
export_config() {
    local SERVER_IP=$(get_server_ip)
    mkdir -p ${CONFIG_BACKUP_DIR}
    
    echo -e ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  📋 Hysteria 2 配置信息${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
    
    # ========== 1. 基本信息 ==========
    echo -e "${CYAN}【1】基本信息${NC}"
    echo -e "  服务器地址：${YELLOW}${SERVER_IP}${NC}"
    echo -e "  端口：${YELLOW}${PORT}${NC}"
    echo -e "  密码：${YELLOW}${PASS}${NC}"
    echo -e "  协议：${YELLOW}Hysteria 2 (QUIC)${NC}"
    echo -e "  主机名：${YELLOW}${HOSTNAME}${NC}"
    echo -e ""
    
    # ========== 2. Hysteria2 链接格式 ==========
    echo -e "${CYAN}【2】Hysteria2 链接格式（一键导入）${NC}"
    local HY2_LINK="hysteria2://${PASS}@${SERVER_IP}:${PORT}/?insecure=1&alpn=h3&obfs=none#${HOSTNAME}"
    echo -e "${YELLOW}${HY2_LINK}${NC}"
    echo -e ""
    
    # ========== 3. JSON 格式（NekoBox/Hiddify） ==========
    echo -e "${CYAN}【3】JSON 格式（客户端导入）${NC}"
    cat << EOFJ
{
  "server": "${SERVER_IP}:${PORT}",
  "auth": "${PASS}",
  "tls": {
    "insecure": true,
    "serverName": "${SERVER_IP}"
  },
  "quic": {
    "initStreamReceiveWindow": 8388608,
    "maxStreamReceiveWindow": 8388608,
    "initConnReceiveWindow": 20971520,
    "maxConnReceiveWindow": 20971520
  },
  "transport": {
    "type": "udp"
  },
  "remark": "${HOSTNAME}"
}
EOFJ
    echo -e ""
    
    # ========== 4. Clash Meta 格式 ==========
    echo -e "${CYAN}【4】Clash Meta 格式${NC}"
    cat << EOFC
  - name: "${HOSTNAME}"
    type: hysteria2
    server: ${SERVER_IP}
    port: ${PORT}
    password: ${PASS}
    alpn:
      - h3
    sni: ${SERVER_IP}
    skip-cert-verify: true
    up: "100 Mbps"
    down: "100 Mbps"
EOFC
    echo -e ""
    
    # ========== 5. Sing-Box 格式 ==========
    echo -e "${CYAN}【5】Sing-Box 格式${NC}"
    cat << EOFS
{
  "tag": "${HOSTNAME}",
  "type": "hysteria2",
  "server": "${SERVER_IP}",
  "server_port": ${PORT},
  "password": "${PASS}",
  "tls": {
    "enabled": true,
    "insecure": true,
    "server_name": "${SERVER_IP}"
  }
}
EOFS
    echo -e ""
    
    # ========== 6. 纯文本格式（方便复制） ==========
    echo -e "${CYAN}【6】纯文本格式${NC}"
    cat << EOFT
服务器地址：${SERVER_IP}
端口：${PORT}
密码：${PASS}
协议：Hysteria 2
TLS：启用
跳过证书验证：启用
ALPN：h3
EOFT
    echo -e ""
    
    # ========== 7. 生成二维码（如果安装了 qrencode） ==========
    if command -v qrencode &> /dev/null; then
        echo -e "${CYAN}【7】二维码（手机扫描导入）${NC}"
        echo -e "  生成二维码..."
        qrencode -t ANSIUTF8 "${HY2_LINK}"
        echo -e ""
    fi
    
    # ========== 8. 保存配置文件 ==========
    echo -e "${CYAN}【8】配置备份${NC}"
    local BACKUP_FILE="${CONFIG_BACKUP_DIR}/hy2-config-$(date +%Y%m%d-%H%M%S).txt"
    
    cat > ${BACKUP_FILE} << EOFB
# Hysteria 2 配置备份
# 生成时间：$(date)
# 服务器：${SERVER_IP}

【Hysteria2 链接】
${HY2_LINK}

【基本信息】
服务器地址：${SERVER_IP}
端口：${PORT}
密码：${PASS}
协议：Hysteria 2 (QUIC)
主机名：${HOSTNAME}

【JSON 格式】
{
  "server": "${SERVER_IP}:${PORT}",
  "auth": "${PASS}",
  "tls": {
    "insecure": true,
    "serverName": "${SERVER_IP}"
  },
  "quic": {
    "initStreamReceiveWindow": 8388608,
    "maxStreamReceiveWindow": 8388608,
    "initConnReceiveWindow": 20971520,
    "maxConnReceiveWindow": 20971520
  },
  "remark": "${HOSTNAME}"
}

【Clash Meta 格式】
  - name: "${HOSTNAME}"
    type: hysteria2
    server: ${SERVER_IP}
    port: ${PORT}
    password: ${PASS}
    alpn:
      - h3
    sni: ${SERVER_IP}
    skip-cert-verify: true

【Sing-Box 格式】
{
  "tag": "${HOSTNAME}",
  "type": "hysteria2",
  "server": "${SERVER_IP}",
  "server_port": ${PORT},
  "password": "${PASS}",
  "tls": {
    "enabled": true,
    "insecure": true,
    "server_name": "${SERVER_IP}"
  }
}
EOFB

    print_success "配置已保存到：${BACKUP_FILE}"
    echo -e ""
    
    # ========== 9. 客户端下载链接 ==========
    echo -e "${CYAN}【9】客户端下载${NC}"
    echo -e "  Android: https://github.com/MatsuriDayo/NekoBoxForAndroid/releases"
    echo -e "  Windows: https://github.com/hiddify/hiddify-next/releases"
    echo -e "  iOS:     Shadowrocket / Streisand"
    echo -e "  macOS:   Hiddify / ClashX"
    echo -e ""
    
    # ========== 10. 快速复制区 ==========
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  📌 快速复制区${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
    echo -e "一键导入链接："
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${HY2_LINK}${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e ""
    
    print_success "所有配置已导出！"
    echo -e ""
}

# 显示配置信息（简化版）
show_config() {
    export_config
}

# 安装主函数
do_install() {
    print_info "开始安装 Hysteria 2..."
    echo -e ""
    
    check_root
    detect_os
    check_dependencies
    generate_config
    download_hysteria
    generate_cert
    create_config
    create_service
    configure_firewall
    start_service
    export_config
    
    print_success "安装完成！"
}

# 启动服务
do_start() {
    print_info "启动 Hysteria 2 服务..."
    systemctl start ${SERVICE_NAME}
    systemctl status ${SERVICE_NAME}
}

# 停止服务
do_stop() {
    print_info "停止 Hysteria 2 服务..."
    systemctl stop ${SERVICE_NAME}
    print_success "服务已停止"
}

# 重启服务
do_restart() {
    print_info "重启 Hysteria 2 服务..."
    systemctl restart ${SERVICE_NAME}
    systemctl status ${SERVICE_NAME}
}

# 查看状态
do_status() {
    systemctl status ${SERVICE_NAME}
}

# 查看日志
do_log() {
    journalctl -u ${SERVICE_NAME} -f
}

# 显示配置
do_config() {
    if [ -f ${CONFIG_FILE} ]; then
        local SERVER_IP=$(get_server_ip)
        local PORT=$(grep "listen:" ${CONFIG_FILE} | awk '{print $2}' | tr -d ':')
        local PASS=$(grep "password:" ${CONFIG_FILE} | awk '{print $2}')
        export_config
    else
        print_error "配置文件不存在"
    fi
}

# 导出配置到文件
do_export() {
    do_config
}

# 更新 Hysteria
do_update() {
    print_info "更新 Hysteria 2..."
    
    local CURRENT_VERSION=$(${HYSTERIA_BIN} --version 2>&1 | head -1)
    print_info "当前版本：${CURRENT_VERSION}"
    
    do_install
    
    print_success "更新完成"
}

# 配置防火墙
do_firewall() {
    if [ -f ${CONFIG_FILE} ]; then
        PORT=$(grep "listen:" ${CONFIG_FILE} | awk '{print $2}' | tr -d ':')
        configure_firewall
    else
        print_error "配置文件不存在"
    fi
}

# 卸载服务
do_uninstall() {
    print_warning "确定要卸载 Hysteria 2 吗？(y/N)"
    read -r confirm
    
    if [[ $confirm != [Yy] && $confirm != [Yy][Ee][Ss] ]]; then
        print_info "取消卸载"
        exit 0
    fi
    
    print_info "停止服务..."
    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    systemctl disable ${SERVICE_NAME} 2>/dev/null || true
    
    print_info "删除文件..."
    rm -f ${SERVICE_FILE}
    rm -f ${HYSTERIA_BIN}
    rm -rf ${CERT_DIR}
    rm -f ${CONFIG_FILE}
    rm -f ${LOG_FILE}
    
    systemctl daemon-reload
    
    print_success "卸载完成"
}

# 显示帮助
show_help() {
    echo -e "${GREEN}Hysteria 2 一键安装维护脚本 v3.0${NC}"
    echo -e ""
    echo -e "用法：$0 [命令]"
    echo -e ""
    echo -e "命令:"
    echo -e "  install   安装 Hysteria 2（默认）"
    echo -e "  start     启动服务"
    echo -e "  stop      停止服务"
    echo -e "  restart   重启服务"
    echo -e "  status    查看服务状态"
    echo -e "  config    显示/导出配置（多种格式）"
    echo -e "  export    导出配置到文件"
    echo -e "  update    更新到最新版本"
    echo -e "  firewall  重新配置防火墙"
    echo -e "  log       查看服务日志"
    echo -e "  uninstall 卸载 Hysteria 2"
    echo -e "  help      显示此帮助信息"
    echo -e ""
    echo -e "示例:"
    echo -e "  $0              # 安装并导出配置"
    echo -e "  $0 install      # 安装"
    echo -e "  $0 config       # 显示所有格式配置"
    echo -e "  $0 export       # 导出配置到文件"
    echo -e "  $0 restart      # 重启"
    echo -e "  $0 status       # 查看状态"
    echo -e ""
    echo -e "自定义配置:"
    echo -e "  export HY2_PORT=8443"
    echo -e "  export HY2_PASSWORD=your_password"
    echo -e "  export HY2_HOSTNAME=My-Server"
    echo -e "  $0 install"
}

# 主程序
main() {
    local COMMAND=${1:-install}
    
    case $COMMAND in
        install)
            do_install
            ;;
        start)
            do_start
            ;;
        stop)
            do_stop
            ;;
        restart)
            do_restart
            ;;
        status)
            do_status
            ;;
        config|export)
            do_config
            ;;
        update)
            do_update
            ;;
        firewall)
            do_firewall
            ;;
        log)
            do_log
            ;;
        uninstall)
            do_uninstall
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "未知命令：$COMMAND"
            show_help
            exit 1
            ;;
    esac
}

# 执行主程序
main "$@"
