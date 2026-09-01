#!/bin/bash
# 生成产物清单：精确包版本 + 构建元数据，供审计与"两次构建是否一致"对账
set -eu
# 项目根：submodule 布局下脚本父目录是 buildkit 根，不是项目根，所以只能取调用方的 cwd
ROOT=${ROOT:-$PWD}
DID=$1; TIER=$2
. "$ROOT/distros/$DID.conf"
IMG="$IMAGE:$TIER"
OUT="$ROOT/out/$DID-$TIER.manifest"
{
  echo "# 产物清单 $IMG"
  echo "# 生成时间(UTC): $(date -u +%FT%TZ)"
  echo "# 构建方法: $METHOD"
  echo "# 源: ${MIRROR:-n/a} ${SUITE:-n/a} ${COMPONENTS:-n/a}"
  if [ -f "$ROOT/out/$DID-$TIER.tar" ]; then
    echo "# tarball sha256: $(sha256sum "$ROOT/out/$DID-$TIER.tar" | cut -d' ' -f1)"
    # 字节数也记下来：仓库不分发 tar，别人只能靠 manifest 复核体积
    echo "# tarball bytes: $(stat -c %s "$ROOT/out/$DID-$TIER.tar")"
    # 镜像 ID：让「采集之后又重建」这类漂移可被机器发现 —— mtime 守卫抓不到它
    echo "# image id: $(docker image inspect "$IMG" --format '{{.Id}}' 2>/dev/null | cut -c8-19)"
  else
    echo "# tarball sha256: n/a（该路径不产 tarball）"
  fi
  # 复现所必需的三项锚点：时间戳基准、仓库快照标识、本地源里被改过的包
  # `$(cat 不存在的文件)` 在 set -e 下会让整个脚本退出（kylin10 没有 .epoch，
  # 表现为清单只剩头部、包列表全空，而 make 的 @for 循环把失败吞了）
  ep="${SOURCE_DATE_EPOCH:-$(cat "$ROOT/out/$DID.epoch" 2>/dev/null || true)}"
  [ -n "$ep" ] || ep=$(sed -n 's/^SOURCE_DATE_EPOCH=//p' "$ROOT/distros/$DID.conf" 2>/dev/null | tr -d '"' | head -1)
  echo "# SOURCE_DATE_EPOCH: ${ep:-n/a（该路径不归一时间戳，见 report.md §8（可复现性））}"
  if [ -n "${MIRROR:-}" ]; then
    ir=$(curl -fsS --max-time 40 "${MIRROR%/}/dists/$SUITE/InRelease" 2>/dev/null | sha256sum | cut -d" " -f1)
    echo "# InRelease sha256: ${ir:-取不到}"
  fi
  # 注意 set -e：`[ -f x ] && echo` 作为 for 循环体的最后一条命令，
  # glob 无匹配时会让整个 for 返回非 0 并中止脚本（kylin10 的 localrepo 就没有 deb），
  # 表现为清单只剩头部、包列表全空。必须兜 || true。
  for d in "$ROOT/localrepo/$DID"/*.deb; do
    if [ -f "$d" ]; then echo "# localrepo: $(basename "$d") $(sha256sum "$d" | cut -d' ' -f1)"; fi
  done || true
  echo "# 镜像 ID: $(docker images "$IMG" --format '{{.ID}}' 2>/dev/null)"
  echo "# 预期基线: glibc=$EXPECT_GLIBC libstdc++=$EXPECT_LIBSTDCPP GLIBCXX=$EXPECT_GLIBCXX"
  echo "#"
    # 包清单按**包管理系**取。原先只用 dpkg-query，rpm 系镜像会拿到空清单，
    # 好在下面那道「不足 10 个包即失败」的断言会拦住 —— 硬失败而非静默产出空清单。
    # 用 dpkg-query -W 的默认输出（包名<TAB>版本），避免格式串被内层 sh 当参数展开。
    docker run --rm "$IMG" /bin/sh -c '
      if command -v dpkg-query >/dev/null 2>&1; then
        if [ -f /usr/lib/dpkg/var/status ]; then dpkg-query --admindir=/usr/lib/dpkg/var -W
        else dpkg-query -W; fi 2>/dev/null | sort
      elif command -v rpm >/dev/null 2>&1; then
        rpm -qa --qf "%{NAME}\t%{VERSION}-%{RELEASE}\n" 2>/dev/null | sort
      fi' 2>/dev/null
} > "$OUT"
  # 只数**真实数据行**。原先 grep -vc '^#' 把空行也算进去，于是 rpm 系镜像拿到
  # 空清单时 n 仍然过线，断言被空行救活 —— 又一次「负向断言失效」。
  n=$(awk 'NF && !/^#/' "$OUT" | wc -l)
if [ "${n:-0}" -lt 10 ]; then
  echo "  !! 清单 $OUT 只有 $n 个包，生成失败" >&2; exit 1
fi
echo "  清单 $OUT ($n 个包)"
