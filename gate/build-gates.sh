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
#     g++ -O2 -static-libstdc++ -static-libgcc -o /w/t_low /w/t.cpp
set -eu
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}   # 默认取仓库根
BUILDER_IMG=${BUILDER_IMG:-dosbuild-cache:latest}
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
