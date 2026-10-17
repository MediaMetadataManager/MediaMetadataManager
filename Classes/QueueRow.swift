//
//  QueueRow.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/24/2026.
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
import MP42Foundation

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
    /// One of the tag columns (files sent from the Library scan). Which tag
    /// is decided by the entries' `tagText`.
    case tag
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
    /// The value of the tag being sorted by (see QueueSortColumn.tag); empty
    /// when the file has none, which sorts first.
    var tagText: String = ""
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
        case .tag:
            // A file with no value comes first, so the gaps gather at one end.
            if x.tagText.isEmpty != y.tagText.isEmpty { return x.tagText.isEmpty ? -1 : 1 }
            switch x.tagText.localizedStandardCompare(y.tagText) {
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
        if let folderHeaderURL = folderHeaderURL { return SeasonFolderName.displayName(forFolder: folderHeaderURL) }
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
            case .pendingMetadata: return release.isSearchingMetadata
                ? (NSLocalizedString("Searching metadata\u{2026}", comment: "Queue status column"), 0)
                : (NSLocalizedString("Waiting for metadata", comment: "Queue status column"), 3)
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
        if let release = release, release.stage == .pendingMetadata {
            return release.isSearchingMetadata
                ? NSLocalizedString("Automatically searching online for its metadata. No action needed yet.", comment: "Queue status tooltip")
                : NSLocalizedString("No confident match was found automatically. Double-click to search again or confirm its metadata by hand.", comment: "Queue status tooltip")
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

    func sortEntry(sizes: [URL: Int64], tagText: String = "") -> QueueSortEntry {
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
                              group: sortGroup,
                              tagText: tagText)
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
    private var firstTableRow: [Int?] = []
    private let queueCount: Int

    /// - Parameters:
    ///   - rowCount: how many rows the Queue holds.
    ///   - expanded: queue indexes of the folder rows that are open.
    ///   - hidden: queue indexes of rows that are not shown, such as the
    ///     files under a folder header that has been closed.
    ///   - fileCount: how many files the folder row at a queue index lists.
    init(rowCount: Int, expanded: Set<Int>, hidden: Set<Int> = [], fileCount: (Int) -> Int) {
        queueCount = rowCount
        entries.reserveCapacity(rowCount)
        firstTableRow.reserveCapacity(rowCount)
        for index in 0..<rowCount {
            if hidden.contains(index) {
                firstTableRow.append(nil)
                continue
            }
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

    /// True when at least one folder is open or a row is hidden, so table
    /// rows and queue indexes no longer match.
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

    /// Where a Queue row is drawn. Nil when the index is out of range or the
    /// row is hidden.
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


/// Folder groups in the Queue: a header row followed by one row per file.
enum QueueFolderGroups {

    /// Indexes of the file rows that belong to the header at `headerIndex`.
    static func childIndexes(ofHeaderAt headerIndex: Int, in rows: [QueueRow]) -> [Int] {
        var result: [Int] = []
        var j = headerIndex + 1
        while j < rows.count, rows[j].folderHeaderURL == nil, rows[j].item?.sourceFolderURL != nil {
            result.append(j)
            j += 1
        }
        return result
    }

    /// What Remove should take out for the selected rows. Selecting a folder
    /// header takes its files with it. Rows that cannot be removed right now
    /// (`keep`, such as a file that is being processed) stay, and a header
    /// stays while any of its files does. A header whose files are all gone
    /// is removed too, as before.
    static func indexesToRemove(selected: IndexSet, rows: [QueueRow], keep: (QueueRow) -> Bool) -> IndexSet {
        var result = selected
        for index in selected where rows[index].folderHeaderURL != nil {
            result.formUnion(IndexSet(childIndexes(ofHeaderAt: index, in: rows)))
        }
        for index in Array(result) where keep(rows[index]) {
            result.remove(index)
        }
        for index in Array(result) where rows[index].folderHeaderURL != nil {
            if childIndexes(ofHeaderAt: index, in: rows).contains(where: { result.contains($0) == false }) {
                result.remove(index)
            }
        }
        return result
    }
}


/// Keeps the same file from being queued twice.
enum QueueDuplicates {

    /// How a file is recognised: its full path, tidied.
    static func key(for url: URL) -> String {
        return url.standardizedFileURL.path
    }

    /// The source files of rows that are still to be processed. A row that is
    /// already completed does not count, so a finished file can be run again.
    static func sourcePaths(of rows: [QueueRow]) -> Set<String> {
        var paths = Set<String>()
        for row in rows {
            if let item = row.effectiveItem {
                if item.status != .completed { paths.insert(key(for: item.fileURL)) }
            } else if let release = row.release, release.stage != .done {
                release.sourceFileURLs.forEach { paths.insert(key(for: $0)) }
            }
        }
        return paths
    }
}

/// Finds the folders that hold the media files of something dropped or added
/// by hand. A show folder with Season subfolders ("Show/Season 1/...") holds
/// no media files itself; the files are one level down, so each Season
/// folder becomes its own group in the Queue.
enum QueueMediaFolders {

    /// How many folder levels below the one dropped are searched.
    static let maxDepth = 3

    /// `folder` itself when it directly holds media files, then every
    /// subfolder (down to `maxDepth` levels) that does, in natural name order.
    /// Hidden items and packages are skipped.
    static func folders(startingAt folder: URL,
                        maxDepth: Int = QueueMediaFolders.maxDepth,
                        isMedia: (URL) -> Bool) -> [URL] {
        var found: [URL] = []
        collect(folder, depth: 0, maxDepth: maxDepth, isMedia: isMedia, into: &found)
        return found
    }

    private static func collect(_ folder: URL, depth: Int, maxDepth: Int, isMedia: (URL) -> Bool, into found: inout [URL]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }

        var hasMedia = false
        var subfolders: [URL] = []
        for child in children {
            let values = try? child.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if values?.isPackage != true { subfolders.append(child) }
            } else if isMedia(child) {
                hasMedia = true
            }
        }

        if hasMedia { found.append(folder) }
        guard depth < maxDepth else { return }

        subfolders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for subfolder in subfolders {
            collect(subfolder, depth: depth + 1, maxDepth: maxDepth, isMedia: isMedia, into: &found)
        }
    }
}

/// Decides which Queue tab a file added by hand belongs on.
enum QueueTabRouting {

    /// True when `url` belongs on the tab it was added to: episodes on the TV
    /// Shows tab, everything else on the Movies tab.
    static func belongs(_ url: URL, onTVShowsTab: Bool) -> Bool {
        return QueueController.isTVEpisodeFile(url) == onTVShowsTab
    }

    /// Splits files into those that stay on the tab they were added to and
    /// those that move to the other tab.
    static func split(_ files: [URL], addedToTVShowsTab: Bool) -> (stay: [URL], move: [URL]) {
        var stay: [URL] = []
        var move: [URL] = []
        for file in files {
            if belongs(file, onTVShowsTab: addedToTVShowsTab) { stay.append(file) } else { move.append(file) }
        }
        return (stay, move)
    }

    /// The status line text for `count` files that went to the other tab.
    static func statusMessage(movedCount count: Int, addedToTVShowsTab: Bool) -> String {
        if addedToTVShowsTab {
            return String.localizedStringWithFormat(NSLocalizedString("%lu movie(s) were added to the Movies tab.", comment: "Queue -> files that do not look like TV episodes were put on the Movies tab"), count)
        }
        return String.localizedStringWithFormat(NSLocalizedString("%lu TV episode(s) were added to the TV Shows tab.", comment: "Queue -> files that look like TV episodes were put on the TV Shows tab"), count)
    }
}

/// Subtitle files that sit next to a video (an .srt beside an .mp4). They are
/// not parts of the movie: they are never merged, and they are embedded in
/// the finished file.
enum SidecarSubtitles {

    static let extensions: Set<String> = ["srt", "ass", "ssa"]

    static func isSubtitle(_ url: URL) -> Bool {
        return extensions.contains(url.pathExtension.lowercased())
    }

    /// Splits `files` into the video/audio files and the subtitle files. When
    /// there is nothing but subtitle files they are all treated as media, as
    /// before, so a folder of subtitles alone is not silently ignored.
    static func partition(_ files: [URL]) -> (media: [URL], subtitles: [URL]) {
        let media = files.filter { isSubtitle($0) == false }
        if media.isEmpty { return (files, []) }
        return (media, files.filter(isSubtitle))
    }

    /// The subtitles among `files` that belong to `video`: their names start
    /// with the video's name ("Movie.mp4" takes "Movie.srt" and "Movie.en.srt").
    static func subtitles(for video: URL, among files: [URL]) -> [URL] {
        let base = video.deletingPathExtension().lastPathComponent
        return files.filter { isSubtitle($0) && $0.deletingPathExtension().lastPathComponent.hasPrefix(base) }
    }

    /// Every subtitle file directly inside `folder`, in natural name order.
    static func files(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])) ?? []
        return contents
            .filter { isSubtitle($0) && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// What a folder row waiting for a merge becomes when the folder is read again
/// from disk and now holds a different number of files.
enum ReleaseRescanStage {

    /// A folder waiting for a merge order (or whose merge failed) that now holds
    /// a single file has nothing to merge: it goes on as a single-file release,
    /// waiting for its metadata. Anything else keeps its stage.
    static func stage(after current: QueueRelease.Stage, fileCount: Int, hasMergedFile: Bool) -> QueueRelease.Stage {
        switch current {
        case .pendingMergeSelection, .mergeFailed:
            return fileCount == 1 && hasMergedFile == false ? .pendingMetadata : current
        default:
            return current
        }
    }
}

// MARK: - Tag columns for files sent from the Library scan

/// The values shown in the Queue's tag columns (files sent from the Library
/// scan). A file starts with the values the scan found, and is read again
/// when it has been processed, so the columns show the tags the Queue wrote.
/// Each Queue has its own. Used on the main thread only; the reading itself
/// is done off it.
final class QueueTagValues {

    enum Text: Equatable {
        /// Not read yet.
        case loading
        case value(String)
        /// The file has no value for this tag.
        case missing
    }

    private struct Entry {
        var values: [String: String]
        /// True once the file has been read after it was processed.
        var afterCompletion: Bool
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var reading: Set<ObjectIdentifier> = []
    private let readQueue = DispatchQueue(label: "m3.queue-tag-reader", qos: .utility)

    private static let columnPrefix = "tag:"

    static func columnIdentifier(forKey key: String) -> String { columnPrefix + key }

    /// The tag a Queue column shows, or nil for any other column.
    static func tagKey(ofColumn identifier: String) -> String? {
        guard identifier.hasPrefix(columnPrefix) else { return nil }
        return String(identifier.dropFirst(columnPrefix.count))
    }

    /// Records the values a file had when it was sent (a tag without an
    /// entry was missing).
    func seed(_ item: QueueItem, values: [String: String]) {
        entries[ObjectIdentifier(item)] = Entry(values: values, afterCompletion: false)
    }

    /// Forgets the files that are no longer in the Queue.
    func prune(keeping items: [QueueItem]) {
        let keep = Set(items.map { ObjectIdentifier($0) })
        entries = entries.filter { keep.contains($0.key) }
    }

    /// What a tag is, as text, if the file has been read: empty when the file
    /// has no value, nil when it has not been read yet.
    func knownText(for item: QueueItem, key: String) -> String? {
        guard let entry = entries[ObjectIdentifier(item)] else { return nil }
        return entry.values[key] ?? ""
    }

    /// Reads the files that are not known yet (all at once, in the
    /// background) and calls `completion` on the main thread when done, so a
    /// sort has every value to work with.
    func load(_ items: [QueueItem], completion: @escaping () -> Void) {
        let missing = items.filter { entries[ObjectIdentifier($0)] == nil }
        guard missing.isEmpty == false else { completion(); return }
        let jobs = missing.map { (id: ObjectIdentifier($0), url: $0.status == .completed ? $0.destURL : $0.fileURL, keys: $0.trackedTagKeys, done: $0.status == .completed) }
        readQueue.async { [weak self] in
            let read = jobs.map { job -> (ObjectIdentifier, [String: String]?, Bool) in
                let metadata = MP42File.readMetadata(ofFileAt: job.url)
                return (job.id, metadata.map { LibraryScanCell.values(in: $0, keys: job.keys) }, job.done)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                for (id, values, done) in read where self.entries[id] == nil {
                    self.entries[id] = Entry(values: values ?? [:], afterCompletion: done)
                }
                completion()
            }
        }
    }

    /// What to show for one tag of one item. A file that is not known yet,
    /// or that has been processed since it was last read, is read in the
    /// background and `refreshed` is called when it is done.
    func text(for item: QueueItem, key: String, refreshed: @escaping () -> Void) -> Text {
        let id = ObjectIdentifier(item)
        let done = item.status == .completed
        let entry = entries[id]
        if entry == nil || (done && entry?.afterCompletion == false) {
            startReading(item, id: id, afterCompletion: done, refreshed: refreshed)
        }
        guard let known = entry else { return .loading }
        if let value = known.values[key] { return .value(value) }
        return .missing
    }

    private func startReading(_ item: QueueItem, id: ObjectIdentifier, afterCompletion: Bool, refreshed: @escaping () -> Void) {
        guard reading.contains(id) == false else { return }
        reading.insert(id)
        // A processed file may have been renamed, so it is found by its output name.
        let url = afterCompletion ? item.destURL : item.fileURL
        let keys = item.trackedTagKeys
        readQueue.async { [weak self] in
            let metadata = MP42File.readMetadata(ofFileAt: url)
            let values = metadata.map { LibraryScanCell.values(in: $0, keys: keys) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reading.remove(id)
                // A file that could not be read keeps what it had, and is not tried again.
                let previous = self.entries[id]?.values ?? [:]
                self.entries[id] = Entry(values: values ?? previous, afterCompletion: afterCompletion)
                refreshed()
            }
        }
    }
}
