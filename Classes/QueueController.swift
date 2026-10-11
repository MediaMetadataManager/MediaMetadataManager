//
//  QueueController.swift
//  Subler
//
//  Created by Damiano Galassi on 26/01/2019.
//

import Cocoa
import UserNotifications
import MP42Foundation

final class QueueController : NSWindowController, NSWindowDelegate, NSPopoverDelegate, ItemViewDelegate, NSTableViewDataSource, NSTableViewDelegate, ExpandedTableViewDelegate, UNUserNotificationCenterDelegate, NSUserInterfaceValidations {

    static let shared = QueueController()

    /// A second Queue -- its own window and saved list -- for TV episodes
    /// found by the intake watcher, so movie releases and TV shows can be
    /// followed and managed separately. Movies stay in `shared`.
    static let tvShows = QueueController(tvShowQueue: true)

    let isTVShowQueue: Bool

    private let queue: Queue
    private let prefs = QueuePreferences()
    private var popover: NSPopover?
    private var itemPopover: NSPopover?

    /// Scheduled by attemptAutoMerge(for:) when a release qualifies for
    /// "auto mode" (MediaIntakePrefs.autoMergeOnSequence) -- fires
    /// runMerge(for:order:) after a short delay so there's a real moment
    /// to intervene before the merge actually starts, same reasoning as
    /// NamingReviewWindowController's autoApproveWorkItem. Keyed by
    /// release.id rather than held as one single var: unlike the naming
    /// window (one modal sheet at a time), several releases can each be
    /// mid-approval and so mid-auto-merge-delay at once. reviewMerge(for:)
    /// cancels and removes a release's entry the moment its row is opened
    /// manually, which is what lets "open Edit during the delay" cancel
    /// the pending auto-merge.
    private var pendingAutoMerges: [UUID: DispatchWorkItem] = [:]
    private var windowController: OptionsViewController?
    private let toolbarDelegate = QueueToolbarDelegate()

    private lazy var docImg: NSImage = {
        // Load a generic movie icon to display in the table view
        let img = {
            if #available(macOS 12, *) {
                return NSWorkspace.shared.icon(for: .quickTimeMovie)
            } else {
                return NSWorkspace.shared.icon(forFileType: "mov")
            }
        }()
        img.size = NSSize(width: 16, height: 16)
        return img
    }()

    @IBOutlet var table: ExpandedTableView!
    @IBOutlet var statusLabel: NSTextField!
    @IBOutlet var progressBar: NSProgressIndicator!

    // Context-menu items (Queue.xib) -- outlets exist only so
    // configureContextMenuIcons() can give each one a glyph; none of
    // them change the menu's existing title/action/validation wiring.
    @IBOutlet weak var revealInFinderMenuItem: NSMenuItem!
    @IBOutlet weak var editMenuItem: NSMenuItem!
    @IBOutlet weak var removeFromQueueMenuItem: NSMenuItem!
    @IBOutlet weak var removeCompletedMenuItem: NSMenuItem!

    override var windowNibName: NSNib.Name? {
        return "Queue"
    }

    private init(tvShowQueue: Bool = false) {
        isTVShowQueue = tvShowQueue
        popover = nil
        itemPopover = nil
        windowController = nil
        if let url = prefs.queueURL {
            let queueURL = tvShowQueue ? url.deletingLastPathComponent().appendingPathComponent("tv-queue.sbqueue", isDirectory: false) : url
            queue = Queue(url: queueURL)
        } else {
            fatalError("Invalid queue url")
        }
        super.init(window: nil)
        _ = window
        if tvShowQueue == false {
            startIntakeWatching()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        window?.tabbingMode = .disallowed

        window?.title = isTVShowQueue
            ? NSLocalizedString("TV Shows Queue", comment: "TV queue window title")
            : NSLocalizedString("Movies Queue", comment: "Movie queue window title")

        if isTVShowQueue, let window = window {
            window.setFrameAutosaveName("SBTVQueuePosition")
            if window.setFrameUsingName("SBTVQueuePosition") == false {
                // First time: sit a little below and to the right of the
                // movie queue instead of exactly on top of it.
                var frame = window.frame
                frame.origin.x += 40
                frame.origin.y -= 40
                window.setFrame(frame, display: false)
            }
        }


        // Matches DocumentWindowController's toolbarStyle -- was
        // `.unified` here, which puts the title and the toolbar's icons
        // on one compact row with a left-aligned, un-centered title.
        // `.expanded` is what the single-file document window already
        // uses (a separate title row above a taller icon+label toolbar
        // row), and the two windows are meant to read as one app, not
        // two different window styles.
        if #available(macOS 11, *) {
            window?.toolbarStyle = .expanded
        }

        toolbarDelegate.target = self

        // The identifier is also the key the toolbar's customized layout is
        // saved under; it was bumped when the default order changed to
        // Add, Merge, Start, space, Settings, so older saved layouts
        // don't keep the previous order.
        let toolbar = NSToolbar(identifier: isTVShowQueue ? "SublerQueueToolbar.tv.v2" : "SublerQueueToolbar.v2")
        toolbar.delegate = toolbarDelegate
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        if #available(macOS 26, *) {
            toolbar.displayMode = .iconAndLabel
        } else {
            toolbar.displayMode = .iconOnly
        }
        self.window?.toolbar = toolbar

        configureContextMenuIcons()

        table.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL, .tableViewIndex])
        // Same "double-click a row to open/edit it" convention already
        // used by MovieViewController, ChapterViewController,
        // TracksViewController, and CustomSourcesListViewController --
        // reuses the existing "Edit\u{2026}" context-menu action, which now
        // also opens the naming review window for a pending release (see
        // edit(_:) below). There was no doubleAction on this table before
        // this -- a release row had no way to be opened at all.
        table.doubleAction = #selector(edit(_:))
        progressBar.isHidden = true

        if #available(macOS 11, *) {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.sound, .alert], completionHandler: {_,_ in })
        }

        let main = OperationQueue.main
        let nc = NotificationCenter.default

        nc.addObserver(forName: Queue.Working, object: queue, queue: main) {(note) in
            guard let info = note.userInfo,
                let status = info["ProgressString"] as? String,
                let progress = info["Progress"] as? Double,
                let index = info["ItemIndex"] as? Int
                else { return }

            self.progressStatusText = status
            self.progressBar.isIndeterminate = false
            self.progressBar.doubleValue = progress
            self.refreshProgressDisplay()

            if index != NSNotFound {
                self.updateUI(indexes: IndexSet(integer: index))
            }
        }

        nc.addObserver(forName: Queue.Completed, object: queue, queue: main) { (note) in
            self.progressBar.isHidden = true
            self.progressBar.stopAnimation(self)
            self.progressBar.doubleValue = 0
            self.progressBar.isIndeterminate = true

            if let toolbar = self.window?.toolbar {
                self.toolbarDelegate.setState(working: false, toolbar: toolbar)
            }
            self.statusLabel.stringValue = NSLocalizedString("Done", comment: "Queue -> Done")

            if MediaIntakePrefs.autoRemoveCompletedItems {
                self.removeCompletedItems(self)
            }
            self.updateUI()
            EmptyFolderCleaner.runAutomaticallyIfEnabled()

            if self.prefs.showDoneNotification, let info = note.userInfo {
                let title = NSLocalizedString("Queue Done", comment: "")
                let informativeText = {
                    if let failedCount = info["FailedCount"] as? UInt, failedCount > 0,
                       let completedCount = info["CompletedCount"] as? UInt {
                        return "Completed: \(completedCount); Failed: \(failedCount)"
                    }
                    else if let completedCount = info["CompletedCount"] as? UInt {
                        return "Completed: \(completedCount)"
                    } else {
                        return ""
                    }
                }()

                if #available(macOS 11, *) {
                    let notification = UNMutableNotificationContent()
                    notification.title = title
                    notification.body  = informativeText
                    notification.sound = UNNotificationSound.default

                    let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                        content: notification,
                                                        trigger: nil)
                    UNUserNotificationCenter.current().add(request) { _ in }
                } else {
                    let notification = NSUserNotification()
                    notification.title = title
                    notification.informativeText = informativeText
                    notification.soundName = NSUserNotificationDefaultSoundName
                    NSUserNotificationCenter.default.deliver(notification)
                }
            }

            for script in self.scripts {
                script.resumeExecution(withResult: "Completed")
            }
            self.scripts.removeAll()
        }

        nc.addObserver(forName: Queue.Failed, object: queue, queue: main) { (note) in
            guard let info = note.userInfo,
                let error = info["Error"] as? Error else { return }
            self.presentError(error)
        }

        // Update the UI the first time
        updateUI()
        removeCompletedItems(self)
    }

    /// Gives the right-click/contextual menu's four items a glyph
    /// alongside their existing titles, so "what can I do with this
    /// row" and "what will actually happen" (Edit... pulls the row out
    /// of the queue for manual editing; the two Remove items only ever
    /// drop rows from this list, never touch the files on disk) read
    /// faster than title text alone -- Edit greys out exactly like its
    /// text already does (NSMenuItem dims its image along with its
    /// title when validateUserInterfaceItem(_:) returns false, so no
    /// extra work was needed there). SF Symbols need macOS 11 -- same
    /// constraint and same #available fallback already used for
    /// toolbar icons (PrefsWindowController, DocumentToolbarDelegate)
    /// and the API-key reveal button (CustomSourcesListViewController)
    /// -- so pre-11 simply keeps the text-only items this menu always
    /// had. "Remove completed items" reuses this app's own existing
    /// "EncodeComplete" status icon (the same checkmark already shown
    /// next to a finished row in this table) rather than a generic SF
    /// Symbol, since it's a more exact match for what the item actually
    /// targets and needs no availability check.
    private func configureContextMenuIcons() {
        removeCompletedMenuItem?.image = NSImage(named: "EncodeComplete")

        guard #available(macOS 11, *) else { return }

        revealInFinderMenuItem?.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        editMenuItem?.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        removeFromQueueMenuItem?.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)
    }

    //MARK: Notification delegate

    @available(macOS 10.14, *)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.sound])
    }

    //MARK: User Interface Validation

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(removeSelectedItems(_:)):
            if let row = table?.selectedRow, row != -1 {
                let queueRow = queue.row(at: row)
                if queueRow.effectiveItem?.status != .working && queueRow.release?.stage != .merging {
                    return true
                }
            } else if let row = table?.clickedRow, row != -1 {
                let queueRow = queue.row(at: row)
                if queueRow.effectiveItem?.status != .working && queueRow.release?.stage != .merging {
                    return true
                }
            }
            return false
        case #selector(showInFinder(_:)):
            if let row = table?.clickedRow, row != -1 {
                if queue.row(at: row).effectiveItem?.status == .completed {
                    return true
                }
            }
            return false
        case #selector(edit(_:)):
            if let row = table?.clickedRow, row != -1 {
                let queueRow = queue.row(at: row)
                if let status = queueRow.effectiveItem?.status, status == .completed || status == .ready {
                    return true
                }
                // A release still awaiting a naming decision (or one the
                // user rejected and wants to reconsider) -- see
                // reviewNaming(for:at:). Every later stage already has an
                // approvedName and isn't reopened from here.
                if let stage = queueRow.release?.stage, stage == .pendingNaming || stage == .namingRejected {
                    return true
                }
                // A multi-file release still awaiting merge order/selection,
                // or one whose last merge attempt failed and needs the
                // order adjusted before retrying -- see reviewMerge(for:)
                // (phase 5).
                if let stage = queueRow.release?.stage, stage == .pendingMergeSelection || stage == .mergeFailed {
                    return true
                }
                // A single-file release whose automatic metadata match
                // wasn't confident enough to resolve itself -- see
                // reviewMetadata(for:) and attemptAutoResolveMetadata(for:)
                // (interface-architecture doc gap #1).
                if let stage = queueRow.release?.stage, stage == .pendingMetadata {
                    return true
                }
            }
            return false
        case #selector(removeCompletedItems(_:)):
            return true
        case #selector(toggleOptions(_:)):
            return true
        case #selector(toggleStartStop(_:)):
            return true
        case #selector(open(_:)):
            return true
        case #selector(mergeSelectedItems(_:)):
            return mergeCandidateRows(at: table?.selectedRowIndexes ?? IndexSet()) != nil
        default:
            return false
        }
    }

    //MARK: Queue

    func saveToDisk() throws {
        prefs.saveUserDefaults()
        try queue.saveToDisk()
    }

    /// Completed items currently open in an editor window, keyed by the
    /// item. Their Queue row stays in the list (with its Edit button
    /// greyed out and Save available) until that window closes.
    private var openEditors: [ObjectIdentifier: Document] = [:]

    internal func edit(item: QueueItem) {
        // Already open: bring that window forward instead of opening the
        // same file a second time.
        if let existing = openEditors[ObjectIdentifier(item)] {
            existing.showWindows()
            existing.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            itemPopover?.close()
            return
        }

        let originalStatus = item.status
        item.status = .working

        updateUI(indexes: IndexSet(integer: queue.index(of: item)))

        DispatchQueue.global().async {
            if originalStatus != .completed {
                do {
                    try item.prepare()
                } catch {
                    DispatchQueue.main.async {
                        self.presentError(error)
                    }
                }
            }

            DispatchQueue.main.async {
                do {
                    var doc: Document?
                    if originalStatus == .completed {
                        try doc = Document(contentsOf: item.destURL, ofType: "")
                    } else if let mp4 = item.mp4File {
                        doc = Document(mp4: mp4)
                        doc?.sourceFileURLHint = item.fileURL
                    }

                    if let doc = doc {
                        // A release item: search by the approved name, not
                        // by the file's own name (often just "01.mp4").
                        doc.searchNameHint = item.actions.compactMap { ($0 as? QueueMetadataAction)?.searchName }.first
                        NSDocumentController.shared.addDocument(doc)
                        doc.makeWindowControllers()
                        doc.showWindows()

                        self.itemPopover?.close()

                        item.status = originalStatus

                        if originalStatus == .completed {
                            // Keep the row, with Edit greyed out while the
                            // editor is open (see keepRow(for:whileEditingIn:)).
                            self.keepRow(for: item, whileEditingIn: doc)
                            self.refreshRow(for: item)
                        } else {
                            let index = self.queue.index(of: item)
                            self.remove(at: index)
                            self.updateState()
                        }
                    }
                } catch {
                    item.status = originalStatus
                    self.refreshRow(for: item)
                    self.presentError(error)
                }
            }
        }
    }

    private func keepRow(for item: QueueItem, whileEditingIn document: Document) {
        let key = ObjectIdentifier(item)
        openEditors[key] = document

        document.onClose = { [weak self, weak item] url in
            guard let self = self else { return }
            self.openEditors[key] = nil
            guard let item = item else { return }

            if let url = url, FileManager.default.fileExists(atPath: url.path) {
                // The row stays so the file can be reopened; a save may
                // have renamed or moved it, so follow it.
                if item.destURL.standardizedFileURL != url.standardizedFileURL {
                    item.destURL = url
                }
                self.refreshRow(for: item)
            } else {
                // The file is gone (moved or deleted outside the app).
                let index = self.queue.index(of: item)
                if index >= 0 {
                    self.remove(at: index)
                }
            }
            self.updateState()
        }
    }

    /// Redraws one item's row (its Edit/Save buttons follow the editor's
    /// state). Safe to call from any thread.
    private func refreshRow(for item: QueueItem?) {
        guard let item = item else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let index = self.queue.index(of: item)
            guard index >= 0 else { return }
            self.table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        }
    }

    // MARK: Per-row Edit / Info buttons

    private enum RowButtonKind {
        case edit, info

        var identifier: NSUserInterfaceItemIdentifier {
            return NSUserInterfaceItemIdentifier(rawValue: self == .edit ? "queueRowEditButton" : "queueRowInfoButton")
        }

        var title: String {
            return self == .edit ? NSLocalizedString("Edit", comment: "") : NSLocalizedString("Info", comment: "")
        }

        var symbol: String {
            return self == .edit ? "pencil.circle.fill" : "info.circle.fill"
        }

        var tint: NSColor {
            return self == .edit ? .systemBlue : .systemGray
        }
    }

    @objc private func editRowButtonClicked(_ sender: NSButton) {
        let index = table.row(for: sender)
        guard index >= 0, let item = queue.item(at: index) else { return }
        edit(item: item)
    }

    private func rowButton(_ kind: RowButtonKind, in cell: NSTableCellView) -> NSButton {
        if let existing = cell.subviews.first(where: { $0.identifier == kind.identifier }) as? NSButton {
            return existing
        }

        let button = NSButton(frame: .zero)
        button.identifier = kind.identifier
        button.target = self
        button.action = kind == .edit ? #selector(editRowButtonClicked(_:)) : #selector(toggleItemsOptions(_:))
        button.bezelStyle = .inline
        button.isBordered = true
        button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setAccessibilityLabel(kind.title)

        if #available(macOS 11, *), let image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title) {
            button.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)) ?? image
        }
        if #available(macOS 10.14, *) {
            button.contentTintColor = kind.tint
        }

        cell.addSubview(button)
        return button
    }

    /// Icon only / icon and text / text only, following the same choice
    /// the Queue window's toolbar is set to (right-click it > Icon Only,
    /// Icon and Text, Text Only), so the row buttons match the toolbar.
    private func applyToolbarDisplayMode(to button: NSButton, kind: RowButtonKind) {
        let mode = window?.toolbar?.displayMode ?? .default
        let hasImage = button.image != nil
        let showImage = hasImage && mode != .labelOnly
        let showTitle = mode != .iconOnly || hasImage == false

        button.title = showTitle ? kind.title : ""
        button.imagePosition = showImage ? (showTitle ? .imageLeading : .imageOnly) : .noImage
    }

    private static let textWithEditID = "queueRowTextWithEdit"
    private static let textWithInfoID = "queueRowTextWithInfo"
    private static let textFullID = "queueRowTextFull"

    /// Info (and, for a completed item, Edit) buttons pinned to the right
    /// edge of the row. The cell comes from Queue.xib with fixed frames,
    /// so the name field is switched to Auto Layout here: it runs from the
    /// icon to the leftmost visible button and truncates in the middle.
    /// Edit reopens the finished file for review; once it is open, Edit
    /// greys out until that editor window closes.
    private func configureRowButtons(in cell: NSTableCellView, item: QueueItem?) {
        let infoButton = rowButton(.info, in: cell)
        let editButton = rowButton(.edit, in: cell)

        // The xib's own (fixed-frame, icon-only) info button is replaced
        // by the labelled one above.
        for case let legacy as NSButton in cell.subviews
        where legacy.action == #selector(toggleItemsOptions(_:)) && legacy.identifier != RowButtonKind.info.identifier {
            legacy.isHidden = true
        }

        if let textField = cell.textField,
           cell.constraints.contains(where: { $0.identifier == QueueController.textFullID }) == false {
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
            textField.setContentHuggingPriority(NSLayoutConstraint.Priority(250), for: .horizontal)

            let withEdit = textField.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -6)
            withEdit.identifier = QueueController.textWithEditID
            let withInfo = textField.trailingAnchor.constraint(equalTo: infoButton.leadingAnchor, constant: -6)
            withInfo.identifier = QueueController.textWithInfoID
            let full = textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8)
            full.identifier = QueueController.textFullID

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 29),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                infoButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
                infoButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                editButton.trailingAnchor.constraint(equalTo: infoButton.leadingAnchor, constant: -4),
                editButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            // All three stay installed; which one is in force is chosen
            // per row below by raising one's priority above the others'.
            for constraint in [withEdit, withInfo, full] {
                constraint.priority = NSLayoutConstraint.Priority(1)
            }
            NSLayoutConstraint.activate([withEdit, withInfo, full])
        }

        let editor = item.flatMap { openEditors[ObjectIdentifier($0)] }
        let showInfo = item != nil
        let showEdit = item != nil && (item?.status == .completed || editor != nil)

        infoButton.isHidden = !showInfo
        editButton.isHidden = !showEdit

        let variants: [(String, Bool)] = [(QueueController.textWithEditID, showEdit),
                                           (QueueController.textWithInfoID, showInfo && !showEdit),
                                           (QueueController.textFullID, !showInfo)]
        for (identifier, active) in variants {
            cell.constraints.first(where: { $0.identifier == identifier })?.priority = NSLayoutConstraint.Priority(active ? 999 : 1)
        }

        applyToolbarDisplayMode(to: infoButton, kind: .info)
        applyToolbarDisplayMode(to: editButton, kind: .edit)

        infoButton.toolTip = NSLocalizedString("Show the details and actions for this file", comment: "")
        editButton.isEnabled = editor == nil && item?.status == .completed
        editButton.toolTip = editor == nil
            ? NSLocalizedString("Open this file in an editor to review or change its metadata", comment: "")
            : NSLocalizedString("This file is already open in an editor", comment: "")
    }

    /// The Queue toolbar's display mode can be changed at any time from
    /// its context menu, and nothing notifies us -- so notice it on the
    /// window's next update and refresh the visible rows' buttons.
    private var lastToolbarDisplayMode: NSToolbar.DisplayMode?

    /// The latest "Working on ..." text from the queue, kept so the status
    /// line can be redrawn when the toolbar's display mode changes.
    private var progressStatusText = ""

    /// While the queue runs, the bottom status area follows the toolbar's
    /// display mode: Icon Only shows just the progress bar, Text Only just
    /// the percentage (appended to the status text), Icon and Text both.
    private func refreshProgressDisplay() {
        guard queue.status == .working else { return }

        let mode = window?.toolbar?.displayMode ?? .default
        progressBar.isHidden = mode == .labelOnly

        if mode != .iconOnly && progressBar.isIndeterminate == false {
            let percent = Int(min(max(progressBar.doubleValue, 0), 100).rounded())
            statusLabel.stringValue = "\(progressStatusText) \(percent)%"
        } else {
            statusLabel.stringValue = progressStatusText
        }
    }

    func windowDidUpdate(_ notification: Notification) {
        guard let mode = window?.toolbar?.displayMode, mode != lastToolbarDisplayMode else { return }
        lastToolbarDisplayMode = mode
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let table = self.table else { return }
            self.refreshProgressDisplay()
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                             columnIndexes: IndexSet(integer: 0))
        }
    }

    /// Keeps the single name column as wide as the table, so the buttons
    /// stay at the window's right edge when it is widened.
    func windowDidResize(_ notification: Notification) {
        table?.sizeLastColumnToFit()
    }

    // MARK: Intake watching (Intake/Queue workflow section 4.1)

    private var intakeWatchers: [IntakeFolderWatcher] = []
    private var intakeTimer: Timer?
    private var intakeConfiguration = ""
    private var intakeScanWorkItem: DispatchWorkItem?
    private var intakeScanInProgress = false

    /// For AppRestarter: a Media Intake scan is walking the Incoming folders.
    var isIntakeScanRunning: Bool { intakeScanInProgress }

    /// Manual merges started with the Merge toolbar button (not tied to a
    /// release row, so they are counted here instead).
    private var manualMergesRunning = 0

    /// For AppRestarter: merges currently writing a file -- releases in the
    /// .merging stage plus manual merges.
    var mergesInProgress: Int {
        return queue.indexesOfRows(where: { $0.release?.stage == .merging }).count + manualMergesRunning
    }
    private var intakeObservations: [String: (signature: String, since: Date)] = [:]
    private var intakeDefaultsObserver: NSObjectProtocol?

    private static let ingestedPathsKey = "SBMediaIntakeIngestedPaths"

    /// Turns "Automatically watch these folders for new files" (Media Intake
    /// settings) into action: every Incoming Folder is watched for changes
    /// and re-scanned every few seconds; whatever has stopped changing is
    /// added to the Queue as a release for naming review, or approved
    /// straight away when auto-approve is on and the match is confident.
    /// Re-reads the settings whenever they change.
    private func startIntakeWatching() {
        intakeDefaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reconfigureIntakeWatching()
        }
        reconfigureIntakeWatching()
    }

    private func reconfigureIntakeWatching() {
        let folders = MediaIntakePrefs.intakeFolders
        let enabled = MediaIntakePrefs.autoWatchIntakeFolder && folders.isEmpty == false
        let configuration = enabled ? folders.map { $0.path }.joined(separator: "\n") : ""

        guard configuration != intakeConfiguration else { return }
        intakeConfiguration = configuration

        intakeWatchers.forEach { $0.stop() }
        intakeWatchers.removeAll()
        intakeTimer?.invalidate()
        intakeTimer = nil
        intakeScanWorkItem?.cancel()
        intakeObservations.removeAll()

        guard enabled else { return }

        for folder in folders {
            if let watcher = IntakeFolderWatcher(url: folder, callback: { [weak self] in self?.scheduleIntakeScan(after: 3) }) {
                watcher.start()
                intakeWatchers.append(watcher)
            }
        }

        // The timer also covers a folder that appears later, a missed
        // file-system event, and a copy that is still settling.
        intakeTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.scanIntakeFolders()
        }
        scheduleIntakeScan(after: 3)
    }

    private func scheduleIntakeScan(after delay: TimeInterval) {
        intakeScanWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.scanIntakeFolders() }
        intakeScanWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// "Scan Now" in the Media Intake settings: looks at the Incoming Folders
    /// right away, even when automatic watching is off, and brings in
    /// everything found without waiting for it to settle. Calls back on the
    /// main thread with how many items (movie releases and TV files or
    /// folders) were added.
    func scanIntakeFoldersNow(completion: @escaping (Int) -> Void) {
        if isTVShowQueue {
            QueueController.shared.scanIntakeFoldersNow(completion: completion)
        } else {
            scanIntakeFolders(force: true, completion: completion)
        }
    }

    private func scanIntakeFolders(force: Bool = false, completion: ((Int) -> Void)? = nil) {
        guard force || MediaIntakePrefs.autoWatchIntakeFolder else {
            completion?(0)
            return
        }

        guard intakeScanInProgress == false else {
            if force {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.scanIntakeFolders(force: true, completion: completion)
                }
            }
            return
        }

        let roots = MediaIntakePrefs.intakeFolders
        guard roots.isEmpty == false else {
            completion?(0)
            return
        }

        let excluded = MediaIntakePrefs.allDeliveryFolders
        intakeScanInProgress = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = IntakeScanner.candidates(in: roots, excluding: excluded)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.intakeScanInProgress = false
                let added = self.processIntakeCandidates(found, force: force)
                completion?(added)
            }
        }
    }

    private var ingestedIntakePaths: Set<String> {
        return Set(UserDefaults.standard.stringArray(forKey: QueueController.ingestedPathsKey) ?? [])
    }

    /// Drops remembered paths whose file or folder is gone while the folder
    /// that held it is still there -- so a file with the same name put back
    /// into an Incoming Folder later (a re-download, or one moved back for
    /// another pass) is treated as new instead of being skipped for good.
    /// A path whose parent folder is missing too (an unmounted drive) is
    /// kept.
    private func forgetMissingIngestedPaths() {
        let fileManager = FileManager.default
        let list = UserDefaults.standard.stringArray(forKey: QueueController.ingestedPathsKey) ?? []
        let kept = list.filter { path in
            if fileManager.fileExists(atPath: path) { return true }
            let parent = (path as NSString).deletingLastPathComponent
            return fileManager.fileExists(atPath: parent) == false
        }
        if kept.count != list.count {
            UserDefaults.standard.set(kept, forKey: QueueController.ingestedPathsKey)
        }
    }

    /// Remembers a path that has been brought into the Queue, so removing
    /// its row later doesn't make the watcher add it again.
    private func rememberIngested(_ path: String) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var list = UserDefaults.standard.stringArray(forKey: QueueController.ingestedPathsKey) ?? []
        guard list.contains(standardized) == false else { return }
        list.append(standardized)
        if list.count > 2000 {
            list.removeFirst(list.count - 2000)
        }
        UserDefaults.standard.set(list, forKey: QueueController.ingestedPathsKey)
    }

    /// Every file and folder path this queue's rows already point at.
    private func referencedPaths() -> Set<String> {
        var paths = Set<String>()
        for index in 0..<queue.count {
            let row = queue.row(at: index)
            if let release = row.release {
                paths.insert(release.folderURL.standardizedFileURL.path)
                release.sourceFileURLs.forEach { paths.insert($0.standardizedFileURL.path) }
            }
            if let item = row.effectiveItem {
                paths.insert(item.fileURL.standardizedFileURL.path)
                paths.insert(item.destURL.standardizedFileURL.path)
                if let folder = item.sourceFolderURL {
                    paths.insert(folder.standardizedFileURL.path)
                }
            }
        }
        return paths
    }

    /// An episode file name (S01E02, 1x02, ...) marks a candidate as a TV
    /// show; those go to the TV Show Queue instead.
    private static func isTVShow(_ candidate: IntakeScanner.Candidate) -> Bool {
        return candidate.files.contains { ReleaseFilenameParser.parse($0.lastPathComponent)?.season != nil }
    }

    /// Returns how many items were added. With `force` (Scan Now) nothing
    /// waits for its files to settle.
    @discardableResult
    private func processIntakeCandidates(_ found: [IntakeScanner.Candidate], force: Bool = false) -> Int {
        guard force || MediaIntakePrefs.autoWatchIntakeFolder else { return 0 }

        forgetMissingIngestedPaths()

        let now = Date()
        let queued = QueueController.shared.referencedPaths().union(QueueController.tvShows.referencedPaths())
        let ingested = ingestedIntakePaths

        var live = Set<String>()
        var settling = false
        var addedReleases: [QueueRelease] = []
        var addedTVShows = 0

        for candidate in found {
            let key = candidate.key
            if ingested.contains(key) || queued.contains(key) { continue }
            if candidate.files.contains(where: { queued.contains($0.standardizedFileURL.path) }) { continue }

            live.insert(key)

            if force == false {
                if let seen = intakeObservations[key], seen.signature == candidate.signature {
                    if now.timeIntervalSince(seen.since) < IntakeScanner.settleSeconds {
                        settling = true
                        continue
                    }
                } else {
                    intakeObservations[key] = (candidate.signature, now)
                    settling = true
                    continue
                }
            }

            if QueueController.isTVShow(candidate) {
                ingestTVShowCandidate(candidate)
                addedTVShows += 1
            } else if let release = ingestIntakeCandidate(candidate) {
                addedReleases.append(release)
            }
        }

        intakeObservations = intakeObservations.filter { live.contains($0.key) }

        if settling {
            scheduleIntakeScan(after: IntakeScanner.settleSeconds + 1)
        }

        if addedReleases.isEmpty == false, queue.status != .working {
            statusLabel.stringValue = String.localizedStringWithFormat(NSLocalizedString("Added %lu new item(s) from the Incoming Folder.", comment: "Queue -> intake watcher"), addedReleases.count)
        }
        for release in addedReleases {
            attemptAutoApproveNaming(for: release)
        }

        return addedReleases.count + addedTVShows
    }

    /// Hands a TV episode file (or a folder of them) to the TV Show Queue
    /// as ordinary queue items, and brings that window forward.
    private func ingestTVShowCandidate(_ candidate: IntakeScanner.Candidate) {
        rememberIngested(candidate.key)
        candidate.files.forEach { rememberIngested($0.path) }

        let tvQueue = QueueController.tvShows
        tvQueue.insert(contentOf: [candidate.folder ?? candidate.files[0]], at: tvQueue.count)
        if tvQueue.window?.isVisible != true {
            tvQueue.window?.orderFront(nil)
        }
    }

    /// Brings one finished candidate into the Queue as a release. A loose
    /// file is first moved into a folder of its own (named after the file),
    /// since a release is renamed and moved as a folder.
    private func ingestIntakeCandidate(_ candidate: IntakeScanner.Candidate) -> QueueRelease? {
        let fileManager = FileManager.default
        let folder: URL

        if let existing = candidate.folder {
            folder = existing
        } else {
            let file = candidate.files[0]
            let wrapper = QueueController.uniqueFolderDestination(for: candidate.root.appendingPathComponent(file.deletingPathExtension().lastPathComponent))
            do {
                try fileManager.createDirectory(at: wrapper, withIntermediateDirectories: false)
                try fileManager.moveItem(at: file, to: wrapper.appendingPathComponent(file.lastPathComponent))
            } catch {
                try? fileManager.removeItem(at: wrapper)
                rememberIngested(candidate.key)
                return nil
            }
            folder = wrapper
        }

        rememberIngested(candidate.key)
        rememberIngested(folder.path)

        guard let release = makeRelease(contentOf: folder) else { return nil }
        insertRelease(release, at: count)
        return release
    }

    /// With "Automatically approve high-confidence naming matches" on, finds
    /// the release's name online without opening the review sheet, and
    /// approves it when the match is confident. Anything less certain stays
    /// in the Queue, waiting for a person to open it as usual.
    private func attemptAutoApproveNaming(for release: QueueRelease) {
        guard MediaIntakePrefs.autoApproveHighConfidenceNaming, release.stage == .pendingNaming else { return }

        let folderName = release.folderURL.lastPathComponent

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let query = NamingReviewWindowController.localQueryComponents(forFolderName: folderName)
            let match = NamingReviewWindowController.bestProviderMatch(title: query.title, studio: query.studio, year: query.year)

            DispatchQueue.main.async {
                guard let self = self,
                      release.stage == .pendingNaming,
                      self.queue.indexesOfRows(where: { $0.release === release }).isEmpty == false,
                      let match = match, match.highConfidence
                else { return }

                self.approveNaming(for: release, name: match.name)
            }
        }
    }

    //MARK: Items creation

    private func destination(for url: URL) -> URL {
        let value = try? url.resourceValues(forKeys: [URLResourceKey.typeIdentifierKey])

        if let destination = prefs.destination {
            return destination.appendingPathComponent(url.lastPathComponent).deletingPathExtension().appendingPathExtension(prefs.fileType)
        } else if let type = value?.typeIdentifier, UTTypeConformsTo(type as CFString, "public.mpeg-4" as CFString) {
            return url
        } else {
            return url.deletingPathExtension().appendingPathExtension(prefs.fileType)
        }
    }

    /// Creates a new QueueItem from an NSURL,
    /// and adds the current actions to it. sourceFolderURL is passed
    /// through untouched to QueueItem -- see that property's own doc
    /// comment -- for items created via insertFolder(_:at:) below.
    private func createItem(url: URL, sourceFolderURL: URL? = nil) -> QueueItem {

        // A file already sitting in the staging folder (or another delivery
        // destination) is scanned and tagged where it is -- no second copy.
        let editInPlace = MediaIntakePrefs.shouldEditInPlace(url)
        let destURL = editInPlace ? url : destination(for: url)
        let item = QueueItem(fileURL: url, destination: destURL, sourceFolderURL: sourceFolderURL)

        if prefs.clearExistingMetadata {
            item.addAction(QueueClearExistingMetadataAction())
        }
        if prefs.searchMetadata {
            item.addAction(QueueMetadataAction(movieLanguage: prefs.movieProviderLanguage,tvShowLanguage: prefs.tvShowProviderLanguage, movieProvider: prefs.movieProvider, tvShowProvider: prefs.tvShowProvider, preferredArtwork: prefs.providerArtwork, preferredArtworkSize: prefs.providerArtworkSize))
        }
        if prefs.setOutputFilename {
            item.addAction(QueueSetOutputFilenameAction())
        }
        if prefs.subtitles {
            item.addAction(QueueSubtitlesAction())
        }
        if prefs.organize {
            item.addAction(QueueOrganizeGroupsAction())
        }
        if prefs.fixFallbacks {
            item.addAction(QueueFixFallbacksAction())
        }
        if prefs.clearTrackName {
            item.addAction(QueueClearTrackNameAction())
        }
        if prefs.prettifyAudioTrackName {
            item.addAction(QueuePrettifyAudioTrackNameAction())
        }
        if prefs.renameChapters {
            item.addAction(QueueRenameChaptersAction())
        }
        if prefs.fixTrackLanguage {
            item.addAction(QueueSetLanguageAction(language: prefs.fixTrackLanguageValue))
        }
        if prefs.applyColorSpace, let tag = QueueColorSpaceActionTag(rawValue: UInt16(prefs.applyColorSpaceValue)) {
            item.addAction(QueueColorSpaceAction(tag: tag))
        }
        if let set = prefs.metadataSet {
            item.addAction(QueueSetAction(preset: set))
        }
        if prefs.optimize {
            item.addAction(QueueOptimizeAction())
        }
        if prefs.sendToiTunes {
            item.addAction(QueueSendToiTunesAction())
        }
 //MARK: Change Selected Tracks by Language
        if prefs.changeAudioLanguage {
            item.addAction(QueueChangeAudioLanguageAction(language: prefs.changeAudioLanguageValue))
        }
        if prefs.changeSubtitleLanguage {
            item.addAction(QueueChangeSubtitleLanguageAction(language: prefs.changeSubtitleLanguageValue))
        }
        // Added last so it runs after every other post action: once the
        // output is written, a file sitting anywhere outside Ready for
        // Media Library gets a folder of its own there, whether or not it
        // had a parent folder to begin with.
        if editInPlace {
            if prefs.setOutputFilename {
                item.addAction(QueueRenameInPlaceAction())
            }
        } else if let readyForLibraryFolder = MediaIntakePrefs.fallbackDeliveryFolder {
            item.addAction(QueueMoveFileToLibraryAction(destinationRoot: readyForLibraryFolder))
        }
        return item
    }

    //MARK: Queue management

    private var scripts: [NSScriptCommand] = []

    func add(script: NSScriptCommand) {
        scripts.append(script)
    }

    var status: Queue.Status {
        get {
            return queue.status
        }
    }

    var count: Int {
        get {
            return queue.count
        }
    }

    func items(at indexes: IndexSet) -> [QueueItem] {
        return queue.items(at: indexes)
    }

    /// Adds a QueueItem to the queue
    func add(_ item: QueueItem) {
        insert(items: [item], at: IndexSet(integer: IndexSet.Element(queue.count)))
    }

    func add(_ item: QueueItem, applyPreset: Bool) {
        // Edit window's "Add to Queue" for a file that already exists on
        // disk. Previously only Optimize was applied here, so the Queue's
        // "Set output filename" option (name + movie/TV folder, incl.
        // Ready for Media Library) was silently skipped for single-file
        // edits -- no folder was ever created. Same action, same pref,
        // as createItem(url:) uses for files added straight to the Queue.
        if prefs.setOutputFilename {
            item.addAction(QueueSetOutputFilenameAction())
        }
        if prefs.optimize {
            item.addAction(QueueOptimizeAction())
        }
        // A file already in the staging folder is tagged and renamed where it
        // is (QueueSetOutputFilenameAction leaves its destination alone).
        if prefs.setOutputFilename, MediaIntakePrefs.shouldEditInPlace(item.fileURL) {
            item.addAction(QueueRenameInPlaceAction())
        }
        add(item)
    }

    private func add(_ items: [QueueItem], at index: Int) {
        let indexes = IndexSet(integersIn: index ..< (index + items.count))
        insert(items: items, at: indexes)
    }

    /// Adds an array of QueueItem to the queue -- the plain manually-queued-
    /// file path (AppleScript, "File > Add to Queue", dragging files
    /// straight in). Implements the undo manager. See insertRelease(_:at:)
    /// for the Intake/Queue workflow's own release rows.
    func insert(items: [QueueItem], at indexes: IndexSet) {
        insertRows(items.map { QueueRow(item: $0) }, at: indexes)
    }

    /// Wraps a QueueRelease in a `.release` row and inserts it into the
    /// queue -- the counterpart to insert(items:at:)/insert(contentOf:at:)
    /// for the Intake/Queue workflow's own multi-file releases. Not wired
    /// to any real UI yet; reachable for now only through the temporary
    /// "Add Test Release (Debug)…" entry point in AppDelegate until the
    /// intake watcher and naming/merge windows are built in later phases.
    func insertRelease(_ release: QueueRelease, at index: Int) {
        insertRows([QueueRow(release: release)], at: IndexSet(integer: index))
    }

    /// Common insertion path behind both of the above -- identical to the
    /// old row-oblivious insert(items:at:) except it takes QueueRow
    /// instead of assuming every inserted row already wraps a QueueItem.
    /// suppressAutoStart lets insertFolder(_:at:) below opt a folder
    /// batch out of QueuePreferences.autoStart -- see that call site's
    /// own comment for why.
    private func insertRows(_ rows: [QueueRow], at indexes: IndexSet, suppressAutoStart: Bool = false) {
        if rows.isEmpty { return }
        guard let firstIndex = indexes.first else { fatalError() }

        table.beginUpdates()

        // Forward
        var currentIndex = firstIndex
        var currentObjectIndex = 0

        while currentIndex != NSNotFound {
            queue.insert(rows[currentObjectIndex], at: currentIndex)
            currentIndex = indexes.integerGreaterThan(currentIndex) ?? NSNotFound
            currentObjectIndex += 1
        }

        table.insertRows(at: indexes, withAnimation: .slideDown)
        table.endUpdates()
        updateState()

        guard let undo = window?.undoManager else { return }

        undo.registerUndo(withTarget: self) { (target) in
            self.removeRows(at: indexes)
        }

        if undo.isUndoing == false {
            undo.setActionName(NSLocalizedString("Add Queue Item", comment: "Queue -> redo add item."))
        }

        if !(undo.isUndoing || undo.isRedoing) {
            if prefs.autoStart && suppressAutoStart == false {
                start(self)
            }
        }
    }

    private func remove(at index: Int) {
        remove(at: IndexSet(integer: IndexSet.Element(index)))
    }

    func remove(at indexes: IndexSet) {
        removeRows(at: indexes)
    }

    /// `indexes`, plus the index of any folder header row (see
    /// insertFolder(_:at:)) whose child file rows would all be gone once
    /// `indexes` are removed -- so removing (or Edit-ing) a folder's last
    /// file doesn't leave its header row sitting alone in the Queue.
    private func indexesIncludingOrphanedFolderHeaders(_ indexes: IndexSet) -> IndexSet {
        var result = indexes
        let count = queue.count
        var i = 0
        while i < count {
            if queue.row(at: i).folderHeaderURL != nil {
                var childIndexes: [Int] = []
                var j = i + 1
                while j < count, queue.row(at: j).folderHeaderURL == nil, queue.row(at: j).item?.sourceFolderURL != nil {
                    childIndexes.append(j)
                    j += 1
                }
                if childIndexes.isEmpty == false, childIndexes.allSatisfy({ indexes.contains($0) }) {
                    result.insert(i)
                }
                i = j
            } else {
                i += 1
            }
        }
        return result
    }

    private func removeRows(at requestedIndexes: IndexSet) {
        if requestedIndexes.isEmpty {
            return
        }

        let indexes = indexesIncludingOrphanedFolderHeaders(requestedIndexes)

        table.beginUpdates()

        let removedRows = queue.rows(at: indexes)

        if queue.count > indexes.last! {
            queue.remove(at: indexes)
        }

        table.removeRows(at: indexes, withAnimation: .slideUp)
        if let index = indexes.first, index < queue.count {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }

        table.endUpdates()
        updateState()

        guard let undo = window?.undoManager else { return }

        undo.registerUndo(withTarget: self) { (target) in
            self.insertRows(removedRows, at: indexes)
        }

        if undo.isUndoing == false {
            undo.setActionName(NSLocalizedString("Remove Queue Item", comment: "Queue -> redo add item."))
        }
    }

    private func move(rows: [QueueRow], at index: Int) {
        var currentIndex = index
        var source: [Int] = []
        var dest: [Int] = []

        table.beginUpdates()

        for row in rows.reversed() {
            let sourceIndex = queue.index(of: row)
            queue.remove(at: IndexSet(integer: sourceIndex))

            if sourceIndex < currentIndex {
                currentIndex -= 1
            }

            queue.insert(row, at: currentIndex)

            source.append(currentIndex)
            dest.append(sourceIndex)

            table.moveRow(at: sourceIndex, to: currentIndex)
        }

        table.endUpdates()

        guard let undo = window?.undoManager else { return }

        undo.registerUndo(withTarget: self) { (target) in
            self.move(at: source, to: dest)
        }

        if undo.isUndoing == false {
            undo.setActionName(NSLocalizedString("Move Queue Item", comment: "Queue -> move add item."))
        }
    }

    private func move(at source: [Int], to dest: [Int]) {
        var newSource: [Int] = []
        var newDest: [Int] = []

        table.beginUpdates()

        for (sourceIndex, destIndex) in zip(source, dest).reversed() {
            newSource.append(destIndex)
            newDest.append(sourceIndex)

            if let row = queue.rows(at: IndexSet(integer: sourceIndex)).first {
                queue.remove(at: IndexSet(integer: sourceIndex))
                queue.insert(row, at: destIndex)

                table.moveRow(at: sourceIndex, to: destIndex)
            }
        }

        table.endUpdates()

        guard let undo = window?.undoManager else { return }

        undo.registerUndo(withTarget: self) { (target) in
            self.move(at: newSource, to: newDest)
        }

        if undo.isUndoing == false {
            undo.setActionName(NSLocalizedString("Move Queue Item", comment: "Queue -> move add item."))
        }
    }

    private func items(contentOf url: URL) -> [QueueItem] {
        var items: [QueueItem] = []
        let supportedFileFormats = MP42FileImporter.supportedFileFormats()

        let value = try? url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])

        if let isDirectory = value?.isDirectory, isDirectory == true,
            let directoryEnumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [URLResourceKey.nameKey, URLResourceKey.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: nil) {

            for case let fileURL as URL in directoryEnumerator {
                let fileValue = try? fileURL.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
                if fileValue?.isDirectory != true, supportedFileFormats.contains(fileURL.pathExtension.lowercased()) {
                    items.append(createItem(url: fileURL))
                }
            }
            items.sort { return $0.fileURL.lastPathComponent.localizedStandardCompare($1.fileURL.lastPathComponent) == ComparisonResult.orderedAscending }
        } else if supportedFileFormats.contains(url.pathExtension.lowercased()) {
            items.append(createItem(url: url))
        }

        return items
    }

    func insert(contentOf urls: [URL], at index: Int) {
        let sorted = urls.sorted(by: { return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == ComparisonResult.orderedAscending })
        let result = sorted.flatMap { items(contentOf: $0) }
        add(result, at: index)
    }

    /// Adds files and folders the way the Add button does: each folder
    /// becomes its own grouped section (header row + its files, see
    /// insertFolder(_:at:)), and a plain file becomes a single ungrouped
    /// row. Used by the Add panel, Finder drag-and-drop, and File > Open
    /// of a folder so all of them behave identically.
    func insertGrouped(_ urls: [URL], at index: Int) {
        let sortedURLs = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == ComparisonResult.orderedAscending }
        var insertionIndex = min(max(index, 0), queue.count)

        for url in sortedURLs {
            let isDirectory = (try? url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey]))?.isDirectory ?? false
            let countBefore = queue.count
            if isDirectory {
                insertFolder(url, at: insertionIndex)
            } else {
                insert(contentOf: [url], at: insertionIndex)
            }
            insertionIndex += queue.count - countBefore
        }
    }

    /// Direct children of folderURL (same non-recursive convention as
    /// makeRelease(contentOf:)) that are in a format this app can queue,
    /// each tagged with sourceFolderURL so its row renders indented under
    /// folderURL's own header row -- see insertFolder(_:at:) below.
    private func items(contentOfFolder folderURL: URL) -> [QueueItem] {
        let supportedFileFormats = MP42FileImporter.supportedFileFormats()

        guard let directoryEnumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [URLResourceKey.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: nil) else {
            return []
        }

        var items: [QueueItem] = []
        for case let fileURL as URL in directoryEnumerator {
            let value = try? fileURL.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
            if value?.isDirectory != true, supportedFileFormats.contains(fileURL.pathExtension.lowercased()) {
                items.append(createItem(url: fileURL, sourceFolderURL: folderURL))
            }
        }
        items.sort { return $0.fileURL.lastPathComponent.localizedStandardCompare($1.fileURL.lastPathComponent) == ComparisonResult.orderedAscending }
        return items
    }

    /// Inserts folderURL's queueable files as a group: a non-processable
    /// header row naming the folder (QueueRow(folderHeaderURL:)), followed
    /// immediately by one ordinary, independently-processable QueueItem
    /// row per file -- unlike the Intake/Queue workflow's QueueRelease
    /// rows, these never go through naming review or a merge step; they're
    /// ready to process from the moment they're added, same as any other
    /// manually-queued file. Purely a readability grouping in the table --
    /// see tableView(_:viewFor:row:). A no-op if the folder has no
    /// queueable files directly inside it.
    func insertFolder(_ folderURL: URL, at index: Int) {
        let children = items(contentOfFolder: folderURL)
        guard children.isEmpty == false else { return }

        let rows = [QueueRow(folderHeaderURL: folderURL)] + children.map { QueueRow(item: $0) }

        // A folder's files are exactly the case mergeSelectedItems(_:)
        // exists for -- several related files that might need combining
        // before they're processed -- and merging only ever works on a
        // row that hasn't started yet (mergeCandidateRows(at:)). With
        // QueuePreferences.autoStart on, insertRows(_:at:)'s normal
        // "start the moment something's added" behavior used to win that
        // race every time: a folder's files went .ready -> .working ->
        // .completed before the user could even select them, silently
        // taking Merge off the table with no explanation. Folder batches
        // opt out of that automatic start so there's always a window to
        // merge first; a single file added any other way still
        // auto-starts exactly as before.
        insertRows(rows, at: IndexSet(integersIn: index ..< (index + rows.count)), suppressAutoStart: true)

        if prefs.autoStart {
            statusLabel.stringValue = String(format: NSLocalizedString("Added %d file(s) from \u{201C}%@\u{201D} \u{2014} merge if needed, then press Start", comment: "Queue -> folder add with Auto-Start on"), children.count, folderURL.lastPathComponent)
        }
    }

    /// Scans a folder for supported media files and builds a QueueRelease
    /// from them, for the Intake/Queue workflow -- as opposed to
    /// items(contentOf:) above, which flattens a folder into N independent
    /// QueueItems for the existing manual drag-and-drop path. Doesn't
    /// touch naming, metadata, or merging -- those are later phases (see
    /// the Intake/Queue workflow design doc kept in this project's notes).
    /// Returns nil if the folder has no supported media files directly
    /// inside it.
    func makeRelease(contentOf folderURL: URL) -> QueueRelease? {
        let supportedFileFormats = MP42FileImporter.supportedFileFormats()

        guard let directoryEnumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [URLResourceKey.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: nil) else {
            return nil
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in directoryEnumerator {
            let value = try? fileURL.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
            if value?.isDirectory != true, supportedFileFormats.contains(fileURL.pathExtension.lowercased()) {
                fileURLs.append(fileURL)
            }
        }
        fileURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == ComparisonResult.orderedAscending }

        guard fileURLs.isEmpty == false else { return nil }

        return QueueRelease(folderURL: folderURL, sourceFileURLs: fileURLs)
    }

    /// An existing row's release still parked at the same folder --
    /// discovered but not yet resolved to a mux-able item or actively
    /// merging -- if one exists. Backs addOrRefreshRelease(contentOf:) so
    /// re-picking the same source folder (the debug entry point's only
    /// way to retry a rejected/canceled release today -- see
    /// addTestReleaseDebug) refreshes that same row instead of piling up
    /// a second, abandoned-looking one for files that never moved.
    /// Matches on the release's current folderURL rather than
    /// sourceFileURLs, which can go stale the moment naming is approved
    /// and the folder gets renamed.
    private func parkedReleaseRow(for folderURL: URL) -> QueueRow? {
        let standardized = folderURL.standardizedFileURL
        let indexes = queue.indexesOfRows { row in
            guard let release = row.release else { return false }
            switch release.stage {
            case .pendingNaming, .namingRejected, .pendingMetadata, .pendingMergeSelection, .mergeFailed:
                return release.folderURL.standardizedFileURL == standardized
            case .merging, .pendingLibraryMove, .done:
                return false
            }
        }
        guard let index = indexes.first else { return nil }
        return queue.row(at: index)
    }

    /// Scans folderURL and either inserts a new release row for it, or --
    /// when a prior attempt at this exact folder is still sitting
    /// unresolved in the queue (rejected naming, a canceled/failed merge
    /// selection) -- refreshes that same row in place instead. Without
    /// this, cancelling out of naming review or merge selection and then
    /// re-picking the same folder to try again left the old, abandoned
    /// row behind every time, so retrying a few times during testing
    /// quietly piled up duplicate rows for files that never actually
    /// moved. Returns false (and inserts/updates nothing) if the folder
    /// has no supported media files, same as makeRelease(contentOf:).
    @discardableResult
    func addOrRefreshRelease(contentOf folderURL: URL) -> Bool {
        guard let release = makeRelease(contentOf: folderURL) else { return false }

        if let existingRow = parkedReleaseRow(for: folderURL), let existing = existingRow.release {
            existing.sourceFileURLs = release.sourceFileURLs
            existing.stage = .pendingNaming
            existing.suggestedName = nil
            existing.suggestedNameSource = nil
            existing.approvedName = nil
            existing.mergeOrder = nil
            existing.mergeErrorMessage = nil
            existing.mergeProgress = 0
            updateUI(indexes: IndexSet(integer: queue.index(of: existingRow)))
        } else {
            insertRelease(release, at: count)
        }

        return true
    }

    //MARK: Popover delegate

    /// Creates a popover with the queue options.
    private func createOptionsPopover() {
        if popover == nil {
            let p = NSPopover()
            p.contentViewController = OptionsViewController(options: prefs)
            p.animates = true
            p.behavior = NSPopover.Behavior.semitransient
            p.delegate = self

            popover = p
        }
    }

    /// Creates a popover with a QueueItem
    private func createItemPopover(_ item: QueueItem) {
        let p = NSPopover()

        let view = ItemViewController(item: item, delegate: self)
        p.contentViewController = view
        p.animates = true
        p.behavior = NSPopover.Behavior.semitransient
        p.delegate = self

        itemPopover = p
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        return popover == self.popover
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover
            else { return }

        if popover == closedPopover {
            popover = nil
            // Save the options as soon as they're closed rather than only
            // at quit (a force-quit or a stop from Xcode never gets there).
            prefs.saveUserDefaults()
        }
        if itemPopover == closedPopover {
            itemPopover = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
    }

    //MARK: UI

    /// Updates the count on the app dock icon.
    private static var dockCounts: [ObjectIdentifier: Int] = [:]

    private func updateDockTile() {
        let count = queue.readyCount + ((queue.status == .working) ? 1 : 0)

        // The movie and TV queues share the one dock badge.
        QueueController.dockCounts[ObjectIdentifier(self)] = count
        let total = QueueController.dockCounts.values.reduce(0, +)

        if total > 0 {
            NSApp.dockTile.badgeLabel = "\(total)"
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    private func updateUI(indexes: IndexSet) {
        table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0))
        updateState()
    }

    private func updateUI() {
        table.reloadData()
        updateState()
    }

    private func updateState() {
        if queue.status != .working {
            if queue.count == 1 {
                statusLabel.stringValue = NSLocalizedString("1 item in queue", comment: "")
            } else {
                statusLabel.stringValue = String.localizedStringWithFormat(NSLocalizedString("%lu items in queue.", comment: ""), queue.count)
            }
        }
        updateDockTile()
    }

    @IBAction func start(_ sender: Any?) {
        if queue.status == .working {
            return
        }

        if let toolbar = self.window?.toolbar {
            self.toolbarDelegate.setState(working: true, toolbar: toolbar)
        }
        statusLabel.stringValue = NSLocalizedString("Working.", comment: "Queue -> Working")
        progressBar.isHidden = (window?.toolbar?.displayMode ?? .default) == .labelOnly
        progressBar.startAnimation(self)

        window?.undoManager?.removeAllActions(withTarget: self)

        queue.start()
    }

    @IBAction func stop(_ sender: Any?) {
        queue.stop()
    }

    @IBAction func toggleStartStop(_ sender: Any?) {
        if queue.status == .working {
            stop(self)
        } else {
            start(self)
        }
    }

    @IBAction func toggleOptions(_ sender: Any?) {
        guard let window = self.window else { return }
        createOptionsPopover()

        if let p = popover, p.isShown == false {
            let toolbarItem = window.toolbar?.visibleItems?.first(where: { $0.itemIdentifier == .queueSettings })
            let target = ((toolbarItem?.view?.window) != nil) ? toolbarItem?.view : window.contentView

            if #available(macOS 14, *) {
                if let toolbarItem, let toolbar = window.toolbar, toolbar.isVisible == true {
                    p.show(relativeTo: toolbarItem)
                } else if let target {
                    p.show(relativeTo: target.bounds, of: target, preferredEdge: .maxY)
                }
            } else if let target {
                p.show(relativeTo: target.bounds, of: target, preferredEdge: .maxY)
            }
        } else {
            popover?.close()
            popover = nil
        }
    }

    @IBAction func toggleItemsOptions(_ sender: Any?) {
        guard let sender = sender as? NSView else { return }
        let index = table.row(for: sender)
        guard let item = queue.item(at: index) else { return }

        if let p = itemPopover, p.isShown, let controller = p.contentViewController as? ItemViewController, controller.item == item {
            p.close()
            itemPopover = nil
        } else {
            createItemPopover(item)
            itemPopover?.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
        }
    }

    //MARK: Open

    @IBAction func open(_ sender: Any?) {
        guard let windowForSheet = window else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedFileTypes = MP42FileImporter.supportedFileFormats()

        panel.beginSheetModal(for: windowForSheet) { (response) in
            guard response == NSApplication.ModalResponse.OK else { return }

            // Folders become grouped sections, plain files single rows --
            // the same handling as a Finder drop (insertGrouped).
            self.insertGrouped(panel.urls, at: self.queue.count)
        }
    }

    //MARK: Table View

    func numberOfRows(in tableView: NSTableView) -> Int {
        return queue.count
    }

    private let nameColumn = NSUserInterfaceItemIdentifier(rawValue: "nameColumn")

    private func image(for status: QueueItem.Status) -> NSImage? {
        switch status {
        case .editing:
            return NSImage(named: "EncodeWorking")
        case .working:
            return NSImage(named: "EncodeWorking")
        case .completed:
            return NSImage(named: "EncodeComplete")
        case .failed:
            return NSImage(named: "EncodeCanceled")
        case .cancelled:
            return NSImage(named: "EncodeCanceled")
        case .ready:
            return docImg
        }
    }

    /// Icon for a release row that hasn't resolved to a QueueItem yet.
    /// Reuses the existing status icons as a minimal-diff placeholder --
    /// the "waiting on the next automatic step" stages (pendingMetadata,
    /// pendingLibraryMove) and the "waiting on the user" stages
    /// (pendingNaming, pendingMergeSelection) both just get the default
    /// doc icon for now; a later pass can give the user-facing ones their
    /// own distinct icon.
    private func image(for stage: QueueRelease.Stage) -> NSImage? {
        switch stage {
        case .pendingNaming, .pendingMetadata, .pendingMergeSelection, .pendingLibraryMove:
            return docImg
        case .merging:
            return NSImage(named: "EncodeWorking")
        case .namingRejected, .mergeFailed:
            return NSImage(named: "EncodeCanceled")
        case .done:
            return NSImage(named: "EncodeComplete")
        }
    }

    /// Leading indent for a row whose file was added as part of a folder
    /// group, so it reads as nested under that folder's header row right
    /// above it (QueueController.insertFolder(_:at:)) -- plain spaces
    /// rather than an indentationLevel/constraint change since this is an
    /// NSTableView, not an NSOutlineView, and every other row kind here
    /// has no such hierarchy to indicate.
    private static let folderChildIndent = "      "

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableColumn?.identifier == nameColumn {
            let queueRow = queue.row(at: row)
            let cell = tableView.makeView(withIdentifier: nameColumn, owner: self) as? NSTableCellView

            // Cells are reused across rows of every kind, so every branch
            // below sets its own font explicitly rather than relying on
            // whatever a previously-recycled row last left it as.
            if let folderHeaderURL = queueRow.folderHeaderURL {
                // The group label for the item rows right after it.
                cell?.textField?.stringValue = folderHeaderURL.lastPathComponent
                cell?.textField?.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                cell?.imageView?.image = NSWorkspace.shared.icon(forFile: folderHeaderURL.path)
            } else if let item = queueRow.effectiveItem {
                // A plain item, or a release that has resolved to a real
                // mux job -- today's logic, unchanged either way, plus the
                // new indent when the item came from a folder group.
                let indent = item.sourceFolderURL != nil ? QueueController.folderChildIndent : ""
                cell?.textField?.stringValue = indent + item.fileURL.lastPathComponent
                cell?.textField?.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                cell?.imageView?.image = image(for: item.status)
            } else if let release = queueRow.release {
                // A release still in a pre-mux stage -- name and icon
                // come from the release itself, not a QueueItem.
                cell?.textField?.stringValue = release.approvedName ?? release.folderURL.lastPathComponent
                cell?.textField?.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                cell?.imageView?.image = image(for: release.stage)
            }

            if let cell = cell {
                configureRowButtons(in: cell, item: queueRow.folderHeaderURL == nil ? queueRow.effectiveItem : nil)
            }
            return cell
        }
        return nil
    }

    /// Toolbar buttons only revalidate on their own -- window updates,
    /// focus changes -- which lags a click that only changed the table
    /// selection. Forcing it here is what makes the Merge button go
    /// active/grey the moment the second file is selected instead of on
    /// the next unrelated UI event.
    func tableViewSelectionDidChange(_ notification: Notification) {
        window?.toolbar?.validateVisibleItems()
    }

    func deleteSelection(in tableView: NSTableView) {
        var rowIndexes = tableView.selectedRowIndexes
        let clickedRow = tableView.clickedRow

        if clickedRow != -1 && rowIndexes.contains(clickedRow) == false {
            rowIndexes.removeAll()
            rowIndexes.insert(clickedRow)
        }

        let rows = queue.rows(at: rowIndexes)

        for row in rows where row.effectiveItem?.status == .working || row.release?.stage == .merging {
            rowIndexes.remove(IndexSet.Element(queue.index(of: row)))
        }

        if rowIndexes.isEmpty == false {
            remove(at: rowIndexes)
        }
    }

    @IBAction func edit(_ sender: Any?) {
        let clickedRow = table.clickedRow
        guard clickedRow > -1 else { return }

        let queueRow = queue.row(at: clickedRow)

        if let release = queueRow.release, release.stage == .pendingNaming || release.stage == .namingRejected {
            reviewNaming(for: release)
            return
        }

        if let release = queueRow.release, release.stage == .pendingMergeSelection || release.stage == .mergeFailed {
            reviewMerge(for: release)
            return
        }

        if let release = queueRow.release, release.stage == .pendingMetadata {
            reviewMetadata(for: release)
            return
        }

        if let item = queueRow.effectiveItem {
            edit(item: item)
        }
    }

    //MARK: Naming review (Intake/Queue workflow phase 3)

    /// Opens the naming approve/reject window (NamingReviewWindowController)
    /// for a release still awaiting a naming decision -- reached by
    /// double-clicking its row or the "Edit\u{2026}" context-menu item (see
    /// edit(_:) above and its entry in validateUserInterfaceItem). See the
    /// design doc's section 4.2 for the full rationale.
    private func reviewNaming(for release: QueueRelease) {
        guard let window = window else { return }

        let reviewController = NamingReviewWindowController(release: release)
        guard let reviewWindow = reviewController.window else { return }

        // reviewController is captured (and so kept alive) by this closure
        // for as long as the sheet is up -- same pattern as
        // mergeSelectedItems(_:)/MergeReorderWindowController.
        window.beginSheet(reviewWindow) { response in
            switch response {
            case .OK:
                self.approveNaming(for: release, name: reviewController.finalName)
            case NamingReviewWindowController.passResponse:
                // Pass -- leave the release exactly as it was
                // (.pendingNaming) so it's simply offered for review
                // again later, rather than parked as rejected.
                break
            default:
                release.stage = .namingRejected
                self.updateUI()
            }
        }
    }

    /// Renames the release's folder (and, transitively, every file inside
    /// it) to the approved name, then either routes a multi-file release to
    /// merge selection (.pendingMergeSelection -- phase 5, not yet built)
    /// or, for a single-file release, resolves it straight to a mux-able
    /// QueueItem with metadata search wired in -- see
    /// resolveSingleFileRelease(_:) below (phase 4).
    ///
    /// Never overwrites an existing file or folder at the computed
    /// destination -- see uniqueFolderDestination(for:) -- and leaves the
    /// release in .pendingNaming (with an alert) if the rename itself
    /// fails, rather than advancing its stage over a folder that never
    /// actually got renamed.
    private func approveNaming(for release: QueueRelease, name: String) {
        guard name.isEmpty == false else { return }

        let oldFolder = release.folderURL
        let renamedFolder: URL

        if oldFolder.lastPathComponent == name {
            renamedFolder = oldFolder
        } else {
            let candidate = oldFolder.deletingLastPathComponent().appendingPathComponent(name)
            let destination = QueueController.uniqueFolderDestination(for: candidate)

            do {
                try FileManager.default.moveItem(at: oldFolder, to: destination)
                renamedFolder = destination
            } catch {
                presentError(error)
                return
            }
        }

        rememberIngested(renamedFolder.path)
        release.folderURL = renamedFolder
        release.sourceFileURLs = release.sourceFileURLs.map { renamedFolder.appendingPathComponent($0.lastPathComponent) }
        release.suggestedName = name
        release.approvedName = name

        if release.sourceFileURLs.count > 1 {
            release.stage = .pendingMergeSelection
            attemptAutoMerge(for: release)
        } else {
            release.stage = .pendingMetadata
            attemptAutoResolveMetadata(for: release)
        }

        updateUI()
    }

    /// "Auto mode" for the merge step (Intake/Queue workflow section 7b):
    /// when MediaIntakePrefs.autoMergeOnSequence is on, the files are
    /// confirmed compatible, and every one of them carries an actually
    /// detected sequence number (MergeReorderWindowController.
    /// everyFileHasDetectedSequence(_:) -- the conservative, all-or-
    /// nothing check: a single un-numbered file falls back to the normal
    /// manual sheet), schedules an automatic merge in
    /// MergeReorderWindowController.defaultOrder(for:)'s order instead of
    /// waiting for the manual reorder/confirmation sheet. No-op (and no
    /// change to release.stage) when any of that doesn't hold, so the
    /// row just sits in .pendingMergeSelection waiting for a manual Edit,
    /// exactly as it does today.
    ///
    /// Scoped to this intake/scan path only, per this feature's design
    /// decision -- mergeSelectedItems(_:)'s manual multi-select merge
    /// always goes through the confirmation sheet, unchanged.
    private func attemptAutoMerge(for release: QueueRelease) {
        guard MediaIntakePrefs.autoMergeOnSequence,
              release.stage == .pendingMergeSelection,
              (try? MergeCompatibility.check(files: release.sourceFileURLs)) != nil,
              MergeReorderWindowController.everyFileHasDetectedSequence(release.sourceFileURLs)
        else { return }

        let order = MergeReorderWindowController.defaultOrder(for: release.sourceFileURLs)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingAutoMerges.removeValue(forKey: release.id)
            // Re-check both the stage (opening the row manually cancels
            // this same work item in reviewMerge(for:), but a defensive
            // second check costs nothing) and that the row wasn't
            // deleted from the queue outright while this was waiting --
            // removing a parked release should mean it's gone, not that
            // it quietly merges anyway a moment later.
            guard release.stage == .pendingMergeSelection,
                  self.queue.indexesOfRows(where: { $0.release === release }).isEmpty == false
            else { return }
            self.runMerge(for: release, order: order)
        }
        pendingAutoMerges[release.id] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    /// Confidence gate for the interface-architecture doc's gap #1
    /// ("single-file curation has no dedicated review step today"):
    /// runs the same kind of movieSeach(...) lookup QueueMetadataAction
    /// will later repeat at mux time, purely to decide up front whether
    /// this single-file release's eventual match is confident enough to
    /// skip a review step entirely -- reusing
    /// NamingReviewWindowController.isHighConfidenceMatch(...)'s existing
    /// conservative title/year heuristic rather than inventing a second
    /// one. Runs on a background thread for the same reason beginSearch()
    /// there does (RunnableTask.run() is blocking).
    ///
    /// - High confidence, or no online match at all (nothing to compare
    ///   against, so nothing to review), resolves the release immediately
    ///   -- exactly the fully-automatic behavior this release had before
    ///   this gap was addressed.
    /// - Anything else leaves the release parked in .pendingMetadata (an
    ///   existing-but-previously-unused QueueRelease.Stage case) for the
    ///   user to open via the normal double-click/Edit… entry point,
    ///   same "parked until opened" pattern reviewNaming(for:)/
    ///   reviewMerge(for:) already use -- see reviewMetadata(for:) below.
    ///
    /// Scoped to the intake/scan path only, by construction: this is only
    /// ever reached from approveNaming(for:name:), which only exists on
    /// the release pipeline -- a plain manually-added QueueItem never
    /// goes through here.
    private func attemptAutoResolveMetadata(for release: QueueRelease) {
        guard release.stage == .pendingMetadata,
              release.sourceFileURLs.count == 1 || release.mergedFileURL != nil else { return }

        guard prefs.searchMetadata else {
            resolveSingleFileRelease(release)
            updateUI()
            return
        }

        let localName = release.approvedName ?? release.folderURL.lastPathComponent
        let query = ReleaseFilenameParser.parse(localName)
        let localTitle = query?.title ?? ReleaseFilenameParser.normalizedDelimiters(localName)
        let localYear = query?.year

        let movieProvider = prefs.movieProvider
        let movieLanguage = prefs.movieProviderLanguage

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let service = MetadataSearch.service(name: movieProvider)
            let search = MetadataSearch.movieSeach(service: service, movie: localTitle, language: movieLanguage)

            var results: [MetadataResult] = []
            search.search(completionHandler: { results = $0 }).run()

            let onlineTitle = results.first?[.name] as? String
            let onlineYear = ParsedMediaName.firstFourDigitYear(in: results.first?[.releaseDate] as? String)

            let highConfidence: Bool
            if let onlineTitle = onlineTitle, onlineTitle.isEmpty == false {
                highConfidence = NamingReviewWindowController.isHighConfidenceMatch(localTitle: localTitle,
                                                                                     localYear: localYear,
                                                                                     onlineTitle: onlineTitle,
                                                                                     onlineYear: onlineYear)
            } else if let query = query, query.season != nil, query.episode != nil {
                // The search above is a movie search; a TV episode finding
                // nothing there says nothing about its TV metadata, so it
                // carries on as before.
                highConfidence = true
            } else {
                // Nothing found online at all: stop at Metadata Review so
                // the user can search with other words (or continue
                // without metadata) instead of delivering the file with
                // empty tags.
                highConfidence = false
            }

            DispatchQueue.main.async {
                guard let self = self, release.stage == .pendingMetadata,
                      self.queue.indexesOfRows(where: { $0.release === release }).isEmpty == false
                else { return }

                if highConfidence {
                    self.resolveSingleFileRelease(release)
                    self.updateUI()
                }
                // Otherwise the release just stays parked in
                // .pendingMetadata -- its row is already showing
                // correctly from approveNaming(for:name:)'s own
                // updateUI() call, so there's nothing further to refresh
                // here.
            }
        }
    }

    /// Opens the metadata/artwork confirm sheet
    /// (SingleFileMetadataReviewWindowController) for a single-file
    /// release whose automatic match wasn't confident enough for
    /// attemptAutoResolveMetadata(for:) above to resolve silently --
    /// reached the same way reviewNaming(for:)/reviewMerge(for:) are
    /// (double-click / "Edit…", see edit(_:) and
    /// validateUserInterfaceItem). See the interface-architecture doc's
    /// gaps #1 (a confirm-or-override step at all) and #2 (a per-item
    /// Portrait/Landscape artwork orientation override, folded into this
    /// same sheet per that doc's own recommendation) for the rationale.
    private func reviewMetadata(for release: QueueRelease) {
        guard let window = window else { return }

        let reviewController = SingleFileMetadataReviewWindowController(release: release,
                                                                          movieProvider: prefs.movieProvider,
                                                                          movieLanguage: prefs.movieProviderLanguage,
                                                                          defaultArtwork: ArtworkType(rawValue: prefs.providerArtwork) ?? .poster,
                                                                          artworkSize: ArtworkSize(rawValue: prefs.providerArtworkSize) ?? .standard)
        guard let reviewWindow = reviewController.window else { return }

        // reviewController is captured (and so kept alive) by this
        // closure for as long as the sheet is up -- same pattern
        // reviewNaming(for:)/reviewMerge(for:) use.
        window.beginSheet(reviewWindow) { response in
            if response == .OK {
                self.resolveSingleFileRelease(release,
                                              artworkOverride: reviewController.chosenArtworkType,
                                              searchTerm: reviewController.chosenSearchTerm,
                                              searchResultIndex: reviewController.chosenResultIndex,
                                              skipMetadata: reviewController.hasMatch == false)
                self.updateUI()
            }
            // .cancel: leave the release parked in .pendingMetadata, same
            // "no-op, reopen later" behavior a cancelled merge-order sheet
            // already has.
        }
    }

    /// Resolves a single-file release straight to a mux-able QueueItem
    /// (Intake/Queue workflow phase 4) -- called either immediately by
    /// attemptAutoResolveMetadata(for:) above (high-confidence/no-match
    /// case) or after the user confirms the metadata review sheet
    /// (reviewMetadata(for:) above). artworkOverride, when supplied by
    /// the review sheet's Portrait/Landscape toggle, takes the place of
    /// the global providerArtwork preference for this one release only --
    /// everything else about QueueMetadataAction's wiring is unchanged.
    private func resolveSingleFileRelease(_ release: QueueRelease, artworkOverride: ArtworkType? = nil, searchTerm: String? = nil, searchResultIndex: Int = 0, skipMetadata: Bool = false) {
        guard let sourceURL = release.mergedFileURL ?? release.sourceFileURLs.first else { return }

        let destURL = destination(for: sourceURL)
        let item = QueueItem(fileURL: sourceURL, destination: destURL)

        if prefs.searchMetadata && skipMetadata == false {
            let artwork = artworkOverride ?? ArtworkType(rawValue: prefs.providerArtwork) ?? .poster
            item.addAction(QueueMetadataAction(movieLanguage: prefs.movieProviderLanguage,
                                                tvShowLanguage: prefs.tvShowProviderLanguage,
                                                movieProvider: prefs.movieProvider,
                                                tvShowProvider: prefs.tvShowProvider,
                                                preferredArtwork: artwork.rawValue,
                                                preferredArtworkSize: prefs.providerArtworkSize,
                                                searchName: release.approvedName ?? release.folderURL.lastPathComponent,
                                                searchTerm: searchTerm,
                                                searchResultIndex: searchResultIndex))
        }
        if let readyForLibraryFolder = MediaIntakePrefs.fallbackDeliveryFolder {
            item.addAction(QueueMoveToLibraryAction(releaseID: release.id, destinationRoot: readyForLibraryFolder))
        }

        release.resolvedItem = item
        release.stage = .pendingLibraryMove
    }

    //MARK: Merge review (Intake/Queue workflow phase 5)

    /// Opens the merge order/selection sheet for a release whose naming is
    /// already approved but whose multiple source files haven't been
    /// merged yet (.pendingMergeSelection), or whose last merge attempt
    /// failed and needs its order adjusted before retrying
    /// (.mergeFailed) -- reached the same way as reviewNaming(for:) above
    /// (double-click / "Edit\u{2026}", see edit(_:) and
    /// validateUserInterfaceItem). Reuses the exact same
    /// MergeReorderWindowController sheet the manual Merge button already
    /// uses (mergeSelectedItems(_:)) rather than a new window, per the
    /// design doc's decision 5 ("one shared merge-selection/reorder UI").
    /// Pre-populates from a previous attempt's mergeOrder when retrying
    /// after a failure, so the user doesn't have to redo a reorder that
    /// wasn't the problem.
    private func reviewMerge(for release: QueueRelease) {
        // Opening the sheet manually -- including during the brief delay
        // before a scheduled auto-merge would otherwise fire -- always
        // wins: cancel any pending auto-merge for this release so it
        // can't also fire once the user is already looking at (and
        // about to override) its order.
        pendingAutoMerges.removeValue(forKey: release.id)?.cancel()

        guard let window = window else { return }

        let reorderController = MergeReorderWindowController(files: release.mergeOrder ?? release.sourceFileURLs)
        guard let reorderWindow = reorderController.window else { return }

        // reorderController is captured (and so kept alive) by this
        // closure for as long as the sheet is up -- same pattern as
        // mergeSelectedItems(_:) above.
        window.beginSheet(reorderWindow) { response in
            guard response == .OK else { return }
            self.runMerge(for: release, order: reorderController.orderedFiles)
        }
    }

    /// A Finder-style unique destination for the merge output file --
    /// mirrors uniqueFolderDestination(for:) above but numbers before the
    /// file extension ("name.mp4", "name 2.mp4", \u{2026}). Needed because a
    /// release-driven merge picks its own destination automatically
    /// rather than asking via a save panel (see runMerge(for:order:)
    /// below and the design doc's 4.5), so it still needs to never
    /// silently overwrite something already sitting there.
    static func uniqueFileDestination(for candidate: URL) -> URL {
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let parent = candidate.deletingLastPathComponent()
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 2

        while true {
            let numbered = parent.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: numbered.path) == false {
                return numbered
            }
            counter += 1
        }
    }

    /// Runs the actual merge for a release, once the user has confirmed a
    /// file order in reviewMerge(for:) above -- the release-driven
    /// counterpart to presentMergeDestinationPanel(for:files:in:), which
    /// exists for the plain manual-selection Merge button. Differs from
    /// it in exactly the ways the design doc's 4.4/4.5 call for:
    ///  - no save panel -- the destination reuses the release's already-
    ///    approved name (4.5: "the group-driving code should pass the
    ///    approved name through explicitly rather than relying on
    ///    [FileMerger.suggestedDestinationName's] fallback guess"),
    ///    written inside the release's own (already renamed) folder;
    ///  - a MergeCompatibility/FileMerger failure is translated to plain
    ///    language (friendlyMergeErrorDescription(for:) below) and stored
    ///    on the release itself (mergeErrorMessage) rather than shown in
    ///    an alert -- release.stage becomes .mergeFailed and the row
    ///    stays visible in the Queue so the user can reopen
    ///    reviewMerge(for:) to adjust the order and retry;
    ///  - on success, resolves the release the same way
    ///    resolveSingleFileRelease(_:) does (phases 4/5) -- see
    ///    resolveMergedRelease(_:mergedFileURL:) below.
    private func runMerge(for release: QueueRelease, order: [URL]) {
        release.mergeOrder = order
        release.mergedFileURL = nil
        release.stage = .merging
        release.mergeProgress = 0
        updateUI()

        let name = release.approvedName ?? release.folderURL.lastPathComponent
        let candidate = release.folderURL.appendingPathComponent(name).appendingPathExtension("mp4")
        let destination = QueueController.uniqueFileDestination(for: candidate)

        // Serialized against the Queue's own single-worker mux lane
        // (Queue.performSerialized(_:)) rather than a separate, unrelated
        // DispatchQueue -- so this merge can never run at the same time as
        // the Queue actively muxing a ready item. See performSerialized(_:)'s
        // own doc comment for why FileMerger can't just be a
        // QueueActionProtocol action instead.
        queue.performSerialized {
            do {
                try FileMerger.merge(files: order, destination: destination, progressHandler: { progress in
                    DispatchQueue.main.async {
                        release.mergeProgress = progress
                    }
                })
                DispatchQueue.main.async {
                    self.resolveMergedRelease(release, mergedFileURL: destination)
                }
            } catch {
                DispatchQueue.main.async {
                    release.mergeErrorMessage = QueueController.friendlyMergeErrorDescription(for: error)
                    release.stage = .mergeFailed
                    self.updateUI()
                }
            }
        }
    }

    /// Same QueueMetadataAction/QueueMoveToLibraryAction wiring as
    /// resolveSingleFileRelease(_:) above, for a release that just
    /// finished merging instead of one that was always a single file --
    /// kept as its own small method rather than folded into
    /// resolveSingleFileRelease(_:) since the source URL here is a just-
    /// written merge output, not release.sourceFileURLs.first.
    ///
    /// A merged release now takes the same metadata step a single file
    /// does: a confident online match resolves it straight away, anything
    /// else parks it in .pendingMetadata so the Metadata Review sheet
    /// (double-click / Edit) lets the user confirm or search again.
    private func resolveMergedRelease(_ release: QueueRelease, mergedFileURL: URL) {
        release.mergedFileURL = mergedFileURL
        release.stage = .pendingMetadata
        attemptAutoResolveMetadata(for: release)
        updateUI()
    }

    /// Translates MergeCompatibility's/FileMerger's technical error cases
    /// (filenames, codec four-character codes, raw timescale numbers,
    /// pixel dimensions) into the plain-language explanations the design
    /// doc's 4.4 calls for, so release.mergeErrorMessage reads like
    /// something a non-technical user can act on rather than a debug
    /// message. Kept as its own translation layer here rather than
    /// changed on MergeCompatibilityError/FileMergerError themselves,
    /// which keep their existing, more detailed errorDescription text for
    /// the manual Merge button's alert
    /// (presentMergeDestinationPanel(for:files:in:) above).
    private static func friendlyMergeErrorDescription(for error: Error) -> String {
        if let error = error as? MergeCompatibilityError {
            switch error {
            case .tooFewFiles:
                return NSLocalizedString("At least two files are needed to merge.", comment: "Friendly merge error")
            case let .couldNotOpenFile(file):
                return String(format: NSLocalizedString("\u{201C}%@\u{201D} couldn\u{2019}t be opened.", comment: "Friendly merge error"), file.lastPathComponent)
            case .noMergeableTracks:
                return NSLocalizedString("None of these files share a video or audio track to merge.", comment: "Friendly merge error")
            case let .trackCountMismatch(file, _, _, mediaType):
                return String(format: NSLocalizedString("\u{201C}%@\u{201D} has a different number of %@ tracks than the other files.", comment: "Friendly merge error"), file.lastPathComponent, mediaType)
            case let .codecMismatch(file, _, _, mediaType):
                return String(format: NSLocalizedString("\u{201C}%@\u{201D} uses a different %@ format than the other files, so they can\u{2019}t be merged together.", comment: "Friendly merge error"), file.lastPathComponent, mediaType)
            case let .timescaleMismatch(file, _, _, mediaType):
                return String(format: NSLocalizedString("\u{201C}%@\u{201D}\u{2019}s %@ doesn\u{2019}t line up closely enough with the other files to merge.", comment: "Friendly merge error"), file.lastPathComponent, mediaType)
            case let .dimensionsMismatch(file, _, _, _, _):
                return String(format: NSLocalizedString("\u{201C}%@\u{201D} isn\u{2019}t the same picture size as the other files.", comment: "Friendly merge error"), file.lastPathComponent)
            }
        }

        if let error = error as? FileMergerError {
            switch error {
            case .concatFailed:
                return NSLocalizedString("Something went wrong while joining these files together.", comment: "Friendly merge error")
            case .writeFailed:
                return NSLocalizedString("The merged file couldn\u{2019}t be written to disk.", comment: "Friendly merge error")
            }
        }

        return error.localizedDescription
    }

    /// A Finder-style unique destination for a folder rename -- "name",
    /// then "name 2", "name 3", ... -- so approving a naming decision
    /// never silently overwrites or merges into something already sitting
    /// at the approved name. Mirrors the collision handling
    /// FileMerger.renameSourceFolderIfPossible(for:) already uses for the
    /// merge-source-folder-rename feature (there reported as
    /// .destinationExists rather than resolved automatically, since that
    /// feature runs unattended after a merge; this one runs from an
    /// explicit user action approving a specific name, so silently
    /// numbering it the way Finder itself would is the friendlier choice).
    ///
    /// Not private -- QueueMoveToLibraryAction (QueueAction.swift, phase
    /// 5) reuses this exact same collision handling when landing a
    /// finished release in Ready for Media Library, rather than
    /// duplicating it.
    static func uniqueFolderDestination(for candidate: URL) -> URL {
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let parent = candidate.deletingLastPathComponent()
        let base = candidate.lastPathComponent
        var counter = 2

        while true {
            let numbered = parent.appendingPathComponent("\(base) \(counter)")
            if FileManager.default.fileExists(atPath: numbered.path) == false {
                return numbered
            }
            counter += 1
        }
    }

    @IBAction func showInFinder(_ sender: Any?) {
        let clickedRow = table.clickedRow
        if clickedRow > -1, let item = queue.item(at: clickedRow) {
            NSWorkspace.shared.activateFileViewerSelecting([item.destURL])
        }
    }

    @IBAction func removeSelectedItems(_ sender: Any?) {
        deleteSelection(in: table)
    }

    @IBAction func removeCompletedItems(_ sender: Any?) {
        remove(at: queue.indexesOfItems(with: .completed))
    }

    //MARK: Merge

    /// The selected rows, if (and only if) they're all eligible to be
    /// merged together: two or more, each a still-untouched, not-yet-
    /// processed file (status .ready -- a plain QueueItem, or a release
    /// whose own naming/merge already produced one). Deliberately
    /// restricted to .ready rather than "anything not currently working":
    /// QueueItem.fileURL is always the original source file, never updated
    /// to point at a completed item's processed output (that's destURL),
    /// so merging a .completed/.failed/.cancelled row here would silently
    /// merge its stale, pre-processing source instead of what the user
    /// actually sees represented by that row. Backs both the Merge
    /// button/menu item's enabled state and the action itself, so the two
    /// can never disagree about what's mergeable. Returns nil rather than
    /// an empty array when nothing qualifies, so callers can use it
    /// directly in an `if let`/`guard let`.
    private func mergeCandidateRows(at indexes: IndexSet) -> [QueueRow]? {
        guard indexes.count >= 2 else { return nil }

        let rows = queue.rows(at: indexes)
        let allEligible = rows.allSatisfy { $0.effectiveItem?.status == .ready }

        return allEligible ? rows : nil
    }

    /// Merges the selected queue rows' files into one, replacing them with
    /// a single new queue item for the result -- the Queue-integrated
    /// replacement for the old standalone "Merge Files (Debug)…" menu
    /// item, which picked its files from a bare NSOpenPanel with no
    /// connection to the Queue at all. Starts with the reorder sheet
    /// (MergeReorderWindowController) so the user can set play order
    /// before anything else happens; it's pre-populated with the files in
    /// table order, so accepting it immediately without dragging anything
    /// reproduces the old table-order-only behavior exactly.
    @IBAction func mergeSelectedItems(_ sender: Any?) {
        guard let window = window,
              let rows = mergeCandidateRows(at: table.selectedRowIndexes)
        else { return }

        let files = rows.compactMap { $0.effectiveItem?.fileURL }
        guard files.count == rows.count else { return }

        let reorderController = MergeReorderWindowController(files: files)
        guard let reorderWindow = reorderController.window else { return }

        // reorderController is captured (and so kept alive) by this
        // closure for as long as the sheet is up -- AppKit retains the
        // completion handler itself until it's invoked, so nothing here
        // needs its own stored property.
        window.beginSheet(reorderWindow) { response in
            guard response == .OK else { return }
            self.presentMergeDestinationPanel(for: rows, files: reorderController.orderedFiles, in: window)
        }
    }

    /// After a successful merge, optionally renames the source files'
    /// shared folder to match a correctly-formatted release name found
    /// nearby -- see FileMerger.renameSourceFolderIfPossible(for:) and
    /// MediaIntakePrefs.renameSourceFolderAfterMerge (off by default;
    /// toggled in the Media Intake preferences pane). If the rename
    /// happens AND the merge's own output file was written inside that
    /// folder (the common case, since suggestedDestinationDirectory(for:)
    /// defaults the save panel there), the folder's entire contents move
    /// along with an ordinary directory rename -- so the merged file
    /// physically ends up under the new folder name too, and this
    /// returns that new location instead of the stale pre-rename one.
    /// replaceRows(_:withMergedFileAt:) needs the Queue item it creates
    /// to point at where the file actually ended up, not where
    /// FileMerger originally wrote it.
    ///
    /// Skips renaming entirely (returning `destination` unchanged) when
    /// the preference is off, when nothing nearby parses into a release
    /// name, when the folder is already correctly named, when the
    /// computed destination name is already taken by something else, or
    /// when the rename itself fails -- logged via Logger.shared in the
    /// last three cases so there's a trace of why nothing happened,
    /// since this runs silently with no alert (the preference toggle
    /// itself is the user's opt-in, not a per-merge confirmation).
    private func renamedDestination(after files: [URL], mergedFileAt destination: URL) -> URL {
        guard MediaIntakePrefs.renameSourceFolderAfterMerge else { return destination }

        switch FileMerger.renameSourceFolderIfPossible(for: files) {
        case let .renamed(from, to):
            Logger.shared.write(toLog: "Renamed merge source folder \u{201C}\(from.lastPathComponent)\u{201D} to \u{201C}\(to.lastPathComponent)\u{201D}")
            guard destination.deletingLastPathComponent().standardizedFileURL == from.standardizedFileURL else {
                return destination
            }
            return to.appendingPathComponent(destination.lastPathComponent)
        case .alreadyNamed, .noReleaseNameFound:
            return destination
        case let .destinationExists(existing):
            Logger.shared.write(toLog: "Skipped renaming merge source folder -- \u{201C}\(existing.lastPathComponent)\u{201D} already exists")
            return destination
        case let .failed(error):
            Logger.shared.write(toLog: "Failed to rename merge source folder: \(error.localizedDescription)")
            return destination
        }
    }

    /// Second half of mergeSelectedItems(_:), split out once the reorder
    /// step was added: asks where to save the merged file, then runs
    /// FileMerger in the background with the same progress-window pattern
    /// the old debug entry point used.
    private func presentMergeDestinationPanel(for rows: [QueueRow], files: [URL], in window: NSWindow) {
        let savePanel = NSSavePanel()
        savePanel.title = NSLocalizedString("Save Merged File", comment: "Merge save panel -> title")
        savePanel.canSelectHiddenExtension = true
        savePanel.allowedFileTypes = ["mp4"]
        // See FileMerger.suggestedDestinationName -- prefers the files'
        // shared containing folder name over the first file's own name.
        savePanel.nameFieldStringValue = FileMerger.suggestedDestinationName(for: files) + " (merged).mp4"
        // Default to the files' own folder rather than wherever the panel
        // last happened to be pointed (the very first time it's shown,
        // that's an unhelpful top-of-filesystem location) -- see
        // FileMerger.suggestedDestinationDirectory.
        savePanel.directoryURL = FileMerger.suggestedDestinationDirectory(for: files)

        savePanel.beginSheetModal(for: window) { response in
            guard response == NSApplication.ModalResponse.OK, let destination = savePanel.url else { return }

            // Reuses the same progress-window pattern as the old debug
            // entry point (and DocumentWindowController's own save
            // progress) rather than inventing a one-off spinner. No cancel
            // support yet -- FileMerger/MP42ConcatImporter don't watch for
            // it -- so the button that view normally offers is hidden.
            let progressController = ProgressViewController()
            _ = progressController.view
            progressController.cancelButton.isHidden = true
            progressController.progressTitle = String(format: NSLocalizedString("Merging %d files\u{2026}", comment: "Merge progress -> title"), files.count)

            let progressWindow = NSWindow(contentViewController: progressController)
            progressWindow.title = NSLocalizedString("Merging Files", comment: "Merge progress window -> title")
            progressWindow.styleMask = [.titled]
            progressWindow.center()
            progressWindow.makeKeyAndOrderFront(nil)

            // Same reasoning as runMerge(for:order:) above -- serialized
            // against the Queue's own mux lane instead of an independent
            // DispatchQueue, so this manual merge can't run concurrently
            // with the Queue actively processing a ready item.
            self.manualMergesRunning += 1
            self.queue.performSerialized {
                do {
                    try FileMerger.merge(files: files, destination: destination, progressHandler: { progress in
                        DispatchQueue.main.async {
                            progressController.progress = progress
                        }
                    })
                    DispatchQueue.main.async {
                        self.manualMergesRunning -= 1
                        progressWindow.close()
                        self.replaceRows(rows, withMergedFileAt: self.renamedDestination(after: files, mergedFileAt: destination))
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.manualMergesRunning -= 1
                        progressWindow.close()
                        let alert = NSAlert()
                        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Merge alert -> button"))
                        alert.messageText = NSLocalizedString("Merge Failed", comment: "Merge alert -> title")
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.beginSheetModal(for: window)
                    }
                }
            }
        }
    }

    /// Swaps the given (now-merged-away) rows out for one new queue item
    /// pointing at the merged file, at the position the first of them
    /// occupied. Looks the rows' current indexes up fresh by identity
    /// (queue.indexesOfRows) rather than trusting indexes captured before
    /// the merge ran, since the merge itself runs in the background and
    /// the queue could have changed underneath it in the meantime (the
    /// merged rows removed or reordered by hand, say) -- if none of them
    /// can be found any more, the merged file is simply appended instead
    /// of crashing or silently doing nothing.
    ///
    /// Goes through the normal createItem(url:) path so the merged file
    /// picks up whatever Queue Options are currently set (metadata search,
    /// Set Output Filename, a chosen Location, etc.) exactly like any
    /// other newly-added file -- deliberately, for the same reason any
    /// other file added to the Queue does.
    private func replaceRows(_ rows: [QueueRow], withMergedFileAt destination: URL) {
        let indexes = queue.indexesOfRows(where: { rows.contains($0) })
        let insertionIndex = indexes.first ?? queue.count

        if indexes.isEmpty == false {
            removeRows(at: indexes)
        }

        let mergedItem = createItem(url: destination)
        insert(items: [mergedItem], at: IndexSet(integer: insertionIndex))

        // insertRows(_:at:)/removeRows(at:) each name their own undo step;
        // since both ran within the same event (there's no await between
        // them), NSUndoManager has already grouped them into one action --
        // this just gives that combined group a name that describes what
        // actually happened.
        window?.undoManager?.setActionName(NSLocalizedString("Merge Files", comment: "Queue -> merge undo action name"))

        table.selectRowIndexes(IndexSet(integer: max(0, min(insertionIndex, queue.count - 1))), byExtendingSelection: false)
    }

    //MARK: Drag & Drop

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = PasteboardItem(index: row, type: .tableViewIndex)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above else { return [] }

        if let source = info.draggingSource as? NSTableView,
           tableView == source
        {
            return .move
        } else if info.draggingSource == nil {
            return .copy
        } else {
            return []
        }
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let pasteboardItems = info.draggingPasteboard.pasteboardItems
                else { return false }

        if let source = info.draggingSource as? NSTableView,
           source == tableView
        {
            let rowIndexes = IndexSet(pasteboardItems.compactMap { $0.integer(forType: .tableViewIndex) })
            let rows = queue.rows(at: rowIndexes)
            move(rows: rows, at: row)
            return true
        } else if info.draggingPasteboard.types?.contains(NSPasteboard.PasteboardType.fileURL) ?? false {
            if let items = info.draggingPasteboard.readObjects(forClasses: [NSURL.classForCoder()], options: [:]) as? [URL] {
                insertGrouped(items, at: row)
            }
            return true
        }

        return false
    }
}
