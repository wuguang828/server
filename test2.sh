#!/bin/bash
#===============================================================================
#
#          FILE: hy2-install.sh
# 
#         USAGE: curl -fsSL https://raw.githubusercontent.com/wuguang828/server/main/hy2-install.sh | bash
#
#   DESCRIPTION: Hysteria 2 完整一键安装脚本
#                - 自动安装依赖
#                - 自动下载并验证二进制
#                - 自动配置防火墙
#                - 自动创建服务
#                - 自动导出配置
#                - 自动修复常见错误
#
#       AUTHOR: wuguang828
#      VERSION: 5.0
#     REVISION: 4.0
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
SERVICE_NAME="hysteria-server"
CONFIG_FILE="/etc/hysteria/config.yaml"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HYSTERIA_BIN="/usr/bin/hysteria"
CERT_DIR="/etc/hysteria"
LOG_FILE="/var/log/hysteria.log"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# 检查root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "必须使用root权限运行！"
        exit 1
    fi
    print_success "Root权限检查通过"
}

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        OS="Unknown"
        VER="Unknown"
    fi
    
    print_info "系统：${OS} ${VER}"
    
    if command -v apt-get &> /dev/null; then
        PM="apt"
    elif command -v yum &> /dev/null; then
        PM="yum"
    else
        PM="unknown"
    fi
}

# 安装依赖
install_dependencies() {
    print_info "安装依赖..."
    
    if [ "$PM" = "apt" ]; then
        apt-get update -qq
        apt-get install -y -qq curl wget openssl net-tools systemd
    elif [ "$PM" = "yum" ]; then
        yum install -y -q curl wget openssl net-tools systemd
    fi
    
    print_success "依赖安装完成"
}

# 获取IP
get_ip() {
    local IP=$(curl -s -4 --connect-timeout 5 icanhazip.com 2>/dev/null)
    if [ -z "$IP" ]; then
        IP=$(curl -s -6 --connect-timeout 5 icanhazip.com 2>/dev/null)
    fi
    if [ -z "$IP" ]; then
        IP="127.0.0.1"
    fi
    echo "$IP"
}

# 生成配置
generate_config() {
    PORT=${HY2_PORT:-$((RANDOM % 55535 + 10000))}
    PASS=${HY2_PASSWORD:-$(openssl rand -hex 16)}
    HOSTNAME=${HY2_HOSTNAME:-"Hysteria2"}
    
    print_info "端口：$PORT"
    print_info "密码：$PASS"
}

# 下载Hysteria（带重试和验证）
download_hysteria() {
    print_info "下载 Hysteria 2..."
    
    # 获取最新版本
    LATEST_VERSION=$(curl -s --connect-timeout 10 https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c2-)
    
    if [ -z "$LATEST_VERSION" ]; then
        print_warning "无法获取最新版本，使用默认版本 v2.4.2"
        LATEST_VERSION="2.4.2"
    fi
    
    print_info "版本：v${LATEST_VERSION}"
    
    # 检测架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
        *) print_error "不支持的架构：$ARCH"; exit 1 ;;
    esac
    
    print_info "架构：$ARCH"
    
    # 下载（带重试）
    local DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/v${LATEST_VERSION}/hysteria-linux-${ARCH}"
    local MAX_RETRIES=3
    local RETRY=0
    
    while [ $RETRY -lt $MAX_RETRIES ]; do
        print_info "下载尝试 $((RETRY+1))/$MAX_RETRIES..."
        
        # 删除旧文件
        rm -f ${HYSTERIA_BIN}
        
        # 下载
        if wget -q --show-progress --timeout=30 --tries=3 -O ${HYSTERIA_BIN} ${DOWNLOAD_URL}; then
            # 验证文件大小（必须大于1MB）
            local FILE_SIZE=$(stat -c%s ${HYSTERIA_BIN} 2>/dev/null || echo "0")
            if [ "$FILE_SIZE" -gt 1048576 ]; then
                chmod +x ${HYSTERIA_BIN}
                
                # 验证可执行
                if ${HYSTERIA_BIN} --version &>/dev/null; then
                    print_success "Hysteria 2 下载完成 (v${LATEST_VERSION}, ${FILE_SIZE} bytes)"
                    return 0
                else
                    print_warning "二进制文件无法执行，重试..."
                fi
            else
                print_warning "文件大小异常 ($FILE_SIZE bytes)，重试..."
            fi
        else
            print_warning "下载失败，重试..."
        fi
        
        RETRY=$((RETRY+1))
        sleep 2
    done
    
    print_error "下载失败，请检查网络连接"
    exit 1
}

# 生成证书
generate_cert() {
    print_info "生成 TLS 证书..."
    
    mkdir -p ${CERT_DIR}
    
    local SERVER_IP=$(get_ip)
    
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout ${CERT_DIR}/server.key \
        -out ${CERT_DIR}/server.crt \
        -days 3650 \
        -subj "/CN=${SERVER_IP}" \
        -addext "subjectAltName=IP:${SERVER_IP}" \
        2>/dev/null
    
    if [ -f ${CERT_DIR}/server.crt ] && [ -f ${CERT_DIR}/server.key ]; then
        print_success "TLS 证书生成完成"
    else
        print_error "证书生成失败"
        exit 1
    fi
}

# 创建配置
create_config() {
    print_info "创建配置文件..."
    
    cat > ${CONFIG_FILE} << EOF
# Hysteria 2 配置文件
# 生成时间：$(date)

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

speedTest: true
disableUDP: false
EOF

    print_success "配置文件创建完成"
}

# 创建服务
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
    
    if command -v ufw &> /dev/null; then
        ufw allow ${PORT}/udp 2>/dev/null || true
        ufw allow ${PORT}/tcp 2>/dev/null || true
        print_success "ufw 配置完成"
    elif command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=${PORT}/udp
            firewall-cmd --permanent --add-port=${PORT}/tcp
            firewall-cmd --reload
            print_success "firewalld 配置完成"
        fi
    fi
    
    # iptables 备用方案
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || true
    fi
}

# 启动服务（带错误检查）
start_service() {
    print_info "启动服务..."
    
    systemctl daemon-reload
    systemctl start ${SERVICE_NAME}
    sleep 3
    
    # 检查状态
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        print_success "服务启动成功"
        return 0
    fi
    
    # 检查错误
    local STATUS=$(systemctl status ${SERVICE_NAME} --no-pager 2>&1)
    
    if echo "$STATUS" | grep -q "status=203/EXEC"; then
        print_error "检测到 203/EXEC 错误"
        print_info "检查二进制文件..."
        
        # 重新下载
        rm -f ${HYSTERIA_BIN}
        download_hysteria
        
        # 重启
        systemctl restart ${SERVICE_NAME}
        sleep 3
        
        if systemctl is-active --quiet ${SERVICE_NAME}; then
            print_success "服务启动成功（修复后）"
            return 0
        fi
    fi
    
    print_error "服务启动失败，查看日志："
    journalctl -u ${SERVICE_NAME} -n 10 --no-pager
    return 1
}

# 导出配置
export_config() {
    local SERVER_IP=$(get_ip)
    
    echo -e ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  ✅ Hysteria 2 安装完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
    echo -e "${CYAN}【服务器信息】${NC}"
    echo -e "  地址：${YELLOW}${SERVER_IP}${NC}"
    echo -e "  端口：${YELLOW}${PORT}${NC}"
    echo -e "  密码：${YELLOW}${PASS}${NC}"
    echo -e ""
    echo -e "${CYAN}【连接命令】${NC}"
    echo -e "${YELLOW}hysteria2://${PASS}@${SERVER_IP}:${PORT}/?insecure=1&alpn=h3&obfs=none#${HOSTNAME}${NC}"
    echo -e ""
    echo -e "${CYAN}【JSON配置】${NC}"
    echo -e "${YELLOW}"
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
    "maxStreamReceiveWindow": 8388608
  },
  "remark": "${HOSTNAME}"
}
EOFJ
    echo -e "${NC}"
    echo -e "${CYAN}【Clash Meta】${NC}"
    echo -e "${YELLOW}"
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
EOFC
    echo -e "${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
    print_success "服务状态："
    systemctl status ${SERVICE_NAME} --no-pager
    echo -e ""
}

# 主函数
main() {
    echo -e ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Hysteria 2 一键安装脚本 v5.0${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e ""
    
    check_root
    detect_os
    install_dependencies
    generate_config
    download_hysteria
    generate_cert
    create_config
    create_service
    configure_firewall
    start_service
    export_config
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  安装完成！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
}

# 执行
main "$@"
