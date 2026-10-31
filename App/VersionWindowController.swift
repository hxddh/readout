import AppKit
import WebKit
import ReadoutCore

/// View ▸ Open Earlier Version: a version of a document from its history,
/// read-only in a window of its own, marked against the version before it
/// (what changed in it). Nothing is saved for it, and it follows no file.
@MainActor
final class VersionWindowController: NSWindowController, NSWindowDelegate {
    private let webView = ReaderWebView(bundle: .main)
    private let session = DocumentSession()
    var onClose: ((VersionWindowController) -> Void)?

    init(title: String, markdown: String, before: [BlockKey]?, directory: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.tabbingMode = .disallowed
        window.isRestorable = false   // a moment of a document, not one to come back to
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()
        super.init(window: window)
        window.delegate = self
        let doc = MarkdownParser.parse(markdown, resolver: FileResolver(baseDirectory: directory))
        let patch = session.load(doc, baseline: before)
        let settings = AppSettings.shared
        let dark = (window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        webView.whenReady { [weak self] in
            guard let self else { return }
            self.webView.setAppearance(dark: dark, accent: .controlAccentColor, fontSize: settings.fontSize,
                                       strings: ReaderStrings.all, codeWrap: settings.codeWrap, textWidth: settings.textWidth)
            self.webView.callEncodingOffMain("apply", patch.page)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { onClose?(self) }
}
