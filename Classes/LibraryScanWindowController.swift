//
//  LibraryScanWindowController.swift
//  M3
//
//  Walks a chosen folder for already-processed media files (.mp4/.m4v/
//  .mov -- the formats a finished, tagged file in a library actually
//  sits in, as opposed to a raw download still awaiting Media Intake)
//  and flags any whose core metadata -- Title, Release Date, Rating,
//  Studio, plus any extra tags chosen with the gear button -- is still
//  missing, so a library built up over time can be
//  swept for gaps without re-checking every file by hand. Reached from
//  WelcomeWindowController's "Scan Library for Missing Metadata" action,
//  or any other future entry point via LibraryScanWindowController.shared.
//
//  Built entirely in code (no .xib), same reasoning as
//  NamingReviewWindowController/MergeReorderWindowController: a small
//  self-contained window with no reason to round-trip through Interface
//  Builder.
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
    /// missingFields(for:). Deliberately a small, practical set rather
    /// than every writable key: these are the ones this app's own
    /// Filename-tab naming rules and folder organization typically key
    /// off of (see NamingRules.swift / MP42FileAdditions.formattedFileName()),
    /// so a file missing one of these is also a file whose output name
    /// probably isn't right yet.
    private static let requiredFields: [(key: String, label: String)] = [
        (MP42MetadataKeyName, NSLocalizedString("Title", comment: "Library scan -> field name")),
        (MP42MetadataKeyReleaseDate, NSLocalizedString("Release Date", comment: "Library scan -> field name")),
        (MP42MetadataKeyRating, NSLocalizedString("Rating", comment: "Library scan -> field name")),
        (MP42MetadataKeyStudio, NSLocalizedString("Studio", comment: "Library scan -> field name"))
    ]

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

    private struct ScanResult {
        let url: URL
        let missingFields: [String]
    }

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

    private let tableView = NSTableView()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private var revealButton: NSButton!
    private var tagButton: NSButton!

    private var scannedFolderURL: URL?

    private var optionsButton: NSButton!
    private var optionsPopover: NSPopover?
    /// The identifiers behind the checkboxes in the gear panel (a
    /// checkbox's tag is its index here).
    private var optionKeys: [String] = []
    /// The file the scan is reading right now (main thread only).
    private var currentFileName = ""

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered,
                               defer: false)
        window.title = NSLocalizedString("Scan Library for Missing Metadata", comment: "Library scan -> window title")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        window.center()

        super.init(window: window)

        window.contentViewController = makeContentViewController()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Layout

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 440))
        controller.view = view

        folderField.translatesAutoresizingMaskIntoConstraints = false
        folderField.lineBreakMode = .byTruncatingMiddle
        folderField.stringValue = NSLocalizedString("No folder chosen", comment: "Library scan -> no folder placeholder")
        folderField.textColor = .secondaryLabelColor

        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder(_:))
        chooseFolderButton.translatesAutoresizingMaskIntoConstraints = false
        chooseFolderButton.bezelStyle = .rounded

        scanButton = NSButton(title: NSLocalizedString("Scan", comment: "Library scan -> button"), target: self, action: #selector(scanOrCancel(_:)))
        scanButton.translatesAutoresizingMaskIntoConstraints = false
        scanButton.bezelStyle = .rounded
        scanButton.keyEquivalent = "\r"
        scanButton.isEnabled = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let fileColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fileColumn.title = NSLocalizedString("File", comment: "Library scan -> column title")
        fileColumn.width = 340

        let missingColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("missing"))
        missingColumn.title = NSLocalizedString("Missing", comment: "Library scan -> column title")
        missingColumn.width = 220

        tableView.addTableColumn(fileColumn)
        tableView.addTableColumn(missingColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(tagSelected(_:))
        tableView.target = self
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

        optionsButton = NSButton(title: "", target: self, action: #selector(showOptions(_:)))
        optionsButton.translatesAutoresizingMaskIntoConstraints = false
        optionsButton.bezelStyle = .rounded
        optionsButton.image = NSImage(named: NSImage.actionTemplateName)
        optionsButton.imagePosition = .imageOnly
        optionsButton.toolTip = NSLocalizedString("Choose which tags the scan looks for.", comment: "Library scan -> gear button tooltip")

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
        view.addSubview(revealButton)
        view.addSubview(tagButton)
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            chooseFolderButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            chooseFolderButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            folderField.centerYAnchor.constraint(equalTo: chooseFolderButton.centerYAnchor),
            folderField.leadingAnchor.constraint(equalTo: chooseFolderButton.trailingAnchor, constant: 10),
            folderField.trailingAnchor.constraint(lessThanOrEqualTo: optionsButton.leadingAnchor, constant: -10),

            optionsButton.centerYAnchor.constraint(equalTo: chooseFolderButton.centerYAnchor),
            optionsButton.trailingAnchor.constraint(equalTo: scanButton.leadingAnchor, constant: -8),

            scanButton.centerYAnchor.constraint(equalTo: chooseFolderButton.centerYAnchor),
            scanButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

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

            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            doneButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        return controller
    }

    private func updateControlsState() {
        scanButton.title = isScanning
            ? NSLocalizedString("Cancel", comment: "Library scan -> button")
            : NSLocalizedString("Scan", comment: "Library scan -> button")
        chooseFolderButton.isEnabled = isScanning == false
    }

    private func updateSelectionControlsState() {
        let hasSelection = tableView.selectedRow != -1
        revealButton.isEnabled = hasSelection
        tagButton.isEnabled = hasSelection
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
    }

    @objc private func scanOrCancel(_ sender: Any?) {
        if isScanning {
            cancelRequested = true
        } else {
            beginScan()
        }
    }

    @objc private func revealSelected(_ sender: Any?) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < results.count else { return }
        NSWorkspace.shared.activateFileViewerSelecting([results[tableView.selectedRow].url])
    }

    @objc private func tagSelected(_ sender: Any?) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < results.count else { return }
        NSDocumentController.shared.openDocument(withContentsOf: results[tableView.selectedRow].url, display: true) { document, _, error in
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

    @objc private func done(_ sender: Any?) {
        cancelRequested = true
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
        tableView.reloadData()
        updateSelectionControlsState()

        cancelRequested = false
        isScanning = true
        progressIndicator.startAnimation(nil)
        currentFileName = ""
        statusLabel.stringValue = NSLocalizedString("Scanning\u{2026}", comment: "Library scan -> status")

        let fields = LibraryScanWindowController.fieldsToCheck()

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
                    let missing = LibraryScanWindowController.missingFields(in: metadata, fields: fields)
                    if missing.isEmpty == false {
                        pendingResults.append(ScanResult(url: url, missingFields: missing))
                    }
                case .notScannable:
                    consecutiveTimeouts = 0
                case .timedOut:
                    consecutiveTimeouts += 1
                    pendingResults.append(ScanResult(url: url, missingFields: [LibraryScanWindowController.unreadableLabel]))
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
        guard isScanning else { return }
        statusLabel.stringValue = String(format: NSLocalizedString("Scanned %d files \u{2014} %d listed \u{2014} reading \u{201C}%@\u{201D}\u{2026}", comment: "Library scan -> progress status with the current file"), scannedCount - 1, results.count, currentFileName)
    }

    private func appendResults(_ batch: [ScanResult], scannedCount: Int) {
        results.append(contentsOf: batch)
        tableView.reloadData()
        refreshStatus(scannedCount: scannedCount)
    }

    private func finishScan(scannedCount: Int, stoppedEarly: Bool = false) {
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

    /// Which of `fields` are empty or untagged in `metadata` -- see
    /// requiredFields for the always-checked set and fieldsToCheck() for
    /// the user's extras.
    private static func missingFields(in metadata: MP42Metadata, fields: [(key: String, label: String)]) -> [String] {
        fields.compactMap { field in
            let items = metadata.metadataItemsFiltered(byIdentifier: field.key)
            return items.contains(where: { isFilled($0) }) ? nil : field.label
        }
    }

    /// A tag counts as filled when it holds some value: non-blank text,
    /// a number, a date, a list entry or an image.
    private static func isFilled(_ item: MP42MetadataItem) -> Bool {
        if let text = item.stringValue {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        if item.numberValue != nil || item.dateValue != nil || item.imageValue != nil { return true }
        if let list = item.arrayValue { return list.isEmpty == false }
        return false
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

        if tableColumn?.identifier.rawValue == "file" {
            cell.textField?.stringValue = result.url.lastPathComponent
        } else {
            cell.textField?.stringValue = result.missingFields.joined(separator: ", ")
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionControlsState()
    }
}
