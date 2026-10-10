import AppKit
import Quartz
import WebKit
import ReadoutCore

/// Quick Look preview: the same renderer as the app, static, without change tracking.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: ReaderWebView?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let w = ReaderWebView(bundle: Bundle(for: PreviewViewController.self))
        w.autoresizingMask = [.width, .height]
        webView = w
        view = w
        preferredContentSize = NSSize(width: 820, height: 900)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let data = try Data(contentsOf: url)
        let text = FileContent.decode(data).text
        let doc = MarkdownParser.parse(text, resolver: FileResolver(baseDirectory: url.deletingLastPathComponent()))
        let session = DocumentSession()
        let patch = session.load(doc)

        await MainActor.run { _ = self.view }
        guard let webView = await MainActor.run(body: { self.webView }) else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                var resumed = false
                let finish = {
                    guard !resumed else { return }
                    resumed = true
                    cont.resume()
                }
                webView.whenReady {
                    let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    webView.setAppearance(dark: dark, accent: .controlAccentColor, width: "narrow", fontSize: 15,
                                          strings: ReaderStrings.all, mode: "quicklook")
                    webView.onMessage = { msg in if msg["type"] as? String == "applied" { finish() } }
                    webView.call("apply", patch)
                }
                // Never hang Quick Look if the page fails to report back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
            }
        }
    }
}
