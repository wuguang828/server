#!/bin/bash
# YYB Mac 模拟器 Curl Error 28 网络诊断脚本 v2
# 修复：去掉sudo、VM内用wget替代curl、修复BSD awk兼容性

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS="${GREEN}[PASS]${NC}"; FAIL="${RED}[FAIL]${NC}"; WARN="${YELLOW}[WARN]${NC}"; INFO="${CYAN}[INFO]${NC}"

TARGET_URL_HTTP="http://down-update.qq.com/sgame/PreUpdateCfgs/11030101/3859c6e28cafabc/phoneSpecList.tsv"
TARGET_URL_HTTPS="https://down-update.qq.com/sgame/PreUpdateCfgs/11030101/3859c6e28cafabc/phoneSpecList.tsv"
TARGET_HOST="down-update.qq.com"

# macOS BSD awk 兼容的浮点比较
float_lt() { [ "$(echo "$1 < $2" | bc -l 2>/dev/null)" = "1" ]; }
float_gt() { [ "$(echo "$1 > $2" | bc -l 2>/dev/null)" = "1" ]; }

echo "============================================================"
echo "  YYB Mac 模拟器 Curl Error 28 网络诊断 v2"
echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

# ─────────────────────────────────────────────
# 1. 检查 YYB/QEMU 进程是否运行
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [1] 检查模拟器进程状态"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

QEMU_PID=$(pgrep -f "qemu-system-x86_64" 2>/dev/null | head -1)
if [ -n "$QEMU_PID" ]; then
    echo -e " $PASS QEMU 进程运行中 (PID: $QEMU_PID)"
    QEMU_CMD=$(ps -p "$QEMU_PID" -o command= 2>/dev/null)

    # 检查网络模式
    if echo "$QEMU_CMD" | grep -q "pcap"; then
        echo -e " $INFO 网络模式: pcap 桥接 (性能较好)"
    elif echo "$QEMU_CMD" | grep -q "netdev.*user\|-net.*user"; then
        echo -e " $WARN 网络模式: SLiRP 用户态 NAT (性能较差，已知会导致 HTTPS 超时)"
    else
        NET_OPTS=$(echo "$QEMU_CMD" | grep -oE '\-net[^[:space:]]*|netdev[^[:space:]]*' | head -3)
        echo -e " $INFO 网络模式: 未明确识别 (选项: $NET_OPTS)"
    fi

    # 检查 QEMU 主线程 CPU 使用率
    QEMU_CPU=$(ps -p "$QEMU_PID" -o %cpu= 2>/dev/null | tr -d ' ')
    echo -e " $INFO QEMU 主进程 CPU: ${QEMU_CPU}%"
    if float_gt "${QEMU_CPU:-0}" 80; then
        echo -e " $FAIL QEMU CPU 使用率过高 (${QEMU_CPU}%)，可能导致 SLiRP 网络转发阻塞"
    fi

    # 检查 QEMU 线程数
    QEMU_THREADS=$(ps -M -p "$QEMU_PID" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    echo -e " $INFO QEMU 线程数: $QEMU_THREADS"

    # 检查 QEMU 内存使用
    QEMU_RSS=$(ps -p "$QEMU_PID" -o rss= 2>/dev/null | tr -d ' ')
    if [ -n "$QEMU_RSS" ]; then
        QEMU_RSS_MB=$((QEMU_RSS / 1024))
        echo -e " $INFO QEMU 内存使用: ${QEMU_RSS_MB}MB"
    fi
else
    echo -e " $FAIL 未检测到 QEMU 进程，请先启动模拟器"
    echo -e " $INFO 将跳过部分 VM 相关测试"
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
    echo -e "   $PASS 解析成功: $(echo "$DNS_RESULT" | tr '\n' ', ')"
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
    LOSS_VAL=$(echo "$PING_LOSS" | cut -d% -f1)
    if float_lt "$LOSS_VAL" 5; then
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
HTTP_RESULT=$(curl -sS -o /dev/null -w "http_code:%{http_code} time_total:%{time_total} time_connect:%{time_connect} time_starttransfer:%{time_starttransfer}" --connect-timeout 9 --max-time 15 "$TARGET_URL_HTTP" 2>&1)
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
HTTPS_RESULT=$(curl -sS -o /dev/null -w "http_code:%{http_code} time_total:%{time_total} time_connect:%{time_connect} time_appconnect:%{time_appconnect} time_starttransfer:%{time_starttransfer}" --connect-timeout 9 --max-time 15 "$TARGET_URL_HTTPS" 2>&1)
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
    if float_gt "$TIME_DIFF" 3; then
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

TLS_INFO=$(echo | openssl s_client -connect "$TARGET_HOST:443" -servername "$TARGET_HOST" 2>/dev/null)

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
    echo -e " $INFO 证书验证返回码: $TLS_VERIFY (0=通过)"
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
    ADB_PATH=$(find /Applications -name "adb" -type f 2>/dev/null | head -1)
    if [ -z "$ADB_PATH" ]; then
        ADB_PATH=$(mdfind -name "adb" 2>/dev/null | grep -v "\.app/" | head -1)
    fi
fi

VM_HTTP_OK="unknown"
VM_HTTPS_OK="unknown"
VM_CURL_AVAILABLE=0
VM_WGET_AVAILABLE=0

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
        fi

        # VM 内 DNS 检查（从 getprop 和 ip route 获取）
        echo -e " $INFO VM 内 DNS 配置:"
        VM_DNS1=$("$ADB_PATH" shell getprop net.dns1 2>/dev/null | tr -d '\r')
        VM_DNS2=$("$ADB_PATH" shell getprop net.dns2 2>/dev/null | tr -d '\r')
        VM_DNS_FROM_ROUTE=$("$ADB_PATH" shell "ip route show" 2>/dev/null | grep "default" | awk '{print $3}' | head -1 | tr -d '\r')
        echo "   DNS1 (getprop): ${VM_DNS1:-未设置}"
        echo "   DNS2 (getprop): ${VM_DNS2:-未设置}"
        echo "   默认网关 (ip route): ${VM_DNS_FROM_ROUTE:-未设置}"

        # VM 内 ping 测试 (网关 10.0.2.2)
        echo -e " $INFO VM 内 ping 网关 (10.0.2.2):"
        VM_PING=$("$ADB_PATH" shell "ping -c 3 -W 3 10.0.2.2" 2>/dev/null)
        VM_PING_LOSS=$(echo "$VM_PING" | grep "packet loss" | grep -o '[0-9]*%')
        if [ -n "$VM_PING_LOSS" ]; then
            LOSS_NUM=$(echo "$VM_PING_LOSS" | tr -d '%')
            if [ "$LOSS_NUM" -lt 5 ] 2>/dev/null; then
                echo -e "   $PASS 丢包率: $VM_PING_LOSS"
            else
                echo -e "   $FAIL 丢包率: $VM_PING_LOSS (VM→宿主网关链路异常)"
            fi
        else
            echo -e "   $WARN ping 不可用或超时"
        fi

        # VM 内 DNS 解析（用 getprop 获取 DNS，再用 ping 测试域名解析）
        echo -e " $INFO VM 内 DNS 解析 $TARGET_HOST:"
        VM_NSLOOKUP=$("$ADB_PATH" shell "nslookup $TARGET_HOST 2>/dev/null" 2>/dev/null | grep "Address:" | tail -1 | tr -d '\r')
        if [ -n "$VM_NSLOOKUP" ]; then
            echo -e "   $PASS 解析成功: $VM_NSLOOKUP"
        else
            # nslookup 可能不可用，用 ping -c 0 测试 DNS 解析
            VM_PING_DNS=$("$ADB_PATH" shell "ping -c 1 -W 3 $TARGET_HOST" 2>/dev/null | grep "PING" | head -1 | tr -d '\r')
            if [ -n "$VM_PING_DNS" ]; then
                VM_RESOLVED_IP=$(echo "$VM_PING_DNS" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
                echo -e "   $PASS 解析成功 (通过ping): $VM_RESOLVED_IP"
            else
                echo -e "   $WARN DNS 解析无法验证 (nslookup 和 ping 均不可用)"
            fi
        fi

        # ── 检测 VM 内可用的下载工具 ──
        echo -e " $INFO 检测 VM 内可用的下载工具..."
        VM_CURL_CHECK=$("$ADB_PATH" shell "which curl" 2>/dev/null | tr -d '\r')
        VM_WGET_CHECK=$("$ADB_PATH" shell "which wget" 2>/dev/null | tr -d '\r')

        if [ -n "$VM_CURL_CHECK" ]; then
            echo -e "   $PASS curl: 可用 ($VM_CURL_CHECK)"
            VM_CURL_AVAILABLE=1
        else
            echo -e "   $WARN curl: 不可用 (Android 通常不带 curl)"
        fi

        if [ -n "$VM_WGET_CHECK" ]; then
            echo -e "   $PASS wget: 可用 ($VM_WGET_CHECK)"
            VM_WGET_AVAILABLE=1
        else
            echo -e "   $WARN wget: 不可用"
        fi

        # ── VM 内 HTTP/HTTPS 下载测试 ──
        # 优先使用 curl，其次 wget，最后用 Android am 命令做连通性测试

        if [ "$VM_CURL_AVAILABLE" = "1" ]; then
            # === 用 curl 测试 ===
            echo -e " $INFO VM 内 HTTP 下载测试 (curl, 9秒超时):"
            VM_HTTP=$("$ADB_PATH" shell "curl -sS -o /dev/null -w 'http_code:%{http_code} time_total:%{time_total} time_connect:%{time_connect}' --connect-timeout 9 --max-time 15 $TARGET_URL_HTTP" 2>/dev/null)
            VM_HTTP_CODE=$(echo "$VM_HTTP" | grep -o 'http_code:[0-9]*' | cut -d: -f2)
            VM_HTTP_TOTAL=$(echo "$VM_HTTP" | grep -o 'time_total:[0-9.]*' | cut -d: -f2)
            if [ "$VM_HTTP_CODE" = "200" ] || [ "$VM_HTTP_CODE" = "302" ] || [ "$VM_HTTP_CODE" = "301" ]; then
                echo -e "   $PASS HTTP 状态码: $VM_HTTP_CODE, 耗时: ${VM_HTTP_TOTAL}s"
                VM_HTTP_OK="yes"
            else
                echo -e "   $FAIL VM 内 HTTP 失败: $VM_HTTP"
                VM_HTTP_OK="no"
            fi

            echo -e " $INFO VM 内 HTTPS 下载测试 (curl, 9秒超时) [关键测试]:"
            VM_HTTPS=$("$ADB_PATH" shell "curl -sS -o /dev/null -w 'http_code:%{http_code} time_total:%{time_total} time_connect:%{time_connect} time_appconnect:%{time_appconnect}' --connect-timeout 9 --max-time 15 $TARGET_URL_HTTPS" 2>/dev/null)
            VM_HTTPS_CODE=$(echo "$VM_HTTPS" | grep -o 'http_code:[0-9]*' | cut -d: -f2)
            VM_HTTPS_TOTAL=$(echo "$VM_HTTPS" | grep -o 'time_total:[0-9.]*' | cut -d: -f2)
            VM_HTTPS_CONNECT=$(echo "$VM_HTTPS" | grep -o 'time_connect:[0-9.]*' | cut -d: -f2)
            VM_HTTPS_APPCONN=$(echo "$VM_HTTPS" | grep -o 'time_appconnect:[0-9.]*' | cut -d: -f2)
            if [ "$VM_HTTPS_CODE" = "200" ] || [ "$VM_HTTPS_CODE" = "302" ] || [ "$VM_HTTPS_CODE" = "301" ]; then
                echo -e "   $PASS HTTPS 状态码: $VM_HTTPS_CODE, 总耗时: ${VM_HTTPS_TOTAL}s, TCP连接: ${VM_HTTPS_CONNECT}s, TLS握手: ${VM_HTTPS_APPCONN}s"
                VM_HTTPS_OK="yes"
            else
                echo -e "   $FAIL VM 内 HTTPS 失败 (Curl Error 28 可能复现!): $VM_HTTPS"
                VM_HTTPS_OK="no"
            fi

        elif [ "$VM_WGET_AVAILABLE" = "1" ]; then
            # === 用 wget 测试 ===
            echo -e " $INFO VM 内 HTTP 下载测试 (wget, 9秒超时):"
            VM_HTTP_WGET=$("$ADB_PATH" shell "wget -S --spider --timeout=9 --tries=1 $TARGET_URL_HTTP 2>&1" 2>/dev/null)
            if echo "$VM_HTTP_WGET" | grep -q "HTTP/.* 200\|HTTP/.* 302\|HTTP/.* 301"; then
                VM_HTTP_CODE=$(echo "$VM_HTTP_WGET" | grep "HTTP/" | tail -1 | awk '{print $2}')
                echo -e "   $PASS HTTP 状态码: $VM_HTTP_CODE"
                VM_HTTP_OK="yes"
            else
                echo -e "   $FAIL VM 内 HTTP 失败: $(echo "$VM_HTTP_WGET" | tail -3)"
                VM_HTTP_OK="no"
            fi

            echo -e " $INFO VM 内 HTTPS 下载测试 (wget, 9秒超时) [关键测试]:"
            VM_HTTPS_WGET=$("$ADB_PATH" shell "wget -S --spider --timeout=9 --tries=1 $TARGET_URL_HTTPS 2>&1" 2>/dev/null)
            if echo "$VM_HTTPS_WGET" | grep -q "HTTP/.* 200\|HTTP/.* 302\|HTTP/.* 301"; then
                VM_HTTPS_CODE=$(echo "$VM_HTTPS_WGET" | grep "HTTP/" | tail -1 | awk '{print $2}')
                echo -e "   $PASS HTTPS 状态码: $VM_HTTPS_CODE"
                VM_HTTPS_OK="yes"
            else
                echo -e "   $FAIL VM 内 HTTPS 失败 (可能复现 Error 28!): $(echo "$VM_HTTPS_WGET" | tail -3)"
                VM_HTTPS_OK="no"
            fi
        fi

        # === 如果 curl 和 wget 都不可用，使用 Android 内置工具做连通性测试 ===
        if [ "$VM_CURL_AVAILABLE" = "0" ] && [ "$VM_WGET_AVAILABLE" = "0" ]; then
            echo -e " $WARN VM 内 curl/wget 均不可用，使用 Android 内置工具测试连通性"

            # 方法1: 使用 am start 让浏览器打开 URL（验证 DNS + TCP + TLS 全链路）
            echo -e " $INFO VM 内 HTTP 连通性测试 (ping + TCP connect):"

            # 测试 HTTP 80 端口连通性
            VM_HTTP80=$("$ADB_PATH" shell "echo > /dev/tcp/$TARGET_HOST/80" 2>&1)
            if [ $? -eq 0 ] || [ -z "$VM_HTTP80" ]; then
                echo -e "   $PASS $TARGET_HOST:80 TCP 连接成功"
                VM_HTTP_OK="yes"
            else
                echo -e "   $FAIL $TARGET_HOST:80 TCP 连接失败"
                VM_HTTP_OK="no"
            fi

            # 测试 HTTPS 443 端口连通性
            echo -e " $INFO VM 内 HTTPS 连通性测试 (TCP 443 + TLS) [关键测试]:"
            VM_HTTPS443=$("$ADB_PATH" shell "echo > /dev/tcp/$TARGET_HOST/443" 2>&1)
            if [ $? -eq 0 ] || [ -z "$VM_HTTPS443" ]; then
                echo -e "   $PASS $TARGET_HOST:443 TCP 连接成功 (TLS握手未测)"
                VM_HTTPS_OK="partial"
            else
                echo -e "   $FAIL $TARGET_HOST:443 TCP 连接失败 (HTTPS 完全不可达!)"
                VM_HTTPS_OK="no"
            fi

            # 方法2: 使用 Android 的 ConnectivityService 诊断
            echo -e " $INFO VM 内网络连通性验证 (ConnectivityService):"
            VM_CS=$("$ADB_PATH" shell "dumpsys connectivity" 2>/dev/null)
            VM_VALIDATED=$(echo "$VM_CS" | grep -c "VALIDATED" | head -1)
            VM_NOT_VALIDATED=$(echo "$VM_CS" | grep -c "NOT_VALIDATED" | head -1)
            if [ "$VM_VALIDATED" -gt 0 ] 2>/dev/null; then
                echo -e "   $PASS 网络验证状态: VALIDATED (Android 系统判定网络可用)"
            else
                echo -e "   $FAIL 网络验证状态: NOT_VALIDATED (Android 系统判定网络不可用!)"
                VM_HTTPS_OK="no"
            fi

            # 方法3: 用 toybox nc 测试 TCP 连接+数据传输
            echo -e " $INFO VM 内 TCP 数据传输测试 (toybox nc):"
            VM_NC_CHECK=$("$ADB_PATH" shell "which nc" 2>/dev/null | tr -d '\r')
            if [ -n "$VM_NC_CHECK" ]; then
                # 发送 HTTP HEAD 请求并检查是否有响应
                VM_NC_HTTP=$("$ADB_PATH" shell "echo 'HEAD / HTTP/1.0\r\nHost: $TARGET_HOST\r\n\r\n' | nc -w 5 $TARGET_HOST 80" 2>/dev/null | head -1 | tr -d '\r')
                if echo "$VM_NC_HTTP" | grep -q "HTTP/"; then
                    echo -e "   $PASS HTTP 数据传输正常: $VM_NC_HTTP"
                    VM_HTTP_OK="yes"
                else
                    echo -e "   $FAIL HTTP 数据传输异常 (TCP连接可能成功但无HTTP响应)"
                    VM_HTTP_OK="no"
                fi

                VM_NC_HTTPS=$("$ADB_PATH" shell "echo 'HEAD / HTTP/1.0\r\nHost: $TARGET_HOST\r\n\r\n' | nc -w 5 $TARGET_HOST 443" 2>/dev/null | head -1 | tr -d '\r')
                if echo "$VM_NC_HTTPS" | grep -q "HTTP/"; then
                    echo -e "   $PASS HTTPS 数据传输正常: $VM_NC_HTTPS (TLS 未测试)"
                    VM_HTTPS_OK="partial"
                else
                    echo -e "   $FAIL HTTPS 数据传输异常 (443端口连接后无HTTP响应，TLS握手可能卡住)"
                    VM_HTTPS_OK="no"
                fi
            else
                echo -e "   $WARN nc 不可用，跳过 TCP 数据传输测试"
            fi

            # 方法4: 用 ping 测试外网 (ICMP 层)
            echo -e " $INFO VM 内外网 ping 测试 (ICMP 层):"
            for target in "10.0.2.2" "8.8.8.8"; do
                VM_PING_EXT=$("$ADB_PATH" shell "ping -c 1 -W 3 $target" 2>/dev/null | grep "time=")
                if [ -n "$VM_PING_EXT" ]; then
                    VM_PING_MS=$(echo "$VM_PING_EXT" | grep -o 'time=[0-9.]*' | cut -d= -f2 | tr -d '\r')
                    echo -e "   $PASS ping $target → ${VM_PING_MS}ms"
                else
                    echo -e "   $FAIL ping $target → 超时"
                fi
            done
        fi

        # VM 内多域名 HTTPS 连通性测试（用可用工具）
        echo -e " $INFO VM 内多域名连通性对比 (判断是否仅特定域名异常):"
        for domain in "www.qq.com" "www.baidu.com"; do
            if [ "$VM_CURL_AVAILABLE" = "1" ]; then
                VM_DOM=$("$ADB_PATH" shell "curl -sS -o /dev/null -w '%{http_code}:%{time_total}' --connect-timeout 5 --max-time 8 https://$domain" 2>/dev/null | tr -d '\r')
                DOM_CODE=$(echo "$VM_DOM" | cut -d: -f1)
                DOM_TIME=$(echo "$VM_DOM" | cut -d: -f2)
                if [ "$DOM_CODE" != "000" ] && [ -n "$DOM_CODE" ]; then
                    echo -e "   $PASS https://$domain → ${DOM_CODE} (${DOM_TIME}s)"
                else
                    echo -e "   $FAIL https://$domain → 超时/失败"
                fi
            elif [ "$VM_NC_CHECK" != "" ]; then
                VM_DOM_NC=$("$ADB_PATH" shell "echo > /dev/tcp/$domain/443 && echo OK" 2>/dev/null | tr -d '\r')
                if [ "$VM_DOM_NC" = "OK" ]; then
                    echo -e "   $PASS $domain:443 TCP连接成功"
                else
                    echo -e "   $FAIL $domain:443 TCP连接失败"
                fi
            else
                VM_DOM_PING=$("$ADB_PATH" shell "ping -c 1 -W 3 $domain" 2>/dev/null | grep "time=")
                if [ -n "$VM_DOM_PING" ]; then
                    echo -e "   $PASS $domain → ICMP可达"
                else
                    echo -e "   $FAIL $domain → ICMP不可达"
                fi
            fi
        done

        # VM 内网络接口信息
        echo -e " $INFO VM 内网络接口信息:"
        "$ADB_PATH" shell "ip route show" 2>/dev/null | head -3 | while read -r line; do echo "   $line"; done

        # VM 内网络验证状态
        echo -e " $INFO VM 内网络验证状态:"
        "$ADB_PATH" shell "dumpsys connectivity" 2>/dev/null | grep -E "NetworkAgentInfo|validated" | head -3 | while read -r line; do echo "   $line"; done

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
    FWD_LIST=$("$ADB_PATH" forward --list 2>/dev/null)
    if [ -n "$FWD_LIST" ]; then
        echo "$FWD_LIST" | while read -r line; do echo "   $line"; done
    else
        echo "   (无)"
    fi
fi

# 检查 VPN/网络扩展（仅提示，utun0-3 通常是系统自带的）
echo -e " $INFO 检查 VPN/网络扩展:"
VPN_IFS=$(ifconfig 2>/dev/null | grep -E "^(utun|ipsec|ppp)" | awk -F: '{print $1}' | sort -u)
UTUN_COUNT=$(echo "$VPN_IFS" | grep -c "utun" 2>/dev/null)
# macOS 默认有 utun0-3，超过4个可能是 VPN
if [ "${UTUN_COUNT:-0}" -gt 4 ]; then
    echo -e " $WARN 检测到 ${UTUN_COUNT} 个 utun 接口 (超过系统默认4个)，可能有 VPN 运行: $VPN_IFS"
elif [ -n "$VPN_IFS" ]; then
    echo -e " $PASS utun 接口数量正常 (${UTUN_COUNT}个，macOS 默认0-4个)"
fi
# 检查是否有活跃的 VPN 连接
SCUTIL_VPN=$(scutil --nc list 2>/dev/null | grep "Connected" | head -1)
if [ -n "$SCUTIL_VPN" ]; then
    echo -e " $WARN 检测到活跃的 VPN 连接: $SCUTIL_VPN"
else
    echo -e " $PASS 无活跃 VPN 连接"
fi

# 检查防火墙状态（不使用 sudo）
FW_STATUS=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null)
if [ -n "$FW_STATUS" ]; then
    echo -e " $INFO macOS 应用防火墙: $FW_STATUS"
fi
echo ""

# ─────────────────────────────────────────────
# 7. 诊断结论汇总
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " [7] 诊断结论汇总"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 宿主机 HTTP/HTTPS 正常判断
HOST_HTTP_OK="unknown"
HOST_HTTPS_OK="unknown"
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    HOST_HTTP_OK="yes"
else
    HOST_HTTP_OK="no"
fi
if [ "$HTTPS_CODE" = "200" ] || [ "$HTTPS_CODE" = "302" ] || [ "$HTTPS_CODE" = "301" ]; then
    HOST_HTTPS_OK="yes"
else
    HOST_HTTPS_OK="no"
fi

echo ""
echo " 宿主机网络:"
[ "$HOST_HTTP_OK" = "yes" ] && echo -e "   HTTP:  $PASS 正常 (${HTTP_TOTAL}s)" || echo -e "   HTTP:  $FAIL 异常"
[ "$HOST_HTTPS_OK" = "yes" ] && echo -e "   HTTPS: $PASS 正常 (${HTTPS_TOTAL}s)" || echo -e "   HTTPS: $FAIL 异常"

if [ -n "$ADB_PATH" ] && [ -n "$DEVICES" ]; then
    echo ""
    echo " VM 内网络:"
    if [ "$VM_HTTP_OK" = "yes" ]; then
        echo -e "   HTTP:  $PASS 正常"
    elif [ "$VM_HTTP_OK" = "no" ]; then
        echo -e "   HTTP:  $FAIL 异常"
    else
        echo -e "   HTTP:  $WARN 无法测试 (VM内无curl/wget)"
    fi
    if [ "$VM_HTTPS_OK" = "yes" ]; then
        echo -e "   HTTPS: $PASS 正常"
    elif [ "$VM_HTTPS_OK" = "partial" ]; then
        echo -e "   HTTPS: $WARN TCP连接成功但TLS未测 (VM内无curl/wget)"
    elif [ "$VM_HTTPS_OK" = "no" ]; then
        echo -e "   HTTPS: $FAIL 异常 ← Curl Error 28 可能复现点"
    else
        echo -e "   HTTPS: $WARN 无法测试 (VM内无curl/wget)"
    fi
fi

echo ""
echo " ──────────────────────────────────────"

# 综合判断逻辑
if [ "$HOST_HTTPS_OK" = "yes" ] && [ "$VM_HTTPS_OK" = "no" ]; then
    echo -e " ${RED}★ 诊断结论：宿主机 HTTPS 正常但 VM 内 HTTPS 失败${NC}"
    echo -e " ${RED}→ 问题在 QEMU 虚拟网络栈的 HTTPS 转发层${NC}"
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
elif [ "$HOST_HTTPS_OK" = "yes" ] && [ "$VM_HTTPS_OK" = "yes" ]; then
    echo -e " ${GREEN}★ 诊断结论：宿主机和 VM 内 HTTPS 均正常${NC}"
    echo -e " ${GREEN}→ 当前未复现 Curl Error 28 问题${NC}"
    echo -e " ${GREEN}→ 建议在问题复现时重新运行此脚本${NC}"
elif [ "$HOST_HTTPS_OK" = "no" ]; then
    echo -e " ${YELLOW}★ 诊断结论：宿主机 HTTPS 也失败，问题可能在本地网络${NC}"
    echo -e " ${YELLOW}→ 请先检查 Mac 的网络连接${NC}"
elif [ "$VM_HTTPS_OK" = "partial" ]; then
    echo -e " ${YELLOW}★ 诊断结论：VM 内 HTTPS 仅 TCP 层可达，TLS 握手未验证${NC}"
    echo -e " ${YELLOW}→ VM 内缺少 curl/wget，无法完整测试 HTTPS${NC}"
    echo -e " ${YELLOW}→ 如需完整测试，请先在 VM 内安装 curl (adb shell pm install ...)"
    echo -e " ${YELLOW}→ 或使用 adb push 将 Mac 的 curl 推送到 VM${NC}"
    echo ""
    echo " 替代验证方法："
    echo "   adb shell am start -a android.intent.action.VIEW -d https://down-update.qq.com"
    echo "   (在 VM 内浏览器中打开，观察是否正常加载)"
else
    echo -e " ${CYAN}★ 诊断结论：未能完成完整的 HTTPS 对比测试${NC}"
    echo -e " ${CYAN}→ 请确保模拟器已启动且 ADB 已连接后重试${NC}"
fi

echo ""
echo "============================================================"
echo "  诊断完成，可将以上输出发送给开发团队分析"
echo "============================================================"
