import AppKit
import SwiftUI
import WebKit
import Combine
import ReadoutCore
import os

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

    let session = DocumentSession()
    let loader: DocumentLoader
    let webView: ReaderWebView
    var watcher: FileWatcher?
    private let splitController = ReaderSplitController()
    var sidebarItem: NSSplitViewItem!
    /// The outline shows by itself in a window wide enough for it and the
    /// page's column with comfortable margins (ReaderLayout), unless the
    /// reader chose otherwise in this window.
    var sidebarFit = SidebarFit()
    /// The outline's width when shown (as the reader left it; the split view keeps it).
    var sidebarWidth: CGFloat = 220
    var searchItem: NSSearchToolbarItem?
    var changeItem: NSToolbarItem?
    var cancellables: Set<AnyCancellable> = []
    /// The window's undo manager (Mark All as Read; NSWindow handles undo:
    /// with it). A few levels: each one keeps a whole baseline.
    let undoStack: UndoManager = {
        let u = UndoManager()
        u.levelsOfUndo = 5
        return u
    }()
    /// Given to the window while the document is momentarily empty (an agent
    /// truncating before it writes): Undo is disabled then, the actions wait.
    let idleUndo = UndoManager()
    /// The tab group whose tab bar the subtitle follows.
    weak var observedTabGroup: NSWindowTabGroup?
    var tabBarObservations: [NSKeyValueObservation] = []
    var windowObservations: [NSKeyValueObservation] = []

    // File state (content tracking lives in `loader`)
    var loaded = false
    /// ⌘P before the first document was applied (`didLoad`): printed then.
    var printWhenLoaded = false
    /// A search made before the first document was applied: run after it.
    var findWhenLoaded: (() -> Void)?
    /// The first read failed: the next change on disk, or opening the file
    /// again, reads it again instead of waiting for a load that never comes.
    var loadFailed = false
    /// A change that arrived while the first load was still parsing. Applied
    /// right after the initial patch so early agent writes are never lost.
    var editedWhileLoading = false
    var deleted = false
    var lastAnchor: (slot: Int, offset: Double)?
    var saveWork: DispatchWorkItem?
    /// Fragment from a cross-file link (other.md#section), scrolled to after load.
    var pendingAnchor: String?
    /// The project folder the document's paths are relative to (an agent's
    /// working folder, from `readout --hook`), read by the loader's resolver.
    final class ProjectRootBox { var path: String? }
    let projectRoot: ProjectRootBox
    /// A project folder arrived: the next read renders the same bytes again.
    var rereadForRoot = false

    /// When the window was asked for, for the open-to-first-paint measurement.
    let openedAt = Date()
    var painted = false
    var appliedOnce = false
    let openSignpost: OSSignpostIntervalState

    var showsLoadFailure = false

    /// Where the reader was when the file went empty (an agent truncating it
    /// before writing it again), until it has content again, and whether they
    /// were following the end then.
    var anchorBeforeEmpty: (slot: Int, offset: Double)?
    var followingBeforeEmpty = false

    /// The document's title, as its tab shows it unless another tab in the
    /// group has the same one.
    var documentTitle: String = ""

    /// More unread waiting for the page's `showUnread`, with its fallback.
    var unreadHold: DispatchWorkItem?

    var lastSavedBaseline: [BlockKey]?
    var lastSavedAnchorExcerpt: String?
    var lastSavedAnchorIndex: Int?
    var lastSavedAnchorOffset: Double?
    var didSaveOnce = false

    /// The opened symlink points to another file, whose state has its own key.
    /// Until that file's content is read, the session still holds the old
    /// one: saves wait until a read of that file (not one of the old target
    /// still in flight) lands, then the next save writes the whole record there.
    var retargetGate = RetargetGate()

    /// The real path of the file whose content the session holds: the key the
    /// reading state is saved under. Not resolved at save time, which could
    /// already see a retarget the window has not read yet.
    var contentPath: String?

    /// Goes up with every read that lands in the session (the first load,
    /// each write, a retargeted symlink's file): a comparison is for the
    /// version it was asked for.
    var contentGeneration = 0

    /// The file lies in a git repository (View ▸ Compare with Last Commit is
    /// enabled), as GitBaseline finds one (a `.git` above it; git is not run).
    /// Looked up again when the window becomes key, a read lands or the file
    /// changes (a retarget), so a `git init` since is seen; menu validation
    /// only reads it.
    var inRepository = false

    /// Bumped by every search, clear and close: a search queued for a page
    /// not up yet runs only if nothing came after it.
    var findGeneration = 0
    /// A search is on (Return or ⌘G since the field was last edited, cleared or closed): the page's counts are shown.
    var finding = false

    /// Whether Open Recent lists the document yet: only once its window has
    /// been in front, not for every file an agent opened in the background.
    var notedRecent = false

    /// The page has a text selection in the document (it says when that changes).
    var hasSelection = false
    /// A block has the keyboard's focus (where N went): with no text
    /// selected, Edit ▸ Copy as Quote quotes it. Not the context menu: a
    /// right click elsewhere does not move the focus.
    var hasFocusedBlock = false

    /// The heading the context menu is opening on (the page says, just before).
    var contextHeading: String?

    /// The reader whose link opened this document as its next tab: closing
    /// this one goes back to it.
    weak var opener: ReaderWindowController?

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
        // Before the window shows: the page lays out once, at its width.
        fitSidebar()

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
        sidebarItem.isCollapsed = true   // fitSidebar, once the window has its frame

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
        splitController.willToggleSidebar = { [weak self] show in self?.sidebarToggled(show: show) }
        splitController.splitView.autosaveName = "ReaderSplit"
        window?.contentViewController = splitController
        window?.setContentSize(NSSize(width: 1060, height: 820))
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
        webView.onContextMenu = { [weak self] menu in
            self?.addQuoteItem(to: menu)
            self?.addSectionLinkItem(to: menu)
        }
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

    var layoutObservation: NSKeyValueObservation?

    /// The inset given to the web view and the toolbar's edge it should match (smoke test).
    var topInsetState: [String: Double] {
        guard let window else { return [:] }
        let web = webView.convert(webView.bounds, to: nil)
        return ["obscured_top": Double(webView.obscuredContentInsets.top),
                "layout_gap": max(0, Double(web.maxY - window.contentLayoutRect.maxY)).rounded()]
    }

    func sendKnownImages() {
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

    func applyAppearance() {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let settings = AppSettings.shared
        // The area under the toolbar shows the web view's under-page colour; keep it in step with the page.
        webView.underPageBackgroundColor = dark ? NSColor(srgbRed: 0x1e / 255, green: 0x1e / 255, blue: 0x1f / 255, alpha: 1) : .white
        webView.whenReady { [weak self] in
            self?.webView.setAppearance(dark: dark, accent: .controlAccentColor, fontSize: settings.fontSize,
                                        strings: ReaderStrings.all, codeWrap: settings.codeWrap)
        }
        lastTopInset = -1
        DispatchQueue.main.async { [weak self] in self?.updateTopInset() }
    }

    private func observeSettings() {
        let s = AppSettings.shared
        s.$fontSize.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance(); self?.fitSidebar() } }.store(in: &cancellables)
        // A wrap toggled in one window applies to every open window.
        s.$codeWrap.dropFirst().removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }.store(in: &cancellables)
        model.$unread.sink { [weak self] n in self?.updateChangeItem(n) }.store(in: &cancellables)
        // The status (deleted, could not be read, decoded as…) is shown in the title bar, sidebar or not.
        model.$status.removeDuplicates().sink { [weak self] status in self?.updateSubtitle(status: status) }.store(in: &cancellables)
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
        default:
            return true
        }
    }
}
