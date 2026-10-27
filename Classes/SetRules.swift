//
//  SetRules.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//
//  Sets that load by rule: "if Content Rating is NC-17 (or Explicit), apply the
//  Adult Set". Works like the Media Locations rules: an ordered list, each rule
//  with its own enable checkbox and "If <field> <operator> <value>" conditions
//  (the same NamingCondition type), but a rule picks a Metadata Set instead of
//  a folder. The first enabled rule whose conditions all match the file's
//  tagged metadata decides the Set. The Queue applies it after the online
//  search, so the Set's values win over what the search found, the same as a
//  Set chosen in the Queue options.
//

import Cocoa
import MP42Foundation

struct SetRule: Codable {
    var conditions: [NamingCondition]
    /// The title of the Metadata Set to apply.
    var setName: String
    var isEnabled: Bool

    init(conditions: [NamingCondition], setName: String = "", isEnabled: Bool = true) {
        self.conditions = conditions
        self.setName = setName
        self.isEnabled = isEnabled
    }

    /// Same AND-across-fields / OR-within-a-field grouping as a naming rule.
    func matches(metadata: MP42Metadata) -> Bool {
        guard conditions.isEmpty == false else { return false }
        return NamingRule(conditions: conditions, tokens: []).matches(metadata: metadata)
    }
}

enum SetRules {

    private static let key = "SBSetRules"

    static var rules: [SetRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([SetRule].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    /// True when at least one enabled rule names a Set.
    static var hasEnabledRules: Bool {
        return rules.contains { $0.isEnabled && $0.setName.isEmpty == false }
    }

    /// The Set name of the first enabled rule whose conditions all match.
    static func matchingSetName(in rules: [SetRule], metadata: MP42Metadata) -> String? {
        for rule in rules where rule.isEnabled && rule.setName.isEmpty == false {
            if rule.matches(metadata: metadata) { return rule.setName }
        }
        return nil
    }

    /// The Metadata Set the rules pick for this metadata, if it still exists.
    static func preset(for metadata: MP42Metadata) -> MetadataPreset? {
        guard let name = matchingSetName(in: rules, metadata: metadata) else { return nil }
        return PresetManager.shared.item(name: name) as? MetadataPreset
    }
}

/// Queue action: applies the Set the rules pick for the file's tagged metadata
/// (nothing when no rule matches). Runs after the online search.
class QueueSetRulesAction: NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Applying a Set by rule", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Apply a Set by rule", comment: "Action description") }

    override init() {
        super.init()
    }

    func runAction(_ item: QueueItem) -> Bool {
        guard let metadata = item.mp4File?.metadata else { return true }
        guard let preset = SetRules.preset(for: metadata) else { return true }
        return QueueSetAction(preset: preset, setWins: true).runAction(item)
    }

    func encode(with aCoder: NSCoder) {
    }

    required init?(coder aDecoder: NSCoder) {
        super.init()
    }

    static var supportsSecureCoding: Bool { return true }
}

/// The sheet opened by "Set Rules..." on the Sets tab: the list of rules.
final class SetRulesViewController: NSViewController {

    private var rules = SetRules.rules
    private var rulesStack = NSStackView()

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let header = NSTextField(labelWithString: NSLocalizedString("Set Rules", comment: "Set rules sheet title"))
        header.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let description = NSTextField(wrappingLabelWithString: NSLocalizedString("A rule applies a Metadata Set when a file\u{2019}s tagged metadata matches its conditions, for example Content Rating is Explicit, or Rating is NC-17, applies your Adult Set. The first enabled rule that matches is used. The Set is applied after the online search, so its values win.", comment: "Set rules sheet description"))
        description.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        description.textColor = .secondaryLabelColor
        description.preferredMaxLayoutWidth = 700

        rulesStack.orientation = .vertical
        rulesStack.alignment = .leading
        rulesStack.spacing = 4
        rulesStack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedClipDocumentView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(rulesStack)
        NSLayoutConstraint.activate([
            rulesStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            rulesStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            rulesStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            rulesStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor)
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = flipped
        scroll.translatesAutoresizingMaskIntoConstraints = false
        flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let addButton = NSButton(title: NSLocalizedString("Add Rule", comment: "Set rules add button"), target: self, action: #selector(addRule(_:)))
        addButton.bezelStyle = .rounded
        let doneButton = NSButton(title: NSLocalizedString("Done", comment: "Set rules done button"), target: self, action: #selector(done(_:)))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let spacer = NSView()
        let buttons = NSStackView(views: [addButton, spacer, doneButton])
        buttons.orientation = .horizontal

        let content = NSStackView(views: [header, description, scroll, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        view.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            view.widthAnchor.constraint(equalToConstant: 760),
            view.heightAnchor.constraint(equalToConstant: 460)
        ])

        rebuildRows()
    }

    private func save() {
        SetRules.rules = rules
    }

    private func rebuildRows() {
        for subview in rulesStack.arrangedSubviews {
            rulesStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        if rules.isEmpty {
            let empty = NSTextField(labelWithString: NSLocalizedString("No rules yet. Choose Add Rule.", comment: "Set rules empty text"))
            empty.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            empty.textColor = .secondaryLabelColor
            rulesStack.addArrangedSubview(empty)
        }

        let setNames = PresetManager.shared.metadataPresets.map { $0.title }

        for (index, rule) in rules.enumerated() {
            // The row view is shared with the Media Locations rules; the Set's
            // name travels in the folder-path slot of a DeliveryRule.
            let shared = DeliveryRule(conditions: rule.conditions, folderPath: rule.setName, isEnabled: rule.isEnabled)
            let row = DeliveryRuleRowView(rule: shared, mediaKind: .movie, showsDivider: index < rules.count - 1, setNames: setNames)

            row.onChange = { [weak self] updated in
                self?.update(index, from: updated)
            }
            row.onStructureChange = { [weak self] updated in
                self?.update(index, from: updated)
                self?.rebuildRows()
            }
            row.onRemoveRule = { [weak self] in
                guard let self = self, index < self.rules.count else { return }
                self.rules.remove(at: index)
                self.save()
                self.rebuildRows()
            }

            rulesStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: rulesStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: rulesStack.trailingAnchor).isActive = true
        }
    }

    private func update(_ index: Int, from updated: DeliveryRule) {
        guard index < rules.count else { return }
        rules[index] = SetRule(conditions: updated.conditions, setName: updated.folderPath, isEnabled: updated.isEnabled)
        save()
    }

    @objc private func addRule(_ sender: Any?) {
        let firstSet = PresetManager.shared.metadataPresets.first?.title ?? ""
        rules.append(SetRule(conditions: [NamingCondition(field: MP42MetadataKeyContentRating, op: .equals, value: "")], setName: firstSet))
        save()
        rebuildRows()
    }

    @objc private func done(_ sender: Any?) {
        save()
        dismiss(nil)
    }
}

/// A scroll view's document view that lays out from the top.
private final class FlippedClipDocumentView: NSView {
    override var isFlipped: Bool { return true }
}
