import AppKit

/// The application menu, built in code.
@MainActor
enum MainMenu {
    private static let recentDelegate = RecentMenuDelegate()

    static func build(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu()
        let appName = "Readout"

        // App
        let app = NSMenu(title: appName)
        app.addItem(withTitle: String(format: NSLocalizedString("About %@", comment: "Menu"), appName),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(item(NSLocalizedString("Check for Updates…", comment: "Menu"), #selector(AppDelegate.checkForUpdates(_:))))
        app.addItem(.separator())
        app.addItem(item(NSLocalizedString("Settings…", comment: "Menu"), #selector(AppDelegate.showSettings(_:)), ","))
        app.addItem(.separator())
        let services = NSMenuItem(title: NSLocalizedString("Services", comment: "Menu"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(item(String(format: NSLocalizedString("Hide %@", comment: "Menu"), appName), #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item(NSLocalizedString("Hide Others", comment: "Menu"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(item(NSLocalizedString("Show All", comment: "Menu"), #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item(String(format: NSLocalizedString("Quit %@", comment: "Menu"), appName), #selector(NSApplication.terminate(_:)), "q"))
        add(app, to: main)

        // File
        let file = NSMenu(title: NSLocalizedString("File", comment: "Menu"))
        file.addItem(item(NSLocalizedString("Open…", comment: "Menu"), #selector(AppDelegate.openDocument(_:)), "o"))
        file.addItem(item(NSLocalizedString("Open Latest Agent File", comment: "Menu"), #selector(AppDelegate.openLatest(_:)), "o", [.command, .shift]))
        let recent = NSMenuItem(title: NSLocalizedString("Open Recent", comment: "Menu"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: recent.title)
        recentMenu.delegate = recentDelegate
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        file.addItem(item(NSLocalizedString("Close", comment: "Menu"), #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(.separator())
        file.addItem(item(NSLocalizedString("Reveal in Finder", comment: "Menu"), #selector(ReaderWindowController.revealInFinder(_:)), "r", [.command, .shift]))
        file.addItem(item(NSLocalizedString("Open in Editor", comment: "Menu"), #selector(ReaderWindowController.openInEditor(_:)), "e"))
        file.addItem(item(NSLocalizedString("Copy File Path", comment: "Menu"), #selector(ReaderWindowController.copyFilePath(_:)), "c", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item(NSLocalizedString("Print…", comment: "Menu"), #selector(ReaderWindowController.printDocument(_:)), "p"))
        add(file, to: main)

        // Edit
        let edit = NSMenu(title: NSLocalizedString("Edit", comment: "Menu"))
        edit.addItem(item(NSLocalizedString("Copy", comment: "Menu"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(NSLocalizedString("Select All", comment: "Menu"), #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = NSMenuItem(title: NSLocalizedString("Find", comment: "Menu"), action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: find.title)
        findMenu.addItem(item(NSLocalizedString("Find…", comment: "Menu"), #selector(ReaderWindowController.showFind(_:)), "f"))
        findMenu.addItem(item(NSLocalizedString("Find Next", comment: "Menu"), #selector(ReaderWindowController.findNext(_:)), "g"))
        findMenu.addItem(item(NSLocalizedString("Find Previous", comment: "Menu"), #selector(ReaderWindowController.findPrevious(_:)), "g", [.command, .shift]))
        find.submenu = findMenu
        edit.addItem(find)
        add(edit, to: main)

        // View
        let view = NSMenu(title: NSLocalizedString("View", comment: "Menu"))
        view.addItem(item(NSLocalizedString("Show Sidebar", comment: "Menu"), #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]))
        view.addItem(item(NSLocalizedString("Wide Text", comment: "Menu"), #selector(ReaderWindowController.toggleWidth(_:)), "\\", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item(NSLocalizedString("Next Change", comment: "Menu"), #selector(ReaderWindowController.nextChange(_:)), "]"))
        view.addItem(item(NSLocalizedString("Previous Change", comment: "Menu"), #selector(ReaderWindowController.previousChange(_:)), "["))
        view.addItem(item(NSLocalizedString("Mark All as Read", comment: "Menu"), #selector(ReaderWindowController.markAllRead(_:)), "k"))
        view.addItem(item(NSLocalizedString("Show Only Changes", comment: "Menu"), #selector(ReaderWindowController.toggleChangesOnly(_:)), "K", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item(NSLocalizedString("Bigger Text", comment: "Menu"), #selector(AppDelegate.biggerText(_:)), "+"))
        let bigger2 = item(NSLocalizedString("Bigger Text", comment: "Menu"), #selector(AppDelegate.biggerText(_:)), "=")
        bigger2.isHidden = true
        bigger2.allowsKeyEquivalentWhenHidden = true
        view.addItem(bigger2)
        view.addItem(item(NSLocalizedString("Smaller Text", comment: "Menu"), #selector(AppDelegate.smallerText(_:)), "-"))
        view.addItem(item(NSLocalizedString("Actual Size", comment: "Menu"), #selector(AppDelegate.actualSizeText(_:)), "0"))
        view.addItem(.separator())
        view.addItem(item(NSLocalizedString("Enter Full Screen", comment: "Menu"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        add(view, to: main)

        // Window
        let window = NSMenu(title: NSLocalizedString("Window", comment: "Menu"))
        window.addItem(item(NSLocalizedString("Minimize", comment: "Menu"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(NSLocalizedString("Zoom", comment: "Menu"), #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item(NSLocalizedString("Welcome", comment: "Menu"), #selector(AppDelegate.showWelcome(_:))))
        window.addItem(.separator())
        window.addItem(item(NSLocalizedString("Bring All to Front", comment: "Menu"), #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        add(window, to: main)

        // Help
        let help = NSMenu(title: NSLocalizedString("Help", comment: "Menu"))
        help.addItem(item(NSLocalizedString("Readout Help", comment: "Menu"), #selector(HelpTarget.openHelp(_:)), "?", target: HelpTarget.shared))
        NSApp.helpMenu = help
        add(help, to: main)

        return main
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        i.target = target
        return i
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let i = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        i.submenu = menu
        main.addItem(i)
    }
}

@MainActor
final class HelpTarget: NSObject {
    static let shared = HelpTarget()
    @objc func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/hxddh/readout#readme")!)
    }
}

/// Fills "Open Recent" from the shared document controller's list every time it opens.
@MainActor
final class RecentMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let i = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = url
            i.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            i.image = icon
            menu.addItem(i)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: NSLocalizedString("Clear Menu", comment: "Menu"), action: #selector(clear(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { (NSApp.delegate as? AppDelegate)?.open(url) }
    }

    @objc func clear(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(nil) }
}
