//
//  WelcomeWindowController.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/02/2026.
//
//  An Xcode-style "what would you like to do" window, shown at launch
//  when Prefs.showWelcomeScreenAtLaunch is on (General preferences --
//  see GeneralPrefsViewController.xib's own checkbox, bound to the same
//  preference) instead of -- or alongside -- whatever Prefs.launchBehavior
//  would otherwise show. Offers the three things a user most often opens
//  this app to do: tag one file, merge several files and tag the result,
//  or scan an existing library for files still missing metadata.
//
//  Built entirely in code (no .xib), same reasoning as
//  NamingReviewWindowController/MergeReorderWindowController: a small
//  one-off window with no reason to round-trip through Interface Builder.
//

import Cocoa

final class WelcomeWindowController: NSWindowController {

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                               styleMask: [.titled, .closable],
                               backing: .buffered,
                               defer: false)
        window.title = ""
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        window.contentViewController = makeContentViewController()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Layout

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
        controller.view = view

        let iconView = NSImageView()
        iconView.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

        let versionLabel = NSTextField(labelWithString: version.isEmpty
            ? ""
            : String(format: NSLocalizedString("Version %@", comment: "Welcome window -> version"), version))
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        let tagButton = makeActionButton(symbolName: "tag",
                                          title: NSLocalizedString("Tag One File", comment: "Welcome window -> action title"),
                                          subtitle: NSLocalizedString("Open a single file to search for and apply its metadata.", comment: "Welcome window -> action subtitle"),
                                          action: #selector(tagOneFile(_:)))

        let mergeButton = makeActionButton(symbolName: "film.stack",
                                            title: NSLocalizedString("Merge and Tag Files", comment: "Welcome window -> action title"),
                                            subtitle: NSLocalizedString("Combine several files into one in the Queue, then tag the result.", comment: "Welcome window -> action subtitle"),
                                            action: #selector(mergeAndTagFiles(_:)))

        let scanButton = makeActionButton(symbolName: "magnifyingglass",
                                           title: NSLocalizedString("Scan Library for Missing Metadata", comment: "Welcome window -> action title"),
                                           subtitle: NSLocalizedString("Look through a folder for files that still need tagging.", comment: "Welcome window -> action subtitle"),
                                           action: #selector(scanLibrary(_:)))

        let actionStack = NSStackView(views: [tagButton, mergeButton, scanButton])
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.orientation = .vertical
        actionStack.alignment = .leading
        actionStack.spacing = 30
        actionStack.distribution = .equalSpacing

        // A vertical NSStackView doesn't stretch arranged views to its own
        // width on its own -- without this, each button's width came from
        // its own intrinsic size (based on the attributedTitle below),
        // which wasn't reliable enough to keep the two-line title+subtitle
        // text from overlapping the row beneath it. Pinning every row to
        // the stack's width makes all three rows a single, predictable
        // width and leaves only vertical spacing to size them.
        for button in [tagButton, mergeButton, scanButton] {
            button.widthAnchor.constraint(equalTo: actionStack.widthAnchor).isActive = true
        }

        let showAtLaunchCheckbox = NSButton(checkboxWithTitle: NSLocalizedString("Show this window at launch", comment: "Welcome window -> checkbox"),
                                             target: self, action: #selector(toggleShowAtLaunch(_:)))
        showAtLaunchCheckbox.state = Prefs.showWelcomeScreenAtLaunch ? .on : .off
        showAtLaunchCheckbox.translatesAutoresizingMaskIntoConstraints = false
        showAtLaunchCheckbox.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        // Same secondary-button styling as Reject/Cancel in
        // NamingReviewWindowController/SingleFileMetadataReviewWindowController
        // -- default (non-rounded) bezel, centered on the bottom row the
        // way that family of windows also centers its own middle action
        // (e.g. "Pass").
        let quitButton = NSButton(title: NSLocalizedString("Quit", comment: "Welcome window -> button"), target: self, action: #selector(quit(_:)))
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(iconView)
        view.addSubview(actionStack)
        view.addSubview(showAtLaunchCheckbox)
        view.addSubview(quitButton)
        view.addSubview(versionLabel)

        NSLayoutConstraint.activate([
            // M3 icon: enlarged 50% (72 -> 108) and kept centered on the window.
            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 36),
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 108),
            iconView.heightAnchor.constraint(equalToConstant: 108),

            // Action rows: the stack spans the full width (left-justified
            // content comes from button.alignment = .left in
            // makeActionButton below, not from a narrower stack) -- an
            // unconstrained/ambiguous row width here is what was causing
            // the two-line title+subtitle text to overlap between rows.
            actionStack.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 32),
            actionStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 48),
            actionStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -48),

            // Bottom-left/bottom-right pair, mirroring each other, with
            // Quit centered between them on the same row.
            showAtLaunchCheckbox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            showAtLaunchCheckbox.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            quitButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            quitButton.centerYAnchor.constraint(equalTo: showAtLaunchCheckbox.centerYAnchor),

            versionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            versionLabel.centerYAnchor.constraint(equalTo: showAtLaunchCheckbox.centerYAnchor)
        ])

        return controller
    }

    /// One Xcode-Welcome-style row: an icon plus a bold title and a
    /// secondary-colored subtitle, as a single flat (borderless) button
    /// so the whole row is clickable, not just its text. SF Symbols need
    /// macOS 11 -- this project's deployment target is 10.13, same
    /// constraint CustomSourcesListViewController's own reveal-button
    /// icon already works around -- so pre-11 falls back to no icon
    /// rather than an icon-less gap.
    private func makeActionButton(symbolName: String, title: String, subtitle: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyUpOrDown
        button.alignment = .left
        button.heightAnchor.constraint(equalToConstant: 48).isActive = true

        if #available(macOS 11, *) {
            // Reduced 10% (22 -> 19.8) to sit proportionally against the
            // enlarged M3 icon above.
            let config = NSImage.SymbolConfiguration(pointSize: 19.8, weight: .regular)
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?.withSymbolConfiguration(config)
        }

        let titleAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                          .foregroundColor: NSColor.labelColor]
        let subtitleAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                             .foregroundColor: NSColor.secondaryLabelColor]

        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 2

        let attributed = NSMutableAttributedString(string: title + "\n", attributes: titleAttr)
        attributed.append(NSAttributedString(string: subtitle, attributes: subtitleAttr))
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))

        button.attributedTitle = attributed

        return button
    }

    // MARK: Actions

    @objc private func tagOneFile(_ sender: Any?) {
        // The Open panel is the only window left once this one closes, so
        // if the user cancels it (or it fails to produce a document) there
        // needs to be something to land back on -- otherwise cancelling
        // here leaves no window open at all. DocumentController reports a
        // genuine panel cancel (as opposed to a successful pick that just
        // got routed somewhere other than a plain document open, e.g. a
        // folder sent to the Queue) through openPanelWasCancelledHandler;
        // see that property's own doc comment.
        if let controller = NSDocumentController.shared as? DocumentController {
            controller.openPanelWasCancelledHandler = { [weak self] in
                self?.showWindow(self)
            }
        }
        close()
        NSDocumentController.shared.openDocument(self)
    }

    @objc private func mergeAndTagFiles(_ sender: Any?) {
        close()
        QueueController.shared.showWindow(self)
    }

    @objc private func scanLibrary(_ sender: Any?) {
        close()
        LibraryScanWindowController.shared.showWindow(self)
    }

    @objc private func toggleShowAtLaunch(_ sender: NSButton) {
        Prefs.showWelcomeScreenAtLaunch = sender.state == .on
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }
}
