//
//  LibraryScanFieldsTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
import MP42Foundation
@testable import M3

/// The Library scan checks Title and Release Date on every scan. Rating and
/// Studio are not checked unless they are ticked in the gear panel.
final class LibraryScanFieldsTests: XCTestCase {

    func testAlwaysCheckedAreTitleAndReleaseDate() {
        XCTAssertEqual(LibraryScanWindowController.alwaysCheckedKeys,
                       [MP42MetadataKeyName, MP42MetadataKeyReleaseDate])
    }

    func testRatingAndStudioAreNotAlwaysChecked() {
        let keys = LibraryScanWindowController.alwaysCheckedKeys
        XCTAssertFalse(keys.contains(MP42MetadataKeyRating))
        XCTAssertFalse(keys.contains(MP42MetadataKeyStudio))
    }

    func testRatingAndStudioCanStillBeTicked() {
        XCTAssertTrue(MP42Metadata.writableMetadata.contains(MP42MetadataKeyRating))
        XCTAssertTrue(MP42Metadata.writableMetadata.contains(MP42MetadataKeyStudio))
    }
}
