//
//  LibraryScanColumnsTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
import MP42Foundation
@testable import M3

/// What the Library scan table shows for each checked tag, and how a tag's
/// column sorts.
final class LibraryScanColumnsTests: XCTestCase {

    private func item(_ key: String, _ value: NSCopying & NSObjectProtocol, _ type: MP42MetadataItemDataType = .unspecified) -> MP42MetadataItem {
        MP42MetadataItem(identifier: key, value: value, dataType: type, extendedLanguageTag: nil)
    }

    func testFilledTextIsShown() {
        let items = [item(MP42MetadataKeyName, "Sample Movie" as NSString)]
        XCTAssertEqual(LibraryScanCell.text(for: items), "Sample Movie")
    }

    func testBlankTextIsMissing() {
        let items = [item(MP42MetadataKeyName, "   " as NSString)]
        XCTAssertNil(LibraryScanCell.text(for: items))
    }

    func testNoEntryIsMissing() {
        XCTAssertNil(LibraryScanCell.text(for: []))
    }

    func testFirstFilledEntryWinsOverBlankOnes() {
        let items = [item(MP42MetadataKeyStudio, "" as NSString),
                     item(MP42MetadataKeyStudio, "Sample Studio" as NSString)]
        XCTAssertEqual(LibraryScanCell.text(for: items), "Sample Studio")
    }

    func testNumberIsShown() {
        let items = [item(MP42MetadataKeyTVSeason, NSNumber(value: 7), .integer)]
        XCTAssertEqual(LibraryScanCell.text(for: items), "7")
    }

    func testDateShowsTheDayOnly() {
        let items = [item(MP42MetadataKeyReleaseDate, "2020-05-01" as NSString)]
        XCTAssertEqual(LibraryScanCell.text(for: items), "2020-05-01")
    }

    func testMissingSortsBeforeText() {
        XCTAssertEqual(LibraryScanCell.sortOrder(nil, "A"), .orderedAscending)
        XCTAssertEqual(LibraryScanCell.sortOrder("A", nil), .orderedDescending)
        XCTAssertEqual(LibraryScanCell.sortOrder(nil, nil), .orderedSame)
    }

    func testTextSortsInNaturalOrder() {
        XCTAssertEqual(LibraryScanCell.sortOrder("Part 2", "Part 10"), .orderedAscending)
        XCTAssertEqual(LibraryScanCell.sortOrder("b", "a"), .orderedDescending)
    }
}
