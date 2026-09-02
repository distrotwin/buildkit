#!/bin/bash
# 造本地源：① 重打包厂商坏包（去掉伪造依赖）② 造容器假包满足内核侧依赖
# BK = buildkit 自身的根（lib/build/test/tools/gate 在这里）
# ROOT = 项目根（distros/out/localrepo/keys 在这里）
# submodule 布局下两者不是同一个目录，混用会在「找得到 conf 却找不到 common.sh」
# 这种地方失败，报错离真因很远。
BK="${BK:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
set -eu
ROOT="${ROOT:-/w}"; . "$BK/lib/common.sh"
DID=$1
. "$ROOT/distros/$DID.conf"
# 与主构建用同一个 epoch，否则重打包的 deb 时间戳不一致，最终产物哈希会漂
SOURCE_DATE_EPOCH=$(derive_epoch "${MIRROR:-}" "${SUITE:-}")
export SOURCE_DATE_EPOCH
log "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
REPO="$ROOT/localrepo/$DID"
rm -rf "$REPO"; mkdir -p "$REPO"

# ① 重打包
if [ -n "${REPACK_DEBS:-}" ]; then
  for p in $REPACK_DEBS; do
    tmp=$(mktemp -d); cd "$tmp"
    # 走 fetch_exact：这个源会「返回 200 且 Content-Length 正确、body 零字节」，
    # 实测撞过一次——35 KB 的 deb 等满 180 秒收到 0 字节。靠 --max-time 卡时长
    # 区分不了慢与卡死，见 lib/common.sh::fetch_exact 的说明。
    fetch_exact "${MIRROR%/}/$p" "$(basename "$p")" 5 || die "下不到 $p（五轮重试均失败）"
    deb=$(basename "$p")
    dpkg-deb -R "$deb" x
    chmod 755 x x/DEBIAN
    old=$(grep '^Depends:' x/DEBIAN/control || true)
    python3 - "$PWD/x/DEBIAN/control" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
def fix(m):
    deps=[d.strip() for d in m.group(1).split(',')]
    keep=[d for d in deps if not re.match(r'^(g\+\+|gcc)(\s|$|\()', d)]
    return 'Depends: '+', '.join(keep)
s=re.sub(r'^Depends: (.*)$', fix, s, flags=re.M)
# 版本打后缀，便于审计一眼看出被改过
s=re.sub(r'^(Version: .*)$', r'\1+nogccdep1', s, flags=re.M)
open(p,'w').write(s)
PY
    newver=$(awk '/^Version:/{print $2}' x/DEBIAN/control)
    pkg=$(awk '/^Package:/{print $2}' x/DEBIAN/control)
    # 归一时间戳，让重打包出来的 deb 本身可复现（否则它的 sha256 不能当审计锚点）
    find x -exec touch -h -d "@${SOURCE_DATE_EPOCH:-1700000000}" {} + 2>/dev/null || true
    # 架构取自包自己的 control（Architecture: all 的包不能被改名成某个具体架构）
    parch=$(awk '/^Architecture:/{print $2}' x/DEBIAN/control)
    dpkg-deb --build --root-owner-group x "$REPO/${pkg}_${newver}_${parch}.deb"
    log "重打包 $pkg -> $newver   原 [$old]"
    cd /; rm -rf "$tmp"
  done
fi

# ② 容器假包
if [ -n "${STUB_PROVIDES:-}" ]; then
  tmp=$(mktemp -d); umask 022
  mkdir -p "$tmp/s/DEBIAN" "$tmp/s/usr/share/doc/container-stub"
  chmod 755 "$tmp/s" "$tmp/s/DEBIAN"
  cat > "$tmp/s/DEBIAN/control" <<EOF
Package: container-stub
Version: 1.0
Architecture: all
Maintainer: domestic-os-images build <build@localhost>
Provides: $STUB_PROVIDES
Section: misc
Priority: optional
Description: 容器环境假包
 满足对内核侧组件（$STUB_PROVIDES）的依赖声明。
 这些组件在容器里没有意义（共享宿主内核），装真包会生成按宿主 uname -r
 打的 initrd，或让 dpkg 段错误。本包只提供依赖关系，不含任何可执行内容。
EOF
  printf '本包由构建系统生成，非发行版官方包。见 %s/README.md\n' "$ROOT" \
      > "$tmp/s/usr/share/doc/container-stub/README"
  # copyright 是 Debian policy 的硬性要求。这个包是本系统自己造的，
  # 缺了就是我们的问题（厂商包缺的另算，见 README 缺陷表）。
  cat > "$tmp/s/usr/share/doc/container-stub/copyright" <<'CPY'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: container-stub
Comment: 本包由 domestic-os-images 构建系统生成，不含任何上游代码，
 仅通过 Provides 满足对内核侧组件的依赖声明。

Files: *
Copyright: 本包无版权内容（仅元数据）
License: public-domain
 该包不含任何可版权化的内容。
CPY
  find "$tmp/s" -type d -exec chmod 755 {} + ; find "$tmp/s" -type f -exec chmod 644 {} +
  chmod 755 "$tmp/s/DEBIAN"
  find "$tmp/s" -exec touch -h -d "@${SOURCE_DATE_EPOCH:-1700000000}" {} + 2>/dev/null || true
  dpkg-deb --build --root-owner-group "$tmp/s" "$REPO/container-stub_1.0_all.deb"
  log "假包 container-stub  Provides: $STUB_PROVIDES"
  rm -rf "$tmp"
fi

# `A && B` 在 set -e 下 A 失败不会中止脚本，所以必须显式检查产物；
# 否则留下空 Packages，后面 apt 因"包被 pin 到 -1 又没人 Provides"失败，报错指不到根因。
cd "$REPO"
dpkg-scanpackages -m . /dev/null > Packages 2>"$REPO/.scan.err" || {
  log "!! dpkg-scanpackages 失败"; cat "$REPO/.scan.err" >&2; exit 1; }
[ -s Packages ] || die "本地源索引为空（$REPO/Packages）"
gzip -9nkf Packages    # -n 不嵌 mtime，让索引本身可复现
rm -f "$REPO/.scan.err"
log "本地源 $REPO：$(ls -1 *.deb 2>/dev/null | wc -l) 个包，索引 $(wc -l < Packages) 行"
