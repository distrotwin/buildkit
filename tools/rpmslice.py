#!/usr/bin/env python3
"""rpm 系的依赖闭包切片：从 ISO 里的 rootfs 切出分档 rootfs。

与 deb 侧的 tools/slice.py 同构，差别只在数据源：
  deb：/var/lib/dpkg/status 的 Depends 字段 + info/*.list 的文件清单
  rpm：rpm 数据库（rpmdb）的 requires/provides + 每包的文件清单

为什么不用 `dnf --installroot`：那条路要求能连上软件源。麒麟信安的桌面版软件源
需要授权，而本项目的前提是「只从 ISO 出发」（report §2.4 第 4 条筛选条件）。
所以走与 UOS 相同的思路——把 ISO 里已经装好的那套 rootfs 按依赖闭包切出来。

依赖解析用宿主的 rpm 命令查询目标 rootfs 的数据库（`rpm --root`），
不在容器里跑目标发行版的 rpm——那会撞上与 deb 侧 kylin10 同类的工具链代差问题。
"""
import os
import shutil
import stat as stat_mod
import subprocess
import sys


def rpm_q(root, *args):
    """对目标 rootfs 的 rpmdb 做查询。失败即抛，不静默返回空。"""
    cmd = ["rpm", "--root", os.path.abspath(root), "--dbpath", "/var/lib/rpm", *args]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:6])}… 失败 rc={p.returncode}: {p.stderr.strip()[:200]}")
    return p.stdout


def all_packages(root):
    """包名 -> 完整 NEVRA。用 %{NAME} 建索引，因为 conf 里的种子写的是包名。"""
    out = rpm_q(root, "-qa", "--qf", "%{NAME}\\t%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\\n")
    m = {}
    for ln in out.splitlines():
        if "\t" not in ln:
            continue
        name, nevra = ln.split("\t", 1)
        m.setdefault(name, nevra)
    return m


def requires_of(root, nevra):
    """一个包的 requires。rpm 的 requires 可以是能力名（如 libc.so.6）而不是包名，
    所以要再用 --whatprovides 落到实际包上 —— 这一步不能省，省了闭包就是残的。"""
    out = rpm_q(root, "-q", "--requires", nevra)
    caps = []
    for ln in out.splitlines():
        c = ln.split()[0] if ln.split() else ""
        if not c or c.startswith("rpmlib("):      # rpmlib(...) 是格式特性，不是真依赖
            continue
        caps.append(c)
    return caps


def providers(root, caps, cache):
    """能力名 -> 提供它的包名集合。批量查并缓存，避免对同一能力反复 fork rpm。"""
    todo = [c for c in caps if c not in cache]
    for c in todo:
        try:
            out = rpm_q(root, "-q", "--whatprovides", c, "--qf", "%{NAME}\\n")
            cache[c] = {x.strip() for x in out.splitlines() if x.strip()}
        except RuntimeError:
            cache[c] = set()          # 无人提供：通常是可选依赖或已被 filter 掉的能力
    return {p for c in caps for p in cache.get(c, ())}


def closure(root, pkgs, seeds):
    """从种子出发求依赖闭包。返回 (保留的包名集合, 未解析的种子)。"""
    missing = {s for s in seeds if s not in pkgs}
    keep, frontier, cap_cache = set(), [s for s in seeds if s in pkgs], {}
    while frontier:
        nxt = []
        for name in frontier:
            if name in keep:
                continue
            keep.add(name)
            try:
                caps = requires_of(root, pkgs[name])
            except RuntimeError as ex:
                print(f"  ! {name} 的 requires 查询失败：{ex}", file=sys.stderr)
                continue
            for p in providers(root, caps, cap_cache):
                if p in pkgs and p not in keep:
                    nxt.append(p)
        frontier = nxt
    return keep, missing


def files_of(root, pkgs, keep):
    """闭包内所有包的文件清单，按「是不是目录」分开 —— 与 deb 侧同样的处理。"""
    files, dirs = set(), set()
    for name in sorted(keep):
        try:
            out = rpm_q(root, "-q", "--list", pkgs[name])
        except RuntimeError:
            continue
        for p in out.splitlines():
            p = p.strip()
            if not p or p == "(contains no files)":
                continue
            ap = os.path.join(root, p.lstrip("/"))
            if os.path.isdir(ap) and not os.path.islink(ap):
                dirs.add(p)
            else:
                files.add(p)
    return files, dirs


def materialize(src, dst, files, dirs):
    """把文件与目录落到 dst。权限处理与 deb 侧一致，原因见那边的注释：
    shutil.copy2 保留 mode 但**不保留 uid/gid**，不补 chown 会让 2755 root:shadow
    的二进制变成 setgid root；而 chown 又会清掉 setuid/setgid 位，所以必须再 chmod。
    """
    os.makedirs(dst, exist_ok=True)
    # 1) 先建顶层符号链接（usr-merge 的 /lib -> usr/lib 之类），按深度升序多趟重试
    links = [f for f in files if os.path.islink(os.path.join(src, f.lstrip("/")))]
    todo_l = sorted(links, key=lambda x: x.count("/"))
    for _ in range(6):
        left = []
        for f in todo_l:
            t = os.path.join(dst, f.lstrip("/"))
            if os.path.lexists(t):
                continue
            try:
                os.makedirs(os.path.dirname(t), exist_ok=True)
                os.symlink(os.readlink(os.path.join(src, f.lstrip("/"))), t)
            except Exception:
                left.append(f)
        if not left or len(left) == len(todo_l):
            todo_l = left
            break
        todo_l = left
    # 2) 建目录，保留属主与权限位（如 /etc/ssl/private 的 710）
    todo = sorted(dirs, key=lambda x: x.count("/"))
    for _ in range(6):
        left = []
        for d in todo:
            try:
                td = os.path.join(dst, d.lstrip("/"))
                os.makedirs(td, exist_ok=True)
                sdir = os.path.join(src, d.lstrip("/"))
                if os.path.isdir(sdir) and not os.path.islink(sdir):
                    st_d = os.lstat(sdir)
                    os.chown(td, st_d.st_uid, st_d.st_gid)
                    os.chmod(td, stat_mod.S_IMODE(st_d.st_mode))
            except Exception:
                left.append(d)
        if not left or len(left) == len(todo):
            todo = left
            break
        todo = left
    if todo:
        print(f"  ! 有 {len(todo)} 个目录建不出来（示例 {todo[:3]}）")
    n_copy = n_skip = 0
    for f in sorted(files):
        s = os.path.join(src, f.lstrip("/"))
        t = os.path.join(dst, f.lstrip("/"))
        if not os.path.lexists(s):
            n_skip += 1
            continue
        try:
            os.makedirs(os.path.dirname(t), exist_ok=True)
        except Exception:
            n_skip += 1
            continue
        try:
            if os.path.islink(s):
                if os.path.lexists(t):
                    n_copy += 1
                    continue
                os.symlink(os.readlink(s), t)
                st_src = os.lstat(s)
                os.chown(t, st_src.st_uid, st_src.st_gid, follow_symlinks=False)
            else:
                shutil.copy2(s, t, follow_symlinks=False)
                st_src = os.lstat(s)
                os.chown(t, st_src.st_uid, st_src.st_gid, follow_symlinks=False)
                os.chmod(t, stat_mod.S_IMODE(st_src.st_mode))
        except Exception as ex:
            n_skip += 1
            if n_skip <= 5:
                print(f"    跳过 {f}: {type(ex).__name__}: {ex}")
            continue
        n_copy += 1
    return n_copy, n_skip


def main():
    if len(sys.argv) < 4:
        sys.exit("用法: rpmslice.py <src_rootfs> <dst_rootfs> <seed1,seed2,...>")
    src, dst, seedstr = sys.argv[1], sys.argv[2], sys.argv[3]
    seeds = [s.strip() for s in seedstr.split(",") if s.strip()]
    dbdir = os.path.join(src, "var/lib/rpm")
    if not os.path.isdir(dbdir):
        sys.exit(f"找不到 rpmdb：{dbdir}")
    pkgs = all_packages(src)
    print(f"源 rootfs 共 {len(pkgs)} 个 rpm 包")
    keep, missing = closure(src, pkgs, seeds)
    print(f"种子 {len(seeds)} 个 -> 闭包 {len(keep)} 个包"
          + (f"，未解析 {len(missing)}: {sorted(missing)[:8]}" if missing else ""))
    if missing:
        sys.exit(f"!! 种子未在源 rootfs 里找到（拼写错误或该档位选包不当）: {sorted(missing)}")
    files, dirs = files_of(src, pkgs, keep)
    print(f"文件 {len(files)} 个，目录 {len(dirs)} 个")
    n_copy, n_skip = materialize(src, dst, files, dirs)
    print(f"拷贝 {n_copy}，跳过缺失 {n_skip}")
    # 与 deb 侧同样的失败阈值：跳过过多是静默劣化的温床
    if n_skip > max(20, n_copy // 200):
        sys.exit(f"!! 跳过文件过多: {n_skip}/{n_copy + n_skip}")
    # 裁剪 rpmdb：只保留闭包内的包，否则镜像里的 rpm -qa 会列出根本不存在的包
    dst_db = os.path.join(dst, "var/lib/rpm")
    os.makedirs(dst_db, exist_ok=True)
    for fn in os.listdir(dbdir):
        sp, tp = os.path.join(dbdir, fn), os.path.join(dst_db, fn)
        if os.path.isfile(sp):
            shutil.copy2(sp, tp)
    kept_file = os.path.join(dst, "var/lib/rpm/.sliced-packages")
    with open(kept_file, "w") as fh:
        fh.write("\n".join(sorted(keep)) + "\n")
    print(f"rpmdb 已拷贝；闭包清单留在 /var/lib/rpm/.sliced-packages（{len(keep)} 个包）")
    print("⚠️ rpmdb 未做逐包裁剪：rpm 的数据库是 BDB/sqlite 二进制，"
          "安全的裁剪要在目标发行版自己的 rpm 里做（与 deb 侧可以直接编辑 status 文本不同）。"
          "因此镜像内 rpm -qa 会列出源 rootfs 的全部包，实际存在的以 .sliced-packages 为准 —— "
          "这一点必须写进 report 的局限，不能让读者以为 rpm -qa 的输出就是镜像内容。")


if __name__ == "__main__":
    main()
