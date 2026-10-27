//
//  DestinationsViewController.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/10/2026.
//
//  The "Media Locations" tab (in Settings > Sources): where a finished
//  file is delivered. The default destination is the Automatically Add to
//  iTunes/TV folder(s); Movies and TV Shows each have their own ordered
//  list of delivery rules, built like the
//  Filename tab's naming rules -- an enable checkbox per rule and
//  "If <field> <operator> <value>" conditions on the file's tagged
//  metadata -- except that a rule chooses a destination folder. The first
//  enabled rule that matches wins; otherwise the default folder is used.
//  See DeliveryRules.swift for the engine.
//

import Cocoa
import MP42Foundation

// MARK: - A folder path row

/// [path field] [Choose…], reporting the typed or chosen folder (nil when
/// the field is empty). The field can be typed or pasted into directly.
private final class FolderPathRow: NSStackView, NSTextFieldDelegate {

    let field = NSTextField()
    var onChange: ((String) -> Void)?

    init(path: String, placeholder: String, width: CGFloat) {
        super.init(frame: .zero)

        field.stringValue = path
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true

        let choose = NSButton(title: NSLocalizedString("Choose\u{2026}", comment: ""), target: self, action: #selector(chooseClicked(_:)))
        choose.bezelStyle = .rounded
        choose.translatesAutoresizingMaskIntoConstraints = false

        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(field)
        addArrangedSubview(choose)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func chooseClicked(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.field.stringValue = url.path
            self.onChange?(url.path)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        onChange?(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - A single delivery rule row

final class DeliveryRuleRowView: NSView, NSTextFieldDelegate, NSComboBoxDelegate {

    private(set) var rule: DeliveryRule
    let mediaKind: MediaKind
    /// When set, the row picks a Metadata Set from this list (Set Rules, see
    /// SetRules.swift) instead of a folder; the chosen name is kept in
    /// `rule.folderPath`.
    private let setNames: [String]?

    /// A value changed that doesn't add or remove rows -- just persist.
    var onChange: ((DeliveryRule) -> Void)?
    /// A condition was added or removed -- persist and rebuild the row.
    var onStructureChange: ((DeliveryRule) -> Void)?
    /// The rule was removed (its remove button, or its last condition).
    var onRemoveRule: (() -> Void)?

    private static let conditionFields: [String] = MP42Metadata.writableMetadata

    private struct ConditionControls {
        let fieldPopup: NSPopUpButton
        let operatorPopup: NSPopUpButton
        let valueField: NSComboBox
    }
    private var conditionControls: [ConditionControls] = []

    init(rule: DeliveryRule, mediaKind: MediaKind, showsDivider: Bool, setNames: [String]? = nil) {
        self.rule = rule
        self.mediaKind = mediaKind
        self.setNames = setNames
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(showsDivider: showsDivider)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI(showsDivider: Bool) {
        conditionControls = []

        var rows: [NSView] = [setNames == nil ? folderRow() : setRow()]
        for index in rule.conditions.indices {
            rows.append(conditionRow(at: index))
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

    private func setRow() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
        checkbox.state = rule.isEnabled ? .on : .off
        checkbox.toolTip = NSLocalizedString("When off, this rule is skipped as if it weren't in the list.", comment: "Set rule checkbox tooltip")

        let label = NSTextField(labelWithString: NSLocalizedString("Apply Set:", comment: "Set rule label"))
        label.translatesAutoresizingMaskIntoConstraints = false

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        var names = setNames ?? []
        // A Set that was deleted after the rule was made stays visible.
        if rule.folderPath.isEmpty == false, names.contains(rule.folderPath) == false { names.append(rule.folderPath) }
        popup.addItems(withTitles: names)
        if names.isEmpty {
            popup.addItem(withTitle: NSLocalizedString("No Sets yet", comment: "Set rule popup when no Sets exist"))
            popup.isEnabled = false
        } else if let index = names.firstIndex(of: rule.folderPath) {
            popup.selectItem(at: index)
        }
        popup.target = self
        popup.action = #selector(setChosen(_:))

        let removeButton = NSButton(title: NSLocalizedString("Remove Rule", comment: "Delivery rule remove button"),
                                    target: self, action: #selector(removeRuleTapped(_:)))
        removeButton.bezelStyle = .rounded
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [checkbox, label, popup, removeButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    @objc private func setChosen(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        rule.folderPath = title
        onChange?(rule)
    }

    private func folderRow() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxToggled(_:)))
        checkbox.state = rule.isEnabled ? .on : .off
        checkbox.toolTip = NSLocalizedString("When off, this rule is skipped as if it weren't in the list.", comment: "Delivery rule checkbox tooltip")

        let label = NSTextField(labelWithString: NSLocalizedString("Folder:", comment: "Delivery rule folder label"))
        label.translatesAutoresizingMaskIntoConstraints = false

        let pathRow = FolderPathRow(path: rule.folderPath,
                                    placeholder: NSLocalizedString("Choose or type a folder path", comment: ""),
                                    width: 380)
        pathRow.onChange = { [weak self] path in
            guard let self = self else { return }
            self.rule.folderPath = path
            self.onChange?(self.rule)
        }

        let removeButton = NSButton(title: NSLocalizedString("Remove Rule", comment: "Delivery rule remove button"),
                                    target: self, action: #selector(removeRuleTapped(_:)))
        removeButton.bezelStyle = .rounded
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [checkbox, label, pathRow, removeButton])
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

        // Same grouping as a naming rule: a condition on the same field as
        // the one above it is OR'd with it, otherwise AND'd.
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
        fieldPopup.addItems(withTitles: DeliveryRuleRowView.conditionFields.map { localizedMetadataKeyName($0) })
        if let fieldIndex = DeliveryRuleRowView.conditionFields.firstIndex(of: condition.field) {
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

    private func populateAutocomplete(_ comboBox: NSComboBox, field: String) {
        comboBox.removeAllItems()
        let values = field == MP42MetadataKeyRating
            ? Ratings.conditionAutocompleteValues(mediaKind: mediaKind)
            : (NamingCondition.fixedValues(for: field) ?? MetadataPrefs.namingConditionValueHistory[field] ?? [])
        comboBox.addItems(withObjectValues: values)
    }

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

    // MARK: Actions

    @objc private func checkboxToggled(_ sender: NSButton) {
        rule.isEnabled = sender.state == .on
        onChange?(rule)
    }

    @objc private func removeRuleTapped(_ sender: NSButton) {
        onRemoveRule?()
    }

    @objc private func fieldChanged(_ sender: NSPopUpButton) {
        let conditionIndex = sender.tag
        guard conditionIndex < rule.conditions.count else { return }
        let newField = DeliveryRuleRowView.conditionFields[sender.indexOfSelectedItem]
        rule.conditions[conditionIndex].field = newField
        if conditionIndex < conditionControls.count {
            populateAutocomplete(conditionControls[conditionIndex].valueField, field: newField)
        }
        // May turn an AND into an OR (or back), so the "And"/"Or" prefixes need a rebuild.
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
        let usedFields = Set(rule.conditions.map { $0.field })
        let defaultField = DeliveryRuleRowView.conditionFields.first { usedFields.contains($0) == false } ?? MP42MetadataKeyRating
        rule.conditions.append(NamingCondition(field: defaultField, op: .equals, value: ""))
        onStructureChange?(rule)
    }

    @objc private func removeConditionTapped(_ sender: NSButton) {
        let conditionIndex = sender.tag
        guard conditionIndex < rule.conditions.count else { return }
        rule.conditions.remove(at: conditionIndex)
        if rule.conditions.isEmpty {
            onRemoveRule?()
        } else {
            onStructureChange?(rule)
        }
    }

    // MARK: NSTextFieldDelegate / NSComboBoxDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        for (conditionIndex, controls) in conditionControls.enumerated() where field === controls.valueField {
            guard conditionIndex < rule.conditions.count else { return }
            rule.conditions[conditionIndex].value = field.stringValue
            if rule.conditions[conditionIndex].field != MP42MetadataKeyRating,
               NamingCondition.fixedValues(for: rule.conditions[conditionIndex].field) == nil {
                MetadataPrefs.recordNamingConditionValue(field.stringValue, for: rule.conditions[conditionIndex].field)
            }
            onChange?(rule)
            return
        }
    }

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

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox else { return }
        // The combo's stringValue is not updated yet when this fires.
        for (conditionIndex, controls) in conditionControls.enumerated() where combo === controls.valueField {
            guard conditionIndex < rule.conditions.count, combo.indexOfSelectedItem >= 0,
                  let selected = combo.itemObjectValue(at: combo.indexOfSelectedItem) as? String else { return }
            rule.conditions[conditionIndex].value = selected
            onChange?(rule)
            return
        }
    }
}

// MARK: - Destinations tab

final class DestinationsViewController: NSViewController, NSTabViewDelegate {

    private enum Section {
        case movie
        case tvShow

        var mediaKind: MediaKind {
            switch self {
            case .movie: return .movie
            case .tvShow: return .tvShow
            }
        }
    }

    private var movieRules = MediaIntakePrefs.movieDeliveryRules
    private var tvShowRules = MediaIntakePrefs.tvDeliveryRules

    private var movieRulesStack: NSStackView!
    private var tvShowRulesStack: NSStackView!

    override func loadView() {
        // Placeholder first; the real construction happens in viewDidLoad
        // (same reason as the other prefs panes: building the tab view
        // reads `view`).
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        rebuildRuleRows(for: .movie)
        rebuildRuleRows(for: .tvShow)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        notifyLayoutChange()
    }

    private func notifyLayoutChange() {
        view.layoutSubtreeIfNeeded()
        (parent as? SourcesPrefsViewController)?.contentSizeDidChange()
    }

    // MARK: UI construction

    private func buildUI() {
        let headerLabel = NSTextField(labelWithString: NSLocalizedString("Media Locations", comment: ""))
        headerLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let descriptionLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("Where a finished file goes. With automatic delivery on, a movie is checked against the Movies rules and a TV episode against the TV Shows rules (decided by its Media Kind tag, so no rule is needed for that). It goes to the first enabled rule whose conditions all match its tagged metadata, and otherwise to the default destination. With it off, every finished file waits in the staging folder for you to look over first.", comment: ""))
        descriptionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.preferredMaxLayoutWidth = 620

        // Default destination: the iTunes / Apple TV "Automatically Add"
        // folders. A file delivered straight into one is left alone instead
        // of being wrapped in a folder of its own.
        let ingestTitleLabel = NSTextField(labelWithString: NSLocalizedString("Default destination: Apple TV Automatically Add Folders", comment: ""))
        ingestTitleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        ingestTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let ingestDescriptionLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("Leave the first row blank to follow the Media folder location in the Apple TV app\u{2019}s own settings, so it keeps working if you change it there. Add more if you keep several libraries; the first row is the default.", comment: ""))
        ingestDescriptionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ingestDescriptionLabel.textColor = .secondaryLabelColor
        ingestDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        ingestDescriptionLabel.preferredMaxLayoutWidth = 620

        let ingestList = FolderListView()
        // Shown greyed-out in the first row while nothing is set, so the
        // user can see where files will actually land by default.
        ingestList.placeholder = MediaIntakePrefs.defaultAutomaticMediaIngestFolderURL()?.path
            ?? NSLocalizedString("Not Set", comment: "")
        ingestList.implicitDefault = MediaIntakePrefs.defaultAutomaticMediaIngestFolderURL()
        ingestList.onChange = { MediaIntakePrefs.automaticMediaIngestFolders = $0 }
        ingestList.onFirstRowBlankChange = { MediaIntakePrefs.ingestListFollowsAppleTV = $0 }
        ingestList.onLayoutChange = { [weak self] in self?.notifyLayoutChange() }
        ingestList.setFolders(MediaIntakePrefs.automaticMediaIngestFolders,
                              leadingBlankRow: MediaIntakePrefs.ingestListFollowsAppleTV)
        ingestList.toolTip = NSLocalizedString("A file delivered straight into one of these folders is left alone instead of being wrapped in its own folder, since the Apple TV app ingests and organizes it from there itself.", comment: "")

        // Rules, one list per media kind.
        let rulesTitleLabel = NSTextField(labelWithString: NSLocalizedString("Rules (checked in order, first match wins; anything else goes to the default destination)", comment: ""))
        rulesTitleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        rulesTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        movieRulesStack = makeRulesStack()
        tvShowRulesStack = makeRulesStack()

        let movieContent = makeTabContent(rulesStack: movieRulesStack, addAction: #selector(addMovieRuleTapped(_:)))
        let tvContent = makeTabContent(rulesStack: tvShowRulesStack, addAction: #selector(addTVShowRuleTapped(_:)))

        let movieTabViewItem = NSTabViewItem(identifier: "movie")
        movieTabViewItem.label = NSLocalizedString("Movies", comment: "Media Locations tab")
        movieTabViewItem.view = movieContent

        let tvTabViewItem = NSTabViewItem(identifier: "tvShow")
        tvTabViewItem.label = NSLocalizedString("TV Shows", comment: "Media Locations tab")
        tvTabViewItem.view = tvContent

        let tabView = NSTabView()
        tabView.controlSize = .small
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self
        tabView.addTabViewItem(movieTabViewItem)
        tabView.addTabViewItem(tvTabViewItem)

        // Staging and the automatic delivery switch.
        let stagingTitleLabel = NSTextField(labelWithString: NSLocalizedString("Staging folder (Ready for Media Library)", comment: ""))
        stagingTitleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        stagingTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stagingRow = FolderPathRow(path: MediaIntakePrefs.readyForLibraryFolder?.path ?? "",
                                       placeholder: NSLocalizedString("Not Set", comment: ""),
                                       width: 440)
        stagingRow.onChange = { path in
            MediaIntakePrefs.readyForLibraryFolder = path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        stagingRow.field.toolTip = NSLocalizedString("Where finished files wait for you to look through them before they reach the library.", comment: "")

        let autoCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Deliver automatically: skip the staging folder and send finished files straight to their destination", comment: ""),
                                    target: self, action: #selector(deliverAutomaticallyToggled(_:)))
        autoCheckbox.state = MediaIntakePrefs.deliverAutomatically ? .on : .off
        autoCheckbox.translatesAutoresizingMaskIntoConstraints = false
        autoCheckbox.toolTip = NSLocalizedString("Off: finished files go to the staging folder so you can check them first. On: they go to the first matching rule's folder, or the default destination. Turn this on once you trust the rules.", comment: "")

        let ingestSection = NSStackView(views: [ingestTitleLabel, ingestDescriptionLabel, ingestList])
        ingestSection.orientation = .vertical
        ingestSection.alignment = .leading
        ingestSection.spacing = 4
        ingestSection.translatesAutoresizingMaskIntoConstraints = false
        ingestList.leadingAnchor.constraint(equalTo: ingestSection.leadingAnchor).isActive = true
        ingestList.trailingAnchor.constraint(equalTo: ingestSection.trailingAnchor).isActive = true

        let stagingSection = NSStackView(views: [stagingTitleLabel, stagingRow, autoCheckbox])
        stagingSection.orientation = .vertical
        stagingSection.alignment = .leading
        stagingSection.spacing = 6
        stagingSection.translatesAutoresizingMaskIntoConstraints = false

        let mainStack = NSStackView(views: [headerLabel, descriptionLabel, ingestSection, rulesTitleLabel, tabView, stagingSection])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
        mainStack.setCustomSpacing(4, after: headerLabel)
        mainStack.setCustomSpacing(18, after: descriptionLabel)
        mainStack.setCustomSpacing(18, after: ingestSection)
        mainStack.setCustomSpacing(4, after: rulesTitleLabel)
        mainStack.setCustomSpacing(20, after: tabView)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            tabView.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor),
            ingestSection.leadingAnchor.constraint(equalTo: mainStack.leadingAnchor),
            ingestSection.trailingAnchor.constraint(equalTo: mainStack.trailingAnchor)
        ])
    }

    private func makeRulesStack() -> NSStackView {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func makeTabContent(rulesStack: NSStackView, addAction: Selector) -> NSView {
        let addButton = NSButton(title: NSLocalizedString("Add Rule", comment: "Media Locations add-rule button"), target: self, action: addAction)
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [rulesStack, addButton])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 16, left: 2, bottom: 16, right: 2)
        return content
    }

    @objc private func deliverAutomaticallyToggled(_ sender: NSButton) {
        MediaIntakePrefs.deliverAutomatically = sender.state == .on
    }

    // MARK: Per-section helpers

    private func rules(for section: Section) -> [DeliveryRule] {
        switch section {
        case .movie: return movieRules
        case .tvShow: return tvShowRules
        }
    }

    private func setRules(_ rules: [DeliveryRule], for section: Section) {
        switch section {
        case .movie:
            movieRules = rules
            MediaIntakePrefs.movieDeliveryRules = rules
        case .tvShow:
            tvShowRules = rules
            MediaIntakePrefs.tvDeliveryRules = rules
        }
    }

    private func rulesStack(for section: Section) -> NSStackView {
        switch section {
        case .movie: return movieRulesStack
        case .tvShow: return tvShowRulesStack
        }
    }

    private func rebuildRuleRows(for section: Section) {
        let stack = rulesStack(for: section)
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let currentRules = rules(for: section)

        if currentRules.isEmpty {
            let empty = NSTextField(labelWithString: NSLocalizedString("No rules yet. Everything goes to the default destination.", comment: ""))
            empty.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            empty.textColor = .secondaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(empty)
        }

        for (index, rule) in currentRules.enumerated() {
            let row = DeliveryRuleRowView(rule: rule, mediaKind: section.mediaKind, showsDivider: index < currentRules.count - 1)

            row.onChange = { [weak self] updated in
                guard let self = self else { return }
                var r = self.rules(for: section)
                guard index < r.count else { return }
                r[index] = updated
                self.setRules(r, for: section)
            }
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

            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        notifyLayoutChange()
    }

    // MARK: Actions

    @objc private func addMovieRuleTapped(_ sender: Any?) {
        addRule(for: .movie)
    }

    @objc private func addTVShowRuleTapped(_ sender: Any?) {
        addRule(for: .tvShow)
    }

    private func addRule(for section: Section) {
        let newRule = DeliveryRule(conditions: [NamingCondition(field: MP42MetadataKeyRating, op: .equals, value: "")])
        var r = rules(for: section)
        r.append(newRule)
        setRules(r, for: section)
        rebuildRuleRows(for: section)
    }

    private func removeRule(at index: Int, in section: Section) {
        var r = rules(for: section)
        guard index < r.count else { return }
        r.remove(at: index)
        setRules(r, for: section)
        rebuildRuleRows(for: section)
    }
}
