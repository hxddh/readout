#!/usr/bin/env python3
"""DIAG (temporary): puts the same launch A/B harness into a Readout tree
(3.8.0, 3.9.0 or a fix), so every build is measured the same way.

- SmokeTest.run: READOUT_SMOKE_PASS=ab waits for the first paint, then
  (after READOUT_AB_WARM_DELAY s) opens READOUT_SMOKE_SECOND three times,
  writes timings-app.json and quits.
- Extra launch phases (first occurrence only): will_finish_launching (3.8 lacks
  it), menu_built, show_called, wv_init_begin, wv_super_init, wv_load_called.
Usage: apply-ab.py TREE [experiment]
"""
import re
import sys
from pathlib import Path

tree = Path(sys.argv[1])
exp = sys.argv[2] if len(sys.argv) > 2 else ""


def edit(rel, old, new, count=1):
    p = tree / rel
    s = p.read_text()
    if old not in s:
        sys.exit(f"apply-ab: {rel}: not found: {old[:80]!r}")
    p.write_text(s.replace(old, new, count))


AB = '''        Task { @MainActor in
            if ProcessInfo.processInfo.environment["READOUT_SMOKE_PASS"] == "ab" {
                let deadline = Date().addingTimeInterval(40)
                while launchPhases["paint"] == nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
                let env = ProcessInfo.processInfo.environment
                if let second = env["READOUT_SMOKE_SECOND"] {
                    let delay = Double(env["READOUT_AB_WARM_DELAY"] ?? "8") ?? 8
                    try? await Task.sleep(for: .seconds(delay))
                    let app = NSApp.delegate as? AppDelegate
                    let u = URL(fileURLWithPath: second)
                    for round in 1...3 {
                        app?.open(u)
                        let d = Date().addingTimeInterval(10)
                        while (firstPaintSamples[u.path]?.count ?? 0) < round && Date() < d { try? await Task.sleep(for: .milliseconds(20)) }
                        app?.reader(for: u)?.window?.close()
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                writeTimings(out)
                NSApp.terminate(nil)
                return
            }
'''
edit("App/SmokeTest.swift", "        Task { @MainActor in\n", AB)

# Phases.
d = (tree / "App/AppDelegate.swift").read_text()
if 'noteLaunchPhase("will_finish_launching")' not in d:
    edit("App/AppDelegate.swift", "    func applicationWillFinishLaunching(_ notification: Notification) {\n",
         "    func applicationWillFinishLaunching(_ notification: Notification) {\n        SmokeTest.noteLaunchPhase(\"will_finish_launching\")\n")
edit("App/AppDelegate.swift", "    func applicationWillFinishLaunching(_ notification: Notification) {\n",
     "    func applicationWillFinishLaunching(_ notification: Notification) {\n        ReaderWebView.diagPhase = { SmokeTest.noteLaunchPhase($0) }\n")
edit("App/AppDelegate.swift", "        NSApp.mainMenu = MainMenu.build(appDelegate: self)\n",
     "        NSApp.mainMenu = MainMenu.build(appDelegate: self)\n        SmokeTest.noteLaunchPhase(\"menu_built\")\n")
edit("App/ReaderWindowController.swift", "    func show() {\n", "    func show() {\n        SmokeTest.noteLaunchPhase(\"show_called\")\n")
edit("Shared/ReaderWebView.swift", "    init(bundle: Bundle) {\n        let config = WKWebViewConfiguration()\n",
     "    static var diagPhase: (@MainActor (String) -> Void)?\n\n    init(bundle: Bundle) {\n        Self.diagPhase?(\"wv_init_begin\")\n        let config = WKWebViewConfiguration()\n")
edit("Shared/ReaderWebView.swift", "        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)\n",
     "        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)\n        Self.diagPhase?(\"wv_super_init\")\n")
edit("Shared/ReaderWebView.swift", "        load(URLRequest(url: Self.readerURL))\n    }\n\n    @available",
     "        load(URLRequest(url: Self.readerURL))\n        Self.diagPhase?(\"wv_load_called\")\n    }\n\n    @available")

# Experiments on the 3.9 tree.
if exp == "dfl":
    # 3.8's order: the spare page at the start of didFinishLaunching.
    edit("App/AppDelegate.swift", "        WebViewPool.shared.prewarm()\n        SmokeTest.noteLaunchPhase(\"spare_created\")\n", "")
    edit("App/AppDelegate.swift", "        SmokeTest.noteLaunchPhase(\"did_finish_launching\")\n",
         "        SmokeTest.noteLaunchPhase(\"did_finish_launching\")\n        WebViewPool.shared.prewarm()\n        SmokeTest.noteLaunchPhase(\"spare_created\")\n")
elif exp:
    sys.exit(f"apply-ab: unknown experiment {exp}")
print(f"apply-ab: {tree} patched ({exp or 'as is'})")
