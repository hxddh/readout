import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(settings.workspaces, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: (path as NSString).expandingTildeInPath))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(abbreviate(path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(path)
                    }
                }
                .frame(minHeight: 96)
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
                    Button {
                        if let s = selection { settings.workspaces.removeAll { $0 == s } }
                        selection = nil
                    } label: {
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
                Text(NSLocalizedString("New Markdown documents your agents create here open in Readout on their own, in the background. The global shortcut opens the most recently written one.", comment: "Settings footer"))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(NSLocalizedString("Global shortcut", comment: "Settings label"), selection: $settings.hotKey) {
                    ForEach(AppSettings.HotKeyChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker(NSLocalizedString("Editor for ⌘E and code references", comment: "Settings label: the app Open in Editor (⌘E) and path:line links open files in"), selection: $settings.editor) {
                    ForEach(AppSettings.Editor.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                if settings.hotKeyInUse {
                    Text(NSLocalizedString("This shortcut is in use by another app. Choose another one.", comment: "Settings note: the global shortcut could not be registered"))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle(NSLocalizedString("Check for updates automatically", comment: "Settings label"), isOn: $settings.checkForUpdatesAutomatically)
            } footer: {
                Text(NSLocalizedString("Readout checks GitHub releases for new versions.", comment: "Settings footer"))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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
