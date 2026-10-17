//
//  OutputPrefsViewController.swift
//  Subler
//
//  Created by Damiano Galassi on 30/11/2017.
//
//  Rewritten to build its view programmatically (no xib) so the Movie and
//  TV Show lists can each host a variable-length, user-editable list of
//  conditional naming rules (see NamingRules.swift) instead of a single
//  fixed template. The two lists live on their own NSTabViewItem each
//  (see buildUI() below) -- small, centered native tab buttons, matching
//  the Metadata/Artwork switch MovieView.xib already uses for the main
//  document window -- rather than being stacked one above the other on
//  one page.
//
//  Each Movie rule's own enable checkbox sits in front of its "Name:"
//  line (shown above that rule's condition(s), rather than below --
//  the condition reads as "when this applies" context for the template
//  the user is primarily editing). This replaced a single standalone
//  "Set filename of Movies" checkbox that used to gate the whole Movie
//  section; the Default rule's own checkbox is what that used to be.
//
//  A rule's conditions: the "+"/"-" buttons on a condition row add or
//  remove one condition from that SAME rule, not a new rule -- removing
//  a rule's last remaining condition removes the whole rule. A dedicated
//  "Add Rule" button below the list is what starts an entirely new,
//  separate conditional rule. Conditions on different fields are AND'd
//  together; consecutive conditions on the *same* field are OR'd
//  together instead (see NamingRules.swift's NamingRule.matches(metadata:))
//  -- a condition row's "And"/"Or" prefix reflects which one applies.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Filename tab with multi-condition naming rules for Movies and TV Shows,
//  per-movie folder when saving, usability fixes.
//

import Cocoa
import MP42Foundation

// MARK: - A single conditional-naming-rule row

/// One row of the Movie naming-rule editor: this rule's own enable
/// checkbox and token-field naming template ("Name:"), followed -- for
/// every rule except the condition-less "Default" row -- by one or more
/// conditions ("If <field> <operator> <value>", "And ...", "Or ...",
/// ...). Conditions on different fields are AND'd together; a condition
/// that shares its field with the one directly above it is OR'd with it
/// instead (a field can only hold one value, so AND-ing two conditions
/// on the same field could never match) -- conditionRow(at:) below picks
/// "And" vs. "Or" for each row's prefix accordingly. The Default row
/// always renders first and never shows a condition; it's just the
/// fallback "Name:" template (and its own isEnabled checkbox) used when
/// nothing above it matches -- or, when unchecked, "leave the file's
/// original name alone".
///
/// Each condition row carries its own inline "-" (removes that one
/// condition -- the whole rule, if it's the condition's last one) and,
/// on the rule's last condition row only, a "+" that appends another
/// condition right after it (AND'd, unless its field is then changed to
/// match this row's, which turns it into an "Or").
private final class RuleRowView: NSView, TokenChangeObserver, NSTextFieldDelegate, NSComboBoxDelegate {

    private(set) var rule: NamingRule
    let isDefaultRow: Bool
    let index: Int
    /// Which section this row belongs to -- Movies or TV Shows -- so the
    /// Rating field's autocomplete pulls the right list (see
    /// populateAutocomplete below and Ratings.conditionAutocompleteValues(mediaKind:)).
    let mediaKind: MediaKind

    /// Fired whenever a field within this rule changes value (the
    /// checkbox, the template, a condition's field/operator/value) in a
    /// way that doesn't add or remove a row -- just persist.
    var onChange: ((NamingRule) -> Void)?
    /// Fired when a condition is added to, or removed from, this rule
    /// without emptying it -- the row needs to be rebuilt in place (its
    /// condition count changed), but no rule is added or removed from
    /// the list. Never set on the Default row (it never has conditions).
    var onStructureChange: ((NamingRule) -> Void)?
    /// Fired when this rule's last remaining condition is removed --
    /// removes the whole rule. Set only on non-default rows.
    var onRemoveRule: (() -> Void)?

    private static let conditionFields: [String] = MP42Metadata.writableMetadata

    private let tokenDelegate: TokenDelegate
    private let tokenField = NSTokenField()
    private var tokensPopover: NSPopover?

    /// One entry per condition row, in the same order as rule.conditions.
    private struct ConditionControls {
        let fieldPopup: NSPopUpButton
        let operatorPopup: NSPopUpButton
        let valueField: NSComboBox
    }
    private var conditionControls: [ConditionControls] = []

    init(rule: NamingRule, isDefaultRow: Bool, index: Int, mediaKind: MediaKind, showsDivider: Bool) {
        self.rule = rule
        self.isDefaultRow = isDefaultRow
        self.index = index
        self.mediaKind = mediaKind

        let separators = CharacterSet(charactersIn: "{}")
        self.tokenDelegate = TokenDelegate(displayMenu: true,
                                           displayString: { localizedMetadataKeyName($0.text.trimmingCharacters(in: separators)) })

        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        tokenDelegate.delegate = self
        buildUI(showsDivider: showsDivider)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI(showsDivider: Bool) {
        conditionControls = []

        var rows: [NSView] = [templateRow()]
        for conditionIndex in rule.conditions.indices {
            rows.append(conditionRow(at: conditionIndex))
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        ])

        if showsDivider {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(separator)
            NSLayoutConstraint.activate([
                separator.leadingAnchor.constraint(equalTo: leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                separator.bottomAnchor.constraint(equalTo: bottomAnchor),
                stack.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -8)
            ])
        } else {
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8).isActive = true
        }
    }

    private func templateRow() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
        checkbox.state = rule.isEnabled ? .on : .off
        checkbox.toolTip = isDefaultRow
            ? NSLocalizedString("When off, a Movie that matches no rule below keeps its original filename.", comment: "Default naming rule checkbox tooltip")
            : NSLocalizedString("When off, this rule is skipped as if it weren't in the list.", comment: "Naming rule checkbox tooltip")

        // "Name:" for every row -- the "If ..." condition(s) below (when
        // there are any) already say this is conditional, so a separate
        // "Then name it:" wording was just saying the same thing twice.
        let label = NSTextField(labelWithString: NSLocalizedString("Name:", comment: "Naming rule template label"))
        label.translatesAutoresizingMaskIntoConstraints = false

        tokenField.delegate = tokenDelegate
        tokenField.tokenizingCharacterSet = CharacterSet(charactersIn: "/")
        tokenField.objectValue = rule.tokens
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        tokenField.widthAnchor.constraint(equalToConstant: 520).isActive = true

        let tokensButton = NSButton(title: "…", target: self, action: #selector(showTokens(_:)))
        tokensButton.translatesAutoresizingMaskIntoConstraints = false
        tokensButton.bezelStyle = .rounded

        let stack = NSStackView(views: [checkbox, label, tokenField, tokensButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func conditionRow(at conditionIndex: Int) -> NSView {
        let condition = rule.conditions[conditionIndex]
        let isFirst = conditionIndex == 0
        let isLast = conditionIndex == rule.conditions.count - 1

        // A condition that shares its field with the one directly above it
        // is OR'd with it rather than AND'd (see NamingRule.matches(metadata:)
        // in NamingRules.swift) -- the prefix reflects that so what's on
        // screen always matches how the rule actually evaluates.
        let sameFieldAsPrevious = isFirst == false && condition.field == rule.conditions[conditionIndex - 1].field
        let prefixLabel = NSTextField(labelWithString: isFirst
            ? NSLocalizedString("If", comment: "Naming rule condition prefix")
            : (sameFieldAsPrevious
                ? NSLocalizedString("Or", comment: "Naming rule condition continuation prefix (same field as the condition above)")
                : NSLocalizedString("And", comment: "Naming rule condition continuation prefix")))
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let fieldPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fieldPopup.translatesAutoresizingMaskIntoConstraints = false
        fieldPopup.addItems(withTitles: RuleRowView.conditionFields.map { localizedMetadataKeyName($0) })
        if let fieldIndex = RuleRowView.conditionFields.firstIndex(of: condition.field) {
            fieldPopup.selectItem(at: fieldIndex)
        }
        fieldPopup.tag = conditionIndex
        fieldPopup.target = self
        fieldPopup.action = #selector(fieldChanged(_:))

        let operatorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        operatorPopup.translatesAutoresizingMaskIntoConstraints = false
        operatorPopup.addItems(withTitles: NamingConditionOperator.allCases.map { $0.localizedName })
        operatorPopup.selectItem(at: condition.op.rawValue)
        operatorPopup.tag = conditionIndex
        operatorPopup.target = self
        operatorPopup.action = #selector(operatorChanged(_:))

        let valueField = NSComboBox()
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.tag = conditionIndex
        valueField.delegate = self
        valueField.placeholderString = NSLocalizedString("Value", comment: "Naming rule condition value placeholder")
        valueField.stringValue = condition.value
        valueField.isHidden = condition.op.needsValue == false
        valueField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        populateAutocomplete(valueField, field: condition.field)

        conditionControls.append(ConditionControls(fieldPopup: fieldPopup, operatorPopup: operatorPopup, valueField: valueField))

        var views: [NSView] = [prefixLabel, fieldPopup, operatorPopup, valueField]
        let removeButton = makeRowButton(image: NSImage.removeTemplateName, action: #selector(removeConditionTapped(_:)),
                                          toolTip: NSLocalizedString("Remove this condition", comment: ""))
        removeButton.tag = conditionIndex
        views.append(removeButton)
        if isLast {
            let addButton = makeRowButton(image: NSImage.addTemplateName, action: #selector(addConditionTapped(_:)),
                                           toolTip: NSLocalizedString("Add another condition to this rule (AND, or OR if you set it to the same field as this one)", comment: ""))
            views.append(addButton)
        }

        let stack = NSStackView(views: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    /// Populates `comboBox`'s dropdown/autocomplete list for `field`:
    /// Ratings' own curated, locale-aware list for the Rating field (so a
    /// picked value is guaranteed to actually match a tagged file -- see
    /// Ratings.conditionAutocompleteValues(mediaKind:)), or this field's
    /// remembered past values otherwise (see
    /// MetadataPrefs.namingConditionValueHistory).
    private func populateAutocomplete(_ comboBox: NSComboBox, field: String) {
        comboBox.removeAllItems()
        let values = field == MP42MetadataKeyRating
            ? Ratings.conditionAutocompleteValues(mediaKind: mediaKind)
            : (NamingCondition.fixedValues(for: field) ?? MetadataPrefs.namingConditionValueHistory[field] ?? [])
        comboBox.addItems(withObjectValues: values)
    }

    /// A small square "+"/"-" style button, inline at the end of a row --
    /// see this class's header comment.
    private func makeRowButton(image imageName: NSImage.Name, action: Selector, toolTip: String) -> NSButton {
        let button = NSButton(image: NSImage(named: imageName) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .smallSquare
        button.imagePosition = .imageOnly
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = toolTip
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        rule.isEnabled = sender.state == .on
        onChange?(rule)
    }

    @objc private func fieldChanged(_ sender: NSPopUpButton) {
        let conditionIndex = sender.tag
        guard conditionIndex < rule.conditions.count else { return }
        let newField = RuleRowView.conditionFields[sender.indexOfSelectedItem]
        rule.conditions[conditionIndex].field = newField
        if conditionIndex < conditionControls.count {
            populateAutocomplete(conditionControls[conditionIndex].valueField, field: newField)
        }
        // A field change can turn this condition's relationship with its
        // neighbor from AND into OR (or back) -- see NamingRule.matches(metadata:)
        // and conditionRow(at:)'s prefixLabel -- so this needs the row
        // rebuilt (onStructureChange), not just persisted in place
        // (onChange), for the "And"/"Or" prefix shown to stay correct.
        onStructureChange?(rule)
    }

    @objc private func operatorChanged(_ sender: NSPopUpButton) {
        let conditionIndex = sender.tag
        guard conditionIndex < rule.conditions.count,
              let op = NamingConditionOperator(rawValue: sender.indexOfSelectedItem) else { return }
        rule.conditions[conditionIndex].op = op
        if conditionIndex < conditionControls.count {
            conditionControls[conditionIndex].valueField.isHidden = op.needsValue == false
        }
        onChange?(rule)
    }

    @objc private func addConditionTapped(_ sender: NSButton) {
        // Default a newly-added condition to a field this rule isn't
        // already filtering on, rather than always Rating -- with Rating
        // already used by an earlier condition (a very common first
        // condition, as in "If Rating = NC-17 ...") every condition added
        // afterward used to default right back to Rating too, which read
        // as "the field I already picked is still being offered/selected
        // even though it's in use." The field popup's own list is
        // untouched (see conditionRow(at:)) -- every field is always
        // selectable, including one already used by another condition in
        // this same rule, for exactly the case this is defaulting away
        // from: deliberately adding a second condition on the same field
        // to OR it with the first (see NamingRule.matches(metadata:)).
        let usedFields = Set(rule.conditions.map { $0.field })
        let defaultField = RuleRowView.conditionFields.first { usedFields.contains($0) == false } ?? MP42MetadataKeyRating
        rule.conditions.append(NamingCondition(field: defaultField, op: .equals, value: ""))
        onStructureChange?(rule)
    }

    @objc private func removeConditionTapped(_ sender: NSButton) {
        let conditionIndex = sender.tag
        guard conditionIndex < rule.conditions.count else { return }
        rule.conditions.remove(at: conditionIndex)
        if rule.conditions.isEmpty {
            // This was the rule's last condition -- a non-default rule
            // can't have zero conditions (that's what the Default row is
            // for), so the whole rule goes away.
            onRemoveRule?()
        } else {
            onStructureChange?(rule)
        }
    }

    @objc private func showTokens(_ sender: NSButton) {
        if let popover = tokensPopover {
            popover.close()
            tokensPopover = nil
            return
        }
        let tokensController = TokensViewController(tokens: MP42Metadata.writableMetadata)
        let p = NSPopover()
        p.contentViewController = tokensController
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        tokensPopover = p
    }

    // MARK: TokenChangeObserver

    func tokenDidChange(_ obj: Notification?) {
        if let tokens = tokenField.objectValue as? [Token] {
            rule.tokens = tokens
        }
        onChange?(rule)
    }

    // MARK: NSTextFieldDelegate / NSComboBoxDelegate

    /// Refresh the Rating list each time the dropdown opens, so a change
    /// to the General tab's "Show ratings for:" is picked up at once.
    func comboBoxWillPopUp(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        for (conditionIndex, controls) in conditionControls.enumerated() where combo === controls.valueField {
            guard conditionIndex < rule.conditions.count else { return }
            populateAutocomplete(combo, field: rule.conditions[conditionIndex].field)
            return
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        for (conditionIndex, controls) in conditionControls.enumerated() where field === controls.valueField {
            guard conditionIndex < rule.conditions.count else { return }
            rule.conditions[conditionIndex].value = field.stringValue
            // The Rating field's own autocomplete list is the
            // authoritative source of valid values (see
            // populateAutocomplete above) -- recording free-typed Rating
            // values into history here would risk resurfacing exactly
            // the kind of unmatchable typo ("USA NC-17") this feature
            // exists to prevent. Every other field's history is fair
            // game.
            if rule.conditions[conditionIndex].field != MP42MetadataKeyRating,
               NamingCondition.fixedValues(for: rule.conditions[conditionIndex].field) == nil {
                MetadataPrefs.recordNamingConditionValue(field.stringValue, for: rule.conditions[conditionIndex].field)
            }
            onChange?(rule)
            return
        }
    }
}

// MARK: - Output (Filename) preferences tab

/// Which section of naming rules a shared helper method is operating on.
/// Movies and TV Shows get identical rule-editing behavior -- multiple
/// rules, a per-rule enable checkbox, AND/OR-grouped conditions, locale- or
/// history-based autocomplete (see RuleRowView above) -- just backed by
/// separate storage (MetadataPrefs.movieNamingRules /
/// .tvShowNamingRules) and separate on-screen lists, so this and
/// rebuildRuleRows(for:)/addRule(for:)/removeRule(at:in:) below exist to
/// share that behavior instead of maintaining two near-identical copies
/// of it.
private enum RuleSection {
    case movie
    case tvShow

    var mediaKind: MediaKind {
        switch self {
        case .movie: return .movie
        case .tvShow: return .tvShow
        }
    }
}

class OutputPrefsViewController: NSViewController, NSTabViewDelegate {

    /// The Default rule (an empty conditions list) always renders first
    /// in each list. matchingTokens(for:) finds it by isDefault rather
    /// than position, so this ordering is purely a display convenience
    /// -- but existing installs may have saved a Default rule anywhere
    /// in the array (e.g. last, from an earlier version of this UI), so
    /// it's explicitly sorted to the front here rather than assumed.
    private var movieRules: [NamingRule] = {
        var loaded = MetadataPrefs.movieNamingRules
        if let defaultIndex = loaded.firstIndex(where: { $0.isDefault }), defaultIndex != 0 {
            let defaultRule = loaded.remove(at: defaultIndex)
            loaded.insert(defaultRule, at: 0)
        }
        return loaded
    }()

    private var tvShowRules: [NamingRule] = {
        var loaded = MetadataPrefs.tvShowNamingRules
        if let defaultIndex = loaded.firstIndex(where: { $0.isDefault }), defaultIndex != 0 {
            let defaultRule = loaded.remove(at: defaultIndex)
            loaded.insert(defaultRule, at: 0)
        }
        return loaded
    }()

    private var movieRulesStack: NSStackView!
    private var tvShowRulesStack: NSStackView!

    override var nibName: NSNib.Name? {
        return nil
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        self.title = NSLocalizedString("Filename", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        buildUI()
        rebuildRuleRows(for: .movie)
        rebuildRuleRows(for: .tvShow)

        // Persist the front-loaded Default-rule order so it stays sorted
        // in storage too, not just in this session's display.
        MetadataPrefs.movieNamingRules = movieRules
        MetadataPrefs.tvShowNamingRules = tvShowRules
    }

    // PrefsWindowController (selectItem(_:animate:)) reads outputController.view
    // -- triggering loadView/viewDidLoad above -- *before* it assigns the
    // result as window.contentView, so view.window is still nil inside
    // viewDidLoad and the resizeWindowToFitContent() calls inside
    // rebuildRuleRows(for:) above can only resize this detached view, never
    // the actual Preferences window -- leaving the window at whatever size
    // the previously-shown pane left it, which can be too short for the
    // Movie/TV Shows rule lists ("a large gap between the first and second
    // Movie entry" on the very first open, until some later action resized
    // the window). viewWillAppear() fires every time this pane is actually
    // selected and, as SourcesPrefsViewController's identical fix already
    // established, reliably does so only once the view is truly installed
    // in the window -- so resizing here is correct on the very first visit
    // and keeps the window the right size on every later visit too.
    override func viewWillAppear() {
        super.viewWillAppear()
        resizeWindowToFitContent()
    }

    // Switching between the Movies and TV Shows tabs can switch to a
    // noticeably taller or shorter list -- keep the window following
    // whichever tab is now showing, the same way SourcesPrefsViewController
    // does for its own three sub-tabs. Width is deliberately left alone
    // here (adjustWidth: false) -- only the toolbar-level switch into this
    // pane (viewWillAppear() above) and in-tab content changes (field
    // wrapping, adding/removing a rule -- see rebuildRuleRows(for:) and
    // its rows' onChange below) are allowed to change the window's width;
    // switching between the Movies/TV Shows tabs themselves should only
    // ever change height, or the window visibly widens/narrows on every
    // switch, which reads as "looks strange" (see
    // SourcesPrefsViewController.tabView(_:didSelect:)'s identical fix).
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        resizeWindowToFitContent(adjustWidth: false)
    }

    // MARK: UI construction

    private func buildUI() {
        let movieRulesStack = NSStackView()
        movieRulesStack.translatesAutoresizingMaskIntoConstraints = false
        movieRulesStack.orientation = .vertical
        movieRulesStack.alignment = .leading
        movieRulesStack.spacing = 4
        self.movieRulesStack = movieRulesStack

        let addMovieRuleButton = NSButton(title: NSLocalizedString("Add Rule", comment: "Filename prefs add-naming-rule button"),
                                           target: self, action: #selector(addMovieRuleTapped(_:)))
        addMovieRuleButton.bezelStyle = .rounded
        addMovieRuleButton.translatesAutoresizingMaskIntoConstraints = false

        let tvShowRulesStack = NSStackView()
        tvShowRulesStack.translatesAutoresizingMaskIntoConstraints = false
        tvShowRulesStack.orientation = .vertical
        tvShowRulesStack.alignment = .leading
        tvShowRulesStack.spacing = 4
        self.tvShowRulesStack = tvShowRulesStack

        let addTVShowRuleButton = NSButton(title: NSLocalizedString("Add Rule", comment: "Filename prefs add-naming-rule button"),
                                            target: self, action: #selector(addTVShowRuleTapped(_:)))
        addTVShowRuleButton.bezelStyle = .rounded
        addTVShowRuleButton.translatesAutoresizingMaskIntoConstraints = false

        // Keeps the file's enclosing folder named to match whenever the
        // file itself gets renamed on save (see
        // Document.ensureOwnFolder(fileURL:targetName:)) --
        // e.g. "Title (Year)/Title (Year).mp4", a Plex/iTunes-style
        // one-folder-per-movie layout. Off by default (Prefs.swift).
        let syncMovieFolderNameCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Keep the containing folder named to match", comment: "Filename prefs Movie checkbox"),
                                                    target: self, action: #selector(toggleSyncMovieFolderName(_:)))
        syncMovieFolderNameCheckbox.state = Prefs.syncMovieFolderNameOnSave ? .on : .off
        syncMovieFolderNameCheckbox.translatesAutoresizingMaskIntoConstraints = false
        syncMovieFolderNameCheckbox.toolTip = NSLocalizedString("Only renames a folder that already belongs to just this one movie -- never a folder shared with other, unrelated files.", comment: "")

        // Nests a saved/queued episode under "<TV Show>/Season NN/" (see
        // Document.nestIntoSubfolders(fileURL:subfolderPath:) and
        // QueueSetOutputFilenameAction), the layout Apple's TV app and
        // Plex both expect for a TV library. Off by default (Prefs.swift).
        let useAppleTVStyleTVFoldersCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Organize into Show/Season folders (Apple TV style)", comment: "Filename prefs TV Shows checkbox"),
                                                         target: self, action: #selector(toggleUseAppleTVStyleTVFolders(_:)))
        useAppleTVStyleTVFoldersCheckbox.state = Prefs.useAppleTVStyleTVFolders ? .on : .off
        useAppleTVStyleTVFoldersCheckbox.translatesAutoresizingMaskIntoConstraints = false
        useAppleTVStyleTVFoldersCheckbox.toolTip = NSLocalizedString("Only ever creates new Show/Season subfolders and moves the episode into them -- never renames or touches an existing folder.", comment: "")

        // Movies and TV Shows each get their own tab rather than being
        // stacked one above the other on one page -- the tab's own label
        // ("Movies"/"TV Shows") is what used to be a separate bold header
        // line above each section.
        let movieTabContent = NSStackView(views: [movieRulesStack, addMovieRuleButton, syncMovieFolderNameCheckbox])
        movieTabContent.translatesAutoresizingMaskIntoConstraints = false
        movieTabContent.orientation = .vertical
        movieTabContent.alignment = .leading
        movieTabContent.spacing = 10
        movieTabContent.edgeInsets = NSEdgeInsets(top: 16, left: 2, bottom: 16, right: 2)

        let tvShowTabContent = NSStackView(views: [tvShowRulesStack, addTVShowRuleButton, useAppleTVStyleTVFoldersCheckbox])
        tvShowTabContent.translatesAutoresizingMaskIntoConstraints = false
        tvShowTabContent.orientation = .vertical
        tvShowTabContent.alignment = .leading
        tvShowTabContent.spacing = 10
        tvShowTabContent.edgeInsets = NSEdgeInsets(top: 16, left: 2, bottom: 16, right: 2)

        let movieTabViewItem = NSTabViewItem(identifier: "movie")
        movieTabViewItem.label = NSLocalizedString("Movies", comment: "Filename prefs tab")
        movieTabViewItem.view = movieTabContent

        let tvShowTabViewItem = NSTabViewItem(identifier: "tvShow")
        tvShowTabViewItem.label = NSLocalizedString("TV Shows", comment: "Filename prefs tab")
        tvShowTabViewItem.view = tvShowTabContent

        // Small control size + NSTabView (not a manually-positioned
        // NSSegmentedControl) to match MovieView.xib's Metadata/Artwork
        // tab view exactly -- AppKit centers a tab view's own tab buttons
        // for free, which a segmented control pinned to a leading-edge
        // constraint does not.
        let tabView = NSTabView()
        tabView.controlSize = .small
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self
        tabView.addTabViewItem(movieTabViewItem)
        tabView.addTabViewItem(tvShowTabViewItem)

        let headerLabel = NSTextField(labelWithString: NSLocalizedString("Filename", comment: "Filename prefs header"))
        headerLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let descriptionLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("Set the format to create a custom filename in the Save As\u{2026} panel and in the queue. Each rule's checkbox enables or disables it. A conditional rule's own name is used instead of the default whenever all of its conditions match the file's metadata.", comment: ""))
        descriptionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.preferredMaxLayoutWidth = 620

        let mainStack = NSStackView(views: [headerLabel, descriptionLabel, tabView])
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.setCustomSpacing(4, after: headerLabel)

        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            mainStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            tabView.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor)
        ])
    }

    // MARK: Per-section helpers (see RuleSection above)

    private func rules(for section: RuleSection) -> [NamingRule] {
        switch section {
        case .movie: return movieRules
        case .tvShow: return tvShowRules
        }
    }

    private func setRules(_ rules: [NamingRule], for section: RuleSection) {
        switch section {
        case .movie:
            movieRules = rules
            MetadataPrefs.movieNamingRules = rules
        case .tvShow:
            tvShowRules = rules
            MetadataPrefs.tvShowNamingRules = rules
        }
    }

    private func rulesStack(for section: RuleSection) -> NSStackView {
        switch section {
        case .movie: return movieRulesStack
        case .tvShow: return tvShowRulesStack
        }
    }

    private func rebuildRuleRows(for section: RuleSection) {
        let stack = rulesStack(for: section)

        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let currentRules = rules(for: section)

        for (index, rule) in currentRules.enumerated() {
            let row = RuleRowView(rule: rule, isDefaultRow: rule.isDefault, index: index, mediaKind: section.mediaKind, showsDivider: index < currentRules.count - 1)

            row.onChange = { [weak self] updated in
                guard let self = self else { return }
                var r = self.rules(for: section)
                guard index < r.count else { return }
                r[index] = updated
                self.setRules(r, for: section)
                // A plain field edit can still change this row's height
                // without adding or removing a whole row -- most notably
                // the Name: token field wrapping onto another line as
                // more tokens are added to it. resizeWindowToFitContent()
                // is a cheap no-op when nothing actually changed size, so
                // it's safe to call on every edit rather than only on the
                // structural add/remove-condition changes below.
                self.resizeWindowToFitContent()
            }

            if rule.isDefault == false {
                row.onStructureChange = { [weak self] updated in
                    guard let self = self else { return }
                    var r = self.rules(for: section)
                    guard index < r.count else { return }
                    r[index] = updated
                    self.setRules(r, for: section)
                    self.rebuildRuleRows(for: section)
                }
                row.onRemoveRule = { [weak self] in
                    self?.removeRule(at: index, in: section)
                }
            }

            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        resizeWindowToFitContent()
    }

    private func resizeWindowToFitContent(adjustWidth: Bool = true) {
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize

        guard let window = view.window else {
            let width = adjustWidth ? max(fitting.width, 640) : view.frame.width
            view.setFrameSize(NSSize(width: width, height: fitting.height))
            return
        }

        let contentRect = window.contentRect(forFrameRect: window.frame)
        let width = adjustWidth ? max(fitting.width, 640) : contentRect.width
        guard abs(contentRect.height - fitting.height) > 0.5 || abs(contentRect.width - width) > 0.5 else { return }

        var frame = window.frame
        let deltaHeight = fitting.height - contentRect.height
        let deltaWidth = width - contentRect.width
        frame.size.height += deltaHeight
        frame.origin.y -= deltaHeight
        frame.size.width += deltaWidth
        frame.origin.x -= deltaWidth / 2

        // Growing upward (above) can walk the window's top edge off the
        // top of the screen when a rule picks up several more
        // conditions in a row -- the window ends up genuinely taller,
        // but part of it renders past the visible screen and reads as
        // "doesn't fit"/cut off. Keep the whole window on the screen it's
        // currently on by sliding it back down (and, in the pathological
        // case of content taller than the screen itself, capping the
        // height so at least the window itself is fully on screen rather
        // than silently extending past both edges).
        if let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
            if frame.size.height > screenFrame.height {
                frame.size.height = screenFrame.height
            }
            if frame.origin.y + frame.size.height > screenFrame.maxY {
                frame.origin.y = screenFrame.maxY - frame.size.height
            }
            if frame.origin.y < screenFrame.minY {
                frame.origin.y = screenFrame.minY
            }
            if frame.size.width > screenFrame.width {
                frame.size.width = screenFrame.width
            }
            if frame.origin.x < screenFrame.minX {
                frame.origin.x = screenFrame.minX
            }
            if frame.origin.x + frame.size.width > screenFrame.maxX {
                frame.origin.x = screenFrame.maxX - frame.size.width
            }
        }

        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    // MARK: Actions

    @objc private func addMovieRuleTapped(_ sender: Any?) {
        addRule(for: .movie)
    }

    @objc private func addTVShowRuleTapped(_ sender: Any?) {
        addRule(for: .tvShow)
    }

    @objc private func toggleSyncMovieFolderName(_ sender: NSButton) {
        Prefs.syncMovieFolderNameOnSave = sender.state == .on
    }

    @objc private func toggleUseAppleTVStyleTVFolders(_ sender: NSButton) {
        Prefs.useAppleTVStyleTVFolders = sender.state == .on
    }

    private func addRule(for section: RuleSection) {
        let newRule = NamingRule(conditions: [NamingCondition(field: MP42MetadataKeyRating, op: .equals, value: "")],
                                  tokens: [Token(text: "{Name}")])
        var r = rules(for: section)
        r.append(newRule)
        setRules(r, for: section)
        rebuildRuleRows(for: section)
    }

    private func removeRule(at index: Int, in section: RuleSection) {
        var r = rules(for: section)
        guard index < r.count, r[index].isDefault == false else { return }
        r.remove(at: index)
        setRules(r, for: section)
        rebuildRuleRows(for: section)
    }

}

private extension NSBox {
    static func separatorBox() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 560).isActive = true
        return box
    }
}
