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

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let w = ReaderWebView(bundle: Bundle(for: PreviewViewController.self))
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
        let data = try Data(contentsOf: url)
        let text = FileContent.decode(data).text
        // The incremental parser's first parse cuts the document into
        // fragments parsed concurrently: the same document as
        // MarkdownParser.parse, sooner for a long one.
        let doc = IncrementalParser(resolver: FileResolver(baseDirectory: url.deletingLastPathComponent())).parse(text)
        let session = DocumentSession()
        let patch = session.load(doc)
        // Only the count outlives this call: the parsed document is released with it.
        let blocks = doc.blocks.count

        await MainActor.run { _ = self.view }
        guard let webView = await MainActor.run(body: { self.webView }) else { return }
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
                    let ms = Int(Date().timeIntervalSince(requested) * 1000)
                    // One line per preview, so CI (and Console) can see that
                    // content actually rendered, not just that we registered.
                    webView?.evaluateJavaScript("document.querySelectorAll('.blk').length") { value, _ in
                        let rendered = (value as? NSNumber)?.intValue ?? -1
                        log.notice("preview \(how, privacy: .public): rendered \(rendered, privacy: .public) of \(blocks, privacy: .public) blocks in \(ms, privacy: .public) ms")
                    }
                }
                webView.whenReady { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    // The app's default text size (Actual Size), in the preview's appearance.
                    webView.setAppearance(dark: self.isDark, accent: .controlAccentColor, width: "narrow", fontSize: 16,
                                          strings: ReaderStrings.all, mode: "quicklook")
                    // Light or dark switched while the preview is open: it follows.
                    self.appearanceObservation = webView.observe(\.effectiveAppearance) { [weak self] _, _ in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self, let webView = self.webView else { return }
                                webView.setAppearance(dark: self.isDark, accent: .controlAccentColor)
                            }
                        }
                    }
                    webView.onMessage = { msg in if msg["type"] as? String == "applied" { finish("applied") } }
                    webView.call("apply", patch.page)
                }
                // Never hang Quick Look if the page fails to report back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish("timed out") }
            }
        }
    }
}
