//
//  QueueRelease.swift
//  Subler
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
    /// Mirrors FileMerger's progressHandler while stage == .merging.
    /// Deliberately not persisted -- see encode(with:) below.
    var mergeProgress: Double = 0

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
        self.resolvedItem = aDecoder.decodeObject(of: [QueueItem.classForCoder()], forKey: "SBQueueReleaseResolvedItem") as? QueueItem
        self.mergeProgress = 0
    }
}
