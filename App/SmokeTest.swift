import AppKit
import WebKit

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
///   `await-cli`   the harness runs `readout -b` and `readout --hook`
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

    /// Timings for tools/smoke-run.py, which adds its own clock readings.
    private static func writeTimings(_ dir: URL) {
        let json: [String: Any] = ["applied_at": appliedAt, "painted_at": paintedAt, "first_paint_s": firstPaint,
                                   "first_paint_samples_s": firstPaintSamples]
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
            try? await Task.sleep(for: .seconds(3))
            await capture(webView, window: controller.window, to: out, name: "1-initial")

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
            // Open what changed in the edited table (the edit mark's action).
            _ = try? await webView.evaluateJavaScript("(() => { const t = document.querySelector('.blk.k-table.m-modified'); return t ? window.readout.toggleDiff(+t.dataset.slot) : false; })()")
            try? await Task.sleep(for: .milliseconds(300))
            await capture(webView, window: controller.window, to: out, name: "3-marks")
            await undoMarkAllRead(controller: controller, webView: webView, out: out)
            await navigationStaysOnTheReader(webView: webView, out: out)

            // Dark appearance, then the auxiliary windows.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            _ = try? await webView.evaluateJavaScript("(() => { const m = document.querySelector('.mermaid-block'); if (m) m.scrollIntoView({block: 'center'}); return 1; })()")
            try? await Task.sleep(for: .seconds(2.5))
            await capture(webView, window: controller.window, to: out, name: "4-dark")
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
            await findModeSwitches(controller: controller, out: out)
            if let edit = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == NSLocalizedString("Edit", comment: "Menu") })?.submenu {
                let items = edit.items.compactMap { i in i.action.map { NSStringFromSelector($0) + (i.keyEquivalent.isEmpty ? "" : " " + i.keyEquivalent) } }
                if let data = try? JSONSerialization.data(withJSONObject: ["edit_menu": items], options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: out.appendingPathComponent("menus.json"))
                }
            }
            app?.showSettings(nil)
            try? await Task.sleep(for: .seconds(1.5))
            screen(out, "5-settings")
            NSApp.keyWindow?.close()
            app?.showWelcome(nil)
            try? await Task.sleep(for: .seconds(1.5))
            screen(out, "6-welcome")
            writeTimings(out)
            NSApp.terminate(nil)
        }
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
                "tabbing_automatic": reader.window?.tabbingMode == .automatic,
                "change_item": ["present": item != nil, "hidden": item?.isHidden ?? true, "enabled": item?.isEnabled ?? false]]
    }

    /// ⌘K, then Edit ▸ Undo through the menu as the reader would choose it:
    /// the marks come back, with the page showing them.
    private static func undoMarkAllRead(controller: ReaderWindowController, webView: WKWebView, out: URL) async {
        controller.show()
        try? await Task.sleep(for: .milliseconds(300))
        let marks = "document.querySelectorAll('.m-inserted, .m-modified, .m-state, .del-mark').length"
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
        _ = validate(redoItem)
        json["redo_title"] = redoItem?.title ?? ""
        write(json, to: out, "undo.json")
    }

    /// A readout: URL other than the reader page (a relative link opened in
    /// the web view, as the context menu's Open Link did) must not replace the
    /// document; the context menu offers no link items.
    private static func navigationStaysOnTheReader(webView: WKWebView, out: URL) async {
        let blocks = "document.querySelectorAll('.blk').length"
        var json: [String: Any] = ["blocks_before": (try? await webView.evaluateJavaScript(blocks)) as? Int ?? -1]
        _ = try? await webView.evaluateJavaScript("location.href = 'readout://app/other-plan.md'; 1")
        try? await Task.sleep(for: .seconds(1))
        json["href"] = (try? await webView.evaluateJavaScript("location.href")) as? String ?? ""
        json["blocks_after"] = (try? await webView.evaluateJavaScript(blocks)) as? Int ?? -1
        let menu = NSMenu()
        for id in ["WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
                   "WKMenuItemIdentifierCopyLink", "-", "WKMenuItemIdentifierCopy", "-", "WKMenuItemIdentifierLookUp", "-"] {
            if id == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        ReaderWebView.filterContextMenu(menu)
        json["context_menu"] = menu.items.map { $0.isSeparatorItem ? "-" : ($0.identifier?.rawValue ?? "") }
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
                result["unreadable"] = chrome(reader)
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
        while backgroundRequests.count < 2 && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        deadline = Date().addingTimeInterval(5)
        let name = URL(fileURLWithPath: file).lastPathComponent
        while !NSApp.windows.contains(where: { $0.title == name }) && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .seconds(1))
        let json: [String: Any] = ["requests": backgroundRequests.map { URL(fileURLWithPath: $0).lastPathComponent },
                                   "reading_before": before, "reading_after": reading(),
                                   "opened": NSApp.windows.contains { $0.title == name }]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("background-opens.json"))
        }
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
