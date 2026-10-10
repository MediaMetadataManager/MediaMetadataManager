//
//  MultiProviderSearchResultsWindowController.swift
//  Subler
//
//  Shown by NamingReviewWindowController's "Search All Providers..."
//  button once a multi-provider fan-out search
//  (MetadataSearch.searchAllMovieProviders(title:)) finishes successfully
//  -- lets the user pick among every enabled provider's own best result,
//  rather than just the first one that happened to answer, the way the
//  naming window's own automatic background search already works. See
//  the "Intake/Queue workflow" design doc, section 7c, for the full
//  rationale.
//
//  Built entirely in code (no .xib) -- same reasoning as
//  NamingReviewWindowController and MergeReorderWindowController: a
//  small one-off window with no reason to round-trip through Interface
//  Builder.
//

import Cocoa

final class MultiProviderSearchResultsWindowController: NSWindowController {

    private let hits: [MetadataSearch.ProviderSearchHit]
    private let tableView = NSTableView()
    private var useButton: NSButton!

    /// The hit the user picked and clicked "Use Selected" on -- nil if
    /// the sheet ended with .cancel. Read by NamingReviewWindowController
    /// after the sheet ends, same pattern as this window's own finalName.
    private(set) var chosenHit: MetadataSearch.ProviderSearchHit?

    private let titleColumnID = NSUserInterfaceItemIdentifier("title")
    private let yearColumnID = NSUserInterfaceItemIdentifier("year")
    private let providerColumnID = NSUserInterfaceItemIdentifier("provider")

    init(hits: [MetadataSearch.ProviderSearchHit]) {
        self.hits = hits

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280),
                               styleMask: [.titled],
                               backing: .buffered,
                               defer: false)
        window.title = NSLocalizedString("Choose a Match", comment: "Multi-provider results window -> title")

        super.init(window: window)

        window.contentViewController = makeContentViewController()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Layout

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 280))
        controller.view = view

        let label = NSTextField(wrappingLabelWithString: NSLocalizedString("Results from every enabled provider \u{2014} pick the right one:", comment: "Multi-provider results window -> label"))
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let titleColumn = NSTableColumn(identifier: titleColumnID)
        titleColumn.title = NSLocalizedString("Title", comment: "Multi-provider results window -> column")
        titleColumn.width = 230
        let yearColumn = NSTableColumn(identifier: yearColumnID)
        yearColumn.title = NSLocalizedString("Year", comment: "Multi-provider results window -> column")
        yearColumn.width = 50
        let providerColumn = NSTableColumn(identifier: providerColumnID)
        providerColumn.title = NSLocalizedString("Provider", comment: "Multi-provider results window -> column")
        providerColumn.width = 100

        tableView.addTableColumn(titleColumn)
        tableView.addTableColumn(yearColumn)
        tableView.addTableColumn(providerColumn)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(use(_:))

        scrollView.documentView = tableView

        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Multi-provider results window -> button"), target: self, action: #selector(cancel(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"

        useButton = NSButton(title: NSLocalizedString("Use Selected", comment: "Multi-provider results window -> button"), target: self, action: #selector(use(_:)))
        useButton.translatesAutoresizingMaskIntoConstraints = false
        useButton.keyEquivalent = "\r"
        useButton.bezelStyle = .rounded
        useButton.isEnabled = false

        view.addSubview(label)
        view.addSubview(scrollView)
        view.addSubview(cancelButton)
        view.addSubview(useButton)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -14),

            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            useButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            useButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        return controller
    }

    // MARK: Actions

    @objc private func cancel(_ sender: Any?) {
        endSheet(with: .cancel)
    }

    @objc private func use(_ sender: Any?) {
        guard tableView.selectedRow >= 0, tableView.selectedRow < hits.count else { return }
        chosenHit = hits[tableView.selectedRow]
        endSheet(with: .OK)
    }

    private func endSheet(with response: NSApplication.ModalResponse) {
        guard let window = window, let sheetParent = window.sheetParent else { return }
        sheetParent.endSheet(window, returnCode: response)
    }
}

extension MultiProviderSearchResultsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return hits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let hit = hits[row]

        let text: String
        switch identifier {
        case titleColumnID: text = hit.title
        case yearColumnID: text = hit.year ?? ""
        case providerColumnID: text = hit.provider
        default: text = ""
        }

        let cellIdentifier = NSUserInterfaceItemIdentifier("cell-\(identifier.rawValue)")
        if let cell = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell.textField?.stringValue = text
            return cell
        }

        let textField = NSTextField(labelWithString: text)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail

        let cell = NSTableCellView()
        cell.identifier = cellIdentifier
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        useButton.isEnabled = tableView.selectedRow >= 0
    }
}
