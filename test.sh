#!/usr/bin/env python3
import os
import sys
import subprocess
import requests
import uuid
import ssl
import socket
from urllib.request import urlretrieve

# Default config
MASQ_DOMAIN = 'www.bing.com'
TUIC_VERSION = 'latest'
HYSTERIA_VERSION = 'v2.6.5'
DEFAULT_TUIC_PORT = int(os.getenv('SERVER_PORT', 443))
DEFAULT_HY2_PORT = 22222
TUIC_BIN = './tuic-server'
HY2_BIN = './hysteria-linux'
CERT_PEM = 'cert.pem'
KEY_PEM = 'key.pem'
TUIC_TOML = 'tuic.toml'
HY2_YAML = 'hy2.yaml'
TUIC_LINK_TXT = 'tuic_link.txt'
HY2_LOG = 'hy2.log'

# Parse command line args
tuic_port = DEFAULT_TUIC_PORT
hy2_port = DEFAULT_HY2_PORT
args = sys.argv[1:]
for i in range(len(args)):
    if args[i] == '--tuic-port' and i+1 < len(args):
        tuic_port = int(args[i+1])
    if args[i] == '--hy2-port' and i+1 < len(args):
        hy2_port = int(args[i+1])

print(f"✅ TUIC 端口: {tuic_port}")
print(f"✅ Hy2 端口: {hy2_port}")

def get_arch():
    machine = os.uname().machine.lower()
    if 'arm64' in machine or 'aarch64' in machine:
        return 'arm64'
    if 'x64' in machine or 'amd64' in machine:
        return 'amd64'
    raise Exception(f'❌ 不支持的架构: {machine}')

ARCH = get_arch()
HY2_BIN_FULL = f"{HY2_BIN}-{ARCH}"

def check_port(port):
    try:
        result = subprocess.run(f"netstat -tuln | grep :{port}", shell=True, check=True, capture_output=True)
        if result.stdout:
            raise Exception(f"❌ 端口 {port} 已占用")
    except subprocess.CalledProcessError:
        pass
    print(f"✅ 端口 {port} 可用")

def download_file(url, dest):
    urlretrieve(url, dest)
    os.chmod(dest, 0o755)

def generate_cert():
    if os.path.exists(CERT_PEM) and os.path.exists(KEY_PEM):
        print("🔐 已有证书，跳过生成")
        return
    print("🔐 生成自签证书...")
    subprocess.run(f"openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout {KEY_PEM} -out {CERT_PEM} -subj '/CN={MASQ_DOMAIN}' -days 365 -nodes", shell=True, check=True)
    os.chmod(KEY_PEM, 0o600)
    os.chmod(CERT_PEM, 0o644)
    print("✅ 证书生成完成")

async def get_server_ip():
    try:
        return requests.get('https://api.ipify.org').text.strip()
    except:
        return 'YOUR_SERVER_IP'

# ... [rest of the functions would be similarly converted]
