#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极限优化部署脚本（支持命令行端口参数 + 默认跳过证书验证）
# 适用于超低内存环境（32-64MB），极限提升网速 + 系统调优 + 防火墙自动提示

set -e

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.6.5"  # 最新版，修复内存泄漏
DEFAULT_PORT=22222         # 若未提供参数则使用此端口
AUTH_PASSWORD="Tokyo00"   # 建议修改为复杂密码
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
SNI="www.bing.com"
ALPN="h3"
LOG_FILE="hysteria.log"
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 极限优化部署脚本（Shell 版） - 更新到 v${HYSTERIA_VERSION}"
echo "支持命令行端口参数，如：bash hysteria2.sh 443"
echo "提示：运行前确保UDP端口开放（脚本将尝试自动开启）"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 获取端口 ----------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 检测架构 ----------
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

ARCH=$(arch_name)
if [ -z "$ARCH" ]; then
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 下载二进制 ----------
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载: $URL"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行: $BIN_PATH"
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现证书，使用现有 cert/key。"
        return
    fi
    echo "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    chmod 644 "$CERT_FILE" "$KEY_FILE"  # 确保权限
    echo "✅ 证书生成成功。"
}

# ---------- 系统调优（极限提升网速） ----------
system_tune() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "⚠️ 非Root权限，跳过系统调优。请手动运行 sysctl 命令或用Root权限重跑脚本。"
        return
    fi
    echo "⚙️ 系统调优：增大UDP缓冲，提升QUIC性能（需root权限）..."
    sysctl -w net.core.rmem_max=67108864  # 64MB接收缓冲
    sysctl -w net.core.wmem_max=67108864  # 64MB发送缓冲
    sysctl -w net.ipv4.tcp_congestion_control=bbr  # 启用BBR作为后备
    echo "✅ 系统调优完成（临时，重启失效；永久编辑 /etc/sysctl.conf）。"
}

# ---------- 尝试开防火墙端口 ----------
open_firewall() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "⚠️ 非Root权限，跳过防火墙设置。请手动开启UDP端口 ${SERVER_PORT}。"
        return
    fi
    echo "🔥 尝试开启UDP端口 ${SERVER_PORT}..."
    if command -v ufw >/dev/null; then
        ufw allow ${SERVER_PORT}/udp && ufw reload
        echo "✅ UFW 已开启UDP端口。"
    elif command -v firewall-cmd >/dev/null; then
        firewall-cmd --add-port=${SERVER_PORT}/udp --permanent && firewall-cmd --reload
        echo "✅ Firewalld 已开启UDP端口。"
    elif command -v iptables >/dev/null; then
        iptables -A INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
        echo "✅ iptables 已开启UDP端口（持久化需保存）。"
    else
        echo "⚠️ 未检测到防火墙工具，手动开启UDP端口！"
    fi
}

# ---------- 写配置文件（极限优化版，提升网速） ----------
write_config() {
cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"

tls:
  cert: "$(pwd)/${CERT_FILE}"
  key: "$(pwd)/${KEY_FILE}"
  alpn:
    - "${ALPN}"

auth:
  type: "password"
  password: "${AUTH_PASSWORD}"

bandwidth:
  up: "1gbps"  # 极限高带宽，Brutal补偿丢包提升速度
  down: "1gbps"
ignoreClientBandwidth: false  # 用Brutal算法，激进优化

quic:
  initStreamReceiveWindow: 33554432  # 32MB初始流窗口，高BDP提升吞吐
  maxStreamReceiveWindow: 33554432   # 32MB最大流窗口
  initConnReceiveWindow: 83886080    # 80MB初始连接窗口
  maxConnReceiveWindow: 83886080     # 80MB最大连接窗口
  maxIdleTimeout: "60s"              # 长超时防断连
  maxIncomingStreams: 2048           # 高并发支持多任务
  disablePathMTUDiscovery: true      # 禁用MTU发现，防丢包

disable_udp: false  # 启用UDP转发
udp_idle_timeout: "60s"

# masquerade:  # 临时注释测试（若需伪装，取消注释）
#   type: proxy
#   proxy:
#     url: "https://${SNI}"
#     rewrite_host: true

logging:  # 添加日志
  level: info
  file: "$(pwd)/${LOG_FILE}"
EOF
    echo "✅ 写入极限优化配置 server.yaml（端口=${SERVER_PORT}, SNI=${SNI}, ALPN=${ALPN}）。警告：监控内存使用！"
}

# ---------- 获取服务器 IP（更可靠） ----------
get_server_ip() {
    IP=$(curl -s --max-time 10 https://ifconfig.me || curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（极限优化版，提升网速）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $IP"
    echo "   🔌 端口: $SERVER_PORT (UDP已尝试开启！)"
    echo "   🔑 密码: $AUTH_PASSWORD"
    echo "   📝 日志: ${LOG_FILE} (tail -f ${LOG_FILE} 查问题)"
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Bing"
    echo ""
    echo "📄 客户端配置文件（添加insecure: true）:"
    echo "server: ${IP}:${SERVER_PORT}"
    echo "auth: ${AUTH_PASSWORD}"
    echo "tls:"
    echo "  sni: ${SNI}"
    echo "  alpn: [\"${ALPN}\"]"
    echo "  insecure: true"
    echo "socks5:"
    echo "  listen: 127.0.0.1:1080"
    echo "http:"
    echo "  listen: 127.0.0.1:8080"
    echo "=========================================================================="
    echo "⚠️ 排查提示："
    echo "  - 检查防火墙: ufw status 或 iptables -L"
    echo "  - 测试UDP: nc -lvu 0.0.0.0 ${SERVER_PORT} (服务器) / nc -vu ${IP} ${SERVER_PORT} (客户端)"
    echo "  - 调试启动: HYSTERIA_BRUTAL_DEBUG=1 chrt -r 99 nohup ${BIN_PATH} server -c server.yaml --log-level=debug &"
    echo "  - 如果无网：临时移除masquerade，检查服务器DNS/路由。"
    echo "  - 内存监控: free -h (若OOM，回滚小QUIC窗口)。"
}

# ---------- 主逻辑 ----------
main() {
    download_binary
    ensure_cert
    system_tune
    open_firewall
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    echo "🚀 启动 Hysteria2 服务器（后台运行，日志到 ${LOG_FILE}，优先级提升）..."
    HYSTERIA_BRUTAL_DEBUG=1 chrt -r 99 nohup "$BIN_PATH" server -c server.yaml > "$LOG_FILE" 2>&1 &
    echo "✅ 服务器启动（PID: $!）。检查日志: tail -f ${LOG_FILE}"
    echo "建议：用systemd守护进程长期运行（参考官方文档）。"
}

main "$@"
