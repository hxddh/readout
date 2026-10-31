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
        var assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case assets
        }

        struct Asset: Decodable {
            var name: String
            var url: URL

            enum CodingKeys: String, CodingKey {
                case name
                case url = "browser_download_url"
            }
        }
    }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Called on the main thread when a background check finds an update,
    /// with its name. The host installs this to add an application-menu item
    /// (which calls `showFoundUpdate`); default nil.
    static var onBackgroundUpdate: ((String) -> Void)?

    /// The update a background check found, until its menu item is chosen.
    private static var found: Release?

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
            let found = release
            DispatchQueue.main.async {
                guard let release = found else {
                    // A failed check does not count as a check: otherwise one
                    // offline launch silences updates for another week.
                    if interactive {
                        let body = rateLimited
                            ? NSLocalizedString("GitHub's limit on update checks from this network was reached. Please try again in an hour.", comment: "Update alert body: GitHub rate limit")
                            : NSLocalizedString("Readout could not reach GitHub. Please try again later.", comment: "Update alert body")
                        alert(title: NSLocalizedString("Could Not Check for Updates", comment: "Update alert title"), body: body, download: nil)
                    }
                    return
                }
                AppSettings.shared.lastUpdateCheck = Date()
                if ReleaseCheck.isNewer(release.tag, than: currentVersion) {
                    if interactive {
                        offer(release)
                    } else {
                        found = release
                        onBackgroundUpdate?(release.name ?? release.tag)
                    }
                } else if interactive {
                    alert(title: NSLocalizedString("You're Up to Date", comment: "Update alert title"),
                          body: String(format: NSLocalizedString("Readout %@ is the latest version.", comment: "Update alert body"), currentVersion),
                          download: nil)
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

    /// The application menu's "Readout X Is Available…": the same alert, and
    /// the same Download Update, as Check for Updates finding it.
    static func showFoundUpdate() {
        guard let found else { return }
        offer(found)
    }

    /// A New Version Is Available: the release's notes, Download Update or
    /// Later. Download Update hands the release's disk image to the browser,
    /// which downloads it (with its progress, cancel and quarantine); the
    /// release page when it has none. Nothing is installed.
    private static func offer(_ release: Release) {
        alert(title: NSLocalizedString("A New Version Is Available", comment: "Update alert title"),
              body: "\(release.name ?? release.tag)\n\n\(ReleaseCheck.plainNotes(release.body ?? ""))",
              download: ReleaseCheck.downloadURL(assets: (release.assets ?? []).map { (name: $0.name, url: $0.url) }, page: release.htmlURL, releases: releasesURL))
    }

    /// `title` is localized by the caller (literal keys, so the strings can be found).
    private static func alert(title: String, body: String, download: URL?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        if download != nil {
            alert.addButton(withTitle: NSLocalizedString("Download Update", comment: "Button"))
            alert.addButton(withTitle: NSLocalizedString("Later", comment: "Button"))
        }
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, let download { NSWorkspace.shared.open(download) }
    }
}
