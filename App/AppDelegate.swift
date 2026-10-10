import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windows: [String: ReaderWindowController] = [:]
    private var welcome: NSWindow?
    private var settingsWindow: NSWindow?
    private var hotKey: GlobalHotKey?
    private var cancellables: Set<AnyCancellable> = []
    private var openedAtLaunch = false

    static let markdownTypes: [UTType] = {
        var types: [UTType] = [UTType("net.daringfireball.markdown")].compactMap { $0 }
        for ext in ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        types.append(.plainText)
        return types
    }()

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appDelegate: self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WebViewPool.shared.prewarm()
        BaselineStore.prune()
        UpdateChecker.scheduleAutomaticCheck()

        let settings = AppSettings.shared
        settings.$hotKey.sink { [weak self] choice in
            self?.hotKey?.unregister()
            self?.hotKey = GlobalHotKey.make(choice) { [weak self] in self?.openLatest(nil) }
        }.store(in: &cancellables)
        settings.$workspaces.sink { paths in WorkspaceIndex.shared.configure(paths) }.store(in: &cancellables)

        if let smoke = ProcessInfo.processInfo.environment["READOUT_SMOKE_FILE"] {
            openedAtLaunch = true
            open(URL(fileURLWithPath: smoke))
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
        for url in urls { open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for w in windows.values { w.saveNow() }
    }

    // MARK: Opening

    func open(_ url: URL, anchor: String? = nil) {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              WorkspaceIndex.markdownExtensions.contains(url.pathExtension.lowercased()) else {
            NSSound.beep()
            return
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if let existing = windows[url.path] {
            existing.show()
            NSApp.activate()
            if let anchor { existing.scrollToAnchor(fragment: anchor) }
            return
        }
        let controller = ReaderWindowController(url: url, pendingAnchor: anchor)
        controller.onClose = { [weak self] c in self?.windows[c.url.path] = nil }
        if let front = NSApp.orderedWindows.first(where: { w in windows.values.contains { $0.window === w } }),
           let w = controller.window {
            w.setFrameTopLeftPoint(NSPoint(x: front.frame.minX + 26, y: front.frame.maxY - 26))
        } else if windows.isEmpty {
            controller.window?.center()
        }
        windows[url.path] = controller
        controller.show()
        welcome?.close()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.forEach { open($0) } }
    }

    @objc func openLatest(_ sender: Any?) {
        if let url = WorkspaceIndex.shared.latest {
            open(url)
            NSApp.activate()
        } else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("No recent Markdown files", comment: "Alert title")
            alert.informativeText = NSLocalizedString("Add the folders your agents write to in Settings. Readout then opens the newest Markdown file with this command.", comment: "Alert body")
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
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 460, height: 400))
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

    // MARK: Command line tool

    @objc func installCommandLineTool(_ sender: Any?) {
        guard let script = Bundle.main.url(forResource: "readout", withExtension: nil) else { return }
        let target = "/usr/local/bin/readout"
        let shell = "mkdir -p /usr/local/bin && ln -sf '\(script.path)' '\(target)'"
        let source = "do shell script \"\(shell.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        let alert = NSAlert()
        if error == nil {
            alert.messageText = NSLocalizedString("Command line tool installed", comment: "Alert title")
            alert.informativeText = NSLocalizedString("Use “readout FILE” to open a file, or “readout -b FILE” to open it without switching apps.", comment: "Alert body")
        } else {
            alert.messageText = NSLocalizedString("The command line tool was not installed", comment: "Alert title")
            alert.informativeText = (error?[NSAppleScript.errorMessage] as? String) ?? ""
        }
        alert.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openLatest(_:)) { return true }
        return true
    }
}

// MARK: - Welcome

struct WelcomeView: View {
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
                        Text(NSLocalizedString("Open Latest", comment: "Button"))
                        if settings.hotKey != .none {
                            Text(settings.hotKey.title).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .controlSize(.large)
            .padding(.top, 20)
            Spacer(minLength: 24)
        }
        .frame(width: 460, height: 400)
    }
}
