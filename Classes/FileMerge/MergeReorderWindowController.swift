//
//  MergeReorderWindowController.swift
//  Subler
//
//  A small window that lets the user drag the files chosen for a merge
//  into the order they should play, before FileMerger actually runs --
//  see QueueController.mergeSelectedItems(_:), the merge feature's
//  Queue-integrated entry point. Reuses the exact same NSTableView
//  drag-and-drop reordering convention already used by the Queue's own
//  table (QueueController.swift's writeRowsWith/validateDrop/acceptDrop),
//  per the merge design doc's own confirmed direction (kept in this
//  project's notes) to match Subler's existing method rather than invent
//  a new interaction.
//
//  Also checks every file for compatibility when the sheet opens (in the
//  background, see updateCompatibility()), marks the file that doesn't fit
//  with a warning icon and the reason, and keeps Merge disabled until all
//  files fit. Compatibility doesn't depend on the order, so dragging
//  doesn't re-read the files.
//

import Cocoa

final class MergeReorderWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    /// The files in their current order -- starts as defaultOrder(for:)'s
    /// best guess at the files' real play order (see below), not simply
    /// whatever order the caller handed them in, and is mutated in place
    /// as the user drags rows around from there. Read this back after the
    /// sheet ends with .OK. Whatever the user drags to is always final --
    /// nothing here ever re-sorts underneath a manual reorder.
    private(set) var orderedFiles: [URL]

    /// Files unticked in the list: they stay in the list but are left out of
    /// the merge. A file about as big as all the others together (the
    /// finished merge from an earlier run) starts unticked.
    private var excluded = Set<URL>()

    /// What gets merged: the ticked files, in the order shown. Read this,
    /// not `orderedFiles`, after the sheet ends with .OK.
    var filesToMerge: [URL] {
        return orderedFiles.filter { excluded.contains($0) == false }
    }

    private let tableView = NSTableView()
    private let fileColumn = NSUserInterfaceItemIdentifier("file")
    private let pasteboardType = NSPasteboard.PasteboardType("SublerMergeReorderRowType")

    /// Reflects MergeCompatibility.check(files:) against the current
    /// orderedFiles -- updated on init and after every reorder (see
    /// tableView(_:acceptDrop:row:dropOperation:) below), not just at
    /// merge time. Closes the design doc's still-open "live compatibility
    /// preview" item: a mismatched set of files is now flagged the moment
    /// it's mismatched, rather than only after the user clicks Merge and
    /// moves on to the destination panel.
    private var statusLabel: NSTextField!

    /// Disabled while the check runs and whenever it finds a file that does
    /// not fit, so there's no point clicking through to a destination panel
    /// (or, for a release-driven merge, starting the merge) that
    /// MergeCompatibility.check would just reject anyway.
    private var mergeButton: NSButton!

    init(files: [URL]) {
        let ordered = MergeReorderWindowController.defaultOrder(for: files)
        orderedFiles = ordered

        let sized = ordered.map { (url: $0, size: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)) }
        if let found = AlreadyMergedDetector.find(in: sized) {
            excluded = [found.merged]
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 344),
                               styleMask: [.titled],
                               backing: .buffered,
                               defer: false)
        window.title = NSLocalizedString("Merge Order", comment: "Merge reorder window -> title")

        super.init(window: window)

        window.contentViewController = makeContentViewController()
        updateCompatibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Default order

    /// A best-effort starting order for the table, sorted by whatever
    /// per-file sequence number can be found in each file's own name --
    /// see ReleaseFilenameParser.extractSequence(_:excluding:) and
    /// looseSequence(_:), which together cover the numbering conventions
    /// actually seen in real multi-part releases (checked against a real
    /// folder of similarly-named downloaded releases): plain "01"/"001",
    /// a trailing number after a restated title like "Sample Title
    /// (2017) 2.mp4", and a bare letter+digit like "e1"/"p1". This is
    /// only a *default*:
    /// once the sheet is on screen, the user's own drag-and-drop is
    /// final and nothing here ever re-sorts underneath them -- the point
    /// is just that a user who never touches the list still gets the
    /// files in the right order most of the time, instead of whatever
    /// order they happened to be selected/added to the Queue in.
    ///
    /// Numbers already embedded in the files' own shared folder name
    /// (e.g. the "4" in a "Sample Title 4" release, restated in
    /// each scene file's own name too) are excluded from consideration,
    /// the same way the Intake Manager's renaming pipeline already
    /// excludes them -- otherwise a restated title number gets mistaken
    /// for the distinguishing per-file sequence number.
    ///
    /// Files with no detected number at all (e.g. ones named only by
    /// performer, with nothing to go on) sort after every numbered file
    /// but otherwise keep their original relative order -- there's no
    /// information to sort them by, so this just avoids scrambling them
    /// arbitrarily.
    /// Not private -- QueueController.attemptAutoMerge(for:) (Intake/
    /// Queue workflow section 7b, "auto mode") reuses this exact same
    /// ordering for an automatic merge, so an auto-merged release ends
    /// up in the same order the manual reorder sheet would have started
    /// it at.
    static func defaultOrder(for files: [URL]) -> [URL] {
        let parentFolders = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
        let excludedNumbers: Set<Int> = parentFolders.count == 1
            ? ReleaseFilenameParser.numbersInTitle(parentFolders.first?.lastPathComponent ?? "")
            : []

        let decorated = files.enumerated().map { (offset: $0.offset, file: $0.element, sequence: detectedSequence(for: $0.element, excluding: excludedNumbers)) }
        guard decorated.contains(where: { $0.sequence != nil }) else { return files }

        return decorated.sorted { lhs, rhs in
            if let l = lhs.sequence, let r = rhs.sequence, l != r {
                return l < r
            }
            if (lhs.sequence == nil) != (rhs.sequence == nil) {
                return lhs.sequence != nil
            }
            return lhs.offset < rhs.offset
        }.map { $0.file }
    }

    /// The same per-file sequence lookup defaultOrder(for:) above uses to
    /// seed the manual reorder sheet, pulled out so
    /// everyFileHasDetectedSequence(_:) below can run the identical check
    /// without duplicating the fallback chain
    /// (extractSequence(_:excluding:), then looseSequence(_:)).
    private static func detectedSequence(for file: URL, excluding excludedNumbers: Set<Int>) -> Int? {
        let baseName = file.deletingPathExtension().lastPathComponent
        return ReleaseFilenameParser.extractSequence(baseName, excluding: excludedNumbers)
            ?? ReleaseFilenameParser.looseSequence(baseName)
    }

    /// True only when EVERY file in `files` has an actual *detected*
    /// sequence number -- not the "no number, keep original order"
    /// fallback defaultOrder(for:) above tolerates for the manual reorder
    /// sheet's starting order. Backs the "auto mode" gate in
    /// QueueController.attemptAutoMerge(for:) (Intake/Queue workflow
    /// section 7b): automatically skipping the confirmation sheet is only
    /// reasonable when there's no ambiguity left for a human to resolve,
    /// so a single un-numbered file in the set is enough to fall back to
    /// the manual sheet, same as an ordinary multi-file merge does today.
    static func everyFileHasDetectedSequence(_ files: [URL]) -> Bool {
        guard files.isEmpty == false else { return false }

        let parentFolders = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
        let excludedNumbers: Set<Int> = parentFolders.count == 1
            ? ReleaseFilenameParser.numbersInTitle(parentFolders.first?.lastPathComponent ?? "")
            : []

        return files.allSatisfy { detectedSequence(for: $0, excluding: excludedNumbers) != nil }
    }

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 344))
        controller.view = view

        let label = NSTextField(wrappingLabelWithString: NSLocalizedString("Drag to set the order the files should play in. Untick a file to leave it out:", comment: "Merge reorder window -> label"))
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let column = NSTableColumn(identifier: fileColumn)
        column.title = NSLocalizedString("File", comment: "Merge reorder window -> column title")
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.registerForDraggedTypes([pasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.allowsMultipleSelection = false

        scrollView.documentView = tableView

        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Merge reorder window -> button"), target: self, action: #selector(cancel(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"

        mergeButton = NSButton(title: NSLocalizedString("Merge", comment: "Merge reorder window -> button"), target: self, action: #selector(confirm(_:)))
        mergeButton.translatesAutoresizingMaskIntoConstraints = false
        mergeButton.keyEquivalent = "\r"
        mergeButton.bezelStyle = .rounded

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail

        view.addSubview(label)
        view.addSubview(scrollView)
        view.addSubview(statusLabel)
        view.addSubview(cancelButton)
        view.addSubview(mergeButton)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -10),

            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            mergeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            mergeButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        return controller
    }

    /// Per-file result of the compatibility check, keyed by file. Compatibility
    /// does not depend on the order, so the files are read once, in the
    /// background, when the sheet opens; dragging only redraws the status.
    private var report: MergeFitReport?
    private var analysisStarted = false
    /// What was read from each file that could be opened.
    private var signatures: [URL: MergeFileSignature] = [:]

    /// Starts the one-time background check. Until it finishes the sheet says
    /// "Checking files..." and Merge stays disabled, so a slow drive or large
    /// files never freeze the window.
    private func updateCompatibility() {
        refreshStatus()
        guard analysisStarted == false else { return }
        analysisStarted = true

        let files = orderedFiles
        reportFiles = files
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var read: [URL: MergeFileSignature] = [:]
            for file in files {
                if let signature = try? MergeFileSignature.read(from: file) { read[file] = signature }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.signatures = read
                self.analysisFinished = true
                self.rebuildReport()
            }
        }
    }

    private var analysisFinished = false

    /// Judges only the ticked files against each other; called when the
    /// files have been read and whenever a file is ticked or unticked.
    private func rebuildReport() {
        guard analysisFinished else { return }
        let included = filesToMerge
        reportFiles = included
        report = MergeFitReport.make(signatures: included.map { signatures[$0] })
        tableView.reloadData()
        refreshStatus()
    }

    @objc private func toggleInclude(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < orderedFiles.count else { return }
        let url = orderedFiles[row]
        if sender.state == .on { excluded.remove(url) } else { excluded.insert(url) }
        rebuildReport()
    }

    /// The problem text for the file at `url`, from the finished check.
    private func problem(for url: URL) -> String? {
        guard let report = report, let index = reportFiles.firstIndex(of: url) else { return nil }
        return report.problems[index]
    }

    /// The files the report was made for, in the order it was made.
    private var reportFiles: [URL] = []

    private func refreshStatus() {
        statusLabel.toolTip = nil
        guard let report = report else {
            statusLabel.stringValue = NSLocalizedString("Checking files\u{2026}", comment: "Merge reorder window -> checking status")
            statusLabel.textColor = .secondaryLabelColor
            mergeButton.isEnabled = false
            return
        }

        if let overall = report.overallProblem {
            statusLabel.stringValue = overall
            statusLabel.textColor = .systemRed
            mergeButton.isEnabled = false
        } else if report.isCompatible {
            statusLabel.stringValue = NSLocalizedString("\u{2713} All files are compatible and can be merged.", comment: "Merge reorder window -> compatible status")
            statusLabel.textColor = .secondaryLabelColor
            mergeButton.isEnabled = true
        } else {
            let odd = report.problems.enumerated().compactMap { index, text in text.map { (reportFiles[index], $0) } }
            var message = String(format: NSLocalizedString("\u{201C}%@\u{201D} doesn\u{2019}t fit: %@", comment: "Merge reorder window -> odd file status"), odd[0].0.lastPathComponent, odd[0].1)
            if odd.count > 1 {
                message += String(format: NSLocalizedString(" (and %ld more)", comment: "Merge reorder window -> more odd files"), odd.count - 1)
            }
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
            statusLabel.toolTip = message
            mergeButton.isEnabled = false
        }
    }

    // MARK: Actions

    /// Both actions end the sheet the caller presented this window as --
    /// QueueController.mergeSelectedItems(_:) reads orderedFiles back from
    /// the completion handler when the response is .OK, and does nothing
    /// at all on .cancel, leaving the Queue untouched.
    @objc private func cancel(_ sender: Any?) {
        endSheet(with: .cancel)
    }

    @objc private func confirm(_ sender: Any?) {
        endSheet(with: .OK)
    }

    private func endSheet(with response: NSApplication.ModalResponse) {
        guard let window = window else { return }
        MovableDialog.end(window, with: response)
    }

    // MARK: NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return orderedFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("fileCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleInclude(_:)))
            checkbox.identifier = NSUserInterfaceItemIdentifier("includeCheckbox")
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            checkbox.toolTip = NSLocalizedString("Untick to leave this file out of the merge", comment: "Merge reorder window -> checkbox tooltip")
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            cell.addSubview(checkbox)
            cell.addSubview(textField)
            cell.addSubview(icon)
            cell.textField = textField
            cell.imageView = icon
            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                checkbox.widthAnchor.constraint(equalToConstant: 18),
                textField.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: icon.leadingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16)
            ])
            return cell
        }()

        let url = orderedFiles[row]
        let included = excluded.contains(url) == false
        if let checkbox = cell.subviews.first(where: { $0.identifier?.rawValue == "includeCheckbox" }) as? NSButton {
            checkbox.state = included ? .on : .off
        }
        cell.textField?.textColor = included ? .labelColor : .disabledControlTextColor
        if included == false {
            cell.imageView?.image = nil
            cell.toolTip = NSLocalizedString("Left out of the merge", comment: "Merge reorder window -> unticked file tooltip")
        } else if let problem = problem(for: url) {
            cell.imageView?.image = NSImage(named: NSImage.cautionName)
            cell.toolTip = problem
        } else {
            cell.imageView?.image = nil
            cell.toolTip = nil
        }
        cell.textField?.stringValue = orderedFiles[row].lastPathComponent
        return cell
    }

    /// Same pasteboard-of-row-indexes approach as
    /// QueueController.tableView(_:writeRowsWith:to:) -- an in-process
    /// reorder, not an export of the files themselves.
    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: rowIndexes, requiringSecureCoding: true)
        pboard.declareTypes([pasteboardType], owner: self)
        pboard.setData(data, forType: pasteboardType)
        return true
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if info.draggingSource is NSTableView, dropOperation == .above {
            return .move
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let rowData = info.draggingPasteboard.data(forType: pasteboardType),
              let rowIndexes = NSKeyedUnarchiver.unarchiveObject(with: rowData) as? IndexSet
        else { return false }

        let moving = rowIndexes.map { orderedFiles[$0] }
        var destination = row

        for index in rowIndexes.sorted(by: >) {
            orderedFiles.remove(at: index)
            if index < destination {
                destination -= 1
            }
        }

        for (offset, url) in moving.enumerated() {
            orderedFiles.insert(url, at: destination + offset)
        }

        tableView.reloadData()
        return true
    }
}
