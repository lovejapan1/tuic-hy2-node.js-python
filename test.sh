#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# 统一代理部署脚本 - 支持 Hysteria2 和 TUIC v5
# 支持协议选择、自定义端口、命令行参数
# Author: Factory AI Droid
# Date: 2025-10-30

set -e

# ================== 全局配置 ==================
SCRIPT_VERSION="1.0.0"
CERT_FILE=""
KEY_FILE=""
CONFIG_FILE=""
LOG_FILE=""
SERVER_PORT=""
PROTOCOL=""
SERVER_IP=""

# ================== 颜色定义 ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ================== 工具函数 ==================
print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║          统一代理部署脚本 v${SCRIPT_VERSION}                      ║"
    echo "║          支持 Hysteria2 & TUIC v5                                ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_debug() { echo -e "${PURPLE}[DEBUG]${NC} $1"; }

# 检测系统架构
detect_arch() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    elif [[ "$machine" == *"armv7"* ]]; then
        echo "armv7"
    else
        echo ""
    fi
}

# 获取公网IP
get_server_ip() {
    local ip
    ip=$(curl -s --connect-timeout 5 https://ifconfig.me || \
         curl -s --connect-timeout 5 https://api.ipify.org || \
         curl -s --connect-timeout 5 https://checkip.amazonaws.com || \
         echo "YOUR_SERVER_IP")
    echo "$ip"
}

# 生成随机密码
generate_password() {
    openssl rand -hex 16
}

# 生成UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16
}

# 生成自签名证书
generate_certificate() {
    local cert="$1"
    local key="$2"
    local domain="$3"
    
    if [[ -f "$cert" && -f "$key" ]]; then
        print_info "证书已存在，跳过生成"
        return
    fi
    
    print_info "生成自签名证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$key" -out "$cert" -subj "/CN=${domain}" >/dev/null 2>&1
    chmod 644 "$cert"
    chmod 600 "$key"
    print_info "证书生成完成"
}

# ================== Hysteria2 相关函数 ==================
hysteria2_defaults() {
    HYSTERIA_VERSION="v2.6.5"
    DEFAULT_PORT=22222
    AUTH_PASSWORD=$(generate_password)
    CERT_FILE="hy2-cert.pem"
    KEY_FILE="hy2-key.pem"
    CONFIG_FILE="hy2-server.yaml"
    LOG_FILE="hysteria2.log"
    SNI="www.bing.com"
    ALPN="h3"
}

download_hysteria2() {
    local arch=$(detect_arch)
    if [[ -z "$arch" ]]; then
        print_error "不支持的系统架构: $(uname -m)"
        exit 1
    fi
    
    local bin_name="hysteria-linux-${arch}"
    local bin_path="./hysteria2-server"
    
    if [[ -f "$bin_path" ]]; then
        print_info "Hysteria2 二进制文件已存在"
        return
    fi
    
    local url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${bin_name}"
    print_info "下载 Hysteria2 ${HYSTERIA_VERSION}..."
    curl -L --retry 3 --connect-timeout 30 -o "$bin_path" "$url"
    chmod +x "$bin_path"
    print_info "Hysteria2 下载完成"
}

generate_hysteria2_config() {
    cat > "$CONFIG_FILE" <<EOF
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

masquerade:
  type: proxy
  proxy:
    url: "https://${SNI}"
    rewrite_host: true

logging:
  level: info
  file: "$(pwd)/${LOG_FILE}"
EOF
    print_info "Hysteria2 配置文件已生成"
}

deploy_hysteria2() {
    print_info "开始部署 Hysteria2..."
    hysteria2_defaults
    
    # 设置端口
    if [[ -n "$1" ]]; then
        SERVER_PORT="$1"
    else
        SERVER_PORT="${DEFAULT_PORT}"
    fi
    
    download_hysteria2
    generate_certificate "$CERT_FILE" "$KEY_FILE" "$SNI"
    generate_hysteria2_config
    
    SERVER_IP=$(get_server_ip)
    
    # 打印连接信息
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🎉 Hysteria2 部署成功！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}📋 服务器信息:${NC}"
    echo -e "   🌐 IP地址: ${BLUE}$SERVER_IP${NC}"
    echo -e "   🔌 端口: ${BLUE}$SERVER_PORT${NC} (UDP)"
    echo -e "   🔑 密码: ${BLUE}$AUTH_PASSWORD${NC}"
    echo -e "   📝 日志文件: ${BLUE}${LOG_FILE}${NC}"
    echo ""
    echo -e "${YELLOW}📱 客户端链接:${NC}"
    echo -e "${CYAN}hysteria2://${AUTH_PASSWORD}@${SERVER_IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-${SERVER_IP}${NC}"
    echo ""
    echo -e "${YELLOW}📄 客户端配置:${NC}"
    cat <<EOF
server: ${SERVER_IP}:${SERVER_PORT}
auth: ${AUTH_PASSWORD}
tls:
  sni: ${SNI}
  alpn: ["${ALPN}"]
  insecure: true
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
EOF
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # 启动服务
    print_info "启动 Hysteria2 服务..."
    nohup ./hysteria2-server server -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
    local pid=$!
    print_info "Hysteria2 已启动 (PID: $pid)"
    
    # 保存配置信息
    save_deployment_info "hysteria2" "$SERVER_IP" "$SERVER_PORT" "$AUTH_PASSWORD"
}

# ================== TUIC v5 相关函数 ==================
tuic_defaults() {
    DEFAULT_PORT=33333
    TUIC_UUID=$(generate_uuid)
    TUIC_PASSWORD=$(generate_password)
    CERT_FILE="tuic-cert.pem"
    KEY_FILE="tuic-key.pem"
    CONFIG_FILE="tuic-server.toml"
    LOG_FILE="tuic.log"
    MASQ_DOMAIN="www.bing.com"
}

download_tuic() {
    local arch=$(detect_arch)
    if [[ "$arch" != "amd64" ]]; then
        print_error "TUIC 暂时只支持 x86_64 架构"
        exit 1
    fi
    
    local bin_path="./tuic-server"
    
    if [[ -f "$bin_path" ]]; then
        print_info "TUIC 二进制文件已存在"
        return
    fi
    
    print_info "获取 TUIC 最新版本..."
    local latest_tag=$(curl -s https://api.github.com/repos/Itsusinn/tuic/releases/latest | grep '"tag_name"' | cut -d '"' -f4)
    if [[ -z "$latest_tag" ]]; then
        print_error "无法获取 TUIC 最新版本"
        exit 1
    fi
    
    print_info "下载 TUIC ${latest_tag}..."
    local url="https://github.com/Itsusinn/tuic/releases/download/$latest_tag/tuic-server-x86_64-linux"
    curl -L -f -o "$bin_path" "$url"
    chmod +x "$bin_path"
    print_info "TUIC 下载完成"
}

generate_tuic_config() {
    cat > "$CONFIG_FILE" <<EOF
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
certificate = "${CERT_FILE}"
private_key = "${KEY_FILE}"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:$((SERVER_PORT + 1000))"
secret = "$(generate_password)"
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
    print_info "TUIC 配置文件已生成"
}

deploy_tuic() {
    print_info "开始部署 TUIC v5..."
    tuic_defaults
    
    # 设置端口
    if [[ -n "$1" ]]; then
        SERVER_PORT="$1"
    else
        SERVER_PORT="${DEFAULT_PORT}"
    fi
    
    download_tuic
    generate_certificate "$CERT_FILE" "$KEY_FILE" "$MASQ_DOMAIN"
    generate_tuic_config
    
    SERVER_IP=$(get_server_ip)
    
    # 打印连接信息
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}🎉 TUIC v5 部署成功！${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}📋 服务器信息:${NC}"
    echo -e "   🌐 IP地址: ${BLUE}$SERVER_IP${NC}"
    echo -e "   🔌 端口: ${BLUE}$SERVER_PORT${NC} (QUIC)"
    echo -e "   🔑 UUID: ${BLUE}$TUIC_UUID${NC}"
    echo -e "   🔑 密码: ${BLUE}$TUIC_PASSWORD${NC}"
    echo -e "   📝 日志文件: ${BLUE}${LOG_FILE}${NC}"
    echo ""
    echo -e "${YELLOW}📱 客户端链接:${NC}"
    echo -e "${CYAN}tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${SERVER_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native#TUIC-${SERVER_IP}${NC}"
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # 启动服务
    print_info "启动 TUIC 服务..."
    nohup ./tuic-server -c "$CONFIG_FILE" > "$LOG_FILE" 2>&1 &
    local pid=$!
    print_info "TUIC 已启动 (PID: $pid)"
    
    # 保存配置信息
    save_deployment_info "tuic" "$SERVER_IP" "$SERVER_PORT" "$TUIC_UUID:$TUIC_PASSWORD"
}

# ================== 配置管理 ==================
save_deployment_info() {
    local protocol="$1"
    local ip="$2"
    local port="$3"
    local auth="$4"
    
    local info_file="deployment_info.txt"
    {
        echo "========================================="
        echo "Protocol: $protocol"
        echo "Date: $(date)"
        echo "IP: $ip"
        echo "Port: $port"
        echo "Auth: $auth"
        echo "========================================="
    } >> "$info_file"
}

# ================== 交互菜单 ==================
show_menu() {
    echo ""
    echo -e "${CYAN}请选择要部署的协议:${NC}"
    echo ""
    echo -e "  ${YELLOW}1)${NC} Hysteria2 (UDP, 高性能)"
    echo -e "  ${YELLOW}2)${NC} TUIC v5 (QUIC, 低延迟)"
    echo -e "  ${YELLOW}3)${NC} 查看部署历史"
    echo -e "  ${YELLOW}4)${NC} 退出"
    echo ""
}

get_port_input() {
    local default_port="$1"
    local port
    
    echo ""
    echo -e "${CYAN}请输入端口号 (默认: ${default_port}):${NC}"
    read -r -p "> " port
    
    if [[ -z "$port" ]]; then
        port="$default_port"
    fi
    
    # 验证端口
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        print_error "无效的端口号: $port"
        exit 1
    fi
    
    echo "$port"
}

# ================== 管理功能 ==================
show_deployment_history() {
    if [[ -f "deployment_info.txt" ]]; then
        echo -e "${CYAN}部署历史记录:${NC}"
        cat deployment_info.txt
    else
        print_warning "没有找到部署历史记录"
    fi
}

check_running_services() {
    echo -e "${CYAN}检查运行中的服务:${NC}"
    echo ""
    
    # 检查 Hysteria2
    if pgrep -f "hysteria2-server" > /dev/null; then
        echo -e "${GREEN}✓ Hysteria2 正在运行${NC}"
        pgrep -f "hysteria2-server" | while read pid; do
            echo "  PID: $pid"
        done
    else
        echo -e "${RED}✗ Hysteria2 未运行${NC}"
    fi
    
    # 检查 TUIC
    if pgrep -f "tuic-server" > /dev/null; then
        echo -e "${GREEN}✓ TUIC 正在运行${NC}"
        pgrep -f "tuic-server" | while read pid; do
            echo "  PID: $pid"
        done
    else
        echo -e "${RED}✗ TUIC 未运行${NC}"
    fi
}

stop_services() {
    print_info "停止所有服务..."
    pkill -f "hysteria2-server" 2>/dev/null || true
    pkill -f "tuic-server" 2>/dev/null || true
    print_info "服务已停止"
}

# ================== 命令行参数处理 ==================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --hysteria2|-h)
                PROTOCOL="hysteria2"
                shift
                if [[ -n "$1" ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
                    SERVER_PORT="$1"
                    shift
                fi
                ;;
            --tuic|-t)
                PROTOCOL="tuic"
                shift
                if [[ -n "$1" ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
                    SERVER_PORT="$1"
                    shift
                fi
                ;;
            --port|-p)
                shift
                if [[ -n "$1" ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
                    SERVER_PORT="$1"
                    shift
                else
                    print_error "端口参数无效"
                    exit 1
                fi
                ;;
            --status|-s)
                check_running_services
                exit 0
                ;;
            --stop)
                stop_services
                exit 0
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    echo "使用方法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --hysteria2, -h [端口]  部署 Hysteria2 (可选端口)"
    echo "  --tuic, -t [端口]       部署 TUIC v5 (可选端口)"
    echo "  --port, -p <端口>       指定端口号"
    echo "  --status, -s            查看服务状态"
    echo "  --stop                  停止所有服务"
    echo "  --help                  显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                      # 交互式菜单"
    echo "  $0 --hysteria2 443      # 部署 Hysteria2，端口 443"
    echo "  $0 --tuic --port 8443   # 部署 TUIC，端口 8443"
}

# ================== 主函数 ==================
main() {
    print_banner
    
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        print_warning "建议使用 root 权限运行此脚本"
        echo -e "${YELLOW}某些操作可能需要 sudo 权限${NC}"
    fi
    
    # 解析命令行参数
    if [[ $# -gt 0 ]]; then
        parse_arguments "$@"
        
        # 如果通过命令行指定了协议，直接部署
        if [[ -n "$PROTOCOL" ]]; then
            case "$PROTOCOL" in
                hysteria2)
                    deploy_hysteria2 "$SERVER_PORT"
                    ;;
                tuic)
                    deploy_tuic "$SERVER_PORT"
                    ;;
            esac
            exit 0
        fi
    fi
    
    # 交互式菜单
    while true; do
        show_menu
        read -r -p "请选择 [1-4]: " choice
        
        case $choice in
            1)
                port=$(get_port_input "22222")
                deploy_hysteria2 "$port"
                break
                ;;
            2)
                port=$(get_port_input "33333")
                deploy_tuic "$port"
                break
                ;;
            3)
                show_deployment_history
                check_running_services
                ;;
            4)
                print_info "退出"
                exit 0
                ;;
            *)
                print_error "无效的选择"
                ;;
        esac
    done
}

# ================== 脚本入口 ==================
main "$@"
