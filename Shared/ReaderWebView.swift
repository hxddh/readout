import AppKit
import WebKit
import ReadoutCore

/// Serves `readout://app/...` from the bundled web renderer and `readout://file/...` images from disk.
final class ReadoutSchemeHandler: NSObject, WKURLSchemeHandler {
    let webRoot: URL
    /// Serves `readout://remote/<token>` from natively proxied downloads.
    /// Nil in Quick Look (no remote loading there): those requests 404.
    var remoteProvider: ((String) -> (data: Data, contentType: String)?)?

    init(bundle: Bundle) {
        webRoot = bundle.resourceURL!.appendingPathComponent("Web", isDirectory: true)
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "avif", "ico"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task, 400) }
        let fileURL: URL
        switch url.host {
        case "app":
            let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let candidate = webRoot.appendingPathComponent(rel).standardizedFileURL
            guard candidate.path.hasPrefix(webRoot.standardizedFileURL.path) else { return fail(task, 403) }
            fileURL = candidate
        case "file":
            let path = url.path.removingPercentEncoding ?? url.path
            guard Self.imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return fail(task, 403) }
            fileURL = URL(fileURLWithPath: path)
        case "remote":
            let token = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            guard let entry = remoteProvider?(token) else { return fail(task, 404) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": entry.contentType,
                "Content-Length": String(entry.data.count),
                "Cache-Control": "no-cache",
                "Access-Control-Allow-Origin": "*",
            ])!
            task.didReceive(response)
            task.didReceive(entry.data)
            task.didFinish()
            return
        default:
            return fail(task, 404)
        }
        guard let data = try? Data(contentsOf: fileURL) else { return fail(task, 404) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": Self.mimeType(fileURL.pathExtension),
            "Content-Length": String(data.count),
            "Cache-Control": "no-cache",
            "Access-Control-Allow-Origin": "*",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        NSLog("Readout scheme handler: %d for %@", code, task.request.url?.absoluteString ?? "?")
        if let url = task.request.url, let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil) {
            task.didReceive(r)
            task.didFinish()
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist))
        }
    }

    static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "heic": return "image/heic"
        case "avif": return "image/avif"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }
}

/// Forwards script messages without retaining the receiver (WKUserContentController retains handlers strongly).
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler?) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

/// A WKWebView preloaded with the reader page. `ready` flips once the page reports in.
@MainActor
final class ReaderWebView: WKWebView, WKScriptMessageHandler {
    private(set) var isReady = false
    private var readyCallbacks: [() -> Void] = []
    /// Receives every message other than `ready`.
    var onMessage: (([String: Any]) -> Void)?
    private let forwarder = WeakScriptMessageHandler(nil)
    private let remoteHandler: ReadoutSchemeHandler

    /// Source for `readout://remote/<token>` bytes (the App's proxied-download
    /// cache). Leave nil — as Quick Look does — to disable remote loading.
    var remoteProvider: ((String) -> (data: Data, contentType: String)?)? {
        get { remoteHandler.remoteProvider }
        set { remoteHandler.remoteProvider = newValue }
    }

    static let readerURL = URL(string: "readout://app/reader.html")!

    init(bundle: Bundle) {
        let config = WKWebViewConfiguration()
        let schemeHandler = ReadoutSchemeHandler(bundle: bundle)
        remoteHandler = schemeHandler
        config.setURLSchemeHandler(schemeHandler, forURLScheme: ReadoutURL.scheme)
        config.suppressesIncrementalRendering = false
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        config.preferences.isTextInteractionEnabled = true
        let ucc = WKUserContentController()
        config.userContentController = ucc
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        forwarder.target = self
        ucc.add(forwarder, name: "readout")
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        underPageBackgroundColor = .textBackgroundColor
        setValue(false, forKey: "drawsBackground")
        load(URLRequest(url: Self.readerURL))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func reloadReader() {
        isReady = false
        load(URLRequest(url: Self.readerURL))
    }

    /// Removes navigation items (Reload, Back, Forward…) that would discard the rendered document.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let blocked: Set<String> = ["WKMenuItemIdentifierReload", "WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierGoForward",
                                    "WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierDownloadLinkedFile",
                                    "WKMenuItemIdentifierOpenFrameInNewWindow", "WKMenuItemIdentifierOpenImageInNewWindow",
                                    "WKMenuItemIdentifierDownloadImage", "WKMenuItemIdentifierInspectElement"]
        for item in menu.items where blocked.contains(item.identifier?.rawValue ?? "") { menu.removeItem(item) }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        super.willOpenMenu(menu, with: event)
    }

    func whenReady(_ block: @escaping () -> Void) {
        if isReady { block() } else { readyCallbacks.append(block) }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "error" {
            NSLog("Readout page error: %@", (body["message"] as? String) ?? "?")
            return
        }
        if type == "ready" {
            isReady = true
            let callbacks = readyCallbacks
            readyCallbacks = []
            callbacks.forEach { $0() }
            return
        }
        onMessage?(body)
    }

    /// Calls `window.readout.<function>(<json>)`.
    func call(_ function: String, json: String = "") {
        evaluateJavaScript("window.readout.\(function)(\(json))", completionHandler: nil)
    }

    func call<T: Encodable>(_ function: String, _ value: T) {
        guard let data = try? JSONEncoder.reader.encode(value), let json = String(data: data, encoding: .utf8) else { return }
        call(function, json: json)
    }

    func setAppearance(dark: Bool? = nil, accent: NSColor? = nil, width: String? = nil, fontSize: Double? = nil,
                       strings: [String: String]? = nil, changesOnly: Bool? = nil, codeWrap: Bool? = nil,
                       mode: String? = nil) {
        var o: [String: Any] = [:]
        if let dark { o["dark"] = dark }
        if let accent { o["accent"] = accent.hexString }
        if let width { o["width"] = width }
        if let fontSize { o["fontSize"] = fontSize }
        if let strings { o["strings"] = strings }
        if let changesOnly { o["changesOnly"] = changesOnly }
        if let codeWrap { o["codeWrap"] = codeWrap }
        if let mode { o["mode"] = mode }
        guard let data = try? JSONSerialization.data(withJSONObject: o), let json = String(data: data, encoding: .utf8) else { return }
        call("setAppearance", json: json)
    }
}

extension JSONEncoder {
    static let reader: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#0a84ff" }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

enum ReaderStrings {
    static var all: [String: String] {
        [
            "copy": NSLocalizedString("Copy", comment: "Code block copy button"),
            "copied": NSLocalizedString("Copied", comment: "Code block copy confirmation"),
            "loadImage": NSLocalizedString("Load image from %@", comment: "Remote image placeholder; %@ is the host"),
            "rewritten": NSLocalizedString("This file was rewritten", comment: "Notice when most of the document changed"),
            "diagramError": NSLocalizedString("Diagram could not be drawn", comment: "Mermaid error prefix"),
            "empty": NSLocalizedString("This file is empty.", comment: "Empty document"),
            "deletedOne": NSLocalizedString("1 block removed", comment: "Deletion marker tooltip"),
            "deletedMany": NSLocalizedString("%d blocks removed", comment: "Deletion marker tooltip; %d is a number"),
            "caughtUp": NSLocalizedString("All caught up", comment: "Empty state when filtering to changes with none left"),
            "copyLink": NSLocalizedString("Copy Link to Section", comment: "Heading link button tooltip"),
            "remoteError": NSLocalizedString("Could not load image: %@", comment: "Remote image download failure; %@ is the reason"),
            "railChange": NSLocalizedString("Unread change %d of %d: %@", comment: "Change-rail tick label; %d is position, %d is total, %@ is the kind"),
            "railAdded": NSLocalizedString("added", comment: "Change kind in rail label"),
            "railEdited": NSLocalizedString("edited", comment: "Change kind in rail label"),
            "railRemoved": NSLocalizedString("removed", comment: "Change kind in rail label"),
            "wrap": NSLocalizedString("Wrap", comment: "Code block button: wrap long lines"),
            "wrapTitle": NSLocalizedString("Wrap long lines in code blocks", comment: "Code block wrap button tooltip"),
        ]
    }
}
