#!/usr/bin/env python3
"""把各测试 job 的 JSON 结果合并成一份报告。

用法: render-report.py <结果目录> [--baseline N] [--out report.md]

之所以要在这里再对一次「检查总数基线」：拆成一个镜像一个 job 之后，
verify.sh 里那道基线断言对每个子集都失去了意义（子集当然低于全量基线），
而它防的是「检查项被静默跳过」——这类缺陷本项目踩过好几种，
失败数为 0 与检查压根没跑，在汇总里长得一模一样。
防线不能因为拆分而消失，只能上移到能看见全局的这一层。
"""
import argparse, json, pathlib, sys

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir")
    ap.add_argument("--baseline", type=int, default=0,
                    help="全部 job 的检查总数下限；0 表示不校验")
    ap.add_argument("--expected", type=int, default=0,
                    help="应当收到的结果数；0 表示不校验。这比检查总数基线更精确——"
                         "某个 job 在跑到 verify 之前就挂掉时不会产出结果，"
                         "检查总数会「合法地」变低而基线放过它，但结果数对不上会被抓住")
    ap.add_argument("--out", default="")
    a = ap.parse_args()

    files = sorted(pathlib.Path(a.results_dir).rglob("*.json"))
    rows, bad_files = [], []
    for f in files:
        try:
            rows.append(json.loads(f.read_text()))
        except Exception as e:
            bad_files.append(f"{f.name}: {e}")

    rows.sort(key=lambda r: (r.get("distro", ""), r.get("arch", ""), r.get("tiers", "")))
    tot_pass = sum(r.get("pass", 0) for r in rows)
    tot_fail = sum(r.get("fail", 0) for r in rows)
    tot_warn = sum(r.get("warn", 0) for r in rows)
    tot_all = sum(r.get("total", 0) for r in rows)

    L = ["# 镜像测试报告", ""]
    L.append(f"共 **{len(rows)}** 个镜像，检查 **{tot_all}** 项："
             f"通过 **{tot_pass}**，失败 **{tot_fail}**，警告 **{tot_warn}**。")
    L += ["", "| 版本 | 架构 | 档位 | 通过 | 失败 | 警告 | 结果 |", "|---|---|---|---|---|---|---|"]
    for r in rows:
        ok = "✅" if r.get("fail", 0) == 0 else "❌"
        L.append(f"| {r.get('distro','?')} | {r.get('arch','?')} | {r.get('tiers','?')} | "
                 f"{r.get('pass',0)} | {r.get('fail',0)} | {r.get('warn',0)} | {ok} |")

    probs = [(r, p) for r in rows for p in r.get("problems", []) if p]
    if probs:
        L += ["", "## 未通过的检查", ""]
        for r, p in probs:
            L.append(f"- `{r.get('distro')}/{r.get('arch')}/{r.get('tiers')}` {p}")

    exit_code = 0
    notes = []
    # 一个都没收到，说明上游全挂或制品名对不上——这与「全部通过」必须区分开，
    # 否则空报告会被读成大获全胜。
    if not rows:
        notes.append("❌ **没有收到任何结果**。上游测试 job 可能全部失败，或制品名不匹配。")
        exit_code = 1
    if bad_files:
        notes.append("❌ 有结果文件解析失败：" + "；".join(bad_files))
        exit_code = 1
    if a.expected and len(rows) != a.expected:
        notes.append(f"❌ **收到 {len(rows)} 份结果，应为 {a.expected} 份**。"
                     f"缺的那些 job 多半在跑到检查之前就失败了——它们不会产出结果，"
                     f"于是检查总数「合法地」变低，只看基线抓不住。")
        exit_code = 1
    if a.baseline and rows and tot_all < a.baseline:
        notes.append(f"❌ **检查总数 {tot_all} 低于基线 {a.baseline}** —— 有检查被静默跳过了。"
                     f"若确为有意缩减，请同步调整调用方传入的 baseline 并在提交里说明。")
        exit_code = 1
    if tot_fail:
        exit_code = 1
    if notes:
        L += ["", "## 汇总层面的问题", ""] + [f"- {n}" for n in notes]

    text = "\n".join(L) + "\n"
    if a.out:
        pathlib.Path(a.out).write_text(text)
    print(text)
    return exit_code

if __name__ == "__main__":
    sys.exit(main())
