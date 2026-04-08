#!/bin/bash

PORT=24330

echo "🔧 正在修复Hysteria 2连接问题..."

# 1. 检查服务
echo "检查服务状态..."
systemctl restart hysteria-server
sleep 2

# 2. 开放防火墙
echo "开放防火墙端口..."
if command -v ufw &> /dev/null; then
    ufw allow $PORT/udp
    ufw allow $PORT/tcp
    ufw reload
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=$PORT/udp
    firewall-cmd --permanent --add-port=$PORT/tcp
    firewall-cmd --reload
fi

# 3. 检查监听
echo "检查端口监听..."
netstat -tunlp | grep $PORT

# 4. 测试服务
echo "服务状态："
systemctl status hysteria-server | grep Active

echo -e "\n✅ 修复完成！"
echo "请在Vultr控制台开放端口 $PORT (TCP+UDP)"
