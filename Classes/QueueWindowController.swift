//
//  QueueWindowController.swift
//  M3
//
//  One Queue window with a Movies tab and a TV Shows tab, in place of two
//  separate windows. Each tab is still its own QueueController (its own
//  list, saved file, Options and Intake handling); this controller only
//  hosts their content, owns the single toolbar, and passes the toolbar's
//  buttons on to whichever tab is showing. Each QueueController reports
//  this window as its own, so its sheets, popovers and Undo work here.
//

import Cocoa

final class QueueWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate, NSUserInterfaceValidations {

    // MARK: Shared instance

    private static var instance: QueueWindowController?

    /// The window both QueueControllers report as theirs once it exists.
    static var hostWindow: NSWindow?

    static var shared: QueueWindowController {
        if let instance = instance { return instance }
        let controller = QueueWindowController()
        instance = controller
        return controller
    }

    /// The window controller if it has been created; used by code that can
    /// run while a QueueController is still being set up.
    static var existing: QueueWindowController? {
        return instance
    }

    // MARK: State

    private let movies: QueueController
    private let tvShows: QueueController
    private let tabView = NSTabView()
    private let moviesItem = NSTabViewItem(identifier: "movies")
    private let tvShowsItem = NSTabViewItem(identifier: "tvShows")
    private let toolbarDelegate = QueueToolbarDelegate()
    private let toolbar = NSToolbar(identifier: "M3QueueToolbar.v1")

    private static let selectedTabKey = "SBQueueSelectedTab"

    var activeController: QueueController {
        return tabView.selectedTabViewItem === tvShowsItem ? tvShows : movies
    }

    // MARK: Setup

    private init() {
        // Both queues are created first; they load their own (hidden)
        // windows, whose content is moved into the tabs below.
        let movies = QueueController.shared
        let tvShows = QueueController.tvShows
        self.movies = movies
        self.tvShows = tvShows

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        super.init(window: window)

        window.title = NSLocalizedString("Queue", comment: "Queue window title")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 320)
        window.delegate = self
        if #available(macOS 11, *) {
            window.toolbarStyle = .expanded
        }

        // Same look as the tabs in Settings (Media Intake and its neighbours):
        // small tab labels in a bordered panel, set in from the window edge.
        tabView.controlSize = .small
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self

        moviesItem.label = NSLocalizedString("Movies", comment: "Queue tab")
        tvShowsItem.label = NSLocalizedString("TV Shows", comment: "Queue tab")
        moviesItem.view = movies.takeNibContent()
        tvShowsItem.view = tvShows.takeNibContent()
        tabView.addTabViewItem(moviesItem)
        tabView.addTabViewItem(tvShowsItem)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 520))
        container.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])
        window.contentView = container

        if UserDefaults.standard.integer(forKey: QueueWindowController.selectedTabKey) == 1 {
            tabView.selectTabViewItem(tvShowsItem)
        }

        // The identifier is also the key the customized layout is saved under.
        toolbarDelegate.target = self
        toolbar.delegate = toolbarDelegate
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        if #available(macOS 26, *) {
            toolbar.displayMode = .iconAndLabel
        } else {
            toolbar.displayMode = .iconOnly
        }
        window.toolbar = toolbar

        // From here on each queue's sheets, popovers and Undo belong to this window.
        QueueWindowController.hostWindow = window
        window.setFrameAutosaveName("SBQueueTabsPosition")

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Showing

    /// Shows the window with `controller`'s tab selected.
    func show(_ controller: QueueController) {
        tabView.selectTabViewItem(controller === tvShows ? tvShowsItem : moviesItem)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Shows the window if it is hidden, with `controller`'s tab selected.
    /// An open window is left on its current tab.
    func showIfHidden(_ controller: QueueController) {
        if window?.isVisible != true {
            show(controller)
        }
    }

    // MARK: Toolbar

    /// Start/Stop follows the tab on screen. A queue that is not showing
    /// does not touch the toolbar; `tabView(_:didSelect:)` catches up.
    func setRunning(_ working: Bool, for controller: QueueController) {
        guard controller === activeController else { return }
        toolbarDelegate.setState(working: working, toolbar: toolbar)
    }

    // MARK: Toolbar actions, passed to the tab on screen

    @objc func open(_ sender: Any?) {
        activeController.open(sender)
    }

    @objc func toggleOptions(_ sender: Any?) {
        activeController.toggleOptions(sender)
    }

    @objc func toggleStartStop(_ sender: Any?) {
        activeController.toggleStartStop(sender)
    }

    @objc func mergeSelectedItems(_ sender: Any?) {
        activeController.mergeSelectedItems(sender)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        return activeController.validateUserInterfaceItem(item)
    }

    // MARK: NSTabViewDelegate

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        UserDefaults.standard.set(tabViewItem === tvShowsItem ? 1 : 0, forKey: QueueWindowController.selectedTabKey)
        toolbarDelegate.setState(working: activeController.status == .working, toolbar: toolbar)
        toolbar.validateVisibleItems()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        movies.windowWillClose(notification)
        tvShows.windowWillClose(notification)
    }

    func windowDidUpdate(_ notification: Notification) {
        activeController.windowDidUpdate(notification)
    }

    /// Coming back to the Queue (from Finder, say) is when files changed
    /// outside the app should show up.
    func windowDidBecomeKey(_ notification: Notification) {
        movies.refreshFromDisk()
        tvShows.refreshFromDisk()
    }

    func windowDidResize(_ notification: Notification) {
        activeController.windowDidResize(notification)
    }
}

// MARK: - Review dialogs that can be moved

/// The Queue's review dialogs (naming, merge order, metadata, "already
/// merged") used to slide down from the Queue window as sheets, which cover
/// the list and cannot be moved. They now open centred over the Queue window
/// but can be dragged aside, so the Status column and the rest of the list
/// stay readable while you decide.
enum MovableDialog {

    private static func centre(_ dialog: NSWindow, over parent: NSWindow) {
        let parentFrame = parent.frame
        let size = dialog.frame.size
        dialog.setFrameOrigin(NSPoint(x: parentFrame.midX - size.width / 2, y: parentFrame.midY - size.height / 2))
    }

    /// Shows a dialog window (one that used to be a sheet) and calls
    /// `completion` with the response it ends with.
    static func present(_ dialog: NSWindow, over parent: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        dialog.styleMask.insert(.titled)
        dialog.isMovableByWindowBackground = true
        centre(dialog, over: parent)
        // Not DispatchQueue.main.async: a modal loop started from inside a
        // main-queue block keeps that block "running", so every other
        // main-queue block (the dialog's own background work reporting back,
        // for one) would wait until the dialog closed.
        RunLoop.main.perform(inModes: [.common]) {
            let response = NSApp.runModal(for: dialog)
            dialog.orderOut(nil)
            completion(response)
        }
    }

    /// The same for an alert.
    static func present(alert: NSAlert, over parent: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            alert.layout()
            alert.window.isMovableByWindowBackground = true
            centre(alert.window, over: parent)
            completion(alert.runModal())
        }
    }

    /// Ends a dialog with `response`, whether it is showing as a sheet or as
    /// a movable window.
    static func end(_ dialog: NSWindow, with response: NSApplication.ModalResponse) {
        if let parent = dialog.sheetParent {
            parent.endSheet(dialog, returnCode: response)
        } else {
            NSApp.stopModal(withCode: response)
        }
    }
}
