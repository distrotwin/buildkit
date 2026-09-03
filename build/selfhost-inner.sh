#!/bin/bash
# 在麒麟 V10 的 stage 容器内执行：自举 configure -> 装档位包 -> 容器化适配 -> 自检
export DEBIAN_FRONTEND=noninteractive
set -u
say(){ printf '    %s\n' "$*"; }

mkdir -p /run/lock /var/lib/dpkg/updates
# ① 真正的自举：用**目标系统自己的 dpkg 1.19.7** 跑 debootstrap 第二阶段
#    （宿主 Debian13 的 dpkg 1.22 写出的 status 麒麟读不了，所以注册+配置必须在这里做）
if [ -x /debootstrap/debootstrap ]; then
  /debootstrap/debootstrap --second-stage 2>&1 | tail -3
  say "第二阶段 rc=$?"
fi
dpkg --configure -a --force-depends >/dev/null 2>&1
say "自举结果: installed=$(grep -c '^Status: install ok installed' /var/lib/dpkg/status 2>/dev/null) unpacked=$(grep -c '^Status: install ok unpacked' /var/lib/dpkg/status 2>/dev/null) dpkg=$(dpkg --version 2>/dev/null|head -1|grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"

# ①b debootstrap 第二阶段只装 required 集；--include 下来的 base 集（apt 等）
#     还躺在 /var/cache/apt/archives。用这些**已通过 GPG 校验**的 deb 补装。
if ! command -v apt-get >/dev/null 2>&1; then
  # PIN_NEVER 必须在这条路径上也生效。它原先只写进 apt 的 preferences，而这里是
  # `dpkg -i .../*.deb` 一律装上 —— 同一条策略在 apt 路径被遵守、在 dpkg 回落路径
  # 被静默忽略。凝思因此带进了 linx-noroot-conf，状态停在 half-configured，
  # `dpkg --audit` 多一条。策略只覆盖部分代码路径，是本仓库反复出的形态。
  DEBS=""
  for f in /var/cache/apt/archives/*.deb; do
    [ -e "$f" ] || continue
    skip=no
    for p in ${PIN_NEVER:-}; do
      case "$(basename "$f")" in "${p}_"*) skip=yes ;; esac
    done
    [ "$skip" = yes ] && { say "  跳过被 PIN_NEVER 排除的 $(basename "$f")"; continue; }
    DEBS="$DEBS $f"
  done
  n=$(printf '%s\n' $DEBS | sed '/^$/d' | wc -l)
  say "apt 不在，从 stage 缓存补装 $n 个 deb"
  dpkg -i --force-depends --force-confold $DEBS >/dev/null 2>&1 || true
  dpkg --configure -a --force-depends >/dev/null 2>&1 || true
  # 只报告，不移除。被 pin 的包如果仍在库里，说明它是从 debootstrap 的 base 集
  # 进来的 —— 那要靠 build-selfhost.sh 的 `debootstrap --exclude` 在入口拦。
  # 这里**不能** `dpkg --purge --force-depends`：实测会把依赖图弄坏
  # （apt 依赖状态不健康），比原症状「dpkg --audit 多一条」更重。
  # 修复动作造成的破坏大于原症状时，正确选择是退回报告、把修复挪到正确的入口。
  for p in ${PIN_NEVER:-}; do
    st=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)
    case "$st" in
      *installed*|*unpacked*|*half*)
        say "  ⚠ $p 仍在库里（$st）—— 应由 debootstrap --exclude 在入口拦住" ;;
    esac
  done
  say "补装后: installed=$(grep -c '^Status: install ok installed' /var/lib/dpkg/status) apt=$(command -v apt-get||echo 仍无)"
fi

# ② base-files 在 --foreign 解包后常处于损坏态，重装修好
mkdir -p /etc/apt/preferences.d /usr/share/keyrings
# ⚠️ 只在真正验签的路径上拷 keyring。原先无条件拷麒麟那把，于是凝思三档
# （NO_CHECK_GPG=yes、出厂无源）各留下一把**跨厂商且无消费方**的 key ——
# 正是 §3.1「多一把没用的 key 就是多一份可被滥用的授权」要杜绝的情形，
# 出现在最新加入的被试上。审稿复核抓到，verify.py 的 keyring 断言当时就在报失败，
# 而我把它混在一批「断言过时」里没有逐条读 —— 失败清单太长会淹没真问题。
if [ "${NO_CHECK_GPG:-no}" != yes ]; then
  # 必须先建目录：/usr/share/keyrings 是 Debian 10 / Ubuntu 18.04 之后才有的，
  # 银河麒麟 V4 那种 16.04 血脉的最小 rootfs 里没有它。
  # 也不能再用 `|| true` 吞掉失败——原先那句在 V4 上必然失败并被静默忽略，
  # 随后 sources.list 的 signed-by 指向不存在的文件，表现是出厂镜像里
  # apt-get update 失败（记为 apt_roundtrip=NOUPDATE）。症状离真因隔了三步，
  # 而中间那一步一声不吭。V10 SP1 是 20.04 血脉、V11 更新，两者自带该目录，
  # 所以只有 V4 触发。
  mkdir -p /usr/share/keyrings
  cp /keys/kylin-archive-keyring.gpg /usr/share/keyrings/ \
    || { say "致命: keyring 拷贝失败，出厂镜像的 signed-by 会指向不存在的文件"; exit 1; }
  [ -s /usr/share/keyrings/kylin-archive-keyring.gpg ] \
    || { say "致命: keyring 落位后为空"; exit 1; }
else
  say "介质无签名（NO_CHECK_GPG=yes），不注入任何 keyring"
fi
# 在线源要验签；介质本地源没有签名（完整性锚点是 ISO 的官方校验值），
# 所以按 NO_CHECK_GPG 决定用 signed-by 还是 trusted=yes。
if [ "${NO_CHECK_GPG:-no}" = yes ]; then
  APT_OPT="trusted=yes"
else
  APT_OPT="signed-by=/usr/share/keyrings/kylin-archive-keyring.gpg"
fi
printf 'deb [%s] %s %s %s\n' "$APT_OPT" "$MIRROR" "$SUITE" "$COMPONENTS" > /etc/apt/sources.list
# 更新源：基础 suite 是冻结的发布树，厂商把后续构建放在独立的 -updates suite 里
# （麒麟 V10 SP1 的 10.1-2403-updates / 10.1-2203-updates 就写在官方 sources.list 文档里）。
# 不配它们镜像会停在发布时的包版本——实测 ca-certificates 停在 2021 年、比安装介质旧三年，
# 构建时拉 https 会因缺新根证书而失败，而客户真机不会。这类是「假失败」，方向比落后更糟。
for _es in ${EXTRA_SUITES:-}; do
  printf 'deb [%s] %s %s %s\n' "$APT_OPT" "$MIRROR" "$_es" "$COMPONENTS" >> /etc/apt/sources.list
done
printf 'APT::Key::gpgvcommand "gpgv";\n' > /etc/apt/apt.conf.d/docker-gpgv
if [ -n "${PIN_NEVER:-}" ]; then
  { for p in $PIN_NEVER; do printf 'Package: %s\nPin: release *\nPin-Priority: -1\n\n' "$p"; done; } \
    > /etc/apt/preferences.d/99-container-never-install
fi
apt-get update -qq 2>&1 | tail -1
apt-get install -y -qq --reinstall base-files >/dev/null 2>&1 || true
dpkg --configure -a >/dev/null 2>&1 || true

# 配了更新源就先把 debootstrap 阶段装的基础包升上去。档位包由下面逐包安装时
# 自然取到最新版，但 libc6 / base-files / dpkg 来自阶段一，不升就停在发布树版本。
if [ -n "${EXTRA_SUITES:-}" ]; then
  # 容器里没有 systemd PID 1，postinst 里直调 systemctl 的包必然配置失败：
  #   System has not been booted with systemd as init system (PID 1). Can't operate.
  # 麒麟 V10 SP1 的 kyseclog-daemon 就是这样。档位包装不出这个问题——它们都不带
  # systemd unit，只有全量升级才会碰到这类包。
  #
  # 两手都要，因为拦的是两条不同的路径：policy-rc.d 按 Debian 约定返回 101，只挡
  # invoke-rc.d 与 deb-systemd-invoke；直调 systemctl 绕过它，得靠改道。
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d
  # systemctl 不存在也要挡：postinst 调不到它会以"命令找不到"失败，症状不同、
  # 后果一样。所以两种情况都铺一个临时的 /bin/true。
  _sctl=$(command -v systemctl 2>/dev/null || true)
  _div=""; _stub=""
  if [ -n "$_sctl" ]; then
    dpkg-divert --local --rename --add "$_sctl" >/dev/null 2>&1 && _div=$_sctl
    ln -sf /bin/true "$_sctl"
  else
    _stub=/usr/bin/systemctl
    ln -sf /bin/true "$_stub"
  fi

  _before=$(dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | sha256sum | cut -c1-12)
  # 退出码不能被管道丢掉（同下面第 ③ 步的理由）。conffile 一律留旧的：厂商包里
  # 有交互式 conffile，不指定就会挂在提示上直到 job 超时。
  set +e
  apt-get upgrade -y --no-install-recommends \
    -o Dpkg::Use-Pty=false -o Dpkg::Options::=--force-confold \
    > /tmp/upgrade.log 2>&1
  _rc=$?
  set -e
  grep -iE '^E:|segmentation|dpkg: error' /tmp/upgrade.log | head -5 || true
  _after=$(dpkg-query -W -f='${Package} ${Version}\n' 2>/dev/null | sha256sum | cut -c1-12)

  # 改道必须撤干净再往下走，否则出厂镜像会带一个指向 /bin/true 的 systemctl，
  # 而那种缺陷在镜像里毫无症状——用户直到要管服务时才发现。判据挂在结果上：
  # 撤完之后 systemctl 必须是真文件，且 divert 表里不能再有它。
  rm -f /usr/sbin/policy-rc.d
  [ -z "$_stub" ] || rm -f "$_stub"
  if [ -n "$_div" ]; then
    rm -f "$_div"
    dpkg-divert --local --rename --remove "$_div" >/dev/null 2>&1 || true
    # 判据不写成"必须是真文件"——有的系统里 systemctl 本身就是软链，那样会误杀。
    # 真正要拦的是"它还指着 /bin/true"，以及 divert 表里还留着我们那条。
    [ -e "$_div" ] || { say "  ✗ systemctl 改道没撤回：$_div 不存在了"; exit 1; }
    if [ "$(readlink -f "$_div")" = "$(readlink -f /bin/true)" ]; then
      say "  ✗ systemctl 仍指向 /bin/true，改道没撤回"; exit 1
    fi
    if dpkg-divert --list 2>/dev/null | grep -q -- "$_div"; then
      say "  ✗ divert 表里仍有 $_div"; exit 1
    fi
  fi

  # 两种都要拦死。配了更新源却一个包没动，说明源没生效——那镜像会静默地
  # 继续发陈旧的 ca-certificates，而这正是加这个配置要修的东西。
  if [ "$_rc" != 0 ]; then
    say "  ✗ apt-get upgrade 失败（rc=$_rc），尾部日志："
    tail -30 /tmp/upgrade.log | sed 's/^/      /'
    exit 1
  fi
  if [ "$_before" = "$_after" ]; then
    say "  ✗ 配了 EXTRA_SUITES=${EXTRA_SUITES} 却没有任何包版本变化，更新源没有生效"
    say "    当前 sources.list："; sed 's/^/      /' /etc/apt/sources.list
    exit 1
  fi
  say "  基础包已按更新源升级（${EXTRA_SUITES}）"
  dpkg-query -W -f='${Package} ${Version}\n' | grep -E '^(libc6|ca-certificates|openssl|base-files|tzdata) ' | sed 's/^/      /' || true
fi

# ③ 装档位包（逐包，规避大事务里的厂商 dpkg 缺陷）
# 注意：apt-get 的退出码不能被管道丢掉，且 `apt-get check` **只验已装包之间的依赖一致性**，
# 对"某个包压根没装上"一无所知。所以装完必须逐包断言 Status 为 install ok installed。
MISSING=""
if [ -n "${PKGS:-}" ]; then
  for p in $PKGS; do
    # -o Dpkg::Use-Pty=false：容器里没挂 devpts，apt 开伪终端写日志会失败并返回 100，
    # 而包其实已经装上。一次构建刷三十多行假警报，真警报就会被一起忽略。
    out=$(apt-get install -y -qq --no-install-recommends -o Dpkg::Use-Pty=false "$p" 2>&1); rc=$?
    printf '%s' "$out" | grep -iE '^E:|segmentation' | head -1
    [ "$rc" -ne 0 ] && say "  ⚠ apt install $p 退出码 $rc"
    dpkg --configure -a >/dev/null 2>&1 || true
  done
  for p in $PKGS; do
    st=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)
    [ "$st" = "install ok installed" ] || MISSING="$MISSING $p"
  done
fi

# ④ micro 档拔掉 apt
if [ "$TIER" = micro ]; then
  for p in apt apt-utils; do
    if dpkg-query -W "$p" >/dev/null 2>&1; then
      rm -f /var/lib/dpkg/info/$p.pre* /var/lib/dpkg/info/$p.post*
      dpkg --purge --force-all "$p" >/dev/null 2>&1 || true
    fi
  done
fi

# ⑤ 证书 + locale
command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates >/dev/null 2>&1
if [ -d /usr/share/i18n/locales ] && command -v localedef >/dev/null 2>&1; then
  localedef -i zh_CN -c -f UTF-8 zh_CN.UTF-8 2>/dev/null || true
  localedef -i en_US -c -f UTF-8 en_US.UTF-8 2>/dev/null || true
fi

# ⑥ 容器化适配 —— 直接复用 lib/common.sh 的 adapt_container，不再手写复刻。
#    之前这里是一份手抄版，注释写着"与 adapt_container 保持一致"却没有任何机制保障，
#    结果 kylin10 静默缺了 apt 调优、/tmp 权限、nsswitch 兜底、SONAME 冗余文件修复等一整批。
if [ -f /dosbuild-lib/common.sh ]; then
  # 仓库是挂载进来的，路径与构建容器不同，所以显式指定 ASSETS_DIR / KEYRING
  ASSETS_DIR=/dosbuild-assets
  KEYRING=/keys/kylin-archive-keyring.gpg
  . /dosbuild-lib/common.sh
  # micro 档没有 apt，出厂时不该留在线源配置。上面第 29-30 行那份是**构建期必需**的
  # （阶段 3 要用 apt 装档位包），这里是出厂前的适配，要按档位清掉。
  # ⚠️ keyring 文件不删：麒麟 V10 的 /usr/share/keyrings/kylin-archive-keyring.gpg
  # 属厂商 kylin-keyring 包（我们的 cp 只是覆盖了同内容的同一路径），删它会破坏
  # dpkg 的文件清单，也越过了「等价环境」的底线 —— 判据是属主，不是路径。
  # MIRROR 是**构建期**的源。四个被试里它恰好也是可出厂的在线源，凝思不是——
  # 它的 MIRROR 是 file:///w/media/lx，即 builder 的挂载路径。照抄进出厂镜像的
  # 结果是运行时那个路径不存在，apt update 必失败，而报错只说取不到源。
  # 所以只有网络源才写进出厂 sources.list；本地介质出厂时写空，与 UOS 同样处理。
  case "$MIRROR" in
    http://*|https://*|ftp://*) SHIPPABLE=yes ;;
    *) SHIPPABLE=no ;;
  esac
  if [ "$TIER" = micro ] || [ "$SHIPPABLE" = no ]; then
    SRCLIST=""
    [ "$SHIPPABLE" = no ] && [ "$TIER" != micro ] && \
      say "出厂 sources.list 留空：构建期源 $MIRROR 是本地介质，非网络源"
  else
    SRCLIST="deb [$APT_OPT] $MIRROR $SUITE $COMPONENTS"
    for _es in ${EXTRA_SUITES:-}; do
      SRCLIST="$SRCLIST
deb [$APT_OPT] $MIRROR $_es $COMPONENTS"
    done
  fi
  adapt_container / "$SRCLIST" "${DID:-}"
  slim_locales /
  say "容器化适配: 复用 lib/common.sh::adapt_container"
else
  say "!! 找不到 /dosbuild-lib/common.sh，无法做容器化适配"; exit 1
fi

# ⑦ 自检
hash -r 2>/dev/null || true
AC=n/a
if [ -x /usr/bin/apt-get ]; then /usr/bin/apt-get check >/dev/null 2>&1 && AC=OK || AC=BAD; fi
say "自检: apt-check=$AC audit=$(dpkg --audit 2>&1|wc -l) locale=$(locale -a 2>/dev/null|grep -c zh_CN) ca=$(stat -c%s /etc/ssl/certs/ca-certificates.crt 2>/dev/null||echo 0)"
if [ "$AC" = BAD ]; then say '!! apt 依赖状态不健康'; apt-get check 2>&1 | head -12 | sed 's/^/      /'; exit 1; fi
if [ -n "${MISSING# }" ]; then say "!! 以下档位包没装上:$MISSING"; exit 1; fi
exit 0
