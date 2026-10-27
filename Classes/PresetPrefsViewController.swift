//
//  PresetPrefsViewController.swift
//  Subler
//
//  Created by Damiano Galassi on 20/08/2017.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Sets tab heading and description, Settings tool, usability fixes. Includes
//  later upstream undo/redo changes ported by hand.
//

import Cocoa

class PresetPrefsViewController: NSViewController, SectionsTableViewDataSource, SectionsTableViewDelegate, NSTextFieldDelegate {

    let presetManager: PresetManager

    @IBOutlet var tableView: SectionsTableView!
    @IBOutlet var removeSetButton: NSButton!
    @IBOutlet var editSetButton: NSButton!

    var controller: PresetEditorViewController?
    var observer: Any?

    override var nibName: NSNib.Name? {
        return "PresetPrefsViewController"
    }

    init() {
        self.presetManager = PresetManager.shared
        super.init(nibName: nil, bundle: nil)
        self.title = NSLocalizedString("Sets", comment: "")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self

        addIntroduction()

        tableView.reloadData()

        observer = NotificationCenter.default.addObserver(forName: PresetManager.updateNotification,
                                                          object: nil,
                                                          queue: OperationQueue.main) { [weak self] notification in
                                                            guard let s = self else { return }
                                                            s.tableView.reloadData()
                                                            s.updateControlsState()
        }
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    /// A heading and short description above the list, laid out like the
    /// other Settings tabs. The list itself comes from the nib; its top
    /// edge is moved from the top of the view to below this text.
    private func addIntroduction() {
        guard let scrollView = tableView.enclosingScrollView else { return }

        let headerLabel = NSTextField(labelWithString: NSLocalizedString("Sets", comment: "Sets prefs header"))
        headerLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        let descriptionLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("A Set is a saved group of settings you can reuse. Metadata sets hold tag values, such as genre, studio or rating, that you can apply to a file from its edit window. Queue sets hold a whole group of Queue options, so a run can be repeated the same way. Choose a set in the Queue options and it is applied to every item automatically, which makes sets a handy step in a workflow: add files, and each one is tagged the same way as it is processed.", comment: "Sets prefs description"))
        descriptionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.preferredMaxLayoutWidth = 520

        let rulesButton = NSButton(title: NSLocalizedString("Set Rules\u{2026}", comment: "Sets prefs button"), target: self, action: #selector(showSetRules(_:)))
        rulesButton.bezelStyle = .rounded
        rulesButton.translatesAutoresizingMaskIntoConstraints = false
        rulesButton.toolTip = NSLocalizedString("Choose which Set is applied automatically when a file\u{2019}s tags match a rule, for example an Adult Set for explicit content.", comment: "Sets prefs button tooltip")

        view.addSubview(headerLabel)
        view.addSubview(descriptionLabel)
        view.addSubview(rulesButton)

        for constraint in view.constraints where constraint.firstItem === scrollView && constraint.firstAttribute == .top {
            constraint.isActive = false
        }

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            rulesButton.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),
            rulesButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            descriptionLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            descriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 12)
        ])
    }

    @objc private func showSetRules(_ sender: Any?) {
        presentAsSheet(SetRulesViewController())
    }

    // MARK: Table View with sections

    func numberOfSections(in tableView: NSTableView) -> Int { return 2 }

    func tableView(_ tableView: NSTableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return presetManager.metadataPresets.count
        } else {
            return presetManager.queuePresets.count
        }
    }

    func tableView(_ tableView: NSTableView, viewForHeaderInSection section: Int) -> NSView? {
        if let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("headerCell"), owner: self) as? NSTableCellView {
            cell.textField?.stringValue = NSLocalizedString(section == 0 ? "Metadata" : "Queue", comment: "")
            cell.textField?.isSelectable = false
            cell.textField?.isEditable = false
            return cell
        }
        return nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: (section: Int, sectionRow: Int)) -> NSView? {
        if tableColumn?.identifier == NSUserInterfaceItemIdentifier("name"),
            let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("nameCell"), owner: self) as? NSTableCellView {
            cell.textField?.stringValue = preset(for: row)?.title ?? "Null"
            cell.textField?.isSelectable = true
            cell.textField?.isEditable = true
            return cell
        }

        return nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControlsState()
    }

    private func updateControlsState() {
        removeSetButton.isEnabled = tableView.selectedRow != -1
        editSetButton.isEnabled = tableView.selectedRow != -1
    }

    // MARK: UI Actions

    private func preset(for row: (section: Int, sectionRow: Int)) -> Preset? {
        switch row.section {
        case 0:
            return presetManager.metadataPresets[row.sectionRow]
        case 1:
            return presetManager.queuePresets[row.sectionRow]
        default:
            return nil
        }
    }

    private func rename(preset: Preset, to title: String) {
        if title.isEmpty == false && preset.title != title {

            let copy = preset.copy() as! MetadataPreset
            copy.title = title

            do {
                try presetManager.append(newElement: copy)
                try presetManager.remove(item: preset)
            }
            catch {
                view.window?.presentError(error)
            }
        }

        tableView.reloadData()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let view = obj.object as? NSTextField {
            let row = tableView.row(for: view)
            let sectionRow = tableView.section(for: row)
            if let preset = preset(for: sectionRow) {
                rename(preset: preset, to: view.stringValue)
            }
        }
    }

    @IBAction func addPreset(_ sender: Any) {
        var index = 0
        while true {
            let preset = MetadataPreset(title: "Untitled Preset \(index)")
            do {
                try presetManager.append(newElement: preset)
                break
            } catch PresetManager.Error.alreadyExists {
                // Only reason to retry with a new name -- try the next
                // "Untitled Preset N". Any other error (disk full,
                // missing/unwritable Application Support folder, etc.)
                // would fail identically on every retry, so looping on it
                // just spins the main thread forever with the window
                // appearing to have locked up.
                index += 1
            } catch {
                view.window?.presentError(error)
                break
            }
        }
    }

    @IBAction func deletePreset(_ sender: Any) {
        let rowIndexes = tableView.selectedRowIndexes
        let rowIndex = tableView.selectedRow
        let sectionRow = tableView.section(for: rowIndex)

        if let preset = self.preset(for: sectionRow) {
            do {
                try presetManager.remove(item: preset)
            } catch {
                view.window?.presentError(error)
            }
        }

        let count = presetManager.metadataPresets.count + presetManager.queuePresets.count
        if let index = rowIndexes.last, index < count {
            tableView.selectRowIndexes(rowIndexes, byExtendingSelection: false)
        }
    }

    @IBAction func editPreset(_ sender: NSView) {
        let rowIndex = tableView.selectedRow
        let sectionRow = tableView.section(for: rowIndex)
        let preset = self.preset(for: sectionRow)

        switch preset {
        case let preset as MetadataPreset:
            controller = PresetEditorViewController.init(preset: preset)
            presentAsSheet(controller!)
        case _ as QueuePreset:
            // TODO
            break
        default:
            break
        }

    }

}
