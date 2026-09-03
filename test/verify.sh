#!/bin/bash
# 全量验收：对每个镜像跑结构/完整性/能力/ABI-gate 检查，并与 distros/*.conf 的预期基线对账
# BK = buildkit 自身的根（lib/build/test/tools/gate 在这里）
# ROOT = 项目根（distros/out/localrepo/keys 在这里）
# submodule 布局下两者不是同一个目录，混用会在「找得到 conf 却找不到 common.sh」
# 这种地方失败，报错离真因很远。
BK="${BK:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
set -u
# 项目根：submodule 布局下脚本父目录是 buildkit 根，不是项目根，所以只能取调用方的 cwd
ROOT=${ROOT:-$PWD}
GATE_BIN=$BK/gate/t_low          # manylinux2014 编的低地板产物（GLIBC_2.14/GLIBCXX_3.4.11）
GATE_HIGH=$BK/gate/t_high        # Debian13 编的高地板产物（GLIBC_2.34）
PASS=0; FAIL=0; WARN=0
declare -a PROBLEMS=()

check(){ # name expect actual [warn]
  local n=$1 e=$2 a=$3 lvl=${4:-fail}
  if [ "$a" = "$e" ]; then
    if is_xfail "$n"; then
      XPASS_HITS=$((XPASS_HITS+1))
      XNOTES+=("  ⚑ $IMG $n 列在 XFAIL 里却通过了（实际 $a）—— 该例外可以收回")
      PASS=$((PASS+1)); _rec "$n" xpass; return 0
    fi
    PASS=$((PASS+1)); _rec "$n" pass; return 0
  fi
  if is_xfail "$n"; then
    XFAIL_HITS=$((XFAIL_HITS+1))
    XNOTES+=("  ○ $IMG $n: 期望 $e 实际 $a （XFAIL，已知且预期）")
    _rec "$n" xfail; return 1
  fi
  if [ "$lvl" = warn ]; then WARN=$((WARN+1)); PROBLEMS+=("  ⚠ $IMG $n: 期望 $e 实际 $a"); _rec "$n" warn; else
    FAIL=$((FAIL+1)); PROBLEMS+=("  ✗ $IMG $n: 期望 $e 实际 $a"); _rec "$n" fail; fi
  return 1
}

# pass/fail：给那些**不是"期望值==实际值"形态**的判断用（阈值、子集、白名单）。
# ⚠️ 这两个函数一开始我忘了定义就直接用，结果 `fail: 未找到命令` ——
# 成功分支和失败分支都是命令未找到，既不计通过也不计失败，四个检查全程空转。
# 这就是本项目反复出现的那类"假通过"，所以变异测试是必需的而不是锦上添花。
# ── 期望失败（xfail）────────────────────────────────────────────────────────────
# 有些检查在某些被试上注定红，而且那不是缺陷：银河麒麟 V4 是 Ubuntu 16.04 血脉，
# 它带的 gnupg 会装一个链接 libldap 的 gpgkeys_ldap，而我们不装 Recommends，
# 于是 ldd 报缺库——真实的 V4 装机同样如此，镜像是忠实的。
#
# 这类项写进 conf 的 XFAIL（或按档位的 XFAIL_MICRO / XFAIL_BASE / XFAIL_DEVEL），
# 失败时计入 xfail 而不是 fail，不构成 CI 失败。
#
# 但反向也要管：列进 XFAIL 的项**居然通过了**要单独报（xpass）。否则某天上游修好了、
# 或者我们的构建变了，这条豁免会永远挂在那里，掩盖住一个本该收回的例外。
# xpass 不判失败，但必须出现在报告里让人回来删。
XFAIL_HITS=0; XPASS_HITS=0
declare -a XNOTES=()
# 逐检查项的状态，供汇总阶段画能力矩阵。只有汇总数画不出矩阵——
# 「哪一项在哪个镜像上是什么状态」是四态图的基本单位。
# 状态取值：pass / fail / xfail / warn。某个镜像上压根没跑的项在图上是「不适用」，
# 由汇总阶段按「全部镜像的项集合」减去本镜像已记录的项推出，不在这里编造。
declare -a CHECKS=()
_M_GLIBC=""; _M_LIBSTDCPP=""; _M_GLIBCXX=""
_rec(){ CHECKS+=("$IMG|$1|$2"); }
# 显式「不适用」：记录状态并给出理由。与「压根没跑到」区分开——后者在矩阵里
# 同样显示为不适用，但那是推断出来的；这里是我们主动声明的，日志里有理由可查。
skip(){ _rec "$1" na; XNOTES+=("  ⬜ $IMG $1 不适用：$2"); }
_xfail_set() {
  local t; t=$(printf '%s' "${TIER:-}" | tr '[:lower:]' '[:upper:]')
  local extra; extra=$(eval "printf '%s' \"\${XFAIL_${t}:-}\"" 2>/dev/null || true)
  printf '%s %s' "${XFAIL:-}" "$extra"
}
is_xfail() {   # $1 = 检查名（允许带尾随冒号）
  local n=${1%:}
  case " $(_xfail_set) " in *" $n "*) return 0;; esac
  return 1
}

pass(){
  local n=${1%% *}
  if is_xfail "$n"; then
    XPASS_HITS=$((XPASS_HITS+1))
    XNOTES+=("  ⚑ $IMG $n 列在 XFAIL 里却通过了 —— 该例外可以收回")
    PASS=$((PASS+1)); _rec "$n" xpass; return 0
  fi
  PASS=$((PASS+1)); _rec "$n" pass
}
fail(){
  local n=${1%% *}
  if is_xfail "$n"; then
    XFAIL_HITS=$((XFAIL_HITS+1))
    XNOTES+=("  ○ $IMG $* （XFAIL，已知且预期）")
    _rec "$n" xfail; return 0
  fi
  FAIL=$((FAIL+1)); PROBLEMS+=("  ✗ $IMG $*"); _rec "$n" fail
}

# 发行版清单从 distros/*.conf 自动发现，避免与 Makefile / sbom.sh 三处各写一遍而漂移
[ -n "${DISTROS:-}" ] && DISTROS_OVERRIDDEN=1
# 档位也可限定：拆成「一个镜像一个 job」之后，每个 test job 只验一个档位。
# 注意这会让下面的「检查总数基线」失去意义——子集当然低于全量基线。
# 防线不能就此消失，而是上移：每个 job 用 RESULT_JSON 输出自己的检查数，
# 由汇总阶段把各 job 的总数相加后再对基线。
[ -n "${TIERS:-}" ] && DISTROS_OVERRIDDEN=1
DISTROS=${DISTROS:-$(ls "$ROOT"/distros/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//' | tr '\n' ' ')}

# IMAGE 撞名守卫：两份 conf 用同一个本地 tag 时，构建会互相覆盖，而本脚本会
# 拿各自的基线去量同一个镜像，表现是「期望 2.38 实际 2.31」这类看起来像构建
# 错了的失败。实际踩过一次（三个麒麟版本都写 IMAGE=kylin），22 条失败全部由此
# 而来，而每一条读起来都像真缺陷。
_seen=""; _dup=""
for _d in $DISTROS; do
  _i=$(. "$ROOT/distros/$_d.conf" >/dev/null 2>&1; printf '%s' "${IMAGE:-}")
  [ -n "$_i" ] || { echo "✗ distros/$_d.conf 没有 IMAGE" >&2; exit 2; }
  case " $_seen " in *" $_i "*) _dup="$_dup $_i";; esac
  _seen="$_seen $_i"
done
if [ -n "$_dup" ]; then
  echo "✗ 多个 distros/*.conf 共用同一个 IMAGE:$_dup" >&2
  echo "  本地 tag 必须按版本唯一，否则构建互相覆盖、基线交叉比对。" >&2
  exit 2
fi
for DID in $DISTROS; do
  # conf 里的变量会跨发行版泄漏（IMMUTABLE 泄漏会把 apt_check/compile_cxx 静默降级成跳过），
  # 每轮开头必须清掉
  # EXPECT_* 必须一起清：漏了它们，某个 conf 少写一项就会静默沿用上一个发行版的基线
  # （DISTROS 是字典序 kylin10→kylin11→uos25），而 check 对"期望空、实际空"判 PASS。
  unset IMMUTABLE PIN_NEVER REPACK_DEBS STUB_PROVIDES DPKG_SEGV_WRAPPER ADMINDIR \
        MICRO_INCLUDE BASE_INCLUDE DEVEL_INCLUDE STAGE_INCLUDE SLICE_MICRO \
        SLICE_BASE_EXTRA SLICE_DEVEL_EXTRA SOURCE_DATE_EPOCH MIRROR SUITE COMPONENTS \
        EXPECT_GLIBC EXPECT_LIBSTDCPP EXPECT_GLIBCXX IMAGE METHOD USRMERGE DISPLAY_NAME \
        EXPECT_CXX EXPECT_OS_REPO \
        SRC_ROOTFS ISO_URL ISO_SQUASHFS_PATH SQUASHFS_SHA256 DEBOOTSTRAP_SCRIPT \
        FAMILY EXPECT_SHADOW NO_CHECK_GPG RPM_DB_BACKEND MEDIA_DIR REPO_BASES RPM_KEY RPM_KEY_FP
  . "$ROOT/distros/$DID.conf"
  for TIER in ${TIERS:-micro base devel}; do
    IMG="$IMAGE:$TIER"
    docker image inspect "$IMG" >/dev/null 2>&1 || { echo "  ✗ $IMG 不存在"; FAIL=$((FAIL+1)); continue; }
    out=$(docker run --rm -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= \
            -v "$BK/test/inner-checks.sh:/checks.sh:ro" "$IMG" /bin/bash /checks.sh 2>/dev/null)
    g(){ printf '%s' "$out" | awk -F= -v k="$1" '$1==k{print $2; exit}'; }
    # 记下实测的 ABI 值，供发布阶段写进镜像 label——那样 docker inspect 就能筛 ABI，
    # 不必把镜像跑起来（跨架构时跑起来还要再装一次 QEMU）。
    _M_GLIBC=$(g glibc); _M_LIBSTDCPP=$(g libstdcpp); _M_GLIBCXX=$(g glibcxx)
    echo "── $IMG  ($(docker images "$IMG" --format '{{.Size}}'))  $(g os_name)  包=$(g pkgs)"

    # L0 结构（所有档都必须过）
    check os_release Y "$(g os_release)"
    check nsswitch   Y "$(g nsswitch)"
    # /etc/mtab 必须在**镜像里**就是符号链接（运行时那层会兜底，所以只能查 tarball）
    if [ -f "$ROOT/out/$DID-$TIER.tar" ]; then
      mt=$(tar tvf "$ROOT/out/$DID-$TIER.tar" 2>/dev/null | awk '$NF=="/proc/self/mounts" && /etc\/mtab/{print "Y"; exit}')
      check tar_mtab Y "${mt:-N}"
    fi
    check no_sshkey  Y "$(g no_sshkey)"
    check no_firmware Y "$(g no_firmware)"
    check no_kernel  Y "$(g no_kernel)"
    # 幽灵包：库里登记为已装、而文件被容器化改造删掉的内核/头文件包。
    # 单看 no_kernel（文件不在）与 pkgs（包数够多）都通过，矛盾只在交叉核对时显形。
    ghost=$(printf '%s' "$(g ghost_pkgs)" | tr ',' ' ' | tr -s ' ')
    [ -z "$(printf '%s' "$ghost" | tr -d ' ')" ] \
      && pass "ghost_pkgs（库里无已删文件的内核包）" \
      || fail "ghost_pkgs: 库里登记为已装、抽样文件全部缺失的包:$ghost（删文件的那一处应同时清库登记，见 lib/common.sh）"
    check copyright_kept Y "$(g copyright_kept)"
    # 逐包 copyright：厂商本来就没打的列入白名单；白名单外缺失即失败 —— 精简策略
    # 写错时只要还剩一个包有 copyright，旧的 copyright_kept 就永真，抓不住。
    # 白名单每一条都必须先核对原始 deb 里确实没有，否则等于把自己的 path-exclude
    # bug 写成「厂商没打」：
    #   · 麒麟 V11 的 libboundscheck / libcryptsetup12 / openssl
    #   · 凝思的 linx-archive-keyring —— `dpkg-deb -c` 实测该 deb 只有 5 个条目，
    #     唯一文件是 usr/share/keyrings/linx-archive-keyring.gpg，无 doc 目录。
    #   · 麒麟信安的 glib2 —— 厂商把 %license 打成指向 LICENSES/LGPL-2.1-or-later.txt
    #     的符号链接，而目标文件不在任何介质包里（逐个 rpm -qlp 扫过 400 个包，
    #     零命中）。这是厂商缺陷 D19，不是本项目精简策略造成的。
    cpmiss=$(printf '%s' "$(g copyright_missing)" | tr ',' '\n' | grep -v '^$' \
      | grep -vxE 'libboundscheck|libcryptsetup12|openssl|linx-archive-keyring|glib2' | tr '\n' ' ')
    [ -z "$cpmiss" ] && pass "copyright 逐包（白名单外无缺失）" \
      || fail "copyright 白名单外缺失: $cpmiss"
    # ld.so.cache 必须存在且非空。切片路径与 --noscripts 的 rpm bootstrap 都会漏它，
    # 而漏掉的表现是「某些二进制起不来」而非任何构建期报错。
    [ "$(g ldcache)" -gt 1000 ] 2>/dev/null \
      && pass "ldcache $(g ldcache) 字节" \
      || fail "ldcache: 期望 >1000 实际 $(g ldcache)（ldconfig 没跑？）"
    # 执行型判据：非默认库目录里的二进制真能跑。n/a 只在该档没有 systemctl 时成立。
    case "$(g systemctl_runs)" in
      Y|n/a) pass "systemctl_runs $(g systemctl_runs)" ;;
      *) fail "systemctl_runs: 期望 Y 或 n/a，实际 $(g systemctl_runs)（私有库路径没进 ld.so.cache？）" ;;
    esac
    check policy_rcd Y "$(g policy_rcd)"
    # L1 完整性
    check audit 0 "$(g audit)"
    # 坏 ELF 按**文件名**白名单，不按数量放宽：允许「1 个」会对任何新增的坏 ELF
    # 放过，允许「q_atm.so」只放过已论证的那一个。
    #   · q_atm.so —— iproute2 的 tc ATM 插件，厂商包本身不带 libatm（缺陷 D11）
    ebad=$(printf '%s' "$(g elf_broken_list)" | tr ',' '\n' | grep -v '^$' \
      | grep -vxE 'q_atm\.so' | tr '\n' ' ')
    [ -z "$ebad" ] && pass "elf_broken（白名单外无坏 ELF，计数 $(g elf_broken)）" \
      || fail "elf_broken 白名单外: $ebad"
    check getent_passwd Y "$(g getent_passwd)"
    check getent_group  Y "$(g getent_group)"
    check ldconfig_clean 0 "$(g ldconfig_clean)" warn
    check tz UTC "$(g tz)"
    # tzdata 的规范名随年代变：Debian 10 那一代 /usr/share/zoneinfo/UCT 是真文件、
    # Etc/UTC 是指向它的链接，`readlink -f` 因此解析到 UCT。同一时刻、不同命名，
    # 不是缺陷。判据接受两者。
    # UTC 在 IANA tz 库里有一整组 backward 兼容别名，它们的时区数据**字节完全相同**
    # （实测 UTC / Etc/UTC / Etc/Zulu 的 sha256 一致）。老发行版的 tzdata 常把
    # /etc/localtime 解到其中某个别名上：银河麒麟 V4 解到 Zulu，于是原先只认三个
    # 名字的判据把一个完全正确的时区判成了失败。
    # 这是尺子的校准问题而不是被试的缺陷——接入比原有被试更老的系统时，
    # 先问「量的是尺子还是被试」。
    case "$(g localtime)" in
      UTC|UCT|Zulu|Universal|Greenwich|Etc/UTC|Etc/UCT|Etc/Zulu|Etc/Universal|Etc/Greenwich)
        pass "localtime $(g localtime)" ;;
      *) fail "localtime: 期望 UTC 或其 IANA 别名，实际 $(g localtime)" ;;
    esac
    # machine-id 必须存在且为空（systemd 的 first-boot 语义）——report.md §7（验收） 列了却一直没接线
    check machine_id_empty Y "$(g machine_id_empty)"
    check dpkg_list_ok Y "$(g dpkg_list_ok)"
    # 哨兵：检查集必须跑到最后一行，否则前面所有"通过"都不可信
    check checks_complete Y "$(g checks_complete)"
    # 悬空软链：厂商自带/切片残留的几条是已知且惰性的，不删（删了就动了"等价环境"）；
    # 但清单之外的一律失败 —— 我自己就往 micro 档造过一条 default.target 悬空链，
    # 当时没有任何检查能发现它。
    unexpected=$(printf '%s' "$(g dangling_etc_list)" | tr ',' '\n' | grep -v '^$' \
      | grep -vxE '99-sysctl\.conf|modules\.conf|vconsole\.conf|99apt-download-hook' | tr '\n' ' ')
    [ -z "$unexpected" ] && pass "dangling_etc 仅已知项" \
      || fail "dangling_etc 出现清单外悬空软链: $unexpected"
    # 包数下限：status 断链时 dpkg-query 输出 0 行且退出码 0（历史假通过的机制本身）
    [ "$(g pkgs)" -ge 40 ] 2>/dev/null \
      && pass "pkgs $(g pkgs)" || fail "pkgs: 期望 >=40 实际 $(g pkgs)"
    # os-release 必须有 ID/VERSION_ID（不能是 ?/?）
    oid=$(g os_id)
    if [ "$oid" = "?/?" ] || [ -z "$oid" ]; then
      FAIL=$((FAIL+1)); PROBLEMS+=("  ✗ $IMG os_id 为空或异常: ${oid:-空}")
    else PASS=$((PASS+1)); fi
    # 非 root 用户可运行（很多生产环境强制 runAsNonRoot）
    nr=$(docker run --rm -u 65534:65534 "$IMG" /bin/sh -c 'id -u' 2>/dev/null)
    check nonroot_run 65534 "${nr:-失败}"
    # 基线对账。glibc 版本由镜像内检查集从包数据库问出来，而那一段是 dpkg 专用的，
    # rpm 系问不到（值为空）。inner-checks.sh 已按族分支，这里只需保证期望值存在。
    check glibc_prefix "$EXPECT_GLIBC" "$(printf '%s' "$(g glibc)" | grep -oE '^[0-9]+\.[0-9]+')"
    check libstdcpp "$EXPECT_LIBSTDCPP" "$(g libstdcpp)"
    check glibcxx   "$EXPECT_GLIBCXX"   "$(g glibcxx)"
    # L2 能力（按档位期望）
    # zh 语言包的粒度按族不同：deb 侧 locales 可精简到只留 zh_CN.UTF-8（1 个）；
    # rpm 侧 glibc-all-langpacks 是一个整包，装了就带 zh_CN 的四个变体
    # （zh_CN、zh_CN.utf8、zh_CN.gb18030、zh_CN.gbk），拆不开。所以期望值按族取：
    # 判据要守的是「zh_CN 可用」，不是「恰好一个变体」。
    if [ "${FAMILY:-deb}" = rpm ]; then
      [ "$(g locale_zh)" -ge 1 ] 2>/dev/null \
        && pass "locale_zh $(g locale_zh)（rpm 系整包提供多个变体）" \
        || fail "locale_zh: 期望 >=1 实际 $(g locale_zh)"
    else
      check locale_zh 1 "$(g locale_zh)"
    fi
    if [ "$(g ca_bytes)" -gt 100000 ]; then PASS=$((PASS+1))
    else FAIL=$((FAIL+1)); PROBLEMS+=("  ✗ $IMG ca_bytes: $(g ca_bytes) 过小"); fi
    # 期望按**包管理系**分支。rpm 系没有 apt，拿 apt 的判据去量会在 has_apt /
    # apt_check / apt_roundtrip 上一片失败 —— 量的是尺子不是被试（与能力探针同一个
    # 错，见 report §6.1）。deb 侧保留原有逻辑，它已针对 UOS 的 OSTree 分发调校过。
    if [ "${FAMILY:-deb}" = rpm ]; then
      case $TIER in
        micro) check has_pkgmgr N "$(g has_pkgmgr)" ;;
        base)  check has_pkgmgr Y "$(g has_pkgmgr)"; check has_python3 Y "$(g has_python3)"; check tls Y "$(g tls)"
               check has_source Y "$(g has_source)"
               check pkg_roundtrip Y "$(g pkg_roundtrip)"
               # rpm 侧的「装完仍自洽」对应 rpm -Va 的未满足依赖数（inner-checks 已按族分支）
               check audit_after 0 "$(g audit_after)" ;;
        devel) check has_pkgmgr Y "$(g has_pkgmgr)"
               check has_cc Y "$(g has_cc)"; check has_make Y "$(g has_make)"
               check compile_c Y "$(g compile_c)"
               check has_cxx Y "$(g has_cxx)"; check compile_cxx Y "$(g compile_cxx)" ;;
      esac
    else
    case $TIER in
      micro) check has_apt N "$(g has_apt)"; check apt_check n/a "$(g apt_check)" ;;
      base)  check has_apt Y "$(g has_apt)"; check has_python3 Y "$(g has_python3)"; check tls Y "$(g tls)"
             if [ "$(g has_source)" = N ]; then
               # 凝思：厂商未提供公开在线仓库，出厂 sources.list 留空（§4.5）。
               # 断言写成「无源」这个确定形态，而不是笼统放过 —— 哪天有源了，
               # has_source 变 Y，这条就会失败并提示复核期望。
               # 也不能把「无源时 apt-get update 成功」当成能更新：源清单为空时
               # 它必然成功（没东西要取），空集上的全称命题恒真。
               pass "has_source N（厂商无公开在线仓库，出厂源清单为空）"
               case "$(g apt_roundtrip)" in
                 N*) pass "apt_roundtrip 如期无源可装（$(g apt_roundtrip)）" ;;
                 *)  fail "apt_roundtrip: 无源时期望 N*，实际 $(g apt_roundtrip)" ;;
               esac
               check audit_after 0 "$(g audit_after)"
             elif [ "${EXPECT_OS_REPO:-yes}" = no ]; then
               # 按 conf 声明的期望判，不拿 IMMUTABLE 当代名词：「是不是不可变系统」
               # 与「有没有可用于装 OS 包的源」是两件事。统信 V20 不是不可变系统，
               # 但它出厂的有效源只有应用商店与打印驱动，同样装不上 OS 包。
               # UOS V25 的 OS 分发走 OSTree + 玲珑，apt 源里只有应用商店的 GUI 应用
               # （实测源只提供 2496 个包，不含 nano 这类 OS 包）。所以：
               #   · apt update 必须成功（两个需授权的 401 源已默认注释掉，见 lib/common.sh）
               #   · 但装 OS 包必然失败，往返结果是 N(...not-installed) —— 这是产品设计，不是缺陷
               # 断言写成"必须是这个失败形态"，而不是笼统放过：若哪天 update 又坏了，
               # 值会变成 NOUPDATE，这条就会失败。
               case "$(g apt_roundtrip)" in
                 NOUPDATE) fail "apt_roundtrip: apt-get update 失败了 — $(g apt_update_err)" ;;
                 # 任何 N* 都是预期形态：它表示「装没装上、包不在」，这正是无 OS 源时该有的
                 # 结果。不要去匹配括号里的文字——那是 dpkg 状态库的偶然写法：V25 上
                 # `dpkg -s nano` 返回带 not-installed 的状态串，V20 上根本没有这条记录，
                 # 值就成了 N(未装)。两者语义相同，按串匹配会把同一件事判成两回事。
                 N*) pass "apt_roundtrip 如期无 OS 包可装（源里只有应用商店条目）：$(g apt_roundtrip)" ;;
                 Y) pass "apt_roundtrip 竟然可装 OS 包（源内容变了，需复核期望）" ;;
                 *) fail "apt_roundtrip 形态未预期: $(g apt_roundtrip)" ;;
               esac
               check apt_check_after OK "$(g apt_check_after)"
               check audit_after 0 "$(g audit_after)"
             else
               check apt_check OK "$(g apt_check)"
               # NOUPDATE 单独报，把镜像内的真实报错带出来，否则只有一个结论没有线索
               if [ "$(g apt_roundtrip)" = NOUPDATE ]; then
                 fail "apt_roundtrip: apt-get update 失败了 — $(g apt_update_err)"
               elif [ "$(g apt_roundtrip)" = "N(未装)" ]; then
                 fail "apt_roundtrip: 装不上测试包 — $(g apt_install_err)"
               else
                 check apt_roundtrip Y "$(g apt_roundtrip)"
               fi
               # 往返之后 dpkg 状态必须仍然干净——这是"能装包"的真正含义
               check audit_after 0 "$(g audit_after)"
               check apt_check_after OK "$(g apt_check_after)"
             fi ;;
      devel) check has_apt Y "$(g has_apt)"
             { [ "${IMMUTABLE:-no}" = yes ] || [ "$(g has_source)" = N ]; } || check apt_check OK "$(g apt_check)"
             check has_cc Y "$(g has_cc)"; check has_make Y "$(g has_make)"
             check compile_c Y "$(g compile_c)"
             if [ "${EXPECT_CXX:-yes}" = no ]; then
               check has_cxx N "$(g has_cxx)" warn   # 装机清单里就没有 g++，已在 conf 注明
             else
               check has_cxx Y "$(g has_cxx)"; check compile_cxx Y "$(g compile_cxx)"
             fi ;;
    esac
    fi
    # L3 ABI gate：低地板产物必须能跑；高地板产物按 glibc 判定
    # 低地板门禁不是每个架构都有：manylinux2014 只有 x86_64 与 aarch64，
    # 而 LoongArch 最早的 glibc 就是 2.36，不存在「低于 2.17 的地板」这回事。
    # build-gates.sh 会把这个事实写进 .gate-status，这里读它——
    # 那个文件此前一直没人读，等于一个悬空机制。
    if grep -q GATE_LOW_NA "$BK/gate/.gate-status" 2>/dev/null; then
      skip gate_low "该架构没有低地板工具链（manylinux2014 无此架构，且其最早 glibc 已高于 2.17）"
    else
      r=$(docker run --rm -v "$BK/gate:/g:ro" "$IMG" /g/t_low 2>&1 | tail -1)
      check gate_low "ok 14" "$r"
    fi
    # 缺门禁二进制不能当作「这项不适用」而跳过——跳过时失败数仍是 0，
    # 汇总照样全绿，而这一整类 ABI 判定其实一次都没跑。
    if [ ! -f "$GATE_HIGH" ]; then
      FAIL=$((FAIL+1)); PROBLEMS+=("  ✗ $IMG gate_high 门禁二进制缺失（$GATE_HIGH），该项未被检验")
    else
      r2=$(docker run --rm -v "$BK/gate:/g:ro" "$IMG" /g/t_high 2>&1 | tail -1)
      major=$(printf '%s' "$EXPECT_GLIBC" | cut -d. -f2)
      if [ "$major" -ge 34 ]; then check gate_high "ok 14" "$r2"
      else
        # 负向断言不能只判"没输出 ok 14"：二进制不存在、exec 格式错、缺任意一个
        # 别的库，都会让它"如期失败"，于是这条断言变成永真。必须核对**失败原因**
        # 就是符号天花板本身。
        if [ "$r2" = "ok 14" ]; then
          FAIL=$((FAIL+1)); PROBLEMS+=("  ✗ $IMG gate_high 本应被 GLIBC_2.34 天花板拦住却通过了")
        elif printf '%s' "$r2" | grep -q "GLIBC_2.34. not found"; then
          PASS=$((PASS+1))
        else
          FAIL=$((FAIL+1)); PROBLEMS+=("  ✗ $IMG gate_high 失败了但原因不是 GLIBC_2.34 天花板: $r2")
        fi
      fi
    fi
    # L3b C++ ABI 高地板：t_high_cxx 需要较高的 GLIBCXX（用 std::to_chars 浮点重载）。
    # 原先只有 GLIBC 的高低地板，GLIBCXX 方向压根没有负向门禁 —— t_high 只需要
    # GLIBCXX_3.4.22，三个发行版都满足，等于没测。
    if [ ! -f "$BK/gate/t_high_cxx" ]; then
      FAIL=$((FAIL+1)); PROBLEMS+=("  ✗ $IMG gate_high_cxx 门禁二进制缺失，该项未被检验")
    elif [ "$(g compile_cxx)" = n/a ]; then
      : # 该档位无 C++ 编译能力，此项确实不适用（micro 档），不计失败
    else
      r3=$(docker run --rm -v "$BK/gate:/g:ro" "$IMG" /g/t_high_cxx 2>&1 | tail -1)
      cxxneed=$(objdump -T "$BK/gate/t_high_cxx" 2>/dev/null \
                | grep -oE 'GLIBCXX_[0-9.]+' | sort -V | tail -1 | sed 's/GLIBCXX_//')
      have=${EXPECT_GLIBCXX:-0}
      # 版本比较用 sort -V，别用字符串比较（3.4.9 vs 3.4.28）
      lower=$(printf '%s\n%s\n' "$cxxneed" "$have" | sort -V | head -1)
      if [ "$lower" = "$cxxneed" ]; then
        # 镜像的 GLIBCXX 够高 → 必须能跑
        case $r3 in cxxok*) pass "gate_high_cxx 可运行" ;;
          *) fail "gate_high_cxx: GLIBCXX $have 够用（需 $cxxneed）却跑不起来: $r3" ;; esac
      else
        # 镜像的 GLIBCXX 不够 → 必须被拦住，且原因就是 GLIBCXX 天花板
        # ⚠️ 局限：t_high_cxx 是 Debian 13 编的，GLIBC 和 GLIBCXX 两个地板都高，
        # 在麒麟 V10 上先撞哪一个取决于动态链接器的检查顺序（实测先报 GLIBC_2.34）。
        # 要把 C++ ABI 维度单独隔离出来，需要"低 glibc + 高 libstdc++"的工具链，
        # 本机没有。所以这里接受任一天花板作为拦截原因，但仍然拒绝"原因不明的失败"。
        case $r3 in
          cxxok*) fail "gate_high_cxx 本应被符号天花板拦住却通过了（镜像 GLIBCXX $have < 需要 $cxxneed）" ;;
          *GLIBCXX*|*GLIBC_2.34*) pass "gate_high_cxx 如期被符号天花板拦住" ;;
          *) fail "gate_high_cxx 失败了但原因不是符号天花板: $r3" ;;
        esac
      fi
    fi
    # L4 元数据
    lbl=$(docker inspect "$IMG" --format '{{index .Config.Labels "cn.internal.tier"}}' 2>/dev/null)
    check label_tier "$TIER" "$lbl"
    ss=$(docker inspect "$IMG" --format '{{.Config.StopSignal}}' 2>/dev/null)
    # 条件按"有没有 systemd"判，而不是按档位名：kylin10:micro 带 systemd 却因为
    # 档位叫 micro 而从这条缝里漏掉过。
    if [ "$(g has_systemd)" = Y ]; then
      check stopsignal "SIGRTMIN+3" "${ss:-空}"
      # 桌面 ISO 默认 graphical.target，会去拉 display-manager
      check default_target multi-user.target "$(g default_target)"
      # 至少 mask 掉 udev/内核挂载那批，0 说明改造没生效
      [ "$(g masked_units)" -ge 5 ] 2>/dev/null \
        && pass "masked_units $(g masked_units)" \
        || fail "masked_units: 期望 >=5 实际 $(g masked_units)"
    fi
    # 影子文件的属主与权限**按发行版取**，不能统一写死：Debian 系是 0640 root:shadow，
    # RH 系是 000 root:root（更严），凝思自带的 shadow 套件产出 0660（多一个组写位）。
    # 写死一个值会把发行版惯例差异报成缺陷，而真正该守的是「与该发行版的基线一致」。
    # 值与理由都记在 distros/*.conf 的 EXPECT_SHADOW。
    check shadow  "${EXPECT_SHADOW:?distros/$DID.conf 缺 EXPECT_SHADOW}" "$(g shadow)"
    check gshadow "${EXPECT_SHADOW}" "$(g gshadow)"
  done
done
echo
echo "══ 汇总: 通过 $PASS / 失败 $FAIL / 警告 $WARN / 期望失败 $XFAIL_HITS / 意外通过 $XPASS_HITS"
[ ${#XNOTES[@]} -gt 0 ] && printf '%s\n' "${XNOTES[@]}"
[ ${#PROBLEMS[@]} -gt 0 ] && printf '%s\n' "${PROBLEMS[@]}"

# ── 检查数量基线 ────────────────────────────────────────────────────────────────
# 「失败 0」还不够：检查项被**静默跳过**时汇总同样是全绿。本项目已经踩过好几种
# 跳过方式 —— conf 变量跨发行版泄漏把 apt_check/compile_cxx 降级成 n/a、
# g() 取不到值、helper 函数名拼错导致两条分支都是"命令未找到"。
# 所以数量本身必须是断言：只允许涨，掉下来就是有检查消失了。
# 基线随被试数一起抬：3 被试时是 360，5 被试实测 637，基线设 620 留 17 的余量吸收
# 「某档没有 systemctl 因而少两项」这类合法波动。留旧基线不动等于让它失去鉴别力 ——
# 360 对 5 个被试来说，整掉一个发行版（约 127 项）都还在线上。
BASELINE=${BASELINE:-620}
# xfail 也算跑过的检查：不计进总数会让「加豁免」等于「让基线下降」，
# 于是豁免越多、静默跳过越难被基线抓住。
TOTAL_RUN=$((PASS+FAIL+WARN+XFAIL_HITS))
# 只在**全量**跑时校基线：显式指定 DISTROS 是子集调试，撞基线没有意义
if [ -n "${DISTROS_OVERRIDDEN:-}" ]; then
  echo "   检查总数 $TOTAL_RUN（子集运行，跳过基线校验）"
elif [ "$TOTAL_RUN" -lt "$BASELINE" ]; then
  echo "❌ 检查总数 $TOTAL_RUN 低于基线 $BASELINE —— 有检查被静默跳过了"
  echo "   （若确为有意缩减，请同步调整 test/verify.sh 里的 BASELINE 并在 commit 里说明）"
  exit 1
else
  echo "   检查总数 $TOTAL_RUN（基线 $BASELINE）"
fi

# 机器可读结果，供汇总阶段合并成报告。problems 逐条转义成 JSON 字符串。
if [ -n "${RESULT_JSON:-}" ]; then
  mkdir -p "$(dirname "$RESULT_JSON")"
  {
    printf '{"distro":"%s","arch":"%s","tiers":"%s","pass":%d,"fail":%d,"warn":%d,"xfail":%d,"xpass":%d,"total":%d,"problems":[' \
      "$DISTROS" "${ARCH:-unknown}" "${TIERS:-micro base devel}" "$PASS" "$FAIL" "$WARN" "$XFAIL_HITS" "$XPASS_HITS" "$TOTAL_RUN"
    _first=1
    for _p in "${PROBLEMS[@]:-}"; do
      [ -n "$_p" ] || continue
      [ "$_first" = 1 ] || printf ','
      _first=0
      printf '%s' "$_p" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()),end="")'
    done
    printf '],"measured":{"glibc":"%s","libstdcpp":"%s","glibcxx":"%s","arch":"%s","tier":"%s"},"checks":[' \
      "$_M_GLIBC" "$_M_LIBSTDCPP" "$_M_GLIBCXX" "${ARCH:-unknown}" "${TIERS:-}"
    _first=1
    for _c in "${CHECKS[@]:-}"; do
      [ -n "$_c" ] || continue
      [ "$_first" = 1 ] || printf ','
      _first=0
      printf '%s' "$_c" | python3 -c 'import sys,json
img,name,st=sys.stdin.read().strip().split("|",2)
print(json.dumps({"image":img,"name":name,"state":st},ensure_ascii=False),end="")'
    done
    printf '],"xnotes":['
    _first=1
    for _p in "${XNOTES[@]:-}"; do
      [ -n "$_p" ] || continue
      [ "$_first" = 1 ] || printf ','
      _first=0
      printf '%s' "$_p" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()),end="")'
    done
    printf ']}\n'
  } > "$RESULT_JSON"
  echo "   结果已写入 $RESULT_JSON"
fi

[ "$FAIL" -eq 0 ] && echo "✅ 全部必过项通过" || echo "❌ 有 $FAIL 项未过"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
