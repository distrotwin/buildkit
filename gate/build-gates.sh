#!/bin/bash
# 门禁二进制的构建记录。
#
# 这些二进制原先是手工编出来直接提交的，仓库里没有任何构建记录 —— 等于审计链上
# 有一段空白。本脚本负责补上：谁编的、用什么地板、需要哪些符号版本。
#
#   t_high      Debian 13 / GCC 14 默认编译       → 需要 GLIBC_2.34（高地板）
#   t_high_cxx  同上，用 std::to_chars 浮点重载   → 需要较高的 GLIBCXX（高 C++ 地板）
#   t_low       manylinux2014（CentOS 7, GLIBC 2.17）→ GLIBC_2.14 / GLIBCXX_3.4.11（低地板）
#
# t_low 需要 manylinux2014 镜像，本机离线环境下拉不到，所以**不在本脚本里重建**，
# 仅记录其来源与实测符号天花板（见 report.md §3.1（信任根））。要重建请在有外网的机器上执行：
#   docker run --rm -v $PWD:/w quay.io/pypa/manylinux2014_x86_64 \
#     g++ -O2 -pthread -static-libstdc++ -static-libgcc -o /w/t_low /w/t.cpp
#
# -pthread 是必须的：t.cpp 用了 std::thread，而 glibc 直到 2.34 才把 pthread_create
# 并入 libc。manylinux2014 是 glibc 2.17，不给 -pthread 就是一串
# undefined reference to `pthread_create`。Debian 13 上反而不需要，
# 所以 t_high 编得过、t_low 编不过——这条注释原先给的命令从未被验证过。
set -eu
BK=${BK:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}
ROOT=$BK   # 门禁二进制属于 buildkit 自身，落在 $BK/gate/
# 本地有 builder 镜像就用它，没有就回退到 debian:13。
# builder 镜像本身就是 debian:13 加一批构建工具，而编门禁二进制只需要 g++，
# 两者产出的 t_high 特征相同（GCC 14 / 需要 GLIBC_2.34）。
# 测试阶段是干净机器、没有 builder 镜像，不该为了编两个小程序去重建整个 builder。
BUILDER_IMG=${BUILDER_IMG:-dosbuild-cache:latest}
if ! docker image inspect "$BUILDER_IMG" >/dev/null 2>&1; then
  echo "本机无 $BUILDER_IMG，回退到 debian:13 编门禁二进制"
  BUILDER_IMG=debian:13
fi
C="gatebuild-$$"
trap 'docker rm -f "$C" >/dev/null 2>&1 || true' EXIT

docker run -d --name "$C" -e http_proxy= -e https_proxy= "$BUILDER_IMG" sleep 600 >/dev/null
docker exec "$C" bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends g++ >/dev/null'

docker exec -i "$C" bash -c 'cat > /t.cpp' < "$ROOT/gate/t.cpp"   # -i 必须有，否则 stdin 不接、源文件是空的
docker exec "$C" bash -c 'g++ -O2 -o /t_high /t.cpp'

docker exec "$C" bash -c 'cat > /cxx.cpp <<CPP
// std::to_chars 的浮点重载在 GCC 11 才落地，对应较高的 GLIBCXX 版本 ——
// 这正是我们需要的「高 C++ 地板」：麒麟 V10（GLIBCXX_3.4.28）应当跑不了，
// 麒麟 V11 / UOS V25 应当能跑。具体需要哪个版本以 objdump 实测为准，不靠猜。
#include <charconv>
#include <cstdio>
#include <array>
int main(){
  std::array<char,32> b{};
  auto r = std::to_chars(b.data(), b.data()+b.size(), 3.14159, std::chars_format::fixed, 3);
  std::printf("cxxok %.*s\n", (int)(r.ptr-b.data()), b.data());
  return 0;
}
CPP
g++ -O2 -o /t_high_cxx /cxx.cpp'

for f in t_high t_high_cxx; do
  docker exec "$C" cat "/$f" > "$ROOT/gate/$f"
  chmod +x "$ROOT/gate/$f"
  printf '%-12s GLIBC<=%s  GLIBCXX<=%s\n' "$f" \
    "$(objdump -T "$ROOT/gate/$f" | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1)" \
    "$(objdump -T "$ROOT/gate/$f" | grep -oE 'GLIBCXX_[0-9.]+' | sort -V | tail -1)"
done

# ── t_low：低地板产物。必须能在所有被试上跑起来，因此要用尽可能老的 glibc 编译。
# manylinux2014 是 CentOS 7 / glibc 2.17，静态链接 libstdc++ 与 libgcc 之后，
# 产物的动态符号需求降到 GLIBC_2.14 附近。
#
# 只有 x86_64 与 aarch64 有 manylinux2014 镜像。LoongArch 的最早 glibc 就是 2.36，
# 不存在「低地板」可言，此时跳过并明确说明——但**不能静默跳过**，
# 调用方据此决定是把该架构的 gate_low 判为不适用，还是判为缺失。
case "${ARCH:-$(dpkg --print-architecture)}" in
  amd64) ML=quay.io/pypa/manylinux2014_x86_64 ;;
  arm64) ML=quay.io/pypa/manylinux2014_aarch64 ;;
  *)     ML="" ;;
esac
if [ -z "$ML" ]; then
  echo "t_low       跳过：架构 ${ARCH:-?} 没有 manylinux2014 镜像，不存在低于 2.17 的地板"
  echo "GATE_LOW_NA=1" > "$BK/gate/.gate-status"
else
  docker run --rm -v "$BK/gate:/g" -e http_proxy= -e https_proxy= "$ML" \
    g++ -O2 -pthread -static-libstdc++ -static-libgcc -o /g/t_low /g/t.cpp
  chmod +x "$BK/gate/t_low"
  printf '%-12s GLIBC<=%s  GLIBCXX<=%s\n' t_low \
    "$(objdump -T "$BK/gate/t_low" | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1)" \
    "$(objdump -T "$BK/gate/t_low" | grep -oE 'GLIBCXX_[0-9.]+' | sort -V | tail -1)"
  echo "GATE_LOW_OK=1" > "$BK/gate/.gate-status"
fi
