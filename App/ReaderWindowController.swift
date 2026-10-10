import AppKit
import SwiftUI
import WebKit
import Combine
import ReadoutCore

/// Keeps one reader page loaded and initialised in the background so a new window opens instantly.
@MainActor
final class WebViewPool {
    static let shared = WebViewPool()
    private var spare: ReaderWebView?

    func prewarm() {
        guard spare == nil else { return }
        let w = ReaderWebView(bundle: .main)
        w.whenReady { w.call("warm") }
        spare = w
    }

    func take() -> ReaderWebView {
        let w = spare ?? ReaderWebView(bundle: .main)
        spare = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.prewarm() }
        return w
    }
}

extension NSToolbarItem.Identifier {
    static let nextChange = NSToolbarItem.Identifier("readout.nextChange")
    static let width = NSToolbarItem.Identifier("readout.width")
    static let search = NSToolbarItem.Identifier("readout.search")
}

/// One window per file: sidebar outline + reader web view, live-updated from disk.
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    let url: URL
    let model = ReaderModel()
    var onClose: ((ReaderWindowController) -> Void)?

    private let session = DocumentSession()
    private let cache = MarkdownParser.RenderCache()
    private let webView: ReaderWebView
    private var watcher: FileWatcher?
    private let parseQueue = DispatchQueue(label: "readout.parse", qos: .userInitiated)
    private let splitController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var searchItem: NSSearchToolbarItem?
    private var changeItem: NSToolbarItem?
    private var cancellables: Set<AnyCancellable> = []

    // File state
    private var lastHash: UInt64?
    private var lastSize: Int?
    private var lastChangeAt: Date?
    private var halfWriteRetries = 0
    private var loaded = false
    private var deleted = false
    private var lastAnchor: (slot: Int, offset: Double)?
    private var saveWork: DispatchWorkItem?

    init(url: URL) {
        self.url = url.standardizedFileURL
        self.webView = WebViewPool.shared.take()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 460, height: 320)
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        buildContent()
        buildToolbar()
        configureWebView()
        observeSettings()

        window.title = url.lastPathComponent
        window.representedURL = url
        window.setFrameAutosaveName("ReaderWindow")

        model.onSelectHeading = { [weak self] slot in self?.webView.call("scrollToSlot", json: String(slot)) }
        watcher = FileWatcher(url: self.url) { [weak self] change in self?.fileChanged(change) }
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildContent() {
        let sidebarVC = NSHostingController(rootView: TOCView(model: model))
        sidebarVC.sizingOptions = []
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !AppSettings.shared.showSidebar

        let contentVC = NSViewController()
        let container = NSView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentVC.view = container
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 360

        splitController.splitViewItems = [sidebarItem, contentItem]
        splitController.splitView.autosaveName = "ReaderSplit"
        window?.contentViewController = splitController
        window?.setContentSize(NSSize(width: 1060, height: 820))
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .nextChange, .width, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .nextChange:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = NSLocalizedString("Next Change", comment: "Toolbar")
            item.toolTip = NSLocalizedString("Jump to the next unread change (N)", comment: "Toolbar tooltip")
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(nextChange(_:))
            item.isBordered = true
            item.isHidden = true
            changeItem = item
            return item
        case .width:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = NSLocalizedString("Text Width", comment: "Toolbar")
            item.toolTip = NSLocalizedString("Switch between narrow and wide text", comment: "Toolbar tooltip")
            item.image = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(toggleWidth(_:))
            item.isBordered = true
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = NSLocalizedString("Find", comment: "Search field placeholder")
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldAction(_:))
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.sendsWholeSearchString = true
            searchItem = item
            return item
        default:
            return nil
        }
    }

    // MARK: Web view

    private func configureWebView() {
        webView.navigationDelegate = self
        webView.onMessage = { [weak self] msg in self?.handle(msg) }
        applyAppearance()
        NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &cancellables)
        window?.publisher(for: \.effectiveAppearance)
            .dropFirst()
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &cancellables)
    }

    private func applyAppearance() {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let settings = AppSettings.shared
        webView.whenReady { [weak self] in
            self?.webView.setAppearance(dark: dark, accent: .controlAccentColor, width: settings.wide ? "wide" : "narrow",
                                        fontSize: settings.fontSize, strings: ReaderStrings.all)
        }
    }

    private func observeSettings() {
        let s = AppSettings.shared
        s.$fontSize.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }.store(in: &cancellables)
        s.$wide.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }.store(in: &cancellables)
        model.$unread.sink { [weak self] n in self?.updateChangeItem(n) }.store(in: &cancellables)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.request.url else { return .cancel }
        if target.scheme == ReadoutURL.scheme { return .allow }
        // A file dropped onto the window arrives as a navigation.
        if target.isFileURL { (NSApp.delegate as? AppDelegate)?.open(target) }
        else if action.navigationType == .linkActivated { NSWorkspace.shared.open(target) }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Recover from a crashed renderer: reload the page and re-send the document.
        self.webView.reloadReader()
        self.webView.whenReady { [weak self] in
            guard let self else { return }
            self.applyAppearance()
            self.webView.call("apply", self.session.fullPayload(rewrite: false))
        }
    }

    // MARK: Loading

    private var resolver: FileResolver {
        FileResolver(baseDirectory: url.deletingLastPathComponent(),
                     searchRoots: AppSettings.shared.workspaces.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
    }

    private struct ReadResult {
        let doc: ParsedDocument
        let hash: UInt64
        let size: Int
        let decoded: FileContent.Decoded
    }

    private func read(_ completion: @escaping (ReadResult?) -> Void) {
        let url = self.url
        let resolver = self.resolver
        let cache = self.cache
        parseQueue.async {
            guard let data = try? Data(contentsOf: url) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let hash = XXHash64.hash(data)
            let decoded = FileContent.decode(data)
            cache.beginGeneration()
            let doc = MarkdownParser.parse(decoded.text, resolver: resolver, cache: cache)
            let result = ReadResult(doc: doc, hash: hash, size: data.count, decoded: decoded)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func load() {
        read { [weak self] result in
            guard let self else { return }
            guard let result else {
                self.model.status = NSLocalizedString("The file could not be read.", comment: "Status")
                return
            }
            let record = BaselineStore.load(self.url)
            let patch = self.session.load(result.doc, baseline: record?.baseline)
            self.lastHash = result.hash
            self.lastSize = result.size
            self.loaded = true
            self.updateModel(patch, decoded: result.decoded)
            self.webView.whenReady { [weak self] in
                guard let self else { return }
                self.webView.call("apply", patch)
                if let idx = record?.topBlockIndex, idx < self.session.blocks.count {
                    let slot = self.session.blocks[idx].slot
                    let anchor = ["slot": slot, "offset": record?.topOffset ?? 0, "ratio": 0] as [String: Any]
                    if let data = try? JSONSerialization.data(withJSONObject: anchor), let json = String(data: data, encoding: .utf8) {
                        self.webView.call("scrollToAnchor", json: json)
                    }
                }
            }
        }
    }

    private func fileChanged(_ change: FileWatcher.Change) {
        guard loaded else { return }
        if change == .deleted {
            deleted = true
            model.status = NSLocalizedString("The file was deleted.", comment: "Status")
            return
        }
        read { [weak self] result in
            guard let self, let result else { return }
            if result.hash == self.lastHash {
                if self.deleted { self.deleted = false; self.model.status = nil }
                return
            }
            let verdict = FileContent.verdict(newSize: result.size, previousSize: self.lastSize,
                                              secondsSincePreviousWrite: self.lastChangeAt.map { Date().timeIntervalSince($0) },
                                              truncatedTail: result.decoded.truncatedTail, retriesSoFar: self.halfWriteRetries)
            if verdict == .waitForMore {
                self.halfWriteRetries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.fileChanged(.modified) }
                return
            }
            self.halfWriteRetries = 0
            self.deleted = false
            self.lastHash = result.hash
            self.lastSize = result.size
            self.lastChangeAt = Date()
            guard let patch = self.session.update(result.doc) else {
                self.model.status = nil
                return
            }
            self.updateModel(patch, decoded: result.decoded)
            self.webView.whenReady { [weak self] in self?.webView.call("apply", patch) }
            self.scheduleSave()
        }
    }

    private func updateModel(_ patch: RenderPatch, decoded: FileContent.Decoded) {
        model.toc = patch.toc
        model.tasks = patch.tasks
        model.unread = session.unreadCount
        model.title = patch.title ?? url.deletingPathExtension().lastPathComponent
        if let enc = decoded.fallbackEncoding {
            model.status = String(format: NSLocalizedString("Decoded as %@", comment: "Status: non-UTF-8 file"), enc)
        } else {
            model.status = nil
        }
        if model.activeSlot == 0 { model.activeSlot = patch.toc.first?.slot ?? 0 }
        updateSubtitle()
    }

    private func updateSubtitle() {
        let t = model.tasks
        window?.subtitle = t.total > 0
            ? String(format: NSLocalizedString("%d of %d tasks done", comment: "Window subtitle"), t.done, t.total)
            : ""
    }

    private func updateChangeItem(_ n: Int) {
        guard let item = changeItem else { return }
        item.isHidden = n == 0
        item.badge = n > 0 ? .count(n) : nil
        item.toolTip = String(format: NSLocalizedString("%d unread changes. Press N to jump to the next one.", comment: "Toolbar tooltip"), n)
    }

    // MARK: Messages from the page

    private func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "read":
            let slots = (msg["slots"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            let dels = (msg["deletions"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            session.markRead(slots: slots, deletionIDs: dels)
            model.unread = session.unreadCount
            scheduleSave()
        case "activeHeading":
            if let slot = (msg["slot"] as? NSNumber)?.intValue, slot != model.activeSlot { model.activeSlot = slot }
        case "anchor":
            if let a = msg["anchor"] as? [String: Any], let slot = (a["slot"] as? NSNumber)?.intValue {
                lastAnchor = (slot, (a["offset"] as? NSNumber)?.doubleValue ?? 0)
                scheduleSave()
            }
        case "copy":
            if let text = msg["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "open":
            if let href = msg["href"] as? String { openLink(href) }
        case "openPath":
            if let path = msg["path"] as? String {
                EditorOpener.open(path: path, line: (msg["line"] as? NSNumber)?.intValue ?? 0,
                                  column: (msg["column"] as? NSNumber)?.intValue ?? 0)
            }
        default:
            break
        }
    }

    private func openLink(_ href: String) {
        if let u = URL(string: href), let scheme = u.scheme?.lowercased(), scheme != "file" {
            NSWorkspace.shared.open(u)
            return
        }
        // Relative or file link: resolve against the document's folder, drop any fragment.
        var path = href
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if path.lowercased().hasPrefix("file://"), let u = URL(string: path) { path = u.path }
        path = path.removingPercentEncoding ?? path
        guard !path.isEmpty else { return }
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        if WorkspaceIndex.markdownExtensions.contains(target.pathExtension.lowercased()) {
            (NSApp.delegate as? AppDelegate)?.open(target)
        } else if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.open(target)
        } else {
            NSSound.beep()
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func saveNow() {
        guard loaded else { return }
        var index: Int? = nil
        if let a = lastAnchor { index = session.blocks.firstIndex { $0.slot == a.slot } }
        BaselineStore.save(.init(baseline: session.baseline, topBlockIndex: index, topOffset: lastAnchor?.offset, savedAt: Date()), for: url)
    }

    // MARK: Actions

    @objc func nextChange(_ sender: Any?) { webView.call("nextChange") }
    @objc func previousChange(_ sender: Any?) { webView.call("previousChange") }

    @objc func markAllRead(_ sender: Any?) {
        session.markAllRead()
        model.unread = 0
        webView.call("markAllRead")
        scheduleSave()
    }

    @objc func toggleWidth(_ sender: Any?) { AppSettings.shared.wide.toggle() }

    @objc func revealInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    @objc func openInEditor(_ sender: Any?) { EditorOpener.open(path: url.path, line: 0, column: 0) }

    @objc func copyFilePath(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.jobDisposition = .spool
        let op = webView.printOperation(with: info)
        op.view?.frame = webView.bounds
        op.jobTitle = model.title
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func showFind(_ sender: Any?) {
        guard let item = searchItem else { return }
        item.beginSearchInteraction()
    }

    @objc func findNext(_ sender: Any?) { find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }

    @objc private func searchFieldAction(_ sender: NSSearchField) { find(backwards: false) }

    private func find(backwards: Bool) {
        let text = searchItem?.searchField.stringValue ?? ""
        guard !text.isEmpty else { showFind(nil); return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(text, configuration: config) { result in
            if !result.matchFound { NSSound.beep() }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            searchItem?.endSearchInteraction()
            window?.makeFirstResponder(webView)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            find(backwards: backwards)
            return true
        }
        return false
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(nextChange(_:)), #selector(previousChange(_:)), #selector(markAllRead(_:)):
            return session.unreadCount > 0
        case #selector(toggleWidth(_:)):
            item.state = AppSettings.shared.wide ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: Window

    func show() {
        showWindow(nil)
        window?.makeFirstResponder(webView)
    }

    func windowWillClose(_ notification: Notification) {
        saveWork?.cancel()
        saveNow()
        watcher?.stop()
        watcher = nil
        cancellables.removeAll()
        AppSettings.shared.showSidebar = !sidebarItem.isCollapsed
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === window { window?.makeFirstResponder(webView) }
    }
}
