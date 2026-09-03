#!/usr/bin/env python3
"""从 rpm 系安装介质自带的本地仓库 bootstrap 出一个 rootfs。

为什么不是 `dnf --installroot`：dnf 要求宿主有 dnf 且能解析目标发行版的 repo 配置。
builder 是 Debian，装 dnf 会拖进一大串 Python 依赖，而我们要的东西介质里已经全有：
`repodata/*-primary.xml.zst` 里带每个包的 provides 与 requires，`Packages/` 里是 rpm 本体。
所以直接解析 repodata 求依赖闭包，再用 `rpm --root` 一次性装进目标目录。

为什么不是 tools/rpmslice.py：那个是给「介质里带预装 rootfs」的情形写的（UOS 那种
squashfs）。麒麟信安的 ISO 实测没有 squashfs，只有仓库，所以走这条。
"""
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

NS = {"c": "http://linux.duke.edu/metadata/common",
      "r": "http://linux.duke.edu/metadata/rpm"}


def load_primary(repodata):
    """解析 primary.xml.zst，返回 (包名 -> 记录, 能力 -> 提供它的包名集合)。"""
    cand = [f for f in os.listdir(repodata) if f.endswith("primary.xml.zst")]
    if not cand:
        cand = [f for f in os.listdir(repodata) if f.endswith("primary.xml.gz")]
    if not cand:
        sys.exit(f"{repodata} 下找不到 primary.xml.zst/gz")
    path = os.path.join(repodata, cand[0])
    dec = ["zstd", "-dc"] if path.endswith(".zst") else ["gzip", "-dc"]
    xml = subprocess.run([*dec, path], capture_output=True).stdout
    root = ET.fromstring(xml)
    pkgs, provides = {}, {}
    for p in root.findall("c:package", NS):
        name = p.findtext("c:name", "", NS)
        loc = p.find("c:location", NS)
        fmt = p.find("c:format", NS)
        rec = {
            "name": name,
            "arch": p.findtext("c:arch", "", NS),
            "href": loc.get("href") if loc is not None else "",
            "requires": [], "provides": [name],
        }
        if fmt is not None:
            for e in fmt.findall("r:requires/r:entry", NS):
                n = e.get("name", "")
                # rpmlib(...) 是 rpm 自身的格式特性，config(...) 是配置伴生依赖，都不是真包
                if n and not n.startswith(("rpmlib(", "config(")):
                    rec["requires"].append(n)
            for e in fmt.findall("r:provides/r:entry", NS):
                n = e.get("name", "")
                if n:
                    rec["provides"].append(n)
        pkgs.setdefault(name, rec)
        for cap in rec["provides"]:
            provides.setdefault(cap, set()).add(name)
    # 文件级依赖（requires 里写 /usr/bin/sh 这类路径）需要 filelists 才能解析。
    # 不去解 filelists：改为在闭包阶段把无人提供的文件路径依赖记为「未解析」并报出来，
    # 由档位包集显式补齐 —— 静默忽略会切出跑不起来的 rootfs。
    return pkgs, provides


def closure(pkgs, provides, seeds):
    missing_seed = [s for s in seeds if s not in pkgs]
    if missing_seed:
        sys.exit(f"!! 种子不在介质仓库里（拼写或档位选包不当）: {missing_seed}")
    keep, frontier, unresolved = set(), list(seeds), set()
    while frontier:
        nxt = []
        for name in frontier:
            if name in keep:
                continue
            keep.add(name)
            for cap in pkgs[name]["requires"]:
                owners = provides.get(cap)
                if not owners:
                    unresolved.add(cap)
                    continue
                # 一个能力可能多包提供，取名字最短的那个（通常是主包而非兼容包）
                pick = sorted(owners, key=lambda x: (len(x), x))[0]
                if pick not in keep:
                    nxt.append(pick)
        frontier = nxt
    return keep, unresolved


def main():
    if len(sys.argv) < 4:
        sys.exit("用法: rpmmedia.py <media_dir> <dst_root> <seed1,seed2,...>")
    media, dst, seedstr = sys.argv[1], sys.argv[2], sys.argv[3]
    seeds = [s.strip() for s in seedstr.split(",") if s.strip()]
    pkgs, provides = load_primary(os.path.join(media, "repodata"))
    print(f"介质仓库 {len(pkgs)} 个包，{len(provides)} 个能力")
    # 取材阶段若交来了闭包清单，直接用它，不自己重算。理由见 rpmrepo-fetch.py：
    # 两套闭包实现对「多提供者时挑哪个」的取舍不同，重算会与取材的结论分叉，
    # 实测 loong64 的 base 档取材算 169 个而这里重算 166 个。ISO 介质那条路径
    # 没有这个文件，仍走自己算。
    _cl = os.path.join(media, ".closure")
    if os.path.exists(_cl):
        keep = {x.strip() for x in open(_cl) if x.strip()}
        _absent = sorted(n for n in keep if n not in pkgs)
        if _absent:
            sys.exit("取材清单里有 %d 个包不在这份 primary 里：%s"
                     % (len(_absent), ", ".join(_absent[:8])))
        unresolved = set()
        print("  用取材交来的闭包清单：%d 个包" % len(keep))
    else:
        keep, unresolved = closure(pkgs, provides, seeds)
    print(f"种子 {len(seeds)} 个 -> 闭包 {len(keep)} 个包")
    # 取材阶段若留下 .closure-count，就核对两侧算出的闭包一致。差异意味着这份
    # primary 不足以自描述（例如路径型依赖的提供者没有登记进 provides），
    # 而后果是这里"成功地"少装几个包，直到装完的依赖自洽检查才报未满足依赖。
    _cc = os.path.join(media, ".closure-count")
    if os.path.exists(_cc):
        _want = int(open(_cc).read().strip() or 0)
        if _want != len(keep):
            sys.exit("取材算出闭包 %d 个，这里重算得 %d 个。"
                     "物化出的 primary 不足以自描述，少的那几个包会被静默漏装。"
                     % (_want, len(keep)))
        print("  闭包条数与取材一致：%d" % _want)
    if unresolved:
        pathdeps = sorted(c for c in unresolved if c.startswith("/"))
        other = sorted(c for c in unresolved if not c.startswith("/"))
        if other:
            print(f"  ! 无人提供的能力 {len(other)} 个（前 8）: {other[:8]}")
        if pathdeps:
            print(f"  ! 文件路径依赖 {len(pathdeps)} 个未解析（前 8）: {pathdeps[:8]}")
            print("    这类要靠 filelists 才能定位提供者；rpm 安装时会自行校验，"
                  "若报缺就在该档位的包集里显式补上对应包。")
    # 安装顺序有讲究：`filesystem` 包负责建 usr-merge 的顶层符号链接（/lib64 -> usr/lib64 等）。
    # 若它不是第一个装，rpm 已经把 /lib64 当普通目录建出来了，再装它就报
    # 「File from package already exists as a directory in system」——与 deb 侧
    # kylin11 那个 /bin/sh ENOENT 是同一类 usr-merge 顺序问题（见 report §4.1 缺陷 D01）。
    FIRST = ["filesystem", "setup", "basesystem"]
    order = [n for n in FIRST if n in keep] + sorted(n for n in keep if n not in FIRST)
    files = []
    for n in order:
        href = pkgs[n]["href"]
        fp = os.path.join(media, href)
        if not os.path.exists(fp):
            sys.exit(f"!! 介质里缺 rpm 文件: {href}")
        files.append(fp)
    os.makedirs(dst, exist_ok=True)
    # 数据库后端必须与目标发行版一致。builder 的 rpm 4.20 默认写 sqlite，而麒麟信安
    # V6 自带的 rpm 4.18.2 编译时把 `_db_backend` 设成了 ndb —— 它去找 ndb 格式的库，
    # 找不到就报「零个包已安装」且不返回错误码。装完之后有一道断言核对条数，
    # 所以这个值配错会当场失败，不会再产出 `rpm -qa` 返回 0 的镜像。
    BACKEND = os.environ.get("RPM_DB_BACKEND", "").strip()
    DEF = ["--define", f"_db_backend {BACKEND}"] if BACKEND else []
    if BACKEND:
        print(f"数据库后端：{BACKEND}（取自 distros/*.conf 的 RPM_DB_BACKEND）")
    # rpm 的数据库要先初始化，否则 --root 安装会报 no dbpath
    subprocess.run(["rpm", *DEF, "--root", os.path.abspath(dst), "--initdb"], check=True)
    # initdb 之后立刻核对真的建出了数据库文件。理由是踩过的一个静默失效：给
    # rpm 4.20 指定 --define "_db_backend bdb" 时它接受参数、退出码 0、一个文件都不建
    # （4.19 起去掉了 bdb 写支持，却不报错）。不在这里拦的话后面每一步都"成功"，
    # 直到最后 rpm -qa 读出 0 个包 —— 那个症状与「空镜像」不可区分，而真因隔着
    # 一百多个包的安装日志。
    _dbdir = os.path.join(os.path.abspath(dst), "var/lib/rpm")
    _dbfiles = sorted(f for f in os.listdir(_dbdir)) if os.path.isdir(_dbdir) else []
    _dbfiles = [f for f in _dbfiles if not f.startswith(".")]
    if not _dbfiles:
        sys.exit("initdb 之后 %s 里没有任何数据库文件（后端 %s）。"
                 "宿主 rpm 可能不支持写这个后端——它会接受参数并返回 0，但什么都不建。"
                 % (_dbdir, BACKEND or "默认"))
    print("  数据库已建：%s" % " ".join(_dbfiles))
    # 分两批：先 filesystem 等建骨架，再装其余。一次性 -Uvh 全量会让 rpm 自己决定顺序，
    # 而它的排序不保证 filesystem 在前（实测就是这么失败的）。
    head = [f for f in files if os.path.basename(f).split("-")[0] in FIRST]
    rest = [f for f in files if f not in head]
    base_args = ["rpm", *DEF, "--root", os.path.abspath(dst), "-Uvh",
                 "--nodeps",     # 依赖已由上面的闭包保证；交给 rpm 会因文件路径依赖而失败
                 "--noscripts",  # 目标发行版的 scriptlet 在 Debian builder 上跑不了（与 deb 侧同因）
                 "--ignorearch", "--nosignature"]
    for label, batch in (("骨架", head), ("其余", rest)):
        if not batch:
            continue
        print(f"rpm 安装{label} {len(batch)} 个包…")
        p = subprocess.run([*base_args, *batch], capture_output=True, text=True)
        out = (p.stdout + p.stderr).strip().splitlines()
        for ln in out[-6:]:
            print("   ", ln)
        if p.returncode != 0:
            sys.exit(f"!! rpm 安装{label}失败 rc={p.returncode}")

    # ── 用目标自己的 rpm 重建数据库 ─────────────────────────────────────────────
    # 有些版本的目标 rpm 与宿主 rpm 在数据库格式上**没有交集**：麒麟信安 V3.4-4A
    # 自带 rpm 4.15.1，只支持 bdb（给它 ndb 或 sqlite 都建出 0 个文件）；而 builder
    # 的 rpm 4.20 自 4.19 起去掉了 bdb 写支持，指定 bdb 会接受参数、返回 0、什么都不建。
    # 两端谈不成，只能让目标自己写：文件已经由宿主 rpm 落到位，这里把包登记重做一遍。
    #
    # 跨架构时这一步和下面的 ldconfig / update-ca-trust 一样靠 binfmt 进 chroot 执行。
    if os.environ.get("RPM_DB_VIA_TARGET", "").strip() == "yes":
        trpm = os.path.join(dst, "usr/bin/rpm")
        if not os.path.exists(trpm):
            sys.exit("RPM_DB_VIA_TARGET=yes 但 rootfs 里没有 /usr/bin/rpm，无从重建")
        print("用目标自己的 rpm 重建数据库（宿主与目标的后端没有交集）…")
        shutil.rmtree(os.path.join(dst, "var/lib/rpm"), ignore_errors=True)
        r = subprocess.run(["chroot", os.path.abspath(dst), "/usr/bin/rpm", "--initdb"],
                           capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            sys.exit("目标 rpm --initdb 失败：%s" % (r.stderr or r.stdout).strip()[:200])
        _td = os.path.join(dst, "tmp/.rpmreg")
        os.makedirs(_td, exist_ok=True)
        inner = []
        for f in files:
            shutil.copy2(f, _td)
            inner.append("/tmp/.rpmreg/" + os.path.basename(f))
        r = subprocess.run(["chroot", os.path.abspath(dst), "/usr/bin/rpm", "--justdb",
                            "-Uvh", "--nodeps", "--noscripts", "--ignorearch",
                            "--nosignature", *inner],
                           capture_output=True, text=True, timeout=1800)
        shutil.rmtree(_td, ignore_errors=True)
        if r.returncode != 0:
            sys.exit("目标 rpm --justdb 登记失败：%s"
                     % (r.stderr or r.stdout).strip()[-300:])
        _f = [x for x in sorted(os.listdir(os.path.join(dst, "var/lib/rpm")))
              if not x.startswith(".")]
        if not _f:
            sys.exit("目标 rpm 重建后 var/lib/rpm 仍然是空的")
        print("  目标侧数据库已建：%s" % " ".join(_f[:6]))

    # --noscripts 跳过了全部 %post，其中 ca-certificates 的那一支会调
    # `update-ca-trust extract` 生成 /etc/pki/ca-trust/extracted/。不补跑，
    # /etc/pki/tls/certs/ca-bundle.crt 就是个悬空符号链接，镜像里所有 TLS 握手都失败。
    # 源数据（ca-bundle.trust.p11-kit）与 trust/p11-kit 二进制都在包里，补跑即可。
    if os.path.exists(os.path.join(dst, "usr/bin/update-ca-trust")):
        print("补跑 update-ca-trust extract（--noscripts 跳过的 %post）…")
        subprocess.run(["chroot", os.path.abspath(dst), "/usr/bin/update-ca-trust", "extract"],
                       capture_output=True, text=True, timeout=180)
        # ca-bundle.crt 指向一个**绝对路径**。宿主侧的 os.path.exists 不认 chroot 边界，
        # 会拿这个绝对路径去查 builder 自己的 /etc/pki，永远查不到 —— 必须手工把
        # 链接目标拼回 dst 前缀再判。
        link = os.path.join(dst, "etc/pki/tls/certs/ca-bundle.crt")
        tgt = os.readlink(link) if os.path.islink(link) else link
        real = os.path.join(dst, tgt.lstrip("/")) if tgt.startswith("/") else \
               os.path.join(os.path.dirname(link), tgt)
        if not os.path.isfile(real) or os.path.getsize(real) == 0:
            sys.exit(f"!! update-ca-trust 之后 {tgt} 仍缺失或为空，TLS 会全挂")
        print(f"    CA bundle 就绪：{os.path.getsize(real)} 字节")

    # --noscripts 也跳过了所有调 ldconfig 的 %post，于是 /etc/ld.so.cache 从未生成。
    # 后果按发行版布局而定：Debian 的多架构目录在动态链接器的内置默认搜索路径里，
    # 缺 cache 只损性能；RH 系把 systemd 的私有库放 /usr/lib64/systemd，那个目录
    # **不在**默认路径、只写在 /etc/ld.so.conf.d/systemd-x86_64.conf 里 —— 没有
    # cache 就等于 systemctl 等 64 个二进制全部起不来（实测 `systemctl --version`
    # 报 error while loading shared libraries）。
    if os.path.exists(os.path.join(dst, "sbin/ldconfig")) or \
       os.path.exists(os.path.join(dst, "usr/sbin/ldconfig")):
        # 与 update-ca-trust 同因：crypto-policies 的 %post 会把
        # /usr/share/crypto-policies/<策略>/ 里的模板展开到 /etc/crypto-policies/back-ends/。
        # --noscripts 跳过它之后那个目录是空的，于是 /etc/krb5.conf.d/crypto-policies
        # 这类指进去的软链全部悬空 —— 实测 V3.4 的 dangling_etc 检查就是这么报出来的，
        # 而报文里只有 basename「crypto-policies」，离真因隔着一层。
        _ucp = os.path.join(dst, "usr/bin/update-crypto-policies")
        if os.path.exists(_ucp):
            print("补跑 update-crypto-policies（--noscripts 跳过的 %post）…")
            subprocess.run(["chroot", os.path.abspath(dst), "/usr/bin/update-crypto-policies",
                            "--no-reload", "--set", "DEFAULT"],
                           capture_output=True, text=True, timeout=180)
            _be = os.path.join(dst, "etc/crypto-policies/back-ends")
            _n = len(os.listdir(_be)) if os.path.isdir(_be) else 0
            if _n == 0:
                sys.exit("update-crypto-policies 跑完 back-ends 仍是空的，"
                         "指进去的软链会全部悬空")
            print("    crypto-policies back-ends 就绪：%d 个文件" % _n)


        print("生成 /etc/ld.so.cache（--noscripts 跳过的 ldconfig）…")
        subprocess.run(["chroot", os.path.abspath(dst), "/sbin/ldconfig"],
                       capture_output=True, text=True, timeout=300)
        cache = os.path.join(dst, "etc/ld.so.cache")
        if not os.path.isfile(cache) or os.path.getsize(cache) == 0:
            sys.exit("!! ldconfig 之后 /etc/ld.so.cache 仍缺失或为空")
        # 断言不能只看文件在不在 —— 要看**非默认库目录里的二进制真能跑**。
        # 这一条最初被 elf_broken 检查里那句「已知误报」的注释掩盖过：症状形状
        # 一样，真相却是二进制起不来。判据因此是执行，不是 ldd 的输出。
        probe = subprocess.run(["chroot", os.path.abspath(dst), "/usr/bin/systemctl", "--version"],
                               capture_output=True, text=True, timeout=120)
        if os.path.exists(os.path.join(dst, "usr/bin/systemctl")) and probe.returncode != 0:
            sys.exit(f"!! systemctl 仍起不来：{(probe.stderr or probe.stdout).strip()[:160]}")
        print(f"    ld.so.cache 就绪：{os.path.getsize(cache)} 字节")
        # aux-cache 记录库的 inode 与 mtime，天然不可复现，且只是增量加速用的
        # 中间产物，本来就不该出厂（切片路径实测因它哈希全漂）。
        shutil.rmtree(os.path.join(dst, "var/cache/ldconfig"), ignore_errors=True)

    # 目标发行版的 rpm 必须能读出自己的库。读不出来时 `rpm -qa` 返回 0 且退出码为 0，
    # 与「空镜像」不可区分 —— 所以这里核对条数，而不是只看命令是否成功。
    if os.path.exists(os.path.join(dst, "usr/bin/rpm")):
        q = subprocess.run(["chroot", os.path.abspath(dst), "/usr/bin/rpm", "-qa"],
                           capture_output=True, text=True, timeout=300)
        got = len([x for x in q.stdout.splitlines() if x.strip()])
        if got != len(order):
            sys.exit(f"!! 镜像内 rpm -qa 读出 {got} 个包，闭包是 {len(order)} 个。"
                     f"多半是 RPM_DB_BACKEND 与目标 rpm 的 %{{_db_backend}} 不一致")
        print(f"    镜像内 rpm -qa 核对通过：{got} 个包")

    # 依赖自洽：装的时候带了 --nodeps（依赖由上面的闭包保证），所以 rpm 自己不会
    # 校验。而闭包只解析 primary.xml，**路径型依赖**（如 /usr/sbin/update-alternatives）
    # 只登记在 filelists.xml 里，求不出提供者就会静默漏包。所以装完必须用目标自己的
    # rpm 反查一遍——这个缺口最初是靠能力探针抓到的，现在提前到构建期。
    if os.path.exists(os.path.join(dst, "usr/bin/rpm")):
        v = subprocess.run(["chroot", os.path.abspath(dst), "/usr/bin/rpm",
                            "-Va", "--nofiles", "--nodigest", "--noscripts"],
                           capture_output=True, text=True, timeout=600)
        unmet = [l for l in (v.stdout + v.stderr).splitlines()
                 if "Unsatisfied dependencies" in l or "is needed by" in l]
        if unmet:
            print("!! 闭包不自洽，以下依赖未满足：")
            for l in unmet[:10]:
                print("   ", l.strip())
            sys.exit("!! 把缺失依赖的提供者加进 distros/*.conf 的 SLICE_* 后重建")
        print("    依赖自洽核对通过")

    # 另外落一份纯文本清单，供不带 rpm 的 micro 档与外部审计核对。
    dbdir = os.path.join(dst, "var/lib/rpm")
    os.makedirs(dbdir, exist_ok=True)
    with open(os.path.join(dbdir, ".sliced-packages"), "w") as fh:
        for n in order:
            fh.write(f"{pkgs[n]['name']}\n")
    n_files = sum(len(fs) for _, _, fs in os.walk(dst))
    print(f"完成：{len(files)} 个包，rootfs 里 {n_files} 个文件"
          f"，包清单已写入 /var/lib/rpm/.sliced-packages")
    if n_files < 200:
        sys.exit(f"!! rootfs 文件数异常少（{n_files}），安装没真正落盘")


if __name__ == "__main__":
    main()
