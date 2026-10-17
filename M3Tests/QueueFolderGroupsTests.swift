//
//  QueueFolderGroupsTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// Removing rows from a folder group in the Queue.
final class QueueFolderGroupsTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/tmp/Sample Show/Season 1", isDirectory: true)

    private func file(_ name: String, in folder: URL? = nil) -> QueueRow {
        let url = URL(fileURLWithPath: "/tmp/Sample Show/Season 1/\(name).m4v")
        return QueueRow(item: QueueItem(fileURL: url, destination: url, sourceFolderURL: folder))
    }

    /// 0 loose file, 1 header, 2-4 files in the folder, 5 loose file.
    private func rows() -> [QueueRow] {
        return [file("loose one"), QueueRow(folderHeaderURL: folder),
                file("a", in: folder), file("b", in: folder), file("c", in: folder), file("loose two")]
    }

    func testRemovingTheHeaderRemovesItsFiles() {
        let result = QueueFolderGroups.indexesToRemove(selected: [1], rows: rows(), keep: { _ in false })
        XCTAssertEqual(result, [1, 2, 3, 4])
    }

    func testRemovingOneFileKeepsTheHeader() {
        let result = QueueFolderGroups.indexesToRemove(selected: [3], rows: rows(), keep: { _ in false })
        XCTAssertEqual(result, [3])
    }

    func testLooseRowsAreUnaffected() {
        let result = QueueFolderGroups.indexesToRemove(selected: [0, 5], rows: rows(), keep: { _ in false })
        XCTAssertEqual(result, [0, 5])
    }

    func testAFileInProgressKeepsItsHeaderAndItself() {
        let all = rows()
        let busy = all[3]
        let result = QueueFolderGroups.indexesToRemove(selected: [1], rows: all, keep: { $0 === busy })
        XCTAssertEqual(result, [2, 4])
    }
}

/// A closed folder header hides the files under it.
final class QueueClosedFolderLayoutTests: XCTestCase {

    private func layout(hidden: Set<Int>) -> QueueOutlineLayout {
        return QueueOutlineLayout(rowCount: 6, expanded: [], hidden: hidden, fileCount: { _ in 0 })
    }

    func testHiddenRowsAreNotDrawn() {
        // 0 loose file, 1 header, 2-4 its files (closed), 5 loose file.
        let l = layout(hidden: [2, 3, 4])
        XCTAssertEqual(l.count, 3)
        XCTAssertTrue(l.hasExpansions)
        XCTAssertEqual(l.tableRow(forQueueIndex: 1), 1)
        XCTAssertNil(l.tableRow(forQueueIndex: 3))
        XCTAssertEqual(l.tableRow(forQueueIndex: 5), 2)
        XCTAssertEqual(l.queueIndex(forTableRow: 2), 5)
    }

    func testOpenFolderShowsEverything() {
        let l = layout(hidden: [])
        XCTAssertEqual(l.count, 6)
        XCTAssertFalse(l.hasExpansions)
        XCTAssertEqual(l.tableRow(forQueueIndex: 4), 4)
    }

    func testDropBelowAClosedFolderLandsAfterItsFiles() {
        let l = layout(hidden: [2, 3, 4])
        XCTAssertEqual(l.queueInsertionIndex(forTableRow: 2), 5)
        XCTAssertEqual(l.queueInsertionIndex(forTableRow: 3), 6)
    }

    func testSelectionMapsOnlyShownRows() {
        let l = layout(hidden: [2, 3, 4])
        XCTAssertEqual(l.tableRows(forQueueIndexes: IndexSet([1, 3, 5])), IndexSet([1, 2]))
    }
}
