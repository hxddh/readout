#!/usr/bin/env python3
"""DIAG (temporary): launch A/B of several Readout builds under one harness.
Usage: ab-run.py LAUNCHER REPO_ROOT OUT_DIR ROUNDS name=/path/Readout.app ...
Each build is launched once first (discarded: the first launch of a fresh
bundle pays its code-signing assessment and WebKit's first run on the VM),
then ROUNDS times, the builds interleaved. Each launch gets a fresh copy of
the documents, no baselines and no saved windows."""
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

launcher, root, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
rounds = int(sys.argv[4])
builds = [a.split("=", 1) for a in sys.argv[5:]]
BUNDLE = "io.github.hxddh.readout"
home = Path.home()
fixtures = root / "web" / "test" / "fixtures"


def clean_state():
    shutil.rmtree(home / "Library" / "Application Support" / "Readout" / "Baselines", ignore_errors=True)
    shutil.rmtree(home / "Library" / "Saved Application State" / f"{BUNDLE}.savedState", ignore_errors=True)


def launch(name, app, tag):
    d = out / f"{name}-{tag}"
    shutil.rmtree(d, ignore_errors=True)
    docs = d / "docs"
    docs.mkdir(parents=True)
    shutil.copyfile(fixtures / "plan.md", docs / "plan.md")
    shutil.copyfile(fixtures / "missing-diagram.png", docs / "missing-diagram.png")
    shutil.copyfile(root / "web" / "test" / "corpus" / "01-sdd-fix-loop-plan.md", docs / "second.md")
    smoke = d / "smoke"
    smoke.mkdir()
    clean_state()
    env = dict(os.environ, READOUT_SMOKE_FILE=str(docs / "plan.md"), READOUT_SMOKE_OUT=str(smoke),
               READOUT_SMOKE_PASS="ab", READOUT_SMOKE_SECOND=str(docs / "second.md"))
    binary = Path(app) / "Contents" / "MacOS" / "Readout"
    with open(d / "log.txt", "wb") as log:
        subprocess.run([str(launcher), str(binary), str(d / "outer.json")], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=150)
    try:
        outer = json.loads((d / "outer.json").read_text())
        inner = json.loads((smoke / "timings-app.json").read_text())
    except (OSError, ValueError) as e:
        print(f"{name} {tag}: no timings ({e})")
        return None
    ph = inner.get("launch_phases_s", {})
    start = ph.get("process_start", outer["spawn"])
    r = {k: round((v - start) * 1000, 1) for k, v in ph.items() if k != "process_start"}
    r["spawn"] = round((outer["spawn"] - start) * 1000, 1)
    for k in ("window_visible", "any_window"):
        if k in outer:
            r[k] = round((outer[k] - start) * 1000, 1)
    sec = next((v for k, v in inner.get("first_apply_samples_s", {}).items() if k.endswith("/second.md")), [])
    pai = next((v for k, v in inner.get("first_paint_samples_s", {}).items() if k.endswith("/second.md")), [])
    try:
        page = json.loads((smoke / "ab-page.json").read_text())
    except (OSError, ValueError):
        page = {}
    for k in ("apply", "raf", "painted"):
        if page.get(k):
            r[f"page_{k}"] = round(page[k][0] - start * 1000, 1)
    for k in ("hlInitStart", "hlInitDone"):
        if page.get(k):
            r[f"page_{k}"] = round(page[k] - start * 1000, 1)
    if page.get("fcp") and page.get("origin"):
        r["page_fcp"] = round(page["origin"] + page["fcp"] - start * 1000, 1)
    r["hl"] = [[h[0], h[1], round(h[2] - start * 1000), h[3]] for h in page.get("hl", [])[:12]]
    r["warm_applied"] = [round(v * 1000, 1) for v in sec]
    r["warm_painted"] = [round(v * 1000, 1) for v in pai]
    return r


def since_spawn(r, k):
    return r[k] - r["spawn"] if k in r else None


results = {n: [] for n, _ in builds}
for n, app in builds:
    r = launch(n, app, "boot")
    print(f"BOOT {n}: {json.dumps(r, sort_keys=True)}")
for i in range(rounds):
    order = builds if i % 2 == 0 else list(reversed(builds))
    for n, app in order:
        r = launch(n, app, f"r{i}")
        print(f"RUN {n} r{i}: {json.dumps(r, sort_keys=True)}")
        if r:
            results[n].append(r)
        time.sleep(2)

(out / "ab-results.json").write_text(json.dumps(results, indent=1, sort_keys=True))
metrics = [
    ("window_visible", lambda r: since_spawn(r, "window_visible")),
    ("window_init", lambda r: since_spawn(r, "window_init")),
    ("did_load", lambda r: since_spawn(r, "did_load")),
    ("page_ready", lambda r: since_spawn(r, "page_ready")),
    ("first_paint", lambda r: since_spawn(r, "paint")),
    ("window_to_load", lambda r: r["did_load"] - r["window_init"] if "did_load" in r and "window_init" in r else None),
    ("cold_apply", lambda r: r["apply"] - max(r["page_ready"], r["did_load"]) if all(k in r for k in ("apply", "page_ready", "did_load")) else None),
    ("warm_applied_min", lambda r: min(r["warm_applied"]) if len(r["warm_applied"]) == 3 else None),
    ("warm_applied_1st", lambda r: r["warm_applied"][0] if r["warm_applied"] else None),
    ("warm_painted_med", lambda r: sorted(r["warm_painted"])[1] if len(r["warm_painted"]) == 3 else None),
]
print("\nAB SUMMARY (ms since spawn unless noted; median [min-max] of rounds)")
print("metric".ljust(20) + "".join(n.rjust(26) for n, _ in builds))
for m, f in metrics:
    row = m.ljust(20)
    for n, _ in builds:
        vals = [v for v in (f(r) for r in results[n]) if v is not None]
        row += (f"{statistics.median(vals):.0f} [{min(vals):.0f}-{max(vals):.0f}]" if vals else "-").rjust(26)
    print(row)
print("\nAB PHASES (median ms since process start)")
keys = sorted({k for n, _ in builds for r in results[n] for k, v in r.items() if isinstance(v, (int, float))},
              key=lambda k: statistics.median([r[k] for n, _ in builds for r in results[n] if k in r]))
for k in keys:
    row = k.ljust(22)
    for n, _ in builds:
        vals = [r[k] for r in results[n] if k in r]
        row += (f"{statistics.median(vals):.0f}" if vals else "-").rjust(12)
    print(row)
