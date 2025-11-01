#!/bin/bash

# =========================================
# TUIC over QUIC
# 固定 SNI：www.bing.com
# =========================================

set -euo pipefail

export LC_ALL=C
IFS=$'\n\t'

MASQ_DOMAIN="www.bing.com"
SERVER_TOML="server.toml"
CERT_PEM="tuic-cert.pem"
KEY_PEM="tuic-key.pem"
LINK_TXT="tuic_link.txt"
TUIC_BIN="./tuic-server"
VERSION_FILE="tuic-version.txt"

# ========== 获取最新版本 ==========
get_latest_version() {
  echo "🔍 Fetching latest TUIC version..."
  local latest_version
  latest_version=$(curl -s --connect-timeout 10 "https://api.github.com/repos/Itsusinn/tuic/releases/latest" | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/' || echo "")
  
  if [[ -z "$latest_version" ]]; then
    echo "⚠️ Failed to fetch latest version, falling back to v1.4.5"
    echo "v1.4.5"
  else
    echo "✅ Latest version: $latest_version"
    echo "$latest_version"
  fi
}

# ========== 获取当前版本 ==========
get_current_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    cat "$VERSION_FILE"
  else
    echo ""
  fi
}

# ========== 保存版本信息 ==========
save_version() {
  echo "$1" > "$VERSION_FILE"
}

# ========== 检查是否需要更新 ==========
needs_update() {
  local current_version="$1"
  local latest_version="$2"
  
  if [[ -z "$current_version" ]] || [[ ! -x "$TUIC_BIN" ]]; then
    return 0  # 需要下载/更新
  fi
  
  if [[ "$current_version" != "$latest_version" ]]; then
    echo "🔄 Update available: $current_version → $latest_version"
    return 0  # 需要更新
  fi
  
  return 1  # 不需要更新
}

# ========== 随机端口 ==========
random_port() {
  echo $(( (RANDOM % 40000) + 20000 ))
}

# ========== 选择端口 ==========
read_port() {
  if [[ $# -ge 1 && -n "${1:-}" ]]; then
    TUIC_PORT="$1"
    echo "✅ Using specified port: $TUIC_PORT"
    return
  fi

  if [[ -n "${SERVER_PORT:-}" ]]; then
    TUIC_PORT="$SERVER_PORT"
    echo "✅ Using environment port: $TUIC_PORT"
    return
  fi

  TUIC_PORT=$(random_port)
  echo "🎲 Random port selected: $TUIC_PORT"
}

# ========== 检查已有配置 ==========
load_existing_config() {
  if [[ -f "$SERVER_TOML" ]]; then
    TUIC_PORT=$(grep '^server' "$SERVER_TOML" | grep -Eo '[0-9]+')
    TUIC_UUID=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk '{print $1}')
    TUIC_PASSWORD=$(grep '^\[users\]' -A1 "$SERVER_TOML" | tail -n1 | awk -F'"' '{print $2}')
    echo "📂 Existing config detected. Loading..."
    return 0
  fi

  return 1
}

# ========== 生成证书 ==========
generate_cert() {
  if [[ -f "$CERT_PEM" && -f "$KEY_PEM" ]]; then
    echo "🔐 Certificate exists, skipping."
    return
  fi

  echo "🔐 Generating self-signed certificate for ${MASQ_DOMAIN}..."
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes >/dev/null 2>&1

  chmod 600 "$KEY_PEM"
  chmod 644 "$CERT_PEM"
}

# ========== 下载/更新 tuic-server ==========
check_tuic_server() {
  local latest_version current_version
  
  latest_version=$(get_latest_version)
  current_version=$(get_current_version)
  
  if needs_update "$current_version" "$latest_version"; then
    echo "📥 Downloading tuic-server $latest_version..."
    
    # 创建备份（如果存在旧版本）
    if [[ -f "$TUIC_BIN" ]]; then
      mv "$TUIC_BIN" "${TUIC_BIN}.backup"
      echo "💾 Backup created: ${TUIC_BIN}.backup"
    fi
    
    # 下载新版本
    local download_url="https://github.com/Itsusinn/tuic/releases/download/${latest_version}/tuic-server-x86_64-linux"
    if curl -L -o "$TUIC_BIN" "$download_url"; then
      chmod +x "$TUIC_BIN"
      save_version "$latest_version"
      echo "✅ Successfully updated to $latest_version"
      
      # 删除备份（如果下载成功）
      [[ -f "${TUIC_BIN}.backup" ]] && rm -f "${TUIC_BIN}.backup"
    else
      echo "❌ Failed to download $latest_version"
      # 恢复备份
      if [[ -f "${TUIC_BIN}.backup" ]]; then
        mv "${TUIC_BIN}.backup" "$TUIC_BIN"
        echo "🔄 Restored from backup"
      fi
      exit 1
    fi
  else
    echo "✅ tuic-server is up to date ($current_version)"
  fi
}

# ========== 生成配置 ==========
generate_config() {
cat > "$SERVER_TOML" <<EOF
log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
task_negotiation_timeout = "4s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "$CERT_PEM"
private_key = "$KEY_PEM"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${TUIC_PORT}"
secret = "$(openssl rand -hex 16)"
maximum_clients_per_user = 999999999

[quic]
initial_mtu = $((1200 + RANDOM % 200))
min_mtu = 1200
gso = true
pmtu = true
send_window = 33554432
receive_window = 16777216
max_idle_time = "25s"

[quic.congestion_control]
controller = "bbr"
initial_window = 6291456

EOF
}

# ========== 获取公网IP ==========
get_server_ip() {
  curl -s --connect-timeout 3 https://api64.ipify.org || echo "127.0.0.1"
}

# ========== 生成TUIC链接 ==========
generate_link() {
  local ip="$1"
  local current_version
  current_version=$(get_current_version)
  
  # 节点输出链接
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}-${current_version}
EOF

  echo "🔗 TUIC link generated successfully:"
  cat "$LINK_TXT"
}

# ========== 守护进程 ==========
run_background_loop() {
  echo "🚀 Starting TUIC server..."
  local current_version
  current_version=$(get_current_version)
  echo "📊 Running TUIC version: $current_version"
  
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC crashed. Restarting in 5s..."
    sleep 5
  done
}

# ========== 手动更新命令 ==========
manual_update() {
  echo "🔄 Manual update requested..."
  # 强制重新检查和下载
  rm -f "$VERSION_FILE"
  check_tuic_server
  echo "✅ Manual update completed"
}

# ========== 显示版本信息 ==========
show_version() {
  local current_version latest_version
  current_version=$(get_current_version)
  latest_version=$(get_latest_version)
  
  echo "📊 Version Information:"
  echo "   Current: ${current_version:-"Not installed"}"
  echo "   Latest:  $latest_version"
  
  if [[ -n "$current_version" ]] && [[ "$current_version" != "$latest_version" ]]; then
    echo "   Status:  🔄 Update available"
  elif [[ -n "$current_version" ]]; then
    echo "   Status:  ✅ Up to date"
  else
    echo "   Status:  ❌ Not installed"
  fi
}

# ========== 显示帮助信息 ==========
show_help() {
  echo "TUIC Auto-Deploy Script with Auto-Update"
  echo ""
  echo "Usage: $0 [COMMAND] [PORT]"
  echo ""
  echo "Commands:"
  echo "  start [PORT]    Start TUIC server (default)"
  echo "  update          Force update to latest version"
  echo "  version         Show version information"
  echo "  help            Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0              # Start with random port"
  echo "  $0 8443         # Start with port 8443"
  echo "  $0 update       # Force update to latest"
  echo "  $0 version      # Show version info"
}

# ========== 主流程 ==========
main() {
  # 处理命令行参数
  case "${1:-start}" in
    "update")
      manual_update
      exit 0
      ;;
    "version")
      show_version
      exit 0
      ;;
    "help"|"-h"|"--help")
      show_help
      exit 0
      ;;
    "start"|[0-9]*)
      # 继续正常流程
      ;;
    *)
      echo "❌ Unknown command: $1"
      show_help
      exit 1
      ;;
  esac

  if ! load_existing_config; then
    read_port "$@"
    TUIC_UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)"
    TUIC_PASSWORD="$(openssl rand -hex 16)"
    generate_cert
    check_tuic_server
    generate_config
  else
    generate_cert
    check_tuic_server
  fi

  ip="$(get_server_ip)"
  generate_link "$ip"
  run_background_loop
}

main "$@"
