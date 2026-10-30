import AppKit
import WebKit
import ReadoutCore

extension NSToolbarItem.Identifier {
    static let nextChange = NSToolbarItem.Identifier("readout.nextChange")
    static let search = NSToolbarItem.Identifier("readout.search")
}

/// The window's toolbar: the sidebar button, the next-change button and the find field.
extension ReaderWindowController {
    func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ReaderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .nextChange, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .nextChange:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = NSLocalizedString("Next Change", comment: "Toolbar")
            item.target = self
            item.action = #selector(nextChange(_:))
            item.isBordered = true
            // Shown only with something unread. It is the last item before
            // the search field, so hiding it moves nothing else.
            item.autovalidates = false
            changeItem = item
            updateChangeItem(model.unread)
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField = FindField()
            item.searchField.placeholderString = NSLocalizedString("Find", comment: "Search field placeholder")
            item.searchField.target = self
            item.searchField.action = #selector(searchFieldAction(_:))
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = false
            item.searchField.sendsWholeSearchString = true
            item.preferredWidthForSearchField = 160
            // macOS 26 grows the field into the free toolbar space whatever
            // the preferred width says: hold it at that width.
            let width = item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 160)
            width.isActive = true
            searchItem = item
            return item
        default:
            return nil
        }
    }

    func updateChangeItem(_ n: Int) {
        guard let item = changeItem else { return }
        item.isEnabled = n > 0
        item.isHidden = n == 0
        if n > 0 { item.image = Self.changeImage(count: n) }
        item.toolTip = n > 0
            ? String(format: NSLocalizedString("Unread changes: %d. Press N for the next change, D to see what changed.", comment: "Toolbar tooltip; %d is the number of unread changes"), n)
            : NSLocalizedString("No unread changes", comment: "Toolbar tooltip")
    }

    /// The next-change button: the system arrow, as plain as the find
    /// field's magnifier beside it. Shown only while something is unread, so
    /// being there is the signal; how many is in its tooltip and for VoiceOver.
    static func changeImage(count: Int) -> NSImage {
        let image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil) ?? NSImage()
        image.accessibilityDescription = String(format: NSLocalizedString("Unread changes: %d", comment: "Next-change button for VoiceOver; %d is the number"), count)
        return image
    }

    // MARK: Find

    @objc func showFind(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    /// The page finds (find.js: WebKit's own find skips the blocks a large
    /// document has not laid out); the field shows the current match of how many.
    var findField: FindField? { searchItem?.searchField as? FindField }

    // The text edited: the last search's marks and count go (the page keeps
    // the blocks' text for the next one). Cleared, closed: the search is over.
    func controlTextDidChange(_ obj: Notification) { endFind(keepText: true) }
    func searchFieldDidEndSearching(_ sender: NSSearchField) { endFind() }
    // The field gave up focus and the bar is collapsed (a narrow window), its text still in it: over too.
    func controlTextDidEndEditing(_ obj: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let field = self.searchItem?.searchField else { return }
            let editing = field.currentEditor() != nil && self.window?.firstResponder === field.currentEditor()
            let collapsed = field.window == nil || field.isHiddenOrHasHiddenAncestor || field.bounds.width < 60
            if collapsed && !editing { self.endFind() }
        }
    }

    func endFind(keepText: Bool = false) {
        findGeneration += 1
        finding = false
        findField?.count = ""
        if webView.isReady { webView.call("findEnd", json: keepText ? "true" : "false") }
    }

    @objc func findNext(_ sender: Any?) { find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }

    @objc private func searchFieldAction(_ sender: NSSearchField) { find(backwards: false) }

    func find(backwards: Bool) {
        let text = searchItem?.searchField.stringValue ?? ""
        guard !text.isEmpty else { showFind(nil); return }
        guard let data = try? JSONEncoder().encode(text), let json = String(data: data, encoding: .utf8) else { return }
        // A cold window's document may not be in its page yet: found once it
        // is (unless the field was cleared or closed, or searched again, meanwhile).
        findGeneration += 1
        finding = true
        let generation = findGeneration
        let search = { [weak self] in
            guard let self, self.findGeneration == generation else { return }
            self.webView.run("window.readout.find(\(json), \(backwards))") { value, _ in
                if ((value as? NSNumber)?.intValue ?? 0) == 0 { NSSound.beep() }
            }
        }
        if loadState == .loaded { webView.whenReady(search) } else { whenLoaded.find = search }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            searchItem?.endSearchInteraction()
            endFind()
            window?.makeFirstResponder(webView)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            find(backwards: backwards)
            return true
        }
        return false
    }
}
