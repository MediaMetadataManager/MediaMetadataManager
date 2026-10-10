//
//  SingleFileMetadataReviewWindowController.swift
//  Subler
//
//  Addresses the "Single-Movie vs. Multi-Movie Interface Architecture"
//  design doc's gap #1 ("single-file curation has no dedicated review
//  step today") and gap #2 (no per-item Portrait/Landscape artwork
//  orientation override) in one sheet, per that doc's own
//  recommendation to fold #2 into whichever UI resolves #1 rather than
//  adding a second control surface.
//
//  Shown by QueueController.reviewMetadata(for:) only when
//  attemptAutoResolveMetadata(for:)'s confidence gate decided the
//  release's automatic match wasn't confident enough to resolve
//  silently -- reached the same way NamingReviewWindowController and
//  MergeReorderWindowController are (double-click / "Edit..." on a
//  parked row, here one sitting in QueueRelease.Stage.pendingMetadata).
//
//  Runs its own metadata search on open (same provider/language the
//  eventual QueueMetadataAction will use) so the user sees exactly what
//  that automatic step is about to find, rather than a generic "low
//  confidence" message with nothing to look at.
//
//  Built entirely in code (no .xib) -- same reasoning as
//  NamingReviewWindowController/MergeReorderWindowController: a small
//  one-off window with no reason to round-trip through Interface
//  Builder.
//

import Cocoa

final class SingleFileMetadataReviewWindowController: NSWindowController {

    private let release: QueueRelease
    private let movieProvider: String
    private let movieLanguage: String
    private let artworkSize: ArtworkSize

    private let matchedTitleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let artworkView = NSImageView()
    private var orientationControl: NSSegmentedControl!
    private var useButton: NSButton!

    /// Every remote artwork the search found, newest result first --
    /// filtered down to just .poster/.backdrop (the two orientations the
    /// toggle below switches between) since season/episode/person art
    /// doesn't apply to a movie release.
    private var artworks: [Artwork] = []

    /// The orientation the user landed on when they clicked "Use This
    /// Match" -- nil if the sheet ended with .cancel, or if no artwork
    /// of either orientation was ever found (nothing to override).
    /// Read by QueueController.reviewMetadata(for:) after the sheet
    /// ends, same pattern as the naming/merge sheets' own result
    /// properties.
    private(set) var chosenArtworkType: ArtworkType?

    init(release: QueueRelease, movieProvider: String, movieLanguage: String, defaultArtwork: ArtworkType, artworkSize: ArtworkSize) {
        self.release = release
        self.movieProvider = movieProvider
        self.movieLanguage = movieLanguage
        self.artworkSize = artworkSize
        self.chosenArtworkType = defaultArtwork.isMovieType ? defaultArtwork : .poster

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                               styleMask: [.titled],
                               backing: .buffered,
                               defer: false)
        window.title = NSLocalizedString("Review Metadata", comment: "Metadata review window -> title")

        super.init(window: window)

        window.contentViewController = makeContentViewController()
        beginSearch()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Layout

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))
        controller.view = view

        let originalLabel = NSTextField(labelWithString: NSLocalizedString("File:", comment: "Metadata review window -> label"))
        originalLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        originalLabel.translatesAutoresizingMaskIntoConstraints = false

        let originalValue = NSTextField(wrappingLabelWithString: release.approvedName ?? release.folderURL.lastPathComponent)
        originalValue.translatesAutoresizingMaskIntoConstraints = false

        let matchLabel = NSTextField(labelWithString: NSLocalizedString("Found match:", comment: "Metadata review window -> label"))
        matchLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        matchLabel.translatesAutoresizingMaskIntoConstraints = false

        matchedTitleLabel.stringValue = NSLocalizedString("Searching…", comment: "Metadata review window -> searching placeholder")
        matchedTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        matchedTitleLabel.lineBreakMode = .byTruncatingTail

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.startAnimation(nil)

        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.stringValue = NSLocalizedString("This match wasn't confident enough to apply automatically \u{2014} confirm or adjust below.", comment: "Metadata review window -> status")
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.wantsLayer = true
        artworkView.layer?.borderWidth = 1
        artworkView.layer?.borderColor = NSColor.gridColor.cgColor
        artworkView.layer?.cornerRadius = 4

        let orientationLabel = NSTextField(labelWithString: NSLocalizedString("Artwork:", comment: "Metadata review window -> label"))
        orientationLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        orientationLabel.translatesAutoresizingMaskIntoConstraints = false

        orientationControl = NSSegmentedControl(labels: [NSLocalizedString("Portrait", comment: "Metadata review window -> segment"),
                                                          NSLocalizedString("Landscape", comment: "Metadata review window -> segment")],
                                                 trackingMode: .selectOne,
                                                 target: self,
                                                 action: #selector(orientationChanged(_:)))
        orientationControl.translatesAutoresizingMaskIntoConstraints = false
        orientationControl.selectedSegment = chosenArtworkType == .backdrop ? 1 : 0
        orientationControl.isEnabled = false

        let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: "Metadata review window -> button"), target: self, action: #selector(cancel(_:)))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1b}"

        useButton = NSButton(title: NSLocalizedString("Use This Match", comment: "Metadata review window -> button"), target: self, action: #selector(use(_:)))
        useButton.translatesAutoresizingMaskIntoConstraints = false
        useButton.keyEquivalent = "\r"
        useButton.bezelStyle = .rounded

        view.addSubview(originalLabel)
        view.addSubview(originalValue)
        view.addSubview(matchLabel)
        view.addSubview(matchedTitleLabel)
        view.addSubview(progressIndicator)
        view.addSubview(statusLabel)
        view.addSubview(artworkView)
        view.addSubview(orientationLabel)
        view.addSubview(orientationControl)
        view.addSubview(cancelButton)
        view.addSubview(useButton)

        NSLayoutConstraint.activate([
            originalLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            originalLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            originalValue.topAnchor.constraint(equalTo: originalLabel.bottomAnchor, constant: 2),
            originalValue.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            originalValue.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            matchLabel.topAnchor.constraint(equalTo: originalValue.bottomAnchor, constant: 16),
            matchLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            progressIndicator.centerYAnchor.constraint(equalTo: matchedTitleLabel.centerYAnchor),
            progressIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            matchedTitleLabel.topAnchor.constraint(equalTo: matchLabel.bottomAnchor, constant: 2),
            matchedTitleLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 6),
            matchedTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: matchedTitleLabel.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            artworkView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            artworkView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 160),
            artworkView.heightAnchor.constraint(equalToConstant: 160),

            orientationLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 14),
            orientationLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            orientationControl.centerYAnchor.constraint(equalTo: orientationLabel.centerYAnchor),
            orientationControl.leadingAnchor.constraint(equalTo: orientationLabel.trailingAnchor, constant: 10),

            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cancelButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            useButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            useButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        return controller
    }

    // MARK: Search

    /// The bare, year-free title to search with -- release.approvedName
    /// is already the user-approved folder/file name by the time this
    /// sheet can ever appear (naming review always precedes metadata
    /// review in the release pipeline), so this mirrors
    /// NamingReviewWindowController.localQueryComponents()'s own parsing
    /// rather than re-deriving it a third way.
    private func localQueryComponents() -> (title: String, year: String?) {
        let name = release.approvedName ?? release.folderURL.lastPathComponent
        let query = ReleaseFilenameParser.parse(name)
        let title = query?.title ?? ReleaseFilenameParser.normalizedDelimiters(name)
        return (title, query?.year)
    }

    private func beginSearch() {
        let (title, _) = localQueryComponents()
        let provider = movieProvider
        let language = movieLanguage

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let service = MetadataSearch.service(name: provider)
            let search = MetadataSearch.movieSeach(service: service, movie: title, language: language)

            var results: [MetadataResult] = []
            search.search(completionHandler: { results = $0 }).run()

            guard let hit = results.first else {
                DispatchQueue.main.async { self?.finishSearch(result: nil) }
                return
            }

            var loaded: MetadataResult? = hit
            search.loadAdditionalMetadata(hit, completionHandler: { loaded = $0 }).run()

            DispatchQueue.main.async { self?.finishSearch(result: loaded) }
        }
    }

    private func finishSearch(result: MetadataResult?) {
        progressIndicator.stopAnimation(nil)

        guard let result = result else {
            matchedTitleLabel.stringValue = NSLocalizedString("No online match found", comment: "Metadata review window -> no match")
            statusLabel.stringValue = NSLocalizedString("Nothing to compare against \u{2014} using the local name as-is.", comment: "Metadata review window -> no match status")
            useButton.title = NSLocalizedString("Continue", comment: "Metadata review window -> button")
            return
        }

        let name = result[.name] as? String ?? NSLocalizedString("Untitled", comment: "Metadata review window -> fallback title")
        let year = ParsedMediaName.firstFourDigitYear(in: result[.releaseDate] as? String)
        matchedTitleLabel.stringValue = year.map { "\(name) (\($0))" } ?? name

        artworks = result.remoteArtworks.filter { $0.type == .poster || $0.type == .backdrop }

        if artworks.isEmpty == false {
            orientationControl.isEnabled = true
        }

        loadPreview()
    }

    // MARK: Artwork preview

    @objc private func orientationChanged(_ sender: NSSegmentedControl) {
        chosenArtworkType = sender.selectedSegment == 1 ? .backdrop : .poster
        loadPreview()
    }

    private func loadPreview() {
        guard let type = chosenArtworkType else { return }

        let preferred = artworks.first(by: type, size: artworkSize, service: movieProvider) ?? artworks.first { $0.type == type } ?? artworks.first

        guard let artwork = preferred else {
            artworkView.image = nil
            return
        }

        let url = artwork.thumbURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = URLSession.data(from: url).flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                self?.artworkView.image = image
            }
        }
    }

    // MARK: Actions

    @objc private func cancel(_ sender: Any?) {
        endSheet(with: .cancel)
    }

    @objc private func use(_ sender: Any?) {
        endSheet(with: .OK)
    }

    private func endSheet(with response: NSApplication.ModalResponse) {
        guard let window = window, let sheetParent = window.sheetParent else { return }
        sheetParent.endSheet(window, returnCode: response)
    }
}
