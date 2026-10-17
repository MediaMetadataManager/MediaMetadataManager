//
//  GenreListTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// The Genre drop-down lists the usual genres, takes any text typed in, and
/// keeps the genres you type.
final class GenreListTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "GenreListTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testListIsFilledWithMovieAndTVGenres() {
        let all = GenreList.all(defaults: defaults)
        for genre in ["Action", "Horror", "Documentary", "Comedy", "Drama", "Reality TV", "Sci-Fi & Fantasy"] {
            XCTAssertTrue(all.contains(genre), genre)
        }
    }

    func testListIsInNameOrderWithNoRepeats() {
        let all = GenreList.all(defaults: defaults)
        XCTAssertEqual(all, all.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(Set(all.map { $0.lowercased() }).count, all.count)
    }

    func testATypedGenreIsKeptAndOffered() {
        GenreList.remember("Heist", defaults: defaults)
        XCTAssertEqual(GenreList.custom(defaults: defaults), ["Heist"])
        XCTAssertTrue(GenreList.all(defaults: defaults).contains("Heist"))
    }

    func testSeveralTypedGenresAreKeptSeparately() {
        GenreList.remember("Heist,  Noir ", defaults: defaults)
        XCTAssertEqual(GenreList.custom(defaults: defaults), ["Heist", "Noir"])
    }

    func testAGenreAlreadyOnTheListIsNotStoredAgain() {
        GenreList.remember("comedy", defaults: defaults)
        GenreList.remember("Heist", defaults: defaults)
        GenreList.remember("HEIST", defaults: defaults)
        XCTAssertEqual(GenreList.custom(defaults: defaults), ["Heist"])
    }

    func testEmptyTextIsNotKept() {
        GenreList.remember("  ", defaults: defaults)
        GenreList.remember(",", defaults: defaults)
        XCTAssertTrue(GenreList.custom(defaults: defaults).isEmpty)
    }

    func testTheGenreOnTheFileIsAlwaysInTheList() {
        XCTAssertTrue(GenreList.all(including: "Space Opera", defaults: defaults).contains("Space Opera"))
        XCTAssertFalse(GenreList.custom(defaults: defaults).contains("Space Opera"))
    }
}

/// The Genres editor in the Metadata preferences saves a corrected list.
final class GenreListEditingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "GenreListEditingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testACorrectedSpellingReplacesTheOldOne() {
        GenreList.remember("Hiest", defaults: defaults)
        GenreList.setCustom(["Heist"], defaults: defaults)
        XCTAssertEqual(GenreList.custom(defaults: defaults), ["Heist"])
        XCTAssertFalse(GenreList.all(defaults: defaults).contains("Hiest"))
    }

    func testRemovingAllGenresClearsTheStoredList() {
        GenreList.remember("Heist", defaults: defaults)
        GenreList.setCustom([], defaults: defaults)
        XCTAssertTrue(GenreList.custom(defaults: defaults).isEmpty)
        XCTAssertNil(defaults.object(forKey: GenreList.customKey))
    }

    func testBlanksRepeatsAndStandardGenresAreDropped() {
        GenreList.setCustom([" Heist ", "", "heist", "Comedy", "Noir"], defaults: defaults)
        XCTAssertEqual(GenreList.custom(defaults: defaults), ["Heist", "Noir"])
    }
}
