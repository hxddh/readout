#!/usr/bin/env python3
"""Writes Acknowledgements.md: the licences of the third-party code inside Readout.

Readout ▸ About Readout links to it (Resources/Acknowledgements.md), and Readout
opens it like any document: its own typesetting, ⌘F. The web bundle is minified
without its legal comments (web/build.mjs), so this file is where those notices live.

usage: tools/credits.py --out PATH [--checkouts DIR]

  Web: every production package in web/package-lock.json (not dev; not the
       esbuild bundler and its binaries, nor @types/* declarations, which ship
       no code), with the licence files from web/node_modules (run npm ci first).
  Swift: every package pinned in Packages/ReadoutCore/Package.resolved, with the
       licence files from the package checkouts (DIR, default: Xcode's
       SourcePackages/checkouts next to the build products, or SwiftPM's
       .build/checkouts).

Fails when a package's licence text cannot be found: a notice is never left out.
`production_packages()` and `unescape()` are also what tools/smoke-assert.py
checks the file with.
"""
import argparse
import json
import os
import re
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
    """Every name Acknowledgements.md must mention."""
    return sorted({n for n, *_ in npm_packages()} | {i for i, *_ in swift_packages()})


# Licence text is prose, not Markdown: every character Markdown (or Readout's
# math) could take as syntax is escaped, so it reads as written.
SPECIAL = re.compile(r"([\\`*_\[\]<>|~$&#])")
LINE_START = re.compile(r"^([-+=])|^(\d+)([.)])")


def escape(text: str) -> str:
    text = SPECIAL.sub(r"\\\1", text)
    return LINE_START.sub(lambda m: "\\" + m[1] if m[1] else m[2] + "\\" + m[3], text)


def unescape(text: str) -> str:
    return re.sub(r"\\([!-/:-@\[-`{-~])", r"\1", text)


def paragraphs(text: str) -> list:
    """The licence's paragraphs, each on one line: hard wraps reflow."""
    return [escape(" ".join(p.split())) for p in re.split(r"\n\s*\n", text) if p.strip()]


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
    parts = ["# Acknowledgements", "", "Readout includes the following third-party software.", ""]
    for texts, packages in groups.items():
        parts += ["## " + escape(", ".join(t for t, _ in packages)), "", escape("; ".join(f"{t} {s}" for t, s in packages)), ""]
        for text in texts:
            for p in paragraphs(text):
                parts += [p, ""]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(parts))
    print(f"credits: {len(entries)} packages ({len(groups)} licence texts) -> {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
