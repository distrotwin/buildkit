#!/usr/bin/env python3
"""切片后补回 update-alternatives 建的符号链接。

这些链接（如 /usr/bin/awk -> /etc/alternatives/awk -> /usr/bin/mawk）由包的 postinst
调 update-alternatives 创建，**不属于任何包的文件清单**，所以按包闭包切片一定会漏。
做法：扫源 rootfs 里指向 /etc/alternatives 的符号链接，只要最终目标在切片产物里存在，
就把两级链接都补上。目标不存在的（属于没切进来的包）跳过。

用法: restore-alternatives.py <src-rootfs> <dst-rootfs>
"""
import os, sys

src, dst = sys.argv[1], sys.argv[2]
BINDIRS = ('usr/bin', 'usr/sbin', 'bin', 'sbin', 'usr/games')
restored = skipped = fallback = 0

def pick_available(altname, dst):
    """从 dpkg 的 alternatives 记录里挑一个在 dst 中真实存在的候选。

    记录格式（dpkg 1.20+）：
        <status>            auto|manual
        <link>              /usr/bin/awk
        [<slave name>
         <slave link>]*
        ''                  空行分隔
        (<候选路径>
         <优先级>
         [<slave 路径>]*)*   多组，空行结束
    这里只需要候选路径，按优先级从高到低挑第一个存在的。
    """
    # admindir 归位（build.sh 里把 UOS 的 /usr/lib/dpkg/var 搬到 /var/lib/dpkg）发生在
    # 本脚本之后，所以两个位置都要找。
    rec = None
    for adm in ('var/lib/dpkg', 'usr/lib/dpkg/var'):
        cand = os.path.join(dst, adm, 'alternatives', altname)
        if os.path.isfile(cand):
            rec = cand; break
    if rec is None:
        return None
    lines = open(rec, encoding='utf-8', errors='replace').read().splitlines()
    best, best_prio = None, -1
    i = 0
    while i < len(lines):
        l = lines[i]
        # 候选组的特征：绝对路径 + 下一行是纯数字优先级
        if l.startswith('/') and i + 1 < len(lines) and lines[i + 1].strip().isdigit():
            prio = int(lines[i + 1].strip())
            if os.path.lexists(os.path.join(dst, l.lstrip('/'))) and prio > best_prio:
                best, best_prio = l, prio
            i += 2
        else:
            i += 1
    return best


alt_src = os.path.join(src, 'etc/alternatives')
alt_dst = os.path.join(dst, 'etc/alternatives')
if not os.path.isdir(alt_src):
    print("  源里没有 /etc/alternatives，跳过"); sys.exit(0)
os.makedirs(alt_dst, exist_ok=True)

for d in BINDIRS:
    sd = os.path.join(src, d)
    if not os.path.isdir(sd):
        continue
    for name in os.listdir(sd):
        sp = os.path.join(sd, name)
        if not os.path.islink(sp):
            continue
        lt = os.readlink(sp)
        if '/etc/alternatives/' not in lt:
            continue
        altname = os.path.basename(lt)
        alt_link = os.path.join(alt_src, altname)
        if not os.path.islink(alt_link):
            continue
        real = os.readlink(alt_link)                       # 源系统当前选中的候选，例如 /usr/bin/gawk
        if not os.path.lexists(os.path.join(dst, real.lstrip('/'))):
            # 当前候选没切进来。像 update-alternatives 那样从 DB 记录里回退到
            # 其它**存在**的候选（否则 /usr/bin/awk 这类会整个消失，
            # 而 mawk 明明在——只是源系统当时选的是 gawk）。
            real = pick_available(altname, dst) or ''
            if not real:
                skipped += 1
                continue
            fallback += 1
        # 两级链接都补
        t2 = os.path.join(alt_dst, altname)
        if os.path.lexists(t2): os.remove(t2)
        os.symlink(real, t2)
        t1 = os.path.join(dst, d, name)
        os.makedirs(os.path.dirname(t1), exist_ok=True)
        if not os.path.lexists(t1):
            os.symlink(lt, t1)
        restored += 1

# 清理不一致：slice 把源的 alternatives/ 目录整个拷了过来（不按 keep 过滤），
# 而链接只在"目标存在"时才补。结果是 DB 里有记录、链接不存在——
# `update-alternatives --all` 会报错，`--auto <name>` 会指向不存在的二进制。
db = next((os.path.join(dst, a, 'alternatives')
           for a in ('var/lib/dpkg', 'usr/lib/dpkg/var')
           if os.path.isdir(os.path.join(dst, a, 'alternatives'))), '')
purged = 0
if os.path.isdir(db):
    for rec in os.listdir(db):
        rp = os.path.join(db, rec)
        if not os.path.isfile(rp):
            continue
        try:
            lines = open(rp, encoding='utf-8', errors='replace').read().splitlines()
        except Exception:
            continue
        # 记录格式：status / link / [slave name, slave link]* / '' / (候选路径 / 优先级 / slave 路径*)*
        # 候选路径都是绝对路径且以 / 开头，逐行挑出来判存在性即可
        cands = [l for l in lines if l.startswith('/') and not l.endswith('.1.gz')]
        if cands and not any(os.path.lexists(os.path.join(dst, c.lstrip('/'))) for c in cands):
            os.remove(rp); purged += 1

print(f"  alternatives 链接: 补回 {restored}（其中回退到其它候选 {fallback}），"
      f"无可用候选跳过 {skipped}，清理悬空记录 {purged}")
