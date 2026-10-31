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
    /// The document's window: a link in the version is followed as one in the document is.
    private weak var reader: ReaderWindowController?

    init(title: String, markdown: String, before: [BlockKey]?, directory: URL, reader: ReaderWindowController) {
        self.reader = reader
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
        webView.onMessage = { [weak self] raw in self?.handle(raw) }
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

    /// What a read-only page asks for: copying, and following links (one to
    /// a heading of the version itself scrolls there). Nothing about reading.
    private func handle(_ raw: [String: Any]) {
        guard let msg = PageMessage(raw) else { return }
        switch msg {
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .open(let href):
            if href.hasPrefix("#") {
                let slug = (String(href.dropFirst()).removingPercentEncoding ?? "").lowercased()
                if let block = session.blocks.first(where: { $0.kind == .heading && $0.anchor?.lowercased() == slug }) {
                    webView.call("scrollToSlot", json: String(block.slot))
                }
            } else {
                reader?.openLink(href)
            }
        default:
            break
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { onClose?(self) }
}
