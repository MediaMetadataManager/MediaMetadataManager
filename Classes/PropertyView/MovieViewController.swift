//
//  MovieViewController.swift
//  Subler
//
//  Created by Damiano Galassi on 11/03/2019.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Usability fixes, plugin-declared settings, a full Genre list that also
//  remembers genres you type. Includes later upstream undo/redo changes
//  ported by hand.
//

import Cocoa
import UniformTypeIdentifiers
import MP42Foundation

extension NSPasteboard.PasteboardType {
    static let metadataDragType = NSPasteboard.PasteboardType("org.subler.metadatadragdrop")
    static let artworkDragType = NSPasteboard.PasteboardType("org.subler.artworkdragdrop")
}

class MovieViewController: PropertyView, NSTableViewDataSource, ExpandedTableViewDelegate, NSCollectionViewDataSource, CollectionViewDelegate, NSDraggingDestination, NSFilePromiseProviderDelegate {

    var metadata: MP42Metadata {
        didSet {
            let metadataIndexes = self.metadataTableView.selectedRowIndexes
//            let artworkIndexes = self.artworksView.selectionIndexPaths;
            reloadData()
            if let last = metadataIndexes.last, last < tags.count {
                self.metadataTableView.selectRowIndexes(metadataIndexes, byExtendingSelection: false)
            }
//            self.artworksView.selectItems(at: artworkIndexes, scrollPosition: .top)
        }
    }

    private var file: MP42File?

    // Metadata tab
    private var tags: [MP42MetadataItem]

    private let ratings: [String]
    private let codes: [String]

    private lazy var dummyCell: NSTableCellView = {
        return self.metadataTableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "TextCellForSizing"), owner: self) as! NSTableCellView
    }()
    private lazy var dummyCellWidth: NSLayoutConstraint = {
        let constraint = NSLayoutConstraint.init(item: self.dummyCell, attribute: NSLayoutConstraint.Attribute.width, relatedBy: NSLayoutConstraint.Relation.equal, toItem: nil, attribute: NSLayoutConstraint.Attribute.notAnAttribute, multiplier: 1, constant: 500)
        self.dummyCell.addConstraint(constraint)
        return constraint
    }()
    private lazy var column: NSTableColumn = {
        return self.metadataTableView.tableColumns[1]
    }()
    private var columnWidth: CGFloat
    private var previousColumnWidth: CGFloat
    private var rowHeights: Dictionary<String, CGFloat>

    /// Identifiers flagged by the last Search Metadata merge as newly
    /// added or overwritten -- see highlightChangedFields(_:), called
    /// from DocumentWindowController.didSelect(metadata:) right after a
    /// merge. Cleared on any wholesale reload (reloadData(), i.e. a plain
    /// file switch rather than a merge) and, per field, the moment the
    /// user edits that field themselves (replace(metadataItem:withItem:)).
    private var recentlyChangedIdentifiers: Set<String> = []

    @IBOutlet var tagsPopUp: NSPopUpButton!
    @IBOutlet var setsPopUp: NSPopUpButton!

    @IBOutlet var removeTagButton: NSButton!
    @IBOutlet var metadataTableView: ExpandedTableView!

    // Set save window
    @IBOutlet var saveSetWindow: NSWindow!
    @IBOutlet var saveSetName: NSTextField!
    @IBOutlet var keepArtworks: NSButton!
    @IBOutlet var keepAnnotations: NSButton!

    // Artwork tab
    private var artworks: [MP42MetadataItem]
    private let standardSize = NSSize(width: 280, height: 224)

    @IBOutlet var removeArtworkButton: NSButton!
    @IBOutlet var zoomSlider: NSSlider!
    @IBOutlet var artworksView: CollectionView!

    override var nibName: NSNib.Name? {
        return "MovieView"
    }

    init(mp4: MP42File?, metadata: MP42Metadata) {
        self.file = mp4
        self.metadata = metadata
        self.tags = []
        self.artworks = []

        let selectedCountry = Prefs.ratingsCountry
        let countries = selectedCountry == "All countries" ?
            Ratings.shared.countries :
            Ratings.shared.countries.filter { $0.displayName == selectedCountry || $0.displayName == "USA" }
        self.ratings = countries.flatMap { country in country.ratings
            .map { "\(country.displayName) \($0.media): \($0.displayName)" } }
        self.codes = countries.flatMap { $0.ratings.map { $0.iTunesCode } }

        self.columnWidth = 0
        self.previousColumnWidth = 0
        self.rowHeights = Dictionary()

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        artworksView.delegate = nil
        artworksView.dataSource = nil
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        updateSetsMenu(self)

        NotificationCenter.default.addObserver(self, selector: #selector(updateSetsMenu(_:)), name: PresetManager.updateNotification, object: nil)

        if let menu = tagsPopUp.menu {
            let identifiersMenu = MP42Metadata.writableMetadata
            for (index, identifier) in identifiersMenu.enumerated() {
                let item = NSMenuItem(title: localizedMetadataKeyName(identifier), action: nil, keyEquivalent: "")
                item.tag = index
                menu.addItem(item)
            }
        }

        if #available(macOS 26, *) {
            setsPopUp.menu?.items.first?.image = NSImage.init(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        }

        columnWidth = column.width

        metadataTableView.defaultEditingColumn = 1
        metadataTableView.doubleAction = #selector(doubleClickAction(_:))
        metadataTableView.target = self
        metadataTableView.pasteboardTypes = [.metadataDragType]
        metadataTableView.scrollRowToVisible(0)

        artworksView.register(ArtworkSelectorViewItem.self, forItemWithIdentifier: ArtworkSelectorController.itemView)
        artworksView.registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0)})
        artworksView.registerForDraggedTypes([.fileURL, .artworkDragType])
        artworksView.pasteboardTypes = [.fileURL, .tiff, .MP42PasteboardTypeArtwork]

        // Determine the kind of source drag originating from this app.
        // Note, if you want to allow your app to drag items to the Finder's trash can, add ".delete".
        artworksView.setDraggingSourceOperationMask([.copy, .delete], forLocal: false)

        reloadData()
    }

    override func viewWillAppear() {
        let zoomValue = zoomLevel
        setZoomValue(zoomValue)
        zoomSlider.floatValue = zoomValue
    }

    private func reloadData() {
        rowHeights.removeAll(keepingCapacity: true)
        recentlyChangedIdentifiers.removeAll()
        updateMetadataArray()
        metadataTableView.reloadData()
        updateArtworksArray()
        artworksView.reloadData()
        updateUI()
    }

    private func updateUI() {
        removeTagButton.isEnabled = self.metadataTableView.selectedRow != -1
    }

    /// Flags `identifiers` as just-changed so their rows get a visual
    /// marker in the metadata table -- called right after a Search
    /// Metadata result has been merged in, so it's obvious at a glance
    /// which fields the search actually touched versus what was already
    /// there. Cleared automatically on the next wholesale reload, or per
    /// field as soon as the user edits it.
    func highlightChangedFields(_ identifiers: Set<String>) {
        recentlyChangedIdentifiers = identifiers
        metadataTableView.reloadData()
    }

    // MARK: Metadata

    private func updateMetadataArray() {

        let dataTypes: UInt = MP42MetadataItemDataType.string.rawValue | MP42MetadataItemDataType.stringArray.rawValue | MP42MetadataItemDataType.bool.rawValue | MP42MetadataItemDataType.integer.rawValue | MP42MetadataItemDataType.integerArray.rawValue | MP42MetadataItemDataType.date.rawValue

        tags = metadata.metadataItemsFiltered(by: MP42MetadataItemDataType(rawValue: dataTypes))

        let context = MP42Metadata.availableMetadata

        tags.sort { (obj1, obj2) -> Bool in
            if let right = context.firstIndex(of: obj1.identifier),
                let left = context.firstIndex(of: obj2.identifier) {
                return right < left ? true : false
            } else {
                return false
            }
        }
    }

    // Document dirtiness and undo for tag edits flow through MP42File.undo
    // (set to the document's undo manager by Document), so this controller no
    // longer registers undo or calls updateChangeCount itself.

    private func add(metadataItems items: [MP42MetadataItem]) {
        for item in items {
            metadata.addItem(item)
            rowHeights[item.identifier] = nil
        }
        updateMetadataArray()
        metadataTableView.reloadData()
    }

    private func remove(metadataItems items: [MP42MetadataItem]) {
        for item in items {
            metadata.removeItem(item)
        }
        updateMetadataArray()
        let index = metadataTableView.selectedRowIndexes.first ?? 0
        metadataTableView.reloadData()
        if index < tags.count {
            metadataTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateUI()
    }

    private func replace(metadataItem item: MP42MetadataItem, withItem newItem: MP42MetadataItem) {
        // Deliberately NOT clearing item.identifier from
        // recentlyChangedIdentifiers here: a field a Set or search merge
        // flagged should stay highlighted through the user filling it in,
        // not go grey the moment they finish typing -- it's meant to mark
        // "touched since the last save", not "touched since the last
        // keystroke". reloadData() (called when a fresh MovieViewController
        // is built from newly-saved/newly-opened metadata) is what
        // actually clears it.

        metadata.removeItem(item)
        metadata.addItem(newItem)

        updateMetadataArray()

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0

        if let index = tags.firstIndex(of: newItem) {
            let indexSet = IndexSet(integer: index)
            // Both columns: value (1) because that's what changed, and
            // key (0) too since it carries the highlight styling.
            let colIndexSet = IndexSet(integersIn: 0...1)

            rowHeights[newItem.identifier] = nil
            metadataTableView.reloadData(forRowIndexes: indexSet, columnIndexes: colIndexSet)
            metadataTableView.noteHeightOfRows(withIndexesChanged: indexSet)
        }

        NSAnimationContext.endGrouping()
    }

    @IBAction func addTag(_ sender: Any?) {
        // End editing
        view.window?.makeFirstResponder(metadataTableView)

        guard let sender = sender as? NSPopUpButton else { return }

        let identifier = MP42Metadata.writableMetadata[sender.selectedTag()]

        if metadata.metadataItemsFiltered(byIdentifier: identifier).isEmpty {

            if identifier == MP42MetadataKeyHDVideo, let hdType = file?.hdType {
                let item = MP42MetadataItem(identifier: identifier, value: hdType.rawValue as NSCopying & NSObjectProtocol, dataType: MP42MetadataItemDataType.integer, extendedLanguageTag: nil)
                add(metadataItems: [item])
            } else {
                let item = MP42MetadataItem(identifier: identifier, value: "" as NSCopying & NSObjectProtocol, dataType: MP42MetadataItemDataType.unspecified, extendedLanguageTag: nil)
                add(metadataItems: [item])
            }
        }

        if let item = metadata.metadataItemsFiltered(byIdentifier: identifier).first,
            let index = tags.firstIndex(of: item) {
            metadataTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            metadataTableView.scrollRowToVisible(index)
        }
    }

    @IBAction func removeTag(_ sender: Any?) {
        // End editing
        view.window?.makeFirstResponder(metadataTableView)

        let items = metadataTableView.selectedRowIndexes.compactMap { tags[$0] }
        remove(metadataItems: items)
    }

    // MARK: Built-In presets

    private var allSet: [String] {
        get {
            return MP42Metadata.writableMetadata
        }
    }

    private var tvShowSet: [String] {
        get {
            return [MP42MetadataKeyName, MP42MetadataKeyArtist, MP42MetadataKeyAlbum, MP42MetadataKeyReleaseDate, MP42MetadataKeyTrackNumber, MP42MetadataKeyDiscNumber, MP42MetadataKeyTVShow, MP42MetadataKeyTVEpisodeNumber, MP42MetadataKeyTVNetwork, MP42MetadataKeyTVEpisodeID, MP42MetadataKeyTVSeason, MP42MetadataKeyUserGenre, MP42MetadataKeyDescription, MP42MetadataKeyLongDescription]
        }
    }

    private var movieSet: [String] {
        get {
            return [MP42MetadataKeyName, MP42MetadataKeyArtist, MP42MetadataKeyAlbum, MP42MetadataKeyUserGenre, MP42MetadataKeyReleaseDate, MP42MetadataKeyTrackNumber, MP42MetadataKeyDiscNumber, MP42MetadataKeyCast, MP42MetadataKeyDirector, MP42MetadataKeyScreenwriters, MP42MetadataKeyUserGenre, MP42MetadataKeyDescription, MP42MetadataKeyLongDescription, MP42MetadataKeyRating, MP42MetadataKeyCopyright]
        }
    }

    // MARK: Sets management

    @IBAction func addMetadataSet(_ sender: NSMenuItem) {
        var itemsToBeAdded: [MP42MetadataItem] = []
        var identifiers: Set<String> = Set()

        switch sender.tag {
        case 0:
            identifiers = Set(allSet)
        case 1:
            identifiers = Set(movieSet)
            let mediaKind = MP42MetadataItem(identifier: MP42MetadataKeyMediaKind, value: 9 as NSCopying & NSObjectProtocol, dataType: .integer, extendedLanguageTag: nil)
            itemsToBeAdded.append(mediaKind)
        case 2:
            identifiers = Set(tvShowSet)
            let mediaKind = MP42MetadataItem(identifier: MP42MetadataKeyMediaKind, value: 10 as NSCopying & NSObjectProtocol, dataType: .integer, extendedLanguageTag: nil)
            itemsToBeAdded.append(mediaKind)
        default:
            break
        }

        let existingIdentifiers = Set(tags.map { $0.identifier} )
        identifiers.subtract(existingIdentifiers)

        itemsToBeAdded.append(contentsOf: identifiers.map { MP42MetadataItem(identifier: $0, value: "" as NSCopying & NSObjectProtocol, dataType: .unspecified, extendedLanguageTag: nil)} )

        add(metadataItems: itemsToBeAdded)
        // Flag every field the Set just added -- filled-in or still
        // blank -- the same way a metadata search merge does, so it's
        // obvious at a glance what this Set actually touched.
        highlightChangedFields(Set(itemsToBeAdded.map { $0.identifier }))
    }

    @IBAction func updateSetsMenu(_ sender: Any) {
        guard let menu = setsPopUp?.menu else { return }

        while menu.numberOfItems > 1 {
            menu.removeItem(at: 1)
        }

        let saveSetItem = NSMenuItem(title: NSLocalizedString("Save Set…", comment: "Set menu"), action: #selector(showSaveSet(_:)), keyEquivalent: "")
        saveSetItem.target = self
        menu.addItem(saveSetItem)

        let allSetItem = NSMenuItem(title: NSLocalizedString("All", comment: "Set menu All set"), action: #selector(addMetadataSet(_:)), keyEquivalent: "")
        allSetItem.target = self
        allSetItem.tag = 0
        menu.addItem(allSetItem)

        let movieSetItem = NSMenuItem(title: NSLocalizedString("Movie", comment: "Set menu Movie set"), action: #selector(addMetadataSet(_:)), keyEquivalent: "")
        movieSetItem.target = self
        movieSetItem.tag = 1
        menu.addItem(movieSetItem)

        let tvSetItem = NSMenuItem(title: NSLocalizedString("TV Show", comment: "Set menu TV Show Set"), action: #selector(addMetadataSet(_:)), keyEquivalent: "")
        tvSetItem.target = self
        tvSetItem.tag = 2
        menu.addItem(tvSetItem)

        let presets = PresetManager.shared.metadataPresets

        if presets.isEmpty == false {
            menu.addItem(NSMenuItem.separator())
        }

        for (index, preset) in presets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(applySet(_:)), keyEquivalent: "")
            if index < 9 {
                item.keyEquivalent = "\(index + 1)"
            }
            item.target = self
            item.tag = index

            menu.addItem(item)
        }
    }

    /// True for an item with no real value -- an empty string/array, an
    /// Integer or Bool field still sitting at its zero/false default, or
    /// no value at all. A field that's merely blank/default is fair game
    /// to fill in even with Preferences > Metadata > "Overwrite existing
    /// metadata" off, since there's nothing there to lose.
    ///
    /// The Integer/Bool case matters because MP42MetadataItem.stringValue
    /// stringifies an Integer or Bool item's value unconditionally (NSNumber's
    /// own stringValue, e.g. "0") -- it's never nil just because the number
    /// happens to be zero -- so checking stringValue first (as this used
    /// to) read an untouched Integer/Bool field as already "set" the
    /// moment it was added, before the user ever touched it. A freshly
    /// added Content Rating field starts at 0 ("None") exactly that way,
    /// which silently blocked a Set's own Content Rating value (e.g.
    /// "Explicit") from ever applying via applySet(_:) below -- the field
    /// looked occupied, so the "never overwrite an existing value" guard
    /// skipped it. See MP42MetadataItem.isEffectivelyEmpty (shared with
    /// QueueSetAction) for the fix.
    @IBAction func applySet(_ sender: NSMenuItem) {
        let index = sender.tag
        let preset = PresetManager.shared.metadataPresets[index]

        let dataTypes: UInt = MP42MetadataItemDataType.string.rawValue | MP42MetadataItemDataType.stringArray.rawValue |
            MP42MetadataItemDataType.bool.rawValue | MP42MetadataItemDataType.integer.rawValue |
            MP42MetadataItemDataType.integerArray.rawValue | MP42MetadataItemDataType.date.rawValue

        var items = preset.metadata.metadataItemsFiltered(by: MP42MetadataItemDataType(rawValue: dataTypes))

        // Preferences > Metadata > "Overwrite existing metadata" wins over
        // this Set's own replace-annotations/replace-artworks choice, when
        // turned off -- that's the user's explicit promise that applying a
        // Set (e.g. right after running a search) never erases a value
        // already sitting in the metadata table, regardless of how the Set
        // itself was saved.
        let skipExisting = MetadataPrefs.overwriteExistingAnnotations == false

        if skipExisting {
            let existingNonEmptyIdentifiers = Set(metadata.metadataItemsFiltered(by: MP42MetadataItemDataType(rawValue: dataTypes))
                .filter { $0.isEffectivelyEmpty == false }
                .map { $0.identifier })
            items = items.filter { existingNonEmptyIdentifiers.contains($0.identifier) == false }
        } else if preset.replaceAnnotations {
            remove(metadataItems: metadata.metadataItemsFiltered(by: MP42MetadataItemDataType(rawValue: dataTypes)))
        }

        // Flag whatever this Set actually ends up touching -- filled-in
        // or still blank -- the same way a metadata search merge does,
        // so it's obvious at a glance what came from the preset.
        var changedIdentifiers: Set<String> = []

        if items.isEmpty == false {
            let identifiers = items.map { $0.identifier }
            // items has already been filtered down to identifiers that are
            // safe to touch (empty or altogether absent), so the only
            // things this ever clears are blank placeholders -- never a
            // value the preference is meant to protect.
            let toRemove = skipExisting
                ? metadata.metadataItemsFiltered(byIdentifiers: identifiers).filter { $0.isEffectivelyEmpty }
                : metadata.metadataItemsFiltered(byIdentifiers: identifiers)
            remove(metadataItems: toRemove)
            add(metadataItems: items)
            changedIdentifiers.formUnion(identifiers)
        }

        let artworkItems = preset.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt)
        let hasExistingArtwork = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt).isEmpty == false

        if skipExisting {
            // Never replace existing artwork -- only add the preset's
            // artwork when there currently isn't any.
            if hasExistingArtwork == false && artworkItems.isEmpty == false {
                add(metadataArtworks: artworkItems)
            }
        } else {
            if preset.replaceArtworks {
                remove(metadataItems: metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt))
            }
            if artworkItems.isEmpty == false {
                add(metadataArtworks: artworkItems)
            }
        }

        if changedIdentifiers.isEmpty == false {
            highlightChangedFields(changedIdentifiers)
        }
    }

    @IBAction func showSaveSet(_ sender: Any) {
        view.window?.beginCriticalSheet(saveSetWindow, completionHandler: nil)
    }

    @IBAction func closeSaveSheet(_ sender: Any) {
        view.window?.endSheet(saveSetWindow)
    }

    @IBAction func saveSet(_ sender: Any) {
        guard let title = saveSetName?.stringValue else { return }

        let preset = MetadataPreset(title: title, metadata: metadata,
                                    replaceArtworks: keepArtworks?.state == .off,
                                    replaceAnnotations: keepAnnotations?.state == .off)

        do {
            try PresetManager.shared.append(newElement: preset)
            view.window?.endSheet(saveSetWindow)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Table View data source

    private static let keyCell = NSUserInterfaceItemIdentifier(rawValue: "NameTextCell")
    private static let boolCell = NSUserInterfaceItemIdentifier(rawValue: "BoolCell")
    private static let textCell = NSUserInterfaceItemIdentifier(rawValue: "TextCell")
    private static let popUpCell = NSUserInterfaceItemIdentifier(rawValue: "PopUpCell")
    private static let comboCell = NSUserInterfaceItemIdentifier(rawValue: "ComboCell")

    func numberOfRows(in tableView: NSTableView) -> Int {
        return tags.count
    }

    private func boolCell(state: Bool, tableView: NSTableView) -> CheckBoxCellView {
        guard let cell = tableView.makeView(withIdentifier: MovieViewController.boolCell, owner: self) as? CheckBoxCellView else { fatalError() }
        cell.checkboxButton.state = state ? .on : .off
        return cell
    }

    private func textCell(string: String?, tableView: NSTableView) -> NSTableCellView {
        guard let cell = tableView.makeView(withIdentifier: MovieViewController.textCell, owner: self) as? NSTableCellView else { fatalError() }
            cell.textField?.stringValue = string ?? ""
        return cell
    }

    /// Returns what to show in the Rating combo box for a raw stored value: the
    /// human-readable label when it matches one of Subler's predefined ratings
    /// (`self.codes` / `self.ratings` are parallel arrays), or the raw value
    /// itself otherwise -- so a custom rating (common with some content
    /// scrapers, which rarely map to a standard MPAA/TV certification) is
    /// preserved and editable instead of being replaced by a placeholder.
    private func ratingDisplayValue(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue, rawValue.isEmpty == false else { return rawValue }
        if let index = self.codes.firstIndex(of: rawValue) {
            return self.ratings[index]
        }
        return rawValue
    }

    private func popUpCell(contents: [(title: String, value: Int)], value: Int?, tableView: NSTableView) -> PopUpCellView {
        guard let cell = tableView.makeView(withIdentifier: MovieViewController.popUpCell, owner: self) as? PopUpCellView, let popUpButton = cell.popUpButton else { fatalError() }

        popUpButton.removeAllItems()

        contents.forEach {
            let item = NSMenuItem(title: $0.title, action: nil, keyEquivalent: "")
            item.tag = $0.value
            popUpButton.menu?.addItem(item)
        }

        if let value = value {
            popUpButton.selectItem(withTag: value)
        }

        if popUpButton.indexOfSelectedItem == -1 {
            let title = (value != nil) ? "\(String(describing: value))" : NSLocalizedString("Unknown", comment: "")
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = -1
            popUpButton.menu?.addItem(item)
            popUpButton.select(item)
        }

        return cell
    }

    private func comboBoxCell(contents: [String], value: String?, tableView: NSTableView) -> ComboBoxCellView {
        guard let cell = tableView.makeView(withIdentifier: MovieViewController.comboCell, owner: self) as? ComboBoxCellView, let comboBox = cell.comboBox else { fatalError() }

        comboBox.stringValue = value ?? NSLocalizedString("Unknown", comment: "")
        // Cells are reused (Genre and Rating share this one), so start empty.
        comboBox.removeAllItems()
        comboBox.addItems(withObjectValues: contents)

        return cell
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // Not private: NamingCondition (NamingRules.swift) reuses this exact
    // list so a Filename condition like "Content Rating is Explicit"
    // compares against the same label this popup shows, instead of the
    // raw Integer code (0/2/4) the file's tag actually stores -- see
    // NamingCondition.comparableValue(for:item:).
    static let contentRatings: [(title: String, value: Int)] =
                   [(title: NSLocalizedString("None", comment: ""), value: 0),
                    (title: NSLocalizedString("Clean", comment: ""), value: 2),
                    (title: NSLocalizedString("Explicit", comment: ""), value: 4)]

    // Not private: NamingCondition reuses this list (see contentRatings above).
    static let mediaKinds: [(title: String, value: Int)] =
                   [(title: NSLocalizedString("Home Video", comment: ""), value: 0),
                    (title: NSLocalizedString("Music", comment: ""), value: 1),
                    (title: NSLocalizedString("Audiobook", comment: ""), value: 2),
                    (title: NSLocalizedString("Music Video", comment: ""), value: 6),
                    (title: NSLocalizedString("Movie", comment: ""), value: 9),
                    (title: NSLocalizedString("TV Show", comment: ""), value: 10),
                    (title: NSLocalizedString("Booklet", comment: ""), value: 11),
                    (title: NSLocalizedString("Ringtone", comment: ""), value: 14),
                    (title: NSLocalizedString("Podcast", comment: ""), value: 21),
                    (title: NSLocalizedString("iTunes U", comment: ""), value: 23),
                    (title: NSLocalizedString("Alert Tone", comment: ""), value: 27)]

    private static let hdVideo: [(title: String, value: Int)] =
                   [(title: NSLocalizedString("No", comment: ""), value: 0),
                    (title: NSLocalizedString("720p", comment: ""), value: 1),
                    (title: NSLocalizedString("1080p", comment: ""), value: 2),
                    (title: NSLocalizedString("4k", comment: ""), value: 3)]

    private let keyColumn = NSUserInterfaceItemIdentifier(rawValue: "key")
    private let valueColumn = NSUserInterfaceItemIdentifier(rawValue: "value")

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {

        let item = tags[row]

        if tableColumn?.identifier == keyColumn {

            let cell = tableView.makeView(withIdentifier: MovieViewController.keyCell, owner: self) as? NSTableCellView
            let isRecentlyChanged = recentlyChangedIdentifiers.contains(item.identifier)
            cell?.textField?.stringValue = isRecentlyChanged
                ? "• " + localizedMetadataKeyName(item.identifier)
                : localizedMetadataKeyName(item.identifier)
            if isRecentlyChanged {
                if #available(macOS 10.14, *) {
                    cell?.textField?.textColor = .controlAccentColor
                }
                else {
                    cell?.textField?.textColor = .systemBlue
                }
                cell?.toolTip = NSLocalizedString("Changed by the last metadata search", comment: "")
            } else {
                cell?.toolTip = nil
                if #available(macOS 10.14, *) {
                    cell?.textField?.textColor = .secondaryLabelColor
                }
                else {
                    cell?.textField?.textColor = .disabledControlTextColor
                }
            }
            return cell

        } else if tableColumn?.identifier == valueColumn {

            switch item.dataType {

            case .string:
                if item.identifier == MP42MetadataKeyUserGenre {
                    return comboBoxCell(contents: GenreList.all(including: item.stringValue), value: item.stringValue, tableView: tableView)
                } else if item.identifier == MP42MetadataKeyRating {
                    return comboBoxCell(contents: ratings, value: ratingDisplayValue(item.stringValue), tableView: tableView)
                } else {
                    return textCell(string: item.stringValue, tableView: tableView)
                }

            case .stringArray, .integer:
                if item.identifier == MP42MetadataKeyContentRating {
                    return popUpCell(contents: MovieViewController.contentRatings, value: item.numberValue?.intValue, tableView: tableView)
                } else if item.identifier == MP42MetadataKeyMediaKind {
                    return popUpCell(contents: MovieViewController.mediaKinds, value: item.numberValue?.intValue, tableView: tableView)
                } else if item.identifier == MP42MetadataKeyHDVideo {
                    return popUpCell(contents: MovieViewController.hdVideo, value: item.numberValue?.intValue, tableView: tableView)
                } else {
                    return textCell(string: item.stringValue, tableView: tableView)
                }

            case .integerArray:
                return textCell(string: item.stringValue, tableView: tableView)

            case .date:

                if let date = item.dateValue {
                    let formattedDate = MovieViewController.formatter.string(from: date)
                    return textCell(string: formattedDate, tableView: tableView)
                } else {
                    return textCell(string: item.stringValue, tableView: tableView)
                }

            case .bool:

                return boolCell(state: item.numberValue?.boolValue ?? false, tableView: tableView)

            default:
                return nil
            }
        }

        return nil
    }

    // MARK: Table View editing

    private func stringsArray(fromString string: String) -> [String] {
        let splitElements = ",\\s*+"
        return string.mp42_components(separatedByRegex: splitElements)
    }

    private func numbersArray(fromString string: String) -> [UInt] {
        let parts = string.split(separator: "/")
        var count: UInt = 0, index: UInt = 0

        index = UInt(parts.first ?? "") ?? 0
        if parts.count > 1 {
            count = UInt(parts.last ?? "") ?? 0
        }

        return [index, count]
    }

    @IBAction func setMetadataStringValue(_ sender: NSTextField) {
        let row = metadataTableView.row(for: sender)

        if row == -1 { return }

        let item = tags[row]

        if sender.stringValue == item.stringValue { return }

        if item.dataType == .date, let date = item.dateValue,  MovieViewController.formatter.string(from: date) == item.stringValue {
            return
        }

        var value: Any = ""
        var type = item.dataType

        switch item.dataType {
        case .string:
            if item.identifier == MP42MetadataKeyReleaseDate {
                if let date = MovieViewController.formatter.date(from: sender.stringValue) {
                    value = date
                    type = .date
                } else {
                    value = sender.stringValue
                }
            } else if item.identifier == MP42MetadataKeyRating {
                if let index = self.ratings.firstIndex(of: sender.stringValue) {
                    value = self.codes[index]
                } else {
                    value = sender.stringValue
                }
            } else {
                value = sender.stringValue
                // A genre typed by hand is added to the list for next time.
                if item.identifier == MP42MetadataKeyUserGenre {
                    GenreList.remember(sender.stringValue)
                }
            }

        case .stringArray:
            value = stringsArray(fromString: sender.stringValue)
            break

        case .integer:
            value = sender.integerValue

        case .integerArray:
            value = numbersArray(fromString: sender.stringValue)

        case .date:
            if let date = MovieViewController.formatter.date(from: sender.stringValue) {
                value = date
            } else {
                value = sender.stringValue
                type = .string
            }

        case .bool:
            value = sender.integerValue

        default:
            break
        }

        let editedItem = MP42MetadataItem(identifier: item.identifier, value: value as! NSCopying & NSObjectProtocol, dataType: type, extendedLanguageTag: item.extendedLanguageTag)

        replace(metadataItem: item, withItem: editedItem)
    }

    @IBAction func setMetadataBoolValue(_ sender: NSButton) {
        let row = metadataTableView.row(for: sender)

        if row == -1 { return }

        let item = tags[row]

        let editedItem = MP42MetadataItem(identifier: item.identifier, value: sender.state == .on ? true as NSCopying & NSObjectProtocol : false as NSCopying & NSObjectProtocol, dataType: item.dataType, extendedLanguageTag: item.extendedLanguageTag)

        replace(metadataItem: item, withItem: editedItem)
    }

    @IBAction func setMetadataIntValue(_ sender: NSPopUpButton) {
        if sender.selectedTag() == -1 { return }

        let row = metadataTableView.row(for: sender)

        if row == -1 { return }

        let item = tags[row]

        let index = sender.indexOfSelectedItem

        var value: Any = -1

        switch item.dataType {
        case .integer:
            if item.identifier == MP42MetadataKeyContentRating {
                value = MovieViewController.contentRatings[index].value
            } else if item.identifier == MP42MetadataKeyMediaKind {
                value = MovieViewController.mediaKinds[index].value
            } else if item.identifier == MP42MetadataKeyHDVideo {
                value = MovieViewController.hdVideo[index].value
            }

        default:
            break
        }

        let editedItem = MP42MetadataItem(identifier: item.identifier, value: value as! NSCopying & NSObjectProtocol, dataType: item.dataType, extendedLanguageTag: item.extendedLanguageTag)

        replace(metadataItem: item, withItem: editedItem)
    }

    // MARK: Table View delegate

    @IBAction func doubleClickAction(_ sender: Any?) {
        // make sure they clicked a real cell and not a header or empty row
        guard let sender = sender as? NSTableView else { return }

        if sender.clickedRow != -1 && sender.clickedColumn == 1 {
            sender.editColumn(sender.clickedColumn, row: sender.clickedRow, with: nil, select: true)
        }
    }

    func deleteSelection(in tableview: NSTableView) {
        removeTag(tableview)
    }

    func copySelection(in tableview: NSTableView) {
        let selectedRows = tableview.selectedRowIndexes
        let items = tags.enumerated().filter { selectedRows.contains($0.offset) == true } .map { $0.element }

        let itemsDescriptions = items.map { "\($0.identifier): \($0.stringValue ?? "")\n"}
        let description = itemsDescriptions.reduce("") {$0 + $1 }

        let pb = NSPasteboard.general
        let data = try? NSKeyedArchiver.archivedData(withRootObject: items, requiringSecureCoding: true)
        pb.declareTypes([.string, .metadataDragType], owner: nil)
        pb.setString(description, forType: .string)
        pb.setData(data, forType: .metadataDragType)
    }

    func cutSelection(in tableview: NSTableView) {
        copySelection(in: tableview)
        removeTag(tableview)
    }

    func paste(to tableview: NSTableView) {
        let pb = NSPasteboard.general
        if let archivedData = pb.data(forType: .metadataDragType),
           let data = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.classForCoder(), MP42MetadataItem.classForCoder()], from: archivedData) as? [MP42MetadataItem] {
            add(metadataItems: data)
        }
    }

    func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        return ""
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let item = tags[row]

        var calculateHeight = false
        let minHeight = CGFloat(14)
        var height = CGFloat(0)

        // Height calculation is slow, so calculate only if stricly necessary.
        switch item.dataType {
        case .string, .stringArray, .date:
            calculateHeight = true
        default:
            calculateHeight = false
        }

        if let cachedHeight = rowHeights[item.identifier] {
            height = cachedHeight
        } else if calculateHeight {
            // Set the width in the dummy cell, and let autolayout calculate the height.
            dummyCellWidth.constant = columnWidth
            dummyCell.textField?.preferredMaxLayoutWidth = columnWidth
            if let string = item.stringValue {
                dummyCell.textField?.stringValue = string
            }
            height = dummyCell.fittingSize.height
            rowHeights[item.identifier] = height
        }

        return (height < minHeight) ? minHeight : height;
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        previousColumnWidth = columnWidth
        columnWidth = column.width

        if columnWidth > previousColumnWidth {
            rowHeights = rowHeights.filter { $0.value < 14.0 }
        } else {
            rowHeights.removeAll(keepingCapacity: true)
        }

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        metadataTableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<metadataTableView.numberOfRows))
        NSAnimationContext.endGrouping()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateUI()
    }

    // MARK: Artworks

    private func updateArtworksArray() {
        artworks = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt)
    }

    private func add(metadataArtworks items: [MP42MetadataItem]) {
        metadata.addItems(items)
        updateArtworksArray()
        artworksView.reloadData()
    }

    private func remove(metadataArtworks items: [MP42MetadataItem]) {
        metadata.removeItems(items)
        updateArtworksArray()
        artworksView.reloadData()
        updateSelection()
    }

    private func replace(metadataArtworks items: [MP42MetadataItem], withItems newItems: [MP42MetadataItem]) {
        metadata.removeItems(items)
        metadata.addItems(newItems)
        updateArtworksArray()
        artworksView.reloadData()
        updateSelection()
    }

    @IBAction func removeArtwork(_ sender: Any?) {
        remove(metadataArtworks: artworksView.selectionIndexes.map { artworks[$0] })
    }

    private func add(artworks: [Any], toIndexPath: IndexPath) -> Bool {
        let items = artworks.compactMap { (artwork: Any) -> MP42Image? in
            if let url = artwork as? URL {
                let value = try? url.resourceValues(forKeys: [URLResourceKey.typeIdentifierKey])

                if let type = value?.typeIdentifier, UTTypeConformsTo(type as CFString, "public.jpeg" as CFString), let data = try? Data(contentsOf: url) {
                    return MP42Image(data: data, type: MP42_ART_JPEG)
                } else if let image = NSImage(contentsOf: url) {
                    return MP42Image(image: image)
                }
            } else if let image = artwork as? NSImage {
                return MP42Image(image: image)
            } else if let image = artwork as? MP42Image {
                return image
            }
            return nil
            }.map {
                return MP42MetadataItem(identifier: MP42MetadataKeyCoverArt, value: $0, dataType: .image, extendedLanguageTag: nil)
        }

        if items.isEmpty {
            return false
        } else {
            add(metadataArtworks: items)
            updateSelection()
            return true
        }
    }

    @IBAction func selectArtwork(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if #available(macOS 11, *) {
            panel.allowedContentTypes = [.image]
        } else {
            panel.allowedFileTypes = ["public.image"]
        }

        guard let window = view.window else { return }

        panel.beginSheetModal(for: window) { (result) in
            if result == NSApplication.ModalResponse.OK {
                _ = self.add(artworks: panel.urls, toIndexPath: IndexPath(index: 0))
            }
        }
    }

    // MARK: - Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return artworks.count
    }

    static let itemView = NSUserInterfaceItemIdentifier(rawValue: "ArtworkSelectorViewItem")

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ArtworkSelectorController.itemView, for: indexPath)
        guard let collectionViewItem = item as? ArtworkSelectorViewItem, let index = indexPath.last else { return item }

        let artwork = artworks[index]

        collectionViewItem.image = artwork.imageValue?.image
        collectionViewItem.title = nil
        collectionViewItem.subtitle = nil
        collectionViewItem.target = self

        return collectionViewItem
    }

    // MARK: - Delegate

    private func updateSelection() {
        removeArtworkButton.isEnabled = artworksView.selectionIndexPaths.isEmpty ? false : true
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        return true
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        if let userInfo = filePromiseProvider.userInfo as? [String: AnyObject] {
            return "Artwork." + (userInfo[FilePromiseProvider.UserInfoKeys.extensionKey] as! String)
        } else {
            return "Artwork"
        }
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        if let userInfo = filePromiseProvider.userInfo as? [String: AnyObject] {
            do {
                if let indexPathData = userInfo[FilePromiseProvider.UserInfoKeys.indexPathKey] as? Data,
                   let indexPath = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSIndexPath.classForCoder()], from: indexPathData) as? IndexPath,
                   let image = artworks[indexPath.last!].imageValue {
                    try image.data?.write(to: url)
                    completionHandler(nil)
                }
            } catch {
                fatalError("failed to unarchive indexPath from promise provider.")
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        var provider: NSFilePromiseProvider?

        let item = artworks[indexPath.last!]
        guard let image = item.imageValue else { return provider }

        let fileExtension = {
            switch image.type {
            case MP42_ART_BMP:
                return "bmp"
            case MP42_ART_GIF:
                return "gif"
            case MP42_ART_JPEG:
                return "jpeg"
            case MP42_ART_PNG: fallthrough
            default:
                return "png"
            }
        }()

        if #available(macOS 11.0, *) {
            let typeIdentifier = UTType(filenameExtension: fileExtension)
            provider = FilePromiseProvider(fileType: typeIdentifier!.identifier, delegate: self)
        } else {
            let typeIdentifier =
                  UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, fileExtension as CFString, nil)
            provider = FilePromiseProvider(fileType: typeIdentifier!.takeRetainedValue() as String, delegate: self)
        }

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: indexPath, requiringSecureCoding: false)
            provider!.userInfo = [FilePromiseProvider.UserInfoKeys.extensionKey: fileExtension as Any,
                                  FilePromiseProvider.UserInfoKeys.indexPathKey: data]
        } catch {
            fatalError("failed to archive indexPath to pasteboard")
        }
        return provider
    }

    func collectionView(_ collectionView: NSCollectionView,
                        validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        var dragOperation: NSDragOperation = []

        guard proposedDropOperation.pointee != .on else { return dragOperation }

        let pasteboard = draggingInfo.draggingPasteboard

        if let draggingSource = draggingInfo.draggingSource as? NSCollectionView, draggingSource == collectionView {
            // Drag source came from our own collection view.
            dragOperation = [.move]
        } else {
            // Drag source came from another app.
            // Search through the array of NSPasteboardItems.
            guard let items = pasteboard.pasteboardItems else { return dragOperation }
            for item in items {
                var type: NSPasteboard.PasteboardType
                if #available(macOS 11.0, *) {
                    type = NSPasteboard.PasteboardType(UTType.image.identifier)
                } else {
                    type = (kUTTypeImage as NSPasteboard.PasteboardType)
                }
                if item.availableType(from: [type]) != nil {
                    // Drag source is coming from another app as a promised image file (for example from Photos app).
                    dragOperation = [.copy]
                }
            }
        }

        // Has a drop operation been determined yet?
        if dragOperation == [] {
            // Look for possible URLs you can consume.
            var acceptedTypes: [String]
            if #available(macOS 11.0, *) {
                acceptedTypes = [UTType.image.identifier]
            } else {
                acceptedTypes = [kUTTypeImage as String]
            }

            let options = [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true,
                           NSPasteboard.ReadingOptionKey.urlReadingContentsConformToTypes: acceptedTypes]
                as [NSPasteboard.ReadingOptionKey: Any]
            // Look only for image urls.
            if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options), !urls.isEmpty {
                // One or more of the URLs in this drag is image file.
                dragOperation = [.copy]
            }
        }
        return dragOperation
    }

    func dropInternalArtworks(_ collectionView: NSCollectionView, draggingInfo: NSDraggingInfo, indexPath: IndexPath) {
        var indexes = Set<IndexPath>()

        draggingInfo.enumerateDraggingItems(
            options: NSDraggingItemEnumerationOptions.concurrent,
            for: collectionView,
            classes: [NSPasteboardItem.self],
            searchOptions: [:],
            using: {(draggingItem, idx, stop) in
                if let pasteboardItem = draggingItem.item as? NSPasteboardItem {
                    do {
                        if let indexPathData = pasteboardItem.data(forType: .artworkDragType),
                           let itemIndexPath = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSIndexPath.classForCoder()], from:indexPathData) as? IndexPath {
                            indexes.insert(itemIndexPath)
                        }
                    } catch {
                        Swift.debugPrint("failed to unarchive indexPath for dropped item.")
                    }
                }
            })

        if let last = indexPath.last {
            let itemIndexes = indexes.compactMap { $0.last }
            let draggedItems = itemIndexes.map { artworks[$0] }
            let destinationIndex = last - itemIndexes.filter { $0 < last }.count

            var modifiedArtworks = IndexSet(artworks.indices).subtracting(IndexSet(itemIndexes)).map { artworks[$0] }

            for item in draggedItems.reversed() {
                modifiedArtworks.insert(item, at: destinationIndex)
            }

            replace(metadataArtworks: artworks, withItems: modifiedArtworks)
        }
    }

    // The temporary directory URL you use to accept file promises.
    lazy var destinationURL: URL = {
        let destinationURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Drops")
        try? FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)
        return destinationURL
    }()

    // Queue you use to read and writing file promises.
    var filePromiseQueue: OperationQueue = {
        let queue = OperationQueue()
        return queue
    }()

    func handlePromisedDrops(draggingInfo: NSDraggingInfo, toIndexPath: IndexPath) -> Bool {
        var handled = false
        if let promises = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) {
            if !promises.isEmpty {
                for promise in promises {
                    if let promiseReceiver = promise as? NSFilePromiseReceiver {
                        promiseReceiver.receivePromisedFiles(atDestination: destinationURL, options: [:], operationQueue: filePromiseQueue) { fileURL, error in
                            OperationQueue.main.addOperation {
                                if error != nil {
                                    __NSBeep()
                                } else {
                                    _ = self.add(artworks: [fileURL], toIndexPath:toIndexPath)
                                }
                            }
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    // Find the proper drop location relative to the provided indexPath.
    static func dropLocation(indexPath: IndexPath) -> IndexPath {
        var toIndexPath = indexPath
        if indexPath.item == 0 {
            toIndexPath = IndexPath(item: indexPath.item, section: indexPath.section)
        } else {
            toIndexPath = IndexPath(item: indexPath.item - 1, section: indexPath.section)
        }
        return toIndexPath
    }

    func dropExternalArtworks(_ collectionView: NSCollectionView, draggingInfo: NSDraggingInfo, indexPath: IndexPath) {
        let toIndexPath = MovieViewController.dropLocation(indexPath: indexPath)

        if handlePromisedDrops(draggingInfo: draggingInfo, toIndexPath: toIndexPath) {
            // Successfully processed the dragged items that were promised.
        } else {
            // Incoming drag was not promised, so move in all the outside dragged items as URLs.
            var foundNonImageFiles = false

            // Move in all the outside dragged items as URLs.
            draggingInfo.enumerateDraggingItems(
                options: NSDraggingItemEnumerationOptions.concurrent,
                for: collectionView,
                classes: [NSPasteboardItem.self],
                searchOptions: [:],
                using: {(draggingItem, idx, stop) in
                    if let pasteboardItem = draggingItem.item as? NSPasteboardItem,
                       // Are we being passed a file URL as the drag type?
                       let itemType = pasteboardItem.availableType(from: [.fileURL]),
                       let filePath = pasteboardItem.string(forType: itemType),
                       let url = URL(string: filePath) {
                        if !self.add(artworks: [url], toIndexPath:toIndexPath) {
                            foundNonImageFiles = true
                        }
                    }
                })

            if foundNonImageFiles {
                __NSBeep()
            }
        }
    }

    func collectionView(_ collectionView: NSCollectionView,
                        acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        // Check where the dragged items are coming from.
        if let draggingSource = draggingInfo.draggingSource as? NSCollectionView, draggingSource == collectionView {
            // Drag source from your own collection view.
            // Move each dragged photo item to their new place.
            dropInternalArtworks(collectionView, draggingInfo: draggingInfo, indexPath: indexPath)
        } else {
            // The drop source is from another app (Finder, Mail, Safari, etc.) and there may be more than one file.
            // Drop each dragged image file to their new place.
            dropExternalArtworks(collectionView, draggingInfo: draggingInfo, indexPath: indexPath)
        }
        return true
    }

    func collectionView(_ collectionView: NSCollectionView,
                        draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint,
                        dragOperation operation: NSDragOperation) {
        if operation == .delete, let items = session.draggingPasteboard.pasteboardItems {
            // User dragged the artwork to the Finder's trash.
            var indexes = Set<IndexPath>()

            for pasteboardItem in items {
                do {
                    if let indexPathData = pasteboardItem.data(forType: .artworkDragType),
                       let itemIndexPath = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSIndexPath.classForCoder()], from:indexPathData) as? IndexPath {
                        indexes.insert(itemIndexPath)
                    }
                } catch {
                    Swift.debugPrint("failed to unarchive indexPath for dropped item.")
                }
            }

            if indexes.isEmpty == false {
                let itemIndexes = indexes.compactMap { $0.last }
                let draggedItems = itemIndexes.map { artworks[$0] }
                remove(metadataArtworks: draggedItems)
            }
        }
    }

    var zoomLevel: Float {
        get {
            Prefs.movieArtworkSelectorZoomLevel
        }
        set (value) {
            Prefs.movieArtworkSelectorZoomLevel = value;
        }
    }

    private func setZoomValue(_ newZoomValue: Float) {
        if let layout = artworksView.collectionViewLayout as? NSCollectionViewFlowLayout {
            if newZoomValue == 50 {
                layout.itemSize = standardSize
            } else if newZoomValue < 50 {
                let zoomValue = (CGFloat(newZoomValue) + 50) / 100
                layout.itemSize = NSSize(width: Int(standardSize.width * zoomValue),
                                         height: Int(standardSize.height * zoomValue))

            } else {
                let zoomValue = pow((CGFloat(newZoomValue) + 50) / 100, 2.4)
                layout.itemSize = NSSize(width: Int(standardSize.width * zoomValue),
                                         height: Int(standardSize.height * zoomValue))
            }
        }
    }

    @IBAction func zoomSliderDidChange(_ sender: NSControl) {
        setZoomValue(sender.floatValue)
        zoomLevel = sender.floatValue
    }

    func collectionViewDelete(in collectionView: NSCollectionView) {
        removeArtwork(self)
    }

    func collectionViewCopy(in collectionView: NSCollectionView) {
        let indexes = artworksView.selectionIndexes
        if indexes.isEmpty { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let items = indexes.compactMap { artworks[$0].imageValue }
        pasteboard.writeObjects(items)
    }

    func collectionViewPaste(to collectionView: NSCollectionView) {
        let pasteboard = NSPasteboard.general

        let classes = [MP42Image.classForCoder(), NSURL.classForCoder(), NSImage.classForCoder()]
        let options = [NSPasteboard.ReadingOptionKey.urlReadingContentsConformToTypes: NSImage.imageTypes]

        if let items = pasteboard.readObjects(forClasses: classes, options: options) as [AnyObject]? {
            _ = add(artworks: items, toIndexPath:IndexPath(index: 0))
        }
    }

    func collectionViewCut(in collectionView: NSCollectionView) {
        collectionViewCopy(in: collectionView)
        collectionViewDelete(in: collectionView)
    }

}

/// The genres offered in the Genre drop-down: the movie and TV genres in
/// common use, plus every genre you have typed in yourself before. The box
/// still takes any text, so a genre that is not on the list can be typed in
/// and is added to the list when it is saved.
enum GenreList {

    static let standard: [String] = [
        "Action", "Action & Adventure", "Adventure", "Animation", "Anime", "Biography",
        "Classic TV", "Classics", "Comedy", "Crime", "Documentary", "Drama", "Family",
        "Fantasy", "Fitness & Workout", "Foreign", "History", "Horror", "Independent",
        "Kids", "Kids & Family", "Music", "Musical", "Mystery", "Non-Fiction", "Reality TV",
        "Romance", "Sci-Fi & Fantasy", "Science Fiction", "Short Film", "Special Interest",
        "Sports", "Thriller", "War", "Western"
    ]

    static let customKey = "SBCustomGenres"

    /// The genres typed in by hand and kept, in the order they were first typed.
    static func custom(defaults: UserDefaults = .standard) -> [String] {
        return defaults.stringArray(forKey: customKey) ?? []
    }

    /// The whole list, in name order, with no repeats (capital letters do not
    /// make a new genre). `current` is the genre already on the file, so it is
    /// always in the list.
    static func all(including current: String? = nil, defaults: UserDefaults = .standard) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for genre in standard + custom(defaults: defaults) + genres(in: current ?? "") {
            if seen.insert(genre.lowercased()).inserted { result.append(genre) }
        }
        return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Replaces the kept genres with `genres` (the Genres editor in the
    /// Metadata preferences): spaces trimmed, empty ones and repeats left out,
    /// and any that are already on the standard list not kept twice.
    static func setCustom(_ genres: [String], defaults: UserDefaults = .standard) {
        var known = Set(standard.map { $0.lowercased() })
        var stored: [String] = []
        for genre in genres.map({ $0.trimmingCharacters(in: .whitespaces) }) where genre.isEmpty == false && known.insert(genre.lowercased()).inserted {
            stored.append(genre)
        }
        if stored.isEmpty { defaults.removeObject(forKey: customKey) } else { defaults.set(stored, forKey: customKey) }
    }

    /// Keeps the genres in `text` (separate several with commas) so they show
    /// up in the list from now on. Genres that are already on the list are not
    /// stored again.
    static func remember(_ text: String, defaults: UserDefaults = .standard) {
        var known = Set((standard + custom(defaults: defaults)).map { $0.lowercased() })
        var stored = custom(defaults: defaults)
        for genre in genres(in: text) where known.insert(genre.lowercased()).inserted {
            stored.append(genre)
        }
        if stored != custom(defaults: defaults) {
            defaults.set(stored, forKey: customKey)
        }
    }

    private static func genres(in text: String) -> [String] {
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false && $0 != NSLocalizedString("Unknown", comment: "") }
    }
}
