//
//  LibraryScanWindowController.swift
//  M3
//
//  Walks a chosen folder for already-processed media files (.mp4/.m4v/
//  .mov -- the formats a finished, tagged file in a library actually
//  sits in, as opposed to a raw download still awaiting Media Intake)
//  and flags any whose core metadata -- Title, Release Date, Rating,
//  Studio -- is still missing, so a library built up over time can be
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

    private struct ScanResult {
        let url: URL
        let missingFields: [String]
    }

    private var results: [ScanResult] = []
    private var isScanning = false {
        didSet { updateControlsState() }
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

        let doneButton = NSButton(title: NSLocalizedString("Done", comment: "Library scan -> button"), target: self, action: #selector(done(_:)))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\u{1b}"

        view.addSubview(folderField)
        view.addSubview(chooseFolderButton)
        view.addSubview(scanButton)
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
            folderField.trailingAnchor.constraint(lessThanOrEqualTo: scanButton.leadingAnchor, constant: -10),

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

    private func beginScan() {
        guard let folderURL = scannedFolderURL else { return }

        results = []
        tableView.reloadData()
        updateSelectionControlsState()

        cancelRequested = false
        isScanning = true
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = NSLocalizedString("Scanning\u{2026}", comment: "Library scan -> status")

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
            var pendingResults: [ScanResult] = []
            var lastFlush = Date()

            for case let url as URL in enumerator {
                if self.cancelRequested { break }

                guard LibraryScanWindowController.scannableExtensions.contains(url.pathExtension.lowercased()) else { continue }

                scannedCount += 1

                if let mp4 = try? MP42File(url: url) {
                    let missing = LibraryScanWindowController.missingFields(for: mp4)
                    if missing.isEmpty == false {
                        pendingResults.append(ScanResult(url: url, missingFields: missing))
                    }
                }

                // Flush to the table every few files (or every half
                // second, whichever comes first) rather than either
                // locking the UI with one update per file or making a
                // large scan look frozen until it's entirely done.
                if pendingResults.count >= 10 || Date().timeIntervalSince(lastFlush) > 0.5 {
                    let batch = pendingResults
                    pendingResults = []
                    lastFlush = Date()
                    let countSoFar = scannedCount
                    DispatchQueue.main.async { self.appendResults(batch, scannedCount: countSoFar) }
                }
            }

            let finalBatch = pendingResults
            let finalCount = scannedCount
            DispatchQueue.main.async {
                if finalBatch.isEmpty == false {
                    self.appendResults(finalBatch, scannedCount: finalCount)
                }
                self.finishScan(scannedCount: finalCount)
            }
        }
    }

    private func appendResults(_ batch: [ScanResult], scannedCount: Int) {
        results.append(contentsOf: batch)
        tableView.reloadData()
        statusLabel.stringValue = String(format: NSLocalizedString("Scanned %d files \u{2014} %d missing metadata\u{2026}", comment: "Library scan -> progress status"), scannedCount, results.count)
    }

    private func finishScan(scannedCount: Int) {
        isScanning = false
        progressIndicator.stopAnimation(nil)
        statusLabel.stringValue = results.isEmpty
            ? String(format: NSLocalizedString("Scanned %d files \u{2014} nothing missing.", comment: "Library scan -> done status, none missing"), scannedCount)
            : String(format: NSLocalizedString("Scanned %d files \u{2014} %d missing metadata.", comment: "Library scan -> done status"), scannedCount, results.count)
    }

    /// Which of LibraryScanWindowController.requiredFields are empty or
    /// untagged on `mp4` -- see that property's own doc comment for why
    /// these four and not every writable key.
    private static func missingFields(for mp4: MP42File) -> [String] {
        requiredFields.compactMap { field in
            let value = mp4.metadata.metadataItemsFiltered(byIdentifier: field.key).first?.stringValue
            let isMissing = value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            return isMissing ? field.label : nil
        }
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
