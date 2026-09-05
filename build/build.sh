#!/bin/bash
# 主入口：build.sh <distro-id> <tier...>   tier ∈ micro base devel
# BK = buildkit 自身的根（lib/build/test/tools/gate 在这里）
# ROOT = 项目根（distros/out/localrepo/keys 在这里）
# submodule 布局下两者不是同一个目录，混用会在「找得到 conf 却找不到 common.sh」
# 这种地方失败，报错离真因很远。
BK="${BK:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
set -eu
ROOT="${ROOT:-/w}"; . "$BK/lib/common.sh"
DID=${1:?用法: build.sh <distro-id> <tier...>}; shift
. "$ROOT/distros/$DID.conf"

# conf 里可以用 KEYRING_FILE 指定自己的 keyring（相对 ROOT）。common.sh 在 conf 之前
# 被 source，那时 conf 的值还不可见，所以这里重解析一次。
if [ -n "${KEYRING_FILE:-}" ]; then KEYRING="$ROOT/${KEYRING_FILE#/}"; fi
export KEYRING
# conf 声明了 KEYRING_KEY_FP 就核对。不核的话任何一把 key 都能让「验签通过」成立
# —— 信任根是**那一把特定的** key，不是「有签名」这件事。
if [ -n "${KEYRING_KEY_FP:-}" ]; then
  [ -f "$KEYRING" ] || die "keyring 不存在: $KEYRING"
  # 转成空格分隔再匹配：keyring 里常有主密钥加子密钥（Loongnix 那份就是两条），
  # gpg 逐行输出，而下面的 case 模式两侧要空格 —— 不转的话期望的指纹明明在里面
  # 也匹配不上，报错还会把它打出来，读起来像"值一样却说不符"。
  _fps=$(LC_ALL=C gpg --show-keys --with-colons "$KEYRING" 2>/dev/null | awk -F: '/^fpr/{print $10}' | tr '\n' ' ')
  case " $_fps " in
    *" ${KEYRING_KEY_FP} "*) log "keyring 指纹已核对: ${KEYRING_KEY_FP}" ;;
    *) die "keyring 指纹不符：期望 ${KEYRING_KEY_FP}，$KEYRING 里是 $(printf '%s' "$_fps" | tr '\n' ' ')" ;;
  esac
fi
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
  # ── mmdebstrap 的可执行性预检 ─────────────────────────────────────────────
  # 它用 `arch-test <arch>` 判目标架构能不能跑，而 arch-test 只认它
  # /usr/libexec/arch-test/ 下有同名 helper 的架构。LoongArch 只有 loong64
  # 那一份，**没有 loongarch64**，于是 `arch-test loongarch64` 回答的是
  #   I don't know how to detect arch 'loongarch64', sorry.
  # 它回答的不是「能不能执行」而是「我认不认识这个名字」。两次调用都失败后
  # mmdebstrap 无条件报 `can neither be executed natively nor via qemu user
  # emulation`，而那句话与 binfmt 配得对不对无关：配得完美它也不会去问。
  #
  # 所以只对这个架构关掉预检（mmdebstrap 文档明确支持 --skip=check/qemu）。
  # 判据不是被删掉而是搬了家：可执行性由 tools/ensure-qemu.sh 与
  # .github/workflows/probe-qemu-oldworld.yml 负责，后者更严 —— 带阴性对照、
  # 真跑目标架构的二进制、并核对 binfmt 的两侧。
  # 别的架构不关：它们的 helper 都在，这道预检是有效的。
  local MMSKIP=""
  case "$ARCH" in
    loongarch64) MMSKIP=check/qemu ;;
  esac
  [ -z "$MMSKIP" ] || log "[$DID/$TIER] 关掉 mmdebstrap 的 $MMSKIP（arch-test 不认识 $ARCH）"
  local -a INC_ARG=(); [ -n "$inc" ] && INC_ARG=(--include="$inc")
  local HOOKS=()
  [ "${USRMERGE:-no}" = yes ] && HOOKS+=(--hook-dir=/usr/share/mmdebstrap/hooks/merged-usr)
  local OUT="$ROOT/out/$DID-$TIER.tar"
  rm -f "$OUT"
  log "[$DID/$TIER] mmdebstrap variant=$variant"
  # signed-by 走宿主路径的 $KEYRING，与 osimg-study 里实证过的写法一致。
  # 实测过两件事：apt 按宿主路径解析（写 chroot 内路径即使 setup-hook 已把文件
  # 拷进去也报 NO_PUBKEY），以及 _apt 能读到深埋在用户目录下的 keyring
  # （/home/runner/... 与 /etc/apt/keyrings/ 两处都可读、两处都能构建成功）。
  # 源列表先拼成变量再喂进去：除基础 suite 之外还可能有 EXTRA_SUITES（Loongnix 的
  # loongnix-security 与 Debian 的 security 同性质）。原先是一条 printf 写死两行，
  # 加更新源无处可放 —— 而 conf 里写了却没人读，就是静默失效。
  # 用字面换行拼，不要用 $(printf '...\n')：命令替换会吃掉尾部换行，三行源会被
  # 拼成一行，而 apt 只会把它当成一条不认识的源静默忽略。
  local SRC
  # 本地源只在**真的存在**时才写进去。它服务的是 REPACK_DEBS / STUB_PROVIDES
  # （重打包的坏包与顶替内核态组件的假包），两者都为空时 mk-localrepo.sh 压根不跑、
  # 目录也就不存在，而无条件写这一行会让 apt 报
  #   Err:3 copy:/w/localrepo/<did> ./ Packages
  # 然后 mmdebstrap 整体失败 —— 判据要挂在「目录里有没有 Packages」这个结果上，
  # 不是挂在「这条路径一向都有」这个假设上。
  SRC=""
  if [ -s "$ROOT/localrepo/$DID/Packages" ] || [ -s "$ROOT/localrepo/$DID/Packages.gz" ]; then
    SRC="deb [trusted=yes] copy://$ROOT/localrepo/$DID ./
"
  fi
  SRC="${SRC}deb [signed-by=$KEYRING] $MIRROR $SUITE $COMPONENTS"
  for _es in ${EXTRA_SUITES:-}; do
    SRC="$SRC
deb [signed-by=$KEYRING] $MIRROR $_es $COMPONENTS"
  done
  printf '%s\n' "$SRC" | \
  DID=$DID TIER=$TIER ROOT=$ROOT SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" mmdebstrap \
      --mode=root --architectures=$ARCH --format=tar --variant="$variant" \
      "${INC_ARG[@]}" \
      "${HOOKS[@]}" "${EXC[@]}" \
      --skip=chroot/policy-rc.d \
      ${MMSKIP:+--skip=$MMSKIP} \
      --aptopt='APT::Key::gpgvcommand "gpgv"' \
      --aptopt='Acquire::Retries "3"' \
      --aptopt='Acquire::http::Timeout "45"' \
      --aptopt='Acquire::CompressionTypes::Order:: "gz"' \
      --aptopt='Acquire::Languages "none"' \
      --aptopt='APT::Install-Recommends "false"' \
      --setup-hook="ROOT=$ROOT DID=$DID KEYRING=$KEYRING $BK/build/setup.sh \"\$1\"" \
      --customize-hook="ROOT=$ROOT DID=$DID TIER=$TIER $BK/build/customize.sh \"\$1\"" \
      "$SUITE" "$OUT" -
  # 这里必须 return 而不是 die：调用方对本函数做了档位级重试，而 die 是 exit，
  # 会把整个脚本带走、重试永远不会发生。函数在 AND-list 里被调用时 set -e 被抑制，
  # 所以 mmdebstrap 失败后能走到这一行；只要这一行不 exit，重试就成立。
  [ -s "$OUT" ] || { log "[$DID/$TIER] 无产物"; return 1; }
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
  # 生成的 rootfs 属于项目产物，不能落进 buildkit（那是 submodule，且会污染工作区）
  local D="$ROOT/work/$DID-$TIER" OUT="$ROOT/out/$DID-$TIER.tar"
  rm -rf "$D"; rm -f "$OUT"
  log "[$DID/$TIER] 切片"
  python3 "$BK/tools/slice.py" "$SRC_ROOTFS" "$D" "$seeds"
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
  # 整目录搬会把指向未入选包的软链一起带进来（V20 的
  # etc/ld.so.conf.d/com.canon.ufr2.conf 指向没进切片的佳能打印驱动）。
  # 留着它 ldconfig 每次都告警，验收也会报「清单外悬空软链」。
  find "$D/etc" -xtype l -print -delete 2>/dev/null | sed "s|^|  清掉悬空软链 |" || true
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
  python3 "$BK/tools/restore-alternatives.py" "$SRC_ROOTFS" "$D"
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
    # 跨架构时这一步要靠 binfmt 才能 exec 目标架构的 ldconfig。原先写成
    # `|| true`，缺 QEMU 时它静默失败、产物照样出厂，直到验收才报
    # 「ldcache 期望 >1000 实际 0」——症状离真因三步远。改成硬断言。
    chroot "$D" /sbin/ldconfig \
      || die "[$DID/$TIER] chroot ldconfig 失败（跨架构时宿主需装 qemu-user-static 并注册 binfmt）"
    [ -s "$D/etc/ld.so.cache" ] || die "[$DID/$TIER] ldconfig 跑完却没有 /etc/ld.so.cache"
    log "  ld.so.cache 生成 $(stat -c%s "$D/etc/ld.so.cache") 字节"
    # ldconfig 另外会写 /var/cache/ldconfig/aux-cache，它记录每个库的 inode 与
    # mtime 用于增量加速 —— 天然不可复现，实测让 uos25 三档连构两次哈希全漂。
    # 它只是加速用的中间产物，删掉不影响任何功能，而且本来就不该出厂。
    rm -rf "$D/var/cache/ldconfig" 2>/dev/null || true
  fi
  # locale 归档与 ld.so.cache 同类：postinst 产物，不属于任何包，切片必漏。
  # 先从源 rootfs 搬现成的——真机装完就有，比在 chroot 里现生成可靠得多。
  # 守卫不能写成「目标目录不存在才搬」：切片会按包的文件清单建出**空的**
  # /usr/lib/locale，-e 为真于是整段跳过。改为合并内容。
  if [ -d "$SRC_ROOTFS/usr/lib/locale" ]; then
    mkdir -p "$D/usr/lib/locale"
    cp -an "$SRC_ROOTFS/usr/lib/locale/." "$D/usr/lib/locale/" 2>/dev/null || true
    log "  合并源 rootfs 的 usr/lib/locale"
  fi
  # 再用 localedef 补一遍。不用 `[ -x ]` 判它跑不跑得起来：那个测试在宿主侧解析
  # 路径，若 /usr/bin/localedef 是绝对符号链接，宿主上目标存在而 chroot 内不存在，
  # -x 会放行而 chroot 报 ENOENT——V20 实测就是这样。直接跑，跑不起来就跳过。
  if [ -d "$D/usr/share/i18n/locales" ]; then
    chroot "$D" /usr/bin/localedef -i zh_CN -c -f UTF-8 zh_CN.UTF-8 2>/dev/null \
      || log "  localedef zh_CN 跑不起来，改依赖搬入的 locale 归档"
    chroot "$D" /usr/bin/localedef -i en_US -c -f UTF-8 en_US.UTF-8 2>/dev/null || true
  fi
  # 判据看结果不看手段：镜像里得真有 zh_CN，搬来的还是现生成的无所谓。
  # 运行时的权威判定在 verify 的 locale_zh（`locale -a`），这里只做一道早失败。
  if [ -d "$D/usr/lib/locale/zh_CN.utf8" ] || [ -s "$D/usr/lib/locale/locale-archive" ]; then
    log "  zh_CN locale 就绪"
  else
    # 暂为告警而非致命：v20/amd64 上 localedef 无法 exec 而同版本 arm64 正常，
    # 差别在盘里而不在代码里。先把现场打全，运行时的判定交给 verify 的 locale_zh。
    echo "  [$DID/$TIER] 没有 zh_CN locale，现场如下："
    for x in "$D/usr/bin/localedef" "$D/usr/sbin/locale-gen" "$D/usr/bin/locale"; do
      printf "    slice %s: " "${x#$D}"; ls -ld "$x" 2>&1 | tail -1
      [ -L "$x" ] && printf "      -> %s（目标在 slice 内%s）\n" "$(readlink "$x")" \
         "$([ -e "$D$(readlink -m /"$(readlink "$x")")" ] && echo 存在 || echo 缺失)"
    done
    for x in "$SRC_ROOTFS/usr/bin/localedef" "$SRC_ROOTFS/usr/lib/locale"; do
      printf "    源 %s: " "${x#$SRC_ROOTFS}"; ls -ld "$x" 2>&1 | tail -1
    done
    printf "    源 /usr/lib/locale 内容: "; ls "$SRC_ROOTFS/usr/lib/locale" 2>&1 | head -5 | tr "\n" " "; echo
    printf "    slice 内 i18n/locales 有无 zh_CN: "; ls -ld "$D/usr/share/i18n/locales/zh_CN" 2>&1 | tail -1
    die "[$DID/$TIER] 镜像里没有 zh_CN locale（现场见上）"
  fi
  # CA 信任库：/etc/ca-certificates.conf 是 conffile，不在包的文件清单里，切片搬不到，
  # 于是 update-ca-certificates 没有可激活的清单，哈希软链残缺。统信 V20 实测只剩 71 个
  # 软链而证书有 137 份，curl 报「unable to get local issuer certificate」，而显式
  # --cacert 指 bundle 就通——说明 bundle 没问题，是 CApath 覆盖不全。V25 侥幸靠
  # openssl 自带的 /usr/lib/ssl/cert.pem 找到 bundle，V20 的 openssl 不带那个软链。
  # 按实际搬进来的证书重建清单再刷新，产物与镜像自洽。
  if [ -d "$D/usr/share/ca-certificates" ] && [ -x "$D/usr/sbin/update-ca-certificates" ]; then
    ( cd "$D/usr/share/ca-certificates" && find . -name "*.crt" | sed "s|^\./||" | sort ) \
      > "$D/etc/ca-certificates.conf"
    chroot "$D" /usr/sbin/update-ca-certificates --fresh >/dev/null 2>&1 \
      || log "  update-ca-certificates 没跑成（跨架构时需 binfmt）"
    log "  CA 信任库重建：$(find "$D/etc/ssl/certs" -name "*.0" -type l 2>/dev/null | wc -l) 个哈希软链"
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
      --aptopt='Acquire::Retries "3"' \
      --aptopt='Acquire::http::Timeout "45"' \
      --aptopt='Acquire::CompressionTypes::Order:: "gz"' \
      --aptopt='Acquire::Languages "none"' \
      --aptopt='APT::Install-Recommends "false"' \
      --setup-hook="ROOT=$ROOT DID=$DID KEYRING=$KEYRING $BK/build/setup.sh \"\$1\"" \
      --customize-hook="ROOT=$ROOT DID=$DID TIER=$TIER $BK/build/customize.sh \"\$1\"" \
      "$SUITE" "$OUT" -
  [ -s "$OUT" ] || die "[$DID/$TIER] 产物为空"
}

# ── rpmmedia：rpm 系介质，解析 repodata 求闭包后用 rpm --root 装 ───────────
# 麒麟信安的 ISO 实测无 squashfs（只有 Packages/ 2935 个 rpm + repodata/），
# 所以既不能切片，也没有在线源可用（桌面版源需授权）。走 tools/rpmmedia.py。
build_rpmrepo() {
  local TIER=$1 seeds
  case $TIER in
    micro) seeds="$SLICE_MICRO" ;;
    base)  seeds="$SLICE_MICRO,$SLICE_BASE_EXTRA" ;;
    devel) seeds="$SLICE_MICRO,$SLICE_BASE_EXTRA,$SLICE_DEVEL_EXTRA" ;;
    *) die "未知档位 $TIER" ;;
  esac
  [ -n "${REPO_BASES:-}" ] || die "conf 没给 REPO_BASES"
  [ -n "${RPM_KEY:-}" ]    || die "conf 没给 RPM_KEY"
  [ -n "${RPM_KEY_FP:-}" ] || die "conf 没给 RPM_KEY_FP（不钉指纹的话任何一把 key 都能'验过'）"
  local KEY="$ROOT/${RPM_KEY#/}"
  [ -f "$KEY" ] || die "公钥不存在: $KEY"

  # 取材：把远程源物化成「介质形状」的目录。这一层之后的安装逻辑与 rpmmedia
  # 完全共用 —— 两条路径的差别只在取材，不在装法。
  local MEDIA="$ROOT/work/$DID-$TIER-src"
  rm -rf "$MEDIA"; mkdir -p "$MEDIA"
  log "[$DID/$TIER] rpmrepo 取材：$REPO_BASES"
  KEYFILE="$KEY" KEY_FP="$RPM_KEY_FP" \
    python3 "$BK/tools/rpmrepo-fetch.py" "$MEDIA" "$seeds" $REPO_BASES \
    || die "[$DID/$TIER] 取材失败"

  # 时间锚点。必须来自源的 repomd revision（取材时写进 .epoch），或者 conf 显式钉的值。
  #
  # 不能写成 `if [ -z "$SOURCE_DATE_EPOCH" ]`：build.sh 在分派之前已经调过
  # derive_epoch，而它对没有 Release 可读的路径会回落到硬编码常量 1700000000。
  # 那个值非空、而且落在任何「合理年份」区间内，所以范围检查放它过去 —— 假锚点
  # 正是这样活下来的。判据得是「它从哪来」而不是「它像不像个日期」。
  # env -u 是必须的：conf-get.sh 取值时写的是 ${VAR:-}，而 build.sh 开头已经
  # export 过 SOURCE_DATE_EPOCH（derive_epoch 的结果）。不剥掉的话读回来的是
  # 环境里那个兜底常量而不是 conf 里的值，于是「conf 有没有钉」这个判断永远为真，
  # 拦截形同不存在 —— 探针继承了它要测量的东西。
  _conf_epoch=$(env -u SOURCE_DATE_EPOCH \
    ARCH="$ARCH" ROOT="$ROOT" BK="$BK" "$BK/tools/conf-get.sh" "$DID" SOURCE_DATE_EPOCH)
  if [ -n "$_conf_epoch" ]; then
    SOURCE_DATE_EPOCH="$_conf_epoch"
    log "[$DID/$TIER] SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH（conf 显式钉的）"
  else
    SOURCE_DATE_EPOCH=$(cat "$MEDIA/.epoch" 2>/dev/null || echo "")
    log "[$DID/$TIER] SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH（源 repomd revision）"
  fi
  export SOURCE_DATE_EPOCH
  case "${SOURCE_DATE_EPOCH:-}" in
    ''|*[!0-9]*) die "SOURCE_DATE_EPOCH 取不到或不是数字: '${SOURCE_DATE_EPOCH:-}'" ;;
  esac
  [ "$SOURCE_DATE_EPOCH" -gt 1600000000 ] \
    || die "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH 早于 2020，不像真锚点"
  # 兜底常量本身要当作错误拦掉：conf 没钉、又恰好等于它，只能是回落来的。
  if [ -z "$_conf_epoch" ] && [ "$SOURCE_DATE_EPOCH" = 1700000000 ]; then
    die "SOURCE_DATE_EPOCH 等于 make_tarball 的兜底常量 1700000000，说明取的不是源 revision"
  fi

  local D="$ROOT/work/$DID-$TIER"
  rm -rf "$D"; mkdir -p "$D"
  log "[$DID/$TIER] 装包（复用 rpmmedia 的装法与断言）"
  RPM_DB_BACKEND="${RPM_DB_BACKEND:-}" RPM_DB_VIA_TARGET="${RPM_DB_VIA_TARGET:-}" \
    python3 "$BK/tools/rpmmedia.py" "$MEDIA" "$D" "$seeds" || die "[$DID/$TIER] 装包失败"
  adapt_container "$D" "" "$DID"
  # 出厂源。deb 侧 micro 档不带源，rpm 侧对齐：micro 的种子里没有 dnf，
  # 留个 repo 文件反而让 has_source 与 has_pkgmgr 自相矛盾。
  if [ "$TIER" = micro ]; then
    rm -rf "$D/etc/yum.repos.d"
  else
    write_yum_repos "$D" "$KEY" "$DID" "$REPO_BASES"
  fi
  slim_locales "$D"
  make_tarball "$D" "$ROOT/out/$DID-$TIER.tar"
}

# ── pkgslice：自研 pkg 数据库（CRUX pkgutils 式）的整盘 rootfs，按 ELF 闭包切片 ──
# 凝思 6.0.42（磐石 Rocky 4.2）的 ISO 是摊开的 rootfs，包管理是 /var/lib/pkg/db，
# 没有依赖字段 —— 闭包在取材期按 ELF NEEDED 算好（.pkgmap），这里只做确定性拷贝。
build_pkgslice() {
  local TIER=$1 seeds
  case $TIER in
    micro) seeds="$SLICE_MICRO" ;;
    base)  seeds="$SLICE_MICRO,$SLICE_BASE_EXTRA" ;;
    devel) seeds="$SLICE_MICRO,$SLICE_BASE_EXTRA,$SLICE_DEVEL_EXTRA" ;;
    *) die "未知档位 $TIER" ;;
  esac
  local MEDIA="$ROOT/media/$MEDIA_DIR"
  [ -f "$MEDIA/.pkgmap" ] || die "介质缺 .pkgmap: $MEDIA（srcdata 取材未就位？）"
  local D="$ROOT/work/$DID-$TIER" OUT="$ROOT/out/$DID-$TIER.tar"
  rm -rf "$D"; rm -f "$OUT"
  log "[$DID/$TIER] pkgslice 切片"
  python3 "$BK/tools/pkgdb-slice.py" tier "$MEDIA" "$D" "$seeds" || die "[$DID/$TIER] 切片失败"
  # 该世代 /tmp 是指向 ./ramdisk/tmp 的软链（真机由 ramdisk 挂载兜住），容器里
  # 悬空会让一切写 /tmp 的程序失败 —— 建实目录，保留原软链形态
  mkdir -p "$D/ramdisk/tmp" "$D/var/tmp" "$D/proc" "$D/sys" "$D/dev" "$D/root"
  chmod 1777 "$D/ramdisk/tmp" "$D/var/tmp"
  # /tmp 本体：pkg db 不登记它，介质也就不带 —— 上一轮镜像里根本没有 /tmp，
  # gcc 一开口就倒。按厂商原样补软链（真机 /tmp -> ./ramdisk/tmp）。
  [ -e "$D/tmp" ] || ln -s ./ramdisk/tmp "$D/tmp"
  # pre-os-release 世代：容器生态以 /etc/os-release 为身份判据，从厂商
  # linx-release 合成一份，文件头注明容器化添加（与 selfhost 路同规）
  if [ ! -e "$D/etc/os-release" ] && [ -f "$MEDIA/etc/linx-release" ]; then
    local _pn; _pn=$(head -1 "$MEDIA/etc/linx-release")
    {
      printf '# 本文件由 distrotwin 构建注入：该系统世代早于 os-release 规范，\n'
      printf '# 内容取自厂商 /etc/linx-release，仅供容器工具链识别。\n'
      printf 'NAME="%s"\nID=linx-rocky\nPRETTY_NAME="%s"\nVERSION_ID="%s"\n' \
        "$_pn" "$_pn" "$(printf '%s' "$_pn" | grep -oE '[0-9][0-9.]*' | head -1)"
    } > "$D/etc/os-release"
  fi
  ( cd "$D" && tar --numeric-owner -cf "$OUT" . ) || { log "[$DID/$TIER] 打包失败"; return 1; }
  [ -s "$OUT" ] || { log "[$DID/$TIER] 无产物"; return 1; }
  log "[$DID/$TIER] 完成 $(du -h "$OUT"|cut -f1)"
}

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
  local D="$ROOT/work/$DID-$TIER"
  rm -rf "$D"; mkdir -p "$D"
  log "[$DID/$TIER] rpmmedia 从介质仓库装包"
  # RPM_DB_VIA_TARGET 此前只在 rpmrepo 路传过（kylinsec），rpmmedia 路漏传 ——
  # 症状是 an7 的 via-target 分支整个没走、最后 rpm -qa 读 0。两条路共用装法，
  # 环境也必须一致。
  RPM_DB_BACKEND="${RPM_DB_BACKEND:-}" RPM_DB_VIA_TARGET="${RPM_DB_VIA_TARGET:-}" \
    python3 "$BK/tools/rpmmedia.py" "$MEDIA" "$D" "$seeds" || die "[$DID/$TIER] rpmmedia 失败"
  # 出厂源与 deb 介质档同规：构建期源是本地介质，厂商包自带的 repo 文件
  # （openEuler.repo 等）指向对 CI/用户都未必可达的网络源，留着会让镜像里
  # dnf 一开口就撞网络。整目录移除并记录；EXPECT_OS_REPO=no 与之配套。
  if ls "$D"/etc/yum.repos.d/*.repo >/dev/null 2>&1; then
    log "[$DID/$TIER] 清空出厂 yum 源（$(ls "$D"/etc/yum.repos.d/*.repo | wc -l) 个厂商 repo 文件，介质档不带在线源）"
    rm -f "$D"/etc/yum.repos.d/*.repo
  fi
  # adapt_container 的签名是 (rootfs, sources.list 内容, distro-id)。
  # rpm 系没有 apt sources.list，第二个参数传空 —— 那段逻辑里的 `if [ -n "$SRCLIST" ]`
  # 会正确走到「micro 档写空文件」那一支，不会留下 bootstrap 期的宿主路径。
  adapt_container "$D" "" "$DID"
  slim_locales "$D"
  make_tarball "$D" "$ROOT/out/$DID-$TIER.tar"
}

case $METHOD in
  mmdebstrap|slice|selfhost|debmedia|rpmmedia|rpmrepo|pkgslice) ;;
  *) die "未知 METHOD=$METHOD" ;;
esac
[ "$METHOD" = mmdebstrap ] && verify_repo_signature "${MIRROR%/}" "$SUITE"

# selfhost 是整体两段式，三档在同一次调用里产出（阶段 1 的 stage 三档共用），
# 不能按档位逐个进循环。原先这里只打印一行说明、由外层 Makefile 分别调用两个脚本，
# 搬到 CI 之后就成了静默空转：退出码 0、一个产物都没有，直到下一步报
# 「缺 out/xxx-micro.tar」才暴露，而那个报错指向的是导入步骤、不是构建步骤。
if [ "$METHOD" = selfhost ]; then
  log "[$DID] 转 selfhost 两段式：$TIERS"
  DID=$DID ROOT=$ROOT BK=$BK ARCH=$ARCH "$BK/build/build-selfhost.sh" $TIERS
else
  # 只跑一次。重试是 CI 层的事——build-one.yml 用 nick-fields/retry 包住整个步骤。
  # 脚本里再写一层会让「重试几次、等多久」散落在两处，而且本地调试时的行为与 CI 不同。
  for T in $TIERS; do
    case $METHOD in
      mmdebstrap) build_mmdebstrap "$T" ;;
      slice)      build_slice "$T" ;;
      debmedia)   build_debmedia "$T" ;;
      rpmmedia)   build_rpmmedia "$T" ;;
      pkgslice)   build_pkgslice "$T" ;;
      rpmrepo)    build_rpmrepo "$T" ;;
    esac
  done
fi


# 出口断言：不允许「退出码 0 但没有产物」。selfhost 的产物由 docker import 直接
# 落成镜像而非 tar，两种形态都算通过。
for T in $TIERS; do
  [ -s "$ROOT/out/$DID-$T.tar" ] && continue
  # 容器内没有 docker 客户端，此时只能以 tar 为准；selfhost 路径在宿主跑，
  # 它的产物由 docker import 直接落成镜像，那种形态也算通过。
  if command -v docker >/dev/null 2>&1 && docker image inspect "${IMAGE}:$T" >/dev/null 2>&1; then
    continue
  fi
  die "[$DID/$T] 构建声称成功，但既没有 out/$DID-$T.tar 也没有镜像 ${IMAGE}:$T"
done
log "[$DID] 全部档位均有产物：$TIERS"
