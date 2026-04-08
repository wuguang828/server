#!/bin/bash
#===============================================================================
#
#          FILE: hy2-full.sh
# 
#         USAGE: ./hy2-full.sh
#
#   DESCRIPTION: Hysteria 2 完整安装、配置、修复脚本
#                - 自动修复 203/EXEC 错误
#                - 自动安装缺失依赖
#                - 完整配置导出
#
#   OPTIONS: 
#       install   - 安装 Hysteria 2
#       repair    - 修复 203/EXEC 错误
#       start     - 启动服务
#       stop      - 停止服务
#       restart   - 重启服务
#       status    - 查看状态
#       config    - 显示配置
#       export    - 导出配置
#       uninstall - 卸载服务
#       update    - 更新
#       log       - 查看日志
#
#       AUTHOR: wuguang828
#      VERSION: 4.0
#      CREATED: 2026-04-08
#     REVISION: 3.0
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
CONFIG_BACKUP_DIR="/root/hy2-config-backup"

# 打印信息
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

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

# 安装依赖（包括 netstat）
install_dependencies() {
    print_info "安装依赖..."
    
    local deps=("curl" "wget" "openssl" "net-tools" "systemd")
    
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            print_warning "$dep 未安装，正在安装..."
            if [ "$PM" = "apt" ]; then
                apt-get update && apt-get install -y $dep 2>/dev/null || true
            elif [ "$PM" = "yum" ]; then
                yum install -y $dep 2>/dev/null || true
            elif [ "$PM" = "dnf" ]; then
                dnf install -y $dep 2>/dev/null || true
            fi
        fi
    done
    
    print_success "依赖安装完成"
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
}

# 下载并验证 Hysteria 2
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
    
    # 下载并验证
    wget -q --show-progress -O ${HYSTERIA_BIN} ${DOWNLOAD_URL}
    
    if [ ! -f ${HYSTERIA_BIN} ]; then
        print_error "下载失败"
        exit 1
    fi
    
    # 确保有执行权限
    chmod +x ${HYSTERIA_BIN}
    
    # 验证二进制文件
    if ! ${HYSTERIA_BIN} --version &>/dev/null; then
        print_error "二进制文件验证失败，可能是架构不匹配"
        file ${HYSTERIA_BIN}
        exit 1
    fi
    
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

# 创建 systemd 服务（修复 203/EXEC 错误）
create_service() {
    print_info "创建 systemd 服务..."
    
    # 验证二进制文件路径和权限
    if [ ! -x ${HYSTERIA_BIN} ]; then
        print_error "二进制文件不存在或无执行权限：${HYSTERIA_BIN}"
        print_info "正在修复..."
        chmod +x ${HYSTERIA_BIN}
    fi
    
    # 验证配置文件
    if [ ! -f ${CONFIG_FILE} ]; then
        print_error "配置文件不存在：${CONFIG_FILE}"
        exit 1
    fi
    
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

# 修复 203/EXEC 错误
# 确保使用绝对路径
WorkingDirectory=/root

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
            print_warning "firewalld 未运行"
        fi
    elif command -v ufw &> /dev/null; then
        ufw allow ${PORT}/udp 2>/dev/null || true
        ufw allow ${PORT}/tcp 2>/dev/null || true
        print_success "ufw 配置完成"
    elif command -v iptables &> /dev/null; then
        iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT 2>/dev/null || true
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null || true
        print_success "iptables 配置完成"
    else
        print_warning "未检测到防火墙工具"
    fi
}

# 修复 203/EXEC 错误
fix_203_exec() {
    print_info "修复 203/EXEC 错误..."
    
    # 1. 检查二进制文件
    if [ ! -f ${HYSTERIA_BIN} ]; then
        print_error "二进制文件不存在：${HYSTERIA_BIN}"
        print_info "重新下载..."
        download_hysteria
    fi
    
    # 2. 检查执行权限
    if [ ! -x ${HYSTERIA_BIN} ]; then
        print_warning "二进制文件无执行权限，正在修复..."
        chmod +x ${HYSTERIA_BIN}
    fi
    
    # 3. 检查架构匹配
    print_info "检查二进制文件架构..."
    file ${HYSTERIA_BIN}
    
    if ! ${HYSTERIA_BIN} --version &>/dev/null; then
        print_error "二进制文件无法执行，架构可能不匹配"
        print_info "重新下载正确版本..."
        download_hysteria
    fi
    
    # 4. 检查配置文件
    if [ ! -f ${CONFIG_FILE} ]; then
        print_error "配置文件不存在：${CONFIG_FILE}"
        return 1
    fi
    
    # 5. 测试手动启动
    print_info "测试手动启动..."
    timeout 3 ${HYSTERIA_BIN} server -c ${CONFIG_FILE} || true
    
    # 6. 重新创建服务文件（确保路径正确）
    create_service
    
    # 7. 重启服务
    print_info "重启服务..."
    systemctl daemon-reload
    systemctl restart ${SERVICE_NAME}
    sleep 3
    
    # 8. 检查状态
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        print_success "203/EXEC 错误已修复，服务正常运行"
    else
        print_error "修复失败，查看日志："
        journalctl -u ${SERVICE_NAME} -n 20 --no-pager
        return 1
    fi
}

# 启动服务（带错误检测和修复）
start_service() {
    print_info "启动服务..."
    
    # 先尝试启动
    systemctl start ${SERVICE_NAME}
    sleep 3
    
    # 检查状态
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        print_success "服务启动成功"
        return 0
    fi
    
    # 检查错误
    local STATUS=$(systemctl status ${SERVICE_NAME} --no-pager)
    
    if echo "$STATUS" | grep -q "status=203/EXEC"; then
        print_error "检测到 203/EXEC 错误，自动修复..."
        fix_203_exec
    else
        print_error "服务启动失败"
        journalctl -u ${SERVICE_NAME} -n 20 --no-pager
        return 1
    fi
}

# 导出配置
export_config() {
    local SERVER_IP=$(get_server_ip)
    local PORT=$(grep "listen:" ${CONFIG_FILE} 2>/dev/null | awk '{print $2}' | tr -d ':' || echo "24330")
    local PASS=$(grep "password:" ${CONFIG_FILE} 2>/dev/null | awk '{print $2}' || echo "unknown")
    local HOSTNAME=$(grep "# 主机名：" ${CONFIG_FILE} 2>/dev/null | awk '{print $3}' || echo "Hysteria2")
    
    mkdir -p ${CONFIG_BACKUP_DIR}
    
    echo -e ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  📋 Hysteria 2 配置信息${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
    
    echo -e "${CYAN}【1】基本信息${NC}"
    echo -e "  服务器地址：${YELLOW}${SERVER_IP}${NC}"
    echo -e "  端口：${YELLOW}${PORT}${NC}"
    echo -e "  密码：${YELLOW}${PASS}${NC}"
    echo -e ""
    
    echo -e "${CYAN}【2】Hysteria2 链接${NC}"
    local HY2_LINK="hysteria2://${PASS}@${SERVER_IP}:${PORT}/?insecure=1&alpn=h3&obfs=none#${HOSTNAME}"
    echo -e "${YELLOW}${HY2_LINK}${NC}"
    echo -e ""
    
    echo -e "${CYAN}【3】JSON 格式${NC}"
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
    echo -e ""
    
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
EOFC
    echo -e ""
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  快速复制区${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
    echo -e "${YELLOW}${HY2_LINK}${NC}"
    echo -e ""
    
    # 保存配置
    local BACKUP_FILE="${CONFIG_BACKUP_DIR}/hy2-config-$(date +%Y%m%d-%H%M%S).txt"
    cat > ${BACKUP_FILE} << EOFB
# Hysteria 2 配置
# 生成时间：$(date)

服务器地址：${SERVER_IP}
端口：${PORT}
密码：${PASS}

Hysteria2 链接：
${HY2_LINK}
EOFB
    
    print_success "配置已保存到：${BACKUP_FILE}"
}

# 安装主函数
do_install() {
    print_info "开始安装 Hysteria 2..."
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
    
    print_success "安装完成！"
}

# 修复命令
do_repair() {
    print_info "开始修复..."
    check_root
    detect_os
    install_dependencies
    fix_203_exec
    export_config
}

# 其他命令
do_start() { systemctl start ${SERVICE_NAME}; systemctl status ${SERVICE_NAME}; }
do_stop() { systemctl stop ${SERVICE_NAME}; print_success "服务已停止"; }
do_restart() { systemctl restart ${SERVICE_NAME}; systemctl status ${SERVICE_NAME}; }
do_status() { systemctl status ${SERVICE_NAME}; }
do_log() { journalctl -u ${SERVICE_NAME} -f; }
do_config() { export_config; }
do_export() { export_config; }

do_update() {
    print_info "更新 Hysteria 2..."
    do_install
    print_success "更新完成"
}

do_uninstall() {
    print_warning "确定要卸载吗？(y/N)"
    read -r confirm
    
    if [[ $confirm != [Yy] && $confirm != [Yy][Ee][Ss] ]]; then
        print_info "取消卸载"
        exit 0
    fi
    
    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    systemctl disable ${SERVICE_NAME} 2>/dev/null || true
    rm -f ${SERVICE_FILE} ${HYSTERIA_BIN} ${CONFIG_FILE}
    rm -rf ${CERT_DIR}
    systemctl daemon-reload
    
    print_success "卸载完成"
}

show_help() {
    echo -e "${GREEN}Hysteria 2 完整安装维护脚本 v4.0${NC}"
    echo -e ""
    echo -e "用法：$0 [命令]"
    echo -e ""
    echo -e "命令:"
    echo -e "  install   安装 Hysteria 2（默认）"
    echo -e "  repair    修复 203/EXEC 错误"
    echo -e "  start     启动服务"
    echo -e "  stop      停止服务"
    echo -e "  restart   重启服务"
    echo -e "  status    查看状态"
    echo -e "  config    显示配置"
    echo -e "  export    导出配置"
    echo -e "  update    更新"
    echo -e "  log       查看日志"
    echo -e "  uninstall 卸载"
    echo -e "  help      显示帮助"
    echo -e ""
    echo -e "示例:"
    echo -e "  $0              # 安装"
    echo -e "  $0 repair       # 修复 203/EXEC 错误"
    echo -e "  $0 config       # 显示配置"
}

main() {
    local COMMAND=${1:-install}
    
    case $COMMAND in
        install) do_install ;;
        repair) do_repair ;;
        start) do_start ;;
        stop) do_stop ;;
        restart) do_restart ;;
        status) do_status ;;
        config|export) do_config ;;
        update) do_update ;;
        log) do_log ;;
        uninstall) do_uninstall ;;
        help|--help|-h) show_help ;;
        *) print_error "未知命令：$COMMAND"; show_help; exit 1 ;;
    esac
}

main "$@"
