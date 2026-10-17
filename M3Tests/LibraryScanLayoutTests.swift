//
//  LibraryScanLayoutTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// The Library scan remembers its column order, widths and sort.
final class LibraryScanLayoutTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "LibraryScanLayoutTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testNothingSavedGivesDefaults() {
        let layout = LibraryScanLayout.load(from: defaults)
        XCTAssertTrue(layout.order.isEmpty)
        XCTAssertTrue(layout.widths.isEmpty)
        XCTAssertNil(layout.sortKey)
        XCTAssertTrue(layout.ascending)
    }

    func testSavedLayoutIsReadBack() {
        var layout = LibraryScanLayout()
        layout.order = ["tag:Name", "file"]
        layout.widths = ["file": 250, "tag:Name": 90]
        layout.sortKey = "tag:Name"
        layout.ascending = false
        layout.save(to: defaults)
        XCTAssertEqual(LibraryScanLayout.load(from: defaults), layout)
    }

    func testOrderUsesSavedOrderThenTheRest() {
        let ids = ["file", "tag:A", "tag:B", "tag:C"]
        XCTAssertEqual(LibraryScanLayout.order(of: ids, saved: ["tag:C", "file"]), ["tag:C", "file", "tag:A", "tag:B"])
    }

    func testOrderIgnoresSavedColumnsThatAreGone() {
        XCTAssertEqual(LibraryScanLayout.order(of: ["file", "tag:A"], saved: ["tag:Z", "tag:A", "file"]), ["tag:A", "file"])
    }

    func testMergedKeepsHiddenColumnsAfterTheVisibleOnes() {
        let merged = LibraryScanLayout.merged(saved: ["file", "tag:Hidden", "tag:A"], current: ["tag:A", "file"])
        XCTAssertEqual(merged, ["tag:A", "file", "tag:Hidden"])
    }
}
