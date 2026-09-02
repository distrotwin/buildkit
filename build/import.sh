#!/bin/bash
# 把 rootfs tarball 导入 docker，按档位设置正确的镜像元数据
set -eu
# 项目根：submodule 布局下脚本父目录是 buildkit 根，不是项目根，所以只能取调用方的 cwd
ROOT=${ROOT:-$PWD}
# 与 build.sh 同签名：import.sh <did> <tier...>。
# 原先是 DID=$1; TIER=$2，多余的档位被静默忽略——调用方写
# `import.sh v11 micro base devel` 时只导入了 micro，而 verify 随后报
# 「kylin-v11:base 不存在」，看起来像构建没产出 base。
# selfhost 路径在 build-selfhost.sh 里自己 docker import，不经过本脚本，
# 于是这个缺陷被两条路径的差异藏了很久。
BK="${BK:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
. "$BK/lib/arch.sh"
DID=${1:?用法: import.sh <did> <tier...>}; shift
. "$ROOT/distros/$DID.conf"

import_one() {
TIER=$1
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
# 平台戳必须显式给。docker import 默认按守护进程的架构写 config，
# loong64 的 rootfs 在 amd64 runner 上导入就会被标成 linux/amd64，
# 而 docker manifest create 的平台取自这个字段——manifest list 于是说谎。
docker import --platform "linux/$ARCH" "${OPTS[@]}" "$TAR" "$IMAGE:$TIER"
# 后置断言：既查 ARCH 传对了，也查 docker 真的认了这个平台名
_got=$(docker image inspect "$IMAGE:$TIER" --format '{{.Architecture}}')
[ "$_got" = "$ARCH" ] || { echo "致命: $IMAGE:$TIER 的架构戳是 $_got，期望 $ARCH"; exit 1; }
echo "  导入 $IMAGE:$TIER $(docker images "$IMAGE:$TIER" --format '{{.Size}}') 架构 $_got"
}

for _t in "${@:-micro base devel}"; do import_one "$_t"; done
