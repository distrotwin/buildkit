#!/usr/bin/env python3
"""把各镜像的检查结果渲染成**每个系统一份**的 markdown 报告。

用法: render-report.py <结果目录> --out-dir reports [--expected N] [--baseline N]

为什么按系统分文件：三个系统 × 两三个架构 × 三个档位挤在一张表里，列数逼近二十，
在 GitHub 的 job summary 里要横向滚动才能看完，等于没有「一眼看出哪里红了」。
分开之后每份表最多六到九列，屏幕内看得全。

四态用 emoji 表达，颜色与字形双编码：
  ✅ 通过    🟡 期望不通过（conf 的 XFAIL 声明过，不构成失败）
  ❌ 异常    ⚠️ 警告    ⬜ 不适用

「不适用」不是编造的：它等于「本系统全部镜像的检查项并集」减去「该镜像实际记录到的项」。
某一项在某个镜像上没跑过就是不适用，不需要在各处再写一遍判据。
"""
import argparse, json, pathlib, sys

# na 必须显式登记。不登记时它会 fallback 到「未记录」那一支，结果凑巧也是 ⬜，
# 但那是巧合不是设计——一旦以后给 fallback 换个符号，声明过的不适用会跟着变，
# 而两者的含义并不相同：一个是我们主动声明的，一个是推断出来的。
EMOJI = {"pass": "✅", "xpass": "✅", "xfail": "🟡", "fail": "❌", "warn": "⚠️", "na": "⬜"}
NA = "⬜"
TIER_ORDER = {"micro": 0, "base": 1, "devel": 2}


def load(results_dir):
    rows, bad = [], []
    for f in sorted(pathlib.Path(results_dir).rglob("*.json")):
        try:
            rows.append(json.loads(f.read_text()))
        except Exception as e:
            bad.append(f"{f.name}: {e}")
    return rows, bad


def col_key(r):
    return (r.get("arch", ""), TIER_ORDER.get(r.get("tiers", ""), 9))


def render_one(distro, rows):
    rows = sorted(rows, key=col_key)
    cols = [f"{r.get('arch','?')}<br>{r.get('tiers','?')}" for r in rows]

    # 项顺序按出现顺序，让同类检查挨在一起；按字母排会把 apt_check 和 cc_present 混在一处
    names, seen = [], set()
    for r in rows:
        for c in r.get("checks", []):
            n = c.get("name", "")
            if n and n not in seen:
                seen.add(n); names.append(n)

    tot = {k: 0 for k in ("pass", "fail", "warn", "xfail", "xpass")}
    for r in rows:
        for k in tot:
            tot[k] += r.get(k, 0)
    n_fail = tot["fail"]

    L = [f"# {distro} 镜像测试报告", ""]
    L.append(f"{len(rows)} 个镜像，检查 {sum(r.get('total',0) for r in rows)} 项："
             f"✅ 通过 **{tot['pass']}**，❌ 异常 **{n_fail}**，"
             f"🟡 期望不通过 **{tot['xfail']}**，⚠️ 警告 **{tot['warn']}**。")
    L.append("")
    L.append("总体：" + ("**✅ 全部通过**" if n_fail == 0 else f"**❌ 有 {n_fail} 项异常**"))
    L += ["", "## 能力矩阵", "",
          "✅ 通过　🟡 期望不通过（XFAIL，不构成失败）　❌ 异常　⚠️ 警告　⬜ 不适用", "",
          "「不适用」有两种来源：一是脚本主动声明的（理由见下方章节），"
          "二是该项在这个镜像上根本没跑到（如 micro 档没有 apt）。两者在表里同为 ⬜。", ""]

    if not names:
        L += ["> 结果里没有逐项状态，无法出矩阵。", ""]
    else:
        L.append("| 检查项 | " + " | ".join(cols) + " |")
        L.append("|---|" + "---|" * len(cols))
        for n in names:
            cells = []
            for r in rows:
                st = next((c.get("state") for c in r.get("checks", []) if c.get("name") == n), None)
                cells.append(EMOJI.get(st, NA) if st else NA)
            L.append(f"| `{n}` | " + " | ".join(cells) + " |")
        L.append("")

    probs = [(r, p) for r in rows for p in r.get("problems", []) if p]
    if probs:
        L += ["## ❌ 异常明细", ""]
        for r, p in probs:
            L.append(f"- `{r.get('arch')}/{r.get('tiers')}` {p.strip()}")
        L.append("")

    xn = [(r, p) for r in rows for p in r.get("xnotes", []) if p]
    if xn:
        L += ["## 🟡 期望不通过与意外通过", "",
              "意外通过（⚑）不判失败，但说明那条 XFAIL 豁免可以收回——"
              "留着会掩盖以后真正的回归。", ""]
        for r, p in xn:
            L.append(f"- `{r.get('arch')}/{r.get('tiers')}` {p.strip()}")
        L.append("")

    return "\n".join(L) + "\n", n_fail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir")
    ap.add_argument("--out-dir", default="reports")
    ap.add_argument("--expected", type=int, default=0,
                    help="应当收到的结果数。比检查总数基线更精确：某个 job 在跑到检查前就"
                         "挂掉时不产出结果，总数会「合法地」变低而基线放过它")
    ap.add_argument("--baseline", type=int, default=0,
                    help="全部结果的检查总数下限；0 不校验")
    a = ap.parse_args()

    rows, bad = load(a.results_dir)
    out = pathlib.Path(a.out_dir); out.mkdir(parents=True, exist_ok=True)

    by_distro = {}
    for r in rows:
        by_distro.setdefault(r.get("distro", "unknown"), []).append(r)

    exit_code, notes = 0, []
    idx = ["# 测试报告索引", "",
           "每个系统一份独立报告，见下表链接与同名 artifact。", "",
           "| 系统 | 镜像数 | ✅ 通过 | ❌ 异常 | 🟡 期望不通过 | ⚠️ 警告 | 结果 |",
           "|---|---|---|---|---|---|---|"]
    for distro in sorted(by_distro):
        drows = by_distro[distro]
        text, nf = render_one(distro, drows)
        (out / f"report-{distro}.md").write_text(text)
        g = lambda k: sum(r.get(k, 0) for r in drows)
        idx.append(f"| **{distro}** | {len(drows)} | {g('pass')} | {g('fail')} | "
                   f"{g('xfail')} | {g('warn')} | {'✅' if nf == 0 else '❌'} |")
        if nf:
            exit_code = 1

    tot_all = sum(r.get("total", 0) for r in rows)
    # 一个结果都没收到必须单独判失败，否则空报告会被读成大获全胜
    if not rows:
        notes.append("❌ **没有收到任何结果**。上游测试 job 可能全部失败，或制品名不匹配。")
        exit_code = 1
    if bad:
        notes.append("❌ 有结果文件解析失败：" + "；".join(bad))
        exit_code = 1
    if a.expected and len(rows) != a.expected:
        notes.append(f"❌ **收到 {len(rows)} 份结果，应为 {a.expected} 份**。"
                     f"缺的那些 job 多半在跑到检查之前就失败了——它们不会产出结果，"
                     f"于是检查总数「合法地」变低，只看基线抓不住。")
        exit_code = 1
    if a.baseline and rows and tot_all < a.baseline:
        notes.append(f"❌ **检查总数 {tot_all} 低于基线 {a.baseline}** —— 有检查被静默跳过了。")
        exit_code = 1
    if notes:
        idx += ["", "## 汇总层面的问题", ""] + [f"- {n}" for n in notes]

    text = "\n".join(idx) + "\n"
    (out / "summary.md").write_text(text)
    print(text)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
