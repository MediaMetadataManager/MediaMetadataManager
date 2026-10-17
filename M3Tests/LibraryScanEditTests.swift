//
//  LibraryScanEditTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
import MP42Foundation
@testable import M3

/// Typing a tag into the Library scan table, and sending library files to the
/// Queue to be edited where they sit.
final class LibraryScanEditTests: XCTestCase {

    // MARK: Which tags can be typed

    func testTextTagsCanBeEdited() {
        XCTAssertTrue(LibraryScanEdit.canEdit(key: MP42MetadataKeyTVSeason))
        XCTAssertTrue(LibraryScanEdit.canEdit(key: MP42MetadataKeyName))
        XCTAssertTrue(LibraryScanEdit.canEdit(key: MP42MetadataKeyStudio))
        XCTAssertTrue(LibraryScanEdit.canEdit(key: MP42MetadataKeyReleaseDate))
    }

    func testRatingAndArtworkAreLeftToTheEditor() {
        XCTAssertFalse(LibraryScanEdit.canEdit(key: MP42MetadataKeyRating))
        XCTAssertFalse(LibraryScanEdit.canEdit(key: MP42MetadataKeyCoverArt))
        XCTAssertFalse(LibraryScanEdit.canEdit(key: MP42MetadataKeyCast))
        XCTAssertFalse(LibraryScanEdit.canEdit(key: MP42MetadataKeyGapless))
    }

    // MARK: What was typed

    func testTextIsAccepted() throws {
        let item = try LibraryScanEdit.makeItem(key: MP42MetadataKeyName, text: "Sample Movie").get()
        XCTAssertEqual(item.stringValue, "Sample Movie")
    }

    func testFullDateIsAccepted() throws {
        let item = try LibraryScanEdit.makeItem(key: MP42MetadataKeyReleaseDate, text: "2020-05-01").get()
        XCTAssertEqual(item.dataType, .date)
        XCTAssertEqual(LibraryScanCell.text(for: item), "2020-05-01")
    }

    func testYearAloneIsNotAValidReleaseDate() {
        if case .success = LibraryScanEdit.makeItem(key: MP42MetadataKeyReleaseDate, text: "2020") {
            XCTFail("A year alone should be refused")
        }
    }

    func testWordsAreNotAValidReleaseDate() {
        if case .success = LibraryScanEdit.makeItem(key: MP42MetadataKeyReleaseDate, text: "last spring") {
            XCTFail("Text that is not a date should be refused")
        }
    }

    func testNumberTagNeedsANumber() throws {
        if case .success = LibraryScanEdit.makeItem(key: MP42MetadataKeyTVSeason, text: "abc") {
            XCTFail("A word should be refused for a number tag")
        }
        let item = try LibraryScanEdit.makeItem(key: MP42MetadataKeyTVSeason, text: "3").get()
        XCTAssertEqual(item.numberValue, 3)
    }

    func testRatingCannotBeTyped() {
        if case .success = LibraryScanEdit.makeItem(key: MP42MetadataKeyRating, text: "PG") {
            XCTFail("Rating is edited in the Editor")
        }
    }

    // MARK: Editing where the file sits

    private func makeItem(inPlace: Bool) -> QueueItem {
        let url = URL(fileURLWithPath: "/tmp/library-scan-test/Sample.mp4")
        let item = QueueItem(fileURL: url, destination: url)
        item.editsInPlace = inPlace
        return item
    }

    func testAnItemIsNotInPlaceUnlessMarked() {
        XCTAssertFalse(makeItem(inPlace: false).editsInPlace)
        XCTAssertTrue(makeItem(inPlace: true).editsInPlace)
    }

    func testSetNameLeavesAnInPlaceItemWhereItIs() {
        let item = makeItem(inPlace: true)
        let before = item.destURL
        XCTAssertTrue(QueueSetOutputFilenameAction().runAction(item))
        XCTAssertEqual(item.destURL, before)
    }

    func testInPlaceFlagSurvivesSavingTheQueue() throws {
        let item = makeItem(inPlace: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: item, requiringSecureCoding: true)
        let restored = try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(ofClass: QueueItem.self, from: data))
        XCTAssertTrue(restored.editsInPlace)
    }

    func testPlainItemStaysPlainAfterSavingTheQueue() throws {
        let item = makeItem(inPlace: false)
        let data = try NSKeyedArchiver.archivedData(withRootObject: item, requiringSecureCoding: true)
        let restored = try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(ofClass: QueueItem.self, from: data))
        XCTAssertFalse(restored.editsInPlace)
    }
}
