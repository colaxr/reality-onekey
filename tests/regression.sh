#!/usr/bin/env bash
# Mock functions are invoked indirectly by the sourced production functions.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_ROOT="$(mktemp -d)"
export REALITY_ROOT_PREFIX="$TEST_ROOT"
export REALITY_PROC_ROOT="$TEST_ROOT/proc"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
# shellcheck disable=SC1090
source <(sed '$d' reality.sh)
ORIGINAL_MANAGED_LISTENERS="$(declare -f managed_listeners)"

# No service, package manager or system file is changed by these mocks.
sleep() { :; }
cat() { printf '42\n'; }
kill() { return 0; }
tail() { :; }
managed_listeners() { printf 'tcp 26996\n'; }
service_listening() { return 0; }
export INIT=openrc
verify_service >/dev/null
service_listening() { return 1; }
if verify_service >/dev/null; then
  echo 'FAIL: non-listening process accepted'; exit 1
fi
service_listening() { return 0; }
kill() { return 1; }
if verify_service >/dev/null; then
  echo 'FAIL: dead process accepted'; exit 1
fi
unset -f cat kill tail sleep managed_listeners service_listening

# systemd's ActiveState/MainPID remains usable when container permissions
# reject kill -0 against the nobody-owned Xray process.
export INIT=systemd
systemctl() {
  case "$*" in
    *MainPID*) printf '42\n' ;;
    *ActiveState*) printf 'active\n' ;;
    *) return 1 ;;
  esac
}
kill() { return 1; }
cat() { printf '42\n'; }
sleep() { :; }
managed_listeners() { printf 'tcp 26996\n'; }
service_listening() { return 0; }
journalctl() { :; }
verify_service >/dev/null || { echo 'FAIL: systemd active PID rejected when kill is denied'; exit 1; }
systemctl() {
  case "$*" in
    *MainPID*) printf '42\n' ;;
    *ActiveState*) printf 'inactive\n' ;;
    *) return 1 ;;
  esac
}
if verify_service >/dev/null; then
  echo 'FAIL: inactive systemd service accepted'; exit 1
fi
unset -f systemctl kill cat sleep managed_listeners service_listening journalctl

# Normal hosts require the listening socket inode to belong to the managed PID.
mkdir -p "$PROC_ROOT/42/fd" "$PROC_ROOT/net"
: >"$PROC_ROOT/42/fd/7"
readlink() { printf 'socket:[1234]\n'; }
printf '0: 00000000:A40C 00000000:0000 0A 0 0 0 0 0 1234\n' >"$PROC_ROOT/net/tcp"
: >"$PROC_ROOT/net/tcp6"
SERVICE_FALLBACK_USED=false
service_socket 42 41996 0A "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/tcp6" || {
  echo 'FAIL: owned TCP listener rejected'; exit 1;
}
[[ "$SERVICE_FALLBACK_USED" == false ]] || { echo 'FAIL: normal host used fallback'; exit 1; }
printf '0: 00000000:A40C 00000000:0000 0A 0 0 0 0 0 5678\n' >"$PROC_ROOT/net/tcp"
if service_socket 42 41996 0A "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/tcp6"; then
  echo 'FAIL: another process listener accepted on normal host'; exit 1
fi
unset -f readlink

# Restricted containers can list fd entries but cannot read any symlink target.
readlink() {
  # GNU readlink is silent on errors unless verbose mode is requested.
  [[ "$1" != -v ]] || printf 'readlink: Permission denied\n' >&2
  return 1
}
SERVICE_FALLBACK_USED=false
service_socket 42 41996 0A "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/tcp6" || {
  echo 'FAIL: restricted container listener rejected'; exit 1;
}
[[ "$SERVICE_FALLBACK_USED" == true ]] || { echo 'FAIL: restricted fallback not recorded'; exit 1; }
printf '0: 00000000:A40D 00000000:0000 0A 0 0 0 0 0 5678\n' >"$PROC_ROOT/net/tcp"
if service_socket 42 41996 0A "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/tcp6"; then
  echo 'FAIL: restricted fallback accepted missing port'; exit 1
fi

# Partial fd access with an explicit permission denial also needs fallback.
: >"$PROC_ROOT/42/fd/8"
readlink() {
  if [[ "${!#}" == */8 ]]; then printf 'socket:[1234]\n'; return 0; fi
  [[ "$1" != -v ]] || printf 'readlink: Permission denied\n' >&2
  return 1
}
printf '0: 00000000:A40C 00000000:0000 0A 0 0 0 0 0 5678\n' >"$PROC_ROOT/net/tcp"
SERVICE_FALLBACK_USED=false
service_socket 42 41996 0A "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/tcp6" || {
  echo 'FAIL: partial fd denial blocked fallback'; exit 1;
}
[[ "$SERVICE_FALLBACK_USED" == true ]] || { echo 'FAIL: partial access did not use fallback'; exit 1; }
unset -f readlink

# Real Linux permission failure: retain directory listing but deny traversal.
# This catches readlink's default silent behavior without mocking its output.
if [[ "$(uname -s)" == Linux && "$EUID" != 0 ]]; then
  ln -s 'socket:[1234]' "$PROC_ROOT/42/fd/9"
  chmod 400 "$PROC_ROOT/42/fd"
  SERVICE_FALLBACK_USED=false
  if ! service_socket 42 41996 0A "$PROC_ROOT/net/tcp" "$PROC_ROOT/net/tcp6"; then
    chmod 700 "$PROC_ROOT/42/fd"
    echo 'FAIL: real readlink permission denial blocked fallback'; exit 1
  fi
  chmod 700 "$PROC_ROOT/42/fd"
  [[ "$SERVICE_FALLBACK_USED" == true ]] || { echo 'FAIL: real permission fallback not recorded'; exit 1; }
fi

export PKG=apt
command() { return 0; }
# Certificate bundle path is normally present in Linux CI.
apt-get() { echo 'FAIL: unnecessary APT invocation' >&2; return 1; }
if [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
  install_dependencies >/dev/null
fi
command() { return 1; }
apt-get() { return 1; }
if install_dependencies >/dev/null; then
  echo 'FAIL: failed dependency installation accepted'; exit 1
fi
unset -f command apt-get

# A legacy REALITY node can be merged with SS without losing its identity.
export SERVICE_GROUP=root
chmod() { :; }
install() {
  local target="${!#}"
  if [[ "$1" == -d ]]; then mkdir -p "$target"; else /usr/bin/install "$@"; fi
}
# Defined immediately above; later redefinition confuses older ShellCheck.
# shellcheck disable=SC2218
install -d -m700 "$APP_DIR"
cat >"$CONFIG_FILE" <<'EOF'
{"inbounds":[{"protocol":"vless","streamSettings":{"realitySettings":{"privateKey":"CNbUQuA6-wuMRF2DIaS6R3CUJBa7CGO0wLE8Aj0HoH0"}}}]}
EOF
write_reality_env 24443 11111111-1111-4111-8111-111111111111 example.com example.com:443 \
  CNbUQuA6-wuMRF2DIaS6R3CUJBa7CGO0wLE8Aj0HoH0 public-test aabbccdd 192.0.2.1 chrome 'REALITY Test' true
write_ss_env 192.0.2.1 28388 aes-256-gcm 'p@ss"word\\test' 'SS Test'
rebuild_config "$CONFIG_FILE.new"
node -e '
const fs = require("fs");
const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (c.inbounds.length !== 2) process.exit(1);
const r = c.inbounds.find(x => x.tag === "reality-in");
const s = c.inbounds.find(x => x.tag === "ss-in");
if (!r || r.streamSettings.realitySettings.privateKey !== "CNbUQuA6-wuMRF2DIaS6R3CUJBa7CGO0wLE8Aj0HoH0") process.exit(2);
if (!s || s.settings.network !== "tcp,udp") process.exit(3);
if (s.settings.password !== "p@ss\"word\\\\test") process.exit(4);
' "$CONFIG_FILE.new"
load_ss quiet
[[ "$SS_PASSWORD" == 'p@ss"word\\test' ]] || { echo 'FAIL: SS password round trip'; exit 1; }
uri="$(base64url_encode "${SS_METHOD}:${SS_PASSWORD}")"
[[ "$uri" != *'='* && "$uri" != *'+'* && "$uri" != *'/'* ]] || {
  echo 'FAIL: invalid SIP002 Base64URL'; exit 1;
}
cp "$ENV_FILE" "$TEST_ROOT/reality.env"
rm -f -- "$ENV_FILE"
rebuild_config "$CONFIG_FILE.ss-only"
node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(c.inbounds.length!==1 || c.inbounds[0].tag!=="ss-in") process.exit(1)' "$CONFIG_FILE.ss-only"
mv "$TEST_ROOT/reality.env" "$ENV_FILE"
rm -f -- "$SS_ENV_FILE"
rebuild_config "$CONFIG_FILE.reality-only"
node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); if(c.inbounds.length!==1 || c.inbounds[0].tag!=="reality-in") process.exit(1)' "$CONFIG_FILE.reality-only"
show_reality() { printf 'SHOW_REALITY\n'; }
menu_output="$(printf '1\n' | protocol_menu show)"
[[ "$menu_output" == *'1. REALITY'* && "$menu_output" != *'Shadowsocks'* && "$menu_output" == *'SHOW_REALITY'* ]] || {
  echo 'FAIL: installed-node submenu is not dynamic'; exit 1;
}
unset -f chmod install

# SOCKS credentials survive quoting, and every nonempty protocol combination
# preserves identities while publishing the right TCP/UDP health requirements.
eval "$ORIGINAL_MANAGED_LISTENERS"
install() {
  if [[ "$1" == -d ]]; then mkdir -p "${!#}"; else /usr/bin/install "$@"; fi
}
write_ss_env 192.0.2.1 28388 aes-256-gcm test-pass 'SS Test'
write_socks_env 192.0.2.1 31080 'user@"test' 'p@ss:word\test' 'SOCKS Test' 192.0.2.1
load_socks
[[ "$SOCKS_USER" == 'user@"test' && "$SOCKS_PASSWORD" == 'p@ss:word\test' ]]
ports_conflict reality 31080 >/dev/null || { echo 'FAIL: SOCKS port conflict missed'; exit 1; }
if ports_conflict socks 31080 >/dev/null; then echo 'FAIL: SOCKS conflicts with itself'; exit 1; fi
validate_ipv4 192.0.2.1
if validate_ipv4 256.0.0.1 || validate_ipv4 01.2.3.4 || validate_socks_credential $'bad\nuser'; then
  echo 'FAIL: invalid SOCKS input accepted'; exit 1
fi
cp "$ENV_FILE" "$TEST_ROOT/reality.saved"
cp "$SS_ENV_FILE" "$TEST_ROOT/ss.saved"
cp "$SOCKS_ENV_FILE" "$TEST_ROOT/socks.saved"
for mask in 1 2 3 4 5 6 7; do
  rm -f "$ENV_FILE" "$SS_ENV_FILE" "$SOCKS_ENV_FILE"
  (( mask & 1 )) && cp "$TEST_ROOT/reality.saved" "$ENV_FILE"
  (( mask & 2 )) && cp "$TEST_ROOT/ss.saved" "$SS_ENV_FILE"
  (( mask & 4 )) && cp "$TEST_ROOT/socks.saved" "$SOCKS_ENV_FILE"
  rebuild_config "$TEST_ROOT/combination.json"
  node -e '
const c=JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
const mask=Number(process.argv[2]);
if(c.inbounds.length!==[1,2,4].filter(x=>mask&x).length) process.exit(1);
const s=c.inbounds.find(x=>x.tag==="socks-in");
if(Boolean(s)!==Boolean(mask&4)) process.exit(2);
if(s && (s.settings.auth!=="password" || s.settings.udp!==true || s.settings.ip!=="192.0.2.1" ||
 s.settings.accounts[0].user!=="user@\"test" || s.settings.accounts[0].pass!=="p@ss:word\\test")) process.exit(3);
const r=c.inbounds.find(x=>x.tag==="reality-in");
if(r && r.settings.clients[0].id!=="11111111-1111-4111-8111-111111111111") process.exit(4);
' "$TEST_ROOT/combination.json" "$mask"
  if (( mask & 4 )); then
    listeners="$(managed_listeners)"
    [[ "$listeners" == *'tcp 31080'* && "$listeners" == *'udp 31080'* ]]
  fi
done
show_socks() { printf 'SHOW_SOCKS\n'; }
menu_output="$(printf '3\n' | protocol_menu show)"
[[ "$menu_output" == *'SOCKS5'* && "$menu_output" == *'SHOW_SOCKS'* ]]
# Exercise actual per-protocol removal, but never start a system service.
apply_node_change() { rebuild_config "$CONFIG_FILE.new" && mv "$CONFIG_FILE.new" "$CONFIG_FILE"; }
remove_node_files() { rm -rf -- "$APP_DIR"; }
mktemp() { /usr/bin/mktemp -d "$TEST_ROOT/delete.XXXXXX"; }
delete_protocol socks --yes >/dev/null
[[ ! -f "$SOCKS_ENV_FILE" && -f "$ENV_FILE" && -f "$SS_ENV_FILE" ]]
node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1])); if(c.inbounds.length!==2 || c.inbounds.some(x=>x.tag==="socks-in")) process.exit(1)' "$CONFIG_FILE"
menu_output="$(printf '1\n' | protocol_menu show)"
[[ "$menu_output" != *'SOCKS5'* ]]
delete_protocol ss --yes >/dev/null
[[ -f "$ENV_FILE" && ! -f "$SS_ENV_FILE" ]]
delete_protocol reality --yes >/dev/null
[[ ! -d "$APP_DIR" ]]
unset -f install mktemp
echo 'Regression checks passed'
