#!/usr/bin/env python3
"""自研 pkg 数据库（CRUX pkgutils 风格）的 rootfs 切片器。

凝思 6.0.42（磐石 Rocky 4.2）的 ISO 是整盘摊开的 rootfs，包管理是
/var/lib/pkg/db（name\\n version\\n file...\\n 空行），**没有依赖字段**——
所以闭包只能落在 ELF 层：种子包的文件里凡是 ELF，读其 NEEDED，把提供
该 so 的包拉进来，递归到不动点。

两种模式：
  media <rootfs> <out> <全部档位种子逗号串>   —— 本机切介质（超集）
  tier  <media>  <out> <本档种子逗号串>        —— 构建期切档位
media 模式产出：子集 rootfs + 剪过的 var/lib/pkg/db + .pkgmap（包→文件）。
tier 模式在 media 上再收窄（media 已含 .pkgmap，免再扫 ELF —— 判据在
media 期已经算完，构建期只做确定性拷贝）。
"""
import os, re, struct, sys, shutil


def load_db(path):
    pkgs = {}
    for blk in open(path, encoding='utf-8', errors='replace').read().split('\n\n'):
        lines = [l for l in blk.split('\n') if l]
        if len(lines) >= 2:
            pkgs[lines[0]] = (lines[1], ['/' + f for f in lines[2:]])
    return pkgs


def elf_needed(path):
    """读 ELF 的 DT_NEEDED。不 shell readelf：构建容器里未必有 binutils。"""
    try:
        with open(path, 'rb') as f:
            hdr = f.read(64)
            if hdr[:4] != b'\x7fELF' or len(hdr) < 64:
                return []
            is64 = hdr[4] == 2
            if not is64:
                return []            # 本线只有 x86_64
            e_shoff, = struct.unpack('<Q', hdr[40:48])
            e_shentsize, e_shnum = struct.unpack('<HH', hdr[58:62])
            f.seek(e_shoff)
            shs = f.read(e_shentsize * e_shnum)
            dyn = strtab = None
            for i in range(e_shnum):
                sh = shs[i*e_shentsize:(i+1)*e_shentsize]
                sh_type, = struct.unpack('<I', sh[4:8])
                if sh_type == 6:     # SHT_DYNAMIC
                    off, sz = struct.unpack('<QQ', sh[24:40])
                    link, = struct.unpack('<I', sh[40:44])
                    dyn = (off, sz)
                    lsh = shs[link*e_shentsize:(link+1)*e_shentsize]
                    strtab = struct.unpack('<QQ', lsh[24:40])
            if not dyn:
                return []
            f.seek(strtab[0]); strs = f.read(strtab[1])
            f.seek(dyn[0]); d = f.read(dyn[1])
            out = []
            for i in range(0, len(d) - 15, 16):
                tag, val = struct.unpack('<qQ', d[i:i+16])
                if tag == 1:         # DT_NEEDED
                    end = strs.index(b'\0', val)
                    out.append(strs[val:end].decode())
            return out
    except Exception:
        return []


def main():
    mode, src, out, seedstr = sys.argv[1:5]
    seeds = [s for s in seedstr.split(',') if s]
    # 第 5 参：逗号分隔的路径前缀，媒体期裁掉（只允许数据类：locale/doc/静态
    # Java 运行库等，与真机的偏差要记进 .origin 与 README）。zh_CN/en_US/C 的
    # locale 永远保留。
    prunes = [x for x in (sys.argv[5] if len(sys.argv) > 5 else '').split(',') if x]
    def pruned(fp):
        for pre in prunes:
            if fp.startswith(pre):
                if 'locale' in pre and re.search(r'/(zh_CN|en_US|C\.|C$|POSIX)', fp):
                    return False
                return True
        return False

    if mode == 'tier':
        # media 已带 .pkgmap（media 期算好的 包→版本→文件），只做确定性拷贝
        pkgs = {}
        for blk in open(os.path.join(src, '.pkgmap'), encoding='utf-8').read().split('\n\n'):
            lines = [l for l in blk.split('\n') if l]
            if len(lines) >= 2:
                pkgs[lines[0]] = (lines[1], lines[2:])
    else:
        pkgs = load_db(os.path.join(src, 'var/lib/pkg/db'))

    missing = [s for s in seeds if s not in pkgs]
    if missing:
        sys.exit('种子包在 pkg db 里不存在: %s' % ' '.join(missing))

    # so 名 → 提供者包
    so_owner = {}
    for name, (_, files) in pkgs.items():
        for fp in files:
            b = os.path.basename(fp)
            if '.so' in b:
                so_owner.setdefault(b, name)

    keep, queue = set(), list(seeds)
    while queue:
        cur = queue.pop()
        if cur in keep:
            continue
        keep.add(cur)
        for fp in pkgs[cur][1]:
            full = os.path.join(src, fp.lstrip('/'))
            if not os.path.isfile(full) or os.path.islink(full):
                continue
            for so in elf_needed(full):
                owner = so_owner.get(so)
                if owner and owner not in keep:
                    queue.append(owner)
    print('  闭包 %d 个包（种子 %d）' % (len(keep), len(seeds)))

    os.makedirs(out, exist_ok=True)
    n = 0
    cut = 0
    for name in sorted(keep):
        for fp in pkgs[name][1]:
            if pruned(fp):
                cut += 1
                continue
            s = os.path.join(src, fp.lstrip('/'))
            d = os.path.join(out, fp.lstrip('/'))
            if os.path.islink(s):
                os.makedirs(os.path.dirname(d), exist_ok=True)
                if not os.path.lexists(d):
                    os.symlink(os.readlink(s), d)
            elif os.path.isfile(s):
                os.makedirs(os.path.dirname(d), exist_ok=True)
                shutil.copy2(s, d)
                n += 1
            elif os.path.isdir(s) and not os.path.lexists(d):
                os.makedirs(d, exist_ok=True)
    print('  拷贝 %d 个文件（媒体期裁掉 %d 个数据类文件）' % (n, cut))

    # 剪过的 pkg db（镜像内自描述 + 测试框架数包用）
    os.makedirs(os.path.join(out, 'var/lib/pkg'), exist_ok=True)
    srcdb = load_db(os.path.join(src, 'var/lib/pkg/db')) if mode == 'media' else None
    with open(os.path.join(out, 'var/lib/pkg/db'), 'w') as f:
        for name in sorted(keep):
            ver = (srcdb or pkgs)[name][0] if mode == 'media' else pkgs[name][0]
            files = pkgs[name][1]
            f.write(name + '\n' + ver + '\n')
            f.write('\n'.join(p.lstrip('/') for p in files) + '\n\n')

    if mode == 'media':
        with open(os.path.join(out, '.pkgmap'), 'w') as f:
            for name in sorted(keep):
                kept = [p for p in pkgs[name][1] if not pruned(p)]
                f.write(name + '\n' + pkgs[name][0] + '\n' + '\n'.join(kept) + '\n\n')
        # 身份文件必须随介质走：pkg db 不登记 /etc/linx-release，但下游要拿它
        # 合成 os-release
        for idf in ('etc/linx-release', 'etc/issue'):
            sp = os.path.join(src, idf)
            if os.path.isfile(sp):
                os.makedirs(os.path.join(out, 'etc'), exist_ok=True)
                shutil.copy2(sp, os.path.join(out, idf))

main()
