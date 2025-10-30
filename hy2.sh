#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极限优化部署脚本（支持命令行端口参数 + 默认跳过证书验证）
# 适用于超低内存环境（32-64MB），修复-1问题 + 回滚安全参数

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
echo "Hysteria2 优化部署脚本（Shell 版） - 更新到 v${HYSTERIA_VERSION}"
echo "支持命令行端口参数，如：bash hysteria2.sh 443"
echo "提示：手动确保UDP端口开放（sudo ufw allow ${DEFAULT_PORT}/udp）"
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

# ---------- 写配置文件（安全优化版，防-1） ----------
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
  up: "500mbps"  # 平衡带宽，Brutal稳定
  down: "500mbps"
ignoreClientBandwidth: false  # 用Brutal算法

quic:
  initStreamReceiveWindow: 8388608  # 默认8MB，防OOM
  maxStreamReceiveWindow: 8388608   
  initConnReceiveWindow: 20971520    # 默认20MB
  maxConnReceiveWindow: 20971520     
  maxIdleTimeout: "30s"              # 默认超时
  maxIncomingStreams: 1024           # 默认并发
  disablePathMTUDiscovery: false     # 默认MTU

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
    echo "✅ 写入安全优化配置 server.yaml（端口=${SERVER_PORT}, SNI=${SNI}, ALPN=${ALPN}）。"
}

# ---------- 获取服务器 IP（更可靠） ----------
get_server_ip() {
    IP=$(curl -s --max-time 10 https://ifconfig.me || curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（优化版，修复-1问题）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $IP"
    echo "   🔌 端口: $SERVER_PORT (请手动确保UDP开放！)"
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
    echo "  - 检查防火墙: sudo ufw allow ${SERVER_PORT}/udp"
    echo "  - 测试UDP: nc -lvu 0.0.0.0 ${SERVER_PORT} (服务器) / nc -vu ${IP} ${SERVER_PORT} (客户端)"
    echo "  - 调试启动: HYSTERIA_BRUTAL_DEBUG=1 nohup ${BIN_PATH} server -c server.yaml --log-level=debug &"
    echo "  - 如果-1：查内存 free -h，日志中OOM则升级RAM或保持小参数。"
}

# ---------- 主逻辑 ----------
main() {
    download_binary
    ensure_cert
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    echo "🚀 启动 Hysteria2 服务器（后台运行，日志到 ${LOG_FILE}）..."
    HYSTERIA_BRUTAL_DEBUG=1 nohup "$BIN_PATH" server -c server.yaml > "$LOG_FILE" 2>&1 &
    echo "✅ 服务器启动（PID: $!）。检查日志: tail -f ${LOG_FILE}"
    echo "建议：用systemd守护进程长期运行（参考官方文档）。"
}

main "$@"
