//
//  Queue.swift
//  Subler
//
//  Created by Damiano Galassi on 27/01/2019.
//

import Foundation
import IOKit

final class Queue {

    static let Working = NSNotification.Name(rawValue: "QueueWorkingNotification")
    static let Completed = NSNotification.Name(rawValue: "QueueCompletedNotification")
    static let Failed = NSNotification.Name(rawValue: "QueueFailedNotification")
    static let Cancelled = NSNotification.Name(rawValue: "QueueCancelledNotification")

    private let workQueue: DispatchQueue
    private let arrayQueue: DispatchQueue

    private var sleepAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var sleepAssertionSuccess: IOReturn = kIOReturnInvalid

    /// The queue's rows. Each row wraps either a plain, already-ready
    /// QueueItem (today's manual drag-and-drop / AppleScript path) or a
    /// QueueRelease (the Intake/Queue workflow's multi-stage path) -- see
    /// QueueRow. A release row is invisible to the work loop below until
    /// it resolves to a real QueueItem (QueueRow.effectiveItem), so it
    /// can sit here mid-naming or mid-merge without being muxed.
    private var items: [QueueRow]

    private var cancelled: Bool
    private var currentItem: QueueItem?

    private let url: URL

    private let logger = Logger.shared

    enum Status {
        case unknown
        case working
        case completed
    }

    init(url queueURL: URL) {
        url = queueURL
        statusInternal = .unknown
        cancelled = false

        workQueue = DispatchQueue(label: "org.subler.WorkQueue")
        arrayQueue = DispatchQueue(label: "org.subler.SaveQueue")

        do {
            let data = try Data(contentsOf: url)
            items = Queue.decodeRows(from: data) ?? []
        } catch {
            items = []
        }

        // Queue files saved before rows were numbered get numbers in the order
        // they are listed in, so "#" starts out matching what is on screen.
        var lastNumber = items.map { $0.addedNumber }.max() ?? 0
        for row in items where row.addedNumber == 0 {
            lastNumber += 1
            row.addedNumber = lastNumber
        }

        for item in items.compactMap({ $0.effectiveItem }) where item.status == .working {
            item.restoreInterruptedEdit()
            item.status = .failed
        }

        // A release that was merging when M3 quit has no merge running any
        // more. Left as "merging" it could never be removed or retried, so
        // it is moved to "merge failed", where Edit reopens the merge sheet.
        // Nothing is merging yet at launch, so any hidden half-written merge
        // file next to a queued release was left by an earlier quit or crash.
        let folders = items.compactMap({ $0.release?.folderURL })
        DispatchQueue.global(qos: .utility).async {
            for folder in folders { FileMerger.removeLeftoverTemporaries(in: folder) }
        }

        for release in items.compactMap({ $0.release }) where release.stage == .merging {
            release.stage = .mergeFailed
            release.mergeErrorMessage = NSLocalizedString("M3 was quit while this release was merging. Open it to check the order and merge again.", comment: "Release merge interrupted by quitting")
        }
    }

    /// Decodes a persisted queue file, preferring the current QueueRow
    /// format but falling back to the older, pre-QueueRow format (a plain
    /// `[QueueItem]` array) so upgrading to this build doesn't silently
    /// drop whatever was already queued -- saveToDisk() below always
    /// writes the new format from this point on, so this fallback only
    /// ever matters once, on the first launch after upgrading.
    private static func decodeRows(from data: Data) -> [QueueRow]? {
        if let rows: [QueueRow] = decode(data, of: QueueRow.classForCoder()) {
            return rows
        }

        // Needs a fresh NSKeyedUnarchiver over the same data -- the
        // attempt above has already consumed the first one.
        if let legacyItems: [QueueItem] = decode(data, of: QueueItem.classForCoder()) {
            return legacyItems.map { QueueRow(item: $0) }
        }

        Logger.shared.write(toLog: "Unable to read the saved queue; starting with an empty queue")
        return nil
    }

    /// Decodes a top-level array of `element` objects using the throwing,
    /// secure-coding unarchiver API. Returns nil if the data can't be read
    /// or isn't an array of that type.
    private static func decode<T>(_ data: Data, of element: AnyClass) -> [T]? {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }
            return try unarchiver.decodeTopLevelObject(of: [NSArray.classForCoder(), NSMutableArray.classForCoder(), element],
                                                       forKey: NSKeyedArchiveRootObjectKey) as? [T]
        } catch {
            return nil
        }
    }

    func saveToDisk() throws {
        try arrayQueue.sync {
            let data = try NSKeyedArchiver.archivedData(withRootObject: items, requiringSecureCoding: true)
            try data.write(to: url, options: .atomic)
        }
    }

    private enum ProcessResult {
        case completed
        case failed
        case cancelled
    }

    private func process(_ item: QueueItem) -> ProcessResult {
        return autoreleasepool { () -> ProcessResult in
            self.arrayQueue.sync {
                self.currentItem = item
            }

            item.status = .working
            item.delegate = self

            defer {
                item.delegate = nil
                self.arrayQueue.sync {
                    self.currentItem = nil
                }
            }

            self.handleSBStatusWorking(progress: 0, index: self.index(of: item))
            do {
                try item.process()

                var cancelled = false
                self.arrayQueue.sync {
                    cancelled = self.cancelled
                }

                if cancelled {
                    item.status = .cancelled
                    self.handleSBStatusCancelled()
                    return .cancelled
                } else {
                    item.status = .completed
                    self.handleSBStatusWorking(progress: 100, index: self.index(of: item))
                    return .completed
                }
            } catch {
                item.status = .failed
                self.handleSBStatusFailed(error: error)

                var cancelled = false
                self.arrayQueue.sync {
                    cancelled = self.cancelled
                }

                if cancelled {
                    self.handleSBStatusCancelled()
                    return .cancelled
                } else {
                    return .failed
                }
            }
        }
    }

    /// Starts the queue.
    func start() {
        var shouldStart = false
        arrayQueue.sync {
            if self.statusInternal != .working {
                shouldStart = true
                self.statusInternal = .working
                self.cancelled = false
            }
        }
        if shouldStart == false {
            return
        }

        workQueue.async {
            self.disableSleep()

            var completed: UInt = 0
            var failed: UInt = 0

            while(true) {
                try? self.saveToDisk()

                let tookLane = QueueLane.shared.enter(exclusive: !MediaIntakePrefs.runQueuesTogether)
                if let currentItem = self.firstItemInQueue {
                    let result = self.process(currentItem)
                    QueueLane.shared.leave(tookLane)
                    if .completed == result {
                        completed += 1
                        self.logger.write(toLog: currentItem.fileURL.lastPathComponent + " completed")
                    } else if .failed == result {
                        failed += 1
                        self.logger.write(toLog: currentItem.fileURL.lastPathComponent + " failed")
                    } else if .cancelled == result {
                        self.logger.write(toLog: currentItem.fileURL.lastPathComponent + " cancelled")
                        break
                    }
                } else {
                    QueueLane.shared.leave(tookLane)
                    break
                }
            }
            self.enableSleep()
            self.arrayQueue.sync {
                self.statusInternal = .completed
            }
            self.handleSBStatusCompleted(completed: completed, failed: failed)
        }
    }

    /// Stops the queue and abort the current work.
    func stop() {
        arrayQueue.sync {
            currentItem?.cancel()
            cancelled = true
        }
    }

    /// Runs `work` serialized against this Queue's own single-worker mux
    /// lane -- the same private workQueue that processItem(_:) already runs
    /// on inside start()'s pull loop. A file merge (FileMerger.merge, called
    /// from QueueController) isn't a QueueItem and can't go through
    /// process(_:)/QueueActionProtocol (see FileMerger.swift's own doc
    /// comment for why a many-inputs-to-one-output operation doesn't fit
    /// that one-item-in/same-item-out shape), but it's exactly as CPU/disk
    /// intensive as muxing a QueueItem is, and previously ran on its own
    /// unrelated DispatchQueue.global(qos:) -- meaning a merge and the
    /// Queue actively processing a ready item could run fully concurrently,
    /// contending for resources with no coordination at all, unlike every
    /// other pair of queued operations. Routing merge work through this
    /// method instead puts it on the same lane as everything else: if the
    /// Queue is mid-item, the merge waits its turn on workQueue exactly the
    /// way the next QueueItem would; if the Queue is idle, it runs
    /// immediately. `work` still runs on a background thread (never the
    /// main thread) and callers dispatch their own UI updates back to main
    /// themselves, same as they already did.
    func performSerialized(_ work: @escaping () -> Void) {
        workQueue.async {
            let tookLane = QueueLane.shared.enter(exclusive: !MediaIntakePrefs.runQueuesTogether)
            work()
            QueueLane.shared.leave(tookLane)
        }
    }

    private var statusInternal: Status

    var status: Status {
        get {
            return arrayQueue.sync { self.statusInternal }
        }
    }

    var count: Int {
        get {
            return arrayQueue.sync { items.count }
        }
    }

    var readyCount: Int {
        get {
            return arrayQueue.sync { items.compactMap { $0.effectiveItem }.filter { $0.status == .ready }.count }
        }
    }

    /// Pulls the next ready QueueItem to mux, looking through each row's
    /// effectiveItem rather than assuming every row already has one -- a
    /// release still waiting on naming approval or a merge (no
    /// resolvedItem yet) simply doesn't appear here, by construction, with
    /// no separate "don't process this yet" flag needed.
    private var firstItemInQueue: QueueItem? {
        get {
            return arrayQueue.sync {
                let first = items.compactMap { $0.effectiveItem }.first(where: { $0.status == .ready })
                first?.status = .working
                return first
            }
        }
    }

    //MARK: Row management

    func append(_ row: QueueRow) {
        arrayQueue.sync {
            numberIfNeeded(row)
            items.append(row)
        }
    }

    /// Gives a newly added row the next "added" number (see
    /// QueueRow.addedNumber). Call while the list is locked.
    private func numberIfNeeded(_ row: QueueRow) {
        guard row.addedNumber == 0 else { return }
        row.addedNumber = (items.map { $0.addedNumber }.max() ?? 0) + 1
    }

    /// The number shown in the "#" column: 1 for the file added first of the
    /// ones still in the Queue. Counting only what is left means removing a
    /// file never leaves a gap.
    func addedRank(of row: QueueRow) -> Int {
        return arrayQueue.sync {
            items.filter { $0.folderHeaderURL == nil && $0.addedNumber < row.addedNumber }.count + 1
        }
    }

    func row(at index: Int) -> QueueRow {
        return arrayQueue.sync { items[index] }
    }

    func rows(at indexes: IndexSet) -> [QueueRow] {
        return arrayQueue.sync { indexes.map { items[$0] } }
    }

    func index(of row: QueueRow) -> Int {
        return arrayQueue.sync { items.firstIndex(of: row) ?? -1 }
    }

    func indexesOfRows(where predicate: (QueueRow) -> Bool) -> IndexSet {
        return arrayQueue.sync { IndexSet(items.enumerated().filter { predicate($0.element) } .map { $0.offset }) }
    }

    func insert(_ row: QueueRow, at index: Int) {
        arrayQueue.sync {
            numberIfNeeded(row)
            items.insert(row, at: index)
        }
    }

    func remove(at indexes: IndexSet) {
        arrayQueue.sync { items = IndexSet(items.indices).subtracting(indexes).map { items[$0] } }
    }

    /// A copy of the rows in their current order.
    var allRows: [QueueRow] {
        return arrayQueue.sync { items }
    }

    /// Puts the rows in the order `transform` returns. Runs while the list
    /// is locked, so rows added meanwhile are not lost; the result is
    /// ignored unless it holds exactly the same rows.
    func reorder(_ transform: ([QueueRow]) -> [QueueRow]) {
        arrayQueue.sync {
            let proposed = transform(items)
            guard proposed.count == items.count,
                  Set(proposed.map { ObjectIdentifier($0) }) == Set(items.map { ObjectIdentifier($0) })
            else { return }
            items = proposed
        }
    }

    func swapAt(_ i: Int, _ j: Int) {
        arrayQueue.sync { items.swapAt(i, j) }
    }

    func remove(_ row: QueueRow) {
        arrayQueue.sync {
            if let index = items.firstIndex(of: row) {
                items.remove(at: index)
            }
        }
    }

    /// Looks up a still-live QueueRelease by ID. Used by
    /// QueueMoveToLibraryAction (QueueAction.swift, Intake/Queue workflow
    /// phase 5) to resolve the release it belongs to at runAction(_:)
    /// time -- reached via QueueItem.delegate, which process(_:) above
    /// sets for the duration of muxing -- rather than through a separate
    /// coordinator singleton, since Queue already holds every release
    /// live in `items`. Returns nil if the release's row was somehow
    /// removed from the queue between mux completion and this running.
    func release(withID id: UUID) -> QueueRelease? {
        return arrayQueue.sync { items.compactMap { $0.release }.first(where: { $0.id == id }) }
    }

    func removeCompletedItems() -> IndexSet {
        return arrayQueue.sync {
            let indexes = IndexSet(items.enumerated().filter { $0.element.effectiveItem?.status == .completed } .map { $0.offset })
            items = IndexSet(items.indices).subtracting(indexes).map { items[$0] }
            return indexes
        }
    }

    //MARK: Item management
    //
    // Convenience wrappers around the row-based API above, for the plain
    // manually-queued-file path (AppleScript, "File > Add to Queue",
    // dragging files/folders straight into the Queue window) that has no
    // reason to know QueueRow exists. Every one of these degrades
    // gracefully around a still-unresolved release row -- e.g. item(at:)
    // returns nil for one -- rather than crashing, since such a row simply
    // has no QueueItem yet.

    func append(_ item: QueueItem) {
        append(QueueRow(item: item))
    }

    func item(at index: Int) -> QueueItem? {
        return row(at: index).effectiveItem
    }

    func items(at indexes: IndexSet) -> [QueueItem] {
        return rows(at: indexes).compactMap { $0.effectiveItem }
    }

    func index(of item: QueueItem) -> Int {
        return arrayQueue.sync { items.firstIndex(where: { $0.effectiveItem == item }) ?? -1 }
    }

    func indexesOfItems(with status: QueueItem.Status) -> IndexSet {
        return indexesOfRows(where: { $0.effectiveItem?.status == status })
    }

    func insert(_ item: QueueItem, at index: Int) {
        insert(QueueRow(item: item), at: index)
    }

    //MARK: Sleep

    private func disableSleep() {
        sleepAssertionSuccess = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                            "Media Metadata Manager Queue" as CFString,
                                                            &sleepAssertion)
    }

    private func enableSleep() {
        if sleepAssertionSuccess == kIOReturnSuccess {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertionSuccess = kIOReturnInvalid
            sleepAssertion = IOPMAssertionID(0)
        }
    }

    // MARK: Notifications

    func updateProgress(_ progress: Double) {
        handleSBStatusWorking(progress: progress, index: -1)
    }

    /// Processes SBQueueStatusWorking state information. Current implementation just
    /// sends SBQueueWorkingNotification.
    private func handleSBStatusWorking(progress: Double, index: Int) {
        let itemDescription = currentItem?.localizedWorkingDescription ?? NSLocalizedString("Working", comment: "Queue Working.")
        let info = String.localizedStringWithFormat(NSLocalizedString("%@.", comment: ""), itemDescription)

        NotificationCenter.default.post(name: Queue.Working, object: self, userInfo: ["ProgressString": info, "Progress": progress, "ItemIndex": index])
    }

    /// Processes SBQueueStatusCompleted state information. Current implementation just
    /// sends SBQueueCompletedNotification.
    private func handleSBStatusCompleted(completed: UInt, failed: UInt) {
        NotificationCenter.default.post(name: Queue.Completed, object: self, userInfo: ["CompletedCount": completed, "FailedCount": failed])
    }

    /// Processes SBQueueStatusFailed state information. Current implementation just
    /// sends SBQueueFailedNotification.
    private func handleSBStatusFailed(error: Error) {
        NotificationCenter.default.post(name: Queue.Failed, object: self, userInfo: ["Error": error])
    }

    /// Processes SBQueueStatusCancelled state information. Current implementation just
    /// sends SBQueueCancelledNotification.
    private func handleSBStatusCancelled() {
        NotificationCenter.default.post(name: Queue.Cancelled, object: self)
    }

}

/// One turn at a time across the Movies and TV Shows queues. Each queue has
/// its own worker; unless "run both queues together" is on, a worker takes
/// this lane before it processes or merges a file and gives it back
/// afterwards, so the two queues alternate instead of competing for the disk.
final class QueueLane {

    static let shared = QueueLane()

    private let semaphore = DispatchSemaphore(value: 1)

    /// Waits for the lane when `exclusive`. Returns whether the lane was
    /// taken, to be passed to `leave`. When not exclusive it never waits.
    func enter(exclusive: Bool) -> Bool {
        guard exclusive else { return false }
        semaphore.wait()
        return true
    }

    func leave(_ tookLane: Bool) {
        if tookLane { semaphore.signal() }
    }
}
