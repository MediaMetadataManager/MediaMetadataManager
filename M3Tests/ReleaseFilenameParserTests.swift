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
}
