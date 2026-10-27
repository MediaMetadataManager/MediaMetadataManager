//
//  ReleaseFilenameParserTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
@testable import M3

final class ReleaseFilenameParserTests: XCTestCase {

    // MARK: Names built from parts

    func testMovieNameWithYear() {
        let name = ParsedMediaName(title: "Sample Title", year: "2020", fileExtension: "mp4")
        XCTAssertEqual(name.cleanedFileName, "Sample Title (2020).mp4")
        XCTAssertEqual(name.movieFolderName, "Sample Title (2020)")
    }

    func testMovieNameWithoutYear() {
        let name = ParsedMediaName(title: "Sample Title", fileExtension: "m4v")
        XCTAssertEqual(name.cleanedFileName, "Sample Title.m4v")
        XCTAssertEqual(name.movieFolderName, "Sample Title")
    }

    func testStudioSequenceAndYear() {
        let name = ParsedMediaName(title: "Sample Title", year: "2023", sequence: 2, studio: "Example Studio", fileExtension: "mp4")
        XCTAssertEqual(name.cleanedFileName, "Sample Title 2 [Example Studio] (2023).mp4")
        XCTAssertEqual(name.movieFolderName, "Sample Title [Example Studio] (2023)")
    }

    func testEpisodeName() {
        let name = ParsedMediaName(title: "Sample Show", season: 1, episode: 2, fileExtension: "mkv")
        XCTAssertEqual(name.cleanedFileName, "Sample Show S01E02.mkv")
    }

    // MARK: titleWithoutBrackets (the "[Studio] ()" search fix)

    func testBracketsWithEmptyYear() {
        XCTAssertEqual(ReleaseFilenameParser.titleWithoutBrackets("A Sample Title [Example Studio] ()"), "A Sample Title")
    }

    func testBracketsWithYear() {
        XCTAssertEqual(ReleaseFilenameParser.titleWithoutBrackets("Sample Title 2 [Example Studio] (2024)"), "Sample Title 2")
    }

    func testExtensionIsIgnored() {
        XCTAssertEqual(ReleaseFilenameParser.titleWithoutBrackets("Sample Title [Example Studio] ().mp4"), "Sample Title")
    }

    func testNoBracketsReturnsNil() {
        XCTAssertNil(ReleaseFilenameParser.titleWithoutBrackets("Sample Title"))
    }

    func testOtherParenthesesAreKept() {
        XCTAssertEqual(ReleaseFilenameParser.titleWithoutBrackets("Sample Title (Extended) [Example Studio]"), "Sample Title (Extended)")
    }

    // MARK: parse

    func testSceneStyleMovieName() {
        let parsed = ReleaseFilenameParser.parse("Sample.Title.2021.1080p.WEB-DL.x264-GRP.mkv")
        XCTAssertEqual(parsed?.title, "Sample Title")
        XCTAssertEqual(parsed?.year, "2021")
        XCTAssertEqual(parsed?.fileExtension, "mkv")
    }

    func testSceneStyleEpisodeName() {
        let parsed = ReleaseFilenameParser.parse("Sample.Show.S02E05.720p.HDTV.x264-GRP.mkv")
        XCTAssertEqual(parsed?.title, "Sample Show")
        XCTAssertEqual(parsed?.season, 2)
        XCTAssertEqual(parsed?.episode, 5)
    }

    func testPlainTitleWithYear() {
        let parsed = ReleaseFilenameParser.parse("Sample Title (2019).mp4")
        XCTAssertEqual(parsed?.title, "Sample Title")
        XCTAssertEqual(parsed?.year, "2019")
    }

    func testYearFromDateString() {
        XCTAssertEqual(ParsedMediaName.firstFourDigitYear(in: "2020-05-17"), "2020")
        XCTAssertNil(ParsedMediaName.firstFourDigitYear(in: nil))
        XCTAssertNil(ParsedMediaName.firstFourDigitYear(in: "n/a"))
    }

    // MARK: collision suffix (L-8)

    func testCollisionSuffixIsRemoved() {
        XCTAssertEqual(ReleaseFilenameParser.withoutCollisionSuffix("720p 2"), "720p")
        XCTAssertEqual(ReleaseFilenameParser.withoutCollisionSuffix("720p 12"), "720p")
        XCTAssertEqual(ReleaseFilenameParser.withoutCollisionSuffix("720p"), "720p")
        XCTAssertEqual(ReleaseFilenameParser.withoutCollisionSuffix("Sample Title 2024"), "Sample Title 2024")
    }

    func testStampedNameWithCollisionSuffixParsesLikeTheOriginal() {
        let plain = ReleaseFilenameParser.parse("03.10.2026_Uploader_Sample Title_Example Studio_720p")
        let numbered = ReleaseFilenameParser.parse("03.10.2026_Uploader_Sample Title_Example Studio_720p 2")
        XCTAssertEqual(plain?.title, "Sample Title")
        XCTAssertEqual(plain?.studio, "Example Studio")
        XCTAssertEqual(numbered?.title, plain?.title)
        XCTAssertEqual(numbered?.studio, plain?.studio)
    }

    // MARK: provider order for naming (L-6)

    func testNamingSearchesTheQueueProviderFirst() {
        let order = NamingReviewWindowController.providerSearchOrder(preferred: "B", enabled: ["A", "B", "C"])
        XCTAssertEqual(order, ["B", "A", "C"])
    }

    func testNamingOrderKeepsEnabledOrderWhenThePreferredOneIsOff() {
        let order = NamingReviewWindowController.providerSearchOrder(preferred: "Z", enabled: ["A", "B"])
        XCTAssertEqual(order, ["A", "B"])
    }
}
