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
                try? await Task.sleep(for: .seconds(3))
                if let page = try? await webView.evaluateJavaScript("JSON.stringify(window.__ab || {})") as? String {
                    try? page.data(using: .utf8)?.write(to: out.appendingPathComponent("ab-page.json"))
                }
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

# Page probes (wall clock): each apply, the rAF of the frame after it, the
# 'painted' task, and every highlightSync call (grammar, ms, when, html?).
edit("web/src/reader/patch.js", "  post({ type: 'applied', version: p.version });\n",
     "  (window.__ab ??= { apply: [], raf: [], painted: [], hl: [] }).apply.push(Date.now());\n  post({ type: 'applied', version: p.version });\n")
edit("web/src/reader/patch.js", "  requestAnimationFrame(() => setTimeout(() => {\n",
     "  requestAnimationFrame(() => { window.__ab.raf.push(Date.now()); setTimeout(() => {\n    window.__ab.painted.push(Date.now());\n")
edit("web/src/reader/patch.js", "    post({ type: 'painted', version: p.version });\n  }, 0));\n",
     "    post({ type: 'painted', version: p.version });\n  }, 0); });\n")
edit("web/src/reader/enhance.js", "  const html = hl.highlightSync(code, id);\n",
     "  const abT = performance.now();\n  const html = hl.highlightSync(code, id);\n  if (window.__ab) window.__ab.hl.push([id, Math.round(performance.now() - abT), Date.now(), !!html]);\n")

# The first document's load, on the main thread: started, parsed (result
# back), reading state found, git baseline found.
R = "App/ReaderWindowController.swift"
edit(R, "        let saved = BaselineStore.prefetch(url)\n        loader.loadInitial { [weak self] result in\n",
     "        let saved = BaselineStore.prefetch(url)\n        SmokeTest.noteLaunchPhase(\"load_start\")\n        loader.loadInitial { [weak self] result in\n            SmokeTest.noteLaunchPhase(\"load_result\")\n")
edit(R, "saved.record(forSourcePath: result.sourcePath) { [weak self] record in   // the file this read came from\n",
     "saved.record(forSourcePath: result.sourcePath) { [weak self] record in   // the file this read came from\n                SmokeTest.noteLaunchPhase(\"record\")\n")
edit(R, "CommitBaseline.find(path: result.sourcePath, current: result.decoded.text) { [weak self] keys in\n",
     "CommitBaseline.find(path: result.sourcePath, current: result.decoded.text) { [weak self] keys in\n                    SmokeTest.noteLaunchPhase(\"commit_baseline\")\n")
# How long the developer-tools check takes in the git baseline (app log).
edit(R, "                if !toolsAvailable { toolsAvailable = GitTools.available() }\n",
     "                let abT0 = Date()\n                if !toolsAvailable { toolsAvailable = GitTools.available() }\n                NSLog(\"ABGIT available %.0f ms (%d)\", Date().timeIntervalSince(abT0) * 1000, toolsAvailable ? 1 : 0)\n")
# The page: highlighter init start/end, first contentful paint (the frame
# really painted), read with the rest.
edit("web/src/highlight.js", "  ready = (async () => {\n", "  (window.__ab ??= { apply: [], raf: [], painted: [], hl: [] }).hlInitStart = Date.now();\n  ready = (async () => {\n")
edit("web/src/highlight.js", "    initialized = true;\n", "    initialized = true;\n    window.__ab.hlInitDone = Date.now();\n")
edit("App/SmokeTest.swift", 'evaluateJavaScript("JSON.stringify(window.__ab || {})")',
     'evaluateJavaScript("JSON.stringify(Object.assign(window.__ab || {}, { fcp: (performance.getEntriesByType(\'paint\').find(e => e.name === \'first-contentful-paint\') || {}).startTime, origin: performance.timeOrigin }))")')

# Experiments on the 3.9 tree.
if exp == "dfl":
    # 3.8's order: the spare page at the start of didFinishLaunching.
    edit("App/AppDelegate.swift", "        WebViewPool.shared.prewarm()\n        SmokeTest.noteLaunchPhase(\"spare_created\")\n", "")
    edit("App/AppDelegate.swift", "        SmokeTest.noteLaunchPhase(\"did_finish_launching\")\n",
         "        SmokeTest.noteLaunchPhase(\"did_finish_launching\")\n        WebViewPool.shared.prewarm()\n        SmokeTest.noteLaunchPhase(\"spare_created\")\n")
elif exp in ("f1", "f2"):
    # No spare page at launch: the first window makes its own; the spare is
    # made once that page has painted (WebViewPool.pagePainted).
    edit("App/AppDelegate.swift", "        WebViewPool.shared.prewarm()\n        SmokeTest.noteLaunchPhase(\"spare_created\")\n", "")
    if exp == "f2":
        # And the first window's page starts loading once the window is on screen.
        edit("Shared/ReaderWebView.swift", "    private(set) var isReady = false\n",
             "    private(set) var isReady = false\n    private var pageRequested = false\n    func loadIfNeeded() {\n        guard !pageRequested else { return }\n        pageRequested = true\n        Self.diagPhase?(\"wv_deferred_load\")\n        load(URLRequest(url: Self.readerURL))\n        Self.diagPhase?(\"wv_deferred_load_done\")\n    }\n")
        edit("Shared/ReaderWebView.swift", "    init(bundle: Bundle) {\n        Self.diagPhase", "    init(bundle: Bundle, loadNow: Bool = true) {\n        Self.diagPhase")
        edit("Shared/ReaderWebView.swift", "        load(URLRequest(url: Self.readerURL))\n        Self.diagPhase?(\"wv_load_called\")\n    }\n",
             "        if loadNow { pageRequested = true; load(URLRequest(url: Self.readerURL)) }\n        Self.diagPhase?(\"wv_load_called\")\n    }\n")
        edit("App/ReaderWindowController.swift", "        let w = spare ?? ReaderWebView(bundle: .main)\n", "        let w = spare ?? ReaderWebView(bundle: .main, loadNow: false)\n")
        edit("App/ReaderWindowController.swift", "        showWindow(nil)\n        window?.makeFirstResponder(webView)\n",
             "        showWindow(nil)\n        window?.makeFirstResponder(webView)\n        window?.displayIfNeeded()\n        webView.loadIfNeeded()\n")
        edit("App/ReaderWindowController.swift", "                              onRetarget: { [weak self] target in if let self { self.retargeted(to: target) } })\n        load()\n",
             "                              onRetarget: { [weak self] target in if let self { self.retargeted(to: target) } })\n        load()\n        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.webView.loadIfNeeded() }\n")
elif exp:
    sys.exit(f"apply-ab: unknown experiment {exp}")
print(f"apply-ab: {tree} patched ({exp or 'as is'})")
