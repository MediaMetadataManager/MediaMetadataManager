//
//  QueueSorterTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
@testable import M3

/// Ordering the Queue by a column.
final class QueueSorterTests: XCTestCase {

    private func entry(_ name: String, rank: Int = 3, status: String = "", size: Int64 = 0, kind: String = "MP4", header: Bool = false, group: String? = nil) -> QueueSortEntry {
        QueueSortEntry(name: name, statusText: status, statusRank: rank, size: size, kind: kind, isHeader: header, group: group)
    }

    private func names(_ entries: [QueueSortEntry], _ order: [Int]) -> [String] {
        order.map { entries[$0].name }
    }

    func testSortByNameIsNaturalAndReversible() {
        let entries = [entry("Movie 10"), entry("movie 2"), entry("Alpha")]
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .name, ascending: true)), ["Alpha", "movie 2", "Movie 10"])
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .name, ascending: false)), ["Movie 10", "movie 2", "Alpha"])
    }

    func testSortByStatusIsAlphabetical() {
        let entries = [entry("c", status: "Ready"), entry("a", status: "Completed"), entry("b", status: "Failed"), entry("w", status: "Working")]
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .status, ascending: true)), ["a", "b", "c", "w"])
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .status, ascending: false)), ["w", "c", "b", "a"])
    }

    func testEqualStatusFallsBackToName() {
        let entries = [entry("b", status: "Failed"), entry("a", status: "Failed")]
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .status, ascending: true)), ["a", "b"])
    }

    func testSortBySizeAndKind() {
        let entries = [entry("big", size: 900, kind: "MKV"), entry("small", size: 10, kind: "MP4"), entry("mid", size: 100, kind: "AVI")]
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .size, ascending: true)), ["small", "mid", "big"])
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .kind, ascending: true)), ["mid", "big", "small"])
    }

    func testResultIsAPermutationAndStable() {
        let entries = [entry("same"), entry("same"), entry("same")]
        XCTAssertEqual(QueueSorter.order(of: entries, by: .name, ascending: true), [0, 1, 2])
    }

    func testFolderHeaderStaysAboveItsFiles() {
        let entries = [
            entry("Zeta folder", header: true, group: "/z"),
            entry("b file", group: "/z"),
            entry("a file", group: "/z"),
            entry("Alpha single")
        ]
        let sorted = names(entries, QueueSorter.order(of: entries, by: .name, ascending: true))
        XCTAssertEqual(sorted, ["Alpha single", "Zeta folder", "a file", "b file"])
    }

    func testFilesStayInsideTheirOwnFolderWhenSortingByStatus() {
        let entries = [
            entry("Folder A", header: true, group: "/a"),
            entry("a1", status: "Done", group: "/a"),
            entry("a2", status: "Failed", group: "/a"),
            entry("Folder B", header: true, group: "/b"),
            entry("b1", status: "Cancelled", group: "/b")
        ]
        let sorted = names(entries, QueueSorter.order(of: entries, by: .status, ascending: true))
        XCTAssertEqual(sorted, ["Folder B", "b1", "Folder A", "a1", "a2"])
    }

    func testSortByAddedOrderRestoresTheOriginalOrder() {
        // Rows as they sit after being sorted by name; "added" is when each was queued.
        var b = entry("b"); b.added = 2
        var c = entry("c"); c.added = 3
        var a = entry("a"); a.added = 1
        let entries = [a, b, c].reversed().map { $0 }   // c, b, a
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .added, ascending: true)), ["a", "b", "c"])
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .added, ascending: false)), ["c", "b", "a"])
    }

    func testSortByAddedKeepsFolderFilesTogether() {
        var header = entry("Folder", header: true, group: "/f"); header.added = 2
        var f2 = entry("f2", group: "/f"); f2.added = 4
        var f1 = entry("f1", group: "/f"); f1.added = 3
        var single = entry("single"); single.added = 1
        let entries = [header, f2, f1, single]
        XCTAssertEqual(names(entries, QueueSorter.order(of: entries, by: .added, ascending: true)), ["single", "Folder", "f1", "f2"])
    }

    func testEmptyInput() {
        XCTAssertEqual(QueueSorter.order(of: [], by: .name, ascending: true), [])
    }
}
