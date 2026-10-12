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
    /// Window request to first patch on screen, per file.
    private static var firstPaint: [String: Double] = [:]
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
    }

    /// Timings for tools/smoke-run.py, which adds its own clock readings.
    private static func writeTimings(_ dir: URL) {
        let json: [String: Any] = ["applied_at": appliedAt, "painted_at": paintedAt, "first_paint_s": firstPaint]
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
            await capture(webView, window: controller.window, to: out, name: "2-after-edit")
            _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0); 1")
            try? await Task.sleep(for: .seconds(1))
            // Open what changed in the edited table (the edit mark's action).
            _ = try? await webView.evaluateJavaScript("(() => { const t = document.querySelector('.blk.k-table.m-modified'); return t ? window.readout.toggleDiff(+t.dataset.slot) : false; })()")
            try? await Task.sleep(for: .milliseconds(300))
            await capture(webView, window: controller.window, to: out, name: "3-marks")

            // Dark appearance, then the auxiliary windows.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            _ = try? await webView.evaluateJavaScript("(() => { const m = document.querySelector('.mermaid-block'); if (m) m.scrollIntoView({block: 'center'}); return 1; })()")
            try? await Task.sleep(for: .seconds(2.5))
            await capture(webView, window: controller.window, to: out, name: "4-dark")
            NSApp.appearance = nil
            let app = NSApp.delegate as? AppDelegate
            // Open a second file while running: the warm open-to-first-paint path.
            if let second = ProcessInfo.processInfo.environment["READOUT_SMOKE_SECOND"] {
                let secondURL = URL(fileURLWithPath: second)
                app?.open(secondURL)
                // Keep it open until its first frame is on screen (or well past the guard).
                let deadline = Date().addingTimeInterval(10)
                while firstPaint[secondURL.path] == nil && Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                NSApp.keyWindow?.close()
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
                NSApp.activate()
            }
            await liveUpdates(app: app, out: out)
            await backgroundOpens(out: out)
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
            try? await Task.sleep(for: .milliseconds(300))
            mark(out, marker)
            deadline = Date().addingTimeInterval(10)
            while reader.model.title == before && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            result[name] = ["before": before, "after": reader.model.title]
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
