#!/bin/bash

# 凡在 chroot 里跑目标发行版的 dpkg/apt，一律套超时。
# 实测教训：凝思（Debian 10）在 Debian 13 的 builder 上跑 `dpkg --configure -a`
# 会挂死 —— CPU 归零、dpkg 变僵尸、mmdebstrap 永不返回，等 20 分钟也不报错。
# 这与 kylin10 那个「宿主 dpkg 1.22 写的 status，目标 dpkg 1.19.7 解析不了」同族
# （见 report §4.2 缺陷 D07）。挂死必须变成有界失败，否则构建链会静默停住。
CT() {  # CT <秒> <rootfs> <sh -c 的命令>
  local secs=$1 root=$2; shift 2
  timeout -k 5 "$secs" chroot "$root" /bin/sh -c "$*"
  local rc=$?
  [ "$rc" = 124 ] && log "  ! chroot 命令超时 ${secs}s（已跳过）: ${*:0:60}"
  return 0   # 这些都是尽力而为的收尾步骤，超时不该让整个构建失败
}
# mmdebstrap --customize-hook：$1 = rootfs 路径（宿主侧）
# 环境: ROOT DID TIER
set -eu
ROOT="${ROOT:-/w}"; . "$ROOT/lib/common.sh"
R=$1; DID="${DID:?}"; TIER="${TIER:?}"
. "$ROOT/distros/$DID.conf"
ADM="${ADMINDIR:-var/lib/dpkg}"

# ══ 阶段 1：还需要网络的操作（必须在 adapt_container 删掉 resolv.conf 之前做）
# 保证 chroot 内 DNS 可用
cp -f /etc/resolv.conf "$R/etc/resolv.conf" 2>/dev/null || \
  printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > "$R/etc/resolv.conf"

# devel 档的工具链由 --include 一次装到位；这里只做厂商缺陷兜底
if [ "$TIER" = devel ]; then
  fix_unconfigured_noscript_pkgs "$R" "$ADM"
  CT 120 "$R" 'export DEBIAN_FRONTEND=noninteractive; dpkg --configure -a >/dev/null 2>&1; true' 
  fix_unconfigured_noscript_pkgs "$R" "$ADM"
  log "[$DID/$TIER] 工具链: $(CT 30 "$R" 'echo "gcc=$(command -v gcc||echo -) g++=$(command -v g++||echo -) make=$(command -v make||echo -)"' 2>/dev/null)"
fi

# CA 证书（postinst 可能没跑成，显式重跑）
CT 60 "$R" 'command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1; true' 

# locale：只生成 zh_CN.UTF-8 / en_US.UTF-8
timeout -k 5 180 chroot "$R" /bin/sh -c '
  if [ -d /usr/share/i18n/locales ] && command -v localedef >/dev/null 2>&1; then
    localedef -i zh_CN -c -f UTF-8 zh_CN.UTF-8 2>/dev/null || true
    localedef -i en_US -c -f UTF-8 en_US.UTF-8 2>/dev/null || true
  fi; true' || true

# micro 档：拔掉 apt（保留 dpkg 与包数据库，比麒麟官方 micro 更可审计）
if [ "$TIER" = micro ]; then
  ADM="$ADM" timeout -k 5 180 chroot "$R" /bin/sh -c '
    for p in apt apt-utils; do
      if dpkg-query -W "$p" >/dev/null 2>&1; then
        rm -f "/$ADM/info/$p".pre* "/$ADM/info/$p".post*
        dpkg --purge --force-all "$p" >/dev/null 2>&1 || true
      fi
    done; true' || true
fi

# ══ 阶段 2：不需要网络的收尾
fix_unconfigured_noscript_pkgs "$R" "$ADM"
CT 120 "$R" 'dpkg --configure -a >/dev/null 2>&1; true'

# micro 档没有 apt（定位就是纯运行时），给它写 sources.list 再塞一把 keyring 是纯粹的
# 冗余：谁都不会去读它，而 keyring 是信任材料，留着就是白送一份可被滥用的授权。
# 判据同时看路径与**档位** —— 早先只按路径判，于是 UOS micro 干净了、麒麟 micro 没干净，
# 同一句「多一把没用的 key 就是多一份授权」在那里没落到底。
if [ "$TIER" = micro ]; then
  SRCLIST=""
else
  SRCLIST="deb [signed-by=/usr/share/keyrings/kylin-archive-keyring.gpg] $MIRROR $SUITE $COMPONENTS"
fi
adapt_container "$R" "$SRCLIST" "$DID"
slim_locales "$R"
[ "$TIER" = micro ] && rm -rf "$R/var/lib/apt" "$R/var/cache/apt" 2>/dev/null || true

# 最终自检（写进构建日志，便于审计）
log "[$DID/$TIER] 自检: $(timeout -k 5 90 chroot "$R" /bin/sh -c 'echo -n "apt-check=$([ -x /usr/bin/apt-get ] && (/usr/bin/apt-get check >/dev/null 2>&1 && echo OK || echo BAD) || echo n/a) audit=$(dpkg --audit 2>&1|wc -l) locale=$(locale -a 2>/dev/null|grep -c zh_CN) ca=$(stat -c%s /etc/ssl/certs/ca-certificates.crt 2>/dev/null||echo 0)"' 2>/dev/null)"
