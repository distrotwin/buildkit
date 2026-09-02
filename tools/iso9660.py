#!/usr/bin/env python3
"""通过 HTTP Range 直读远程 ISO9660 目录树，不下载整盘。"""
import sys, json, ssl, urllib.request, io, struct

SEC = 2048
class RemoteISO:
    def __init__(self, url):
        self.url = url; self.ctx = ssl.create_default_context()
        self.bytes_read = 0; self.reqs = 0
    def read(self, off, length):
        import subprocess, tempfile, os
        fd, tmp = tempfile.mkstemp(prefix="isoseg."); os.close(fd)
        try:
            for attempt in range(3):
                p = subprocess.run(["curl","-sS","--no-alpn","-L","--max-time","120",
                                    "-r", f"{off}-{off+length-1}",
                                    "-H","User-Agent: Mozilla/5.0 (X11; Linux x86_64)",
                                    "-o", tmp, self.url],
                                   capture_output=True)
                d = open(tmp,"rb").read()
                if p.returncode == 0 and len(d) > 0:
                    self.bytes_read += len(d); self.reqs += 1
                    return d
            raise RuntimeError(f"curl 取 {off}+{length} 失败: rc={p.returncode} {p.stderr[:200]!r}")
        finally:
            try: os.unlink(tmp)
            except OSError: pass
    def sectors(self, lba, n=1): return self.read(lba*SEC, n*SEC)

def both_le(b, off, size):   # both-endian 字段，取小端那半
    return int.from_bytes(b[off:off+size//2], "little")

def parse_dirrecs(data):
    """解析一段目录区，返回 [(name, lba, size, isdir, flags)]"""
    out=[]; i=0
    while i < len(data):
        ln = data[i]
        if ln == 0:
            i = (i//SEC + 1)*SEC      # 跳到下一扇区
            if i >= len(data): break
            continue
        rec = data[i:i+ln]
        if len(rec) < 33: break
        lba  = both_le(rec, 2, 8)
        size = both_le(rec, 10, 8)
        flags= rec[25]
        nlen = rec[32]
        raw  = rec[33:33+nlen]
        if   raw == b"\x00": name="."
        elif raw == b"\x01": name=".."
        else:
            name = raw.decode("utf-8","replace").split(";")[0]
        # Rock Ridge: System Use 区里的 NM 条目才是真实长文件名
        su_off = 33 + nlen + ((nlen+1) % 2)
        su = rec[su_off:]
        rrname = b""; j = 0
        while j + 4 <= len(su):
            sig = su[j:j+2]; slen = su[j+2]
            if slen < 3: break
            if sig == b"NM":
                rrname += su[j+5:j+slen]
            j += slen
        if rrname:
            name = rrname.decode("utf-8","replace")
        out.append({"name":name,"lba":lba,"size":size,"dir":bool(flags&0x02),
                    "multi":bool(flags&0x80)})
        i += ln
    # 合并多 extent 文件（>4GiB）
    merged=[]
    for r in out:
        if merged and merged[-1]["multi"] and merged[-1]["name"]==r["name"]:
            merged[-1]["size"] += r["size"]; merged[-1]["multi"]=r["multi"]
        else: merged.append(dict(r))
    return merged

class ISO:
    def __init__(self, url):
        self.io = RemoteISO(url)
        pvd = self.io.sectors(16)
        if pvd[1:6] != b"CD001": raise RuntimeError("非 ISO9660: magic=%r" % pvd[1:6])
        self.volid = pvd[40:72].decode("ascii","replace").strip()
        self.nsec  = both_le(pvd, 80, 8)
        rr = pvd[156:156+34]
        self.root = {"lba": both_le(rr,2,8), "size": both_le(rr,10,8)}
    def ls(self, ent):
        nsec = (ent["size"]+SEC-1)//SEC
        return [r for r in parse_dirrecs(self.io.sectors(ent["lba"], nsec))
                if r["name"] not in (".","..")]
    def find(self, path):
        cur = self.root
        for part in [p for p in path.split("/") if p]:
            hit=[e for e in self.ls(cur) if e["name"].lower()==part.lower()]
            if not hit: return None
            cur = hit[0]
        return cur
    def cat(self, ent, limit=None):
        n = min(ent["size"], limit or ent["size"])
        return self.io.read(ent["lba"]*SEC, n)

def human(n):
    for u in ["B","KB","MB","GB"]:
        if n < 1024: return f"{n:.1f}{u}"
        n/=1024
    return f"{n:.1f}TB"

if __name__ == "__main__":
    url = sys.argv[1]
    iso = ISO(url)
    print(f"  volume-id : {iso.volid!r}   总扇区 {iso.nsec} ({human(iso.nsec*SEC)})")
    print(f"  根目录:")
    for e in sorted(iso.ls(iso.root), key=lambda x:(not x["dir"], x["name"])):
        print(f"      {'d' if e['dir'] else '-'} {e['name']:<28} {human(e['size'])}")
    print(f"  [Range 请求 {iso.io.reqs} 次，共下载 {human(iso.io.bytes_read)}]")
