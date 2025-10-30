#!/usr/bin/env bash
# -*- coding: utf-8 -*-
#===============================================================================
# 代理协议一键部署脚本
# 支持协议: Hysteria2, TUIC
# 特性: 交互式选择、自定义端口、自动证书生成
#===============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量
PROTOCOL=""
SERVER_PORT=""
WORK_DIR="$(pwd)"

#===============================================================================
# 工具函数
#===============================================================================

print_banner() {
    echo -e "${CYAN}"
    cat << "EOF"
╔══════════════════════════════════════════════════════════════════╗
║                 代理协议一键部署工具 v1.0                        ║
║                                                                  ║
║  支持协议: Hysteria2 (HY2) | TUIC v5                            ║
║  作者: Factory AI                                                ║
╚══════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

#===============================================================================
# 协议选择
#===============================================================================

select_protocol() {
    echo -e "\n${CYAN}请选择要部署的协议:${NC}"
    echo "  1) Hysteria2 (HY2) - 基于 QUIC 的高性能代理协议"
    echo "  2) TUIC v5 - QUIC 代理协议，支持 BBR 拥塞控制"
    echo "  3) 退出"
    echo ""
    
    while true; do
        read -rp "请输入选项 [1-3]: " choice
        case $choice in
            1)
                PROTOCOL="hysteria2"
                log_success "已选择: Hysteria2"
                break
                ;;
            2)
                PROTOCOL="tuic"
                log_success "已选择: TUIC v5"
                break
                ;;
            3)
                log_info "退出部署"
                exit 0
                ;;
            *)
                log_error "无效选项，请重新选择"
                ;;
        esac
    done
}

#===============================================================================
# 端口配置
#===============================================================================

configure_port() {
    echo -e "\n${CYAN}端口配置:${NC}"
    
    # 检查是否有命令行参数
    if [[ $# -ge 1 && -n "${1:-}" ]]; then
        SERVER_PORT="$1"
        log_success "使用命令行参数端口: $SERVER_PORT"
        return
    fi
    
    # 检查环境变量
    if [[ -n "${SERVER_PORT:-}" ]]; then
        log_success "检测到环境变量 SERVER_PORT: $SERVER_PORT"
        return
    fi
    
    # 交互式输入
    while true; do
        read -rp "请输入监听端口 (1024-65535，推荐 22222 或 8443): " port
        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
            log_error "无效端口: $port (必须是数字)"
            continue
        fi
        if [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
            log_error "无效端口: $port (必须在 1-65535 范围内)"
            continue
        fi
        if [[ "$port" -lt 1024 ]]; then
            log_warn "端口 $port < 1024 需要 root 权限，建议使用 1024 以上端口"
            read -rp "是否继续使用端口 $port？[y/N]: " confirm
            if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi
        SERVER_PORT="$port"
        log_success "端口设置为: $SERVER_PORT"
        break
    done
}

#===============================================================================
# 架构检测
#===============================================================================

detect_arch() {
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

#===============================================================================
# 获取公网 IP
#===============================================================================

get_public_ip() {
    local ip
    ip=$(curl -s --connect-timeout 5 https://api.ipify.org || \
         curl -s --connect-timeout 5 https://ifconfig.me || \
         curl -s --connect-timeout 5 https://icanhazip.com || \
         echo "YOUR_SERVER_IP")
    echo "$ip"
}

#===============================================================================
# 证书生成
#===============================================================================

generate_cert() {
    local cert_file="$1"
    local key_file="$2"
    local sni="$3"
    
    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        log_info "检测到已有证书，跳过生成"
        return
    fi
    
    log_info "生成自签 ECDSA 证书 (P-256)..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_file" -out "$cert_file" \
        -subj "/CN=${sni}" -days 3650 -nodes >/dev/null 2>&1
    
    chmod 600 "$key_file"
    chmod 644 "$cert_file"
    log_success "证书生成完成"
}

#===============================================================================
# Hysteria2 部署
#===============================================================================

deploy_hysteria2() {
    log_info "开始部署 Hysteria2..."
    
    # 配置参数
    local HYSTERIA_VERSION="v2.6.5"
    local AUTH_PASSWORD="$(openssl rand -hex 16)"
    local CERT_FILE="hy2-cert.pem"
    local KEY_FILE="hy2-key.pem"
    local SNI="www.bing.com"
    local ALPN="h3"
    local LOG_FILE="hysteria2.log"
    
    # 检测架构
    local ARCH=$(detect_arch)
    if [[ -z "$ARCH" ]]; then
        log_error "无法识别 CPU 架构: $(uname -m)"
        exit 1
    fi
    
    local BIN_NAME="hysteria-linux-${ARCH}"
    local BIN_PATH="./${BIN_NAME}"
    
    # 下载二进制
    if [[ ! -f "$BIN_PATH" ]]; then
        log_info "下载 Hysteria2 二进制文件..."
        local URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
        curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
        chmod +x "$BIN_PATH"
        log_success "下载完成"
    else
        log_info "二进制文件已存在，跳过下载"
    fi
    
    # 生成证书
    generate_cert "$CERT_FILE" "$KEY_FILE" "$SNI"
    
    # 生成配置文件
    log_info "生成配置文件..."
    cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"

tls:
  cert: "${WORK_DIR}/${CERT_FILE}"
  key: "${WORK_DIR}/${KEY_FILE}"
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

logging:
  level: info
  file: "${WORK_DIR}/${LOG_FILE}"
EOF
    
    log_success "配置文件生成完成"
    
    # 获取公网 IP
    local SERVER_IP=$(get_public_ip)
    
    # 打印连接信息
    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Hysteria2 部署成功！                                ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${CYAN}📋 服务器信息:${NC}"
    echo -e "   🌐 IP地址: ${YELLOW}${SERVER_IP}${NC}"
    echo -e "   🔌 端口: ${YELLOW}${SERVER_PORT}${NC} (UDP)"
    echo -e "   🔑 密码: ${YELLOW}${AUTH_PASSWORD}${NC}"
    echo -e "   📝 日志: ${YELLOW}${LOG_FILE}${NC}"
    
    echo -e "\n${CYAN}📱 节点链接:${NC}"
    local HY2_LINK="hysteria2://${AUTH_PASSWORD}@${SERVER_IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#HY2-${SERVER_IP}"
    echo -e "${GREEN}${HY2_LINK}${NC}"
    echo "$HY2_LINK" > hysteria2_link.txt
    
    echo -e "\n${CYAN}📄 客户端配置:${NC}"
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
    
    echo -e "\n${CYAN}⚠️  重要提示:${NC}"
    echo -e "   • 确保防火墙开放 UDP 端口:"
    echo -e "     ${YELLOW}sudo ufw allow ${SERVER_PORT}/udp${NC} (Ubuntu/Debian)"
    echo -e "     ${YELLOW}sudo firewall-cmd --add-port=${SERVER_PORT}/udp --permanent && sudo firewall-cmd --reload${NC} (CentOS/RHEL)"
    echo -e "   • 查看日志: ${YELLOW}tail -f ${LOG_FILE}${NC}"
    echo -e "   • 连接信息已保存到: ${YELLOW}hysteria2_link.txt${NC}"
    if [[ $SERVER_PORT -lt 1024 ]]; then
        echo -e "   • ${RED}注意: 端口 $SERVER_PORT < 1024 可能需要 root 权限运行${NC}"
    fi
    
    # 启动服务
    echo -e "\n${CYAN}🚀 启动 Hysteria2 服务器...${NC}"
    nohup "$BIN_PATH" server -c server.yaml > "$LOG_FILE" 2>&1 &
    local PID=$!
    log_success "服务已启动 (PID: $PID)"
    
    echo -e "\n${YELLOW}建议: 使用 systemd 配置开机自启动（参考 README.md）${NC}\n"
}

#===============================================================================
# TUIC 部署
#===============================================================================

deploy_tuic() {
    log_info "开始部署 TUIC v5..."
    
    # 配置参数
    local TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)"
    local TUIC_PASSWORD="$(openssl rand -hex 16)"
    local CERT_FILE="tuic-cert.pem"
    local KEY_FILE="tuic-key.pem"
    local SNI="www.bing.com"
    local CONFIG_FILE="tuic-server.toml"
    local TUIC_BIN="./tuic-server"
    local LINK_FILE="tuic_link.txt"
    
    # 检测架构
    local ARCH=$(uname -m)
    if [[ "$ARCH" != "x86_64" ]]; then
        log_error "TUIC 目前仅支持 x86_64 架构，当前架构: $ARCH"
        exit 1
    fi
    
    # 下载 TUIC 服务器
    if [[ ! -x "$TUIC_BIN" ]]; then
        log_info "下载 TUIC 服务器..."
        local LATEST_TAG=$(curl -s https://api.github.com/repos/Itsusinn/tuic/releases/latest | grep '"tag_name"' | cut -d '"' -f4)
        
        if [[ -z "$LATEST_TAG" ]]; then
            log_error "无法获取 TUIC 最新版本"
            exit 1
        fi
        
        log_info "最新版本: $LATEST_TAG"
        local TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/$LATEST_TAG/tuic-server-x86_64-linux"
        
        curl -L -f -o "$TUIC_BIN" "$TUIC_URL"
        chmod +x "$TUIC_BIN"
        log_success "下载完成"
    else
        log_info "TUIC 服务器已存在，跳过下载"
    fi
    
    # 生成证书
    generate_cert "$CERT_FILE" "$KEY_FILE" "$SNI"
    
    # 生成配置文件
    log_info "生成配置文件..."
    cat > "$CONFIG_FILE" <<EOF
log_level = "info"
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
addr = "127.0.0.1:$(($SERVER_PORT + 1))"
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
    
    log_success "配置文件生成完成"
    
    # 获取公网 IP
    local SERVER_IP=$(get_public_ip)
    
    # 生成连接链接
    local TUIC_LINK="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${SERVER_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${SNI}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${SERVER_IP}"
    echo "$TUIC_LINK" > "$LINK_FILE"
    
    # 打印连接信息
    echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              TUIC v5 部署成功！                                  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${CYAN}📋 服务器信息:${NC}"
    echo -e "   🌐 IP地址: ${YELLOW}${SERVER_IP}${NC}"
    echo -e "   🔌 端口: ${YELLOW}${SERVER_PORT}${NC} (UDP)"
    echo -e "   🔑 UUID: ${YELLOW}${TUIC_UUID}${NC}"
    echo -e "   🔑 密码: ${YELLOW}${TUIC_PASSWORD}${NC}"
    echo -e "   🎯 SNI: ${YELLOW}${SNI}${NC}"
    
    echo -e "\n${CYAN}📱 节点链接:${NC}"
    echo -e "${GREEN}${TUIC_LINK}${NC}"
    
    echo -e "\n${CYAN}⚠️  重要提示:${NC}"
    echo -e "   • 确保防火墙开放 UDP 端口: ${YELLOW}sudo ufw allow ${SERVER_PORT}/udp${NC}"
    echo -e "   • 连接信息已保存到: ${YELLOW}${LINK_FILE}${NC}"
    
    # 启动服务
    echo -e "\n${CYAN}🚀 启动 TUIC 服务器...${NC}"
    nohup "$TUIC_BIN" -c "$CONFIG_FILE" > tuic.log 2>&1 &
    local PID=$!
    log_success "服务已启动 (PID: $PID)"
    
    echo -e "\n${YELLOW}建议: 使用 systemd 配置开机自启动（参考 README.md）${NC}\n"
}

#===============================================================================
# 主函数
#===============================================================================

main() {
    print_banner
    
    log_info "脚本以普通用户权限运行（无需 root）"
    
    # 检查必要工具
    for cmd in curl openssl; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "缺少必要工具: $cmd"
            exit 1
        fi
    done
    
    # 选择协议
    select_protocol
    
    # 配置端口
    configure_port "$@"
    
    # 部署对应协议
    case $PROTOCOL in
        hysteria2)
            deploy_hysteria2
            ;;
        tuic)
            deploy_tuic
            ;;
        *)
            log_error "未知协议: $PROTOCOL"
            exit 1
            ;;
    esac
    
    log_success "部署完成！"
}

# 执行主函数
main "$@"
