#!/usr/bin/env bash
set -Eeuo pipefail

readonly APP_NAME="reality-onekey"
readonly ROOT_PREFIX="${REALITY_ROOT_PREFIX:-}"
readonly PROC_ROOT="${REALITY_PROC_ROOT:-/proc}"
readonly APP_DIR="${ROOT_PREFIX}/etc/${APP_NAME}"
readonly XRAY_DIR="${ROOT_PREFIX}/usr/local/share/xray"
readonly XRAY_BIN="${ROOT_PREFIX}/usr/local/bin/xray"
readonly MANAGER_BIN="${ROOT_PREFIX}/usr/local/bin/reality"
readonly SHORTCUT_BIN="${ROOT_PREFIX}/usr/local/bin/x"
readonly CONFIG_FILE="${APP_DIR}/config.json"
readonly ENV_FILE="${APP_DIR}/node.env"
readonly SS_ENV_FILE="${APP_DIR}/ss.env"
readonly SOCKS_ENV_FILE="${APP_DIR}/socks.env"
readonly SOCKS_NAME="reality-onekey-socks"
readonly SOCKS_DIR="${ROOT_PREFIX}/etc/${SOCKS_NAME}"
readonly SOCKS_CONFIG="${SOCKS_DIR}/config.yml"
readonly SOCKS_BIN="${ROOT_PREFIX}/usr/local/bin/reality-socks5"
readonly SOCKS_SYSTEMD="${ROOT_PREFIX}/etc/systemd/system/${SOCKS_NAME}.service"
readonly SOCKS_OPENRC="${ROOT_PREFIX}/etc/init.d/${SOCKS_NAME}"
readonly SOCKS_VERSION="2.13.1"
readonly SYSTEMD_FILE="${ROOT_PREFIX}/etc/systemd/system/${APP_NAME}.service"
readonly OPENRC_FILE="${ROOT_PREFIX}/etc/init.d/${APP_NAME}"
readonly RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly SCRIPT_API_URL="https://api.github.com/repos/colaxr/reality-onekey/contents/reality.sh?ref=main"
readonly MIN_CLIENT_VERSION="1.0.0"

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
    debian|ubuntu) PKG="apt"; SERVICE_GROUP="nogroup" ;;
    alpine) PKG="apk"; SERVICE_GROUP="nobody" ;;
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
  local -a missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  if ! command -v setcap >/dev/null 2>&1; then
    if [[ "$PKG" == apt ]]; then missing+=(libcap2-bin); else missing+=(libcap); fi
  fi
  if (( ${#missing[@]} == 0 )); then
    info "依赖已齐全，跳过软件源更新和依赖安装。"
    return 0
  fi
  info "仅安装缺少的依赖：${missing[*]}"
  if [[ "$PKG" == "apt" ]]; then
    # Avoid persistent binary caches and translation indexes on small machines.
    local -a apt_options=(-o 'Dir::Cache::pkgcache=' -o 'Dir::Cache::srcpkgcache=' -o 'Acquire::Languages=none')
    apt-get "${apt_options[@]}" update &&
      DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" install -y --no-install-recommends "${missing[@]}" && return 0
  else
    apk add --no-cache "${missing[@]}" && return 0
  fi
  yellow "依赖安装失败。若出现 Killed，请检查内存/cgroup 限制及 Swap；依赖安装完成前无法继续。"
  return 1
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

prompt_yes_no() {
  local label="$1" default="${2:-true}" value hint
  if [[ "$default" == "true" ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi
  while true; do
    read -r -p "${label} [${hint}]: " value
    if [[ -z "$value" ]]; then
      printf '%s' "$default"
      return 0
    fi
    case "$value" in
      y|Y|yes|YES|Yes) printf 'true'; return 0 ;;
      n|N|no|NO|No) printf 'false'; return 0 ;;
      *) yellow "请输入 y 或 n。" >&2 ;;
    esac
  done
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

validate_fingerprint() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]
}

validate_node_name() {
  [[ -n "$1" && ${#1} -le 64 && "$1" != *"'"* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

validate_ss_method() {
  case "$1" in
    aes-256-gcm|aes-128-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305) return 0 ;;
    *) return 1 ;;
  esac
}

validate_password() {
  [[ -n "$1" && ${#1} -le 256 && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

base64_encode() {
  printf '%s' "$1" | openssl base64 -A
}

base64_decode() {
  printf '%s' "$1" | openssl base64 -d -A
}

base64url_encode() {
  base64_encode "$1" | tr '+/' '-_' | tr -d '='
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\t'/\\t}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  printf '%s' "$value"
}

urlencode() {
  local LC_ALL=C value="$1" output="" char hex index
  for ((index = 0; index < ${#value}; index++)); do
    char="${value:index:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) output+="$char" ;;
      *)
        printf -v hex '%02X' "'$char"
        output+="%${hex}"
        ;;
    esac
  done
  printf '%s' "$output"
}

validate_server_address() {
  [[ -n "$1" && "$1" =~ ^[A-Za-z0-9.::_-]+$ ]]
}

public_ip() {
  curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null ||
    curl -6fsS --max-time 8 https://api64.ipify.org 2>/dev/null || true
}

download_xray() {
  local tmp version="${1:-}" url
  # /tmp may be tmpfs; keep the archive and extracted files under /var/tmp.
  tmp="$(mktemp -d /var/tmp/reality-download.XXXXXX)" || return 1
  if [[ -z "$version" ]]; then
    version="$(curl -fsSL "$RELEASE_API" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)" ||
      { rm -rf -- "$tmp"; return 1; }
  fi
  [[ "$version" =~ ^v[0-9]+([.][0-9]+){1,3}([._-][A-Za-z0-9.-]+)?$ ]] ||
    { rm -rf -- "$tmp"; yellow "无效的 Xray 版本号：${version}"; return 1; }
  url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${ARCH}.zip"
  info "下载 Xray ${version} (${ARCH})..."
  curl -fL --retry 3 -o "${tmp}/xray.zip" "$url" ||
    { rm -rf -- "$tmp"; return 1; }
  unzip -oq "${tmp}/xray.zip" -d "$tmp" ||
    { rm -rf -- "$tmp"; return 1; }
  install -Dm755 "${tmp}/xray" "$XRAY_BIN" ||
    { rm -rf -- "$tmp"; return 1; }
  setcap cap_net_bind_service=+ep "$XRAY_BIN" ||
    { rm -rf -- "$tmp"; return 1; }
  install -d "$XRAY_DIR" ||
    { rm -rf -- "$tmp"; return 1; }
  [[ -f "${tmp}/geoip.dat" ]] && install -m644 "${tmp}/geoip.dat" "${XRAY_DIR}/geoip.dat"
  [[ -f "${tmp}/geosite.dat" ]] && install -m644 "${tmp}/geosite.dat" "${XRAY_DIR}/geosite.dat"
  rm -rf -- "$tmp"
  # Read the complete output so pipefail cannot turn head's early pipe close
  # into a false installation failure (Xray prints two version lines).
  "$XRAY_BIN" version | sed -n '1p'
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
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || return 1
    systemctl enable "$APP_NAME" || return 1
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
    rc-update add "$APP_NAME" default || return 1
  fi
  service_restart
}

service_stop() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl disable --now "$APP_NAME" 2>/dev/null || true
  else
    rc-service "$APP_NAME" stop 2>/dev/null || true
    rc-update del "$APP_NAME" default 2>/dev/null || true
  fi
}

restore_config_permissions() {
  [[ -d "$APP_DIR" && -f "$CONFIG_FILE" ]] || return 1
  chown root:"$SERVICE_GROUP" "$APP_DIR" "$CONFIG_FILE" || return 1
  chmod 750 "$APP_DIR" || return 1
  chmod 640 "$CONFIG_FILE" || return 1
  local file
  for file in "$ENV_FILE" "$SS_ENV_FILE" "$SOCKS_ENV_FILE"; do
    [[ -f "$file" ]] || continue
    chown root:root "$file" && chmod 600 "$file" || return 1
  done
}

service_restart() {
  restore_config_permissions || {
    yellow "无法恢复配置读取权限，未重启服务。"
    return 1
  }
  if [[ "$INIT" == "systemd" ]]; then
    systemctl restart "$APP_NAME" || return 1
  else
    rc-service "$APP_NAME" restart || return 1
  fi
  verify_service
}

# Match a socket to the managed PID, not another process on the same port.
service_socket() {
  local pid="$1" port="$2" state="$3" fd socket inode hex
  local denied=false fd_error=""
  shift 3
  printf -v hex '%04X' "$port"
  for fd in "$PROC_ROOT/$pid/fd/"*; do
    # GNU readlink suppresses errors by default; -v is required to detect EACCES.
    if socket="$(LC_ALL=C readlink -v "$fd" 2>&1)"; then
      :
    else
      fd_error="$socket"
      case "$socket" in
        *"Permission denied"*|*"Operation not permitted"*) denied=true ;;
      esac
      continue
    fi
    [[ "$socket" == socket:\[*\] ]] || continue
    inode="${socket#socket:[}"
    inode="${inode%]}"
    if awk -v port="$hex" -v inode="$inode" -v state="$state" '
      $4 == state && $10 == inode && $2 ~ (":" port "$") { found=1 }
      END { exit !found }
    ' "$@" 2>/dev/null; then
      return 0
    fi
  done
  # Some containers deny root access to some or all of another user's fd
  # symlinks. Fully readable hosts still require the inode ownership match.
  if [[ "$denied" == true ]] &&
     awk -v port="$hex" -v state="$state" '
       $4 == state && $2 ~ (":" port "$") { found=1 }
       END { exit !found }
     ' "$@" 2>/dev/null; then
    SERVICE_FALLBACK_USED=true
    return 0
  fi
  SERVICE_CHECK_REASON="PID=${pid}，端口=${port}，监听状态=${state}：未确认监听归属；fd 权限受限=${denied}；readlink=${fd_error:-无错误}"
  return 1
}

service_listening() {
  service_socket "$1" "$2" 0A "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/tcp6"
}

service_udp_listening() {
  service_socket "$1" "$2" 07 "$PROC_ROOT/net/udp" "$PROC_ROOT/net/udp6"
}

managed_listeners() {
  if [[ -r "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    validate_port "${PORT:-}" || return 1
    printf 'tcp %s\n' "$PORT"
  fi
  if [[ -r "$SS_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$SS_ENV_FILE"
    validate_port "${SS_PORT:-}" || return 1
    printf 'tcp %s\nudp %s\n' "$SS_PORT" "$SS_PORT"
  fi
  if [[ -r "$SOCKS_ENV_FILE" ]] && ! socks_is_independent; then
    # shellcheck disable=SC1090
    . "$SOCKS_ENV_FILE"
    validate_port "${SOCKS_PORT:-}" || return 1
    printf 'tcp %s\nudp %s\n' "$SOCKS_PORT" "$SOCKS_PORT"
  fi
}

service_has_all_listeners() {
  local pid="$1" protocol port found=false
  while read -r protocol port; do
    [[ -n "$protocol" ]] || continue
    found=true
    if [[ "$protocol" == tcp ]]; then
      service_listening "$pid" "$port" || return 1
    else
      service_udp_listening "$pid" "$port" || return 1
    fi
  done < <(managed_listeners)
  [[ "$found" == true ]]
}

service_pid_alive() {
  local pid="$1" active
  if [[ "$INIT" == systemd ]]; then
    # systemd owns MainPID; kill -0 may be denied in an unprivileged container.
    active="$(systemctl show -p ActiveState --value "$APP_NAME" 2>/dev/null)" || active="unknown"
    [[ "$active" == active ]] && return 0
    SERVICE_CHECK_REASON="PID=${pid}，systemd ActiveState=${active}"
  else
    kill -0 "$pid" 2>/dev/null && return 0
    SERVICE_CHECK_REASON="PID=${pid}：进程已退出或无权检查其存活状态"
  fi
  return 1
}

verify_service() {
  local pid previous="" attempt stable=0 listeners
  SERVICE_FALLBACK_USED=false
  listeners="$(managed_listeners | paste -sd '、' -)" || return 1
  [[ -n "$listeners" ]] || return 1
  info "检查服务进程及监听状态：${listeners}"
  for ((attempt=0; attempt<10; attempt++)); do
    sleep 1
    if [[ "$INIT" == systemd ]]; then
      pid="$(systemctl show -p MainPID --value "$APP_NAME" 2>/dev/null)" || pid=""
    else
      pid="$(cat "/run/${APP_NAME}.pid" 2>/dev/null)" || pid=""
    fi
    SERVICE_CHECK_REASON="服务 PID 无效：${pid:-空}"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && service_pid_alive "$pid" &&
       service_has_all_listeners "$pid"; then
      if [[ "$pid" == "$previous" ]]; then stable=$((stable + 1)); else stable=1; fi
      previous="$pid"
      SERVICE_CHECK_REASON="PID=${pid}：监听检查通过，连续稳定 ${stable}/3 次"
      if (( stable >= 3 )); then
        [[ "$SERVICE_FALLBACK_USED" == true ]] &&
          yellow "当前环境限制读取 Xray 进程 fd，已改用稳定 PID 与端口监听的备用检查。"
        return 0
      fi
    else
      stable=0
      previous=""
    fi
  done
  yellow "服务未能持续运行并监听全部 TCP/UDP 端口，请检查端口冲突和资源限制。"
  yellow "最后一次检查：${SERVICE_CHECK_REASON}"
  if [[ "$INIT" == systemd ]]; then
    journalctl -u "$APP_NAME" -n 20 --no-pager || true
  else
    tail -n 20 "/var/log/${APP_NAME}.err" "/var/log/${APP_NAME}.log" || true
  fi
  return 1
}

service_status() {
  if [[ "$INIT" == "systemd" ]]; then
    systemctl --no-pager --full status "$APP_NAME" || true
  else
    rc-service "$APP_NAME" status || true
  fi
  if socks_is_independent; then
    if [[ "$INIT" == systemd ]]; then
      systemctl --no-pager --full status "$SOCKS_NAME" || true
    else
      rc-service "$SOCKS_NAME" status || true
    fi
  fi
}

remove_node_files() {
  service_stop
  rm -f -- "$SYSTEMD_FILE" "$OPENRC_FILE"
  if socks_is_independent; then
    rm -f -- "$ENV_FILE" "$SS_ENV_FILE" "$CONFIG_FILE"
  else
    rm -rf -- "$APP_DIR"
  fi
  rm -f -- "/var/log/${APP_NAME}.log" "/var/log/${APP_NAME}.err" "/run/${APP_NAME}.pid"
  [[ "$INIT" == "systemd" ]] && systemctl daemon-reload
}

load_reality() {
  if [[ ! -r "$ENV_FILE" ]]; then
    [[ "${1:-}" == quiet ]] || yellow "尚未安装 REALITY 节点。"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  : "${NODE_NAME:=REALITY-${SERVER_IP}}"
  : "${XUDP_ENABLED:=true}"
}

load_ss() {
  if [[ ! -r "$SS_ENV_FILE" ]]; then
    [[ "${1:-}" == quiet ]] || yellow "尚未安装 Shadowsocks 节点。"
    return 1
  fi
  # shellcheck disable=SC1090
  . "$SS_ENV_FILE"
  SS_PASSWORD="$(base64_decode "$SS_PASSWORD_B64" 2>/dev/null)" || {
    yellow "Shadowsocks 密码数据损坏。"
    return 1
  }
}

validate_socks_credential() {
  local LC_ALL=C
  [[ -n "$1" && ${#1} -le 255 && ! "$1" =~ [[:cntrl:]] ]]
}

validate_ipv4() {
  local ip="$1" octet
  local -a octets=()
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    [[ ${#octet} -le 3 && ( "$octet" == 0 || "$octet" != 0* ) ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
}

load_socks() {
  if [[ ! -r "$SOCKS_ENV_FILE" ]]; then
    [[ "${1:-}" == quiet ]] || yellow "尚未安装 SOCKS5 节点。"
    return 1
  fi
  SOCKS_BACKEND=xray
  # shellcheck disable=SC1090
  . "$SOCKS_ENV_FILE"
  [[ "$SOCKS_BACKEND" == xray || "$SOCKS_BACKEND" == hev ]] || return 1
  SOCKS_USER="$(base64_decode "$SOCKS_USER_B64" 2>/dev/null)" || return 1
  SOCKS_PASSWORD="$(base64_decode "$SOCKS_PASSWORD_B64" 2>/dev/null)" || return 1
  validate_socks_credential "$SOCKS_USER" && validate_socks_credential "$SOCKS_PASSWORD" &&
    validate_ipv4 "$SOCKS_UDP_IP" && validate_port "$SOCKS_PORT"
}

write_socks_env() {
  [[ -d "$APP_DIR" ]] || install -d -m700 "$APP_DIR" || return 1
  cat >"$SOCKS_ENV_FILE" <<EOF
SOCKS_SERVER_IP='$1'
SOCKS_PORT='$2'
SOCKS_USER_B64='$(base64_encode "$3")'
SOCKS_PASSWORD_B64='$(base64_encode "$4")'
SOCKS_NODE_NAME='$5'
SOCKS_UDP_IP='$6'
SOCKS_BACKEND='${7:-xray}'
EOF
  chmod 600 "$SOCKS_ENV_FILE"
}

write_reality_env() {
  local port="$1" uuid="$2" domain="$3" dest="$4" public_key="$6"
  local short_id="$7" server_ip="$8" fingerprint="$9" node_name="${10}" xudp_enabled="${11}"
  install -d -m700 "$APP_DIR"
  cat >"$ENV_FILE" <<EOF
SERVER_IP='${server_ip}'
PORT='${port}'
UUID='${uuid}'
SNI='${domain}'
DEST='${dest}'
PUBLIC_KEY='${public_key}'
SHORT_ID='${short_id}'
FLOW='xtls-rprx-vision'
FINGERPRINT='${fingerprint}'
NODE_NAME='${node_name}'
XUDP_ENABLED='${xudp_enabled}'
EOF
  chmod 600 "$ENV_FILE"
}

write_ss_env() {
  local server_ip="$1" port="$2" method="$3" password="$4" node_name="$5"
  install -d -m700 "$APP_DIR"
  cat >"$SS_ENV_FILE" <<EOF
SS_SERVER_IP='${server_ip}'
SS_PORT='${port}'
SS_METHOD='${method}'
SS_PASSWORD_B64='$(base64_encode "$password")'
SS_NODE_NAME='${node_name}'
SS_NETWORK='tcp,udp'
EOF
  chmod 600 "$SS_ENV_FILE"
}

# Uppercase fields are loaded dynamically from the root-owned node env files.
# shellcheck disable=SC2153
rebuild_config() {
  local output="${1:-$CONFIG_FILE}" comma="" private_key ss_password
  [[ -r "$ENV_FILE" || -r "$SS_ENV_FILE" || -r "$SOCKS_ENV_FILE" ]] || return 1
  # Rendering a candidate must not change permissions of the live directory.
  [[ -d "$APP_DIR" ]] || install -d -m700 "$APP_DIR" || return 1
  {
    printf '{\n  "log": { "loglevel": "warning" },\n  "inbounds": ['
    if load_reality quiet; then
      if [[ -n "${PRIVATE_KEY:-}" ]]; then
        private_key="$PRIVATE_KEY"
      else
        private_key="$(sed -n 's/.*"privateKey":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" 2>/dev/null | sed -n '1p')"
      fi
      [[ -n "$private_key" ]] || { yellow "无法读取现有 REALITY 私钥。" >&2; return 1; }
      cat <<EOF
{
    "tag": "reality-in",
    "listen": "0.0.0.0",
    "port": ${PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$(json_escape "$UUID")", "flow": "xtls-rprx-vision" }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "$(json_escape "$DEST")",
        "xver": 0,
        "serverNames": ["$(json_escape "$SNI")"],
        "privateKey": "$(json_escape "$private_key")",
        "minClientVer": "${MIN_CLIENT_VERSION}",
        "shortIds": ["$(json_escape "$SHORT_ID")"]
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": true
    }
  }
EOF
      comma=,
    fi
    if load_ss quiet; then
      ss_password="$SS_PASSWORD"
      printf '%s\n' "$comma"
      cat <<EOF
  {
    "tag": "ss-in",
    "listen": "0.0.0.0",
    "port": ${SS_PORT},
    "protocol": "shadowsocks",
    "settings": {
      "network": "tcp,udp",
      "method": "$(json_escape "$SS_METHOD")",
      "password": "$(json_escape "$ss_password")"
    }
  }
EOF
      comma=,
    fi
    if [[ -r "$SOCKS_ENV_FILE" ]] && ! socks_is_independent; then
      load_socks quiet || { yellow "SOCKS5 参数损坏，配置未应用。" >&2; return 1; }
      printf '%s\n' "$comma"
      # accounts is supported by both older and newer Xray releases.
      cat <<EOF
  {
    "tag": "socks-in",
    "listen": "0.0.0.0",
    "port": ${SOCKS_PORT},
    "protocol": "socks",
    "settings": {
      "auth": "password",
      "accounts": [{ "user": "$(json_escape "$SOCKS_USER")", "pass": "$(json_escape "$SOCKS_PASSWORD")" }],
      "udp": true,
      "ip": "$(json_escape "$SOCKS_UDP_IP")"
    }
  }
EOF
    fi
    cat <<'EOF'
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
  } >"$output"
  chmod 600 "$output"
}

install_manager() {
  install_dependencies || die "依赖未就绪。"
  if [[ "$(readlink -f "$0" 2>/dev/null || true)" != "$MANAGER_BIN" ]]; then
    install -Dm755 "$0" "$MANAGER_BIN"
  fi
  ln -sf "$MANAGER_BIN" "$SHORTCUT_BIN"
}

install_common() {
  install_manager
  if [[ -x "$XRAY_BIN" ]] && "$XRAY_BIN" version >/dev/null 2>&1; then
    info "复用已安装的 Xray；如需升级或重装，请使用菜单 5。"
  else
    download_xray || die "Xray 下载或安装失败。"
  fi
}

ports_conflict() {
  local protocol="$1" port="$2"
  if [[ "$protocol" != reality ]] && load_reality quiet && [[ "$PORT" == "$port" ]]; then
    yellow "端口 ${port} 已被 REALITY 节点使用。"
    return 0
  fi
  if [[ "$protocol" != ss ]] && load_ss quiet && [[ "$SS_PORT" == "$port" ]]; then
    yellow "端口 ${port} 已被 Shadowsocks 节点使用。"
    return 0
  fi
  if [[ "$protocol" != socks ]] && load_socks quiet && [[ "$SOCKS_PORT" == "$port" ]]; then
    yellow "端口 ${port} 已被 SOCKS5 节点使用。"
    return 0
  fi
  return 1
}

backup_state() {
  local target="$1"
  mkdir -p "$target" || return 1
  if [[ -d "$APP_DIR" ]]; then cp -a "$APP_DIR/." "$target/" || return 1; fi
  return 0
}

restore_state() {
  local source="$1"
  rm -rf -- "$APP_DIR"
  if [[ -n "$(find "$source" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    install -d -m700 "$APP_DIR"
    cp -a "$source/." "$APP_DIR/" || return 1
    if [[ -f "$CONFIG_FILE" ]]; then
      restore_config_permissions || return 1
    fi
  fi
}

apply_node_change() {
  local backup="$1" success_message="$2"
  local candidate candidate_dir
  candidate_dir="$(mktemp -d /var/tmp/reality-config.XXXXXX)" || return 1
  candidate="${candidate_dir}/config.json"
  if ! rebuild_config "$candidate" || ! "$XRAY_BIN" run -test -c "$candidate"; then
    rm -rf -- "$candidate_dir"
    restore_state "$backup" || { yellow "原配置恢复失败，请检查文件与权限。"; return 1; }
    yellow "新配置校验失败，已恢复原配置。"
    return 1
  fi
  install -m640 -o root -g "$SERVICE_GROUP" "$candidate" "$CONFIG_FILE"
  rm -rf -- "$candidate_dir"
  if ! make_service; then
    restore_state "$backup" || { yellow "原配置恢复失败，请检查文件与权限。"; return 1; }
    if has_xray_nodes; then
      service_restart || yellow "原配置也未能启动，请检查上述日志。"
    else
      remove_node_files
    fi
    yellow "服务启动检查失败，已恢复原节点配置。"
    return 1
  fi
  green "$success_message"
}

install_reality() {
  local port domain dest uuid keys private_key public_key short_id server_ip fingerprint node_name xudp_enabled backup
  install_common

  port="$(prompt "监听端口" "443")"
  validate_port "$port" || die "端口必须是 1-65535 的整数。"
  ports_conflict reality "$port" && return 1
  domain="$(prompt "伪装域名（支持 TLS 1.3，勿填自己的域名）" "www.microsoft.com")"
  validate_domain "$domain" || die "伪装域名格式不正确。"
  dest="$(prompt "目标地址" "${domain}:443")"
  [[ "$dest" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "目标地址格式应为 域名:端口。"
  server_ip="$(prompt "服务器公网 IP/域名" "$(public_ip)")"
  validate_server_address "$server_ip" || die "服务器地址格式不正确。"
  fingerprint="$(prompt "客户端指纹（fp）" "chrome")"
  validate_fingerprint "$fingerprint" || die "客户端指纹格式不正确。"
  node_name="$(prompt "节点名称" "REALITY-${server_ip}")"
  validate_node_name "$node_name" || die "节点名称不能为空、不能包含单引号/换行，且最长 64 个字符。"
  xudp_enabled="$(prompt_yes_no "启用 XUDP/UDP 支持" "true")"

  uuid="$("$XRAY_BIN" uuid)"
  keys="$("$XRAY_BIN" x25519)"
  private_key="$(printf '%s\n' "$keys" | awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}')"
  public_key="$(printf '%s\n' "$keys" | awk -F': ' 'tolower($1) ~ /(public|password)/ {print $2; exit}')"
  [[ -n "$private_key" && -n "$public_key" ]] || die "生成 REALITY 密钥失败。"
  short_id="$(openssl rand -hex 8)"
  backup="$(mktemp -d /var/tmp/reality-state.XXXXXX)" || return 1
  backup_state "$backup"
  PRIVATE_KEY="$private_key"
  write_reality_env "$port" "$uuid" "$domain" "$dest" "$private_key" "$public_key" "$short_id" "$server_ip" "$fingerprint" "$node_name" "$xudp_enabled"
  if apply_node_change "$backup" "REALITY 安装完成。请确认已放行 TCP ${port}。"; then
    rm -rf -- "$backup"
    show_reality
  else
    rm -rf -- "$backup"
    return 1
  fi
}

# Uppercase node fields are loaded from node.env by load_reality.
# shellcheck disable=SC2153
show_reality() {
  load_reality || return 1
  local host link xudp_param="" xudp_status="关闭"
  host="$SERVER_IP"
  [[ "$host" == *:* && "$host" != \[*\] ]] && host="[${host}]"
  if [[ "$XUDP_ENABLED" == "true" ]]; then
    xudp_param="&packetEncoding=xudp"
    xudp_status="开启"
  fi
  link="vless://${UUID}@${host}:${PORT}?encryption=none&flow=${FLOW}&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp${xudp_param}#$(urlencode "$NODE_NAME")"
  printf '\n节点信息\n'
  printf '名称：%s\n服务器：%s\n端口：%s\nUUID：%s\nSNI：%s\nPublic Key：%s\nShort ID：%s\nXUDP/UDP：%s\n\n' \
    "$NODE_NAME" "$SERVER_IP" "$PORT" "$UUID" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$xudp_status"
  green "$link"
}

select_ss_method() {
  local current="${1:-aes-256-gcm}" choice
  printf '\nShadowsocks 加密方式（当前/默认：%s）\n' "$current" >&2
  printf '1. aes-256-gcm\n2. aes-128-gcm\n3. chacha20-ietf-poly1305\n4. xchacha20-ietf-poly1305\n0. 保持当前/默认\n' >&2
  read -r -p "请选择 [0-4]: " choice
  case "$choice" in
    0|"") printf '%s' "$current" ;;
    1) printf 'aes-256-gcm' ;;
    2) printf 'aes-128-gcm' ;;
    3) printf 'chacha20-ietf-poly1305' ;;
    4) printf 'xchacha20-ietf-poly1305' ;;
    *) yellow "无效选项。" >&2; return 1 ;;
  esac
}

install_ss() {
  local server_ip port method password node_name backup
  install_common
  server_ip="$(prompt "服务器公网 IP/域名" "$(public_ip)")"
  validate_server_address "$server_ip" || { yellow "服务器地址格式不正确。"; return 1; }
  port="$(prompt "监听端口" "8388")"
  validate_port "$port" || { yellow "端口必须是 1-65535 的整数。"; return 1; }
  ports_conflict ss "$port" && return 1
  method="$(select_ss_method aes-256-gcm)" || return 1
  password="$(prompt "密码（留空自动生成）")"
  [[ -n "$password" ]] || password="$(openssl rand -base64 24 | tr -d '\n')"
  validate_password "$password" || { yellow "密码不能为空、不能包含换行，且最长 256 个字符。"; return 1; }
  node_name="$(prompt "节点名称" "SS-${server_ip}")"
  validate_node_name "$node_name" || { yellow "节点名称不能为空、不能包含单引号/换行，且最长 64 个字符。"; return 1; }
  backup="$(mktemp -d /var/tmp/reality-state.XXXXXX)" || return 1
  backup_state "$backup"
  write_ss_env "$server_ip" "$port" "$method" "$password" "$node_name"
  if apply_node_change "$backup" "Shadowsocks 安装完成，TCP 和 UDP 均已启用。请在安全组/防火墙放行 TCP/UDP ${port}。"; then
    rm -rf -- "$backup"
    show_ss
  else
    rm -rf -- "$backup"
    return 1
  fi
}

show_ss() {
  load_ss || return 1
  local host userinfo link
  host="$SS_SERVER_IP"
  [[ "$host" == *:* && "$host" != \[*\] ]] && host="[$host]"
  userinfo="$(base64url_encode "${SS_METHOD}:${SS_PASSWORD}")"
  link="ss://${userinfo}@${host}:${SS_PORT}#$(urlencode "$SS_NODE_NAME")"
  printf '\nShadowsocks 节点信息\n'
  printf '名称：%s\n服务器：%s\n端口：%s\n加密：%s\n网络：TCP + UDP\n密码：%s\n\n' \
    "$SS_NODE_NAME" "$SS_SERVER_IP" "$SS_PORT" "$SS_METHOD" "$SS_PASSWORD"
  green "$link"
}

# shellcheck disable=SC2153
edit_node() {
  load_reality || return 1
  local server_ip port uuid domain dest short_id fingerprint node_name xudp_enabled private_key
  local backup
  private_key="$(sed -n 's/.*"privateKey":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG_FILE" | sed -n '1p')"
  if [[ -z "$private_key" ]]; then
    yellow "无法读取现有 REALITY 私钥，配置未修改。"
    return 1
  fi

  server_ip="$(prompt "服务器公网 IP/域名" "$SERVER_IP")"
  validate_server_address "$server_ip" || { yellow "服务器地址格式不正确。"; return 1; }
  port="$(prompt "监听端口" "$PORT")"
  validate_port "$port" || { yellow "端口必须是 1-65535 的整数。"; return 1; }
  ports_conflict reality "$port" && return 1
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
  fingerprint="$(prompt "客户端指纹（fp）" "$FINGERPRINT")"
  validate_fingerprint "$fingerprint" ||
    { yellow "客户端指纹格式不正确。"; return 1; }
  node_name="$(prompt "节点名称" "$NODE_NAME")"
  validate_node_name "$node_name" ||
    { yellow "节点名称不能为空、不能包含单引号/换行，且最长 64 个字符。"; return 1; }
  xudp_enabled="$(prompt_yes_no "启用 XUDP/UDP 支持" "$XUDP_ENABLED")"

  backup="$(mktemp -d /var/tmp/reality-state.XXXXXX)" || return 1
  backup_state "$backup"
  PRIVATE_KEY="$private_key"
  write_reality_env "$port" "$uuid" "$domain" "$dest" "$private_key" "$PUBLIC_KEY" "$short_id" "$server_ip" "$fingerprint" "$node_name" "$xudp_enabled"
  if apply_node_change "$backup" "REALITY 节点已修改并重启。请确认已放行 TCP ${port}。"; then
    rm -rf -- "$backup"
    show_reality
  else
    rm -rf -- "$backup"
    return 1
  fi
}

edit_ss() {
  load_ss || return 1
  local server_ip port method password node_name backup
  server_ip="$(prompt "服务器公网 IP/域名" "$SS_SERVER_IP")"
  validate_server_address "$server_ip" || { yellow "服务器地址格式不正确。"; return 1; }
  port="$(prompt "监听端口" "$SS_PORT")"
  validate_port "$port" || { yellow "端口必须是 1-65535 的整数。"; return 1; }
  ports_conflict ss "$port" && return 1
  method="$(select_ss_method "$SS_METHOD")" || return 1
  password="$(prompt "密码" "$SS_PASSWORD")"
  validate_password "$password" || { yellow "密码不能为空、不能包含换行，且最长 256 个字符。"; return 1; }
  node_name="$(prompt "节点名称" "$SS_NODE_NAME")"
  validate_node_name "$node_name" || { yellow "节点名称格式不正确。"; return 1; }
  backup="$(mktemp -d /var/tmp/reality-state.XXXXXX)" || return 1
  backup_state "$backup"
  write_ss_env "$server_ip" "$port" "$method" "$password" "$node_name"
  if apply_node_change "$backup" "Shadowsocks 节点已修改，TCP 和 UDP 均已启用。"; then
    rm -rf -- "$backup"
    show_ss
  else
    rm -rf -- "$backup"
    return 1
  fi
}

socks_is_independent() {
  [[ -r "$SOCKS_ENV_FILE" ]] && grep -qx "SOCKS_BACKEND='hev'" "$SOCKS_ENV_FILE"
}

has_xray_nodes() {
  [[ -r "$ENV_FILE" || -r "$SS_ENV_FILE" ]] ||
    { [[ -r "$SOCKS_ENV_FILE" ]] && ! socks_is_independent; }
}

download_socks() {
  local asset digest temp actual
  case "$ARCH" in
    64) asset=x86_64; digest=9707a6d9e6419f6474173affa9d00b25a9ec61c9f320f2d19bb14a0a5a584bc5 ;;
    arm64-v8a) asset=arm64; digest=53fb8db2835075f9b0744fe5fa46e308b8fc9d214158e509f4482783799f9b02 ;;
    *) yellow "不支持的 SOCKS5 架构。"; return 1 ;;
  esac
  if [[ -x "$SOCKS_BIN" ]]; then
    actual="$(openssl dgst -sha256 "$SOCKS_BIN")" || return 1
    [[ "${actual##* }" != "$digest" ]] || return 0
    # Never overwrite the executable of an active service in place.
    if socks_is_independent; then
      yellow "已安装的独立 SOCKS5 文件校验不符，请先排查，未覆盖运行文件。"
      return 1
    fi
  fi
  temp="$(mktemp /var/tmp/reality-socks-download.XXXXXX)" || return 1
  if ! curl -fL --retry 3 -o "$temp" "https://github.com/heiher/hev-socks5-server/releases/download/${SOCKS_VERSION}/hev-socks5-server-linux-${asset}"; then
    rm -f -- "$temp"; return 1
  fi
  actual="$(openssl dgst -sha256 "$temp")" || { rm -f -- "$temp"; return 1; }
  if [[ "${actual##* }" != "$digest" ]]; then
    rm -f -- "$temp"; yellow "SOCKS5 SHA256 校验失败，未安装。"; return 1
  fi
  if ! install -Dm755 "$temp" "$SOCKS_BIN" || ! setcap cap_net_bind_service=+ep "$SOCKS_BIN"; then
    rm -f -- "$temp"; return 1
  fi
  rm -f -- "$temp"
}

render_socks_config() {
  load_socks quiet || return 1
  cat <<EOF
main:
  workers: 1
  port: ${SOCKS_PORT}
  listen-address: "0.0.0.0"
  udp-port: ${SOCKS_PORT}
  udp-listen-address: "0.0.0.0"
  udp-public-address-v4: "${SOCKS_UDP_IP}"
auth:
  username: "$(json_escape "$SOCKS_USER")"
  password: "$(json_escape "$SOCKS_PASSWORD")"
misc:
  log-file: stderr
  log-level: warn
EOF
}

socks_stop() {
  if [[ "$INIT" == systemd ]]; then
    systemctl stop "$SOCKS_NAME" 2>/dev/null || true
  else
    rc-service "$SOCKS_NAME" stop 2>/dev/null || true
  fi
}

remove_socks_service() {
  socks_stop
  if [[ "$INIT" == systemd ]]; then
    systemctl disable "$SOCKS_NAME" 2>/dev/null || true
  else
    rc-update del "$SOCKS_NAME" default 2>/dev/null || true
  fi
  rm -f -- "$SOCKS_SYSTEMD" "$SOCKS_OPENRC" "$SOCKS_BIN"
  rm -rf -- "$SOCKS_DIR"
  rm -f -- "/run/${SOCKS_NAME}.pid" "/var/log/${SOCKS_NAME}.log" "/var/log/${SOCKS_NAME}.err"
  if [[ "$INIT" == systemd ]]; then systemctl daemon-reload; fi
}

socks_permissions() {
  chown root:"$SERVICE_GROUP" "$APP_DIR" "$SOCKS_DIR" "$SOCKS_CONFIG" || return 1
  chmod 750 "$APP_DIR" "$SOCKS_DIR" && chmod 640 "$SOCKS_CONFIG" || return 1
  chown root:root "$SOCKS_ENV_FILE" && chmod 600 "$SOCKS_ENV_FILE" || return 1
  [[ ! -f "$CONFIG_FILE" ]] || restore_config_permissions || return 1
}

socks_restart() {
  local pid previous="" stable=0 attempt
  socks_permissions || return 1
  if [[ "$INIT" == systemd ]]; then
    systemctl restart "$SOCKS_NAME" || return 1
  else
    rc-service "$SOCKS_NAME" restart || return 1
  fi
  load_socks quiet || return 1
  # UDP relay sockets are created on UDP ASSOCIATE, not at daemon startup.
  info "检查独立 SOCKS5 进程及 TCP ${SOCKS_PORT}（UDP ${SOCKS_PORT} 按关联创建）。"
  for attempt in {1..10}; do
    sleep 1
    if [[ "$INIT" == systemd ]]; then
      pid="$(systemctl show "$SOCKS_NAME" -p MainPID --value 2>/dev/null)"
      [[ "$(systemctl show "$SOCKS_NAME" -p ActiveState --value 2>/dev/null)" == active ]] || pid=0
    else
      pid="$(cat "/run/${SOCKS_NAME}.pid" 2>/dev/null || true)"
    fi
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null && service_listening "$pid" "$SOCKS_PORT"; then
      if [[ "$pid" == "$previous" ]]; then stable=$((stable + 1)); else stable=1; fi
      previous="$pid"
      (( stable < 3 )) || return 0
    else
      stable=0; previous=""
    fi
  done
  yellow "独立 SOCKS5 未通过启动检查。"
  if [[ "$INIT" == systemd ]]; then
    journalctl -u "$SOCKS_NAME" -n 20 --no-pager || true
  else
    tail -n 20 "/var/log/${SOCKS_NAME}.err" || true
  fi
  return 1
}

make_socks_service() {
  if [[ "$INIT" == systemd ]]; then
    cat >"$SOCKS_SYSTEMD" <<EOF
[Unit]
Description=Independent SOCKS5 TCP/UDP Service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=nobody
Group=${SERVICE_GROUP}
ExecStart=${SOCKS_BIN} ${SOCKS_CONFIG}
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable "$SOCKS_NAME" || return 1
  else
    touch "/var/log/${SOCKS_NAME}.log" "/var/log/${SOCKS_NAME}.err"
    chown nobody:"$SERVICE_GROUP" "/var/log/${SOCKS_NAME}.log" "/var/log/${SOCKS_NAME}.err" || return 1
    cat >"$SOCKS_OPENRC" <<EOF
#!/sbin/openrc-run
name="Independent SOCKS5 TCP/UDP Service"
command="${SOCKS_BIN}"
command_args="${SOCKS_CONFIG}"
command_user="nobody"
command_background="yes"
pidfile="/run/${SOCKS_NAME}.pid"
output_log="/var/log/${SOCKS_NAME}.log"
error_log="/var/log/${SOCKS_NAME}.err"
depend() { need net; }
EOF
    chmod 755 "$SOCKS_OPENRC"
    rc-update add "$SOCKS_NAME" default || return 1
  fi
  socks_restart
}

apply_socks_change() {
  local backup="$1" ok=true migrated=false
  # Free the legacy Xray SOCKS port before starting the independent daemon.
  if [[ -r "$backup/socks.env" ]] && ! grep -qx "SOCKS_BACKEND='hev'" "$backup/socks.env"; then
    migrated=true
    if has_xray_nodes; then
      apply_node_change "$backup" "Xray 节点已保留。" || ok=false
    else
      remove_node_files
    fi
  fi
  if [[ "$ok" == true ]]; then
    install -d -m750 "$SOCKS_DIR" || ok=false
    render_socks_config >"$SOCKS_CONFIG" || ok=false
    if [[ "$ok" == true ]] && make_socks_service; then return 0; fi
  fi
  socks_stop
  restore_state "$backup" || { yellow "配置恢复失败，请检查权限。"; return 1; }
  if socks_is_independent && [[ -f "$backup.yml" ]]; then
    install -m640 "$backup.yml" "$SOCKS_CONFIG"
    socks_restart || yellow "原 SOCKS5 未能恢复，请查看服务日志。"
  else
    remove_socks_service
  fi
  if [[ "$migrated" == true ]] && has_xray_nodes; then
    make_service || yellow "原 Xray 未能恢复，请查看服务日志。"
  fi
  yellow "独立 SOCKS5 应用失败，已恢复原节点配置。"
  return 1
}

configure_socks() {
  local action="${1:-install}" server_ip port username password node_name udp_ip udp_default backup
  local current_server="" current_port=1080 current_user=socks current_password="" current_name="" current_udp=""
  if [[ "$action" == edit ]]; then
    load_socks || return 1
    current_server="$SOCKS_SERVER_IP"; current_port="$SOCKS_PORT"
    current_user="$SOCKS_USER"; current_password="$SOCKS_PASSWORD"
    current_name="$SOCKS_NODE_NAME"; current_udp="$SOCKS_UDP_IP"
  else
    current_server="$(public_ip)"
  fi
  install_manager
  info "SOCKS5 启用用户名/密码认证及 TCP + UDP；协议本身不加密。"
  info "独立 SOCKS5 服务：TCP 与客户端 UDP 转发使用同一固定端口，不依赖 Xray 版本。"
  yellow "NAT 必须同时映射 TCP/UDP，且公网与本机端口相同；客户端须支持 UDP ASSOCIATE。"
  server_ip="$(prompt "服务器公网 IP/域名" "$current_server")"
  validate_server_address "$server_ip" || { yellow "服务器地址格式不正确。"; return 1; }
  port="$(prompt "监听端口" "$current_port")"
  validate_port "$port" || { yellow "端口必须是 1-65535 的整数。"; return 1; }
  ports_conflict socks "$port" && return 1
  udp_default="${current_udp:-$server_ip}"
  if ! validate_ipv4 "$udp_default"; then
    udp_default="$(public_ip)"
    validate_ipv4 "$udp_default" || udp_default=""
  fi
  udp_ip="$(prompt "UDP 转发公网 IPv4（客户端可达；NAT 填映射公网 IP）" "$udp_default")"
  validate_ipv4 "$udp_ip" || { yellow "UDP 转发地址必须是有效 IPv4。"; return 1; }
  username="$(prompt "用户名" "$current_user")"
  validate_socks_credential "$username" || { yellow "用户名必须为 1-255 字节，不能包含控制字符。"; return 1; }
  password="$(prompt "密码（安装时留空自动生成；修改时留空保持）" "$current_password")"
  [[ -n "$password" ]] || password="$(openssl rand -hex 16)"
  validate_socks_credential "$password" || { yellow "密码必须为 1-255 字节，不能包含控制字符。"; return 1; }
  node_name="$(prompt "节点名称" "${current_name:-SOCKS5-${server_ip}}")"
  validate_node_name "$node_name" || { yellow "节点名称格式不正确。"; return 1; }
  backup="$(mktemp -d /var/tmp/reality-state.XXXXXX)" || return 1
  backup_state "$backup" || { rm -rf -- "$backup"; return 1; }
  if ! download_socks; then rm -rf -- "$backup"; return 1; fi
  [[ ! -f "$SOCKS_CONFIG" ]] || cp -a "$SOCKS_CONFIG" "$backup.yml"
  write_socks_env "$server_ip" "$port" "$username" "$password" "$node_name" "$udp_ip" hev
  if apply_socks_change "$backup"; then
    rm -rf -- "$backup"
    rm -f -- "$backup.yml"
    green "SOCKS5 配置完成。请放行/映射 TCP 和 UDP ${port}；Xray 升降级不会改变 SOCKS5。"
    show_socks
  else
    rm -rf -- "$backup"
    rm -f -- "$backup.yml"
    return 1
  fi
}

show_socks() {
  load_socks || return 1
  local host="$SOCKS_SERVER_IP"
  [[ "$host" == *:* && "$host" != \[*\] ]] && host="[$host]"
  printf '\nSOCKS5 节点信息\n名称：%s\n服务器：%s\n端口：%s\n用户名：%s\n密码：%s\nUDP 转发 IPv4：%s\n网络：TCP + UDP\n' \
    "$SOCKS_NODE_NAME" "$SOCKS_SERVER_IP" "$SOCKS_PORT" "$SOCKS_USER" "$SOCKS_PASSWORD" "$SOCKS_UDP_IP"
  info "客户端需支持 SOCKS5 UDP ASSOCIATE；如不识别链接，请按上述字段手动添加。"
  if socks_is_independent; then
    info "独立服务 hev ${SOCKS_VERSION}；固定 TCP/UDP ${SOCKS_PORT}。UDP 套接字在客户端发起关联后创建。"
  else
    yellow "旧版 Xray SOCKS5：新 Xray 可能使用动态 UDP 端口。菜单 2 → SOCKS5 可保留参数迁移至独立服务。"
  fi
  green "socks5://$(urlencode "$SOCKS_USER"):$(urlencode "$SOCKS_PASSWORD")@${host}:${SOCKS_PORT}#$(urlencode "$SOCKS_NODE_NAME")"
}

delete_protocol() {
  local protocol="$1" answer="${2:-}" file label backup
  case "$protocol" in
    reality) file="$ENV_FILE"; label=REALITY ;;
    ss) file="$SS_ENV_FILE"; label=Shadowsocks ;;
    socks) file="$SOCKS_ENV_FILE"; label=SOCKS5 ;;
    *) yellow "无效协议。"; return 1 ;;
  esac
  [[ -r "$file" ]] || { yellow "尚未安装 ${label} 节点。"; return 1; }
  if [[ "$answer" != --yes ]]; then
    read -r -p "将删除 ${label} 节点，其他协议节点会保留，确定吗？[y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { yellow "已取消。"; return 0; }
  fi
  if [[ "$protocol" == socks ]] && socks_is_independent; then
    remove_socks_service
    rm -f -- "$SOCKS_ENV_FILE"
    green "已删除独立 SOCKS5 节点；REALITY/SS 不受影响。"
    return 0
  fi
  backup="$(mktemp -d /var/tmp/reality-state.XXXXXX)" || return 1
  backup_state "$backup"
  rm -f -- "$file"
  if ! has_xray_nodes; then
    remove_node_files
    rm -rf -- "$backup"
    green "已删除 ${label} 节点及 Xray 节点服务；独立 SOCKS5（如有）继续运行，Xray 和管理命令仍保留。"
    return 0
  fi
  if apply_node_change "$backup" "已删除 ${label} 节点，其他节点继续运行。"; then
    rm -rf -- "$backup"
  else
    rm -rf -- "$backup"
    return 1
  fi
}

uninstall_reality() {
  local answer="${1:-}"
  if [[ "$answer" != "--yes" ]]; then
    read -r -p "将完全删除 Xray、REALITY/SS/SOCKS5 配置、服务和日志，确定吗？[y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { yellow "已取消。"; return; }
  fi
  remove_socks_service
  rm -f -- "$SOCKS_ENV_FILE"
  remove_node_files
  rm -f -- "$XRAY_BIN" "$SHORTCUT_BIN" "$MANAGER_BIN"
  rm -rf -- "$XRAY_DIR"
  green "已完全卸载 REALITY One-key 及全部节点。"
  exit 0
}

ensure_min_client_version() {
  local candidate candidate_dir
  [[ -r "$CONFIG_FILE" ]] || return 1
  [[ -r "$ENV_FILE" ]] || return 0
  candidate_dir="$(mktemp -d /var/tmp/reality-config.XXXXXX)" || return 1
  candidate="${candidate_dir}/config.json"
  if ! rebuild_config "$candidate" || ! "$XRAY_BIN" run -test -c "$candidate"; then
    rm -rf -- "$candidate_dir"
    yellow "无法写入 REALITY 最低客户端版本，原配置未修改。"
    return 1
  fi
  if ! install -m640 -o root -g "$SERVICE_GROUP" "$candidate" "$CONFIG_FILE" ||
     ! restore_config_permissions; then
    rm -rf -- "$candidate_dir"
    return 1
  fi
  rm -rf -- "$candidate_dir"
}

update_xray() {
  local current releases choice target index backup
  local -a versions=()
  [[ -x "$XRAY_BIN" && -r "$CONFIG_FILE" ]] ||
    { yellow "请先安装节点。"; return 1; }
  current="v$("$XRAY_BIN" version | awk 'NR == 1 {print $2}')"
  releases="$(curl -fsSL --max-time 15 \
    "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=10" 2>/dev/null || true)"
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    versions+=("$target")
    (( ${#versions[@]} >= 3 )) && break
  done < <(printf '%s\n' "$releases" |
    sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p')

  printf '\n当前 Xray 版本：%s\n' "$current"
  if (( ${#versions[@]} > 0 )); then
    for index in "${!versions[@]}"; do
      if [[ "${versions[$index]}" == "$current" ]]; then
        printf '%d. %s（当前版本）\n' "$((index + 1))" "${versions[$index]}"
      else
        printf '%d. %s\n' "$((index + 1))" "${versions[$index]}"
      fi
    done
  else
    yellow "无法获取官方版本列表，仍可手动输入版本号。"
  fi
  printf '%d. 手动输入版本号\n0. 返回菜单\n' "$(( ${#versions[@]} + 1 ))"
  read -r -p "请选择更新版本: " choice
  if [[ "$choice" == "0" ]]; then
    return 0
  elif [[ "$choice" =~ ^[0-9]+$ ]] &&
       (( choice >= 1 && choice <= ${#versions[@]} )); then
    target="${versions[$((choice - 1))]}"
  elif [[ "$choice" == "$(( ${#versions[@]} + 1 ))" ]]; then
    target="$(prompt "请输入版本号，例如 v26.5.9")"
    [[ "$target" == v* ]] || target="v${target}"
  else
    yellow "无效选项。"
    return 1
  fi
  [[ "$target" =~ ^v[0-9]+([.][0-9]+){1,3}([._-][A-Za-z0-9.-]+)?$ ]] ||
    { yellow "版本号格式不正确。"; return 1; }
  if [[ "$target" == "$current" ]]; then
    read -r -p "目标版本与当前版本相同，仍要重新安装吗？[y/N]: " choice
    [[ "$choice" =~ ^[Yy]$ ]] || return 0
  fi
  if [[ -r "$SOCKS_ENV_FILE" ]] && ! socks_is_independent; then
    yellow "SOCKS5 提醒：v26.7.28/v26.9.9 使用动态 UDP 端口，单端口 NAT 或未放行动态端口时 UDP 不可用。"
  fi

  backup="$(mktemp -d /var/tmp/reality-backup.XXXXXX)" || return 1
  cp "$XRAY_BIN" "$backup/xray"
  cp "$CONFIG_FILE" "$backup/config.json"
  [[ -f "$XRAY_DIR/geoip.dat" ]] && cp "$XRAY_DIR/geoip.dat" "$backup/geoip.dat"
  [[ -f "$XRAY_DIR/geosite.dat" ]] && cp "$XRAY_DIR/geosite.dat" "$backup/geosite.dat"
  if ! ensure_min_client_version ||
     ! download_xray "$target" ||
     ! "$XRAY_BIN" run -test -c "$CONFIG_FILE" ||
     ! service_restart; then
    install -m755 "$backup/xray" "$XRAY_BIN"
    setcap cap_net_bind_service=+ep "$XRAY_BIN"
    install -m640 -o root -g "$SERVICE_GROUP" "$backup/config.json" "$CONFIG_FILE"
    [[ -f "$backup/geoip.dat" ]] && install -m644 "$backup/geoip.dat" "$XRAY_DIR/geoip.dat"
    [[ -f "$backup/geosite.dat" ]] && install -m644 "$backup/geosite.dat" "$XRAY_DIR/geosite.dat"
    service_restart || yellow "旧版本文件已恢复，但服务仍无法启动，请检查上述日志。"
    rm -rf -- "$backup"
    yellow "更新失败，已恢复 ${current}。"
    return 1
  fi
  rm -rf -- "$backup"
  if [[ -r "$ENV_FILE" ]]; then
    green "Xray 已更新到 ${target}；全部节点身份和分享链接保持不变，REALITY 最低客户端版本为 ${MIN_CLIENT_VERSION}。"
  else
    green "Xray 已更新到 ${target}；全部节点身份和连接信息保持不变。"
  fi
}

update_script() {
  local tmp
  if ! command -v curl >/dev/null 2>&1; then
    yellow "缺少 curl，无法更新管理脚本。"
    return 1
  fi
  tmp="$(mktemp)"
  if ! curl -fL --retry 3 \
    -H "Accept: application/vnd.github.raw+json" \
    -H "Cache-Control: no-cache" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -o "$tmp" "$SCRIPT_API_URL"; then
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

protocol_menu() {
  local action="$1" choice index selected
  local -a protocols=() labels=()
  if [[ "$action" == install ]]; then
    while true; do
      printf '\n请选择节点类型\n1. REALITY\n2. Shadowsocks（SS，TCP + UDP）\n3. SOCKS5（TCP + UDP）\n0. 返回主菜单\n'
      read -r -p "请选择 [0-3]: " choice
      case "$choice" in
        1) install_reality || true; return ;;
        2) install_ss || true; return ;;
        3) configure_socks install || true; return ;;
        0) return ;;
        *) yellow "无效选项。" ;;
      esac
    done
  fi

  if [[ -r "$ENV_FILE" ]]; then
    protocols+=(reality)
    labels+=(REALITY)
  fi
  if [[ -r "$SS_ENV_FILE" ]]; then
    protocols+=(ss)
    labels+=("Shadowsocks（SS，TCP + UDP）")
  fi
  if [[ -r "$SOCKS_ENV_FILE" ]]; then
    protocols+=(socks)
    labels+=("SOCKS5（TCP + UDP）")
  fi
  if (( ${#protocols[@]} == 0 )); then
    yellow "未发现已安装的节点。"
    return 0
  fi

  while true; do
    printf '\n请选择已安装的节点\n'
    for index in "${!labels[@]}"; do
      printf '%d. %s\n' "$((index + 1))" "${labels[$index]}"
    done
    printf '0. 返回主菜单\n'
    read -r -p "请选择 [0-${#protocols[@]}]: " choice
    [[ "$choice" == 0 ]] && return 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#protocols[@]} )); then
      yellow "无效选项。"
      continue
    fi
    selected="${protocols[$((choice - 1))]}"
    case "${action}:${selected}" in
      edit:reality) edit_node || true ;;
      edit:ss) edit_ss || true ;;
      edit:socks) configure_socks edit || true ;;
      show:reality) show_reality || true ;;
      show:ss) show_ss || true ;;
      show:socks) show_socks || true ;;
      delete:reality) delete_protocol reality || true ;;
      delete:ss) delete_protocol ss || true ;;
      delete:socks) delete_protocol socks || true ;;
      *) yellow "无效操作。" ;;
    esac
    return 0
  done
}

menu() {
  while true; do
    printf '\nREALITY 一键管理脚本\n'
    printf '1. 安装/重新配置\n2. 修改节点配置\n3. 查询节点\n4. 查看服务状态\n5. 更新 Xray\n6. 更新管理脚本\n7. 删除已安装节点\n8. 完全卸载\n0. 退出\n'
    read -r -p "请选择 [0-8]: " choice
    case "$choice" in
      1) protocol_menu install ;;
      2) protocol_menu edit ;;
      3) protocol_menu show ;;
      4) service_status ;;
      5) update_xray || true ;;
      6) update_script || true ;;
      7) protocol_menu delete ;;
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
    install) protocol_menu install ;;
    install-reality) install_reality ;;
    install-ss) install_ss ;;
    install-socks) configure_socks install ;;
    edit) protocol_menu edit ;;
    edit-reality) edit_node ;;
    edit-ss) edit_ss ;;
    edit-socks) configure_socks edit ;;
    show) protocol_menu show ;;
    show-reality) show_reality ;;
    show-ss) show_ss ;;
    show-socks) show_socks ;;
    status) service_status ;;
    update) update_xray ;;
    self-update) update_script ;;
    remove-node) protocol_menu delete ;;
    remove-reality) delete_protocol reality "${2:-}" ;;
    remove-ss) delete_protocol ss "${2:-}" ;;
    remove-socks) delete_protocol socks "${2:-}" ;;
    uninstall) uninstall_reality "${2:-}" ;;
    menu) menu ;;
    -h|--help)
      printf '用法: %s [install|install-reality|install-ss|install-socks|edit|edit-reality|edit-ss|edit-socks|show|show-reality|show-ss|show-socks|status|update|self-update|remove-node|remove-reality [--yes]|remove-ss [--yes]|remove-socks [--yes]|uninstall [--yes]|menu]\n' "$0"
      ;;
    *) die "未知命令：$1" ;;
  esac
}

main "$@"
