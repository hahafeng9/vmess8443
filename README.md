# vmess8443 — VMess 节点 + Cloudflare 隧道（固定/随机）一键部署

在一台 Debian/Ubuntu（systemd、root）机器上一键部署一个 VMess+WS 节点，经 Cloudflare 隧道对外。
支持两种隧道模式，用 `TUNNEL_MODE` 选择：

- `fixed`（默认）**固定隧道**：需要隧道 token，域名固定。
  链路：客户端 → 优选域名 `cf.877774.xyz:8443` → 固定隧道 `vmess251.ccc.tech`
  → 本机 `127.0.0.1:18001`（sing-box VMess+WS）
- `quick` **随机隧道**：免 token，cloudflared 自动注册临时域名 `xxx.trycloudflare.com:443`。
  注意：cloudflared 重启（含重启机器）后域名会变，旧链接失效；重跑本脚本可刷新链接。

## 用法

在目标机器上以 root 运行（一整段粘贴）：

```bash
# 固定隧道（默认）：只需 token 和隧道域名，UUID / WS 路径自动生成
curl -fsSL https://raw.githubusercontent.com/hahafeng9/vmess8443/main/install.sh -o /tmp/vmess8443-install.sh && \
TUNNEL_TOKEN='你的隧道token' TUNNEL_HOST='你的隧道域名' \
bash /tmp/vmess8443-install.sh

# 随机隧道（免 token）
curl -fsSL https://raw.githubusercontent.com/hahafeng9/vmess8443/main/install.sh -o /tmp/vmess8443-install.sh && \
TUNNEL_MODE=quick bash /tmp/vmess8443-install.sh
```

UUID 和 WS_PATH **不用填**：省略时自动随机生成，存进 `/etc/vmess8443/params.env`，
重跑脚本自动复用（链接不变）。部署完链接直接打印在最后，也存在
`/root/vmess8443-link.txt`。想用指定的 UUID/路径才需要加 `VMESS_UUID='...' WS_PATH='/vmess-xxx'`。

`TUNNEL_HOST` 是固定隧道的域名（就是你建隧道时 Public Hostname 里的那个完整域名，
如 `vmess251.ccc.tech`），**必须和 Cloudflare 面板里配置的一致**——它会写进 VMess
链接的 Host/SNI。不传的话默认用 `vmess251.ccc.tech`。

参数（都可省略）：

| 环境变量 | 说明 |
| --- | --- |
| `TUNNEL_MODE` | `fixed`（固定隧道，默认）/ `quick`（随机隧道）。重跑时省略则复用上次模式。 |
| `TUNNEL_TOKEN` | 固定隧道的 token（仅 fixed 需要）。没给时脚本会在终端提示粘贴（或读上次保存的）。 |
| `CF_API_TOKEN` | 可选。Cloudflare API Token（需 `Zone.Zone 读取` + `Zone.DNS 编辑` 权限）。给了就自动做 DNS 自愈：清理同名旧隧道记录并把域名 CNAME 对准本隧道，杜绝 530/1033。不给则只在探测到 1033 时打印手工修复步骤。 |
| `VMESS_UUID` | 节点 UUID。没给随机生成。 |
| `WS_PATH` | WebSocket 路径。没给随机生成。 |
| `LOCAL_PORT` | 本机监听端口，默认 `18001`（只绑 127.0.0.1）。 |
| `TUNNEL_HOST` | 固定隧道的隧道域名，默认 `vmess251.ccc.tech`（仅 fixed）。 |
| `EDGE_ADDR` / `EDGE_PORT` | 固定隧道客户端连接地址/端口，默认 `cf.877774.xyz` / `8443`（仅 fixed）。 |

UUID、路径、隧道模式会存到 `/etc/vmess8443/params.env`，重跑脚本自动复用；随机隧道的
当前域名存 `/etc/vmess8443/quick-domain.txt`。所有参数会先做合法性校验（UUID 格式、
WS_PATH 字符集、端口范围等），不合法直接报错退出，避免特殊字符破坏配置。

## 脚本做了什么

1. 缺 curl 时自动 `apt-get install curl ca-certificates`。
2. 从官方源装 sing-box（SagerNet GitHub Releases）与 cloudflared（Cloudflare GitHub Releases）。
   sing-box 版本号先查 GitHub API，被限流时自动改用 releases/latest 跳转解析。
3. 写独立配置 `/etc/vmess8443/`（sing-box 配置、隧道 token 600 权限），不改机器上其他服务。
   cloudflared 优先用 `--token-file`，极旧版回退 `--token` 时 token 放 600 权限的
   EnvironmentFile，不会明文写进 systemd unit。
4. 建两个 systemd 服务并自启：`sing-box-vmess8443`、`cloudflared-8443`（cloudflared 强制 http2）。
   **quick 模式特例**：重跑脚本时，若隧道已在运行且配置没变，则不重启 cloudflared——
   保住当前随机域名，只重新从日志解析域名并刷新链接。
5. 自检：本机 WS 握手（101）→ 公网隧道握手（fixed 走隧道域名，quick 走随机域名）
   → fixed 模式再加一层优选入口完整链路（用 `--resolve` 复现客户端连 `EDGE_ADDR:8443`
   的真实路径，仅提示不阻断）。
6. 输出 VMess 链接，并存一份到 `/root/vmess8443-link.txt`。

## 前置条件（隧道侧，脚本之外）

- fixed：固定隧道需先在 Cloudflare 建好（远程管理型），且 ingress 指向
  `http://127.0.0.1:18001`、DNS 有对应 CNAME。本仓库配套的隧道：`vmess251.ccc.tech`。
- quick：无需任何 Cloudflare 侧配置，但出口要能连上 Cloudflare 边缘。

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/hahafeng9/vmess8443/main/install.sh -o /tmp/vmess8443-install.sh && \
bash /tmp/vmess8443-install.sh --uninstall
```

会停掉并删除 `sing-box-vmess8443`、`cloudflared-8443` 两个服务和 `/etc/vmess8443/`、
`/root/vmess8443-link.txt`；`/usr/local/bin/` 下的 sing-box、cloudflared 二进制保留。

手动卸载（脚本不在手边时）：

```bash
systemctl disable --now sing-box-vmess8443 cloudflared-8443
rm -f /etc/systemd/system/sing-box-vmess8443.service /etc/systemd/system/cloudflared-8443.service
systemctl daemon-reload
rm -rf /etc/vmess8443 /root/vmess8443-link.txt
```
