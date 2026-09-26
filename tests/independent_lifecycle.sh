#!/usr/bin/env bash
# Mocks are invoked through sourced production functions.
# shellcheck disable=SC2317,SC2329
set -euo pipefail
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export REALITY_ROOT_PREFIX="$TEST_ROOT"
# shellcheck disable=SC1090
source <(sed '$d' reality.sh)
export SERVICE_GROUP=root INIT=systemd
service_stop() { :; }
systemctl() { :; }
chown() { :; }
chmod() { :; }
install() {
  if [[ "$1" == -d ]]; then mkdir -p "${!#}"; else /usr/bin/install "$@"; fi
}
socks_stop() { :; }
socks_restart() { :; }
START_OK=true
validate_socks_config() { :; }
# Both definitions are used indirectly by production functions.
# shellcheck disable=SC2329,SC2218,SC2317
mktemp() { /usr/bin/mktemp -d "$TEST_ROOT/candidate.XXXXXX"; }
make_socks_service() { [[ "$START_OK" == true ]]; }
remove_socks_service() { rm -rf -- "$SOCKS_DIR"; rm -f -- "$SOCKS_BIN"; }
X_RESTARTS=0
apply_node_change() {
  X_RESTARTS=$((X_RESTARTS + 1))
  rebuild_config "$CONFIG_FILE.new" && mv "$CONFIG_FILE.new" "$CONFIG_FILE"
}
make_service() { X_RESTARTS=$((X_RESTARTS + 1)); }
backup_state "$TEST_ROOT/empty-backup"
[[ -d "$TEST_ROOT/empty-backup" ]]
write_ss_env 192.0.2.1 28388 aes-256-gcm test-pass 'SS Test'
rebuild_config
cp "$CONFIG_FILE" "$TEST_ROOT/ss-original.json"
mkdir "$TEST_ROOT/new-backup"
backup_state "$TEST_ROOT/new-backup"
write_socks_env 192.0.2.1 31080 test-user test-pass Test 192.0.2.1 xray-fixed
apply_socks_change "$TEST_ROOT/new-backup" >/dev/null
[[ "$X_RESTARTS" == 0 ]]
cmp "$CONFIG_FILE" "$TEST_ROOT/ss-original.json"
[[ "$(managed_listeners)" != *31080* ]]
grep -q '"port": 31080' "$SOCKS_CONFIG"
mkdir "$TEST_ROOT/edit-backup"
backup_state "$TEST_ROOT/edit-backup"
cp "$SOCKS_CONFIG" "$TEST_ROOT/edit-backup.json"
write_socks_env 192.0.2.1 31081 other-user other-pass Other 192.0.2.1 xray-fixed
START_OK=false
if apply_socks_change "$TEST_ROOT/edit-backup" >/dev/null; then
  echo 'FAIL: failed SOCKS edit accepted'; exit 1
fi
load_socks
[[ "$SOCKS_PORT" == 31080 && "$SOCKS_USER" == test-user && "$X_RESTARTS" == 0 ]]
cmp "$SOCKS_CONFIG" "$TEST_ROOT/edit-backup.json"
START_OK=true
delete_protocol socks --yes >/dev/null
[[ ! -f "$SOCKS_ENV_FILE" && -f "$SS_ENV_FILE" && "$X_RESTARTS" == 0 ]]
# Migration of old shared Xray SOCKS must remove only that inbound.
write_socks_env 192.0.2.1 31080 test-user test-pass Test 192.0.2.1
rebuild_config
mkdir "$TEST_ROOT/legacy-backup"
backup_state "$TEST_ROOT/legacy-backup"
write_socks_env 192.0.2.1 31080 test-user test-pass Test 192.0.2.1 xray-fixed
START_OK=false
if apply_socks_change "$TEST_ROOT/legacy-backup" >/dev/null; then
  echo 'FAIL: failed migration accepted'; exit 1
fi
load_socks
[[ "$SOCKS_BACKEND" == xray ]]
grep -q socks-in "$CONFIG_FILE"
grep -q ss-in "$CONFIG_FILE"
START_OK=true
X_RESTARTS=0
write_socks_env 192.0.2.1 31080 test-user test-pass Test 192.0.2.1 xray-fixed
apply_socks_change "$TEST_ROOT/legacy-backup" >/dev/null
[[ "$X_RESTARTS" == 1 ]]
if grep -q socks-in "$CONFIG_FILE"; then echo 'FAIL: legacy inbound remains'; exit 1; fi
grep -q ss-in "$CONFIG_FILE"
# Last Xray node deletion must preserve the independent SOCKS metadata/service.
mktemp() { /usr/bin/mktemp -d "$TEST_ROOT/delete.XXXXXX"; }
delete_protocol ss --yes >/dev/null
[[ -f "$SOCKS_ENV_FILE" && -f "$SOCKS_CONFIG" && ! -f "$CONFIG_FILE" && ! -f "$SS_ENV_FILE" ]]

# Exercise actual install/edit entry points: SOCKS-only must not call the main
# installer. Adding SS later must preserve the independent config and identity.
delete_protocol socks --yes >/dev/null
rm -rf -- "$APP_DIR"
MAIN_INSTALLS=0
SOCKS_INSTALLS=0
install_manager() { :; }
public_ip() { printf '192.0.2.1'; }
prompt() {
  case "$1" in
    密码*) printf 'test-pass' ;;
    *) printf '%s' "${2:-test}" ;;
  esac
}
download_socks() {
  SOCKS_INSTALLS=$((SOCKS_INSTALLS + 1))
  mkdir -p "$(dirname "$SOCKS_BIN")"
  touch "$SOCKS_BIN"
}
install_common() {
  MAIN_INSTALLS=$((MAIN_INSTALLS + 1))
  mkdir -p "$(dirname "$XRAY_BIN")"
  touch "$XRAY_BIN"
}
select_ss_method() { printf 'aes-256-gcm'; }
X_RESTARTS=0
configure_socks install >/dev/null
[[ "$SOCKS_INSTALLS" == 1 && "$MAIN_INSTALLS" == 0 && "$X_RESTARTS" == 0 ]]
[[ -f "$SOCKS_BIN" && ! -f "$XRAY_BIN" && ! -f "$CONFIG_FILE" ]]
cp "$SOCKS_CONFIG" "$TEST_ROOT/fixed.saved"
install_ss >/dev/null
[[ "$MAIN_INSTALLS" == 1 && "$X_RESTARTS" == 1 ]]
cmp "$SOCKS_CONFIG" "$TEST_ROOT/fixed.saved"
configure_socks edit >/dev/null
[[ "$MAIN_INSTALLS" == 1 && "$X_RESTARTS" == 1 ]]
cmp "$SOCKS_CONFIG" "$TEST_ROOT/fixed.saved"

# Full uninstall deletes both binaries/configs and the manager, then exits.
touch "$MANAGER_BIN" "$SHORTCUT_BIN"
(uninstall_reality --yes >/dev/null)
[[ ! -d "$APP_DIR" && ! -d "$SOCKS_DIR" && ! -f "$SOCKS_BIN" && ! -f "$XRAY_BIN" ]]
[[ ! -f "$MANAGER_BIN" && ! -f "$SHORTCUT_BIN" ]]
echo 'Independent lifecycle checks passed'
