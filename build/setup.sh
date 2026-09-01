#!/bin/bash
# mmdebstrap --setup-hook：$1 = rootfs（解包前）。写 apt pin，把指定包钉成永不安装。
set -eu
ROOT="${ROOT:-/w}"; DID="${DID:?}"
. "$ROOT/distros/$DID.conf"
R=$1

[ -n "${PIN_NEVER:-}" ] || exit 0
mkdir -p "$R/etc/apt/preferences.d"
{
  echo "# 由构建系统写入：这些包在容器里有害或无意义，由 container-stub 的 Provides 满足依赖"
  for p in $PIN_NEVER; do
    printf 'Package: %s\nPin: release *\nPin-Priority: -1\n\n' "$p"
  done
} > "$R/etc/apt/preferences.d/99-container-never-install"
