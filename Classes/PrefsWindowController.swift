//
//  PrefsWindowController.swift
//  Subler
//
//  Created by Damiano Galassi on 20/08/2017.
//

import Cocoa

class PrefsWindowController: NSWindowController, NSWindowDelegate {

    override var windowNibName: NSNib.Name? {
        return "PrefsWindowController"
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        if #available(macOS 11, *) {
            window?.toolbarStyle = .preference

            for item in window?.toolbar?.items ?? [] {
                switch item.itemIdentifier {
                case general:
                    item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "")
                case metadata:
                    item.image = NSImage(systemSymbolName: "network", accessibilityDescription: "")
                case presets:
                    item.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: "")
                case output:
                    item.image = NSImage(systemSymbolName: "rectangle.and.pencil.and.ellipsis", accessibilityDescription: "")
                case ocr:
                    item.image = NSImage(systemSymbolName: "doc.text.viewfinder", accessibilityDescription: "")
                case advanced:
                    item.image = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: "")
                case sources:
                    item.image = NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: "")
                case support:
                    item.image = NSImage(systemSymbolName: "heart", accessibilityDescription: "")
                default:
                    item.image = NSImage(systemSymbolName: "placeholdertext.fill", accessibilityDescription: "")
                }
            }
        }

        window?.toolbar?.allowsUserCustomization = false
        window?.toolbar?.selectedItemIdentifier = general

        if let items = window?.toolbar?.items, let item = (items.first { $0.itemIdentifier == general }) {
            selectItem(item, animate: false)
        }
    }

    func windowWillClose(_ notification: Notification) {
        _ = self.window?.endEditing()
    }

    lazy var generalController: GeneralPrefsViewController = { return GeneralPrefsViewController() }()
    lazy var metadataController: MetadataPrefsViewController = { return MetadataPrefsViewController() }()
    lazy var presetController: PresetPrefsViewController = { return PresetPrefsViewController() }()
    lazy var outputController: OutputPrefsViewController = { return OutputPrefsViewController() }()
    lazy var ocrController: OCRPrefsViewController = { return OCRPrefsViewController() }()
    lazy var advancedController: AdvancedPrefsViewController = { return AdvancedPrefsViewController() }()
    lazy var sourcesController: SourcesPrefsViewController = { return SourcesPrefsViewController() }()
    lazy var supportController: SupportPrefsViewController = { return SupportPrefsViewController() }()

    let general: NSToolbarItem.Identifier = NSToolbarItem.Identifier("TOOLBAR_GENERAL")
    let metadata: NSToolbarItem.Identifier = NSToolbarItem.Identifier("TOOLBAR_METADATA")
    let presets: NSToolbarItem.Identifier = NSToolbarItem.Identifier("TOOLBAR_SETS")
    let output: NSToolbarItem.Identifier = NSToolbarItem.Identifier("TOOLBAR_OUTPUT")
    let ocr: NSToolbarItem.Identifier = NSToolbarItem.Identifier("TOOLBAR_OCR")
    let advanced: NSToolbarItem.Identifier = NSToolbarItem.Identifier("TOOLBAR_ADVANCED")
    let sources: NSToolbarItem.Identifier = NSToolbarItem.Identifier("TOOLBAR_SOURCES")
    let support: NSToolbarItem.Identifier = NSToolbarItem.Identifier("TOOLBAR_SUPPORT")

    // MARK: Panel switching

    private func view(for identifier: NSToolbarItem.Identifier) -> NSView? {
        if identifier == general { return generalController.view }
        if identifier == metadata { return metadataController.view }
        if identifier == presets { return presetController.view }
        if identifier == output { return outputController.view }
        if identifier == ocr { return ocrController.view }
        if identifier == advanced { return advancedController.view }
        if identifier == sources { return sourcesController.view }
        if identifier == support { return supportController.view }
        return nil
    }

    private func animationDuration(view: NSView, previousView: NSView?) -> TimeInterval {
        guard let previousView = previousView else { return 0 }
        return TimeInterval(abs(previousView.frame.size.height - view.frame.height)) * 0.0011
    }

    private func selectItem(_ item: NSToolbarItem, animate: Bool) {
        guard let window = self.window,
            let view = self.view(for: item.itemIdentifier),
            window.contentView != view
            else { return }

        let duration = animationDuration(view: view, previousView: window.contentView)
        window.contentView = view

        if window.isVisible && animate {
            NSAnimationContext.runAnimationGroup({ context in
                context.allowsImplicitAnimation = true
                context.duration = duration
                window.layoutIfNeeded()

                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                view.isHidden = true
                NSAnimationContext.endGrouping()
            }, completionHandler: {
                view.isHidden = false
                window.title = item.label
                self.window?.makeFirstResponder(view.nextKeyView)
            })
        }
        else {
            window.title = item.label
        }
    }

    @IBAction func setPrefView(_ sender: NSToolbarItem) {
        selectItem(sender, animate: true)
    }

}

// MARK: - Support (donations)
//
// Media Metadata Manager is built on Subler. This is the one place the app's
// donation links live, so they can be changed without touching any UI code:
//
//  - ownSponsorURL: where people can sponsor Media Metadata Manager itself
//    (GitHub Sponsors).
//  - originalAuthorSupportURL: where people can support the original Subler
//    author (Damiano Galassi). Subler's old donate page (subler.org/donate.php)
//    is dead, so this points at the Subler project site until upstream
//    publishes a working donation link. The weekly upstream check watches for
//    that and updates ONLY this constant -- never ownSponsorURL.

enum SupportLinks {

    static let ownSponsorURL = URL(string: "https://github.com/sponsors/MediaMetadataManager")!
    static let originalAuthorSupportURL = URL(string: "https://subler.org")!

    static var introText: String {
        return NSLocalizedString("Media Metadata Manager is free. If it saves you time, you can help fund its development, testing and upkeep through GitHub Sponsors.", comment: "Support -> intro")
    }

    static var creditText: String {
        return NSLocalizedString("Media Metadata Manager is built on Subler, created by Damiano Galassi and its contributors. Their work is the foundation of everything here, and you can support them too.", comment: "Support -> credit to the original author")
    }

    static var sponsorButtonTitle: String {
        return NSLocalizedString("Sponsor on GitHub", comment: "Support -> button")
    }

    static var originalAuthorButtonTitle: String {
        return NSLocalizedString("Support the Original Subler Author", comment: "Support -> button")
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// The small dialog behind the app menu's Support item. Never shown
    /// automatically -- only when the user asks for it.
    static func showSupportAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Support Media Metadata Manager", comment: "Support -> title")
        alert.informativeText = introText + "\n\n" + creditText
        alert.addButton(withTitle: sponsorButtonTitle)
        alert.addButton(withTitle: originalAuthorButtonTitle)
        let close = alert.addButton(withTitle: NSLocalizedString("Close", comment: "Support -> button"))
        close.keyEquivalent = String(format: "%c", 0x1b) // escape key

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            open(ownSponsorURL)
        case .alertSecondButtonReturn:
            open(originalAuthorSupportURL)
        default:
            break
        }
    }
}

/// The "Support" tab in Preferences. Built in code (no .xib).
final class SupportPrefsViewController: NSViewController {

    init() {
        super.init(nibName: nil, bundle: nil)
        self.title = NSLocalizedString("Support", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 300))
        self.view = view

        let header = NSTextField(labelWithString: NSLocalizedString("Support Media Metadata Manager", comment: "Support -> title"))
        header.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let intro = NSTextField(wrappingLabelWithString: SupportLinks.introText)
        intro.preferredMaxLayoutWidth = 600

        let sponsorButton = NSButton(title: SupportLinks.sponsorButtonTitle, target: self, action: #selector(openSponsor(_:)))
        sponsorButton.bezelStyle = .rounded

        let creditHeader = NSTextField(labelWithString: NSLocalizedString("The Original Subler", comment: "Support -> section title"))
        creditHeader.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let credit = NSTextField(wrappingLabelWithString: SupportLinks.creditText)
        credit.preferredMaxLayoutWidth = 600

        let originalButton = NSButton(title: SupportLinks.originalAuthorButtonTitle, target: self, action: #selector(openOriginalAuthor(_:)))
        originalButton.bezelStyle = .rounded

        let note = NSTextField(wrappingLabelWithString: NSLocalizedString("Both buttons open a web page in your browser. Nothing is sent from the app.", comment: "Support -> footnote"))
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 600

        let stack = NSStackView(views: [header, intro, sponsorButton, creditHeader, credit, originalButton, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(24, after: sponsorButton)
        stack.setCustomSpacing(24, after: originalButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -30)
        ])
    }

    @objc private func openSponsor(_ sender: Any?) {
        SupportLinks.open(SupportLinks.ownSponsorURL)
    }

    @objc private func openOriginalAuthor(_ sender: Any?) {
        SupportLinks.open(SupportLinks.originalAuthorSupportURL)
    }
}
