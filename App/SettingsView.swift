import SwiftUI
import Sparkle

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    let updater: SPUUpdater?
    @State private var autoUpdate = true
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
                        Text("No folders yet")
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack {
                    Button("Add Folder…", action: addFolder)
                    Button("Remove") {
                        if let s = selection { settings.workspaces.removeAll { $0 == s } }
                        selection = nil
                    }
                    .disabled(selection == nil)
                }
            } header: {
                Text("Agent folders")
            } footer: {
                Text("Readout watches these folders for Markdown files. The global shortcut opens the newest one.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Global shortcut", selection: $settings.hotKey) {
                    ForEach(AppSettings.HotKeyChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("Open code references in", selection: $settings.editor) {
                    ForEach(AppSettings.Editor.allCases) { Text($0.title).tag($0) }
                }
            }

            if let updater {
                Section {
                    Toggle("Check for updates automatically", isOn: $autoUpdate)
                        .onChange(of: autoUpdate) { _, v in updater.automaticallyChecksForUpdates = v }
                }
                .onAppear { autoUpdate = updater.automaticallyChecksForUpdates }
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
