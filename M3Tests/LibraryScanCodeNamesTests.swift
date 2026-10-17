//
//  LibraryScanCodeNamesTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
import MP42Foundation
@testable import M3

/// Tags the file stores as a code (Media Kind, Content Rating, Rating) show by
/// name in the Library scan and in the Queue's tag columns, not as the number.
final class LibraryScanCodeNamesTests: XCTestCase {

    private func number(_ key: String, _ value: Int) -> MP42MetadataItem {
        return MP42MetadataItem(identifier: key, value: NSNumber(value: value), dataType: .integer, extendedLanguageTag: nil)
    }

    private func string(_ key: String, _ value: String) -> MP42MetadataItem {
        return MP42MetadataItem(identifier: key, value: value as NSString, dataType: .string, extendedLanguageTag: nil)
    }

    private func title(_ list: [(title: String, value: Int)], _ code: Int) -> String? {
        return list.first { $0.value == code }?.title
    }

    func testMediaKindShowsItsName() {
        XCTAssertEqual(LibraryScanCell.text(for: number(MP42MetadataKeyMediaKind, 10)), title(MovieViewController.mediaKinds, 10))
        XCTAssertEqual(LibraryScanCell.text(for: number(MP42MetadataKeyMediaKind, 9)), title(MovieViewController.mediaKinds, 9))
        XCTAssertNotEqual(LibraryScanCell.text(for: number(MP42MetadataKeyMediaKind, 10)), "10")
    }

    func testContentRatingShowsItsName() {
        XCTAssertEqual(LibraryScanCell.text(for: number(MP42MetadataKeyContentRating, 4)), title(MovieViewController.contentRatings, 4))
        XCTAssertEqual(LibraryScanCell.text(for: number(MP42MetadataKeyContentRating, 2)), title(MovieViewController.contentRatings, 2))
        XCTAssertNotEqual(LibraryScanCell.text(for: number(MP42MetadataKeyContentRating, 4)), "4")
    }

    func testCodeStoredAsTextIsAlsoNamed() {
        XCTAssertEqual(LibraryScanCell.text(for: string(MP42MetadataKeyMediaKind, "10")), title(MovieViewController.mediaKinds, 10))
    }

    func testUnknownCodeStaysANumber() {
        XCTAssertEqual(LibraryScanCell.text(for: number(MP42MetadataKeyMediaKind, 99)), "99")
        XCTAssertEqual(LibraryScanCell.text(for: number(MP42MetadataKeyContentRating, 7)), "7")
    }

    func testRatingShowsTheRatingNameOnly() {
        XCTAssertEqual(LibraryScanCell.text(for: string(MP42MetadataKeyRating, "mpaa|R|300|")), "R")
        XCTAssertEqual(LibraryScanCell.text(for: string(MP42MetadataKeyRating, "PG")), "PG")
    }

    func testOtherNumbersAreUnchanged() {
        XCTAssertEqual(LibraryScanCell.text(for: number(MP42MetadataKeyTVSeason, 4)), "4")
    }
}
