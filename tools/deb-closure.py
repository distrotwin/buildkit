#!/usr/bin/env python3
"""算 deb 侧的依赖闭包：给一批种子，算出「介质里必须留下哪些 .deb」。

为什么需要它：rpm 侧已有 rpmrepo-fetch.py 算闭包，deb 侧一直是直接连源
（mmdebstrap／debootstrap 自己解依赖），没有切片需求。一旦要把介质塞进
数据镜像，就得先回答「4.3 GB 里哪些是必须的」——那就要自己算一次。

判据落在 Packages 索引上，不落在「跑一次构建看它下了什么」上：后者受
时序与缓存影响，不同两次可能不同；闭包是确定性的。
"""
import gzip, os, re, sys


def vercmp(a, b):
    """deb 版本比较（Debian Policy 5.6.12 的实现，不是字符串比较）。
    字符串比较在 2.31-13+deb11u3 vs 2.31-9 这类值上会答反 —— 合并多个
    suite 挑赢家时这直接决定选哪个包，错不起。"""
    def split_epoch(v):
        if ':' in v:
            e, r = v.split(':', 1)
            return int(e), r
        return 0, v

    def order(c):
        if c == '~':
            return -1
        if c.isdigit():
            return 0
        if c.isalpha():
            return ord(c)
        return ord(c) + 256

    def cmp_part(x, y):
        while x or y:
            # 非数字段
            while (x and not x[0].isdigit()) or (y and not y[0].isdigit()):
                cx = order(x[0]) if x and not x[0].isdigit() else 0
                cy = order(y[0]) if y and not y[0].isdigit() else 0
                if cx != cy:
                    return cx - cy
                if x and not x[0].isdigit():
                    x = x[1:]
                if y and not y[0].isdigit():
                    y = y[1:]
            # 数字段
            nx = ny = ''
            while x and x[0].isdigit():
                nx += x[0]; x = x[1:]
            while y and y[0].isdigit():
                ny += y[0]; y = y[1:]
            d = int(nx or 0) - int(ny or 0)
            if d:
                return d
        return 0

    ea, ra = split_epoch(a)
    eb, rb = split_epoch(b)
    if ea != eb:
        return ea - eb
    if '-' in ra:
        ua, xa = ra.rsplit('-', 1)
    else:
        ua, xa = ra, ''
    if '-' in rb:
        ub, xb = rb.rsplit('-', 1)
    else:
        ub, xb = rb, ''
    return cmp_part(ua, ub) or cmp_part(xa, xb)

def parse(path):
    op = gzip.open if path.endswith('.gz') else open
    txt = op(path, 'rt', errors='replace').read()
    out = []
    for blk in txt.split('\n\n'):
        if not blk.strip():
            continue
        d = {}
        key = None
        for line in blk.split('\n'):
            if line[:1] in (' ', '\t'):
                continue                      # 续行（长描述）一律丢，闭包用不到
            m = re.match(r'^([A-Za-z0-9-]+):\s*(.*)$', line)
            if m:
                key = m.group(1)
                d[key] = m.group(2)
        if 'Package' in d:
            out.append(d)
    return out

def dep_names(field):
    """把 Depends 拆成「每个 or 组的候选名列表」。
    or 依赖不能只取第一个候选就算完 —— 介质里可能只带了第二个候选。
    所以返回全部候选，由调用方挑一个真的在介质里的。"""
    groups = []
    for grp in field.split(','):
        alts = []
        for alt in grp.split('|'):
            n = alt.strip().split()[0] if alt.strip() else ''
            n = n.split(':')[0]               # 去掉 :any 这类架构限定
            if n:
                alts.append(n)
        if alts:
            groups.append(alts)
    return groups

def main():
    media, seedstr = sys.argv[1], sys.argv[2]
    outfile = sys.argv[3] if len(sys.argv) > 3 else '/tmp/deb.closure' 
    pkgs = {}
    provides = {}
    for root, _, files in os.walk(os.path.join(media, 'dists')):
        for f in files:
            if f == 'Packages' or f == 'Packages.gz':
                if 'debian-installer' in root:
                    continue                  # udeb 不进 rootfs
                for d in parse(os.path.join(root, f)):
                    n = d['Package']
                    # 同名多版本取版本串最大的（介质里罕见，但不能默认唯一）
                    if n not in pkgs or vercmp(d.get('Version','0'), pkgs[n].get('Version','0')) > 0:
                        pkgs[n] = d
    for n, d in pkgs.items():
        provides.setdefault(n, n)
        for p in d.get('Provides','').split(','):
            p = p.strip().split()[0].split(':')[0] if p.strip() else ''
            if p:
                provides.setdefault(p, n)     # 虚拟包 → 真实提供者

    # 自动种子按构建器选：mmdebstrap variant=essential 装的是 Essential:yes
    # 集合，debootstrap 阶段一装的才是 Priority:required。默认种 Essential ——
    # required 是过度近似，而且厂商会乱标：方德把 425 MB 的 360 浏览器标成
    # Priority:required，按 required 播种就把它整个背进闭包。
    # debootstrap 类流程（selfhost）传 --with-required 显式打开。
    auto = [n for n, d in pkgs.items() if d.get('Essential') == 'yes']
    kind = 'Essential:yes'
    if '--with-required' in sys.argv:
        auto = sorted(set(auto) | {n for n, d in pkgs.items() if d.get('Priority') == 'required'})
        kind = 'Essential:yes ∪ Priority:required'
    req = auto
    seeds = [s.strip() for s in seedstr.split(",") if s.strip()]
    print("  索引 %d 个包（自动种子 %d 个：%s）" % (len(pkgs), len(req), kind))

    keep, missing, queue = set(), set(), list(dict.fromkeys(req + seeds))
    for s in queue:
        if s not in provides:
            missing.add(s)
    while queue:
        cur = queue.pop()
        real = provides.get(cur)
        if real is None or real in keep:
            continue
        keep.add(real)
        d = pkgs[real]
        for field in ('Pre-Depends', 'Depends'):
            if field not in d:
                continue
            for alts in dep_names(d[field]):
                # 挑第一个介质里真有的候选；都没有才记缺失
                hit = next((a for a in alts if a in provides), None)
                if hit is None:
                    missing.add(alts[0])
                elif provides[hit] not in keep:
                    queue.append(hit)

    total = sum(int(pkgs[n].get('Size', 0)) for n in keep)
    print("  闭包 %d 个包，合计 %.1f MB" % (len(keep), total / 1048576))
    if missing:
        print("  介质里缺 %d 个（多为虚拟/可选）: %s" %
              (len(missing), ', '.join(sorted(missing)[:8])))
    with open(outfile, 'w') as f:
        for n in sorted(keep):
            f.write("%s\t%s\n" % (n, pkgs[n].get('Filename', '')))
    print("  清单已写 %s" % outfile)

main()
