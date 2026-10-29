#!/usr/bin/env python3
"""Checks measured speed against tools/perf-budgets.json.

usage: tools/perf-assert.py WHERE RESULTS.json [RESULTS.json ...]
  WHERE: mac | linux-webkit (only that environment's budgets are checked)

Result files are flat JSON objects of metric -> number, or (core tests)
metric -> {"ms": number, ...}. Fails when a gated metric (a guard, and not
"gated": false) is missing or over its guard. Prints every metric with its
target and guard; a tracked metric over its guard is reported, not failed.
"""
import json
import sys
from pathlib import Path

budgets = json.loads((Path(__file__).parent / "perf-budgets.json").read_text())
where, files = sys.argv[1], sys.argv[2:]
measured = {}
for f in files:
    try:
        data = json.loads(Path(f).read_text())
    except (OSError, ValueError) as e:
        print(f"FAIL: cannot read {f}: {e}")
        sys.exit(1)
    for k, v in data.items():
        if isinstance(v, dict) and "ms" in v:
            v = v["ms"]
        if isinstance(v, (int, float)):
            measured[k] = v

failures = 0
for name, b in budgets.items():
    if name.startswith("_") or b["where"] != where:
        continue
    v = measured.get(name)
    target, guard, unit = b.get("target"), b.get("guard"), b.get("unit", "ms")
    gated = guard is not None and b.get("gated", True)
    limits = f"target {target if target is not None else '-'}, guard {guard if guard is not None else 'not set'}{'' if gated or guard is None else ', tracked'}"
    if v is None:
        if gated:
            failures += 1
            print(f"FAIL: {name} was not measured ({limits})")
        else:
            print(f"--: {name} not measured ({limits})")
        continue
    if guard is not None and v > guard:
        failures += gated
        print(f"{'FAIL' if gated else 'tracked, over its guard'}: {name} = {v} {unit} ({limits})")
    elif target is not None and v <= target:
        print(f"ok: {name} = {v} {unit}, meets target ({limits})")
    else:
        print(f"tracked: {name} = {v} {unit} ({limits})")
print(f"{failures} perf budget failure(s)")
sys.exit(1 if failures else 0)
