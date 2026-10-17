//
//  LibraryScanWindowController.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/02/2026.
//
//  Walks a chosen folder for already-processed media files (.mp4/.m4v/
//  .mov -- the formats a finished, tagged file in a library actually
//  sits in, as opposed to a raw download still awaiting Media Intake)
//  and flags any whose core metadata -- Title and Release Date, plus
//  any extra tags chosen with the gear button (Rating and Studio among
//  them) -- is still missing, so a library built up over time can be
//  swept for gaps without re-checking every file by hand. Reached from
//  WelcomeWindowController's "Scan Library for Missing Metadata" action,
//  or any other future entry point via LibraryScanWindowController.shared.
//
//  Built entirely in code (no .xib), same reasoning as
//  NamingReviewWindowController/MergeReorderWindowController: a small
//  self-contained window with no reason to round-trip through Interface
//  Builder.
//
//  The table has a File column and one column for each tag being
//  checked, showing the tag's value or a red "Missing". Columns can be
//  resized and dragged, a click on a heading sorts by it, and the
//  window can be enlarged (its size is remembered).
//
//  Fixing the gaps: right-click a tag cell and choose Edit... to type a
//  value, which is written straight into that file (a safety copy is
//  kept until the write succeeds). Rows can be selected (Command-A for
//  all) and sent to the Queue, where each file is edited where it sits:
//  metadata is searched and the tags written into the file, with no copy
//  and no move to the library.
//
//  A first pass at this feature: it reports gaps and gets out of the
//  way for tagging them (double-click opens the file in the normal
//  single-file editor, same as anywhere else in the app) rather than
//  trying to fix anything itself.
//

import Cocoa
import MP42Foundation

final class LibraryScanWindowController: NSWindowController {

    static let shared = LibraryScanWindowController()

    /// The fields a "complete" file is expected to have tagged -- see
    /// values(in:fields:). Deliberately a small, practical set rather
    /// than every writable key: these are the ones this app's own
    /// Filename-tab naming rules and folder organization typically key
    /// off of (see NamingRules.swift / MP42FileAdditions.formattedFileName()),
    /// so a file missing one of these is also a file whose output name
    /// probably isn't right yet.
    private static let requiredFields: [(key: String, label: String)] = [
        (MP42MetadataKeyName, NSLocalizedString("Title", comment: "Library scan -> field name")),
        (MP42MetadataKeyReleaseDate, NSLocalizedString("Release Date", comment: "Library scan -> field name"))
    ]

    /// The tags checked on every scan (the gear panel's "Always checked").
    static var alwaysCheckedKeys: [String] { requiredFields.map { $0.key } }

    private static let scannableExtensions: Set<String> = ["mp4", "m4v", "mov"]

    // MARK: Fields to check

    private static let extraFieldsKey = "SBLibraryScanExtraFields"

    /// Extra tags (MP42 metadata identifiers) chosen in the gear panel,
    /// checked in addition to requiredFields. Kept between scans.
    private static var extraFieldKeys: [String] {
        get { UserDefaults.standard.stringArray(forKey: extraFieldsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: extraFieldsKey) }
    }

    private static func fieldsToCheck() -> [(key: String, label: String)] {
        let requiredKeys = Set(requiredFields.map { $0.key })
        let extras = extraFieldKeys
            .filter { requiredKeys.contains($0) == false }
            .map { (key: $0, label: localizedMetadataKeyName($0) ?? $0) }
        return requiredFields + extras
    }

    /// A file that takes longer than this to read is listed as unreadable
    /// and the scan moves on (a stalled drive or share otherwise blocks it
    /// for good).
    private static let readTimeout: TimeInterval = 20
    /// After this many unreadable files in a row the scan stops: the
    /// drive itself has most likely stopped responding.
    private static let maximumConsecutiveTimeouts = 3
    /// Reads slower than this are written to the message log.
    private static let slowReadSeconds: TimeInterval = 5

    private static let unreadableLabel = NSLocalizedString("Unreadable (timed out)", comment: "Library scan -> missing column for a file that could not be read in time")

    /// One listed file: its text for each checked tag (a tag with no entry
    /// is missing), or `unreadable` when it could not be read in time.
    private struct ScanResult {
        let url: URL
        var values: [String: String]
        var unreadable = false
    }

    /// The cell being edited by the right-click Edit... command.
    private var editingField: NSTextField?
    private var editingURL: URL?
    private var editingKey = ""
    private var editingOriginal = ""
    /// True while a tag is being written into a file.
    private var isWritingTag = false
    /// The row and column that were right-clicked.
    private var contextRow = -1
    private var contextColumn = -1

    /// The tags the table currently shows a column for.
    private var scanFields: [(key: String, label: String)] = []
    private static let fileColumnID = "file"
    private static let tagColumnPrefix = "tag:"

    private var results: [ScanResult] = []
    /// How many Library scans are running right now (for AppRestarter).
    static var activeScanCount = 0

    private var isScanning = false {
        didSet {
            if isScanning != oldValue {
                LibraryScanWindowController.activeScanCount += isScanning ? 1 : -1
            }
            updateControlsState()
        }
    }

    private let folderField = NSTextField(labelWithString: "")
    private let chooseFolderButton = NSButton(title: NSLocalizedString("Choose Folder\u{2026}", comment: "Library scan -> button"), target: nil, action: nil)
    private var scanButton: NSButton!
    private var cancelRequested = false

    // MARK: Pause
    // The scan thread waits on this between files while the scan is paused.
    private let pauseGate = ScanPauseGate()
    private var pauseButton: NSButton!
    /// True while the scan is paused (main thread; drives the button and status).
    private var isPausedUI = false

    private let tableView = NSTableView()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private var revealButton: NSButton!
    private var tagButton: NSButton!
    private var queueButton: NSButton!
    private var clearButton: NSButton!

    private var scannedFolderURL: URL?

    private var optionsButton: NSButton!
    private var optionsPopover: NSPopover?
    /// The identifiers behind the checkboxes in the gear panel (a
    /// checkbox's tag is its index here).
    private var optionKeys: [String] = []
    /// The file the scan is reading right now (main thread only).
    private var currentFileName = ""
    /// Files read so far in this scan (for the status line after a pause).
    private var scannedSoFar = 0

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered,
                               defer: false)
        window.title = NSLocalizedString("Scan Library for Missing Metadata", comment: "Library scan -> window title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 320)
        window.center()

        super.init(window: window)

        window.contentViewController = makeContentViewController()
        // After the content is set (it fixes the size), so a size you chose
        // earlier is restored.
        window.setFrameAutosaveName("LibraryScanWindow")
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Layout

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 520))
        controller.view = view

        folderField.translatesAutoresizingMaskIntoConstraints = false
        folderField.lineBreakMode = .byTruncatingMiddle
        folderField.stringValue = NSLocalizedString("No folder chosen", comment: "Library scan -> no folder placeholder")
        folderField.textColor = .secondaryLabelColor

        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder(_:))
        chooseFolderButton.translatesAutoresizingMaskIntoConstraints = false
        chooseFolderButton.bezelStyle = .rounded

        scanButton = NSButton(title: NSLocalizedString("Scan", comment: "Library scan -> button"), target: self, action: #selector(scanOrStop(_:)))
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        scanButton.bezelStyle = .rounded
        scanButton.keyEquivalent = "\r"
        scanButton.isEnabled = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scanFields = LibraryScanWindowController.fieldsToCheck()
        rebuildColumns()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(tagSelected(_:))
        tableView.target = self
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu
        scrollView.documentView = tableView

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        revealButton = NSButton(title: NSLocalizedString("Reveal in Finder", comment: "Library scan -> button"), target: self, action: #selector(revealSelected(_:)))
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.bezelStyle = .rounded
        revealButton.isEnabled = false

        tagButton = NSButton(title: NSLocalizedString("Tag\u{2026}", comment: "Library scan -> button"), target: self, action: #selector(tagSelected(_:)))
        tagButton.translatesAutoresizingMaskIntoConstraints = false
        tagButton.bezelStyle = .rounded
        tagButton.isEnabled = false

        queueButton = NSButton(title: NSLocalizedString("Send All to Queue\u{2026}", comment: "Library scan -> button"), target: self, action: #selector(sendToQueueButton(_:)))
        queueButton.translatesAutoresizingMaskIntoConstraints = false
        queueButton.bezelStyle = .rounded
        queueButton.isEnabled = false
        queueButton.toolTip = NSLocalizedString("Add the selected files (or all of them) to the Queue to be edited where they are: metadata is searched and written into each file, with no copy and no move.", comment: "Library scan -> Send to Queue tooltip")

        clearButton = NSButton(title: NSLocalizedString("Clear", comment: "Library scan -> button that empties the list"), target: self, action: #selector(clearList(_:)))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .rounded
        clearButton.isEnabled = false
        clearButton.toolTip = NSLocalizedString("Empty the list. The folder stays chosen, so Scan starts again from it. No file is changed.", comment: "Library scan -> Clear button tooltip")

        optionsButton = NSButton(title: "", target: self, action: #selector(showOptions(_:)))
        optionsButton.translatesAutoresizingMaskIntoConstraints = false
        optionsButton.bezelStyle = .rounded
        optionsButton.image = NSImage(named: NSImage.actionTemplateName)
        optionsButton.imagePosition = .imageOnly
        optionsButton.toolTip = NSLocalizedString("Choose which tags the scan looks for.", comment: "Library scan -> gear button tooltip")

        pauseButton = NSButton(title: NSLocalizedString("Pause", comment: "Library scan -> button"), target: self, action: #selector(togglePause(_:)))
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.bezelStyle = .rounded
        pauseButton.isEnabled = false
        pauseButton.toolTip = NSLocalizedString("Pause the scan after the file it is reading, and carry on from there with Resume. The files found so far stay in the list.", comment: "Library scan -> Pause button tooltip")

        let doneButton = NSButton(title: NSLocalizedString("Done", comment: "Library scan -> button"), target: self, action: #selector(done(_:)))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\u{1b}"

        view.addSubview(folderField)
        view.addSubview(chooseFolderButton)
        view.addSubview(scanButton)
        view.addSubview(optionsButton)
        view.addSubview(scrollView)
        view.addSubview(progressIndicator)
        view.addSubview(statusLabel)
        view.addSubview(pauseButton)
        view.addSubview(revealButton)
        view.addSubview(tagButton)
        view.addSubview(queueButton)
        view.addSubview(clearButton)
        view.addSubview(doneButton)

        let helpButton = HelpAnchorButton(anchor: .libraryScan)
        helpButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(helpButton)

        NSLayoutConstraint.activate([
            chooseFolderButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            chooseFolderButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            folderField.centerYAnchor.constraint(equalTo: chooseFolderButton.centerYAnchor),
            folderField.leadingAnchor.constraint(equalTo: chooseFolderButton.trailingAnchor, constant: 10),
            folderField.trailingAnchor.constraint(lessThanOrEqualTo: helpButton.leadingAnchor, constant: -10),

            // Only the options (gear) button is at the top right; Pause,
            // Scan (Stop while scanning) and Done sit in the bottom row.
            optionsButton.centerYAnchor.constraint(equalTo: chooseFolderButton.centerYAnchor),
            optionsButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            // The "?" opens the help book at this window's section.
            helpButton.centerYAnchor.constraint(equalTo: optionsButton.centerYAnchor),
            helpButton.trailingAnchor.constraint(equalTo: optionsButton.leadingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: chooseFolderButton.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: progressIndicator.topAnchor, constant: -10),

            progressIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressIndicator.bottomAnchor.constraint(equalTo: revealButton.topAnchor, constant: -10),
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),

            statusLabel.centerYAnchor.constraint(equalTo: progressIndicator.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            revealButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            revealButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            tagButton.leadingAnchor.constraint(equalTo: revealButton.trailingAnchor, constant: 10),
            tagButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            queueButton.leadingAnchor.constraint(equalTo: tagButton.trailingAnchor, constant: 10),
            queueButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            clearButton.leadingAnchor.constraint(equalTo: queueButton.trailingAnchor, constant: 10),
            clearButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            scanButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -10),
            scanButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            pauseButton.trailingAnchor.constraint(equalTo: scanButton.leadingAnchor, constant: -10),
            pauseButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        return controller
    }

    // MARK: Columns and sorting

    /// A File column, then one column for each checked tag. Each heading
    /// can be clicked to sort (the arrow shows the direction), and each
    /// column can be dragged wider or narrower.
    private func rebuildColumns() {
        restoringLayout = true
        defer { restoringLayout = false }
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        tableView.sortDescriptors = []

        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(LibraryScanWindowController.fileColumnID))
        fileColumn.title = NSLocalizedString("File", comment: "Library scan -> column title")
        fileColumn.width = 300
        fileColumn.minWidth = 140
        fileColumn.resizingMask = [.autoresizingMask, .userResizingMask]
        fileColumn.sortDescriptorPrototype = NSSortDescriptor(key: LibraryScanWindowController.fileColumnID, ascending: true)
        tableView.addTableColumn(fileColumn)

        for field in scanFields {
            let id = LibraryScanWindowController.tagColumnPrefix + field.key
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = field.label
            column.width = 130
            column.minWidth = 60
            column.resizingMask = [.autoresizingMask, .userResizingMask]
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            tableView.addTableColumn(column)
        }

        // Put back the order, widths and sort the user chose last time.
        let saved = LibraryScanLayout.load()
        for column in tableView.tableColumns {
            if let width = saved.widths[column.identifier.rawValue] {
                column.width = min(max(CGFloat(width), column.minWidth), column.maxWidth)
            }
        }
        let wanted = LibraryScanLayout.order(of: tableView.tableColumns.map { $0.identifier.rawValue }, saved: saved.order)
        for (position, id) in wanted.enumerated() {
            if let current = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }), current != position {
                tableView.moveColumn(current, toColumn: position)
            }
        }
        if let key = saved.sortKey, tableView.tableColumns.contains(where: { $0.identifier.rawValue == key }) {
            tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: saved.ascending)]
        }
    }

    /// True while the columns are being rebuilt, so that does not overwrite
    /// the saved layout.
    private var restoringLayout = false

    /// Remembers the column order, widths and sort for the next scan.
    private func saveLayout() {
        guard restoringLayout == false else { return }
        var layout = LibraryScanLayout.load()
        for column in tableView.tableColumns { layout.widths[column.identifier.rawValue] = Double(column.width) }
        layout.order = LibraryScanLayout.merged(saved: layout.order, current: tableView.tableColumns.map { $0.identifier.rawValue })
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            layout.sortKey = key
            layout.ascending = descriptor.ascending
        } else {
            layout.sortKey = nil
        }
        layout.save()
    }

    func tableViewColumnDidResize(_ notification: Notification) { saveLayout() }

    func tableViewColumnDidMove(_ notification: Notification) { saveLayout() }

    /// Orders `results` by the heading that was clicked (a file with a
    /// missing value sorts first, so the gaps gather at one end), keeps the
    /// selected file selected, and redraws the table.
    private func sortAndReload() {
        let selectedURLs = Set(selectedResults.map { $0.url })

        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            let ascending = descriptor.ascending
            results.sort { a, b in
                var order: ComparisonResult
                if key == LibraryScanWindowController.fileColumnID {
                    order = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
                } else if key.hasPrefix(LibraryScanWindowController.tagColumnPrefix) {
                    let tag = String(key.dropFirst(LibraryScanWindowController.tagColumnPrefix.count))
                    order = LibraryScanCell.sortOrder(a.values[tag], b.values[tag])
                    if order == .orderedSame {
                        order = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
                        return order == .orderedAscending
                    }
                } else {
                    return false
                }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }

        tableView.reloadData()
        if selectedURLs.isEmpty == false {
            var rows = IndexSet()
            for (index, result) in results.enumerated() where selectedURLs.contains(result.url) { rows.insert(index) }
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        updateSelectionControlsState()
    }

    private func updateControlsState() {
        // "Stop" rather than "Cancel": the files found so far stay in the list.
        scanButton.title = isScanning
            ? NSLocalizedString("Stop", comment: "Library scan -> button while a scan is running")
            : NSLocalizedString("Scan", comment: "Library scan -> button")
        chooseFolderButton.isEnabled = isScanning == false
        pauseButton.isEnabled = isScanning
        pauseButton.title = isPausedUI
            ? NSLocalizedString("Resume", comment: "Library scan -> button")
            : NSLocalizedString("Pause", comment: "Library scan -> button")
        updateSelectionControlsState()
    }

    private func updateSelectionControlsState() {
        let selectedCount = tableView.selectedRowIndexes.count
        revealButton.isEnabled = selectedCount > 0
        tagButton.isEnabled = selectedCount == 1
        // With nothing selected the button sends every listed file.
        queueButton.title = selectedCount > 0
            ? NSLocalizedString("Send Selected to Queue\u{2026}", comment: "Library scan -> button")
            : NSLocalizedString("Send All to Queue\u{2026}", comment: "Library scan -> button")
        queueButton.isEnabled = isScanning == false && isWritingTag == false && results.contains { $0.unreadable == false }
        clearButton.isEnabled = LibraryScanCell.canClear(isScanning: isScanning, isWritingTag: isWritingTag, listedCount: results.count)
    }

    // MARK: Actions

    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Choose a folder to scan for files missing metadata.", comment: "Library scan -> open panel message")

        guard let window = window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.urls.first else { return }
            self.scannedFolderURL = url
            self.folderField.stringValue = url.path
            self.folderField.textColor = .labelColor
            self.scanButton.isEnabled = true
        }
    }

    // MARK: Options (gear) panel

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    @objc private func showOptions(_ sender: NSButton) {
        if let popover = optionsPopover, popover.isShown {
            popover.close()
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = makeOptionsViewController()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        optionsPopover = popover
    }

    private func makeOptionsViewController() -> NSViewController {
        let controller = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 420))
        controller.view = view
        controller.preferredContentSize = view.frame.size

        func sectionTitle(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            label.translatesAutoresizingMaskIntoConstraints = false
            return label
        }

        let requiredTitle = sectionTitle(NSLocalizedString("Always checked", comment: "Library scan -> options section"))

        let requiredStack = NSStackView()
        requiredStack.orientation = .vertical
        requiredStack.alignment = .leading
        requiredStack.spacing = 4
        requiredStack.translatesAutoresizingMaskIntoConstraints = false
        for field in LibraryScanWindowController.requiredFields {
            let box = NSButton(checkboxWithTitle: field.label, target: nil, action: nil)
            box.state = .on
            box.isEnabled = false
            requiredStack.addArrangedSubview(box)
        }

        let extraTitle = sectionTitle(NSLocalizedString("Also look for", comment: "Library scan -> options section"))

        let requiredKeys = Set(LibraryScanWindowController.requiredFields.map { $0.key })
        let chosen = Set(LibraryScanWindowController.extraFieldKeys)
        optionKeys = MP42Metadata.writableMetadata.filter { requiredKeys.contains($0) == false }

        let extraStack = NSStackView()
        extraStack.orientation = .vertical
        extraStack.alignment = .leading
        extraStack.spacing = 4
        extraStack.translatesAutoresizingMaskIntoConstraints = false
        for (index, key) in optionKeys.enumerated() {
            let box = NSButton(checkboxWithTitle: localizedMetadataKeyName(key) ?? key, target: self, action: #selector(toggleExtraField(_:)))
            box.tag = index
            box.state = chosen.contains(key) ? .on : .off
            extraStack.addArrangedSubview(box)
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(extraStack)
        scrollView.documentView = container

        let note = NSTextField(wrappingLabelWithString: NSLocalizedString("A file is listed when any checked tag is empty or missing. Changes apply to the next scan.", comment: "Library scan -> options footnote"))
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(requiredTitle)
        view.addSubview(requiredStack)
        view.addSubview(extraTitle)
        view.addSubview(scrollView)
        view.addSubview(note)

        NSLayoutConstraint.activate([
            requiredTitle.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            requiredTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            requiredStack.topAnchor.constraint(equalTo: requiredTitle.bottomAnchor, constant: 6),
            requiredStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            extraTitle.topAnchor.constraint(equalTo: requiredStack.bottomAnchor, constant: 14),
            extraTitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            scrollView.topAnchor.constraint(equalTo: extraTitle.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -10),

            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            container.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            extraStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            extraStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            extraStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            extraStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        return controller
    }

    @objc private func toggleExtraField(_ sender: NSButton) {
        guard optionKeys.indices.contains(sender.tag) else { return }
        let key = optionKeys[sender.tag]
        var keys = LibraryScanWindowController.extraFieldKeys
        if sender.state == .on {
            if keys.contains(key) == false { keys.append(key) }
        } else {
            keys.removeAll { $0 == key }
        }
        LibraryScanWindowController.extraFieldKeys = keys
        // Show the new column straight away when no results are on screen
        // (a table already holding results keeps the columns it was scanned
        // with until the next scan).
        if results.isEmpty && isScanning == false {
            scanFields = LibraryScanWindowController.fieldsToCheck()
            rebuildColumns()
        }
    }

    @objc private func scanOrStop(_ sender: Any?) {
        if isScanning {
            stopScan()
        } else {
            beginScan()
        }
    }

    /// Asks the running scan to stop after the file it is on, waking it
    /// first if it is paused.
    private func stopScan() {
        cancelRequested = true
        setPaused(false)
    }

    /// Pause or resume. A paused scan finishes the file it is reading, shows
    /// what it has found so far, and waits.
    @objc private func togglePause(_ sender: Any?) {
        guard isScanning else { return }
        setPaused(isPausedUI == false)
    }

    private func setPaused(_ pause: Bool) {
        if pause { pauseGate.pause() } else { pauseGate.resume() }

        guard isPausedUI != pause else { return }
        isPausedUI = pause
        if pause {
            progressIndicator.stopAnimation(nil)
            statusLabel.stringValue = String(format: NSLocalizedString("Pausing\u{2026} %d listed so far.", comment: "Library scan -> status right after Pause is clicked"), results.count)
        } else if isScanning {
            progressIndicator.startAnimation(nil)
            refreshStatus(scannedCount: scannedSoFar + 1)
        }
        updateControlsState()
    }


    /// The listed files that are selected, in table order.
    private var selectedResults: [ScanResult] {
        tableView.selectedRowIndexes.filter { $0 < results.count }.map { results[$0] }
    }

    @objc private func revealSelected(_ sender: Any?) {
        let urls = selectedResults.map { $0.url }
        guard urls.isEmpty == false else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func tagSelected(_ sender: Any?) {
        // A double-click on a heading or empty space has no row.
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < results.count else { return }
        openInEditor(results[row].url)
    }

    private func openInEditor(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error = error {
                self.window?.presentError(error)
            } else if let document = document as? Document {
                // This file already lives wherever the user's library
                // keeps it -- see Document.skipsFolderCreationOnSave's own
                // doc comment for why that should stay untouched by the
                // "create a folder for me" step a loose/shared-folder save
                // would otherwise trigger.
                document.skipsFolderCreationOnSave = true
            }
        }
    }

    // MARK: Send to Queue

    /// Empties the list (a finished or stopped scan's results). The chosen
    /// folder and the columns stay, so Scan can start again; no file is touched.
    @objc private func clearList(_ sender: Any?) {
        guard LibraryScanCell.canClear(isScanning: isScanning, isWritingTag: isWritingTag, listedCount: results.count) else {
            NSSound.beep()
            return
        }
        endEditing(cancelled: true)
        results = []
        contextRow = -1
        tableView.deselectAll(nil)
        tableView.reloadData()
        statusLabel.stringValue = NSLocalizedString("List cleared.", comment: "Library scan -> status after Clear")
        updateSelectionControlsState()
    }

    @objc private func sendToQueueButton(_ sender: Any?) {
        let chosen = selectedResults
        sendToQueue(chosen.isEmpty ? results : chosen)
    }

    @objc private func sendContextRowsToQueue(_ sender: Any?) {
        sendToQueue(contextTargetResults())
    }

    /// The rows a right-click acts on: the whole selection when the
    /// clicked row is part of it, otherwise just the clicked row.
    private func contextTargetResults() -> [ScanResult] {
        guard contextRow >= 0, contextRow < results.count else { return selectedResults }
        if tableView.selectedRowIndexes.contains(contextRow) { return selectedResults }
        return [results[contextRow]]
    }

    /// Sends files to the Queue to be edited where they are, after asking:
    /// it is the one place this window leads to changes in the library.
    private func sendToQueue(_ rows: [ScanResult]) {
        let sendable = rows.filter { $0.unreadable == false }
        guard sendable.isEmpty == false, let window = window else { NSSound.beep(); return }

        let alert = NSAlert()
        alert.messageText = sendable.count == 1
            ? NSLocalizedString("Send 1 file to the Queue?", comment: "Library scan -> confirm title")
            : String(format: NSLocalizedString("Send %d files to the Queue?", comment: "Library scan -> confirm title"), sendable.count)
        alert.informativeText = NSLocalizedString("Each file is edited where it is: the Queue searches for its metadata and writes the tags into the file, with no copy and no move to the library. If \u{201C}Set output filename\u{201D} is on in the Queue options, the file is also renamed from its tags.", comment: "Library scan -> confirm text")
        alert.addButton(withTitle: NSLocalizedString("Send to Queue", comment: "Library scan -> confirm button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Library scan -> button"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let added = QueueController.shared.addForInPlaceEdit(sendable.map { (url: $0.url, values: $0.values) }, tagKeys: self.scanFields.map { $0.key })
            var message = String.localizedStringWithFormat(NSLocalizedString("Sent %lu file(s) to the Queue.", comment: "Library scan -> status after sending files to the Queue"), added.movies + added.tvShows)
            if added.skipped > 0 {
                message += " " + String.localizedStringWithFormat(NSLocalizedString("%lu file(s) were already in the Queue.", comment: "Library scan -> status, files already queued"), added.skipped)
            }
            self.statusLabel.stringValue = message
            if added.movies > 0 || added.tvShows == 0 {
                QueueController.shared.showWindow(nil)
            } else {
                QueueController.tvShows.showWindow(nil)
            }
        }
    }

    // MARK: Editing a tag in place

    /// The tag key of a table column, nil for the File column.
    private func tagKey(ofColumn column: Int) -> String? {
        guard column >= 0, column < tableView.tableColumns.count else { return nil }
        let id = tableView.tableColumns[column].identifier.rawValue
        guard id.hasPrefix(LibraryScanWindowController.tagColumnPrefix) else { return nil }
        return String(id.dropFirst(LibraryScanWindowController.tagColumnPrefix.count))
    }

    private func canEditContextCell() -> Bool {
        guard isScanning == false, isWritingTag == false,
              contextRow >= 0, contextRow < results.count,
              results[contextRow].unreadable == false,
              let key = tagKey(ofColumn: contextColumn) else { return false }
        return LibraryScanEdit.canEdit(key: key)
    }

    @objc private func editContextCell(_ sender: Any?) {
        guard canEditContextCell(), let key = tagKey(ofColumn: contextColumn),
              let cell = tableView.view(atColumn: contextColumn, row: contextRow, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        let result = results[contextRow]
        editingField = field
        editingURL = result.url
        editingKey = key
        editingOriginal = result.values[key] ?? ""
        field.isEditable = true
        field.delegate = self
        field.textColor = .labelColor
        field.stringValue = editingOriginal
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endEditing(cancelled: Bool) {
        guard let field = editingField, let url = editingURL else { return }
        let key = editingKey
        let original = editingOriginal
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.isEditable = false
        editingField = nil
        editingURL = nil

        guard cancelled == false, text.isEmpty == false, text != original else {
            tableView.reloadData()
            return
        }

        let item: MP42MetadataItem
        switch LibraryScanEdit.makeItem(key: key, text: text) {
        case .success(let made): item = made
        case .failure(let problem):
            tableView.reloadData()
            showEditProblem(problem.localizedDescription)
            return
        }

        isWritingTag = true
        updateSelectionControlsState()
        statusLabel.stringValue = String(format: NSLocalizedString("Saving into \u{201C}%@\u{201D}\u{2026}", comment: "Library scan -> status while a tag is written into a file"), url.lastPathComponent)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try LibraryScanEdit.write(item, to: url) } catch { failure = error }
            DispatchQueue.main.async { self.finishEdit(url: url, key: key, item: item, text: text, error: failure) }
        }
    }

    private func finishEdit(url: URL, key: String, item: MP42MetadataItem, text: String, error: Error?) {
        isWritingTag = false
        if let error = error {
            LibraryScanWindowController.log("Library scan: could not write a tag into \(url.path): \(error.localizedDescription)")
            statusLabel.stringValue = String(format: NSLocalizedString("Could not save \u{201C}%@\u{201D}.", comment: "Library scan -> status when a tag could not be written"), url.lastPathComponent)
            showEditProblem(error.localizedDescription)
            updateSelectionControlsState()
            return
        }
        LibraryScanWindowController.log("Library scan: wrote \(key) into \(url.path)")
        if let index = results.firstIndex(where: { $0.url == url }) {
            results[index].values[key] = LibraryScanCell.text(for: item) ?? text
            // A file with nothing left missing no longer belongs in the list.
            if results[index].values.count >= scanFields.count {
                results.remove(at: index)
            }
        }
        sortAndReload()
        statusLabel.stringValue = String(format: NSLocalizedString("Saved into \u{201C}%@\u{201D} \u{2014} %d still listed.", comment: "Library scan -> status after a tag was written into a file"), url.lastPathComponent, results.count)
    }

    private func showEditProblem(_ text: String) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("The tag was not changed.", comment: "Library scan -> edit problem title")
        alert.informativeText = text
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Library scan -> button"))
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc private func openContextRowInEditor(_ sender: Any?) {
        guard contextRow >= 0, contextRow < results.count else { return }
        openInEditor(results[contextRow].url)
    }

    @objc private func revealContextRows(_ sender: Any?) {
        let urls = contextTargetResults().map { $0.url }
        guard urls.isEmpty == false else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func done(_ sender: Any?) {
        stopScan()
        close()
    }

    // MARK: Scanning

    private enum TagReadOutcome {
        case tags(MP42Metadata)
        case notScannable
        case timedOut
    }

    private final class TagReadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: MP42Metadata?
        func set(_ metadata: MP42Metadata?) { lock.lock(); stored = metadata; lock.unlock() }
        func get() -> MP42Metadata? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Reads only the tags of one file (no tracks, chapters or preview
    /// images -- see MP42File.readMetadata(ofFileAt:)), on its own thread
    /// so a stalled drive can't hold the whole scan: after `timeout`
    /// seconds the file is given up on (the read thread is simply left to
    /// finish or hang by itself and its result discarded).
    private static func readTags(of url: URL, timeout: TimeInterval) -> TagReadOutcome {
        let box = TagReadBox()
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .utility).async {
            box.set(MP42File.readMetadata(ofFileAt: url))
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            return .timedOut
        }
        if let metadata = box.get() {
            return .tags(metadata)
        }
        return .notScannable
    }

    private static func log(_ message: String) {
        DispatchQueue.main.async { Logger.shared.write(toLog: message) }
    }

    private func beginScan() {
        guard let folderURL = scannedFolderURL else { return }

        results = []
        scanFields = LibraryScanWindowController.fieldsToCheck()
        rebuildColumns()
        tableView.reloadData()
        updateSelectionControlsState()

        cancelRequested = false
        pauseGate.resume()
        isPausedUI = false
        scannedSoFar = 0
        isScanning = true
        progressIndicator.startAnimation(nil)
        currentFileName = ""
        statusLabel.stringValue = NSLocalizedString("Scanning\u{2026}", comment: "Library scan -> status")

        let fields = scanFields

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(at: folderURL,
                                                           includingPropertiesForKeys: [.isRegularFileKey],
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                           errorHandler: nil) else {
                DispatchQueue.main.async { self.finishScan(scannedCount: 0) }
                return
            }

            var scannedCount = 0
            var consecutiveTimeouts = 0
            var stoppedEarly = false
            var pendingResults: [ScanResult] = []
            var lastFlush = Date()

            for case let url as URL in enumerator {
                if self.cancelRequested { break }

                // Paused: show what has been found, then wait (no file is
                // being read while the scan waits).
                if self.pauseGate.isPaused {
                    let batch = pendingResults
                    pendingResults = []
                    lastFlush = Date()
                    let doneCount = scannedCount
                    DispatchQueue.main.async { self.appendResults(batch, scannedCount: doneCount + 1) }
                    self.pauseGate.waitWhilePaused(stopping: { self.cancelRequested }) {
                        DispatchQueue.main.async {
                            self.statusLabel.stringValue = String(format: NSLocalizedString("Paused after %d files \u{2014} %d listed.", comment: "Library scan -> status while paused"), doneCount, self.results.count)
                        }
                    }
                    if self.cancelRequested { break }
                }

                guard LibraryScanWindowController.scannableExtensions.contains(url.pathExtension.lowercased()) else { continue }

                scannedCount += 1

                // Show which file is being read before reading it, so a
                // slow or stuck one is named on screen.
                let name = url.lastPathComponent
                let countSoFar = scannedCount
                DispatchQueue.main.async {
                    self.currentFileName = name
                    self.refreshStatus(scannedCount: countSoFar)
                }

                let started = Date()
                switch LibraryScanWindowController.readTags(of: url, timeout: LibraryScanWindowController.readTimeout) {
                case .tags(let metadata):
                    consecutiveTimeouts = 0
                    let values = LibraryScanWindowController.values(in: metadata, fields: fields)
                    if values.count < fields.count {
                        pendingResults.append(ScanResult(url: url, values: values))
                    }
                case .notScannable:
                    consecutiveTimeouts = 0
                case .timedOut:
                    consecutiveTimeouts += 1
                    pendingResults.append(ScanResult(url: url, values: [:], unreadable: true))
                    LibraryScanWindowController.log("Library scan: gave up reading \(url.path) after \(Int(LibraryScanWindowController.readTimeout)) seconds")
                }

                let elapsed = Date().timeIntervalSince(started)
                if elapsed > LibraryScanWindowController.slowReadSeconds, elapsed < LibraryScanWindowController.readTimeout {
                    LibraryScanWindowController.log("Library scan: \(url.path) took \(Int(elapsed)) seconds to read")
                }

                // Flush to the table every few files (or every half
                // second, whichever comes first) rather than either
                // locking the UI with one update per file or making a
                // large scan look frozen until it's entirely done.
                if pendingResults.count >= 10 || Date().timeIntervalSince(lastFlush) > 0.5 {
                    let batch = pendingResults
                    pendingResults = []
                    lastFlush = Date()
                    DispatchQueue.main.async { self.appendResults(batch, scannedCount: countSoFar) }
                }

                if consecutiveTimeouts >= LibraryScanWindowController.maximumConsecutiveTimeouts {
                    stoppedEarly = true
                    LibraryScanWindowController.log("Library scan stopped: \(consecutiveTimeouts) files in a row could not be read. The drive may have stopped responding.")
                    break
                }
            }

            let finalBatch = pendingResults
            let finalCount = scannedCount
            let aborted = stoppedEarly
            DispatchQueue.main.async {
                if finalBatch.isEmpty == false {
                    self.appendResults(finalBatch, scannedCount: finalCount)
                }
                self.finishScan(scannedCount: finalCount, stoppedEarly: aborted)
            }
        }
    }

    private func refreshStatus(scannedCount: Int) {
        guard isScanning, isPausedUI == false else { return }
        scannedSoFar = scannedCount - 1
        statusLabel.stringValue = String(format: NSLocalizedString("Scanned %d files \u{2014} %d listed \u{2014} reading \u{201C}%@\u{201D}\u{2026}", comment: "Library scan -> progress status with the current file"), scannedCount - 1, results.count, currentFileName)
    }

    private func appendResults(_ batch: [ScanResult], scannedCount: Int) {
        results.append(contentsOf: batch)
        sortAndReload()
        refreshStatus(scannedCount: scannedCount)
    }

    private func finishScan(scannedCount: Int, stoppedEarly: Bool = false) {
        isPausedUI = false
        isScanning = false
        progressIndicator.stopAnimation(nil)
        currentFileName = ""
        if stoppedEarly {
            statusLabel.stringValue = String(format: NSLocalizedString("Stopped after %d files \u{2014} several files in a row could not be read. Check that the drive is responding.", comment: "Library scan -> stopped because reads timed out"), scannedCount)
        } else {
            statusLabel.stringValue = results.isEmpty
                ? String(format: NSLocalizedString("Scanned %d files \u{2014} nothing missing.", comment: "Library scan -> done status, none missing"), scannedCount)
                : String(format: NSLocalizedString("Scanned %d files \u{2014} %d missing metadata.", comment: "Library scan -> done status"), scannedCount, results.count)
        }
    }

    /// The text of each of `fields` that is filled in `metadata`, by tag
    /// key. A tag with no entry is empty or untagged (missing).
    private static func values(in metadata: MP42Metadata, fields: [(key: String, label: String)]) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            let items = metadata.metadataItemsFiltered(byIdentifier: field.key)
            if let text = LibraryScanCell.text(for: items) { values[field.key] = text }
        }
        return values
    }
}

extension LibraryScanWindowController: NSWindowDelegate {

    /// Closing the window stops a scan, including a paused one, which would
    /// otherwise wait for ever.
    func windowWillClose(_ notification: Notification) {
        if isScanning { stopScan() }
    }
}

extension LibraryScanWindowController: NSMenuDelegate, NSTextFieldDelegate {

    /// The right-click menu is built each time for the cell under the pointer.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextRow = tableView.clickedRow
        contextColumn = tableView.clickedColumn

        if contextRow >= 0, contextRow < results.count {
            let edit = NSMenuItem(title: NSLocalizedString("Edit\u{2026}", comment: "Library scan -> context menu"), action: #selector(editContextCell(_:)), keyEquivalent: "")
            edit.target = self
            edit.isEnabled = canEditContextCell()
            if tagKey(ofColumn: contextColumn) != nil {
                menu.addItem(edit)
                menu.addItem(.separator())
            }

            let count = contextTargetResults().filter { $0.unreadable == false }.count
            let send = NSMenuItem(title: count > 1
                ? String(format: NSLocalizedString("Send %d Files to Queue for In-Place Edit\u{2026}", comment: "Library scan -> context menu"), count)
                : NSLocalizedString("Send to Queue for In-Place Edit\u{2026}", comment: "Library scan -> context menu"),
                action: #selector(sendContextRowsToQueue(_:)), keyEquivalent: "")
            send.target = self
            send.isEnabled = count > 0 && isScanning == false && isWritingTag == false
            menu.addItem(send)
            menu.addItem(.separator())

            let open = NSMenuItem(title: NSLocalizedString("Open in Editor", comment: "Library scan -> context menu"), action: #selector(openContextRowInEditor(_:)), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let reveal = NSMenuItem(title: NSLocalizedString("Reveal in Finder", comment: "Library scan -> context menu"), action: #selector(revealContextRows(_:)), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
            menu.addItem(.separator())
        }

        let selectAll = NSMenuItem(title: NSLocalizedString("Select All", comment: "Library scan -> context menu"), action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "")
        selectAll.target = tableView
        menu.addItem(selectAll)

        let clear = NSMenuItem(title: NSLocalizedString("Clear List", comment: "Library scan -> context menu"), action: #selector(clearList(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = LibraryScanCell.canClear(isScanning: isScanning, isWritingTag: isWritingTag, listedCount: results.count)
        menu.addItem(.separator())
        menu.addItem(clear)
    }

    /// Return or Tab saves the typed value; Escape drops it.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === editingField else { return }
        let movement = obj.userInfo?["NSTextMovement"] as? Int
        endEditing(cancelled: movement == NSTextMovement.cancel.rawValue)
    }
}

extension LibraryScanWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < results.count else { return nil }
        let result = results[row]

        let identifier = NSUserInterfaceItemIdentifier("cell-\(tableColumn?.identifier.rawValue ?? "")")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let columnID = tableColumn?.identifier.rawValue ?? ""
        cell.textField?.isEditable = false
        cell.textField?.textColor = .labelColor
        cell.textField?.toolTip = nil
        if columnID == LibraryScanWindowController.fileColumnID {
            cell.textField?.stringValue = result.url.lastPathComponent
            cell.textField?.toolTip = result.url.path
        } else if result.unreadable {
            // The first tag column carries the explanation; the rest stay blank.
            let isFirstTagColumn = tableColumn === tableView.tableColumns.dropFirst().first
            cell.textField?.stringValue = isFirstTagColumn ? LibraryScanWindowController.unreadableLabel : "\u{2014}"
            cell.textField?.textColor = .secondaryLabelColor
        } else {
            let tag = String(columnID.dropFirst(LibraryScanWindowController.tagColumnPrefix.count))
            if let text = result.values[tag] {
                cell.textField?.stringValue = text
                cell.textField?.toolTip = text
            } else {
                cell.textField?.stringValue = LibraryScanCell.missingText
                cell.textField?.textColor = .systemRed
            }
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortAndReload()
        saveLayout()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionControlsState()
    }
}

/// What the Library scan shows in a tag's column, and how a column sorts.
enum LibraryScanCell {

    /// Whether Clear may empty the list: there is something listed and
    /// nothing is running (a scan, or a tag being written into a file).
    static func canClear(isScanning: Bool, isWritingTag: Bool, listedCount: Int) -> Bool {
        return isScanning == false && isWritingTag == false && listedCount > 0
    }

    static let missingText = NSLocalizedString("Missing", comment: "Library scan -> shown in a tag's column when the file has no value for it")

    /// The text of the first filled entry among `items`, or nil when there
    /// is none (the tag is missing). A tag counts as filled when it holds
    /// non-blank text, a number, a date, a list entry or an image.
    static func text(for items: [MP42MetadataItem]) -> String? {
        for item in items {
            if let text = text(for: item) { return text }
        }
        return nil
    }

    /// Tags a file stores as a code are shown by name: Media Kind 10 as
    /// "TV Show", Content Rating 4 as "Explicit", and a Rating such as
    /// "mpaa|R|300|" as "R" -- the same names the Editor shows. A code the
    /// lists do not know is shown as the number.
    static func codeName(for item: MP42MetadataItem) -> String? {
        switch item.identifier {
        case MP42MetadataKeyMediaKind, MP42MetadataKeyContentRating:
            let code = item.numberValue?.intValue ?? item.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let code = code else { return nil }
            let table = item.identifier == MP42MetadataKeyMediaKind ? MovieViewController.mediaKinds : MovieViewController.contentRatings
            return table.first { $0.value == code }?.title
        case MP42MetadataKeyRating:
            guard let raw = item.stringValue, raw.contains("|") else { return nil }
            let parts = raw.components(separatedBy: "|")
            let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return name.isEmpty ? nil : name
        default:
            return nil
        }
    }

    static func text(for item: MP42MetadataItem) -> String? {
        if let name = codeName(for: item) { return name }
        // A date is shown as day only (its text form carries a time and zone).
        if item.dataType == .date, let date = item.dateValue {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        if let string = item.stringValue {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = item.numberValue { return number.stringValue }
        if let date = item.dateValue {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        if let list = item.arrayValue, list.isEmpty == false {
            let joined = list.map { "\($0)" }.joined(separator: ", ")
            return joined.isEmpty ? "\u{2026}" : joined
        }
        if item.imageValue != nil { return NSLocalizedString("Artwork", comment: "Library scan -> shown for a tag that holds a picture") }
        return nil
    }

    /// The column heading for a tag: "Title" for the name tag (as the Library
    /// scan and the Queue both call it), otherwise the tag's own name.
    static func title(forKey key: String) -> String {
        if key == MP42MetadataKeyName { return NSLocalizedString("Title", comment: "Library scan -> field name") }
        return localizedMetadataKeyName(key) ?? key
    }

    /// The text of each of `keys` that is filled in `metadata`, by tag key.
    /// A tag with no entry is empty or untagged.
    static func values(in metadata: MP42Metadata, keys: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for key in keys {
            if let text = text(for: metadata.metadataItemsFiltered(byIdentifier: key)) { values[key] = text }
        }
        return values
    }

    /// Orders two column values for sorting: a missing value (nil) comes
    /// before any text, so the gaps gather at the top when sorted ascending.
    static func sortOrder(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (x?, y?): return x.localizedStandardCompare(y)
        }
    }
}

/// Writing one tag typed in the Library scan table straight into a file.
enum LibraryScanEdit {

    enum Problem: LocalizedError {
        case notEditable
        case badDate
        case badNumber

        var errorDescription: String? {
            switch self {
            case .notEditable:
                return NSLocalizedString("This tag cannot be typed in here. Open the file in the Editor to change it.", comment: "Library scan -> edit problem")
            case .badDate:
                return NSLocalizedString("Enter the date as YYYY-MM-DD, for example 2020-05-01.", comment: "Library scan -> edit problem")
            case .badNumber:
                return NSLocalizedString("Enter a whole number.", comment: "Library scan -> edit problem")
            }
        }
    }

    /// Tags that are not plain text, a whole number or a date -- pictures,
    /// lists, yes/no switches, and codes with a fixed set of values (such as
    /// Rating). They are changed in the Editor instead. (A list, rather than
    /// asking MP42MetadataItem for the tag's type, because building a
    /// picture tag from typed text is not supported.)
    private static let editorOnlyKeys: Set<String> = [
        MP42MetadataKeyCoverArt, MP42MetadataKeyRating, MP42MetadataKeyContentRating,
        MP42MetadataKeyCast, MP42MetadataKeyDirector, MP42MetadataKeyCodirector,
        MP42MetadataKeyProducer, MP42MetadataKeyScreenwriters,
        MP42MetadataKeyTrackNumber, MP42MetadataKeyDiscNumber,
        MP42MetadataKeyGapless, MP42MetadataKeyiTunesU, MP42MetadataKeyPodcast,
        MP42MetadataKeyShowWorkAndMovement, MP42MetadataKeyDiscCompilation,
        MP42MetadataKeyMediaKind, MP42MetadataKeyHDVideo,
        MP42MetadataKeyArtistID, MP42MetadataKeyComposerID, MP42MetadataKeyContentID,
        MP42MetadataKeyGenreID, MP42MetadataKeyPlaylistID,
        MP42MetadataKeyAccountKind, MP42MetadataKeyAccountCountry
    ]

    /// True for a tag that can be typed in the table.
    static func canEdit(key: String) -> Bool {
        return editorOnlyKeys.contains(key) == false
    }

    /// The tag to write for what was typed, or why it cannot be written.
    static func makeItem(key: String, text: String) -> Result<MP42MetadataItem, Problem> {
        guard canEdit(key: key) else { return .failure(.notEditable) }
        let item = MP42MetadataItem(identifier: key, value: text as NSString, dataType: .unspecified, extendedLanguageTag: nil)
        if key == MP42MetadataKeyReleaseDate {
            // A date that could not be read is kept as plain text, which
            // would write an unreadable release date.
            return item.dataType == .date ? .success(item) : .failure(.badDate)
        }
        if item.dataType == .integer, Int(text) == nil { return .failure(.badNumber) }
        return .success(item)
    }

    /// Replaces the tag in the file, keeping a copy of the file until the
    /// write has worked (put back if it fails).
    static func write(_ item: MP42MetadataItem, to url: URL) throws {
        let file = try MP42File(url: url)
        let metadata = file.metadata
        metadata.removeItems(metadata.metadataItemsFiltered(byIdentifier: item.identifier))
        metadata.addItem(item)

        let copy = QueueItem.makeSafetyCopy(of: url)
        do {
            try file.update(options: [:])
        } catch {
            if let copy = copy { QueueItem.restoreSafetyCopy(copy, over: url) }
            throw error
        }
        if let copy = copy { QueueItem.discardSafetyCopy(copy) }
    }
}

// MARK: - Remembered column layout

/// The order, widths and sort of the Library scan's columns, kept between
/// scans and launches. The columns are rebuilt whenever the checked tags
/// change, so this is saved by column name rather than by the table's own
/// autosave. A column that is not saved yet gets its default place.
struct LibraryScanLayout: Equatable {
    var order: [String] = []
    var widths: [String: Double] = [:]
    var sortKey: String?
    var ascending = true

    static let defaultsKey = "SBLibraryScanColumnLayout"

    static func load(from defaults: UserDefaults = .standard) -> LibraryScanLayout {
        var layout = LibraryScanLayout()
        guard let dictionary = defaults.dictionary(forKey: defaultsKey) else { return layout }
        layout.order = (dictionary["order"] as? [String]) ?? []
        if let widths = dictionary["widths"] as? [String: Double] { layout.widths = widths }
        layout.sortKey = dictionary["sortKey"] as? String
        layout.ascending = (dictionary["ascending"] as? Bool) ?? true
        return layout
    }

    func save(to defaults: UserDefaults = .standard) {
        var dictionary: [String: Any] = ["order": order, "widths": widths, "ascending": ascending]
        if let sortKey = sortKey { dictionary["sortKey"] = sortKey }
        defaults.set(dictionary, forKey: LibraryScanLayout.defaultsKey)
    }

    /// The columns in the order to show them: the saved order for the
    /// columns that were saved, and the others after them in their default
    /// order.
    static func order(of ids: [String], saved: [String]) -> [String] {
        let known = saved.filter { ids.contains($0) }
        return known + ids.filter { known.contains($0) == false }
    }

    /// The saved order with the columns now on screen in their new
    /// positions, then the saved columns that are not on screen right now (a
    /// tag that is unchecked for the moment).
    static func merged(saved: [String], current: [String]) -> [String] {
        return current + saved.filter { current.contains($0) == false }
    }
}

// MARK: - Pausing a scan

/// Lets the scan thread wait between files while the scan is paused. Kept on
/// its own so it can be tested without a window.
final class ScanPauseGate {

    private let condition = NSCondition()
    private var paused = false

    var isPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    func pause() {
        condition.lock()
        paused = true
        condition.unlock()
    }

    /// Lets a waiting scan carry on. Also how a cancel wakes a paused scan:
    /// set the cancel flag first, then call this.
    func resume() {
        condition.lock()
        paused = false
        condition.broadcast()
        condition.unlock()
    }

    /// Called on the scan thread between files. Returns at once unless the
    /// scan is paused; then calls `onWait` (once) and blocks until
    /// `resume()` is called or `stopping` says to stop.
    func waitWhilePaused(stopping: () -> Bool, onWait: () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        guard paused, stopping() == false else { return }
        onWait()
        while paused && stopping() == false { condition.wait() }
    }
}

#if DEBUG
// Used by DocsScreenshots (debug builds only): scans a folder without the folder chooser.
extension LibraryScanWindowController {
    func docsScan(folder: URL) {
        showWindow(nil)
        scannedFolderURL = folder
        folderField.stringValue = folder.path
        folderField.textColor = .labelColor
        scanButton.isEnabled = true
        beginScan()
    }

    var docsIsScanning: Bool { isScanning }

    /// "Send All to Queue" without the confirmation question. Returns how many files were sent.
    func docsSendAllToQueue() -> Int {
        let sendable = results.filter { $0.unreadable == false }
        guard sendable.isEmpty == false else { return 0 }
        let added = QueueController.shared.addForInPlaceEdit(sendable.map { (url: $0.url, values: $0.values) }, tagKeys: scanFields.map { $0.key })
        return added.movies + added.tvShows
    }
}
#endif
