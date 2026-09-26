#!/usr/bin/env bash
# Run as root on Linux; all file mutations are confined to a disposable prefix.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$EUID" == 0 && "$(uname -s)" == Linux ]] || {
  echo 'Permission integration tests require Linux root'; exit 1;
}
TEST_ROOT="$(mktemp -d)"
export REALITY_ROOT_PREFIX="$TEST_ROOT"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
chmod 755 "$TEST_ROOT"
# shellcheck disable=SC1090
source <(sed '$d' reality.sh)
export SERVICE_GROUP
SERVICE_GROUP="$(id -gn nobody)"
export INIT=systemd
mkdir -p "$(dirname "$XRAY_BIN")"
cat >"$XRAY_BIN" <<'EOF'
#!/bin/sh
if [ "$1" = version ]; then echo 'Xray 26.3.27 (test fixture)'; fi
exit 0
EOF
chmod 755 "$XRAY_BIN"

# Keep service/network/binary operations fake, but use real Unix permissions
# and the actual nobody account to verify service access.
systemctl() { return 0; }
setcap() { return 0; }
curl() { printf '{"tag_name":"v26.7.28"}\n'; }
download_xray() {
  if [[ "${FAIL_DOWNLOAD:-false}" == true ]]; then
    chmod 700 "$APP_DIR"
    return 1
  fi
}
verify_service() {
  [[ "$(stat -c '%a' "$APP_DIR")" == 750 ]] || return 1
  [[ "$(stat -c '%a' "$CONFIG_FILE")" == 640 ]] || return 1
  runuser -u nobody -- cat "$CONFIG_FILE" >/dev/null || return 1
  local file
  for file in "$ENV_FILE" "$SS_ENV_FILE" "$SOCKS_ENV_FILE"; do
    [[ -f "$file" ]] || continue
    [[ "$(stat -c '%a' "$file")" == 600 ]] || return 1
    if runuser -u nobody -- test -r "$file"; then return 1; fi
  done
}
write_reality_env 24443 11111111-1111-4111-8111-111111111111 example.com example.com:443 \
  unused public-test aabbccdd 192.0.2.1 chrome 'Permission Test' true
export PRIVATE_KEY='CNbUQuA6-wuMRF2DIaS6R3CUJBa7CGO0wLE8Aj0HoH0'
write_ss_env 192.0.2.1 28388 aes-256-gcm test-password 'SS Test'
write_socks_env 192.0.2.1 31080 test-user test-password 'SOCKS Test' 192.0.2.1
rebuild_config
restore_config_permissions
cp "$SOCKS_ENV_FILE" "$TEST_ROOT/socks.saved"

# Candidate generation must preserve access to the currently running config.
rebuild_config "$TEST_ROOT/candidate.json"
verify_service || { echo 'FAIL: rendering changed live permissions'; exit 1; }

# Updates, including SS-only, must allow the service user to read the config.
for protocol in combined ss-only socks-only; do
  if [[ "$protocol" == ss-only ]]; then
    rm -f "$ENV_FILE" "$SOCKS_ENV_FILE"
    rebuild_config
    restore_config_permissions
  elif [[ "$protocol" == socks-only ]]; then
    rm -f "$ENV_FILE" "$SS_ENV_FILE"
    cp "$TEST_ROOT/socks.saved" "$SOCKS_ENV_FILE"
    rebuild_config
    restore_config_permissions
  fi
  cp "$CONFIG_FILE" "$TEST_ROOT/expected.json"
  update_xray <<<1 >/dev/null
  verify_service || { echo "FAIL: $protocol update permissions"; exit 1; }
  cmp "$TEST_ROOT/expected.json" "$CONFIG_FILE"
  FAIL_DOWNLOAD=true
  if update_xray <<<1 >/dev/null; then
    echo 'FAIL: failed update reported success'; exit 1
  fi
  FAIL_DOWNLOAD=false
  verify_service || { echo "FAIL: $protocol rollback permissions"; exit 1; }
  cmp "$TEST_ROOT/expected.json" "$CONFIG_FILE"
done

# Restoring node state must repair a restrictive directory even without restart.
mkdir "$TEST_ROOT/state"
backup_state "$TEST_ROOT/state"
chmod 700 "$TEST_ROOT/state"
restore_state "$TEST_ROOT/state"
verify_service || { echo 'FAIL: restored node permissions'; exit 1; }

# The dedicated config is readable by the daemon, never its root-only metadata.
write_socks_env 192.0.2.1 31080 test-user test-password Test 192.0.2.1 xray-fixed
install -d -m700 "$SOCKS_DIR"
render_socks_config >"$SOCKS_CONFIG"
socks_permissions
runuser -u nobody -- cat "$SOCKS_CONFIG" >/dev/null
if runuser -u nobody -- test -r "$SOCKS_ENV_FILE"; then
  echo 'FAIL: dedicated SOCKS metadata exposed'; exit 1
fi
[[ "$(stat -c '%a' "$SOCKS_DIR")" == 750 && "$(stat -c '%a' "$SOCKS_CONFIG")" == 640 ]]
rm -f -- "$CONFIG_FILE"
chmod 700 "$APP_DIR" "$SOCKS_DIR"
socks_permissions
runuser -u nobody -- cat "$SOCKS_CONFIG" >/dev/null
echo 'Real service-user permission checks passed'
