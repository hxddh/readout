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
    /// Hides every block without an unread mark; headings stay visible as context.
    private var changesOnly = false
    // Parse coalescing: rapid successive writes share one in-flight parse;
    // completions carry a generation and stale ones are dropped.
    private var readGeneration = 0
    private var readInFlight = false
    private var readAgain = false
    private var pendingCompletions: [(ReadResult?) -> Void] = []
    /// Fragment from a cross-file link (other.md#section), scrolled to after load.
    private var pendingAnchor: String?

    init(url: URL, pendingAnchor: String? = nil) {
        self.url = url.standardizedFileURL
        self.webView = WebViewPool.shared.take()
        self.pendingAnchor = pendingAnchor

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
        // Proxied remote images: the page posts loadRemote, we download with a
        // cookie-free ephemeral session and serve the bytes back over readout:.
        // Quick Look never sets this, so remote loading stays disabled there.
        webView.remoteProvider = { RemoteImageLoader.shared.entry(for: $0).map { (data: $0.data, contentType: $0.contentType) } }
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
        // The area under the toolbar shows the web view's under-page colour; keep it in step with the page.
        webView.underPageBackgroundColor = dark ? NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x1f / 255, alpha: 1) : .white
        webView.whenReady { [weak self] in
            self?.webView.setAppearance(dark: dark, accent: .controlAccentColor, width: settings.wide ? "wide" : "narrow",
                                        fontSize: settings.fontSize, strings: ReaderStrings.all,
                                        changesOnly: self?.changesOnly)
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
        // Coalesce: if a parse is already running, queue the completion for
        // the follow-up read instead of queueing another full parse behind it.
        if readInFlight {
            readAgain = true
            pendingCompletions.append(completion)
            return
        }
        readInFlight = true
        readGeneration += 1
        let generation = readGeneration
        let url = self.url
        let resolver = self.resolver
        let cache = self.cache
        parseQueue.async {
            guard let data = try? Data(contentsOf: url) else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishRead(generation: generation, result: nil)
                }
                return
            }
            let hash = XXHash64.hash(data)
            let decoded = FileContent.decode(data)
            cache.beginGeneration()
            let doc = MarkdownParser.parse(decoded.text, resolver: resolver, cache: cache)
            let result = ReadResult(doc: doc, hash: hash, size: data.count, decoded: decoded)
            DispatchQueue.main.async { [weak self] in
                self?.finishRead(generation: generation, result: result)
            }
        }
        // The initiating completion waits for this read like any other.
        pendingCompletions.append(completion)
    }

    private func finishRead(generation: Int, result: ReadResult?) {
        guard generation == readGeneration else { return }  // superseded by a newer read
        if readAgain {
            // The file changed while we were parsing: re-read from disk, and
            // queued completions wait for that fresher result.
            readAgain = false
            readInFlight = false
            read { [weak self] result in self?.drainCompletions(with: result) }
            return
        }
        readInFlight = false
        let completions = pendingCompletions
        pendingCompletions = []
        for c in completions { c(result) }
    }

    private func drainCompletions(with result: ReadResult?) {
        let completions = pendingCompletions
        pendingCompletions = []
        for c in completions { c(result) }
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
                SmokeTest.run(controller: self, webView: self.webView)
                if let pending = self.pendingAnchor {
                    // Cross-file link target: the fragment wins over the saved position.
                    self.pendingAnchor = nil
                    self.scrollToAnchor(fragment: pending)
                } else if let slot = self.resumeSlot(from: record) {
                    let anchor = ["slot": slot, "offset": record?.topOffset ?? 0, "ratio": 0] as [String: Any]
                    if let data = try? JSONSerialization.data(withJSONObject: anchor), let json = String(data: data, encoding: .utf8) {
                        self.webView.call("scrollToAnchor", json: json)
                    }
                }
            }
        }
    }

    /// Restores the reading position. Block indices shift as agents edit, so the
    /// saved text excerpt is matched first; the saved index is a fallback for
    /// records written before excerpts existed.
    private func resumeSlot(from record: BaselineStore.Record?) -> Int? {
        guard let record else { return nil }
        let texts = session.blocks.map(\.text)
        if let excerpt = record.topExcerpt,
           let i = ExcerptAnchor.index(of: excerpt, in: texts, near: record.topBlockIndex), i < session.blocks.count {
            return session.blocks[i].slot
        }
        if let idx = record.topBlockIndex, idx < session.blocks.count { return session.blocks[idx].slot }
        return nil
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
        model.words = ReadingStats.words(in: session.blocks)
        model.minutes = ReadingStats.minutes(forBlocks: session.blocks)
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
            : String(format: NSLocalizedString("%d words · %d min read", comment: "Window subtitle when no tasks"), model.words,
                     model.minutes))
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
        case "copyLink":
            // Section link: "<filename>#<anchor>" on the clipboard.
            if let anchor = msg["anchor"] as? String, !anchor.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(url.lastPathComponent)#\(anchor)", forType: .string)
            }
        case "open":
            if let href = msg["href"] as? String { openLink(href) }
        case "loadRemote":
            if let url = msg["url"] as? String, let id = msg["id"] as? String {
                RemoteImageLoader.shared.load(url) { [weak self] result in
                    switch result {
                    case .success(let local):
                        self?.webView.call("remoteReady", ["id": id, "url": local])
                    case .failure(let error):
                        let reason: String
                        if case RemoteImageLoader.LoadError.rejected(let r) = error { reason = r }
                        else { reason = "could not be loaded" }
                        self?.webView.call("remoteFailed", ["id": id, "error": reason])
                    }
                }
            }
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
        // Split off the fragment first: other.md#section should open the file
        // AND scroll to the section.
        var fragment: String? = nil
        var path = href
        if let hash = path.firstIndex(of: "#") {
            fragment = String(path[path.index(after: hash)...])
            path = String(path[..<hash])
        }
        if path.lowercased().hasPrefix("file://"), let u = URL(string: path) {
            fragment = fragment ?? u.fragment
            path = u.path
        }
        path = path.removingPercentEncoding ?? path
        if fragment?.isEmpty == true { fragment = nil }
        guard !path.isEmpty else {
            // Same-document anchor: scroll in place.
            if let fragment { scrollToAnchor(fragment: fragment) }
            return
        }
        let target = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : url.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        if WorkspaceIndex.markdownExtensions.contains(target.pathExtension.lowercased()) {
            (NSApp.delegate as? AppDelegate)?.open(target, anchor: fragment)
        } else if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.open(target)
        } else {
            NSSound.beep()
        }
    }

    /// Scrolls to the heading whose slug matches the fragment (GitHub-style).
    func scrollToAnchor(fragment: String) {
        let slug = fragment.lowercased()
        if let block = session.blocks.first(where: {
            $0.kind == .heading && ($0.anchor == slug || $0.anchor?.lowercased() == slug)
        }) {
            webView.call("scrollToSlot", json: String(block.slot))
        } else {
            // Fall back to the page's own anchor lookup (percent-decoding, case variants).
            let fragJSON = (try? JSONSerialization.data(withJSONObject: ["fragment": fragment]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            webView.call("scrollToFragment", json: fragJSON)
        }
    }

    // MARK: Persistence

    /// Saves the reading position (cheap). Content baselines are saved
    /// separately, only when unread state changes.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private var lastSavedBaseline: [BlockKey]?
    private var lastSavedAnchorExcerpt: String?
    private var lastSavedAnchorIndex: Int?
    private var lastSavedAnchorOffset: Double?
    private var didSaveOnce = false

    func saveNow() {
        guard loaded else { return }
        var index: Int? = nil
        var excerpt: String? = nil
        if let a = lastAnchor, let i = session.blocks.firstIndex(where: { $0.slot == a.slot }) {
            index = i
            excerpt = String(session.blocks[i].text.prefix(120))
        }
        let baseline = session.baseline
        let offset = lastAnchor?.offset
        // Anchor-only scrolls must not rewrite the (potentially large)
        // baseline payload: skip the write when nothing changed at all.
        if didSaveOnce, baseline == lastSavedBaseline, excerpt == lastSavedAnchorExcerpt,
           index == lastSavedAnchorIndex, offset == lastSavedAnchorOffset { return }
        didSaveOnce = true
        lastSavedBaseline = baseline
        lastSavedAnchorExcerpt = excerpt
        lastSavedAnchorIndex = index
        lastSavedAnchorOffset = offset
        BaselineStore.save(.init(baseline: baseline, topBlockIndex: index, topOffset: offset,
                                 topExcerpt: excerpt, savedAt: Date()), for: url)
    }

    // MARK: Actions

    @objc func nextChange(_ sender: Any?) { webView.call("nextChange") }
    @objc func previousChange(_ sender: Any?) { webView.call("previousChange") }

    @objc func toggleChangesOnly(_ sender: Any?) {
        changesOnly.toggle()
        webView.call("setChangesOnly", json: changesOnly ? "true" : "false")
    }

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
        case #selector(toggleChangesOnly(_:)):
            item.state = changesOnly ? .on : .off
            return session.unreadCount > 0 || changesOnly
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
