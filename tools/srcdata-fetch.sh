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
# 不用 docker cp：它在客户端按介质原样的权限位落盘，而 ISO 拷出的目录是 555，
# 非 root 的 CLI 建完 555 目录就没法往里建子目录（mkdir permission denied）。
# export + tar --no-same-permissions 按 umask 落盘，传输不依赖介质的权限位。
_tmp=$(mktemp -d)
docker export "$C" | tar -C "$_tmp" -x --no-same-owner --no-same-permissions src
docker rm "$C" >/dev/null
mv "$_tmp/src" "$DST"; rmdir "$_tmp"
# 介质里的 555 目录落盘后连自己都删不掉（下次幂等重取的 rm -rf 会卡住）。
# 只补目录：文件的权限位是被试内容的一部分（磐石 /etc/shadow 是 444，
# 整树 chmod 会把它抹成 644，镜像里的 shadow 权限就失真了——实测踩过）。
find "$DST" -type d -exec chmod u+w {} +

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
