#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# 统一代理部署脚本 - 支持 TUIC v5 和 Hysteria2 协议选择
# 支持自定义端口配置和命令行参数

set -euo pipefail
IFS=$'\n\t'

# ==================== 全局配置 ====================
SCRIPT_VERSION="1.0.0"
DEFAULT_PORT=22222
MASQ_DOMAIN="www.bing.com"
LOG_FILE="proxy.log"

# 协议特定配置
HYSTERIA_VERSION="v2.6.5"
HY2_AUTH_PASSWORD="CHANGE_THIS_PASSWORD"
HY2_ALPN="h3"

# 文件名定义
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
HY2_CONFIG="server.yaml"
TUIC_CONFIG="server.toml"
TUIC_LINK="tuic_link.txt"

# 全局变量
SELECTED_PROTOCOL=""
SERVER_PORT=""
TUIC_UUID=""
TUIC_PASSWORD=""

# ==================== 工具函数 ====================

# 打印横幅
print_banner() {
    echo "=============================================================================="
    echo "🚀 统一代理部署脚本 v${SCRIPT_VERSION}"
    echo "✨ 支持协议: TUIC v5 | Hysteria2"
    echo "⚙️ 功能: 协议选择 + 自定义端口 + 一键部署"
    echo "=============================================================================="
}

# 检测系统架构
detect_arch() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    case "$machine" in
        *"arm64"*|*"aarch64"*)
            echo "arm64"
            ;;
        *"x86_64"*|*"amd64"*)
            echo "amd64"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 获取端口配置
get_port_config() {
    # 优先级: 命令行参数 > 环境变量 > 交互输入
    if [[ $# -ge 2 && -n "${2:-}" ]]; then
        SERVER_PORT="$2"
        echo "✅ 使用命令行指定端口: $SERVER_PORT"
        return
    fi
    
    if [[ -n "${SERVER_PORT:-}" ]]; then
        echo "✅ 使用环境变量端口: $SERVER_PORT"
        return
    fi
    
    # 交互式输入
    while true; do
        echo ""
        echo "🔧 端口配置 (1024-65535，默认 $DEFAULT_PORT):"
        read -rp "请输入端口 [回车使用默认]: " port
        
        if [[ -z "$port" ]]; then
            SERVER_PORT="$DEFAULT_PORT"
            break
        fi
        
        if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1024 ]] && [[ "$port" -le 65535 ]]; then
            SERVER_PORT="$port"
            break
        else
            echo "❌ 无效端口: $port，请输入 1024-65535 范围内的数字"
        fi
    done
    
    echo "✅ 端口设置: $SERVER_PORT"
}

# 协议选择菜单
select_protocol() {
    if [[ $# -ge 1 && -n "${1:-}" ]]; then
        case "${1,,}" in
            "tuic"|"1")
                SELECTED_PROTOCOL="TUIC"
                ;;
            "hy2"|"hysteria2"|"hysteria"|"2")
                SELECTED_PROTOCOL="HY2"
                ;;
            *)
                echo "❌ 无效的协议参数: $1"
                echo "💡 支持: tuic|1 或 hy2|hysteria2|2"
                exit 1
                ;;
        esac
        echo "✅ 命令行选择协议: $SELECTED_PROTOCOL"
        return
    fi
    
    # 交互式选择
    echo ""
    echo "📡 请选择要部署的代理协议："
    echo "   1) TUIC v5 (基于 QUIC，高性能)"
    echo "   2) Hysteria2 (优化版，低内存)"
    echo ""
    
    while true; do
        read -rp "请输入选项 [1-2]: " choice
        case "$choice" in
            "1"|"tuic")
                SELECTED_PROTOCOL="TUIC"
                break
                ;;
            "2"|"hy2"|"hysteria2")
                SELECTED_PROTOCOL="HY2"
                break
                ;;
            *)
                echo "❌ 无效选择，请输入 1 或 2"
                ;;
        esac
    done
    
    echo "✅ 已选择协议: $SELECTED_PROTOCOL"
}

# 生成证书
generate_certificates() {
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        echo "🔐 发现现有证书，跳过生成"
        return
    fi
    
    echo "🔐 生成自签 ECDSA-P256 证书 (CN=$MASQ_DOMAIN)..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" \
        -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
    
    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
    echo "✅ 证书生成完成"
}

# 获取公网IP
get_server_ip() {
    local ip
    ip=$(curl -s --connect-timeout 10 --max-time 10 https://ifconfig.me 2>/dev/null || \
         curl -s --connect-timeout 10 --max-time 10 https://api.ipify.org 2>/dev/null || \
         echo "YOUR_SERVER_IP")
    echo "$ip"
}

# ==================== TUIC 部署逻辑 ====================

# 下载 TUIC 服务器
download_tuic() {
    local tuic_bin="./tuic-server"
    
    if [[ -x "$tuic_bin" ]]; then
        echo "✅ TUIC 服务器已存在"
        return
    fi
    
    echo "📥 下载 TUIC 服务器..."
    
    local arch
    arch=$(detect_arch)
    if [[ "$arch" != "amd64" ]]; then
        echo "❌ TUIC 暂不支持架构: $(uname -m)"
        exit 1
    fi
    
    # 获取最新版本
    local latest_tag
    latest_tag=$(curl -s https://api.github.com/repos/Itsusinn/tuic/releases/latest | \
                 grep '"tag_name"' | cut -d '"' -f4)
    
    if [[ -z "$latest_tag" ]]; then
        echo "❌ 无法获取 TUIC 最新版本"
        exit 1
    fi
    
    echo "✅ 最新版本: $latest_tag"
    
    local download_url="https://github.com/Itsusinn/tuic/releases/download/$latest_tag/tuic-server-x86_64-linux"
    
    if curl -L -f --retry 3 --connect-timeout 30 -o "$tuic_bin" "$download_url"; then
        chmod +x "$tuic_bin"
        echo "✅ TUIC 服务器下载完成"
    else
        echo "❌ 下载失败: $download_url"
        exit 1
    fi
}

# 生成 TUIC 配置
generate_tuic_config() {
    # 生成认证信息
    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    
    cat > "$TUIC_CONFIG" <<EOF
log_level = "off"
server = "0.0.0.0:${SERVER_PORT}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
self_sign = false
certificate = "$CERT_FILE"
private_key = "$KEY_FILE"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${SERVER_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = 1500
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "20s"

[quic.congestion_control]
controller = "bbr"
initial_window = 4194304
EOF
    
    echo "✅ TUIC 配置生成完成"
}

# 部署 TUIC
deploy_tuic() {
    echo ""
    echo "🚀 开始部署 TUIC v5..."
    
    download_tuic
    generate_certificates
    generate_tuic_config
    
    local server_ip
    server_ip=$(get_server_ip)
    
    # 生成连接信息
    local tuic_link="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${server_ip}:${SERVER_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${server_ip}"
    
    echo "$tuic_link" > "$TUIC_LINK"
    
    # 打印部署信息
    echo ""
    echo "🎉 TUIC v5 部署成功！"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $server_ip"
    echo "   🔌 端口: $SERVER_PORT (UDP)"
    echo "   🔑 UUID: $TUIC_UUID"
    echo "   🔑 密码: $TUIC_PASSWORD"
    echo "   🎯 SNI: $MASQ_DOMAIN"
    echo ""
    echo "📱 TUIC 链接："
    echo "$tuic_link"
    echo ""
    echo "📄 客户端配置："
    echo "服务器: ${server_ip}:${SERVER_PORT}"
    echo "UUID: $TUIC_UUID"
    echo "密码: $TUIC_PASSWORD"
    echo "ALPN: h3"
    echo "SNI: $MASQ_DOMAIN"
    echo "允许不安全: true"
    echo "=========================================================================="
    
    # 启动服务
    echo "🚀 启动 TUIC 服务器（后台守护）..."
    nohup ./tuic-server -c "$TUIC_CONFIG" > "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "✅ 服务器启动成功 (PID: $pid)"
    echo "📝 日志文件: $LOG_FILE (tail -f $LOG_FILE 查看日志)"
}

# ==================== Hysteria2 部署逻辑 ====================

# 下载 Hysteria2
download_hysteria() {
    local arch
    arch=$(detect_arch)
    
    if [[ -z "$arch" ]]; then
        echo "❌ 无法识别 CPU 架构: $(uname -m)"
        exit 1
    fi
    
    local bin_name="hysteria-linux-${arch}"
    local bin_path="./${bin_name}"
    
    if [[ -f "$bin_path" ]]; then
        echo "✅ Hysteria2 二进制已存在"
        return
    fi
    
    echo "📥 下载 Hysteria2..."
    local download_url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${bin_name}"
    
    if curl -L --retry 3 --connect-timeout 30 -o "$bin_path" "$download_url"; then
        chmod +x "$bin_path"
        echo "✅ Hysteria2 下载完成: $bin_path"
    else
        echo "❌ 下载失败: $download_url"
        exit 1
    fi
}

# 生成 Hysteria2 配置
generate_hy2_config() {
    cat > "$HY2_CONFIG" <<EOF
listen: ":${SERVER_PORT}"

tls:
  cert: "$(pwd)/${CERT_FILE}"
  key: "$(pwd)/${KEY_FILE}"
  alpn:
    - "${HY2_ALPN}"

auth:
  type: "password"
  password: "${HY2_AUTH_PASSWORD}"

bandwidth:
  up: "500mbps"
  down: "500mbps"
ignoreClientBandwidth: false

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608   
  initConnReceiveWindow: 20971520    
  maxConnReceiveWindow: 20971520     
  maxIdleTimeout: "30s"
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false

disable_udp: false
udp_idle_timeout: "60s"

logging:
  level: info
  file: "$(pwd)/${LOG_FILE}"
EOF
    
    echo "✅ Hysteria2 配置生成完成"
}

# 部署 Hysteria2
deploy_hy2() {
    echo ""
    echo "🚀 开始部署 Hysteria2..."
    
    download_hysteria
    generate_certificates
    generate_hy2_config
    
    local server_ip
    server_ip=$(get_server_ip)
    
    local arch
    arch=$(detect_arch)
    local bin_path="./hysteria-linux-${arch}"
    
    # 打印部署信息
    echo ""
    echo "🎉 Hysteria2 部署成功！"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 IP地址: $server_ip"
    echo "   🔌 端口: $SERVER_PORT (UDP)"
    echo "   🔑 密码: $HY2_AUTH_PASSWORD"
    echo "   🎯 SNI: $MASQ_DOMAIN"
    echo "   📝 日志: $LOG_FILE"
    echo ""
    echo "📱 Hysteria2 链接："
    echo "hysteria2://${HY2_AUTH_PASSWORD}@${server_ip}:${SERVER_PORT}?sni=${MASQ_DOMAIN}&alpn=${HY2_ALPN}&insecure=1#HY2-${server_ip}"
    echo ""
    echo "📄 客户端配置："
    echo "server: ${server_ip}:${SERVER_PORT}"
    echo "auth: $HY2_AUTH_PASSWORD"
    echo "tls:"
    echo "  sni: $MASQ_DOMAIN"
    echo "  alpn: [\"$HY2_ALPN\"]"
    echo "  insecure: true"
    echo "socks5:"
    echo "  listen: 127.0.0.1:1080"
    echo "http:"
    echo "  listen: 127.0.0.1:8080"
    echo "=========================================================================="
    echo "⚠️ 排查提示："
    echo "  - 检查防火墙: sudo ufw allow ${SERVER_PORT}/udp"
    echo "  - 测试端口: nc -lvu 0.0.0.0 ${SERVER_PORT}"
    echo "  - 查看日志: tail -f ${LOG_FILE}"
    
    # 启动服务
    echo "🚀 启动 Hysteria2 服务器（后台运行）..."
    HYSTERIA_BRUTAL_DEBUG=1 nohup "$bin_path" server -c "$HY2_CONFIG" > "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "✅ 服务器启动成功 (PID: $pid)"
    echo "📝 日志文件: $LOG_FILE (tail -f $LOG_FILE 查看日志)"
}

# ==================== 主程序 ====================

print_usage() {
    echo "用法: $0 [协议] [端口]"
    echo ""
    echo "协议选项:"
    echo "  tuic, 1        - 部署 TUIC v5"
    echo "  hy2, hysteria2, 2 - 部署 Hysteria2"
    echo ""
    echo "示例:"
    echo "  $0 tuic 8443     - 部署 TUIC 到端口 8443"
    echo "  $0 hy2 22222     - 部署 Hysteria2 到端口 22222"
    echo "  $0               - 交互式选择"
    echo ""
}

main() {
    print_banner
    
    # 处理帮助参数
    if [[ $# -ge 1 ]] && [[ "${1}" == "-h" || "${1}" == "--help" ]]; then
        print_usage
        exit 0
    fi
    
    # 协议选择
    select_protocol "$@"
    
    # 端口配置
    get_port_config "$@"
    
    # 根据选择的协议进行部署
    case "$SELECTED_PROTOCOL" in
        "TUIC")
            deploy_tuic
            ;;
        "HY2")
            deploy_hy2
            ;;
        *)
            echo "❌ 未知协议: $SELECTED_PROTOCOL"
            exit 1
            ;;
    esac
    
    echo ""
    echo "🎊 部署完成！请确保服务器防火墙已开放 UDP 端口 $SERVER_PORT"
    echo "💡 建议使用 systemd 或其他进程管理器来长期运行服务"
}

# 脚本入口点
main "$@"
