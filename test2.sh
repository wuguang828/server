#!/bin/bash
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 全局变量
SERVICE_NAME="hysteria-server"
CONFIG_FILE="/etc/hysteria/config.yaml"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HYSTERIA_BIN="/usr/bin/hysteria"
CERT_DIR="/etc/hysteria"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

# 检查root
if [[ $EUID -ne 0 ]]; then
    print_error "必须使用root权限运行！"
    exit 1
fi

# 设置非交互模式
export DEBIAN_FRONTEND=noninteractive

print_info "开始安装 Hysteria 2..."

# 安装依赖（非交互模式）
print_info "安装依赖..."
apt-get update -qq
apt-get install -y -qq curl wget openssl net-tools systemd libpam-runtime

# 获取配置
PORT=$((RANDOM % 55535 + 10000))
PASS=$(openssl rand -hex 16)
SERVER_IP=$(curl -s -4 icanhazip.com 2>/dev/null || echo "0.0.0.0")

print_info "端口：$PORT"
print_info "密码：$PASS"

# 下载 Hysteria
print_info "下载 Hysteria 2..."
LATEST_VERSION="2.4.2"
wget -q --show-progress -O ${HYSTERIA_BIN} https://github.com/apernet/hysteria/releases/download/v${LATEST_VERSION}/hysteria-linux-amd64
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
echo -e ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  ✅ Hysteria 2 安装完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e ""
echo -e "服务器地址：${SERVER_IP}"
echo -e "端口：${PORT}"
echo -e "密码：${PASS}"
echo -e ""
echo -e "连接命令："
echo -e "hysteria2://${PASS}@${SERVER_IP}:${PORT}/?insecure=1&alpn=h3&obfs=none#Hysteria2"
echo -e ""

# 检查状态
if systemctl is-active --quiet ${SERVICE_NAME}; then
    print_success "服务运行正常"
else
    print_error "服务启动失败"
    systemctl status ${SERVICE_NAME} --no-pager
fi

echo -e ""
