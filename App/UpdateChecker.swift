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

    /// Called on the main thread when a background check finds an update.
    /// The host installs this to add an application-menu item; default nil.
    static var onBackgroundUpdate: ((String, URL) -> Void)?

    /// Runs one check. A user-invoked (interactive) check always answers with an
    /// alert; a background check never alerts and reports an update only
    /// through `onBackgroundUpdate` (the application menu).
    static func check(interactive: Bool) {
        var request = URLRequest(url: latestURL, timeoutInterval: 20)
        request.setValue("Readout/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            var release: Release?
            let http = response as? HTTPURLResponse
            if let data, http?.statusCode == 200 {
                release = try? JSONDecoder().decode(Release.self, from: data)
            }
            // GitHub answers 403 (or 429) with no requests left when the hourly limit is used up.
            let rateLimited = (http?.statusCode == 403 || http?.statusCode == 429)
                && http?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"
            DispatchQueue.main.async {
                guard let release else {
                    // A failed check does not count as a check: otherwise one
                    // offline launch silences updates for another week.
                    if interactive {
                        let body = rateLimited
                            ? NSLocalizedString("GitHub's limit on update checks from this network was reached. Please try again in an hour.", comment: "Update alert body: GitHub rate limit")
                            : NSLocalizedString("Readout could not reach GitHub. Please try again later.", comment: "Update alert body")
                        alert(titleKey: "Could Not Check for Updates", body: body, updateURL: nil)
                    }
                    return
                }
                AppSettings.shared.lastUpdateCheck = Date()
                if ReleaseCheck.isNewer(release.tag, than: currentVersion) {
                    let updateURL = release.htmlURL ?? releasesURL
                    if interactive {
                        alert(titleKey: "A New Version Is Available",
                              body: "\(release.name ?? release.tag)\n\n\(ReleaseCheck.plainNotes(release.body ?? ""))",
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

    private static var automaticTimer: Timer?
    private static var checkQueued = false

    /// Starts the weekly background check: at launch, then every few hours
    /// for an app that stays open for weeks. Called once at launch.
    static func startAutomaticChecks() {
        checkIfDue()
        automaticTimer?.invalidate()
        automaticTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { checkIfDue() }
        }
    }

    /// Runs a background check when automatic checks are on and the last one
    /// is more than a week old (also when the setting is turned on).
    static func checkIfDue() {
        guard AppSettings.shared.checkForUpdatesAutomatically, !checkQueued else { return }
        let last = AppSettings.shared.lastUpdateCheck ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 86400 else { return }
        checkQueued = true
        // Delay so the check never slows down launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            checkQueued = false
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
