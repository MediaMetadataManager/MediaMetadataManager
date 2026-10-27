//
//  QueueStatsTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
@testable import M3

/// The totals and timing shown under the Queue list.
final class QueueStatsTests: XCTestCase {

    func testTallyCountsEachState() {
        let tally = QueueTally(ranks: [4, 4, 1, 3, 3, 3, 0, 2])
        XCTAssertEqual(tally.total, 8)
        XCTAssertEqual(tally.done, 2)
        XCTAssertEqual(tally.failed, 1)
        XCTAssertEqual(tally.waiting, 3)
        XCTAssertEqual(tally.working, 1)
        XCTAssertEqual(tally.needsYou, 1)
    }

    func testTallyTextLeavesOutZeroes() {
        XCTAssertEqual(QueueTally(ranks: []).text, "0 in queue")
        XCTAssertEqual(QueueTally(ranks: [4, 3, 3]).text, "3 in queue \u{00B7} 1 done \u{00B7} 2 waiting")
    }

    func testRemainingNeedsEnoughToGoOn() {
        XCTAssertNil(QueueTiming.remaining(elapsed: 5, doneUnits: 1, totalUnits: 10))
        XCTAssertNil(QueueTiming.remaining(elapsed: 60, doneUnits: 0, totalUnits: 10))
        XCTAssertNil(QueueTiming.remaining(elapsed: 60, doneUnits: 0, totalUnits: 0))
    }

    func testRemainingScalesWithProgress() {
        // A quarter done in 60 seconds leaves 180.
        XCTAssertEqual(QueueTiming.remaining(elapsed: 60, doneUnits: 25, totalUnits: 100) ?? -1, 180, accuracy: 0.001)
        XCTAssertEqual(QueueTiming.remaining(elapsed: 60, doneUnits: 100, totalUnits: 100), 0)
    }

    func testClockAndApproximateFormats() {
        XCTAssertEqual(QueueTiming.clock(0), "0:00")
        XCTAssertEqual(QueueTiming.clock(750), "12:30")
        XCTAssertEqual(QueueTiming.clock(3909), "1:05:09")
        XCTAssertEqual(QueueTiming.approximately(45), "45 sec")
        XCTAssertEqual(QueueTiming.approximately(12 * 60), "12 min")
        XCTAssertEqual(QueueTiming.approximately(80 * 60), "1 hr 20 min")
    }
}

/// Spotting a folder that already holds the merged file.
final class AlreadyMergedDetectorTests: XCTestCase {

    private func files(_ sizes: [(String, Int64)]) -> [(url: URL, size: Int64)] {
        sizes.map { (url: URL(fileURLWithPath: "/tmp/\($0.0)"), size: $0.1) }
    }

    func testFindsMergedFileThatMatchesTheParts() {
        // A real folder: five parts and the merged file.
        let found = AlreadyMergedDetector.find(in: files([
            ("merged.mp4", 4_074_638_751), ("p1.mp4", 854_569_075), ("p2.mp4", 991_084_142),
            ("p3.mp4", 642_052_864), ("p4.mp4", 910_815_791), ("p5.mp4", 680_404_934)]))
        XCTAssertEqual(found?.merged.lastPathComponent, "merged.mp4")
        XCTAssertEqual(found?.parts.count, 5)
    }

    func testIgnoresAnOrdinaryFolderOfParts() {
        XCTAssertNil(AlreadyMergedDetector.find(in: files([("a.mp4", 1_000), ("b.mp4", 1_000), ("c.mp4", 1_000)])))
    }

    func testNeedsAtLeastTwoParts() {
        XCTAssertNil(AlreadyMergedDetector.find(in: files([("whole.mp4", 2_000), ("part.mp4", 2_000)])))
    }

    func testRejectsAFileThatIsNotCloseEnough() {
        XCTAssertNil(AlreadyMergedDetector.find(in: files([("big.mp4", 2_300), ("a.mp4", 1_000), ("b.mp4", 1_000)])))
    }
}

/// Where an existing merged file is put when its parts are merged again.
final class OldCopyNameTests: XCTestCase {

    func testAddsOldBeforeTheExtension() {
        let url = QueueController.oldCopyURL(for: URL(fileURLWithPath: "/tmp/Folder/Sample Title (2000).mp4"), fileExists: { _ in false })
        XCTAssertEqual(url.lastPathComponent, "Sample Title (2000) - OLD.mp4")
        XCTAssertEqual(url.deletingLastPathComponent().path, "/tmp/Folder")
    }

    func testNumbersTheNameIfOldIsTaken() {
        var taken: Set<String> = ["Sample - OLD.mp4", "Sample - OLD 2.mp4"]
        let url = QueueController.oldCopyURL(for: URL(fileURLWithPath: "/tmp/Sample.mp4"), fileExists: { taken.contains($0.lastPathComponent) })
        XCTAssertEqual(url.lastPathComponent, "Sample - OLD 3.mp4")
        taken.removeAll()
    }
}

// MARK: - Expanding folder rows

final class QueueOutlineLayoutTests: XCTestCase {

    private func layout(_ count: Int, open: Set<Int>, files: Int = 3) -> QueueOutlineLayout {
        return QueueOutlineLayout(rowCount: count, expanded: open, fileCount: { _ in files })
    }

    func testNothingOpenMapsOneToOne() {
        let l = layout(4, open: [])
        XCTAssertEqual(l.count, 4)
        XCTAssertFalse(l.hasExpansions)
        for i in 0..<4 {
            XCTAssertEqual(l.queueIndex(forTableRow: i), i)
            XCTAssertEqual(l.tableRow(forQueueIndex: i), i)
        }
    }

    func testOpenFolderAddsFileLinesUnderIt() {
        let l = layout(4, open: [1])
        XCTAssertEqual(l.count, 7)
        XCTAssertTrue(l.hasExpansions)
        XCTAssertEqual(l.tableRow(forQueueIndex: 1), 1)
        XCTAssertEqual(l.tableRow(forQueueIndex: 2), 5)
        XCTAssertEqual(l.entry(atTableRow: 2), .file(parent: 1, position: 0))
        XCTAssertTrue(l.isFile(atTableRow: 4))
        XCTAssertFalse(l.isFile(atTableRow: 5))
    }

    func testFileLinesBelongToTheirFolder() {
        let l = layout(3, open: [0])
        XCTAssertEqual(l.queueIndex(forTableRow: 2), 0)
        XCTAssertNil(l.queueIndex(forTableRow: 99))
    }

    func testSelectionIgnoresFileLines() {
        let l = layout(3, open: [0])
        XCTAssertEqual(l.queueIndexes(forTableRows: IndexSet([0, 1, 4, 5])), IndexSet([0, 1, 2]))
        XCTAssertEqual(l.tableRows(forQueueIndexes: IndexSet([0, 2])), IndexSet([0, 5]))
    }

    func testDropInsideOpenFolderLandsAfterIt() {
        let l = layout(3, open: [0])
        XCTAssertEqual(l.queueInsertionIndex(forTableRow: 0), 0)
        XCTAssertEqual(l.queueInsertionIndex(forTableRow: 2), 1)
        XCTAssertEqual(l.queueInsertionIndex(forTableRow: 4), 1)
        XCTAssertEqual(l.queueInsertionIndex(forTableRow: 5), 2)
        XCTAssertEqual(l.queueInsertionIndex(forTableRow: 6), 3)
    }

    func testRedrawIncludesFileLines() {
        let l = layout(3, open: [0])
        XCTAssertEqual(l.tableRowsIncludingFiles(forQueueIndexes: IndexSet(integer: 0)), IndexSet(integersIn: 0...3))
        XCTAssertEqual(l.tableRowsIncludingFiles(forQueueIndexes: IndexSet(integer: 1)), IndexSet(integer: 4))
    }

    func testDifferentFileCountsPerFolder() {
        let l = QueueOutlineLayout(rowCount: 3, expanded: [0, 2], fileCount: { $0 == 0 ? 2 : 1 })
        XCTAssertEqual(l.count, 6)
        XCTAssertEqual(l.tableRow(forQueueIndex: 2), 4)
    }

    // Stage 2: picking and moving the file lines.

    func testFileLinesOfOneFolderAreFound() {
        let l = layout(3, open: [0])
        let found = l.fileLines(inTableRows: IndexSet([1, 3]))
        XCTAssertEqual(found?.parent, 0)
        XCTAssertEqual(found?.positions, IndexSet([0, 2]))
    }

    func testFileLinesNilWhenAFolderRowIsIncluded() {
        let l = layout(3, open: [0])
        XCTAssertNil(l.fileLines(inTableRows: IndexSet([0, 1])))
        XCTAssertNil(l.fileLines(inTableRows: IndexSet()))
    }

    func testFileLinesNilAcrossTwoFolders() {
        let l = layout(3, open: [0, 1])
        // rows: 0 folder, 1-3 files, 4 folder, 5-7 files
        XCTAssertNil(l.fileLines(inTableRows: IndexSet([1, 5])))
    }

    func testSelectionKeepsFilesOfTheFirstFolderOnly() {
        let l = layout(3, open: [0, 1])
        let kept = l.selectionKeepingOneFolder(IndexSet([0, 2, 3, 4, 5])) { _ in true }
        XCTAssertEqual(kept, IndexSet([2, 3]))
    }

    func testSelectionWithoutFilesIsUnchanged() {
        let l = layout(3, open: [])
        XCTAssertEqual(l.selectionKeepingOneFolder(IndexSet([0, 2])) { _ in true }, IndexSet([0, 2]))
    }

    func testSelectionDropsFilesOfAFolderThatRefuses() {
        let l = layout(3, open: [0])
        XCTAssertEqual(l.selectionKeepingOneFolder(IndexSet([1, 2])) { _ in false }, IndexSet())
        XCTAssertEqual(l.selectionKeepingOneFolder(IndexSet([0, 1])) { _ in false }, IndexSet([0]))
    }

    func testDropPositionInsideAFoldersLines() {
        let l = layout(3, open: [1])
        // rows: 0 folder, 1 folder (open), 2-4 files, 5 folder
        XCTAssertEqual(l.filePosition(forDropAtTableRow: 2, inFolder: 1), 0)
        XCTAssertEqual(l.filePosition(forDropAtTableRow: 4, inFolder: 1), 2)
        XCTAssertEqual(l.filePosition(forDropAtTableRow: 5, inFolder: 1), 3)
        XCTAssertNil(l.filePosition(forDropAtTableRow: 1, inFolder: 1))
        XCTAssertNil(l.filePosition(forDropAtTableRow: 6, inFolder: 1))
    }

    func testTableRowsOfFilePositions() {
        let l = layout(3, open: [1])
        XCTAssertEqual(l.tableRows(forFilePositions: IndexSet([0, 2]), inFolder: 1), IndexSet([2, 4]))
    }
}

final class QueueFileOrderTests: XCTestCase {

    private func urls(_ names: [String]) -> [URL] {
        return names.map { URL(fileURLWithPath: "/Sample/\($0)") }
    }

    func testMovingOneFileEarlier() {
        let u = urls(["a.mp4", "b.mp4", "c.mp4", "d.mp4"])
        XCTAssertEqual(QueueFileOrder.moving(u, positions: IndexSet(integer: 3), to: 1), urls(["a.mp4", "d.mp4", "b.mp4", "c.mp4"]))
    }

    func testMovingOneFileLater() {
        let u = urls(["a.mp4", "b.mp4", "c.mp4", "d.mp4"])
        XCTAssertEqual(QueueFileOrder.moving(u, positions: IndexSet(integer: 0), to: 3), urls(["b.mp4", "c.mp4", "a.mp4", "d.mp4"]))
    }

    func testMovingToTheEnd() {
        let u = urls(["a.mp4", "b.mp4", "c.mp4"])
        XCTAssertEqual(QueueFileOrder.moving(u, positions: IndexSet(integer: 0), to: 3), urls(["b.mp4", "c.mp4", "a.mp4"]))
    }

    func testMovingSeveralKeepsTheirOrder() {
        let u = urls(["a.mp4", "b.mp4", "c.mp4", "d.mp4"])
        XCTAssertEqual(QueueFileOrder.moving(u, positions: IndexSet([0, 2]), to: 4), urls(["b.mp4", "d.mp4", "a.mp4", "c.mp4"]))
    }

    func testMovingNothingValidChangesNothing() {
        let u = urls(["a.mp4", "b.mp4"])
        XCTAssertEqual(QueueFileOrder.moving(u, positions: IndexSet(integer: 9), to: 0), u)
    }

    func testDragItemRoundTrips() {
        let value = QueueFileOrder.encode(parent: 12, position: 7)
        let decoded = QueueFileOrder.decode(value)
        XCTAssertEqual(decoded.parent, 12)
        XCTAssertEqual(decoded.position, 7)
    }

    func testSortByNameUsesNaturalOrder() {
        let u = urls(["part 10.mp4", "part 2.mp4", "part 1.mp4"])
        XCTAssertEqual(QueueFileOrder.sorted(u, by: .name, ascending: true, sizes: [:]), urls(["part 1.mp4", "part 2.mp4", "part 10.mp4"]))
        XCTAssertEqual(QueueFileOrder.sorted(u, by: .name, ascending: false, sizes: [:]), urls(["part 10.mp4", "part 2.mp4", "part 1.mp4"]))
    }

    func testSortBySize() {
        let u = urls(["a.mp4", "b.mp4", "c.mp4"])
        let sizes: [URL: Int64] = [u[0]: 300, u[1]: 100, u[2]: 200]
        XCTAssertEqual(QueueFileOrder.sorted(u, by: .size, ascending: true, sizes: sizes), [u[1], u[2], u[0]])
    }

    func testOtherColumnsLeaveTheOrderAlone() {
        let u = urls(["b.mp4", "a.mp4"])
        XCTAssertEqual(QueueFileOrder.sorted(u, by: .status, ascending: true, sizes: [:]), u)
    }
}


final class ReleaseFileStatusTests: XCTestCase {

    private func release(_ stage: QueueRelease.Stage, order: [URL]? = nil) -> (QueueRelease, [URL]) {
        let files = (1...3).map { URL(fileURLWithPath: "/tmp/sample/part\($0).mp4") }
        let r = QueueRelease(folderURL: URL(fileURLWithPath: "/tmp/sample"), sourceFileURLs: files)
        r.stage = stage
        r.mergeOrder = order
        return (r, files)
    }

    func testMergingShowsOnEveryFile() {
        let (r, files) = release(.merging, order: nil)
        XCTAssertEqual(files.map { r.fileStatusText(for: $0) }, ["Merging", "Merging", "Merging"])
    }

    func testFileLinesNeverShowThePercentEvenOnceItIsReported() {
        let (r, files) = release(.merging, order: nil)
        r.mergeProgress = 42.7
        // The folder/release row shows the percentage (mergingText);
        // each file line underneath stays plain so it isn't repeated.
        XCTAssertEqual(r.mergingText, "Merging 42%")
        XCTAssertEqual(r.fileStatusText(for: files[0]), "Merging")
        r.mergeProgress = 0.4
        XCTAssertEqual(r.mergingText, "Merging")
        XCTAssertEqual(r.fileStatusText(for: files[0]), "Merging")
    }

    func testFileLeftOutOfMergeShowsNothing() {
        let (r, files) = release(.merging, order: [])
        let kept = Array(files.prefix(2))
        r.mergeOrder = kept
        XCTAssertEqual(r.fileStatusText(for: files[0]), "Merging")
        XCTAssertNil(r.fileStatusText(for: files[2]))
    }

    func testFailedMergeSaysSo() {
        let (r, files) = release(.mergeFailed, order: nil)
        XCTAssertEqual(r.fileStatusText(for: files[0]), "Merge failed")
    }

    func testMergedFilesSaySoOnceTheMergedFileExists() {
        let (r, files) = release(.pendingMetadata, order: Array(files3().prefix(2)))
        XCTAssertNil(r.fileStatusText(for: files[0]))
        r.mergedFileURL = URL(fileURLWithPath: "/tmp/sample/merged.mp4")
        XCTAssertEqual(r.fileStatusText(for: files[0]), "Merged")
        XCTAssertNil(r.fileStatusText(for: files[2]))
        r.stage = .pendingLibraryMove
        XCTAssertEqual(r.fileStatusText(for: files[1]), "Merged")
    }

    private func files3() -> [URL] { return (1...3).map { URL(fileURLWithPath: "/tmp/sample/part\($0).mp4") } }

    func testOtherStagesShowNothing() {
        let (r, files) = release(.pendingMergeSelection)
        XCTAssertNil(r.fileStatusText(for: files[0]))
    }

    func testSearchingMetadataIsDistinctFromWaiting() {
        let (r, _) = release(.pendingMetadata)
        let waitingRow = QueueRow(release: r)
        XCTAssertEqual(waitingRow.statusSummary.text, "Waiting for metadata")
        XCTAssertEqual(waitingRow.statusSummary.rank, 3)

        r.isSearchingMetadata = true
        let searchingRow = QueueRow(release: r)
        XCTAssertEqual(searchingRow.statusSummary.text, "Searching metadata\u{2026}")
        // Ranked alongside "Working" (0), not "Waiting" (3) -- it's
        // actively doing something, not parked on the user.
        XCTAssertEqual(searchingRow.statusSummary.rank, 0)
    }
}
