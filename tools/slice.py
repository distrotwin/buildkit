#!/usr/bin/env python3
"""从一个已解包的 rootfs 里按包闭包切出小 rootfs（穷人版 chisel）。
用法: slice.py <src-rootfs> <dst-rootfs> <seed-pkg,...> """
import sys, os, re, shutil, subprocess
import stat as stat_mod

def parse_status(path):
    pkgs = {}
    cur = {}
    key = None
    for line in open(path, encoding='utf-8', errors='replace'):
        if line.strip() == '':
            if cur.get('Package'): pkgs[cur['Package']] = cur
            cur, key = {}, None; continue
        if line[0] in ' \t' and key:
            cur[key] += '\n' + line.rstrip(); continue
        if ':' in line:
            key, _, v = line.partition(':')
            cur[key] = v.strip()
    if cur.get('Package'): pkgs[cur['Package']] = cur
    return pkgs

def dep_alts(field):
    """返回 [[候选1, 候选2...], ...]。保留 or-组的全部候选。

    只取第一个候选是错的：`Depends: foo | bar` 里 foo 若不存在也没人 Provides，
    整条依赖会被丢掉，而 bar 明明可用。
    """
    out = []
    for alt in field.split(','):
        cands = []
        for one in alt.split('|'):
            n = re.split(r'[\s(:]', one.strip())[0]
            if n: cands.append(n)
        if cands: out.append(cands)
    return out


def dep_names(field):
    return [c[0] for c in dep_alts(field)]

def closure(pkgs, seeds):
    provides = {}
    for n, p in pkgs.items():
        for pr in dep_names(p.get('Provides', '')):
            provides.setdefault(pr, []).append(n)
    seen, stack = set(), list(seeds)
    missing = set()

    def resolve(name):
        """把一个依赖名解析成实际包名：本体优先，其次 Provides（优先已选中的提供者）。"""
        if name in pkgs: return name
        cand = provides.get(name)
        if not cand: return None
        for c in cand:
            if c in seen: return c        # 已选中的提供者优先，避免把 gawk 拉进只要 mawk 的镜像
        return cand[0]

    while stack:
        n = stack.pop()
        if n in seen: continue
        r = resolve(n)
        if r is None: missing.add(n); continue
        n = r
        if n in seen: continue
        seen.add(n)
        p = pkgs[n]
        for f in ('Pre-Depends', 'Depends'):
            for alts in dep_alts(p.get(f, '')):
                # or-组：任一候选已解析得到就够；都解析不出才记 missing
                if any(resolve(c) in seen for c in alts if resolve(c)): continue
                picked = next((c for c in alts if resolve(c)), None)
                if picked: stack.append(picked)
                else: missing.add(alts[0])
    return seen, missing

def copy_filtered_db(src_f, dst_f, keep, pkg_line):
    """按 keep 过滤 dpkg 的 diversions / statoverride。

    diversions 格式：每 3 行一组（原路径 / 改道后路径 / 拥有该改道的包）。
    statoverride 格式：每行 `user group mode path`，无包归属 -> pkg_line=0 表示整行照抄。
    """
    if not os.path.isfile(src_f):
        open(dst_f, 'a').close(); return
    lines = open(src_f, encoding='utf-8', errors='replace').read().splitlines()
    out = []
    if pkg_line:
        for i in range(0, len(lines) - pkg_line + 1, pkg_line):
            grp = lines[i:i + pkg_line]
            if len(grp) < pkg_line:
                break
            owner = grp[pkg_line - 1].strip()
            # 包名可能带 :arch；LOCAL 表示本地改道，保留
            if owner == 'LOCAL' or owner.split(':')[0] in keep:
                out.extend(grp)
    else:
        out = lines
    with open(dst_f, 'w', encoding='utf-8') as fh:
        for l in out:
            fh.write(l + '\n')


def main():
    src, dst, seedstr = sys.argv[1], sys.argv[2], sys.argv[3]
    seeds = [s.strip() for s in seedstr.split(',') if s.strip()]
    # dpkg admindir 位置各家不同：UOS V25 在 /usr/lib/dpkg/var
    admin = None
    for cand in ('var/lib/dpkg', 'usr/lib/dpkg/var'):
        if os.path.exists(os.path.join(src, cand, 'status')): admin = cand; break
    if not admin: sys.exit(f"找不到 dpkg status（试过 var/lib/dpkg, usr/lib/dpkg/var）")
    print(f"dpkg admindir: /{admin}")
    status = os.path.join(src, admin, 'status')
    pkgs = parse_status(status)
    keep, missing = closure(pkgs, seeds)
    print(f"种子 {len(seeds)} 个 -> 闭包 {len(keep)} 个包" + (f"，未解析 {len(missing)}: {sorted(missing)[:8]}" if missing else ""))
    info = os.path.join(src, admin, 'info')
    files, dirs = set(), set()
    for n in keep:
        arch = pkgs[n].get('Architecture', '')
        for cand in (f'{n}:{arch}.list', f'{n}.list'):
            fp = os.path.join(info, cand)
            if os.path.exists(fp):
                for ln in open(fp, encoding='utf-8', errors='replace'):
                    p = ln.rstrip('\n')
                    if not p or p == '/.': continue
                    ap = os.path.join(src, p.lstrip('/'))
                    if os.path.isdir(ap) and not os.path.islink(ap): dirs.add(p)
                    else: files.add(p)
                break
    print(f"文件 {len(files)} 个，目录 {len(dirs)} 个")
    os.makedirs(dst, exist_ok=True)
    # 1) 先建顶层符号链接（usr-merge 的 /lib -> usr/lib 等），按深度升序
    links = [f for f in files if os.path.islink(os.path.join(src, f.lstrip('/')))]
    todo_l = sorted(links, key=lambda x: x.count('/'))
    for _ in range(6):
        left = []
        for f in todo_l:
            t = os.path.join(dst, f.lstrip('/'))
            if os.path.lexists(t): continue
            try:
                os.makedirs(os.path.dirname(t), exist_ok=True)
                os.symlink(os.readlink(os.path.join(src, f.lstrip('/'))), t)
            except Exception:
                left.append(f)
        if not left or len(left) == len(todo_l): todo_l = left; break
        todo_l = left
    # 2) 再建目录：多趟重试，直到不再有进展（符号链接目标可能后建）
    todo = sorted(dirs, key=lambda x: x.count('/'))
    for _ in range(6):
        left = []
        for d in todo:
            try:
                td = os.path.join(dst, d.lstrip('/'))
                os.makedirs(td, exist_ok=True)
                sdir = os.path.join(src, d.lstrip('/'))
                if os.path.isdir(sdir) and not os.path.islink(sdir):
                    st_d = os.lstat(sdir)
                    os.chown(td, st_d.st_uid, st_d.st_gid)
                    os.chmod(td, stat_mod.S_IMODE(st_d.st_mode))   # 如 /etc/ssl/private 的 710
            except Exception: left.append(d)
        if not left or len(left) == len(todo): todo = left; break
        todo = left
    if todo: print(f"  ! 有 {len(todo)} 个目录建不出来（示例 {todo[:3]}）")
    n_copy = n_skip = 0
    for f in sorted(files):
        s = os.path.join(src, f.lstrip('/')); t = os.path.join(dst, f.lstrip('/'))
        if not os.path.lexists(s): n_skip += 1; continue
        try: os.makedirs(os.path.dirname(t), exist_ok=True)
        except Exception: n_skip += 1; continue
        if os.path.islink(s):
            if os.path.lexists(t): n_copy += 1; continue
            try:
                os.symlink(os.readlink(s), t)
                st_src = os.lstat(s)
                os.chown(t, st_src.st_uid, st_src.st_gid, follow_symlinks=False)
            except OSError: n_skip += 1; continue
        else:
            try:
                shutil.copy2(s, t, follow_symlinks=False)
                # ⚠️ shutil.copy2 保留 mode（含 setuid/setgid 位）但**不保留 uid/gid**。
                # 不补这一步，源里 2755 root:shadow 的 chage/unix_chkpwd 会变成
                # setgid **root**——严格强于原权限，是实打实的提权面。
                st_src = os.lstat(s)
                os.chown(t, st_src.st_uid, st_src.st_gid, follow_symlinks=False)
                os.chmod(t, stat_mod.S_IMODE(st_src.st_mode))   # chown 会清 setuid/setgid，需重设
            except Exception as ex:
                n_skip += 1
                if n_skip <= 5: print(f"    跳过 {f}: {type(ex).__name__}: {ex}")
                continue
        n_copy += 1
    print(f"拷贝 {n_copy}，跳过缺失 {n_skip}")
    # 缺包 / 跳过过多都是静默劣化的温床，超阈值直接失败而不是只打印
    if missing - {'usrmerge'}:
        sys.exit(f"!! 依赖未解析（非预期）: {sorted(missing - {'usrmerge'})[:12]}")
    if n_skip > max(20, n_copy // 200):
        sys.exit(f"!! 跳过文件过多: {n_skip}/{n_copy + n_skip}")
    # 裁剪 dpkg 元数据
    dd = os.path.join(dst, admin)
    os.makedirs(os.path.join(dd, 'info'), exist_ok=True)
    os.makedirs(os.path.join(dd, 'updates'), exist_ok=True)
    open(os.path.join(dd, 'available'), 'a').close()
    # diversions / statoverride 必须从源带过来（按 keep 过滤），不能建成空文件：
    #   diversions  记录 dpkg-divert 的改道，UOS 的 /usr/bin/dpkg -> dpkg.real 就是一条
    #               diversion；清空后 dpkg 认为那是普通文件，dpkg -V 必报差异
    #   statoverride 记录"这个文件该是什么属主/权限"，清空后属主异常无从追溯
    copy_filtered_db(os.path.join(src, admin, 'diversions'),  os.path.join(dd, 'diversions'),  keep, 3)
    copy_filtered_db(os.path.join(src, admin, 'statoverride'), os.path.join(dd, 'statoverride'), keep, 0)
    # ⚠️ admindir 的顶层元文件必须从源系统原样带过来，否则 dpkg 行为不对：
    #    arch        —— 记录本机与外来架构。缺了它 dpkg 就不知道自己是 amd64，
    #                   对 `Multi-Arch: same` 的包会去找 pkg.list 而不是 pkg:amd64.list，
    #                   于是 `dpkg --audit` 报一大片 "missing the list control file"。
    #    cmethopt / alternatives / triggers / parts —— dpkg 与 update-alternatives 的状态。
    # info/format 决定 dpkg 怎么给 info 文件命名：内容为 1 时，Multi-Arch: same 的包
    # 用 pkg:arch.list，否则用 pkg.list。漏了这个文件，dpkg 会去找不带 arch 的名字，
    # 结果对一大片包报 "missing the list control file"（而源系统存的是带 arch 的名字）。
    fmt = os.path.join(src, admin, 'info', 'format')
    if os.path.isfile(fmt):
        shutil.copy2(fmt, os.path.join(dd, 'info', 'format'))
    for f in ('arch', 'cmethopt', 'format'):
        src_f = os.path.join(src, admin, f)
        if os.path.isfile(src_f):
            shutil.copy2(src_f, os.path.join(dd, f))
    for d in ('alternatives', 'triggers', 'parts'):
        src_d = os.path.join(src, admin, d)
        dst_d = os.path.join(dd, d)
        os.makedirs(dst_d, exist_ok=True)
        if os.path.isdir(src_d):
            for e in os.listdir(src_d):
                sp = os.path.join(src_d, e)
                if os.path.isfile(sp):
                    try: shutil.copy2(sp, os.path.join(dst_d, e))
                    except Exception: pass
    with open(os.path.join(dd, 'status'), 'w', encoding='utf-8') as out:
        raw = open(status, encoding='utf-8', errors='replace').read()
        for blk in raw.split('\n\n'):
            m = re.search(r'^Package: (\S+)', blk, re.M)
            if m and m.group(1) in keep:
                out.write(blk.rstrip('\n') + '\n\n')
    for n in keep:
        arch = pkgs[n].get('Architecture', '')
        for base in (f'{n}:{arch}', n):
            for ext in ('list', 'md5sums', 'conffiles', 'shlibs', 'symbols', 'triggers'):
                s = os.path.join(info, f'{base}.{ext}')
                if os.path.exists(s):
                    shutil.copy2(s, os.path.join(dd, 'info', f'{base}.{ext}'))
    sz = subprocess.run(['du','-sh',dst], capture_output=True, text=True).stdout.split()[0]
    print(f"完成: {dst}  {sz}")

main()
