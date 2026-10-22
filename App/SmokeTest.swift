import AppKit
import SwiftUI
import WebKit
import ReadoutCore

/// Read-only state export used by CI (tools/smoke-run.py). Enabled only when
/// READOUT_SMOKE_OUT is set. The app never modifies the document here: the
/// external harness performs every file write the way an agent would, and
/// this side only captures what the reader shows, into READOUT_SMOKE_OUT.
///
/// Handshake (marker files in the output directory):
///   `opened`      the smoke file was opened (harness may race an early edit)
///   `await-edit`  1-initial was captured and the view scrolled mid-document;
///                 the harness now replaces the file with the edited version
///   `await-tmp-edit`, `await-retarget`
///                 a file under /tmp, and one reached through a symlink, are
///                 shown; the harness rewrites the first and points the link
///                 at another file (`ln -sf`)
///   `await-refill` the harness empties the smoke file and writes it back a
///                 second later; the reader must return to its place
///   `await-dangle` the harness points a symlink at a file not written yet,
///                 then writes that file
///   `await-cli`   the harness runs `readout -b` and `readout --hook` (one
///                 hook names the project folder its plan's paths are in), then
///                 adds a section to the file opened with `readout -b`
@MainActor
enum SmokeTest {
    /// The harness's warm-up launch (READOUT_SMOKE_PASS=boot): it adds nothing to the recent documents.
    static var isBootPass: Bool { outputDirectory != nil && ProcessInfo.processInfo.environment["READOUT_SMOKE_PASS"] == "boot" }

    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["READOUT_SMOKE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Patches the page reported as applied (any document).
    private static var appliedCount = 0
    /// Wall-clock time of every applied patch, and of the frame that showed it,
    /// for the harness's cold-start and write-to-update measurements.
    private static var appliedAt: [Double] = []
    private static var paintedAt: [Double] = []
    /// Window request to first patch on screen, per file (the last open of
    /// it), and every open's when a file is opened more than once.
    private static var firstPaint: [String: Double] = [:]
    private static var firstPaintSamples: [String: [Double]] = [:]
    private static var started = false
    /// Files opened on their own after an agent wrote them.
    private static var autoOpened: [String] = []

    static func noteAutoOpened(_ paths: [String]) {
        if outputDirectory != nil { autoOpened += paths }
    }

    /// Opens asked for in the background through `readout-open:` (`readout -b`, `--hook`).
    private static var backgroundRequests: [String] = []

    static func noteBackgroundRequest(_ path: String) {
        if outputDirectory != nil { backgroundRequests.append(path) }
    }

    static func noteApplied() {
        appliedCount += 1
        if outputDirectory != nil { appliedAt.append(Date().timeIntervalSince1970) }
    }

    static func notePainted() {
        if outputDirectory != nil { paintedAt.append(Date().timeIntervalSince1970) }
    }

    static func noteFirstPaint(_ url: URL, seconds: Double) {
        guard outputDirectory != nil else { return }
        firstPaint[url.path] = seconds
        firstPaintSamples[url.path, default: []].append(seconds)
    }

    /// Window request to the page's first apply, per file, every open
    /// (Readout's own share of an open, without the frame the system paints).
    private static var firstApplySamples: [String: [Double]] = [:]
    static func noteFirstApply(_ url: URL, seconds: Double) {
        guard outputDirectory != nil else { return }
        firstApplySamples[url.path, default: []].append(seconds)
    }

    /// Where keyboard focus landed on an unread change (VoiceOver's announcement).
    private static var landed: [[String: Any]] = []
    static func noteLanded(index: Int, total: Int, kind: String) {
        guard outputDirectory != nil else { return }
        landed.append(["index": index, "total": total, "kind": kind])
    }

    /// When each phase of the launch first happened (wall clock, seconds):
    /// will_finish_launching, spare_created (the spare page made),
    /// did_finish_launching, open_requested, then for the first window
    /// window_init, page_ready, did_load, apply and paint. tools/smoke-run.py
    /// splits cold_start_ms with them.
    private static var launchPhases: [String: Double] = [:]
    static func noteLaunchPhase(_ name: String) {
        guard outputDirectory != nil, launchPhases[name] == nil else { return }
        launchPhases[name] = Date().timeIntervalSince1970
    }

    /// When the kernel started this process (wall clock, seconds), from sysctl:
    /// what comes before the app's first line of code (launch, the code
    /// signature's first assessment) is part of a cold start too.
    private static var processStart: Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    /// The first window's page, in ms: its first setAppearance, then the first
    /// apply's block work and the layout it reads (page time, report only).
    private static var pageFirstApply: [String: Any] = [:]
    private static func readPageFirstApply(_ webView: WKWebView) async {
        if let text = try? await webView.evaluateJavaScript("JSON.stringify(window.readout.firstTimings())") as? String,
           let data = text.data(using: .utf8), let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { pageFirstApply = d }
    }

    /// How long a call into the first window's page waited at worst in the
    /// 2 s after its first document was on screen, in ms: one is planned
    /// every 50 ms from 50 ms after the paint, and each counts from the time it was planned for to the
    /// page's answer, so a freeze of the app's main thread (which delays the
    /// call being made) counts as much as one of the page's. What a click or
    /// a key pressed then waits for.
    private static var postPaintInputDelay: Double?
    private static func probeAfterFirstPaint(_ webView: WKWebView) async {
        let deadline = Date().addingTimeInterval(30)
        while launchPhases["paint"] == nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        guard let paint = launchPhases["paint"] else { return }
        // Planned from the paint itself, not from when this task woke to see it.
        let start = Date(timeIntervalSince1970: paint)
        var longest = 0.0
        var planned = start.addingTimeInterval(0.05)
        while planned.timeIntervalSince(start) < 2 {
            let wait = planned.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            _ = try? await webView.evaluateJavaScript("0")
            longest = max(longest, Date().timeIntervalSince(planned))
            // The next one 50 ms after this one was planned, or now if that has passed.
            planned = max(planned.addingTimeInterval(0.05), Date())
        }
        postPaintInputDelay = (longest * 1000).rounded()
    }

    /// Timings for tools/smoke-run.py, which adds its own clock readings.
    private static func writeTimings(_ dir: URL) {
        var phases = launchPhases
        if let start = processStart { phases["process_start"] = start }
        let json: [String: Any] = ["applied_at": appliedAt, "painted_at": paintedAt, "first_paint_s": firstPaint,
                                   "first_paint_samples_s": firstPaintSamples, "first_apply_samples_s": firstApplySamples,
                                   "launch_phases_s": phases, "page_first_apply_ms": pageFirstApply,
                                   "post_paint_input_delay_ms": postPaintInputDelay.map { $0 as Any } ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("timings-app.json"))
        }
    }

    /// The spare page (made after the first paint) warms its grammars up in
    /// slices of up to tens of milliseconds: in a WebContent process of its
    /// own, so the window being read never waits for them. Its pid and the
    /// window's (WebKit's private _webProcessIdentifier, read only here).
    private static func processes(webView: WKWebView, out: URL) {
        func pid(_ w: WKWebView?) -> Int {
            guard let w, w.responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return -1 }
            return (w.value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue ?? -1
        }
        let spare = WebViewPool.shared.spareForSmokeTest
        let json: [String: Any] = ["window_pid": pid(webView), "spare_pid": spare == nil ? -1 : pid(spare)]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("processes.json"))
        }
    }

    static func didOpen() {
        guard let out = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        mark(out, "opened")
    }

    static func run(controller: ReaderWindowController, webView: WKWebView) {
        guard let out = outputDirectory, !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        NSApp.activate()
        Task { @MainActor in
            // The warm-up launch before the measured one (tools/smoke-run.py):
            // the first document painted, its timings written, then quit.
            if ProcessInfo.processInfo.environment["READOUT_SMOKE_PASS"] == "boot" {
                let deadline = Date().addingTimeInterval(30)
                while launchPhases["paint"] == nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                await probeAfterFirstPaint(webView)
                // Let the page finish what follows its first paint (the highlighter, diagrams).
                try? await Task.sleep(for: .seconds(1))
                await readPageFirstApply(webView)
                writeTimings(out)
                NSApp.terminate(nil)
                return
            }
            // The second, Chinese pass (tools/smoke-run.py): menus and windows only.
            if ProcessInfo.processInfo.environment["READOUT_SMOKE_PASS"] == "zh" {
                await localePass(controller: controller, out: out)
                NSApp.terminate(nil)
                return
            }
            await probeAfterFirstPaint(webView)
            try? await Task.sleep(for: .seconds(1))
            await readPageFirstApply(webView)
            processes(webView: webView, out: out)
            await capture(webView, window: controller.window, to: out, name: "1-initial")
            await typesetting(webView: webView, out: out)

            // Scroll into the middle and remember where a block sits, then let
            // the harness rewrite the file (temp file + rename, like agents).
            _ = try? await webView.evaluateJavaScript("(() => { const b = [...document.querySelectorAll('.blk')]; const t = b[Math.floor(b.length/2)]; window.scrollBy(0, t.getBoundingClientRect().top - 30); window.__smoke = {slot: +t.dataset.slot, top: t.getBoundingClientRect().top}; return 1; })()")
            let before = appliedCount
            mark(out, "await-edit")
            let deadline = Date().addingTimeInterval(20)
            while appliedCount == before && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Let lazy renderers (Mermaid, KaTeX) and anchor compensation settle.
            try? await Task.sleep(for: .seconds(1.5))
            // One write, one patch: the watcher reports a write at once and
            // folds the events that follow it, never applying it twice.
            write(["applies": appliedCount - before], to: out, "edit.json")
            await capture(webView, window: controller.window, to: out, name: "2-after-edit")
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0); 1")
            try? await Task.sleep(for: .seconds(1))
            // The window alone, for the README: light, the edited document from the top, its changes marked.
            windowShot(controller.window, out, "window-light")
            // The Chinese and Japanese lines of the fixture: where PingFang and
            // Hiragino put the emphasis dots, the quotes, the spacing.
            _ = try? await webView.evaluateJavaScript("(() => { const e = [...document.querySelectorAll('.blk')].find(b => b.textContent.includes('日本語の確認')); if (e) window.scrollBy(0, e.getBoundingClientRect().top - 160); return 1; })()")
            try? await Task.sleep(for: .seconds(1))
            windowShot(controller.window, out, "cjk-light")
            await chinesePunctuation(webView: webView, out: out)
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0); 1")
            try? await Task.sleep(for: .milliseconds(500))
            // Open what changed in the edited table (the edit mark's action).
            _ = try? await webView.evaluateJavaScript("(() => { const t = document.querySelector('.blk.k-table.m-modified'); return t ? window.readout.toggleDiff(+t.dataset.slot) : false; })()")
            try? await Task.sleep(for: .milliseconds(300))
            await capture(webView, window: controller.window, to: out, name: "3-marks")
            await undoMarkAllRead(controller: controller, webView: webView, out: out)
            await copyAsQuote(controller: controller, webView: webView, out: out)
            await copyAsMarkdown(controller: controller, webView: webView, out: out)
            await navigationStaysOnTheReader(webView: webView, out: out)

            // Dark appearance, then the auxiliary windows.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            _ = try? await webView.evaluateJavaScript("(() => { const m = document.querySelector('.mermaid-block'); if (m) m.scrollIntoView({block: 'center'}); return 1; })()")
            try? await Task.sleep(for: .seconds(2.5))
            await capture(webView, window: controller.window, to: out, name: "4-dark")
            await scrollEdge(controller: controller, webView: webView, out: out)
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0); 1")
            try? await Task.sleep(for: .seconds(1))
            windowShot(controller.window, out, "window-dark")
            NSApp.appearance = nil
            let app = NSApp.delegate as? AppDelegate
            // Open a second file while running: the warm open-to-first-paint path.
            // Three opens (the harness takes the median: one slow moment of a
            // shared runner is not a regression), each with a spare page made again.
            if let second = ProcessInfo.processInfo.environment["READOUT_SMOKE_SECOND"] {
                let secondURL = URL(fileURLWithPath: second)
                for round in 1...3 {
                    app?.open(secondURL)
                    // Keep it open until its first frame is on screen (or well past the guard).
                    let deadline = Date().addingTimeInterval(10)
                    while (firstPaintSamples[secondURL.path]?.count ?? 0) < round && Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    app?.reader(for: secondURL)?.window?.close()
                    // The pool makes its next spare page once the page taken has
                    // painted (above), or 3 s after it was taken: ready by now.
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            // An agent writes a new document into a watched folder while Readout is
            // in the background: it must open on its own, without activating Readout.
            if let folder = ProcessInfo.processInfo.environment["READOUT_SMOKE_AGENT_FOLDER"] {
                WorkspaceIndex.shared.configure([folder])
                NSApp.deactivate()
                try? await Task.sleep(for: .seconds(1))
                let wasActive = NSApp.isActive
                let readingBefore = reading()
                mark(out, "await-agent-write")
                let deadline = Date().addingTimeInterval(15)
                while autoOpened.isEmpty && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .milliseconds(500))
                let titles = NSApp.windows.filter(\.isVisible).map(\.title)
                let json: [String: Any] = ["auto_opened": autoOpened.map { URL(fileURLWithPath: $0).lastPathComponent },
                                           "active_before": wasActive, "active_after": NSApp.isActive,
                                           "reading_before": readingBefore, "reading_after": reading(),
                                           "window_titles": titles]
                if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: out.appendingPathComponent("agent-folder.json"))
                }
                // A folder in Settings that does not exist yet (~/.claude/plans before
                // the first plan): created and written to while Readout stays in the
                // background, its new document must still open on its own.
                if let late = ProcessInfo.processInfo.environment["READOUT_SMOKE_LATE_FOLDER"] {
                    WorkspaceIndex.shared.configure([folder, late])
                    // Watched through the folder above it that exists, not polled.
                    let watch = WorkspaceIndex.shared.missingFolderWatch
                    let count = autoOpened.count
                    mark(out, "await-late-folder")
                    let deadline = Date().addingTimeInterval(15)
                    while autoOpened.count == count && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                    var json: [String: Any] = ["auto_opened": autoOpened.dropFirst(count).map { URL(fileURLWithPath: $0).lastPathComponent },
                                               "active_after": NSApp.isActive, "missing_watch": watch,
                                               "missing_watch_after": WorkspaceIndex.shared.missingFolderWatch]
                    // Another folder added (or one appearing, as the global shortcut
                    // finds it): while it is scanned, what was known stays, so the
                    // shortcut never finds nothing; then the scan's result.
                    let work = URL(fileURLWithPath: folder).deletingLastPathComponent().path
                    WorkspaceIndex.shared.configure([folder, late, work])
                    let during = WorkspaceIndex.shared.latest?.lastPathComponent ?? ""
                    final class Box { var after: String? }
                    let box = Box()
                    WorkspaceIndex.shared.whenScanned { box.after = WorkspaceIndex.shared.latest?.lastPathComponent ?? "" }
                    let scanDeadline = Date().addingTimeInterval(10)
                    while box.after == nil && Date() < scanDeadline { try? await Task.sleep(for: .milliseconds(20)) }
                    json["rescan"] = ["latest_during": during, "latest_after": box.after ?? "(no scan)"]
                    WorkspaceIndex.shared.configure([folder, late])
                    write(json, to: out, "late-folder.json")
                }
                NSApp.activate()
            }
            await refill(controller: controller, webView: webView, out: out)
            await liveUpdates(app: app, out: out)
            await backgroundOpens(out: out)
            await commitBaseline(out: out)
            await earlyPrint(out: out)
            await findInPage(controller: controller, webView: webView, out: out)
            writeMenus(out)
            app?.showSettings(nil)
            try? await Task.sleep(for: .seconds(1.5))
            screen(out, "5-settings")
            let settingsWindow = NSApp.windows.first { $0.contentViewController is NSHostingController<SettingsView> }
            var aux: [String: Any] = ["settings_tabbing_disallowed": settingsWindow?.tabbingMode == .disallowed]
            settingsWindow?.close()
            // Open Latest Agent File with nothing written yet (S2, 3.9): the
            // welcome window, no alert. (An alert would stop the run here.)
            let none = out.appendingPathComponent("no-agent-files", isDirectory: true)
            try? FileManager.default.createDirectory(at: none, withIntermediateDirectories: true)
            WorkspaceIndex.shared.configure([none.path])
            app?.openLatest(nil)
            let welcomeDeadline = Date().addingTimeInterval(5)
            let welcomeWindow = { NSApp.windows.first(where: { $0.contentViewController is NSHostingController<WelcomeView> }) }
            while welcomeWindow()?.isVisible != true && Date() < welcomeDeadline { try? await Task.sleep(for: .milliseconds(50)) }
            aux["open_latest_none_welcome"] = welcomeWindow()?.isVisible ?? false
            aux["open_latest_none_modal"] = NSApp.modalWindow != nil
            aux["acknowledgements_bundled"] = Bundle.main.url(forResource: "Acknowledgements", withExtension: "md") != nil
            try? await Task.sleep(for: .seconds(1.5))
            screen(out, "6-welcome")
            if let welcome = welcomeWindow() {
                aux["welcome_tabbing_disallowed"] = welcome.tabbingMode == .disallowed
                aux["welcome_minimize_hidden"] = welcome.standardWindowButton(.miniaturizeButton)?.isHidden ?? false
                aux["welcome_zoom_hidden"] = welcome.standardWindowButton(.zoomButton)?.isHidden ?? false
                aux["welcome_title"] = welcome.title
                aux["welcome_in_window_menu"] = !welcome.isExcludedFromWindowsMenu
            }
            write(aux, to: out, "aux-windows.json")
            await tabDot(controller: controller, out: out)
            await landing(controller: controller, webView: webView, out: out)
            restoration(controller: controller, out: out)
            await restoredTabs(out: out)
            await crossDocument(controller: controller, out: out)
            writeTimings(out)
            NSApp.terminate(nil)
        }
    }

    /// The whole menu bar: every item's title, action, key and modifiers,
    /// submenus nested (menus.json), and the Edit menu's actions as before.
    private static func writeMenus(_ out: URL, name: String = "menus.json") {
        func modifiers(_ m: NSEvent.ModifierFlags) -> String {
            [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                .filter { m.contains($0.0) }.map { $0.1 }.joined()
        }
        func tree(_ menu: NSMenu) -> [[String: Any]] {
            menu.items.map { i -> [String: Any] in
                if i.isSeparatorItem { return ["separator": true] }
                var e: [String: Any] = ["title": i.title]
                if let a = i.action { e["action"] = NSStringFromSelector(a) }
                if !i.keyEquivalent.isEmpty { e["key"] = modifiers(i.keyEquivalentModifierMask) + i.keyEquivalent }
                if i.isAlternate { e["alternate"] = true }
                if i.isHidden { e["hidden"] = true }
                if let sub = i.submenu { e["items"] = tree(sub) }
                return e
            }
        }
        var json: [String: Any] = ["menus": NSApp.mainMenu.map(tree) ?? []]
        if let edit = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == NSLocalizedString("Edit", comment: "Menu") })?.submenu {
            json["edit_menu"] = edit.items.compactMap { i in i.action.map { NSStringFromSelector($0) + (i.keyEquivalent.isEmpty ? "" : " " + i.keyEquivalent) } }
        }
        write(json, to: out, name)
    }

    /// Launched with `-AppleLanguages (zh-Hans)`: the menu bar (menus-zh.json),
    /// Settings and the welcome window in Chinese.
    private static func localePass(controller: ReaderWindowController, out: URL) async {
        try? await Task.sleep(for: .seconds(2))
        windowShot(controller.window, out, "window-zh")
        writeMenus(out, name: "menus-zh.json")
        let app = NSApp.delegate as? AppDelegate
        app?.showSettings(nil)
        try? await Task.sleep(for: .seconds(1.5))
        screen(out, "5-settings-zh")
        NSApp.windows.first { $0.contentViewController is NSHostingController<SettingsView> }?.close()
        app?.showWelcome(nil)
        try? await Task.sleep(for: .seconds(1.5))
        screen(out, "6-welcome-zh")
    }

    /// What this WebKit supports of the CJK typesetting the reader asks for
    /// (reader.css), and what the page's paragraphs get (css-supports.json).
    private static func typesetting(webView: WKWebView, out: URL) async {
        let script = """
            (() => {
              const p = document.querySelector('.blk p') || document.body;
              const cs = getComputedStyle(p), root = getComputedStyle(document.documentElement);
              return JSON.stringify({
                supports: {
                  'text-autospace: normal': CSS.supports('text-autospace', 'normal'),
                  'text-spacing-trim: space-first': CSS.supports('text-spacing-trim', 'space-first'),
                  'hanging-punctuation: allow-end': CSS.supports('hanging-punctuation', 'allow-end'),
                  'text-wrap-style: pretty': CSS.supports('text-wrap-style', 'pretty'),
                  'text-wrap: pretty': CSS.supports('text-wrap', 'pretty'),
                },
                computed: {
                  'text-autospace': cs.getPropertyValue('text-autospace'),
                  'text-spacing-trim': root.getPropertyValue('text-spacing-trim'),
                  'hanging-punctuation': cs.getPropertyValue('hanging-punctuation'),
                  'text-wrap-style': cs.getPropertyValue('text-wrap-style'),
                  'font-family': cs.getPropertyValue('font-family'),
                },
                emphasis: { dots: document.querySelectorAll('.em-dot').length, long: document.querySelectorAll('.cjk-em-long').length },
              });
            })()
            """
        guard let text = try? await webView.evaluateJavaScript(script) as? String,
              let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        write(json, to: out, "css-supports.json")
    }

    /// Which font draws “ ” ‘ ’ — … in the fixture's Chinese paragraph
    /// (reader.css: the ro-zh-punct face, `local()` PingFang on a Chinese
    /// block): the face's status, and the width of those six characters
    /// as the block draws them, in PingFang SC and in the system font
    /// (zh-punct.json). Taken once the paragraph has been shown.
    private static func chinesePunctuation(webView: WKWebView, out: URL) async {
        let script = #"""
            (() => {
              const blk = [...document.querySelectorAll('#ro-doc > .chunk > .blk')].find(b => b.lang === 'zh' && b.textContent.includes('\u201C'));
              if (!blk) return JSON.stringify({ found: false });
              const host = blk.querySelector('p') || blk;
              const width = font => {
                const s = document.createElement('span');
                s.textContent = '\u201C\u201D\u2018\u2019\u2014\u2026';
                s.style.cssText = 'position:absolute;visibility:hidden;white-space:nowrap;font-size:20px;font-weight:400' + (font ? ';font-family:' + font : '');
                host.appendChild(s);
                const w = s.getBoundingClientRect().width;
                s.remove();
                return Math.round(w * 100) / 100;
              };
              return JSON.stringify({
                found: true,
                family: getComputedStyle(blk).fontFamily,
                check: document.fonts.check('20px ro-zh-punct', '\u201C'),
                faces: [...document.fonts].filter(f => f.family.replace(/["']/g, '') === 'ro-zh-punct').map(f => ({ weight: f.weight, status: f.status })),
                width: { block: width(''), pingfang: width('"PingFang SC"'), system: width('-apple-system') },
              });
            })()
            """#
        guard let text = try? await webView.evaluateJavaScript(script) as? String,
              let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        write(json, to: out, "zh-punct.json")
    }

    /// The soft scroll edge under the toolbar: the web view's top scroll
    /// pocket (WebKit SPI, read only if it answers), and the rows of a window
    /// shot just above the toolbar's edge with a dark code block 10 pt under
    /// it. A hard pocket paints those rows one solid colour; the soft edge
    /// lets the block show through, fading.
    private static func scrollEdge(controller: ReaderWindowController, webView: WKWebView, out: URL) async {
        var json: [String: Any] = controller.topInsetState
        func has(_ name: String) -> Bool { webView.responds(to: NSSelectorFromString(name)) }
        json["fill_settable"] = has("_setUsesAutomaticContentInsetBackgroundFill:")
        if has("_usesAutomaticContentInsetBackgroundFill") {
            let fill = (webView.value(forKey: "_usesAutomaticContentInsetBackgroundFill") as? NSNumber)?.boolValue
            json["automatic_fill"] = fill.map { $0 as Any } ?? NSNull()
        }
        let rect = "(() => { const c = document.querySelector('.code-block'); if (!c) return null; window.scrollBy(0, c.getBoundingClientRect().top + 10); const r = c.getBoundingClientRect(); return [r.left, r.top, r.right, r.bottom]; })()"
        let r = (try? await webView.evaluateJavaScript(rect)) as? [NSNumber]
        try? await Task.sleep(for: .seconds(1.2))
        if has("_topScrollPocket"), let pocket = webView.value(forKey: "_topScrollPocket") as? NSObject {
            var p: [String: Any] = ["class": String(describing: type(of: pocket))]
            if pocket.responds(to: NSSelectorFromString("style")) { p["style"] = (pocket.value(forKey: "style") as? NSNumber)?.intValue ?? -1 }
            if let v = pocket as? NSView { p["hidden"] = v.isHidden; p["frame"] = NSStringFromRect(v.frame) }
            // Every scalar or object property AppKit declares on the pocket (SPI), to see what it decided.
            var props: [String: String] = [:]
            var cls: AnyClass? = type(of: pocket)
            while let c = cls, c != NSView.self {
                var count: UInt32 = 0
                if let list = class_copyPropertyList(c, &count) {
                    for i in 0..<Int(count) {
                        let name = String(cString: property_getName(list[i]))
                        let attrs = property_getAttributes(list[i]).map { String(cString: $0) } ?? ""
                        guard props[name] == nil, attrs.hasPrefix("Tc") || attrs.hasPrefix("TB") || attrs.hasPrefix("Tq") || attrs.hasPrefix("TQ")
                                || attrs.hasPrefix("Td") || attrs.hasPrefix("T@\"NSColor") else { continue }
                        // Only getters KVC finds by the name (name or is<Name>), so value(forKey:) cannot throw.
                        let getter = attrs.split(separator: ",").first { $0.hasPrefix("G") }.map { String($0.dropFirst()) } ?? name
                        let isName = "is" + name.prefix(1).uppercased() + name.dropFirst()
                        guard getter == name || getter == isName, pocket.responds(to: NSSelectorFromString(getter)) else { continue }
                        props[name] = String(describing: pocket.value(forKey: name) ?? "nil")
                    }
                    free(list)
                }
                cls = class_getSuperclass(c)
            }
            p["properties"] = props
            json["pocket"] = p
        } else {
            json["pocket"] = NSNull()
        }
        guard let window = controller.window, let r, r.count == 4 else {
            json["error"] = "no code block"
            write(json, to: out, "scroll-edge.json")
            return
        }
        json["code_top"] = r[1].doubleValue
        json["window_key"] = window.isKeyWindow
        json["app_active"] = NSApp.isActive
        windowShot(window, out, "scroll-edge-dark")
        // Rows of the shot from 20 pt above the toolbar's edge to 12 pt below,
        // across the code block (4 pt in from its sides): mean and spread of luminance.
        if let rep = NSBitmapImageRep(data: (try? Data(contentsOf: out.appendingPathComponent("scroll-edge-dark.png"))) ?? Data()) {
            let scale = CGFloat(rep.pixelsWide) / window.frame.width
            let web = webView.convert(webView.bounds, to: nil)
            let edge = window.frame.height - web.maxY + CGFloat(webView.obscuredContentInsets.top)   // from the window's top
            let x0 = Int(((web.minX + CGFloat(r[0].doubleValue) + 4) * scale).rounded()), x1 = Int(((web.minX + CGFloat(r[2].doubleValue) - 4) * scale).rounded())
            var rows: [[String: Double]] = []
            for rel in -20...12 {
                let y = Int(((edge + CGFloat(rel)) * scale).rounded())
                guard y >= 0, y < rep.pixelsHigh, x0 < x1 else { continue }
                var values: [Double] = []
                for x in stride(from: max(0, x0), to: min(rep.pixelsWide, x1), by: 1) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    values.append((0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) * 255)
                }
                guard !values.isEmpty else { continue }
                let mean = values.reduce(0, +) / Double(values.count)
                let sd = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
                rows.append(["rel": Double(rel), "mean": (mean * 10).rounded() / 10, "sd": (sd * 10).rounded() / 10])
            }
            json["rows"] = rows
            json["scale"] = Double(scale)
            // A/B (A1): the same window at the same scroll position with the
            // private fill flag off. Identical pixels mean the flag has no
            // visible effect here (the owner checks a key window on a Mac).
            if has("_setUsesAutomaticContentInsetBackgroundFill:") {
                webView.setValue(false, forKey: "usesAutomaticContentInsetBackgroundFill")
                try? await Task.sleep(for: .seconds(1.2))
                windowShot(window, out, "scroll-edge-dark-off")
                var ab: [String: Any] = [:]
                if has("_usesAutomaticContentInsetBackgroundFill") {
                    ab["automatic_fill_off"] = (webView.value(forKey: "_usesAutomaticContentInsetBackgroundFill") as? NSNumber)?.boolValue ?? NSNull()
                }
                let y0 = Int(((edge - 20) * scale).rounded()), y1 = Int(((edge + 12) * scale).rounded())
                let on = out.appendingPathComponent("scroll-edge-dark.png"), off = out.appendingPathComponent("scroll-edge-dark-off.png")
                ab["window"] = pixelDifference(on, off)
                ab["band"] = pixelDifference(on, off, x: max(0, x0)..<max(max(0, x0), x1), y: max(0, y0)..<max(max(0, y0), y1))
                if let w = ab["window"] as? [String: Any] { ab["identical"] = (w["differing_pixels"] as? Int) == 0 }
                webView.setValue(true, forKey: "usesAutomaticContentInsetBackgroundFill")
                try? await Task.sleep(for: .seconds(0.5))
                if has("_usesAutomaticContentInsetBackgroundFill") {
                    ab["automatic_fill_restored"] = (webView.value(forKey: "_usesAutomaticContentInsetBackgroundFill") as? NSNumber)?.boolValue ?? NSNull()
                }
                json["ab"] = ab
            }
        }
        write(json, to: out, "scroll-edge.json")
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0); 1")
    }

    /// How two PNG shots differ, over the whole image or within `x`/`y`
    /// (pixels): how many pixels differ in any channel, and the largest
    /// difference of one channel (0-255).
    private static func pixelDifference(_ a: URL, _ b: URL, x: Range<Int>? = nil, y: Range<Int>? = nil) -> [String: Any] {
        guard let ra = (try? Data(contentsOf: a)).flatMap(NSBitmapImageRep.init(data:)),
              let rb = (try? Data(contentsOf: b)).flatMap(NSBitmapImageRep.init(data:)) else { return ["error": "unreadable"] }
        guard ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh, ra.bitsPerPixel == rb.bitsPerPixel,
              ra.bytesPerRow == rb.bytesPerRow, ra.bitsPerSample == 8, !ra.isPlanar, !rb.isPlanar,
              let pa = ra.bitmapData, let pb = rb.bitmapData else {
            return ["error": "different formats", "a": "\(ra.pixelsWide)x\(ra.pixelsHigh)", "b": "\(rb.pixelsWide)x\(rb.pixelsHigh)"]
        }
        let bytes = ra.bitsPerPixel / 8
        let xs = (x ?? 0..<ra.pixelsWide).clamped(to: 0..<ra.pixelsWide), ys = (y ?? 0..<ra.pixelsHigh).clamped(to: 0..<ra.pixelsHigh)
        var differing = 0, maxDelta = 0
        for row in ys {
            let base = row * ra.bytesPerRow
            for col in xs {
                var differs = false
                for c in 0..<bytes {
                    let i = base + col * bytes + c
                    let d = abs(Int(pa[i]) - Int(pb[i]))
                    if d > 0 { differs = true; maxDelta = max(maxDelta, d) }
                }
                if differs { differing += 1 }
            }
        }
        return ["pixels": xs.count * ys.count, "differing_pixels": differing, "max_channel_delta": maxDelta]
    }

    /// Next Change from the menu: focus lands on the change it went to, and
    /// the page reports which one it is (for VoiceOver).
    private static func landing(controller: ReaderWindowController, webView: WKWebView, out: URL) async {
        controller.show()
        landed = []
        let unread = controller.model.unread
        controller.nextChange(nil)
        let deadline = Date().addingTimeInterval(3)
        while landed.isEmpty && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        let focused = (try? await webView.evaluateJavaScript("(() => { const e = document.activeElement; return e ? e.className : ''; })()")) as? String ?? ""
        write(["unread": unread, "landed": landed, "focused_class": focused, "app_active": NSApp.isActive,
               "key": controller.window?.isKeyWindow ?? false], to: out, "landed.json")
    }

    /// Edit ▸ Copy as Quote on a selection across two blocks: enabled while
    /// there is one; the blocks' Markdown as a blockquote, the file's lines and section.
    private static func copyAsQuote(controller: ReaderWindowController, webView: WKWebView, out: URL) async {
        controller.show()
        let select = """
            (() => { const b = [...document.querySelectorAll('#ro-doc > .chunk > .blk.k-paragraph')].filter(e => e.textContent.trim().length > 20);
              const a = b[1], z = b[2]; if (!a || !z) return null;
              const t = n => { const w = document.createTreeWalker(n, NodeFilter.SHOW_TEXT); let x; while ((x = w.nextNode())) if (x.textContent.trim().length > 4) return x; return null; };
              const r = document.createRange(); r.setStart(t(a), 2); r.setEnd(t(z), 3);
              const s = getSelection(); s.removeAllRanges(); s.addRange(r); return [+a.dataset.slot, +z.dataset.slot]; })()
            """
        let picked = try? await webView.evaluateJavaScript(select)
        try? await Task.sleep(for: .milliseconds(300))
        let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.copyAsQuote(_:)), keyEquivalent: "")
        let enabled = controller.validateMenuItem(item)
        NSPasteboard.general.clearContents()
        controller.copyAsQuote(nil)
        try? await Task.sleep(for: .milliseconds(400))
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        _ = try? await webView.evaluateJavaScript("getSelection().removeAllRanges(); document.activeElement?.blur(); 1")
        try? await Task.sleep(for: .milliseconds(300))
        let enabledAfterDeselect = controller.validateMenuItem(item)
        // No text selected, the keyboard on a block (where N goes): that block is quoted.
        let focus = "(() => { const b = [...document.querySelectorAll('#ro-doc > .chunk > .blk.k-paragraph')].filter(e => e.textContent.trim().length > 20)[1]; if (!b) return null; if (!b.hasAttribute('tabindex')) b.tabIndex = -1; b.focus(); return +b.dataset.slot; })()"
        let focused = try? await webView.evaluateJavaScript(focus)
        try? await Task.sleep(for: .milliseconds(300))
        let enabledFocused = controller.validateMenuItem(item)
        NSPasteboard.general.clearContents()
        controller.copyAsQuote(nil)
        try? await Task.sleep(for: .milliseconds(400))
        let focusedText = NSPasteboard.general.string(forType: .string) ?? ""
        _ = try? await webView.evaluateJavaScript("document.activeElement?.blur(); 1")
        write(["picked": picked ?? NSNull(), "enabled": enabled, "text": text,
               "enabled_after_deselect": enabledAfterDeselect,
               "focused_slot": focused ?? NSNull(), "enabled_focused": enabledFocused, "focused_text": focusedText,
               "path": ReaderChrome.tabToolTip(path: controller.url.path)], to: out, "copy-quote.json")
    }

    /// Edit ▸ Copy (⌘C) on the task items: what WKWebView puts on the
    /// pasteboard is the items' Markdown as plain text and clean HTML.
    private static func copyAsMarkdown(controller: ReaderWindowController, webView: WKWebView, out: URL) async {
        controller.show()
        let select = """
            (() => { const b = [...document.querySelectorAll('#ro-doc > .chunk > .blk.k-listItem')].filter(e => e.querySelector('.task-box'));
              if (b.length < 2) return null;
              const r = document.createRange(); r.setStart(b[0], 0); r.setEnd(b[1], b[1].childNodes.length);
              const s = getSelection(); s.removeAllRanges(); s.addRange(r); return [+b[0].dataset.slot, +b[1].dataset.slot]; })()
            """
        let picked = try? await webView.evaluateJavaScript(select)
        try? await Task.sleep(for: .milliseconds(300))
        NSPasteboard.general.clearContents()
        let sent = NSApp.sendAction(#selector(NSText.copy(_:)), to: webView, from: nil)
        try? await Task.sleep(for: .milliseconds(600))
        let pb = NSPasteboard.general
        let text = pb.string(forType: .string) ?? ""
        let html = pb.string(forType: .html) ?? ""
        // Edit ▸ Select All selects the whole page (toolbar, notices): Copy writes the document.
        _ = try? await webView.evaluateJavaScript("getSelection().removeAllRanges(); 1")
        _ = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: webView, from: nil)
        try? await Task.sleep(for: .milliseconds(300))
        pb.clearContents()
        let sentAll = NSApp.sendAction(#selector(NSText.copy(_:)), to: webView, from: nil)
        try? await Task.sleep(for: .milliseconds(600))
        let all = pb.string(forType: .string) ?? ""
        _ = try? await webView.evaluateJavaScript("getSelection().removeAllRanges(); 1")
        write(["picked": picked ?? NSNull(), "sent": sent, "text": text, "html": html,
               "types": (pb.types ?? []).map(\.rawValue),
               "select_all_sent": sentAll, "select_all_text": String(all.prefix(400))], to: out, "copy-markdown.json")
    }

    /// The window's restorable state, encoded and decoded as AppKit keeps it
    /// for the next launch (relaunching is not part of the smoke run).
    private static func restoration(controller: ReaderWindowController, out: URL) {
        func roundTrip(_ c: ReaderWindowController) -> [String: Any] {
            guard let window = c.window else { return [:] }
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            c.window(window, willEncodeRestorableState: archiver)
            archiver.finishEncoding()
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else { return [:] }
            unarchiver.requiresSecureCoding = true
            let back = ReaderRestoration.decode(unarchiver)
            return ["path": back?.path ?? "", "root": back?.projectRoot ?? "", "expected_path": c.url.path,
                    "expected_root": c.restorationState.projectRoot ?? "", "group": back?.group ?? "", "index": back?.tabIndex ?? -1]
        }
        let readers = NSApp.windows.compactMap { $0.windowController as? ReaderWindowController }
        var json: [String: Any] = ["main": roundTrip(controller)]
        if let plan = ProcessInfo.processInfo.environment["READOUT_SMOKE_HOOK_PLAN"],
           let hooked = (NSApp.delegate as? AppDelegate)?.reader(for: URL(fileURLWithPath: plan)) { json["hooked"] = roundTrip(hooked) }
        // A file that is gone does not come back.
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        ReaderRestoration.encode(ReaderRestorationState(path: "/nonexistent/readout-gone.md"), into: archiver)
        archiver.finishEncoding()
        if let u = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) { json["gone_restored"] = ReaderRestoration.decode(u) != nil }
        json["restorable"] = readers.allSatisfy { $0.window?.isRestorable == true && $0.window?.restorationClass == ReaderRestoration.self }
        let ids = readers.compactMap { $0.window?.identifier?.rawValue }
        json["identifiers_unique"] = Set(ids).count == ids.count && ids.count == readers.count
        // No window holds the frame name (only the first one could): each saves under it.
        json["frame_autosave_names"] = readers.compactMap { $0.window?.frameAutosaveName }.filter { !$0.isEmpty }
        json["others_restorable"] = NSApp.windows.filter { !($0.windowController is ReaderWindowController) && $0.isRestorable }.map(\.title)
        write(json, to: out, "restoration.json")
    }

    /// N with nothing unread left in the document goes on to the next
    /// document with unread changes (its tab comes forward, at its first
    /// change); with none anywhere it stays. The Dock badge counts them.
    private static func crossDocument(controller: ReaderWindowController, out: URL) async {
        let app = NSApp.delegate as? AppDelegate
        let readers = { NSApp.windows.compactMap { $0.windowController as? ReaderWindowController } }
        controller.show()
        var json: [String: Any] = ["badge_before": NSApp.dockTile.badgeLabel ?? "",
                                   "attention_before": readers().filter(\.showsAttention).count,
                                   "showing_unread_before": readers().filter(\.showsUnread).count]
        controller.markAllRead(nil)
        try? await Task.sleep(for: .milliseconds(900))
        // A document opened behind and not looked at yet counts as waiting
        // (U2): N goes on to it as it shows, without a first change. (The CI
        // window is never key: no document has been looked at.)
        json["unseen_from"] = reading()
        landed = []
        controller.nextChange(nil)
        var deadline = Date().addingTimeInterval(4)
        while reading() == json["unseen_from"] as? String && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(600))
        let unseen = readers().first { ($0.window?.tabGroup?.selectedWindow ?? $0.window) === $0.window && $0.window?.title == reading() }
        json["unseen"] = ["to": reading(), "unread": unseen?.model.unread ?? -1, "looked_at": unseen?.notedRecent ?? true,
                          "landed": landed, "notice": await noticeText(unseen), "subtitle": unseen?.window?.subtitle ?? ""]
        // As if the reader had looked at every document: only unread changes wait now.
        for r in readers() { r.noteLookedAt() }
        try? await Task.sleep(for: .milliseconds(300))
        json["badge_looked_at"] = NSApp.dockTile.badgeLabel ?? ""
        json["showing_unread_looked_at"] = readers().filter(\.showsUnread).count
        controller.show()
        try? await Task.sleep(for: .milliseconds(300))
        json["from"] = reading()
        landed = []
        controller.nextChange(nil)
        deadline = Date().addingTimeInterval(4)
        while (reading() == json["from"] as? String || landed.isEmpty) && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        // Before the change it went to is read (300 ms on screen).
        let destination = readers().first { ($0.window?.tabGroup?.selectedWindow ?? $0.window) === $0.window && $0.window?.title == reading() }
        json["to"] = reading()
        json["to_had_unread"] = destination?.model.unread ?? -1
        try? await Task.sleep(for: .milliseconds(300))
        json["landed"] = landed
        json["to_notice"] = await noticeText(destination)
        json["to_subtitle"] = destination?.window?.subtitle ?? ""
        json["badge_after_read"] = NSApp.dockTile.badgeLabel ?? ""
        json["showing_unread_after_read"] = readers().filter(\.showsUnread).count
        // Nothing unread anywhere: N has nowhere to go.
        for r in readers() { r.markAllRead(nil) }
        try? await Task.sleep(for: .milliseconds(900))
        json["went_with_none_left"] = app?.goToNextUnread(from: controller) ?? true
        json["badge_none"] = NSApp.dockTile.badgeLabel ?? ""
        write(json, to: out, "cross-document.json")
    }

    /// The page's notice in `reader`'s window ("" when none shows).
    private static func noticeText(_ reader: ReaderWindowController?) async -> String {
        guard let web = reader?.window?.contentView?.firstDescendant(ofType: WKWebView.self) else { return "" }
        let script = "document.getElementById('ro-notice').hidden ? '' : document.getElementById('ro-notice').textContent"
        return (try? await web.evaluateJavaScript(script)) as? String ?? ""
    }

    /// A file opened for the first time in a git repository, changed since
    /// its last commit: what changed since is marked, and the notice says
    /// against what. An untracked file beside it opens unmarked.
    private static func commitBaseline(out: URL) async {
        let env = ProcessInfo.processInfo.environment
        guard let tracked = env["READOUT_SMOKE_GIT_FILE"], let untracked = env["READOUT_SMOKE_GIT_UNTRACKED"] else { return }
        let app = NSApp.delegate as? AppDelegate
        var json: [String: Any] = ["tools": GitTools.available()]
        // What the lookup sees, so a failure can be explained. (This also
        // warms xcrun's lookup of git: the first git after a runner boots can
        // outlast the 1.5 s limit, which a reader's first open accepts.)
        let real = RealPath.of(tracked)
        let dir = (real as NSString).deletingLastPathComponent
        let current = (try? String(contentsOfFile: real, encoding: .utf8)) ?? ""
        let raw = ProcessGit().run(["--no-pager", "show", "HEAD:./" + (real as NSString).lastPathComponent], in: dir)
        let shell = ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/git --no-pager show HEAD:./notes.md 2>&1; echo exit=$?"], in: dir, timeout: 5, limit: 100_000)
        json["diagnostics"] = ["real": real, "repository": GitBaseline.repository(containing: real, exists: { FileManager.default.fileExists(atPath: $0) }) ?? "",
                               "raw_bytes": raw?.count ?? -1, "head_text": GitBaseline.headText(for: real, current: current, git: ProcessGit()) != nil,
                               "shell": shell.map { String(decoding: $0, as: UTF8.self) } ?? "(nil)"]
        for (name, path) in [("tracked", tracked), ("untracked", untracked)] {
            let url = URL(fileURLWithPath: path)
            app?.open(url, mode: .background)
            let deadline = Date().addingTimeInterval(10)
            while (firstPaintSamples[url.standardizedFileURL.path]?.isEmpty ?? true) && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(500))
            guard let reader = app?.reader(for: url), let web = reader.window?.contentView?.firstDescendant(ofType: WKWebView.self) else { continue }
            let state = (try? await web.evaluateJavaScript("JSON.stringify({ marks: document.querySelectorAll('.m-inserted, .m-modified').length, deletions: document.querySelectorAll('.del-mark').length, notice: document.getElementById('ro-notice').hidden ? '' : document.getElementById('ro-notice').textContent })")) as? String
            json[name] = ["unread": reader.model.unread, "page": state ?? ""]
            json["compare_" + name] = await compareWithLastCommit(reader, web: web)
            reader.window?.close()
        }
        // Outside a repository (a plan in /tmp/…/plans): the item is disabled.
        if let plan = env["READOUT_SMOKE_HOOK_PLAN"], let hooked = app?.reader(for: URL(fileURLWithPath: plan)) {
            json["compare_enabled_outside"] = hooked.validateMenuItem(NSMenuItem(title: "", action: #selector(ReaderWindowController.compareWithLastCommit(_:)), keyEquivalent: ""))
        }
        write(json, to: out, "git-baseline.json")
    }

    /// View ▸ Compare with Last Commit (N1) on a document in the repository:
    /// with everything read, the changes since the commit are marked again,
    /// with the notice; Edit ▸ Undo brings back what was read.
    private static func compareWithLastCommit(_ reader: ReaderWindowController, web: WKWebView) async -> [String: Any] {
        let item = NSMenuItem(title: "", action: #selector(ReaderWindowController.compareWithLastCommit(_:)), keyEquivalent: "")
        let marks = "document.querySelectorAll('.m-inserted:not(.m-read), .m-modified:not(.m-read)').length"
        let notice = "document.getElementById('ro-notice').hidden ? '' : document.getElementById('ro-notice').textContent"
        var json: [String: Any] = ["enabled": reader.validateMenuItem(item)]
        reader.markAllRead(nil)
        try? await Task.sleep(for: .milliseconds(500))
        json["unread_read"] = reader.model.unread
        // A reader chooses these from the menu, one event each, so each is an
        // undo group of its own; called here without an event in between,
        // they can share one, and Undo would take back Mark All as Read too
        // (the commit's marks again). Only the comparison is to be undone.
        reader.window?.undoManager?.removeAllActions()
        compared = []
        let before = appliedCount
        let shown = (try? await web.evaluateJavaScript(notice)) as? String ?? ""
        reader.compareWithLastCommit(nil)
        // Marked and applied, or only a notice instead (nothing to compare with).
        let deadline = Date().addingTimeInterval(10)
        while (compared.isEmpty || appliedCount == before) && Date() < deadline {
            if compared.isEmpty, ((try? await web.evaluateJavaScript(notice)) as? String ?? "") != shown { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(500))
        json["unread_compared"] = reader.model.unread
        json["marks_compared"] = (try? await web.evaluateJavaScript(marks)) as? Int ?? -1
        json["notice"] = (try? await web.evaluateJavaScript(notice)) as? String ?? ""
        json["subtitle"] = reader.window?.subtitle ?? ""
        let undo = reader.window?.undoManager
        json["undo_title"] = undo?.undoMenuItemTitle ?? ""
        if undo?.canUndo == true && !compared.isEmpty {
            undo?.undo()
            try? await Task.sleep(for: .milliseconds(800))
            json["unread_undone"] = reader.model.unread
            json["marks_undone"] = (try? await web.evaluateJavaScript(marks)) as? Int ?? -1
            json["notice_undone"] = (try? await web.evaluateJavaScript(notice)) as? String ?? "?"
            json["redo_title"] = undo?.redoMenuItemTitle ?? ""
        }
        return json
    }

    /// Compare with Last Commit marked the document (the notice it showed).
    private static var compared: [String] = []
    static func noteCompared(_ notice: String) {
        if outputDirectory != nil { compared.append(notice) }
    }

    /// Two documents restored as the tabs of one window, through the
    /// restoration path AppKit takes at launch (ReaderRestoration's coder,
    /// restoreWindow, the regrouping): the tab not in front comes back
    /// without the dot when it had been looked at (U1, a 3.7 regression).
    private static func restoredTabs(out: URL) async {
        let paths = (ProcessInfo.processInfo.environment["READOUT_SMOKE_RESTORE_FILES"] ?? "").split(separator: ":").map(String.init)
        guard paths.count == 2, let app = NSApp.delegate as? AppDelegate else { return }
        let states = [ReaderRestorationState(path: paths[0], group: "smoke-restore", tabIndex: 0, selected: true, seen: true),
                      ReaderRestorationState(path: paths[1], group: "smoke-restore", tabIndex: 1, selected: false, seen: true)]
        final class Box { var windows: [NSWindow] = [] }
        let box = Box()
        for (i, state) in states.enumerated() {
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            ReaderRestoration.encode(state, into: archiver)
            archiver.finishEncoding()
            guard let coder = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else { continue }
            coder.requiresSecureCoding = true
            ReaderRestoration.restoreWindow(withIdentifier: NSUserInterfaceItemIdentifier("reader-smoke-restore-\(i)"), state: coder) { w, _ in
                if let w { box.windows.append(w) }
            }
        }
        // AppKit orders restored windows in, then the launch regroups their tabs.
        box.windows.first?.orderFront(nil)
        app.regroupRestoredTabs()
        let readers = box.windows.compactMap { $0.windowController as? ReaderWindowController }
        let deadline = Date().addingTimeInterval(10)
        while readers.contains(where: { !$0.isLoaded }) && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(500))
        let group = box.windows.first?.tabGroup
        write(["restored": readers.count,
               "same_group": box.windows.count == 2 && box.windows.allSatisfy { $0.tabGroup === group && group != nil },
               "selected_first": group?.selectedWindow === box.windows.first,
               "tabs": readers.map { r -> [String: Any] in
                   ["file": r.url.lastPathComponent, "dot": r.window?.tab.accessoryView != nil, "looked_at": r.notedRecent,
                    "waiting": r.needsAttention, "key": r.window?.isKeyWindow ?? false,
                    "seen_kept": r.restorationState.seen]
               }], to: out, "restored-tabs.json")
        for w in box.windows { w.close() }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// While set (the smoke run's early print), a print records the number
    /// of blocks the page held when it would have begun, instead of a sheet.
    private static var capturingPrints = false
    private static var printedBlocks: [Int] = []

    /// Whether the print was recorded here (CI) instead of shown.
    static func capturePrint(_ webView: WKWebView) -> Bool {
        guard capturingPrints else { return false }
        Task { @MainActor in
            let n = (try? await webView.evaluateJavaScript("document.querySelectorAll('.blk').length")) as? Int
            printedBlocks.append(n ?? -1)
        }
        return true
    }

    /// ⌘P the moment a window opens, before its document has loaded: what
    /// prints is the document, not the empty page (3.7 review, finding 2).
    private static func earlyPrint(out: URL) async {
        // Not READOUT_SMOKE_SECOND: its opens are the warm-open samples (exactly three).
        guard let path = ProcessInfo.processInfo.environment["READOUT_SMOKE_GIT_FILE"] else { return }
        let url = URL(fileURLWithPath: path)
        let app = NSApp.delegate as? AppDelegate
        capturingPrints = true
        printedBlocks = []
        defer { capturingPrints = false }
        app?.open(url)
        guard let reader = app?.reader(for: url) else { return write(["opened": false], to: out, "early-print.json") }
        // The read runs off the main thread: it cannot have finished yet.
        let loadedWhenAsked = reader.isLoaded
        reader.printDocument(nil)
        reader.printDocument(nil)   // asked twice while loading: printed once
        let deadline = Date().addingTimeInterval(15)
        while printedBlocks.isEmpty && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .seconds(1))
        let web = reader.window?.contentView?.firstDescendant(ofType: WKWebView.self)
        let pageBlocks = (try? await web?.evaluateJavaScript("document.querySelectorAll('.blk').length")) as? Int
        write(["opened": true, "loaded_when_asked": loadedWhenAsked, "printed": printedBlocks,
               "page_blocks": pageBlocks ?? -1], to: out, "early-print.json")
        reader.window?.close()
    }

    private static func write(_ json: [String: Any], to dir: URL, _ name: String) {
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent(name))
        }
    }

    /// The smoke file is emptied and written again a second later (an agent
    /// truncating before it writes): the reader comes back to where it was.
    /// Also: a heading's link copies the file's full path with the anchor.
    private static func refill(controller: ReaderWindowController, webView: WKWebView, out: URL) async {
        controller.show()
        _ = try? await webView.evaluateJavaScript("(() => { const b = [...document.querySelectorAll('.blk')]; const t = b[Math.floor(b.length/2)]; window.scrollBy(0, t.getBoundingClientRect().top - 40); window.__refill = {slot: +t.dataset.slot, top: t.getBoundingClientRect().top}; return 1; })()")
        // The page reports its place a moment after scrolling settles.
        try? await Task.sleep(for: .seconds(1.2))
        // Diagnostics, so a failure can be explained: where the page was, the
        // anchor block and the blocks above it, and what else is in the flow.
        let state = "(() => { const r = window.__refill; const b = [...document.querySelectorAll('#ro-doc > .chunk > .blk')]; const i = r ? b.findIndex(e => +e.dataset.slot === r.slot) : -1; const e = i >= 0 ? b[i] : null; return JSON.stringify({ scrollY: Math.round(scrollY), scrollHeight: document.scrollingElement.scrollHeight, innerHeight, anchorTop: e ? Math.round(e.getBoundingClientRect().top * 10) / 10 : null, captured: window.readout.captureAnchor(), above: (i >= 0 ? b.slice(0, i) : []).map(x => [+x.dataset.slot, x.className.replace(/^blk /, ''), Math.round(x.getBoundingClientRect().height)]), extra: [...document.querySelectorAll('#ro-doc > :not(.blk)')].map(x => [x.id || x.className, Math.round(x.getBoundingClientRect().height)]) }); })()"
        func pageState() async -> Any? {
            guard let text = try? await webView.evaluateJavaScript(state) as? String, let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        let stateBefore = await pageState()
        let started = Date()
        let before = appliedCount
        mark(out, "await-refill")
        let deadline = Date().addingTimeInterval(15)
        // The empty patch, then the refill: wait until the block is back and
        // no further patch arrived for a while (a read can catch the refill
        // half written and a second one completes it).
        let blockBack = "(() => { const r = window.__refill; return !!(r && document.querySelector('.blk[data-slot=\"' + r.slot + '\"]')); })()"
        var settled = (count: -1, at: Date())
        while Date() < deadline {
            if appliedCount != settled.count { settled = (appliedCount, Date()) }
            if appliedCount >= before + 2, Date().timeIntervalSince(settled.at) > 0.6,
               (try? await webView.evaluateJavaScript(blockBack)) as? Bool == true { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Two frames: the page's restore and any fallback scheduled on the next frame have run.
        _ = try? await webView.callAsyncJavaScript("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return 1", contentWorld: .page)
        // Lazy renderers (math, diagrams) settle; the page compensates for their height.
        try? await Task.sleep(for: .seconds(1))
        let shift = try? await webView.evaluateJavaScript("(() => { const r = window.__refill; const e = r && document.querySelector('.blk[data-slot=\"' + r.slot + '\"]'); return e ? e.getBoundingClientRect().top - r.top : null; })()")
        var json: [String: Any] = ["applies": appliedCount - before]
        if let shift = shift as? Double { json["shift"] = shift }
        // What moved the page, and when (page time, ms): patches, compensation,
        // resize holds, and the app's fallback restore (scrollToAnchor).
        if let s = stateBefore { json["before"] = s }
        if let s = await pageState() { json["after"] = s }
        if let text = try? await webView.evaluateJavaScript("JSON.stringify(window.readout.trace ? window.readout.trace() : [])") as? String,
           let data = text.data(using: .utf8), let trace = try? JSONSerialization.jsonObject(with: data) {
            json["trace"] = trace
        }
        if let now = try? await webView.evaluateJavaScript("Math.round(performance.now())") as? Double { json["page_now_ms"] = now }
        json["seconds_waited"] = Date().timeIntervalSince(started)

        // Copy Link to Section from a heading's context menu (3.9 E9: no
        // hover § any more), and none in a paragraph's.
        let contextMenu: (String) async -> NSMenuItem? = { selector in
            _ = try? await webView.evaluateJavaScript("document.querySelector('\(selector)')?.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }))")
            try? await Task.sleep(for: .milliseconds(300))
            let menu = NSMenu()
            (webView as? ReaderWebView)?.onContextMenu?(menu)
            return menu.items.first { $0.action == #selector(ReaderWindowController.copyLinkToSection(_:)) }
        }
        NSPasteboard.general.clearContents()
        json["section_link_on_paragraph"] = await contextMenu("#ro-doc > .chunk > .k-paragraph p") != nil
        if let item = await contextMenu("#ro-doc > .chunk > .k-heading h1, #ro-doc > .chunk > .k-heading h2"), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
        json["copied_link"] = NSPasteboard.general.string(forType: .string) ?? ""
        json["link_prefix"] = controller.url.path + "#"
        json["hover_link_buttons"] = (try? await webView.evaluateJavaScript("document.querySelectorAll('.h-link').length")) as? Int ?? -1
        write(json, to: out, "refill.json")
    }

    /// The window around a document: title, tab title and tooltip, subtitle,
    /// the toolbar (the next-change button, the find field) and how it tabs.
    private static func chrome(_ reader: ReaderWindowController) -> [String: Any] {
        let items = reader.window?.toolbar?.items ?? []
        let item = items.first { $0.itemIdentifier == .nextChange }
        let search = items.compactMap { $0 as? NSSearchToolbarItem }.first
        return ["title": reader.window?.title ?? "", "tab_title": reader.window?.tab.title ?? "",
                "tab_tooltip": reader.window?.tab.toolTip ?? "", "path": reader.url.path,
                "subtitle": reader.window?.subtitle ?? "", "status": reader.model.status ?? "", "unread": reader.model.unread,
                "toolbar": items.map(\.itemIdentifier.rawValue),
                "search_width": search.map { Double($0.preferredWidthForSearchField) } ?? -1,
                // What the field is drawn at (macOS 26 grew it past the preferred width).
                "search_field_width": search.map { Double($0.searchField.frame.width) } ?? -1,
                "tabbing_automatic": reader.window?.tabbingMode == .automatic,
                "tab_bar_visible": reader.window?.tabGroup?.isTabBarVisible ?? false,
                "folder": reader.url.deletingLastPathComponent().lastPathComponent,
                "change_item": ["present": item != nil, "hidden": item?.isHidden ?? true, "enabled": item?.isEnabled ?? false]]
    }

    /// ⌘K, then Edit ▸ Undo through the menu as the reader would choose it:
    /// the marks come back, with the page showing them.
    private static func undoMarkAllRead(controller: ReaderWindowController, webView: WKWebView, out: URL) async {
        controller.show()
        try? await Task.sleep(for: .milliseconds(300))
        let marks = "document.querySelectorAll('.m-inserted, .m-modified, .m-state, .del-mark').length"
        // Undo shows the document again with new slots: the edit check's anchor is done with.
        _ = try? await webView.evaluateJavaScript("delete window.__smoke; 1")
        var json: [String: Any] = ["unread_before": controller.model.unread]
        json["page_marks_before"] = (try? await webView.evaluateJavaScript(marks)) as? Int ?? -1
        controller.markAllRead(nil)
        try? await Task.sleep(for: .milliseconds(300))
        json["unread_after_mark"] = controller.model.unread
        let edit = NSApp.mainMenu?.items.first { $0.submenu?.title == NSLocalizedString("Edit", comment: "Menu") }?.submenu
        let undoItem = edit?.items.first { $0.action == Selector(("undo:")) }
        let redoItem = edit?.items.first { $0.action == Selector(("redo:")) }
        // What the menu does for the key window, walked by hand: the CI runner
        // may not let Readout become active, and without a key window
        // NSApp.sendAction finds no target at all.
        func handler(_ item: NSMenuItem?) -> NSResponder? {
            guard let action = item?.action else { return nil }
            var r = controller.window?.firstResponder
            while let current = r {
                if current.responds(to: action) { return current }
                r = current.nextResponder
            }
            return nil
        }
        func validate(_ item: NSMenuItem?) -> Bool {
            guard let item, let target = handler(item) else { return false }
            if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) }
            if let v = target as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
            return true
        }
        json["app_active"] = NSApp.isActive
        json["undo_handler"] = handler(undoItem).map { String(describing: type(of: $0)) } ?? ""
        json["undo_enabled"] = validate(undoItem)
        json["undo_title"] = undoItem?.title ?? ""
        let before = appliedCount
        if let undoItem, let action = undoItem.action, let target = handler(undoItem) {
            json["undo_sent"] = NSApp.sendAction(action, to: target, from: undoItem)
        }
        let deadline = Date().addingTimeInterval(5)
        while appliedCount == before && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .milliseconds(500))
        json["unread_after_undo"] = controller.model.unread
        json["page_marks_after_undo"] = (try? await webView.evaluateJavaScript(marks)) as? Int ?? -1
        // The outline shows where the unread changes are: a dot on those sections' rows.
        json["outline_entries"] = controller.model.toc.count
        json["outline_unread"] = controller.model.toc.filter { controller.model.unreadSections.contains($0.slot) }.map(\.title)
        json["tab_dot"] = controller.window?.tab.accessoryView != nil
        try? await Task.sleep(for: .milliseconds(300))
        windowShot(controller.window, out, "sidebar-unread")
        _ = validate(redoItem)
        json["redo_title"] = redoItem?.title ?? ""
        write(json, to: out, "undo.json")
    }

    /// A readout: URL other than the reader page (a relative link opened in
    /// the web view, as the context menu's Open Link did) must not replace the
    /// document; the context menu offers no item that opens a link in the web
    /// view, and copies a link only when it leads to the web.
    private static func navigationStaysOnTheReader(webView: WKWebView, out: URL) async {
        let blocks = "document.querySelectorAll('.blk').length"
        var json: [String: Any] = ["blocks_before": (try? await webView.evaluateJavaScript(blocks)) as? Int ?? -1]
        _ = try? await webView.evaluateJavaScript("location.href = 'readout://app/other-plan.md'; 1")
        try? await Task.sleep(for: .seconds(1))
        json["href"] = (try? await webView.evaluateJavaScript("location.href")) as? String ?? ""
        // Tab reaches links, not only ⌥Tab.
        json["tab_focuses_links"] = webView.configuration.preferences.tabFocusesLinks
        json["blocks_after"] = (try? await webView.evaluateJavaScript(blocks)) as? Int ?? -1
        // The link a context menu opens on, as the app's script reports it.
        func contextLink(_ href: String) async -> String {
            let script = "(() => { const a = document.createElement('a'); a.href = '\(href)'; a.textContent = 'x'; document.body.appendChild(a); a.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true})); a.remove(); return 1; })()"
            _ = try? await webView.evaluateJavaScript(script)
            try? await Task.sleep(for: .milliseconds(300))
            return (webView as? ReaderWebView)?.contextLink ?? ""
        }
        func filtered(_ link: String?) -> [String] {
            let menu = NSMenu()
            for id in ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
                       "WKMenuItemIdentifierCopyLink", "-", "WKMenuItemIdentifierCopy", "-", "WKMenuItemIdentifierLookUp", "-"] {
                if id == "-" { menu.addItem(.separator()); continue }
                let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(id)
                menu.addItem(item)
            }
            ReaderWebView.filterContextMenu(menu, linkURL: link)
            return menu.items.map { $0.isSeparatorItem ? "-" : ($0.identifier?.rawValue ?? "") }
        }
        let web = await contextLink("https://example.com/readout")
        let relative = await contextLink("other-plan.md")
        json["context_link_web"] = web
        json["context_link_relative"] = relative
        json["context_menu_web"] = filtered(web.isEmpty ? nil : web)
        json["context_menu"] = filtered(relative.isEmpty ? nil : relative)
        write(json, to: out, "navigation.json")
    }

    /// The document in front (the selected tab of the frontmost reader window).
    private static func reading() -> String {
        let front = NSApp.orderedWindows.first { $0.windowController is ReaderWindowController }
        return (front?.tabGroup?.selectedWindow ?? front)?.title ?? ""
    }

    /// A file under /tmp (FSEvents reports /private/tmp) and a symlink pointed
    /// at another file must both follow what is on disk.
    private static func liveUpdates(app: AppDelegate?, out: URL) async {
        let env = ProcessInfo.processInfo.environment
        var result: [String: Any] = [:]
        for (name, variable, marker) in [("tmp", "READOUT_SMOKE_TMP_FILE", "await-tmp-edit"),
                                         ("link", "READOUT_SMOKE_LINK_FILE", "await-retarget")] {
            guard let path = env[variable] else { continue }
            let url = URL(fileURLWithPath: path)
            app?.open(url)
            guard let reader = app?.reader(for: url) else {
                result[name] = ["error": "no window"]
                continue
            }
            var deadline = Date().addingTimeInterval(10)
            while reader.model.title.isEmpty && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            let before = reader.model.title
            let shownBefore = WorkspaceIndex.realPath(path)
            reader.saveNow()   // a record for what it shows now
            try? await Task.sleep(for: .milliseconds(300))
            mark(out, marker)
            var earlyRecord: Bool?
            if name == "link" {
                // Retargeted, but the new file not read yet: a save now must not
                // store the old file's state under the new key.
                deadline = Date().addingTimeInterval(10)
                func retargetSeen() -> Bool { WorkspaceIndex.realPath(path) != shownBefore && app?.reader(for: url) === reader }
                while !retargetSeen() && Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
                if reader.model.title == before {
                    reader.saveNow()
                    BaselineStore.flush()
                    earlyRecord = FileManager.default.fileExists(atPath: BaselineStore.recordFiles(for: url).current.path)
                }
            }
            deadline = Date().addingTimeInterval(10)
            while reader.model.title == before && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            var entry: [String: Any] = ["before": before, "after": reader.model.title]
            if let earlyRecord { entry["early_record"] = earlyRecord }
            if name == "tmp" { entry["chrome"] = chrome(reader) }
            if shownBefore != WorkspaceIndex.realPath(path) {
                // A retargeted link: the window is found through the link and no longer through the old target.
                deadline = Date().addingTimeInterval(3)
                while app?.reader(for: url) !== reader && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                entry["found_through_link"] = app?.reader(for: url) === reader
                entry["old_target_free"] = app?.reader(for: URL(fileURLWithPath: shownBefore)) == nil
                // Its reading state is saved under the new target's key, record included.
                reader.saveNow()
                BaselineStore.flush()
                entry["record_at_new_target"] = FileManager.default.fileExists(atPath: BaselineStore.recordFiles(for: url).current.path)
            }
            result[name] = entry
        }
        // A link retargeted to a file another window already shows: that window
        // keeps the path, the link's window stays owned (saved on quit).
        if let path = env["READOUT_SMOKE_COLLIDE_LINK"], let otherPath = env["READOUT_SMOKE_COLLIDE_TARGET"] {
            let url = URL(fileURLWithPath: path), otherURL = URL(fileURLWithPath: otherPath)
            app?.open(otherURL)
            app?.open(url)
            if let reader = app?.reader(for: url), let other = app?.reader(for: otherURL), reader !== other {
                var deadline = Date().addingTimeInterval(10)
                while (reader.model.title.isEmpty || other.model.title.isEmpty) && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let before = reader.model.title
                try? await Task.sleep(for: .milliseconds(300))
                mark(out, "await-collide")
                deadline = Date().addingTimeInterval(10)
                while reader.model.title == before && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(500))
                result["collide"] = ["before": before, "after": reader.model.title,
                                     "owned": app?.owns(reader) == true,
                                     "target_window_kept": app?.reader(for: otherURL) === other]
            } else {
                result["collide"] = ["error": "no window"]
            }
        }
        // `ln -sf ../runs/run-46.md next.md` before run-46.md is written, then
        // the agent writes it: the window follows, saves resume, and opening
        // the link again finds the same window.
        if let path = env["READOUT_SMOKE_DANGLE_LINK"] {
            let url = URL(fileURLWithPath: path)
            app?.open(url)
            if let reader = app?.reader(for: url) {
                var deadline = Date().addingTimeInterval(10)
                while reader.model.title.isEmpty && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                let before = reader.model.title
                try? await Task.sleep(for: .milliseconds(300))
                mark(out, "await-dangle")
                deadline = Date().addingTimeInterval(15)
                while reader.model.title == before && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(500))
                app?.open(url, mode: .background)
                reader.saveNow()
                BaselineStore.flush()
                result["dangle"] = ["before": before, "after": reader.model.title, "status": reader.model.status ?? "",
                                    "same_window": app?.reader(for: url) === reader,
                                    "record_at_new_target": FileManager.default.fileExists(atPath: BaselineStore.recordFiles(for: url).current.path)]
            } else {
                result["dangle"] = ["error": "no window"]
            }
        }
        // A file that cannot be read says so in the title bar, not only in the sidebar.
        if let path = env["READOUT_SMOKE_UNREADABLE"] {
            let url = URL(fileURLWithPath: path)
            app?.open(url, mode: .background)
            if let reader = app?.reader(for: url) {
                let deadline = Date().addingTimeInterval(10)
                while reader.model.status == nil && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(200))
                var entry = chrome(reader)
                // The page says why in its empty state, not a blank page.
                let readerWeb = reader.window?.contentView?.firstDescendant(ofType: WKWebView.self)
                for _ in 0..<40 {
                    if let text = (try? await readerWeb?.evaluateJavaScript("document.getElementById('ro-empty')?.textContent ?? ''")) as? String, !text.isEmpty {
                        entry["page_empty_text"] = text
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                result["unreadable"] = entry
            } else {
                result["unreadable"] = ["error": "no window"]
            }
        }
        // A pre-3.3 record (keyed by the path as spelled, /tmp/...) is read once and moved.
        if let tmpPath = env["READOUT_SMOKE_TMP_FILE"] {
            let url = URL(fileURLWithPath: tmpPath).deletingLastPathComponent().appendingPathComponent("legacy-record.md")
            let files = BaselineStore.recordFiles(for: url)
            let record = BaselineStore.Record(baseline: [], topBlockIndex: 3, topOffset: 0, topExcerpt: nil, savedAt: Date())
            // Its reading position, saved later in a file of its own, must survive the move.
            let position: [String: Any] = ["topBlockIndex": 5, "topOffset": 0, "savedAt": Date().timeIntervalSinceReferenceDate + 10]
            if files.current != files.legacy, let data = try? JSONEncoder().encode(record),
               let positionData = try? JSONSerialization.data(withJSONObject: position) {
                try? data.write(to: files.legacy)
                try? positionData.write(to: files.legacyPosition)
                let fm = FileManager.default
                // A copy that cannot be written (a folder in the way) keeps the old record.
                try? fm.createDirectory(at: files.current, withIntermediateDirectories: true)
                _ = BaselineStore.load(url)
                BaselineStore.flush()
                let keptOnFailure = fm.fileExists(atPath: files.legacy.path)
                try? fm.removeItem(at: files.current)
                let loaded = BaselineStore.load(url)
                BaselineStore.flush()
                let reloaded = BaselineStore.load(url)   // now from the new key
                result["legacy"] = ["loaded": loaded?.topBlockIndex == 5, "kept_on_failure": keptOnFailure,
                                    "position_kept": reloaded?.topBlockIndex == 5,
                                    "old_position_removed": !fm.fileExists(atPath: files.legacyPosition.path),
                                    "moved": fm.fileExists(atPath: files.current.path),
                                    "old_removed": !fm.fileExists(atPath: files.legacy.path)]
            } else {
                result["legacy"] = ["error": "same key"]
            }
        }
        guard !result.isEmpty, let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: out.appendingPathComponent("live-updates.json"))
    }

    /// `readout -b` (a new file) and `readout --hook` (a file already open in a
    /// tab behind) must leave the tab being read in front.
    private static func backgroundOpens(out: URL) async {
        guard let file = ProcessInfo.processInfo.environment["READOUT_SMOKE_CLI_FILE"] else { return }
        try? await Task.sleep(for: .milliseconds(500))
        let before = reading()
        mark(out, "await-cli")
        var deadline = Date().addingTimeInterval(15)
        while backgroundRequests.count < 5 && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        deadline = Date().addingTimeInterval(5)
        let name = URL(fileURLWithPath: file).lastPathComponent
        while !NSApp.windows.contains(where: { $0.title == name }) && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .seconds(1))
        var json: [String: Any] = ["requests": backgroundRequests.map { URL(fileURLWithPath: $0).lastPathComponent },
                                   "reading_before": before, "reading_after": reading(),
                                   "opened": NSApp.windows.contains { $0.title == name },
                                   // Opened behind and never in front: not in Open Recent.
                                   "in_recents": NSDocumentController.shared.recentDocumentURLs.contains { $0.lastPathComponent == name }]
        // Opened as a tab: with the tab bar showing, the subtitle leaves the folder to the tab's tooltip.
        if let reader = (NSApp.delegate as? AppDelegate)?.reader(for: URL(fileURLWithPath: file)) { json["chrome"] = chrome(reader) }
        // A plan outside its project (hooked.md), opened by the hook without a
        // folder and then with the project's: its code reference resolves there,
        // and the folder is kept for the next launch.
        if let plan = ProcessInfo.processInfo.environment["READOUT_SMOKE_HOOK_PLAN"],
           let reader = (NSApp.delegate as? AppDelegate)?.reader(for: URL(fileURLWithPath: plan)),
           let web = reader.window?.contentView?.firstDescendant(ofType: WKWebView.self) {
            let link = "document.querySelector('code.path-link')?.dataset.path ?? ''"
            var resolved = ""
            deadline = Date().addingTimeInterval(10)
            while resolved.isEmpty && Date() < deadline {
                resolved = (try? await web.evaluateJavaScript(link)) as? String ?? ""
                if resolved.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            }
            BaselineStore.flush()
            json["hook_root"] = ["resolved": resolved, "kept": BaselineStore.projectRoot(for: URL(fileURLWithPath: plan)) ?? "",
                                 "marks": (try? await web.evaluateJavaScript("document.querySelectorAll('.m-inserted, .m-modified').length")) as? Int ?? -1]
            // Outside its project: the window says which project it is for (subtitle, tooltip).
            json["hook_chrome"] = chrome(reader)
            // Opened behind, never looked at, nothing unread: its tab still has the dot.
            json["hook_tab"] = ["unread": reader.model.unread, "dot": reader.window?.tab.accessoryView != nil,
                                "noted_recent": reader.notedRecent, "key": reader.window?.isKeyWindow ?? false]
        }
        // Cursor's hook (top-level file_path, workspace_roots): opened, with the workspace as its project.
        if let plan = ProcessInfo.processInfo.environment["READOUT_SMOKE_CURSOR_PLAN"] {
            let url = URL(fileURLWithPath: plan)
            BaselineStore.flush()
            json["cursor"] = ["opened": (NSApp.delegate as? AppDelegate)?.reader(for: url) != nil,
                              "root": BaselineStore.projectRoot(for: url) ?? ""]
        }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("background-opens.json"))
        }
    }

    /// The document opened with `readout -b`, given a new section since, in a
    /// tab behind the smoke document: its tab carries the unread dot; the
    /// tab being read only while it has unread changes of its own.
    private static func tabDot(controller: ReaderWindowController, out: URL) async {
        guard let file = ProcessInfo.processInfo.environment["READOUT_SMOKE_CLI_FILE"],
              let behind = (NSApp.delegate as? AppDelegate)?.reader(for: URL(fileURLWithPath: file)),
              let main = controller.window, let other = behind.window else { return }
        controller.show()
        if other.tabGroup !== main.tabGroup || main.tabGroup == nil { main.addTabbedWindow(other, ordered: .above) }
        main.tabGroup?.selectedWindow = main
        try? await Task.sleep(for: .seconds(1))
        // Two documents with the same title (H1) in the same tab group: their tabs name the files.
        let app = NSApp.delegate as? AppDelegate
        let dups = (ProcessInfo.processInfo.environment["READOUT_SMOKE_DUP_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        for d in dups { app?.open(d, mode: .background) }
        let deadline = Date().addingTimeInterval(10)
        while dups.contains(where: { app?.reader(for: $0)?.documentTitle.hasPrefix("Same") != true }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(500))
        let group = main.tabGroup?.windows ?? [main]
        write(["behind_unread": behind.model.unread, "behind_dot": other.tab.accessoryView != nil,
               "behind_outline_unread": behind.model.toc.filter { behind.model.unreadSections.contains($0.slot) }.map(\.title),
               "front_unread": controller.model.unread, "front_dot": main.tab.accessoryView != nil,
               "front_noted_recent": controller.notedRecent,
               "tab_bar_visible": main.tabGroup?.isTabBarVisible ?? false,
               // With the tab bar showing, the page's inset follows the toolbar's edge (contentLayoutRect).
               "inset": controller.topInsetState,
               "tab_titles": group.map(\.tab.title),
               "dup_titles": dups.compactMap { app?.reader(for: $0)?.window?.tab.title },
               "dup_in_group": dups.allSatisfy { d in group.contains { $0 === app?.reader(for: d)?.window } }], to: out, "tab-dot.json")
        windowShot(main, out, "tabs-unread")
    }

    /// `found` events the page sent (each search tells its count).
    private static var foundCount = 0
    static func noteFound() { if outputDirectory != nil { foundCount += 1 } }

    /// The find field finds in the page (find.js): Return selects a match and
    /// the field says which of how many, Return again goes on, Escape takes the
    /// marks away. Then in a window whose page is not up yet (the pool's spare
    /// went to the window opened just before): a search cleared meanwhile never
    /// runs, one left is made once its document is in the page.
    private static func findInPage(controller: ReaderWindowController, webView: WKWebView, out: URL) async {
        func field(_ c: ReaderWindowController?) -> FindField? {
            c?.window?.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first?.searchField as? FindField
        }
        // The search `act` starts, and the count the page tells after it (a
        // new event: a single match wraps to the same "1 of 1").
        func counted(_ f: FindField, _ act: () -> Void) async -> String {
            let seen = foundCount
            act()
            let deadline = Date().addingTimeInterval(10)
            while foundCount == seen && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            return f.count
        }
        guard let f = field(controller) else { return write(["error": "no find field"], to: out, "find.json") }
        // A word of the block in the middle of the window.
        let word = (try? await webView.evaluateJavaScript("(() => { const b = document.elementFromPoint(innerWidth / 2, innerHeight / 2)?.closest('.blk') || document.querySelector('.blk'); return (b.textContent.match(/[A-Za-z]{5,}/) || ['Readout'])[0]; })()") as? String) ?? "Readout"
        controller.showFind(nil)
        f.stringValue = word
        let enter = #selector(NSResponder.insertNewline(_:))
        let first = await counted(f) { _ = controller.control(f, textView: NSTextView(), doCommandBy: enter) }
        try? await Task.sleep(for: .milliseconds(300))   // selected once the landing is painted
        let selected = (try? await webView.evaluateJavaScript("getSelection().toString()") as? String) ?? ""
        let second = await counted(f) { _ = controller.control(f, textView: NSTextView(), doCommandBy: enter) }
        _ = controller.control(f, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        try? await Task.sleep(for: .milliseconds(300))
        let marks = (try? await webView.evaluateJavaScript("CSS.highlights.size") as? NSNumber)?.intValue ?? -1
        var json: [String: Any] = ["word": word, "first": first, "second": second, "selected": selected,
                                   "after_escape": f.count, "marks_after_escape": marks]
        f.stringValue = ""
        if let tmp = ProcessInfo.processInfo.environment["READOUT_SMOKE_TMP_FILE"] {
            let dir = URL(fileURLWithPath: tmp).deletingLastPathComponent()
            let app = NSApp.delegate as? AppDelegate
            app?.open(dir.appendingPathComponent("cold-a.md"))
            app?.open(dir.appendingPathComponent("cold-b.md"))
            app?.open(dir.appendingPathComponent("cold-c.md"))
            let b = app?.reader(for: dir.appendingPathComponent("cold-b.md")), c = app?.reader(for: dir.appendingPathComponent("cold-c.md"))
            // Searched and cleared before its document is in the page: the search never runs.
            if let c, let cf = field(c) {
                json["cleared_loaded_at_search"] = c.isLoaded
                c.showFind(nil)
                cf.stringValue = "cold"
                c.findNext(nil)
                cf.stringValue = ""
                c.searchFieldDidEndSearching(cf)
            }
            if let b, let bf = field(b) {
                json["cold_loaded_at_search"] = b.isLoaded
                b.showFind(nil)
                bf.stringValue = "cold"
                json["cold"] = await counted(bf) { b.findNext(nil) }
            }
            if let c, let cf = field(c) {
                let deadline = Date().addingTimeInterval(10)
                while !c.isLoaded && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .seconds(1))
                json["cold_cleared"] = cf.count
            }
        }
        write(json, to: out, "find.json")
    }

    private static func mark(_ dir: URL, _ name: String) {
        try? Data().write(to: dir.appendingPathComponent(name))
    }

    /// One window, without its shadow: `screencapture -l` (no desktop around it).
    private static func windowShot(_ window: NSWindow?, _ dir: URL, _ name: String) {
        guard let window else { return }
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), dir.appendingPathComponent("\(name).png").path]
        try? shot.run()
        shot.waitUntilExit()
    }

    private static func screen(_ dir: URL, _ name: String) {
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", dir.appendingPathComponent("\(name).screen.png").path]
        try? shot.run()
        shot.waitUntilExit()
    }

    private static func capture(_ webView: WKWebView, window: NSWindow?, to dir: URL, name: String) async {
        let stats = try? await webView.evaluateJavaScript("""
            JSON.stringify({
              blocks: document.querySelectorAll('.blk').length,
              highlighted: document.querySelectorAll('.code-block[data-hl="done"]').length,
              math: document.querySelectorAll('.math.done, .math-block.done').length,
              mermaid: document.querySelectorAll('.mermaid-block.done').length,
              marks: document.querySelectorAll('.m-inserted, .m-modified, .m-state').length,
              deletions: document.querySelectorAll('.del-mark').length,
              anchorShift: window.__smoke ? (document.querySelector('.blk[data-slot="' + window.__smoke.slot + '"]').getBoundingClientRect().top - window.__smoke.top) : null,
              theme: document.documentElement.dataset.theme,
              firstTop: (() => { const b = document.querySelector('.blk'); return b ? Math.round(b.getBoundingClientRect().top) : null; })(),
              scrollY: Math.round(scrollY),
              innerHeight,
              topInsetVar: getComputedStyle(document.documentElement).getPropertyValue('--top-inset'),
              title: document.title,
              early: document.body.innerText.includes('EARLY-EDIT-OK'),
              diffDel: [...document.querySelectorAll('.wd-panel del')].map(e => e.textContent),
              diffIns: [...document.querySelectorAll('.wd-panel ins')].map(e => e.textContent)
            })
            """)
        if let s = stats as? String {
            try? s.write(to: dir.appendingPathComponent("\(name).json"), atomically: true, encoding: .utf8)
        }
        let config = WKSnapshotConfiguration()
        if let image = try? await webView.takeSnapshot(configuration: config),
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        screen(dir, name)
        if let window {
            let info = "frame=\(NSStringFromRect(window.frame)) title=\(window.title) subtitle=\(window.subtitle)"
            try? info.write(to: dir.appendingPathComponent("\(name).window.txt"), atomically: true, encoding: .utf8)
        }
    }
}

extension NSView {
    /// The first view of `type` in this view's subtree (the smoke test finds a window's web view).
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for sub in subviews {
            if let match = sub as? T ?? sub.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}
