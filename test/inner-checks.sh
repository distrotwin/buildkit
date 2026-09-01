#!/bin/bash
# 在被测镜像内运行的检查集。输出 key=value 行，由外层汇总。
export LC_ALL=C
A=""; [ -f /usr/lib/dpkg/var/status ] && A="--admindir=/usr/lib/dpkg/var"
# 包管理系由镜像自己判定。这一整套检查原先是 dpkg 专用的，rpm 系被试会在包数、
# 许可证路径、CA 路径、glibc 版本上一片失败 —— 量的是尺子不是被试（见 §6.1）。
if command -v rpm >/dev/null 2>&1 && ! command -v dpkg >/dev/null 2>&1; then PKGSYS=rpm
elif command -v dpkg >/dev/null 2>&1; then PKGSYS=deb
else PKGSYS=none; fi
kv pkgsys "$PKGSYS"
kv(){ printf '%s=%s\n' "$1" "$2"; }
# 被破坏的镜像上 apt/dpkg 会挂死（实测：status 断链时 apt-get 永久等待），
# 检查集若跟着卡住，外层就只能拿到截断的输出 —— 而缺失的 key 会被读成"空值"
# 而不是失败。所以凡是碰 dpkg/apt 的地方一律套超时。
T(){ local t=$1; shift; if command -v timeout >/dev/null 2>&1; then timeout -k 5 "$t" "$@"; else "$@"; fi; }
has(){ [ -x "/usr/bin/$1" ] || [ -x "/bin/$1" ] || [ -x "/usr/sbin/$1" ] || [ -x "/sbin/$1" ]; }

# ── L0 结构
kv os_release "$( [ -f /etc/os-release ] && echo Y || echo N )"
kv os_name    "$(. /etc/os-release 2>/dev/null; echo "${NAME:-?}")"
kv nsswitch   "$( [ -f /etc/nsswitch.conf ] && echo Y || echo N )"
# 注意：/etc/mtab 由容器运行时（runc）自动建成 -> /proc/mounts，镜像里有没有都一样，
# 所以在**运行时**查它永远为真、毫无意义。真正的检查在 verify.sh 里对 tarball 做（见 tar_mtab）。
kv mtab_link_runtime "$( [ -L /etc/mtab ] && echo Y || echo N )"
kv machine_id_empty "$( [ -f /etc/machine-id ] && [ ! -s /etc/machine-id ] && echo Y || echo N )"
kv no_sshkey  "$( ls /etc/ssh/ssh_host_* >/dev/null 2>&1 && echo N || echo Y )"
kv no_firmware "$( [ -d /lib/firmware ] || [ -d /usr/lib/firmware ] && echo N || echo Y )"
kv no_kernel  "$( ls /boot/vmlinuz* >/dev/null 2>&1 && echo N || echo Y )"
# 交叉核对：包数据库声称已装的包，其文件必须真的在。no_kernel 只验「文件不在」，
# pkgs 只验「包数够多」，两者各自自洽，矛盾只在交叉核对时显形 ——
# lib/common.sh 删掉 /boot 却不动包登记时，库里会留下一个 256 MB 的幽灵内核包，
# SBOM 报告一个不存在的包、trivy 凭空产出 373 条 HIGH+CRITICAL（缺陷 D18）。
#
# 实现要点（前两版都错过）：
#   · 不按包名猜。第一版 grep '^kernel(-|$)' 把 kernel-headers（1026 文件一个不缺、
#     glibc-devel 正当依赖）判成幽灵 —— 用代理指标替代要测的东西。
#   · 只数**非目录**条目。清单里目录不带尾斜杠（/usr、/usr/bin），永远存在，
#     于是「抽样全部缺失」永不成立，判据成永真。
#   · 子进程数必须是 O(1)。逐包调 dpkg-query -L 会把脚本拖到超时，外层只拿到截断
#     输出、缺失 key 被读成空值 —— 实测因此凭空报出 103 项失败。
#     所以先用一次全局查询圈出「文件落在被清空目录下」的候选包，再只查这几个。
if [ "$PKGSYS" = deb ]; then
  _cand=$(grep -l -E '^/(boot|lib/modules|usr/lib/modules|lib/firmware)/' \
            /var/lib/dpkg/info/*.list /usr/lib/dpkg/var/info/*.list 2>/dev/null \
          | sed 's|.*/||; s|\.list$||' | sort -u)
  _plist() { dpkg-query $A -L "$1" 2>/dev/null; }
else
  _cand=$(rpm -qla 2>/dev/null | awk '
      /^[^\/]/ {next}
      /^\/(boot|lib\/modules|usr\/lib\/modules|lib\/firmware)\//{print}' >/dev/null 2>&1; \
    rpm -qa --qf '%{NAME}\n' 2>/dev/null | while read -r n; do
      rpm -ql "$n" 2>/dev/null | grep -qE '^/(boot|lib/modules|usr/lib/modules|lib/firmware)/' && echo "$n"
    done | sort -u)
  _plist() { rpm -ql "$1" 2>/dev/null; }
fi
ghost=""
for _pk in $_cand; do
  _n=0; _miss=0
  for _f in $(_plist "$_pk" | grep -vE '^/\.$|/$|contains no files' | head -40); do
    [ -d "$_f" ] && continue
    _n=$((_n+1)); [ -e "$_f" ] || _miss=$((_miss+1))
  done
  [ "$_n" -gt 0 ] && [ "$_miss" = "$_n" ] && ghost="$ghost$_pk,"
done
kv ghost_pkgs "$ghost"
# /etc/ld.so.cache 不属于任何包（ldconfig 触发器的产物），切片与 --noscripts 的
# rpm bootstrap 都会漏。最坏后果是非默认库目录里的二进制全部起不来。
kv ldcache "$(stat -c%s /etc/ld.so.cache 2>/dev/null || echo 0)"
# 执行型判据：光看文件在不在不够。这一项被 elf_broken 那句「已知误报」掩盖过一次。
if command -v systemctl >/dev/null 2>&1; then
  kv systemctl_runs "$(systemctl --version >/dev/null 2>&1 && echo Y || echo N)"
else kv systemctl_runs n/a; fi
if [ "$PKGSYS" = rpm ]; then
  kv copyright_kept "$( ls -d /usr/share/licenses/*/ >/dev/null 2>&1 && echo Y || echo N )"
else
  kv copyright_kept "$( ls /usr/share/doc/*/copyright >/dev/null 2>&1 && echo Y || echo N )"
fi
# 逐包查 copyright。原先只判"存在任意一个"，等于几乎永真：
# 精简策略（path-exclude /usr/share/doc + path-include copyright）一旦写错，
# 只要还剩一个包有 copyright 就能过。
if [ "$PKGSYS" = rpm ]; then
  # ⚠️ 判据按族分化。Debian policy **强制**每个包带 /usr/share/doc/<pkg>/copyright；
  # RH 没有这条强制，只有实际携带许可证文本的包才装 %license —— 实测麒麟信安
  # devel 档 132/194 个包有许可证目录，audit-libs 之类的 rpm 清单里本来就没有
  # license 条目（`rpm -q --licensefiles audit-libs` 为空）。
  # 所以 rpm 侧问的是「**声明了** %license 的包，那些文件是否真的在」——
  # 把 Debian 的强制性要求套过来会把打包惯例差异报成精简策略缺陷。
  kv copyright_missing "$(for p in $(rpm -qa --qf '%{NAME}\n' 2>/dev/null | LC_ALL=C sort -u); do
      # rpm 对无文件的包返回字面串 "(contains no files)"，必须过滤 ——
      # 不过滤会把它拆成三个"文件名"，于是 basesystem 被误报为缺许可证。
      _lf=$(rpm -q --licensefiles "$p" 2>/dev/null | grep '^/' | head -3)
      [ -z "$_lf" ] && continue
      for _l in $_lf; do [ -e "$_l" ] || { printf '%s,' "$p"; break; }; done
    done)"
else
  kv copyright_missing "$(for p in $(dpkg-query $A -f '${Package}\n' -W 2>/dev/null | LC_ALL=C sort -u); do
      [ -e "/usr/share/doc/$p/copyright" ] || printf '%s,' "$p"; done)"
fi
kv policy_rcd "$( [ -x /usr/sbin/policy-rc.d ] && echo Y || echo N )"

# ── L1 完整性
if [ "$PKGSYS" = rpm ]; then kv pkgs "$(rpm -qa 2>/dev/null | wc -l)"
else kv pkgs "$(dpkg-query $A -f '${binary:Package}\n' -W 2>/dev/null | wc -l)"; fi
# deb 侧是 dpkg --audit（半配置包）；rpm 侧对应依赖自洽反查。两边都以 0 为干净。
if [ "$PKGSYS" = rpm ]; then
  kv audit "$(T 120 rpm -Va --nofiles --nodigest --noscripts 2>&1 | grep -c 'Unsatisfied dependencies')"
else kv audit "$(T 30 dpkg --audit 2>&1 | wc -l)"; fi
if [ -x /usr/bin/apt-get ]; then
  /usr/bin/apt-get check >/dev/null 2>&1 && kv apt_check OK || kv apt_check BAD
else kv apt_check n/a; fi
# ELF 依赖闭环（抽样 200 个可执行文件，避免过慢）
# ⚠️ `xargs sh -c 'script' _` 里 $0 是占位的 `_`，**文件名在 $1**。
#    之前写成 ldd "$0" 等于一直在 ldd 那个下划线，这条检查恒为 0（9 个镜像白送 9 项）。
#    抽样上限也从 200 提到 1200 并按名排序，让抽样确定且覆盖更广。
broken_out=$(find /usr/bin /usr/sbin /bin /sbin /usr/lib -maxdepth 4 -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null \
  | LC_ALL=C sort | head -1200 \
  | xargs -r -n1 -P4 sh -c '
      # 私有库目录（如 /usr/lib/x86_64-linux-gnu/systemd/）不在 ld.so.conf 里，
      # 由调用方二进制的 RUNPATH 覆盖。单独 ldd 这类 .so 会报 not found，是已知误报，
      # 所以把文件自身所在目录也加进搜索路径再判。
      LD_LIBRARY_PATH="$(dirname "$1")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        ldd "$1" 2>/dev/null | grep -q "not found" && basename "$1"' _ 2>/dev/null)
broken_files="$broken_out"
broken=$(printf '%s\n' "$broken_out" | grep -c '^..*$')
kv elf_broken "$broken"
# 同时给出**是哪些文件**。只报数量时白名单只能锚在数量上（「允许 1 个」），
# 那对任何新增的坏 ELF 都会放过；锚在身份上才只放过已论证的那一个。
# 复用上面 find 的同一组文件，不再重扫一遍。
kv elf_broken_list "$(printf '%s\n' "${broken_files:-}" | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ',')"
kv getent_passwd "$(getent passwd root >/dev/null 2>&1 && echo Y || echo N)"
kv getent_group  "$(getent group root  >/dev/null 2>&1 && echo Y || echo N)"

# ── L2 能力
if [ "$PKGSYS" = rpm ]; then kv glibc "$(rpm -q --qf '%{VERSION}-%{RELEASE}' glibc 2>/dev/null)"
else kv glibc "$(dpkg-query $A -W -f='${Version}' libc6 2>/dev/null)"; fi
# libstdc++ 的位置按族不同：Debian 系在多架构目录，RH 系在 /usr/lib64/。
# 写死一边会让另一边的 ABI 基线对账拿到空值，而 check 对「期望空、实际空」判 PASS。
lib=""
# 三元组随架构变（x86_64-/aarch64-/loongarch64-linux-gnu…），枚举必漏，改用通配。
# 保持「Debian 系多架构目录优先、RH 系 lib64 兜底」的原有顺序。
for c in /usr/lib/*-linux-gnu*/libstdc++.so.6 /lib/*-linux-gnu*/libstdc++.so.6 \
         /usr/lib64/libstdc++.so.6 /lib64/libstdc++.so.6; do
  [ -e "$c" ] && { lib="$c"; break; }
done
so=$([ -n "$lib" ] && readlink "$lib" 2>/dev/null)
kv libstdcpp "${so#libstdc++.so.}"
kv glibcxx "$(grep -aoE 'GLIBCXX_3\.4\.[0-9]+' "$lib" 2>/dev/null | sort -uV | tail -1 | sed 's/GLIBCXX_//')"
kv locale_zh "$(locale -a 2>/dev/null | grep -c '^zh_CN')"
# CA bundle 路径按族不同；RH 系那条是指向 ca-trust extracted 的符号链接。
if [ "$PKGSYS" = rpm ]; then kv ca_bytes "$(stat -Lc%s /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null || echo 0)"
else kv ca_bytes "$(stat -c%s /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 0)"; fi
kv has_apt   "$(has apt-get && echo Y || echo N)"
if command -v apt-get >/dev/null 2>&1; then PKGMGR=apt-get
elif command -v dnf >/dev/null 2>&1; then PKGMGR=dnf
elif command -v yum >/dev/null 2>&1; then PKGMGR=yum
else PKGMGR=""; fi
kv has_pkgmgr "$( [ -n "$PKGMGR" ] && echo Y || echo N)"
# has_source 决定「装不上」该怎么读：无源时是渠道缺位（凝思，厂商未提供公开仓库），
# 有源时才是源里没有那个包（UOS）。
if [ "$PKGSYS" = rpm ]; then
  kv has_source "$( ls /etc/yum.repos.d/*.repo >/dev/null 2>&1 && echo Y || echo N)"
else
  hs=no
  { [ -s /etc/apt/sources.list ] && grep -qE '^[[:space:]]*deb[[:space:]]' /etc/apt/sources.list; } && hs=yes
  ls /etc/apt/sources.list.d/*.list >/dev/null 2>&1 && hs=yes
  ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1 && hs=yes
  kv has_source "$( [ "$hs" = yes ] && echo Y || echo N)"
fi
if [ "$PKGSYS" = rpm ] && [ -n "$PKGMGR" ] && ls /etc/yum.repos.d/*.repo >/dev/null 2>&1; then
  if T 180 $PKGMGR -y -q install nano >/dev/null 2>&1 && rpm -q nano >/dev/null 2>&1; then
    T 120 $PKGMGR -y -q remove nano >/dev/null 2>&1
    command -v nano >/dev/null 2>&1 && kv pkg_roundtrip PARTIAL || kv pkg_roundtrip Y
  else kv pkg_roundtrip N; fi
elif [ "$PKGSYS" = rpm ]; then kv pkg_roundtrip nosrc
else kv pkg_roundtrip n/a; fi
# 悬空软链：镜像里指向不存在目标的软链。我自己就造过一条（micro 档的
# default.target 指向不存在的 multi-user.target），当时没有任何检查能发现。
kv dangling_etc_list "$(find /etc -maxdepth 3 -type l ! -lname /dev/null 2>/dev/null \
  | while read -r l; do [ -e "$l" ] || basename "$l"; done | LC_ALL=C sort -u | tr '\n' ',')"
kv has_systemd "$(has systemctl && echo Y || echo N)"
# 桌面 ISO 出身的 default.target 是 graphical.target，server 镜像必须是 multi-user
kv default_target "$(readlink /etc/systemd/system/default.target 2>/dev/null | sed 's|.*/||')"
kv masked_units "$(find /etc/systemd/system -maxdepth 1 -lname /dev/null 2>/dev/null | wc -l)"
# setuid 的 su/newgrp 没有影子文件就是白送的攻击面
kv shadow "$([ -f /etc/shadow ] && stat -c '%u:%g/%a' /etc/shadow 2>/dev/null || echo 缺)"
kv gshadow "$([ -f /etc/gshadow ] && stat -c '%u:%g/%a' /etc/gshadow 2>/dev/null || echo 缺)"
kv has_python3 "$(has python3 && echo Y || echo N)"
kv has_cc    "$(has cc || has gcc && echo Y || echo N)"
kv has_cxx   "$(has g++ && echo Y || echo N)"
kv has_make  "$(has make && echo Y || echo N)"
kv has_useradd "$(has useradd && echo Y || echo N)"
kv ldconfig_clean "$(ldconfig 2>&1 | wc -l)"

# 编译自检（devel 档）
if has cc || has gcc; then
  printf '#include <stdio.h>\nint main(){puts("cok");return 0;}\n' > /tmp/_c.c
  cc -O2 -o /tmp/_c /tmp/_c.c 2>/dev/null || gcc -O2 -o /tmp/_c /tmp/_c.c 2>/dev/null
  kv compile_c "$( [ -x /tmp/_c ] && [ "$(/tmp/_c 2>/dev/null)" = cok ] && echo Y || echo N )"
else kv compile_c n/a; fi
if has g++; then
  printf '#include <string>\n#include <cstdio>\n#include <thread>\nint main(){std::string s="xok";std::thread t([]{});t.join();printf("%%s\\n",s.c_str());return 0;}\n' > /tmp/_x.cpp
  g++ -O2 -std=c++17 -pthread -o /tmp/_x /tmp/_x.cpp 2>/dev/null
  kv compile_cxx "$( [ -x /tmp/_x ] && [ "$(/tmp/_x 2>/dev/null)" = xok ] && echo Y || echo N )"
else kv compile_cxx n/a; fi

# apt 往返（有 apt 的档）
# ⚠️ 必须用**带 maintainer script** 的包。之前用 tree（控制包里只有 control+md5sums）
#    恰好避开了唯一会失败的类别：厂商 dpkg 在 configure 阶段也会 segv，
#    而无脚本的包 configure 是空操作，所以 tree 永远能过。
if [ -x /usr/bin/apt-get ]; then
  # 三次重试。这条检查要回答的是「这个镜像能不能装包」，而不是「此刻网络好不好」。
  # 源对境外出口偶发卡死（返回 200、Content-Length 正确、body 零字节），单次 60 秒
  # 足以被打穿：实测同一版本同一架构的 devel 通过而 base 报 NOUPDATE，两者的
  # sources.list 完全一样——那是网络抖动，不是镜像缺陷。
  _upd=no; _uerr=""
  for _i in 1 2 3; do
    if T 60 /usr/bin/apt-get update -qq >/dev/null 2>/tmp/.aptupd.err; then _upd=yes; break; fi
    # 留下失败原因。原先这里是 2>&1 >/dev/null，于是 NOUPDATE 只是一个结论、
    # 没有任何线索：连不上、验签不过、缺 gpgv、源不完整，长得一模一样。
    # 两轮 CI 里 v4 的 base 档各失败一次而 devel 都通过，靠猜排不出来。
    _uerr=$(tr '\n' ' ' < /tmp/.aptupd.err 2>/dev/null | tail -c 300)
    sleep 5
  done
  [ "$_upd" = yes ] || kv apt_update_err "${_uerr:-无输出}"
  if [ "$_upd" = yes ]; then
    DEBIAN_FRONTEND=noninteractive T 90 /usr/bin/apt-get install -y -qq --no-install-recommends nano >/dev/null 2>&1
    st=$(dpkg-query $A -W -f='${Status}' nano 2>/dev/null)
    if [ "$st" = "install ok installed" ]; then
      DEBIAN_FRONTEND=noninteractive T 60 /usr/bin/apt-get purge -y -qq nano >/dev/null 2>&1
      if has nano; then kv apt_roundtrip PARTIAL; else kv apt_roundtrip Y; fi
    else
      kv apt_roundtrip "N(${st:-未装})"
    fi
  else kv apt_roundtrip NOUPDATE; fi
else kv apt_roundtrip n/a; fi
# 往返**之后**再采一次状态：之前 audit 在往返前采样，往返后的损坏从未被审计。
# ⚠️ 必须按族分支。audit 改了而 audit_after 漏了 —— 同一个判据的两个采样点只改了
# 一个。rpm 镜像里没有 dpkg，`dpkg --audit` 输出一行 command not found，
# 被 wc -l 数成「1 条未满足依赖」，伪装成一条真缺陷。若它恰好输出 0 行，
# 这一项又会静默通过。所以判据要先确认命令存在，再谈它的输出。
if [ "$PKGSYS" = rpm ]; then
  kv audit_after "$(T 120 rpm -Va --nofiles --nodigest --noscripts 2>&1 | grep -c 'Unsatisfied dependencies')"
elif command -v dpkg >/dev/null 2>&1; then
  kv audit_after "$(T 30 dpkg --audit 2>&1 | wc -l)"
else
  kv audit_after n/a
fi
if [ -x /usr/bin/apt-get ]; then
  T 30 /usr/bin/apt-get check >/dev/null 2>&1 && kv apt_check_after OK || kv apt_check_after BAD
else kv apt_check_after n/a; fi

# 时区必须是 UTC（容器约定；官方 official-images 的通用测试也查这一项）
# ⚠️ `date -u +%Z` 强制 UTC，与 /etc/localtime 无关，恒为 UTC（又是 9 项白送）。
#    要查镜像自身的时区就得用不带 -u 的 date，或直接看 /etc/localtime 指向。
kv tz "$(date +%Z 2>/dev/null)"
kv localtime "$(readlink -f /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')"
# os-release 的 ID / VERSION_ID 必须有值（扫描器与运维靠它识别系统）
kv os_id "$(. /etc/os-release 2>/dev/null; echo "${ID:-?}/${VERSION_ID:-?}")"
# dpkg 抽查：随便挑一个已装包，能列出文件才说明 info 库是完整的
#   （专防"status 是断链 -> audit 输出 0 行 -> 被当成通过"这类静默失效）
# 不用 awk：被测镜像本身可能没装（micro 档就没有），测试工具不该引入额外依赖
_p=$(dpkg-query $A -W 2>/dev/null | head -1 | cut -f1)
# 「包的文件清单可查」两族都有，问法不同：deb 是 dpkg-query -L，rpm 是 rpm -ql。
# 这一项在从 HEAD 重打改动时漏了族分支，于是 rpm 三档全报 N —— 又一次「尺子是
# deb 本位」。重打多处改动时，要逐项对照失败清单确认没有漏。
if [ "$PKGSYS" = rpm ]; then
  _p=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | head -1)
  kv dpkg_list_ok "$( [ -n "$_p" ] && [ "$(rpm -ql "$_p" 2>/dev/null | wc -l)" -gt 0 ] && echo Y || echo N )"
else
  kv dpkg_list_ok "$( [ -n "$_p" ] && [ "$(dpkg-query $A -L "$_p" 2>/dev/null | wc -l)" -gt 0 ] && echo Y || echo N )"
fi

# TLS（有 curl 的档）
if has curl; then
  curl -fsSI --max-time 15 https://mirrors.aliyun.com >/dev/null 2>&1 && kv tls Y || kv tls N
else kv tls n/a; fi

# ── 完成哨兵 ────────────────────────────────────────────────────────────────
# 必须是最后一行。verify 硬断言它为 Y，这样"检查集中途挂掉/被杀"就一定是失败，
# 而不是「那几个 key 恰好为空所以没人管」。这类静默截断本项目已经踩过一次。
kv checks_complete Y
