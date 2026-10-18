#!/usr/bin/env python3
"""Writes Credits.html: the licences of the third-party code inside Readout.

The standard About panel (Readout ▸ About Readout) shows Credits.html from the
app's Resources. The web bundle is minified without its legal comments
(web/build.mjs), so this file is where those notices live.

usage: tools/credits.py --out PATH [--checkouts DIR]

  Web: every production package in web/package-lock.json (not dev; not the
       esbuild bundler and its binaries, nor @types/* declarations, which ship
       no code), with the licence files from web/node_modules (run npm ci first).
  Swift: every package pinned in Packages/ReadoutCore/Package.resolved, with the
       licence files from the package checkouts (DIR, default: Xcode's
       SourcePackages/checkouts next to the build products, or SwiftPM's
       .build/checkouts).

Fails when a package's licence text cannot be found: a notice is never left out.
`production_packages()` is also what tools/smoke-assert.py checks the file against.
"""
import argparse
import html
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "web" / "package-lock.json"
RESOLVED = ROOT / "Packages" / "ReadoutCore" / "Package.resolved"
LICENCE_PREFIXES = ("license", "licence", "copying", "notice")


def is_shipped(name: str, meta: dict) -> bool:
    if meta.get("dev") or meta.get("devOptional"):
        return False
    # The bundler and its platform binaries, and type declarations: not in the app.
    return not (name == "esbuild" or name.startswith("@esbuild/") or name.startswith("@types/"))


def npm_packages() -> list:
    """(name, version, licence id, folder) of every production npm package."""
    lock = json.loads(LOCK.read_text())
    out = []
    for key, meta in sorted(lock.get("packages", {}).items()):
        if not key.startswith("node_modules/"):
            continue
        name = key.rsplit("node_modules/", 1)[1]
        if not is_shipped(name, meta):
            continue
        # Optional packages for another platform are not installed (and not shipped).
        if meta.get("optional") and not (ROOT / "web" / key).is_dir():
            continue
        out.append((name, meta.get("version", "?"), meta.get("license", ""), ROOT / "web" / key))
    return out


def swift_packages() -> list:
    """(identity, version, location) of every pinned Swift package."""
    pins = json.loads(RESOLVED.read_text()).get("pins", [])
    return [(p["identity"], p.get("state", {}).get("version") or p.get("state", {}).get("revision", "?")[:12], p.get("location", ""))
            for p in sorted(pins, key=lambda p: p["identity"])]


def production_packages() -> list:
    """Every name Credits.html must mention."""
    return sorted({n for n, *_ in npm_packages()} | {i for i, *_ in swift_packages()})


def licence_texts(folder: Path) -> list:
    if not folder.is_dir():
        return []
    files = sorted(f for f in folder.iterdir() if f.is_file() and f.name.lower().startswith(LICENCE_PREFIXES))
    return [(f.name, f.read_text(errors="replace").strip()) for f in files]


def find_checkouts(given):
    candidates = [Path(given)] if given else []
    build_dir = os.environ.get("BUILD_DIR")
    if build_dir:
        candidates.append(Path(build_dir).parent.parent / "SourcePackages" / "checkouts")
    candidates += [ROOT / "build" / "SourcePackages" / "checkouts", ROOT / "Packages" / "ReadoutCore" / ".build" / "checkouts"]
    for c in candidates:
        if c.is_dir():
            return c
    sys.exit(f"credits: no Swift package checkouts in {[str(c) for c in candidates]}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--checkouts")
    args = ap.parse_args()

    entries = []   # (title, subtitle, [(file, text)])
    missing = []
    checkouts = find_checkouts(args.checkouts)
    for identity, version, location in swift_packages():
        texts = licence_texts(checkouts / identity)
        if not texts:
            missing.append(f"{identity} (Swift, in {checkouts / identity})")
        entries.append((identity, f"{version} · {location}", texts))
    for name, version, spdx, folder in npm_packages():
        texts = licence_texts(folder)
        if not texts:
            missing.append(f"{name} (npm, in {folder})")
        entries.append((name, f"{version}" + (f" · {spdx}" if spdx else ""), texts))
    if missing:
        sys.exit("credits: no licence text for " + ", ".join(missing))

    # Packages with the very same licence text (one project's packages) share it.
    groups = {}
    for title, sub, texts in entries:
        key = tuple(t for _, t in texts)
        groups.setdefault(key, []).append((title, sub))
    parts = ["<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>",
             "body{font:11px -apple-system,'Helvetica Neue',sans-serif}",
             "h3{font-size:11px;margin:14px 0 2px}p{margin:0;color:#666}",
             "pre{font:9px Menlo,monospace;white-space:pre-wrap;margin:4px 0 0}",
             "</style></head><body>",
             "<p>Readout includes the following third-party software.</p>"]
    for texts, packages in groups.items():
        names = ", ".join(html.escape(t) for t, _ in packages)
        subs = "; ".join(html.escape(f"{t} {s}") for t, s in packages)
        parts.append(f"<h3>{names}</h3><p>{subs}</p>")
        for text in texts:
            parts.append(f"<pre>{html.escape(text)}</pre>")
    parts.append("</body></html>")
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(parts) + "\n")
    print(f"credits: {len(entries)} packages ({len(groups)} licence texts) -> {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
