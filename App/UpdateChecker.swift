import AppKit
import CoreServices
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

        /// The release's disk image, when it has one on GitHub.
        var dmg: Asset? {
            assets?.first { $0.name.lowercased().hasSuffix(".dmg") && $0.url.scheme == "https" && $0.url.host == "github.com" }
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
            DispatchQueue.main.async {
                guard let release else {
                    // A failed check does not count as a check: otherwise one
                    // offline launch silences updates for another week.
                    if interactive {
                        let body = rateLimited
                            ? NSLocalizedString("GitHub's limit on update checks from this network was reached. Please try again in an hour.", comment: "Update alert body: GitHub rate limit")
                            : NSLocalizedString("Readout could not reach GitHub. Please try again later.", comment: "Update alert body")
                        alert(title: NSLocalizedString("Could Not Check for Updates", comment: "Update alert title"), body: body, update: nil)
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
                          update: nil)
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
    /// the same download, as Check for Updates finding it.
    static func showFoundUpdate() {
        guard let found else { return }
        offer(found)
    }

    /// A New Version Is Available: the release's notes, Download Update or Later.
    private static func offer(_ release: Release) {
        alert(title: NSLocalizedString("A New Version Is Available", comment: "Update alert title"),
              body: "\(release.name ?? release.tag)\n\n\(ReleaseCheck.plainNotes(release.body ?? ""))",
              update: (page: release.htmlURL ?? releasesURL, dmg: release.dmg))
    }

    /// `title` is localized by the caller (literal keys, so the strings can be found).
    private static func alert(title: String, body: String, update: (page: URL, dmg: Release.Asset?)?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        if let update {
            alert.addButton(withTitle: NSLocalizedString("Download Update", comment: "Button"))
            alert.addButton(withTitle: NSLocalizedString("Later", comment: "Button"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let dmg = update.dmg { download(from: dmg.url, name: dmg.name, fallback: update.page) } else { NSWorkspace.shared.open(update.page) }
        } else {
            NSApp.activate()
            alert.runModal()
        }
    }

    /// The download running, if any: Download Update chosen again meanwhile
    /// (the alert again, or the menu item) does not start a second one.
    private static var running: URLSessionDownloadTask?
    /// Its progress, published on the file in Downloads: Finder and the
    /// Dock's Downloads stack show it, and can cancel it.
    private static var progress: Progress?
    private static var progressObservation: NSKeyValueObservation?

    /// What the last download did, for the smoke test.
    private(set) static var lastDownload: [String: Any] = [:]

    /// Download Update: the release's disk image into Downloads, its progress
    /// shown on the file there, then shown in Finder, quarantined as a browser
    /// download is (Gatekeeper checks it as usual). Nothing is installed. If it
    /// cannot be downloaded, the release page opens instead (`fallback`).
    /// False when a download is already running: this one is ignored.
    /// `directory` (Downloads when nil) and `completion`, which replaces the
    /// reveal and the fallback, are for the smoke test.
    @discardableResult
    static func download(from source: URL, name: String, fallback: URL?, directory: URL? = nil,
                         completion: ((URL?) -> Void)? = nil) -> Bool {
        guard running == nil else { return false }
        var request = URLRequest(url: source, timeoutInterval: 300)
        request.setValue("Readout/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let name = (name as NSString).lastPathComponent
        // The file it becomes, there from the start, so the progress has a file to show on.
        let target = try? reserveDownload(name: name, in: directory)
        let task = URLSession.shared.downloadTask(with: request) { temp, response, error in
            // The temporary file is removed once this returns: move it now.
            // A file: URL (the smoke test) answers without HTTP.
            var saved: URL?
            let ok = (response as? HTTPURLResponse)?.statusCode == 200 || (response != nil && source.isFileURL)
            if let temp, ok { saved = try? keepDownload(temp, at: target, name: name, in: directory, from: source) }
            if saved == nil, let target { try? FileManager.default.removeItem(at: target) }
            // Cancelled from its progress (Finder, the Dock): nothing else happens.
            let cancelled = (error as? URLError)?.code == .cancelled
            DispatchQueue.main.async {
                finishProgress(saved: saved)
                running = nil
                if let completion { return completion(saved) }
                if let saved { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                else if let fallback, !cancelled { NSWorkspace.shared.open(fallback) }
            }
        }
        running = task
        lastDownload = ["name": name, "progress_file": target?.lastPathComponent ?? NSNull()]
        if let target { publishProgress(for: task, on: target) }
        task.resume()
        return true
    }

    /// A progress on the file in Downloads that follows the task's bytes;
    /// cancelling it there (Finder, the Dock) cancels the download.
    private static func publishProgress(for task: URLSessionDownloadTask, on file: URL) {
        let p = Progress(totalUnitCount: -1)
        p.kind = .file
        p.fileOperationKind = .downloading
        p.fileURL = file
        p.isCancellable = true
        p.isPausable = false
        p.cancellationHandler = { [weak task] in task?.cancel() }
        p.publish()
        progress = p
        progressObservation = task.progress.observe(\.completedUnitCount, options: [.initial, .new]) { taskProgress, _ in
            let total = taskProgress.totalUnitCount, done = taskProgress.completedUnitCount
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let p = progress else { return }
                    if total > 0 { p.totalUnitCount = total }
                    p.completedUnitCount = done
                    lastDownload["progress_updates"] = ((lastDownload["progress_updates"] as? Int) ?? 0) + 1
                }
            }
        }
    }

    private static func finishProgress(saved: URL?) {
        progressObservation?.invalidate()
        progressObservation = nil
        if let p = progress {
            if saved != nil {
                if p.totalUnitCount <= 0 { p.totalUnitCount = 1 }
                p.completedUnitCount = p.totalUnitCount
            }
            lastDownload["progress_published"] = true
            lastDownload["progress_total"] = p.totalUnitCount
            lastDownload["progress_completed"] = p.completedUnitCount
            p.unpublish()
        }
        progress = nil
        lastDownload["saved"] = saved?.lastPathComponent ?? NSNull()
    }

    /// An empty file in ~/Downloads under `name` ("Readout-3.7.0 2.dmg" when
    /// that is taken): where the download goes, with its progress on it meanwhile.
    nonisolated private static func reserveDownload(name: String, in directory: URL?) throws -> URL {
        let fm = FileManager.default
        let downloads = try directory ?? fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = downloads.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = downloads.appendingPathComponent("\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        return target
    }

    /// Moves a finished download onto the file reserved for it (into
    /// Downloads under `name` when there is none) and marks it as downloaded from `source`.
    nonisolated private static func keepDownload(_ temp: URL, at reserved: URL?, name: String, in directory: URL?, from source: URL) throws -> URL {
        let fm = FileManager.default
        let target = try reserved ?? reserveDownload(name: name, in: directory)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: temp, to: target)
        let quarantine: [String: Any] = [kLSQuarantineAgentNameKey as String: "Readout",
                                         kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
                                         kLSQuarantineDataURLKey as String: source]
        try? (target as NSURL).setResourceValue(quarantine, forKey: .quarantinePropertiesKey)
        return target
    }
}
