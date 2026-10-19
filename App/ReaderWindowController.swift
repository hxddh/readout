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

    /// When the next spare page is made: not while the page just taken is
    /// still loading (at launch, WebKit's first process start), but once a
    /// page has painted its first document, or a few seconds after the page
    /// taken is ready when none paints.
    private var plan = SparePagePlan()

    func take() -> ReaderWebView {
        let w = spare ?? ReaderWebView(bundle: .main)
        w.navigationDelegate = nil   // the window controller sets its own
        spare = nil
        let token = plan.taken()
        // The fallback counts from the page's ready, so the next spare never
        // competes with its load.
        w.whenReady { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + SparePagePlan.fallback) { [weak self] in
                guard let self, self.plan.fallbackFired(token) else { return }
                self.prewarm()
            }
        }
        return w
    }

    /// A window's page painted its first document: the spare page owed is made now.
    func pagePainted() {
        guard plan.painted() else { return }
        // After the frame that showed it, not inside the message reporting it.
        DispatchQueue.main.async { [weak self] in self?.prewarm() }
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
    /// Whether the document shows unread changes changed (the Dock badge counts them).
    var onUnreadShownChanged: (() -> Void)?
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
    /// The window's undo manager (Mark All as Read; NSWindow handles undo:
    /// with it). A few levels: each one keeps a whole baseline.
    private let undoStack: UndoManager = {
        let u = UndoManager()
        u.levelsOfUndo = 5
        return u
    }()
    /// Given to the window while the document is momentarily empty (an agent
    /// truncating before it writes): Undo is disabled then, the actions wait.
    private let idleUndo = UndoManager()
    /// The tab group whose tab bar the subtitle follows.
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabBarObservations: [NSKeyValueObservation] = []
    private var windowObservations: [NSKeyValueObservation] = []

    // File state (content tracking lives in `loader`)
    private var loaded = false
    /// ⌘P before the first document was applied (`didLoad`): printed then.
    private var printWhenLoaded = false
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
    /// The project folder the document's paths are relative to (an agent's
    /// working folder, from `readout --hook`), read by the loader's resolver.
    private final class ProjectRootBox { var path: String? }
    private let projectRoot: ProjectRootBox
    /// A project folder arrived: the next read renders the same bytes again.
    private var rereadForRoot = false

    /// When the window was asked for, for the open-to-first-paint measurement.
    private let openedAt = Date()
    private var painted = false
    private var appliedOnce = false
    private let openSignpost: OSSignpostIntervalState

    init(url: URL, pendingAnchor: String? = nil, projectRoot root: String? = nil) {
        openSignpost = ReaderPerf.signposter.beginInterval("open")
        self.url = url.standardizedFileURL
        let base = self.url.deletingLastPathComponent()
        // The folder given now, else the one kept from an earlier open (across relaunches).
        let stored = BaselineStore.projectRoot(for: self.url)
        if let root, root != stored { BaselineStore.saveProjectRoot(root, for: self.url) }
        let project = ProjectRootBox()
        project.path = root ?? stored
        self.projectRoot = project
        self.loader = DocumentLoader(url: self.url) {
            FileResolver(baseDirectory: base, project: project.path, workspaces: AppSettings.shared.workspaces)
        }
        SmokeTest.noteLaunchPhase("window_init")
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
        // Back on the next launch as System Settings ▸ Desktop & Dock ▸
        // "Close windows when quitting an application" says (ReaderRestoration).
        window.isRestorable = true
        window.restorationClass = ReaderRestoration.self
        window.identifier = NSUserInterfaceItemIdentifier("reader-" + UUID().uuidString)
        super.init(window: window)
        window.delegate = self

        buildContent()
        buildToolbar()
        configureWebView()
        observeSettings()
        // The first window's page up (the spare made at launch, or one made for it).
        webView.whenReady { SmokeTest.noteLaunchPhase("page_ready") }

        window.title = url.lastPathComponent
        window.representedURL = url
        // Where the file is: on the tab, not in the subtitle.
        updateTabToolTip()
        // Every reader window saves its frame under one name when resized or
        // closed, and a new one starts from it. (As the frame autosave name,
        // only the first window could have it: the others never saved theirs.)
        window.setFrameUsingName(Self.frameName)

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
            // macOS 26 grows the field into the free toolbar space whatever
            // the preferred width says: hold it at that width.
            let width = item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 160)
            width.isActive = true
            searchItem = item
            return item
        default:
            return nil
        }
    }

    // MARK: Web view

    private func configureWebView() {
        webView.navigationDelegate = self
        // macOS 26's soft scroll edge under the toolbar: WebKit gives its top
        // scroll pocket the automatic (soft) style only when the web view uses
        // the automatic content-inset background fill, and the hard style
        // otherwise, which looks like no edge effect at all
        // (WebViewImpl::updateTopScrollPocketStyle). Private, off by default,
        // so asked for only where the web view answers to it; set before the
        // first inset so the pocket is made with it. KVC finds the
        // underscored setter (_set<Key>:).
        if webView.responds(to: NSSelectorFromString("_setUsesAutomaticContentInsetBackgroundFill:")) {
            webView.setValue(true, forKey: "usesAutomaticContentInsetBackgroundFill")
        }
        webView.onMessage = { [weak self] msg in self?.handle(msg) }
        webView.onContextMenu = { [weak self] menu in self?.addQuoteItem(to: menu) }
        // Proxied remote images: the page posts loadRemote, we download with a
        // cookie-free ephemeral session and serve the bytes back over readout:.
        // Quick Look never sets this, so remote loading stays disabled there.
        webView.remoteProvider = { RemoteImageLoader.shared.entry(for: $0).map { (data: $0.data, contentType: $0.contentType) } }
        applyAppearance()
        // Images the reader loaded before show without asking again: those
        // known now, before the document arrives, and those loaded later in any window.
        sendKnownImages()
        NotificationCenter.default.publisher(for: RemoteImageLoader.didLoad)
            .sink { [weak self] note in
                guard let self, let url = note.userInfo?["url"] as? String, let local = note.userInfo?["local"] as? String else { return }
                self.webView.whenReady { [weak self] in self?.webView.call("remoteKnown", [url: local]) }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &cancellables)
        window?.publisher(for: \.effectiveAppearance)
            .dropFirst()
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &cancellables)
        // The page scrolls under the toolbar's glass (obscuredContentInsets).
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self] _ in self?.updateTopInset() }
                .store(in: &cancellables)
        }
        // A tab bar shown or hidden moves the toolbar's edge without resizing
        // the window: the layout rect says so.
        layoutObservation = window?.observe(\.contentLayoutRect) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateTopInset() } }
        }
    }

    private var layoutObservation: NSKeyValueObservation?

    /// The inset given to the web view and the toolbar's edge it should match (smoke test).
    var topInsetState: [String: Double] {
        guard let window else { return [:] }
        let web = webView.convert(webView.bounds, to: nil)
        return ["obscured_top": Double(webView.obscuredContentInsets.top),
                "layout_gap": max(0, Double(web.maxY - window.contentLayoutRect.maxY)).rounded()]
    }

    private func sendKnownImages() {
        let known = RemoteImageLoader.shared.known
        guard !known.isEmpty else { return }
        webView.whenReady { [weak self] in self?.webView.call("remoteKnown", known) }
    }

    private var lastTopInset: Double = -1

    /// How much of the web view's top the window toolbar covers, in points.
    /// WebKit lays the page out below it (scroll position, sticky headers,
    /// anchors) while the content scrolls on under the toolbar's glass, with
    /// the system's scroll edge effect; the page itself needs no inset.
    private func updateTopInset() {
        guard let window else { return }
        let web = webView.convert(webView.bounds, to: nil)
        let inset = max(0, Double(web.maxY - window.contentLayoutRect.maxY)).rounded()
        guard inset != lastTopInset else { return }
        lastTopInset = inset
        webView.obscuredContentInsets = NSEdgeInsets(top: CGFloat(inset), left: 0, bottom: 0, right: 0)
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
        // The new page has no selection and no focused block yet (Copy as Quote).
        hasSelection = false
        hasFocusedBlock = false
        self.webView.reloadReader()
        self.webView.whenReady { [weak self] in
            guard let self else { return }
            self.applyAppearance()
            self.sendKnownImages()
            self.webView.callEncodingOffMain("apply", self.session.fullPayload(rewrite: false).page)
            // The new page starts out of find mode, and switches queued before
            // the crash have run by now: send the state the window is in.
            self.webView.call("findMode", json: self.findModeOn ? "true" : "false")
        }
    }

    // MARK: Loading

    private func load() {
        // The reading state is read and decoded (JSON ~1.6× the document's
        // size) off the main thread, while the document parses.
        let saved = BaselineStore.prefetch(url)
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
                // Nothing to print but the failure: a later read does not print on its own.
                self.printWhenLoaded = false
                self.showLoadFailure()
                return
            }
            saved.record(forSourcePath: result.sourcePath) { [weak self] record in   // the file this read came from
                guard let self else { return }
                guard record == nil else { return self.didLoad(result, record: record) }
                // Never opened before: in a git repository, marked against the last commit.
                CommitBaseline.find(path: result.sourcePath, current: result.decoded.text) { [weak self] keys in
                    self?.didLoad(result, record: nil, commitBaseline: keys)
                }
            }
        }
    }

    /// The first read failed: the page says why in its empty state, instead of staying blank.
    private var showsLoadFailure = false
    private func showLoadFailure() {
        guard let status = model.status else { return }
        showsLoadFailure = true
        webView.whenReady { [weak self] in
            guard let self, self.showsLoadFailure, !self.loaded else { return }
            self.webView.setAppearance(strings: ["empty": status])
            self.webView.call("apply", json: Self.emptyPatch)
        }
    }
    private static let emptyPatch = #"{"version":0,"reset":true,"rewrite":false,"ops":[],"marks":[],"deletions":[]}"#

    private func didLoad(_ result: DocumentLoader.ReadResult, record: BaselineStore.Record?, commitBaseline: [BlockKey]? = nil) {
        SmokeTest.noteLaunchPhase("did_load")
        let patch = self.session.load(result.doc, baseline: record?.baseline ?? commitBaseline)
        contentGeneration += 1
        defer { refreshRepository() }   // once contentPath is set below
        // What is marked is what changed since the last commit, not since the reader last read it.
        let commitNotice = commitBaseline == nil ? nil : CommitNotice.after(rewrite: patch.rewrite, unread: session.unreadCount)
        // What is on disk already: an unchanged baseline is not written again.
        self.lastSavedBaseline = record?.baseline
        self.loaded = true
        self.contentPath = result.sourcePath
        self.deleted = false
        self.updateModel(patch, decoded: result.decoded)
        self.webView.whenReady { [weak self] in
            guard let self else { return }
            if self.showsLoadFailure {
                // The empty state says "empty" again.
                self.showsLoadFailure = false
                self.webView.setAppearance(strings: ReaderStrings.all)
            }
            // A whole document: encoded off the main thread, still delivered before the calls below.
            self.webView.callEncodingOffMain("apply", patch.page)
            // After the apply: in place of the page's own "This file was rewritten".
            if let commitNotice { self.webView.call("notice", Self.text(commitNotice)) }
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
            } else if let slot = self.resumeSlot(from: record, rewritten: patch.rewrite) {
                let anchor = ["slot": slot, "offset": record?.topOffset ?? 0, "ratio": 0] as [String: Any]
                if let data = try? JSONSerialization.data(withJSONObject: anchor), let json = String(data: data, encoding: .utf8) {
                    self.webView.call("scrollToAnchor", json: json)
                }
            }
            // ⌘P while it loaded: now, queued behind the document's apply.
            if self.printWhenLoaded {
                self.printWhenLoaded = false
                self.printDocument(nil)
            }
        }
    }

    /// Restores the reading position (see ExcerptAnchor.resumeIndex).
    private func resumeSlot(from record: BaselineStore.Record?, rewritten: Bool) -> Int? {
        guard let record else { return nil }
        let i = ExcerptAnchor.resumeIndex(excerpt: record.topExcerpt, index: record.topBlockIndex,
                                          in: session.blocks.map(\.text), rewritten: rewritten)
        return i.map { session.blocks[$0].slot }
    }

    /// An agent named the folder it works in (`readout --hook`): paths in the
    /// document are looked up there too, now and when the file is opened again.
    func setProjectRoot(_ root: String) {
        guard root != projectRoot.path else { return }
        projectRoot.path = root
        BaselineStore.saveProjectRoot(root, for: url)
        updateTabToolTip()
        updateSubtitle()
        window?.invalidateRestorableState()
        rereadForRoot = true
        if loaded { fileChanged(.modified) } else { editedWhileLoading = true }
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
                showLoadFailure()
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
        if rereadForRoot {
            rereadForRoot = false
            loader.forgetContent()
        }
        loader.readChange { [weak self] change in
            guard let self else { return }
            defer { self.finishRetarget() }   // after the session took the new content
            guard case .content(let result) = change else {
                if self.deleted { self.deleted = false; self.model.status = nil }
                return
            }
            self.deleted = false
            self.contentGeneration += 1
            self.refreshRepository()
            let wasEmpty = self.session.blocks.isEmpty
            guard let patch = self.session.update(result.doc) else {
                self.model.status = nil
                return
            }
            // A whole document again (a reset) is shown at once: the page holds back only what a patch adds.
            self.updateModel(patch, decoded: result.decoded, holdIncrease: !patch.reset)
            let emptiedNow = !wasEmpty && self.session.blocks.isEmpty
            let restore = self.placeAfterRefill(wasEmpty: wasEmpty, patch: patch)
            self.webView.whenReady { [weak self] in
                guard let self else { return }
                if emptiedNow {
                    // Asked before the empty patch is applied (calls run in
                    // order): whether the reader sat at the end, following.
                    self.webView.run(Self.atBottomScript) { [weak self] value, _ in
                        self?.followingBeforeEmpty = (value as? Bool) ?? false
                    }
                }
                if patch.reset {
                    // A whole document (a rewrite): encoded off the main thread,
                    // still delivered before the calls below.
                    self.webView.callEncodingOffMain("apply", patch.page)
                } else {
                    self.webView.call("apply", patch.page)
                }
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
        webView.run("requestAnimationFrame(() => window.readout.scrollToAnchor(\(json))); 1")
    }

    /// `decoded`: how the content was read (sets the status); nil keeps the status.
    private func updateModel(_ patch: RenderPatch, decoded: FileContent.Decoded?, holdIncrease: Bool = false) {
        // Assigned only when changed: each assignment has SwiftUI compare the
        // whole sidebar again, and most patches leave the outline as it was.
        if model.toc != patch.toc { model.toc = patch.toc }
        if model.tasks != patch.tasks { model.tasks = patch.tasks }
        refreshUnread(holdIncrease: holdIncrease)
        model.title = patch.title ?? url.deletingPathExtension().lastPathComponent
        // Tabs of same-named files (every agent's plan.md) show the document's
        // title; the window title stays the file name. Tabs whose documents
        // have the same title too name their files (updateTabTitles).
        let tabTitle = patch.title ?? url.lastPathComponent
        if tabTitle != documentTitle {
            documentTitle = tabTitle
            updateTabTitles()
        }
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
    /// not be read, decoded as…), else task progress, else, for a window
    /// without a tab bar, the file's folder (with one, the tab's tooltip has
    /// the path).
    private func updateSubtitle(status: String?? = nil) {
        let status = status ?? model.status
        observeTabBar()
        if let flash = flashText, status == nil {
            window?.subtitle = flash
            return
        }
        let showsTabBar = window?.tabGroup?.isTabBarVisible ?? false
        switch ReaderChrome.subtitle(status: status, tasks: model.tasks, path: url.path, showsTabBar: showsTabBar, project: projectName) {
        case .status(let s): window?.subtitle = s
        case .tasks(let done, let total):
            window?.subtitle = String(format: NSLocalizedString("%d of %d tasks done", comment: "Window subtitle"), done, total)
        case .projectTasks(let project, let done, let total):
            window?.subtitle = project + " · " + String(format: NSLocalizedString("%d of %d tasks done", comment: "Window subtitle"), done, total)
        case .folder(let name): window?.subtitle = name
        case nil: window?.subtitle = ""
        }
    }

    /// The project a plan outside it was written for (`readout --hook`): its
    /// name in the subtitle, its folder in the tab's tooltip.
    private var projectName: String? { ReaderChrome.projectName(path: url.path, projectRoot: projectRoot.path) }

    private func updateTabToolTip() {
        var tip = ReaderChrome.tabToolTip(path: url.path)
        if projectName != nil, let root = projectRoot.path {
            tip += "\n" + String(format: NSLocalizedString("Project: %@", comment: "Tab tooltip line: the project folder a plan outside it was written for"),
                                 ReaderChrome.tabToolTip(path: root))
        }
        if window?.tab.toolTip != tip { window?.tab.toolTip = tip }
    }

    /// A passing message in the subtitle (a link to a file that is not
    /// there), for a few seconds; the file's own status wins.
    private var flashText: String?
    private var flashWork: DispatchWorkItem?
    private func flashStatus(_ text: String) {
        flashText = text
        updateSubtitle()
        announce(text)
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flashText = nil
            self?.updateSubtitle()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// Says `text` to VoiceOver now.
    private func announce(_ text: String) {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The window joined or left tabs, or its tab bar was shown or hidden:
    /// the subtitle and the tab titles follow.
    func tabsChanged() {
        updateSubtitle()
        updateTabTitles()
        // Which tabs it is among comes back on the next launch.
        window?.invalidateRestorableState()
    }

    /// The document's title, as its tab shows it unless another tab in the
    /// group has the same one.
    private(set) var documentTitle: String = ""

    /// The titles of every tab in the window's group: a title two documents
    /// share is followed by the file name (or folder) that tells them apart.
    private func updateTabTitles() {
        guard let window else { return }
        let readers = (window.tabGroup?.windows ?? [window]).compactMap { $0.windowController as? ReaderWindowController }
        let base = readers.map { $0.documentTitle.isEmpty ? $0.url.lastPathComponent : $0.documentTitle }
        let titles = ReaderChrome.tabTitles(titles: base, paths: readers.map(\.url.path))
        for (reader, title) in zip(readers, titles) where reader.window?.tab.title != title { reader.window?.tab.title = title }
    }

    /// Follows the tab bar of the window's current tab group, and the window
    /// itself: its group is made or replaced (Show Tab Bar, Merge All Windows,
    /// a tab dragged out) while it stays key.
    private func observeTabBar() {
        let changed: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.tabsChanged() } }
        }
        let selected: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.selectedTabChanged() } }
        }
        if windowObservations.isEmpty, let window {
            windowObservations = [
                window.observe(\.tabGroup) { _, _ in changed() },
                window.observe(\.tabbedWindows) { _, _ in changed() },
            ]
        }
        guard let group = window?.tabGroup, group !== observedTabGroup else { return }
        observedTabGroup = group
        tabBarObservations = [
            group.observe(\.isTabBarVisible) { _, _ in changed() },
            group.observe(\.windows) { _, _ in changed() },
            group.observe(\.selectedWindow) { _, _ in selected() },
        ]
    }

    /// Another tab was selected: which one is selected comes back on the next
    /// launch, so every tab's restorable state (its `selected`) is stale.
    /// (Selecting a tab makes it key; a selection made in code may not.)
    private func selectedTabChanged() {
        for w in window?.tabGroup?.windows ?? [] { w.invalidateRestorableState() }
    }

    /// The unread count, the outline entries with an unread change, and the
    /// tab's dot. `holdIncrease`: a patch an agent wrote may have added
    /// unread changes the reader reads as they arrive: more unread waits until
    /// the page says what it added is to be shown (`showUnread`), or a moment
    /// at most; less shows at once (UnreadDisplay).
    private func refreshUnread(holdIncrease: Bool = false) {
        // On the tab, in the tab bar only: the document has unread changes,
        // or was opened behind and has not been looked at yet.
        let n = session.unreadCount
        let actual = UnreadDisplay(count: n, sections: session.unreadSections, dot: CrossDocument.needsAttention(unread: n, lookedAt: notedRecent))
        let shown = UnreadDisplay(count: model.unread, sections: model.unreadSections, dot: window?.tab.accessoryView != nil)
        var show = actual
        if holdIncrease || unreadHold != nil {
            let next = UnreadDisplay.next(shown: shown, actual: actual)
            show = next.show
            if next.held { holdUnread() } else { releaseHold() }
        }
        showUnread(show)
    }

    private func showUnread(_ d: UnreadDisplay) {
        let had = showsAttention
        if model.unread != d.count { model.unread = d.count }
        if model.unreadSections != d.sections { model.unreadSections = d.sections }
        if let tab = window?.tab, (tab.accessoryView != nil) != d.dot {
            tab.accessoryView = d.dot ? UnreadDotView() : nil
        }
        // The Dock badge counts what the tab's dot says.
        if had != showsAttention { onUnreadShownChanged?() }
    }

    /// More unread waiting for the page's `showUnread`, with its fallback.
    private var unreadHold: DispatchWorkItem?
    private static let unreadHoldFallback: TimeInterval = 2.5

    private func holdUnread() {
        guard unreadHold == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.unreadShown() }
        unreadHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unreadHoldFallback, execute: work)
    }

    private func releaseHold() {
        unreadHold?.cancel()
        unreadHold = nil
    }

    /// The page says what it added is to be shown (or the fallback ran out).
    private func unreadShown() {
        releaseHold()
        refreshUnread()
    }

    /// The document has unread changes (the session's, shown or about to be).
    var hasUnread: Bool { session.unreadCount > 0 }

    /// Waiting for the reader, as the tab's dot says: unread changes, or opened
    /// behind and not looked at yet (Open Latest Agent File).
    var needsAttention: Bool { CrossDocument.needsAttention(unread: session.unreadCount, lookedAt: notedRecent) }

    /// Shows the document's unread changes (the toolbar's count).
    var showsUnread: Bool { model.unread > 0 }

    /// Shows that it waits for the reader, as the tab's dot does: unread
    /// changes, or opened behind and not looked at yet (the Dock badge counts these).
    var showsAttention: Bool { model.unread > 0 || window?.tab.accessoryView != nil }

    private func updateChangeItem(_ n: Int) {
        guard let item = changeItem else { return }
        item.isEnabled = n > 0
        item.isHidden = n == 0
        if n > 0 { item.image = Self.changeImage(count: n) }
        item.toolTip = n > 0
            ? String(format: NSLocalizedString("Unread changes: %d. Press N for the next change, D to see what changed.", comment: "Toolbar tooltip; %d is the number of unread changes"), n)
            : NSLocalizedString("No unread changes", comment: "Toolbar tooltip")
    }

    /// The next-change button: the arrow with the unread count in a badge of
    /// the accent colour. NSItemBadge is always red, which reads as an error;
    /// unread changes are not one. Drawn when shown, in the window's appearance.
    static func changeImage(count: Int) -> NSImage {
        let text = count > 99 ? "99+" : String(count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let badge = NSSize(width: max(13, ceil(textSize.width) + 6), height: 13)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(config) ?? NSImage()
        let a = arrow.size
        // The badge sits over the arrow's top right, as the system's does.
        let size = NSSize(width: ceil(a.width / 2 + 3 + badge.width), height: ceil(max(a.height + 5, badge.height + 6)))
        let image = NSImage(size: size, flipped: false) { rect in
            let tinted = arrow.withSymbolConfiguration(config.applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))) ?? arrow
            tinted.draw(in: NSRect(x: 0, y: 0, width: a.width, height: a.height))
            let b = NSRect(x: rect.width - badge.width, y: rect.height - badge.height, width: badge.width, height: badge.height)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: b, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
            (text as NSString).draw(at: NSPoint(x: b.midX - textSize.width / 2, y: b.midY - textSize.height / 2),
                                    withAttributes: [.font: font, .foregroundColor: NSColor.white])
            return true
        }
        image.accessibilityDescription = String(format: NSLocalizedString("Unread changes: %d", comment: "Next-change button for VoiceOver; %d is the number"), count)
        return image
    }

    // MARK: Messages from the page

    private func handle(_ raw: [String: Any]) {
        guard let msg = PageMessage(raw) else { return }
        switch msg {
        case .read(let slots, let deletions):
            session.markRead(slots: slots, deletionIDs: deletions)
            refreshUnread()
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
            if !appliedOnce {
                // Window request to the page's first apply: Readout's own share
                // of an open, without the frame the system paints it in.
                appliedOnce = true
                SmokeTest.noteFirstApply(url, seconds: Date().timeIntervalSince(openedAt))
                SmokeTest.noteLaunchPhase("apply")
            }
        case .painted:
            SmokeTest.notePainted()
            if !painted {
                // First patch presented on screen: the open is done.
                painted = true
                ReaderPerf.signposter.endInterval("open", openSignpost)
                SmokeTest.noteFirstPaint(url, seconds: Date().timeIntervalSince(openedAt))
                SmokeTest.noteLaunchPhase("paint")
                WebViewPool.shared.pagePainted()
            }
        case .open(let href):
            openLink(href)
        case .loadRemote(let remote, let id):
            loadRemote(remote, id: id)
        case .openPath(let path, let line, let column):
            EditorOpener.open(path: path, line: line, column: column)
        case .setCodeWrap(let on):
            if AppSettings.shared.codeWrap != on { AppSettings.shared.codeWrap = on }
        case .nothing, .wrapped:
            // A key with nothing to go to (D with nothing in view), or N
            // wrapping past the last change back to the first.
            NSSound.beep()
        case .noUnread:
            // N with no unread change left here: on to the next document with some.
            if (NSApp.delegate as? AppDelegate)?.goToNextUnread(from: self) != true { NSSound.beep() }
        case .showUnread:
            if unreadHold != nil { unreadShown() }
        case .selection(let has, let focused):
            hasSelection = has
            hasFocusedBlock = focused
        case .landed(let index, let total, let kind):
            // VoiceOver hears which change it is, as the rail's ticks say it.
            let kindText = ReaderStrings.all[kind] ?? kind
            announce(String(format: NSLocalizedString("Unread change %d of %d: %@", comment: "Change-rail tick label; %d is position, %d is total, %@ is the kind"),
                            index, total, kindText))
            SmokeTest.noteLanded(index: index, total: total, kind: kind)
        case .ready, .error:
            break   // handled by ReaderWebView
        }
    }

    private func loadRemote(_ remote: String, id: String) {
        RemoteImageLoader.shared.load(remote) { [weak self] result in
            switch result {
            case .success(let local):
                self?.webView.call("remoteReady", ["id": id, "url": local])
            case .failure(.rejected(let reason)):
                self?.webView.call("remoteFailed", ["id": id, "error": reason])
            }
        }
    }

    private func openLink(_ href: String) {
        let fm = FileManager.default
        // A link to a source file is looked for where a path in a code span
        // is (the project, the repository's folders, the agent folders) before it is missing.
        let resolver = FileResolver(baseDirectory: url.deletingLastPathComponent(), project: projectRoot.path,
                                    workspaces: AppSettings.shared.workspaces)
        guard let target = LinkTarget.resolve(href, from: url, markdownExtensions: WorkspaceIndex.markdownExtensions,
                                              fileExists: { fm.fileExists(atPath: $0.path) },
                                              isDirectory: { u in
                                                  var dir: ObjCBool = false
                                                  return fm.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
                                              },
                                              candidates: resolver.candidates(for:)) else { return }
        switch target {
        case .external(let u), .file(let u):
            // No app for it (a file name with a line that is not there, "main.swift:42"): say so.
            if !NSWorkspace.shared.open(u) { NSSound.beep() }
        case .source(let u, let line, let column): EditorOpener.open(path: u.path, line: line, column: column)
        case .sameDocument(let fragment): scrollToAnchor(fragment: fragment)
        case .markdown(let u, let fragment): (NSApp.delegate as? AppDelegate)?.open(u, anchor: fragment, from: self)
        case .missing(let u):
            NSSound.beep()
            flashStatus(String(format: NSLocalizedString("%@ could not be found.", comment: "Subtitle for a few seconds after a link to a missing file; %@ is the file name"), u.lastPathComponent))
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
        refreshRepository()
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
        refreshUnread()
        webView.call("markAllRead")
        scheduleSave()
        // ⌘Z brings the marks back.
        undoStack.registerUndo(withTarget: self) { $0.restoreUnread(baseline: before) }
        undoStack.setActionName(NSLocalizedString("Mark All as Read", comment: "Menu"))
    }

    /// Undo of Mark All as Read: the document marked against the baseline from
    /// before, as reopening the window would show it, at the same place.
    private func restoreUnread(baseline: [BlockKey]) {
        // Empty for a moment: reloading now would mark the empty version
        // against the old baseline and drop the session's memory of what came
        // before it. Keep the action for when the content is back.
        guard !session.blocks.isEmpty else {
            NSSound.beep()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.undoStack.registerUndo(withTarget: self) { $0.restoreUnread(baseline: baseline) }
                self.undoStack.setActionName(NSLocalizedString("Mark All as Read", comment: "Menu"))
            }
            return
        }
        reloadMarked(against: baseline)
        // Redo marks everything read again.
        undoStack.registerUndo(withTarget: self) { $0.markAllRead(nil) }
        undoStack.setActionName(NSLocalizedString("Mark All as Read", comment: "Menu"))
    }

    /// The document shown again marked against `baseline`, at the same place.
    @discardableResult
    private func reloadMarked(against baseline: [BlockKey], then: ((RenderPatch) -> Void)? = nil) -> RenderPatch {
        let place = lastAnchor.flatMap { a in session.blocks.firstIndex { $0.slot == a.slot }.map { (index: $0, offset: a.offset) } }
        let patch = session.reload(baseline: baseline)
        model.activeSlot = 0   // the slots are new
        updateModel(patch, decoded: nil)
        let restore = place.flatMap { p in p.index < session.blocks.count ? (slot: session.blocks[p.index].slot, offset: p.offset) : nil }
        if let restore { lastAnchor = restore }
        webView.whenReady { [weak self] in
            guard let self else { return }
            self.webView.callEncodingOffMain("apply", patch.page)
            if let restore { self.restorePlace(restore) }
            then?(patch)
        }
        scheduleSave()
        return patch
    }

    // MARK: Compare with Last Commit

    /// Goes up with every read that lands in the session (the first load,
    /// each write, a retargeted symlink's file): a comparison is for the
    /// version it was asked for.
    private var contentGeneration = 0

    /// View ▸ Compare with Last Commit: the document marked again against
    /// its committed version (`git show HEAD:`), what the agent changed since
    /// unread; ⌘Z brings back what was read before, as for Mark All as Read.
    @objc func compareWithLastCommit(_ sender: Any?) { compareWithLastCommit(rerun: false) }

    /// `rerun`: a read landed while the first comparison ran; this one is
    /// against the version shown now, and is dropped if another lands.
    private func compareWithLastCommit(rerun: Bool) {
        // Nothing loaded yet: nothing to compare. A loaded document with no
        // blocks (empty, or only whitespace) is compared: what was committed shows as removed.
        guard loaded, !retargetGate.isPending else { return NSSound.beep() }
        let askedAt = contentGeneration
        // What the window shows, not the file on disk (a newer write may have reached it first).
        let displayed = session.blocks.map(BlockKey.init)
        CommitBaseline.compare(path: contentPath ?? url.path, displayed: displayed) { [weak self] result in
            guard let self else { return }
            switch CommitComparison.applies(askedAt: askedAt, current: self.contentGeneration, retargeting: self.retargetGate.isPending, rerun: rerun) {
            case .apply: break
            case .rerun: return self.compareWithLastCommit(rerun: true)
            case .drop: return NSSound.beep()
            }
            switch result {
            case .baseline(let keys):
                self.showMarked(against: keys, againstCommit: true)
            case .unchanged:
                NSSound.beep()
                self.flashStatus(NSLocalizedString("No changes since the last commit", comment: "Subtitle for a few seconds after Compare with Last Commit: the file is as committed"))
            case .unavailable:
                NSSound.beep()
                self.flashStatus(NSLocalizedString("Not in the last commit", comment: "Subtitle for a few seconds after Compare with Last Commit: git has no committed version of the file (untracked, new, not text, or git not available)"))
            }
        }
    }

    /// Marked against `baseline`, undoably: the commit's (`againstCommit`,
    /// with the notice that says so) or the reading state from before it.
    private func showMarked(against baseline: [BlockKey], againstCommit: Bool) {
        let name = NSLocalizedString("Compare with Last Commit", comment: "Menu: mark the document again against its version in the last git commit")
        // Undoing it while the document is empty for a moment (an agent
        // truncating it) waits for the content; comparing an empty document does not.
        guard !session.blocks.isEmpty || againstCommit else {
            // Empty for a moment (an agent truncating it): kept for when it is back, as restoreUnread does.
            NSSound.beep()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.undoStack.registerUndo(withTarget: self) { $0.showMarked(against: baseline, againstCommit: againstCommit) }
                self.undoStack.setActionName(name)
            }
            return
        }
        let before = session.baseline
        reloadMarked(against: baseline) { [weak self] patch in
            guard let self else { return }
            guard againstCommit else {
                // Undone: the commit's notice goes with its marks (any other notice stays).
                for n in [CommitNotice.marked, .rewritten] { self.webView.call("hideNotice", Self.text(n)) }
                return
            }
            let notice = CommitNotice.after(rewrite: patch.rewrite, unread: self.session.unreadCount)
            if let notice { self.webView.call("notice", Self.text(notice)) }
            SmokeTest.noteCompared(notice.map { Self.text($0) } ?? "")
        }
        undoStack.registerUndo(withTarget: self) { $0.showMarked(against: before, againstCommit: !againstCommit) }
        undoStack.setActionName(name)
    }

    /// The notice above a document marked against its last commit.
    static func text(_ notice: CommitNotice) -> String {
        switch notice {
        case .marked:
            return NSLocalizedString("Marked against the last commit", comment: "Notice above a document opened for the first time: its changes since the last git commit are marked")
        case .rewritten:
            return NSLocalizedString("Rewritten since the last commit", comment: "Notice above a document marked against its last git commit when most of it changed since (nothing is marked)")
        }
    }

    /// The file lies in a git repository (View ▸ Compare with Last Commit is
    /// enabled), as GitBaseline finds one (a `.git` above it; git is not run).
    /// Looked up again when the window becomes key, a read lands or the file
    /// changes (a retarget), so a `git init` since is seen; menu validation
    /// only reads it.
    private var inRepository = false
    private func refreshRepository() {
        let path = contentPath ?? url.path
        inRepository = !path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/")
            && GitBaseline.repository(containing: path, exists: { FileManager.default.fileExists(atPath: $0) }) != nil
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        loaded && session.blocks.isEmpty ? idleUndo : undoStack
    }

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

    /// ⌘E: the editor at the source line of the selection's block, or else
    /// at the line as far into the block at the top of the view as the view is.
    @objc func openInEditor(_ sender: Any?) {
        webView.run(Self.editorSlotScript) { [weak self] value, _ in
            guard let self else { return }
            let place = value as? [String: Any]
            let slot = (place?["slot"] as? NSNumber)?.intValue ?? self.lastAnchor?.slot ?? 0
            let ratio = (place?["ratio"] as? NSNumber)?.doubleValue
            let line = self.session.blocks.first { $0.slot == slot }.map { ReaderChrome.editorLine(lines: $0.lines, ratio: ratio) } ?? 0
            EditorOpener.open(path: self.url.path, line: line, column: 0)
        }
    }

    /// The block the selection starts in (its first line: ratio 0), else the
    /// block at the top of the view and how far it is scrolled under the toolbar.
    private static let editorSlotScript = """
        (() => {
          const s = getSelection();
          const n = s && !s.isCollapsed ? s.anchorNode : null;
          const e = n && (n.nodeType === 1 ? n : n.parentElement);
          const b = e && e.closest('.blk[data-slot]');
          if (b) return { slot: +b.dataset.slot, ratio: 0 };
          const a = window.readout && window.readout.captureAnchor();
          return a ? { slot: a.slot, ratio: a.ratio } : null;
        })()
        """

    /// Edit ▸ Find ▸ Use Selection for Find: the selection becomes what ⌘G finds.
    @objc func useSelectionForFind(_ sender: Any?) {
        webView.run("getSelection().toString()") { [weak self] value, _ in
            let text = ((value as? String) ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard let self, !text.isEmpty else { return NSSound.beep() }
            self.searchItem?.searchField.stringValue = text
            let find = NSPasteboard(name: .find)
            find.clearContents()
            find.setString(text, forType: .string)
        }
    }

    /// View ▸ Show What Changed: what the page's D key does (the comparisons of the edited blocks in view).
    @objc func showWhatChanged(_ sender: Any?) { webView.call("toggleDiffInView") }

    @objc func copyFilePath(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc func printDocument(_ sender: Any?) {
        // Before the first document is applied the page is empty (and its
        // apply not queued yet, so nothing would wait for it): print once
        // didLoad has queued it. Asked twice meanwhile, printed once.
        guard loaded else {
            printWhenLoaded = true
            return
        }
        // Diagrams and code are drawn lazily near the viewport: the page draws
        // the rest first (it gives up after a few seconds), then prints.
        // In order with the calls before it (a document still being encoded,
        // a cold window's page not up yet): never ahead of them.
        webView.whenReady { [weak self] in
            self?.webView.runAsync("return await window.readout.preparePrint()") { [weak self] _ in
                guard let self else { return }
                // CI: what would print is recorded instead of a print sheet.
                if SmokeTest.capturePrint(self.webView) { return }
                self.runPrint()
            }
        }
    }

    /// The first document has been applied (CI).
    var isLoaded: Bool { loaded }

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
        case #selector(nextChange(_:)), #selector(previousChange(_:)):
            // With none left here, N goes on to another document that has some.
            return session.unreadCount > 0 || (NSApp.delegate as? AppDelegate)?.anyUnread == true
        case #selector(markAllRead(_:)):
            return session.unreadCount > 0
        case #selector(copyAsQuote(_:)):
            // Text selected, or else a block with the keyboard's focus (where N went).
            return (hasSelection || hasFocusedBlock) && loaded
        case #selector(compareWithLastCommit(_:)):
            // A file in a git repository (git itself is asked when chosen).
            return loaded && inRepository
        case #selector(showWhatChanged(_:)):
            // As the page's D key: with nothing to compare, the page beeps.
            return loaded
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
        returnToOpener()
        saveFrame()
        releaseHold()
        saveWork?.cancel()
        saveNow()
        watcher?.stop()
        watcher = nil
        cancellables.removeAll()
        tabBarObservations = []
        windowObservations = []
        layoutObservation = nil
        // Nothing to undo in a closed window; the actions hold the controller.
        undoStack.removeAllActions()
        flashWork?.cancel()
        AppSettings.shared.showSidebar = !sidebarItem.isCollapsed
        onClose?(self)
    }

    /// Whether Open Recent lists the document yet: only once its window has
    /// been in front, not for every file an agent opened in the background.
    private(set) var notedRecent = false

    /// Looked at before the quit (ReaderRestorationState.seen), so already in
    /// Open Recent: only unread changes give the restored tab its dot.
    func noteLookedAt() {
        guard !notedRecent else { return }
        notedRecent = true
        refreshUnread()
        window?.invalidateRestorableState()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if !notedRecent {
            // Not the help files inside the app.
            if !url.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path + "/") {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
            noteLookedAt()   // looked at: the tab's dot stays only for unread changes
        }
        updateSubtitle()
        if loaded { refreshRepository() }
        if window?.firstResponder === window { window?.makeFirstResponder(webView) }
        sendWindowKey()
        // A key window in a tab group is its selected tab.
        if (window?.tabGroup?.windows.count ?? 0) > 1 { selectedTabChanged() }
    }

    func windowDidResignKey(_ notification: Notification) { sendWindowKey() }

    /// The page reads changes while the window is key, focus in the outline
    /// or the find field included (document.hasFocus() alone says no then).
    private func sendWindowKey() {
        let key = window?.isKeyWindow ?? false
        webView.whenReady { [weak self] in self?.webView.call("setWindowKey", json: key ? "true" : "false") }
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    static let frameName = "ReaderWindow"

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: Self.frameName)
    }

    // MARK: Restoration

    /// What the window keeps for the next launch (see ReaderRestoration).
    var restorationState: ReaderRestorationState {
        let group = window?.tabGroup
        let tabs = group?.windows ?? []
        let index = window.flatMap { w in tabs.firstIndex { $0 === w } } ?? 0
        return ReaderRestorationState(path: url.path, projectRoot: projectRoot.path,
                                      group: tabs.count > 1 ? group.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 36) } : nil,
                                      tabIndex: index, selected: group?.selectedWindow === window || tabs.count <= 1, seen: notedRecent)
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        ReaderRestoration.encode(restorationState, into: state)
    }

    // MARK: Copy as Quote

    /// The page has a text selection in the document (it says when that changes).
    private var hasSelection = false
    /// A block has the keyboard's focus (where N went): with no text
    /// selected, Edit ▸ Copy as Quote quotes it. Not the context menu: a
    /// right click elsewhere does not move the focus.
    private var hasFocusedBlock = false

    /// Edit ▸ Copy as Quote (⇧⌘C): the Markdown source of the blocks the
    /// selection touches, as a blockquote, and the file's lines and section.
    @objc func copyAsQuote(_ sender: Any?) {
        webView.run("window.readout.selectedSlots()") { [weak self] value, _ in
            guard let self else { return }
            let slots = Set(((value as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue })
            let path = QuoteFormatter.displayPath(self.url.path, projectRoot: self.projectRoot.path)
            guard let text = QuoteFormatter.quote(blocks: self.session.blocks, slots: slots, path: path) else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// The page's context menu: Copy as Quote after Copy, when text is selected.
    private func addQuoteItem(to menu: NSMenu) {
        guard hasSelection, let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) else { return }
        let item = NSMenuItem(title: NSLocalizedString("Copy as Quote", comment: "Menu: copy the selected blocks' Markdown as a quote with the file's lines"),
                              action: #selector(copyAsQuote(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: copy + 1)
    }

    // MARK: Across documents

    /// The reader whose link opened this document as its next tab: closing
    /// this one goes back to it.
    weak var opener: ReaderWindowController?

    /// Closing the tab a link opened, while it is the one in front: the tab
    /// the link was in comes forward again, whichever AppKit would select.
    private func returnToOpener() {
        guard let opener, let back = opener.window, let window, let group = window.tabGroup,
              group.selectedWindow === window, group.windows.contains(where: { $0 === back }) else { return }
        // Once this tab is gone, unless the opener closed meanwhile (Close All).
        DispatchQueue.main.async { [weak opener] in
            guard let opener, (NSApp.delegate as? AppDelegate)?.owns(opener) == true, let back = opener.window else { return }
            back.tabGroup?.selectedWindow = back
            back.makeKeyAndOrderFront(nil)
        }
    }

    /// N arrived here from a document with nothing unread left: to the first
    /// change, with where it is in the subtitle for a moment. Opened behind
    /// and not looked at yet, nothing is marked: it is read from where it shows.
    func goToFirstChange() {
        if CrossDocument.arrival(unread: session.unreadCount) == .firstChange {
            webView.whenReady { [weak self] in self?.webView.call("firstChange") }
        }
        flashStatus(String(format: NSLocalizedString("Next unread: %@", comment: "Subtitle for a few seconds after N went on to this document; %@ is its title"),
                           window?.tab.title.isEmpty == false ? window!.tab.title : url.lastPathComponent))
    }
}

/// The dot on a window's tab while its document has unread changes, in the
/// accent colour, as the outline's. Shown only where the tab bar is.
final class UnreadDotView: NSView {
    private static let diameter: CGFloat = 6

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(NSLocalizedString("Unread changes", comment: "Accessibility label of the change rail beside the page"))
        // A new accent colour chosen in System Settings.
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSColor.systemColorsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 12) }

    @objc private func redraw() { needsDisplay = true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = Self.diameter
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
    }
}

/// The first open of a file in a git repository: the committed version, as a
/// reading baseline, so what changed since the last commit is marked.
/// git runs off the main thread, at most `GitBaseline.timeout`, and only when
/// the developer tools are installed (`/usr/bin/git` would otherwise ask to
/// install them); files outside a repository never run it.
@MainActor
enum CommitBaseline {
    private static let queue = DispatchQueue(label: "Readout.CommitBaseline", qos: .userInitiated)
    /// Found once per launch (on `queue`). Not found is asked again next
    /// time: a first `xcode-select` or git after boot can outlast the limit.
    nonisolated(unsafe) private static var toolsAvailable = false

    static func find(path: String, current: String, completion: @escaping @MainActor ([BlockKey]?) -> Void) {
        // The app's own files (help) are no one's commit.
        guard !path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/") else { return completion(nil) }
        queue.async {
            var keys: [BlockKey]? = nil
            if GitBaseline.repository(containing: path, exists: { FileManager.default.fileExists(atPath: $0) }) != nil {
                if !toolsAvailable { toolsAvailable = GitTools.available() }
                if toolsAvailable, let text = GitBaseline.headText(for: path, current: current, git: ProcessGit()) {
                    // On a large stack, as the document itself (`ParseThread`).
                    keys = ParseThread.sync { MarkdownParser.parse(text).blocks.map(BlockKey.init) }
                }
            }
            let found = keys
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(found) } }
        }
    }

    /// View ▸ Compare with Last Commit: the version the window `displayed`
    /// against the committed version of the file at `path` (its real path),
    /// with the guards of `find`. Only git's HEAD blob is read.
    static func compare(path: String, displayed: [BlockKey], completion: @escaping @MainActor (CommitComparison) -> Void) {
        guard !path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/") else { return completion(.unavailable) }
        queue.async {
            var result = CommitComparison.unavailable
            if GitBaseline.repository(containing: path, exists: { FileManager.default.fileExists(atPath: $0) }) != nil {
                if !toolsAvailable { toolsAvailable = GitTools.available() }
                if toolsAvailable { result = GitBaseline.compare(path: path, displayed: displayed, git: ProcessGit()) }
            }
            let found = result
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(found) } }
        }
    }
}
