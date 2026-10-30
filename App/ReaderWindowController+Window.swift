import AppKit
import WebKit
import ReadoutCore

/// The window and its tabs: the subtitle, tab titles and tooltips, the tab
/// group followed, the window's delegate, restoration, and going back to the opener.
extension ReaderWindowController {
    /// The subtitle shows the file's status when there is one (deleted, could
    /// not be read, decoded as…), else task progress, else, for a window
    /// without a tab bar, the file's folder (with one, the tab's tooltip has
    /// the path).
    func updateSubtitle(status: String?? = nil) {
        let status = status ?? model.status
        observeTabBar()
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

    func updateTabToolTip() {
        var tip = ReaderChrome.tabToolTip(path: url.path)
        if projectName != nil, let root = projectRoot.path {
            tip += "\n" + String(format: NSLocalizedString("Project: %@", comment: "Tab tooltip line: the project folder a plan outside it was written for"),
                                 ReaderChrome.tabToolTip(path: root))
        }
        if window?.tab.toolTip != tip { window?.tab.toolTip = tip }
    }

    /// The window joined or left tabs, or its tab bar was shown or hidden:
    /// the subtitle and the tab titles follow.
    func tabsChanged() {
        updateSubtitle()
        updateTabTitles()
        // Which tabs it is among comes back on the next launch.
        window?.invalidateRestorableState()
    }

    /// The titles of every tab in the window's group: a title two documents
    /// share is followed by the file name (or folder) that tells them apart.
    func updateTabTitles() {
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

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        loadState == .loaded && session.blocks.isEmpty ? idleUndo : undoStack
    }

    // MARK: Window

    func show() {
        showWindow(nil)
        window?.makeFirstResponder(webView)
    }

    /// On screen: the first time, a phase of the cold start (SmokeTest).
    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window?.occlusionState.contains(.visible) == true { SmokeTest.noteLaunchPhase("window_visible") }
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
        onClose?(self)
    }

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
            if !url.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path + "/"), !SmokeTest.isBootPass {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
            noteLookedAt()   // looked at: the tab's dot stays only for unread changes
        }
        updateSubtitle()
        if loadState == .loaded { refreshRepository() }
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

    func windowDidResize(_ notification: Notification) { fitSidebar() }

    // MARK: Outline

    /// Whether this window has room for the outline beside the page (its
    /// content width, the outline's width, the reader's text size).
    private func sidebarFits() -> Bool {
        guard let window else { return false }
        let width = window.contentRect(forFrameRect: window.frame).width
        return ReaderLayout.sidebarFits(windowWidth: Double(width), sidebarWidth: Double(sidebarWidth),
                                        fontSize: AppSettings.shared.fontSize, shown: !sidebarItem.isCollapsed)
    }

    /// Shows or hides the outline as the window's width (and the reader's
    /// choice in it) calls for, without animating: the page lays out once
    /// at its new width and keeps the reader's place (reader.js: resize).
    func fitSidebar() {
        guard sidebarItem != nil else { return }
        if !sidebarItem.isCollapsed {
            let w = sidebarItem.viewController.view.frame.width
            if w > 0 { sidebarWidth = w }
        }
        let show = sidebarFit.shown(fits: sidebarFits())
        if show == !sidebarItem.isCollapsed { return }
        sidebarItem.isCollapsed = !show
    }

    /// Show/Hide Sidebar (the toolbar button, View ▸ Show Sidebar, ⌃⌘S): the
    /// reader's choice for this window when it goes against its width.
    func sidebarToggled(show: Bool) {
        sidebarFit.toggled(to: show, fits: sidebarFits())
    }

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

    // MARK: Across documents

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
    /// change, saying where it is in the notice. Opened behind
    /// and not looked at yet, nothing is marked: it is read from where it shows.
    func goToFirstChange() {
        if CrossDocument.arrival(unread: session.unreadCount) == .firstChange {
            webView.whenReady { [weak self] in self?.webView.call("firstChange") }
        }
        showNotice(String(format: NSLocalizedString("Next unread: %@", comment: "Notice above the document after N went on to this document; %@ is its title"),
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

/// The reader window's split view: tells the window when the reader shows or
/// hides the outline (the toolbar button and View ▸ Show Sidebar both send
/// toggleSidebar: here), so the choice holds against the window's width.
final class ReaderSplitController: NSSplitViewController {
    /// Called before the toggle, with whether it shows the outline. Also
    /// when the reader drags the divider so the outline collapses or comes
    /// back: that is their choice for this window too, as the toggle is.
    var willToggleSidebar: ((Bool) -> Void)?
    private var wasCollapsed: Bool?

    private var sidebar: NSSplitViewItem? { splitViewItems.first { $0.behavior == .sidebar } }

    override func toggleSidebar(_ sender: Any?) {
        if let item = sidebar { willToggleSidebar?(item.isCollapsed) }
        super.toggleSidebar(sender)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(subviewsResized),
                                               name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }

    /// A collapse (or uncollapse) while the mouse button is down is the
    /// divider dragged; the window's own fit and the toggle happen with it up.
    @objc private func subviewsResized(_ note: Notification) {
        guard let item = sidebar else { return }
        defer { wasCollapsed = item.isCollapsed }
        guard let was = wasCollapsed, was != item.isCollapsed, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        willToggleSidebar?(was)
    }
}
