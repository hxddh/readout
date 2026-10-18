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

    /// Timings for tools/smoke-run.py, which adds its own clock readings.
    private static func writeTimings(_ dir: URL) {
        let json: [String: Any] = ["applied_at": appliedAt, "painted_at": paintedAt, "first_paint_s": firstPaint,
                                   "first_paint_samples_s": firstPaintSamples, "first_apply_samples_s": firstApplySamples]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("timings-app.json"))
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
            // The second, Chinese pass (tools/smoke-run.py): menus and windows only.
            if ProcessInfo.processInfo.environment["READOUT_SMOKE_PASS"] == "zh" {
                await localePass(controller: controller, out: out)
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .seconds(3))
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
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0); 1")
            try? await Task.sleep(for: .milliseconds(500))
            // The next-change button's image as drawn in an active window (the
            // CI runner's windows are inactive, which greys toolbar items).
            badgeShot(out)
            // Open what changed in the edited table (the edit mark's action).
            _ = try? await webView.evaluateJavaScript("(() => { const t = document.querySelector('.blk.k-table.m-modified'); return t ? window.readout.toggleDiff(+t.dataset.slot) : false; })()")
            try? await Task.sleep(for: .milliseconds(300))
            await capture(webView, window: controller.window, to: out, name: "3-marks")
            await undoMarkAllRead(controller: controller, webView: webView, out: out)
            await copyAsQuote(controller: controller, webView: webView, out: out)
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
                    // The pool makes its next spare page a second after one is taken.
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
            await findModeSwitches(controller: controller, out: out)
            writeMenus(out)
            app?.showSettings(nil)
            try? await Task.sleep(for: .seconds(1.5))
            screen(out, "5-settings")
            let settingsWindow = NSApp.windows.first { $0.contentViewController is NSHostingController<SettingsView> }
            var aux: [String: Any] = ["settings_tabbing_disallowed": settingsWindow?.tabbingMode == .disallowed]
            settingsWindow?.close()
            app?.showWelcome(nil)
            try? await Task.sleep(for: .seconds(1.5))
            screen(out, "6-welcome")
            if let welcome = NSApp.windows.first(where: { $0.contentViewController is NSHostingController<WelcomeView> }) {
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
        }
        write(json, to: out, "scroll-edge.json")
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0); 1")
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
            (() => { const b = [...document.querySelectorAll('#ro-doc > .blk.k-paragraph')].filter(e => e.textContent.trim().length > 20);
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
        _ = try? await webView.evaluateJavaScript("getSelection().removeAllRanges(); 1")
        try? await Task.sleep(for: .milliseconds(300))
        write(["picked": picked ?? NSNull(), "enabled": enabled, "text": text,
               "enabled_after_deselect": controller.validateMenuItem(item),
               "path": ReaderChrome.tabToolTip(path: controller.url.path)], to: out, "copy-quote.json")
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
                                   "showing_unread_before": readers().filter(\.showsUnread).count]
        controller.markAllRead(nil)
        try? await Task.sleep(for: .milliseconds(900))
        json["from"] = reading()
        landed = []
        controller.nextChange(nil)
        let deadline = Date().addingTimeInterval(4)
        while (reading() == json["from"] as? String || landed.isEmpty) && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        // Before the change it went to is read (300 ms on screen).
        let destination = readers().first { ($0.window?.tabGroup?.selectedWindow ?? $0.window) === $0.window && $0.window?.title == reading() }
        json["to"] = reading()
        json["to_had_unread"] = destination?.model.unread ?? -1
        try? await Task.sleep(for: .milliseconds(300))
        json["landed"] = landed
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

    /// A file opened for the first time in a git repository, changed since
    /// its last commit: what changed since is marked, and the notice says
    /// against what. An untracked file beside it opens unmarked.
    private static func commitBaseline(out: URL) async {
        let env = ProcessInfo.processInfo.environment
        guard let tracked = env["READOUT_SMOKE_GIT_FILE"], let untracked = env["READOUT_SMOKE_GIT_UNTRACKED"] else { return }
        let app = NSApp.delegate as? AppDelegate
        var json: [String: Any] = ["tools": GitTools.available()]
        for (name, path) in [("tracked", tracked), ("untracked", untracked)] {
            let url = URL(fileURLWithPath: path)
            app?.open(url, mode: .background)
            let deadline = Date().addingTimeInterval(10)
            while (firstPaintSamples[url.standardizedFileURL.path]?.isEmpty ?? true) && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(500))
            guard let reader = app?.reader(for: url), let web = reader.window?.contentView?.firstDescendant(ofType: WKWebView.self) else { continue }
            let state = (try? await web.evaluateJavaScript("JSON.stringify({ marks: document.querySelectorAll('.m-inserted, .m-modified').length, deletions: document.querySelectorAll('.del-mark').length, notice: document.getElementById('ro-notice').hidden ? '' : document.getElementById('ro-notice').textContent })")) as? String
            json[name] = ["unread": reader.model.unread, "page": state ?? ""]
            reader.window?.close()
        }
        write(json, to: out, "git-baseline.json")
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
        let state = "(() => { const r = window.__refill; const b = [...document.querySelectorAll('#ro-doc > .blk')]; const i = r ? b.findIndex(e => +e.dataset.slot === r.slot) : -1; const e = i >= 0 ? b[i] : null; return JSON.stringify({ scrollY: Math.round(scrollY), scrollHeight: document.scrollingElement.scrollHeight, innerHeight, anchorTop: e ? Math.round(e.getBoundingClientRect().top * 10) / 10 : null, captured: window.readout.captureAnchor(), above: (i >= 0 ? b.slice(0, i) : []).map(x => [+x.dataset.slot, x.className.replace(/^blk /, ''), Math.round(x.getBoundingClientRect().height)]), extra: [...document.querySelectorAll('#ro-doc > :not(.blk)')].map(x => [x.id || x.className, Math.round(x.getBoundingClientRect().height)]) }); })()"
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

        NSPasteboard.general.clearContents()
        _ = try? await webView.evaluateJavaScript("(() => { const l = document.querySelector('.k-heading .h-link'); if (l) l.click(); return !!l; })()")
        try? await Task.sleep(for: .milliseconds(300))
        json["copied_link"] = NSPasteboard.general.string(forType: .string) ?? ""
        json["link_prefix"] = controller.url.path + "#"
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
        while backgroundRequests.count < 4 && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
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

    /// Find-mode switches the page was sent (each re-lays out the document).
    private static var findModeCalls: [Bool] = []
    /// Whether the page was up when each switch was delivered.
    private static var findModeReady: [Bool] = []
    static func noteFindMode(_ on: Bool, pageReady: Bool) {
        guard outputDirectory != nil else { return }
        findModeCalls.append(on)
        findModeReady.append(pageReady)
    }

    /// Find bar open, Return twice with editing ending and restarting around
    /// it, then Escape: find mode goes on once and off once.
    private static func findModeSwitches(controller: ReaderWindowController, out: URL) async {
        guard let field = controller.window?.toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first?.searchField else { return }
        findModeCalls = []
        controller.showFind(nil)
        field.stringValue = "Readout"
        let note = Notification(name: NSControl.textDidEndEditingNotification, object: field)
        for _ in 0..<2 {
            controller.controlTextDidEndEditing(note)
            controller.controlTextDidBeginEditing(note)
            _ = controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            try? await Task.sleep(for: .milliseconds(200))
        }
        _ = controller.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        field.stringValue = ""
        controller.controlTextDidEndEditing(note)
        try? await Task.sleep(for: .milliseconds(300))
        var json: [String: Any] = ["calls": findModeCalls]
        // Find asked for in a window whose page is not up yet (the pool's spare
        // went to the window opened just before): delivered once it is.
        if let tmp = ProcessInfo.processInfo.environment["READOUT_SMOKE_TMP_FILE"] {
            let dir = URL(fileURLWithPath: tmp).deletingLastPathComponent()
            let app = NSApp.delegate as? AppDelegate
            findModeCalls = []
            findModeReady = []
            app?.open(dir.appendingPathComponent("cold-a.md"))
            app?.open(dir.appendingPathComponent("cold-b.md"))
            if let cold = app?.reader(for: dir.appendingPathComponent("cold-b.md")) {
                cold.showFind(nil)
                let deadline = Date().addingTimeInterval(10)
                while findModeCalls.isEmpty && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
                json["cold_calls"] = findModeCalls
                json["cold_ready"] = findModeReady
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("find-mode.json"))
        }
    }

    private static func mark(_ dir: URL, _ name: String) {
        try? Data().write(to: dir.appendingPathComponent(name))
    }

    private static func badgeShot(_ out: URL) {
        for (name, appearance) in [("badge-light", NSAppearance.Name.aqua), ("badge-dark", .darkAqua)] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let image = ReaderWindowController.changeImage(count: 5)
                let scale: CGFloat = 4
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
                rep.size = image.size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                (appearance == .aqua ? NSColor.white : NSColor(white: 0.12, alpha: 1)).setFill()
                NSRect(origin: .zero, size: image.size).fill()
                image.draw(in: NSRect(origin: .zero, size: image.size))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
            }
        }
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
