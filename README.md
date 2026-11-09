# vmess8443 — VMess 节点 + Cloudflare 固定隧道 一键部署

在一台 Debian/Ubuntu（systemd、root）机器上一键部署一个 VMess+WS 节点，
经 Cloudflare 固定隧道对外，客户端连接地址用优选域名、端口 8443。

链路：客户端 → `cf.877774.xyz:8443` → CF 固定隧道 `vmess251.fengco.tech`
→ 本机 `127.0.0.1:18001`（sing-box VMess+WS）

## 用法

在目标机器上以 root 运行（一整段粘贴）：

```bash
curl -fsSL https://raw.githubusercontent.com/hahafeng9/vmess8443/main/install.sh -o /tmp/vmess8443-install.sh && \
TUNNEL_TOKEN='你的隧道token' VMESS_UUID='你的UUID' WS_PATH='/vmess-你的路径' \
bash /tmp/vmess8443-install.sh
```

参数（都可省略）：

| 环境变量 | 说明 |
| --- | --- |
| `TUNNEL_TOKEN` | Cloudflare 固定隧道的 token。没给时脚本会在终端提示粘贴（或读上次保存的）。 |
| `VMESS_UUID` | 节点 UUID。没给随机生成。 |
| `WS_PATH` | WebSocket 路径。没给随机生成。 |
| `LOCAL_PORT` | 本机监听端口，默认 `18001`（只绑 127.0.0.1）。 |
| `TUNNEL_HOST` | 隧道域名，默认 `vmess251.fengco.tech`。 |
| `EDGE_ADDR` / `EDGE_PORT` | 客户端连接地址/端口，默认 `cf.877774.xyz` / `8443`。 |

UUID 与路径会存到 `/etc/vmess8443/params.env`，重跑脚本自动复用，不会换链接。

## 脚本做了什么

1. 缺 curl 时自动 `apt-get install curl ca-certificates`。
2. 从官方源装 sing-box（SagerNet GitHub Releases）与 cloudflared（Cloudflare GitHub Releases）。
3. 写独立配置 `/etc/vmess8443/`（sing-box 配置、隧道 token 600 权限），不改机器上其他服务。
4. 建两个 systemd 服务并自启：`sing-box-vmess8443`、`cloudflared-8443`（cloudflared 强制 http2）。
5. 自检：本机 WS 握手应为 101，再探公网隧道握手。
6. 输出 VMess 链接，并存一份到 `/root/vmess8443-link.txt`。

## 前置条件（隧道侧，脚本之外）

固定隧道需先在 Cloudflare 建好（远程管理型），且 ingress 指向 `http://127.0.0.1:18001`、
DNS 有对应 CNAME。本仓库配套的隧道：`vmess251.fengco.tech`。

## 卸载

```bash
systemctl disable --now sing-box-vmess8443 cloudflared-8443
rm -f /etc/systemd/system/sing-box-vmess8443.service /etc/systemd/system/cloudflared-8443.service
systemctl daemon-reload
rm -rf /etc/vmess8443 /root/vmess8443-link.txt
```
