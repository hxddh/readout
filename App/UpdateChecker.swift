import AppKit
import ReadoutCore

/// Lightweight update checker backed by GitHub Releases.
///
/// Replaces the Sparkle dependency: Sparkle's embedded XPC services must be
/// signed with the same Developer ID as the host app, which ad-hoc and
/// mismatched distribution builds cannot satisfy — the app then dies at
/// launch inside dyld while loading the framework. Checking the public
/// releases API needs no bundled executable code and no signing relationship.
@MainActor
enum UpdateChecker {
    private static let latestURL = URL(string: "https://api.github.com/repos/hxddh/readout/releases/latest")!
    private static let releasesURL = URL(string: "https://github.com/hxddh/readout/releases")!

    private struct Release: Decodable {
        var tag: String
        var name: String?
        var body: String?
        var htmlURL: URL?

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
        }
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Compares dotted version strings numerically ("1.0.0" < "1.0.10").
    static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.split(separator: "-").first ?? $0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Whether a check result may show a modal alert — UpdatePolicy.shouldAlert.
    /// Only interactive (user-invoked) checks pop up; background checks surface
    /// through the application menu instead, never stealing focus.
    static func shouldAlert(interactive: Bool, hasUpdate: Bool) -> Bool {
        UpdatePolicy.shouldAlert(interactive: interactive, hasUpdate: hasUpdate)
    }

    /// Strips Markdown formatting for alert text — UpdatePolicy.plainNotes.
    static func plainNotes(_ markdown: String, limit: Int = 600) -> String {
        UpdatePolicy.plainNotes(markdown, limit: limit)
    }

    /// Called on the main thread when a background check finds an update.
    /// The host installs this to add an application-menu item; default nil.
    static var onBackgroundUpdate: ((String, URL) -> Void)?

    /// Runs one check. When `interactive` is false, stays silent unless an update is found.
    static func check(interactive: Bool) {
        var request = URLRequest(url: latestURL, timeoutInterval: 20)
        request.setValue("Readout/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            var release: Release?
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                release = try? JSONDecoder().decode(Release.self, from: data)
            }
            DispatchQueue.main.async {
                guard let release else {
                    // A failed background check must not push the weekly timer
                    // forward: otherwise one offline launch silences updates
                    // for another week. Only interactive runs record it.
                    if interactive {
                        AppSettings.shared.lastUpdateCheck = Date()
                        alert(titleKey: "Could Not Check for Updates",
                              body: NSLocalizedString("Readout could not reach GitHub. Please try again later.", comment: "Update alert body"),
                              updateURL: nil)
                    }
                    return
                }
                AppSettings.shared.lastUpdateCheck = Date()
                if isNewer(release.tag, than: currentVersion) {
                    let updateURL = release.htmlURL ?? releasesURL
                    if interactive {
                        alert(titleKey: "A New Version Is Available",
                              body: "\(release.name ?? release.tag)\n\n\(plainNotes(release.body ?? ""))",
                              updateURL: updateURL)
                    } else {
                        onBackgroundUpdate?(release.name ?? release.tag, updateURL)
                    }
                } else if interactive {
                    alert(titleKey: "You're Up to Date",
                          body: String(format: NSLocalizedString("Readout %@ is the latest version.", comment: "Update alert body"), currentVersion),
                          updateURL: nil)
                }
            }
        }.resume()
    }

    /// Schedules the weekly background check. Called once at launch.
    static func scheduleAutomaticCheck() {
        guard AppSettings.shared.checkForUpdatesAutomatically else { return }
        let last = AppSettings.shared.lastUpdateCheck ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 86400 else { return }
        // Delay so the check never slows down launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard AppSettings.shared.checkForUpdatesAutomatically else { return }
            check(interactive: false)
        }
    }

    private static func alert(titleKey: String, body: String, updateURL: URL?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(titleKey, comment: "Update alert title")
        alert.informativeText = body
        if let updateURL {
            alert.addButton(withTitle: NSLocalizedString("View Full Release Notes", comment: "Button"))
            alert.addButton(withTitle: NSLocalizedString("Later", comment: "Button"))
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(updateURL) }
        } else {
            NSApp.activate()
            alert.runModal()
        }
    }
}
