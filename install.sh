#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REALITY_REPO:-colaxr/reality-onekey}"
BRANCH="${REALITY_BRANCH:-main}"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/reality.sh"
TARGET="/usr/local/bin/reality"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf '请使用 root 用户运行。\n' >&2
  exit 1
fi

if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 "$URL" -o "$TARGET"
elif command -v wget >/dev/null 2>&1; then
  wget -O "$TARGET" "$URL"
else
  printf '请先安装 curl 或 wget。\n' >&2
  exit 1
fi

chmod 755 "$TARGET"
exec "$TARGET" menu
