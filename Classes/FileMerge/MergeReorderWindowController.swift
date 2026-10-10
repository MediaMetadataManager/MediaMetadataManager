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
//  Also runs MergeCompatibility.check(files:) live as the order changes
//  (see updateCompatibility()) and disables Merge when the current order
//  isn't mergeable -- closing the design doc's "live compatibility
//  preview" item, which previously only surfaced a mismatch after Merge
//  was clicked and the destination panel/release merge actually ran.
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

    /// Disabled whenever updateCompatibility() finds the current order
    /// incompatible, so there's no point clicking through to a destination
    /// panel (or, for a release-driven merge, starting the merge) that
    /// MergeCompatibility.check would just reject anyway.
    private var mergeButton: NSButton!

    init(files: [URL]) {
        orderedFiles = MergeReorderWindowController.defaultOrder(for: files)

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

        let label = NSTextField(wrappingLabelWithString: NSLocalizedString("Drag to set the order the files should play in:", comment: "Merge reorder window -> label"))
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

    /// Runs MergeCompatibility.check(files:) against the current
    /// orderedFiles and reflects the result in statusLabel/mergeButton --
    /// called once from init (so the sheet opens already showing whether
    /// the starting order is mergeable) and again after every reorder
    /// (tableView(_:acceptDrop:row:dropOperation:) below). Cheap enough to
    /// run eagerly on every change: per MergeCompatibility.check's own doc
    /// comment it only opens each file and inspects track metadata -- the
    /// same cost the destination panel/release merge already pays once at
    /// merge time, just paid here earlier and repeatedly instead of once
    /// at the end.
    private func updateCompatibility() {
        do {
            _ = try MergeCompatibility.check(files: orderedFiles)
            statusLabel.stringValue = NSLocalizedString("\u{2713} All files are compatible and can be merged.", comment: "Merge reorder window -> compatible status")
            statusLabel.textColor = .secondaryLabelColor
            mergeButton.isEnabled = true
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
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
        guard let window = window, let sheetParent = window.sheetParent else { return }
        sheetParent.endSheet(window, returnCode: response)
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
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()

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
        updateCompatibility()
        return true
    }
}
