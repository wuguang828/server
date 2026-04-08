#!/bin/bash
# Hysteria 2 简化安装脚本

set -e

echo "🚀 开始安装 Hysteria 2..."

# 检查root
if [[ $EUID -ne 0 ]]; then
   echo "错误：必须使用root权限运行！"
   exit 1
fi

# 安装依赖
echo "安装依赖..."
apt-get update
apt-get install -y curl wget openssl

# 获取最新版本的 Hysteria 2
echo "下载 Hysteria 2..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' | cut -c2-)
wget -O /usr/bin/hysteria https://github.com/apernet/hysteria/releases/download/v${LATEST_VERSION}/hysteria-linux-amd64
chmod +x /usr/bin/hysteria

# 生成配置
PORT=$((RANDOM % 55535 + 10000))
PASS=$(openssl rand -hex 16)
SERVER_IP=$(curl -s -4 icanhazip.com)

# 创建目录和证书
mkdir -p /etc/hysteria
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -days 3650 -subj "/CN=${SERVER_IP}" 2>/dev/null

# 创建配置文件
cat > /etc/hysteria/config.yaml << EOF
listen: :${PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

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

# 启动服务
systemctl daemon-reload
systemctl enable hysteria-server.service
systemctl start hysteria-server.service

# 开放防火墙
ufw allow ${PORT}/udp 2>/dev/null || true
ufw allow ${PORT}/tcp 2>/dev/null || true

# 显示配置
echo ""
echo "========================================"
echo "  ✅ Hysteria 2 安装完成！"
echo "========================================"
echo ""
echo "服务器地址：${SERVER_IP}"
echo "端口：${PORT}"
echo "密码：${PASS}"
echo ""
echo "连接命令："
echo "hysteria2://${PASS}@${SERVER_IP}:${PORT}/?insecure=1&alpn=h3&obfs=none#Hysteria2"
echo ""
echo "服务状态："
systemctl status hysteria-server --no-pager
echo ""
