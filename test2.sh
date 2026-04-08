#!/bin/bash
# 修复并重新安装

echo "🔧 正在修复 Hysteria 2..."

# 1. 安装缺失的工具
echo "安装 net-tools..."
apt-get update
apt-get install -y net-tools

# 2. 停止当前服务
systemctl stop hysteria-server 2>/dev/null || true

# 3. 检查配置
echo "检查配置文件..."
cat /etc/hysteria/config.yaml

# 4. 检查二进制文件
echo "检查 Hysteria 二进制文件..."
ls -la /usr/bin/hysteria
/usr/bin/hysteria --version || {
    echo "Hysteria 未正确安装，重新下载..."
    wget -O /usr/bin/hysteria https://github.com/apernet/hysteria/releases/download/v2.4.2/hysteria-linux-amd64
    chmod +x /usr/bin/hysteria
}

# 5. 生成证书（如果不存在）
if [ ! -f /etc/hysteria/server.crt ]; then
    echo "生成 TLS 证书..."
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/hysteria/server.key \
        -out /etc/hysteria/server.crt \
        -days 3650 -subj "/CN=$(curl -s -4 icanhazip.com)" 2>/dev/null
fi

# 6. 手动测试启动
echo "测试启动..."
timeout 5 /usr/bin/hysteria server -c /etc/hysteria/config.yaml || true

# 7. 启动服务
echo "启动服务..."
systemctl daemon-reload
systemctl enable hysteria-server.service
systemctl start hysteria-server.service
sleep 3

# 8. 检查状态
echo ""
echo "服务状态："
systemctl status hysteria-server --no-pager

# 9. 开放防火墙
ufw allow 24330/udp 2>/dev/null || true
ufw allow 24330/tcp 2>/dev/null || true

# 10. 显示配置
SERVER_IP=$(curl -s -4 icanhazip.com)
echo ""
echo "========================================"
echo "  ✅ 修复完成！"
echo "========================================"
echo ""
echo "服务器地址：${SERVER_IP}"
echo "端口：24330"
echo "密码：66315b5a411efde221cd0ce317875ffa"
echo ""
echo "连接命令："
echo "hysteria2://66315b5a411efde221cd0ce317875ffa@${SERVER_IP}:24330/?insecure=1&alpn=h3&obfs=none#Hysteria2"
echo ""
