import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import ReadoutCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [String: ReaderWindowController] = [:]
    /// Windows whose symlink was retargeted to a file another window already
    /// shows: no longer found by path, still owned here until they close.
    private var displaced: [ReaderWindowController] = []
    private var welcome: NSWindow?
    private var settingsWindow: NSWindow?
    private var hotKey: GlobalHotKey?
    private var cancellables: Set<AnyCancellable> = []
    private var openedAtLaunch = false
    /// Markdown written in the agent folders opens on its own, in the background.
    private var autoOpen = AutoOpen()
    private var autoOpenWork: DispatchWorkItem?

    static let markdownTypes: [UTType] = {
        var types: [UTType] = [UTType("net.daringfireball.markdown")].compactMap { $0 }
        for ext in ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        // Not .plainText: open(_:) takes Markdown extensions only, so a .txt picked here would just beep.
        return types
    }()

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WebViewPool.shared.prewarm()
        BaselineStore.prune()
        UpdateChecker.onBackgroundUpdate = { [weak self] name, url in self?.showUpdateMenuItem(name: name, url: url) }
        UpdateChecker.startAutomaticChecks()

        let settings = AppSettings.shared
        settings.$hotKey.sink { [weak self] choice in
            self?.hotKey?.unregister()
            self?.hotKey = GlobalHotKey.make(choice) { [weak self] in self?.openLatest(nil) }
            // Registration fails when another app holds the combination: say so where it is chosen.
            let inUse = choice != .none && self?.hotKey == nil
            if settings.hotKeyInUse != inUse { settings.hotKeyInUse = inUse }
        }.store(in: &cancellables)
        // Turning automatic checks on takes effect now, not at the next launch.
        settings.$checkForUpdatesAutomatically.dropFirst().removeDuplicates().sink { on in
            if on { DispatchQueue.main.async { UpdateChecker.checkIfDue() } }
        }.store(in: &cancellables)
        settings.$workspaces.sink { paths in WorkspaceIndex.shared.configure(paths) }.store(in: &cancellables)
        WorkspaceIndex.shared.onWrite = { [weak self] urls in self?.noteAgentWrites(urls) }

        if let smoke = ProcessInfo.processInfo.environment["READOUT_SMOKE_FILE"] {
            openedAtLaunch = true
            open(URL(fileURLWithPath: smoke))
            SmokeTest.didOpen()
        }

        // Files passed on launch arrive through application(_:open:) right after this; show the welcome
        // window only if none did.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.openedAtLaunch, self.windows.isEmpty else { return }
            self.showWelcome(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedAtLaunch = true
        for url in urls {
            if url.isFileURL {
                open(url)
            } else if let request = OpenLink.parse(url) {
                // `readout -b` and `readout --hook`: open behind the document being
                // read. `readout plan.md#risks`: open at the section. The hook's
                // project folder: where the paths in the document are found.
                open(URL(fileURLWithPath: request.path), anchor: request.anchor, mode: request.background ? .background : .request,
                     projectRoot: ProjectRoot.validated(request.root))
                if request.background { SmokeTest.noteBackgroundRequest(request.path) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// An agent folder created since (`~/.claude/plans` before Claude Code's
    /// first plan) is watched from now on.
    func applicationDidBecomeActive(_ notification: Notification) { WorkspaceIndex.shared.refresh() }

    /// A click on the Dock icon with no window showing: the last minimized
    /// window comes back; the welcome window only when there is none.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let minimized = NSApp.orderedWindows.first(where: { $0.isMiniaturized })
            ?? NSApp.windows.first(where: { $0.isMiniaturized }) {
            minimized.deminiaturize(nil)
        } else {
            showWelcome(nil)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for w in windows.values { w.saveNow() }
        for w in displaced { w.saveNow() }
        // The saves are queued: write them before the process exits (⌘Q right after reading).
        BaselineStore.flush()
    }

    // MARK: Opening

    /// How an open request treats the reader's focus.
    enum OpenMode {
        /// Asked for by the reader or by Launch Services (Finder, `open`, the
        /// `readout` script): the window comes to the front of Readout's windows.
        /// Readout never activates itself here: Launch Services already did.
        case request
        /// Opened on its own (an agent wrote the file) or asked for in the
        /// background (`readout -b`, `readout --hook`, through `readout-open:`):
        /// an open window is left alone, a new one appears without taking focus
        /// from anything.
        case background
    }

    /// `projectRoot`: the folder an agent worked in when it wrote the file
    /// (an existing absolute folder), kept with the file's reading state.
    func open(_ url: URL, anchor: String? = nil, mode: OpenMode = .request, projectRoot: String? = nil) {
        var url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            NSSound.beep()
            return
        }
        // A folder (`readout DIR`, one dropped on the Dock icon): its newest Markdown file.
        if isDir.boolValue {
            guard let newest = Self.newestMarkdown(in: url) else {
                NSSound.beep()
                return
            }
            url = newest
        }
        guard WorkspaceIndex.markdownExtensions.contains(url.pathExtension.lowercased()) else {
            NSSound.beep()
            return
        }
        // Open Recent and the Dock menu list a document once its window has
        // been in front (ReaderWindowController.windowDidBecomeKey), not every
        // file an agent opened in the background.
        // Keyed by the real path: the same file reached through a symlink, or
        // reported by FSEvents under /private, is the same window.
        let key = WorkspaceIndex.realPath(url.path)
        if let existing = windows[key] {
            // An open window follows the file by itself; bringing it forward is
            // only for a request, and never activates Readout. A window whose
            // first read failed reads again.
            existing.retryLoadIfFailed()
            if let projectRoot { existing.setProjectRoot(projectRoot) }
            if mode == .request { existing.show() }
            if let anchor { existing.scrollToAnchor(fragment: anchor) }
            return
        }
        let controller = ReaderWindowController(url: url, pendingAnchor: anchor, projectRoot: projectRoot)
        controller.onClose = { [weak self] c in
            guard let self else { return }
            self.windows = self.windows.filter { $0.value !== c }   // by identity: a retarget may have re-keyed it
            self.displaced.removeAll { $0 === c }
        }
        controller.onRetarget = { [weak self] c in self?.rekey(c) }
        if let front = NSApp.orderedWindows.first(where: { w in windows.values.contains { $0.window === w } }),
           let w = controller.window {
            w.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 26, y: front.frame.maxY - 26))
        } else if windows.isEmpty {
            controller.window?.center()
        }
        let readers = NSApp.orderedWindows.filter { w in windows.values.contains { $0.window === w } }
        windows[key] = controller
        if mode == .background, let w = controller.window {
            if let current = readers.first {
                // Reader windows join tabs: add it as a tab behind the one being read.
                let reading = current.tabGroup?.selectedWindow ?? current
                current.addTabbedWindow(w, ordered: .above)
                current.tabGroup?.selectedWindow = reading
                // With a tab bar now, the folder leaves the subtitles (the tabs' tooltips have it).
                for window in current.tabGroup?.windows ?? [w] { (window.windowController as? ReaderWindowController)?.tabsChanged() }
            } else if NSApp.isActive, let keyWindow = NSApp.keyWindow {
                // The reader is in another Readout window (welcome, settings): wait behind it.
                w.order(.below, relativeTo: keyWindow.windowNumber)
            } else {
                controller.show()   // Readout is in the background: this does not activate it
            }
        } else {
            controller.show()
        }
        // A background open leaves the window the reader is in alone, the welcome window included.
        if mode == .request || !(NSApp.isActive && welcome?.isKeyWindow == true) { welcome?.close() }
    }

    /// A symlink a window shows now points to another file: key the window by
    /// that file, so opening the link again finds it and opening the old target
    /// does not. When another window already shows the new file, that one keeps
    /// the key, and this one stays open in `displaced` until it closes.
    /// The most recently modified Markdown file directly in `folder`.
    static func newestMarkdown(in folder: URL) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items.filter { WorkspaceIndex.markdownExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { u -> (URL, Date)? in
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
                return (u, v.contentModificationDate ?? .distantPast)
            }
            .max { $0.1 < $1.1 }?.0
    }

    private func rekey(_ controller: ReaderWindowController) {
        let key = WorkspaceIndex.realPath(controller.url.path)
        guard windows[key] !== controller else { return }
        windows = windows.filter { $0.value !== controller }
        displaced.removeAll { $0 === controller }
        if windows[key] == nil { windows[key] = controller } else { displaced.append(controller) }
    }

    /// Whether Readout still owns the window (saved on quit, released on close).
    func owns(_ controller: ReaderWindowController) -> Bool {
        windows.values.contains { $0 === controller } || displaced.contains { $0 === controller }
    }

    /// The window showing `url`, however it is spelled.
    func reader(for url: URL) -> ReaderWindowController? { windows[WorkspaceIndex.realPath(url.standardizedFileURL.path)] }

    /// Whether a window shows `path`, however it is spelled.
    private func isShown(_ path: String) -> Bool { windows[WorkspaceIndex.realPath(path)] != nil }

    private func noteAgentWrites(_ writes: [(url: URL, isNew: Bool)]) {
        let now = Date()
        for w in writes { autoOpen.noteWrite(w.url.standardizedFileURL.path, at: now, isNew: w.isNew) }
        guard autoOpen.hasPending else { return }
        autoOpenWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.openSettledWrites() }
        autoOpenWork = work
        let delay = max(0, autoOpen.settleDate(now: now).timeIntervalSince(now))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func openSettledWrites() {
        let paths = autoOpen.settle(isOpen: { [unowned self] in isShown($0) },
                                    exists: { FileManager.default.fileExists(atPath: $0) })
        for path in paths { open(URL(fileURLWithPath: path), mode: .background) }
        if !paths.isEmpty { SmokeTest.noteAutoOpened(paths) }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.forEach { open($0) } }
    }

    @objc func openLatest(_ sender: Any?) {
        // The global shortcut works with Readout in the background: pick up a folder created since.
        let index = WorkspaceIndex.shared
        index.refresh()
        // A folder that just appeared (or was added) is still being scanned:
        // decide once it has been, so its newest file is the one opened and an
        // empty list is never taken for "nothing written". At once otherwise.
        index.whenScanned { [weak self] in self?.openLatestScanned() }
    }

    private func openLatestScanned() {
        if let url = WorkspaceIndex.shared.latest {
            open(url)
            NSApp.activate()
        } else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("No recent Markdown files", comment: "Alert title")
            alert.informativeText = NSLocalizedString("Add the folders your agents write to in Settings. Readout then opens the most recently written Markdown file with this command.", comment: "Alert body")
            alert.addButton(withTitle: NSLocalizedString("Open Settings", comment: "Button"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Button"))
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { showSettings(nil) }
        }
    }

    // MARK: Windows

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil {
            let view = WelcomeView(
                onOpen: { [weak self] in self?.openDocument(nil) },
                onOpenLatest: { [weak self] in self?.openLatest(nil) },
                onOpenURL: { [weak self] url in self?.open(url) }
            )
            let host = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            // Named for VoiceOver and Mission Control; Window ▸ Welcome is its menu item.
            w.title = NSLocalizedString("Welcome", comment: "Window title")
            w.titleVisibility = .hidden
            w.isExcludedFromWindowsMenu = true
            // A fixed panel: never a tab, nothing to minimize or zoom.
            w.tabbingMode = .disallowed
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 460, height: WelcomeView.height))
            w.center()
            welcome = w
        }
        welcome?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let w = NSWindow(contentViewController: host)
            w.title = NSLocalizedString("Settings", comment: "Window title")
            w.styleMask = [.titled, .closable]
            // Never a tab of a reader window ("Prefer tabs: Always").
            w.tabbingMode = .disallowed
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: View settings

    @objc func biggerText(_ sender: Any?) { AppSettings.shared.fontSize = min(24, AppSettings.shared.fontSize + 1) }
    @objc func smallerText(_ sender: Any?) { AppSettings.shared.fontSize = max(12, AppSettings.shared.fontSize - 1) }
    @objc func actualSizeText(_ sender: Any?) { AppSettings.shared.fontSize = 16 }

    @objc func checkForUpdates(_ sender: Any?) { UpdateChecker.check(interactive: true) }

    /// Background check found an update: surface it as an application-menu
    /// item that opens the release page. Never pops up, never activates —
    /// the reader keeps reading undisturbed.
    private var pendingUpdateURL: URL?
    private func showUpdateMenuItem(name: String, url: URL) {
        pendingUpdateURL = url
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu,
              appMenu.item(withTag: 901) == nil else { return }
        let title = String(format: NSLocalizedString("%@ Is Available…", comment: "Menu: background update found; %@ is like 'Readout 3.0.2'"), name)
        let item = NSMenuItem(title: title, action: #selector(openPendingUpdate(_:)), keyEquivalent: "")
        item.tag = 901
        // Insert right after "Check for Updates…" (index 1), before the separator.
        appMenu.insertItem(item, at: min(2, appMenu.numberOfItems))
    }

    @objc private func openPendingUpdate(_ sender: Any?) {
        if let url = pendingUpdateURL { NSWorkspace.shared.open(url) }
    }

    /// File ▸ Close All (⌥⌘W, the alternate of Close).
    @objc func closeAll(_ sender: Any?) {
        for w in NSApp.windows where (w.isVisible || w.isMiniaturized) && w.styleMask.contains(.closable) { w.performClose(sender) }
    }

    /// Help ▸ Readout Help: the keyboard shortcuts bundled with the app, in
    /// Readout itself, in the reader's language.
    @objc func openHelp(_ sender: Any?) {
        let name = ReaderChrome.helpFileName(preferredLanguages: Bundle.main.preferredLocalizations)
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Help/\(name)") else { return NSSound.beep() }
        open(url)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    /// Fixed size: open, open latest and drop a file. Recent files live in File ▸ Open Recent.
    static let height: CGFloat = 430

    let onOpen: () -> Void
    let onOpenLatest: () -> Void
    let onOpenURL: (URL) -> Void
    @State private var targeted = false
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Readout")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 10)
            Text(NSLocalizedString("Read what your agents write.", comment: "Welcome subtitle"))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            // Plans are mentioned only while their folder is in Settings.
            Text(AgentFolders.includesClaudePlans(settings.workspaces)
                 ? NSLocalizedString("New plans in ~/.claude/plans open in Readout on their own. Add other agent folders in Settings.", comment: "Welcome: how documents arrive")
                 : NSLocalizedString("New Markdown files in the agent folders you add in Settings open in Readout on their own.", comment: "Welcome: how documents arrive, ~/.claude/plans not in Settings"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
                .padding(.top, 8)

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.06) : .clear))
                .overlay(
                    Text(NSLocalizedString("Drop a Markdown file here", comment: "Welcome drop target"))
                        .foregroundStyle(.secondary)
                )
                .frame(height: 96)
                .padding(.horizontal, 32)
                .padding(.top, 22)
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                    for p in providers {
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            let ext = url.pathExtension.lowercased()
                            guard WorkspaceIndex.markdownExtensions.contains(ext) else {
                                NSSound.beep()
                                return
                            }
                            DispatchQueue.main.async { onOpenURL(url) }
                        }
                    }
                    return true
                }

            HStack(spacing: 10) {
                Button(NSLocalizedString("Open…", comment: "Button"), action: onOpen)
                    .keyboardShortcut("o", modifiers: .command)
                Button(action: onOpenLatest) {
                    HStack(spacing: 6) {
                        Text(NSLocalizedString("Open Latest Agent File", comment: "Menu"))
                        if settings.hotKey != .none && !settings.hotKeyInUse {
                            Text(settings.hotKey.title).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .controlSize(.large)
            .padding(.top, 20)

            Spacer(minLength: 24)
        }
        .frame(width: 460, height: Self.height)
    }

}
