#!/bin/bash
# 把 rootfs tarball 导入 docker，按档位设置正确的镜像元数据
set -eu
# 项目根：submodule 布局下脚本父目录是 buildkit 根，不是项目根，所以只能取调用方的 cwd
ROOT=${ROOT:-$PWD}
DID=$1; TIER=$2
. "$ROOT/distros/$DID.conf"
TAR="$ROOT/out/$DID-$TIER.tar"
[ -s "$TAR" ] || { echo "缺 $TAR"; exit 1; }
OPTS=(-c 'CMD ["/bin/bash"]' -c 'ENV LANG=C.UTF-8'
      -c "LABEL org.opencontainers.image.title=\"$DISPLAY_NAME\""
      -c "LABEL cn.internal.tier=\"$TIER\""
      -c "LABEL cn.internal.build-method=\"${METHOD}\""
      -c "LABEL cn.internal.suite=\"${SUITE:-n/a}\""
      -c "LABEL cn.internal.expect-glibc=\"${EXPECT_GLIBC}\""
      -c "LABEL cn.internal.expect-libstdcpp=\"${EXPECT_LIBSTDCPP}\"")
# systemd 忽略 SIGTERM 只认 SIGRTMIN+3。判据是 tarball 里有没有 systemctl，
# 不能按档位名（麒麟 V10 的 micro 档也带 systemd）。
if tar tf "$TAR" 2>/dev/null | grep -qE '(usr/)?bin/systemctl$'; then
  OPTS+=(-c 'STOPSIGNAL SIGRTMIN+3')
fi
docker import "${OPTS[@]}" "$TAR" "$IMAGE:$TIER" >/dev/null
echo "  导入 $IMAGE:$TIER $(docker images "$IMAGE:$TIER" --format '{{.Size}}')"
