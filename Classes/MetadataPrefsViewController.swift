//
//  MetadataPrefsViewController.swift
//  Subler
//
//  Created by Damiano Galassi on 10/08/2017.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Overwrite/Append existing metadata options, Fill Series Description moved
//  to this tab, Providers text, editor for the genres you have typed.
//

import Cocoa
import MP42Foundation

class MetadataPrefsViewController : NSViewController, NSTableViewDelegate, NSTableViewDataSource, TokenChangeObserver {

    @IBOutlet var builtInTokenField: NSTokenField!
    @IBOutlet var addMetadataPopUpButton: NSPopUpButton!
    @IBOutlet var removeMetadataButton: NSButton!

    @IBOutlet var tableView: NSTableView!

    // "Overwrite existing metadata" and "Append to existing metadata" are
    // presented as mutually exclusive, radio-button-style checkboxes even
    // though they're backed by two independent preferences (each still has
    // its own Cocoa binding to UserDefaults in the xib) -- checking one here
    // just also unchecks the other, rather than the two being wired as an
    // actual NSMatrix/radio group.
    @IBOutlet var overwriteButton: NSButton!
    @IBOutlet var appendButton: NSButton!

    @IBOutlet var typesController: NSArrayController!
    @objc var types: [String]

    var movieMap: MetadataResultMap
    var tvShowMap: MetadataResultMap

    var map: MetadataResultMap

    var currentTokens: [String]

    var selectionObserver: NSKeyValueObservation?
    let sort: (MetadataResultMapItem, MetadataResultMapItem) -> Bool

    let tokenDelegate: TokenDelegate
    let tableTokenDelegate: TokenDelegate

    override var nibName: NSNib.Name? {
        return "MetadataPrefsViewController"
    }

    init() {
        self.types = [NSLocalizedString("Movie", comment: ""), NSLocalizedString("TV Show", comment: "")]

        // Load data from preferences
        self.movieMap = MetadataPrefs.movieResultMap
        self.tvShowMap = MetadataPrefs.tvShowResultMap
        self.map = movieMap
        self.currentTokens = []

        let context = MP42Metadata.availableMetadata
        self.sort = { (obj1: MetadataResultMapItem ,obj2: MetadataResultMapItem) -> Bool in
            if let right = context.firstIndex(of: obj1.key),
                let left = context.firstIndex(of: obj2.key) {
                return right > left ? false : true
            }
            return false
        }

        self.tokenDelegate = TokenDelegate(displayMenu: false, displayString: { MetadataResult.Key.localizedDisplayName(key: $0.text) })
        self.tableTokenDelegate = TokenDelegate(displayMenu: true, displayString: { MetadataResult.Key.localizedDisplayName(key: $0.text) })

        super.init(nibName: nil, bundle: nil)

        self.title = NSLocalizedString("Metadata", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tokenDelegate.delegate = self
        tableTokenDelegate.delegate = self

        builtInTokenField.tokenizingCharacterSet = CharacterSet(charactersIn: "/")
        builtInTokenField.delegate = tokenDelegate

        if let menu = addMetadataPopUpButton.menu {
            for (index, key) in MP42Metadata.writableMetadata.enumerated() {
                let item = NSMenuItem(title: localizedMetadataKeyName(key), action: nil, keyEquivalent: "")
                item.tag = index
                item.representedObject = key
                menu.addItem(item)
            }
        }

        selectionObserver = typesController.observe(\.selectionIndex, options: [.initial, .new]) { [weak self] observed, change in
            guard let s = self else { return }
            if observed.selectionIndex > 0 {
                s.currentTokens = MetadataResult.Key.tvShowKeysStrings
                s.map = s.tvShowMap
            }
            else {
                s.currentTokens = MetadataResult.Key.movieKeysStrings
                s.map = s.movieMap
            }
            s.map.items.sort(by: s.sort)
            s.tableView.reloadData()
            s.builtInTokenField.stringValue = s.currentTokens.reduce("", { "\($0)/\($1)" })

            s.updateControlsState()
        }

        updateControlsState()

        buildFillSeriesDescriptionCheckbox()
    }

    // Fills Series Description from a detected sequel/part indicator on
    // the Title or filename (see
    // Document.fillSeriesDescriptionIfNeeded(originalFileURL:) and
    // SeriesTitleDetector.baseSeriesTitle(from:)) -- e.g. a Title of
    // "John Wick 2" sets Series Description to "John Wick". Off by default
    // (Prefs.swift): it's a heuristic that can mistake a title like
    // "Ocean's 11" for a sequel number, and it always overwrites whatever
    // Series Description already says.
    //
    // This view controller is xib-based (unlike the programmatic
    // Output/Sources prefs panes), so rather than hand-editing the xib's
    // Auto Layout chain, this checkbox is appended in code: it unpins
    // appendButton from the view's bottom and takes that spot itself,
    // right below the existing overwrite/append checkboxes.
    private func buildFillSeriesDescriptionCheckbox() {
        if let bottomConstraint = view.constraints.first(where: { constraint in
            constraint.firstItem === view && constraint.firstAttribute == .bottom &&
            constraint.secondItem === appendButton && constraint.secondAttribute == .bottom
        }) {
            bottomConstraint.isActive = false
        }

        let checkbox = NSButton(checkboxWithTitle: NSLocalizedString("Fill Series Description for sequels/parts", comment: "Metadata prefs checkbox"),
                                 target: self, action: #selector(toggleFillSeriesDescription(_:)))
        checkbox.state = Prefs.fillSeriesDescriptionOnSave ? .on : .off
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.toolTip = NSLocalizedString("When the title ends in a number or \u{201c}Part/Chapter \u{2026}\u{201d} (e.g. \u{201c}John Wick 2\u{201d}), sets Series Description to the title with that removed (\u{201c}John Wick\u{201d}). Always overwrites Series Description, and can't tell a real sequel number from one that's just part of a title (\u{201c}Ocean's 11\u{201d}).", comment: "")
        view.addSubview(checkbox)

        // Opens the editor for the genres typed into the Genre box.
        let genresButton = NSButton(title: NSLocalizedString("Edit My Genres\u{2026}", comment: "Metadata prefs button"),
                                    target: self, action: #selector(editGenres(_:)))
        genresButton.bezelStyle = .rounded
        genresButton.translatesAutoresizingMaskIntoConstraints = false
        genresButton.toolTip = NSLocalizedString("Correct or remove the genres you have typed into the Genre box. They are kept so they show up in its list.", comment: "Metadata prefs button tooltip")
        view.addSubview(genresButton)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: appendButton.leadingAnchor),
            checkbox.topAnchor.constraint(equalTo: appendButton.bottomAnchor, constant: 8),
            view.trailingAnchor.constraint(greaterThanOrEqualTo: checkbox.trailingAnchor, constant: 20),
            genresButton.leadingAnchor.constraint(equalTo: appendButton.leadingAnchor),
            genresButton.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 10),
            view.bottomAnchor.constraint(equalTo: genresButton.bottomAnchor, constant: 20)
        ])
    }

    private var genreEditor: GenreEditorWindowController?

    @objc private func editGenres(_ sender: Any?) {
        guard let parent = view.window else { return }
        let editor = GenreEditorWindowController()
        guard let sheet = editor.window else { return }
        genreEditor = editor
        parent.beginSheet(sheet) { [weak self] _ in
            self?.genreEditor = nil
        }
    }

    private func updateControlsState() {
        removeMetadataButton.isEnabled = tableView.selectedRow != -1
    }

    private func save() {
        MetadataPrefs.movieResultMap = movieMap
        MetadataPrefs.tvShowResultMap = tvShowMap
    }

    @IBAction func addMetadataItem(_ sender: NSPopUpButton) {
        if let key = sender.selectedItem?.representedObject as? String {
            let item = MetadataResultMapItem(key: key)
            map.items.append(item)
            map.items.sort(by: sort)
            if let index = map.items.firstIndex(where: { $0 === item }) {
                tableView.insertRows(at: IndexSet(integer: index), withAnimation: .slideUp)
            }
            save()
        }
    }

    @IBAction func removeMetadata(_ sender: Any) {
        for index in tableView.selectedRowIndexes.reversed() {
            map.items.remove(at: index)
        }
        tableView.removeRows(at: tableView.selectedRowIndexes, withAnimation: .slideDown)
        save()
    }

    @objc private func toggleFillSeriesDescription(_ sender: NSButton) {
        Prefs.fillSeriesDescriptionOnSave = sender.state == .on
    }

    @IBAction func overwriteOrAppendChanged(_ sender: NSButton) {
        // Each button's own Cocoa binding has already pushed sender's new
        // state to its UserDefaults key by the time this fires -- this only
        // handles clearing the *other* checkbox so the two behave like a
        // radio-button pair instead of two independent toggles.
        //
        // This used to do that by setting the other button's .state
        // directly, on the theory that doing so "goes back through that
        // button's own binding too" -- it doesn't. Cocoa Bindings only
        // pushes a button's displayed state to its bound UserDefaults key
        // when the button itself sends an action from a real click (or
        // -performClick:); assigning .state in code changes what's drawn
        // on screen without ever touching the bound preference. So after
        // checking "Append", "Overwrite existing metadata" could keep
        // reading true underneath a checkbox that now *looked* unchecked
        // -- applySet(_:)/QueueSetAction's "only skip Overwrite's wipe
        // when the preference is really off" check saw the stale true and
        // wiped metadata anyway, even with Append selected on screen.
        //
        // Writing the other preference's stored value directly fixes both
        // halves at once: the preference itself is now actually correct,
        // and NSUserDefaultsController's own binding reflects the change
        // back into that checkbox automatically, same as if the user had
        // unchecked it by hand.
        guard sender.state == .on else { return }
        if sender === overwriteButton {
            MetadataPrefs.appendExistingAnnotations = false
        } else if sender === appendButton {
            MetadataPrefs.overwriteExistingAnnotations = false
        }
    }

    @IBAction func restoreDefaults(_ sender: Any) {
        if typesController.selectionIndex > 0 {
            tvShowMap = MetadataResultMap.tvShowDefaultMap;
            map = tvShowMap;
        }
        else {
            movieMap = MetadataResultMap.movieDefaultMap;
            map = movieMap;
        }
        map.items.sort(by: sort)
        tableView.reloadData()
        save()
    }

    // MARK: Table View

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControlsState()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == self.tableView {
            return map.items.count
        } else {
            return 0
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == self.tableView {

            let item = map.items[row]

            if tableColumn?.identifier == NSUserInterfaceItemIdentifier("annotation"),
                let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("annotation"), owner: self) as? NSTableCellView {
                cell.textField?.stringValue = item.localizedKeyDisplayName
                return cell
            }
            else if tableColumn?.identifier == NSUserInterfaceItemIdentifier("value"),
                let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("value"), owner: self) as? TokenCellView {
                cell.tokenView.delegate = tableTokenDelegate
                cell.tokenView.tokenizingCharacterSet = CharacterSet(charactersIn: "/")
                cell.tokenView.objectValue = item.value
                return cell
            }
        }

        return nil
    }

    // MARK: Format Token Field Delegate

    func tokenDidChange(_ obj: Notification?) {
        if let tokenField = obj?.object as? NSTokenField {
            let row = tableView.row(for: tokenField)

            if row != -1, let tokens = tokenField.objectValue as? [Token] {
                map.items[row].value = tokens
            }
        }

        save()
    }

}

/// A small sheet to correct or remove the genres typed into the Genre box
/// (see GenreList). Double-click a genre to change its spelling.
final class GenreEditorWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private var genres: [String]
    private let tableView = NSTableView()
    private var removeButton: NSButton!
    private var hintLabel: NSTextField!

    init() {
        genres = GenreList.custom()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = NSLocalizedString("My Genres", comment: "Genre editor -> title")
        super.init(window: window)

        let intro = NSTextField(wrappingLabelWithString: NSLocalizedString("These are the genres you typed into the Genre box. Double-click one to correct it, or remove it. The standard genres cannot be changed here.", comment: "Genre editor -> description"))
        intro.translatesAutoresizingMaskIntoConstraints = false
        intro.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        intro.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("genre"))
        column.title = NSLocalizedString("Genre", comment: "Genre editor -> column")
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        hintLabel = NSTextField(labelWithString: NSLocalizedString("No genres of your own yet.", comment: "Genre editor -> empty list"))
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.textColor = .tertiaryLabelColor

        let addButton = NSButton(title: "+", target: self, action: #selector(add(_:)))
        addButton.bezelStyle = .smallSquare
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.toolTip = NSLocalizedString("Add a genre", comment: "Genre editor -> tooltip")
        removeButton = NSButton(title: "\u{2212}", target: self, action: #selector(remove(_:)))
        removeButton.bezelStyle = .smallSquare
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.toolTip = NSLocalizedString("Remove the selected genre", comment: "Genre editor -> tooltip")

        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        let doneButton = NSButton(title: NSLocalizedString("Done", comment: ""), target: self, action: #selector(done(_:)))
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        [intro, scroll, hintLabel, addButton, removeButton, cancelButton, doneButton].forEach { content.addSubview($0) }
        window.contentView = content

        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -6),

            hintLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            addButton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 4),
            removeButton.widthAnchor.constraint(equalToConstant: 28),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -56),
            removeButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),

            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            doneButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor)
        ])

        updateControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateControls() {
        removeButton.isEnabled = tableView.selectedRow != -1
        hintLabel.isHidden = genres.isEmpty == false
    }

    // MARK: Actions

    @objc private func add(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        genres.append(NSLocalizedString("New Genre", comment: "Genre editor -> new row"))
        tableView.reloadData()
        let row = genres.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.editColumn(0, row: row, with: nil, select: true)
        updateControls()
    }

    @objc private func remove(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        let rows = tableView.selectedRowIndexes
        for row in rows.reversed() where genres.indices.contains(row) { genres.remove(at: row) }
        tableView.reloadData()
        updateControls()
    }

    @objc private func cancel(_ sender: Any?) {
        end(with: .cancel)
    }

    @objc private func done(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        GenreList.setCustom(genres)
        end(with: .OK)
    }

    private func end(with response: NSApplication.ModalResponse) {
        guard let window = window else { return }
        window.sheetParent?.endSheet(window, returnCode: response)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        return genres.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("genreCell")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
            let field = NSTextField()
            field.identifier = identifier
            field.isBordered = false
            field.drawsBackground = false
            field.isEditable = true
            field.delegate = self
            return field
        }()
        field.stringValue = genres[row]
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        guard genres.indices.contains(row) else { return }
        genres[row] = field.stringValue
    }
}
