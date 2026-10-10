//
//  QueueRow.swift
//  Subler
//
//  One row in the Queue's table, wrapping either a plain, already-ready
//  QueueItem (today's manual drag-and-drop / AppleScript path, completely
//  unchanged) or a QueueRelease (the new Intake/Queue workflow's
//  multi-stage path -- see the "Queue release model" design doc kept in
//  this project's notes).
//
//  This exists because Queue.items has to be one uniform array type, but
//  a release discovered by the intake workflow isn't ready to be muxed
//  the moment it's found the way a manually-added QueueItem always is --
//  it first has to go through naming approval and, for a multi-file
//  release, a merge.
//
//  Exactly one of `item`/`release` is non-nil for the life of a row --
//  enforced by the two initializers below, not a runtime check. A release
//  row is never turned into a plain item row: only its internal
//  QueueRelease.resolvedItem transitions from nil to set as the release
//  moves through naming/metadata/merge, which is why effectiveItem below
//  (not this row's own identity) is what the Queue's work loop and table
//  rendering key off of.
//

import Cocoa

@objc(SBQueueRow) final class QueueRow: NSObject, NSSecureCoding {

    let item: QueueItem?
    let release: QueueRelease?

    /// A non-processable row that just labels a folder whose contents
    /// were added right after it as ordinary QueueItem rows -- see
    /// QueueController.insertFolder(_:at:). Purely a display grouping:
    /// effectiveItem is always nil for this row (same as an unresolved
    /// release), so the queue's work loop and every effectiveItem-keyed
    /// status check already skip it with no extra code anywhere else.
    let folderHeaderURL: URL?

    init(item: QueueItem) {
        self.item = item
        self.release = nil
        self.folderHeaderURL = nil
    }

    init(release: QueueRelease) {
        self.item = nil
        self.release = release
        self.folderHeaderURL = nil
    }

    init(folderHeaderURL: URL) {
        self.item = nil
        self.release = nil
        self.folderHeaderURL = folderHeaderURL
    }

    /// The real, mux-able QueueItem for this row, if one exists yet.
    /// A plain item row always has one (itself); a release row only has
    /// one once the release has resolved to a single, correctly-named
    /// file (naming approved for an already-single-file release, or a
    /// multi-file merge succeeded).
    var effectiveItem: QueueItem? {
        return item ?? release?.resolvedItem
    }

    // MARK: Secure coding

    static var supportsSecureCoding: Bool { return true }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(item, forKey: "SBQueueRowItem")
        aCoder.encode(release, forKey: "SBQueueRowRelease")
        if let folderHeaderURL = folderHeaderURL {
            aCoder.encode(folderHeaderURL, forKey: "SBQueueRowFolderHeaderURL")
        }
    }

    init?(coder aDecoder: NSCoder) {
        item = aDecoder.decodeObject(of: [QueueItem.classForCoder()], forKey: "SBQueueRowItem") as? QueueItem
        release = aDecoder.decodeObject(of: [QueueRelease.classForCoder()], forKey: "SBQueueRowRelease") as? QueueRelease
        folderHeaderURL = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "SBQueueRowFolderHeaderURL") as? URL

        if item == nil && release == nil && folderHeaderURL == nil {
            // A row with none of the three is corrupt -- shouldn't happen
            // since encode(with:) always writes one of them, but bail
            // rather than let a meaningless row into the queue.
            return nil
        }
    }
}
