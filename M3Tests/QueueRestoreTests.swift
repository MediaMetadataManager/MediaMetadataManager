//
//  QueueRestoreTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
@testable import M3

/// What comes back after M3 is quit part-way through a run.
final class QueueRestoreTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("M3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeFile(_ name: String, contents: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testItemBeingEditedComesBackWaiting() throws {
        let file = try makeFile("movie.mp4", contents: "x")
        let queueURL = folder.appendingPathComponent("queue.sbqueue")

        let queue = Queue(url: queueURL)
        let item = QueueItem(fileURL: file, destination: file)
        item.status = .editing
        queue.append(QueueRow(item: item))
        try queue.saveToDisk()

        let restored = Queue(url: queueURL)
        XCTAssertEqual(restored.row(at: 0).effectiveItem?.status, .ready)
    }

    // MARK: Closing an editor opened from a row

    func testCancelledEditKeepsAWaitingRow() {
        XCTAssertEqual(QueueEditOutcome.afterClose(wasCompleted: false, saved: false, fileExists: true), .keepRow)
    }

    func testCancelledEditKeepsTheRowEvenIfTheFileIsMissing() {
        XCTAssertEqual(QueueEditOutcome.afterClose(wasCompleted: false, saved: false, fileExists: false), .keepRow)
    }

    func testSavedEditOfAWaitingFileRemovesItsRow() {
        XCTAssertEqual(QueueEditOutcome.afterClose(wasCompleted: false, saved: true, fileExists: true), .removeRow)
    }

    func testCompletedFileKeepsItsRowWhileTheFileExists() {
        XCTAssertEqual(QueueEditOutcome.afterClose(wasCompleted: true, saved: false, fileExists: true), .keepRow)
        XCTAssertEqual(QueueEditOutcome.afterClose(wasCompleted: true, saved: true, fileExists: true), .keepRow)
        XCTAssertEqual(QueueEditOutcome.afterClose(wasCompleted: true, saved: false, fileExists: false), .removeRow)
    }

    func testWorkingItemComesBackFailed() throws {
        let file = try makeFile("movie.mp4", contents: "x")
        let queueURL = folder.appendingPathComponent("queue.sbqueue")

        let queue = Queue(url: queueURL)
        let item = QueueItem(fileURL: file, destination: file)
        item.status = .working
        queue.append(QueueRow(item: item))
        try queue.saveToDisk()

        let restored = Queue(url: queueURL)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.row(at: 0).effectiveItem?.status, .failed)
    }

    func testMergingReleaseComesBackAsFailedMerge() throws {
        let file = try makeFile("part1.mp4", contents: "x")
        let queueURL = folder.appendingPathComponent("queue.sbqueue")

        let queue = Queue(url: queueURL)
        let release = QueueRelease(folderURL: folder, sourceFileURLs: [file])
        release.stage = .merging
        queue.append(QueueRow(release: release))
        try queue.saveToDisk()

        let restored = Queue(url: queueURL)
        XCTAssertEqual(restored.row(at: 0).release?.stage, .mergeFailed)
        XCTAssertNotNil(restored.row(at: 0).release?.mergeErrorMessage)
    }

    func testInterruptedEditPutsTheOriginalBack() throws {
        let file = try makeFile("movie.mp4", contents: "damaged half-written file")
        let copy = QueueItem.safetyCopyURL(for: file)
        try "original".write(to: copy, atomically: true, encoding: .utf8)
        let queueURL = folder.appendingPathComponent("queue.sbqueue")

        let queue = Queue(url: queueURL)
        let item = QueueItem(fileURL: file, destination: file)
        item.status = .working
        queue.append(QueueRow(item: item))
        try queue.saveToDisk()

        _ = Queue(url: queueURL)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testSafetyCopyRoundTrip() throws {
        let file = try makeFile("movie.mp4", contents: "original")
        let copy = try XCTUnwrap(QueueItem.makeSafetyCopy(of: file))
        XCTAssertEqual(copy.lastPathComponent, ".movie.mp4.m3-backup")

        try "changed".write(to: file, atomically: true, encoding: .utf8)
        QueueItem.restoreSafetyCopy(copy, over: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testDiscardRemovesTheCopy() throws {
        let file = try makeFile("movie.mp4", contents: "original")
        let copy = try XCTUnwrap(QueueItem.makeSafetyCopy(of: file))
        QueueItem.discardSafetyCopy(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
