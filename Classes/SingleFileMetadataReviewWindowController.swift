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
//  Shown by QueueController.reviewMetadata(for:) when
//  attemptAutoResolveMetadata(for:) decided the release's automatic match
//  wasn't confident enough to resolve silently -- including the case where
//  the online search found nothing at all. Reached the same way
//  NamingReviewWindowController and MergeReorderWindowController are
//  (double-click / "Edit..." on a parked row, here one sitting in
//  QueueRelease.Stage.pendingMetadata).
//
//  Runs its own metadata search on open (same provider/language the
//  eventual QueueMetadataAction will use) so the user sees exactly what
//  that automatic step is about to find. The search words are editable:
//  type a different title, press Search (or Return), and pick the right
//  entry from the results list. What the user confirms -- the search
//  words and which result -- is handed back to the Queue so the metadata
//  that is applied is the one the user looked at.
//
//  Built entirely in code (no .xib) -- same reasoning as
//  NamingReviewWindowController/MergeReorderWindowController: a small
//  one-off window with no reason to round-trip through Interface
//  Builder.
//

import Cocoa

final class SingleFileMetadataReviewWindowController: NSWindowController {

    private static let maxResults = 10

    private let release: QueueRelease
    private let movieProvider: String
    private let movieLanguage: String
    private let artworkSize: ArtworkSize

    private let searchField = NSTextField(string: "")
    private var searchButton: NSButton!
    private let resultsPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let artworkView = NSImageView()
    private var orientationControl: NSSegmentedControl!
    private var useButton: NSButton!

    /// The search words the sheet opened with (the bare title parsed from
    /// the approved name), and the words used for the search whose
    /// results are currently listed.
    private let initialTerm: String
    private var lastSearchedTerm: String

    /// The results of the last search, in the order the popup lists them.
    private var results: [MetadataResult] = []

    /// Bumped by every search and every result selection, so a slow
    /// response from an earlier one can't overwrite a newer one.
    private var generation = 0

    /// Every remote artwork the selected result has, filtered down to
    /// just .poster/.backdrop (the two orientations the toggle below
    /// switches between) since season/episode/person art doesn't apply
    /// to a movie release.
    private var artworks: [Artwork] = []

    /// The orientation the user landed on when they clicked "Use This
    /// Match" -- nil if the sheet ended with .cancel. Read by
    /// QueueController.reviewMetadata(for:) after the sheet ends, same
    /// pattern as the naming/merge sheets' own result properties.
    private(set) var chosenArtworkType: ArtworkType?

    /// True when the sheet ended with a real result selected. False
    /// means "Continue Without Metadata": nothing was found (or the user
    /// gave up searching), so the file is delivered as it is.
    var hasMatch: Bool { return results.isEmpty == false }

    /// The words to search with when the user changed them or picked a
    /// result other than the first; nil when the sheet is simply
    /// confirming what the automatic search would have found anyway.
    var chosenSearchTerm: String? {
        guard hasMatch else { return nil }
        return (lastSearchedTerm != initialTerm || chosenResultIndex != 0) ? lastSearchedTerm : nil
    }

    /// Position of the selected result in the list the search returned.
    var chosenResultIndex: Int {
        return max(0, resultsPopUp.indexOfSelectedItem)
    }

    init(release: QueueRelease, movieProvider: String, movieLanguage: String, defaultArtwork: ArtworkType, artworkSize: ArtworkSize) {
        self.release = release
        self.movieProvider = movieProvider
        self.movieLanguage = movieLanguage
        self.artworkSize = artworkSize
        self.chosenArtworkType = defaultArtwork.isMovieType ? defaultArtwork : .poster

        let name = release.approvedName ?? release.folderURL.lastPathComponent
        let query = ReleaseFilenameParser.parse(name)
        let title = query?.title ?? ReleaseFilenameParser.normalizedDelimiters(name)
        self.initialTerm = title
        self.lastSearchedTerm = title

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
                               styleMask: [.titled],
                               backing: .buffered,
                               defer: false)
        window.title = NSLocalizedString("Review Metadata", comment: "Metadata review window -> title")

        super.init(window: window)

        window.contentViewController = makeContentViewController()
        runSearch(term: title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Layout

    private func makeContentViewController() -> NSViewController {
        let controller = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 500))
        controller.view = view

        let originalLabel = NSTextField(labelWithString: NSLocalizedString("File:", comment: "Metadata review window -> label"))
        originalLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        originalLabel.translatesAutoresizingMaskIntoConstraints = false

        let originalValue = NSTextField(wrappingLabelWithString: release.approvedName ?? release.folderURL.lastPathComponent)
        originalValue.translatesAutoresizingMaskIntoConstraints = false

        let searchLabel = NSTextField(labelWithString: NSLocalizedString("Search for:", comment: "Metadata review window -> label"))
        searchLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        searchLabel.translatesAutoresizingMaskIntoConstraints = false

        searchField.stringValue = initialTerm
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.target = self
        searchField.action = #selector(search(_:))

        searchButton = NSButton(title: NSLocalizedString("Search", comment: "Metadata review window -> button"), target: self, action: #selector(search(_:)))
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.bezelStyle = .rounded

        let matchLabel = NSTextField(labelWithString: NSLocalizedString("Found match:", comment: "Metadata review window -> label"))
        matchLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        matchLabel.translatesAutoresizingMaskIntoConstraints = false

        resultsPopUp.translatesAutoresizingMaskIntoConstraints = false
        resultsPopUp.target = self
        resultsPopUp.action = #selector(resultChanged(_:))

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.maximumNumberOfLines = 3

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

        [originalLabel, originalValue, searchLabel, searchField, searchButton, matchLabel, resultsPopUp,
         progressIndicator, statusLabel, artworkView, orientationLabel, orientationControl,
         cancelButton, useButton].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            originalLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            originalLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            originalValue.topAnchor.constraint(equalTo: originalLabel.bottomAnchor, constant: 2),
            originalValue.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            originalValue.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            searchLabel.topAnchor.constraint(equalTo: originalValue.bottomAnchor, constant: 14),
            searchLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            searchButton.topAnchor.constraint(equalTo: searchLabel.bottomAnchor, constant: 4),
            searchButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            searchField.centerYAnchor.constraint(equalTo: searchButton.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -8),

            matchLabel.topAnchor.constraint(equalTo: searchButton.bottomAnchor, constant: 14),
            matchLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            progressIndicator.centerYAnchor.constraint(equalTo: resultsPopUp.centerYAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            resultsPopUp.topAnchor.constraint(equalTo: matchLabel.bottomAnchor, constant: 2),
            resultsPopUp.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            resultsPopUp.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -8),

            statusLabel.topAnchor.constraint(equalTo: resultsPopUp.bottomAnchor, constant: 8),
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

    /// Runs a new search for the given words and lists what it finds.
    /// The first result is selected and its details (artwork) loaded.
    private func runSearch(term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        generation += 1
        let current = generation
        lastSearchedTerm = trimmed

        results = []
        artworks = []
        artworkView.image = nil
        orientationControl.isEnabled = false
        resultsPopUp.removeAllItems()
        resultsPopUp.addItem(withTitle: NSLocalizedString("Searching…", comment: "Metadata review window -> searching placeholder"))
        resultsPopUp.isEnabled = false
        statusLabel.stringValue = ""
        useButton.title = NSLocalizedString("Use This Match", comment: "Metadata review window -> button")
        useButton.isEnabled = false
        searchButton.isEnabled = false
        progressIndicator.startAnimation(nil)

        let provider = movieProvider
        let language = movieLanguage
        let limit = SingleFileMetadataReviewWindowController.maxResults

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let service = MetadataSearch.service(name: provider)
            let search = MetadataSearch.movieSeach(service: service, movie: trimmed, language: language)

            var found: [MetadataResult] = []
            search.search(completionHandler: { found = $0 }).run()
            found = Array(found.prefix(limit))

            DispatchQueue.main.async {
                guard let self = self, self.generation == current else { return }
                self.finishSearch(found)
            }
        }
    }

    private func finishSearch(_ found: [MetadataResult]) {
        results = found
        searchButton.isEnabled = true
        resultsPopUp.removeAllItems()

        guard found.isEmpty == false else {
            progressIndicator.stopAnimation(nil)
            resultsPopUp.addItem(withTitle: NSLocalizedString("No online match found", comment: "Metadata review window -> no match"))
            resultsPopUp.isEnabled = false
            statusLabel.stringValue = NSLocalizedString("Nothing was found for these search words. Change them and press Search, or continue without online metadata.", comment: "Metadata review window -> no match status")
            useButton.title = NSLocalizedString("Continue Without Metadata", comment: "Metadata review window -> button")
            useButton.isEnabled = true
            return
        }

        for result in found {
            let name = result[.name] as? String ?? NSLocalizedString("Untitled", comment: "Metadata review window -> fallback title")
            let year = ParsedMediaName.firstFourDigitYear(in: result[.releaseDate] as? String)
            resultsPopUp.addItem(withTitle: year.map { "\(name) (\($0))" } ?? name)
        }
        resultsPopUp.isEnabled = true
        resultsPopUp.selectItem(at: 0)
        statusLabel.stringValue = NSLocalizedString("This match wasn't confident enough to apply automatically \u{2014} pick the right result, or change the search words and search again.", comment: "Metadata review window -> status")

        loadSelectedResult()
    }

    /// Loads the full details (mainly the artwork list) of the result
    /// selected in the popup.
    private func loadSelectedResult() {
        let index = chosenResultIndex
        guard results.indices.contains(index) else { return }

        generation += 1
        let current = generation
        let hit = results[index]
        let term = lastSearchedTerm
        let provider = movieProvider
        let language = movieLanguage

        artworks = []
        artworkView.image = nil
        orientationControl.isEnabled = false
        useButton.isEnabled = false
        progressIndicator.startAnimation(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let service = MetadataSearch.service(name: provider)
            let search = MetadataSearch.movieSeach(service: service, movie: term, language: language)

            var loaded: MetadataResult? = hit
            search.loadAdditionalMetadata(hit, completionHandler: { loaded = $0 }).run()

            DispatchQueue.main.async {
                guard let self = self, self.generation == current else { return }
                self.progressIndicator.stopAnimation(nil)
                self.useButton.isEnabled = true

                self.artworks = (loaded?.remoteArtworks ?? []).filter { $0.type == .poster || $0.type == .backdrop }
                self.orientationControl.isEnabled = self.artworks.isEmpty == false
                self.loadPreview()
            }
        }
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
        let current = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = URLSession.data(from: url).flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self = self, self.generation == current else { return }
                self.artworkView.image = image
            }
        }
    }

    // MARK: Actions

    @objc private func search(_ sender: Any?) {
        runSearch(term: searchField.stringValue)
    }

    @objc private func resultChanged(_ sender: Any?) {
        loadSelectedResult()
    }

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
