#!/usr/bin/env python3
"""从远端 ISO 里用 HTTP Range 只抽 squashfs（不下整盘），并校验 sha256。

用法: fetch-squashfs.py <iso-url> <iso内路径> <落地文件> [期望sha256]

刻意不在这里解析 conf。研究 repo 的版本自带一个正则 conf 解析器，它读不懂
`${ARCH}` 与按架构的 case 块——而 ISO_URL 恰恰每个架构都不同，那样会静默抽到
另一个架构的盘。取配置一律走 tools/conf-get.sh，由它 source conf（ARCH 已就位）。
"""
import os, sys, time, subprocess, hashlib, importlib.util

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

# 续传自己做，不能交给 curl 的 --retry。这是个抽 Range 的下载，curl 重试时会
# 按原 -r 从头再来；3 GiB 的盘在 1 MB/s 下要将近一小时，一次卡顿就白费一小时。
# 实测就是这么白费过一次。所以按已落地字节数重算区间，追加写入。
have = os.path.getsize(out) if os.path.exists(out) else 0
if have > size:
    print(f'  已有文件比目标还大（{have} > {size}），重来', flush=True)
    os.remove(out); have = 0
tries = 0
stuck = 0
while have < size:
    tries += 1
    if tries > 30: sys.exit(f'!! 续传 {tries-1} 轮仍未取满：已 {have} / 目标 {size}')
    print(f'  取 {have}..{size}（第 {tries} 轮，已有 {have*100//size}%）', flush=True)
    with open(out, 'ab') as fh:
        # 不设 --max-time：那是**总传输上限**，区分不了「慢但在进」和「卡死不动」。
        # 这个 CDN 实测在 1 MB/s 上下且会持续变慢，3 GiB 一趟就要一两小时，
        # 设了上限只会在半路砍断（curl: (28)），把已下的两三个 G 变成要重连的断点。
        # 卡死交给 --speed-limit / --speed-time：持续 120 秒低于 10 KB/s 才放弃。
        rc = subprocess.call(['curl', '-fsS', '--no-alpn', '-L',
                              '--connect-timeout', '30',
                              '--speed-limit', '10240', '--speed-time', '120',
                              '-r', f'{off+have}-{off+size-1}', url], stdout=fh)
    now = os.path.getsize(out)
    if now == have:
        # 一次连接失败不代表源端不可用。给几次退避重连的机会，连续零进展才判死。
        stuck += 1
        if stuck >= 3:
            sys.exit(f'!! 连续 {stuck} 轮一个字节都没进（rc={rc}），判定源端不可用')
        print(f'    第 {tries} 轮零进展（rc={rc}），退避 {stuck*30} 秒后重连', flush=True)
        time.sleep(stuck * 30)
    else:
        stuck = 0
    have = now
if have == size:
    print(f'  取满 {size} 字节', flush=True)

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
