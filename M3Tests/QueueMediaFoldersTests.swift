//
//  QueueMediaFoldersTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// A dropped show folder is searched for the folders that hold its files.
final class QueueMediaFoldersTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("QueueMediaFoldersTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    /// The temporary folder is reached through a link (/var is /private/var), and
    /// folder listings report one spelling or the other, so leave "/private" out.
    private func plain(_ path: String) -> String {
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    private func found(_ folder: String = "", maxDepth: Int = QueueMediaFolders.maxDepth) -> [String] {
        let start = folder.isEmpty ? root! : root.appendingPathComponent(folder)
        return QueueMediaFolders.folders(startingAt: start, maxDepth: maxDepth) { $0.pathExtension == "m4v" }
            .map { plain($0.path).replacingOccurrences(of: plain(root.path) + "/", with: "") }
    }

    func testShowFolderGivesOneGroupPerSeasonInNaturalOrder() throws {
        try make("Sample Show/Season 2/01 Sample Title.m4v")
        try make("Sample Show/Season 10/01 Sample Title.m4v")
        try make("Sample Show/Season 1/01 Sample Title.m4v")
        XCTAssertEqual(found("Sample Show"), ["Sample Show/Season 1", "Sample Show/Season 2", "Sample Show/Season 10"])
    }

    func testFolderWithFilesComesFirstThenItsSubfolders() throws {
        try make("Sample Show/Trailer.m4v")
        try make("Sample Show/Season 1/01 Sample Title.m4v")
        XCTAssertEqual(found("Sample Show"), ["Sample Show", "Sample Show/Season 1"])
    }

    func testFolderOfFilesIsItself() throws {
        try make("Sample Movie/Sample Movie.m4v")
        XCTAssertEqual(found("Sample Movie"), ["Sample Movie"])
    }

    func testFoldersWithoutMediaAreLeftOut() throws {
        try make("Sample Show/Season 1/notes.txt")
        try make("Sample Show/Season 2/01 Sample Title.m4v")
        XCTAssertEqual(found("Sample Show"), ["Sample Show/Season 2"])
    }

    func testSearchStopsAtTheDepthLimit() throws {
        try make("A/B/C/D/deep.m4v")
        XCTAssertEqual(found("A", maxDepth: 3), ["A/B/C/D"])
        XCTAssertEqual(found("A", maxDepth: 2), [])
    }

    func testHiddenFoldersAreSkipped() throws {
        try make("Sample Show/.hidden/01 Sample Title.m4v")
        XCTAssertEqual(found("Sample Show"), [])
    }

    func testSeasonFolderFilesAreRoutedToTheTVShowsTab() throws {
        try make("Sample Show/Season 1/01 Sample Title.m4v")
        let url = root.appendingPathComponent("Sample Show/Season 1/01 Sample Title.m4v")
        XCTAssertTrue(QueueController.isTVEpisodeFile(url))
    }

    func testMovieFileIsNotRoutedToTheTVShowsTab() throws {
        try make("Sample Movie/Sample Movie (2001).m4v")
        let url = root.appendingPathComponent("Sample Movie/Sample Movie (2001).m4v")
        XCTAssertFalse(QueueController.isTVEpisodeFile(url))
    }

    // MARK: whole-folder move (L-4)

    func testMovedURLFollowsAWholeFolderMove() {
        let old = URL(fileURLWithPath: "/tmp/m3-sample/Incoming/Sample Title")
        let new = URL(fileURLWithPath: "/tmp/m3-sample/Ready/Sample Title 2")
        let file = old.appendingPathComponent("Sample Title.mp4")
        XCTAssertEqual(QueueMoveToLibraryAction.movedURL(file, from: old, to: new).path, "/tmp/m3-sample/Ready/Sample Title 2/Sample Title.mp4")
        let inner = old.appendingPathComponent("Extras").appendingPathComponent("a.mp4")
        XCTAssertEqual(QueueMoveToLibraryAction.movedURL(inner, from: old, to: new).path, "/tmp/m3-sample/Ready/Sample Title 2/Extras/a.mp4")
    }

    func testMovedURLLeavesOtherFilesAlone() {
        let old = URL(fileURLWithPath: "/tmp/m3-sample/Incoming/Sample Title")
        let new = URL(fileURLWithPath: "/tmp/m3-sample/Ready/Sample Title")
        let elsewhere = URL(fileURLWithPath: "/tmp/m3-sample/Incoming/Sample Title 2/x.mp4")
        XCTAssertEqual(QueueMoveToLibraryAction.movedURL(elsewhere, from: old, to: new), elsewhere)
        XCTAssertEqual(QueueMoveToLibraryAction.movedURL(old, from: old, to: new), old)
    }

    // MARK: file missing (L-11)

    func testWaitingItemWhoseFileIsGoneIsMissing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("m3-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Sample Title.mp4")
        FileManager.default.createFile(atPath: file.path, contents: Data([0]))

        let item = QueueItem(fileURL: file, destination: file)
        XCTAssertFalse(item.isFileMissing)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(item.isFileMissing)
    }
}

/// Checking that the disks have room before a run (L-13).
final class DiskSpaceCheckTests: XCTestCase {

    private func item(_ name: String, in folder: String, bytes: Int64) -> DiskSpaceItem {
        return DiskSpaceItem(id: name, name: name, destination: URL(fileURLWithPath: "/\(folder)/\(name).mp4"), bytes: bytes)
    }

    private func volumeOf(_ url: URL) -> String? { return url.pathComponents.dropFirst().first.map { "/" + $0 } }

    func testEnoughRoomIsNotAShortfall() {
        let result = DiskSpaceCheck.shortfalls(for: [item("a", in: "A", bytes: 1_000)], volumeOf: volumeOf, available: { _ in 10_000_000_000 })
        XCTAssertTrue(result.isEmpty)
    }

    func testFilesOnTheSameDiskAddUp() {
        let items = [item("a", in: "A", bytes: 600), item("b", in: "A", bytes: 600)]
        let result = DiskSpaceCheck.shortfalls(for: items, volumeOf: volumeOf, available: { _ in 1_000 }, margin: 0)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.needed, 1_200)
        XCTAssertEqual(result.first?.available, 1_000)
        XCTAssertEqual(result.first?.items.count, 2)
    }

    func testEachDiskIsJudgedOnItsOwn() {
        let items = [item("a", in: "A", bytes: 600), item("b", in: "B", bytes: 600)]
        let result = DiskSpaceCheck.shortfalls(for: items, volumeOf: volumeOf, available: { $0 == "/A" ? 1_000 : 100 }, margin: 0)
        XCTAssertEqual(result.map { $0.volume }, ["/B"])
    }

    func testTheMarginCounts() {
        let items = [item("a", in: "A", bytes: 900)]
        XCTAssertTrue(DiskSpaceCheck.shortfalls(for: items, volumeOf: volumeOf, available: { _ in 1_000 }, margin: 0).isEmpty)
        XCTAssertEqual(DiskSpaceCheck.shortfalls(for: items, volumeOf: volumeOf, available: { _ in 1_000 }, margin: 200).count, 1)
    }

    func testUnknownFreeSpaceNeverBlocks() {
        let result = DiskSpaceCheck.shortfalls(for: [item("a", in: "A", bytes: 5_000)], volumeOf: volumeOf, available: { _ in nil })
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyFilesAreIgnored() {
        let result = DiskSpaceCheck.shortfalls(for: [item("a", in: "A", bytes: 0)], volumeOf: volumeOf, available: { _ in 0 }, margin: 0)
        XCTAssertTrue(result.isEmpty)
    }

    func testShortDisksComeInOrderOfFirstFile() {
        let items = [item("a", in: "B", bytes: 10), item("b", in: "A", bytes: 10)]
        let result = DiskSpaceCheck.shortfalls(for: items, volumeOf: volumeOf, available: { _ in 1 }, margin: 0)
        XCTAssertEqual(result.map { $0.volume }, ["/B", "/A"])
    }

    func testVolumeOfAFileThatDoesNotExistYet() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3Tests-\(UUID().uuidString)/Sub/new.mp4")
        XCTAssertNotNil(DiskSpaceCheck.volumePath(of: url))
        XCTAssertNotNil(DiskSpaceCheck.availableBytes(onVolumeAt: DiskSpaceCheck.volumePath(of: url) ?? "/"))
    }

    func testInPlaceEditNeedsACopyUnlessTheDiskClones() {
        XCTAssertEqual(DiskSpaceCheck.inPlaceBytes(size: 1_000, supportsCloning: false, copiesMade: 1, optimize: false), 1_000)
        XCTAssertEqual(DiskSpaceCheck.inPlaceBytes(size: 1_000, supportsCloning: true, copiesMade: 1, optimize: false), 0)
    }

    func testOptimizeAddsOneRewriteEvenOnACloningDisk() {
        XCTAssertEqual(DiskSpaceCheck.inPlaceBytes(size: 1_000, supportsCloning: true, copiesMade: 1, optimize: true), 1_000)
        XCTAssertEqual(DiskSpaceCheck.inPlaceBytes(size: 1_000, supportsCloning: false, copiesMade: 1, optimize: true), 2_000)
    }

    func testNoCopiesAndNoOptimizeNeedsNothing() {
        XCTAssertEqual(DiskSpaceCheck.inPlaceBytes(size: 1_000, supportsCloning: false, copiesMade: 0, optimize: false), 0)
    }

    func testADeliveryToAnotherDiskCannotBeRetargetedAndKeepsItsOwner() {
        let move = DiskSpaceItem(id: "x:move", name: "m", destination: URL(fileURLWithPath: "/B/m.mp4"), bytes: 500, canChangeTarget: false, ownerID: "x")
        XCTAssertFalse(move.canChangeTarget)
        XCTAssertEqual(move.queueKey, "x")
        XCTAssertEqual(item("a", in: "A", bytes: 1).queueKey, "a")
    }
}

