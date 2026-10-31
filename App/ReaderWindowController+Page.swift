import AppKit
import WebKit
import ReadoutCore
import os

/// The page bridge: what the reader page asks for, and what the window asks
/// of it (navigation, the page's messages, links, notices, copying).
extension ReaderWindowController {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = action.request.url else { return .cancel }
        // The reader page is the only page: any other readout: URL (a
        // relative link resolved against the page, readout://app/other.md)
        // would replace the document with an error page.
        if target.scheme == ReadoutURL.scheme { return ReaderWebView.isReaderPage(target) ? .allow : .cancel }
        // A file dropped onto the window arrives as a navigation.
        if target.isFileURL { (NSApp.delegate as? AppDelegate)?.open(target) }
        else if action.navigationType == .linkActivated { openExternal(target) }
        return .cancel
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Recover from a crashed renderer: reload the page and re-send the document.
        // The new page has no selection and no focused block yet (Copy as Quote).
        hasSelection = false
        hasFocusedBlock = false
        self.webView.reloadReader()
        self.webView.whenReady { [weak self] in
            guard let self else { return }
            self.applyAppearance()
            self.sendKnownImages()
            self.webView.callEncodingOffMain("apply", self.session.fullPayload(rewrite: false).page)
        }
        // The new page has found nothing yet (and a search queued for the old one does not run).
        endFind()
    }

    /// A passing message (a link to a file that is not there, Compare with
    /// Last Commit finding nothing, N going on to this document): the page's
    /// notice, where every passing message shows (VoiceOver reads it:
    /// role=status). The subtitle keeps only what stays true.
    func showNotice(_ text: String) {
        webView.whenReady { [weak self] in self?.webView.call("notice", text) }
    }

    /// Says `text` to VoiceOver now.
    private func announce(_ text: String) {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Messages from the page

    func handle(_ raw: [String: Any]) {
        guard let msg = PageMessage(raw) else { return }
        switch msg {
        case .read(let slots, let deletions):
            session.markRead(slots: slots, deletionIDs: deletions)
            refreshUnread()
            scheduleSave()
        case .activeHeading(let slot):
            if slot != model.activeSlot { model.activeSlot = slot }
        case .anchor(let slot, let offset):
            lastAnchor = (slot, offset)
            scheduleSave()
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .contextHeading(let anchor):
            contextHeading = anchor
        case .applied:
            ReaderPerf.signposter.emitEvent("applied")
            SmokeTest.noteApplied()
            if !appliedOnce {
                // Window request to the page's first apply: Readout's own share
                // of an open, without the frame the system paints it in.
                appliedOnce = true
                SmokeTest.noteFirstApply(url, seconds: Date().timeIntervalSince(openedAt))
                SmokeTest.noteLaunchPhase("apply")
            }
        case .painted:
            SmokeTest.notePainted()
            if !painted {
                // First patch presented on screen: the open is done.
                painted = true
                ReaderPerf.signposter.endInterval("open", openSignpost)
                SmokeTest.noteFirstPaint(url, seconds: Date().timeIntervalSince(openedAt))
                SmokeTest.noteLaunchPhase("paint")
                WebViewPool.shared.pagePainted()
            }
        case .open(let href):
            openLink(href)
        case .loadRemote(let remote, let id):
            loadRemote(remote, id: id)
        case .openPath(let path, let line, let column):
            EditorOpener.open(path: path, line: line, column: column)
        case .setCodeWrap(let on):
            if AppSettings.shared.codeWrap != on { AppSettings.shared.codeWrap = on }
        case .setTextWidth(let rem):
            // Every window follows, as for View ▸ Text Width.
            let width = rem.map { ReaderLayout.textWidth(rem: $0) } ?? "standard"
            if AppSettings.shared.textWidth != width { AppSettings.shared.textWidth = width }
        case .nothing, .wrapped:
            // A key with nothing to go to (D with nothing in view), or N
            // wrapping past the last change back to the first.
            NSSound.beep()
        case .noUnread:
            // N with no unread change left here: on to the next document with some.
            if (NSApp.delegate as? AppDelegate)?.goToNextUnread(from: self) != true { NSSound.beep() }
        case .showUnread:
            if unreadHold != nil { unreadShown() }
        case .selection(let has, let focused):
            hasSelection = has
            hasFocusedBlock = focused
        case .landed(let index, let total, let kind):
            // VoiceOver hears which change it is, as the rail's ticks say it.
            let kindText = ReaderStrings.all[kind] ?? kind
            announce(String(format: NSLocalizedString("Unread change %d of %d: %@", comment: "Change-rail tick label; %d is position, %d is total, %@ is the kind"),
                            index, total, kindText))
            SmokeTest.noteLanded(index: index, total: total, kind: kind)
        case .found(let current, let total):
            guard finding else { break }   // a count on its way when the search ended
            findField?.count = total == 0 ? NSLocalizedString("Not found", comment: "Find field: no match")
                : current == 0 ? String(format: NSLocalizedString("– of %d", comment: "Find field: matches an edit brought, none current yet"), total)
                : String(format: NSLocalizedString("%d of %d", comment: "Find field: the current match of how many"), current, total)
            SmokeTest.noteFound()
        case .ready, .error:
            break   // handled by ReaderWebView
        }
    }

    func loadRemote(_ remote: String, id: String) {
        RemoteImageLoader.shared.load(remote) { [weak self] result in
            switch result {
            case .success(let local):
                self?.webView.call("remoteReady", ["id": id, "url": local])
            case .failure(.rejected(let reason)):
                self?.webView.call("remoteFailed", ["id": id, "error": reason])
            }
        }
    }

    /// A link followed in the document, or in an earlier version of it (VersionWindowController).
    func openLink(_ href: String) {
        let fm = FileManager.default
        // A link to a source file is looked for where a path in a code span
        // is (the project, the repository's folders, the agent folders) before it is missing.
        let resolver = FileResolver(baseDirectory: url.deletingLastPathComponent(), project: projectRoot.path,
                                    workspaces: AppSettings.shared.workspaces)
        guard let target = LinkTarget.resolve(href, from: url, markdownExtensions: WorkspaceIndex.markdownExtensions,
                                              fileExists: { fm.fileExists(atPath: $0.path) },
                                              isDirectory: { u in
                                                  var dir: ObjCBool = false
                                                  return fm.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
                                              },
                                              candidates: resolver.candidates(for:)) else { return }
        switch target {
        case .external(let u): openExternal(u)
        case .file(let u):
            var dir: ObjCBool = false
            let isDirectory = fm.fileExists(atPath: u.path, isDirectory: &dir) && dir.boolValue
            if LinkTarget.runsWhenOpened(u, isDirectory: isDirectory, isExecutable: fm.isExecutableFile(atPath: u.path)) {
                // An app, a script, an installer: shown in Finder, never run from a document.
                NSWorkspace.shared.activateFileViewerSelecting([u])
            } else if !NSWorkspace.shared.open(u) {
                // No app for it (a file name with a line that is not there, "main.swift:42"): say so.
                NSSound.beep()
            }
        case .source(let u, let line, let column): EditorOpener.open(path: u.path, line: line, column: column)
        case .sameDocument(let fragment): scrollToAnchor(fragment: fragment)
        case .markdown(let u, let fragment): (NSApp.delegate as? AppDelegate)?.open(u, anchor: fragment, from: self)
        case .missing(let u):
            NSSound.beep()
            showNotice(String(format: NSLocalizedString("%@ could not be found.", comment: "Notice above the document after a link to a missing file; %@ is the file name"), u.lastPathComponent))
        }
    }

    /// A link out of the document: opened by the system when its scheme is
    /// one that only shows something (the web, mail); any other (an app's own
    /// URL scheme can act on what it is given) is refused, and said so.
    private func openExternal(_ u: URL) {
        guard LinkTarget.isSafeExternalScheme(u) else {
            NSSound.beep()
            showNotice(String(format: NSLocalizedString("Readout doesn't open %@ links.", comment: "Notice above the document after a link with a scheme Readout refuses; %@ is the scheme, like 'ssh:'"),
                              (u.scheme ?? "") + ":"))
            return
        }
        // No app for it (a file name with a line that is not there, "main.swift:42"): say so.
        if !NSWorkspace.shared.open(u) { NSSound.beep() }
    }

    /// Scrolls to the heading whose slug matches the fragment (GitHub-style).
    /// Before the document is shown it waits: a fragment asked for then
    /// (opened again at a section while loading) wins over the saved position.
    func scrollToAnchor(fragment: String) {
        guard loadState == .loaded else { whenLoaded.anchor = fragment; return }
        // Loaded, the page not ready (a new page, a renderer that crashed): after its apply.
        guard webView.isReady else { return webView.whenReady { [weak self] in self?.scrollToAnchor(fragment: fragment) } }
        let slug = fragment.lowercased()
        if let block = session.blocks.first(where: {
            $0.kind == .heading && ($0.anchor == slug || $0.anchor?.lowercased() == slug)
        }) {
            webView.call("scrollToSlot", json: String(block.slot))
        } else {
            // Fall back to the page's own anchor lookup (percent-decoding, case variants).
            let fragJSON = (try? JSONSerialization.data(withJSONObject: ["fragment": fragment]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            webView.call("scrollToFragment", json: fragJSON)
        }
    }

    // MARK: Actions sent to the page

    @objc func nextChange(_ sender: Any?) { webView.call("nextChange") }
    @objc func previousChange(_ sender: Any?) { webView.call("previousChange") }

    // MARK: Copy as Quote

    /// Edit ▸ Copy as Quote (⇧⌘C): the Markdown source of the blocks the
    /// selection touches, as a blockquote, and the file's lines and section.
    @objc func copyAsQuote(_ sender: Any?) {
        webView.run("window.readout.quoteSelection()") { [weak self] value, _ in
            guard let self else { return }
            let selection = value as? [String: Any]
            let slots = Set(((selection?["slots"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue })
            let path = QuoteFormatter.displayPath(self.url.path, projectRoot: self.projectRoot.path)
            guard let text = QuoteFormatter.quote(blocks: self.session.blocks, slots: slots, path: path,
                                                  definitions: selection?["links"] as? [String] ?? []) else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: Copy Link to Section

    /// A heading's context menu: Copy Link to Section first.
    func addSectionLinkItem(to menu: NSMenu) {
        guard let anchor = contextHeading else { return }
        contextHeading = nil
        let item = NSMenuItem(title: NSLocalizedString("Copy Link to Section", comment: "Context menu of a heading"),
                              action: #selector(copyLinkToSection(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = anchor
        menu.insertItem(item, at: 0)
        if menu.items.count > 1 { menu.insertItem(.separator(), at: 1) }
    }

    /// Section link: "<full path>#<anchor>" on the clipboard, usable from anywhere.
    @objc func copyLinkToSection(_ sender: NSMenuItem) {
        guard let anchor = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(url.path)#\(anchor)", forType: .string)
    }

    /// The page's context menu: Copy as Quote after Copy, when text is selected.
    func addQuoteItem(to menu: NSMenu) {
        guard hasSelection, let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) else { return }
        let item = NSMenuItem(title: NSLocalizedString("Copy as Quote", comment: "Menu: copy the selected blocks' Markdown as a quote with the file's lines"),
                              action: #selector(copyAsQuote(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: copy + 1)
    }
}
