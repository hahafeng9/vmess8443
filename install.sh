#!/usr/bin/env bash
# vmess8443 — 一键部署 VMess+WS 节点 + Cloudflare 隧道（固定/随机二选一）
#
# 固定隧道（默认）：客户端 → 优选域名 cf.877774.xyz:8443 → CF 固定隧道 → 本机 127.0.0.1:18001
# 随机隧道：客户端 → 随机域名 xxx.trycloudflare.com:443 → CF 临时隧道 → 本机 127.0.0.1:18001
#   （免 token，但 cloudflared 重启后域名会变；重跑本脚本可刷新链接且不会重启在跑的隧道）
#
# 用法（root 运行）：
#   固定: TUNNEL_TOKEN='隧道token' TUNNEL_HOST='隧道域名' VMESS_UUID='uuid' WS_PATH='/vmess-xxxx' bash install.sh
#   随机: TUNNEL_MODE=quick bash install.sh
# TUNNEL_HOST 是你建固定隧道时 Public Hostname 的完整域名（默认 vmess251.fengco.tech），
# 会写进 VMess 链接的 Host/SNI，必须和 Cloudflare 面板里配的一致。
# 参数都可省略：token 没给会在终端里提示粘贴；UUID/路径没给会随机生成并保存，
# 重跑脚本时自动复用同一套参数与上次模式（幂等）。
#
# 卸载：bash install.sh --uninstall （只删本脚本装的服务与配置，二进制保留）
#
# 装两个 systemd 服务：sing-box-vmess8443、cloudflared-8443。不动系统里其他服务与配置。
set -euo pipefail

TUNNEL_MODE="${TUNNEL_MODE:-}"
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
QUICK_DOMAIN_FILE="$APP_DIR/quick-domain.txt"

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
TUNNEL_MODE="${TUNNEL_MODE:-${SAVED_TUNNEL_MODE:-fixed}}"
case "$TUNNEL_MODE" in
  fixed|quick) ;;
  *) die "TUNNEL_MODE 只支持 fixed（固定隧道）或 quick（随机隧道）：$TUNNEL_MODE" ;;
esac
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

# ---------- token（仅固定隧道需要） ----------
if [ "$TUNNEL_MODE" = "fixed" ]; then
  if [ -z "$TUNNEL_TOKEN" ] && [ -f "$CF_DIR/token" ]; then
    TUNNEL_TOKEN=$(cat "$CF_DIR/token")
  fi
  if [ -z "$TUNNEL_TOKEN" ] && [ -t 0 ]; then
    read -rsp "粘贴 Cloudflare 隧道 token，然后回车: " TUNNEL_TOKEN; echo
  fi
  TUNNEL_TOKEN=$(printf '%s' "$TUNNEL_TOKEN" | tr -d ' \t\r\n')
  [ -n "$TUNNEL_TOKEN" ] || die "固定隧道缺少 TUNNEL_TOKEN（环境变量传入或按提示粘贴；免 token 用 TUNNEL_MODE=quick）"
  printf '%s' "$TUNNEL_TOKEN" > "$CF_DIR/token"
  chmod 600 "$CF_DIR/token"
fi

# 从 token 解出本隧道 ID（DNS 自愈与诊断提示用）
TUNNEL_ID=""
if [ "$TUNNEL_MODE" = "fixed" ]; then
  TUNNEL_ID=$(printf '%s' "$TUNNEL_TOKEN" | base64 -d 2>/dev/null | grep -oE '"t":"[0-9a-f-]{36}"' | cut -d'"' -f4) || TUNNEL_ID=""
fi

# ---------- DNS 自愈（可选）：安装命令带 CF_API_TOKEN 时自动清理同名旧记录并指到本隧道 ----------
# 背景：同名旧隧道记录（旧"隧道"记录 / 手工 CNAME）会挡住 Public Hostname 的 DNS 自动创建，
# 导致边缘把流量路由进旧隧道而报 530/1033。有 token 就自动对齐，没有则只在出问题时打印手工修复指引。
# CF_API_TOKEN 需要：Zone.Zone 读取 + Zone.DNS 编辑 权限。
if [ "$TUNNEL_MODE" = "fixed" ] && [ -n "$TUNNEL_ID" ] && [ -n "${CF_API_TOKEN:-}" ]; then
  ZONE_NAME="${TUNNEL_HOST#*.}"
  log "DNS 自愈：检查 $ZONE_NAME 里 $TUNNEL_HOST 指向是否为本隧道 $TUNNEL_ID …"
  CF_API_TOKEN="${CF_API_TOKEN}" python3 - "$ZONE_NAME" "$TUNNEL_HOST" "$TUNNEL_ID" <<'PYDNS' || log "警告：DNS 自愈失败（见上方输出），可按提示手动修复后重跑本脚本"
import json, os, sys, urllib.request, urllib.parse
zone_name, hostname, tunnel_id = sys.argv[1], sys.argv[2], sys.argv[3]
token = os.environ["CF_API_TOKEN"]
BASE = "https://api.cloudflare.com/client/v4"

def api(method, path, data=None):
    req = urllib.request.Request(
        BASE + path, method=method,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        data=json.dumps(data).encode() if data is not None else None)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)

try:
    z = api("GET", "/zones?name=" + urllib.parse.quote(zone_name))
    if not z.get("success") or not z.get("result"):
        print("  找不到 zone " + zone_name + "（token 无效、权限不足或域名不在本账号）")
        sys.exit(1)
    zid = z["result"][0]["id"]
    target = tunnel_id + ".cfargotunnel.com"
    recs = api("GET", "/zones/" + zid + "/dns_records?name=" + urllib.parse.quote(hostname) + "&per_page=100")
    if not recs.get("success"):
        print("  拉取 DNS 记录失败: " + json.dumps(recs.get("errors", [])[:1]))
        sys.exit(1)
    good = False
    for r in recs["result"]:
        if r.get("type") == "CNAME" and r.get("content") == target:
            good = True
            if not r.get("proxied"):
                api("PATCH", "/zones/" + zid + "/dns_records/" + r["id"], {"proxied": True})
                print("  已为正确记录开启橙云代理")
        else:
            api("DELETE", "/zones/" + zid + "/dns_records/" + r["id"])
            print("  已删除同名旧记录: " + r.get("type", "?") + " " + str(r.get("content", "?"))[:70])
    if not good:
        api("POST", "/zones/" + zid + "/dns_records",
            {"type": "CNAME", "name": hostname, "content": target, "proxied": True, "comment": "vmess8443 auto"})
        print("  已创建: " + hostname + " -> " + target + "（已代理）")
    else:
        print("  记录已正确指向本隧道: " + hostname + " -> " + target)
    print("  DNS 自愈完成")
except Exception as e:
    print("  API 错误: " + str(e))
    sys.exit(1)
PYDNS
fi

cat > "$PARAMS_FILE" <<EOF
SAVED_UUID="$VMESS_UUID"
SAVED_WS_PATH="$WS_PATH"
SAVED_TUNNEL_MODE="$TUNNEL_MODE"
EOF
chmod 600 "$PARAMS_FILE"

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

if [ "$TUNNEL_MODE" = "fixed" ]; then
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
else
  # 随机隧道：免 token，cloudflared 自行注册临时域名（日志里会打印 trycloudflare.com 域名）
  CF_EXEC_LINE="ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 --url http://127.0.0.1:$LOCAL_PORT"
  CF_ENV_LINE=""
fi

NEW_CF_UNIT="$(cat <<EOF
[Unit]
Description=cloudflared $TUNNEL_MODE tunnel (vmess8443)
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
)"
CF_UNIT_FILE="/etc/systemd/system/cloudflared-8443.service"
OLD_CF_UNIT=""
if [ -f "$CF_UNIT_FILE" ]; then OLD_CF_UNIT=$(cat "$CF_UNIT_FILE"); fi
printf '%s\n' "$NEW_CF_UNIT" > "$CF_UNIT_FILE"

# quick 模式下：隧道已在跑且 unit 内容没变 → 不重启，保住当前随机域名
CF_NEED_RESTART=1
if [ "$TUNNEL_MODE" = "quick" ] && [ -n "$OLD_CF_UNIT" ] && [ "$OLD_CF_UNIT" = "$NEW_CF_UNIT" ] \
   && systemctl is-active --quiet cloudflared-8443 2>/dev/null; then
  CF_NEED_RESTART=0
  log "随机隧道已在运行且配置未变，保留当前域名不重启"
fi

# ---------- 启动 ----------
systemctl daemon-reload
systemctl enable sing-box-vmess8443.service cloudflared-8443.service >/dev/null 2>&1 || true
systemctl restart sing-box-vmess8443.service
if [ "$CF_NEED_RESTART" = "1" ]; then
  systemctl restart cloudflared-8443.service
fi

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

# ---------- 隧道域名：quick 从日志抓随机域名，fixed 用固定域名 ----------
if [ "$TUNNEL_MODE" = "quick" ]; then
  log "等待随机隧道域名（最长约 1 分钟）…"
  PUB_DOMAIN=""
  for _ in $(seq 1 12); do
    PUB_DOMAIN=$(journalctl -u cloudflared-8443 --no-pager -n 300 2>/dev/null \
      | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' | tail -1 | sed 's#https://##') || PUB_DOMAIN=""
    [ -n "$PUB_DOMAIN" ] && break
    sleep 5
  done
  if [ -z "$PUB_DOMAIN" ]; then
    journalctl -u cloudflared-8443 -n 30 --no-pager || true
    die "没拿到随机隧道域名（检查本机到 Cloudflare 边缘的网络；要固定域名用 TUNNEL_MODE=fixed）"
  fi
  printf '%s\n' "$PUB_DOMAIN" > "$QUICK_DOMAIN_FILE"
  PUB_HOST="$PUB_DOMAIN"
  log "随机域名: $PUB_DOMAIN"
else
  PUB_HOST="$TUNNEL_HOST"
fi

log "等待隧道公网握手（最长约 2 分钟）…"
ok=""
for _ in $(seq 1 24); do
  [ "$(ws_probe "https://$PUB_HOST$WS_PATH")" = "101" ] && { ok=1; break; }
  sleep 5
done
if [ -z "$ok" ]; then
  journalctl -u cloudflared-8443 -n 20 --no-pager || true
  # 识别 Cloudflare 边缘错误码，给针对性提示（边缘 5xx 响应体带 "error code: 10xx"）
  CF_ERR=$(curl -s --max-time 8 "https://$PUB_HOST$WS_PATH" 2>/dev/null | grep -oE 'error code: [0-9]+' | head -1) || CF_ERR=""
  case "$CF_ERR" in
    *"1033"*)
      log "警告：公网 530/1033 —— 域名 $PUB_HOST 的 DNS 记录没有指向本隧道（多为同名旧记录残留），本机隧道本身是通的。"
      log "  本隧道 ID: ${TUNNEL_ID:-（token 解析失败，去 CF 面板 Tunnels 列表查看）}"
      log "  修复①：CF 面板 → 域名 → DNS → 记录 → 删掉 $PUB_HOST 的其他同名记录，把 CNAME 内容改为 ${TUNNEL_ID:-<本隧道ID>}.cfargotunnel.com（橙云开启）"
      log "  修复②：或删旧记录后到 Zero Trust → Tunnels → 本隧道 → Public Hostname 重新保存一次让其自动重建"
      log "  下次安装命令带 CF_API_TOKEN='...'（需 Zone.DNS 编辑权限）即可让脚本自动修复"
      ;;
    *"1001"*)
      log "警告：公网 530/1001 —— $PUB_HOST 在 DNS 里没有记录。到 Zero Trust → Tunnels → Public Hostname 重新保存一次让其自动创建。"
      ;;
    "")
      log "警告：公网握手暂未通（隧道注册或 DNS 生效可能还要一会儿），节点链接先照常输出"
      ;;
    *)
      log "警告：公网握手暂未通（Cloudflare 边缘返回 $CF_ERR），节点链接先照常输出"
      ;;
  esac
fi

if [ "$TUNNEL_MODE" = "fixed" ]; then
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
fi

# ---------- 生成 VMess 链接 ----------
if [ "$TUNNEL_MODE" = "quick" ]; then
  LINK_ADD="$PUB_DOMAIN"; LINK_PORT="443"; LINK_HOST="$PUB_DOMAIN"
else
  LINK_ADD="$EDGE_ADDR"; LINK_PORT="$EDGE_PORT"; LINK_HOST="$TUNNEL_HOST"
fi
LINK_JSON=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"tls","sni":"%s","alpn":""}' \
  "$NODE_NAME" "$LINK_ADD" "$LINK_PORT" "$VMESS_UUID" "$LINK_HOST" "$WS_PATH" "$LINK_HOST")
LINK="vmess://$(printf '%s' "$LINK_JSON" | base64 -w0)"
printf '%s\n' "$LINK" > "$LINK_FILE"
chmod 600 "$LINK_FILE"

echo
echo "================ 部署完成 ================"
systemctl is-active --quiet sing-box-vmess8443 && echo "sing-box-vmess8443: running"
systemctl is-active --quiet cloudflared-8443 && echo "cloudflared-8443:    running"
if [ "$TUNNEL_MODE" = "quick" ]; then
  echo "模式:   随机隧道（trycloudflare.com 临时域名，cloudflared 重启后域名会变）"
  echo "刷新:   重跑本脚本即可刷新链接（不会重启在跑的隧道，域名保持不变）"
else
  echo "模式:   固定隧道"
fi
echo "连接地址: $LINK_ADD:$LINK_PORT  (SNI/Host: $LINK_HOST)"
echo "节点链接（也存在 $LINK_FILE）:"
echo "$LINK"
echo "==========================================="
