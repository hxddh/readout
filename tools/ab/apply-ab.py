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


import subprocess
if exp == "web38" or exp.startswith("web="):
    # This tree's app with another commit's page (web/), to tell the app's part from the page's.
    subprocess.run(["git", "-C", str(tree), "checkout", "59acabc" if exp == "web38" else exp[4:], "--", "web"], check=True)


def edit(rel, old, new, count=1):
    p = tree / rel
    s = p.read_text()
    if old not in s:
        if exp.startswith("web=") and rel.startswith("web/"):
            print(f"apply-ab: {rel}: probe not placed: {old[:60]!r}")
            return
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
pj = tree / "web/src/reader/patch.js"
js = pj.read_text()
i = js.index("    post({ type: 'painted', version: p.version });\n")
j = js.index("  }, 0));\n", i)
pj.write_text(js[:j] + "  }, 0); });\n" + js[j + len("  }, 0));\n"):])
edit("web/src/reader/enhance.js", "  const html = hl.highlightSync(code, id);\n",
     "  const abT = performance.now();\n  const html = hl.highlightSync(code, id);\n  if (window.__ab) window.__ab.hl.push([id, Math.round(performance.now() - abT), Date.now(), !!html]);\n")

# The first document's load, on the main thread: started, parsed (result
# back), reading state found, git baseline found.
R = "App/ReaderWindowController.swift"
rw = (tree / R).read_text()
if "        loader.loadInitial { [weak self] result in\n" in rw:
    edit(R, "        loader.loadInitial { [weak self] result in\n",
         "        SmokeTest.noteLaunchPhase(\"load_start\")\n        loader.loadInitial { [weak self] result in\n            SmokeTest.noteLaunchPhase(\"load_result\")\n")
else:
    edit(R, "        }) { [weak self] result in\n            guard let self else { return }\n            guard let result else {\n",
         "        }) { [weak self] result in\n            SmokeTest.noteLaunchPhase(\"load_result\")\n            guard let self else { return }\n            guard let result else {\n")
    edit(R, "        let saved = BaselineStore.prefetch(url)\n", "        let saved = BaselineStore.prefetch(url)\n        SmokeTest.noteLaunchPhase(\"load_start\")\n")
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

# Main-thread gaps of the page (a 16 ms timer loop late by > 50 ms) and the
# resources it loaded, read with the rest.
PROBE = '"(() => {\\n  const L = (window.__abLong = []);\\n  const seen = {};\\n  let applied = 0;\\n  const wrap = (name, fn) => function (...a) {\\n    const t = performance.now();\\n    try { return fn.apply(this, a); } finally {\\n      const d = performance.now() - t;\\n      const k = name.startsWith(\'ev:\') ? \'ev\' : name;\\n      if (applied) seen[k] = (seen[k] || 0) + 1;\\n      if ((d > 30 || (applied && seen[k] <= 12 && (k === \'ro\' || k === \'io\' || k === \'raf\'))) && L.length < 150) L.push([name, Math.round(t), Math.round(d), String(fn).replace(/\\\\s+/g, \' \').slice(0, 60)]);\\n    }\\n  };\\n  const st = window.setTimeout;\\n  window.setTimeout = function (f, ms, ...a) { return st.call(window, typeof f === \'function\' ? wrap(\'timeout\', f) : f, ms, ...a); };\\n  const raf = window.requestAnimationFrame;\\n  window.requestAnimationFrame = function (f) { return raf.call(window, wrap(\'raf\', f)); };\\n  const ric = window.requestIdleCallback;\\n  if (ric) window.requestIdleCallback = function (f, o) { return ric.call(window, wrap(\'idle\', f), o); };\\n  for (const [k, n] of [[\'IntersectionObserver\', \'io\'], [\'ResizeObserver\', \'ro\'], [\'MutationObserver\', \'mo\']]) {\\n    const C = window[k];\\n    if (C) window[k] = class extends C { constructor(cb, o) { super(wrap(n, cb), o); } };\\n  }\\n  const ael = EventTarget.prototype.addEventListener, rel = EventTarget.prototype.removeEventListener, wrapped = new WeakMap();\\n  const w = (type, f) => { if (typeof f !== \'function\') return f; let x = wrapped.get(f); if (!x) { x = wrap(\'ev:\' + type, f); wrapped.set(f, x); } return x; };\\n  EventTarget.prototype.addEventListener = function (type, f, o) { return ael.call(this, type, w(type, f), o); };\\n  EventTarget.prototype.removeEventListener = function (type, f, o) { return rel.call(this, type, w(type, f), o); };\\n  let ro;\\n  Object.defineProperty(window, \'readout\', { configurable: true, get() { return ro; }, set(v) {\\n    for (const k of [\'apply\', \'setAppearance\', \'warm\']) if (typeof v[k] === \'function\') v[k] = wrap(\'api:\' + k, v[k]);\\n    const ap = v.apply; v.apply = function (...x) { if (!applied) applied = performance.now(); return ap.apply(this, x); };\\n    ro = v;\\n  } });\\n  const g = (window.__abGaps = []);\\n  let last = performance.now();\\n  const t = () => { const now = performance.now(); if (now - last > 66) g.push([Math.round(last), Math.round(now - last)]); last = now; if (now < 30000) st.call(window, t, 16); };\\n  st.call(window, t, 16);\\n})();\\n"'
edit("Shared/ReaderWebView.swift", "        ucc.addUserScript(WKUserScript(source: Self.contextLinkScript",
     "        ucc.addUserScript(WKUserScript(source: " + PROBE + ", injectionTime: .atDocumentStart, forMainFrameOnly: true))\n        ucc.addUserScript(WKUserScript(source: Self.contextLinkScript")
edit("App/SmokeTest.swift", "origin: performance.timeOrigin }", "origin: performance.timeOrigin, gaps: window.__abGaps, long: window.__abLong, res: performance.getEntriesByType('resource').map(e => [e.name.split('/').pop().slice(0, 24), Math.round(e.startTime), Math.round(e.responseEnd)]) }")
# Each take of a page: was there a spare, was it ready (app log).
edit("App/ReaderWindowController.swift", "        let w = spare ?? ReaderWebView(bundle: .main",
     "        NSLog(\"ABTAKE spare=%d ready=%d\", spare == nil ? 0 : 1, spare?.isReady == true ? 1 : 0)\n        let w = spare ?? ReaderWebView(bundle: .main")

# Every window's page: made or taken, ready, first apply, painted (app log).
edit(R, "        self.pendingAnchor = pendingAnchor\n",
     "        self.pendingAnchor = pendingAnchor\n        NSLog(\"ABWIN %@ ready=%d\", url.lastPathComponent, webView.isReady ? 1 : 0)\n        do { let name = url.lastPathComponent; webView.whenReady { NSLog(\"ABREADY %@\", name) } }\n")
edit(R, "                SmokeTest.noteLaunchPhase(\"apply\")\n", "                SmokeTest.noteLaunchPhase(\"apply\")\n                NSLog(\"ABAPPLIED %@\", url.lastPathComponent)\n")
edit(R, "                SmokeTest.noteLaunchPhase(\"paint\")\n", "                SmokeTest.noteLaunchPhase(\"paint\")\n                NSLog(\"ABPAINTED %@\", url.lastPathComponent)\n")

# --- launch2 probes (2026-10-21) ---------------------------------------
# The window build, step by step.
edit(R, "        window.minSize = NSSize(width: 460, height: 320)\n",
     "        SmokeTest.noteLaunchPhase(\"win_nswindow\")\n        window.minSize = NSSize(width: 460, height: 320)\n")
edit(R, "        buildContent()\n        buildToolbar()\n        configureWebView()\n        observeSettings()\n",
     "        SmokeTest.noteLaunchPhase(\"win_super\")\n        buildContent()\n        SmokeTest.noteLaunchPhase(\"win_content\")\n        buildToolbar()\n        SmokeTest.noteLaunchPhase(\"win_toolbar\")\n        configureWebView()\n        SmokeTest.noteLaunchPhase(\"win_webview_cfg\")\n        observeSettings()\n        SmokeTest.noteLaunchPhase(\"win_settings\")\n")
edit(R, "        load()\n    }\n\n    @available(*, unavailable)",
     "        SmokeTest.noteLaunchPhase(\"win_before_load\")\n        load()\n    }\n\n    @available(*, unavailable)")
edit(R, "    func show() {\n        SmokeTest.noteLaunchPhase(\"show_called\")\n        showWindow(nil)\n        window?.makeFirstResponder(webView)\n",
     "    func show() {\n        SmokeTest.noteLaunchPhase(\"show_called\")\n        showWindow(nil)\n        SmokeTest.noteLaunchPhase(\"show_window_done\")\n        window?.makeFirstResponder(webView)\n        SmokeTest.noteLaunchPhase(\"show_done\")\n        DispatchQueue.main.async { SmokeTest.noteLaunchPhase(\"show_next_turn\") }\n")
if "        MainMenu.trimEditMenu()\n" in (tree / "App/AppDelegate.swift").read_text():
    edit("App/AppDelegate.swift", "        MainMenu.trimEditMenu()\n", "        MainMenu.trimEditMenu()\n        SmokeTest.noteLaunchPhase(\"dfl_trimmed\")\n")
# Each module chunk's evaluation, marked where it starts and ends.
edit("web/build.mjs", "  legalComments: 'none',\n",
     "  legalComments: 'none',\n  banner: { js: \"performance.mark('ev<'+import.meta.url.split('/').pop());\" }, footer: { js: \"performance.mark('ev>'+import.meta.url.split('/').pop());\" },\n")
# The highlighter's set-up, step by step.
H = "web/src/highlight.js"
edit(H, "await Promise.all([import('shiki/core'), import('shiki/engine/javascript')]);\n",
     "await Promise.all([import('shiki/core'), import('shiki/engine/javascript')]);\n    performance.mark('hl:imported');\n")
edit(H, "    if (preload) await Promise.all(PRELOAD.map(id => ensureLang(id)));\n",
     "    performance.mark('hl:core');\n    if (preload) await Promise.all(PRELOAD.map(id => ensureLang(id)));\n    performance.mark('hl:done');\n")
edit(H, "    const done = registry.then(() => load).then(m => {\n",
     "    const done = registry.then(() => load).then(m => {\n      performance.mark('hl:mod:' + id);\n")
edit(H, "      return highlighter.loadLanguage(m.default);\n",
     "      const abR = highlighter.loadLanguage(m.default);\n      performance.mark('hl:reg:' + id);\n      return abR;\n")
edit(H, "  ready = (async () => {\n", "  ready = (async () => {\n    performance.mark('hl:start');\n    if (window.__abHlDelay) await new Promise(r => setTimeout(r, window.__abHlDelay));\n")
# Long tasks / long animation frames, where WebKit has them; marks around the page's first frame.
LT = """(() => {
  window.__abLT = [];
  try {
    window.__abTypes = PerformanceObserver.supportedEntryTypes;
    for (const t of ['longtask', 'long-animation-frame']) {
      if (!PerformanceObserver.supportedEntryTypes.includes(t)) continue;
      new PerformanceObserver(l => { for (const e of l.getEntries()) if (window.__abLT.length < 200) window.__abLT.push([t, Math.round(e.startTime), Math.round(e.duration), Math.round(e.blockingDuration || 0), (e.scripts || []).map(s => [String(s.sourceURL || '').split('/').pop(), String(s.invoker || '').slice(0, 40), Math.round(s.duration)]).slice(0, 6)]); }).observe({ type: t, buffered: true });
    }
  } catch (e) { window.__abTypes = String(e); }
})();
"""
edit("Shared/ReaderWebView.swift", "        ucc.addUserScript(WKUserScript(source: Self.contextLinkScript",
     "        ucc.addUserScript(WKUserScript(source: #\"\"\"\n" + LT + "\"\"\"#, injectionTime: .atDocumentStart, forMainFrameOnly: true))\n        ucc.addUserScript(WKUserScript(source: Self.contextLinkScript")
edit("App/SmokeTest.swift", "origin: performance.timeOrigin, gaps: window.__abGaps,",
     "origin: performance.timeOrigin, marks: performance.getEntriesByType('mark').map(m => [m.name.slice(0, 32), Math.round(m.startTime)]), lt: window.__abLT, types: window.__abTypes, gaps: window.__abGaps,")
# Shorter gaps (a 16 ms timer late by more than 40 ms).
pj = tree / "Shared/ReaderWebView.swift"
pj.write_text(pj.read_text().replace("if (now - last > 66) g.push", "if (now - last > 40) g.push", 1))

edit(R, "        window.title = url.lastPathComponent\n        window.representedURL = url\n        // Where the file is: on the tab, not in the subtitle.\n        updateTabToolTip()\n",
     "        window.title = url.lastPathComponent\n        SmokeTest.noteLaunchPhase(\"win_title\")\n        window.representedURL = url\n        SmokeTest.noteLaunchPhase(\"win_represented\")\n        // Where the file is: on the tab, not in the subtitle.\n        updateTabToolTip()\n        SmokeTest.noteLaunchPhase(\"win_tooltip\")\n")
edit(R, "        window.setFrameUsingName(Self.frameName)\n\n", "        window.setFrameUsingName(Self.frameName)\n        SmokeTest.noteLaunchPhase(\"win_frame\")\n\n")

# Experiments on the 3.9 tree.
if exp == "dfl":
    # 3.8's order: the spare page at the start of didFinishLaunching.
    edit("App/AppDelegate.swift", "        WebViewPool.shared.prewarm()\n        SmokeTest.noteLaunchPhase(\"spare_created\")\n", "")
    edit("App/AppDelegate.swift", "        SmokeTest.noteLaunchPhase(\"did_finish_launching\")\n",
         "        SmokeTest.noteLaunchPhase(\"did_finish_launching\")\n        WebViewPool.shared.prewarm()\n        SmokeTest.noteLaunchPhase(\"spare_created\")\n")
elif exp in ("f1", "f2", "defer"):
    # No spare page at launch: the first window makes its own; the spare is
    # made once that page has painted (WebViewPool.pagePainted).
    if exp != "defer":
        edit("App/AppDelegate.swift", "        WebViewPool.shared.prewarm()\n        SmokeTest.noteLaunchPhase(\"spare_created\")\n", "")
    if exp in ("f2", "defer"):
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
elif exp == "nomm":
    # Mermaid's flowchart warm-up 3 s after the first paint instead of the next idle moment.
    edit("web/src/reader/mermaid.js", "  requestAnimationFrame(() => setTimeout(() => idle(warmUp, { timeout: 3000 }), 0));\n",
         "  setTimeout(() => idle(warmUp, { timeout: 3000 }), 3000);\n")
elif exp == "hld":
    # The highlighter's set-up 1.5 s later than asked.
    edit("web/src/reader.js", "window.readout = {\n", "window.__abHlDelay = 1500;\nwindow.readout = {\n")
elif exp == "hln":
    # No preloaded grammars: only the document's own.
    edit("web/src/highlight.js", "const PRELOAD = ['shellscript', 'json', 'typescript'];", "const PRELOAD = [];")
elif exp == "wp":
    # Text painted (in the page's background colour) as soon as the page
    # loads: WebKit's first text drawing on the GPU starts then, not with the document.
    edit("web/src/reader.html", "<body>\n", "<body>\n<div id=\"ro-warm\" aria-hidden=\"true\">Readout 读 Aa 0</div>\n")
    css = tree / "web/src/reader.css"
    css.write_text(css.read_text() + "\n#ro-warm { position: fixed; left: 2px; bottom: 2px; color: var(--bg); pointer-events: none; z-index: -1; }\n")
    edit("web/src/reader/patch.js", "    post({ type: 'painted', version: p.version });\n",
         "    post({ type: 'painted', version: p.version });\n    document.getElementById('ro-warm')?.remove();\n")
elif exp == "win":
    # The outline (SwiftUI) and the document proxy icon after the window is on screen.
    edit(R, "        let sidebarVC = NSHostingController(rootView: TOCView(model: model))\n        sidebarVC.sizingOptions = []\n",
         "        let sidebarVC = NSViewController()\n        sidebarVC.view = NSView()\n        DispatchQueue.main.async { [weak self, weak sidebarVC] in\n            guard let self, let sidebarVC else { return }\n            let host = NSHostingController(rootView: TOCView(model: self.model))\n            host.sizingOptions = []\n            sidebarVC.addChild(host)\n            host.view.frame = sidebarVC.view.bounds\n            host.view.autoresizingMask = [.width, .height]\n            sidebarVC.view.addSubview(host.view)\n            SmokeTest.noteLaunchPhase(\"outline_installed\")\n        }\n")
    edit(R, "        window.representedURL = url\n", "        DispatchQueue.main.async { [weak self] in self?.window?.representedURL = self?.url }\n")
elif exp == "web38" or exp.startswith("web="):
    pass
elif exp == "pre12":
    # 3.8.0's twelve preloaded grammars.
    edit("web/src/highlight.js", "const PRELOAD = ['shellscript', 'json', 'typescript'];",
         "const PRELOAD = ['shellscript', 'json', 'typescript', 'javascript', 'python', 'swift', 'go', 'rust', 'yaml', 'diff', 'markdown', 'sql'];")
elif exp == "nomath":
    edit("web/src/reader/enhance.js", "  if (el.querySelector('.math, .math-block')) renderMath(el);\n", "")
elif exp == "nomm":
    edit("web/src/reader/enhance.js", "  for (const m of el.querySelectorAll('.mermaid-block')) { setupMermaid(m); diagrams.add(m); }\n", "")
elif exp == "cpu":
    # WebKit draws the page's layers on the CPU (no accelerated drawing).
    edit("Shared/ReaderWebView.swift", "        let config = WKWebViewConfiguration()\n",
         "        let config = WKWebViewConfiguration()\n        if config.preferences.responds(to: NSSelectorFromString(\"_setAcceleratedDrawingEnabled:\")) { config.preferences.setValue(false, forKey: \"acceleratedDrawingEnabled\"); NSLog(\"ABCPU on\") } else { NSLog(\"ABCPU unavailable\") }\n")
elif exp:
    sys.exit(f"apply-ab: unknown experiment {exp}")
print(f"apply-ab: {tree} patched ({exp or 'as is'})")
