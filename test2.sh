#!/bin/bash
#===============================================================================
#
#          FILE: hy2-full.sh
# 
#         USAGE: curl -fsSL https://raw.githubusercontent.com/wuguang828/server/main/hy2-full.sh | bash
#
#   DESCRIPTION: Hysteria 2 完整安装维护脚本
#
#   OPTIONS: 
#       install   - 安装（默认）
#       config    - 显示完整配置
#       export    - 导出配置
#       start     - 启动服务
#       stop      - 停止服务
#       restart   - 重启服务
#       status    - 查看状态
#       uninstall - 卸载
#
#       AUTHOR: wuguang828
#      VERSION: 6.0
#===============================================================================

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 变量
SERVICE_NAME="hysteria-server"
CONFIG_FILE="/etc/hysteria/config.yaml"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HYSTERIA_BIN="/usr/bin/hysteria"
CERT_DIR="/etc/hysteria"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# 检查root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "必须使用root权限运行！"
        exit 1
    fi
}

# 获取IP
get_ip() {
    curl -s -4 icanhazip.com 2>/dev/null || echo "0.0.0.0"
}

# 获取配置信息
get_config_info() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi
    PORT=$(grep "listen:" $CONFIG_FILE | awk '{print $2}' | tr -d ':')
    PASS=$(grep "password:" $CONFIG_FILE | awk '{print $2}')
    SERVER_IP=$(get_ip)
}

# 显示完整配置
show_config() {
    get_config_info || { print_error "配置文件不存在"; exit 1; }
    
    echo -e ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  📋 Hysteria 2 配置信息${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e ""
    
    echo -e "${CYAN}【1】基本信息${NC}"
    echo -e "  服务器地址：${YELLOW}${SERVER_IP}${NC}"
    echo -e "  端口：${YELLOW}${PORT}${NC}"
    echo -e "  密码：${YELLOW}${PASS}${NC}"
    echo -e "  协议：${YELLOW}Hysteria 2 (QUIC)${NC}"
    echo -e ""
    
    echo -e "${CYAN}【2】Hysteria2 链接（一键导入）${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}hysteria2://${PASS}@${SERVER_IP}:${PORT}/?insecure=1&alpn=h3&obfs=none#Hysteria2${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e ""
    
    echo -e "${CYAN}【3】JSON 格式（NekoBox/Hiddify）${NC}"
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
  "remark": "Hysteria2"
}
EOFJ
    echo -e ""
    
    echo -e "${CYAN}【4】Clash Meta 格式${NC}"
    cat << EOFC
  - name: "Hysteria2"
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
    
    echo -e "${CYAN}【5】Sing-Box 格式${NC}"
    cat << EOFS
{
  "tag": "Hysteria2",
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
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  客户端下载${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  Android: https://github.com/MatsuriDayo/NekoBoxForAndroid/releases"
    echo -e "  Windows: https://github.com/hiddify/hiddify-next/releases"
    echo -e "  iOS:     Shadowrocket / Streisand"
    echo -e ""
}

# 安装
do_install() {
    check_root
    
    print_info "开始安装 Hysteria 2..."
    
    # 设置非交互模式
    export DEBIAN_FRONTEND=noninteractive
    
    # 修复dpkg
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
    
    # 安装依赖
    print_info "安装依赖..."
    apt-get update -qq
    apt-get install -y -qq curl wget openssl net-tools systemd
    
    # 生成配置
    PORT=$((RANDOM % 55535 + 10000))
    PASS=$(openssl rand -hex 16)
    SERVER_IP=$(get_ip)
    
    print_info "端口：$PORT"
    print_info "密码：$PASS"
    
    # 下载Hysteria
    print_info "下载 Hysteria 2..."
    wget -q --show-progress -O ${HYSTERIA_BIN} https://github.com/apernet/hysteria/releases/download/v2.4.2/hysteria-linux-amd64
    chmod +x ${HYSTERIA_BIN}
    
    # 验证
    if ! ${HYSTERIA_BIN} --version &>/dev/null; then
        print_error "二进制文件验证失败"
        exit 1
    fi
    
    print_success "Hysteria 2 下载完成"
    
    # 生成证书
    print_info "生成 TLS 证书..."
    mkdir -p ${CERT_DIR}
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout ${CERT_DIR}/server.key \
        -out ${CERT_DIR}/server.crt \
        -days 3650 -subj "/CN=${SERVER_IP}" 2>/dev/null
    
    print_success "TLS 证书生成完成"
    
    # 创建配置
    print_info "创建配置文件..."
    cat > ${CONFIG_FILE} << EOF
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
    
    # 创建服务
    print_info "创建 systemd 服务..."
    cat > ${SERVICE_FILE} << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${HYSTERIA_BIN} server -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}
    
    print_success "systemd 服务创建完成"
    
    # 防火墙
    print_info "配置防火墙..."
    ufw allow ${PORT}/udp 2>/dev/null || true
    ufw allow ${PORT}/tcp 2>/dev/null || true
    
    # 启动
    print_info "启动服务..."
    systemctl start ${SERVICE_NAME}
    sleep 3
    
    # 显示配置
    show_config
    
    # 检查状态
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        print_success "服务运行正常"
    else
        print_error "服务启动失败"
        systemctl status ${SERVICE_NAME} --no-pager
    fi
}

# 其他命令
do_start() { systemctl start ${SERVICE_NAME}; systemctl status ${SERVICE_NAME}; }
do_stop() { systemctl stop ${SERVICE_NAME}; print_success "服务已停止"; }
do_restart() { systemctl restart ${SERVICE_NAME}; systemctl status ${SERVICE_NAME}; }
do_status() { systemctl status ${SERVICE_NAME}; }

do_uninstall() {
    print_warning "确定要卸载吗？(y/N)"
    read -r confirm
    [[ $confirm != [Yy]* ]] && { print_info "取消"; exit 0; }
    
    systemctl stop ${SERVICE_NAME} 2>/dev/null || true
    systemctl disable ${SERVICE_NAME} 2>/dev/null || true
    rm -f ${SERVICE_FILE} ${HYSTERIA_BIN} ${CONFIG_FILE}
    rm -rf ${CERT_DIR}
    systemctl daemon-reload
    
    print_success "卸载完成"
}

# 帮助
show_help() {
    echo -e "${GREEN}Hysteria 2 完整安装维护脚本${NC}"
    echo -e ""
    echo -e "用法：$0 [命令]"
    echo -e ""
    echo -e "命令:"
    echo -e "  install   安装（默认）"
    echo -e "  config    显示完整配置"
    echo -e "  export    导出配置（同config）"
    echo -e "  start     启动服务"
    echo -e "  stop      停止服务"
    echo -e "  restart   重启服务"
    echo -e "  status    查看状态"
    echo -e "  uninstall 卸载"
    echo -e "  help      显示帮助"
    echo -e ""
    echo -e "示例:"
    echo -e "  $0              # 安装并显示配置"
    echo -e "  $0 config       # 显示配置"
    echo -e "  $0 restart      # 重启服务"
}

# 主程序
case ${1:-install} in
    install) do_install ;;
    config|export) show_config ;;
    start) do_start ;;
    stop) do_stop ;;
    restart) do_restart ;;
    status) do_status ;;
    uninstall) do_uninstall ;;
    help|--help|-h) show_help ;;
    *) print_error "未知命令：$1"; show_help; exit 1 ;;
esac
