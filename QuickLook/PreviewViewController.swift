import AppKit
import Quartz
import WebKit
import ReadoutCore
import os

private let log = Logger(subsystem: "io.github.hxddh.readout.quicklook", category: "preview")

/// Quick Look preview: the same renderer as the app, static, without change tracking.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: ReaderWebView?
    private var appearanceObservation: NSKeyValueObservation?
    private var usedSpare = false

    /// The containing app (Readout.app/Contents/PlugIns/ReadoutQuickLook.appex):
    /// its Contents/Resources/Web serves the reader page, so the extension
    /// ships no copy of its own.
    private static let appBundle: Bundle = {
        let appex = Bundle(for: PreviewViewController.self).bundleURL
        return Bundle(url: appex.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? .main
    }()

    /// A page made after each preview for the next one, which then finds it
    /// loaded (WebKit's process start and the page's load are most of a
    /// preview's time) while the extension stays running.
    private static var spare: ReaderWebView?
    private static let spareWatch = SpareWatch()
    private static func makeSpare() {
        guard spare == nil else { return }
        let w = ReaderWebView(bundle: appBundle)
        w.navigationDelegate = spareWatch
        spare = w
    }
    /// The spare's web content process died while it waited (memory
    /// pressure, a crash): it is dropped, and the next preview makes its own
    /// page, as without a spare (the app's WebViewPool does the same).
    private final class SpareWatch: NSObject, WKNavigationDelegate {
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MainActor.assumeIsolated {
                if webView === PreviewViewController.spare { PreviewViewController.spare = nil }
            }
        }
    }

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        usedSpare = Self.spare != nil
        let w = Self.spare ?? ReaderWebView(bundle: Self.appBundle)
        Self.spare = nil
        w.navigationDelegate = nil
        w.autoresizingMask = [.width, .height]
        webView = w
        view = w
        preferredContentSize = NSSize(width: 820, height: 900)
    }

    private var isDark: Bool {
        (webView?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let requested = Date()
        // With the "applied" line below: how long a preview took (CI's ql_open_ms).
        log.notice("preview requested")
        // The web view first: its page loads in WebKit's process while the
        // document is read and parsed here, instead of after it.
        let made: ReaderWebView? = await MainActor.run {
            _ = self.view
            guard let webView = self.webView else { return nil }
            let created = Date()
            log.notice("preview view created in \(Int(created.timeIntervalSince(requested) * 1000), privacy: .public) ms (spare page: \(self.usedSpare ? "yes" : "no", privacy: .public))")
            // CI's ql_page_ready_ms: view created to its page's ready.
            webView.whenReady { [weak self, weak webView] in
                log.notice("preview page ready in \(Int(Date().timeIntervalSince(created) * 1000), privacy: .public) ms")
                guard let self, let webView else { return }
                // The app's default text size (Actual Size) and column (Text Width ▸
                // Standard), in the preview's appearance.
                // First, so the grammars prepared below are the only ones loaded.
                webView.setAppearance(dark: self.isDark, accent: .controlAccentColor, fontSize: 16,
                                      strings: ReaderStrings.all, mode: "quicklook", textWidth: "standard")
                // Light or dark switched while the preview is open: it follows.
                self.appearanceObservation = webView.observe(\.effectiveAppearance) { [weak self] _, _ in
                    let controller = self
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self = controller, let webView = self.webView else { return }
                            webView.setAppearance(dark: self.isDark, accent: .controlAccentColor)
                        }
                    }
                }
            }
            return webView
        }
        guard let webView = made else { return }
        // Off the main thread, whatever this method is called on: the page's
        // messages (its ready) are handled there meanwhile.
        let (patch, blocks) = try await Task.detached(priority: .userInitiated) { () async throws -> (RenderPatch, Int) in
            let data = try Data(contentsOf: url)
            let text = FileContent.decode(data).text
            // Its fence languages first: the page loads their grammars while
            // it parses (a page up already, the spare: one still loading
            // takes the document as soon as it is ready).
            let langs = FenceLanguages.scan(text)
            if !langs.isEmpty {
                DispatchQueue.main.async { MainActor.assumeIsolated { if webView.isReady { webView.call("prepare", langs) } } }
            }
            // The incremental parser's first parse cuts the document into
            // fragments parsed concurrently: the same document as
            // MarkdownParser.parse, sooner for a long one.
            let doc = IncrementalParser(resolver: FileResolver(baseDirectory: url.deletingLastPathComponent())).parse(text)
            let session = DocumentSession()
            // Only the count outlives this: the parsed document is released with it.
            return (session.load(doc), doc.blocks.count)
        }.value

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                var resumed = false
                // Weak: the web view holds this through onMessage, and a
                // strong reference back kept every preview's web view alive.
                let finish = { [weak webView] (how: String) in
                    guard !resumed else { return }
                    resumed = true
                    cont.resume()
                    webView?.onMessage = nil
                    // The next preview's page, once this one is shown.
                    DispatchQueue.main.async { MainActor.assumeIsolated { Self.makeSpare() } }
                    let ms = Int(Date().timeIntervalSince(requested) * 1000)
                    // One line per preview, so CI (and Console) can see that
                    // content actually rendered, not just that we registered.
                    webView?.evaluateJavaScript("document.querySelectorAll('.blk').length") { value, _ in
                        let rendered = (value as? NSNumber)?.intValue ?? -1
                        log.notice("preview \(how, privacy: .public): rendered \(rendered, privacy: .public) of \(blocks, privacy: .public) blocks in \(ms, privacy: .public) ms")
                    }
                    // Where its code is highlighted: a worker, or the page
                    // itself where an extension's page cannot start one (CI's log).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak webView] in
                        webView?.evaluateJavaScript("window.readout.highlighter()") { value, _ in
                            log.notice("preview highlighter: \(value as? String ?? "unknown", privacy: .public)")
                        }
                    }
                }
                webView.whenReady { [weak webView] in
                    guard let webView else { return }
                    webView.onMessage = { msg in if msg["type"] as? String == "applied" { finish("applied") } }
                    webView.call("apply", patch.page)
                }
                // Never hang Quick Look if the page fails to report back:
                // 3 s from its page being ready to take the document, or 10 s
                // in all if it never is. The page's ready waits for WebKit to
                // start the extension's first web content process, which on
                // a cold machine alone took 1.9 to 3.2 s (CI): a deadline
                // counted from here showed an empty preview whenever that
                // start was slow.
                webView.whenReady { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish("timed out") } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish("timed out") }
            }
        }
    }
}
