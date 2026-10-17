//
//  QueueController.swift
//  Subler
//
//  Created by Damiano Galassi on 26/01/2019.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Queue window as Movies and TV Shows tabs with folder groups, the intake,
//  naming, merge, already-merged and metadata-review workflow, sortable
//  columns, statistics, time-limited runs, TV episode routing, files sent
//  from the Library scan edited in place, with the scan's tag columns.
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

    /// Both queues live in the one tabbed Queue window (QueueWindowController).
    /// Until that window exists this is the queue's own nib window.
    override var window: NSWindow? {
        get { return QueueWindowController.hostWindow ?? super.window }
        set { super.window = newValue }
    }

    /// Hands this queue's content (list, status line, progress bar) over to
    /// the tabbed window, leaving the nib's own window empty and unused.
    func takeNibContent() -> NSView? {
        guard let nibWindow = super.window, let content = nibWindow.contentView else { return nil }
        nibWindow.contentView = NSView()
        return content
    }

    // MARK: Totals and timing under the list

    /// Second line of the bottom strip: how many files are in the Queue and in
    /// each state, plus the time the current (or last) run has taken and when
    /// it should finish. The first line (statusLabel) keeps the file being worked on.
    private let statsLabel = NSTextField(labelWithString: "")
    private var statsTimer: Timer?
    private var runStartedAt: Date?
    private var runItemIDs = Set<ObjectIdentifier>()
    private var lastRunText: String?

    private func installStatsLabel() {
        guard let container = statusLabel.superview else { return }
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        container.addSubview(statsLabel)
        NSLayoutConstraint.activate([
            statsLabel.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            statsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            statsLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6)
        ])
    }

    /// The running percentage ("42%"), shown beside the progress bar
    /// instead of folded into statusLabel's title text -- Hans asked
    /// (2026-10-13) for the number to read as paired with the bar
    /// graphic rather than squeezed into the sentence, and for the
    /// footer to stay one line tall (no second row under the title).
    private let percentLabel = NSTextField(labelWithString: "")

    /// Installed in code, the same way installStatsLabel() is above,
    /// rather than by touching Queue.xib's layout: the single constraint
    /// that used to pin progressBar's trailing edge to the container's
    /// trailing edge moves onto this label instead, so the bar makes
    /// room for it with no Interface Builder frame/constraint edits.
    private func installPercentLabel() {
        guard let container = progressBar.superview else { return }

        if let barTrailing = container.constraints.first(where: {
            ($0.firstItem as? NSView) === container && $0.firstAttribute == .trailing &&
            ($0.secondItem as? NSView) === progressBar && $0.secondAttribute == .trailing
        }) {
            barTrailing.isActive = false
        }

        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = statusLabel.font
        percentLabel.alignment = .right
        percentLabel.lineBreakMode = .byClipping
        percentLabel.isHidden = true
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        container.addSubview(percentLabel)

        NSLayoutConstraint.activate([
            percentLabel.leadingAnchor.constraint(equalTo: progressBar.trailingAnchor, constant: 6),
            percentLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            percentLabel.widthAnchor.constraint(equalToConstant: 36),
            percentLabel.centerYAnchor.constraint(equalTo: progressBar.centerYAnchor)
        ])
    }

    /// Called when a run starts: remembers the start time and which files are
    /// part of the run (files added while it runs join it), and reads their
    /// sizes so the estimate can go by size rather than by file count.
    private func beginRunStats() {
        runStartedAt = Date()
        lastRunText = nil
        runItemIDs = []
        collectRunItems()

        let urls = queue.allRows.flatMap { $0.sizeSourceURLs }
        fetchSizes(urls, force: false) { [weak self] in self?.refreshStats() }

        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.queue.status == .working {
                self.refreshStats()
            } else {
                self.endRunStats()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
        refreshStats()
    }

    private func endRunStats() {
        statsTimer?.invalidate()
        statsTimer = nil
        if let start = runStartedAt {
            lastRunText = String(format: NSLocalizedString("last run took %@", comment: "Queue totals"), QueueTiming.clock(Date().timeIntervalSince(start)))
        }
        runStartedAt = nil
        refreshStats()
    }

    private func collectRunItems() {
        for row in queue.allRows {
            guard let item = row.effectiveItem, item.status == .ready || item.status == .working else { continue }
            runItemIDs.insert(ObjectIdentifier(item))
        }
    }

    /// How far through the run is, in bytes when every file's size is known
    /// and in files otherwise. Counts both plain QueueItems being muxed
    /// AND releases still merging -- a release that hasn't resolved to a
    /// QueueItem yet used to contribute nothing at all, so "about X left"
    /// quietly ignored however long its merge would still take. Releases
    /// parked waiting on the user (naming, merge order, a metadata
    /// review) are deliberately left out: there's no way to estimate
    /// how long a human takes to click something, so folding those in
    /// would make the estimate worse, not better.
    private func runProgressUnits() -> (done: Double, total: Double) {
        let itemFraction = progressBar.isIndeterminate ? 0 : min(max(progressBar.doubleValue, 0), 100) / 100

        struct Entry {
            var doneFraction: Double
            var bytes: Double?
        }
        var entries: [Entry] = []

        func bytesTotal(for urls: [URL]) -> Double? {
            var bytes: Double? = 0
            for url in urls {
                if let size = sizeCache[url], size >= 0 { bytes = (bytes ?? 0) + Double(size) } else { bytes = nil }
            }
            return bytes
        }

        for row in queue.allRows {
            if let item = row.effectiveItem, runItemIDs.contains(ObjectIdentifier(item)) {
                let finished = item.status == .completed || item.status == .failed || item.status == .cancelled
                let doneFraction = finished ? 1 : (item.status == .working ? itemFraction : 0)
                entries.append(Entry(doneFraction: doneFraction, bytes: bytesTotal(for: row.sizeSourceURLs)))
            } else if let release = row.release, release.stage == .merging {
                // Its own mergeProgress, not the shared progressBar's
                // itemFraction above -- that one may belong to a
                // completely different row (a QueueItem muxing, or
                // another release merging) at this exact tick.
                let doneFraction = min(max(release.mergeProgress, 0), 100) / 100
                let urls = release.mergeOrder ?? release.sourceFileURLs
                entries.append(Entry(doneFraction: doneFraction, bytes: bytesTotal(for: urls)))
            }
        }

        let useBytes = entries.isEmpty == false && entries.allSatisfy { $0.bytes != nil }
        var done = 0.0
        var total = 0.0
        for entry in entries {
            let weight = useBytes ? (entry.bytes ?? 0) : 1
            total += weight
            done += weight * entry.doneFraction
        }
        return (done, total)
    }

    private func refreshStats() {
        guard statsLabel.superview != nil else { return }

        let ranks = queue.allRows.filter { $0.folderHeaderURL == nil }.map { $0.statusSummary.rank }
        var text = QueueTally(ranks: ranks).text

        if let start = runStartedAt {
            collectRunItems()
            let elapsed = Date().timeIntervalSince(start)
            text += " \u{2014} " + String(format: NSLocalizedString("elapsed %@", comment: "Queue totals"), QueueTiming.clock(elapsed))

            let units = runProgressUnits()
            if let left = QueueTiming.remaining(elapsed: elapsed, doneUnits: units.done, totalUnits: units.total) {
                let finish = Date().addingTimeInterval(left)
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                formatter.dateStyle = Calendar.current.isDateInToday(finish) ? .none : .medium
                text += " \u{00B7} " + String(format: NSLocalizedString("about %@ left", comment: "Queue totals"), QueueTiming.approximately(left))
                text += " \u{00B7} " + String(format: NSLocalizedString("finishes about %@", comment: "Queue totals"), formatter.string(from: finish))
            } else {
                text += " \u{00B7} " + NSLocalizedString("estimating time left\u{2026}", comment: "Queue totals")
            }
        } else if let lastRunText = lastRunText {
            text += " \u{2014} " + lastRunText
        }

        statsLabel.stringValue = text
    }

    override func showWindow(_ sender: Any?) {
        QueueWindowController.shared.show(self)
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

        // The window itself, its toolbar and its title now belong to
        // QueueWindowController; this queue only fills in its own content.
        configureContextMenuIcons()

        table.registerForDraggedTypes([NSPasteboard.PasteboardType.fileURL, .tableViewIndex])
        configureColumns()
        // Same "double-click a row to open/edit it" convention already
        // used by MovieViewController, ChapterViewController,
        // TracksViewController, and CustomSourcesListViewController --
        // reuses the existing "Edit\u{2026}" context-menu action, which now
        // also opens the naming review window for a pending release (see
        // edit(_:) below). There was no doubleAction on this table before
        // this -- a release row had no way to be opened at all.
        table.doubleAction = #selector(edit(_:))
        // Set explicitly: the Queue window's controller is now
        // QueueWindowController, so a double-click with no target would reach
        // it instead of this queue and nothing would open.
        table.target = self
        progressBar.isHidden = true
        installStatsLabel()
        installPercentLabel()
        refreshStats()

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
            self.refreshStats()

            if index != NSNotFound {
                self.updateUI(indexes: IndexSet(integer: index))
            }
        }

        nc.addObserver(forName: Queue.Completed, object: queue, queue: main) { (note) in
            self.progressBar.isHidden = true
            self.progressBar.stopAnimation(self)
            self.progressBar.doubleValue = 0
            self.progressBar.isIndeterminate = true
            self.percentLabel.isHidden = true

            self.runTimeLimitTimer?.invalidate()
            self.runTimeLimitTimer = nil
            let pausedByTimeLimit = self.queue.pausedByTimeLimit

            QueueWindowController.existing?.setRunning(false, for: self)
            self.statusLabel.stringValue = pausedByTimeLimit
                ? NSLocalizedString("Paused \u{2014} time limit reached. Start again to pick up where it left off.", comment: "Queue -> paused by time limit")
                : NSLocalizedString("Done", comment: "Queue -> Done")
            self.endRunStats()

            if MediaIntakePrefs.autoRemoveCompletedItems {
                self.removeCompletedItems(self)
            }
            self.updateUI()
            EmptyFolderCleaner.runAutomaticallyIfEnabled()

            if self.prefs.showDoneNotification, let info = note.userInfo {
                let title = pausedByTimeLimit
                    ? NSLocalizedString("Queue Paused", comment: "Queue -> paused by time limit, notification title")
                    : NSLocalizedString("Queue Done", comment: "")
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
            if let row = selectedQueueIndex {
                let queueRow = queue.row(at: row)
                if queueRow.effectiveItem?.status != .working && queueRow.release?.stage != .merging {
                    return true
                }
            } else if let row = clickedQueueIndex {
                let queueRow = queue.row(at: row)
                if queueRow.effectiveItem?.status != .working && queueRow.release?.stage != .merging {
                    return true
                }
            }
            return false
        case #selector(showInFinder(_:)):
            if let row = clickedQueueIndex {
                return finderTarget(for: queue.row(at: row)) != nil
            }
            return false
        case #selector(edit(_:)):
            if let row = clickedQueueIndex {
                let queueRow = queue.row(at: row)
                if let status = queueRow.effectiveItem?.status, status == .completed || status == .ready {
                    return true
                }
                // A release still awaiting a naming decision (or one the
                // user rejected and wants to reconsider) -- see
                // reviewNaming(for:at:). Every later stage already has an
                // approvedName and isn't reopened from here.
                if let stage = queueRow.release?.stage, stage == .pendingNaming || stage == .namingRejected || stage == .alreadyMerged {
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
            return mergeCandidateRows(at: selectedQueueIndexes) != nil
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

    /// Lets the person point a queued item at the file it was renamed or
    /// moved to, then opens it.
    private func locate(item: QueueItem, near missing: URL) {
        guard let window = window else { return }
        var start = missing.deletingLastPathComponent()
        while FileManager.default.fileExists(atPath: start.path) == false, start.path != "/" {
            start = start.deletingLastPathComponent()
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.message = String(format: NSLocalizedString("Choose the file that \u{201C}%@\u{201D} is now.", comment: "Queue edit -> locate panel"), missing.lastPathComponent)
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.sizeCache[missing] = nil
            item.relocate(to: url)
            try? self?.queue.saveToDisk()
            self?.refreshRow(for: item)
            self?.edit(item: item)
        }
    }

    internal func edit(item: QueueItem) {
        // Already open: bring that window forward instead of opening the
        // same file a second time.
        if let existing = openEditors[ObjectIdentifier(item)] {
            existing.showWindows()
            existing.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            itemPopover?.close()
            return
        }

        // The file may have been moved, renamed or deleted since it was added.
        var fileToOpen = item.status == .completed ? item.destURL : item.fileURL
        // Renamed in Finder? When the folder it was in holds exactly one media
        // file, and no other row uses that file, that is the file.
        if FileManager.default.fileExists(atPath: fileToOpen.path) == false, item.status != .completed {
            let candidates = QueueController.mediaFiles(in: fileToOpen.deletingLastPathComponent())
            let used = Set((0..<queue.count).compactMap { queue.row(at: $0).effectiveItem }.filter { $0 !== item }.map { $0.fileURL.standardizedFileURL.path })
            if candidates.count == 1, used.contains(candidates[0].standardizedFileURL.path) == false {
                sizeCache[fileToOpen] = nil
                item.relocate(to: candidates[0])
                fileToOpen = candidates[0]
                refreshRow(for: item)
                try? queue.saveToDisk()
            }
        }
        if FileManager.default.fileExists(atPath: fileToOpen.path) == false {
            sizeCache[fileToOpen] = nil
            refreshRow(for: item)
            if let window = window {
                let missing = fileToOpen
                let canLocate = item.status != .completed
                let folderName = missing.deletingLastPathComponent().lastPathComponent
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("This file can\u{2019}t be found", comment: "Queue edit -> missing file title")
                alert.informativeText = String(format: NSLocalizedString("\u{201C}%@\u{201D} in \u{201C}%@\u{201D} has been moved, renamed or deleted since it was added to the Queue.", comment: "Queue edit -> missing file text"), missing.lastPathComponent, folderName)
                    + (canLocate ? " " + NSLocalizedString("Choose Find\u{2026} to point the Queue at it, or remove it from the Queue and add it again.", comment: "Queue edit -> missing file hint") : "")
                if canLocate {
                    alert.addButton(withTitle: NSLocalizedString("Find\u{2026}", comment: "Queue edit -> locate the missing file"))
                    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
                } else {
                    alert.addButton(withTitle: NSLocalizedString("OK", comment: "Alert button"))
                }
                MovableDialog.present(alert: alert, over: window) { [weak self] response in
                    guard canLocate, response == .alertFirstButtonReturn else { return }
                    self?.locate(item: item, near: missing)
                }
            }
            return
        }

        // The editor reads the file from disk each time it opens. The size
        // shown in the list is remembered, so forget it and read it again in
        // case the file was changed outside the app.
        sizeCache[item.fileURL] = nil
        sizeCache[item.destURL] = nil

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
            self.table.reloadData(forRowIndexes: self.rebuildLayout().tableRowsIncludingFiles(forQueueIndexes: IndexSet(integer: index)), columnIndexes: allColumns)
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
        guard let index = queueIndex(forTableRow: table.row(for: sender)), let item = queue.item(at: index) else { return }
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

    private static let nameTextID = "queueRowNameText"
    private static let nameTextLeadingID = "queueRowNameTextLeading"
    private static let nameIconLeadingID = "queueRowNameIconLeading"
    private static let disclosureID = NSUserInterfaceItemIdentifier(rawValue: "queueRowDisclosure")
    private static let disclosureLeadingID = "queueRowDisclosureLeading"

    /// The little triangle in front of a folder row.
    private enum FolderTriangle {
        case none, collapsed, expanded
    }

    /// The Name cell comes from Queue.xib with fixed frames and a small info
    /// button of its own. The Info and Edit buttons now have their own column,
    /// so that old button is hidden and the name uses the whole cell, with
    /// long names cut off in the middle. Each cell has room for a disclosure
    /// triangle, then the icon, then the name; `indent` moves all three right
    /// for the files listed inside an open folder.
    private func configureNameCell(_ cell: NSTableCellView, indent: CGFloat = 0, disclosure: FolderTriangle = .none) {
        for case let legacy as NSButton in cell.subviews where legacy.action == #selector(toggleItemsOptions(_:)) {
            legacy.isHidden = true
        }

        guard let textField = cell.textField else { return }

        if cell.constraints.contains(where: { $0.identifier == QueueController.nameTextID }) == false {
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
            textField.setContentHuggingPriority(NSLayoutConstraint.Priority(250), for: .horizontal)
            let trailing = textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8)
            trailing.identifier = QueueController.nameTextID
            let textLeading = textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 41)
            textLeading.identifier = QueueController.nameTextLeadingID
            var constraints = [trailing, textLeading, textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]

            let button = NSButton(frame: .zero)
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .disclosure
            button.title = ""
            button.identifier = QueueController.disclosureID
            button.target = self
            button.action = #selector(toggleDisclosure(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(button)
            let buttonLeading = button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3)
            buttonLeading.identifier = QueueController.disclosureLeadingID
            constraints += [buttonLeading, button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]

            if let icon = cell.imageView {
                icon.translatesAutoresizingMaskIntoConstraints = false
                let iconLeading = icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 19)
                iconLeading.identifier = QueueController.nameIconLeadingID
                constraints += [
                    iconLeading,
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16)
                ]
            }
            NSLayoutConstraint.activate(constraints)
        }

        for constraint in cell.constraints {
            switch constraint.identifier {
            case QueueController.disclosureLeadingID?: constraint.constant = 3 + indent
            case QueueController.nameIconLeadingID?: constraint.constant = 19 + indent
            case QueueController.nameTextLeadingID?: constraint.constant = 41 + indent
            default: break
            }
        }

        if let button = cell.subviews.first(where: { $0.identifier == QueueController.disclosureID }) as? NSButton {
            button.isHidden = disclosure == .none
            button.state = disclosure == .expanded ? .on : .off
            button.toolTip = disclosure == .expanded
                ? NSLocalizedString("Hide the files in this folder", comment: "Queue folder row tooltip")
                : NSLocalizedString("Show the files in this folder", comment: "Queue folder row tooltip")
        }
    }

    /// The cell for the Actions column: Info (every file) and Edit (a
    /// completed file) side by side, pinned to the right.
    private func actionsCell(in tableView: NSTableView) -> NSTableCellView {
        if let cell = tableView.makeView(withIdentifier: actionsColumn, owner: self) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = actionsColumn
        let infoButton = rowButton(.info, in: cell)
        let editButton = rowButton(.edit, in: cell)
        NSLayoutConstraint.activate([
            infoButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            infoButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: infoButton.leadingAnchor, constant: -4),
            editButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    /// Info for any file, and Edit once a file is completed (or while its
    /// editor is open). Edit reopens the finished file for review; it greys
    /// out until that editor window closes. A folder heading or a release
    /// that is not a file yet shows neither.
    private func configureRowButtons(in cell: NSTableCellView, item: QueueItem?) {
        let infoButton = rowButton(.info, in: cell)
        let editButton = rowButton(.edit, in: cell)

        let editor = item.flatMap { openEditors[ObjectIdentifier($0)] }
        let showInfo = item != nil
        let showEdit = item != nil && (item?.status == .completed || editor != nil)

        infoButton.isHidden = !showInfo
        editButton.isHidden = !showEdit

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
    /// display mode: Icon Only shows just the progress bar (no text at
    /// all -- the same way the toolbar's own icon-only mode drops button
    /// titles), Text Only just the percentage (appended to the status
    /// text), Icon and Text both.
    private func refreshProgressDisplay() {
        guard queue.status == .working || mergeNamesShown.isEmpty == false else { return }

        let mode = window?.toolbar?.displayMode ?? .default
        progressBar.isHidden = mode == .labelOnly

        switch mode {
        case .iconOnly:
            // Just the bar -- no title, no percent, same as the
            // toolbar's own icon-only mode drops every button's title.
            statusLabel.stringValue = ""
            percentLabel.isHidden = true
        case .labelOnly:
            // No bar to sit the percent beside, so it stays folded into
            // the status text, same as before.
            percentLabel.isHidden = true
            if progressBar.isIndeterminate == false {
                let percent = Int(min(max(progressBar.doubleValue, 0), 100).rounded())
                statusLabel.stringValue = "\(progressStatusText) \(percent)%"
            } else {
                statusLabel.stringValue = progressStatusText
            }
        default:
            // Icon and Text: the title stays plain, and the percent is
            // its own label right next to the bar instead of appended
            // to the sentence.
            statusLabel.stringValue = progressStatusText
            if progressBar.isIndeterminate == false {
                let percent = Int(min(max(progressBar.doubleValue, 0), 100).rounded())
                percentLabel.stringValue = "\(percent)%"
                percentLabel.isHidden = false
            } else {
                percentLabel.stringValue = ""
                percentLabel.isHidden = true
            }
        }
    }

    // MARK: Merge progress in the bottom strip

    /// Folders being merged right now (or waiting for their turn), by
    /// identity, with the name to show. The progress bar and status line show
    /// a merge the same way they show a file being processed, unless the
    /// Queue itself is running and owns them.
    private var mergeNamesShown: [ObjectIdentifier: String] = [:]

    private func mergeStarted(_ release: QueueRelease, name: String) {
        mergeNamesShown[ObjectIdentifier(release)] = name
        showMergeProgress(name: name, progress: nil)
    }

    private func mergeProgressed(_ release: QueueRelease, progress: Double) {
        guard let name = mergeNamesShown[ObjectIdentifier(release)] else { return }
        showMergeProgress(name: name, progress: progress)
    }

    private func mergeEnded(_ release: QueueRelease) {
        mergeNamesShown[ObjectIdentifier(release)] = nil
        if let other = mergeNamesShown.first {
            showMergeProgress(name: other.value, progress: nil)
            return
        }
        guard queue.status != .working else { return }
        progressBar.isHidden = true
        progressBar.stopAnimation(self)
        progressBar.doubleValue = 0
        progressBar.isIndeterminate = true
        percentLabel.isHidden = true
        updateState()
    }

    private func showMergeProgress(name: String, progress: Double?) {
        guard queue.status != .working else { return }
        progressStatusText = String(format: NSLocalizedString("Merging %@", comment: "Queue -> status line while a folder is merged"), name)
        if let progress = progress {
            progressBar.stopAnimation(self)
            progressBar.isIndeterminate = false
            progressBar.doubleValue = min(max(progress, 0), 100)
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(self)
        }
        refreshProgressDisplay()
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
                             columnIndexes: allColumns)
        }
    }

    /// Keeps the single name column as wide as the table, so the buttons
    /// stay at the window's right edge when it is widened.
    func windowDidResize(_ notification: Notification) {
        table?.sizeToFit()
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
        // Saving a setting posts this notification on the same stack, while the
        // setting is still being written. Reading it back right then (the
        // "Automatically watch" switch) is a simultaneous access and aborts the
        // app, so wait until the save has finished.
        intakeDefaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.reconfigureIntakeWatching() }
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

    /// Forgets every path the Incoming Folder scan has already taken in
    /// (both queues share the one list), so whatever still sits in an
    /// Incoming Folder and isn't in a Queue is picked up again by the next
    /// scan. Rows already in a Queue are never duplicated.
    static func resetIntakeMemory() {
        UserDefaults.standard.removeObject(forKey: ingestedPathsKey)
        shared.intakeObservations.removeAll()
        tvShows.intakeObservations.removeAll()
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
        return candidate.files.contains { isTVEpisodeFile($0) }
    }

    /// True when a file's name carries an episode marker (S01E02, 1x02), or
    /// the file sits in a season folder ("Season 1"), as store purchases do.
    static func isTVEpisodeFile(_ url: URL) -> Bool {
        if ReleaseFilenameParser.parse(url.lastPathComponent)?.season != nil { return true }
        return SeasonFolderName.isInsideSeasonFolder(url)
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
        QueueWindowController.shared.showIfHidden(tvQueue)
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
                // Its subtitle files go in the same folder.
                for companion in candidate.companions {
                    try? fileManager.moveItem(at: companion, to: wrapper.appendingPathComponent(companion.lastPathComponent))
                }
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
        // A file sent from the Library scan is treated the same way.
        let editInPlace = MediaIntakePrefs.shouldEditInPlace(url)
            || QueueController.inPlaceSourcePaths.contains(url.standardizedFileURL.path)
        let destURL = editInPlace ? url : destination(for: url)
        let item = QueueItem(fileURL: url, destination: destURL, sourceFolderURL: sourceFolderURL)
        item.editsInPlace = editInPlace
        // A file sent from the Library scan brings the scan's tag columns.
        if editInPlace, let seed = QueueController.inPlaceSeedValues[url.standardizedFileURL.path] {
            item.trackedTagKeys = QueueController.inPlaceTagKeys
            tagValues.seed(item, values: seed)
        }

        if prefs.clearExistingMetadata {
            item.addAction(QueueClearExistingMetadataAction())
        }
        // A file the Library scan matched to a library server's item is filled
        // from that item (only the tags it lacks), whatever the search setting.
        let known = editInPlace ? QueueController.inPlaceKnownItems[url.standardizedFileURL.path] : nil
        if let known = known {
            item.addAction(QueueMetadataAction(movieLanguage: prefs.movieProviderLanguage,tvShowLanguage: prefs.tvShowProviderLanguage, movieProvider: prefs.movieProvider, tvShowProvider: prefs.tvShowProvider, preferredArtwork: prefs.providerArtwork, preferredArtworkSize: prefs.providerArtworkSize, existingTags: ExistingTagsMode.fillMissing.rawValue, keepEmptyAnnotations: false, knownSource: known.source, knownItemID: known.id))
        } else if prefs.searchMetadata {
            item.addAction(QueueMetadataAction(movieLanguage: prefs.movieProviderLanguage,tvShowLanguage: prefs.tvShowProviderLanguage, movieProvider: prefs.movieProvider, tvShowProvider: prefs.tvShowProvider, preferredArtwork: prefs.providerArtwork, preferredArtworkSize: prefs.providerArtworkSize, existingTags: prefs.existingTags, keepEmptyAnnotations: prefs.keepEmptyAnnotations))
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
            item.addAction(QueueSetAction(preset: set, setWins: true))
        }
        if prefs.optimize {
            item.addAction(QueueOptimizeAction())
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

        // With folder rows open the table has more rows than the Queue, so the
        // animated insert below would put the new rows in the wrong place:
        // redraw instead.
        // An animated insert into a table that is not on screen (the other
        // tab) can leave rows without their cells, so redraw it instead.
        let foldersOpen = rebuildLayout().hasExpansions || canAnimateRowChanges == false
        if foldersOpen == false { table.beginUpdates() }

        // Forward
        var currentIndex = firstIndex
        var currentObjectIndex = 0

        while currentIndex != NSNotFound {
            queue.insert(rows[currentObjectIndex], at: currentIndex)
            currentIndex = indexes.integerGreaterThan(currentIndex) ?? NSNotFound
            currentObjectIndex += 1
        }

        if foldersOpen {
            table.reloadData()
        } else {
            table.insertRows(at: indexes, withAnimation: .slideDown)
            table.endUpdates()
        }
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

    /// True when the table is on screen, so inserting and removing rows can
    /// be animated. A table on the tab that is not showing is simply redrawn.
    private var canAnimateRowChanges: Bool {
        guard let table = table else { return false }
        return table.window != nil && table.isHiddenOrHasHiddenAncestor == false
    }

    /// Redraws every row. Used when this tab is brought to the front, so rows
    /// added while it was out of sight are shown properly.
    func reloadTable() {
        table?.reloadData()
    }

    private func removeRows(at requestedIndexes: IndexSet) {
        if requestedIndexes.isEmpty {
            return
        }

        let indexes = indexesIncludingOrphanedFolderHeaders(requestedIndexes)

        let foldersOpen = rebuildLayout().hasExpansions || canAnimateRowChanges == false
        if foldersOpen == false { table.beginUpdates() }

        let removedRows = queue.rows(at: indexes)

        if queue.count > indexes.last! {
            queue.remove(at: indexes)
        }

        if foldersOpen {
            table.reloadData()
        } else {
            table.removeRows(at: indexes, withAnimation: .slideUp)
        }
        if let index = indexes.first, index < queue.count {
            table.selectRowIndexes(tableRows(forQueueIndexes: IndexSet(integer: index)), byExtendingSelection: false)
        }

        if foldersOpen == false { table.endUpdates() }
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

        let foldersOpen = rebuildLayout().hasExpansions
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

            if foldersOpen == false {
                table.moveRow(at: sourceIndex, to: currentIndex)
            }
        }

        table.endUpdates()
        if foldersOpen { table.reloadData() }

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

        let foldersOpen = rebuildLayout().hasExpansions
        table.beginUpdates()

        for (sourceIndex, destIndex) in zip(source, dest).reversed() {
            newSource.append(destIndex)
            newDest.append(sourceIndex)

            if let row = queue.rows(at: IndexSet(integer: sourceIndex)).first {
                queue.remove(at: IndexSet(integer: sourceIndex))
                queue.insert(row, at: destIndex)

                if foldersOpen == false {
                    table.moveRow(at: sourceIndex, to: destIndex)
                }
            }
        }

        table.endUpdates()
        if foldersOpen { table.reloadData() }

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
        let queued = QueueDuplicates.sourcePaths(of: queue.allRows)

        if let isDirectory = value?.isDirectory, isDirectory == true,
            let directoryEnumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [URLResourceKey.nameKey, URLResourceKey.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: nil) {

            var found: [URL] = []
            for case let fileURL as URL in directoryEnumerator {
                let fileValue = try? fileURL.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
                if fileValue?.isDirectory != true, supportedFileFormats.contains(fileURL.pathExtension.lowercased()) {
                    found.append(fileURL)
                }
            }
            // A subtitle file beside a video is loaded into it, not a row of its own.
            for fileURL in SidecarSubtitles.partition(found).media {
                if queued.contains(QueueDuplicates.key(for: fileURL)) {
                    duplicatesSkipped += 1
                    continue
                }
                items.append(createItem(url: fileURL))
            }
            items.sort { return $0.fileURL.lastPathComponent.localizedStandardCompare($1.fileURL.lastPathComponent) == ComparisonResult.orderedAscending }
        } else if supportedFileFormats.contains(url.pathExtension.lowercased()) {
            if queued.contains(QueueDuplicates.key(for: url)) {
                duplicatesSkipped += 1
            } else {
                items.append(createItem(url: url))
            }
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
    ///
    /// A folder is searched a few levels down, so a show folder holding
    /// Season folders adds one group per Season folder.
    ///
    /// Each file goes to the tab it belongs on: files whose names carry an episode
    /// marker (or that sit in a Season folder) to the TV Shows tab, all
    /// others to the Movies tab, whichever tab they were added to. A folder
    /// holding both kinds is split file by file.
    func insertGrouped(_ urls: [URL], at index: Int) {
        let sortedURLs = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == ComparisonResult.orderedAscending }
        var insertionIndex = min(max(index, 0), queue.count)
        let other = isTVShowQueue ? QueueController.shared : QueueController.tvShows
        let supportedFileFormats = MP42FileImporter.supportedFileFormats()
        var sentToOther = 0
        duplicatesSkipped = 0
        other.duplicatesSkipped = 0

        // True when the file belongs on this tab.
        let belongsHere: (URL) -> Bool = { [unowned self] in
            return QueueTabRouting.belongs($0, onTVShowsTab: self.isTVShowQueue)
        }

        for url in sortedURLs {
            let isDirectory = (try? url.resourceValues(forKeys: [URLResourceKey.isDirectoryKey]))?.isDirectory ?? false

            guard isDirectory else {
                if belongsHere(url) {
                    let countBefore = queue.count
                    insert(contentOf: [url], at: insertionIndex)
                    insertionIndex += queue.count - countBefore
                } else {
                    let countBefore = other.count
                    other.insert(contentOf: [url], at: other.count)
                    sentToOther += other.count - countBefore
                }
                continue
            }

            let folders = QueueMediaFolders.folders(startingAt: url) { supportedFileFormats.contains($0.pathExtension.lowercased()) }
            for folder in folders {
                sentToOther += other.insertFolder(folder, at: other.count, include: { belongsHere($0) == false })
                let countBefore = queue.count
                insertFolder(folder, at: insertionIndex, include: belongsHere)
                insertionIndex += queue.count - countBefore
            }
        }

        var messages: [String] = []
        if sentToOther > 0 {
            messages.append(QueueTabRouting.statusMessage(movedCount: sentToOther, addedToTVShowsTab: isTVShowQueue))
        }
        let skipped = duplicatesSkipped + other.duplicatesSkipped
        if skipped > 0 {
            messages.append(String.localizedStringWithFormat(NSLocalizedString("%lu file(s) were already in the Queue and were not added again.", comment: "Queue -> files skipped because they are already queued"), skipped))
        }
        if messages.isEmpty == false {
            statusLabel.stringValue = messages.joined(separator: " ")
        }
    }

    /// The paths of files being added by addForInPlaceEdit(_:) right now,
    /// so createItem(url:) edits them where they are.
    private static var inPlaceSourcePaths: Set<String> = []
    /// The Library scan's tag columns, and each file's values at the moment
    /// it was sent, for the files being added by addForInPlaceEdit(_:tagKeys:).
    private static var inPlaceTagKeys: [String] = []
    private static var inPlaceSeedValues: [String: [String: String]] = [:]
    /// For files sent from a library-server scan: the source's name and the
    /// server's item id, by file path. Those files get their metadata from
    /// that item (no title search).
    private static var inPlaceKnownItems: [String: (source: String, id: String)] = [:]

    /// Adds files from the Library scan: each goes to the Movies or TV Shows
    /// Queue as usual, but is edited where it sits (tags written into the
    /// file, no copy and no move to the library). Returns how many went
    /// to each Queue and how many were skipped as already queued.
    ///
    /// `tagKeys` are the Library scan's tag columns; each file brings its
    /// values from the scan (a tag with no entry was missing). The Queue
    /// shows them as columns and reads each file again when it is done.
    @discardableResult
    func addForInPlaceEdit(_ files: [(url: URL, values: [String: String])], tagKeys: [String], knownItems: [URL: (source: String, id: String)] = [:]) -> (movies: Int, tvShows: Int, skipped: Int) {
        let moviesBefore = QueueController.shared.count
        let tvBefore = QueueController.tvShows.count
        QueueController.inPlaceSourcePaths = Set(files.map { $0.url.standardizedFileURL.path })
        QueueController.inPlaceTagKeys = tagKeys
        QueueController.inPlaceSeedValues = Dictionary(files.map { ($0.url.standardizedFileURL.path, $0.values) }, uniquingKeysWith: { first, _ in first })
        QueueController.inPlaceKnownItems = Dictionary(knownItems.map { ($0.key.standardizedFileURL.path, $0.value) }, uniquingKeysWith: { first, _ in first })
        defer {
            QueueController.inPlaceSourcePaths = []
            QueueController.inPlaceTagKeys = []
            QueueController.inPlaceSeedValues = [:]
            QueueController.inPlaceKnownItems = [:]
        }
        QueueController.shared.insertGrouped(files.map { $0.url }, at: QueueController.shared.count)
        QueueController.shared.syncTagColumns()
        QueueController.tvShows.syncTagColumns()
        let skipped = QueueController.shared.duplicatesSkipped + QueueController.tvShows.duplicatesSkipped
        return (QueueController.shared.count - moviesBefore, QueueController.tvShows.count - tvBefore, skipped)
    }

    /// Files skipped by the latest add because they were already in this
    /// Queue and not yet completed.
    private(set) var duplicatesSkipped = 0

    /// Direct children of folderURL (same non-recursive convention as
    /// makeRelease(contentOf:)) that are in a format this app can queue,
    /// each tagged with sourceFolderURL so its row renders indented under
    /// folderURL's own header row -- see insertFolder(_:at:) below.
    private func items(contentOfFolder folderURL: URL, include: (URL) -> Bool = { _ in true }) -> [QueueItem] {
        let supportedFileFormats = MP42FileImporter.supportedFileFormats()

        guard let directoryEnumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [URLResourceKey.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: nil) else {
            return []
        }

        var items: [QueueItem] = []
        let queued = QueueDuplicates.sourcePaths(of: queue.allRows)
        var found: [URL] = []
        for case let fileURL as URL in directoryEnumerator {
            let value = try? fileURL.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
            if value?.isDirectory != true, supportedFileFormats.contains(fileURL.pathExtension.lowercased()), include(fileURL) {
                found.append(fileURL)
            }
        }
        // A subtitle file beside a video is loaded into it, not a row of its own.
        for fileURL in SidecarSubtitles.partition(found).media {
            if queued.contains(QueueDuplicates.key(for: fileURL)) {
                duplicatesSkipped += 1
                continue
            }
            items.append(createItem(url: fileURL, sourceFolderURL: folderURL))
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
    ///
    /// `include` limits which of the folder's files are added. Returns how
    /// many files were added.
    @discardableResult
    func insertFolder(_ folderURL: URL, at index: Int, include: (URL) -> Bool = { _ in true }) -> Int {
        let children = items(contentOfFolder: folderURL, include: include)
        guard children.isEmpty == false else { return 0 }

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
        return children.count
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
        let fileURLs = QueueController.mediaFiles(in: folderURL)

        guard fileURLs.isEmpty == false else { return nil }

        let release = QueueRelease(folderURL: folderURL, sourceFileURLs: fileURLs)

        // A folder that holds the parts and also a file as big as all of them
        // together was probably merged already. Merging again would only make
        // a second copy, so it is set aside for a person to look at.
        let sized = fileURLs.map { (url: $0, size: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)) }
        if let found = AlreadyMergedDetector.find(in: sized) {
            release.stage = .alreadyMerged
            release.existingMergedFileURL = found.merged
        }

        return release
    }

    /// The media files directly inside `folderURL`, in natural name order.
    static func mediaFiles(in folderURL: URL) -> [URL] {
        let supportedFileFormats = MP42FileImporter.supportedFileFormats()

        guard let directoryEnumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [URLResourceKey.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles], errorHandler: nil) else {
            return []
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in directoryEnumerator {
            let value = try? fileURL.resourceValues(forKeys: [URLResourceKey.isDirectoryKey])
            if value?.isDirectory != true, supportedFileFormats.contains(fileURL.pathExtension.lowercased()) {
                fileURLs.append(fileURL)
            }
        }
        fileURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == ComparisonResult.orderedAscending }
        // A subtitle file beside a video is not a part of the movie.
        return SidecarSubtitles.partition(fileURLs).media
    }

    // MARK: Files changed outside the app

    private var lastDiskRefresh = Date.distantPast

    /// A folder row can be re-read from disk while nothing has been decided
    /// about it yet: not merged, not merging, not already turned into a file.
    private func canRescan(_ release: QueueRelease) -> Bool {
        guard release.resolvedItem == nil, release.mergedFileURL == nil else { return false }
        switch release.stage {
        case .pendingNaming, .namingRejected, .pendingMergeSelection, .mergeFailed, .pendingMetadata:
            return true
        default:
            return false
        }
    }

    /// Re-reads one folder row from disk right now, so the window about to
    /// open for it (naming, merge order, metadata, already merged) shows the
    /// folder as it is, not as it was when it was added. Returns true when
    /// something changed.
    @discardableResult
    private func rescan(_ release: QueueRelease) -> Bool {
        guard release.stage == .alreadyMerged || canRescan(release),
              release.resolvedItem == nil, release.mergedFileURL == nil,
              let fresh = makeRelease(contentOf: release.folderURL)
        else { return false }

        var changed = false
        if fresh.sourceFileURLs != release.sourceFileURLs {
            release.sourceFileURLs = fresh.sourceFileURLs
            changed = true
            // Files taken out of the folder since: one left needs no merge.
            if adoptSingleFileStage(release) { changed = true }
        }
        // The merged file that held a folder back may have been moved or
        // deleted since (or turned up since).
        if release.stage == .alreadyMerged, fresh.stage != .alreadyMerged {
            release.stage = fresh.stage
            release.existingMergedFileURL = nil
            changed = true
        } else if release.stage == .alreadyMerged {
            release.existingMergedFileURL = fresh.existingMergedFileURL
        }

        if changed {
            for url in release.sourceFileURLs { sizeCache[url] = nil }
            try? queue.saveToDisk()
            table.reloadData()
        }
        return changed
    }

    /// A folder waiting for a merge order whose files were taken out in Finder,
    /// leaving just one, has nothing to merge any more: it becomes a
    /// single-file release (see ReleaseRescanStage). Returns true when its
    /// stage changed.
    private func adoptSingleFileStage(_ release: QueueRelease) -> Bool {
        let stage = ReleaseRescanStage.stage(after: release.stage, fileCount: release.sourceFileURLs.count, hasMergedFile: release.mergedFileURL != nil)
        guard stage != release.stage else { return false }
        pendingAutoMerges.removeValue(forKey: release.id)?.cancel()
        release.stage = stage
        release.mergeErrorMessage = nil
        release.mergeOrder = nil
        return true
    }

    /// Re-reads from disk what the list shows: every file's size, and the
    /// files inside folders that are still waiting for a decision, so a file
    /// changed, added or removed in Finder shows up here. Runs in the
    /// background; at most once every few seconds.
    func refreshFromDisk() {
        guard Date().timeIntervalSince(lastDiskRefresh) > 5 else { return }
        lastDiskRefresh = Date()

        let rows = queue.allRows
        let sizeURLs = Array(Set(rows.flatMap { $0.sizeSourceURLs }))
        let folders = rows.compactMap { row -> QueueRelease? in
            guard let release = row.release, canRescan(release) else { return nil }
            return release
        }
        let folderURLs = folders.map { $0.folderURL }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var sizes: [URL: Int64] = [:]
            for url in sizeURLs {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                sizes[url] = size.map { Int64($0) } ?? -1
            }
            let listings = folderURLs.map { QueueController.mediaFiles(in: $0) }

            DispatchQueue.main.async {
                guard let self = self else { return }
                var changed = false

                for (release, files) in zip(folders, listings) where files.isEmpty == false && files != release.sourceFileURLs && self.canRescan(release) {
                    release.sourceFileURLs = files
                    changed = true
                    if self.adoptSingleFileStage(release) {
                        self.attemptAutoResolveMetadata(for: release)
                    }
                }
                for (url, size) in sizes where self.sizeCache[url] != size {
                    self.sizeCache[url] = size
                    changed = true
                }

                if changed {
                    try? self.queue.saveToDisk()
                    self.table.reloadData()
                }
            }
        }
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
            case .pendingNaming, .namingRejected, .pendingMetadata, .pendingMergeSelection, .mergeFailed, .alreadyMerged:
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
            existing.stage = release.stage
            existing.existingMergedFileURL = release.existingMergedFileURL
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
        // The files listed under an open folder follow their folder's status.
        table.reloadData(forRowIndexes: rebuildLayout().tableRowsIncludingFiles(forQueueIndexes: indexes), columnIndexes: allColumns)
        updateState()
    }

    private func updateUI() {
        table.reloadData()
        updateState()
    }

    private func updateState() {
        if queue.status != .working {
            // The counts are on the second line (statsLabel).
            statusLabel.stringValue = queue.count == 0
                ? NSLocalizedString("The queue is empty.", comment: "Queue status")
                : NSLocalizedString("Ready.", comment: "Queue status")
        }
        refreshStats()
        updateDockTile()
        syncTagColumns()
    }

    /// Set while a Start-time "run for a time limit" choice is active;
    /// invalidated on completion, on manual Stop, and before a fresh one
    /// is scheduled, so a stale timer from an earlier run can never fire
    /// into a later one.
    private var runTimeLimitTimer: Timer?

    /// What presentRunDurationPrompt(in:completion:) can answer with --
    /// nil from that method itself means "Cancel", not "until done".
    private enum RunDurationChoice {
        case untilDone
        case limited(TimeInterval)
    }

    /// Preset choices offered in the Start-time run-duration sheet, each
    /// a whole number of minutes; -1 marks the "type your own" option,
    /// read from the sheet's accessory text field instead. Hans asked
    /// for this 2026-10-13, wondering about a "run for one hour, then
    /// pause" option.
    private static let runDurationPresets: [(title: String, minutes: Int)] = [
        (NSLocalizedString("Until done", comment: "Queue run duration"), 0),
        (NSLocalizedString("30 minutes", comment: "Queue run duration"), 30),
        (NSLocalizedString("1 hour", comment: "Queue run duration"), 60),
        (NSLocalizedString("2 hours", comment: "Queue run duration"), 120),
        (NSLocalizedString("4 hours", comment: "Queue run duration"), 240),
        (NSLocalizedString("Custom (minutes below)\u{2026}", comment: "Queue run duration"), -1)
    ]

    /// Asks, every time Start is clicked, whether to run until the queue
    /// is empty or stop automatically after a time limit. Answered via
    /// `completion`: nil means Cancel (don't start at all); .untilDone
    /// or .limited(seconds) otherwise. A sheet on `window` rather than
    /// an app-modal alert, so it doesn't block anything else Hans might
    /// be doing while it's up.
    private func presentRunDurationPrompt(in window: NSWindow, completion: @escaping (RunDurationChoice?) -> Void) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Run the queue for how long?", comment: "Queue run duration prompt")
        alert.informativeText = NSLocalizedString("Whatever file or merge is in progress when a time limit is reached always finishes; only the next one waits. Click Start again anytime to pick up where it left off.", comment: "Queue run duration prompt")
        alert.addButton(withTitle: NSLocalizedString("Start", comment: "Queue run duration prompt"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Queue run duration prompt"))

        // .zero frame + explicit width constraints, same convention as
        // the popups/fields in CustomSourcesListViewController.swift,
        // DestinationsViewController.swift and
        // SingleFileMetadataReviewWindowController.swift -- an alert's
        // accessoryView is autolayout, not frame-based.
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        for preset in QueueController.runDurationPresets {
            popup.addItem(withTitle: preset.title)
        }

        let customField = NSTextField(frame: .zero)
        customField.translatesAutoresizingMaskIntoConstraints = false
        customField.placeholderString = NSLocalizedString("minutes", comment: "Queue run duration -- custom minutes field placeholder")
        customField.alignment = .right

        let stack = NSStackView(views: [popup, customField])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            popup.widthAnchor.constraint(equalToConstant: 200),
            customField.widthAnchor.constraint(equalToConstant: 70),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        alert.accessoryView = container

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }

            let index = popup.indexOfSelectedItem
            guard index >= 0, index < QueueController.runDurationPresets.count else {
                completion(.untilDone)
                return
            }

            let minutes = QueueController.runDurationPresets[index].minutes
            if minutes == 0 {
                completion(.untilDone)
            } else if minutes == -1 {
                let typed = Int(customField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
                completion(typed > 0 ? .limited(TimeInterval(typed * 60)) : .untilDone)
            } else {
                completion(.limited(TimeInterval(minutes * 60)))
            }
        }
    }

    /// Starts the queue immediately, with no time limit -- used by
    /// AppleScript's Start/"start and wait" commands (QueueScriptCommand.swift)
    /// and MediaIntakePrefs.autoStart's "start as soon as something is
    /// added" behavior, neither of which should ever block on a dialog
    /// nobody is there to answer. The toolbar/menu Start control a
    /// person actually clicks goes through toggleStartStop(_:) below
    /// instead, which asks first.
    @IBAction func start(_ sender: Any?) {
        if queue.status == .working {
            return
        }
        beginTimedRun(timeLimit: nil)
    }

    /// The actual startup work Start used to do directly, now shared by
    /// both answers to presentRunDurationPrompt(in:completion:).
    /// `timeLimit`, when given, schedules runTimeLimitTimer to call
    /// queue.pauseAfterCurrentItem() once it fires -- the item or merge
    /// in progress at that moment still finishes; only the next one
    /// waits (see Queue.pauseAfterCurrentItem()'s own doc comment).
    private func beginTimedRun(timeLimit: TimeInterval?) {
        QueueWindowController.existing?.setRunning(true, for: self)
        statusLabel.stringValue = NSLocalizedString("Working.", comment: "Queue -> Working")
        progressBar.isHidden = (window?.toolbar?.displayMode ?? .default) == .labelOnly
        percentLabel.isHidden = true
        progressBar.startAnimation(self)

        window?.undoManager?.removeAllActions(withTarget: self)

        runTimeLimitTimer?.invalidate()
        runTimeLimitTimer = nil
        if let timeLimit = timeLimit {
            runTimeLimitTimer = Timer.scheduledTimer(withTimeInterval: timeLimit, repeats: false) { [weak self] _ in
                self?.queue.pauseAfterCurrentItem()
            }
        }

        beginRunStats()
        queue.start()
    }

    @IBAction func stop(_ sender: Any?) {
        runTimeLimitTimer?.invalidate()
        runTimeLimitTimer = nil
        queue.stop()
    }

    /// The toolbar button and menu item both wire to this (see
    /// QueueToolbarDelegate.swift and MainMenu.xib's toggleStartStop:),
    /// not directly to start(_:) -- so this is the one genuinely
    /// human-clicked path, and the only place the run-duration prompt
    /// belongs. If somehow there's no window to sheet onto, fall back
    /// to start(_:)'s no-prompt behavior rather than silently doing
    /// nothing.
    @IBAction func toggleStartStop(_ sender: Any?) {
        if queue.status == .working {
            stop(self)
            return
        }
        guard let window = window else {
            start(self)
            return
        }
        presentRunDurationPrompt(in: window) { [weak self] choice in
            guard let self = self, let choice = choice else { return }
            switch choice {
            case .untilDone: self.beginTimedRun(timeLimit: nil)
            case .limited(let seconds): self.beginTimedRun(timeLimit: seconds)
            }
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
        guard let index = queueIndex(forTableRow: table.row(for: sender)), let item = queue.item(at: index) else { return }

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
        return rebuildLayout().count
    }

    /// Folder rows currently open, by identity (so a sort or drag keeps them
    /// open), and the table-row numbering that goes with them.
    /// Folder rows start open, so what is remembered is the ones the user
    /// closed. That way every folder, new or restored, shows its files
    /// until it is closed.
    private var collapsedRows = Set<ObjectIdentifier>()
    private var layout = QueueOutlineLayout(rowCount: 0, expanded: [], fileCount: { _ in 0 })

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
        case .pendingNaming, .pendingMetadata, .pendingMergeSelection, .pendingLibraryMove, .alreadyMerged:
            // A release is a folder of files, not a single file yet.
            return NSImage(named: NSImage.folderName)
        case .merging:
            return NSImage(named: "EncodeWorking")
        case .namingRejected, .mergeFailed:
            return NSImage(named: "EncodeCanceled")
        case .done:
            return NSImage(named: "EncodeComplete")
        }
    }

    // MARK: Columns and sorting

    private let statusColumn = NSUserInterfaceItemIdentifier(rawValue: "statusColumn")
    private let sizeColumn = NSUserInterfaceItemIdentifier(rawValue: "sizeColumn")
    private let kindColumn = NSUserInterfaceItemIdentifier(rawValue: "kindColumn")
    private let numberColumn = NSUserInterfaceItemIdentifier(rawValue: "numberColumn")
    private let actionsColumn = NSUserInterfaceItemIdentifier(rawValue: "actionsColumn")

    /// File sizes already read, by file. -1 means the size could not be read.
    private var sizeCache: [URL: Int64] = [:]
    private var sizeRequests = Set<URL>()
    private var ignoreSortChange = false

    private var allColumns: IndexSet {
        return IndexSet(integersIn: 0..<max(table?.numberOfColumns ?? 1, 1))
    }

    /// Adds the "#", Status, Size, Type and Actions columns around the Name
    /// column and makes every header except Actions sortable. Both Queue
    /// windows use this same code, so they stay identical. To add a column:
    /// a case in QueueSortColumn, a line here and a branch in the cell code.
    private func configureColumns() {
        guard let nameCol = table.tableColumns.first else { return }
        nameCol.title = NSLocalizedString("Name", comment: "Queue column title")
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: QueueSortColumn.name.rawValue, ascending: true)
        // Name takes up whatever room the window has; the others keep their width.
        nameCol.resizingMask = [.autoresizingMask, .userResizingMask]
        nameCol.minWidth = 160
        // With many tag columns the table can be wider than the window.
        table.enclosingScrollView?.hasHorizontalScroller = true
        table.enclosingScrollView?.autohidesScrollers = true

        func add(_ identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat = 40, key: QueueSortColumn?) {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = minWidth
            column.maxWidth = 400
            column.resizingMask = .userResizingMask
            if let key = key {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            }
            table.addTableColumn(column)
        }
        add(numberColumn, title: "#", width: 38, minWidth: 28, key: .added)
        add(statusColumn, title: NSLocalizedString("Status", comment: "Queue column title"), width: 140, key: .status)
        add(sizeColumn, title: NSLocalizedString("Size", comment: "Queue column title"), width: 80, key: .size)
        add(kindColumn, title: NSLocalizedString("Type", comment: "Queue column title"), width: 60, key: .kind)
        add(actionsColumn, title: "", width: 110, minWidth: 60, key: nil)

        // "#" goes on the far left, in front of Name.
        if let index = table.tableColumns.firstIndex(where: { $0.identifier == numberColumn }) {
            table.moveColumn(index, toColumn: 0)
        }

        // Sorting by a header's key shows an arrow there; the columns without
        // a key (Actions) get a plain header.
        for column in table.tableColumns {
            let key = column.sortDescriptorPrototype?.key
            let header = QueueHeaderCell(textCell: column.title)
            header.sortKey = key
            header.alignment = column.identifier == numberColumn ? .center : .left
            column.headerCell = header
        }

        // Columns can be dragged into a new order (see shouldReorderColumn:
        // "#" stays first and Actions last) and dragged wider or narrower.
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 23))
        // ".v2": the saved column layout from before "#" and Actions existed
        // would put them in the wrong place, so a new layout name starts fresh.
        table.autosaveName = isTVShowQueue ? "SBTVQueueTable.v2" : "SBQueueTable.v2"
        table.autosaveTableColumns = true
    }

    // MARK: Tag columns (files sent from the Library scan)

    /// The values shown in this Queue's tag columns.
    private let tagValues = QueueTagValues()

    /// Adds a column for each tag tracked by the Queue's items (files sent
    /// from the Library scan), and removes them when no item needs them any
    /// more. The columns sit just before Actions.
    func syncTagColumns() {
        guard let table = table else { return }
        var keys: [String] = []
        var items: [QueueItem] = []
        for row in queue.allRows {
            guard let item = row.effectiveItem, item.trackedTagKeys.isEmpty == false else { continue }
            items.append(item)
            for key in item.trackedTagKeys where keys.contains(key) == false { keys.append(key) }
        }
        tagValues.prune(keeping: items)

        let wanted = keys.map { QueueTagValues.columnIdentifier(forKey: $0) }
        let current = table.tableColumns.map { $0.identifier.rawValue }.filter { QueueTagValues.tagKey(ofColumn: $0) != nil }
        guard wanted != current else { return }

        for column in table.tableColumns where QueueTagValues.tagKey(ofColumn: column.identifier.rawValue) != nil && wanted.contains(column.identifier.rawValue) == false {
            // A column that is going away cannot stay the sort column.
            if table.sortDescriptors.first?.key == column.identifier.rawValue {
                ignoreSortChange = true
                table.sortDescriptors = []
                ignoreSortChange = false
            }
            table.removeTableColumn(column)
        }
        for key in keys {
            let id = QueueTagValues.columnIdentifier(forKey: key)
            guard table.tableColumns.contains(where: { $0.identifier.rawValue == id }) == false else { continue }
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = LibraryScanCell.title(forKey: key)
            column.width = 120
            column.minWidth = 50
            column.maxWidth = 400
            column.resizingMask = .userResizingMask
            // Clicking the heading sorts the Queue by this tag.
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            let header = QueueHeaderCell(textCell: column.title)
            header.sortKey = id
            header.alignment = .left
            column.headerCell = header
            table.addTableColumn(column)
            if let actions = table.tableColumns.firstIndex(where: { $0.identifier == actionsColumn }),
               let added = table.tableColumns.firstIndex(where: { $0 === column }), added != actions - 1 {
                table.moveColumn(added, toColumn: actions)
            }
        }
        fitNameColumn()
        table.reloadData()
    }

    /// Gives the Name column whatever width the other columns leave, so a
    /// column added after the window was laid out is not pushed off the
    /// right edge. When the columns are wider than the window, Name keeps its
    /// minimum width and the table scrolls sideways.
    private func fitNameColumn() {
        guard let table = table, let nameCol = table.tableColumn(withIdentifier: nameColumn) else { return }
        let visible = table.enclosingScrollView?.contentView.bounds.width ?? table.bounds.width
        let others = table.tableColumns.filter { $0 !== nameCol }.reduce(CGFloat(0)) { $0 + $1.width }
        let spacing = table.intercellSpacing.width * CGFloat(table.numberOfColumns)
        nameCol.width = max(nameCol.minWidth, visible - others - spacing)
    }

    private func tagCell(in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier, row queueRow: QueueRow) -> NSTableCellView {
        let cell = infoCell(in: tableView, identifier: identifier)
        cell.toolTip = nil
        cell.textField?.textColor = .secondaryLabelColor
        cell.textField?.stringValue = ""
        guard let key = QueueTagValues.tagKey(ofColumn: identifier.rawValue),
              let item = queueRow.effectiveItem, item.trackedTagKeys.contains(key) else { return cell }

        let reload: () -> Void = { [weak self, weak queueRow] in
            guard let self = self, let table = self.table, let queueRow = queueRow else { return }
            let index = self.queue.index(of: queueRow)
            guard index >= 0 else { return }
            let column = table.column(withIdentifier: identifier)
            guard column >= 0 else { return }
            table.reloadData(forRowIndexes: self.tableRows(forQueueIndexes: IndexSet(integer: index)), columnIndexes: IndexSet(integer: column))
        }

        switch tagValues.text(for: item, key: key, refreshed: reload) {
        case .loading:
            cell.textField?.stringValue = "\u{2014}"
        case .value(let text):
            cell.textField?.stringValue = text
            cell.textField?.textColor = .labelColor
            cell.toolTip = text
        case .missing:
            cell.textField?.stringValue = LibraryScanCell.missingText
            cell.textField?.textColor = .systemRed
        }
        return cell
    }

    private func infoCell(in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.textColor = .secondaryLabelColor
        field.alignment = identifier == sizeColumn ? .right : (identifier == numberColumn ? .center : .left)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func sizeText(for row: QueueRow) -> String {
        let urls = row.sizeSourceURLs
        guard urls.isEmpty == false else { return "" }

        var total: Int64 = 0
        var missing: [URL] = []
        var unknown = false
        for url in urls {
            if let size = sizeCache[url] {
                if size < 0 { unknown = true } else { total += size }
            } else {
                missing.append(url)
            }
        }
        if missing.isEmpty == false {
            fetchSizes(missing) { [weak self] in
                guard let self = self, let table = self.table, table.numberOfRows > 0 else { return }
                let column = table.column(withIdentifier: self.sizeColumn)
                guard column >= 0 else { return }
                table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: column))
            }
            return "\u{2014}"
        }
        return unknown ? "\u{2014}" : ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Reads file sizes off the main thread (a slow or damaged drive must not
    /// freeze the Queue) and calls `completion` on the main thread.
    /// `force` is for a caller that must wait for the sizes (sorting): it
    /// reads them even if a redraw already asked, and always calls back.
    private func fetchSizes(_ urls: [URL], force: Bool = false, completion: @escaping () -> Void) {
        let wanted = urls.filter { sizeCache[$0] == nil && (force || sizeRequests.contains($0) == false) }
        guard wanted.isEmpty == false else {
            if force { completion() }
            return
        }
        sizeRequests.formUnion(wanted)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [URL: Int64] = [:]
            for url in wanted {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                found[url] = size.map { Int64($0) } ?? -1
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for (url, size) in found { self.sizeCache[url] = size }
                self.sizeRequests.subtract(wanted)
                completion()
            }
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard ignoreSortChange == false,
              let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key
        else { return }
        if let tag = QueueTagValues.tagKey(ofColumn: key) {
            sortQueue(by: .tag, tagKey: tag, ascending: descriptor.ascending)
        }
        else if let column = QueueSortColumn(rawValue: key), column != .tag {
            sortQueue(by: column, ascending: descriptor.ascending)
        }
    }

    /// "#" always stays at the far left and Actions at the far right; the
    /// columns in between can be dragged anywhere.
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        let columns = tableView.tableColumns
        guard columns.indices.contains(columnIndex) else { return false }
        let moving = columns[columnIndex].identifier
        if moving == numberColumn || moving == actionsColumn { return false }
        return newColumnIndex >= 1 && newColumnIndex <= columns.count - 2
    }

    /// Reorders the Queue itself, which is also the order files are processed
    /// in. Can be undone, and rows can still be dragged afterwards.
    private func sortQueue(by column: QueueSortColumn, tagKey: String? = nil, ascending: Bool) {
        let apply: () -> Void = { [weak self] in
            guard let self = self else { return }
            let before = self.queue.allRows
            let selected = self.selectedQueueIndexes.filter { $0 < before.count }.map { before[$0] }
            let sizes = self.sizeCache
            let tagValues = self.tagValues

            self.queue.reorder { current in
                let entries = current.map { row -> QueueSortEntry in
                    var text = ""
                    if let key = tagKey, let item = row.effectiveItem { text = tagValues.knownText(for: item, key: key) ?? "" }
                    return row.sortEntry(sizes: sizes, tagText: text)
                }
                return QueueSorter.order(of: entries, by: column, ascending: ascending).map { current[$0] }
            }
            self.finishReorder(restoring: before, selected: selected, clearSortIndicator: false, actionName: NSLocalizedString("Sort Queue", comment: "Queue -> sort undo action name"))
        }

        if column == .tag, let key = tagKey {
            // Every file's value is needed first; unread files are read now.
            let items = queue.allRows.compactMap { $0.effectiveItem }.filter { $0.trackedTagKeys.contains(key) }
            tagValues.load(items, completion: apply)
            return
        }
        if column == .size {
            let urls = queue.allRows.flatMap { $0.sizeSourceURLs }
            if urls.contains(where: { sizeCache[$0] == nil }) {
                fetchSizes(urls, force: true, completion: apply)
                return
            }
        }
        apply()
    }

    /// Redraws after the rows moved, keeps the selection, saves, and lets
    /// Undo put the previous order back (and Redo undo that).
    private func finishReorder(restoring previous: [QueueRow], selected: [QueueRow], clearSortIndicator: Bool, actionName: String) {
        try? queue.saveToDisk()
        table.reloadData()
        let indexes = IndexSet(selected.map { queue.index(of: $0) }.filter { $0 >= 0 })
        table.selectRowIndexes(tableRows(forQueueIndexes: indexes), byExtendingSelection: false)
        updateState()

        // After a sort the header keeps its arrow, so clicking the same
        // header again flips the direction. After an Undo or Redo the order
        // no longer matches that arrow, so it is cleared then.
        if clearSortIndicator {
            ignoreSortChange = true
            table.sortDescriptors = []
            ignoreSortChange = false
        }

        guard let undo = window?.undoManager else { return }
        let current = queue.allRows
        undo.registerUndo(withTarget: self) { target in
            target.restoreOrder(previous, redoTo: current)
        }
        if undo.isUndoing == false {
            undo.setActionName(actionName)
        }
    }

    private func restoreOrder(_ order: [QueueRow], redoTo redo: [QueueRow]) {
        let selected = selectedQueueIndexes.map { queue.row(at: $0) }
        queue.reorder { current in
            let known = Set(current.map { ObjectIdentifier($0) })
            let wanted = order.filter { known.contains(ObjectIdentifier($0)) }
            let placed = Set(wanted.map { ObjectIdentifier($0) })
            return wanted + current.filter { placed.contains(ObjectIdentifier($0)) == false }
        }
        finishReorder(restoring: redo, selected: selected, clearSortIndicator: true, actionName: NSLocalizedString("Sort Queue", comment: "Queue -> sort undo action name"))
    }

    /// Leading indent for a row whose file was added as part of a folder
    /// group, so it reads as nested under that folder's header row right
    /// above it (QueueController.insertFolder(_:at:)) -- plain spaces
    /// rather than an indentationLevel/constraint change since this is an
    /// NSTableView, not an NSOutlineView, and every other row kind here
    /// has no such hierarchy to indicate.
    private static let folderChildIndent = "      "

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = layout.entry(atTableRow: row) else { return nil }

        let queueRow: QueueRow
        switch entry {
        case .file(let parent, let position):
            return fileLineView(for: tableColumn, parent: parent, position: position, in: tableView)
        case .row(let queueIndex):
            guard queueIndex < queue.count else { return nil }
            queueRow = queue.row(at: queueIndex)
        }

        if let identifier = tableColumn?.identifier, QueueTagValues.tagKey(ofColumn: identifier.rawValue) != nil {
            return tagCell(in: tableView, identifier: identifier, row: queueRow)
        }

        if let identifier = tableColumn?.identifier,
           identifier == statusColumn || identifier == sizeColumn || identifier == kindColumn || identifier == numberColumn {
            let cell = infoCell(in: tableView, identifier: identifier)
            switch identifier {
            case statusColumn:
                cell.textField?.stringValue = queueRow.statusSummary.text
                cell.toolTip = queueRow.statusTooltip
            case numberColumn:
                cell.textField?.stringValue = queueRow.folderHeaderURL == nil ? String(queue.addedRank(of: queueRow)) : ""
            case sizeColumn:
                cell.textField?.stringValue = sizeText(for: queueRow)
            default:
                cell.textField?.stringValue = queueRow.kindText
            }
            return cell
        }

        if tableColumn?.identifier == actionsColumn {
            let cell = actionsCell(in: tableView)
            configureRowButtons(in: cell, item: queueRow.folderHeaderURL == nil ? queueRow.effectiveItem : nil)
            return cell
        }

        if tableColumn?.identifier == nameColumn {
            let cell = tableView.makeView(withIdentifier: nameColumn, owner: self) as? NSTableCellView

            // Cells are reused across rows of every kind, so every branch
            // below sets its own font and colour explicitly rather than
            // relying on whatever a previously-recycled row last left it as.
            cell?.toolTip = nil
            cell?.textField?.textColor = .controlTextColor
            var disclosure = FolderTriangle.none
            if let folderHeaderURL = queueRow.folderHeaderURL {
                // The group label for the item rows right after it.
                cell?.textField?.stringValue = SeasonFolderName.displayName(forFolder: folderHeaderURL)
                cell?.textField?.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                cell?.imageView?.image = NSWorkspace.shared.icon(forFile: folderHeaderURL.path)
                disclosure = collapsedRows.contains(ObjectIdentifier(queueRow)) ? .collapsed : .expanded
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
                if release.stage != .done {
                    cell?.toolTip = String(format: NSLocalizedString("A folder with %ld media file(s). Double-click to review it.", comment: "Queue release row tooltip"), release.sourceFileURLs.count)
                }
                if canExpand(queueRow) {
                    disclosure = collapsedRows.contains(ObjectIdentifier(queueRow)) ? .collapsed : .expanded
                }
            }

            if let cell = cell {
                configureNameCell(cell, disclosure: disclosure)
            }
            return cell
        }
        return nil
    }

    /// One of the files listed under an open folder row: read-only, indented,
    /// in a quieter colour than the folder itself.
    private func fileLineView(for tableColumn: NSTableColumn?, parent: Int, position: Int, in tableView: NSTableView) -> NSView? {
        guard parent < queue.count,
              let urls = queue.row(at: parent).release?.sourceFileURLs,
              urls.indices.contains(position),
              let identifier = tableColumn?.identifier
        else { return nil }
        let url = urls[position]

        if identifier == nameColumn {
            let cell = tableView.makeView(withIdentifier: nameColumn, owner: self) as? NSTableCellView
            cell?.toolTip = url.path
            cell?.textField?.stringValue = url.lastPathComponent
            cell?.textField?.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            cell?.textField?.textColor = .secondaryLabelColor
            cell?.imageView?.image = docImg
            if let cell = cell {
                configureNameCell(cell, indent: 16, disclosure: .none)
            }
            return cell
        }

        if identifier == actionsColumn {
            let cell = actionsCell(in: tableView)
            configureRowButtons(in: cell, item: nil)
            return cell
        }

        guard identifier == statusColumn || identifier == sizeColumn || identifier == kindColumn || identifier == numberColumn else { return nil }
        let cell = infoCell(in: tableView, identifier: identifier)
        cell.toolTip = nil
        switch identifier {
        case sizeColumn:
            if let size = sizeCache[url], size >= 0 {
                cell.textField?.stringValue = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            } else {
                cell.textField?.stringValue = "\u{2014}"
            }
        case kindColumn:
            cell.textField?.stringValue = url.pathExtension.uppercased()
        case statusColumn:
            cell.textField?.stringValue = queue.row(at: parent).release?.fileStatusText(for: url) ?? ""
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    // MARK: Opening and closing folder rows

    /// Folder rows still waiting to be merged or named can be opened to list
    /// the files inside, and a folder header can be closed to hide its files. A row that has become a single file is not a folder
    /// any more.
    private func canExpand(_ row: QueueRow) -> Bool {
        // A folder header always has the files added with it under it.
        if row.folderHeaderURL != nil { return true }
        guard let release = row.release, release.resolvedItem == nil, release.stage != .done else { return false }
        return release.sourceFileURLs.isEmpty == false
    }

    /// Rebuilds the table-row numbering from the Queue and the folders that
    /// are open. Called whenever the table asks how many rows there are, and
    /// before any lookup that must be current.
    @discardableResult
    private func rebuildLayout() -> QueueOutlineLayout {
        let rows = queue.allRows
        var open = Set<Int>()
        var hidden = Set<Int>()
        var stillThere = Set<ObjectIdentifier>()
        for (index, row) in rows.enumerated() {
            let id = ObjectIdentifier(row)
            guard collapsedRows.contains(id), canExpand(row) else {
                if row.folderHeaderURL == nil, canExpand(row) { open.insert(index) }
                continue
            }
            stillThere.insert(id)
            if row.folderHeaderURL != nil {
                hidden.formUnion(QueueFolderGroups.childIndexes(ofHeaderAt: index, in: rows))
            }
        }
        collapsedRows = stillThere
        layout = QueueOutlineLayout(rowCount: rows.count, expanded: open, hidden: hidden, fileCount: { rows[$0].release?.sourceFileURLs.count ?? 0 })
        return layout
    }

    /// The Queue index of the selected row, if any (a file line counts as
    /// the folder it is in).
    private var selectedQueueIndex: Int? {
        guard let table = table else { return nil }
        return rebuildLayout().queueIndex(forTableRow: table.selectedRow)
    }

    private var clickedQueueIndex: Int? {
        guard let table = table else { return nil }
        return rebuildLayout().queueIndex(forTableRow: table.clickedRow)
    }

    /// Selected rows as Queue indexes.
    private var selectedQueueIndexes: IndexSet {
        guard let table = table else { return IndexSet() }
        return rebuildLayout().queueIndexes(forTableRows: table.selectedRowIndexes)
    }

    private func queueIndex(forTableRow row: Int) -> Int? {
        return rebuildLayout().queueIndex(forTableRow: row)
    }

    /// Where Queue rows are drawn right now.
    private func tableRows(forQueueIndexes indexes: IndexSet) -> IndexSet {
        return rebuildLayout().tableRows(forQueueIndexes: indexes)
    }

    @objc private func toggleDisclosure(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard let index = queueIndex(forTableRow: row), index < queue.count else { return }
        let id = ObjectIdentifier(queue.row(at: index))
        let expand = collapsedRows.contains(id)

        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            setAllFolders(expanded: expand)
        } else {
            setFolders(at: IndexSet(integer: index), expanded: expand)
        }
    }

    /// Opens or closes the folder rows at `indexes` (Queue indexes), sliding
    /// their files in or out. Rows that cannot open are skipped.
    private func setFolders(at indexes: IndexSet, expanded expand: Bool) {
        for index in indexes where index < queue.count {
            let queueRow = queue.row(at: index)
            let id = ObjectIdentifier(queueRow)
            guard canExpand(queueRow), collapsedRows.contains(id) == expand else { continue }

            let before = rebuildLayout()
            guard let parentRow = before.tableRow(forQueueIndex: index) else { continue }
            let isHeader = queueRow.folderHeaderURL != nil
            let groupIndexes = isHeader ? IndexSet(QueueFolderGroups.childIndexes(ofHeaderAt: index, in: queue.allRows)) : IndexSet()
            let fileCount = queueRow.release?.sourceFileURLs.count ?? 0

            if expand { collapsedRows.remove(id) } else { collapsedRows.insert(id) }
            let after = rebuildLayout()

            guard canAnimateRowChanges else {
                table.reloadData()
                continue
            }

            table.beginUpdates()
            if isHeader {
                if expand {
                    table.insertRows(at: after.tableRows(forQueueIndexes: groupIndexes), withAnimation: .slideDown)
                } else {
                    table.removeRows(at: before.tableRows(forQueueIndexes: groupIndexes), withAnimation: .slideUp)
                }
            } else {
                let lines = IndexSet(integersIn: (parentRow + 1)..<(parentRow + 1 + fileCount))
                if expand {
                    table.insertRows(at: lines, withAnimation: .slideDown)
                } else {
                    table.removeRows(at: lines, withAnimation: .slideUp)
                }
            }
            table.endUpdates()
            if let row = after.tableRow(forQueueIndex: index) {
                table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: allColumns)
            }
        }
    }

    private func setAllFolders(expanded expand: Bool) {
        let rows = queue.allRows
        var changed = false
        for row in rows where canExpand(row) {
            let id = ObjectIdentifier(row)
            guard collapsedRows.contains(id) == expand else { continue }
            if expand { collapsedRows.remove(id) } else { collapsedRows.insert(id) }
            changed = true
        }
        guard changed else { return }
        let selected = selectedQueueIndexes.map { rows[$0] }
        table.reloadData()
        let indexes = IndexSet(selected.map { queue.index(of: $0) }.filter { $0 >= 0 })
        table.selectRowIndexes(tableRows(forQueueIndexes: indexes), byExtendingSelection: false)
    }

    /// Right arrow opens the selected folder rows, left arrow closes them.
    func tableView(_ tableview: NSTableView, handleArrowKey key: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        let indexes = selectedQueueIndexes
        let folders = indexes.filter { $0 < queue.count && canExpand(queue.row(at: $0)) }
        guard folders.isEmpty == false else { return false }

        if key == NSRightArrowFunctionKey {
            setFolders(at: IndexSet(folders), expanded: true)
            return true
        }
        if key == NSLeftArrowFunctionKey {
            setFolders(at: IndexSet(folders), expanded: false)
            return true
        }
        return false
    }

    /// The files listed under an open folder can be looked at but not picked.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return layout.isFile(atTableRow: row) == false
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
        var rowIndexes = selectedQueueIndexes
        let clickedRow = clickedQueueIndex ?? -1

        if clickedRow != -1 && rowIndexes.contains(clickedRow) == false {
            rowIndexes.removeAll()
            rowIndexes.insert(clickedRow)
        }

        // Removing a folder row removes the files under it; files that are
        // being processed stay, and so does their folder row.
        rowIndexes = QueueFolderGroups.indexesToRemove(selected: rowIndexes, rows: queue.allRows) { row in
            row.effectiveItem?.status == .working || row.release?.stage == .merging
        }

        if rowIndexes.isEmpty == false {
            remove(at: rowIndexes)
        }
    }

    @IBAction func edit(_ sender: Any?) {
        guard let clickedRow = clickedQueueIndex else { return }

        let queueRow = queue.row(at: clickedRow)

        // Open with the folder as it is on disk now.
        if let release = queueRow.release {
            rescan(release)
        }

        if let release = queueRow.release, release.stage == .alreadyMerged {
            reviewAlreadyMerged(for: release)
            return
        }

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

        // A file that is being worked on right now can't be opened.
        if let item = queueRow.effectiveItem, item.status != .working {
            edit(item: item)
        }
    }

    //MARK: Already-merged review

    /// Where an existing merged file goes when its parts are merged again:
    /// the same name plus " - OLD" ("Name.mp4" becomes "Name - OLD.mp4"), or
    /// " - OLD 2" and so on if that name is taken.
    static func oldCopyURL(for merged: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let folder = merged.deletingLastPathComponent()
        let base = merged.deletingPathExtension().lastPathComponent
        let ext = merged.pathExtension

        func candidate(_ suffix: String) -> URL {
            let url = folder.appendingPathComponent(base + suffix)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }

        var url = candidate(" - OLD")
        var number = 2
        while fileExists(url) {
            url = candidate(" - OLD \(number)")
            number += 1
        }
        return url
    }

    /// A folder that already holds a merged copy of its parts is not merged
    /// again; it waits here until a person decides. "Use the Merged File"
    /// carries on with that one file. "Merge the Parts Anyway" renames the
    /// existing merged file to "... - OLD" so it is kept but out of the way,
    /// and carries on as a normal multi-file release of the parts alone.
    private func reviewAlreadyMerged(for release: QueueRelease) {
        guard let window = window, let merged = release.existingMergedFileURL else { return }
        let oldURL = QueueController.oldCopyURL(for: merged)

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("This folder already has a merged file", comment: "Already merged review")
        alert.informativeText = String(format: NSLocalizedString("\u{201C}%@\u{201D} is about the same size as the other files in this folder put together, so it is probably already their merge.\n\nMerging the parts again will first rename that file to \u{201C}%@\u{201D} and keep it.", comment: "Already merged review"), merged.lastPathComponent, oldURL.lastPathComponent)
        alert.addButton(withTitle: NSLocalizedString("Use the Merged File", comment: "Already merged review"))
        alert.addButton(withTitle: NSLocalizedString("Merge the Parts Anyway", comment: "Already merged review"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Already merged review"))
        alert.addHelpButton(anchor: .queue)

        MovableDialog.present(alert: alert, over: window) { [weak self] response in
            guard let self = self else { return }
            switch response {
            case .alertFirstButtonReturn:
                release.sourceFileURLs = [merged]
                release.stage = .pendingNaming
                release.existingMergedFileURL = nil
            case .alertSecondButtonReturn:
                do {
                    try FileManager.default.moveItem(at: merged, to: oldURL)
                } catch {
                    self.presentError(error)
                    return
                }
                let mergedPath = merged.standardizedFileURL.path
                release.sourceFileURLs = release.sourceFileURLs.filter { $0.standardizedFileURL.path != mergedPath }
                release.stage = .pendingNaming
                release.existingMergedFileURL = nil
            default:
                return
            }
            if let index = self.queue.indexesOfRows(where: { $0.release === release }).first {
                self.updateUI(indexes: IndexSet(integer: index))
            }
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
        MovableDialog.present(reviewWindow, over: window) { response in
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

        release.isSearchingMetadata = true
        refreshRows(of: release)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The chosen provider first, then every other enabled one --
            // the first to find the title decides.
            let enabled = MetadataSearch.movieProviders
            var order: [String] = enabled.contains(movieProvider) ? [movieProvider] : []
            order.append(contentsOf: enabled.filter { $0 != movieProvider })
            if order.isEmpty { order = [movieProvider] }

            var results: [MetadataResult] = []
            for providerName in order {
                let service = MetadataSearch.service(name: providerName)
                let language = providerName == movieProvider ? movieLanguage : MetadataSearch.defaultLanguage(service: service, type: .movie)
                let search = MetadataSearch.movieSeach(service: service, movie: localTitle, language: language)
                search.search(completionHandler: { results = $0 }).run()
                if results.isEmpty == false { break }
            }

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
                release.isSearchingMetadata = false

                guard let self = self, release.stage == .pendingMetadata,
                      self.queue.indexesOfRows(where: { $0.release === release }).isEmpty == false
                else { return }

                if highConfidence {
                    self.resolveSingleFileRelease(release)
                    self.updateUI()
                } else {
                    // Parked in .pendingMetadata for the user to open --
                    // the row needs its own refresh now (unlike before
                    // isSearchingMetadata existed) since the status text
                    // changes from "Searching metadata..." to "Waiting
                    // for metadata" with no stage change to trigger it.
                    self.refreshRows(of: release)
                }
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
        MovableDialog.present(reviewWindow, over: window) { response in
            if response == .OK {
                self.resolveSingleFileRelease(release,
                                              artworkOverride: reviewController.chosenArtworkType,
                                              searchTerm: reviewController.chosenSearchTerm,
                                              searchResultIndex: reviewController.chosenResultIndex,
                                              providerOverride: reviewController.chosenProvider,
                                              languageOverride: reviewController.chosenLanguage,
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
    private func resolveSingleFileRelease(_ release: QueueRelease, artworkOverride: ArtworkType? = nil, searchTerm: String? = nil, searchResultIndex: Int = 0, providerOverride: String? = nil, languageOverride: String? = nil, skipMetadata: Bool = false) {
        guard let sourceURL = release.mergedFileURL ?? release.sourceFileURLs.first else { return }

        let destURL = destination(for: sourceURL)
        let item = QueueItem(fileURL: sourceURL, destination: destURL)

        // Subtitle files in the release folder (an .srt beside the video) are
        // embedded in the finished file. Not for a merged file: the parts'
        // subtitles would not line up with it.
        if release.mergedFileURL == nil {
            let subtitles = SidecarSubtitles.files(in: sourceURL.deletingLastPathComponent())
            if subtitles.isEmpty == false {
                item.addAction(QueueSubtitlesAction(files: subtitles))
            }
        }

        if prefs.searchMetadata && skipMetadata == false {
            let artwork = artworkOverride ?? ArtworkType(rawValue: prefs.providerArtwork) ?? .poster
            // A provider picked in the review window is searched first, in its
            // own language; the other enabled providers still add what they have.
            item.addAction(QueueMetadataAction(movieLanguage: languageOverride ?? prefs.movieProviderLanguage,
                                                tvShowLanguage: prefs.tvShowProviderLanguage,
                                                movieProvider: providerOverride ?? prefs.movieProvider,
                                                tvShowProvider: prefs.tvShowProvider,
                                                preferredArtwork: artwork.rawValue,
                                                preferredArtworkSize: prefs.providerArtworkSize,
                                                searchName: release.approvedName ?? release.folderURL.lastPathComponent,
                                                searchTerm: searchTerm,
                                                searchResultIndex: searchResultIndex,
                                                existingTags: prefs.existingTags,
                                                keepEmptyAnnotations: prefs.keepEmptyAnnotations))
        }
        // The Set chosen in the Queue options, applied after the search so
        // its values win over what the search found.
        if let set = prefs.metadataSet {
            item.addAction(QueueSetAction(preset: set, setWins: true))
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
        MovableDialog.present(reorderWindow, over: window) { response in
            guard response == .OK else { return }
            self.runMerge(for: release, order: reorderController.filesToMerge)
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
    /// Redraws the row of `release` and, if it is open, its file lines.
    private func refreshRows(of release: QueueRelease) {
        let indexes = queue.indexesOfRows(where: { $0.release === release })
        guard indexes.isEmpty == false else { return }
        table.reloadData(forRowIndexes: rebuildLayout().tableRowsIncludingFiles(forQueueIndexes: indexes), columnIndexes: allColumns)
    }

    private func runMerge(for release: QueueRelease, order: [URL]) {
        release.mergeOrder = order
        release.mergedFileURL = nil
        release.stage = .merging
        release.mergeProgress = 0
        updateUI()

        let name = release.approvedName ?? release.folderURL.lastPathComponent
        mergeStarted(release, name: name)
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
                        let before = Int(release.mergeProgress)
                        release.mergeProgress = progress
                        self.mergeProgressed(release, progress: progress)
                        // Redraw only when the whole percent changes.
                        if Int(progress) != before {
                            self.refreshRows(of: release)
                        }
                    }
                })
                DispatchQueue.main.async {
                    self.mergeEnded(release)
                    self.resolveMergedRelease(release, mergedFileURL: destination)
                }
            } catch {
                DispatchQueue.main.async {
                    self.mergeEnded(release)
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

    /// What "Show in Finder" reveals for a row: the processed file of a
    /// completed item, the file of a waiting one, or a folder row's folder.
    /// When that has been moved, renamed or deleted, the closest folder that
    /// still exists is shown instead, so the button always has somewhere to go.
    private func finderTarget(for row: QueueRow) -> URL? {
        var url: URL
        if let item = row.effectiveItem {
            url = item.status == .completed ? item.destURL : item.fileURL
        } else if let release = row.release {
            url = release.folderURL
        } else {
            return nil
        }
        let manager = FileManager.default
        while manager.fileExists(atPath: url.path) == false, url.path != "/" {
            url = url.deletingLastPathComponent()
        }
        return url.path == "/" ? nil : url
    }

    @IBAction func showInFinder(_ sender: Any?) {
        if let clickedRow = clickedQueueIndex, let url = finderTarget(for: queue.row(at: clickedRow)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
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
              let rows = mergeCandidateRows(at: selectedQueueIndexes)
        else { return }

        let files = rows.compactMap { $0.effectiveItem?.fileURL }
        guard files.count == rows.count else { return }

        let reorderController = MergeReorderWindowController(files: files)
        guard let reorderWindow = reorderController.window else { return }

        // reorderController is captured (and so kept alive) by this
        // closure for as long as the sheet is up -- AppKit retains the
        // completion handler itself until it's invoked, so nothing here
        // needs its own stored property.
        MovableDialog.present(reorderWindow, over: window) { response in
            guard response == .OK else { return }
            // Files unticked in the sheet are left out, and their rows stay
            // in the Queue untouched.
            let chosen = reorderController.filesToMerge
            let chosenRows = rows.filter { row in row.effectiveItem.map { chosen.contains($0.fileURL) } ?? false }
            self.presentMergeDestinationPanel(for: chosenRows, files: chosen, in: window)
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

        table.selectRowIndexes(tableRows(forQueueIndexes: IndexSet(integer: max(0, min(insertionIndex, queue.count - 1)))), byExtendingSelection: false)
    }

    //MARK: Drag & Drop

    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // The files listed inside an open folder are not draggable.
        guard let queueIndex = queueIndex(forTableRow: row), layout.isFile(atTableRow: row) == false else { return nil }
        let item = PasteboardItem(index: queueIndex, type: .tableViewIndex)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard dropOperation == .above else { return [] }

        // A drop between the files of an open folder means "after that folder".
        let current = rebuildLayout()
        if current.isFile(atTableRow: row) {
            let after = current.queueInsertionIndex(forTableRow: row)
            tableView.setDropRow(current.tableRow(forQueueIndex: after) ?? current.count, dropOperation: .above)
        }

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
            move(rows: rows, at: rebuildLayout().queueInsertionIndex(forTableRow: row))
            return true
        } else if info.draggingPasteboard.types?.contains(NSPasteboard.PasteboardType.fileURL) ?? false {
            if let items = info.draggingPasteboard.readObjects(forClasses: [NSURL.classForCoder()], options: [:]) as? [URL] {
                insertGrouped(items, at: rebuildLayout().queueInsertionIndex(forTableRow: row))
            }
            return true
        }

        return false
    }
}

#if DEBUG
// Used by DocsScreenshots (debug builds only): where the options panel is on screen.
extension QueueController {
    var docsPopoverFrame: NSRect? {
        return popover?.contentViewController?.view.window?.frame
    }

    /// Adds a release row for a folder, as the intake scan would, but parked at `stage`
    /// (nothing is renamed, searched or merged until the screenshot step opens its dialog).
    @discardableResult
    func docsAddRelease(folder: URL, stage: QueueRelease.Stage, approvedName: String? = nil) -> QueueRelease? {
        guard let release = makeRelease(contentOf: folder) else { return nil }
        release.stage = stage
        release.approvedName = approvedName
        insertRelease(release, at: count)
        return release
    }

    /// Opens the dialog a double-click on this release's row would open.
    func docsReview(_ release: QueueRelease) {
        switch release.stage {
        case .alreadyMerged: reviewAlreadyMerged(for: release)
        case .pendingNaming, .namingRejected: reviewNaming(for: release)
        case .pendingMergeSelection, .mergeFailed: reviewMerge(for: release)
        case .pendingMetadata: reviewMetadata(for: release)
        default: break
        }
    }

    /// Clean settings leave "Search metadata" off; the in-place editing shot needs it on,
    /// and it has to be on before the files are added (each item gets its actions then).
    func docsEnableMetadataSearch() {
        prefs.searchMetadata = true
    }

    /// True when nothing is running and nothing is waiting to run.
    var docsIsIdle: Bool {
        return queue.status != .working && queue.readyCount == 0
    }
}
#endif
