#!/usr/bin/env python3
"""从远端 ISO 里用 HTTP Range 只抽 squashfs（不下整盘），并校验 sha256。

用法: fetch-squashfs.py <iso-url> <iso内路径> <落地文件> [期望sha256]

刻意不在这里解析 conf。研究 repo 的版本自带一个正则 conf 解析器，它读不懂
`${ARCH}` 与按架构的 case 块——而 ISO_URL 恰恰每个架构都不同，那样会静默抽到
另一个架构的盘。取配置一律走 tools/conf-get.sh，由它 source conf（ARCH 已就位）。
"""
import os, sys, subprocess, hashlib, importlib.util

url, path, out = sys.argv[1], sys.argv[2], sys.argv[3]
want = sys.argv[4] if len(sys.argv) > 4 else ''
BK = os.environ.get('BK') or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.makedirs(os.path.dirname(out) or '.', exist_ok=True)

spec = importlib.util.spec_from_file_location('i9', os.path.join(BK, 'tools', 'iso9660.py'))
m9 = importlib.util.module_from_spec(spec); spec.loader.exec_module(m9)

iso = m9.ISO(url)
e = iso.find(path) or sys.exit(f'ISO 里找不到 {path}')
off, size = e['lba'] * 2048, e['size']
print(f'squashfs: offset={off} size={size} ({size/2**30:.2f} GiB) -> {out}', flush=True)

if os.path.exists(out) and os.path.getsize(out) == size:
    print('  已存在且大小一致，跳过下载', flush=True)
else:
    rc = subprocess.call(['curl', '-fsS', '--no-alpn', '-L', '--max-time', '7200',
                          '--speed-limit', '10240', '--speed-time', '120',
                          '--retry', '3', '--retry-delay', '5', '--retry-all-errors',
                          '-r', f'{off}-{off+size-1}', '-o', out, url])
    if rc != 0: sys.exit(f'curl 抽取失败 rc={rc}')
    if os.path.getsize(out) != size:
        sys.exit(f'抽出的字节数不符：期望 {size} 实际 {os.path.getsize(out)}')

h = hashlib.sha256()
with open(out, 'rb') as f:
    for blk in iter(lambda: f.read(1 << 22), b''): h.update(blk)
got = h.hexdigest()
# 采指纹模式：conf 里还没有锚点时用它把实测值取回来，取完即止，不继续构建。
# 平时（HARVEST 未设）没有锚点必须失败——没有锚点等于不知道手上这份是不是原货。
if os.environ.get('HARVEST') == '1':
    print(f'HARVEST_SHA256={got}', flush=True)
    sys.exit(0)
if not want:
    sys.exit(f'!! conf 里没有 SQUASHFS_SHA256。实测为 {got}\n'
             f'   写回 conf 再构建——没有锚点等于不知道手上这份是不是原货')
if got != want:
    sys.exit(f'!! sha256 不符\n   期望 {want}\n   实际 {got}')
print(f'  sha256 校验通过 {got[:16]}…', flush=True)
