#!/bin/bash
# 主入口：build.sh <distro-id> <tier...>   tier ∈ micro base devel
set -eu
ROOT="${ROOT:-/w}"; . "$ROOT/lib/common.sh"
DID=${1:?用法: build.sh <distro-id> <tier...>}; shift
. "$ROOT/distros/$DID.conf"
TIERS=${*:-micro base devel}
umask 022
# 可复现性：所有产物时间戳归一。默认取仓库 Release 的 Date（同一快照 -> 同一时间戳），
# 可用环境变量覆盖以做逐位复现验证。推导逻辑在 lib/common.sh::derive_epoch，
# 与 tools/mk-localrepo.sh 共用，避免两边算出不同的 epoch。
SOURCE_DATE_EPOCH=$(derive_epoch "${MIRROR:-}" "${SUITE:-}")
export SOURCE_DATE_EPOCH
log "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH ($(date -u -d @$SOURCE_DATE_EPOCH 2>/dev/null))"
# 落盘供清单引用：epoch 是逐位复现的必要输入，不记下来 manifest 就兑现不了 report.md §8（可复现性） 的承诺
mkdir -p "$ROOT/out"; printf '%s' "$SOURCE_DATE_EPOCH" > "$ROOT/out/$DID.epoch"

EXC=(
 --dpkgopt=path-exclude=/usr/share/doc/*      --dpkgopt=path-include=/usr/share/doc/*/copyright
 --dpkgopt=path-exclude=/usr/share/man/*      --dpkgopt=path-exclude=/usr/share/info/*
 --dpkgopt=path-exclude=/usr/share/lintian/*  --dpkgopt=path-exclude=/usr/share/linda/*
 --dpkgopt=path-exclude=/usr/share/locale/*   --dpkgopt=path-include=/usr/share/locale/locale.alias
 --dpkgopt=path-include=/usr/share/locale/zh_CN/*
)

build_mmdebstrap() {
  local TIER=$1 variant inc
  case $TIER in
    micro) variant=essential; inc="$MICRO_INCLUDE" ;;
    base)  variant=apt;       inc="$BASE_INCLUDE" ;;
    devel) variant=apt;       inc="$BASE_INCLUDE,$DEVEL_INCLUDE" ;;
    *) die "未知档位 $TIER" ;;
  esac
  local -a INC_ARG=(); [ -n "$inc" ] && INC_ARG=(--include="$inc")
  local HOOKS=()
  [ "${USRMERGE:-no}" = yes ] && HOOKS+=(--hook-dir=/usr/share/mmdebstrap/hooks/merged-usr)
  local OUT="$ROOT/out/$DID-$TIER.tar"
  rm -f "$OUT"
  log "[$DID/$TIER] mmdebstrap variant=$variant"
  printf 'deb [trusted=yes] copy://%s/localrepo/%s ./\ndeb [signed-by=%s] %s %s %s\n' \
      "$ROOT" "$DID" "$KEYRING" "$MIRROR" "$SUITE" "$COMPONENTS" | \
  DID=$DID TIER=$TIER ROOT=$ROOT SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" mmdebstrap \
      --mode=root --architectures=$ARCH --format=tar --variant="$variant" \
      "${INC_ARG[@]}" \
      "${HOOKS[@]}" "${EXC[@]}" \
      --skip=chroot/policy-rc.d \
      --aptopt='APT::Key::gpgvcommand "gpgv"' \
      --aptopt='Acquire::Languages "none"' \
      --aptopt='APT::Install-Recommends "false"' \
      --setup-hook="ROOT=$ROOT DID=$DID $ROOT/build/setup.sh \"\$1\"" \
      --customize-hook="ROOT=$ROOT DID=$DID TIER=$TIER $ROOT/build/customize.sh \"\$1\"" \
      "$SUITE" "$OUT" -
  [ -s "$OUT" ] || die "[$DID/$TIER] 无产物"
  log "[$DID/$TIER] 完成 $(du -h "$OUT"|cut -f1)"
}

build_slice() {
  local TIER=$1 seeds
  case $TIER in
    micro) seeds="$SLICE_MICRO" ;;
    base)  seeds="$SLICE_MICRO,$SLICE_BASE_EXTRA" ;;
    devel) seeds="$SLICE_MICRO,$SLICE_BASE_EXTRA,$SLICE_DEVEL_EXTRA" ;;
    *) die "未知档位 $TIER" ;;
  esac
  # 切片源必须带有与 squashfs sha256 一致的指纹标记，否则不知道手上这份是不是原货
  [ -d "$SRC_ROOTFS" ] || die "切片源不存在: $SRC_ROOTFS（先跑 tools/prepare-slice-src.sh $DID）"
  local want="${SQUASHFS_SHA256:-}"
  if [ -n "$want" ] && [ "$(cat "$SRC_ROOTFS/.verified" 2>/dev/null)" != "$want" ]; then
    die "切片源指纹不符（期望 ${want:0:16}…）。跑 tools/prepare-slice-src.sh $DID 重建"
  fi
  local D="$ROOT/build/$DID-$TIER" OUT="$ROOT/out/$DID-$TIER.tar"
  rm -rf "$D"; rm -f "$OUT"
  log "[$DID/$TIER] 切片"
  python3 "$ROOT/tools/slice.py" "$SRC_ROOTFS" "$D" "$seeds"
  # postinst 生成物 + 配置：切片不跑脚本，从源 rootfs 直接取
  local f d
  for f in etc/passwd etc/group etc/shadow etc/gshadow etc/nsswitch.conf etc/host.conf \
           etc/login.defs etc/profile etc/bash.bashrc etc/environment etc/ld.so.conf \
           etc/os-release usr/lib/os-release etc/debian_version etc/apt/sources.list; do
    [ -e "$SRC_ROOTFS/$f" ] && { mkdir -p "$D/$(dirname "$f")"; cp -a "$SRC_ROOTFS/$f" "$D/$f" 2>/dev/null || true; }
  done
  for d in etc/ld.so.conf.d etc/pam.d etc/ssl etc/apt/apt.conf.d usr/share/ca-certificates usr/share/i18n; do
    if [ -d "$SRC_ROOTFS/$d" ]; then mkdir -p "$D/$d"; cp -a "$SRC_ROOTFS/$d/." "$D/$d/" 2>/dev/null || true; fi
  done
  # UOS V25 把真二进制改名成 *.real，再把 dpkg/apt/apt-get 换成 deepin-immutable-ctl
  # 适配器。容器里没有 OSTree 部署，适配器必然失败，因此指回真二进制。
  # 这是与真机的**有意偏差**，已在 README 记录；好处是 dpkg 查询/本地装包可用。
  for b in dpkg apt apt-get; do
    if [ -L "$D/usr/bin/$b" ] && [ -x "$SRC_ROOTFS/usr/bin/$b.real" ]; then
      cp -a "$SRC_ROOTFS/usr/bin/$b.real" "$D/usr/bin/$b.real"
      ln -sfn "$b.real" "$D/usr/bin/$b"
      log "  $b -> $b.real（绕开 immutable 适配器）"
    fi
  done
  # 补回 update-alternatives 建的符号链接（不属于任何包，切片必漏）
  python3 "$ROOT/tools/restore-alternatives.py" "$SRC_ROOTFS" "$D"
  # ⚠️ 顺序要紧：厂商的 sources.list.d 必须在 adapt_container **之前**拷进去 ——
  # adapt_container 里要把两个返回 401 的授权源注释掉，文件还不存在的话那段就空跑
  # （我就这么把它空跑过一次，改完源清单毫无变化）。
  # micro 档没有 apt，带一份在线源清单出厂毫无意义 —— 上一轮只按「路径」收窄了
  # sources.list，漏了 sources.list.d，于是 uos25:micro 仍带着一条 active 的
  # appstore https 源，而当时新加的度量只 wc -c 那一个文件、结构性看不见它。
  if [ "$TIER" != micro ] && [ -d "$SRC_ROOTFS/etc/apt/sources.list.d" ]; then
    mkdir -p "$D/etc/apt/sources.list.d"
    cp -a "$SRC_ROOTFS/etc/apt/sources.list.d/." "$D/etc/apt/sources.list.d/" 2>/dev/null || true
  fi
  adapt_container "$D" "${UOS_SOURCES:-}" "$DID"
  # UOS V25 把 dpkg admindir 搬到 /usr/lib/dpkg/var（配合 OSTree 的 /var 可写分离）。
  # 容器里这个布局有两个麻烦：
  #   ① SBOM/CVE 扫描器（trivy/syft）从镜像层 tar 里找 /var/lib/dpkg/status，
  #      且**不跨归档跟随符号链接**——放符号链接扫出来是空的（实测 SPDX 只有 2 条）
  #   ② dpkg 默认 admindir 是 /var/lib/dpkg，元文件（arch 等）不在那里就会
  #      对 Multi-Arch: same 的包报一片 "missing the list control file"
  # 所以把真 admindir 放回标准位置 /var/lib/dpkg，再把 UOS 的原路径做成符号链接指过来。
  # 两边都能读到同一份数据，扫描器和 dpkg 都正常。这是与真机的有意偏差，report.md §5（精简与容器化改造） 有记。
  if [ -n "${ADMINDIR:-}" ] && [ "$ADMINDIR" != "var/lib/dpkg" ]; then
    rm -rf "$D/var/lib/dpkg"
    mkdir -p "$D/var/lib"
    mv "$D/$ADMINDIR" "$D/var/lib/dpkg"
    rmdir "$D/$(dirname "$ADMINDIR")" 2>/dev/null || true
    mkdir -p "$D/$(dirname "$ADMINDIR")"
    ln -sfn /var/lib/dpkg "$D/$ADMINDIR"
    log "  dpkg admindir 归位 /var/lib/dpkg（/$ADMINDIR 做符号链接指回）"
  fi

  # /etc/ld.so.cache 不属于任何包（是 ldconfig 触发器的产物），切片只搬包内文件，
  # 所以必然漏。UOS 的情形不致命 —— Debian 多架构目录在动态链接器内置默认路径里，
  # 缺 cache 只损性能；但补上更接近真机，且这一项现在有门禁盯着。
  if [ -x "$D/sbin/ldconfig" ]; then
    chroot "$D" /sbin/ldconfig 2>/dev/null || true
    [ -s "$D/etc/ld.so.cache" ] && log "  ld.so.cache 生成 $(stat -c%s "$D/etc/ld.so.cache") 字节"
    # ldconfig 另外会写 /var/cache/ldconfig/aux-cache，它记录每个库的 inode 与
    # mtime 用于增量加速 —— 天然不可复现，实测让 uos25 三档连构两次哈希全漂。
    # 它只是加速用的中间产物，删掉不影响任何功能，而且本来就不该出厂。
    rm -rf "$D/var/cache/ldconfig" 2>/dev/null || true
  fi
  # locale：宿主的 localedef 版本可能不同，用容器化方式在目标 rootfs 里生成
  if [ -d "$D/usr/share/i18n/locales" ] && [ -x "$D/usr/bin/localedef" ]; then
    chroot "$D" /usr/bin/localedef -i zh_CN -c -f UTF-8 zh_CN.UTF-8 2>/dev/null || true
    chroot "$D" /usr/bin/localedef -i en_US -c -f UTF-8 en_US.UTF-8 2>/dev/null || true
  fi
  slim_locales "$D"
  make_tarball "$D" "$OUT"
}

# ── debmedia：介质自带完整 apt 仓库，从它 bootstrap ────────────────────────
# 凝思的 DVD 是 Binary-1（.disk/info 明写），dists/ 与 pool/ 都在盘上（实测 6486 个 deb）。
# 所以不需要切片，也不需要在线源 —— mmdebstrap 直接吃 copy:// 本地源即可。
# 与 mmdebstrap 路径的差别只有源：那条走厂商在线源并验签，这条走介质、trusted=yes
# （介质本身的完整性由 ISO 的官方 md5 + sha256 兜，见 conf 里的 ISO_MD5/ISO_SHA256）。
build_debmedia() {
  local TIER=$1 variant inc
  case $TIER in
    micro) variant=essential; inc="$MICRO_INCLUDE" ;;
    base)  variant=apt;       inc="$BASE_INCLUDE" ;;
    devel) variant=apt;       inc="$BASE_INCLUDE,$DEVEL_INCLUDE" ;;
    *) die "未知档位 $TIER" ;;
  esac
  local -a INC_ARG=(); [ -n "$inc" ] && INC_ARG=(--include="$inc")
  local HOOKS=()
  [ "${USRMERGE:-no}" = yes ] && HOOKS+=(--hook-dir=/usr/share/mmdebstrap/hooks/merged-usr)
  local MEDIA="$ROOT/media/$MEDIA_DIR"
  [ -d "$MEDIA/dists/$SUITE" ] || die "介质仓库不存在: $MEDIA/dists/$SUITE"
  # 预检包名：介质里没有的包名会让 mmdebstrap 在「installing essential packages」
  # 阶段挂死（dpkg 变僵尸、CPU 归零），而不是明确报错 —— 实测等了 20 分钟才发现，
  # 根因只是 libgcc-s1 在 Debian 10 里叫 libgcc1。所以在这里秒级失败。
  local IDX="$MEDIA/dists/$SUITE/${COMPONENTS:-main}/binary-$ARCH/Packages"
  [ -f "$IDX" ] || IDX="$IDX.gz"
  if [ -f "$IDX" ]; then
    local missing="" pk
    for pk in $(printf '%s' "$inc" | tr ',' ' '); do
      [ -z "$pk" ] && continue
      case "$IDX" in
        *.gz) zgrep -qx "Package: $pk" "$IDX" || missing="$missing $pk" ;;
        *)     grep -qx "Package: $pk" "$IDX" || missing="$missing $pk" ;;
      esac
    done
    [ -z "$missing" ] || die "[$DID/$TIER] 介质里没有这些包（包名与该发行版的 suite 不符？）:$missing"
  fi
  local OUT="$ROOT/out/$DID-$TIER.tar"
  rm -f "$OUT"
  log "[$DID/$TIER] debmedia variant=$variant suite=$SUITE"
  printf 'deb [trusted=yes] copy://%s %s %s\n' "$MEDIA" "$SUITE" "${COMPONENTS:-main}" | \
  DID=$DID TIER=$TIER ROOT=$ROOT SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" mmdebstrap \
      --mode=root --architectures=$ARCH --format=tar --variant="$variant" \
      "${INC_ARG[@]}" "${HOOKS[@]}" "${EXC[@]}" \
      --skip=chroot/policy-rc.d \
      --aptopt='Acquire::Languages "none"' \
      --aptopt='APT::Install-Recommends "false"' \
      --setup-hook="ROOT=$ROOT DID=$DID $ROOT/build/setup.sh \"\$1\"" \
      --customize-hook="ROOT=$ROOT DID=$DID TIER=$TIER $ROOT/build/customize.sh \"\$1\"" \
      "$SUITE" "$OUT" -
  [ -s "$OUT" ] || die "[$DID/$TIER] 产物为空"
}

# ── rpmmedia：rpm 系介质，解析 repodata 求闭包后用 rpm --root 装 ───────────
# 麒麟信安的 ISO 实测无 squashfs（只有 Packages/ 2935 个 rpm + repodata/），
# 所以既不能切片，也没有在线源可用（桌面版源需授权）。走 tools/rpmmedia.py。
build_rpmmedia() {
  local TIER=$1 seeds
  case $TIER in
    micro) seeds="$SLICE_MICRO" ;;
    base)  seeds="$SLICE_MICRO,$SLICE_BASE_EXTRA" ;;
    devel) seeds="$SLICE_MICRO,$SLICE_BASE_EXTRA,$SLICE_DEVEL_EXTRA" ;;
    *) die "未知档位 $TIER" ;;
  esac
  local MEDIA="$ROOT/media/$MEDIA_DIR"
  [ -d "$MEDIA/repodata" ] || die "介质仓库不存在: $MEDIA/repodata"
  local D="$ROOT/build/$DID-$TIER"
  rm -rf "$D"; mkdir -p "$D"
  log "[$DID/$TIER] rpmmedia 从介质仓库装包"
  RPM_DB_BACKEND="${RPM_DB_BACKEND:-}" \
    python3 "$ROOT/tools/rpmmedia.py" "$MEDIA" "$D" "$seeds" || die "[$DID/$TIER] rpmmedia 失败"
  # adapt_container 的签名是 (rootfs, sources.list 内容, distro-id)。
  # rpm 系没有 apt sources.list，第二个参数传空 —— 那段逻辑里的 `if [ -n "$SRCLIST" ]`
  # 会正确走到「micro 档写空文件」那一支，不会留下 bootstrap 期的宿主路径。
  adapt_container "$D" "" "$DID"
  slim_locales "$D"
  make_tarball "$D" "$ROOT/out/$DID-$TIER.tar"
}

case $METHOD in
  mmdebstrap|slice|selfhost|debmedia|rpmmedia) ;;
  *) die "未知 METHOD=$METHOD" ;;
esac
[ "$METHOD" = mmdebstrap ] && verify_repo_signature "${MIRROR%/}" "$SUITE"
for T in $TIERS; do
  case $METHOD in
    mmdebstrap) build_mmdebstrap "$T" ;;
    slice)      build_slice "$T" ;;
    debmedia)   build_debmedia "$T" ;;
    rpmmedia)   build_rpmmedia "$T" ;;
    selfhost)   log "[$DID/$T] selfhost 由 build/build-selfhost.sh 处理" ;;
  esac
done
