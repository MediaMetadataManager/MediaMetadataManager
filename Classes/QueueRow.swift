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

    /// Where this row was added in the Queue's history: 1 for the first file
    /// ever added, 2 for the next, and so on. Dragging or sorting changes the
    /// row's place in the list but never this number, so sorting by it puts
    /// the Queue back in the order the files were added. Zero means the Queue
    /// has not numbered the row yet (see Queue.append and Queue.insert).
    var addedNumber: Int = 0

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
        aCoder.encode(addedNumber, forKey: "SBQueueRowAddedNumber")
    }

    init?(coder aDecoder: NSCoder) {
        item = aDecoder.decodeObject(of: [QueueItem.classForCoder()], forKey: "SBQueueRowItem") as? QueueItem
        release = aDecoder.decodeObject(of: [QueueRelease.classForCoder()], forKey: "SBQueueRowRelease") as? QueueRelease
        folderHeaderURL = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "SBQueueRowFolderHeaderURL") as? URL
        addedNumber = aDecoder.decodeInteger(forKey: "SBQueueRowAddedNumber")

        if item == nil && release == nil && folderHeaderURL == nil {
            // A row with none of the three is corrupt -- shouldn't happen
            // since encode(with:) always writes one of them, but bail
            // rather than let a meaningless row into the queue.
            return nil
        }
    }
}

// MARK: - Sorting the Queue

/// The columns the Queue can be sorted by. Add a case here, a column in
/// QueueController.configureColumns() and a branch in `QueueSorter.compare`
/// to add another one later.
enum QueueSortColumn: String {
    /// The order files were added in (the "#" column).
    case added
    case name
    case status
    case size
    case kind
}

/// What the sorter needs to know about one row. Kept free of QueueItem and
/// QueueRelease so the ordering can be tested on its own.
struct QueueSortEntry {
    var name: String
    var statusText: String
    /// 0 working, 1 failed or stopped, 2 needs you, 3 waiting or ready, 4 done.
    var statusRank: Int
    var size: Int64
    var kind: String
    var isHeader: Bool
    /// See QueueRow.addedNumber.
    var added: Int = 0
    /// A folder header and the files added from that folder share this value.
    var group: String?
}

enum QueueSorter {

    /// The new order as indexes into `entries`. A folder header stays right
    /// above its own files: the files are sorted inside their folder, and
    /// the folder (or a single file) is placed by its first entry.
    static func order(of entries: [QueueSortEntry], by column: QueueSortColumn, ascending: Bool) -> [Int] {
        func before(_ a: Int, _ b: Int) -> Bool {
            let result = compare(entries[a], entries[b], column)
            if result != 0 { return ascending ? result < 0 : result > 0 }
            return a < b
        }

        var blocks: [[Int]] = []
        var i = 0
        while i < entries.count {
            if entries[i].isHeader, let group = entries[i].group {
                var block = [i]
                var j = i + 1
                while j < entries.count, entries[j].isHeader == false, entries[j].group == group {
                    block.append(j)
                    j += 1
                }
                blocks.append(block)
                i = j
            }
            else {
                blocks.append([i])
                i += 1
            }
        }

        // Inside a folder: the header first, then its files in order.
        let sortedBlocks: [[Int]] = blocks.map { block in
            guard let first = block.first, entries[first].isHeader, block.count > 1 else { return block }
            return [first] + block.dropFirst().sorted(by: before)
        }

        // Between blocks: by the folder's own name when sorting by name,
        // otherwise by the block's first file.
        func representative(_ block: [Int]) -> Int {
            if column != .name, block.count > 1, entries[block[0]].isHeader { return block[1] }
            return block[0]
        }

        return sortedBlocks
            .sorted { before(representative($0), representative($1)) }
            .flatMap { $0 }
    }

    private static func compare(_ x: QueueSortEntry, _ y: QueueSortEntry, _ column: QueueSortColumn) -> Int {
        func byName() -> Int {
            switch x.name.localizedStandardCompare(y.name) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        }

        switch column {
        case .added:
            if x.added != y.added { return x.added < y.added ? -1 : 1 }
            return 0
        case .name:
            return byName()
        case .status:
            switch x.statusText.localizedStandardCompare(y.statusText) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return byName()
            }
        case .size:
            if x.size != y.size { return x.size < y.size ? -1 : 1 }
            return byName()
        case .kind:
            switch x.kind.localizedStandardCompare(y.kind) {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return byName()
            }
        }
    }
}

extension QueueRow {

    /// The name the Name column shows.
    var displayName: String {
        if let folderHeaderURL = folderHeaderURL { return folderHeaderURL.lastPathComponent }
        if let item = effectiveItem { return item.fileURL.lastPathComponent }
        if let release = release { return release.approvedName ?? release.folderURL.lastPathComponent }
        return ""
    }

    /// The Status column's text, and where it sorts (see QueueSortEntry).
    var statusSummary: (text: String, rank: Int) {
        if folderHeaderURL != nil { return ("", 3) }

        if let item = effectiveItem {
            switch item.status {
            case .working: return (NSLocalizedString("Working", comment: "Queue status column"), 0)
            case .failed: return (NSLocalizedString("Failed", comment: "Queue status column"), 1)
            case .cancelled: return (NSLocalizedString("Cancelled", comment: "Queue status column"), 1)
            case .editing: return (NSLocalizedString("Editing", comment: "Queue status column"), 2)
            case .ready: return (NSLocalizedString("Waiting", comment: "Queue status column"), 3)
            case .completed: return (NSLocalizedString("Completed", comment: "Queue status column"), 4)
            }
        }

        if let release = release {
            switch release.stage {
            case .merging: return (release.mergingText, 0)
            case .mergeFailed: return (NSLocalizedString("Merge failed", comment: "Queue status column"), 1)
            case .namingRejected: return (NSLocalizedString("Name rejected", comment: "Queue status column"), 1)
            case .pendingNaming: return (NSLocalizedString("Needs name approval", comment: "Queue status column"), 2)
            case .pendingMergeSelection: return (NSLocalizedString("Needs merge order", comment: "Queue status column"), 2)
            case .pendingMetadata: return (NSLocalizedString("Waiting for metadata", comment: "Queue status column"), 3)
            case .pendingLibraryMove: return (NSLocalizedString("Moving to library", comment: "Queue status column"), 3)
            case .done: return (NSLocalizedString("Done", comment: "Queue status column"), 4)
            case .alreadyMerged: return (NSLocalizedString("Already merged: review", comment: "Queue status column"), 2)
            }
        }

        return ("", 3)
    }

    /// Shown when the pointer rests on the Status text: what "Waiting" means
    /// and which steps the file will go through, so the list itself can stay
    /// uncluttered.
    var statusTooltip: String? {
        if let item = effectiveItem, item.status == .ready {
            let steps = item.actions.map { $0.localizedDescription }
            var text = NSLocalizedString("Waiting for its turn in the queue.", comment: "Queue status tooltip")
            if steps.isEmpty {
                text += " " + NSLocalizedString("No extra steps are set for this file.", comment: "Queue status tooltip")
            } else {
                text += " " + String(format: NSLocalizedString("When the queue runs it will do: %@.", comment: "Queue status tooltip"), steps.joined(separator: ", "))
            }
            if item.actions.contains(where: { $0 is QueueMetadataAction }) == false {
                text += " " + NSLocalizedString("Metadata is not searched for this file.", comment: "Queue status tooltip")
            }
            return text
        }
        if release?.stage == .alreadyMerged {
            return NSLocalizedString("The folder already holds a file about the size of all its parts together. Double-click to choose what to do.", comment: "Queue status tooltip")
        }
        return nil
    }

    /// File type for the Type column, such as "MP4" or "MKV".
    var kindText: String {
        if folderHeaderURL != nil { return "" }
        let url = effectiveItem?.fileURL ?? release?.sourceFileURLs.first
        return url?.pathExtension.uppercased() ?? ""
    }

    /// The files whose sizes make up the Size column.
    var sizeSourceURLs: [URL] {
        if folderHeaderURL != nil { return [] }
        if let item = effectiveItem { return [item.fileURL] }
        return release?.sourceFileURLs ?? []
    }

    /// Ties a folder header to the files that were added from that folder.
    var sortGroup: String? {
        if let folderHeaderURL = folderHeaderURL { return folderHeaderURL.path }
        return item?.sourceFolderURL?.path
    }

    func sortEntry(sizes: [URL: Int64]) -> QueueSortEntry {
        let summary = statusSummary
        let urls = sizeSourceURLs
        let total = urls.reduce(Int64(0)) { $0 + max(sizes[$1] ?? 0, 0) }
        return QueueSortEntry(name: displayName,
                              statusText: summary.text,
                              statusRank: summary.rank,
                              size: total,
                              kind: kindText,
                              isHeader: folderHeaderURL != nil,
                              added: addedNumber,
                              group: sortGroup)
    }
}

// MARK: - Queue totals and timing (the strip under the list)

/// How many files are in each state, for the line under the Queue list.
struct QueueTally: Equatable {
    var total = 0
    var working = 0
    var failed = 0
    var needsYou = 0
    var waiting = 0
    var done = 0

    /// `ranks` are the `QueueRow.statusSummary.rank` values of the file rows:
    /// 0 working, 1 failed or stopped, 2 needs you, 3 waiting, 4 done.
    init(ranks: [Int]) {
        total = ranks.count
        for rank in ranks {
            switch rank {
            case 0: working += 1
            case 1: failed += 1
            case 2: needsYou += 1
            case 4: done += 1
            default: waiting += 1
            }
        }
    }

    /// For example "56 in queue · 12 done · 1 failed · 43 waiting". Counts
    /// of zero are left out.
    var text: String {
        var parts = [String.localizedStringWithFormat(NSLocalizedString("%ld in queue", comment: "Queue totals"), total)]
        if working > 0 { parts.append(String.localizedStringWithFormat(NSLocalizedString("%ld working", comment: "Queue totals"), working)) }
        if done > 0 { parts.append(String.localizedStringWithFormat(NSLocalizedString("%ld done", comment: "Queue totals"), done)) }
        if failed > 0 { parts.append(String.localizedStringWithFormat(NSLocalizedString("%ld failed", comment: "Queue totals"), failed)) }
        if waiting > 0 { parts.append(String.localizedStringWithFormat(NSLocalizedString("%ld waiting", comment: "Queue totals"), waiting)) }
        if needsYou > 0 { parts.append(String.localizedStringWithFormat(NSLocalizedString("%ld need you", comment: "Queue totals"), needsYou)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

enum QueueTiming {

    /// Time left, from how long the run has taken so far and how much of it
    /// is finished (`doneUnits` of `totalUnits`; bytes, or files when sizes
    /// are not known). Nil until there is enough to go on.
    static func remaining(elapsed: TimeInterval, doneUnits: Double, totalUnits: Double) -> TimeInterval? {
        guard totalUnits > 0 else { return nil }
        if doneUnits >= totalUnits { return 0 }
        guard elapsed >= 10, doneUnits > 0 else { return nil }
        return elapsed * (totalUnits - doneUnits) / doneUnits
    }

    /// "12:30" or "1:05:09".
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = Int(max(interval, 0).rounded())
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        if hours > 0 { return String(format: "%ld:%02ld:%02ld", hours, minutes, rest) }
        return String(format: "%ld:%02ld", minutes, rest)
    }

    /// "45 sec", "12 min" or "1 hr 20 min".
    static func approximately(_ interval: TimeInterval) -> String {
        let seconds = max(interval, 0)
        if seconds < 90 { return String(format: NSLocalizedString("%ld sec", comment: "Queue time left"), Int(seconds.rounded())) }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(format: NSLocalizedString("%ld min", comment: "Queue time left"), minutes) }
        return String(format: NSLocalizedString("%ld hr %ld min", comment: "Queue time left"), minutes / 60, minutes % 60)
    }
}

// MARK: - Expanding folder rows

/// Which table row shows what, when some of the Queue's folder rows are
/// expanded to list their files (like a Finder list-view folder).
///
/// The Queue itself only holds one entry per row; an expanded folder adds
/// extra display-only rows right under it, one for each file inside. This
/// type is the translation between the two numberings:
///
///  - a "queue index" counts the Queue's own rows (what `Queue` uses),
///  - a "table row" counts every row on screen, files included.
///
/// With nothing expanded the two are the same number, so the Queue behaves
/// exactly as it did before folders could be opened.
struct QueueOutlineLayout: Equatable {

    enum Entry: Equatable {
        /// One of the Queue's own rows.
        case row(queueIndex: Int)
        /// A file listed under the folder row at `parent`; `position` is
        /// its place in that folder's file list.
        case file(parent: Int, position: Int)
    }

    private(set) var entries: [Entry] = []
    private var firstTableRow: [Int] = []
    private let queueCount: Int

    /// - Parameters:
    ///   - rowCount: how many rows the Queue holds.
    ///   - expanded: queue indexes of the folder rows that are open.
    ///   - fileCount: how many files the folder row at a queue index lists.
    init(rowCount: Int, expanded: Set<Int>, fileCount: (Int) -> Int) {
        queueCount = rowCount
        entries.reserveCapacity(rowCount)
        firstTableRow.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            firstTableRow.append(entries.count)
            entries.append(.row(queueIndex: index))
            if expanded.contains(index) {
                for position in 0..<max(fileCount(index), 0) {
                    entries.append(.file(parent: index, position: position))
                }
            }
        }
    }

    var count: Int { return entries.count }

    /// True when at least one folder is open, so table rows and queue
    /// indexes no longer match.
    var hasExpansions: Bool { return entries.count != queueCount }

    func entry(atTableRow row: Int) -> Entry? {
        return entries.indices.contains(row) ? entries[row] : nil
    }

    /// The Queue row a table row belongs to: itself, or for a file line the
    /// folder row it sits under. Nil when `row` is out of range.
    func queueIndex(forTableRow row: Int) -> Int? {
        switch entry(atTableRow: row) {
        case .row(let index)?: return index
        case .file(let parent, _)?: return parent
        case nil: return nil
        }
    }

    func isFile(atTableRow row: Int) -> Bool {
        if case .file? = entry(atTableRow: row) { return true }
        return false
    }

    /// Where a Queue row is drawn. Nil when the index is out of range.
    func tableRow(forQueueIndex index: Int) -> Int? {
        return firstTableRow.indices.contains(index) ? firstTableRow[index] : nil
    }

    /// The Queue rows among `rows`; file lines are left out.
    func queueIndexes(forTableRows rows: IndexSet) -> IndexSet {
        var result = IndexSet()
        for row in rows {
            if case .row(let index)? = entry(atTableRow: row) {
                result.insert(index)
            }
        }
        return result
    }

    func tableRows(forQueueIndexes indexes: IndexSet) -> IndexSet {
        var result = IndexSet()
        for index in indexes {
            if let row = tableRow(forQueueIndex: index) {
                result.insert(row)
            }
        }
        return result
    }

    /// Like `tableRows(forQueueIndexes:)`, plus the file lines under any of
    /// those rows that are open -- for redrawing, never for selecting.
    func tableRowsIncludingFiles(forQueueIndexes indexes: IndexSet) -> IndexSet {
        var result = IndexSet()
        for index in indexes {
            guard let row = tableRow(forQueueIndex: index) else { continue }
            result.insert(row)
            var next = row + 1
            while next < entries.count, case .file = entries[next] {
                result.insert(next)
                next += 1
            }
        }
        return result
    }

    /// Where a drop proposed at `row` (before that table row) lands among
    /// the Queue's own rows. Dropping inside an open folder's file list
    /// means "after that folder".
    func queueInsertionIndex(forTableRow row: Int) -> Int {
        if row >= entries.count { return queueCount }
        switch entries[row] {
        case .row(let index): return index
        case .file(let parent, _): return parent + 1
        }
    }
}
