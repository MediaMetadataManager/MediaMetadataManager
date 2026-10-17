//
//  QueueDuplicatesTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// The same file is not added to the Queue twice while it is still waiting.
final class QueueDuplicatesTests: XCTestCase {

    private func row(_ path: String, status: QueueItem.Status = .ready) -> QueueRow {
        let url = URL(fileURLWithPath: path)
        let item = QueueItem(fileURL: url, destination: url)
        item.status = status
        return QueueRow(item: item)
    }

    func testQueuedFilesAreRecognisedByPath() {
        let paths = QueueDuplicates.sourcePaths(of: [row("/tmp/Sample Show/Season 1/01 Sample Title.m4v")])
        XCTAssertTrue(paths.contains(QueueDuplicates.key(for: URL(fileURLWithPath: "/tmp/Sample Show/Season 1/01 Sample Title.m4v"))))
        XCTAssertTrue(paths.contains(QueueDuplicates.key(for: URL(fileURLWithPath: "/tmp/Sample Show/Season 1/../Season 1/01 Sample Title.m4v"))))
        XCTAssertFalse(paths.contains(QueueDuplicates.key(for: URL(fileURLWithPath: "/tmp/Sample Show/Season 1/02 Sample Title.m4v"))))
    }

    func testAFinishedFileCanBeAddedAgain() {
        let paths = QueueDuplicates.sourcePaths(of: [row("/tmp/a.m4v", status: .completed), row("/tmp/b.m4v", status: .failed)])
        XCTAssertFalse(paths.contains(QueueDuplicates.key(for: URL(fileURLWithPath: "/tmp/a.m4v"))))
        XCTAssertTrue(paths.contains(QueueDuplicates.key(for: URL(fileURLWithPath: "/tmp/b.m4v"))))
    }

    func testFolderHeadersAreIgnored() {
        let header = QueueRow(folderHeaderURL: URL(fileURLWithPath: "/tmp/Sample Show/Season 1", isDirectory: true))
        XCTAssertTrue(QueueDuplicates.sourcePaths(of: [header]).isEmpty)
    }
}
