//
//  NamingReviewWindowController.swift
//  Subler
//
//  Phase 3 of the Intake/Queue workflow (see the design doc kept in the
//  Subler claude.ai project, section 4.2): the naming approve/reject
//  window for a pending QueueRelease. Shown when the user opens a
//  `.pendingNaming` (or `.namingRejected`, to reconsider) release row --
//  see QueueController.edit(_:) for how it's reached (double-click or the
//  "Edit\u{2026}" context-menu item, same entry point a plain QueueItem
//  already uses).
//
//  Purely a UI/search layer, same division of responsibility as
//  MergeReorderWindowController: this window only proposes a name and
//  reports the user's decision back through the sheet completion handler
//  (approved(name:) or rejected); QueueController itself does the actual
//  filesystem rename and QueueRelease.stage transition once the sheet
//  ends, exactly as it already does the merge/save work after
//  MergeReorderWindowController's sheet ends.
//
//  Built entirely in code (no .xib) -- same reasoning as
//  MergeReorderWindowController: a small one-off window with no reason to
//  round-trip through Interface Builder.
//
//  Phase 8 (Sep 26 2026): resolves the design doc's "auto-approve
//  high-confidence matches" open question (section 5) -- when
//  MediaIntakePrefs.autoApproveHighConfidenceNaming is on and the online
//  hit clears isHighConfidenceMatch(...) below, the sheet still shows
//  the match briefly, then auto-clicks Approve rather than always
//  waiting for a manual click. See scheduleAutoApprove(matchedSource:).
//

import Cocoa

final class NamingReviewWindowController: NSWindowController {

    /// endSheet(with:)'s response for the Pass button -- distinct from
    /// both .OK (Approve) and .cancel (Reject, which parks the release
    /// as .namingRejected). QueueController's sheet completion handler
    /// treats this as a no-op: the release is left exactly as it was
    /// (.pendingNaming) so it's simply offered for review again later,
    /// the same as if this window had never been opened, rather than
    /// being parked in a separate "rejected" state the user would have
    /// to deliberately go find and reconsider.
    static let passResponse = NSApplication.ModalResponse(2)

    private let release: QueueRelease

    private let suggestedNameField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private var approveButton: NSButton!
    private var passButton: NSButton!
    private var searchAllProvidersButton: NSButton!

    /// Set once the user types into suggestedNameField -- once true, a
    /// search result arriving late no longer overwrites what the user's
    /// already edited.
    private var userEditedName = false

    /// Scheduled by finishSearch(...) when MediaIntakePrefs.
    /// autoApproveHighConfidenceNaming is on and the online hit clears
    /// isHighConfidenceMatch(...) -- fires approve(_:) after a short
    /// delay so the sheet still visibly shows the matched name for a
    /// moment before closing, rather than resolving silently. Cancelled
    /// by any manual action (typing, Approve, Reject) that should
    /// preempt it.
    private var autoApproveWorkItem: DispatchWorkItem?

    /// The final name to use if the user approves -- suggestedNameField's
    /// current text, trimmed. Read by QueueController after the sheet
    /// ends with .OK.
    var finalName: String {
        suggestedNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(release: QueueRelease) {
        self.release = release

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 256),
                               styleMask: [.titled],
                               backing: .buffered,
                               defer: false)
        window.title = NSLocalizedString("Review Naming", comment: "Naming review window -> title")

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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 256))
        controller.view = view

        let originalLabel = NSTextField(labelWithString: NSLocalizedString("Original name:", comment: "Naming review window -> label"))
        originalLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        originalLabel.translatesAutoresizingMaskIntoConstraints = false

        let fileCount = release.sourceFileURLs.count
        let originalValue = NSTextField(wrappingLabelWithString: release.folderURL.lastPathComponent)
        originalValue.translatesAutoresizingMaskIntoConstraints = false

        let filesLabel = NSTextField(labelWithString: fileCount == 1
            ? NSLocalizedString("1 file", comment: "Naming review window -> file count")
            : String(format: NSLocalizedString("%d files", comment: "Naming review window -> file count"), fileCount))
        filesLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        filesLabel.textColor = .secondaryLabelColor
        filesLabel.translatesAutoresizingMaskIntoConstraints = false

        let suggestedLabel = NSTextField(labelWithString: NSLocalizedString("Suggested name:", comment: "Naming review window -> label"))
        suggestedLabel.font = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        suggestedLabel.translatesAutoresizingMaskIntoConstraints = false

        suggestedNameField.translatesAutoresizingMaskIntoConstraints = false
        suggestedNameField.delegate = self
        suggestedNameField.stringValue = NamingReviewWindowController.localGuess(for: release)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = NSLocalizedString("Searching\u{2026}", comment: "Naming review window -> searching status")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let rejectButton = NSButton(title: NSLocalizedString("Reject", comment: "Naming review window -> button"), target: self, action: #selector(reject(_:)))
        rejectButton.translatesAutoresizingMaskIntoConstraints = false
        rejectButton.keyEquivalent = "\u{1b}"

        approveButton = NSButton(title: NSLocalizedString("Approve", comment: "Naming review window -> button"), target: self, action: #selector(approve(_:)))
        approveButton.translatesAutoresizingMaskIntoConstraints = false
        approveButton.keyEquivalent = "\r"
        approveButton.bezelStyle = .rounded

        // Neither approves nor rejects -- just closes the window without
        // deciding anything, so this release comes up for review again
        // later exactly as if it hadn't been opened. See passResponse's
        // own doc comment.
        passButton = NSButton(title: NSLocalizedString("Pass", comment: "Naming review window -> button"), target: self, action: #selector(pass(_:)))
        passButton.translatesAutoresizingMaskIntoConstraints = false
        passButton.toolTip = NSLocalizedString("Skip this one for now -- you'll be asked to review it again later.", comment: "")

        // "Second pass" from the Intake/Queue workflow design doc's
        // section 7c: an explicit, user-triggered fan-out across every
        // enabled provider (MetadataSearch.searchAllMovieProviders(
        // title:)), distinct from -- and left for the user to reach for
        // only when -- the automatic single-best-guess search above
        // isn't good enough (e.g. a wrong first hit, or none at all).
        searchAllProvidersButton = NSButton(title: NSLocalizedString("Search All Providers\u{2026}", comment: "Naming review window -> button"), target: self, action: #selector(searchAllProviders(_:)))
        searchAllProvidersButton.translatesAutoresizingMaskIntoConstraints = false
        searchAllProvidersButton.toolTip = NSLocalizedString("Searches every enabled provider (Preferences > Sources > Providers) for this title and lets you pick from all of their results combined, instead of just the first one that happened to answer.", comment: "")

        view.addSubview(originalLabel)
        view.addSubview(originalValue)
        view.addSubview(filesLabel)
        view.addSubview(suggestedLabel)
        view.addSubview(suggestedNameField)
        view.addSubview(progressIndicator)
        view.addSubview(statusLabel)
        view.addSubview(rejectButton)
        view.addSubview(passButton)
        view.addSubview(approveButton)
        view.addSubview(searchAllProvidersButton)

        NSLayoutConstraint.activate([
            originalLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            originalLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            originalValue.topAnchor.constraint(equalTo: originalLabel.bottomAnchor, constant: 4),
            originalValue.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            originalValue.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            filesLabel.topAnchor.constraint(equalTo: originalValue.bottomAnchor, constant: 2),
            filesLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            suggestedLabel.topAnchor.constraint(equalTo: filesLabel.bottomAnchor, constant: 18),
            suggestedLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            suggestedNameField.topAnchor.constraint(equalTo: suggestedLabel.bottomAnchor, constant: 4),
            suggestedNameField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            suggestedNameField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            progressIndicator.topAnchor.constraint(equalTo: suggestedNameField.bottomAnchor, constant: 8),
            progressIndicator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),

            statusLabel.centerYAnchor.constraint(equalTo: progressIndicator.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 6),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            searchAllProvidersButton.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 16),
            searchAllProvidersButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            rejectButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            rejectButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            passButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            passButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            approveButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            approveButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])

        return controller
    }

    // MARK: Search

    /// A same-heuristic-as-ever local guess (ReleaseFilenameParser, the
    /// same one already used for the folder-rename feature and the merge
    /// destination name), shown immediately so the field is never blank
    /// while the online search below is still running.
    private static func localGuess(for release: QueueRelease) -> String {
        ReleaseFilenameParser.canonicalReleaseName(release.folderURL.lastPathComponent)
            ?? ReleaseFilenameParser.normalizedDelimiters(release.folderURL.lastPathComponent)
    }

    /// Searches MetadataSearch.movieProviders (the same enabled-provider
    /// list Preferences > Sources > Providers manages, and QueueMetadataAction
    /// already searches for the automated path -- see the design doc
    /// section 4.2) for a better title than the purely local guess above.
    /// Stops at the first provider that returns any result, same
    /// first-match behavior QueueMetadataAction already uses. Runs
    /// entirely on a background thread -- RunnableTask.run() is a
    /// blocking, synchronous call (confirmed against its own
    /// implementation), so providers are tried strictly one after another
    /// rather than all at once.
    /// The bare local title/studio/year parsed from the release's
    /// folder name -- shared by beginSearch() above and
    /// searchAllProviders(_:) below so both query providers with the
    /// exact same (already year-free) title text, and both fall back
    /// identically when the parser finds nothing to work with.
    private func localQueryComponents() -> (title: String, studio: String?, year: String?) {
        return NamingReviewWindowController.localQueryComponents(forFolderName: release.folderURL.lastPathComponent)
    }

    static func localQueryComponents(forFolderName folderName: String) -> (title: String, studio: String?, year: String?) {
        let query = ReleaseFilenameParser.parse(folderName)
        let title = query?.title ?? ReleaseFilenameParser.normalizedDelimiters(folderName)
        return (title, query?.studio, query?.year)
    }

    /// The first enabled provider's best match for a title, formatted as a
    /// folder name -- the search behind beginSearch() below, also used
    /// without any window by QueueController's automatic intake approval.
    /// Blocking; call off the main thread.
    struct ProviderNameMatch {
        let name: String
        let source: String
        let highConfidence: Bool
    }

    static func bestProviderMatch(title: String, studio localStudio: String?, year localYear: String?) -> ProviderNameMatch? {
        for providerName in MetadataSearch.movieProviders {
            let service = MetadataSearch.service(name: providerName)
            let language = MetadataSearch.defaultLanguage(service: service, type: .movie)
            let search = MetadataSearch.movieSeach(service: service, movie: title, language: language)

            var results: [MetadataResult] = []
            search.search(completionHandler: { results = $0 }).run()

            guard let hit = results.first else { continue }

            let onlineTitle = hit[.name] as? String
            let onlineYear = ParsedMediaName.firstFourDigitYear(in: hit[.releaseDate] as? String)

            guard let resolvedTitle = onlineTitle, resolvedTitle.isEmpty == false else { continue }

            let formatted = ParsedMediaName(title: resolvedTitle,
                                             year: onlineYear ?? localYear,
                                             studio: localStudio,
                                             fileExtension: "")
            let highConfidence = isHighConfidenceMatch(localTitle: title,
                                                       localYear: localYear,
                                                       onlineTitle: resolvedTitle,
                                                       onlineYear: onlineYear)
            return ProviderNameMatch(name: formatted.movieFolderName, source: providerName, highConfidence: highConfidence)
        }
        return nil
    }

    private func beginSearch() {
        progressIndicator.startAnimation(nil)

        let (title, localStudio, localYear) = localQueryComponents()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let match = NamingReviewWindowController.bestProviderMatch(title: title, studio: localStudio, year: localYear)
            let matchedName = match?.name
            let matchedSource = match?.source
            let highConfidence = match?.highConfidence ?? false

            DispatchQueue.main.async {
                self?.finishSearch(matchedName: matchedName, matchedSource: matchedSource, highConfidence: highConfidence)
            }
        }
    }

    private func finishSearch(matchedName: String?, matchedSource: String?, highConfidence: Bool) {
        progressIndicator.stopAnimation(nil)

        if let matchedName = matchedName, let matchedSource = matchedSource {
            if userEditedName == false {
                suggestedNameField.stringValue = matchedName
            }
            statusLabel.stringValue = String(format: NSLocalizedString("Matched via %@", comment: "Naming review window -> search status"), matchedSource)

            if highConfidence && userEditedName == false && MediaIntakePrefs.autoApproveHighConfidenceNaming {
                scheduleAutoApprove(matchedSource: matchedSource)
            }
        } else {
            statusLabel.stringValue = NSLocalizedString("No online match \u{2014} using local guess", comment: "Naming review window -> search status")
        }
    }

    // MARK: Search All Providers (Intake/Queue workflow section 7c)

    /// The explicit "second pass" the design doc's section 7c asks for,
    /// distinct from beginSearch() above: fans out to every provider in
    /// MetadataSearch.movieProviders (same bare, year-free title --
    /// localQueryComponents() guarantees both searches use identical
    /// text) and collects every one's own result instead of stopping at
    /// the first hit, then lets the user pick from the combined list via
    /// MultiProviderSearchResultsWindowController. Only ever triggered by
    /// this button -- never run automatically -- per this feature's own
    /// design decision.
    @objc private func searchAllProviders(_ sender: Any?) {
        autoApproveWorkItem?.cancel()
        searchAllProvidersButton.isEnabled = false
        progressIndicator.startAnimation(nil)
        statusLabel.stringValue = NSLocalizedString("Searching all providers\u{2026}", comment: "Naming review window -> search status")

        let (title, localStudio, localYear) = localQueryComponents()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hits = MetadataSearch.searchAllMovieProviders(title: title)

            DispatchQueue.main.async {
                self?.finishSearchAllProviders(hits: hits, localStudio: localStudio, localYear: localYear)
            }
        }
    }

    private func finishSearchAllProviders(hits: [MetadataSearch.ProviderSearchHit], localStudio: String?, localYear: String?) {
        progressIndicator.stopAnimation(nil)
        searchAllProvidersButton.isEnabled = true

        guard hits.isEmpty == false else {
            statusLabel.stringValue = NSLocalizedString("No matches from any provider", comment: "Naming review window -> search status")
            return
        }

        guard let window = window else { return }
        let resultsController = MultiProviderSearchResultsWindowController(hits: hits)
        guard let resultsWindow = resultsController.window else { return }

        // resultsController is captured (and so kept alive) by this
        // closure for as long as the sheet is up -- same pattern this
        // window itself is presented with by QueueController.
        window.beginSheet(resultsWindow) { response in
            guard response == .OK, let chosen = resultsController.chosenHit else { return }

            let formatted = ParsedMediaName(title: chosen.title,
                                             year: chosen.year ?? localYear,
                                             studio: localStudio,
                                             fileExtension: "")
            self.suggestedNameField.stringValue = formatted.movieFolderName
            self.userEditedName = true
            self.statusLabel.stringValue = String(format: NSLocalizedString("Matched via %@ (all-providers search)", comment: "Naming review window -> search status"), chosen.provider)
        }
    }

    // MARK: Confidence heuristic + auto-approve

    /// None of the configured providers (TheMovieDB, TheTVDB, an installed
    /// plugin, etc.) expose an actual match-confidence score in what
    /// MetadataResult already parses -- there's no numeric field to
    /// threshold against. So "high confidence" is this heuristic
    /// instead: the online hit's title normalizes (case/punctuation-
    /// insensitive) to the same string as the locally-parsed title from
    /// the filename, and -- only when both sides actually have a year --
    /// the years agree too. Deliberately conservative: a fuzzy/partial
    /// title match, or a year mismatch when both are known, is not
    /// high-confidence. When only one side (or neither) has a year, the
    /// title match alone still counts, since scene-filename years are
    /// often missing rather than wrong.
    static func isHighConfidenceMatch(localTitle: String?, localYear: String?, onlineTitle: String, onlineYear: String?) -> Bool {
        guard let localTitle = localTitle, localTitle.isEmpty == false else { return false }
        guard NamingReviewWindowController.normalizedForComparison(localTitle) ==
                NamingReviewWindowController.normalizedForComparison(onlineTitle) else { return false }

        if let localYear = localYear, let onlineYear = onlineYear {
            return localYear == onlineYear
        }
        return true
    }

    /// Lowercases, strips everything but letters/digits/whitespace, and
    /// collapses runs of whitespace -- enough to make "Some Movie Vol. 2"
    /// and "some movie vol 2" compare equal without pulling in a full
    /// fuzzy-matching library for what's meant to be a strict check.
    private static func normalizedForComparison(_ title: String) -> String {
        let lowered = title.lowercased()
        let kept = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)
        }
        let collapsed = String(String.UnicodeScalarView(kept))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
        return collapsed.joined(separator: " ")
    }

    /// Fires approve(_:) after a short delay rather than immediately, so
    /// the sheet visibly shows the matched name and an "auto-approving"
    /// status for a moment -- giving the user a real chance to hit
    /// Reject if a high-confidence match still looks wrong -- instead of
    /// resolving the release with no review step at all. Re-checks
    /// userEditedName when it fires (not just at scheduling time) in
    /// case the user started typing during the delay; also cancelled
    /// outright by controlTextDidChange(_:)/reject(_:)/approve(_:).
    private func scheduleAutoApprove(matchedSource: String) {
        statusLabel.stringValue = String(format: NSLocalizedString("Matched via %@ \u{2014} auto-approving\u{2026}", comment: "Naming review window -> search status"), matchedSource)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.userEditedName == false else { return }
            self.approve(nil)
        }
        autoApproveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    // MARK: Actions

    /// Both actions end the sheet QueueController presented this window
    /// as -- it reads finalName back and does the actual rename/stage
    /// transition on .OK, and just marks the release rejected on
    /// .cancel. See QueueController.reviewNaming(for:at:).
    @objc private func reject(_ sender: Any?) {
        autoApproveWorkItem?.cancel()
        endSheet(with: .cancel)
    }

    @objc private func approve(_ sender: Any?) {
        autoApproveWorkItem?.cancel()
        endSheet(with: .OK)
    }

    @objc private func pass(_ sender: Any?) {
        autoApproveWorkItem?.cancel()
        endSheet(with: NamingReviewWindowController.passResponse)
    }

    private func endSheet(with response: NSApplication.ModalResponse) {
        guard let window = window, let sheetParent = window.sheetParent else { return }
        sheetParent.endSheet(window, returnCode: response)
    }
}

extension NamingReviewWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        userEditedName = true
        autoApproveWorkItem?.cancel()
    }
}
