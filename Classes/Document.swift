//
//  Document.swift
//  Subler
//
//  Created by Damiano Galassi on 10/02/2018.
//

import Cocoa
import IOKit.pwr_mgt
import MP42Foundation

@objc(SBDocument)
final class Document: NSDocument {

    private(set) var mp4: MP42File
    private var unsupportedMp4Brand: Bool

    /// Set by DocumentController.openDocument(withContentsOf:) when this
    /// document was created to import a non-MP4 source (MKV, etc.) rather
    /// than opened directly -- that path creates a brand-new untitled
    /// document with no fileURL of its own (see showImportSheet(fileURLs:)),
    /// so without this, the first Save's panel has nothing tying it back
    /// to where the source file actually was and falls back to whatever
    /// directory NSSavePanel last remembers being in -- landing the saved
    /// file who-knows-where instead of next to the source ("completed
    /// torrents" folder, say). Only used to default prepareSavePanel(_:)'s
    /// directory below; never touched again afterward.
    var importSourceURL: URL?

    /// Set by LibraryScanWindowController when it opens a file for
    /// editing in place -- that file is already sitting wherever the
    /// user's existing library keeps it, often a folder shared with many
    /// other titles, so the new "no folder of its own yet -- create one"
    /// step in ensureOwnFolder(fileURL:targetName:) below should not run
    /// for it the way it would for a file saved somewhere else. Renaming
    /// the file itself to match its metadata (Prefs.renameFileToMatchMetadataOnSave)
    /// still happens either way; this only skips the folder-creation half.
    var skipsFolderCreationOnSave = false

    /// Called once when this document closes, with the file's location at
    /// that moment (a save can rename or move it). The Queue keeps a
    /// completed row's Edit button greyed out while the file is open here,
    /// and uses this to re-enable it and follow the file.
    var onClose: ((URL?) -> Void)?

    override func close() {
        let url = fileURL
        super.close()
        let handler = onClose
        onClose = nil
        handler?(url)
    }

    /// The file this document was built from, for a document made with
    /// init(mp4:) that ended up with no fileURL of its own (Queue >
    /// Edit on an item whose MP42File carries no URL). Only used as a
    /// fallback for deriving metadata-search terms from the file name --
    /// see DocumentWindowController.searchMetadata(_:).
    var sourceFileURLHint: URL?

    /// The approved release name, when this document was opened from a
    /// Queue release item. The metadata search uses it in preference to the
    /// file's own name, which inside a release is often just "01.mp4".
    var searchNameHint: String?

    override init() {
        self.cancelled = false
        self.options = [:]
        self.optimize = false
        self.unsupportedMp4Brand = false
        self.mp4 = MP42File()
        super.init()
        self.mp4.undo = undoManager
    }

    init(mp4: MP42File) {
        self.cancelled = false
        self.options = [:]
        self.optimize = false
        self.unsupportedMp4Brand = false
        self.mp4 = mp4
        super.init()

        if let url = mp4.url {
            fileURL = url
        } else {
            updateChangeCount(.changeDone)
        }
        self.mp4.undo = undoManager
    }

    override func makeWindowControllers() {
        let documentWindowController = DocumentWindowController()
        addWindowController(documentWindowController)
        documentWindowController.showWindow(self)

        if let url = fileURL, unsupportedMp4Brand {
            // We can't edit this file, so ask the user if it wants to import it
            documentWindowController.showImportSheet(fileURLs: [url])
            fileURL = nil
        }
    }

    // MARK: Read

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { return true }

    override public var isEntireFileLoaded: Bool { get { return false } }

    override func read(from url: URL, ofType typeName: String) throws {
        do {
            mp4 = try MP42File(url: url)
            mp4.undo = undoManager
        } catch {
            unsupportedMp4Brand = true
        }
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        mp4 = try MP42File(url: url)
        mp4.undo = undoManager

        if let docController = windowControllers.first as? DocumentWindowController {
            docController.reloadData()
            undoManager?.removeAllActions()
        }

        updateChangeCount(.changeCleared)
    }

    // MARK: Save

    override nonisolated class var autosavesInPlace: Bool { return false }

    private var optimize: Bool
    private var options: [String : Any]
    private var cancelled: Bool

    private func saveOptions(for saveOperation: NSDocument.SaveOperationType) -> [String : Any] {
        var options = [String : Any]()

        if Prefs.chaptersPreviewTrack {
            options[MP42GenerateChaptersPreviewTrack] = true
            options[MP42ChaptersPreviewPosition] = Prefs.chaptersPreviewPosition
        }

        if Prefs.forceHvc1 {
            options[MP42ForceHvc1] = true
        }

        if let accessoryViewController = accessoryViewController,
           saveOperation == .saveAsOperation || saveOperation == .saveToOperation {
            options[MP4264BitData] = accessoryViewController._64bit_data.state == .on ? true : false
            options[MP4264BitTime] = accessoryViewController._64bit_time.state == .on ? true : false
            optimize = accessoryViewController.optimize.state == .on ? true : false
        }

        return options
    }

    @IBAction func saveAndOptimize(_ sender: Any) {
        optimize = true
        save(self)
    }

    /// Whether the next completed save should prompt to open another file
    /// once it finishes (see saveAndOpen(_:) below). Consumed and reset to
    /// false as soon as that save finishes, so a plain save triggered
    /// afterwards (Cmd-S, etc.) doesn't also bring up the Open panel.
    private var openAfterSave: Bool = false

    /// Saves the current document, then -- once that finishes -- brings up
    /// the same Open panel Subler shows an untitled launch with
    /// (AppDelegate.applicationShouldOpenUntitledFile(_:) /
    /// NSDocumentController.openDocument(_:)), so picking up the next file
    /// in a batch never needs a trip to File > Open. This previously
    /// opened the just-saved file in its default external application
    /// instead (e.g. QuickTime) -- a different, unrelated feature that
    /// didn't serve the actual goal here: an easy way to move on to
    /// another file once the current one is done.
    @IBAction func saveAndOpen(_ sender: Any) {
        openAfterSave = true
        save(self)
    }

    /// Saves, and once the save has succeeded closes the document. With
    /// nothing to save it simply closes. A cancelled or failed save leaves
    /// the document open.
    @IBAction func saveAndClose(_ sender: Any) {
        guard isDocumentEdited else {
            close()
            return
        }
        save(withDelegate: self, didSave: #selector(document(_:didSaveThenClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, didSaveThenClose didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if didSave {
            close()
        }
    }

    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { return true }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        let docController = windowControllers.first as? DocumentWindowController

        let modifiedCompletionhandler = { (error: Error?) -> Void in
            docController?.endProgressReporting()

            if let error = error {
                completionHandler(error);
            } else {
                do {
                    let reloadedFile = try MP42File(url: url)

                    // A metadata item added blank (e.g. by applying a Set)
                    // has no data for the underlying MP4 tag-writing library
                    // to persist -- these atoms have no way to represent
                    // "present but empty", so it's silently dropped when the
                    // file is written. Re-reading the just-saved file below
                    // would otherwise make that field vanish from the table
                    // the instant Save completes, which reads as "my blank
                    // Set fields didn't save" even though nothing was lost
                    // that the file format could actually hold on to. Carry
                    // forward whatever was in the table before this save
                    // that the reload doesn't already account for, so the
                    // field only disappears once the document is closed and
                    // reopened -- when the file on disk genuinely is the
                    // only source of truth left.
                    let previousItems = self.mp4.metadata.items
                    let reloadedIdentifiers = Set(reloadedFile.metadata.items.map { $0.identifier })
                    let droppedOnWrite = previousItems.filter { reloadedIdentifiers.contains($0.identifier) == false }
                    if droppedOnWrite.isEmpty == false {
                        reloadedFile.metadata.addItems(droppedOnWrite)
                    }

                    self.mp4 = reloadedFile

                    self.mp4.undo = self.undoManager
                    self.undoManager?.removeAllActions()

                    if saveOperation == .saveOperation {
                        self.renameFileToMatchMetadataIfNeeded(currentURL: url)
                        EmptyFolderCleaner.runAutomaticallyIfEnabled()
                    }

                    docController?.reloadData()
                    if self.openAfterSave {
                        self.openAfterSave = false
                        NSDocumentController.shared.openDocument(self)
                    }
                    completionHandler(error)
                } catch {
                    completionHandler(error)
                }
            }
        }

        options = saveOptions(for: saveOperation)
        releaseSavePanel()

        docController?.startProgressReporting()
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: modifiedCompletionhandler)
    }

    func cancelSave() {
        cancelled = true
        mp4.cancel()
    }

    // MARK: Copyright

    /// Fills in Copyright from the tagged Release Date's year when
    /// Copyright itself hasn't been tagged (or was tagged blank) --
    /// "\u{00a9} 2019 Studio" when a Studio is tagged, "\u{00a9} 2019"
    /// otherwise. Runs on every save (unlike the file rename above, which
    /// only applies to an in-place save), since filling in a blank field
    /// never risks anything the way renaming/moving the file could.
    /// Leaves an already-present, non-blank Copyright alone -- this only
    /// ever fills a gap, never overwrites what's there.
    private func fillMissingCopyrightIfNeeded() {
        let existing = mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCopyright).first?.stringValue
        if let existing = existing, existing.isEmpty == false {
            return
        }

        guard let year = ParsedMediaName.firstFourDigitYear(in: mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyReleaseDate).first?.stringValue) else {
            return
        }

        let studio = mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyStudio).first?.stringValue
            .flatMap { $0.isEmpty ? nil : $0 }

        let copyright = studio.map { "\u{00a9} \(year) \($0)" } ?? "\u{00a9} \(year)"

        if let existingItem = mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCopyright).first {
            mp4.metadata.removeItem(existingItem)
        }
        let item = MP42MetadataItem(identifier: MP42MetadataKeyCopyright, value: copyright as NSString, dataType: .string, extendedLanguageTag: nil)
        mp4.metadata.addItem(item)
    }

    // MARK: Series Description

    /// Fills the Series Description tag from a detected sequel/part
    /// indicator on the Title (or, if Title doesn't have one, the file's
    /// own current name) -- see SeriesTitleDetector.baseSeriesTitle(from:)
    /// and Prefs.fillSeriesDescriptionOnSave. Runs on every save (like
    /// fillMissingCopyrightIfNeeded() above, and for the same reason: it
    /// has to happen here, before the actual write, for the change to be
    /// part of this save rather than needing a second one) while this
    /// file still has its original, pre-rename name, since that's what
    /// the filename fallback needs to look at -- renameFileToMatchMetadataIfNeeded's
    /// own file rename happens afterward, once this save has already
    /// completed. Unlike the Copyright fill, this always overwrites
    /// whatever Series Description already says rather than only filling
    /// a blank one -- see Prefs.fillSeriesDescriptionOnSave's own comment
    /// for why.
    private func fillSeriesDescriptionIfNeeded(originalFileURL: URL) {
        guard Prefs.fillSeriesDescriptionOnSave else { return }

        let currentTitle = mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue

        let baseSeriesTitle: String?
        if let title = currentTitle, let base = SeriesTitleDetector.baseSeriesTitle(from: title) {
            baseSeriesTitle = base
        } else {
            let filenameStem = originalFileURL.deletingPathExtension().lastPathComponent
            baseSeriesTitle = SeriesTitleDetector.baseSeriesTitle(from: filenameStem)
        }

        guard let seriesTitle = baseSeriesTitle, seriesTitle.isEmpty == false else { return }

        if let existingItem = mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeySeriesDescription).first {
            mp4.metadata.removeItem(existingItem)
        }
        let item = MP42MetadataItem(identifier: MP42MetadataKeySeriesDescription, value: seriesTitle as NSString, dataType: .string, extendedLanguageTag: nil)
        mp4.metadata.addItem(item)

        NSLog("[SeriesDescription] Detected a series/part indicator -- set Series Description to \"\(seriesTitle)\"")
    }

    // MARK: Rename to match metadata

    /// Renames the just-saved file to match its own tagged metadata,
    /// following the "Filename" preferences tab's settings -- the Movie
    /// naming-rule list (NamingRules.swift) or the TV Show token template,
    /// via MP42File.formattedFileName() -- the exact same naming function
    /// Save As's suggested name and the Queue's "Set output filename"
    /// action both use, so all three stay consistent with whatever's
    /// configured there. Only called after an in-place Save
    /// (.saveOperation): a Save As/Save To already had the user
    /// deliberately choose the destination name, which this must never
    /// second-guess.
    ///
    /// Does nothing if the preference is off, if there's no usable name to
    /// give the file (formattedFileName() has nothing to build one from),
    /// if the computed name is already what the file is called, or if the
    /// rename can't be completed safely (e.g. something else already sits
    /// at the destination and isn't just this same file under a different
    /// case) -- in every one of those cases the existing file name is left
    /// alone rather than guessed at.
    private func renameFileToMatchMetadataIfNeeded(currentURL: URL) {
        // The folder step has its own toggle (Prefs.syncMovieFolderNameOnSave /
        // useAppleTVStyleTVFolders, checked by preferredOutputSubfolder()),
        // independent of the file-rename toggle -- same as the Queue, whose
        // folder creation doesn't depend on a rename. So with the rename
        // pref off the file keeps its name but still gets its folder.
        guard Prefs.renameFileToMatchMetadataOnSave else {
            syncFolderStructureIfNeeded(fileURL: currentURL)
            return
        }

        guard let baseName = mp4.formattedFileName(), baseName.isEmpty == false else {
            syncFolderStructureIfNeeded(fileURL: currentURL)
            return
        }

        let ext = currentURL.pathExtension
        let desiredName = ext.isEmpty ? baseName : "\(baseName).\(ext)"

        // The file's name might already be right while its *folder* isn't
        // (e.g. the metadata changed after the file was first named, or
        // syncFolderStructureIfNeeded's own toggle was only just turned
        // on) -- so this no longer returns early when there's no filename
        // change to make; it just skips straight to the folder/subfolder
        // step below with the file's current location.
        var renamedURL = currentURL

        if desiredName != currentURL.lastPathComponent {
            let directory = currentURL.deletingLastPathComponent()
            let fileManager = FileManager.default

            var candidateURL = directory.appendingPathComponent(desiredName)
            var suffix = 2

            while fileManager.fileExists(atPath: candidateURL.path) {
                // Case-insensitive filesystems (the macOS default) report the
                // file's own current name as already existing -- that's not a
                // real collision, it's the rename we're about to do.
                if candidateURL.standardizedFileURL.path.caseInsensitiveCompare(currentURL.standardizedFileURL.path) == .orderedSame {
                    break
                }
                let numberedName = ext.isEmpty ? "\(baseName) \(suffix)" : "\(baseName) \(suffix).\(ext)"
                candidateURL = directory.appendingPathComponent(numberedName)
                suffix += 1
            }

            do {
                try fileManager.moveItem(at: currentURL, to: candidateURL)
                fileURL = candidateURL
                renamedURL = candidateURL
            } catch {
                NSLog("[Document] Couldn't rename \(currentURL.lastPathComponent) to \(candidateURL.lastPathComponent): \(error.localizedDescription)")
                return
            }
        }

        syncFolderStructureIfNeeded(fileURL: renamedURL)
    }

    /// Dispatches to the Movie or TV Show folder-structure step, per the
    /// "Filename" preferences tab's own per-media-kind toggle --
    /// MP42File.preferredOutputSubfolder() is nil (a no-op here) unless
    /// the relevant one (Prefs.syncMovieFolderNameOnSave /
    /// Prefs.useAppleTVStyleTVFolders) is actually on.
    private func syncFolderStructureIfNeeded(fileURL: URL) {
        guard let subfolder = mp4.preferredOutputSubfolder() else {
            NSLog("[FolderSync] syncFolderStructureIfNeeded: preferredOutputSubfolder() was nil, see preceding log line for why -- not touching any folder")
            return
        }

        guard let mediaKindValue = mp4.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue,
              let mediaKind = MediaKind(rawValue: mediaKindValue)
            else {
                NSLog("[FolderSync] syncFolderStructureIfNeeded: no Media Kind tagged -- not touching any folder")
                return
            }

        NSLog("[FolderSync] syncFolderStructureIfNeeded: fileURL=\(fileURL.path) mediaKind=\(mediaKind) subfolder=\(subfolder)")

        guard fileURL.deletingLastPathComponent().isAutomaticMediaIngestFolder == false else {
            NSLog("[FolderSync] syncFolderStructureIfNeeded: destination is an Automatically Add to iTunes/TV folder -- leaving it alone for that app's own ingestion")
            return
        }

        // Automatic delivery to an Automatically Add folder: the file alone
        // goes there, with no folder of its own.
        if let ingest = mp4.deliveryFolder, ingest.isAutomaticMediaIngestFolder {
            let fileManager = FileManager.default
            let target = QueueController.uniqueFileDestination(for: ingest.appendingPathComponent(fileURL.lastPathComponent))
            do {
                try fileManager.createDirectory(at: ingest, withIntermediateDirectories: true)
                try fileManager.moveItem(at: fileURL, to: target)
                self.fileURL = target
                NSLog("[FolderSync] syncFolderStructureIfNeeded: moved \(target.lastPathComponent) into the Automatically Add folder")
            } catch {
                NSLog("[FolderSync] FAILED: couldn't move \(fileURL.lastPathComponent) into the Automatically Add folder: \(error.localizedDescription)")
                recoverFromFolderMoveFailure(error: error, fileURL: fileURL, folderName: fileURL.deletingPathExtension().lastPathComponent, movingWholeFolder: false, partialDestination: target)
            }
            return
        }

        switch mediaKind {
        case .movie:
            ensureOwnFolder(fileURL: fileURL, targetName: subfolder)
        case .tvShow:
            nestIntoSubfolders(fileURL: fileURL, subfolderPath: subfolder)
        }
    }

    /// File extensions ensureOwnFolder(fileURL:targetName:)
    /// treats as always-safe release companions regardless of their own
    /// name -- common scene/torrent-release metadata, readme, and
    /// cover-art files, never anything that could itself be an unrelated
    /// video.
    private static let folderRenameCompanionExtensions: Set<String> = [
        "nfo", "sfv", "srr", "txt", "diz", "nzb", "url", "jpg", "jpeg", "png"
    ]

    /// Decides between the two ways this movie ends up in a folder of its
    /// own named `targetName` (Prefs.syncMovieFolderNameOnSave): renaming
    /// its current folder if that folder already belongs to just this one
    /// file (renameEnclosingFolder(fileURL:currentFolder:to:) below), or
    /// -- new -- creating a brand new folder and moving just this file
    /// into it when the current folder is shared with other, unrelated
    /// content (createOwnFolderAndMove(fileURL:to:) below), e.g. a file
    /// sitting loose directly in a general library/downloads folder
    /// rather than its own per-movie folder. Skipped entirely for a file
    /// opened via LibraryScanWindowController (skipsFolderCreationOnSave)
    /// -- that file is already wherever the user's library keeps it, and
    /// unlike a freshly-downloaded file, a shared folder there is the
    /// normal, expected place for it to stay.
    ///
    /// Whichever of the two ways applies, when a Ready for Media Library
    /// folder is configured (MediaIntakePrefs.readyForLibraryFolder, Media
    /// Intake settings) the resulting folder lands there instead of
    /// staying beside wherever the source file happened to be -- see both
    /// functions' own comments. Leave that preference unset to keep
    /// today's behavior (folder created/renamed in place).
    private func ensureOwnFolder(fileURL: URL, targetName: String) {
        let currentFolder = fileURL.deletingLastPathComponent()

        // The ordinary (no Ready for Media Library configured) fast path
        // is unchanged: a folder already named right means nothing to
        // do. With one configured, a correctly-named folder sitting
        // somewhere other than Ready for Media Library still needs to
        // move there, so this short-circuit is skipped and the checks
        // below fall through to renameEnclosingFolder(fileURL:currentFolder:to:)
        // -- which does its own, more specific "already there" check --
        // instead of stopping here.
        if mp4.deliveryFolder == nil {
            guard currentFolder.lastPathComponent != targetName else {
                NSLog("[FolderSync] ensureOwnFolder: folder \(currentFolder.lastPathComponent) already named \(targetName) -- nothing to do")
                return
            }
        }

        let fileManager = FileManager.default
        let currentStem = fileURL.deletingPathExtension().lastPathComponent

        guard let siblings = try? fileManager.contentsOfDirectory(at: currentFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            NSLog("[FolderSync] ensureOwnFolder: couldn't list contents of \(currentFolder.path) -- skipping")
            return
        }

        let otherSiblings = siblings.filter { $0.standardizedFileURL != fileURL.standardizedFileURL }
        let folderBelongsToThisFileAlone = otherSiblings.allSatisfy { sibling in
            let isDirectory = (try? sibling.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory == false else { return false }
            if sibling.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(currentStem) == .orderedSame {
                return true
            }
            // Scene/torrent-release folders almost always carry a handful
            // of small companion files alongside the actual video --
            // .nfo/.sfv/.srr release info, cover art, a .txt readme -- with
            // no relationship to the video's own file name at all. Treating
            // every one of those as "unrelated content" blocked the folder
            // rename on exactly the kind of folder ("completed torrents")
            // this preference is meant for. A real second video, a
            // subtitle/artwork file that shares the stem, or anything else
            // not on this short, explicitly-non-video list still blocks
            // the rename exactly as before.
            return Document.folderRenameCompanionExtensions.contains(sibling.pathExtension.lowercased())
        }

        if folderBelongsToThisFileAlone {
            renameEnclosingFolder(fileURL: fileURL, currentFolder: currentFolder, to: targetName)
        } else if skipsFolderCreationOnSave {
            NSLog("[FolderSync] ensureOwnFolder: \(currentFolder.lastPathComponent) is a shared folder and this file was opened for in-place editing (Library Scan) -- leaving it where it is")
        } else {
            NSLog("[FolderSync] ensureOwnFolder: \(currentFolder.lastPathComponent) also holds unrelated item(s) -- \(otherSiblings.map { $0.lastPathComponent }) -- not this file's stem (\(currentStem)), treating it as a plain/shared destination and creating a new folder instead of renaming it")
            createOwnFolderAndMove(fileURL: fileURL, to: targetName)
        }
    }

    /// Renames fileURL's enclosing folder to `targetName` -- only reached
    /// once ensureOwnFolder(fileURL:targetName:) above has already
    /// confirmed that folder belongs to just this one file, so there's
    /// nothing else in there that renaming would orphan or misname. Also
    /// a no-op if the target name is already taken by something else --
    /// this never overwrites or merges folders, only ever a plain rename
    /// of one folder that's provably just this file's own.
    private func renameEnclosingFolder(fileURL: URL, currentFolder: URL, to targetName: String) {
        let fileManager = FileManager.default

        // When a Ready for Media Library folder is configured
        // (MediaIntakePrefs.readyForLibraryFolder), a movie that's just
        // gotten its own correctly-named folder is "finished" in the
        // same sense a release that went through the full Intake/Queue
        // pipeline is once QueueMoveToLibraryAction lands it there (see
        // that class) -- so it lands in that same staging folder too,
        // instead of staying beside wherever its source file happened to
        // be (a downloads/torrents folder, say). Collisions there are
        // resolved the same Finder-style way
        // (QueueController.uniqueFolderDestination(for:)) that action
        // already uses, rather than silently refusing like the plain
        // in-place rename below does -- a shared staging folder is far
        // more likely to already hold something using that exact name
        // than a torrent/download's own folder is.
        if let readyForLibraryFolder = mp4.deliveryFolder {
            let candidate = readyForLibraryFolder.appendingPathComponent(targetName)

            guard currentFolder.standardizedFileURL != candidate.standardizedFileURL else {
                NSLog("[FolderSync] renameEnclosingFolder: \(currentFolder.lastPathComponent) is already named \(targetName) and already in Ready for Media Library -- nothing to do")
                return
            }

            let targetFolder = QueueController.uniqueFolderDestination(for: candidate)

            do {
                try fileManager.createDirectory(at: readyForLibraryFolder, withIntermediateDirectories: true)
                try fileManager.moveItem(at: currentFolder, to: targetFolder)
                self.fileURL = targetFolder.appendingPathComponent(fileURL.lastPathComponent)
                NSLog("[FolderSync] renameEnclosingFolder: moved \(currentFolder.lastPathComponent) to Ready for Media Library as \(targetFolder.lastPathComponent)")
            } catch {
                NSLog("[FolderSync] FAILED: couldn't move folder \(currentFolder.lastPathComponent) to Ready for Media Library: \(error.localizedDescription)")
                recoverFromFolderMoveFailure(error: error, fileURL: fileURL, folderName: targetName, movingWholeFolder: true, partialDestination: targetFolder)
            }
            return
        }

        let parentDirectory = currentFolder.deletingLastPathComponent()
        let targetFolder = parentDirectory.appendingPathComponent(targetName)
        guard currentFolder.lastPathComponent != targetName else {
            NSLog("[FolderSync] renameEnclosingFolder: folder \(currentFolder.lastPathComponent) already named \(targetName) -- nothing to do")
            return
        }
        guard fileManager.fileExists(atPath: targetFolder.path) == false else {
            NSLog("[FolderSync] renameEnclosingFolder: a folder named \(targetName) already exists at \(targetFolder.path) -- not renaming into it")
            return
        }

        do {
            try fileManager.moveItem(at: currentFolder, to: targetFolder)
            self.fileURL = targetFolder.appendingPathComponent(fileURL.lastPathComponent)
            NSLog("[FolderSync] renameEnclosingFolder: renamed \(currentFolder.lastPathComponent) to \(targetName)")
        } catch {
            NSLog("[FolderSync] FAILED: couldn't rename folder \(currentFolder.lastPathComponent) to \(targetFolder.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Called when moving a just-saved movie (or its whole folder) into the
    /// Ready for Media Library folder fails -- typically because that
    /// volume is out of space or has gone offline. First cleans up what
    /// the failed attempt left behind (an empty folder, or a partial copy
    /// while the original is still intact), then tells the user and offers
    /// a file-navigator to pick another destination, retrying the same
    /// move there. "Leave Where It Is" keeps the file where it is, saved
    /// with its new metadata.
    private func recoverFromFolderMoveFailure(error: Error, fileURL: URL, folderName: String, movingWholeFolder: Bool, partialDestination: URL) {
        let itemURL = movingWholeFolder ? fileURL.deletingLastPathComponent() : fileURL
        if let folder = FolderMoveRecovery.recover(error: error, itemURL: itemURL, folderName: folderName, movingWholeFolder: movingWholeFolder, partialDestination: partialDestination) {
            self.fileURL = folder.appendingPathComponent(fileURL.lastPathComponent)
        }
    }

    /// Creates a new subfolder named `targetName` inside fileURL's current
    /// folder and moves just this one file into it -- for the case where
    /// the file is sitting loose in a shared/plain directory (a library
    /// or downloads root, not a folder already dedicated to just this
    /// movie -- see renameEnclosingFolder(fileURL:currentFolder:to:)
    /// above for that other case). Never touches any other file already
    /// in the current folder. A no-op if something already exists at the
    /// target folder path.
    private func createOwnFolderAndMove(fileURL: URL, to targetName: String) {
        let currentFolder = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        // Same Ready for Media Library redirect as
        // renameEnclosingFolder(fileURL:currentFolder:to:) above -- see
        // that function's comment for the rationale and the collision
        // handling the two share. Here the new folder is created
        // directly under Ready for Media Library instead of inside
        // fileURL's current (shared) folder, rather than creating it
        // locally and then having to move it a second time.
        if let readyForLibraryFolder = mp4.deliveryFolder {
            let candidate = readyForLibraryFolder.appendingPathComponent(targetName)
            let targetFolder = QueueController.uniqueFolderDestination(for: candidate)

            do {
                try fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                let destination = targetFolder.appendingPathComponent(fileURL.lastPathComponent)
                try fileManager.moveItem(at: fileURL, to: destination)
                self.fileURL = destination
                NSLog("[FolderSync] createOwnFolderAndMove: moved \(fileURL.lastPathComponent) into a new Ready for Media Library folder \(targetFolder.lastPathComponent)")
            } catch {
                NSLog("[FolderSync] FAILED: couldn't create folder \(targetName) in Ready for Media Library for \(fileURL.lastPathComponent): \(error.localizedDescription)")
                recoverFromFolderMoveFailure(error: error, fileURL: fileURL, folderName: targetName, movingWholeFolder: false, partialDestination: targetFolder)
            }
            return
        }

        let targetFolder = currentFolder.appendingPathComponent(targetName)

        guard fileManager.fileExists(atPath: targetFolder.path) == false else {
            NSLog("[FolderSync] createOwnFolderAndMove: a folder named \(targetName) already exists at \(targetFolder.path) -- not creating it")
            return
        }

        do {
            try fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)
            let destination = targetFolder.appendingPathComponent(fileURL.lastPathComponent)
            try fileManager.moveItem(at: fileURL, to: destination)
            self.fileURL = destination
            NSLog("[FolderSync] createOwnFolderAndMove: moved \(fileURL.lastPathComponent) into new folder \(targetName)")
        } catch {
            NSLog("[FolderSync] FAILED: couldn't create folder \(targetName) for \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Moves fileURL down into "<subfolderPath>/" (Prefs.useAppleTVStyleTVFolders),
    /// creating whatever subfolders don't exist yet -- normally beneath
    /// fileURL's own current folder, left otherwise untouched, so unlike
    /// ensureOwnFolder(fileURL:targetName:) above it needs no "does this
    /// folder belong to just me" check; see that root's own doc comment
    /// for the one exception, where a Ready for Media Library folder is
    /// configured and this is rooted there instead. A no-op if the file
    /// is already nested that way, or if something else already sits at
    /// the destination.
    private func nestIntoSubfolders(fileURL: URL, subfolderPath: String) {
        let components = subfolderPath.split(separator: "/").map(String.init)
        guard components.isEmpty == false else { return }

        let fileManager = FileManager.default

        // Same Ready for Media Library redirect
        // ensureOwnFolder(fileURL:targetName:) already gives Movies -- a
        // finished TV episode lands there too. Unlike a Movie's one-shot,
        // collision-suffixed folder (renameEnclosingFolder(fileURL:currentFolder:to:)/
        // createOwnFolderAndMove(fileURL:to:) above), the show folder here
        // is reused by exact name across every episode -- there's only
        // ever meant to be one "<Show>" folder in the library -- with just
        // the season subfolder beneath it created as needed, matching
        // QueueSetOutputFilenameAction's identical TV branch
        // (Classes/QueueAction.swift) for the straight-through-the-Queue
        // path.
        if let readyForLibraryFolder = mp4.deliveryFolder {
            var targetFolder = readyForLibraryFolder
            for component in components {
                targetFolder.appendPathComponent(component)
            }

            let targetURL = targetFolder.appendingPathComponent(fileURL.lastPathComponent)

            guard fileURL.standardizedFileURL != targetURL.standardizedFileURL else {
                NSLog("[FolderSync] nestIntoSubfolders: \(fileURL.lastPathComponent) is already nested in Ready for Media Library at \(subfolderPath) -- nothing to do")
                return
            }
            guard fileManager.fileExists(atPath: targetURL.path) == false else {
                NSLog("[FolderSync] nestIntoSubfolders: something already exists at \(targetURL.path) -- not moving into it")
                return
            }

            do {
                try fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                try fileManager.moveItem(at: fileURL, to: targetURL)
                self.fileURL = targetURL
                NSLog("[FolderSync] nestIntoSubfolders: moved \(fileURL.lastPathComponent) into Ready for Media Library as \(subfolderPath)")
            } catch {
                NSLog("[Document] Couldn't move \(fileURL.lastPathComponent) into Ready for Media Library at \(targetFolder.path): \(error.localizedDescription)")
            }
            return
        }

        let currentFolder = fileURL.deletingLastPathComponent()

        var ancestor = currentFolder
        var alreadyNested = true
        for component in components.reversed() {
            guard ancestor.lastPathComponent == component else {
                alreadyNested = false
                break
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
        guard alreadyNested == false else { return }

        var targetFolder = currentFolder
        for component in components {
            targetFolder.appendPathComponent(component)
        }

        let targetURL = targetFolder.appendingPathComponent(fileURL.lastPathComponent)
        guard fileManager.fileExists(atPath: targetURL.path) == false else { return }

        do {
            try fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)
            try fileManager.moveItem(at: fileURL, to: targetURL)
            self.fileURL = targetURL
        } catch {
            NSLog("[Document] Couldn't nest \(fileURL.lastPathComponent) into \(targetFolder.path): \(error.localizedDescription)")
        }
    }

    private var sleepAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var sleepAssertionSuccess: IOReturn = kIOReturnInvalid

    private func preventSleep() {
        sleepAssertionSuccess = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                  "Media Metadata Manager Save Operation" as CFString,
                                                  &sleepAssertion)
    }

    private func allowSleep() {
        if sleepAssertionSuccess == kIOReturnSuccess {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertionSuccess = kIOReturnInvalid
            sleepAssertion = IOPMAssertionID(0)
        }
    }

    override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        unblockUserInteraction()
        preventSleep()

        if Prefs.organizeAlternateGroups {
            mp4.organizeAlternateGroups()
            if Prefs.inferMediaCharacteristics {
                mp4.inferTracksLanguages()
                mp4.inferMediaCharacteristics()
            }
        }

        fillMissingCopyrightIfNeeded()
        fillSeriesDescriptionIfNeeded(originalFileURL: url)

        defer {
            allowSleep()
            optimize = false
            options = [:]
        }

        switch saveOperation {
        case .saveOperation:
            try mp4.update(options: options)
        case .saveAsOperation:
            try mp4.write(to: url, options: options)
        default:
            fatalError("Unsupported save operation")
        }

        if optimize && cancelled == false {
            DispatchQueue.main.async {
                let docController = self.windowControllers.first as? DocumentWindowController
                docController?.setProgress(title: NSLocalizedString("Optimizing…", comment: "Document Optimize sheet."))
            }
            mp4.optimize()
        }

        cancelled = false
    }

    // MARK: Save panel

    private var accessoryViewController: SaveOptions?

    override var shouldRunSavePanelWithAccessoryView: Bool { return false }
    
    override var savePanelShowsFileFormatsControl: Bool { return false }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        self.accessoryViewController = SaveOptions(doc: self, savePanel: savePanel)

        savePanel.isExtensionHidden = false
        savePanel.accessoryView = accessoryViewController?.view

        // First save of a document that was created to import a non-MP4
        // source (see importSourceURL above) -- default the panel to the
        // source file's own folder instead of NSSavePanel's own last-used
        // directory, which has no relationship to this document at all.
        // Only applies the very first time: once fileURL is set (this
        // document has been saved at least once), the panel already
        // defaults to that location on its own.
        if fileURL == nil, let importSourceURL = importSourceURL {
            savePanel.directoryURL = importSourceURL.deletingLastPathComponent()
        }

        return true
    }

    private func releaseSavePanel() {
        accessoryViewController?.saveUserDefaults()
        accessoryViewController = nil
    }

    // MARK: Queue
    @IBAction func sendToQueue(_ sender: Any) {
        guard let windowForSheet = windowForSheet else { return }

        let queue = QueueController.shared
        if mp4.hasFileRepresentation {
            let item = QueueItem(mp4: mp4)
            queue.add(item, applyPreset: true)
            close()
        }
        else {
            let panel = NSSavePanel()
            panel.prompt = NSLocalizedString("Send To Queue", comment: "")

            let handler = { (response: NSApplication.ModalResponse) in
                if response == NSApplication.ModalResponse.OK, let url = panel.url {
                    let options = self.saveOptions(for: .saveAsOperation)
                    let item = QueueItem(mp4: self.mp4, destURL: url, attributes: options, optimize: self.optimize)
                    queue.add(item)
                    self.releaseSavePanel()
                    self.close()
                }
            }

            if prepareSavePanel(panel) {
                panel.beginSheetModal(for: windowForSheet, completionHandler: handler)
            }
        }
    }

    // MARK: User interface validation

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(revertToSaved(_:)) where isDocumentEdited == true:
            return true
        case #selector(save(_:)) where isDocumentEdited == true:
            return true
        case #selector(saveAndOpen(_:)) where isDocumentEdited == true:
            return true
        case #selector(saveAs(_:)),
             #selector(saveAndClose(_:)),
             #selector(sendToQueue(_:)):
            return true
        case #selector(saveAndOptimize(_:)) where isDocumentEdited == false && mp4.hasFileRepresentation == true:
            return true
        default:
            return false
        }
    }

}
