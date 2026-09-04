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

# 解释器路径要从 update-binfmts 问，而不是只看 /proc。
# 关键理由：**mmdebstrap 的可执行性检查走 `update-binfmts --display`**，不看
# /proc 也不做实际 exec。直接往 /proc/sys/fs/binfmt_misc/register 写的注册项
# 它看不见，于是即使 chroot 里明明能跑，mmdebstrap 仍报
#   E: <arch> can neither be executed natively nor via qemu user emulation
# 那句话读起来像 binfmt 没配，实际是配在了它不看的地方。
HAVE_UB=no
command -v update-binfmts >/dev/null 2>&1 && HAVE_UB=yes

interp=""
if [ "$HAVE_UB" = yes ]; then
  interp=$(update-binfmts --display "$BINFMT_NAME" 2>/dev/null \
           | sed -n 's/^ *interpreter = //p' | head -1)
fi
if [ -z "$interp" ] && [ -e "/proc/sys/fs/binfmt_misc/$BINFMT_NAME" ]; then
  interp=$(sed -n 's/^interpreter //p' "/proc/sys/fs/binfmt_misc/$BINFMT_NAME")
fi
cur=""
[ -n "$interp" ] && [ -x "$interp" ] \
  && cur=$("$interp" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
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

# 解包前先确认解压器在。deb 的 data.tar 可能是 .xz/.zst/.gz，缺了对应工具时
# tar 报的是 `xz: Cannot exec: No such file or directory` 然后 exit 2，而脚本
# 若不检查就会继续往下走、用上一次残留的注册项"成功"——那种假通过最难查。
for t in ar tar file sha256sum; do
  command -v "$t" >/dev/null 2>&1 || { echo "[ensure-qemu] 缺少 $t"; exit 1; }
done
(cd "$TMP" && ar t q.deb) | grep -q '^data\.tar' || { echo "[ensure-qemu] deb 里没有 data.tar"; exit 1; }
DATA=$( (cd "$TMP" && ar t q.deb) | grep '^data\.tar' | head -1)
case "$DATA" in
  *.xz)  command -v xz  >/dev/null 2>&1 || { echo "[ensure-qemu] 需要 xz-utils 才能解开 $DATA"; exit 1; } ;;
  *.zst) command -v zstd >/dev/null 2>&1 || { echo "[ensure-qemu] 需要 zstd 才能解开 $DATA"; exit 1; } ;;
esac
(cd "$TMP" && ar x q.deb && tar xf "$DATA") \
  || { echo "[ensure-qemu] 解开 $DATA 失败"; exit 1; }
SRC=$(find "$TMP" -name qemu-loongarch64 -type f | head -1)
[ -n "$SRC" ] || { echo "[ensure-qemu] deb 里找不到 qemu-loongarch64"; exit 1; }
got=$(sha256sum "$SRC" | cut -d' ' -f1)
[ "$got" = "$BIN_SHA" ] || { echo "[ensure-qemu] 二进制校验不符：期望 $BIN_SHA 实得 $got"; exit 1; }
# 必须是静态的，否则换到别的发行版上跑不起来（Debian 13 的动态版要 glibc 2.41）
file "$SRC" | grep -q 'static-pie' || { echo "[ensure-qemu] 这个二进制不是 static-pie，换宿主会失效"; exit 1; }

$SUDO mkdir -p "$DST"
$SUDO install -m 0755 "$SRC" "$DST/qemu-loongarch64"
echo "[ensure-qemu] 已装 $DST/qemu-loongarch64 ($("$DST/qemu-loongarch64" --version | head -1))"

# 把 update-binfmts 指向的那个解释器**就地换掉**，而不是另注册一条：
# 它的定义文件里写死了路径，另注册会让 update-binfmts 与 /proc 两处不一致，
# 而 mmdebstrap 只看前者。换之前备份，便于回退。
if [ "$HAVE_UB" = yes ] && [ -n "$interp" ]; then
  real=$(readlink -f "$interp" 2>/dev/null || printf '%s' "$interp")
  if [ -e "$real" ]; then
    $SUDO cp -a "$real" "$real.pre-ensure-qemu" 2>/dev/null || true
    $SUDO install -m 0755 "$SRC" "$real"
    echo "[ensure-qemu] 已就地替换 $real（原件存为 $real.pre-ensure-qemu）"
  fi
fi

# ── 重注册 ────────────────────────────────────────────────────────────────────
# 必须重注册而不是改软链：原注册项带 F 标志，内核在**注册时**就打开并持有解释器，
# 之后改路径指向不生效。
# magic/mask 用**字面** \x 文本让内核自己解码；不能先在 shell 里转成真字节，
# magic 含 NUL，shell 变量存不了，会被静默截断而 register 只报 Invalid argument。
MAGIC='\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x02\x01'
MASK='\xff\xff\xff\xff\xff\xff\xff\xfc\x00\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
if [ "$HAVE_UB" = yes ]; then
  # 走发行版工具重注册：F 标志让内核在注册时打开并持有解释器，所以换了文件
  # 必须 disable+enable 才生效，改软链或改文件内容都不够。
  # 不要把 update-binfmts 的输出丢掉：它失败时那句话就是唯一的线索。
  dout=$($SUDO update-binfmts --disable "$BINFMT_NAME" 2>&1) || true
  [ -n "$dout" ] && printf '%s\n' "$dout" | sed 's/^/[ensure-qemu]   disable: /'
  if ! eout=$($SUDO update-binfmts --enable "$BINFMT_NAME" 2>&1); then
    printf '%s\n' "$eout" | sed 's/^/[ensure-qemu]   enable: /'
    # 退一步：用 --import 重新读定义文件再启用。qemu-user-static 的定义在
    # /usr/share/binfmts/<name>，--import 会按它重建数据库条目。
    iout=$($SUDO update-binfmts --import "$BINFMT_NAME" 2>&1) || true
    [ -n "$iout" ] && printf '%s\n' "$iout" | sed 's/^/[ensure-qemu]   import: /'
    if ! eout2=$($SUDO update-binfmts --enable "$BINFMT_NAME" 2>&1); then
      printf '%s\n' "$eout2" | sed 's/^/[ensure-qemu]   enable(2): /'
      echo "[ensure-qemu] update-binfmts 启用失败"; exit 1
    fi
  fi
else
  # 没有 update-binfmts 时退回直接写 /proc。注意这种注册 mmdebstrap 看不见，
  # 只适合手工验证，不适合跑构建。
  echo "[ensure-qemu] ⚠ 没有 update-binfmts，退回直写 /proc（mmdebstrap 看不到这种注册）"
  [ -e "/proc/sys/fs/binfmt_misc/$BINFMT_NAME" ] \
    && echo -1 | $SUDO tee "/proc/sys/fs/binfmt_misc/$BINFMT_NAME" >/dev/null
  echo ":$BINFMT_NAME:M::$MAGIC:$MASK:$DST/qemu-loongarch64:POCF" \
    | $SUDO tee /proc/sys/fs/binfmt_misc/register >/dev/null
fi
[ -e "/proc/sys/fs/binfmt_misc/$BINFMT_NAME" ] || { echo "[ensure-qemu] 注册后条目不存在"; exit 1; }

# 判据挂在结果上：注册项必须真的指向我们装的那个，且版本达标。
now_interp=$(sed -n 's/^interpreter //p' "/proc/sys/fs/binfmt_misc/$BINFMT_NAME")
now_ver=$("$now_interp" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
[ -n "$now_ver" ] || { echo "[ensure-qemu] 注册项 $now_interp 问不出版本"; exit 1; }
[ "${now_ver%%.*}" -ge "$NEED_MAJOR" ] \
  || { echo "[ensure-qemu] 注册后版本仍是 $now_ver（要求 ≥ $NEED_MAJOR）"; exit 1; }
# update-binfmts 那一侧也要达标 —— mmdebstrap 只看它。两处都核才算数。
if [ "$HAVE_UB" = yes ]; then
  ub=$(update-binfmts --display "$BINFMT_NAME" 2>/dev/null)
  printf '%s' "$ub" | grep -q 'enabled' \
    || { echo "[ensure-qemu] update-binfmts 里 $BINFMT_NAME 不是 enabled"; exit 1; }
  ubi=$(printf '%s' "$ub" | sed -n 's/^ *interpreter = //p' | head -1)
  ubv=$([ -x "$ubi" ] && "$ubi" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ "${ubv%%.*}" -ge "$NEED_MAJOR" ] 2>/dev/null \
    || { echo "[ensure-qemu] update-binfmts 指向的 $ubi 版本是 ${ubv:-未知}"; exit 1; }
  echo "[ensure-qemu] ✓ update-binfmts 侧也是 QEMU $ubv"
fi
echo "[ensure-qemu] ✓ $BINFMT_NAME 现指向 QEMU $now_ver（$now_interp）"
