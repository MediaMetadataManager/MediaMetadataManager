//
//  LibraryScanClearTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//

import XCTest
@testable import M3

/// When the Library scan's Clear button (and the right-click Clear List) may
/// empty the list.
final class LibraryScanClearTests: XCTestCase {

    func testClearIsAvailableWhenFilesAreListedAndNothingIsRunning() {
        XCTAssertTrue(LibraryScanCell.canClear(isScanning: false, isWritingTag: false, listedCount: 3))
    }

    func testClearIsOffForAnEmptyList() {
        XCTAssertFalse(LibraryScanCell.canClear(isScanning: false, isWritingTag: false, listedCount: 0))
    }

    func testClearIsOffWhileScanningEvenWhenPaused() {
        XCTAssertFalse(LibraryScanCell.canClear(isScanning: true, isWritingTag: false, listedCount: 3))
    }

    func testClearIsOffWhileATagIsBeingWritten() {
        XCTAssertFalse(LibraryScanCell.canClear(isScanning: false, isWritingTag: true, listedCount: 3))
    }
}
