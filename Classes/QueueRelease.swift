//
//  QueueRelease.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/24/2026.
//
//  A multi-file "release" discovered by the Intake/Queue workflow (a
//  multi-file download folder, typically) that hasn't resolved to a single,
//  correctly-named file yet -- as opposed to QueueItem, which always
//  represents exactly one file ready to be muxed. See the "Queue release
//  model" design doc kept in this project's notes for the full design
//  this implements.
//
//  A QueueRelease moves through `stage` as the user approves a suggested
//  name and, for a multi-file release, picks and orders files to merge.
//  Once it has exactly one correctly-named file -- immediately for an
//  already-single-file release, or after a successful merge -- it's given
//  a real QueueItem, stored as `resolvedItem`. From that point on the
//  Queue's existing mux engine picks it up like any other item (see
//  QueueRow.effectiveItem and Queue's firstItemInQueue/readyCount).
//
//  Naming, metadata search, and merging themselves are not implemented
//  yet -- this phase only establishes the model and lets a release row
//  exist in the queue, sitting in .pendingNaming, without being muxed.
//

import Cocoa

@objc(SBQueueRelease) final class QueueRelease: NSObject, NSSecureCoding {

    let id: UUID

    /// The folder currently holding this release's files. Starts as
    /// wherever it was discovered; will get renamed in place once naming
    /// is approved (a later phase), so this URL's last path component
    /// tracks that rename.
    var folderURL: URL

    /// Raw candidate media files discovered in folderURL, in discovery
    /// order. Left untouched once merging begins -- mergeOrder is what
    /// actually gets merged, so a user can reorder/deselect without
    /// losing the original discovery list.
    var sourceFileURLs: [URL]

    @objc enum Stage: Int {
        case pendingNaming         // discovered; naming suggestion not yet approved
        case namingRejected        // user rejected the suggested name; parked
        case pendingMetadata       // naming approved, exactly one file -- metadata search not yet run
        case pendingMergeSelection // naming approved, multiple files -- user hasn't confirmed merge order yet
        case merging               // FileMerger.merge running
        case mergeFailed           // MergeCompatibility/FileMerger failed; see mergeErrorMessage
        case pendingLibraryMove    // resolvedItem exists and has been added to the Queue for muxing
        case done                  // moved to Ready for Media Library
        case alreadyMerged         // the folder already holds a merged copy of its parts; set aside for review
    }
    var stage: Stage

    // MARK: Naming step

    /// Best candidate name, "Title Vol N [Studio] (Year)" formatted.
    var suggestedName: String?
    /// Which provider produced suggestedName, for display in the naming
    /// approval window (a later phase).
    var suggestedNameSource: String?
    /// Set on approve; the folder/file base name carried through every
    /// later step (metadata search, merge, move to library).
    var approvedName: String?

    // MARK: Merge step (only relevant when sourceFileURLs.count > 1)

    /// User-chosen subset + order; nil until the merge-selection window
    /// (a later phase) is confirmed.
    var mergeOrder: [URL]?
    /// Friendly, already-translated MergeCompatibilityError text.
    var mergeErrorMessage: String?
    /// The finished merge output, set once the merge succeeds. From then on
    /// the release goes through the same metadata step as a single-file
    /// release, using this file instead of sourceFileURLs.first.
    var mergedFileURL: URL?
    /// For a release in .alreadyMerged: the file in the folder that is about
    /// as big as all the other files together, so most likely their merge.
    var existingMergedFileURL: URL?
    /// Mirrors FileMerger's progressHandler while stage == .merging.
    /// Deliberately not persisted -- see encode(with:) below.
    var mergeProgress: Double = 0

    /// True while attemptAutoResolveMetadata(for:) has a background
    /// metadata search in flight for this release (stage ==
    /// .pendingMetadata the whole time it's true). Lets the Status
    /// column tell "still working, nothing to do" apart from "stopped
    /// and genuinely waiting on you" -- both used to show the identical
    /// "Waiting for metadata" text, which is exactly what Hans flagged
    /// (2026-10-13) as leaving him guessing whether anything needed his
    /// attention. Deliberately not persisted, same reasoning as
    /// mergeProgress: meaningless after a relaunch, and the search
    /// would just be kicked off again on the next launch's attempt.
    var isSearchingMetadata: Bool = false

    /// Set once there's exactly one real, correctly-named file to mux.
    /// Until this is non-nil, the row this release belongs to is
    /// invisible to the Queue's mux work loop by construction (see
    /// QueueRow.effectiveItem) -- there's no separate flag to remember to
    /// check.
    var resolvedItem: QueueItem?

    init(folderURL: URL, sourceFileURLs: [URL]) {
        self.id = UUID()
        self.folderURL = folderURL
        self.sourceFileURLs = sourceFileURLs
        self.stage = .pendingNaming
    }

    // MARK: Secure coding

    static var supportsSecureCoding: Bool { return true }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(1, forKey: "SBQueueReleaseTagEncodeVersion")

        aCoder.encode(id.uuidString, forKey: "SBQueueReleaseID")
        aCoder.encode(folderURL, forKey: "SBQueueReleaseFolderURL")
        aCoder.encode(sourceFileURLs as NSArray, forKey: "SBQueueReleaseSourceFileURLs")
        aCoder.encode(Int32(stage.rawValue), forKey: "SBQueueReleaseStage")
        aCoder.encode(suggestedName, forKey: "SBQueueReleaseSuggestedName")
        aCoder.encode(suggestedNameSource, forKey: "SBQueueReleaseSuggestedNameSource")
        aCoder.encode(approvedName, forKey: "SBQueueReleaseApprovedName")
        aCoder.encode(mergeOrder as NSArray?, forKey: "SBQueueReleaseMergeOrder")
        aCoder.encode(mergeErrorMessage, forKey: "SBQueueReleaseMergeErrorMessage")
        aCoder.encode(mergedFileURL, forKey: "SBQueueReleaseMergedFileURL")
        aCoder.encode(existingMergedFileURL, forKey: "SBQueueReleaseExistingMergedFileURL")
        aCoder.encode(resolvedItem, forKey: "SBQueueReleaseResolvedItem")
        // mergeProgress is deliberately not persisted -- meaningless after
        // a relaunch, same as QueueItem doesn't persist a partial mux's
        // byte-level progress today.
    }

    init?(coder aDecoder: NSCoder) {
        guard let idString = aDecoder.decodeObject(of: [NSString.classForCoder()], forKey: "SBQueueReleaseID") as? String,
              let uuid = UUID(uuidString: idString),
              let folderURL = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "SBQueueReleaseFolderURL") as? URL,
              let sourceFileURLs = aDecoder.decodeObject(of: [NSArray.classForCoder(), NSURL.classForCoder()], forKey: "SBQueueReleaseSourceFileURLs") as? [URL]
        else { return nil }

        let stageRaw = aDecoder.decodeInt32(forKey: "SBQueueReleaseStage")

        self.id = uuid
        self.folderURL = folderURL
        self.sourceFileURLs = sourceFileURLs
        self.stage = Stage(rawValue: Int(stageRaw)) ?? .pendingNaming
        self.suggestedName = aDecoder.decodeObject(of: [NSString.classForCoder()], forKey: "SBQueueReleaseSuggestedName") as? String
        self.suggestedNameSource = aDecoder.decodeObject(of: [NSString.classForCoder()], forKey: "SBQueueReleaseSuggestedNameSource") as? String
        self.approvedName = aDecoder.decodeObject(of: [NSString.classForCoder()], forKey: "SBQueueReleaseApprovedName") as? String
        self.mergeOrder = aDecoder.decodeObject(of: [NSArray.classForCoder(), NSURL.classForCoder()], forKey: "SBQueueReleaseMergeOrder") as? [URL]
        self.mergeErrorMessage = aDecoder.decodeObject(of: [NSString.classForCoder()], forKey: "SBQueueReleaseMergeErrorMessage") as? String
        self.mergedFileURL = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "SBQueueReleaseMergedFileURL") as? URL
        self.existingMergedFileURL = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "SBQueueReleaseExistingMergedFileURL") as? URL
        self.resolvedItem = aDecoder.decodeObject(of: [QueueItem.classForCoder()], forKey: "SBQueueReleaseResolvedItem") as? QueueItem
        self.mergeProgress = 0
        self.isSearchingMetadata = false
    }
}

// MARK: - Spotting a folder that already holds the merged file

enum AlreadyMergedDetector {

    /// How far the big file's size may be from the other files' total. A
    /// merge only drops a little container overhead, so this is generous.
    static let tolerance = 0.02

    /// If the largest file is about as big as all the others together (and
    /// there are at least two others), it is probably their merge: returns
    /// that file and the parts. Otherwise nil.
    static func find(in files: [(url: URL, size: Int64)]) -> (merged: URL, parts: [URL])? {
        guard files.count >= 3,
              let largest = files.max(by: { $0.size < $1.size }),
              largest.size > 0
        else { return nil }

        let others = files.filter { $0.url != largest.url }
        let total = others.reduce(Int64(0)) { $0 + max($1.size, 0) }
        guard total > 0 else { return nil }

        let difference = abs(Double(largest.size) - Double(total))
        guard difference <= Double(total) * tolerance else { return nil }
        return (largest.url, others.map { $0.url })
    }
}

extension QueueRelease {
    /// "Merging", or "Merging 42%" once the merge has reported progress.
    var mergingText: String {
        let base = NSLocalizedString("Merging", comment: "Queue status column")
        guard mergeProgress >= 1 else { return base }
        return base + " " + String(Int(min(mergeProgress, 100))) + "%"
    }

    /// What the Status column shows beside one of this folder's files while
    /// the folder is open in the Queue: "Merging" for each file going into
    /// the merge -- always plain, with no percentage. The percentage is
    /// shown once, on the folder's own row (see mergingText above); showing
    /// the same number again on every file line underneath it is just
    /// noise. Also "Merge failed" if the last attempt did not work, and
    /// "Merged" once the merged file exists. Files left out of the merge,
    /// and every other stage, show nothing of their own.
    func fileStatusText(for url: URL) -> String? {
        let mergedFileExists = mergedFileURL != nil && (stage == .pendingMetadata || stage == .pendingLibraryMove || stage == .done)
        guard stage == .merging || stage == .mergeFailed || mergedFileExists else { return nil }
        if let order = mergeOrder, order.contains(url) == false { return nil }
        if mergedFileExists { return NSLocalizedString("Merged", comment: "Queue status column") }
        return stage == .merging
            ? NSLocalizedString("Merging", comment: "Queue status column")
            : NSLocalizedString("Merge failed", comment: "Queue status column")
    }
}
