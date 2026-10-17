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
}
