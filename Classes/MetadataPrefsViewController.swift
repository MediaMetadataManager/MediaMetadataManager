//
//  MetadataPrefsViewController.swift
//  Subler
//
//  Created by Damiano Galassi on 10/08/2017.
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

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: appendButton.leadingAnchor),
            checkbox.topAnchor.constraint(equalTo: appendButton.bottomAnchor, constant: 8),
            view.trailingAnchor.constraint(greaterThanOrEqualTo: checkbox.trailingAnchor, constant: 20),
            view.bottomAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 20)
        ])
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
