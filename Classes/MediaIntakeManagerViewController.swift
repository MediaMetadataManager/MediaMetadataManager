//
//  MediaIntakeManagerViewController.swift
//  Subler
//
//  Settings for the intake side of the Intake/Queue workflow
//  (MediaMetadataManager only -- not part of the public Subler app): where new, unprocessed
//  media lands (e.g. a download client's output folder), whether that
//  folder should be watched automatically, and where a finished,
//  fully-tagged release goes to wait for one last human look before it
//  reaches the actual media server ("Ready for Media Library").
//
//  This used to also be where the work itself happened -- a live
//  pending list with Scan Now / Approve / Reject, scanning the incoming
//  folder and renaming recognized releases (ReleaseFilenameParser) in
//  place. That working UI has moved into the Queue itself as part of a
//  broader redesign (see the "Intake/Queue workflow" and "Queue release
//  model" design docs kept in this project's notes), since the point of
//  that redesign is for monitoring, naming approval, metadata search,
//  and merging to all happen in one place the user already checks --
//  the Queue -- rather than a separate pane. This view controller now
//  only owns the two settings that workflow reads plus the auto-watch
//  toggle; it no longer runs any watching or renaming logic itself.
//  IntakeFolderWatcher (previously used by the retired working UI) is
//  untouched and is meant to be picked up by the Queue's own intake
//  coordinator once that's built.
//
//  This intentionally leaves the native "Filename" tab (Preferences ->
//  Metadata; see OutputPrefsViewController / MP42FileAdditions) alone.
//  That tab formats a file's Save As/Queue output name from metadata
//  already embedded in an MP42File -- a later pipeline stage than this
//  one, which only ever sees a raw, untagged filename straight off a
//  download client. The two don't currently overlap enough to merge.
//

import Cocoa

final class MediaIntakeManagerViewController: NSViewController, NSTextFieldDelegate {

    private var intakeFolderList: FolderListView!
    private var scanNowButton: NSButton!
    private var resetScanButton: NSButton!
    private var scanResultLabel: NSTextField!
    private var readyForLibraryFolderField: NSTextField!
    private var autoWatchCheckbox: NSButton!
    private var renameAfterMergeCheckbox: NSButton!
    private var autoApproveHighConfidenceCheckbox: NSButton!
    private var autoMergeOnSequenceCheckbox: NSButton!
    private var autoCleanEmptyFoldersCheckbox: NSButton!
    private var autoCleanProcessedFilesCheckbox: NSButton!
    private var autoRemoveCompletedCheckbox: NSButton!
    private var runQueuesTogetherCheckbox: NSButton!
    private var sendEpisodesToTVTabCheckbox: NSButton!

    /// Maps each editable folder field to the preference it writes to, so
    /// one text-field delegate method (controlTextDidEndEditing(_:)) can
    /// commit whichever field the user actually typed into -- see
    /// makeFolderRow(title:chooseAction:getValue:setValue:field:).
    private var fieldSetters: [ObjectIdentifier: (URL?) -> Void] = [:]

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 480))
        self.view = view

        // mainStack below is deliberately bottom-pinned to this view
        // (see the constraint block further down) -- this is the
        // sizing signal SourcesPrefsViewController's shared tab canvas
        // relies on to know how tall this tab actually needs to be
        // (see that file's loadView() comment). Without it, this
        // view's own fittingSize has no lower bound tied to its real
        // content, so the shared canvas can end up shorter than this
        // tab needs once enough checkboxes accumulate here, clipping
        // the bottom rows instead of growing the window to fit them.

        let headerLabel = NSTextField(labelWithString: NSLocalizedString("Media Intake", comment: ""))
        headerLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let descriptionLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("Where new media lands, and where a finished release goes to wait for a final check before reaching your media server. The actual monitoring, naming, metadata, and merge workflow runs in the Queue.", comment: ""))
        descriptionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.preferredMaxLayoutWidth = 620

        let intakeList = FolderListView()
        intakeList.alwaysKeepsOneRow = true
        intakeList.onChange = { MediaIntakePrefs.intakeFolders = $0 }
        intakeList.onLayoutChange = { [weak self] in self?.folderListLayoutDidChange() }
        intakeList.setFolders(MediaIntakePrefs.intakeFolders)
        intakeFolderList = intakeList
        scanNowButton = NSButton(title: NSLocalizedString("Scan Now", comment: ""), target: self, action: #selector(scanNow(_:)))
        scanNowButton.bezelStyle = .rounded
        scanNowButton.controlSize = .small
        scanNowButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        scanNowButton.toolTip = NSLocalizedString("Look in the Incoming Folders right now and add whatever is there to the Queue (TV episodes go to the TV Show Queue), even if automatic watching is off.", comment: "")
        scanNowButton.translatesAutoresizingMaskIntoConstraints = false

        resetScanButton = NSButton(title: NSLocalizedString("Reset Scan\u{2026}", comment: ""), target: self, action: #selector(resetScan(_:)))
        resetScanButton.bezelStyle = .rounded
        resetScanButton.controlSize = .small
        resetScanButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        resetScanButton.toolTip = NSLocalizedString("Forget which files the scan has already taken in, then scan again. Use this when a file or folder in an Incoming Folder is not being picked up.", comment: "")
        resetScanButton.translatesAutoresizingMaskIntoConstraints = false

        scanResultLabel = NSTextField(labelWithString: "")
        scanResultLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        scanResultLabel.textColor = .secondaryLabelColor
        scanResultLabel.translatesAutoresizingMaskIntoConstraints = false

        let intakeSection = makeFolderListSection(title: NSLocalizedString("Incoming Folders", comment: ""), list: intakeList,
                                                  accessories: [scanNowButton, resetScanButton, scanResultLabel])

        autoWatchCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Automatically watch these folders for new files", comment: ""),
                                      target: self, action: #selector(toggleAutoWatch(_:)))
        autoWatchCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoWatchCheckbox.toolTip = NSLocalizedString("New releases found in these folders are picked up by the Queue for you to review.", comment: "")

        autoApproveHighConfidenceCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Automatically approve high-confidence naming matches", comment: ""),
                                                      target: self, action: #selector(toggleAutoApproveHighConfidenceNaming(_:)))
        autoApproveHighConfidenceCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoApproveHighConfidenceCheckbox.toolTip = NSLocalizedString("When the naming review window finds an online match whose title and year agree with the local filename guess, it fills it in and approves automatically after a moment instead of waiting for a manual click. The window still briefly shows the match first, so there's time to reject it if it looks wrong.", comment: "")

        _ = makeFolderRow(title: NSLocalizedString("Ready for Media Library", comment: ""),
                                                    chooseAction: #selector(chooseReadyForLibraryFolder(_:)),
                                                    getValue: { MediaIntakePrefs.readyForLibraryFolder },
                                                    setValue: { MediaIntakePrefs.readyForLibraryFolder = $0 },
                                                    field: &readyForLibraryFolderField)

        renameAfterMergeCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Rename the source folder after merging, when a correct name is found", comment: ""),
                                             target: self, action: #selector(toggleRenameAfterMerge(_:)))
        renameAfterMergeCheckbox.translatesAutoresizingMaskIntoConstraints = false
        renameAfterMergeCheckbox.toolTip = NSLocalizedString("After the Queue's Merge button finishes, rename the merged files' shared folder to the release's real title if one can be found nearby (a cover image, the folder's own name, or a video file already carrying it) and it differs from the folder's current name. Off by default, since this renames a real folder on disk rather than just filling in a save-panel field.", comment: "")

        autoMergeOnSequenceCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Automatically merge multi-file releases with a clear sequence", comment: ""),
                                                target: self, action: #selector(toggleAutoMergeOnSequence(_:)))
        autoMergeOnSequenceCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoMergeOnSequenceCheckbox.toolTip = NSLocalizedString("Once naming is approved for a release with more than one file, merge them automatically -- in the order their names already indicate (01/02/\u{2026}, Part 1/Part 2, \u{2026}) -- instead of always stopping at the manual reorder sheet. Only applies when every file in the set has a clearly detected sequence number and they're confirmed compatible; otherwise the row waits for you to confirm the order.", comment: "")

        autoCleanEmptyFoldersCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Remove empty folders automatically", comment: ""),
                                                  target: self, action: #selector(toggleAutoCleanEmptyFolders(_:)))
        autoCleanEmptyFoldersCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoCleanEmptyFoldersCheckbox.toolTip = NSLocalizedString("After each Queue run and each Edit-window save, move folders inside the Intake and Ready for Media Library folders that hold nothing (or only .DS_Store files) to the Trash, and add their paths to a log file (Removed Empty Folders.txt in Application Support/M3). Folders touched in the last two minutes are left alone. The same cleanup can be run by hand from Window \u{2192} Clean Up Empty Folders\u{2026}.", comment: "")

        autoCleanProcessedFilesCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Clean up processed files", comment: ""),
                                                    target: self, action: #selector(toggleAutoCleanProcessedFiles(_:)))
        autoCleanProcessedFilesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoCleanProcessedFilesCheckbox.toolTip = NSLocalizedString("Once a release has been merged or converted and moved into Ready for Media Library, move the original files it was made from (the separate parts, or the unconverted source) to the Trash so they can be recovered from there, and add their paths to a log file (Cleaned Up Processed Files.txt in Application Support/M3). The finished file is never touched. Leave this off to keep the originals next to the result as a backup in case a merge turns out badly.", comment: "")

        autoRemoveCompletedCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Remove finished items from the Queue automatically", comment: ""),
                                                target: self, action: #selector(toggleAutoRemoveCompleted(_:)))
        autoRemoveCompletedCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoRemoveCompletedCheckbox.toolTip = NSLocalizedString("When a Queue run finishes, the finished rows (the ones with a checkmark) are taken off the list for you. Only the rows go; your files are not touched. Failed rows and rows still waiting for you stay.", comment: "")

        sendEpisodesToTVTabCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Send TV episodes to the TV Shows tab when I add files", comment: ""),
                                                target: self, action: #selector(toggleSendEpisodesToTVTab(_:)))
        sendEpisodesToTVTabCheckbox.translatesAutoresizingMaskIntoConstraints = false
        sendEpisodesToTVTabCheckbox.toolTip = NSLocalizedString("When files are added to the Movies tab with the Add button or by drag and drop, any whose names look like TV episodes (S01E02, 1x02) are put on the TV Shows tab instead. Movies added to the TV Shows tab stay where they are. Files from the Incoming Folders are always sorted this way.", comment: "")

        runQueuesTogetherCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Run the Movies and TV Shows queues at the same time", comment: ""),
                                              target: self, action: #selector(toggleRunQueuesTogether(_:)))
        runQueuesTogetherCheckbox.translatesAutoresizingMaskIntoConstraints = false
        runQueuesTogetherCheckbox.toolTip = NSLocalizedString("Off: the two queues take turns, one file at a time. On: each queue works by itself, so two files can be processed at once.", comment: "")

        let runQueuesTogetherNote = NSTextField(wrappingLabelWithString: NSLocalizedString("By default M3 works on one file at a time across both queues, which is kinder to a single disk. Turn this on only if your files are on fast drives such as SSDs.", comment: ""))
        runQueuesTogetherNote.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        runQueuesTogetherNote.textColor = .secondaryLabelColor
        runQueuesTogetherNote.translatesAutoresizingMaskIntoConstraints = false
        runQueuesTogetherNote.preferredMaxLayoutWidth = 600

        let mainStack = NSStackView(views: [headerLabel, descriptionLabel, intakeSection,
                                             autoWatchCheckbox, autoApproveHighConfidenceCheckbox,
                                             renameAfterMergeCheckbox, autoMergeOnSequenceCheckbox, autoCleanEmptyFoldersCheckbox, autoCleanProcessedFilesCheckbox, autoRemoveCompletedCheckbox,
                                             sendEpisodesToTVTabCheckbox, runQueuesTogetherCheckbox, runQueuesTogetherNote])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.setCustomSpacing(4, after: headerLabel)
        mainStack.setCustomSpacing(16, after: descriptionLabel)
        mainStack.setCustomSpacing(8, after: autoWatchCheckbox)
        mainStack.setCustomSpacing(8, after: autoApproveHighConfidenceCheckbox)
        mainStack.setCustomSpacing(8, after: renameAfterMergeCheckbox)
        mainStack.setCustomSpacing(8, after: autoMergeOnSequenceCheckbox)
        mainStack.setCustomSpacing(8, after: autoCleanEmptyFoldersCheckbox)
        mainStack.setCustomSpacing(8, after: autoCleanProcessedFilesCheckbox)
        mainStack.setCustomSpacing(8, after: autoRemoveCompletedCheckbox)
        mainStack.setCustomSpacing(16, after: sendEpisodesToTVTabCheckbox)
        mainStack.setCustomSpacing(4, after: runQueuesTogetherCheckbox)
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            intakeSection.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor),
            intakeSection.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor)
        ])

        mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20).isActive = true

        refreshFolderLabels()
        autoWatchCheckbox.state = MediaIntakePrefs.autoWatchIntakeFolder ? .on : .off
        autoApproveHighConfidenceCheckbox.state = MediaIntakePrefs.autoApproveHighConfidenceNaming ? .on : .off
        renameAfterMergeCheckbox.state = MediaIntakePrefs.renameSourceFolderAfterMerge ? .on : .off
        autoMergeOnSequenceCheckbox.state = MediaIntakePrefs.autoMergeOnSequence ? .on : .off
        autoCleanEmptyFoldersCheckbox.state = MediaIntakePrefs.autoCleanEmptyFolders ? .on : .off
        autoCleanProcessedFilesCheckbox.state = MediaIntakePrefs.autoCleanProcessedFiles ? .on : .off
        autoRemoveCompletedCheckbox.state = MediaIntakePrefs.autoRemoveCompletedItems ? .on : .off
        runQueuesTogetherCheckbox.state = MediaIntakePrefs.runQueuesTogether ? .on : .off
        sendEpisodesToTVTabCheckbox.state = MediaIntakePrefs.sendEpisodesToTVTab ? .on : .off
    }

    // MARK: - Layout helpers

    /// One "Title" label + editable path field + "Choose…" button row.
    /// The field can be typed (or pasted) into directly -- committed on
    /// Return or when focus leaves it, via controlTextDidEndEditing(_:)
    /// below -- as well as filled in through the button's folder picker,
    /// per the user's request that these fields support either. getValue
    /// supplies the field's initial/refreshed contents; setValue is
    /// called from both the picker and a manual edit, so there's exactly
    /// one place each preference actually gets written.
    private func makeFolderRow(title: String,
                                chooseAction: Selector,
                                getValue: @escaping () -> URL?,
                                setValue: @escaping (URL?) -> Void,
                                field: inout NSTextField!) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let pathField = NSTextField()
        pathField.placeholderString = NSLocalizedString("Not Set", comment: "")
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.delegate = self
        pathField.translatesAutoresizingMaskIntoConstraints = false
        field = pathField
        fieldSetters[ObjectIdentifier(pathField)] = setValue

        let chooseButton = NSButton(title: NSLocalizedString("Choose…", comment: ""), target: self, action: chooseAction)
        chooseButton.bezelStyle = .rounded
        chooseButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(pathField)
        container.addSubview(chooseButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            pathField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            pathField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: chooseButton.leadingAnchor, constant: -8),
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            pathField.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            chooseButton.centerYAnchor.constraint(equalTo: pathField.centerYAnchor),
            chooseButton.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        return container
    }

    /// A bold title above a FolderListView (one or more folders, each
    /// with its own Choose…, remove and add buttons).
    private func makeFolderListSection(title: String, list: FolderListView, accessories: [NSView] = []) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView(views: [titleLabel] + accessories)
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let section = NSStackView(views: [titleRow, list])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        section.translatesAutoresizingMaskIntoConstraints = false

        list.leadingAnchor.constraint(equalTo: section.leadingAnchor).isActive = true
        list.trailingAnchor.constraint(equalTo: section.trailingAnchor).isActive = true
        return section
    }

    @objc private func scanNow(_ sender: NSButton) {
        guard MediaIntakePrefs.intakeFolders.isEmpty == false else {
            scanResultLabel.stringValue = NSLocalizedString("Add an Incoming Folder first.", comment: "")
            return
        }

        scanNowButton.isEnabled = false
        scanResultLabel.stringValue = NSLocalizedString("Scanning\u{2026}", comment: "")

        QueueController.shared.scanIntakeFoldersNow { [weak self] added in
            guard let self = self else { return }
            self.scanNowButton.isEnabled = true
            self.scanResultLabel.stringValue = added == 0
                ? NSLocalizedString("Nothing new found.", comment: "")
                : String.localizedStringWithFormat(NSLocalizedString("Added %lu new item(s).", comment: ""), added)
        }
    }

    @objc private func resetScan(_ sender: NSButton) {
        guard MediaIntakePrefs.intakeFolders.isEmpty == false else {
            scanResultLabel.stringValue = NSLocalizedString("Add an Incoming Folder first.", comment: "")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Reset the scan?", comment: "")
        alert.informativeText = NSLocalizedString("M3 will forget which files it has already taken in from the Incoming Folders, then scan them again. Anything still in an Incoming Folder that is not already in a Queue will be added. Items already in a Queue are not duplicated.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Reset and Scan", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        QueueController.resetIntakeMemory()
        scanNow(sender)
    }

    /// A folder list gained or lost a row: let the shared Sources window
    /// grow or shrink to the tab's new height.
    private func folderListLayoutDidChange() {
        view.layoutSubtreeIfNeeded()
        (parent as? SourcesPrefsViewController)?.contentSizeDidChange()
    }

    private func refreshFolderLabels() {
        readyForLibraryFolderField.stringValue = MediaIntakePrefs.readyForLibraryFolder?.path ?? ""
    }

    // MARK: - Folder pickers

    @objc private func chooseReadyForLibraryFolder(_ sender: Any) {
        presentFolderPicker { [weak self] url in
            guard let self = self else { return }
            MediaIntakePrefs.readyForLibraryFolder = url
            self.refreshFolderLabels()
        }
    }

    private func presentFolderPicker(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                completion(url)
            }
        }
    }

    // MARK: - NSTextFieldDelegate

    /// Commits a manually-typed (or pasted) path when the user presses
    /// Return or clicks/tabs away from one of the folder fields above --
    /// the counterpart to the "Choose…" button's presentFolderPicker
    /// path, so either way of setting a folder ends up calling the same
    /// setValue closure captured for that field in makeFolderRow(...).
    /// An emptied field clears the preference rather than leaving the
    /// previous value in place, matching how clearing any other Subler
    /// preference field works.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let setValue = fieldSetters[ObjectIdentifier(field)] else { return }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            setValue(nil)
        } else {
            setValue(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath))
        }
        refreshFolderLabels()
    }

    // MARK: - Auto watch toggle

    @objc private func toggleAutoWatch(_ sender: NSButton) {
        MediaIntakePrefs.autoWatchIntakeFolder = sender.state == .on
    }

    // MARK: - Auto-approve high-confidence naming toggle

    @objc private func toggleAutoApproveHighConfidenceNaming(_ sender: NSButton) {
        MediaIntakePrefs.autoApproveHighConfidenceNaming = sender.state == .on
    }

    // MARK: - Rename after merge toggle

    @objc private func toggleRenameAfterMerge(_ sender: NSButton) {
        MediaIntakePrefs.renameSourceFolderAfterMerge = sender.state == .on
    }

    // MARK: - Auto-merge-on-sequence toggle

    @objc private func toggleAutoMergeOnSequence(_ sender: NSButton) {
        MediaIntakePrefs.autoMergeOnSequence = sender.state == .on
    }

    // MARK: - Remove empty folders toggle

    @objc private func toggleAutoCleanEmptyFolders(_ sender: NSButton) {
        MediaIntakePrefs.autoCleanEmptyFolders = sender.state == .on
    }

    // MARK: - Clean up processed files toggle

    @objc private func toggleAutoCleanProcessedFiles(_ sender: NSButton) {
        MediaIntakePrefs.autoCleanProcessedFiles = sender.state == .on
    }

    @objc private func toggleAutoRemoveCompleted(_ sender: NSButton) {
        MediaIntakePrefs.autoRemoveCompletedItems = sender.state == .on
    }

    @objc private func toggleSendEpisodesToTVTab(_ sender: NSButton) {
        MediaIntakePrefs.sendEpisodesToTVTab = sender.state == .on
    }

    @objc private func toggleRunQueuesTogether(_ sender: NSButton) {
        MediaIntakePrefs.runQueuesTogether = sender.state == .on
    }
}


// MARK: - FolderListView

/// An editable list of folder paths, one per row: [path field] [Choose…]
/// [−] [+]. The + inserts a blank row right below its own; the − removes
/// the row (or just clears it when it's the only one). Every change --
/// typing a path and pressing Return / clicking away, picking a folder, adding
/// or removing a row -- reports the full list of non-empty, de-duplicated
/// folders through onChange, so the owner has exactly one place to save.
final class FolderListView: NSStackView, NSTextFieldDelegate {

    /// Called with every non-empty folder in the list, in row order.
    var onChange: (([URL]) -> Void)?
    /// Called after a row is added or removed, so the window can resize.
    var onLayoutChange: (() -> Void)?
    /// Greyed-out text of the first row while it's empty.
    var placeholder: String = NSLocalizedString("Not Set", comment: "")
    var maximumRows = 10
    /// When true the list always keeps one row, so the minus button is disabled while only one row is left
    /// (the row can still be edited with Choose or by typing).
    var alwaysKeepsOneRow = false
    /// A folder the app follows on its own while the first row is blank (for
    /// example the Automatically Add folder the Apple TV app's settings
    /// point to). When set, plus works on that blank first row, and the row
    /// stays blank so the default keeps following the app's setting.
    var implicitDefault: URL?
    /// Called with whether the first row is blank, each time the list changes.
    var onFirstRowBlankChange: ((Bool) -> Void)?

    private final class Row {
        let stack: NSStackView
        let field: NSTextField
        let choose: NSButton
        let remove: NSButton
        let add: NSButton

        init(stack: NSStackView, field: NSTextField, choose: NSButton, remove: NSButton, add: NSButton) {
            self.stack = stack
            self.field = field
            self.choose = choose
            self.remove = remove
            self.add = add
        }
    }

    private var rows: [Row] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replaces the list's rows with one per folder (or a single blank
    /// row when there are none). Doesn't call onChange.
    func setFolders(_ urls: [URL], leadingBlankRow: Bool = false) {
        for row in rows {
            removeArrangedSubview(row.stack)
            row.stack.removeFromSuperview()
        }
        rows.removeAll()

        var paths = urls.isEmpty ? [""] : urls.map { $0.path }
        if leadingBlankRow && urls.isEmpty == false { paths.insert("", at: 0) }
        for path in paths {
            let row = makeRow(path: path)
            rows.append(row)
            addArrangedSubview(row.stack)
            pin(row)
        }
        updateButtons()
    }

    // MARK: Rows

    private func makeRow(path: String) -> Row {
        let field = NSTextField()
        field.stringValue = path
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        field.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let choose = NSButton(title: NSLocalizedString("Choose\u{2026}", comment: ""), target: self, action: #selector(chooseClicked(_:)))
        choose.bezelStyle = .rounded
        choose.translatesAutoresizingMaskIntoConstraints = false

        let remove = NSButton(title: "\u{2212}", target: self, action: #selector(removeClicked(_:)))
        remove.bezelStyle = .rounded
        remove.toolTip = NSLocalizedString("Remove this folder", comment: "")
        remove.setAccessibilityLabel(NSLocalizedString("Remove this folder", comment: ""))
        remove.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: "+", target: self, action: #selector(addClicked(_:)))
        add.bezelStyle = .rounded
        add.toolTip = NSLocalizedString("Add another folder", comment: "")
        add.setAccessibilityLabel(NSLocalizedString("Add another folder", comment: ""))
        add.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [field, choose, remove, add])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        return Row(stack: stack, field: field, choose: choose, remove: remove, add: add)
    }

    /// Stretches a row across the list's full width; call once the row
    /// has been added to this stack.
    private func pin(_ row: Row) {
        NSLayoutConstraint.activate([
            row.stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            row.remove.widthAnchor.constraint(equalToConstant: 34),
            row.add.widthAnchor.constraint(equalToConstant: 34)
        ])
    }

    /// "+" only makes sense once the row has a folder (otherwise blank
    /// rows pile up); "−" is pointless on a lone, already-blank row.
    private func updateButtons() {
        for (index, row) in rows.enumerated() {
            let isBlank = row.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let otherBlankRowExists = rows.enumerated().contains { $0.offset != index && $0.element.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let blankButUsesDefault = isBlank && index == 0 && implicitDefault != nil && otherBlankRowExists == false
            row.add.isEnabled = (isBlank == false || blankButUsesDefault) && rows.count < maximumRows
            row.remove.isEnabled = alwaysKeepsOneRow ? rows.count > 1 : !(rows.count == 1 && isBlank)
            row.field.placeholderString = index == 0
                ? placeholder
                : NSLocalizedString("Choose or type a folder path", comment: "")
        }
    }

    private func commit() {
        var seen = Set<String>()
        var urls: [URL] = []
        for row in rows {
            let trimmed = row.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL
            if seen.insert(url.path).inserted {
                urls.append(url)
            }
        }
        onFirstRowBlankChange?(rows.first?.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
        onChange?(urls)
    }

    // MARK: Actions

    @objc private func addClicked(_ sender: NSButton) {
        guard rows.count < maximumRows,
              let index = rows.firstIndex(where: { $0.add === sender }) else { return }

        let row = makeRow(path: "")
        rows.insert(row, at: index + 1)
        insertArrangedSubview(row.stack, at: index + 1)
        pin(row)
        updateButtons()
        onLayoutChange?()
        window?.makeFirstResponder(row.field)
    }

    @objc private func removeClicked(_ sender: NSButton) {
        guard let index = rows.firstIndex(where: { $0.remove === sender }) else { return }

        if rows.count == 1 {
            rows[0].field.stringValue = ""
        } else {
            let row = rows.remove(at: index)
            removeArrangedSubview(row.stack)
            row.stack.removeFromSuperview()
        }
        updateButtons()
        commit()
        onLayoutChange?()
    }

    @objc private func chooseClicked(_ sender: NSButton) {
        guard let row = rows.first(where: { $0.choose === sender }) else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            row.field.stringValue = url.path
            self.updateButtons()
            self.commit()
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateButtons()
    }

    /// Return, or clicking/tabbing away, commits a typed or pasted path.
    func controlTextDidEndEditing(_ obj: Notification) {
        updateButtons()
        commit()
    }
}
