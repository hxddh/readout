import AppKit
import WebKit
import ReadoutCore

/// The document session's wiring: the first load and every change read from
/// disk into the session and on to the page, unread state, the reading state
/// saved, Mark All as Read and its undo, Compare with Last Commit.
extension ReaderWindowController {
    // MARK: Loading

    func load() {
        // The reading state is read and decoded (JSON ~1.6× the document's
        // size) off the main thread, while the document parses.
        let saved = BaselineStore.prefetch(url)
        // The languages its code fences name, as soon as the file is read:
        // the page loads and compiles their grammars while it parses. Only
        // to a page already up (the spare page): one still loading (the
        // first window at launch) takes the document the moment it is ready,
        // with no time to gain and its first paint to make.
        loader.loadInitial(fenceLanguages: { [weak self] langs in
            guard let webView = self?.webView, webView.isReady else { return }
            webView.call("prepare", langs)
        }) { [weak self] result in
            guard let self else { return }
            guard let result else {
                self.loadState = .failed
                if self.whenLoaded.reread {
                    // It changed while the failed read ran: read it again now.
                    self.whenLoaded.reread = false
                    self.retryLoadIfFailed()
                    return
                }
                let gone = !FileManager.default.fileExists(atPath: self.url.path)
                self.deleted = gone
                self.model.status = gone ? NSLocalizedString("The file was deleted.", comment: "Status")
                                         : NSLocalizedString("The file could not be read.", comment: "Status")
                // Nothing to print but the failure: a later read does not print on its own.
                self.whenLoaded.print = false
                self.showLoadFailure()
                return
            }
            // Read and parsed: what follows waits for the reading state, or git (SmokeTest).
            SmokeTest.noteOpenStep(self.url, "parsed", seconds: Date().timeIntervalSince(self.openedAt))
            saved.record(forSourcePath: result.sourcePath) { [weak self] record in   // the file this read came from
                guard let self else { return }
                guard record == nil else { return self.didLoad(result, record: record) }
                // Never opened before: in a git repository, marked against the last commit.
                CommitBaseline.find(path: result.sourcePath, current: result.decoded.text) { [weak self] keys in
                    self?.didLoad(result, record: nil, commitBaseline: keys)
                }
            }
        }
    }

    /// The first read failed: the page says why in its empty state, instead of staying blank.
    private func showLoadFailure() {
        guard let status = model.status else { return }
        showsLoadFailure = true
        webView.whenReady { [weak self] in
            guard let self, self.showsLoadFailure, self.loadState != .loaded else { return }
            self.webView.setAppearance(strings: ["empty": status])
            self.webView.call("apply", json: Self.emptyPatch)
        }
    }
    private static let emptyPatch = #"{"version":0,"reset":true,"rewrite":false,"ops":[],"marks":[],"deletions":[]}"#

    func didLoad(_ result: DocumentLoader.ReadResult, record: BaselineStore.Record?, commitBaseline: [BlockKey]? = nil) {
        SmokeTest.noteLaunchPhase("did_load")
        SmokeTest.noteOpenStep(url, "did_load", seconds: Date().timeIntervalSince(openedAt))
        let patch = self.session.load(result.doc, baseline: record?.baseline ?? commitBaseline)
        contentGeneration += 1
        defer { refreshRepository() }   // once contentPath is set below
        // What is marked is what changed since the last commit, not since the reader last read it.
        let commitNotice = commitBaseline == nil ? nil : CommitNotice.after(rewrite: patch.rewrite, unread: session.unreadCount)
        // What is on disk already: an unchanged baseline is not written again.
        self.lastSavedBaseline = record?.baseline
        self.loadState = .loaded
        self.contentPath = result.sourcePath
        self.deleted = false
        self.updateModel(patch, decoded: result.decoded)
        self.recordVersion()
        self.webView.whenReady { [weak self] in
            guard let self else { return }
            if self.showsLoadFailure {
                // The empty state says "empty" again.
                self.showsLoadFailure = false
                self.webView.setAppearance(strings: ReaderStrings.all)
            }
            // A whole document: encoded off the main thread, still delivered before the calls below.
            SmokeTest.noteOpenStep(self.url, "apply_sent", seconds: Date().timeIntervalSince(self.openedAt))
            self.webView.callEncodingOffMain("apply", patch.page)
            // After the apply: in place of the page's own "Rewritten since you last read".
            if let commitNotice { self.webView.call("notice", Self.text(commitNotice)) }
            SmokeTest.run(controller: self, webView: self.webView)
            // An agent write that landed mid-load: re-read now that the
            // first patch is applied, so the fresh content wins.
            if self.whenLoaded.reread {
                self.whenLoaded.reread = false
                self.fileChanged(.modified)
            }
            if let pending = self.whenLoaded.anchor {
                // Cross-file link target: the fragment wins over the saved position.
                self.whenLoaded.anchor = nil
                self.scrollToAnchor(fragment: pending)
            } else if let slot = self.resumeSlot(from: record, rewritten: patch.rewrite) {
                let anchor = ["slot": slot, "offset": record?.topOffset ?? 0, "ratio": 0] as [String: Any]
                if let data = try? JSONSerialization.data(withJSONObject: anchor), let json = String(data: data, encoding: .utf8) {
                    self.webView.call("scrollToAnchor", json: json)
                }
            }
            // Return in the find field while it loaded: searched now, behind the apply.
            if let find = self.whenLoaded.find {
                self.whenLoaded.find = nil
                find()
            }
            // ⌘P while it loaded: now, queued behind the document's apply.
            if self.whenLoaded.print {
                self.whenLoaded.print = false
                self.printDocument(nil)
            }
        }
    }

    /// Restores the reading position (see ExcerptAnchor.resumeIndex).
    private func resumeSlot(from record: BaselineStore.Record?, rewritten: Bool) -> Int? {
        guard let record else { return nil }
        let i = ExcerptAnchor.resumeIndex(excerpt: record.topExcerpt, index: record.topBlockIndex,
                                          in: session.blocks.map(\.text), rewritten: rewritten)
        return i.map { session.blocks[$0].slot }
    }

    /// An agent named the folder it works in (`readout --hook`): paths in the
    /// document are looked up there too, now and when the file is opened again.
    func setProjectRoot(_ root: String) {
        guard root != projectRoot.path else { return }
        projectRoot.path = root
        BaselineStore.saveProjectRoot(root, for: url)
        updateTabToolTip()
        updateSubtitle()
        window?.invalidateRestorableState()
        rereadForRoot = true
        if loadState == .loaded { fileChanged(.modified) } else { whenLoaded.reread = true }
    }

    /// Reads the file again when its first read failed.
    func retryLoadIfFailed() {
        guard loadState == .failed else { return }
        loadState = .loading
        load()
    }

    func fileChanged(_ change: FileWatcher.Change) {
        if loadState == .failed {
            if change == .deleted {
                deleted = true
                model.status = NSLocalizedString("The file was deleted.", comment: "Status")
                showLoadFailure()
            } else {
                retryLoadIfFailed()
            }
            return
        }
        guard loadState == .loaded else {
            // The first load is still parsing: don't drop the write, replay
            // it right after the initial patch instead.
            whenLoaded.reread = true
            return
        }
        if change == .deleted {
            deleted = true
            model.status = NSLocalizedString("The file was deleted.", comment: "Status")
            return
        }
        if rereadForRoot {
            rereadForRoot = false
            loader.forgetContent()
        }
        loader.readChange { [weak self] change in
            guard let self else { return }
            defer { self.finishRetarget() }   // after the session took the new content
            guard case .content(let result) = change else {
                if self.deleted { self.deleted = false; self.model.status = nil }
                return
            }
            self.deleted = false
            self.contentGeneration += 1
            self.refreshRepository()
            let wasEmpty = self.session.blocks.isEmpty
            guard let patch = self.session.update(result.doc) else {
                self.model.status = nil
                return
            }
            // A whole document again (a reset) is shown at once: the page holds back only what a patch adds.
            self.updateModel(patch, decoded: result.decoded, holdIncrease: !patch.reset)
            self.recordVersionSoon()
            let emptiedNow = !wasEmpty && self.session.blocks.isEmpty
            let restore = self.placeAfterRefill(wasEmpty: wasEmpty, patch: patch)
            self.webView.whenReady { [weak self] in
                guard let self else { return }
                if emptiedNow {
                    // Asked before the empty patch is applied (calls run in
                    // order): whether the reader sat at the end, following.
                    self.webView.run(Self.atBottomScript) { [weak self] value, _ in
                        self?.followingBeforeEmpty = (value as? Bool) ?? false
                    }
                }
                if patch.reset {
                    // A whole document (a rewrite): encoded off the main thread,
                    // still delivered before the calls below.
                    self.webView.callEncodingOffMain("apply", patch.page)
                } else {
                    self.webView.call("apply", patch.page)
                }
                if let restore { self.restorePlace(restore) }
            }
            self.scheduleSave()
        }
    }

    /// The page's own test for "at the end" (anchor.js atBottom).
    private static let atBottomScript = "(() => { const s = document.scrollingElement; return s.scrollHeight - (s.scrollTop + window.innerHeight) < 48 && s.scrollTop > 0; })()"

    /// After a brief truncate-and-refill the page returns to the reader's
    /// place itself (or to the end when following). As a fallback, when the
    /// reader was not following and the anchor block is back, the app sends
    /// that place once the page has applied the refill: a no-op when the page
    /// kept it. Never when following: the page goes to the new end.
    private func placeAfterRefill(wasEmpty: Bool, patch: RenderPatch) -> (slot: Int, offset: Double)? {
        if session.blocks.isEmpty {
            if anchorBeforeEmpty == nil { anchorBeforeEmpty = lastAnchor }
            return nil
        }
        defer { anchorBeforeEmpty = nil; followingBeforeEmpty = false }
        guard wasEmpty, patch.reset, let a = anchorBeforeEmpty, session.blocks.contains(where: { $0.slot == a.slot }) else { return nil }
        lastAnchor = a
        return followingBeforeEmpty ? nil : a
    }

    /// Restores a place after the page's next frame, once its own restore
    /// and the layout the refill caused have run.
    private func restorePlace(_ a: (slot: Int, offset: Double)) {
        let anchor = ["slot": a.slot, "offset": a.offset, "ratio": 0] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: anchor), let json = String(data: data, encoding: .utf8) else { return }
        webView.run("requestAnimationFrame(() => window.readout.scrollToAnchor(\(json))); 1")
    }

    /// `decoded`: how the content was read (sets the status); nil keeps the status.
    private func updateModel(_ patch: RenderPatch, decoded: FileContent.Decoded?, holdIncrease: Bool = false) {
        // Assigned only when changed: each assignment has SwiftUI compare the
        // whole sidebar again, and most patches leave the outline as it was.
        if model.toc != patch.toc { model.toc = patch.toc }
        if model.tasks != patch.tasks { model.tasks = patch.tasks }
        refreshUnread(holdIncrease: holdIncrease)
        model.title = patch.title ?? url.deletingPathExtension().lastPathComponent
        // Tabs of same-named files (every agent's plan.md) show the document's
        // title; the window title stays the file name. Tabs whose documents
        // have the same title too name their files (updateTabTitles).
        let tabTitle = patch.title ?? url.lastPathComponent
        if tabTitle != documentTitle {
            documentTitle = tabTitle
            updateTabTitles()
        }
        if let decoded, let enc = decoded.fallbackEncoding {
            let name = enc == FileContent.replacementEncoding
                ? NSLocalizedString("UTF-8 (with replacement characters)", comment: "Status: bytes that are no known encoding, shown with replacement characters")
                : enc
            model.status = String(format: NSLocalizedString("Decoded as %@", comment: "Status: non-UTF-8 file"), name)
        } else if decoded != nil {
            model.status = nil
        }
        if model.activeSlot == 0 { model.activeSlot = patch.toc.first?.slot ?? 0 }
        updateSubtitle()
    }

    // MARK: Unread

    /// The unread count, the outline entries with an unread change, and the
    /// tab's dot. `holdIncrease`: a patch an agent wrote may have added
    /// unread changes the reader reads as they arrive: more unread waits until
    /// the page says what it added is to be shown (`showUnread`), or a moment
    /// at most; less shows at once (UnreadDisplay).
    func refreshUnread(holdIncrease: Bool = false) {
        // On the tab, in the tab bar only: the document has unread changes,
        // or was opened behind and has not been looked at yet.
        let n = session.unreadCount
        let actual = UnreadDisplay(count: n, sections: session.unreadSections, dot: CrossDocument.needsAttention(unread: n, lookedAt: notedRecent))
        let shown = UnreadDisplay(count: model.unread, sections: model.unreadSections, dot: window?.tab.accessoryView != nil)
        var show = actual
        if holdIncrease || unreadHold != nil {
            let next = UnreadDisplay.next(shown: shown, actual: actual)
            show = next.show
            if next.held { holdUnread() } else { releaseHold() }
        }
        showUnread(show)
    }

    func showUnread(_ d: UnreadDisplay) {
        let had = showsAttention
        if model.unread != d.count { model.unread = d.count }
        if model.unreadSections != d.sections { model.unreadSections = d.sections }
        if let tab = window?.tab, (tab.accessoryView != nil) != d.dot {
            tab.accessoryView = d.dot ? UnreadDotView() : nil
        }
        // The Dock badge counts what the tab's dot says.
        if had != showsAttention { onUnreadShownChanged?() }
    }

    private static let unreadHoldFallback: TimeInterval = 2.5

    private func holdUnread() {
        guard unreadHold == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.unreadShown() }
        unreadHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unreadHoldFallback, execute: work)
    }

    func releaseHold() {
        unreadHold?.cancel()
        unreadHold = nil
    }

    /// The page says what it added is to be shown (or the fallback ran out).
    func unreadShown() {
        releaseHold()
        refreshUnread()
    }

    /// The document has unread changes (the session's, shown or about to be).
    var hasUnread: Bool { session.unreadCount > 0 }

    /// Waiting for the reader, as the tab's dot says: unread changes, or opened
    /// behind and not looked at yet (Open Latest Agent File).
    var needsAttention: Bool { CrossDocument.needsAttention(unread: session.unreadCount, lookedAt: notedRecent) }

    /// Shows the document's unread changes (the toolbar's count).
    var showsUnread: Bool { model.unread > 0 }

    /// Shows that it waits for the reader, as the tab's dot does: unread
    /// changes, or opened behind and not looked at yet (the Dock badge counts these).
    var showsAttention: Bool { model.unread > 0 || window?.tab.accessoryView != nil }

    // MARK: Persistence

    /// Saves the reading position (cheap). Content baselines are saved
    /// separately, only when unread state changes.
    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func retargeted(to target: String) {
        retargetGate.retargeted(to: target)
        onRetarget?(self)
    }

    /// A read filled the session: when it was the retargeted file's, saves resume under its key.
    private func finishRetarget() {
        guard retargetGate.read(from: loader.lastSourcePath) else { return }
        contentPath = loader.lastSourcePath ?? contentPath
        refreshRepository()
        didSaveOnce = false
        lastSavedBaseline = nil
        lastRecordedKeys = nil
        // The versions listed are the new file's, once its first is recorded.
        history = nil
        scheduleSave()
        recordVersionSoon()
    }

    func saveNow() {
        guard loadState == .loaded, !retargetGate.isPending else { return }
        var index: Int? = nil
        var excerpt: String? = nil
        if let a = lastAnchor, let i = session.blocks.firstIndex(where: { $0.slot == a.slot }) {
            index = i
            excerpt = String(session.blocks[i].text.prefix(120))
        }
        let baseline = session.baseline
        let offset = lastAnchor?.offset
        // Anchor-only scrolls must not rewrite the (potentially large)
        // baseline payload: skip the write when nothing changed at all.
        if didSaveOnce, baseline == lastSavedBaseline, excerpt == lastSavedAnchorExcerpt,
           index == lastSavedAnchorIndex, offset == lastSavedAnchorOffset { return }
        let baselineChanged = baseline != lastSavedBaseline
        didSaveOnce = true
        lastSavedBaseline = baseline
        lastSavedAnchorExcerpt = excerpt
        lastSavedAnchorIndex = index
        lastSavedAnchorOffset = offset
        BaselineStore.save(.init(baseline: baseline, topBlockIndex: index, topOffset: offset,
                                 topExcerpt: excerpt, savedAt: Date()),
                           unread: session.unreadCount,
                           for: contentPath.map { URL(fileURLWithPath: $0) } ?? url, baselineChanged: baselineChanged)
    }

    /// A change read into the session goes into the history within a
    /// second: at most once a second while an agent streams a write in
    /// (DocumentHistory keeps the state it settles in), and on a timer of
    /// its own, which saves of the reading position never postpone.
    func recordVersionSoon() {
        guard historyWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.historyWork = nil
            self?.recordVersion()
        }
        historyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The document as it is now, into its history, when it changed since
    /// it was last recorded (on load, and after each change: `recordVersionSoon`).
    func recordVersion() {
        guard loadState == .loaded, !retargetGate.isPending else { return }
        let keys = session.keys
        guard keys != lastRecordedKeys else { return }
        lastRecordedKeys = keys
        let path = contentPath
        BaselineStore.recordVersion(keys, at: Date(), for: path.map { URL(fileURLWithPath: $0) } ?? url) { [weak self] history in
            // Still the same file (not retargeted meanwhile): the timeline lists its versions.
            guard let self, self.contentPath == path else { return }
            self.history = history
        }
    }

    // MARK: Compare with Earlier Version

    /// View ▸ Compare with Earlier Version: the versions to choose from,
    /// newest first, each with when it was seen and how much differs now.
    func earlierVersions() -> [(index: Int, title: String)] {
        guard loadState == .loaded, let history else { return [] }
        let current = session.keys
        let format = DateFormatter()
        format.doesRelativeDateFormatting = true
        format.dateStyle = .medium
        format.timeStyle = .short
        return history.earlier(than: current).map { i in
            let d = DocumentHistory.difference(from: history.keys(of: i), to: current)
            let what = String(format: NSLocalizedString("+%d −%d blocks", comment: "Menu: View ▸ Compare with Earlier Version, after the time: blocks the document has gained and lost since that version"), d.added, d.removed)
            return (i, "\(format.string(from: history.versions[i].at))  \(what)")
        }
    }

    /// The document marked against version `representedObject` of its
    /// history: what changed since then unread; ⌘Z brings back what was read
    /// before, as for Compare with Last Commit.
    @objc func compareWithVersion(_ sender: NSMenuItem) {
        guard loadState == .loaded, !retargetGate.isPending, let i = sender.representedObject as? Int,
              let history, history.versions.indices.contains(i) else { return NSSound.beep() }
        showMarked(againstVersion: history.keys(of: i), at: history.versions[i].at)
    }

    /// View ▸ Open Earlier Version: version `representedObject`, read-only in a
    /// window of its own, marked against the version before it (what changed in it).
    @objc func openVersion(_ sender: NSMenuItem) {
        guard loadState == .loaded, let i = sender.representedObject as? Int,
              let history, history.versions.indices.contains(i) else { return NSSound.beep() }
        let path = contentPath ?? url.path
        let when = DateFormatter.localizedString(from: history.versions[i].at, dateStyle: .medium, timeStyle: .short)
        let title = String(format: NSLocalizedString("%@ — %@", comment: "Title of an earlier version's window: the file's name, then when Readout saw that version"),
                           (path as NSString).lastPathComponent, when)
        let window = VersionWindowController(title: title, markdown: history.markdown(of: i),
                                             before: i > 0 ? history.keys(of: i - 1) : nil,
                                             directory: URL(fileURLWithPath: path).deletingLastPathComponent())
        (NSApp.delegate as? AppDelegate)?.showVersion(window)
    }

    private static let compareWithVersionName = NSLocalizedString("Compare with Earlier Version", comment: "Menu: mark the document again against a version Readout saw before")

    private static func versionNotice(_ at: Date) -> String {
        String(format: NSLocalizedString("Marked what changed since %@", comment: "Notice above the document after View ▸ Compare with Earlier Version: the time of the version chosen"),
               DateFormatter.localizedString(from: at, dateStyle: .medium, timeStyle: .short))
    }

    /// Marked against an earlier version seen `at`, with its notice; undone
    /// (`unmarkVersion`), and redone, as itself.
    private func showMarked(againstVersion keys: [BlockKey], at: Date) {
        let before = session.baseline
        let notice = Self.versionNotice(at)
        reloadMarked(against: keys) { [weak self] _ in self?.showNotice(notice) }
        undoStack.registerUndo(withTarget: self) { $0.unmarkVersion(back: before, keys: keys, at: at) }
        undoStack.setActionName(Self.compareWithVersionName)
    }

    /// Undone: what was read before, without the version's notice.
    private func unmarkVersion(back before: [BlockKey], keys: [BlockKey], at: Date) {
        let notice = Self.versionNotice(at)
        reloadMarked(against: before) { [weak self] _ in self?.webView.call("hideNotice", notice) }
        undoStack.registerUndo(withTarget: self) { $0.showMarked(againstVersion: keys, at: at) }
        undoStack.setActionName(Self.compareWithVersionName)
    }

    // MARK: Mark All as Read

    @objc func markAllRead(_ sender: Any?) {
        guard session.unreadCount > 0 else { return }
        let before = session.baseline
        session.markAllRead()
        refreshUnread()
        webView.call("markAllRead")
        scheduleSave()
        // ⌘Z brings the marks back.
        undoStack.registerUndo(withTarget: self) { $0.restoreUnread(baseline: before) }
        undoStack.setActionName(NSLocalizedString("Mark All as Read", comment: "Menu"))
    }

    /// Undo of Mark All as Read: the document marked against the baseline from
    /// before, as reopening the window would show it, at the same place.
    private func restoreUnread(baseline: [BlockKey]) {
        // Empty for a moment: reloading now would mark the empty version
        // against the old baseline and drop the session's memory of what came
        // before it. Keep the action for when the content is back.
        guard !session.blocks.isEmpty else {
            NSSound.beep()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.undoStack.registerUndo(withTarget: self) { $0.restoreUnread(baseline: baseline) }
                self.undoStack.setActionName(NSLocalizedString("Mark All as Read", comment: "Menu"))
            }
            return
        }
        reloadMarked(against: baseline)
        // Redo marks everything read again.
        undoStack.registerUndo(withTarget: self) { $0.markAllRead(nil) }
        undoStack.setActionName(NSLocalizedString("Mark All as Read", comment: "Menu"))
    }

    /// The document shown again marked against `baseline`, at the same place.
    @discardableResult
    private func reloadMarked(against baseline: [BlockKey], then: ((RenderPatch) -> Void)? = nil) -> RenderPatch {
        let place = lastAnchor.flatMap { a in session.blocks.firstIndex { $0.slot == a.slot }.map { (index: $0, offset: a.offset) } }
        let patch = session.reload(baseline: baseline)
        model.activeSlot = 0   // the slots are new
        updateModel(patch, decoded: nil)
        let restore = place.flatMap { p in p.index < session.blocks.count ? (slot: session.blocks[p.index].slot, offset: p.offset) : nil }
        if let restore { lastAnchor = restore }
        webView.whenReady { [weak self] in
            guard let self else { return }
            self.webView.callEncodingOffMain("apply", patch.page)
            if let restore { self.restorePlace(restore) }
            then?(patch)
        }
        scheduleSave()
        return patch
    }

    // MARK: Compare with Last Commit

    /// View ▸ Compare with Last Commit: the document marked again against
    /// its committed version (`git show HEAD:`), what the agent changed since
    /// unread; ⌘Z brings back what was read before, as for Mark All as Read.
    @objc func compareWithLastCommit(_ sender: Any?) { compareWithLastCommit(rerun: false) }

    /// `rerun`: a read landed while the first comparison ran; this one is
    /// against the version shown now, and is dropped if another lands.
    func compareWithLastCommit(rerun: Bool) {
        // Nothing loaded yet: nothing to compare. A loaded document with no
        // blocks (empty, or only whitespace) is compared: what was committed shows as removed.
        guard loadState == .loaded, !retargetGate.isPending else { return NSSound.beep() }
        let askedAt = contentGeneration
        // What the window shows, not the file on disk (a newer write may have reached it first).
        let displayed = session.blocks.map(BlockKey.init)
        CommitBaseline.compare(path: contentPath ?? url.path, displayed: displayed) { [weak self] result in
            guard let self else { return }
            switch CommitComparison.applies(askedAt: askedAt, current: self.contentGeneration, retargeting: self.retargetGate.isPending, rerun: rerun) {
            case .apply: break
            case .rerun: return self.compareWithLastCommit(rerun: true)
            case .drop: return NSSound.beep()
            }
            switch result {
            case .baseline(let keys):
                self.showMarked(against: keys, againstCommit: true)
            case .unchanged:
                NSSound.beep()
                self.showNotice(NSLocalizedString("No changes since the last commit", comment: "Notice above the document after Compare with Last Commit: the file is as committed"))
            case .unavailable:
                NSSound.beep()
                self.showNotice(NSLocalizedString("Not in the last commit", comment: "Notice above the document after Compare with Last Commit: git has no committed version of the file (untracked, new, not text, or git not available)"))
            }
        }
    }

    /// Marked against `baseline`, undoably: the commit's (`againstCommit`,
    /// with the notice that says so) or the reading state from before it.
    private func showMarked(against baseline: [BlockKey], againstCommit: Bool) {
        let name = NSLocalizedString("Compare with Last Commit", comment: "Menu: mark the document again against its version in the last git commit")
        // Undoing it while the document is empty for a moment (an agent
        // truncating it) waits for the content; comparing an empty document does not.
        guard !session.blocks.isEmpty || againstCommit else {
            // Empty for a moment (an agent truncating it): kept for when it is back, as restoreUnread does.
            NSSound.beep()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.undoStack.registerUndo(withTarget: self) { $0.showMarked(against: baseline, againstCommit: againstCommit) }
                self.undoStack.setActionName(name)
            }
            return
        }
        let before = session.baseline
        reloadMarked(against: baseline) { [weak self] patch in
            guard let self else { return }
            guard againstCommit else {
                // Undone: the commit's notice goes with its marks (any other notice stays).
                for n in [CommitNotice.marked, .rewritten] { self.webView.call("hideNotice", Self.text(n)) }
                return
            }
            let notice = CommitNotice.after(rewrite: patch.rewrite, unread: self.session.unreadCount)
            if let notice { self.webView.call("notice", Self.text(notice)) }
            SmokeTest.noteCompared(notice.map { Self.text($0) } ?? "")
        }
        undoStack.registerUndo(withTarget: self) { $0.showMarked(against: before, againstCommit: !againstCommit) }
        undoStack.setActionName(name)
    }

    /// The notice above a document marked against its last commit.
    static func text(_ notice: CommitNotice) -> String {
        switch notice {
        case .marked:
            return NSLocalizedString("Changes since the last commit", comment: "Notice above a document opened for the first time: its changes since the last git commit are marked")
        case .rewritten:
            return NSLocalizedString("Rewritten since the last commit", comment: "Notice above a document marked against its last git commit when most of it changed since (nothing is marked)")
        }
    }

    func refreshRepository() {
        let path = contentPath ?? url.path
        inRepository = !path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/")
            && GitBaseline.repository(containing: path, exists: { FileManager.default.fileExists(atPath: $0) }) != nil
    }
}
