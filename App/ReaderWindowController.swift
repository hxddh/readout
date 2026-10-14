import AppKit
import SwiftUI
import WebKit
import Combine
import ReadoutCore
import os

/// Keeps one reader page loaded and initialised in the background so a new window opens instantly.
@MainActor
final class WebViewPool: NSObject, WKNavigationDelegate {
    static let shared = WebViewPool()
    private var spare: ReaderWebView?

    func prewarm() {
        guard spare == nil else { return }
        let w = ReaderWebView(bundle: .main)
        w.navigationDelegate = self
        w.whenReady { w.call("warm") }
        spare = w
    }

    /// The idle spare's web content process died (memory pressure, a crash):
    /// drop it, or the next window would open on a blank page. A new one is
    /// made shortly.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === spare else { return }
        spare = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.prewarm() }
    }

    func take() -> ReaderWebView {
        let w = spare ?? ReaderWebView(bundle: .main)
        w.navigationDelegate = nil   // the window controller sets its own
        spare = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.prewarm() }
        return w
    }
}

extension NSToolbarItem.Identifier {
    static let nextChange = NSToolbarItem.Identifier("readout.nextChange")
    static let search = NSToolbarItem.Identifier("readout.search")
}

/// Performance signposts (visible in Instruments): "open" spans a window
/// request to its first patch on screen; "applied" marks every patch.
enum ReaderPerf {
    static let signposter = OSSignposter(subsystem: "io.github.hxddh.readout", category: "perf")
}

/// One window per file: sidebar outline + reader web view, live-updated from disk.
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    let url: URL
    let model = ReaderModel()
    var onClose: ((ReaderWindowController) -> Void)?
    /// The opened path is a symlink that now points to another file.
    var onRetarget: ((ReaderWindowController) -> Void)?

    private let session = DocumentSession()
    private let loader: DocumentLoader
    private let webView: ReaderWebView
    private var watcher: FileWatcher?
    private let splitController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var searchItem: NSSearchToolbarItem?
    private var changeItem: NSToolbarItem?
    private var cancellables: Set<AnyCancellable> = []
    /// The window's undo manager (Mark All as Read). Nothing between the web
    /// view and the window handles undo: itself, so this controller does.
    private let undoStack = UndoManager()

    // File state (content tracking lives in `loader`)
    private var loaded = false
    /// The first read failed: the next change on disk, or opening the file
    /// again, reads it again instead of waiting for a load that never comes.
    private var loadFailed = false
    /// A change that arrived while the first load was still parsing. Applied
    /// right after the initial patch so early agent writes are never lost.
    private var editedWhileLoading = false
    private var deleted = false
    private var lastAnchor: (slot: Int, offset: Double)?
    private var saveWork: DispatchWorkItem?
    /// Hides every block without an unread mark; headings stay visible as context.
    private var changesOnly = false
    /// Fragment from a cross-file link (other.md#section), scrolled to after load.
    private var pendingAnchor: String?

    /// When the window was asked for, for the open-to-first-paint measurement.
    private let openedAt = Date()
    private var painted = false
    private let openSignpost: OSSignpostIntervalState

    init(url: URL, pendingAnchor: String? = nil) {
        openSignpost = ReaderPerf.signposter.beginInterval("open")
        self.url = url.standardizedFileURL
        let base = self.url.deletingLastPathComponent()
        self.loader = DocumentLoader(url: self.url) {
            FileResolver(baseDirectory: base,
                         searchRoots: AppSettings.shared.workspaces.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
        }
        self.webView = WebViewPool.shared.take()
        self.pendingAnchor = pendingAnchor

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 460, height: 320)
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        // As System Settings ▸ Desktop & Dock ▸ "Prefer tabs" says; opens in
        // the background still join the reader's window as tabs (AppDelegate.open).
        window.tabbingMode = .automatic
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self

        buildContent()
        buildToolbar()
        configureWebView()
        observeSettings()

        window.title = url.lastPathComponent
        window.representedURL = url
        // Where the file is: on the tab, not in the subtitle.
        window.tab.toolTip = ReaderChrome.tabToolTip(path: self.url.path)
        window.setFrameAutosaveName("ReaderWindow")

        model.onSelectHeading = { [weak self] slot in self?.jumpToHeading(slot) }
        watcher = FileWatcher(url: self.url, onChange: { [weak self] change in self?.fileChanged(change) },
                              onRetarget: { [weak self] target in if let self { self.retargeted(to: target) } })
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
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .nextChange, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .nextChange:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = NSLocalizedString("Next Change", comment: "Toolbar")
            item.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(nextChange(_:))
            item.isBordered = true
            // Shown only with something unread. It is the last item before
            // the search field, so hiding it moves nothing else.
            item.autovalidates = false
            changeItem = item
            updateChangeItem(model.unread)
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = NSLocalizedString("Find", comment: "Search field placeholder")
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldAction(_:))
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.sendsWholeSearchString = true
            item.preferredWidthForSearchField = 160
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
        // The page scrolls under the toolbar; sticky table headers stop below it.
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self] _ in self?.updateTopInset() }
                .store(in: &cancellables)
        }
    }

    private var lastTopInset: Double = -1

    /// How much of the web view's top the window toolbar covers, in points.
    private func updateTopInset() {
        guard let window else { return }
        let web = webView.convert(webView.bounds, to: nil)
        let inset = max(0, Double(web.maxY - window.contentLayoutRect.maxY)).rounded()
        guard inset != lastTopInset else { return }
        lastTopInset = inset
        webView.whenReady { [weak self] in self?.webView.setAppearance(topInset: inset) }
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
                                        changesOnly: self?.changesOnly, codeWrap: settings.codeWrap)
        }
        lastTopInset = -1
        DispatchQueue.main.async { [weak self] in self?.updateTopInset() }
    }

    private func observeSettings() {
        let s = AppSettings.shared
        s.$fontSize.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }.store(in: &cancellables)
        s.$wide.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }.store(in: &cancellables)
        // A wrap toggled in one window applies to every open window.
        s.$codeWrap.dropFirst().removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }.store(in: &cancellables)
        model.$unread.sink { [weak self] n in self?.updateChangeItem(n) }.store(in: &cancellables)
        // The status (deleted, could not be read, decoded as…) is shown in the title bar, sidebar or not.
        model.$status.removeDuplicates().sink { [weak self] status in self?.updateSubtitle(status: status) }.store(in: &cancellables)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.request.url else { return .cancel }
        // The reader page is the only page: any other readout: URL (a
        // relative link resolved against the page, readout://app/other.md)
        // would replace the document with an error page.
        if target.scheme == ReadoutURL.scheme { return ReaderWebView.isReaderPage(target) ? .allow : .cancel }
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
            // The new page starts out of find mode, and switches queued before
            // the crash have run by now: send the state the window is in.
            self.webView.call("findMode", json: self.findModeOn ? "true" : "false")
        }
    }

    // MARK: Loading

    private func load() {
        loader.loadInitial { [weak self] result in
            guard let self else { return }
            guard let result else {
                self.loadFailed = true
                if self.editedWhileLoading {
                    // It changed while the failed read ran: read it again now.
                    self.editedWhileLoading = false
                    self.retryLoadIfFailed()
                    return
                }
                let gone = !FileManager.default.fileExists(atPath: self.url.path)
                self.deleted = gone
                self.model.status = gone ? NSLocalizedString("The file was deleted.", comment: "Status")
                                         : NSLocalizedString("The file could not be read.", comment: "Status")
                return
            }
            let record = BaselineStore.load(self.url, realPath: result.sourcePath)   // the file this read came from
            let patch = self.session.load(result.doc, baseline: record?.baseline)
            // What is on disk already: an unchanged baseline is not written again.
            self.lastSavedBaseline = record?.baseline
            self.loaded = true
            self.contentPath = result.sourcePath
            self.deleted = false
            self.updateModel(patch, decoded: result.decoded)
            self.webView.whenReady { [weak self] in
                guard let self else { return }
                self.webView.call("apply", patch)
                SmokeTest.run(controller: self, webView: self.webView)
                // An agent write that landed mid-load: re-read now that the
                // first patch is applied, so the fresh content wins.
                if self.editedWhileLoading {
                    self.editedWhileLoading = false
                    self.fileChanged(.modified)
                }
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

    /// Reads the file again when its first read failed.
    func retryLoadIfFailed() {
        guard !loaded, loadFailed else { return }
        loadFailed = false
        load()
    }

    private func fileChanged(_ change: FileWatcher.Change) {
        if !loaded && loadFailed {
            if change == .deleted {
                deleted = true
                model.status = NSLocalizedString("The file was deleted.", comment: "Status")
            } else {
                retryLoadIfFailed()
            }
            return
        }
        guard loaded else {
            // The first load is still parsing: don't drop the write, replay
            // it right after the initial patch instead.
            editedWhileLoading = true
            return
        }
        if change == .deleted {
            deleted = true
            model.status = NSLocalizedString("The file was deleted.", comment: "Status")
            return
        }
        loader.readChange { [weak self] change in
            guard let self else { return }
            defer { self.finishRetarget() }   // after the session took the new content
            guard case .content(let result) = change else {
                if self.deleted { self.deleted = false; self.model.status = nil }
                return
            }
            self.deleted = false
            let wasEmpty = self.session.blocks.isEmpty
            guard let patch = self.session.update(result.doc) else {
                self.model.status = nil
                return
            }
            self.updateModel(patch, decoded: result.decoded)
            let emptiedNow = !wasEmpty && self.session.blocks.isEmpty
            let restore = self.placeAfterRefill(wasEmpty: wasEmpty, patch: patch)
            self.webView.whenReady { [weak self] in
                guard let self else { return }
                if emptiedNow {
                    // Asked before the empty patch is applied (calls run in
                    // order): whether the reader sat at the end, following.
                    self.webView.evaluateJavaScript(Self.atBottomScript) { [weak self] value, _ in
                        self?.followingBeforeEmpty = (value as? Bool) ?? false
                    }
                }
                self.webView.call("apply", patch)
                if let restore { self.restorePlace(restore) }
            }
            self.scheduleSave()
        }
    }

    /// The page's own test for "at the end" (anchor.js atBottom).
    private static let atBottomScript = "(() => { const s = document.scrollingElement; return s.scrollHeight - (s.scrollTop + window.innerHeight) < 48 && s.scrollTop > 0; })()"

    /// Where the reader was when the file went empty (an agent truncating it
    /// before writing it again), until it has content again, and whether they
    /// were following the end then.
    private var anchorBeforeEmpty: (slot: Int, offset: Double)?
    private var followingBeforeEmpty = false

    /// After a brief truncate-and-refill the page returns to the reader's
    /// place itself (or to the end when following). As a fallback, when the
    /// reader was not following and the anchor block is back, the app sends
    /// that place once the page has applied the refill: a no-op when the page
    /// kept it. Never when following: the page goes to the new end.
    private func placeAfterRefill(wasEmpty: Bool, patch: RenderPatch) -> (slot: Int, offset: Double)? {
        if session.blocks.isEmpty {
            if anchorBeforeEmpty == nil { anchorBeforeEmpty = lastAnchor }
            return nil
        }
        defer { anchorBeforeEmpty = nil; followingBeforeEmpty = false }
        guard wasEmpty, patch.reset, let a = anchorBeforeEmpty, session.blocks.contains(where: { $0.slot == a.slot }) else { return nil }
        lastAnchor = a
        return followingBeforeEmpty ? nil : a
    }

    /// Restores a place after the page's next frame, once its own restore
    /// and the layout the refill caused have run.
    private func restorePlace(_ a: (slot: Int, offset: Double)) {
        let anchor = ["slot": a.slot, "offset": a.offset, "ratio": 0] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: anchor), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("requestAnimationFrame(() => window.readout.scrollToAnchor(\(json))); 1", completionHandler: nil)
    }

    /// `decoded`: how the content was read (sets the status); nil keeps the status.
    private func updateModel(_ patch: RenderPatch, decoded: FileContent.Decoded?) {
        model.toc = patch.toc
        model.tasks = patch.tasks
        model.unread = session.unreadCount
        model.title = patch.title ?? url.deletingPathExtension().lastPathComponent
        // Tabs of same-named files (every agent's plan.md) show the document's
        // title; the window title stays the file name.
        window?.tab.title = patch.title ?? url.lastPathComponent
        if let decoded, let enc = decoded.fallbackEncoding {
            let name = enc == FileContent.replacementEncoding
                ? NSLocalizedString("UTF-8 (with replacement characters)", comment: "Status: bytes that are no known encoding, shown with replacement characters")
                : enc
            model.status = String(format: NSLocalizedString("Decoded as %@", comment: "Status: non-UTF-8 file"), name)
        } else if decoded != nil {
            model.status = nil
        }
        if model.activeSlot == 0 { model.activeSlot = patch.toc.first?.slot ?? 0 }
        updateSubtitle()
    }

    /// The subtitle shows the file's status when there is one (deleted, could
    /// not be read, decoded as…), else task progress, else nothing (the
    /// folder is in the tab's tooltip).
    private func updateSubtitle(status: String?? = nil) {
        let status = status ?? model.status
        switch ReaderChrome.subtitle(status: status, tasks: model.tasks) {
        case .status(let s): window?.subtitle = s
        case .tasks(let done, let total):
            window?.subtitle = String(format: NSLocalizedString("%d of %d tasks done", comment: "Window subtitle"), done, total)
        case nil: window?.subtitle = ""
        }
    }

    private func updateChangeItem(_ n: Int) {
        guard let item = changeItem else { return }
        item.isEnabled = n > 0
        item.isHidden = n == 0
        item.badge = n > 0 ? .count(n) : nil
        item.toolTip = n > 0
            ? String(format: NSLocalizedString("Unread changes: %d. Press N for the next change, D to see what changed.", comment: "Toolbar tooltip; %d is the number of unread changes"), n)
            : NSLocalizedString("No unread changes", comment: "Toolbar tooltip")
    }

    // MARK: Messages from the page

    private func handle(_ raw: [String: Any]) {
        guard let msg = PageMessage(raw) else { return }
        switch msg {
        case .read(let slots, let deletions):
            session.markRead(slots: slots, deletionIDs: deletions)
            model.unread = session.unreadCount
            scheduleSave()
        case .activeHeading(let slot):
            if slot != model.activeSlot { model.activeSlot = slot }
        case .anchor(let slot, let offset):
            lastAnchor = (slot, offset)
            scheduleSave()
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .copyLink(let anchor):
            // Section link: "<full path>#<anchor>" on the clipboard, usable from anywhere.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(url.path)#\(anchor)", forType: .string)
        case .applied:
            ReaderPerf.signposter.emitEvent("applied")
            SmokeTest.noteApplied()
        case .painted:
            SmokeTest.notePainted()
            if !painted {
                // First patch presented on screen: the open is done.
                painted = true
                ReaderPerf.signposter.endInterval("open", openSignpost)
                SmokeTest.noteFirstPaint(url, seconds: Date().timeIntervalSince(openedAt))
            }
        case .open(let href):
            openLink(href)
        case .loadRemote(let remote, let id):
            loadRemote(remote, id: id)
        case .openPath(let path, let line, let column):
            EditorOpener.open(path: path, line: line, column: column)
        case .setCodeWrap(let on):
            if AppSettings.shared.codeWrap != on { AppSettings.shared.codeWrap = on }
        case .nothing:
            // A key with nothing to go to (N past the last change).
            NSSound.beep()
        case .ready, .error:
            break   // handled by ReaderWebView
        }
    }

    private func loadRemote(_ remote: String, id: String) {
        RemoteImageLoader.shared.load(remote) { [weak self] result in
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

    private func openLink(_ href: String) {
        guard let target = LinkTarget.resolve(href, from: url, markdownExtensions: WorkspaceIndex.markdownExtensions,
                                              fileExists: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        switch target {
        case .external(let u), .file(let u): NSWorkspace.shared.open(u)
        case .sameDocument(let fragment): scrollToAnchor(fragment: fragment)
        case .markdown(let u, let fragment): (NSApp.delegate as? AppDelegate)?.open(u, anchor: fragment)
        case .missing: NSSound.beep()
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

    /// The opened symlink points to another file, whose state has its own key.
    /// Until that file's content is read, the session still holds the old
    /// one: saves wait until a read of that file (not one of the old target
    /// still in flight) lands, then the next save writes the whole record there.
    private var retargetGate = RetargetGate()
    /// The real path of the file whose content the session holds: the key the
    /// reading state is saved under. Not resolved at save time, which could
    /// already see a retarget the window has not read yet.
    private var contentPath: String?
    private func retargeted(to target: String) {
        retargetGate.retargeted(to: target)
        onRetarget?(self)
    }

    /// A read filled the session: when it was the retargeted file's, saves resume under its key.
    private func finishRetarget() {
        guard retargetGate.read(from: loader.lastSourcePath) else { return }
        contentPath = loader.lastSourcePath ?? contentPath
        didSaveOnce = false
        lastSavedBaseline = nil
        scheduleSave()
    }

    func saveNow() {
        guard loaded, !retargetGate.isPending else { return }
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
        let baselineChanged = baseline != lastSavedBaseline
        didSaveOnce = true
        lastSavedBaseline = baseline
        lastSavedAnchorExcerpt = excerpt
        lastSavedAnchorIndex = index
        lastSavedAnchorOffset = offset
        BaselineStore.save(.init(baseline: baseline, topBlockIndex: index, topOffset: offset,
                                 topExcerpt: excerpt, savedAt: Date()),
                           for: contentPath.map { URL(fileURLWithPath: $0) } ?? url, baselineChanged: baselineChanged)
    }

    // MARK: Actions

    @objc func nextChange(_ sender: Any?) { webView.call("nextChange") }
    @objc func previousChange(_ sender: Any?) { webView.call("previousChange") }

    @objc func toggleChangesOnly(_ sender: Any?) {
        changesOnly.toggle()
        webView.call("setChangesOnly", json: changesOnly ? "true" : "false")
    }

    @objc func markAllRead(_ sender: Any?) {
        guard session.unreadCount > 0 else { return }
        let before = session.baseline
        session.markAllRead()
        model.unread = 0
        webView.call("markAllRead")
        scheduleSave()
        // ⌘Z brings the marks back.
        undoStack.registerUndo(withTarget: self) { $0.restoreUnread(baseline: before) }
        undoStack.setActionName(NSLocalizedString("Mark All as Read", comment: "Menu"))
    }

    /// Undo of Mark All as Read: the document marked against the baseline from
    /// before, as reopening the window would show it, at the same place.
    private func restoreUnread(baseline: [BlockKey]) {
        let place = lastAnchor.flatMap { a in session.blocks.firstIndex { $0.slot == a.slot }.map { (index: $0, offset: a.offset) } }
        let patch = session.reload(baseline: baseline)
        model.activeSlot = 0   // the slots are new
        updateModel(patch, decoded: nil)
        let restore = place.flatMap { p in p.index < session.blocks.count ? (slot: session.blocks[p.index].slot, offset: p.offset) : nil }
        if let restore { lastAnchor = restore }
        webView.whenReady { [weak self] in
            guard let self else { return }
            self.webView.call("apply", patch)
            if let restore { self.restorePlace(restore) }
        }
        scheduleSave()
        // Redo marks everything read again.
        undoStack.registerUndo(withTarget: self) { $0.markAllRead(nil) }
        undoStack.setActionName(NSLocalizedString("Mark All as Read", comment: "Menu"))
    }

    // Edit ▸ Undo / Redo with the page focused (the find field's editor
    // handles its own text first).
    @objc func undo(_ sender: Any?) { if undoStack.canUndo { undoStack.undo() } }
    @objc func redo(_ sender: Any?) { if undoStack.canRedo { undoStack.redo() } }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoStack }

    /// A click in the outline: to that heading, every time (clicking the row
    /// already selected jumps again), then back to the page so the keyboard
    /// scrolls it. Arrow keys in the outline keep the focus there.
    private var lastJump: (slot: Int, at: Date)?
    private func jumpToHeading(_ slot: Int) {
        // The selection change and the click both report one click.
        if let last = lastJump, last.slot == slot, Date().timeIntervalSince(last.at) < 0.3 { return }
        lastJump = (slot, Date())
        webView.call("scrollToSlot", json: String(slot))
        let mouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        if let type = NSApp.currentEvent?.type, mouse.contains(type) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.webView)
            }
        }
    }

    @objc func toggleWidth(_ sender: Any?) { AppSettings.shared.wide.toggle() }

    @objc func revealInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    @objc func openInEditor(_ sender: Any?) { EditorOpener.open(path: url.path, line: 0, column: 0) }

    @objc func copyFilePath(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func printDocument(_ sender: Any?) {
        // Diagrams and code are drawn lazily near the viewport: the page draws
        // the rest first (it gives up after a few seconds), then prints.
        webView.callAsyncJavaScript("return await window.readout.preparePrint()", in: nil, in: .page) { [weak self] _ in
            self?.runPrint()
        }
    }

    private func runPrint() {
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
        setFindMode(true)
        item.beginSearchInteraction()
    }

    /// While finding, the page lays out the whole document: in a large one it
    /// otherwise skips off-screen blocks, and so would find in page. Sent only
    /// when it changes: each switch re-lays out the document.
    private var findModeOn = false
    private func setFindMode(_ on: Bool) {
        guard on != findModeOn else { return }
        findModeOn = on
        // A cold window's page may not be up yet: deliver once it is.
        webView.whenReady { [weak self] in
            guard let self else { return }
            self.webView.call("findMode", json: on ? "true" : "false")
            SmokeTest.noteFindMode(on, pageReady: self.webView.isReady)
        }
    }

    // Find mode stays on while the find bar is open: Return in the field may
    // end and restart editing, which must not re-lay out the document twice.
    // It ends on Escape, when editing ends with the field empty, or when the
    // field has given up focus and its bar is collapsed (closed with text in it).
    private var editingGeneration = 0
    func controlTextDidBeginEditing(_ obj: Notification) {
        editingGeneration += 1
        setFindMode(true)
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        editingGeneration += 1
        if searchItem?.searchField.stringValue.isEmpty ?? true {
            setFindMode(false)
            return
        }
        // Return ends and restarts editing at once: decide once that settled.
        let generation = editingGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editingGeneration == generation, !self.isSearchFieldEditing, self.isSearchCollapsed else { return }
            self.setFindMode(false)
        }
    }
    func searchFieldDidEndSearching(_ sender: NSSearchField) { setFindMode(false) }

    /// The find field is the window's field editor's client (it has focus).
    private var isSearchFieldEditing: Bool {
        guard let field = searchItem?.searchField, let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// The find bar shows only its button: collapsed, or not in the window at all.
    private var isSearchCollapsed: Bool {
        guard let field = searchItem?.searchField, field.window != nil, !field.isHiddenOrHasHiddenAncestor else { return true }
        return field.bounds.width < 60
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
        // Find mode lays out the whole document, so matches off screen in a
        // large one are found. ⌘G with the find bar closed switches it on for
        // this search only: left on, it would stay with no bar to close.
        let onlyForThisSearch = !findModeOn && isSearchCollapsed && !isSearchFieldEditing
        setFindMode(true)
        webView.find(text, configuration: config) { [weak self] result in
            if !result.matchFound { NSSound.beep() }
            guard let self, onlyForThisSearch, self.isSearchCollapsed, !self.isSearchFieldEditing else { return }
            self.setFindMode(false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            editingGeneration += 1
            searchItem?.endSearchInteraction()
            setFindMode(false)
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
        case #selector(undo(_:)):
            item.title = undoStack.undoMenuItemTitle
            return undoStack.canUndo
        case #selector(redo(_:)):
            item.title = undoStack.redoMenuItemTitle
            return undoStack.canRedo
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
