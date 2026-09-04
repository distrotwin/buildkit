#!/bin/bash
# 粗查 shell 脚本里「引用早于定义」的局部变量。
#
# 为什么需要它：set -u 下引用未定义变量会当场退出，而 `bash -n` 只做语法检查、
# 查不出这一类——未定义变量在语法上完全合法。本轮接旧世界时我因此栽了三次：
# DST_PRECHECK、TIER 各一次，都是把新代码插在了变量定义之前，CI 跑几分钟才炸。
#
# 判据很粗（按函数体内的行序比对 local 声明与 $VAR 引用），会有假阳性；
# 但它抓的是「插入位置算错一行」这个具体错误，而那是实测反复发生的。
set -eu
python3 - "$@" <<'PY'
import re, sys
bad=[]
for path in sys.argv[1:]:
    lines=open(path, encoding='utf-8', errors='replace').read().split('\n')
    i=0
    while i < len(lines):
        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{', lines[i]):
            # 收集函数体
            body=[]; j=i+1
            while j < len(lines) and not re.match(r'^\}', lines[j]):
                body.append((j+1, lines[j])); j+=1
            # 本函数用 local 声明的名字及其行号
            decl={}
            for ln, l in body:
                m=re.match(r'^\s*local\s+(.*)$', l)
                if m:
                    for tok in re.split(r'\s+', m.group(1).strip()):
                        name=tok.split('=')[0].lstrip('-')
                        if re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', name) and name not in decl:
                            decl[name]=ln
            # 找引用早于声明的
            for ln, l in body:
                if l.strip().startswith('#'): continue
                for m in re.finditer(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)', l):
                    v=m.group(1)
                    if v in decl and ln < decl[v]:
                        bad.append((path, ln, v, decl[v], l.strip()[:70]))
            i=j
        i+=1
if bad:
    print("✗ 引用早于 local 声明：")
    for p,ln,v,dl,t in bad:
        print("    %s:%d 用了 $%s，而它在第 %d 行才声明 — %s" % (p,ln,v,dl,t))
    sys.exit(1)
print("✓ 未发现引用早于声明")
PY
