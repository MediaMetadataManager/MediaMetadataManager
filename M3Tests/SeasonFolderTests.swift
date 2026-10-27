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

    // MARK: show, season and episode from the folders (L-12)

    private func info(_ path: String) -> (show: String, season: Int, episode: Int?)? {
        return SeasonFolderName.episodeInfo(for: URL(fileURLWithPath: "/tmp/\(path)"))
    }

    func testShowAndSeasonComeFromTheFolders() {
        let result = info("Sample Show/Season 2/05 - Sample Title.mkv")
        XCTAssertEqual(result?.show, "Sample Show")
        XCTAssertEqual(result?.season, 2)
        XCTAssertEqual(result?.episode, 5)
    }

    func testEpisodeNumberFormats() {
        XCTAssertEqual(SeasonFolderName.episodeNumber(inFileName: "05.Sample Title"), 5)
        XCTAssertEqual(SeasonFolderName.episodeNumber(inFileName: "Sample Title Episode 7"), 7)
        XCTAssertEqual(SeasonFolderName.episodeNumber(inFileName: "E12 Sample Title"), 12)
        XCTAssertNil(SeasonFolderName.episodeNumber(inFileName: "Sample Title"))
        XCTAssertNil(SeasonFolderName.episodeNumber(inFileName: "2001 A Sample Odyssey"))
    }

    func testSeasonFolderWithoutAnEpisodeNumberStillGivesShowAndSeason() {
        let result = info("Sample Show/Season 1/Sample Title.mkv")
        XCTAssertEqual(result?.show, "Sample Show")
        XCTAssertEqual(result?.season, 1)
        XCTAssertNil(result?.episode)
    }

    func testOrdinaryFoldersGiveNothing() {
        XCTAssertNil(info("Sample Movies/05 - Sample Title.mkv"))
        XCTAssertNil(info("Sample Show/Specials/01 Sample Title.mkv"))
    }
}

/// Review Show: one show and season confirmed for a whole folder of episodes (L-2).
final class ReviewShowTests: XCTestCase {

    private func folder(_ path: String) -> URL { return URL(fileURLWithPath: "/tmp/\(path)") }

    private func terms(_ show: String, _ season: Int?, _ file: String) -> (series: String, season: Int?, episode: Int?)? {
        guard case let .tvShow(series, season, episode) = TVEpisodeTerms.terms(showName: show, season: season, fileURL: folder(file)) else { return nil }
        return (series, season, episode)
    }

    func testSeasonFolderGivesShowFromTheFolderAbove() {
        let start = SeasonFolderName.showAndSeason(forFolder: folder("Sample.Show/Season 2"))
        XCTAssertEqual(start.show, "Sample Show")
        XCTAssertEqual(start.season, 2)
    }

    func testOrdinaryFolderIsTheShowWithNoSeason() {
        let start = SeasonFolderName.showAndSeason(forFolder: folder("Sample Show"))
        XCTAssertEqual(start.show, "Sample Show")
        XCTAssertNil(start.season)
    }

    func testConfirmedShowAndSeasonWinOverTheFileName() {
        let result = terms("Sample Show", 3, "Season 3/Other.Name.S01E04.mkv")
        XCTAssertEqual(result?.series, "Sample Show")
        XCTAssertEqual(result?.season, 3)
        XCTAssertEqual(result?.episode, 4)
    }

    func testEpisodeNumberComesFromALeadingNumber() {
        let result = terms("Sample Show", 2, "Season 2/05 - Sample Title.mkv")
        XCTAssertEqual(result?.episode, 5)
        XCTAssertEqual(result?.season, 2)
    }

    func testNoSeasonConfirmedFallsBackToTheFileThenTheFolder() {
        XCTAssertEqual(terms("Sample Show", nil, "Misc/Sample.S04E02.mkv")?.season, 4)
        XCTAssertEqual(terms("Sample Show", nil, "Season 5/02 - Sample Title.mkv")?.season, 5)
        XCTAssertNil(terms("Sample Show", nil, "Misc/Sample Title.mkv")?.season)
    }

    func testActionKeepsTheConfirmedShowWhenArchived() throws {
        let action = QueueMetadataAction(movieLanguage: "en", tvShowLanguage: "en", movieProvider: "TheMovieDB", tvShowProvider: "TheTVDB",
                                         preferredArtwork: 0, preferredArtworkSize: 0, tvShowName: "Sample Show", tvSeason: 2)
        let data = try NSKeyedArchiver.archivedData(withRootObject: action, requiringSecureCoding: true)
        let back = try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(ofClass: QueueMetadataAction.self, from: data))
        XCTAssertEqual(back.tvShowName, "Sample Show")
        XCTAssertEqual(back.tvSeason, 2)
    }

    func testActionWithoutASeasonStaysWithoutOne() throws {
        let action = QueueMetadataAction(movieLanguage: "en", tvShowLanguage: "en", movieProvider: "TheMovieDB", tvShowProvider: "TheTVDB",
                                         preferredArtwork: 0, preferredArtworkSize: 0, tvShowName: "Sample Show")
        let data = try NSKeyedArchiver.archivedData(withRootObject: action, requiringSecureCoding: true)
        let back = try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(ofClass: QueueMetadataAction.self, from: data))
        XCTAssertNil(back.tvSeason)
    }

    func testSettingTheShowKeepsTheOtherChoices() {
        let action = QueueMetadataAction(movieLanguage: "en", tvShowLanguage: "de", movieProvider: "TheMovieDB", tvShowProvider: "TheTVDB",
                                         preferredArtwork: 0, preferredArtworkSize: 0)
        let changed = action.settingShow("Sample Show", season: 4)
        XCTAssertEqual(changed.tvShowName, "Sample Show")
        XCTAssertEqual(changed.tvSeason, 4)
        XCTAssertNil(action.tvShowName)
    }
}

