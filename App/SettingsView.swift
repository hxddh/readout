import SwiftUI
import UniformTypeIdentifiers
import ReadoutCore

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(settings.workspaces, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: Self.icon(path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(abbreviate(path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(path)
                    }
                }
                // As tall as its folders, at least 2 rows, then it scrolls.
                .frame(height: CGFloat(ReaderChrome.folderListRows(settings.workspaces.count)) * Self.rowHeight + 8)
                // ⌫ removes the selected folder, as the − button does.
                .onDeleteCommand(perform: removeSelected)
                .overlay {
                    if settings.workspaces.isEmpty {
                        Text(NSLocalizedString("No folders yet", comment: "Settings empty"))
                            .foregroundStyle(.tertiary)
                    }
                }
                // The usual +/− pair under a list.
                HStack(spacing: 2) {
                    Button(action: addFolder) {
                        Image(systemName: "plus").frame(width: 20, height: 16)
                    }
                    .help(NSLocalizedString("Add Folder…", comment: "Button"))
                    .accessibilityLabel(NSLocalizedString("Add Folder…", comment: "Button"))
                    Button(action: removeSelected) {
                        Image(systemName: "minus").frame(width: 20, height: 16)
                    }
                    .disabled(selection == nil)
                    .help(NSLocalizedString("Remove", comment: "Button"))
                    .accessibilityLabel(NSLocalizedString("Remove", comment: "Button"))
                    Spacer()
                }
                .buttonStyle(.borderless)
            } header: {
                Text(NSLocalizedString("Agent folders", comment: "Settings section"))
            } footer: {
                Text(NSLocalizedString("New Markdown files here open on their own, in the background.", comment: "Settings footer"))
                    .foregroundStyle(.secondary)
            }

            Section {
                // On or off: ⌃⌥⌘R from any app.
                Toggle(String(format: NSLocalizedString("Open latest agent file with %@ from any app", comment: "Settings toggle; %@ is the shortcut, like ⌃⌥⌘R"), settings.hotKey.title),
                       isOn: Binding(get: { settings.hotKey.isGlobal }, set: { settings.hotKey = settings.hotKey.turned(on: $0) }))
                Picker(NSLocalizedString("Editor", comment: "Settings label: the app Open in Editor (⌘E) and path:line links open files in"), selection: $settings.editor) {
                    ForEach(AppSettings.Editor.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                if settings.hotKeyInUse {
                    Text(NSLocalizedString("Another app uses this shortcut.", comment: "Settings note: the global shortcut could not be registered"))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(NSLocalizedString("Check GitHub for updates weekly", comment: "Settings label"), isOn: $settings.checkForUpdatesAutomatically)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let rowHeight: CGFloat = 24

    /// The folder's own icon; a plain folder icon for one that does not exist
    /// yet (~/.claude/plans before the first plan), not a blank document.
    private static func icon(_ path: String) -> NSImage {
        let full = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else {
            return NSWorkspace.shared.icon(for: .folder)
        }
        return NSWorkspace.shared.icon(forFile: full)
    }

    private func removeSelected() {
        if let s = selection { settings.workspaces.removeAll { $0 == s } }
        selection = nil
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = NSLocalizedString("Add", comment: "Open panel button")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.workspaces.contains(url.path) {
            settings.workspaces.append(url.path)
        }
    }
}
