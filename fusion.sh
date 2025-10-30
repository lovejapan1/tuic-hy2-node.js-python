#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const https = require('https');
const child_process = require('child_process');
const os = require('os');
const { promisify } = require('util');

const exec = promisify(child_process.exec);

// 默认配置
const MASQ_DOMAIN = 'www.bing.com'; // TUIC & Hy2 共用SNI
const TUIC_VERSION = 'latest'; // 从GitHub获取最新
const HYSTERIA_VERSION = 'v2.6.5';
const DEFAULT_TUIC_PORT = process.env.SERVER_PORT || 443; // 支持环境变量
const DEFAULT_HY2_PORT = 22222;
const TUIC_BIN = './tuic-server';
const HY2_BIN = './hysteria-linux';
const CERT_PEM = 'cert.pem';
const KEY_PEM = 'key.pem';
const TUIC_TOML = 'tuic.toml';
const HY2_YAML = 'hy2.yaml';
const TUIC_LINK_TXT = 'tuic_link.txt';
const HY2_LOG = 'hy2.log';

// 命令行解析（简单手动解析，支持 --tuic-port 和 --hy2-port）
const args = process.argv.slice(2);
let tuicPort = DEFAULT_TUIC_PORT;
let hy2Port = DEFAULT_HY2_PORT;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--tuic-port' && args[i+1]) tuicPort = parseInt(args[i+1]);
  if (args[i] === '--hy2-port' && args[i+1]) hy2Port = parseInt(args[i+1]);
}

console.log(`✅ TUIC 端口: ${tuicPort}`);
console.log(`✅ Hy2 端口: ${hy2Port}`);

// 获取架构
function getArch() {
  const machine = os.arch().toLowerCase();
  if (machine.includes('arm64') || machine.includes('aarch64')) return 'arm64';
  if (machine.includes('x64') || machine.includes('amd64')) return 'amd64';
  throw new Error('❌ 不支持的架构: ' + machine);
}

const ARCH = getArch();
const HY2_BIN_FULL = `${HY2_BIN}-${ARCH}`;

// 检查端口是否可用（简单netstat）
async function checkPort(port) {
  try {
    const { stdout } = await exec(`netstat -tuln | grep :${port}`);
    if (stdout) throw new Error(`❌ 端口 ${port} 已占用`);
  } catch (err) {
    if (err.message.includes('占用')) throw err;
  }
  console.log(`✅ 端口 ${port} 可用`);
}

// 下载文件
function download(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    https.get(url, res => {
      res.pipe(file);
      file.on('finish', () => {
        file.close(resolve);
        fs.chmodSync(dest, '755'); // +x
      });
    }).on('error', reject);
  });
}

// 生成证书（使用openssl）
async function generateCert() {
  if (fs.existsSync(CERT_PEM) && fs.existsSync(KEY_PEM)) {
    console.log('🔐 已有证书，跳过生成');
    return;
  }
  console.log('🔐 生成自签证书...');
  await exec(`openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout ${KEY_PEM} -out ${CERT_PEM} -subj "/CN=${MASQ_DOMAIN}" -days 365 -nodes`);
  fs.chmodSync(KEY_PEM, '600');
  fs.chmodSync(CERT_PEM, '644');
  console.log('✅ 证书生成完成');
}

// 获取服务器IP
async function getServerIp() {
  try {
    const { stdout } = await exec('curl -s https://api.ipify.org');
    return stdout.trim();
  } catch {
    return 'YOUR_SERVER_IP';
  }
}

// TUIC部分
async function deployTuic() {
  await checkPort(tuicPort);

  // 下载TUIC
  if (fs.existsSync(TUIC_BIN)) {
    console.log('✅ TUIC 二进制已存在');
  } else {
    console.log('📥 下载 TUIC...');
    const latestTag = (await exec('curl -s https://api.github.com/repos/Itsusinn/tuic/releases/latest | grep tag_name | cut -d\'"\' -f4')).stdout.trim();
    const url = `https://github.com/Itsusinn/tuic/releases/download/${latestTag}/tuic-server-x86_64-linux`; // 假设x86_64，arm需调整
    await download(url, TUIC_BIN);
    console.log('✅ TUIC 下载完成');
  }

  // 生成UUID和密码
  const tuicUuid = (await exec('cat /proc/sys/kernel/random/uuid || uuidgen')).stdout.trim();
  const tuicPassword = (await exec('openssl rand -hex 16')).stdout.trim();
  console.log(`🔑 TUIC UUID: ${tuicUuid}`);
  console.log(`🔑 TUIC 密码: ${tuicPassword}`);

  // 生成配置
  const config = `
log_level = "off"
server = "0.0.0.0:${tuicPort}"

udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "10s"
task_negotiation_timeout = "5s"
gc_interval = "10s"
gc_lifetime = "10s"
max_external_packet_size = 8192

[users]
${tuicUuid} = "${tuicPassword}"

[tls]
self_sign = false
certificate = "${CERT_PEM}"
private_key = "${KEY_PEM}"
alpn = ["h3"]

[restful]
addr = "127.0.0.1:${tuicPort}"
secret = "${(await exec('openssl rand -hex 16')).stdout.trim()}"
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
`;
  fs.writeFileSync(TUIC_TOML, config);
  console.log('✅ TUIC 配置生成');

  // 生成链接
  const ip = await getServerIp();
  const link = `tuic://${tuicUuid}:${tuicPassword}@${ip}:${tuicPort}?congestion_control=bbr&alpn=h3&allowInsecure=1&sni=${MASQ_DOMAIN}&udp_relay_mode=native&disable_sni=0&reduce_rtt=1&max_udp_relay_packet_size=8192#TUIC-${ip}`;
  fs.writeFileSync(TUIC_LINK_TXT, link);
  console.log(`📱 TUIC 链接: ${link}`);

  // 运行（后台循环）
  console.log('🚀 启动 TUIC...');
  const tuicProc = child_process.spawn(TUIC_BIN, ['-c', TUIC_TOML], { detached: true, stdio: 'ignore' });
  tuicProc.unref();
  setInterval(() => {
    // 简单守护：检查进程是否存在，不存在重启（实际生产用pm2或systemd更好）
    exec(`ps -p ${tuicProc.pid}`).catch(() => {
      console.log('⚠️ TUIC 重启...');
      child_process.spawn(TUIC_BIN, ['-c', TUIC_TOML], { detached: true, stdio: 'ignore' }).unref();
    });
  }, 5000);
}

// Hy2部分
async function deployHy2() {
  await checkPort(hy2Port);

  // 下载Hy2
  if (fs.existsSync(HY2_BIN_FULL)) {
    console.log('✅ Hy2 二进制已存在');
  } else {
    console.log('📥 下载 Hy2...');
    const url = `https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-${ARCH}`;
    await download(url, HY2_BIN_FULL);
    console.log('✅ Hy2 下载完成');
  }

  // 生成密码
  const authPassword = (await exec('openssl rand -hex 16')).stdout.trim(); // 改为随机
  console.log(`🔑 Hy2 密码: ${authPassword}`);

  // 生成配置
  const config = `
listen: ":${hy2Port}"

tls:
  cert: "${path.resolve(CERT_PEM)}"
  key: "${path.resolve(KEY_PEM)}"
  alpn:
    - "h3"

auth:
  type: "password"
  password: "${authPassword}"

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
  file: "${path.resolve(HY2_LOG)}"
`;
  fs.writeFileSync(HY2_YAML, config);
  console.log('✅ Hy2 配置生成');

  // 打印信息
  const ip = await getServerIp();
  console.log(`🎉 Hy2 部署成功！`);
  console.log(`🔗 链接: hysteria2://${authPassword}@${ip}:${hy2Port}?sni=${MASQ_DOMAIN}&alpn=h3&insecure=1#Hy2-Bing`);
  console.log(`⚠️ 确保UDP ${hy2Port} 开放: sudo ufw allow ${hy2Port}/udp`);

  // 运行（后台）
  console.log('🚀 启动 Hy2...');
  process.env.HYSTERIA_BRUTAL_DEBUG = '1';
  const hy2Proc = child_process.spawn(HY2_BIN_FULL, ['server', '-c', HY2_YAML], { detached: true, stdio: ['ignore', 'ignore', 'ignore'] });
  hy2Proc.unref();
  // 日志: tail -f hy2.log
}

// 主逻辑
async function main() {
  try {
    await generateCert();
    const ip = await getServerIp();
    console.log(`🌐 服务器IP: ${ip}`);

    if (!isNaN(tuicPort)) await deployTuic();
    if (!isNaN(hy2Port)) await deployHy2();

    if (isNaN(tuicPort) && isNaN(hy2Port)) {
      console.log('❌ 请指定至少一个端口: --tuic-port 或 --hy2-port');
      process.exit(1);
    }

    console.log('✅ 部署完成！服务后台运行中。');
    console.log('提示: 用 pm2 或 systemd 守护进程以防重启。');
  } catch (err) {
    console.error('❌ 错误:', err.message);
    process.exit(1);
  }
}

main();
