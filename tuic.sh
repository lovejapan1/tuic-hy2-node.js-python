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
FALLBACK_VERSION="v1.4.5"
GITHUB_REPO="Itsusinn/tuic"

# ========== 获取最新版本号 ==========
get_latest_version() {
  echo "🔍 Fetching latest release from GitHub..."
  local latest_version
  
  # 尝试从 GitHub API 获取最新版本
  latest_version=$(curl -s --connect-timeout 5 --max-time 10 \
    "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
    | grep '"tag_name":' \
    | sed -E 's/.*"tag_name": "([^"]+)".*/\1/' \
    | head -n1)
  
  # 验证版本号格式 (应该是 vX.X.X 格式)
  if [[ -n "$latest_version" && "$latest_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✅ Latest version found: $latest_version"
    echo "$latest_version"
  else
    echo "⚠️ Failed to fetch latest version, using fallback: $FALLBACK_VERSION"
    echo "$FALLBACK_VERSION"
  fi
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

# ========== 下载 tuic-server (多源备选) ==========
check_tuic_server() {
  if [[ -x "$TUIC_BIN" ]]; then
    echo "✅ tuic-server already exists."
    
    # 检查是否需要更新
    local current_version=""
    if [[ -f "${TUIC_BIN}.version" ]]; then
      current_version=$(cat "${TUIC_BIN}.version")
    fi
    
    local latest_version=$(get_latest_version)
    
    if [[ -n "$current_version" && "$current_version" == "$latest_version" ]]; then
      echo "✅ Already running latest version: $latest_version"
      return
    else
      echo "🔄 New version available: $latest_version (current: ${current_version:-unknown})"
      echo "   To update, delete $TUIC_BIN and re-run the script."
    fi
    return
  fi

  local version=$(get_latest_version)
  
  # 定义多个下载源
  declare -a download_urls=(
    "https://github.com/${GITHUB_REPO}/releases/download/${version}/tuic-server-x86_64-linux"
    "https://ghproxy.com/https://github.com/${GITHUB_REPO}/releases/download/${version}/tuic-server-x86_64-linux"
    "https://mirror.ghproxy.com/https://github.com/${GITHUB_REPO}/releases/download/${version}/tuic-server-x86_64-linux"
  )
  
  echo "📥 Downloading tuic-server ${version}..."
  
  local downloaded=0
  for url in "${download_urls[@]}"; do
    echo "   Trying: $url"
    if curl -L -o "$TUIC_BIN" "$url" --connect-timeout 10 --max-time 120 --retry 2 2>/dev/null; then
      if [[ -s "$TUIC_BIN" ]]; then
        chmod +x "$TUIC_BIN"
        echo "$version" > "${TUIC_BIN}.version"
        echo "✅ Successfully downloaded tuic-server ${version}"
        downloaded=1
        break
      fi
    fi
  done
  
  if [[ $downloaded -eq 0 ]]; then
    echo "❌ Failed to download version $version from all sources"
    
    if [[ "$version" != "$FALLBACK_VERSION" ]]; then
      echo "🔄 Retrying with fallback version: $FALLBACK_VERSION"
      
      local fallback_urls=(
        "https://github.com/${GITHUB_REPO}/releases/download/${FALLBACK_VERSION}/tuic-server-x86_64-linux"
        "https://ghproxy.com/https://github.com/${GITHUB_REPO}/releases/download/${FALLBACK_VERSION}/tuic-server-x86_64-linux"
        "https://mirror.ghproxy.com/https://github.com/${GITHUB_REPO}/releases/download/${FALLBACK_VERSION}/tuic-server-x86_64-linux"
      )
      
      for url in "${fallback_urls[@]}"; do
        echo "   Trying: $url"
        if curl -L -o "$TUIC_BIN" "$url" --connect-timeout 10 --max-time 120 --retry 2 2>/dev/null; then
          if [[ -s "$TUIC_BIN" ]]; then
            chmod +x "$TUIC_BIN"
            echo "$FALLBACK_VERSION" > "${TUIC_BIN}.version"
            echo "✅ Successfully downloaded tuic-server ${FALLBACK_VERSION}"
            downloaded=1
            break
          fi
        fi
      done
    fi
    
    if [[ $downloaded -eq 0 ]]; then
      echo ""
      echo "❌ ==============================================="
      echo "❌ All download attempts failed!"
      echo "❌ Solutions:"
      echo "❌ 1. Check your network connection"
      echo "❌ 2. Try using a VPN or proxy"
      echo "❌ 3. Check if GitHub is accessible in your region"
      echo "❌ 4. Or download manually from:"
      echo "❌    https://github.com/${GITHUB_REPO}/releases"
      echo "❌    Then place the binary as: ./tuic-server"
      echo "❌ ==============================================="
      echo ""
      exit 1
    fi
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
  local ip
  
  # 尝试多个 IP 检测服务
  ip=$(curl -s --connect-timeout 3 --max-time 5 https://api64.ipify.org 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  ip=$(curl -s --connect-timeout 3 --max-time 5 https://ipinfo.io/ip 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  ip=$(curl -s --connect-timeout 3 --max-time 5 https://icanhazip.com 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  ip=$(curl -s --connect-timeout 3 --max-time 5 https://myip.ipip.net 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  
  # 所有尝试都失败，使用默认值
  echo "127.0.0.1"
}

# ========== 生成TUIC链接 ==========
generate_link() {
  local ip="$1"
  # 节点输出链接
  cat > "$LINK_TXT" <<EOF
tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${ip}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}
EOF

  echo ""
  echo "🔗 TUIC link generated successfully:"
  echo "=============================================="
  cat "$LINK_TXT"
  echo "=============================================="
  echo ""
}

# ========== 守护进程 ==========
run_background_loop() {
  echo "🚀 Starting TUIC server..."
  echo "📊 Server info:"
  echo "   Port: $TUIC_PORT"
  echo "   UUID: $TUIC_UUID"
  echo "   Password: $TUIC_PASSWORD"
  echo ""
  
  while true; do
    "$TUIC_BIN" -c "$SERVER_TOML" >/dev/null 2>&1 || true
    echo "⚠️ TUIC crashed. Restarting in 5s..."
    sleep 5
  done
}

# ========== 主流程 ==========
main() {
  echo "========================================="
  echo "TUIC Server Setup (QUIC Tunnel)"
  echo "========================================="
  echo ""
  
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
