#!/bin/bash
# 确保 binfmt 里注册的 QEMU 新到足以跑目标架构；不够就换成钉住的那一版。
#
# 为什么需要这一层：LoongArch 有两套互不兼容的 ABI，而**旧世界要求 QEMU ≥ 9**。
# 旧世界的 glibc 仍在调 syscall 79/80，上游 QEMU 8.x 没实现，症状是
#   Unknown syscall 80        （strace 下）
#   cannot stat shared object: Error 38   （ENOSYS，装载器报出来的样子）
# 而 Ubuntu 24.04 只带 8.2.2、没有 backports，所以 apt 装不到够新的。
#
# 实测依据（本机 2026-09）：同一份旧世界 bash，QEMU 8.2.2 报 Unknown syscall 80，
# QEMU 10.0.11 正常跑出 MACHTYPE=loongarch64-unknown-linux-gnu。新世界两个版本都行。
#
# 取材钉死：Debian 13 的 qemu-user 里那个 qemu-loongarch64 是 static-pie、零 glibc
# 依赖，实测能直接在 glibc 2.39 的宿主上跑。整包 68 MB，只取需要的那一个二进制。
set -eu

ARCH="${1:?用法: ensure-qemu.sh <arch>}"

# 以 root 跑时不要求有 sudo：GitHub runner 上有 sudo 但不是 root，容器里常常
# 是 root 但没装 sudo。无条件写 sudo 会让后者直接失败在 command not found。
SUDO=""
[ "$(id -u)" = 0 ] || SUDO=sudo

# 各架构要求的最低 QEMU 大版本。没列的按 0 处理（用发行版自带的即可）。
case "$ARCH" in
  loongarch64) NEED_MAJOR=9  ;;   # 旧世界，见上
  loong64)     NEED_MAJOR=0  ;;   # 新世界，8.2 起可用，发行版自带够了
  *)           NEED_MAJOR=0  ;;
esac
[ "$NEED_MAJOR" = 0 ] && { echo "[ensure-qemu] $ARCH 不需要更新版 QEMU"; exit 0; }

BINFMT_NAME=qemu-loongarch64
case "$ARCH" in
  loong64|loongarch64) BINFMT_NAME=qemu-loongarch64 ;;
  *) echo "[ensure-qemu] 还没为 $ARCH 登记 binfmt 名字"; exit 1 ;;
esac

cur=""
if [ -e "/proc/sys/fs/binfmt_misc/$BINFMT_NAME" ]; then
  interp=$(sed -n 's/^interpreter //p' "/proc/sys/fs/binfmt_misc/$BINFMT_NAME")
  [ -n "$interp" ] && cur=$("$interp" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
fi
cur_major=${cur%%.*}
echo "[ensure-qemu] 当前注册的 QEMU: ${cur:-未知}（需要 ≥ ${NEED_MAJOR}）"
if [ -n "${cur_major:-}" ] && [ "${cur_major:-0}" -ge "$NEED_MAJOR" ] 2>/dev/null; then
  echo "[ensure-qemu] 已满足，不改动"
  exit 0
fi

# ── 取那一个二进制 ─────────────────────────────────────────────────────────────
# 允许用本地已有的 deb（离线复现与本地预演用）。给了 QEMU_DEB 就不下载，
# 但校验一步都不省 —— 来源换了不等于可以不核。
DEB_URL="${QEMU_DEB_URL:-https://deb.debian.org/debian/pool/main/q/qemu/qemu-user_10.0.11+ds-0+deb13u1_amd64.deb}"
DEB_SHA=6b6fea55551fbcc1eb30e146ad5abdfbb49f8fa8c5998016242126de4d7f80df
BIN_SHA=f1519bf750428ffbcd36f2a83d7f73cb98fa7f92f93f4deced496e68d7e8cca7
DST=/usr/local/lib/qemu-binfmt
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -n "${QEMU_DEB:-}" ] && [ -s "${QEMU_DEB}" ]; then
  echo "[ensure-qemu] 用本地 deb: $QEMU_DEB"
  cp "$QEMU_DEB" "$TMP/q.deb"
else
  echo "[ensure-qemu] 取 $DEB_URL"
  curl -fsSL --retry 3 --connect-timeout 20 --speed-limit 4096 --speed-time 60 \
    -o "$TMP/q.deb" "$DEB_URL"
fi
got=$(sha256sum "$TMP/q.deb" | cut -d' ' -f1)
[ "$got" = "$DEB_SHA" ] || { echo "[ensure-qemu] deb 校验不符：期望 $DEB_SHA 实得 $got"; exit 1; }

(cd "$TMP" && ar x q.deb && tar xf data.tar.* ./usr/bin/qemu-loongarch64 2>/dev/null \
   || tar xf data.tar.*)
SRC=$(find "$TMP" -name qemu-loongarch64 -type f | head -1)
[ -n "$SRC" ] || { echo "[ensure-qemu] deb 里找不到 qemu-loongarch64"; exit 1; }
got=$(sha256sum "$SRC" | cut -d' ' -f1)
[ "$got" = "$BIN_SHA" ] || { echo "[ensure-qemu] 二进制校验不符：期望 $BIN_SHA 实得 $got"; exit 1; }
# 必须是静态的，否则换到别的发行版上跑不起来（Debian 13 的动态版要 glibc 2.41）
file "$SRC" | grep -q 'static-pie' || { echo "[ensure-qemu] 这个二进制不是 static-pie，换宿主会失效"; exit 1; }

$SUDO mkdir -p "$DST"
$SUDO install -m 0755 "$SRC" "$DST/qemu-loongarch64"
echo "[ensure-qemu] 已装 $DST/qemu-loongarch64 ($("$DST/qemu-loongarch64" --version | head -1))"

# ── 重注册 ────────────────────────────────────────────────────────────────────
# 必须重注册而不是改软链：原注册项带 F 标志，内核在**注册时**就打开并持有解释器，
# 之后改路径指向不生效。
# magic/mask 用**字面** \x 文本让内核自己解码；不能先在 shell 里转成真字节，
# magic 含 NUL，shell 变量存不了，会被静默截断而 register 只报 Invalid argument。
MAGIC='\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x02\x01'
MASK='\xff\xff\xff\xff\xff\xff\xff\xfc\x00\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
if [ -e "/proc/sys/fs/binfmt_misc/$BINFMT_NAME" ]; then
  echo -1 | $SUDO tee "/proc/sys/fs/binfmt_misc/$BINFMT_NAME" >/dev/null
  echo "[ensure-qemu] 已注销旧的 $BINFMT_NAME"
fi
echo ":$BINFMT_NAME:M::$MAGIC:$MASK:$DST/qemu-loongarch64:POCF" \
  | $SUDO tee /proc/sys/fs/binfmt_misc/register >/dev/null
[ -e "/proc/sys/fs/binfmt_misc/$BINFMT_NAME" ] || { echo "[ensure-qemu] 注册后条目不存在"; exit 1; }

# 判据挂在结果上：注册项必须真的指向我们装的那个，且版本达标。
now_interp=$(sed -n 's/^interpreter //p' "/proc/sys/fs/binfmt_misc/$BINFMT_NAME")
now_ver=$("$now_interp" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ "$now_interp" = "$DST/qemu-loongarch64" ] \
  || { echo "[ensure-qemu] 注册项指向 $now_interp，不是我们装的那个"; exit 1; }
[ "${now_ver%%.*}" -ge "$NEED_MAJOR" ] \
  || { echo "[ensure-qemu] 注册后版本仍是 $now_ver"; exit 1; }
echo "[ensure-qemu] ✓ $BINFMT_NAME 现指向 QEMU $now_ver"
