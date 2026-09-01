#!/bin/bash
# 国产 OS 容器镜像构建 —— 公共函数库
# 所有路径以 $ROOT 为根（容器内为 /w，宿主为 /data/dosbuild）
ROOT="${ROOT:-/w}"
# 这两个可以被调用方单独覆盖：selfhost 路径在**目标容器内**执行，仓库是挂载进去的，
# 路径与构建容器不同，所以不能写死成 $ROOT 的子目录。
ASSETS_DIR="${ASSETS_DIR:-$ROOT/assets}"
KEYRING="${KEYRING:-$ROOT/keys/kylin-archive-keyring.gpg}"
# 架构参数化（ARCH / MULTIARCH / EXPECT_LOADER）
. "$(dirname "${BASH_SOURCE[0]}")/arch.sh"

# 统一的取源函数：fetch_exact <url> <out> [重试次数]
#
# 重试用 curl 自带的 --retry / --retry-all-errors，不手写循环——
# 手写循环等于把「重试几次、等多久」的策略从工具里挪到我们的代码里再实现一遍。
#
# 卡死判定用 --speed-limit / --speed-time 而不是 --max-time。这个源的故障形态是
# 「返回 200、Content-Length 正确、body 一个字节都不来」，而 --max-time 区分不了
# 「慢但在进」和「卡死不动」：收紧它会砍掉本来能成的大文件（27 MB 的索引在 45 秒内
# 需要 590 KB/s），放宽它会让一个 35 KB 的卡死连接白等三分钟。
# --speed-limit 1024 --speed-time 30 的含义是「持续 30 秒低于 1 KB/s 就放弃」，
# 正常传输不受影响，卡死的 30 秒内退出并由 --retry 接手。
#
# 落地后必须校验字节非空：只看 curl 退出码会把「拿到空文件」当成拿到了。
fetch_exact() {
  local url=$1 out=$2 tries=${3:-5}
  rm -f "$out"
  curl -fsS --connect-timeout 20 --speed-limit 1024 --speed-time 30 \
       --retry "$tries" --retry-delay 3 --retry-all-errors -o "$out" "$url" \
    && [ -s "$out" ]
}

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '[%s] 致命: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ── GPG：麒麟的 archive key 自签名用 SHA1，apt3 的 sqv 拒绝，改用 gpgv 验（真验证，非跳过）
#    apt 侧通过 --aptopt='APT::Key::gpgvcommand "gpgv"' 切换，见 build/build.sh
# ── 推导 SOURCE_DATE_EPOCH：取仓库 Release 的 Date（同一快照 -> 同一时间戳）。
#    build.sh 与 mk-localrepo.sh 必须用同一套逻辑，否则本地源里重打包的 deb 时间戳
#    与主构建不一致，产物哈希就会漂（实测踩过：差异只在 libboundscheck 的 /usr/include）。
derive_epoch() {
  local mirror=$1 suite=$2 rel
  if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then printf '%s' "$SOURCE_DATE_EPOCH"; return 0; fi
  rel=$(curl -fsS --max-time 60 "${mirror%/}/dists/$suite/Release" 2>/dev/null \
        | sed -n 's/^Date: //p' | head -1)
  if [ -n "$rel" ]; then
    date -u -d "$rel" +%s 2>/dev/null || printf '%s' 1700000000
  else
    printf '%s' 1700000000
  fi
}

# 构建前独立验一次仓库签名，失败即中止（不依赖 apt 的策略）
verify_repo_signature() {
  local base=$1 suite=$2 tmp
  [ -f "$KEYRING" ] || die "keyring 不存在: $KEYRING"
  tmp=$(mktemp -d)
  # 国内归档站对境外出口不稳定：实测过「返回 200 且 Content-Length 正确、
  # body 却是 0 字节直到超时」。所以必须重试，并且**校验落地字节非空**——
  # 只看 curl 退出码会把「拿到空文件」当成拿到了。
  if ! fetch_exact "$base/dists/$suite/InRelease" "$tmp/InRelease" 5; then
    rm -rf "$tmp"; die "取不到 $suite 的 InRelease（五轮重试均失败）"
  fi
  if gpgv --keyring "$KEYRING" "$tmp/InRelease" 2>&1 | grep -q "Good signature"; then
    local who; who=$(gpgv --keyring "$KEYRING" "$tmp/InRelease" 2>&1 | grep -o 'Good signature from.*' | head -1)
    log "GPG 验签通过 [$suite] $who"
    rm -rf "$tmp"; return 0
  fi
  rm -rf "$tmp"; die "GPG 验签失败 [$suite]"
}

# ── 容器化适配：所有发行版共用
#    $1 = rootfs 路径, $2 = sources.list 内容, $3 = distro-id
adapt_container() {
  local R=$1 SRCLIST=$2 DID=$3
  mkdir -p "$R/usr/sbin" "$R/etc/apt/apt.conf.d" "$R/etc/dpkg/dpkg.cfg.d" \
           "$R/var/log" "$R/var/tmp" "$R/tmp" "$R/run" "$R/proc" "$R/sys" "$R/dev" "$R/root"
  chmod 1777 "$R/tmp" "$R/var/tmp"; chmod 700 "$R/root"

  printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod 755 "$R/usr/sbin/policy-rc.d"

  local CLEAN='rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true'
  cat > "$R/etc/apt/apt.conf.d/docker-clean" <<EOF
DPkg::Post-Invoke { "$CLEAN"; };
APT::Update::Post-Invoke { "$CLEAN"; };
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
EOF
  printf 'Acquire::GzipIndexes "true";\nAcquire::CompressionTypes::Order:: "gz";\n' > "$R/etc/apt/apt.conf.d/docker-gzip-indexes"
  printf 'Acquire::Languages "none";\n'                  > "$R/etc/apt/apt.conf.d/docker-no-languages"
  printf 'Apt::AutoRemove::SuggestsImportant "false";\n' > "$R/etc/apt/apt.conf.d/docker-autoremove-suggests"
  # 麒麟 key 自签名是 SHA1，容器内 apt 也要走 gpgv
  printf 'APT::Key::gpgvcommand "gpgv";\n'               > "$R/etc/apt/apt.conf.d/docker-gpgv"
  # 出厂镜像自带 apt 重试。用户拉到这些镜像后面对的是同一个厂商源，而它对境外出口
  # 偶发卡死（返回 200、Content-Length 正确、body 零字节）。
  # Timeout 是**不活动**超时——manpage 原文 "applies to the connection as well as
  # the data timeout"，只要数据在流就不触发，所以 45 秒对多大的索引都安全；
  # 曾误当成总时长上限而调到 180，结果单个卡死的包最坏耗时翻四倍。
  printf 'Acquire::Retries "3";\nAcquire::http::Timeout "45";\n' \
                                                         > "$R/etc/apt/apt.conf.d/docker-retries"
  # ⚠️ 不设 force-unsafe-io。麒麟 V11 的 dpkg 1.22.6-ok3k1.9 在这个代码路径上有缺陷：
  #    一旦启用，容器内 apt 安装任何新包都会在 configure 阶段段错误（core dumped），
  #    且随后的 `dpkg --configure -a` 也会崩。实测去掉后装/卸完全干净。
  #    它唯一的好处是构建期速度，而我们只构建一次，不值这个风险。
  rm -f "$R/etc/dpkg/dpkg.cfg.d/docker-apt-speedup"

  # 麒麟 V11 的 dpkg 在容器内 --unpack 收尾会 SIGSEGV（文件已正确解包）。
  # 装一个只供 apt 调用的包装器吸收它并补跑 configure；命令行 dpkg 不受影响。
  # micro 档没有 apt，装了纯属死重量；只在有 apt 的档安装
  if [ "${DPKG_SEGV_WRAPPER:-no}" = yes ] && [ "${TIER:-}" != micro ] \
     && [ -f "$ASSETS_DIR/dpkg-segv-wrapper.sh" ]; then
    install -D -m 755 "$ASSETS_DIR/dpkg-segv-wrapper.sh" "$R/usr/local/bin/dpkg-segv-wrapper"
    printf 'Dir::Bin::dpkg "/usr/local/bin/dpkg-segv-wrapper";\n' > "$R/etc/apt/apt.conf.d/docker-dpkg-wrapper"
  fi

  # SRCLIST 为空时要**清空** sources.list，不能放着不管：mmdebstrap 在 bootstrap 期
  # 写进去的是宿主侧路径（`copy:///w/localrepo/...`、`signed-by=/w/keys/...`），
  # 出厂镜像里指向构建机上的目录，毫无意义还会误导使用者。micro 档没有 apt，
  # 正确状态是空文件而不是残留的构建期配置。
  if [ -n "$SRCLIST" ]; then
    printf '%s\n' "$SRCLIST" > "$R/etc/apt/sources.list"
  else
    : > "$R/etc/apt/sources.list"
  fi
  # keyring 只拷给**真的要用它验签**的路径。早先这里是无条件拷贝，于是走切片路径、
  # 根本不从在线源拉包的 UOS 也被塞进一把麒麟的 key —— 它的 micro 档里那把还是
  # 目录下唯一的文件。这与「UOS 的信任根是 ISO 本身」以及「多一把没用的 key 就是
  # 多一份可被滥用的授权」直接冲突。判据用 $SRCLIST：只有写了在线源的路径才需要它。
  if [ -n "$SRCLIST" ] && [ -f "$KEYRING" ]; then
    mkdir -p "$R/usr/share/keyrings"
    cp "$KEYRING" "$R/usr/share/keyrings/" 2>/dev/null || true
  fi

  # 麒麟的一类打包 bug：multiarch 目录里布局正确，同时又在 /usr/lib 塞了冗余真文件，
  # 文件名恰好等于 SONAME 且不是符号链接 -> ldconfig 每次都报 "is not a symbolic link"。
  # 把 /usr/lib 下的冗余份改成指向 multiarch 正确副本（文件内容一致，零功能损失）。
  fix_redundant_soname_files "$R"

  : > "$R/etc/machine-id"
  rm -f "$R/etc/hostname" "$R/etc/resolv.conf" "$R/etc/hosts"
  ln -sfn /proc/self/mounts "$R/etc/mtab"
  rm -f "$R"/etc/ssh/ssh_host_* "$R/var/lib/systemd/random-seed" "$R/var/lib/dbus/machine-id" 2>/dev/null || true
  # ── 影子文件 ────────────────────────────────────────────────────────────────
  # 麒麟 V11 的 micro 档（mmdebstrap custom variant）不跑 passwd 的 postinst，
  # 于是 /etc/shadow、/etc/gshadow 压根没生成，可 su/newgrp 的 setuid 位还在 ——
  # setuid 二进制拿不到影子文件，既没用又是白送的攻击面。这里按 pwconv/grpconv
  # 的语义补出来（口令一律 `*` = 锁定，容器里 docker exec 不走 PAM，不受影响）。
  # 最后改动日期必须用 SOURCE_DATE_EPOCH 折算，不能用「今天」，否则可复现性当场报废。
  local sdays=$(( ${SOURCE_DATE_EPOCH:-0} / 86400 ))
  if [ ! -e "$R/etc/shadow" ] && [ -f "$R/etc/passwd" ]; then
    awk -F: -v d="$sdays" '{print $1":*:"d":0:99999:7:::"}' "$R/etc/passwd" > "$R/etc/shadow"
    chmod 640 "$R/etc/shadow"; chown 0:42 "$R/etc/shadow" 2>/dev/null || true
  fi
  if [ ! -e "$R/etc/gshadow" ] && [ -f "$R/etc/group" ]; then
    awk -F: '{print $1":*::"$4}' "$R/etc/group" > "$R/etc/gshadow"
    chmod 640 "$R/etc/gshadow"; chown 0:42 "$R/etc/gshadow" 2>/dev/null || true
  fi

  # ── systemd：桌面语义改成 server 语义 ────────────────────────────────────────
  # 三个发行版都是**桌面** ISO 出身，default.target 指向 graphical.target，
  # 会去拉 display-manager；而且一个 masked 单元都没有，容器里跑不了的单元
  # （udev / 内核挂载 / audit socket / 厂商 LSM 守护）会一路报错刷屏。
  # 守卫必须判 multi-user.target 本身是否存在。只判目录不行：micro 档也有
  # /usr/lib/systemd/system 目录（个别包会往里丢单元），但没有 target 文件，
  # 于是 default.target 会变成一条**悬空软链**（实测踩过）。
  # 单元目录得实测，不能写死 /usr/lib：麒麟 V10 不做 usr-merge，单元在 /lib/systemd/system，
  # 守卫两处都判了却把软链目标写死成 /usr/lib —— 结果三档全是悬空的 default.target。
  local unitdir=""
  if   [ -e "$R/usr/lib/systemd/system/multi-user.target" ]; then unitdir=/usr/lib/systemd/system
  elif [ -e "$R/lib/systemd/system/multi-user.target" ];     then unitdir=/lib/systemd/system
  fi
  if [ -n "$unitdir" ]; then
    mkdir -p "$R/etc/systemd/system"
    ln -sfn "$unitdir/multi-user.target" "$R/etc/systemd/system/default.target"

    # 只 mask 在容器里**确证跑不起来**的单元，不做无根据的裁剪。
    local u
    for u in \
      systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
      systemd-udev-trigger.service systemd-modules-load.service \
      systemd-journald-audit.socket \
      sys-kernel-config.mount sys-kernel-debug.mount sys-kernel-tracing.mount \
      sys-fs-fuse-connections.mount proc-sys-fs-binfmt_misc.mount \
      display-manager.service \
      kysec-daemon.service kysecmgr.service
    do
      # 宿主上不存在的单元不必 mask，免得留下一堆指向虚空的软链
      if [ -e "$R/usr/lib/systemd/system/$u" ] || [ -e "$R/lib/systemd/system/$u" ]; then
        ln -sfn /dev/null "$R/etc/systemd/system/$u"
      fi
    done
  fi

  # ── UOS 的授权源 ────────────────────────────────────────────────────────────
  # UOS V25 的 sources.list.d 里有两个**需要订阅授权**的专业源，未授权时返回 401，
  # 会让整个 `apt-get update` 退出非零 —— 哪怕 appstore 源本身是通的。
  # 镜像里带一个必然失败的源清单没有意义，所以默认注释掉，并留下重新启用的说明。
  # 注意：即便全部打通，UOS V25 也没有 apt 形式的 OS 软件源（实测仅剩的 appstore 源
  # 源只提供 2496 个包且全来自应用商店，不含 nano 这类 OS 包）—— 它的 OS 分发走 OSTree + 玲珑。
  for _l in "$R"/etc/apt/sources.list.d/*.list; do
    [ -f "$_l" ] || continue
    if grep -qE '^deb .*(professional-security\.chinauos\.com|pro-driver-packages\.uniontech\.com)' "$_l"; then
      sed -i -E 's|^(deb .*(professional-security\.chinauos\.com\|pro-driver-packages\.uniontech\.com).*)$|# [容器镜像默认禁用] 该源需订阅授权，未授权返回 401 会使 apt-get update 整体失败。\n# 有授权后请取消下一行注释，并把凭据写入 /etc/apt/auth.conf.d/\n#\1|' "$_l"
    fi
  done

  # 时区：容器约定 UTC。UOS 的 squashfs 里压根没有 /etc/localtime（真机首启才建），
  # 不补的话 date 只能靠 glibc 的默认值，且 /etc/localtime 缺失会让某些程序告警。
  if [ ! -e "$R/etc/localtime" ] && [ -e "$R/usr/share/zoneinfo/Etc/UTC" ]; then
    ln -sfn /usr/share/zoneinfo/Etc/UTC "$R/etc/localtime"
    printf 'Etc/UTC\n' > "$R/etc/timezone"
  fi
  [ -f "$R/etc/nsswitch.conf" ] || printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\nnetworks: files\nprotocols: db files\nservices: db files\nethers: db files\nrpc: db files\n' > "$R/etc/nsswitch.conf"
  # 内核/固件/initramfs 残留（bootstrap 期间可能按宿主 uname -r 生成）
  # ⚠️ 删文件的同一处必须把包数据库一起改，否则库里会留下「已装而文件全不在」的
  # 幽灵包。凝思实测：linux-image-* 登记为 install ok installed、Installed-Size
  # 261829（256 MB），文件一个不在 —— SBOM 报告一个不存在的包，trivy 因此凭空
  # 产出 373 条 HIGH+CRITICAL，占该镜像全部命中的 69%（缺陷 D18）。
  # 在入口用 debootstrap --exclude 拦不住它（它是作为依赖被拉进来的），
  # 而这里正是不一致被创造出来的地方，所以修在这里。
  if [ -x "$R/usr/bin/dpkg-query" ] || [ -x "$R/usr/bin/dpkg" ]; then
    # 必须连同**依赖内核包的包**一起 purge。只 purge 叶子会把「清单不一致」
    # 换成「依赖不一致」—— 实测两次：initramfs-tools 那次和内核这次，
    # 症状都是第三阶段自检报 apt-check=BAD。凝思这条链是
    # linux-image-amd64 → linux-image-4.19.0-11-...-unsigned ← update-drivers-4.19.0。
    _st="$R/var/lib/dpkg/status"; [ -f "$_st" ] || _st="$R/usr/lib/dpkg/var/status"
    _kpkgs=$(chroot "$R" dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
      | awk '$NF=="installed"{print $1}' | grep -E '^linux-image|^linux-headers|^update-drivers' | tr '\n' ' ')
    if [ -n "$(printf %s "$_kpkgs" | tr -d " ")" ]; then
      log "  移除幽灵内核包登记: $_kpkgs"
      chroot "$R" dpkg --purge --force-all $_kpkgs >/dev/null 2>&1 || \
        chroot "$R" dpkg --remove --force-all $_kpkgs >/dev/null 2>&1 || true
      # 当场验证依赖图仍健康。之前两次都是等到第三阶段自检才发现坏了。
      if [ -x "$R/usr/bin/apt-get" ]; then
        if ! chroot "$R" apt-get check >/dev/null 2>&1; then
          log "  ⚠ purge 后依赖图不健康，逐条列出："
          chroot "$R" apt-get check 2>&1 | head -6 | sed 's/^/      /'
          die "purge 内核链破坏了依赖图 —— 检查是否还有包依赖被删的包"
        fi
        log "  purge 后 apt-get check 通过"
      fi
    fi
  fi
  rm -rf "$R"/boot/* "$R"/lib/modules/* "$R"/usr/lib/modules/* "$R"/lib/firmware "$R"/usr/lib/firmware \
         "$R"/var/lib/initramfs-tools/* 2>/dev/null || true
  find "$R/var/log" -type f -exec sh -c ': > "$1"' _ {} \; 2>/dev/null || true
  rm -rf "$R"/var/lib/apt/lists/* "$R"/var/cache/apt/*.bin "$R"/var/cache/apt/archives/*.deb 2>/dev/null || true
}

# 修 /usr/lib 下与 multiarch 重复的真文件（麒麟 libchkuid / libkylin_chkname 等）
fix_redundant_soname_files() {
  local R=$1 ma="$R/usr/lib/$MULTIARCH" base real cand f
  [ -d "$ma" ] || return 0
  # glob 放宽：原来的 *.so.[0-9].[0-9].[0-9] 只匹配三段全单数字，
  # libfoo.so.1.2.10 / libfoo.so.0.10.0 这类会漏
  for real in "$ma"/*.so.[0-9]*; do
    # 只认**普通文件**：放宽 glob 后它也会匹配到 multiarch 目录里的符号链接
    # （如 libchkuid.so.0 -> libchkuid.so.0.0.0），把 /usr/lib 的冗余份指向一个
    # 符号链接虽然功能上等价，但取哪个取决于 glob 顺序，产物就不再逐位可复现。
    [ -f "$real" ] && [ ! -L "$real" ] || continue
    base=$(basename "$real")
    for cand in "${base%.*.*}" "${base%.*.*.*}" "$base"; do
      # 覆盖 libX.so / libX.so.N / libX.so.N.N.N 三种命名
      for f in "${cand}" "${cand%.so*}.so" "${base%.*.*}" ; do
        [ -n "$f" ] || continue
        if [ -e "$R/usr/lib/$f" ] && [ ! -L "$R/usr/lib/$f" ] && [ ! -d "$R/usr/lib/$f" ]; then
          if cmp -s "$R/usr/lib/$f" "$real"; then
            ln -sf "$MULTIARCH/$base" "$R/usr/lib/$f"
          fi
        fi
      done
    done
  done
  # /lib 若是真目录（非 usr-merge）也扫一遍
  if [ -d "$R/lib" ] && [ ! -L "$R/lib" ]; then
    for real in "$R"/lib/$MULTIARCH/*.so.[0-9]*; do
      [ -f "$real" ] && [ ! -L "$real" ] || continue
      base=$(basename "$real")
      for f in "${base%.*.*}" "${base%.so*}.so" "$base"; do
        if [ -e "$R/lib/$f" ] && [ ! -L "$R/lib/$f" ] && cmp -s "$R/lib/$f" "$real"; then
          ln -sf "$MULTIARCH/$base" "$R/lib/$f"
        fi
      done
    done
  fi
}

# 只保留 C / zh_CN / en_US 三套 locale（国产 OS 必须留 zh_CN）
slim_locales() {
  local R=$1
  [ -d "$R/usr/share/locale" ] && find "$R/usr/share/locale" -mindepth 1 -maxdepth 1 -type d \
      ! -name 'zh_CN*' ! -name 'en*' ! -name 'C*' -exec rm -rf {} + 2>/dev/null || true
  [ -d "$R/usr/share/i18n/charmaps" ] && find "$R/usr/share/i18n/charmaps" -type f \
      ! -name 'UTF-8*' -delete 2>/dev/null || true
}

# 确定性打包：时间戳归一到 SOURCE_DATE_EPOCH，条目按名排序，剔除 atime/ctime，
# 保留 numeric-owner 与 xattr（file capabilities 靠它）。两次构建应逐位一致。
make_tarball() {
  local R=$1 OUT=$2 epoch="${SOURCE_DATE_EPOCH:-1700000000}" err
  err=$(mktemp)
  # 注意 GNU tar 的 --mtime 是**无条件覆盖**所有条目，不是 clamp，所以不需要先 touch 一遍
  # （之前那趟 find|touch 对结果毫无贡献，还要遍历几十万文件并改写源目录）
  if ! ( cd "$R" && tar --numeric-owner --xattrs --xattrs-include='*' \
      --sort=name --mtime="@$epoch" \
      --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
      -cf "$OUT" . ) 2>"$err"; then
    log "!! tar 打包失败:"; sed 's/^/     /' "$err" >&2; rm -f "$err"; return 1
  fi
  # tar 返回 1 是警告（如 file changed as we read it / xattr 写不进），也值得看见
  [ -s "$err" ] && { log "  tar 警告 $(wc -l < "$err") 行（前 3）:"; head -3 "$err" | sed 's/^/     /'; }
  rm -f "$err"
  log "打包 $OUT ($(du -h "$OUT" | cut -f1), SOURCE_DATE_EPOCH=$epoch)"
}

# ── 厂商缺陷兜底：某些包（麒麟 bzip2 等）用硬链接，配合 usr-merge 的 /bin->usr/bin，
#    dpkg 在 configure 阶段会段错误（core dumped）。这些包的控制包里**没有任何
#    maintainer script**，configure 本身是空操作，只更新状态。
#    做法：先用 dpkg -V 校验文件完整性，通过后直接把状态改成 installed。
#    这样既不跳过校验，也不留半配置状态。$1 = rootfs
fix_unconfigured_noscript_pkgs() {
  local R=$1 adm="${2:-var/lib/dpkg}" pkgs p arch n s has_script
  pkgs=$(awk '/^Package: /{p=$2} /^Status: install ok (unpacked|half-configured|half-installed)/{print p}' "$R/$adm/status" 2>/dev/null)
  [ -n "$pkgs" ] || return 0
  for p in $pkgs; do
    # ⚠️ 不能写成 `ls "$info/$p".{preinst,postinst,...}`：ls 只要任一操作数不存在就返回
    #    非 0，那个 if 的真实语义会变成"四个脚本全都存在才跳过"，等于守卫失效。
    #    另外 Multi-Arch: same 的包（info/format 为 1 时）脚本名带 :arch，也必须一起查。
    arch=$(awk -v P="$p" '/^Package: /{c=$2} c==P && /^Architecture: /{print $2; exit}' "$R/$adm/status" 2>/dev/null)
    has_script=no
    for n in "$p" "${p}:${arch}"; do
      for s in preinst postinst prerm postrm; do
        [ -f "$R/$adm/info/$n.$s" ] && has_script=yes
      done
    done
    if [ "$has_script" = yes ]; then
      log "  跳过 $p（有 maintainer script，需人工处理）"; continue
    fi
    # 有 conffiles 的包也不碰：configure 阶段才把 conffile 就位，硬改状态会让它永远缺失
    if [ -f "$R/$adm/info/$p.conffiles" ] || [ -f "$R/$adm/info/${p}:${arch}.conffiles" ]; then
      log "  跳过 $p（有 conffiles）"; continue
    fi
    # md5sums 为空时 dpkg -V 会"空过"返回 0，所以要求 md5sums 非空才敢采信
    if [ ! -s "$R/$adm/info/$p.md5sums" ] && [ ! -s "$R/$adm/info/${p}:${arch}.md5sums" ]; then
      log "  跳过 $p（无 md5sums，dpkg -V 无法采信）"; continue
    fi
    if chroot "$R" dpkg -V "$p" >/dev/null 2>&1; then
      python3 - "$R/$adm/status" "$p" <<'PY2'
import sys,re,os,tempfile
path,pkg=sys.argv[1],sys.argv[2]
blocks=open(path,encoding='utf-8',errors='replace').read().split('\n\n')
out=[]
for b in blocks:
    m=re.search(r'^Package: (\S+)',b,re.M)
    if m and m.group(1)==pkg:
        b=re.sub(r'^Status: install ok (unpacked|half-configured|half-installed)$','Status: install ok installed',b,flags=re.M)
    out.append(b)
# 原地重写 dpkg status 是危险动作：先写临时文件再 rename，保证原子（dpkg 自己也这么做）
d=os.path.dirname(path)
fd,tmp=tempfile.mkstemp(dir=d,prefix='status-new.')
with os.fdopen(fd,'w',encoding='utf-8') as fh:
    fh.write('\n\n'.join(out))
os.replace(tmp,path)
PY2
      log "  $p: 无脚本/无 conffiles + dpkg -V 通过 -> 状态置为 installed（厂商 dpkg 段错误兜底）"
    else
      log "  !! $p: dpkg -V 校验未过，不做处理"
    fi
  done
}
