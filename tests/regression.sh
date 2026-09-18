#!/usr/bin/env bash
# Mock functions are invoked indirectly by the sourced production functions.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_ROOT="$(mktemp -d)"
export REALITY_ROOT_PREFIX="$TEST_ROOT"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
# shellcheck disable=SC1090
source <(sed '$d' reality.sh)

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
echo 'Regression checks passed'
