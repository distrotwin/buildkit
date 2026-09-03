#!/bin/bash
# 架构参数化：dpkg 架构名 -> multiarch 三元组
#
# 为什么需要这一层：构建脚本里凡是碰 /usr/lib/<三元组>/ 的地方，都不能写死 x86_64-linux-gnu。
# 而三元组无法从 dpkg 架构名机械推导（arm64 -> aarch64、armhf 带 gnueabihf 后缀），只能查表。
#
# LoongArch 有两套互不兼容的 ABI，麒麟两个版本各用一套：
#   loongarch64  旧世界，动态链接器 /lib64/ld.so.1                        （V10 SP1）
#   loong64      新世界，动态链接器 /lib64/ld-linux-loongarch-lp64d.so.1  （V11）
# 两者的 multiarch 三元组同名，但产物不可互换；上游 QEMU 只保证新世界。

ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"

arch_to_multiarch() {
  case "$1" in
    amd64)              echo x86_64-linux-gnu ;;
    arm64)              echo aarch64-linux-gnu ;;
    armhf)              echo arm-linux-gnueabihf ;;
    i386)               echo i386-linux-gnu ;;
    loong64|loongarch64) echo loongarch64-linux-gnu ;;
    mips64el)           echo mips64el-linux-gnuabi64 ;;
    *) return 1 ;;
  esac
}

# 期望的动态链接器路径，用于镜像内校验：拿它核对产物确实是目标 ABI，
# 而不是宿主架构的二进制被误打进去。loong 两个世界靠这一项区分。
arch_to_loader() {
  case "$1" in
    amd64)        echo /lib64/ld-linux-x86-64.so.2 ;;
    arm64)        echo /lib/ld-linux-aarch64.so.1 ;;
    armhf)        echo /lib/ld-linux-armhf.so.3 ;;
    i386)         echo /lib/ld-linux.so.2 ;;
    loong64)      echo /lib64/ld-linux-loongarch-lp64d.so.1 ;;
    loongarch64)  echo /lib64/ld.so.1 ;;
    mips64el)     echo /lib64/ld.so.1 ;;
    *) return 1 ;;
  esac
}

# rpm 系的架构名。注意一个陷阱：deb 世界用名字区分 LoongArch 的两个世界
# （loongarch64=旧、loong64=新），而**rpm 世界两个世界都叫 loongarch64**，
# 名字不携带世代信息。所以世代判定必须落在 EXPECT_LOADER 上而不是架构名上
# —— 麒麟信安 V6 的 loong 是新世界（实测其 glibc 的解释器为
# /lib64/ld-linux-loongarch-lp64d.so.1、符号版本 GLIBCXX 对应 GLIBC_2.36），
# 因此在本套体系里写作 ARCH=loong64，而它的 rpm 架构名是 loongarch64。
arch_to_rpm() {
  case "$1" in
    amd64)               echo x86_64 ;;
    arm64)               echo aarch64 ;;
    loong64|loongarch64) echo loongarch64 ;;
    i386)                echo i686 ;;
    armhf)               echo armv7hl ;;
    mips64el)            echo mips64el ;;
    *) return 1 ;;
  esac
}

MULTIARCH="${MULTIARCH:-$(arch_to_multiarch "$ARCH")}" || {
  printf '致命: 未知架构 %s，请先在 lib/arch.sh 的映射表里登记\n' "$ARCH" >&2; exit 1; }
EXPECT_LOADER="${EXPECT_LOADER:-$(arch_to_loader "$ARCH" || echo '')}"
RPMARCH="${RPMARCH:-$(arch_to_rpm "$ARCH" || echo '')}"
export ARCH MULTIARCH EXPECT_LOADER RPMARCH
