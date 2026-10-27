//
//  AppHelp.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//
//  Help. The guides are built into HTML pages (Tools/docs/build-helpbook.py) that
//  ship inside the app in Documentation/HelpBook/M3.help and are shown by
//  HelpWindowController, searched by HelpIndex. The system's Help Viewer is not
//  used: it did not find or search a book for this app reliably.
//
//  The Help menu is registered with the system (NSApp.helpMenu), which gives it
//  the search box that finds menu commands and points at them. AppDelegate also
//  answers that search box with help topics (NSUserInterfaceItemSearching).
//
//  HelpAnchor names the places in the help the app opens from its windows ("?"
//  buttons). Every raw value must exist as an anchor in the pages;
//  M3Tests/HelpAnchorTests.swift checks that, so renaming a heading in a guide
//  cannot silently break a "?" button.
//

import Cocoa

/// A place in the help. The raw value is the anchor name in the help pages.
enum HelpAnchor: String, CaseIterable {
    case home
    case gettingStarted = "start-welcome"
    case firstLaunch = "first-launch"
    case editor = "the-editor-single-file-window"
    case searchingForMetadata = "searching-for-metadata"
    case queue = "the-queue-windows"
    case queueOptions = "queue-options"
    case reviewSheets = "review-sheets"
    case libraryScan = "library-scan-window"
    case messageLog = "message-log"
    case preferencesGeneral = "preferences-general"
    case preferencesMetadata = "preferences-metadata"
    case preferencesSets = "preferences-sets"
    case preferencesFilename = "preferences-filename"
    case preferencesOCR = "preferences-ocr"
    case preferencesAdvanced = "preferences-advanced"
    case preferencesSources = "preferences-sources"
    case preferencesSupport = "preferences-support"
    case mediaIntake = "media-intake-in-detail"
    case intakeSettings = "settings-reference"
    case mediaLocations = "media-locations-where-finished-files-go"
    case losslessMerge = "lossless-merge"
    case commonTasks = "common-tasks"
    case troubleshooting = "troubleshooting"
    case whatsNew = "whats-new"
}

enum AppHelp {

    static let issuesURL = URL(string: "https://github.com/MediaMetadataManager/MediaMetadataManager/issues")!
    static let projectURL = URL(string: "https://github.com/MediaMetadataManager/MediaMetadataManager")!

    /// Opens the Help window at an anchor. If this build has no help pages, the project page
    /// opens instead so the menu item never does nothing.
    static func open(_ anchor: HelpAnchor = .home) {
        guard !HelpIndex.shared.pages.isEmpty else {
            NSWorkspace.shared.open(projectURL)
            return
        }
        HelpWindowController.shared.show(anchor: anchor.rawValue)
    }

    /// Opens one of the guides shipped as a PDF (the file name without ".pdf").
    @discardableResult
    static func openPDF(named name: String) -> Bool {
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf") else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// A round "?" button that opens the help at a fixed anchor. Put one in the corner of a window
/// or panel whose topic has its own section in the guide.
final class HelpAnchorButton: NSButton {

    /// Where the button opens. A window whose content changes (Settings, tab by tab) updates it.
    var anchor: HelpAnchor

    init(anchor: HelpAnchor) {
        self.anchor = anchor
        super.init(frame: NSRect(x: 0, y: 0, width: 21, height: 25))
        bezelStyle = .helpButton
        title = ""
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(openHelp(_:))
        toolTip = NSLocalizedString("Open help for this window", comment: "Help button tooltip")
        setAccessibilityLabel(NSLocalizedString("Help", comment: "Help button accessibility label"))
    }

    required init?(coder: NSCoder) {
        fatalError("HelpAnchorButton is made in code")
    }

    @objc private func openHelp(_ sender: Any?) {
        AppHelp.open(anchor)
    }
}

/// What a "?" toolbar item does. NSToolbarItem keeps its target weakly, so each window has one shared object.
final class HelpToolbarAction: NSObject {
    static let queue = HelpToolbarAction(.queue)
    static let editor = HelpToolbarAction(.editor)

    let anchor: HelpAnchor
    private init(_ anchor: HelpAnchor) { self.anchor = anchor }

    @objc func openHelp(_ sender: Any?) {
        AppHelp.open(anchor)
    }

    /// The "?" item for the right-hand end of a window's toolbar, after the Settings item.
    func makeToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        ButtonToolbarItem(itemIdentifier: identifier,
                          label: NSLocalizedString("Help", comment: "Toolbar"),
                          toolTip: NSLocalizedString("Open help for this window", comment: "Help button tooltip"),
                          image: "NSInfoTemplate",
                          symbolName: "questionmark.circle",
                          target: self,
                          action: #selector(openHelp(_:)))
    }
}

extension NSWindow {

    /// Puts a "?" button at the right end of the title bar that opens the help at `anchor`.
    /// Returns the button so the caller can change its anchor later.
    @discardableResult
    func addHelpButton(anchor: HelpAnchor) -> HelpAnchorButton {
        let button = HelpAnchorButton(anchor: anchor)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        button.frame = NSRect(x: 8, y: 1, width: 24, height: 25)
        holder.addSubview(button)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        addTitlebarAccessoryViewController(accessory)
        return button
    }
}

extension NSAlert {

    /// Shows the "?" button on the alert; it opens the help at `anchor`.
    func addHelpButton(anchor: HelpAnchor) {
        AlertHelpDelegate.shared.anchor = anchor
        delegate = AlertHelpDelegate.shared
        showsHelp = true
    }
}

/// Answers the "?" button of an alert (NSAlert keeps its delegate weakly, hence one shared object).
final class AlertHelpDelegate: NSObject, NSAlertDelegate {
    static let shared = AlertHelpDelegate()
    var anchor: HelpAnchor = .home

    func alertShowHelp(_ alert: NSAlert) -> Bool {
        AppHelp.open(anchor)
        return true
    }
}

extension AppDelegate {

    /// Registers the Help menu with the system (which adds its search box), lets that box find
    /// help topics, and adds the guides, release notes and issue links below the Help item.
    func configureHelpMenu() {
        guard let helpMenu = NSApp.mainMenu?.items.last?.submenu else { return }
        NSApp.helpMenu = helpMenu
        NSApp.registerUserInterfaceItemSearchHandler(self)
        // The Mac keeps Cmd-? for its own Help search and never delivers it to the app (it only beeps), so the
        // Help item shows no shortcut; the Help menu's search box and the "?" buttons are the quick ways in.
        helpMenu.items.first(where: { $0.action == #selector(help(_:)) })?.keyEquivalent = ""
        guard !helpMenu.items.contains(where: { $0.action == #selector(openUserGuide(_:)) }) else { return }

        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            helpMenu.addItem(item)
        }
        helpMenu.addItem(.separator())
        add(NSLocalizedString("Getting Started Guide", comment: "Help menu"), #selector(openGettingStarted(_:)))
        add(NSLocalizedString("User Guide (PDF)", comment: "Help menu"), #selector(openUserGuide(_:)))
        add(NSLocalizedString("What\u{2019}s New in This Version", comment: "Help menu"), #selector(openWhatsNew(_:)))
        helpMenu.addItem(.separator())
        add(NSLocalizedString("Report an Issue\u{2026}", comment: "Help menu"), #selector(openIssues(_:)))
        add(NSLocalizedString("M3 on GitHub", comment: "Help menu"), #selector(openProjectPage(_:)))
    }

    @objc func openGettingStarted(_ sender: Any?) {
        AppHelp.open(.gettingStarted)
    }

    @objc func openUserGuide(_ sender: Any?) {
        if !AppHelp.openPDF(named: "User-Guide") { AppHelp.open(.home) }
    }

    @objc func openWhatsNew(_ sender: Any?) {
        AppHelp.open(.whatsNew)
    }

    @objc func openIssues(_ sender: Any?) {
        NSWorkspace.shared.open(AppHelp.issuesURL)
    }

    @objc func openProjectPage(_ sender: Any?) {
        NSWorkspace.shared.open(AppHelp.projectURL)
    }
}

// MARK: - Help topics in the Help menu's search box

extension AppDelegate: NSUserInterfaceItemSearching {

    func searchForItems(withSearch searchString: String, resultLimit: Int,
                        matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void) {
        handleMatchedItems(HelpIndex.shared.search(searchString, limit: resultLimit))
    }

    func localizedTitles(forItem item: Any) -> [String] {
        guard let hit = item as? HelpHit else { return [] }
        return [hit.page.title]
    }

    func performAction(forItem item: Any) {
        guard let hit = item as? HelpHit else { return }
        HelpWindowController.shared.show(page: hit.page)
    }

    func showAllHelpTopics(forSearch searchString: String) {
        HelpWindowController.shared.show(searchString: searchString)
    }
}
