#!/usr/bin/env python3
"""The Perf A/B workflow's table (.github/workflows/perf-ab.yml).

usage: tools/perf-ab-table.py OUT_DIR TITLE

OUT_DIR holds N-A.json / N-B.json, one per run. Every numeric metric: each
side's median and runs, B's median over A's, and a verdict for B: "ok" when
its median is at most A's x 1.03 or within A's run-to-run range (the parity
rule for a PR), "worse" otherwise (metrics where lower is better; counts of
0 against 0 are "ok").
"""
import json
import statistics
import sys
from pathlib import Path

out, title = Path(sys.argv[1]), sys.argv[2]
runs = {"A": [], "B": []}
for f in sorted(out.glob("*.json"), key=lambda p: int(p.stem.split("-")[0])):
    try:
        runs[f.stem.split("-")[1]].append(json.loads(f.read_text()))
    except (ValueError, IndexError, KeyError) as e:
        print(f"<!-- {f.name}: {e} -->")

keys = []
for r in runs["A"] + runs["B"]:
    for k, v in r.items():
        if isinstance(v, (int, float)) and not isinstance(v, bool) and k not in keys:
            keys.append(k)

def nums(side, k):
    return [r[k] for r in runs[side] if isinstance(r.get(k), (int, float)) and not isinstance(r.get(k), bool)]

print(f"\n### {title}: A ({len(runs['A'])} runs), B ({len(runs['B'])} runs)\n")
print("| metric | A median | B median | B/A | B | A runs | B runs |")
print("|---|---|---|---|---|---|---|")
for k in keys:
    a, b = nums("A", k), nums("B", k)
    ma = statistics.median(a) if a else None
    mb = statistics.median(b) if b else None
    ratio = f"{mb / ma:.2f}" if ma and mb is not None else "-"
    verdict = "-"
    if a and b:
        verdict = "ok" if mb <= ma * 1.03 or min(a) <= mb <= max(a) or mb <= min(a) else "worse"
    print(f"| {k} | {ma} | {mb} | {ratio} | {verdict} | {', '.join(map(str, a))} | {', '.join(map(str, b))} |")
for side in runs:
    for i, r in enumerate(runs[side]):
        if r.get("errors"):
            print(f"\n{side} run {i + 1} errors: {r['errors']}")
