#!/bin/bash
# YYB Mac 模拟器 Curl Error 28 网络诊断脚本
# 用途：排查 QEMU SLiRP 虚拟网络栈导致的 HTTPS 连接超时问题

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS="${GREEN}[PASS]${NC}"; FAIL="${RED}[FAIL]${NC}"; WARN="${YELLOW}[WARN]${NC}"; INFO="${CYAN}[INFO]${NC}"

TARGET_URL_HTTP="http://down-update.qq.com/sgame/PreUpdateCfgs/11030101/3859c6e28cafabc/phoneSpecList.tsv"
TARGET_URL_HTTPS="https://down-update.qq.com/sgame/PreUpdateCfgs/11030101/3859c6e28cafabc/phoneSpecList.tsv"
TARGET_HOST="down-update.qq.com"

echo "============================================================"
echo "  YYB Mac 模拟器 Curl Error 28 网络诊断"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

# ─────────────────────────────────────────────
# 1. 检查 YYB/QEMU 进程是否运行
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [1] 检查模拟器进程状态"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

QEMU_PID=$(pgrep -x qemu-system-x86_64 2>/dev/null || pgrep -f "qemu-system-x86_64" 2>/dev/null | head -1)
if [ -n "$QEMU_PID" ]; then
    echo -e " $PASS QEMU 进程运行中 (PID: $QEMU_PID)"
    QEMU_CMD=$(ps -p "$QEMU_PID" -o command= 2>/dev/null)
    
    # 检查网络模式
    if echo "$QEMU_CMD" | grep -q "netdev.*user\|-net.*user\|slave.*pcap"; then
        if echo "$QEMU_CMD" | grep -q "pcap"; then
            echo -e " $INFO 网络模式: pcap 桥接 (性能较好)"
        else
            echo -e " $WARN 网络模式: SLiRP 用户态 NAT (性能较差，已知会导致 HTTPS 超时)"
        fi
    else
        echo -e " $INFO 网络模式: 未明确识别 (命令行: $(echo "$QEMU_CMD" | grep -o '\-net[^[:space:]]*\|netdev[^[:space:]]*' | head -3))"
    fi
    
    # 检查 QEMU 主线程 CPU 使用率
    QEMU_CPU=$(ps -p "$QEMU_PID" -o %cpu= 2>/dev/null | tr -d ' ')
    echo -e " $INFO QEMU 主进程 CPU: ${QEMU_CPU}%"
    if [ "$(echo "$QEMU_CPU > 80" | bc 2>/dev/null)" = "1" ]; then
        echo -e " $FAIL QEMU CPU 使用率过高 (${QEMU_CPU}%)，可能导致 SLiRP 网络转发阻塞"
    fi
    
    # 检查 QEMU 线程数
    QEMU_THREADS=$(ps -M -p "$QEMU_PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    echo -e " $INFO QEMU 线程数: $QEMU_THREADS"
    
else
    echo -e " $FAIL 未检测到 QEMU 进程，请先启动模拟器"
    echo -e " $INFO 跳过 VM 内部测试，仅执行宿主机测试"
fi
echo ""

# ─────────────────────────────────────────────
# 2. Mac 宿主机网络基础检查
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [2] Mac 宿主机网络基础检查"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# DNS 解析
echo -e " $INFO DNS 解析 $TARGET_HOST:"
DNS_RESULT=$(dig +short "$TARGET_HOST" A 2>/dev/null | head -3)
if [ -n "$DNS_RESULT" ]; then
    echo -e "   $PASS 解析成功: $DNS_RESULT"
else
    DNS_RESULT=$(nslookup "$TARGET_HOST" 2>/dev/null | grep "Address:" | tail -1 | awk '{print $2}')
    if [ -n "$DNS_RESULT" ]; then
        echo -e "   $PASS 解析成功: $DNS_RESULT"
    else
        echo -e "   $FAIL DNS 解析失败"
    fi
fi

# 默认网关可达性
GW=$(netstat -nr 2>/dev/null | grep "^default" | head -1 | awk '{print $2}')
if [ -n "$GW" ]; then
    PING_GW=$(ping -c 1 -W 2000 "$GW" 2>/dev/null | grep "time=")
    if [ -n "$PING_GW" ]; then
        GW_MS=$(echo "$PING_GW" | grep -o 'time=[0-9.]*' | cut -d= -f2)
        echo -e " $PASS 网关 $GW 可达 (${GW_MS}ms)"
    else
        echo -e " $FAIL 网关 $GW 不可达"
    fi
fi

# 外网连通性
PING_EXT=$(ping -c 3 -W 3000 8.8.8.8 2>/dev/null)
PING_LOSS=$(echo "$PING_EXT" | grep "packet loss" | grep -o '[0-9]*\.[0-9]*%' | head -1)
if [ -n "$PING_LOSS" ]; then
    if [ "$(echo "$PING_LOSS" | cut -d% -f1 | awk '{print ($0+0)<5}')" = "1" ]; then
        echo -e " $PASS 外网 ping 8.8.8.8 丢包率: $PING_LOSS"
    else
        echo -e " $FAIL 外网 ping 8.8.8.8 丢包率: $PING_LOSS (异常)"
    fi
fi
echo ""

# ─────────────────────────────────────────────
# 3. Mac 宿主机直接下载测试 (HTTP vs HTTPS)
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [3] Mac 宿主机直接下载测试"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# HTTP 下载测试
echo -e " $INFO 测试 HTTP 下载 (9秒超时)..."
HTTP_RESULT=$(curl -sS -o /dev/null -w "http_code:%{http_code} time_total:%{time_total} time_connect:%{time_connect} time_starttransfer:%{time_starttransfer} speed_download:%{speed_download}" --connect-timeout 9 --max-time 15 "$TARGET_URL_HTTP" 2>&1)
HTTP_CODE=$(echo "$HTTP_RESULT" | grep -o 'http_code:[0-9]*' | cut -d: -f2)
HTTP_TOTAL=$(echo "$HTTP_RESULT" | grep -o 'time_total:[0-9.]*' | cut -d: -f2)
HTTP_CONNECT=$(echo "$HTTP_RESULT" | grep -o 'time_connect:[0-9.]*' | cut -d: -f2)
HTTP_START=$(echo "$HTTP_RESULT" | grep -o 'time_starttransfer:[0-9.]*' | cut -d: -f2)

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    echo -e "   $PASS HTTP 状态码: $HTTP_CODE, 总耗时: ${HTTP_TOTAL}s, 连接: ${HTTP_CONNECT}s, 首字节: ${HTTP_START}s"
else
    echo -e "   $FAIL HTTP 请求失败: $HTTP_RESULT"
fi

# HTTPS 下载测试
echo -e " $INFO 测试 HTTPS 下载 (9秒超时)..."
HTTPS_RESULT=$(curl -sS -o /dev/null -w "http_code:%{http_code} time_total:%{time_total} time_connect:%{time_connect} time_appconnect:%{time_appconnect} time_starttransfer:%{time_starttransfer} speed_download:%{speed_download}" --connect-timeout 9 --max-time 15 "$TARGET_URL_HTTPS" 2>&1)
HTTPS_CODE=$(echo "$HTTPS_RESULT" | grep -o 'http_code:[0-9]*' | cut -d: -f2)
HTTPS_TOTAL=$(echo "$HTTPS_RESULT" | grep -o 'time_total:[0-9.]*' | cut -d: -f2)
HTTPS_CONNECT=$(echo "$HTTPS_RESULT" | grep -o 'time_connect:[0-9.]*' | cut -d: -f2)
HTTPS_APPCONN=$(echo "$HTTPS_RESULT" | grep -o 'time_appconnect:[0-9.]*' | cut -d: -f2)
HTTPS_START=$(echo "$HTTPS_RESULT" | grep -o 'time_starttransfer:[0-9.]*' | cut -d: -f2)

if [ "$HTTPS_CODE" = "200" ] || [ "$HTTPS_CODE" = "302" ] || [ "$HTTPS_CODE" = "301" ]; then
    echo -e "   $PASS HTTPS 状态码: $HTTPS_CODE, 总耗时: ${HTTPS_TOTAL}s, TCP连接: ${HTTPS_CONNECT}s, TLS握手: ${HTTPS_APPCONN}s, 首字节: ${HTTPS_START}s"
    TLS_TIME=$(echo "$HTTPS_APPCONN $HTTPS_CONNECT" | awk '{printf "%.3f", $1 - $2}')
    echo -e "   $INFO 纯 TLS 握手耗时: ${TLS_TIME}s"
else
    echo -e "   $FAIL HTTPS 请求失败: $HTTPS_RESULT"
fi

# HTTP vs HTTPS 对比
if [ -n "$HTTP_TOTAL" ] && [ -n "$HTTPS_TOTAL" ]; then
    TIME_DIFF=$(echo "$HTTPS_TOTAL $HTTP_TOTAL" | awk '{printf "%.3f", $1 - $2}')
    echo -e " $INFO HTTPS 比 HTTP 慢: ${TIME_DIFF}s"
    if [ "$(echo "$TIME_DIFF > 3" | bc 2>/dev/null)" = "1" ]; then
        echo -e " $WARN HTTPS 显著慢于 HTTP (>3s)，TLS 握手可能存在问题"
    fi
fi
echo ""

# ─────────────────────────────────────────────
# 4. SSL/TLS 握手详细分析
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [4] SSL/TLS 握手详细分析"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

OPENSSL_START=$(python3 -c "import time; print(time.time())" 2>/dev/null || date +%s%3N)
TLS_INFO=$(echo | openssl s_client -connect "$TARGET_HOST:443" -servername "$TARGET_HOST" 2>/dev/null)
OPENSSL_END=$(python3 -c "import time; print(time.time())" 2>/dev/null || date +%s%3N)

TLS_PROTO=$(echo "$TLS_INFO" | grep "Protocol" | head -1 | awk '{print $NF}')
TLS_CIPHER=$(echo "$TLS_INFO" | grep "Cipher" | head -1 | awk '{print $NF}')
TLS_VERIFY=$(echo "$TLS_INFO" | grep "Verify return code" | awk '{print $NF}')

if [ -n "$TLS_PROTO" ]; then
    echo -e " $PASS TLS 协议: $TLS_PROTO, 密码套件: $TLS_CIPHER"
else
    echo -e " $FAIL TLS 握手失败 (可能是网络不可达或被拦截)"
fi

if [ "$TLS_VERIFY" = "0" ]; then
    echo -e " $PASS 证书验证: 通过"
else
    echo -e " $WARN 证书验证返回码: $TLS_VERIFY (0=通过)"
fi
echo ""

# ─────────────────────────────────────────────
# 5. ADB 连接 & VM 内部网络测试
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [5] VM 内部网络测试 (通过 ADB)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 查找 adb
ADB_PATH=$(which adb 2>/dev/null)
if [ -z "$ADB_PATH" ]; then
    # 尝试从 YYB 安装目录查找
    ADB_PATH=$(find /Applications -name "adb" -type f 2>/dev/null | head -1)
    if [ -z "$ADB_PATH" ]; then
        ADB_PATH=$(mdfind -name "adb" 2>/dev/null | grep -v "\.app/" | head -1)
    fi
fi

if [ -n "$ADB_PATH" ]; then
    echo -e " $INFO ADB 路径: $ADB_PATH"
    
    # 检查连接设备
    DEVICES=$("$ADB_PATH" devices 2>/dev/null | grep -v "^List" | grep -v "^$" | head -3)
    if [ -n "$DEVICES" ]; then
        echo -e " $PASS 已连接设备:"
        echo "$DEVICES" | while read -r line; do echo "   $line"; done
        
        # VM 内 IP 地址检查
        VM_IP=$("$ADB_PATH" shell ip addr show eth0 2>/dev/null | grep "inet " | awk '{print $2}')
        if [ -n "$VM_IP" ]; then
            echo -e " $INFO VM 内 eth0 IP: $VM_IP"
        else
            echo -e " $WARN 无法获取 VM 内 IP"
        fi
        
        # VM 内 DNS 检查
        echo -e " $INFO VM 内 DNS 配置:"
        "$ADB_PATH" shell getprop net.dns1 2>/dev/null | while read -r dns; do echo "   DNS1: $dns"; done
        "$ADB_PATH" shell getprop net.dns2 2>/dev/null | while read -r dns; do echo "   DNS2: $dns"; done
        
        # VM 内 ping 测试 (网关 10.0.2.2)
        echo -e " $INFO VM 内 ping 网关 (10.0.2.2):"
        VM_PING=$("$ADB_PATH" shell "ping -c 3 -W 3 10.0.2.2" 2>/dev/null)
        VM_PING_LOSS=$(echo "$VM_PING" | grep "packet loss" | grep -o '[0-9]*%')
        if [ -n "$VM_PING_LOSS" ]; then
            if [ "${VM_PING_LOSS%\%}" -lt 5 ] 2>/dev/null; then
                echo -e "   $PASS 丢包率: $VM_PING_LOSS"
            else
                echo -e "   $FAIL 丢包率: $VM_PING_LOSS (VM→宿主网关链路异常)"
            fi
        else
            echo -e "   $WARN ping 不可用或超时"
        fi
        
        # VM 内 DNS 解析
        echo -e " $INFO VM 内 DNS 解析 $TARGET_HOST:"
        VM_DNS=$("$ADB_PATH" shell "nslookup $TARGET_HOST" 2>/dev/null | grep "Address:" | tail -1)
        if [ -n "$VM_DNS" ]; then
            echo -e "   $PASS 解析成功: $VM_DNS"
        else
            echo -e "   $FAIL DNS 解析失败 (可能是 SLiRP DNS 转发问题)"
        fi
        
        # VM 内 HTTP 下载测试
        echo -e " $INFO VM 内 HTTP 下载测试 (9秒超时):"
        VM_HTTP=$("$ADB_PATH" shell "curl -sS -o /dev/null -w 'http_code:%{http_code} time_total:%{time_total} time_connect:%{time_connect}' --connect-timeout 9 --max-time 15 $TARGET_URL_HTTP" 2>/dev/null)
        if [ -n "$VM_HTTP" ]; then
            VM_HTTP_CODE=$(echo "$VM_HTTP" | grep -o 'http_code:[0-9]*' | cut -d: -f2)
            VM_HTTP_TOTAL=$(echo "$VM_HTTP" | grep -o 'time_total:[0-9.]*' | cut -d: -f2)
            if [ "$VM_HTTP_CODE" = "200" ] || [ "$VM_HTTP_CODE" = "302" ]; then
                echo -e "   $PASS HTTP 状态码: $VM_HTTP_CODE, 耗时: ${VM_HTTP_TOTAL}s"
            else
                echo -e "   $FAIL VM 内 HTTP 失败: $VM_HTTP"
            fi
        else
            echo -e "   $WARN VM 内 curl 不可用或超时 (>15s)"
        fi
        
        # VM 内 HTTPS 下载测试 (关键测试！)
        echo -e " $INFO VM 内 HTTPS 下载测试 (9秒超时) [关键测试]:"
        VM_HTTPS=$("$ADB_PATH" shell "curl -sS -o /dev/null -w 'http_code:%{http_code} time_total:%{time_total} time_connect:%{time_connect} time_appconnect:%{time_appconnect}' --connect-timeout 9 --max-time 15 $TARGET_URL_HTTPS" 2>/dev/null)
        if [ -n "$VM_HTTPS" ]; then
            VM_HTTPS_CODE=$(echo "$VM_HTTPS" | grep -o 'http_code:[0-9]*' | cut -d: -f2)
            VM_HTTPS_TOTAL=$(echo "$VM_HTTPS" | grep -o 'time_total:[0-9.]*' | cut -d: -f2)
            VM_HTTPS_CONNECT=$(echo "$VM_HTTPS" | grep -o 'time_connect:[0-9.]*' | cut -d: -f2)
            VM_HTTPS_APPCONN=$(echo "$VM_HTTPS" | grep -o 'time_appconnect:[0-9.]*' | cut -d: -f2)
            if [ "$VM_HTTPS_CODE" = "200" ] || [ "$VM_HTTPS_CODE" = "302" ]; then
                echo -e "   $PASS HTTPS 状态码: $VM_HTTPS_CODE, 总耗时: ${VM_HTTPS_TOTAL}s, TCP连接: ${VM_HTTPS_CONNECT}s, TLS握手: ${VM_HTTPS_APPCONN}s"
            else
                echo -e "   $FAIL VM 内 HTTPS 失败 (Curl Error 28 复现!): $VM_HTTPS"
            fi
        else
            echo -e "   $FAIL VM 内 HTTPS 完全超时 (>15s) - Curl Error 28 已复现!"
        fi
        
        # VM 内多域名 HTTPS 连通性测试
        echo -e " $INFO VM 内多域名 HTTPS 连通性 (5秒超时):"
        for domain in "www.baidu.com" "www.qq.com" "www.apple.com"; do
            VM_DOM_RESULT=$("$ADB_PATH" shell "curl -sS -o /dev/null -w '%{http_code}:%{time_total}' --connect-timeout 5 --max-time 8 https://$domain" 2>/dev/null)
            if [ -n "$VM_DOM_RESULT" ]; then
                DOM_CODE=$(echo "$VM_DOM_RESULT" | cut -d: -f1)
                DOM_TIME=$(echo "$VM_DOM_RESULT" | cut -d: -f2)
                if [ "$DOM_CODE" != "000" ]; then
                    echo -e "   $PASS https://$domain → ${DOM_CODE} (${DOM_TIME}s)"
                else
                    echo -e "   $FAIL https://$domain → 超时/连接失败"
                fi
            else
                echo -e "   $FAIL https://$domain → 完全超时"
            fi
        done
        
        # VM 内网络类型确认
        echo -e " $INFO VM 内网络接口信息:"
        "$ADB_PATH" shell "ip route show" 2>/dev/null | head -3 | while read -r line; do echo "   $line"; done
        
        # VM 内 NetworkMonitor 验证状态
        echo -e " $INFO VM 内网络验证状态:"
        "$ADB_PATH" shell "dumpsys connectivity" 2>/dev/null | grep -E "NetworkAgentInfo|validated|score|transport" | head -5 | while read -r line; do echo "   $line"; done
        
    else
        echo -e " $FAIL 未检测到已连接的 ADB 设备"
        echo -e " $INFO 请确认模拟器已启动且 ADB 调试已开启"
    fi
else
    echo -e " $FAIL 未找到 adb 工具，跳过 VM 内部测试"
fi
echo ""

# ─────────────────────────────────────────────
# 6. SLiRP 特有问题检测
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [6] SLiRP 虚拟网络栈专项检测"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 检查 QEMU 进程的文件描述符（网络相关）
if [ -n "$QEMU_PID" ]; then
    FD_COUNT=$(lsof -p "$QEMU_PID" 2>/dev/null | wc -l | tr -d ' ')
    echo -e " $INFO QEMU 打开的文件描述符数: $FD_COUNT"
    
    # 检查 QEMU 网络相关 fd
    NET_FDS=$(lsof -p "$QEMU_PID" 2>/dev/null | grep -i "socket\|pcap\|tun\|tap\|bridge" | head -5)
    if [ -n "$NET_FDS" ]; then
        echo -e " $INFO QEMU 网络相关 fd:"
        echo "$NET_FDS" | while read -r line; do echo "   $line"; done
    fi
    
    # 检查 QEMU 是否使用 pcap 模式
    if echo "$QEMU_CMD" | grep -q "pcap"; then
        PCAP_IF=$(echo "$QEMU_CMD" | grep -o 'pcap=[^,]*' | cut -d= -f2)
        echo -e " $INFO pcap 桥接接口: $PCAP_IF"
        if ifconfig "$PCAP_IF" >/dev/null 2>&1; then
            echo -e " $PASS 接口 $PCAP_IF 存在且可用"
        else
            echo -e " $WARN 接口 $PCAP_IF 不可用"
        fi
    fi
fi

# 检查宿主机到 VM 的端口转发
if [ -n "$ADB_PATH" ] && [ -n "$DEVICES" ]; then
    echo -e " $INFO ADB 端口转发规则:"
    "$ADB_PATH" forward --list 2>/dev/null | while read -r line; do echo "   $line"; done
fi

# 检查系统网络扩展/VPN（可能拦截流量）
echo -e " $INFO 检查 VPN/网络扩展:"
VPN_IFS=$(ifconfig 2>/dev/null | grep -E "^(utun|ipsec|ppp)" | awk -F: '{print $1}')
if [ -n "$VPN_IFS" ]; then
    echo -e " $WARN 检测到 VPN 接口: $VPN_IFS (可能影响模拟器网络)"
else
    echo -e " $PASS 未检测到 VPN 接口"
fi

# 检查防火墙状态
PF_STATUS=$(sudo pfctl -s info 2>/dev/null | grep "Status" | head -1)
if [ -n "$PF_STATUS" ]; then
    echo -e " $INFO macOS 防火墙: $PF_STATUS"
else
    # 不用 sudo 的方式检查
    FW_STATUS=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
    echo -e " $INFO macOS 应用防火墙: $FW_STATUS"
fi
echo ""

# ─────────────────────────────────────────────
# 7. 宿主机 vs VM 性能对比汇总
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [7] 诊断结论汇总"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ISSUES=0

# 宿主机 HTTP/HTTPS 正常判断
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    HOST_HTTP_OK=1
else
    HOST_HTTP_OK=0
    ISSUES=$((ISSUES + 1))
fi

if [ "$HTTPS_CODE" = "200" ] || [ "$HTTPS_CODE" = "302" ] || [ "$HTTPS_CODE" = "301" ]; then
    HOST_HTTPS_OK=1
else
    HOST_HTTPS_OK=0
    ISSUES=$((ISSUES + 1))
fi

echo ""
echo " 宿主机网络:"
[ "$HOST_HTTP_OK" = "1" ] && echo -e "   HTTP:  $PASS 正常 (${HTTP_TOTAL}s)" || echo -e "   HTTP:  $FAIL 异常"
[ "$HOST_HTTPS_OK" = "1" ] && echo -e "   HTTPS: $PASS 正常 (${HTTPS_TOTAL}s)" || echo -e "   HTTPS: $FAIL 异常"

if [ -n "$ADB_PATH" ] && [ -n "$DEVICES" ]; then
    echo ""
    echo " VM 内网络:"
    if [ "$VM_HTTP_CODE" = "200" ] || [ "$VM_HTTP_CODE" = "302" ]; then
        echo -e "   HTTP:  $PASS 正常 (${VM_HTTP_TOTAL}s)"
    else
        echo -e "   HTTP:  $FAIL 异常"
        ISSUES=$((ISSUES + 1))
    fi
    if [ "$VM_HTTPS_CODE" = "200" ] || [ "$VM_HTTPS_CODE" = "302" ]; then
        echo -e "   HTTPS: $PASS 正常 (${VM_HTTPS_TOTAL}s)"
    else
        echo -e "   HTTPS: $FAIL 异常 ← Curl Error 28 复现点"
        ISSUES=$((ISSUES + 1))
    fi
fi

echo ""
echo " ──────────────────────────────────────"
if [ "$HOST_HTTPS_OK" = "1" ] && [ "${VM_HTTPS_CODE:-000}" != "200" ] && [ "${VM_HTTPS_CODE:-000}" != "302" ]; then
    echo -e " ${RED}诊断结论：宿主机 HTTPS 正常但 VM 内 HTTPS 失败${NC}"
    echo -e " ${RED}→ 问题在 QEMU 虚拟网络栈 (SLiRP) 的 HTTPS 转发层${NC}"
    echo -e " ${RED}→ 非 Mac 本地网络问题，非 CDN 服务器问题${NC}"
    echo ""
    echo " 可能原因："
    echo "   1. SLiRP 单线程转发，QEMU 主线程负载高时 HTTPS 被阻塞"
    echo "   2. SLiRP 对 TLS 多次握手的数据包转发存在延迟/丢包"
    echo "   3. SLiRP NAT 规则初始化期间（VM启动后90秒内）连接被丢弃"
    echo "   4. SLiRP 对大包/长连接的处理存在超时bug"
    echo ""
    echo " 建议方案："
    echo "   1. 将 QEMU 网络模式从 SLiRP 切换到 pcap/bridge 模式"
    echo "   2. 增加 Unity 的 curl 超时时间（9s → 30s）"
    echo "   3. 检查 QEMU 主线程是否有阻塞点（渲染/IO）"
    echo "   4. 在 VM 启动后等待 90 秒再发起网络请求"
elif [ "$HOST_HTTPS_OK" = "0" ]; then
    echo -e " ${YELLOW}诊断结论：宿主机 HTTPS 也失败，问题可能在本地网络${NC}"
else
    echo -e " ${GREEN}诊断结论：宿主机和 VM 内 HTTPS 均正常，当前未复现问题${NC}"
    echo -e " ${GREEN}建议在问题复现时重新运行此脚本${NC}"
fi

echo ""
echo "============================================================"
echo "  诊断完成，可将以上输出发送给开发团队分析"
echo "============================================================"
