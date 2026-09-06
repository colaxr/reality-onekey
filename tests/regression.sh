#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1090
source <(sed '$d' reality.sh)

# No service, package manager or system file is changed by these mocks.
sleep() { :; }
cat() { printf '42\n'; }
sed() { printf '26996\n'; }
kill() { return 0; }
tail() { :; }
service_listening() { return 0; }
INIT=openrc
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
unset -f cat sed kill tail sleep service_listening

PKG=apt
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
echo 'Regression checks passed'
