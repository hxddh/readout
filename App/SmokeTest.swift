import AppKit
import WebKit

/// Scripted run used by CI: opens a file, captures the rendered page, simulates an agent rewrite,
/// captures again and quits. Enabled only when READOUT_SMOKE_OUT is set.
@MainActor
enum SmokeTest {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["READOUT_SMOKE_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(controller: ReaderWindowController, webView: WKWebView) {
        guard let out = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment

        NSApp.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await capture(webView, window: controller.window, to: out, name: "1-initial")

            // Scroll into the middle, then apply the edited file the way agents do: write a temp file and rename it.
            _ = try? await webView.evaluateJavaScript("(() => { const b = [...document.querySelectorAll('.blk')]; const t = b[Math.floor(b.length/2)]; window.scrollBy(0, t.getBoundingClientRect().top - 30); window.__smoke = {slot: +t.dataset.slot, top: t.getBoundingClientRect().top}; return 1; })()")
            if let edit = env["READOUT_SMOKE_EDIT"] {
                let target = controller.url
                let tmp = target.deletingLastPathComponent().appendingPathComponent(".readout-smoke.tmp")
                try? FileManager.default.removeItem(at: tmp)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: edit), to: tmp)
                _ = try? FileManager.default.replaceItemAt(target, withItemAt: tmp)
                try? await Task.sleep(for: .seconds(2))
                await capture(webView, window: controller.window, to: out, name: "2-after-edit")
                _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 0); 1")
                try? await Task.sleep(for: .seconds(1))
                await capture(webView, window: controller.window, to: out, name: "3-marks")
            }
            // Dark appearance, then the auxiliary windows.
            NSApp.appearance = NSAppearance(named: .darkAqua)
            _ = try? await webView.evaluateJavaScript("(() => { const m = document.querySelector('.mermaid-block'); if (m) m.scrollIntoView({block: 'center'}); return 1; })()")
            try? await Task.sleep(for: .seconds(2.5))
            await capture(webView, window: controller.window, to: out, name: "4-dark")
            NSApp.appearance = nil
            let app = NSApp.delegate as? AppDelegate
            app?.showSettings(nil)
            try? await Task.sleep(for: .seconds(1.5))
            screen(out, "5-settings")
            NSApp.keyWindow?.close()
            app?.showWelcome(nil)
            try? await Task.sleep(for: .seconds(1.5))
            screen(out, "6-welcome")
            NSApp.terminate(nil)
        }
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
              early: document.body.innerText.includes('EARLY-EDIT-OK')
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
