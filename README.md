# 🚀 一键极简部署 Hysteria2 & TUIC 节点

面向 Node.js/Python 环境，快速一键安装，轻松上云，首选低配 VPS 场景！

---

## 1️⃣ Hysteria2 部署（可自定义端口）

- 兼容 Node.js 与 Python 环境
- 支持命令行自定义端口号

curl -Ls https://raw.githubusercontent.com/lovejapan1/tuic-hy2-node.js-python/main/hy2.sh | sed 's/\r$//' | bash -s -- [端口号]

> ✨ **请将 `[端口号]` 替换为你需要的端口（如 443、22222 等）**

---

## 2️⃣ TUIC 部署

- Node.js/Python 环境一键部署

curl -Ls https://raw.githubusercontent.com/lovejapan1/tuic-hy2-node.js-python/main/tuic.sh | sed 's/\r$//' | bash

---

## 🌟 推荐云服务器平台

| 云主机名称 | 官网地址                                |
|:-----------|:---------------------------------------|
| **Lunes**      | [https://lunes.host/](https://lunes.host/)         |
| **Orihost**    | [https://orihost.com/](https://orihost.com/)       |
| **Wispbyte**   | [https://wispbyte.com/](https://wispbyte.com/)     |

---

## 💡 温馨提示

- ✅ 支持低内存小鸡，极简安装体验
- ✅ 自动生成全部配置和证书
- ✅ 默认参数即开即用
- 建议提前在云服务器防火墙放行所需端口（如 `443/udp`）
- 按需自定义配置，更多细节可参考脚本说明

---
