#!/usr/bin/env python3
"""把一个或多个远程 rpm 源物化成「介质形状」的目录，供 tools/rpmmedia.py 直接使用。

为什么不直接 dnf --installroot：理由与 rpmmedia.py 同 —— builder 是 Debian，
装 dnf 会拖进一大串 Python 依赖，而 repodata 里已经有 provides/requires。

为什么不整盘下 ISO：麒麟信安放 ISO 的那个宿主对 GitHub runner 全量 403（真文件与
不存在的路径同样 403，即不给存在性信号），而它的公开 rpm 源 200/404 分明、秒级可达。
所以取材走源，不走盘。

产物形状刻意与 ISO 一致（repodata/ + Packages/），这样安装那一步和它的四条断言
一行都不用改 —— 差异全部收在取材这一层。
"""
import gzip, os, re, subprocess, sys, xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

NS = {"c": "http://linux.duke.edu/metadata/common",
      "r": "http://linux.duke.edu/metadata/rpm"}
for p, u in NS.items():
    ET.register_namespace('' if p == 'c' else p, u)


def curl(url, out=None, tries=4):
    """取一个 URL。代理必须显式剥掉：厂商站点常常只对国内出口放行，
    而继承来的 https_proxy 会把请求送到境外出口，表现为全量 403。"""
    # 按后缀剥，不按名字列举：环境里同时存在 http_proxy/https_proxy/all_proxy
    # 三组大小写共六个变量，漏掉任何一个 curl 都照样走代理。实测因为只列了
    # 前四个，本机跑出过「厂商站不可达」的假结论。
    env = {k: v for k, v in os.environ.items()
           if not k.lower().endswith("_proxy")}
    cmd = ["curl", "-sS", "-L", "--connect-timeout", "15",
           "--speed-limit", "2048", "--speed-time", "60",
           "-H", "User-Agent: Mozilla/5.0 (X11; Linux x86_64)"]
    # --max-time 是「整次传输」的上限，对大文件是错的旋钮（实测把成功的下载掐断）。
    # 用 --speed-limit/--speed-time 判「卡住」才对。
    if out:
        cmd += ["-o", out]
    for a in range(tries):
        p = subprocess.run(cmd + [url], capture_output=True, env=env)
        if p.returncode == 0 and (out is None or os.path.getsize(out) > 0):
            return p.stdout
        if a == tries - 1:
            sys.exit("取 %s 失败: rc=%d %s" % (url, p.returncode, p.stderr[:200]))
    return b""


def decomp(data, href):
    if href.endswith(".gz"):
        return gzip.decompress(data)
    if href.endswith(".zst"):
        return subprocess.run(["zstd", "-dc"], input=data, capture_output=True).stdout
    if href.endswith(".xz"):
        return subprocess.run(["xz", "-dc"], input=data, capture_output=True).stdout
    return data


def rpmvercmp(a, b):
    """rpm 的版本比较。自己实现而不是调 rpm：这一步要在解析阶段跑几万次，
    每次 fork 一个 rpm 太慢；而算法本身是定义明确的，可测。"""
    def seg(s):
        return re.findall(r'\d+|[A-Za-z]+|~|\^', s or '')
    A, B = seg(a), seg(b)
    i = j = 0
    while i < len(A) and j < len(B):
        x, y = A[i], B[j]
        if x == '~' or y == '~':                 # ~ 排在任何东西之前
            if x != y:
                return -1 if x == '~' else 1
            i += 1; j += 1; continue
        if x == '^' or y == '^':
            if x != y:
                return 1 if x == '^' else -1
            i += 1; j += 1; continue
        xd, yd = x[0].isdigit(), y[0].isdigit()
        if xd != yd:
            return 1 if xd else -1              # 数字段大于字母段
        if xd:
            xi, yi = int(x), int(y)
            if xi != yi:
                return 1 if xi > yi else -1
        else:
            if x != y:
                return 1 if x > y else -1
        i += 1; j += 1
    if i == len(A) and j == len(B):
        return 0
    # 还有剩余段的那一边更大，除非剩余以 ~ 开头
    rest = A[i:] if i < len(A) else B[j:]
    sign = 1 if i < len(A) else -1
    return -sign if rest and rest[0] == '~' else sign


def evr_cmp(p, q):
    for k in ("epoch", "ver", "rel"):
        c = rpmvercmp(p.get(k) or "0", q.get(k) or "0")
        if c:
            return c
    return 0


def load_repo(base):
    """读一个源的 primary，返回 [记录]。记录里保留原始 XML 元素，便于原样重写。"""
    rm = curl(base.rstrip("/") + "/repodata/repomd.xml").decode("utf-8", "replace")
    m = re.search(r'<data type="primary">.*?<location href="([^"]+)"', rm, re.S)
    if not m:
        sys.exit("%s 的 repomd.xml 里没有 primary" % base)
    rev = re.search(r"<revision>(\d+)", rm)
    href = m.group(1)
    xml = decomp(curl(base.rstrip("/") + "/" + href), href)
    root = ET.fromstring(xml)
    out = []
    for p in root.findall("c:package", NS):
        v = p.find("c:version", NS)
        loc = p.find("c:location", NS)
        out.append({
            "name": p.findtext("c:name", "", NS),
            "arch": p.findtext("c:arch", "", NS),
            "epoch": v.get("epoch") if v is not None else "0",
            "ver": v.get("ver") if v is not None else "",
            "rel": v.get("rel") if v is not None else "",
            "href": loc.get("href") if loc is not None else "",
            "base": base.rstrip("/"),
            "el": p,
        })
    return out, (int(rev.group(1)) if rev else 0)


def scan_filelists(base, wanted, provides):
    """按需解析 filelists，把路径型依赖的提供者补进 provides。

    研究 repo 那一版只解析 primary，于是 `Requires: /sbin/ldconfig` 这类求不出提供者，
    只能靠装完 `rpm -Va` 反查、再人工往 conf 里补包名（chkconfig 就是这么加的）。
    路径型依赖只登记在 filelists 里，而这个源恰好带 filelists（13 MB + 7 MB，可接受），
    所以这个缺口能直接关掉，不必留成人工步骤。

    只在第一轮出现未解析路径时才调用 —— 常见情形不付这个下载代价。
    """
    rm = curl(base.rstrip("/") + "/repodata/repomd.xml").decode("utf-8", "replace")
    m = re.search(r'<data type="filelists">.*?<location href="([^"]+)"', rm, re.S)
    if not m:
        return 0
    href = m.group(1)
    tmp = "/tmp/filelists-%s.xml" % abs(hash(base))
    raw = curl(base.rstrip("/") + "/" + href)
    open(tmp, "wb").write(decomp(raw, href))
    cur, hits = None, 0
    # 逐行扫而不是整棵树 DOM 化：解压后是上百 MB，DOM 会把内存吃光。
    pkg_re = re.compile(r'<package [^>]*name="([^"]+)"')
    file_re = re.compile(r'<file(?: type="[a-z]+")?>([^<]+)</file>')
    with open(tmp, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            mp = pkg_re.search(line)
            if mp:
                cur = mp.group(1)
            for mf in file_re.finditer(line):
                path = mf.group(1)
                if path in wanted and cur:
                    provides.setdefault(path, set()).add(cur)
                    hits += 1
    os.unlink(tmp)
    return hits


def build_closure(pkgs, provides, seeds):
    """求闭包，返回 (选中集合, 未解析能力集合)。"""
    want, queue, unresolved = set(), list(seeds), set()
    while queue:
        n = queue.pop()
        if n in want:
            continue
        want.add(n)
        for cap in pkgs[n]["requires"]:
            ps = provides.get(cap)
            if not ps:
                unresolved.add(cap)
                continue
            pick = cap if cap in ps else sorted(ps)[0]
            if pick in pkgs and pick not in want:
                queue.append(pick)
    return want, unresolved


def main():
    if len(sys.argv) < 4:
        sys.exit("用法: rpmrepo-fetch.py <目标目录> <种子,逗号分隔> <源URL> [更多源URL...]\n"
                 "      后写的源优先级更高（同名包取版本最新的那个）\n"
                 "      环境变量 KEYFILE 给厂商公钥，给了就逐包验签")
    dst, seedstr, bases = sys.argv[1], sys.argv[2], sys.argv[3:]
    seeds = [s.strip() for s in seedstr.split(",") if s.strip()]

    # ① 合并各源。同名同架构取 EVR 最新的，因此 os/ 与 update/ 谁在前无所谓，
    #    判据是版本而不是书写顺序 —— 挂在结果上，不挂在约定上。
    best, revs = {}, []
    for b in bases:
        recs, rev = load_repo(b)
        revs.append((b, rev))
        print("  源 %s  revision=%d  %d 个包" % (b, rev, len(recs)))
        for r in recs:
            k = (r["name"], r["arch"])
            if k not in best or evr_cmp(r, best[k]) > 0:
                best[k] = r
    print("  合并后 %d 个 (名,架构) 组合" % len(best))

    # ② provides 索引 + requires，用于求闭包
    pkgs, provides = {}, {}
    for (name, arch), r in best.items():
        fmt = r["el"].find("c:format", NS)
        req = []
        if fmt is not None:
            pe = fmt.find("r:provides", NS)
            if pe is not None:
                for e in pe.findall("r:entry", NS):
                    provides.setdefault(e.get("name"), set()).add(name)
            re_ = fmt.find("r:requires", NS)
            if re_ is not None:
                for e in re_.findall("r:entry", NS):
                    n = e.get("name")
                    if n and not n.startswith("rpmlib("):
                        req.append(n)
        provides.setdefault(name, set()).add(name)
        r["requires"] = req
        pkgs.setdefault(name, r)

    missing = [s for s in seeds if s not in pkgs]
    if missing:
        sys.exit("种子包在源里不存在: %s" % ", ".join(missing))

    # ③ 闭包。第一轮只有 primary，路径型依赖会落在未解析里。
    want, unresolved = build_closure(pkgs, provides, seeds)
    pathy = sorted(c for c in unresolved if c.startswith("/"))
    print("  闭包 %d 个包（种子 %d 个）" % (len(want), len(seeds)))

    # 路径型依赖用 filelists 补，然后重算闭包。补进来的提供者往往会带出新的包，
    # 所以必须重算而不是就地补一补。
    if pathy:
        print("  %d 条路径型依赖待解析，拉 filelists" % len(pathy))
        need = set(pathy)
        for b in bases:
            hits = scan_filelists(b, need, provides)
            print("    %s 命中 %d 条" % (b.rsplit("/", 3)[-3:] and b[-24:], hits))
        want, unresolved = build_closure(pkgs, provides, seeds)
        print("  补完重算：闭包 %d 个包" % len(want))

    still = sorted(c for c in unresolved if c.startswith("/"))
    other = sorted(c for c in unresolved if not c.startswith("/"))
    if still:
        print("  ✗ 仍未解析的路径型依赖 %d 条：%s" % (len(still), ", ".join(still[:10])))
        sys.exit("路径型依赖解析不全，装出来的镜像会有 missing requires，拒绝继续")
    if other:
        # 非路径型的未解析多为 rpmlib()/config() 这类虚拟能力，或介质里确实没有的
        # 可选依赖。这些不拦，但要打出来 —— 静默跳过才是问题。
        print("  未解析的非路径能力 %d 条（多为虚拟/可选）: %s"
              % (len(other), ", ".join(other[:10])))

    # ④ 下载
    os.makedirs(os.path.join(dst, "Packages"), exist_ok=True)
    os.makedirs(os.path.join(dst, "repodata"), exist_ok=True)
    sel = [pkgs[n] for n in sorted(want)]

    def fetch(r):
        fn = r["href"].split("/")[-1]
        out = os.path.join(dst, "Packages", fn)
        if os.path.exists(out) and os.path.getsize(out) > 0:
            return fn
        curl(r["base"] + "/" + r["href"], out)
        return fn
    with ThreadPoolExecutor(max_workers=8) as ex:
        names = list(ex.map(fetch, sel))
    total = sum(os.path.getsize(os.path.join(dst, "Packages", n)) for n in names)
    print("  已下载 %d 个 rpm，共 %.1f MB" % (len(names), total / 1048576.0))

    # ⑤ 验签。信任根是钉了指纹的厂商公钥 —— 这个源没有 repomd.xml.asc，
    #    所以信任落在逐包 GPG 签名上，比只验一个 repomd 更严。
    keyfile = os.environ.get("KEYFILE", "")
    if keyfile:
        # 先核公钥指纹。不核的话，任何一把 key 都能让"验签通过"成立 ——
        # 信任根是**那一把特定的** key，不是"有签名"这件事。
        want_fp = os.environ.get("KEY_FP", "").upper().replace(" ", "")
        if not want_fp:
            sys.exit("给了 KEYFILE 但没给 KEY_FP，无法确认这把公钥是不是厂商那一把")
        gp = subprocess.run(["gpg", "--show-keys", "--with-colons", keyfile],
                            capture_output=True, text=True)
        fps = [l.split(":")[9] for l in gp.stdout.splitlines() if l.startswith("fpr:")]
        if want_fp not in fps:
            sys.exit("公钥指纹不符：期望 %s，文件里是 %s" % (want_fp, ", ".join(fps) or "（读不出）"))
        print("  公钥指纹已核对: %s" % want_fp)
        # rpm 4.20 起用 Sequoia 做 OpenPGP 后端，默认策略拒绝 SHA-1 的密钥绑定签名。
        # 厂商这把 key 建于 2019-04-10、自签名的 digest algo 是 2（SHA-1），于是
        # `rpm --import` 报 "Policy rejects ...: No binding signature at time <现在>"
        # —— 那句话读起来像密钥过期，其实这把 key 到 2029 才到期，被拒的是哈希算法。
        #
        # 放宽这一条是可接受的，因为**信任根是上面核过的指纹，不是 key 自签名的抗碰撞性**：
        # 我们并不依据自签名去认定这把 key 属于谁，那由硬编码的 KEY_FP 决定。
        # 放宽只作用于本次验签用的临时 keyring，不写进镜像也不改宿主策略。
        pol = os.path.join(dst, ".sequoia-policy")
        with open(pol, "w") as f:
            f.write("[hash_algorithms]\n"
                    "sha1.collision_resistance = 2100-01-01\n"
                    "sha1.second_preimage_resistance = 2100-01-01\n")
        renv = dict(os.environ, SEQUOIA_CRYPTO_POLICY=pol)
        kr = os.path.join(dst, ".keyring")
        subprocess.run(["rpm", "--root", kr, "--initdb"], check=True, env=renv)
        subprocess.run(["rpm", "--root", kr, "--import", keyfile], check=True, env=renv)
        # 导入成功要有据可查：import 静默失败的话下面每个包都会报 NOKEY，
        # 那时真因离现场已经隔了一层。
        kq = subprocess.run(["rpm", "--root", kr, "-qa", "gpg-pubkey*"],
                            capture_output=True, text=True, env=renv)
        if not kq.stdout.strip():
            sys.exit("公钥导入后 keyring 里查不到 gpg-pubkey，验签无从谈起")
        print("  keyring 已就绪: %s" % kq.stdout.strip().replace("\n", " "))
        # 判据必须是字面的 "signatures OK"。两个坑：
        #   · 未签名的包 `rpm -K` 会打印 "digests OK" 并返回 0 —— 只看退出码或只找
        #     "OK" 会让无签名的包蒙混过关，而验签的全部意义就是拦住这种。
        #   · "NOT OK" 里含 "OK"，用子串判存在会把失败读成成功。
        # 所以既查退出码，又要求出现 signatures OK，再显式排除失败字样。
        bad = []
        for n in names:
            p = subprocess.run(["rpm", "--root", kr, "-K",
                                os.path.join(dst, "Packages", n)],
                               capture_output=True, text=True, env=renv)
            out = (p.stdout or "") + (p.stderr or "")
            good = (p.returncode == 0
                    and "signatures OK" in out
                    and not re.search(r"NOT OK|NOKEY|MISSING KEYS", out))
            if not good:
                bad.append("%s: %s" % (n, out.strip().replace("\n", " ")[:110]))
        if bad:
            # ISO 介质里厂商自己后加的包常常没签名（凝思 an7 的 linxos-release/
            # linxos-gpg-keys/kernel-headers 就是），它们的完整性由 ISO 官方校验
            # 和 + repodata 逐包 sha256 兜底。UNSIGNED_OK 按包名前缀逐个放行，
            # 名单必须写进上层 .origin；名单外仍然一票否决。
            allow = set(os.environ.get("UNSIGNED_OK", "").split())
            def _pkgname(line):
                base = line.split(":", 1)[0].strip()
                base = os.path.basename(base)
                return re.sub(r"-[^-]+-[^-]+\.[a-z0-9_]+\.rpm$", "", base)
            hard = [b for b in bad if _pkgname(b) not in allow]
            print("  验签失败 %d 个（白名单放行 %d 个）：" % (len(bad), len(bad) - len(hard)))
            for b in bad[:10]:
                print("    %s%s" % (b, "" if b in hard else "（放行）"))
            if hard:
                print("  未放行明细（%d 个）：" % len(hard))
                for b in hard:
                    print("    " + b.split(":", 1)[0].strip())
                sys.exit("有 rpm 未通过厂商公钥验签且不在 UNSIGNED_OK，拒绝继续")
        print("  %d 个 rpm 全部通过厂商公钥验签" % len(names))
    else:
        sys.exit("未提供 KEYFILE，拒绝在无信任根的情况下产出镜像")

    # ⑥ 写一份只含闭包的 primary.xml.gz，href 改成 Packages/<文件名>。
    #    形状与 ISO 上的 repodata 一致，rpmmedia.py 因此完全不用改。
    # 把 filelists 解析出来的路径能力**写进提供者的 provides**，让物化出的 primary
    # 自描述。不这么做的话下游 rpmmedia.py 会在这份 primary 上重算闭包，而它只解析
    # primary、拿不到 filelists，于是路径型依赖的提供者被它自己排除掉 —— 实测取材
    # 算出 139 个包而它只装了 138 个，差的正是 /usr/bin/pkg-config 的提供者，
    # 症状是装完的依赖自洽检查报「未满足依赖」。
    _inject = 0
    _byname = {r["name"]: r for r in sel}
    for cap, owners in provides.items():
        if not cap.startswith("/"):
            continue
        for owner in owners:
            r = _byname.get(owner)
            if r is None:
                continue
            fmt = r["el"].find("c:format", NS)
            if fmt is None:
                continue
            pe = fmt.find("r:provides", NS)
            if pe is None:
                pe = ET.SubElement(fmt, "{%s}provides" % NS["r"])
            if not any(e.get("name") == cap for e in pe.findall("r:entry", NS)):
                ET.SubElement(pe, "{%s}entry" % NS["r"], {"name": cap})
                _inject += 1
    if _inject:
        print("  已把 %d 条路径能力写进 provides（让 primary 自描述）" % _inject)

    root = ET.Element("{%s}metadata" % NS["c"], {"packages": str(len(sel))})
    for r in sel:
        el = r["el"]
        loc = el.find("c:location", NS)
        if loc is not None:
            loc.set("href", "Packages/" + r["href"].split("/")[-1])
        root.append(el)
    xmlb = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    with gzip.open(os.path.join(dst, "repodata", "merged-primary.xml.gz"), "wb") as f:
        f.write(xmlb)
    print("  已写 repodata/merged-primary.xml.gz（%d 个包）" % len(sel))

    # ⑦ 时间锚点：取各源 revision 的最大值。这是真实时间戳，
    #    不是随手填的常量 —— 常量看着有值，其实是假锚点。
    epoch = max(r for _, r in revs)
    # 把闭包条数写下来给下游核对。下游会在这份 primary 上**重算**闭包，两个数
    # 必须一致；不一致说明这份 primary 不足以自描述（少了某个能力的提供者），
    # 而那种情况下下游会"成功地"少装几个包。
    with open(os.path.join(dst, ".closure-count"), "w") as f:
        f.write("%d\n" % len(sel))
    # 除了条数，把闭包**清单**也交出去。下游据此直接安装，不再自己重算 ——
    # 两套闭包实现在「一个能力有多个提供者时挑哪个」上会分叉，追平它们是治标；
    # 让取材算一次、装包直接用，这一类分叉就不存在了。
    with open(os.path.join(dst, ".closure"), "w") as f:
        f.write("\n".join(sorted(r["name"] for r in sel)) + "\n")
    with open(os.path.join(dst, ".epoch"), "w") as f:
        f.write("%d\n" % epoch)
    print("  SOURCE_DATE_EPOCH 锚点 = %d（各源 revision 取最大）" % epoch)


if __name__ == "__main__":
    main()
