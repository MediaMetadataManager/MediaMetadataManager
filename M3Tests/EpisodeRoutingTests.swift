//
//  EpisodeRoutingTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/14/2026.
//

import XCTest
@testable import M3

/// Which files are taken for TV episodes when they are added by hand:
/// those whose names carry an episode marker.
final class EpisodeRoutingTests: XCTestCase {

    private func isEpisode(_ name: String) -> Bool {
        return QueueController.isTVEpisodeFile(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testEpisodeMarkersAreRecognised() {
        XCTAssertTrue(isEpisode("Sample Show S01E02.mkv"))
        XCTAssertTrue(isEpisode("Sample.Show.S10E114.1080p.WEB-DL.mkv"))
        XCTAssertTrue(isEpisode("Sample Show 1x02.mp4"))
    }

    func testMoviesAreNotTreatedAsEpisodes() {
        XCTAssertFalse(isEpisode("Sample Movie (2020).mkv"))
        XCTAssertFalse(isEpisode("Sample.Movie.2020.1080p.BluRay.mkv"))
        XCTAssertFalse(isEpisode("Sample Movie.mp4"))
    }
}

/// Files added by hand go to the tab they belong on, whichever tab they were
/// added to: episodes to TV Shows, everything else to Movies.
final class QueueTabRoutingTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: "/tmp/\(path)") }

    func testEpisodeAddedToMoviesTabMoves() {
        XCTAssertFalse(QueueTabRouting.belongs(url("Sample Show S01E02.mkv"), onTVShowsTab: false))
    }

    func testEpisodeAddedToTVShowsTabStays() {
        XCTAssertTrue(QueueTabRouting.belongs(url("Sample Show S01E02.mkv"), onTVShowsTab: true))
    }

    func testMovieAddedToTVShowsTabMoves() {
        XCTAssertFalse(QueueTabRouting.belongs(url("Sample Movie (2020).mkv"), onTVShowsTab: true))
    }

    func testMovieAddedToMoviesTabStays() {
        XCTAssertTrue(QueueTabRouting.belongs(url("Sample Movie (2020).mkv"), onTVShowsTab: false))
    }

    func testSeasonFolderFileCountsAsEpisode() {
        let file = url("Sample Show/Season 1/01 Sample Title.m4v")
        XCTAssertFalse(QueueTabRouting.belongs(file, onTVShowsTab: false))
        XCTAssertTrue(QueueTabRouting.belongs(file, onTVShowsTab: true))
    }

    func testMixedFolderIsSplitFileByFileFromTheMoviesTab() {
        let files = [url("Mixed/Sample Show S01E01.mkv"), url("Mixed/Sample Movie.mkv"), url("Mixed/Sample Show S01E02.mkv")]
        let result = QueueTabRouting.split(files, addedToTVShowsTab: false)
        XCTAssertEqual(result.stay.map { $0.lastPathComponent }, ["Sample Movie.mkv"])
        XCTAssertEqual(result.move.map { $0.lastPathComponent }, ["Sample Show S01E01.mkv", "Sample Show S01E02.mkv"])
    }

    func testMixedFolderIsSplitFileByFileFromTheTVShowsTab() {
        let files = [url("Mixed/Sample Show S01E01.mkv"), url("Mixed/Sample Movie.mkv")]
        let result = QueueTabRouting.split(files, addedToTVShowsTab: true)
        XCTAssertEqual(result.stay.map { $0.lastPathComponent }, ["Sample Show S01E01.mkv"])
        XCTAssertEqual(result.move.map { $0.lastPathComponent }, ["Sample Movie.mkv"])
    }

    func testStatusMessageNamesTheTabTheFilesWentTo() {
        XCTAssertEqual(QueueTabRouting.statusMessage(movedCount: 3, addedToTVShowsTab: false), "3 TV episode(s) were added to the TV Shows tab.")
        XCTAssertEqual(QueueTabRouting.statusMessage(movedCount: 2, addedToTVShowsTab: true), "2 movie(s) were added to the Movies tab.")
    }
}
