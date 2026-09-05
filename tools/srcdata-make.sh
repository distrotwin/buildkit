#!/bin/bash
# 本机切好的介质目录 → GHCR 数据镜像（ghcr.io/distrotwin/scratch:<tag>）。
# 用法: srcdata-make.sh <介质目录> <tag>
# 目录里必须已有 .origin（来源锚点）；本脚本补 .manifest（逐文件 sha256），
# 打成 FROM scratch 镜像推上去，最后打印要钉进 conf 的 manifest sha256。
#
# 只在本机跑，不进 CI —— 只有本机够得着厂商站点。
set -eu
DIR=$1; TAG=$2
IMG="ghcr.io/distrotwin/scratch:$TAG"
[ -f "$DIR/.origin" ] || { echo "缺 $DIR/.origin：先写来源锚点再打包" >&2; exit 1; }

# manifest 覆盖除它自身外的所有文件。排序钉死，否则同内容两次打包 manifest 不同。
( cd "$DIR" && find . -type f ! -name .manifest -print0 | sort -z | xargs -0 sha256sum ) > "$DIR/.manifest"
N=$(wc -l < "$DIR/.manifest")
PIN=$(sha256sum "$DIR/.manifest" | cut -d' ' -f1)

# tar 直灌 docker import：不落第二份磁盘拷贝，也绕开 ISO 拷出文件只读
# 导致的清理失败（cp -al 跨设备还会静默退化成嵌套拷贝，实测踩过）。
tar --numeric-owner --owner=0 --group=0 -C "$DIR" \
    --transform 's,^\./,src/,' -cf - . | docker import - "$IMG" >/dev/null
docker push -q "$IMG" >/dev/null

# 推完立刻拉回校验：digest 一致才算发布成功，不拿「push 没报错」当判据
docker rmi "$IMG" >/dev/null
docker pull -q "$IMG" >/dev/null
C=$(docker create "$IMG" /nonexistent)
BACK=$(mktemp -d)
docker cp "$C:/src/.manifest" "$BACK/m" >/dev/null
docker rm "$C" >/dev/null
GOT=$(sha256sum "$BACK/m" | cut -d' ' -f1); rm -rf "$BACK"
[ "$GOT" = "$PIN" ] || { echo "✗ 往返后 manifest 不一致" >&2; exit 1; }

echo "✓ 已发布 $IMG（$N 个文件）"
echo "  conf 里钉这两行："
echo "  SRCDATA_IMAGE=\"$IMG\""
echo "  SRCDATA_MANIFEST_SHA256=\"$PIN\""
