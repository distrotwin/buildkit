#!/bin/bash
# 取 distros/<did>.conf 里某个键的值：conf-get.sh <did> <VAR> [VAR...]
#
# 为什么要这个：conf 里有按 $ARCH 分支的基线覆写，直接 source 它就必须先有 ARCH，
# 否则 set -u 下报「conf: line N: ARCH: unbound variable」。这个报错离真因很远，
# 尤其当调用它的步骤名字碰巧指向另一个可疑方向时（实际踩过：一个名为「探源可达性」
# 的步骤因为漏传 ARCH 而失败，差一步就据此断定软件源不可达并去改架构）。
#
# 把取值收拢到一处，调用方就不必逐个记得传哪些变量。
BK="${BK:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
set -eu
ROOT="${ROOT:-$PWD}"
. "$BK/lib/arch.sh"                      # 先把 ARCH / MULTIARCH / EXPECT_LOADER 备好
DID=${1:?用法: conf-get.sh <did> <VAR>...}; shift
[ -f "$ROOT/distros/$DID.conf" ] || { echo "!! 没有 $ROOT/distros/$DID.conf" >&2; exit 2; }
. "$ROOT/distros/$DID.conf"
for v in "$@"; do
  # 未定义的键输出空行而不是报错：调用方常用它判断「有没有配这一项」
  printf '%s\n' "$(eval "printf '%s' \"\${$v:-}\"")"
done
