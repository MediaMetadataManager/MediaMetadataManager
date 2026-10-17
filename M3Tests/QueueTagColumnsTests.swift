//
//  QueueTagColumnsTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
import MP42Foundation
@testable import M3

/// The Library scan's tag columns carried over to the Queue: which tags an
/// item tracks, and what the cells show.
final class QueueTagColumnsTests: XCTestCase {

    private let values = QueueTagValues()

    private func makeItem() -> QueueItem {
        let url = URL(fileURLWithPath: "/tmp/queue-tag-test/Sample.mp4")
        return QueueItem(fileURL: url, destination: url)
    }

    // MARK: Column identifiers

    func testColumnIdentifierRoundTrips() {
        let id = QueueTagValues.columnIdentifier(forKey: MP42MetadataKeyStudio)
        XCTAssertEqual(QueueTagValues.tagKey(ofColumn: id), MP42MetadataKeyStudio)
    }

    func testOrdinaryColumnsAreNotTagColumns() {
        XCTAssertNil(QueueTagValues.tagKey(ofColumn: "statusColumn"))
        XCTAssertNil(QueueTagValues.tagKey(ofColumn: "sizeColumn"))
        XCTAssertNil(QueueTagValues.tagKey(ofColumn: "AutomaticTableColumnIdentifier.0"))
    }

    func testNameTagIsTitledTitle() {
        XCTAssertEqual(LibraryScanCell.title(forKey: MP42MetadataKeyName), "Title")
    }

    // MARK: Cells

    func testSeededValueIsShown() {
        let item = makeItem()
        values.seed(item, values: [MP42MetadataKeyName: "Sample Movie"])
        let text = values.text(for: item, key: MP42MetadataKeyName, refreshed: {})
        XCTAssertEqual(text, .value("Sample Movie"))
    }

    func testSeededGapIsMissing() {
        let item = makeItem()
        values.seed(item, values: [MP42MetadataKeyName: "Sample Movie"])
        let text = values.text(for: item, key: MP42MetadataKeyReleaseDate, refreshed: {})
        XCTAssertEqual(text, .missing)
    }

    func testPrunedItemIsReadAgain() {
        let item = makeItem()
        values.seed(item, values: [MP42MetadataKeyName: "Sample Movie"])
        values.prune(keeping: [])
        // Nothing is known now, so the cell waits for a read of the file.
        let text = values.text(for: item, key: MP42MetadataKeyName, refreshed: {})
        XCTAssertEqual(text, .loading)
    }

    // MARK: Values read from a file's tags

    func testValuesListOnlyFilledTags() {
        let metadata = MP42Metadata()
        metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyName, value: "Sample Movie" as NSString, dataType: .unspecified, extendedLanguageTag: nil))
        metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyStudio, value: "  " as NSString, dataType: .unspecified, extendedLanguageTag: nil))
        let found = LibraryScanCell.values(in: metadata, keys: [MP42MetadataKeyName, MP42MetadataKeyStudio, MP42MetadataKeyReleaseDate])
        XCTAssertEqual(found, [MP42MetadataKeyName: "Sample Movie"])
    }

    // MARK: Saved with the Queue

    func testTrackedTagsSurviveSavingTheQueue() throws {
        let item = makeItem()
        item.trackedTagKeys = [MP42MetadataKeyName, MP42MetadataKeyReleaseDate]
        let data = try NSKeyedArchiver.archivedData(withRootObject: item, requiringSecureCoding: true)
        let restored = try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(ofClass: QueueItem.self, from: data))
        XCTAssertEqual(restored.trackedTagKeys, [MP42MetadataKeyName, MP42MetadataKeyReleaseDate])
    }

    func testPlainItemTracksNoTags() {
        XCTAssertTrue(makeItem().trackedTagKeys.isEmpty)
    }

    // MARK: Sorting by a tag

    private func entry(_ name: String, tag: String) -> QueueSortEntry {
        QueueSortEntry(name: name, statusText: "", statusRank: 3, size: 0, kind: "", isHeader: false, tagText: tag)
    }

    func testSortByTagPutsMissingFirst() {
        let entries = [entry("b", tag: "2020-01-01"), entry("a", tag: ""), entry("c", tag: "1999-05-05")]
        let order = QueueSorter.order(of: entries, by: .tag, ascending: true)
        XCTAssertEqual(order, [1, 2, 0])
    }

    func testSortByTagDescendingPutsMissingLast() {
        let entries = [entry("b", tag: "2020-01-01"), entry("a", tag: ""), entry("c", tag: "1999-05-05")]
        let order = QueueSorter.order(of: entries, by: .tag, ascending: false)
        XCTAssertEqual(order, [0, 2, 1])
    }

    func testSortByTagTiesFallBackToName() {
        let entries = [entry("b", tag: "x"), entry("a", tag: "x")]
        XCTAssertEqual(QueueSorter.order(of: entries, by: .tag, ascending: true), [1, 0])
    }

    func testSortByTagReadsNumbersAsNumbers() {
        let entries = [entry("a", tag: "10"), entry("b", tag: "9")]
        XCTAssertEqual(QueueSorter.order(of: entries, by: .tag, ascending: true), [1, 0])
    }

    func testKnownTextIsNilUntilReadAndEmptyWhenMissing() {
        let item = makeItem()
        XCTAssertNil(values.knownText(for: item, key: MP42MetadataKeyName))
        values.seed(item, values: [MP42MetadataKeyName: "Sample Movie"])
        XCTAssertEqual(values.knownText(for: item, key: MP42MetadataKeyName), "Sample Movie")
        XCTAssertEqual(values.knownText(for: item, key: MP42MetadataKeyReleaseDate), "")
    }

    func testLoadWithNothingMissingCompletesAtOnce() {
        let item = makeItem()
        values.seed(item, values: [:])
        var finished = false
        values.load([item]) { finished = true }
        XCTAssertTrue(finished)
    }

    func testTagColumnSortKeyIsTheColumnIdentifier() {
        let id = QueueTagValues.columnIdentifier(forKey: MP42MetadataKeyName)
        XCTAssertNotNil(QueueTagValues.tagKey(ofColumn: id))
        XCTAssertNil(QueueSortColumn(rawValue: id))
    }
}
