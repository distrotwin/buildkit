#!/bin/bash
# runner 侧：从数据镜像取回介质到 $ROOT/media/$MEDIA_DIR，并逐文件验 manifest。
# 用法: srcdata-fetch.sh <distro-id>
# conf 需给 SRCDATA_IMAGE / SRCDATA_MANIFEST_SHA256 / MEDIA_DIR。
set -eu
DID=$1
BK=$(cd "$(dirname "$0")/.." && pwd)
ROOT=${ROOT:?}
g(){ "$BK/tools/conf-get.sh" "$DID" "$1"; }
IMG=$(g SRCDATA_IMAGE); PIN=$(g SRCDATA_MANIFEST_SHA256); MD=$(g MEDIA_DIR)
[ -n "$IMG" ] || { echo "conf 没给 SRCDATA_IMAGE" >&2; exit 1; }
[ -n "$PIN" ] || { echo "conf 没给 SRCDATA_MANIFEST_SHA256（不钉 manifest 的话镜像被换掉不会被发现）" >&2; exit 1; }
[ -n "$MD" ]  || { echo "conf 没给 MEDIA_DIR" >&2; exit 1; }
DST="$ROOT/media/$MD"

# 幂等：已取过且 manifest 指纹相符就不再拉
if [ -f "$DST/.manifest" ] && [ "$(sha256sum "$DST/.manifest" | cut -d' ' -f1)" = "$PIN" ]; then
  echo "介质已就位（manifest 相符），跳过拉取"
  exit 0
fi
rm -rf "$DST"; mkdir -p "$(dirname "$DST")"
docker pull -q "$IMG" >/dev/null
C=$(docker create "$IMG" /nonexistent)   # scratch 无 CMD，必须给个永不执行的参数
docker cp "$C:/src" "$DST"
docker rm "$C" >/dev/null

# 两道门禁，缺一不可：
# ① manifest 文件本身与 conf 钉的指纹一致 —— 防整份 manifest 被换
# ② 逐文件与 manifest 一致 —— 防 manifest 对了但内容缺损
GOT=$(sha256sum "$DST/.manifest" | cut -d' ' -f1)
[ "$GOT" = "$PIN" ] || { echo "✗ manifest 指纹不符：期望 $PIN 实得 $GOT" >&2; exit 1; }
( cd "$DST" && sha256sum -c --quiet .manifest ) || { echo "✗ 介质内容与 manifest 不符" >&2; exit 1; }
N=$(wc -l < "$DST/.manifest")
echo "✓ 介质就位：$DST（$N 个文件，manifest 验过）"
echo "  来源锚点（.origin）："
sed 's/^/    /' "$DST/.origin"
