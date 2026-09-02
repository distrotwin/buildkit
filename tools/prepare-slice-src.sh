#!/bin/bash
# 准备切片源：抽 squashfs -> 校验 sha256 -> unsquashfs -> 落一个带指纹的标记。
# 指纹标记是必须的：目录被改过、被换过、上次只解了一半，构建都会照常进行。
set -eu
BK="${BK:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
ROOT="${ROOT:-$PWD}"
. "$BK/lib/common.sh"
DID=${1:?用法: prepare-slice-src.sh <did>}

# 取配置走 conf-get.sh：它先 source arch.sh，所以 ISO_URL 里的 ${ARCH}
# 与按架构的 case 块都能正确展开
read -r ISO_URL   < <("$BK/tools/conf-get.sh" "$DID" ISO_URL)
read -r SQ_PATH   < <("$BK/tools/conf-get.sh" "$DID" ISO_SQUASHFS_PATH)
read -r SQ_SHA    < <("$BK/tools/conf-get.sh" "$DID" SQUASHFS_SHA256)
read -r SRC_ROOTFS< <("$BK/tools/conf-get.sh" "$DID" SRC_ROOTFS)
[ -n "$ISO_URL" ]    || die "conf 里缺 ISO_URL"
[ -n "$SQ_PATH" ]    || die "conf 里缺 ISO_SQUASHFS_PATH"
[ -n "$SRC_ROOTFS" ] || die "conf 里缺 SRC_ROOTFS"

SQ="$ROOT/iso/$DID-$ARCH-filesystem.squashfs"
python3 "$BK/tools/fetch-squashfs.py" "$ISO_URL" "$SQ_PATH" "$SQ" "$SQ_SHA"

if [ "$(cat "$SRC_ROOTFS/.verified" 2>/dev/null)" = "$SQ_SHA" ]; then
  log "[$DID/$ARCH] 切片源已就绪且指纹一致（$(du -sh "$SRC_ROOTFS" | cut -f1)）"
  exit 0
fi

# unsquashfs 须以 root 跑才能保住属主；xattr 在 rootless 下写不了
log "[$DID/$ARCH] unsquashfs -> $SRC_ROOTFS"
rm -rf "$SRC_ROOTFS"; mkdir -p "$(dirname "$SRC_ROOTFS")"
unsquashfs -no-progress -no-xattrs -d "$SRC_ROOTFS" "$SQ" 2>&1 | tail -2 || true
[ -x "$SRC_ROOTFS/bin/sh" ] || [ -x "$SRC_ROOTFS/usr/bin/sh" ] \
  || die "解包后的 rootfs 里没有 sh，unsquashfs 多半没成"
printf '%s' "$SQ_SHA" > "$SRC_ROOTFS/.verified"
log "[$DID/$ARCH] 切片源就绪（$(du -sh "$SRC_ROOTFS" | cut -f1)）"
