#!/bin/bash
# Hysteria 2 一键安装脚本
# 支持 Ubuntu/Debian/CentOS

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查root权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：必须使用root权限运行！${NC}"
   exit 1
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Hysteria 2 一键安装脚本${NC}"
echo -e "${BLUE}========================================${NC}"

# 检测操作系统
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

echo -e "${YELLOW}检测到系统：${OS} ${VER}${NC}"

# 获取服务器IP
get_ip() {
    local IP=$(curl -s -4 icanhazip.com 2>/dev/null)
    if [ -z "$IP" ]; then
        IP=$(curl -s -6 icanhazip.com 2>/dev/null)
    fi
    echo "$IP"
}

SERVER_IP=$(get_ip)
echo -e "${YELLOW}服务器IP：${SERVER_IP}${NC}"

# 生成随机端口（10000-65535）
RANDOM_PORT=$((RANDOM % 55535 + 10000))

# 生成随机密码
RANDOM_PASS=$(openssl rand -hex 16)

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}正在安装依赖...${NC}"
    
    if [ -f /etc/redhat-release ]; then
        # CentOS/RHEL
        yum update -y
        yum install -y curl wget openssl
    elif [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        apt-get update
        apt-get install -y curl wget openssl
    fi
}

# 下载Hysteria 2
download_hysteria() {
    echo -e "${YELLOW}正在下载Hysteria 2...${NC}"
    
    # 获取最新版本号
    LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c2-)
    
    # 根据架构下载
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="arm" ;;
    esac
    
    # 下载
    wget -q https://github.com/apernet/hysteria/releases/download/app%2Fv${LATEST_VERSION}/hysteria-linux-${ARCH} -O /usr/bin/hysteria
    
    # 赋予执行权限
    chmod +x /usr/bin/hysteria
    
    echo -e "${GREEN}Hysteria 2 安装完成 (v${LATEST_VERSION})${NC}"
}

# 生成自签名证书
generate_cert() {
    echo -e "${YELLOW}正在生成TLS证书...${NC}"
    
    mkdir -p /etc/hysteria
    
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/server.key \
        -out /etc/hysteria/server.crt \
        -days 3650 \
        -subj "/CN=${SERVER_IP}" \
        -addext "subjectAltName=IP:${SERVER_IP}" \
        2>/dev/null
    
    echo -e "${GREEN}证书生成完成${NC}"
}

# 创建配置文件
create_config() {
    echo -e "${YELLOW}正在创建配置文件...${NC}"
    
    cat > /etc/hysteria/config.yaml << EOF
# Hysteria 2 配置文件
listen: :${RANDOM_PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${RANDOM_PASS}

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
EOF

    echo -e "${GREEN}配置文件创建完成${NC}"
}

# 创建systemd服务
create_service() {
    echo -e "${YELLOW}正在创建systemd服务...${NC}"
    
    cat > /etc/systemd/system/hysteria-server.service << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # 重载systemd
    systemctl daemon-reload
    
    # 启用开机启动
    systemctl enable hysteria-server.service
    
    echo -e "${GREEN}systemd服务创建完成${NC}"
}

# 配置防火墙
configure_firewall() {
    echo -e "${YELLOW}正在配置防火墙...${NC}"
    
    if command -v firewall-cmd &> /dev/null; then
        # CentOS firewalld
        firewall-cmd --permanent --add-port=${RANDOM_PORT}/udp
        firewall-cmd --permanent --add-port=${RANDOM_PORT}/tcp
        firewall-cmd --reload
    elif command -v ufw &> /dev/null; then
        # Ubuntu/Debian ufw
        ufw allow ${RANDOM_PORT}/udp
        ufw allow ${RANDOM_PORT}/tcp
    elif command -v iptables &> /dev/null; then
        # iptables
        iptables -I INPUT -p udp --dport ${RANDOM_PORT} -j ACCEPT
        iptables -I INPUT -p tcp --dport ${RANDOM_PORT} -j ACCEPT
        
        # 保存规则
        if [ -f /etc/redhat-release ]; then
            service iptables save 2>/dev/null || iptables-save > /etc/sysconfig/iptables
        elif [ -f /etc/debian_version ]; then
            iptables-save > /etc/iptables/rules.v4
        fi
    fi
    
    echo -e "${GREEN}防火墙配置完成${NC}"
}

# 启动服务
start_service() {
    echo -e "${YELLOW}正在启动服务...${NC}"
    
    systemctl start hysteria-server.service
    
    # 检查状态
    sleep 2
    if systemctl is-active --quiet hysteria-server.service; then
        echo -e "${GREEN}服务启动成功！${NC}"
    else
        echo -e "${RED}服务启动失败，请检查日志${NC}"
        systemctl status hysteria-server.service
        exit 1
    fi
}

# 显示配置信息
show_info() {
    echo -e ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}  Hysteria 2 安装完成！${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e ""
    echo -e "${YELLOW}服务器地址：${NC}${SERVER_IP}"
    echo -e "${YELLOW}端口：${NC}${RANDOM_PORT}"
    echo -e "${YELLOW}密码：${NC}${RANDOM_PASS}"
    echo -e "${YELLOW}协议：${NC}Hysteria 2 (QUIC)"
    echo -e ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}客户端配置信息（复制保存）：${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e ""
    echo "hysteria2://${RANDOM_PASS}@${SERVER_IP}:${RANDOM_PORT}/?insecure=1&alpn=h3&obfs=none#Hysteria2-Server"
    echo -e ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}客户端下载：${NC}"
    echo -e "Windows: https://github.com/HyNetwork/hysteria/releases"
    echo -e "Android: https://github.com/HyNetwork/hysteria/releases"
    echo -e "iOS:     使用Shadowrocket或Streisand"
    echo -e ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${YELLOW}服务管理命令：${NC}"
    echo -e "启动：systemctl start hysteria-server"
    echo -e "停止：systemctl stop hysteria-server"
    echo -e "重启：systemctl restart hysteria-server"
    echo -e "状态：systemctl status hysteria-server"
    echo -e "${BLUE}========================================${NC}"
}

# 主流程
main() {
    install_dependencies
    download_hysteria
    generate_cert
    create_config
    create_service
    configure_firewall
    start_service
    show_info
}

# 运行
main
