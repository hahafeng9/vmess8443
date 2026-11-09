#!/usr/bin/env bash
# vmess8443 — 一键部署 VMess+WS 节点 + Cloudflare 固定隧道
#
# 链路：客户端 → 优选域名 cf.877774.xyz:8443 → CF 固定隧道 → 本机 127.0.0.1:18001 (sing-box VMess+WS)
#
# 用法（root 运行）：
#   TUNNEL_TOKEN='隧道token' VMESS_UUID='uuid' WS_PATH='/vmess-xxxx' bash install.sh
# 三个参数都可省略：token 没给会在终端里提示粘贴；UUID/路径没给会随机生成并保存，
# 重跑脚本时自动复用同一套参数（幂等）。
#
# 卸载：bash install.sh --uninstall （只删本脚本装的服务与配置，二进制保留）
#
# 装两个 systemd 服务：sing-box-vmess8443、cloudflared-8443。不动系统里其他服务与配置。
set -euo pipefail

TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
VMESS_UUID="${VMESS_UUID:-}"
WS_PATH="${WS_PATH:-}"
LOCAL_PORT="${LOCAL_PORT:-18001}"
TUNNEL_HOST="${TUNNEL_HOST:-vmess251.fengco.tech}"
EDGE_ADDR="${EDGE_ADDR:-cf.877774.xyz}"
EDGE_PORT="${EDGE_PORT:-8443}"
NODE_NAME="${NODE_NAME:-oracle251-vmess-8443}"

APP_DIR="/etc/vmess8443"
SB_DIR="$APP_DIR/sing-box"
CF_DIR="$APP_DIR/cloudflared"
PARAMS_FILE="$APP_DIR/params.env"
LINK_FILE="/root/vmess8443-link.txt"

log() { echo "[vmess8443] $*"; }
die() { echo "[vmess8443] 错误：$*" >&2; exit 1; }

# ---------- 卸载 ----------
if [ "${1:-}" = "--uninstall" ]; then
  [ "$(id -u)" = "0" ] || die "请用 root 运行本脚本"
  systemctl disable --now sing-box-vmess8443.service cloudflared-8443.service 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box-vmess8443.service /etc/systemd/system/cloudflared-8443.service
  systemctl daemon-reload
  rm -rf "$APP_DIR" "$LINK_FILE"
  log "已卸载（sing-box / cloudflared 二进制保留，需要的话手动删 /usr/local/bin/ 下的同名文件）"
  exit 0
fi

[ "$(id -u)" = "0" ] || die "请用 root 运行本脚本"
command -v systemctl >/dev/null 2>&1 || die "需要 systemd"

fetch() { # fetch URL DEST
  if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 --connect-timeout 15 -o "$2" "$1";
  elif command -v wget >/dev/null 2>&1; then wget -q --timeout=60 -O "$2" "$1";
  else die "缺 curl/wget"; fi
}

# ---------- 基础工具 ----------
if ! command -v curl >/dev/null 2>&1; then
  log "安装 curl / ca-certificates …"
  apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null || die "apt 安装 curl 失败，请手动安装后重试"
fi

# ---------- 参数：优先环境变量，其次复用已保存的，最后随机生成 ----------
mkdir -p "$SB_DIR" "$CF_DIR"
if [ -f "$PARAMS_FILE" ]; then
  # shellcheck disable=SC1091
  . "$PARAMS_FILE"
  VMESS_UUID="${VMESS_UUID:-${SAVED_UUID:-}}"
  WS_PATH="${WS_PATH:-${SAVED_WS_PATH:-}}"
fi
[ -n "$VMESS_UUID" ] || VMESS_UUID=$(cat /proc/sys/kernel/random/uuid)
if [ -z "$WS_PATH" ]; then
  WS_PATH="/vmess-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

# ---------- 参数校验（防特殊字符破坏 JSON 配置 / params.env） ----------
valid_uuid() { printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; }
valid_path() { printf '%s' "$1" | grep -Eq '^/[A-Za-z0-9._~-]{1,100}$'; }
valid_host() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]{1,253}$'; }
valid_name() { printf '%s' "$1" | grep -Eq '^[^"\\]{1,64}$'; }

valid_uuid "$VMESS_UUID" || die "VMESS_UUID 不是合法 UUID：$VMESS_UUID"
valid_path "$WS_PATH" || die "WS_PATH 需 / 开头，仅字母数字和 . _ ~ -（如 /vmess-abc123）：$WS_PATH"
case "$LOCAL_PORT" in ''|*[!0-9]*) die "LOCAL_PORT 必须是数字：$LOCAL_PORT" ;; esac
[ "$LOCAL_PORT" -ge 1 ] && [ "$LOCAL_PORT" -le 65535 ] || die "LOCAL_PORT 超出 1-65535：$LOCAL_PORT"
case "$EDGE_PORT" in ''|*[!0-9]*) die "EDGE_PORT 必须是数字：$EDGE_PORT" ;; esac
valid_host "$TUNNEL_HOST" || die "TUNNEL_HOST 含非法字符：$TUNNEL_HOST"
valid_host "$EDGE_ADDR" || die "EDGE_ADDR 含非法字符：$EDGE_ADDR"
valid_name "$NODE_NAME" || die "NODE_NAME 不能含引号/反斜杠，且不超过 64 字符"

# ---------- token ----------
if [ -z "$TUNNEL_TOKEN" ] && [ -f "$CF_DIR/token" ]; then
  TUNNEL_TOKEN=$(cat "$CF_DIR/token")
fi
if [ -z "$TUNNEL_TOKEN" ] && [ -t 0 ]; then
  read -rsp "粘贴 Cloudflare 隧道 token，然后回车: " TUNNEL_TOKEN; echo
fi
TUNNEL_TOKEN=$(printf '%s' "$TUNNEL_TOKEN" | tr -d ' \t\r\n')
[ -n "$TUNNEL_TOKEN" ] || die "缺少 TUNNEL_TOKEN（环境变量传入或按提示粘贴）"

cat > "$PARAMS_FILE" <<EOF
SAVED_UUID="$VMESS_UUID"
SAVED_WS_PATH="$WS_PATH"
EOF
chmod 600 "$PARAMS_FILE"
printf '%s' "$TUNNEL_TOKEN" > "$CF_DIR/token"
chmod 600 "$CF_DIR/token"

# ---------- 端口占用检查（覆盖 0.0.0.0 / [::] / 127.0.0.1 任意地址的监听） ----------
if command -v ss >/dev/null 2>&1; then
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$LOCAL_PORT\$"; then
    [ "$(systemctl is-active sing-box-vmess8443 2>/dev/null || true)" = "active" ] \
      || die "本地端口 $LOCAL_PORT 已被其他程序占用"
  fi
else
  log "警告：系统没有 ss 命令，跳过端口占用预检"
fi

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) SB_ARCH=amd64; CF_ARCH=amd64 ;;
  aarch64|arm64) SB_ARCH=arm64; CF_ARCH=arm64 ;;
  *) die "不支持的架构：$ARCH" ;;
esac

# ---------- sing-box（官方 SagerNet 发布） ----------
if ! command -v sing-box >/dev/null 2>&1; then
  # 先走 GitHub API，被限流/失败时退回解析 releases/latest 的 302 跳转
  SB_VER=$(curl -fsSL --max-time 20 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
    | grep -o '"tag_name": *"v[^"]*"' | head -1 | sed 's/.*"v//; s/"$//') || SB_VER=""
  if ! printf '%s' "$SB_VER" | grep -Eq '^[0-9]+(\.[0-9]+)+$'; then
    SB_VER=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 20 \
      "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null | sed 's#.*/tag/v##') || SB_VER=""
  fi
  printf '%s' "$SB_VER" | grep -Eq '^[0-9]+(\.[0-9]+)+$' || die "拿不到 sing-box 版本号（到 GitHub 网络不通或 API 限流，请稍后重试）"
  log "下载 sing-box v$SB_VER ($SB_ARCH) …"
  TMP=$(mktemp -d)
  fetch "https://github.com/SagerNet/sing-box/releases/download/v$SB_VER/sing-box-$SB_VER-linux-$SB_ARCH.tar.gz" "$TMP/sb.tar.gz"
  tar -xzf "$TMP/sb.tar.gz" -C "$TMP"
  install -m 755 "$TMP/sing-box-$SB_VER-linux-$SB_ARCH/sing-box" /usr/local/bin/sing-box
  rm -rf "$TMP"
fi
log "sing-box: $(sing-box version | head -1)"

cat > "$SB_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": $LOCAL_PORT,
      "users": [ { "name": "vmess8443", "uuid": "$VMESS_UUID", "alterId": 0 } ],
      "transport": { "type": "ws", "path": "$WS_PATH" }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
sing-box check -c "$SB_DIR/config.json" || die "sing-box 配置校验失败"

cat > /etc/systemd/system/sing-box-vmess8443.service <<EOF
[Unit]
Description=sing-box VMess node (vmess8443)
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $SB_DIR/config.json
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# ---------- cloudflared（官方发布） ----------
if ! command -v cloudflared >/dev/null 2>&1; then
  log "下载 cloudflared …"
  fetch "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH" /usr/local/bin/cloudflared
  chmod 755 /usr/local/bin/cloudflared
fi
log "cloudflared: $(cloudflared --version 2>/dev/null | head -1)"

# token 优先走 --token-file（不进 unit 文件）；极旧版 cloudflared 不支持时退回 --token，
# 但 token 放 600 权限的 EnvironmentFile，避免明文出现在 644 可读的 unit 里
CF_EXEC_LINE="ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 run --token-file $CF_DIR/token"
CF_ENV_LINE=""
if ! cloudflared tunnel run --help 2>&1 | grep -q -- '--token-file'; then
  printf 'TUNNEL_TOKEN=%s\n' "$TUNNEL_TOKEN" > "$CF_DIR/token.env"
  chmod 600 "$CF_DIR/token.env"
  CF_EXEC_LINE="ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 run --token \$TUNNEL_TOKEN"
  CF_ENV_LINE="EnvironmentFile=$CF_DIR/token.env"
else
  rm -f "$CF_DIR/token.env"
fi

cat > /etc/systemd/system/cloudflared-8443.service <<EOF
[Unit]
Description=cloudflared fixed tunnel (vmess8443)
After=network-online.target sing-box-vmess8443.service
Wants=network-online.target

[Service]
$CF_EXEC_LINE
$CF_ENV_LINE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---------- 启动 ----------
systemctl daemon-reload
systemctl enable sing-box-vmess8443.service cloudflared-8443.service >/dev/null 2>&1 || true
systemctl restart sing-box-vmess8443.service
systemctl restart cloudflared-8443.service

ws_probe() { # ws_probe URL [RESOLVE] -> http_code
  local url="$1" resolve="${2:-}" extra=()
  [ -n "$resolve" ] && extra+=(--resolve "$resolve")
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 ${extra[@]+"${extra[@]}"} "$url" \
    -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Sec-WebSocket-Version: 13' || true
}

log "等待本机 WS 握手…"
ok=""
for _ in $(seq 1 15); do
  [ "$(ws_probe "http://127.0.0.1:$LOCAL_PORT$WS_PATH")" = "101" ] && { ok=1; break; }
  sleep 2
done
[ -n "$ok" ] || { journalctl -u sing-box-vmess8443 -n 20 --no-pager; die "本机 WS 握手失败（应为 101）"; }
log "本机握手 101 OK"

log "等待隧道公网握手（最长约 2 分钟）…"
ok=""
for _ in $(seq 1 24); do
  [ "$(ws_probe "https://$TUNNEL_HOST$WS_PATH")" = "101" ] && { ok=1; break; }
  sleep 5
done
if [ -z "$ok" ]; then
  journalctl -u cloudflared-8443 -n 20 --no-pager || true
  log "警告：公网握手暂未通（隧道注册或 DNS 生效可能还要一会儿），节点链接先照常输出"
fi

# 优选入口完整链路自检：复现客户端真实路径（连 EDGE 地址、SNI/Host 用隧道域名），仅提示不阻断
EDGE_IP=$(getent ahostsv4 "$EDGE_ADDR" 2>/dev/null | awk 'NR==1{print $1}') || EDGE_IP=""
if [ -n "$EDGE_IP" ]; then
  code=$(ws_probe "https://$TUNNEL_HOST:$EDGE_PORT$WS_PATH" "$TUNNEL_HOST:$EDGE_PORT:$EDGE_IP")
  if [ "$code" = "101" ]; then
    log "优选入口 $EDGE_ADDR:$EDGE_PORT 完整链路 101 OK"
  else
    log "提示：优选入口 $EDGE_ADDR:$EDGE_PORT 探测返回 ${code:-超时}（优选 IP 可能临时不通，客户端可换其他优选 IP；隧道本身已验证通过）"
  fi
fi

# ---------- 生成 VMess 链接 ----------
LINK_JSON=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","alpn":""}' \
  "$NODE_NAME" "$EDGE_ADDR" "$EDGE_PORT" "$VMESS_UUID" "$TUNNEL_HOST" "$WS_PATH" "$TUNNEL_HOST")
LINK="vmess://$(printf '%s' "$LINK_JSON" | base64 -w0)"
printf '%s\n' "$LINK" > "$LINK_FILE"
chmod 600 "$LINK_FILE"

echo
echo "================ 部署完成 ================"
systemctl is-active --quiet sing-box-vmess8443 && echo "sing-box-vmess8443: running"
systemctl is-active --quiet cloudflared-8443 && echo "cloudflared-8443:    running"
echo "连接地址: $EDGE_ADDR:$EDGE_PORT  (SNI/Host: $TUNNEL_HOST)"
echo "节点链接（也存在 $LINK_FILE）:"
echo "$LINK"
echo "==========================================="
