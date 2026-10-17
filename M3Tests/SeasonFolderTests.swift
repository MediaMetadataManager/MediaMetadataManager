//
//  SeasonFolderTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// Season folders ("Season 1") mark TV episodes whose file names carry no
/// episode marker, and are shown together with the show folder above them.
final class SeasonFolderTests: XCTestCase {

    func testSeasonFolderNamesAreRecognised() {
        XCTAssertEqual(SeasonFolderName.seasonNumber(in: "Season 1"), 1)
        XCTAssertEqual(SeasonFolderName.seasonNumber(in: "season 02"), 2)
        XCTAssertEqual(SeasonFolderName.seasonNumber(in: "Series 10"), 10)
        XCTAssertEqual(SeasonFolderName.seasonNumber(in: "Season.3"), 3)
        XCTAssertEqual(SeasonFolderName.seasonNumber(in: "S04"), 4)
        XCTAssertEqual(SeasonFolderName.seasonNumber(in: "Season 5 (2012)"), 5)
    }

    func testOtherFolderNamesAreNotSeasonFolders() {
        XCTAssertNil(SeasonFolderName.seasonNumber(in: "Sample Show"))
        XCTAssertNil(SeasonFolderName.seasonNumber(in: "Seasonal Movies"))
        XCTAssertNil(SeasonFolderName.seasonNumber(in: "Sample Movie (2020)"))
        XCTAssertNil(SeasonFolderName.seasonNumber(in: "Season"))
        XCTAssertNil(SeasonFolderName.seasonNumber(in: "Specials"))
        XCTAssertNil(SeasonFolderName.seasonNumber(in: "Sports"))
    }

    func testFilesInSeasonFolderCountAsEpisodes() {
        let episode = URL(fileURLWithPath: "/tmp/Sample Show/Season 1/01 Sample Title.m4v")
        XCTAssertTrue(QueueController.isTVEpisodeFile(episode))
        let movie = URL(fileURLWithPath: "/tmp/Sample Movies/01 Sample Title.m4v")
        XCTAssertFalse(QueueController.isTVEpisodeFile(movie))
    }

    func testSeasonFolderIsShownWithTheShowName() {
        let season = URL(fileURLWithPath: "/tmp/Sample Show/Season 1", isDirectory: true)
        XCTAssertEqual(SeasonFolderName.displayName(forFolder: season), "Sample Show \u{2013} Season 1")
        let plain = URL(fileURLWithPath: "/tmp/Sample Show", isDirectory: true)
        XCTAssertEqual(SeasonFolderName.displayName(forFolder: plain), "Sample Show")
    }
}
