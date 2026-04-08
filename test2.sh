#!/bin/bash
# Hysteria 2 一键安装脚本
# 作者：wuguang028

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：必须使用root权限运行！${NC}"
   exit 1
fi

echo -e "${GREEN}开始安装Hysteria 2...${NC}"

# 获取IP
SERVER_IP=$(curl -s -4 icanhazip.com)
[ -z "$SERVER_IP" ] && SERVER_IP=$(curl -s -6 icanhazip.com)

# 随机配置
RANDOM_PORT=$((RANDOM % 55535 + 10000))
RANDOM_PASS=$(openssl rand -hex 16)

# 下载Hysteria
echo -e "${YELLOW}下载Hysteria 2...${NC}"
LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c2-)
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构：$ARCH${NC}"; exit 1 ;;
esac

wget -q https://github.com/apernet/hysteria/releases/download/v${LATEST_VERSION}/hysteria-linux-${ARCH} -O /usr/bin/hysteria
chmod +x /usr/bin/hysteria

# 生成证书
echo -e "${YELLOW}生成TLS证书...${NC}"
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -days 3650 -subj "/CN=${SERVER_IP}" 2>/dev/null

# 创建配置
echo -e "${YELLOW}创建配置文件...${NC}"
cat > /etc/hysteria/config.yaml << EOF
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

speedTest: true
disableUDP: false
EOF

# 创建systemd服务
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

systemctl daemon-reload
systemctl enable hysteria-server.service

# 防火墙
if command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=${RANDOM_PORT}/udp
    firewall-cmd --permanent --add-port=${RANDOM_PORT}/tcp
    firewall-cmd --reload
elif command -v ufw &> /dev/null; then
    ufw allow ${RANDOM_PORT}/udp
    ufw allow ${RANDOM_PORT}/tcp
fi

# 启动
systemctl start hysteria-server.service
sleep 2

# 显示信息
echo -e ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Hysteria 2 安装完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e ""
echo -e "服务器地址: ${SERVER_IP}"
echo -e "端口: ${RANDOM_PORT}"
echo -e "密码: ${RANDOM_PASS}"
echo -e ""
echo -e "连接命令:"
echo -e "hysteria2://${RANDOM_PASS}@${SERVER_IP}:${RANDOM_PORT}/?insecure=1&alpn=h3&obfs=none#Hysteria2"
echo -e ""
echo -e "服务管理:"
echo -e "systemctl status hysteria-server"
echo -e ""
