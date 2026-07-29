#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_NAME="reality-onekey"
readonly APP_DIR="/etc/${APP_NAME}"
readonly XRAY_DIR="/usr/local/share/xray"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly MANAGER_BIN="/usr/local/bin/reality"
readonly SHORTCUT_BIN="/usr/local/bin/x"
readonly CONFIG_FILE="${APP_DIR}/config.json"
readonly ENV_FILE="${APP_DIR}/node.env"
readonly SYSTEMD_FILE="/etc/systemd/system/${APP_NAME}.service"
readonly OPENRC_FILE="/etc/init.d/${APP_NAME}"
readonly RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly SCRIPT_URL="https://raw.githubusercontent.com/colaxr/reality-onekey/main/reality.sh"

OS=""
ARCH=""
INIT=""
PKG=""
SERVICE_GROUP=""

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
die() { red "错误：$*"; exit 1; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行。"
}

detect_system() {
  [[ -r /etc/os-release ]] || die "无法识别操作系统。"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) OS="$ID"; PKG="apt"; SERVICE_GROUP="nogroup" ;;
    alpine) OS="alpine"; PKG="apk"; SERVICE_GROUP="nobody" ;;
    *) die "仅支持 Debian、Ubuntu 和 Alpine（当前：${ID:-unknown}）。" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ARCH="64" ;;
    aarch64|arm64) ARCH="arm64-v8a" ;;
    *) die "仅支持 AMD64/x86_64 和 ARM64/aarch64（当前：$(uname -m)）。" ;;
  esac
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    INIT="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    INIT="openrc"
  else
    die "未检测到 systemd 或 OpenRC。"
  fi
}

install_dependencies() {
  if [[ "$PKG" == "apt" ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip ca-certificates openssl libcap2-bin
  else
    apk add --no-cache curl unzip ca-certificates openssl libcap
  fi
}

prompt() {
  local label="$1" default="${2:-}" value
  if [[ -n "$default" ]]; then
    read -r -p "${label} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "${label}: " value
    printf '%s' "$value"
  fi
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

validate_domain() {
  [[ "$1" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]
}

validate_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

validate_short_id() {
  [[ "$1" =~ ^([0-9a-fA-F]{2}){1,8}$ ]]
}

validate_server_address() {
  [[ -n "$1" && "$1" =~ ^[A-Za-z0-9.::_-]+$ ]]
}

public_ip() {
  curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null ||
    curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true
}

download_xray() {
  local tmp version url
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "${tmp:-}"' RETURN
  version="$(curl -fsSL "$RELEASE_API" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$version" ]] || die "无法获取 Xray 最新版本。"
  url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${ARCH}.zip"
  info "下载 Xray ${version} (${ARCH})..."
  curl -fL --retry 3 -o "${tmp}/xray.zip" "$url"
  unzip -oq "${tmp}/xray.zip" -d "$tmp"
  install -Dm755 "${tmp}/xray" "$XRAY_BIN"
  setcap cap_net_bind_service=+ep "$XRAY_BIN"
  install -d "$XRAY_DIR"
  [[ -f "${tmp}/geoip.dat" ]] && install -m644 "${tmp}/geoip.dat" "${XRAY_DIR}/geoip.dat"
  [[ -f "${tmp}/geosite.dat" ]] && install -m644 "${tmp}/geosite.dat" "${XRAY_DIR}/geosite.dat"
  rm -rf -- "$tmp"
  trap - RETURN
  "$XRAY_BIN" version | head -n1
}

make_service() {
  if [[ "$INIT" == "systemd" ]]; then
    cat >"$SYSTEMD_FILE" <<EOF
[Unit]
Description=REALITY One-key Xray Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=${XRAY_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$APP_NAME"
  else
    touch "/var/log/${APP_NAME}.log" "/var/log/${APP_NAME}.err"
    chown nobody:nobody "/var/log/${APP_NAME}.log" "/var/log/${APP_NAME}.err"
    cat >"$OPENRC_FILE" <<EOF
#!/sbin/openrc-run
name="REALITY One-key Xray Service"
command="${XRAY_BIN}"
command_args="run -c ${CONFIG_FILE}"
command_user="nobody"
command_background="yes"
pidfile="/run/${APP_NAME}.pid"
output_log="/var/log/${APP_NAME}.log"
error_log="/var/log/${APP_NAME}.err"
depend() { need net; }
EOF
    chmod 755 "$OPENRC_FILE"
    rc-update add "$APP_NAME" default
    rc-service "$APP_NAME" restart
  fi
}

service_stop() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl disable --now "$APP_NAME" 2>/dev/null || true
  else
    rc-service "$APP_NAME" stop 2>/dev/null || true
    rc-update del "$APP_NAME" default 2>/dev/null || true
  fi
}

service_restart() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl restart "$APP_NAME"
  else
    rc-service "$APP_NAME" restart
  fi
}

service_status() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl --no-pager --full status "$APP_NAME" || true
  else
    rc-service "$APP_NAME" status || true
  fi
}

remove_node_files() {
  service_stop
  rm -f -- "$SYSTEMD_FILE" "$OPENRC_FILE"
  rm -rf -- "$APP_DIR"
  rm -f -- "/var/log/${APP_NAME}.log" "/var/log/${APP_NAME}.err" "/run/${APP_NAME}.pid"
  [[ "$INIT" == "systemd" ]] && systemctl daemon-reload
}

delete_node() {
  local answer="${1:-}"
  [[ -e "$CONFIG_FILE" || -e "$SYSTEMD_FILE" || -e "$OPENRC_FILE" ]] ||
    { yellow "未发现已安装的节点。"; return; }
  if [[ "$answer" != "--yes" ]]; then
    read -r -p "将删除当前节点配置和服务，但保留 Xray 与管理命令，确定吗？[y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { yellow "已取消。"; return; }
  fi
  remove_node_files
  green "已删除当前节点；Xray 和 reality 管理命令仍保留。"
}

write_config() {
  local port="$1" uuid="$2" domain="$3" dest="$4" private_key="$5" public_key="$6"
  local short_id="$7" server_ip="$8"
  install -d -m700 "$APP_DIR"
  cat >"$CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": ${port},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "${dest}",
        "xver": 0,
        "serverNames": ["${domain}"],
        "privateKey": "${private_key}",
        "shortIds": ["${short_id}"]
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": true
    }
  }],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
  chmod 600 "$CONFIG_FILE"
  cat >"$ENV_FILE" <<EOF
SERVER_IP='${server_ip}'
PORT='${port}'
UUID='${uuid}'
SNI='${domain}'
DEST='${dest}'
PUBLIC_KEY='${public_key}'
SHORT_ID='${short_id}'
FLOW='xtls-rprx-vision'
FINGERPRINT='chrome'
EOF
  chmod 600 "$ENV_FILE"
  chown root:"$SERVICE_GROUP" "$APP_DIR" "$CONFIG_FILE"
  chmod 750 "$APP_DIR"
  chmod 640 "$CONFIG_FILE"
}

install_reality() {
  local port domain dest uuid keys private_key public_key short_id server_ip
  install_dependencies
  if [[ "$(readlink -f "$0" 2>/dev/null || true)" != "$MANAGER_BIN" ]]; then
    install -Dm755 "$0" "$MANAGER_BIN"
  fi
  ln -sf "$MANAGER_BIN" "$SHORTCUT_BIN"
  download_xray

  port="$(prompt "监听端口" "443")"
  validate_port "$port" || die "端口必须是 1-65535 的整数。"
  domain="$(prompt "伪装域名（支持 TLS 1.3，勿填自己的域名）" "www.microsoft.com")"
  validate_domain "$domain" || die "伪装域名格式不正确。"
  dest="$(prompt "目标地址" "${domain}:443")"
  [[ "$dest" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "目标地址格式应为 域名:端口。"
  server_ip="$(prompt "服务器公网 IP/域名" "$(public_ip)")"
  validate_server_address "$server_ip" || die "服务器地址格式不正确。"

  uuid="$("$XRAY_BIN" uuid)"
  keys="$("$XRAY_BIN" x25519)"
  private_key="$(printf '%s\n' "$keys" | awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$keys" | awk -F': ' 'tolower($1) ~ /(public|password)/ {print $2; exit}')"
  [[ -n "$private_key" && -n "$public_key" ]] || die "生成 REALITY 密钥失败。"
  short_id="$(openssl rand -hex 8)"
  write_config "$port" "$uuid" "$domain" "$dest" "$private_key" "$public_key" "$short_id" "$server_ip"
  "$XRAY_BIN" run -test -c "$CONFIG_FILE"
  make_service
  green "安装完成。请确认云防火墙/安全组已放行 TCP ${port}。"
  show_node
}

load_node() {
  if [[ ! -r "$ENV_FILE" ]]; then
    yellow "尚未安装或节点配置不存在。"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

show_node() {
  load_node || return 1
  local host link
  host="$SERVER_IP"
  [[ "$host" == *:* && "$host" != \[*\] ]] && host="[${host}]"
  link="vless://${UUID}@${host}:${PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#REALITY-${SERVER_IP}"
  printf '\n节点信息\n'
  printf '服务器：%s\n端口：%s\nUUID：%s\nSNI：%s\nPublic Key：%s\nShort ID：%s\n\n' \
    "$SERVER_IP" "$PORT" "$UUID" "$SNI" "$PUBLIC_KEY" "$SHORT_ID"
  green "$link"
}

edit_node() {
  load_node || return 1
  local server_ip port uuid domain dest short_id private_key
  local backup_config backup_env
  private_key="$(sed -n 's/.*"privateKey":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | head -n1)"
  if [[ -z "$private_key" ]]; then
    yellow "无法读取现有 REALITY 私钥，配置未修改。"
    return 1
  fi

  server_ip="$(prompt "服务器公网 IP/域名" "$SERVER_IP")"
  validate_server_address "$server_ip" || { yellow "服务器地址格式不正确。"; return 1; }
  port="$(prompt "监听端口" "$PORT")"
  validate_port "$port" || { yellow "端口必须是 1-65535 的整数。"; return 1; }
  uuid="$(prompt "UUID" "$UUID")"
  validate_uuid "$uuid" || { yellow "UUID 格式不正确。"; return 1; }
  domain="$(prompt "伪装域名（SNI）" "$SNI")"
  validate_domain "$domain" || { yellow "伪装域名格式不正确。"; return 1; }
  dest="$(prompt "目标地址" "$DEST")"
  [[ "$dest" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] ||
    { yellow "目标地址格式应为 域名:端口。"; return 1; }
  short_id="$(prompt "Short ID" "$SHORT_ID")"
  validate_short_id "$short_id" ||
    { yellow "Short ID 必须是 2-16 位偶数长度的十六进制字符。"; return 1; }

  backup_config="$(mktemp)"
  backup_env="$(mktemp)"
  cp "$CONFIG_FILE" "$backup_config"
  cp "$ENV_FILE" "$backup_env"
  write_config "$port" "$uuid" "$domain" "$dest" "$private_key" "$PUBLIC_KEY" "$short_id" "$server_ip"
  if ! "$XRAY_BIN" run -test -c "$CONFIG_FILE"; then
    cp "$backup_config" "$CONFIG_FILE"
    cp "$backup_env" "$ENV_FILE"
    rm -f -- "$backup_config" "$backup_env"
    yellow "新配置校验失败，已恢复原配置。"
    return 1
  fi
  rm -f -- "$backup_config" "$backup_env"
  service_restart
  green "节点配置已修改并重启。请确认已放行 TCP ${port}。"
  show_node
}

uninstall_reality() {
  local answer="${1:-}"
  if [[ "$answer" != "--yes" ]]; then
    read -r -p "将完全删除 Xray、REALITY 配置、服务和日志，确定吗？[y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { yellow "已取消。"; return; }
  fi
  remove_node_files
  rm -f -- "$XRAY_BIN" "$SHORTCUT_BIN" "$MANAGER_BIN"
  rm -rf -- "$XRAY_DIR"
  green "已完全卸载 REALITY One-key。"
  exit 0
}

update_xray() {
  [[ -r "$CONFIG_FILE" ]] || die "请先安装。"
  download_xray
  "$XRAY_BIN" run -test -c "$CONFIG_FILE"
  service_restart
  green "Xray 已更新并重启。"
}

update_script() {
  local tmp
  if ! command -v curl >/dev/null 2>&1; then
    yellow "缺少 curl，无法更新管理脚本。"
    return 1
  fi
  tmp="$(mktemp)"
  if ! curl -fL --retry 3 -o "$tmp" "${SCRIPT_URL}?t=$(date +%s)"; then
    rm -f -- "$tmp"
    yellow "下载最新版管理脚本失败，当前版本未被修改。"
    return 1
  fi
  if ! bash -n "$tmp"; then
    rm -f -- "$tmp"
    yellow "最新版脚本语法检查失败，当前版本未被修改。"
    return 1
  fi
  install -m755 "$tmp" "$MANAGER_BIN"
  rm -f -- "$tmp"
  ln -sf "$MANAGER_BIN" "$SHORTCUT_BIN"
  green "管理脚本已更新到最新版，正在重新打开菜单。"
  exec "$MANAGER_BIN" menu </dev/tty
}

menu() {
  while true; do
    printf '\nREALITY 一键管理脚本\n'
    printf '1. 安装/重新配置\n2. 修改节点配置\n3. 查询节点\n4. 查看服务状态\n5. 更新 Xray\n6. 更新管理脚本\n7. 删除已安装节点\n8. 完全卸载\n0. 退出\n'
    read -r -p "请选择 [0-8]: " choice
    case "$choice" in
      1) install_reality ;;
      2) edit_node || true ;;
      3) show_node || true ;;
      4) service_status ;;
      5) update_xray ;;
      6) update_script || true ;;
      7) delete_node ;;
      8) uninstall_reality ;;
      0) exit 0 ;;
      *) yellow "无效选项。" ;;
    esac
  done
}

main() {
  require_root
  if [[ ! -t 0 ]]; then
    exec </dev/tty || die "无法连接交互终端，请直接运行：sudo /usr/local/bin/reality"
  fi
  detect_system
  case "${1:-menu}" in
    install) install_reality ;;
    edit) edit_node ;;
    show) show_node ;;
    status) service_status ;;
    update) update_xray ;;
    self-update) update_script ;;
    remove-node) delete_node "${2:-}" ;;
    uninstall) uninstall_reality "${2:-}" ;;
    menu) menu ;;
    -h|--help)
      printf '用法: %s [install|edit|show|status|update|self-update|remove-node [--yes]|uninstall [--yes]|menu]\n' "$0"
      ;;
    *) die "未知命令：$1" ;;
  esac
}

main "$@"
