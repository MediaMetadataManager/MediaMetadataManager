//
//  QueueItem.swift
//  Subler
//
//  Created by Damiano Galassi on 28/01/2019.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Source-folder grouping, missing and renamed file handling, edit in place.
//

import Cocoa
import MP42Foundation

@objc(SBQueueItem) final class QueueItem: NSObject, NSSecureCoding {

    @objc enum Status: Int {
        case ready
        case editing
        case working
        case completed
        case failed
        case cancelled
    }

    private var destURLInternal: URL
    #if SB_SANDBOX
    private let destURLInternalBookmark: Data?
    #endif

    @objc dynamic private(set) var fileURL: URL
    #if SB_SANDBOX
    private let fileURLBookmark: Data?
    #endif

    @objc dynamic var destURL: URL {
        get {
            return queue.sync { destURLInternal }
        }
        set (value) {
            queue.sync { destURLInternal = value }
        }
    }

    /// Points the item at the file it was renamed to outside the app. The
    /// output keeps its folder, and takes the new name if it used to share the
    /// old file's name.
    func relocate(to newFileURL: URL) {
        let oldName = fileURL.lastPathComponent
        let output = destURL
        if output.lastPathComponent == oldName {
            destURL = output.deletingLastPathComponent().appendingPathComponent(newFileURL.lastPathComponent)
        }
        fileURL = newFileURL
    }

    var mp4File: MP42File?
    var localizedWorkingDescription: String?

    /// The folder this item was added from, when it was added as part of
    /// a folder (QueueController.insertFolder(_:at:)) rather than picked
    /// or dropped individually -- nil for every other way of adding an
    /// item. Display-only: it drives the indented look of this item's row
    /// under its folder's header row (QueueController.tableView(_:viewFor
    /// :row:)) and nothing about how the item itself is processed.
    let sourceFolderURL: URL?

    /// True for a file edited where it sits, with no new copy written and no
    /// move to the library (a file already in the staging folder, or one
    /// sent from the Library scan). The Set Name step then leaves the
    /// destination alone and the file is renamed in place afterwards.
    var editsInPlace = false

    /// The tags (MP42 metadata identifiers) whose values the Queue shows as
    /// extra columns for this item: set for files sent from the Library scan,
    /// so the scan's columns carry over. Empty for every other item.
    var trackedTagKeys: [String] = []

    weak var delegate: Queue?

    private var statusInternal: Status
    @objc private let uniqueID: String
    private var attributes: [String : Any]
    private var actionsInternal: [QueueActionProtocol]

    private var cancelled: Bool
    private let queue: DispatchQueue

    private init(fileURL: URL, destURL: URL, sourceFolderURL: URL? = nil) {
        statusInternal = .ready
        uniqueID = UUID().uuidString
        actionsInternal = []
        attributes = [:]
        cancelled = false
        self.fileURL = fileURL
        self.destURLInternal = destURL
        self.sourceFolderURL = sourceFolderURL
        #if SB_SANDBOX
        fileURLBookmark = nil
        destURLInternalBookmark = nil
        #endif
        queue = DispatchQueue(label: "com.mediametadatamanager.itemQueue")
    }

    convenience init(fileURL: URL, destination: URL, sourceFolderURL: URL? = nil) {
        self.init(fileURL: fileURL, destURL: destination, sourceFolderURL: sourceFolderURL)

        var url = fileURL
        url.removeCachedResourceValue(forKey: URLResourceKey.fileSizeKey)
        let value = try? url.resourceValues(forKeys: [URLResourceKey.fileSizeKey])

        if let fileSize = value?.fileSize, fileSize > 3800000000 {
            attributes[MP4264BitData] = true
        }

        if Prefs.chaptersPreviewTrack {
            attributes[MP42GenerateChaptersPreviewTrack] = true
            attributes[MP42ChaptersPreviewPosition] = Prefs.chaptersPreviewPosition
        }

        if Prefs.forceHvc1 {
            attributes[MP42ForceHvc1] = true
        }
    }

    convenience init(mp4: MP42File) {
        self.init(fileURL: mp4.url!, destURL: mp4.url!)
        mp4File = mp4

        if Prefs.chaptersPreviewTrack {
            attributes[MP42GenerateChaptersPreviewTrack] = true
            attributes[MP42ChaptersPreviewPosition] = Prefs.chaptersPreviewPosition
        }

        if Prefs.forceHvc1 {
            attributes[MP42ForceHvc1] = true
        }
    }

    convenience init(mp4: MP42File, destURL: URL, attributes: [String : Any] = [:], optimize: Bool = false) {
        self.init(fileURL: destURL, destURL: destURL)
        self.mp4File = mp4
        self.attributes = attributes

        if Prefs.forceHvc1 {
            self.attributes[MP42ForceHvc1] = true
        }

        if optimize {
            addAction(QueueOptimizeAction())
        }
    }

    // MARK: Public properties

    @objc dynamic var status: Status {
        get {
            return queue.sync { statusInternal }
        }
        set (newStatus) {
            queue.sync { statusInternal = newStatus }
        }
    }

    // MARK: Actions

    @objc dynamic var actions: [QueueActionProtocol] {
        get {
            return queue.sync { actionsInternal }
        }
    }

    func addAction(_ action: QueueActionProtocol) {
        willChangeValue(for: \.actions)
        queue.sync { actionsInternal.append(action) }
        didChangeValue(for: \.actions)
    }

    /// True when the finished file is also rewritten to optimize it.
    var willOptimize: Bool { return actions.contains { $0 is QueueOptimizeAction } }

    func replaceAction(at index: Int, with action: QueueActionProtocol) {
        willChangeValue(for: \.actions)
        queue.sync {
            if actionsInternal.indices.contains(index) { actionsInternal[index] = action }
        }
        didChangeValue(for: \.actions)
    }

    func removeAction(at index: Int) {
        willChangeValue(for: \.actions)
        _ = queue.sync { actionsInternal.remove(at: index) }
        didChangeValue(for: \.actions)
    }

    // MARK: Item processing

    enum ProcessError: Error {
        case fileExists
        case fileNotFound
        case outOfDiskSpace
        case optimizationFailure
    }

    private func checkDiskSpace(at url: URL) -> Int {
        var directoryURL = url
        directoryURL.removeCachedResourceValue(forKey: .volumeAvailableCapacityKey)
        let value = try? directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let availableCapacity = value?.volumeAvailableCapacity {
            return availableCapacity
        } else {
            return 0
        }
    }

    private func configureAudio(track: MP42AudioTrack, mp4: MP42File) {
        var conversionNeeded = false

        let bitrate = Prefs.audioBitrate
        let drc = Prefs.audioDRC
        let mixdown = MP42AudioMixdown(Prefs.audioMixdown)

        // AC-3 track, we might need to do the aac + ac3 trick.
        if track.format == kMP42AudioCodecType_AC3 ||
            track.format == kMP42AudioCodecType_EnhancedAC3 {

            if Prefs.audioConvertAC3 {
                if Prefs.audioKeepAC3 && track.fallbackTrack == nil {
                    let copy = track.copy() as! MP42AudioTrack
                    let settings = MP42AudioConversionSettings(format: kMP42AudioCodecType_MPEG4AAC, bitRate: bitrate, mixDown: mixdown, drc: drc)
                    copy.conversionSettings = settings

                    track.fallbackTrack = copy
                    track.isEnabled = false

                    mp4.addTrack(copy)
                } else {
                    conversionNeeded = true
                }
            }
        }
        // DTS -> convert only if specified in the prefs.
        else if track.format ==  kMP42AudioCodecType_DTS {
            if Prefs.audioConvertDts {
                switch Prefs.audioDtsOptions {
                case 1: // Convert to AC-3

                    let copy = track.copy() as! MP42AudioTrack
                    let settings = MP42AudioConversionSettings(format: kMP42AudioCodecType_MPEG4AAC, bitRate: bitrate, mixDown: mixdown, drc: drc)
                    copy.conversionSettings = settings

                    track.fallbackTrack = copy
                    track.isEnabled = false

                    // Wouldn't it be better to use pref settings too instead of 640/Multichannel and the drc from the prefs?
                    track.conversionSettings = MP42AudioConversionSettings(format: kMP42AudioCodecType_AC3, bitRate: 640, mixDown: kMP42AudioMixdown_None, drc: drc)

                    mp4.addTrack(copy)

                case 2: // Keep DTS

                    let copy = track.copy() as! MP42AudioTrack
                    let settings = MP42AudioConversionSettings(format: kMP42AudioCodecType_MPEG4AAC, bitRate: bitrate, mixDown: mixdown, drc: drc)
                    copy.conversionSettings = settings

                    track.fallbackTrack = copy
                    track.isEnabled = false

                    mp4.addTrack(copy)

                default:
                    conversionNeeded = true
                }
            }
        }

        // If an audio track needs to be converted, apply the mixdown from the preferences.
        if trackNeedConversion(track.format) || conversionNeeded {
            let settings = MP42AudioConversionSettings(format: kMP42AudioCodecType_MPEG4AAC, bitRate: bitrate, mixDown: mixdown, drc: drc)
            track.conversionSettings = settings
        }
    }

    private func configureSubtitles(track: MP42SubtitleTrack, mp4: MP42File) {
        // VobSub -> only if specified in the prefs.
        if track.format == kMP42SubtitleCodecType_VobSub && Prefs.subtitleConvertBitmap {
            let settings = MP42ConversionSettings.subtitlesConversion()
            track.conversionSettings = settings
        } else if trackNeedConversion(track.format) {
            let settings = MP42ConversionSettings.subtitlesConversion()
            track.conversionSettings = settings
        }
    }

    func prepare() throws {

        defer {
            localizedWorkingDescription = nil
            delegate?.updateProgress(0)
        }

        if FileManager.default.fileExists(atPath: fileURL.path) == false {
            throw ProcessError.fileNotFound
        }

        #if SB_SANDBOX
        let fileToken = MP42SecurityAccessToken(object: fileURL as NSURL)
        #endif

        if mp4File == nil {
            let value = try? fileURL.resourceValues(forKeys: [URLResourceKey.typeIdentifierKey])

            if let type = value?.typeIdentifier, type == "com.apple.m4a-audio" || type == "com.apple.m4v-video" || type == "public.mpeg-4" {
                mp4File = try MP42File(url: fileURL)
            } else {
                let mp4 = MP42File()
                let importer = try MP42FileImporter(url: fileURL)
                let activeTracks = importer.tracks.filter { isTrackMuxable($0.format) || trackNeedConversion($0.format) }

                mp4.metadata.merge(importer.metadata, overwrite: true)

                for track in activeTracks {

                    if let track = track as? MP42AudioTrack {
                        configureAudio(track: track, mp4: mp4)
                    } else if let track = track as? MP42SubtitleTrack {
                        configureSubtitles(track: track, mp4: mp4)
                    }

                    mp4.addTrack(track)
                }
                mp4File = mp4
            }
        }

        runPreActions()
    }

    private func runPreActions() {
        for action in actions.filter({ $0.type == .pre }) {
            localizedWorkingDescription = action.localizedDescription
            delegate?.updateProgress(0)
            let succeeded = action.runAction(self)
            if succeeded == false {
                Logger.shared.write(toLog: "Queue action '\(action.localizedDescription)' did not make a change for \(fileURL.lastPathComponent); continuing")
            }
        }
    }

    /// A destination folder QueueSetOutputFilenameAction created for this
    /// item's output (the top-most one it had to create), remembered so a
    /// failed or cancelled run -- out of disk space, say -- doesn't leave
    /// an empty folder behind. Transient: never archived.
    var createdDestinationFolder: URL?

    private func removeCreatedDestinationFolderIfEmpty() {
        guard let folder = createdDestinationFolder else { return }
        createdDestinationFolder = nil
        if EmptyFolderCleaner.isEmptyTree(folder) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Safety copy for in-place edits

    /// Where the copy of a file being edited in place is kept: next to it,
    /// hidden, with an extension no scan looks at.
    static func safetyCopyURL(for url: URL) -> URL {
        return url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).m3-backup")
    }

    /// Copies `url` aside before it is edited in place. Returns nil, and
    /// logs it, when there is not room for a copy on the volume (the edit
    /// then goes ahead without one, as it always used to).
    static func makeSafetyCopy(of url: URL) -> URL? {
        let fileManager = FileManager.default
        let copy = safetyCopyURL(for: url)
        try? fileManager.removeItem(at: copy)
        do {
            try fileManager.copyItem(at: url, to: copy)
            return copy
        } catch {
            try? fileManager.removeItem(at: copy)
            Logger.shared.write(toLog: "No safety copy made for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Puts the copy back over the file after a failed edit.
    static func restoreSafetyCopy(_ copy: URL, over url: URL) {
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: copy)
            Logger.shared.write(toLog: "Restored \(url.lastPathComponent) after a failed edit")
        } catch {
            Logger.shared.write(toLog: "Could not restore \(url.lastPathComponent): \(error.localizedDescription). The original is kept as \(copy.lastPathComponent)")
        }
    }

    static func discardSafetyCopy(_ copy: URL) {
        try? FileManager.default.removeItem(at: copy)
    }

    /// Run when the Queue is loaded: a copy still sitting next to the file
    /// of an item that was working when M3 quit means the edit never
    /// finished, so the original is put back.
    func restoreInterruptedEdit() {
        let copy = QueueItem.safetyCopyURL(for: destURL)
        if FileManager.default.fileExists(atPath: copy.path) {
            QueueItem.restoreSafetyCopy(copy, over: destURL)
        }
    }

    func process() throws {
        do {
            try performProcess()
        } catch {
            removeCreatedDestinationFolderIfEmpty()
            throw error
        }
        if cancelled {
            removeCreatedDestinationFolderIfEmpty()
        }
        createdDestinationFolder = nil
    }

    private func performProcess() throws {

        guard let filePathURL = (fileURL as NSURL?)?.filePathURL else { return }

        #if SB_SANDBOX
        let destToken = MP42SecurityAccessToken(object: destURL as NSURL)
        #endif

        defer {
            mp4File?.progressHandler = nil
            mp4File = nil
        }

        // The file has been added directly to the queue
        if mp4File == nil {
            try prepare()
        } else {
            runPreActions()
        }

        guard let mp4 = mp4File else { return }

        #if SB_SANDBOX
        let mp4Token = MP42SecurityAccessToken(object: mp4)
        #endif

        mp4.progressHandler = { [weak self] in self?.delegate?.updateProgress($0) }

        // Check if there is enough space on the destination disk
        if filePathURL != destURL {
            let availableCapacity = checkDiskSpace(at: destURL.deletingLastPathComponent())
            if mp4.dataSize > availableCapacity {
                throw ProcessError.outOfDiskSpace
            }
        }

        // An existing file edited where it sits is changed in place, so a
        // copy of it is set aside first and put back if the edit fails. On
        // an APFS volume the copy is instant and uses no extra space.
        var safetyCopy: URL? = nil
        defer { if let copy = safetyCopy { QueueItem.discardSafetyCopy(copy) } }

        if cancelled == false {
            if filePathURL == destURL && mp4.hasFileRepresentation {
                // We have an existing mp4 file, update it
                safetyCopy = QueueItem.makeSafetyCopy(of: filePathURL)
                do {
                    try mp4.update(options: attributes)
                    // The edit worked, so the copy has done its job. It has to
                    // go now: the steps after this can rename the file's
                    // folder, and the copy would be left behind in it.
                    if let copy = safetyCopy {
                        QueueItem.discardSafetyCopy(copy)
                        safetyCopy = nil
                    }
                } catch {
                    if let copy = safetyCopy {
                        QueueItem.restoreSafetyCopy(copy, over: filePathURL)
                        safetyCopy = nil
                    }
                    throw error
                }
            } else {
                // Write the new file to disk
                try mp4.write(to: destURL, options: attributes)
            }
        }

        if cancelled == false {
            for action in actions.filter( { $0.type == .post }) {
                localizedWorkingDescription = action.localizedDescription
                delegate?.updateProgress(0)
                let result = action.runAction(self)
                if result == false, let _ = action as? QueueOptimizeAction {
                    throw ProcessError.optimizationFailure
                }
            }
            localizedWorkingDescription = nil
        }
    }

    func cancel() {
        queue.sync {
            self.cancelled = true
            mp4File?.cancel()
        }
    }

    // MARK: AppleScript

    @objc func name() -> String {
        return destURL.lastPathComponent
    }

    @objc func sourcePath() -> String {
        return fileURL.path
    }

    @objc func destinationPath() -> String {
        return destURL.path
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        get {
            let appDescription = NSApp.classDescription
            return NSUniqueIDSpecifier(containerClassDescription: appDescription as! NSScriptClassDescription, containerSpecifier: nil, key: "items", uniqueID: uniqueID)
        }
    }

    // MARK: Secure coding

    static var supportsSecureCoding: Bool { return true }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(5, forKey: "SBQueueItemTagEncodeVersion")

        aCoder.encode(uniqueID, forKey: "SBQueueItemID")
        aCoder.encode(mp4File, forKey: "SBQueueItemMp4File")

        #if SB_SANDBOX

        if let bookmark = fileURLBookmark {
            aCoder.encode(bookmark, forKey: "SBQueueItemFileURLBookmark")
        } else {
            do {
                let bookmark = try fileURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                aCoder.encode(bookmark, forKey: "SBQueueItemFileURLBookmark")
            } catch {
                print(error)
            }
        }

        if let bookmark = destURLInternalBookmark {
            aCoder.encode(bookmark, forKey: "SBQueueItemDestURLBookmark")
        } else if let bookmark = try? MP42SecurityAccessToken.bookmark(from: destURLInternal) {
            aCoder.encode(bookmark, forKey: "SBQueueItemDestURLBookmark")
        }


        #endif
        aCoder.encode(fileURL, forKey: "SBQueueItemFileURL")
        aCoder.encode(destURL, forKey: "SBQueueItemDestURL")
        if let sourceFolderURL = sourceFolderURL {
            aCoder.encode(sourceFolderURL, forKey: "SBQueueItemSourceFolderURL")
        }
        aCoder.encode(editsInPlace, forKey: "SBQueueItemEditsInPlace")
        aCoder.encode(trackedTagKeys, forKey: "SBQueueItemTrackedTags")
        aCoder.encode(attributes, forKey: "SBQueueItemAttributes")
        aCoder.encode(actionsInternal, forKey: "SBQueueItemActions")

        aCoder.encode(statusInternal.rawValue, forKey: "SBQueueItemStatus")
    }

    required init?(coder aDecoder: NSCoder) {
        cancelled = false
        queue = DispatchQueue(label: "com.mediametadatamanager.itemQueue")

        statusInternal = QueueItem.Status(rawValue: Int(aDecoder.decodeInt32(forKey: "SBQueueItemStatus"))) ?? .failed
        mp4File = aDecoder.decodeObject(of: [MP42File.classForCoder()], forKey: "SBQueueItemMp4File") as? MP42File
        uniqueID = aDecoder.decodeObject(of: [NSString.classForCoder()], forKey: "SBQueueItemID") as? String ?? UUID().uuidString
        attributes = aDecoder.decodeObject(of: [NSDictionary.classForCoder(), NSString.classForCoder(), NSNumber.classForCoder()], forKey: "SBQueueItemAttributes") as? [String : Any] ?? [:]

        #if SB_SANDBOX
        if var bookmark = aDecoder.decodeObject(of: [NSData.classForCoder()], forKey: "SBQueueItemFileURLBookmark") as? Data {
            do {
                var isStale: ObjCBool = false
                fileURL = try MP42SecurityAccessToken.url(fromBookmark: bookmark, bookmarkDataIsStale: &isStale)
                if isStale.boolValue == true {
                    bookmark = try MP42SecurityAccessToken.bookmark(from: fileURL)
                }
            } catch {
                return nil
            }
            fileURLBookmark = bookmark
        } else {
            return nil
        }

        if var bookmark = aDecoder.decodeObject(of: [NSData.classForCoder()], forKey: "SBQueueItemDestURLBookmark") as? Data {
            do {
                var isStale: ObjCBool = false
                destURLInternal = try MP42SecurityAccessToken.url(fromBookmark: bookmark, bookmarkDataIsStale: &isStale)
                if isStale.boolValue == true {
                    bookmark = try MP42SecurityAccessToken.bookmark(from: destURLInternal)
                }
            } catch {
                return nil
            }
            destURLInternalBookmark = bookmark
        } else {
            return nil
        }
        #else
        if let fileURL = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "SBQueueItemFileURL") as? URL,
           let destURLInternal = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "SBQueueItemDestURL") as? URL {
            self.fileURL = fileURL
            self.destURLInternal = destURLInternal
        } else {
            return nil
        }
        #endif
        sourceFolderURL = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "SBQueueItemSourceFolderURL") as? URL
        editsInPlace = aDecoder.decodeBool(forKey: "SBQueueItemEditsInPlace")
        trackedTagKeys = (aDecoder.decodeObject(of: [NSArray.classForCoder(), NSString.classForCoder()], forKey: "SBQueueItemTrackedTags") as? [String]) ?? []

        actionsInternal = aDecoder.decodeObject(of: [NSArray.classForCoder(), QueueSetAction.classForCoder(),
                                                     QueueMetadataAction.classForCoder(), QueueSubtitlesAction.classForCoder(),
                                                     QueueSetLanguageAction.classForCoder(), QueueFixFallbacksAction.classForCoder(),
                                                     QueueClearTrackNameAction.classForCoder(), QueuePrettifyAudioTrackNameAction.classForCoder(),
                                                     QueueRenameChaptersAction.classForCoder(),
                                                     QueueOrganizeGroupsAction.classForCoder(), QueueColorSpaceAction.classForCoder(),
                                                     QueueSetOutputFilenameAction.classForCoder(), QueueClearExistingMetadataAction.classForCoder(),
                                                     QueueOptimizeAction.classForCoder(),
                                                     QueueMoveToLibraryAction.classForCoder(), QueueMoveFileToLibraryAction.classForCoder(),
                                                     QueueRenameInPlaceAction.classForCoder(),
                                                     QueueChangeAudioLanguageAction.classForCoder(), QueueChangeSubtitleLanguageAction.classForCoder(),
                                                     QueueSetRulesAction.classForCoder()], forKey: "SBQueueItemActions") as? [QueueActionProtocol] ?? []
    }
}

extension QueueItem.ProcessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return NSLocalizedString("File not found.", comment: "QueueItem Error")
        case .fileExists:
            return NSLocalizedString("A file already exists at the destination.", comment: "QueueItem Error")
        case .outOfDiskSpace:
            return NSLocalizedString("Not enough disk space.", comment: "QueueItem Error")
        case .optimizationFailure:
            return NSLocalizedString("The file couldn't be optimized.", comment: "QueueItem Error")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .fileNotFound:
            return NSLocalizedString("The source file couldn't be found.", comment: "My error")
        case .fileExists:
            return NSLocalizedString("Try to use another name for the destination file.", comment: "QueueItem Error")
        case .outOfDiskSpace:
            return NSLocalizedString("Please free some space on the destination disk.", comment: "QueueItem Error")
        case .optimizationFailure:
            return NSLocalizedString("An error occurred while optimizing the file.", comment: "QueueItem Error")
        }
    }
}

extension QueueItem {
    /// True when the file the item was added for is no longer where it was
    /// (moved, renamed or deleted since). Shown as "File missing" in the
    /// Status column of a waiting item (L-11).
    var isFileMissing: Bool {
        return FileManager.default.fileExists(atPath: fileURL.path) == false
    }
}

/// What happens to a Queue row when the editor opened from it closes.
enum QueueEditOutcome: Equatable {
    case keepRow
    case removeRow

    /// - A finished file keeps its row while the file is still there.
    /// - A waiting file keeps its row when the editor was closed or cancelled
    ///   without saving; once saved it is done with, so the row goes.
    static func afterClose(wasCompleted: Bool, saved: Bool, fileExists: Bool) -> QueueEditOutcome {
        if wasCompleted { return fileExists ? .keepRow : .removeRow }
        return saved ? .removeRow : .keepRow
    }
}
