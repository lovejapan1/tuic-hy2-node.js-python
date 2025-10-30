set -e

# ==================== 配置颜色输出 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==================== 主菜单 ====================
show_main_menu() {
    clear
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "${GREEN}              代理协议统一安装脚本${NC}"
    echo -e "${BLUE}========================================================================${NC}"
    echo ""
    echo -e "${YELLOW}请选择要安装的协议:${NC}"
    echo ""
    echo "  1) Hysteria2 (基于 QUIC 的高性能协议)"
    echo "  2) TUIC v5 (轻量级 QUIC 代理协议)"
    echo "  3) 退出"
    echo ""
    echo -e "${BLUE}========================================================================${NC}"
}

# ==================== 端口输入函数 ====================
get_custom_port() {
    local default_port="$1"
    local port
    
    echo ""
    echo -e "${YELLOW}请输入端口 (1024-65535，直接回车使用默认端口 ${default_port}):${NC}"
    read -rp "> " port
    
    # 如果用户直接回车，使用默认端口
    if [[ -z "$port" ]]; then
        echo "$default_port"
        return
    fi
    
    # 验证端口
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1024 ]] || [[ "$port" -gt 65535 ]]; then
        echo -e "${RED}❌ 无效端口: $port，使用默认端口 ${default_port}${NC}"
        echo "$default_port"
        return
    fi
    
    echo "$port"
}

# ==================== Hysteria2 安装函数 ====================
install_hysteria2() {
    echo ""
    echo -e "${GREEN}========================================================================${NC}"
    echo -e "${GREEN}开始安装 Hysteria2${NC}"
    echo -e "${GREEN}========================================================================${NC}"
    
    # 获取端口
    CUSTOM_PORT=$(get_custom_port "22222")
    
    # ---------- 默认配置 ----------
    HYSTERIA_VERSION="v2.6.5"
    DEFAULT_PORT="$CUSTOM_PORT"
    AUTH_PASSWORD="Tokyo00"
    CERT_FILE="hy2-cert.pem"
    KEY_FILE="hy2-key.pem"
    SNI="www.bing.com"
    ALPN="h3"
    LOG_FILE="hysteria.log"
    
    echo ""
    echo -e "${BLUE}配置信息:${NC}"
    echo "  版本: ${HYSTERIA_VERSION}"
    echo "  端口: ${DEFAULT_PORT}"
    echo "  密码: ${AUTH_PASSWORD}"
    echo "  SNI: ${SNI}"
    echo ""
    
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
        echo -e "${RED}❌ 无法识别 CPU 架构: $(uname -m)${NC}"
        exit 1
    fi
    
    BIN_NAME="hysteria-linux-${ARCH}"
    BIN_PATH="./${BIN_NAME}"
    
    # ---------- 下载二进制 ----------
    if [ -f "$BIN_PATH" ]; then
        echo -e "${GREEN}✅ 二进制已存在，跳过下载${NC}"
    else
        URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
        echo -e "${YELLOW}⏳ 下载: $URL${NC}"
        curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
        chmod +x "$BIN_PATH"
        echo -e "${GREEN}✅ 下载完成并设置可执行${NC}"
    fi
    
    # ---------- 生成证书 ----------
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo -e "${GREEN}✅ 发现证书，使用现有 cert/key${NC}"
    else
        echo -e "${YELLOW}🔑 生成自签证书...${NC}"
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}" >/dev/null 2>&1
        chmod 644 "$CERT_FILE" "$KEY_FILE"
        echo -e "${GREEN}✅ 证书生成成功${NC}"
    fi
    
    # ---------- 写配置文件 ----------
    cat > server.yaml <<EOF
listen: ":${DEFAULT_PORT}"

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

logging:
  level: info
  file: "$(pwd)/${LOG_FILE}"
EOF
    echo -e "${GREEN}✅ 配置文件生成成功${NC}"
    
    # ---------- 获取服务器 IP ----------
    SERVER_IP=$(curl -s --max-time 10 https://ifconfig.me || curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP")
    
    # ---------- 打印连接信息 ----------
    echo ""
    echo -e "${GREEN}========================================================================${NC}"
    echo -e "${GREEN}🎉 Hysteria2 安装成功！${NC}"
    echo -e "${GREEN}========================================================================${NC}"
    echo ""
    echo -e "${BLUE}📋 服务器信息:${NC}"
    echo "   🌐 IP地址: $SERVER_IP"
    echo "   🔌 端口: $DEFAULT_PORT (请确保UDP端口开放！)"
    echo "   🔑 密码: $AUTH_PASSWORD"
    echo "   📝 日志: ${LOG_FILE}"
    echo ""
    echo -e "${BLUE}📱 节点链接:${NC}"
    echo "hysteria2://${AUTH_PASSWORD}@${SERVER_IP}:${DEFAULT_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Bing"
    echo ""
    echo -e "${BLUE}📄 客户端配置:${NC}"
    echo "server: ${SERVER_IP}:${DEFAULT_PORT}"
    echo "auth: ${AUTH_PASSWORD}"
    echo "tls:"
    echo "  sni: ${SNI}"
    echo "  alpn: [\"${ALPN}\"]"
    echo "  insecure: true"
    echo "socks5:"
    echo "  listen: 127.0.0.1:1080"
    echo "http:"
    echo "  listen: 127.0.0.1:8080"
    echo ""
    echo -e "${YELLOW}⚠️ 排查提示:${NC}"
    echo "  - 检查防火墙: sudo ufw allow ${DEFAULT_PORT}/udp"
    echo "  - 查看日志: tail -f ${LOG_FILE}"
    echo -e "${GREEN}========================================================================${NC}"
    echo ""
    
    # ---------- 启动服务 ----------
    echo -e "${YELLOW}🚀 启动 Hysteria2 服务器...${NC}"
    HYSTERIA_BRUTAL_DEBUG=1 nohup "$BIN_PATH" server -c server.yaml > "$LOG_FILE" 2>&1 &
    echo -e "${GREEN}✅ 服务器已启动 (PID: $!)${NC}"
    echo -e "${BLUE}检查日志: tail -f ${LOG_FILE}${NC}"
    echo ""
}

# ==================== TUIC 安装函数 ====================
install_tuic() {
    echo ""
    echo -e "${GREEN}========================================================================${NC}"
    echo -e "${GREEN}开始安装 TUIC v5${NC}"
    echo -e "${GREEN}========================================================================${NC}"
    
    # 获取端口
    CUSTOM_PORT=$(get_custom_port "8443")
    
    # ---------- 默认配置 ----------
    TUIC_PORT="$CUSTOM_PORT"
    MASQ_DOMAIN="www.bing.com"
    SERVER_TOML="server.toml"
    CERT_PEM="tuic-cert.pem"
    KEY_PEM="tuic-key.pem"
    LINK_TXT="tuic_link.txt"
    TUIC_BIN="./tuic-server"
    
    # 生成 UUID 和密码
    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    
    echo ""
    echo -e "${BLUE}配置信息:${NC}"
    echo "  端口: ${TUIC_PORT}"
    echo "  UUID: ${TUIC_UUID}"
    echo "  密码: ${TUIC_PASSWORD}"
    echo "  SNI: ${MASQ_DOMAIN}"
    echo ""
    
    # ---------- 生成证书 ----------
    if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
        echo -e "${GREEN}✅ 发现证书，跳过生成${NC}"
    else
        echo -e "${YELLOW}🔑 生成自签证书...${NC}"
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1
        chmod 600 "$KEY_PEM"
        chmod 644 "$CERT_PEM"
        echo -e "${GREEN}✅ 证书生成成功${NC}"
    fi
    
    # ---------- 下载 tuic-server ----------
    if [[ -x "$TUIC_BIN" ]]; then
        echo -e "${GREEN}✅ tuic-server 已存在${NC}"
    else
        echo -e "${YELLOW}📥 下载 tuic-server...${NC}"
        ARCH=$(uname -m)
        if [[ "$ARCH" != "x86_64" ]]; then
            echo -e "${RED}❌ 暂不支持架构: $ARCH${NC}"
            exit 1
        fi
        
        LATEST_TAG=$(curl -s https://api.github.com/repos/Itsusinn/tuic/releases/latest | grep '"tag_name"' | cut -d '"' -f4)
        if [[ -z "$LATEST_TAG" ]]; then
            echo -e "${RED}❌ 无法获取最新版本${NC}"
            exit 1
        fi
        echo -e "${GREEN}✅ 最新版本: $LATEST_TAG${NC}"
        
        TUIC_URL="https://github.com/Itsusinn/tuic/releases/download/$LATEST_TAG/tuic-server-x86_64-linux"
        if curl -L -f -o "$TUIC_BIN" "$TUIC_URL"; then
            chmod +x "$TUIC_BIN"
            echo -e "${GREEN}✅ tuic-server 下载完成${NC}"
        else
            echo -e "${RED}❌ 下载失败${NC}"
            exit 1
        fi
    fi
    
    # ---------- 生成配置文件 ----------
    cat > "$SERVER_TOML" <<EOF
log_level = "off"
server = "0.0.0.0:${TUIC_PORT}"

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
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${TUIC_PORT}"
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
    echo -e "${GREEN}✅ 配置文件生成成功${NC}"
    
    # ---------- 获取服务器 IP ----------
    SERVER_IP=$(curl -s --connect-timeout 3 https://api.ipify.org || echo "YOUR_SERVER_IP")
    
    # ---------- 生成链接 ----------
    cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${SERVER_IP}
EOF
    
    # ---------- 打印连接信息 ----------
    echo ""
    echo -e "${GREEN}========================================================================${NC}"
    echo -e "${GREEN}🎉 TUIC v5 安装成功！${NC}"
    echo -e "${GREEN}========================================================================${NC}"
    echo ""
    echo -e "${BLUE}📋 服务器信息:${NC}"
    echo "   🌐 IP地址: $SERVER_IP"
    echo "   🔌 端口: $TUIC_PORT (请确保UDP端口开放！)"
    echo "   🔑 UUID: $TUIC_UUID"
    echo "   🔑 密码: $TUIC_PASSWORD"
    echo ""
    echo -e "${BLUE}📱 TUIC 链接 (已保存到 ${LINK_TXT}):${NC}"
    cat "$LINK_TXT"
    echo ""
    echo -e "${YELLOW}⚠️ 排查提示:${NC}"
    echo "  - 检查防火墙: sudo ufw allow ${TUIC_PORT}/udp"
    echo "  - 链接文件: cat ${LINK_TXT}"
    echo -e "${GREEN}========================================================================${NC}"
    echo ""
    
    # ---------- 启动服务 ----------
    echo -e "${YELLOW}🚀 启动 TUIC 服务器 (后台循环守护)...${NC}"
    nohup bash -c "while true; do $TUIC_BIN -c $SERVER_TOML; echo '⚠️ tuic-server 已退出，5秒后重启...'; sleep 5; done" > tuic.log 2>&1 &
    echo -e "${GREEN}✅ 服务器已启动 (PID: $!)${NC}"
    echo -e "${BLUE}检查日志: tail -f tuic.log${NC}"
    echo ""
}

# ==================== 主函数 ====================
main() {
    while true; do
        show_main_menu
        read -rp "请选择 [1-3]: " choice
        
        case $choice in
            1)
                install_hysteria2
                echo ""
                read -rp "按回车键返回主菜单..."
                ;;
            2)
                install_tuic
                echo ""
                read -rp "按回车键返回主菜单..."
                ;;
            3)
                echo -e "${GREEN}退出安装脚本。再见！${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 无效选择，请输入 1-3${NC}"
                sleep 2
                ;;
        esac
    done
}

# 执行主函数
main "$@"
