#!/bin/bash
# 自举构建路径（银河麒麟桌面 V10 SP1）
#
# 为什么不能用 mmdebstrap：
#   ① apt 在解析 V10 的 essential 集时报 "Couldn't configure debconf, probably a
#      dependency cycle"（V10 把 systemd/policycoreutils 等塞进了 Essential:yes）
#   ② 即使绕过①，宿主 Debian13 的 dpkg 1.22 会往 status 里写 `Conffiles: ... newconffile`
#      标记，而麒麟 V10 自带的 dpkg 1.19.7 解析不了 -> 后续所有 dpkg 操作失败
#   ③ 麒麟把 bash 的 preinst 编译成了 ELF 二进制，需要 libc 已在位才能执行
#
# 因此走两阶段自举：debootstrap --foreign 只解包（不跑脚本）-> 导入容器 ->
# 用**麒麟自己的 dpkg 1.19.7** 完成 configure。这是发行版工具链代差的标准解法。
set -eu
BK_HOST=${BK:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}      # buildkit 根
ROOT_HOST=${ROOT_HOST:-${ROOT:-$PWD}}                                    # 项目根（distros/keys/out 在这里）
# 容器内固定把项目根挂在 /w，于是 buildkit 自然位于 /w/buildkit
CROOT=/w; CBK=$CROOT/buildkit
BUILDER=${BUILDER:-dosb}
# DID 可由环境变量指定：这条两阶段自举路径最初只为 kylin10 写，后来凝思也要用
# （同一根因：目标发行版的 dpkg 在新版 builder 上跑 chroot 内配置会失败——
#  kylin10 是解析不了 status，凝思是直接死锁）。默认值保持 kylin10 不变。
DID=${DID:-kylin10}
[ -f "$ROOT_HOST/distros/$DID.conf" ] || { echo "!! 没有 distros/$DID.conf" >&2; exit 2; }
. "$ROOT_HOST/distros/$DID.conf"
TIERS=${*:-micro base devel}
# 档位白名单：传错了要当场说清楚，而不是等到 66 行报 "PKGS: 未绑定的变量"
# （本脚本 DID 是硬编码的，别把发行版名当档位传进来）
for _t in $TIERS; do
  case $_t in micro|base|devel) ;;
    *) echo "!! 无效档位 '$_t'（只接受 micro/base/devel；本脚本的 DID 由环境变量给（当前 $DID），档位参数只接受 micro/base/devel）" >&2; exit 2 ;;
  esac
done
STAGE=$CROOT/work/$DID-stage
log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ── 阶段 0：独立验签（debootstrap 用 gpgv，能接受麒麟 key 的 SHA1 自签名）
# 在线源必须验签；介质本地源没有签名（完整性由 ISO 的官方校验值兜，见各 conf 的
# ISO_MD5/ISO_SHA256），所以按 conf 的 NO_CHECK_GPG 跳过这一步而不是无条件执行。
if [ "${NO_CHECK_GPG:-no}" = yes ]; then
  log "[$DID] 源为介质本地仓库，跳过 InRelease 验签（完整性锚点是 ISO 的官方校验值）"
else
  docker exec "$BUILDER" bash -c "unset http_proxy https_proxy; ROOT=$CROOT BK=$CBK . $CBK/lib/common.sh; verify_repo_signature '${MIRROR%/}' '$SUITE'" || exit 1
fi

# ── 阶段 1：--foreign 纯解包
# .foreign-done 里存输入指纹（源+suite+components+STAGE_INCLUDE）。只有指纹一致才复用 stage，
# 否则改了 distros/*.conf 的包清单会静默拿旧 stage 继续构建。
# ⚠️ 指纹必须包含 keyring 的**内容哈希**：debootstrap 会把 --keyring 指向的文件
# 拷进 rootfs，并把它的文件名写进 sources.list 的 signed-by=。换了信任根却不换指纹，
# 旧 stage 会被复用，于是产物里留着一个仓库里已不存在的 keyring —— 实际踩过：
# 把信任集从 kylin-combined.gpg 收窄到 kylin-archive-keyring.gpg 之后，
# kylin10 三档仍然带着旧文件，而 manifest 的哈希锚点已经跟着新代码更新了。
if [ "${NO_CHECK_GPG:-no}" = yes ]; then
  KEYRING_FP=nogpg          # 无 keyring 时不能让指纹变空串 —— 那会让不同配置共用同一个 stage
else
  KEYRING_FP=$(sha256sum "$ROOT_HOST/keys/$(basename "${KEYRING:-keys/kylin-archive-keyring.gpg}")" 2>/dev/null | cut -c1-16)
  [ -n "$KEYRING_FP" ] || { echo "致命: keyring 指纹为空（文件不存在？）" >&2; exit 1; }
fi
# 缓存键必须含**全部**影响 stage 内容的输入。PIN_NEVER 原先不在键里，于是加了
# `debootstrap --exclude` 之后旧 stage 被直接复用 —— 改动完全没生效，日志里连
# --exclude 那行都不打印（整个阶段 1 被跳过）。漏一个输入等于把「改了配置」
# 静默降级成「什么都没改」，而且不报错，最容易让人去怀疑修法本身。
STAGE_FP=$(printf '%s|%s|%s|%s|%s|%s' "$MIRROR" "$SUITE" "$COMPONENTS" "${STAGE_INCLUDE:-}" "${PIN_NEVER:-}" "$KEYRING_FP" | sha256sum | cut -c1-16)
# STAGE_FROM_TAR 时必须连阶段 1 一起跳过：新 job 里 work 目录不存在，
# .foreign-done 指纹必然不匹配，debootstrap 会照跑一遍——传 tar 就白传了，
# 而且不报错，只是慢二十来分钟，最容易被当成「拆分没带来收益」。
if [ "${STAGE_FROM_TAR:-no}" = yes ] && [ -s "$ROOT_HOST/out/$DID-stage.tar" ]; then
  log "[$DID] 阶段1: 跳过（复用上游 job 传来的 stage tar）"
elif [ "$(cat "$ROOT_HOST/work/$DID-stage/.foreign-done" 2>/dev/null)" != "$STAGE_FP" ]; then
  if [ "${NO_CHECK_GPG:-no}" = yes ]; then
    DB_GPG_ARG="--no-check-gpg"
  else
    DB_GPG_ARG="--keyring=$CROOT/keys/$(basename "${KEYRING:-keys/kylin-archive-keyring.gpg}")"
  fi
  # PIN_NEVER 的包要在**入口**拦。此前的做法是过滤缓存安装，但这两个包其实是
  # debootstrap 的 base 集带进来的，过滤缓存拦不住；而事后 `dpkg --purge
  # --force-depends` 会把依赖图弄坏（实测 apt 依赖状态不健康），比原症状更重。
  # debootstrap 自己有 --exclude，那才是正确的杠杆。
  DB_EXCLUDE_ARG=""
  [ -n "${PIN_NEVER:-}" ] && DB_EXCLUDE_ARG="--exclude=$(printf '%s' "$PIN_NEVER" | tr ' ' ',')"
  [ -n "$DB_EXCLUDE_ARG" ] && log "[$DID] debootstrap $DB_EXCLUDE_ARG"
  log "[$DID] 阶段1: debootstrap --foreign（只解包，不跑 maintainer script）"
  docker exec "$BUILDER" bash -c "
    set -eo pipefail          # 否则 debootstrap 的退出码会被 | tail 吞掉
    unset http_proxy https_proxy; umask 022
    ln -sf $DEBOOTSTRAP_SCRIPT /usr/share/debootstrap/scripts/$SUITE
    rm -rf $STAGE
    unshare --pid --fork --mount-proc -- \
      debootstrap --foreign --variant=minbase --arch=$ARCH --no-merged-usr \
        ${DB_GPG_ARG} \
        --components=$(echo $COMPONENTS | tr ' ' ',') \
        ${DB_EXCLUDE_ARG} \
        --include=$STAGE_INCLUDE \
        $SUITE $STAGE $MIRROR > /tmp/db.log 2>&1 || { echo '--- debootstrap 失败，末 30 行 ---'; tail -30 /tmp/db.log; exit 1; }
    tail -2 /tmp/db.log
    # 宿主 dpkg1.22 若写过 newconffile 标记，麒麟 dpkg1.19.7 解析不了 -> 删掉这些行
    [ -s $STAGE/var/lib/dpkg/status ] && sed -i '/^ \\/.* newconffile\$/d' $STAGE/var/lib/dpkg/status
    mkdir -p $STAGE/usr/sbin
    printf '#!/bin/sh\\nexit 101\\n' > $STAGE/usr/sbin/policy-rc.d; chmod 755 $STAGE/usr/sbin/policy-rc.d
    rm -f $STAGE/var/lib/dpkg/lock* 2>/dev/null || true
    printf '%s' '$STAGE_FP' > $STAGE/.foreign-done
    du -sh $STAGE" || exit 1
fi

# ── 阶段 2：导入容器，用麒麟自己的 dpkg 自举 configure
#
# 阶段 1 的 stage 是三档共用的（实测占 selfhost 总耗时的三分之二），所以把它与
# 档位构建拆到不同 job 时，靠传递 out/<did>-stage.tar 复用，而不是各建一遍。
#   STAGE_ONLY=yes   只产出 stage tar 就退出，供上游 job 用
#   已存在 stage tar 时直接 import，跳过阶段 1 与打包
if [ -s "$ROOT_HOST/out/$DID-stage.tar" ] && [ "${STAGE_ONLY:-no}" != yes ] \
   && [ "${STAGE_FROM_TAR:-no}" = yes ]; then
  log "[$DID] 阶段2: 复用既有 stage tar（$(stat -c%s "$ROOT_HOST/out/$DID-stage.tar") 字节）"
else
  log "[$DID] 阶段2: 打包 stage 并导入"
  docker exec "$BUILDER" bash -c "cd $STAGE && tar --numeric-owner -cf $CROOT/out/$DID-stage.tar --exclude=./.foreign-done ." || exit 1
fi
docker import "$ROOT_HOST/out/$DID-stage.tar" "$IMAGE:_stage" >/dev/null

if [ "${STAGE_ONLY:-no}" = yes ]; then
  log "[$DID] STAGE_ONLY：stage tar 就绪（$(stat -c%s "$ROOT_HOST/out/$DID-stage.tar") 字节），不建档位"
  docker rmi "$IMAGE:_stage" >/dev/null 2>&1 || true
  exit 0
fi

for TIER in $TIERS; do
  log "[$DID/$TIER] 阶段3: 自举配置 + 装档位包"
  case $TIER in
    micro) PKGS=$(echo "$MICRO_INCLUDE" | tr ',' ' ') ;;
    base)  PKGS=$(echo "$BASE_INCLUDE"  | tr ',' ' ') ;;
    devel) PKGS="$(echo "$BASE_INCLUDE" | tr ',' ' ') $(echo "$DEVEL_INCLUDE" | tr ',' ' ')" ;;
  esac
  # 介质本地源是 file:///w/media/xx，容器里必须能读到那个路径，否则第三阶段
  # apt 取不到包，只报「以下档位包没装上」而不说为什么（实测踩过）。
  if [ -n "${MEDIA_DIR:-}" ]; then
    MEDIA_MOUNT="-v $ROOT_HOST/media/$MEDIA_DIR:$CROOT/media/$MEDIA_DIR:ro"
  else
    MEDIA_MOUNT=""
  fi
  C="sh-$DID-$TIER"
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run -d --name "$C" --privileged --init \
    -e DEBIAN_FRONTEND=noninteractive -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= \
    -e TIER="$TIER" -e PKGS="$PKGS" -e SUITE="$SUITE" -e MIRROR="$MIRROR" \
    -e COMPONENTS="$COMPONENTS" -e PIN_NEVER="${PIN_NEVER:-}" \
    -e NO_CHECK_GPG="${NO_CHECK_GPG:-no}" \
    -v "$BK_HOST/build/selfhost-inner.sh:/inner.sh:ro" \
    -v "$ROOT_HOST/keys:/keys:ro" \
    -v "$BK_HOST/lib:/dosbuild-lib:ro" \
    -v "$ROOT_HOST/assets:/dosbuild-assets:ro" \
    -v "$ROOT_HOST/distros:/dosbuild-distros:ro" \
    ${MEDIA_MOUNT} \
    -e DID="$DID" \
    "$IMAGE:_stage" sleep infinity >/dev/null
  if docker exec "$C" /bin/bash /inner.sh; then
    IMPORT_OPTS=(-c 'CMD ["/bin/bash"]' -c 'ENV LANG=C.UTF-8'
      -c "LABEL org.opencontainers.image.title=\"$DISPLAY_NAME\""
      -c "LABEL cn.internal.tier=\"$TIER\""
      -c "LABEL cn.internal.build-method=\"selfhost\""
      -c "LABEL cn.internal.suite=\"$SUITE\""
      -c "LABEL cn.internal.expect-glibc=\"$EXPECT_GLIBC\""
      -c "LABEL cn.internal.expect-libstdcpp=\"$EXPECT_LIBSTDCPP\"")
    # systemd 忽略 SIGTERM 只认 SIGRTMIN+3。判据必须是"容器里有没有 systemd"，
    # 不能按档位名 —— 麒麟 V10 把 systemd 放进了 Priority: required，
    # 连 micro 档都带着它，按名字判就会漏掉（实测踩过）。
    # 先落 tarball 再导入：产物可审计、可与其它两条路径统一做 tarball 层检查
    # （注意：docker export 的字节流不可逐位复现，见 report.md §8（可复现性））
    docker export "$C" > "$ROOT_HOST/out/$DID-$TIER.tar"
    # systemd 探测必须查**导出的 tar**，不能 docker exec：阶段 3 跑完之后这个容器
    # 就再也 exec 不进去了（报 cap_last_cap，见 report.md §9.1（局限）），用 exec 探测会让
    # STOPSIGNAL 静默漏设 —— 我就这么把它漏设过一次。
    if tar tf "$ROOT_HOST/out/$DID-$TIER.tar" 2>/dev/null | grep -qE '(usr/)?bin/systemctl$'; then
      IMPORT_OPTS+=(-c 'STOPSIGNAL SIGRTMIN+3')
    fi
    docker import "${IMPORT_OPTS[@]}" "$ROOT_HOST/out/$DID-$TIER.tar" "$IMAGE:$TIER" >/dev/null
    docker rm -f "$C" >/dev/null 2>&1 || true
    log "[$DID/$TIER] 完成 -> $IMAGE:$TIER $(docker images "$IMAGE:$TIER" --format '{{.Size}}')"
  else
    docker rm -f "$C" >/dev/null 2>&1 || true
    log "[$DID/$TIER] 失败"; exit 1
  fi
done
docker rmi "$IMAGE:_stage" >/dev/null 2>&1 || true
