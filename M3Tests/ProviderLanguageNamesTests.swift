//
//  ProviderLanguageNamesTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
import MP42Foundation
@testable import M3

/// The language lists in the Queue options show names ("English"), not the
/// codes a metadata source uses ("eng", "en"), and picking a name gives back
/// that source's own code. TheTVDB writes languages with three letters,
/// TheMovieDB with two, and some sources use plain text.
final class ProviderLanguageNamesTests: XCTestCase {

    func testThreeLetterCodesBecomeNames() {
        let codes = ["eng", "fra", "deu", "spa"]
        let names = LanguageType.ISO_639_2.menuNames(for: codes)

        XCTAssertEqual(names.count, codes.count)
        for (code, name) in zip(codes, names) {
            XCTAssertNotEqual(name, code, "\(code) should be shown as a name")
            XCTAssertFalse(name.isEmpty)
        }
        XCTAssertEqual(Set(names).count, names.count, "each language needs its own name")
    }

    func testTwoLetterCodesBecomeNames() {
        let codes = ["en", "fr", "de", "es"]
        let names = LanguageType.ISO.menuNames(for: codes)

        for (code, name) in zip(codes, names) {
            XCTAssertNotEqual(name, code, "\(code) should be shown as a name")
        }
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testPlainTextLanguagesAreLeftAlone() {
        let codes = ["USA", "UK", "Canada"]
        XCTAssertEqual(LanguageType.custom.menuNames(for: codes), codes)
    }

    func testACodeWithNoNameIsShownAsItIs() {
        // Four letters can never be a real ISO 639-2 code.
        XCTAssertEqual(LanguageType.ISO_639_2.menuName(for: "zzzz"), "zzzz")
        // But "und" itself keeps its normal name.
        XCTAssertEqual(LanguageType.ISO_639_2.menuName(for: "und"),
                       LanguageType.ISO_639_2.displayName(language: "und"))
    }

    func testPickingANameGivesBackTheSourcesOwnCode() {
        let codes = ["eng", "fra", "deu", "spa"]
        for code in codes {
            let name = LanguageType.ISO_639_2.menuName(for: code)
            XCTAssertEqual(LanguageType.ISO_639_2.code(forMenuName: name, among: codes), code)
        }

        let twoLetter = ["en", "fr", "de"]
        for code in twoLetter {
            let name = LanguageType.ISO.menuName(for: code)
            XCTAssertEqual(LanguageType.ISO.code(forMenuName: name, among: twoLetter), code)
        }
    }

    func testAnUnknownNameGivesNoCode() {
        XCTAssertNil(LanguageType.ISO_639_2.code(forMenuName: "Not A Language", among: ["eng", "fra"]))
    }

    func testTheDefaultTVLanguageStaysSelectable() {
        // TheTVDB writes languages with three letters and its default is "eng":
        // that name must be in the list and lead back to "eng", or the popup
        // would show nothing chosen.
        let type = LanguageType.ISO_639_2
        let codes = ["eng", "fra", "deu"]
        let names = type.menuNames(for: codes)

        XCTAssertTrue(names.contains(type.menuName(for: "eng")))
        XCTAssertEqual(type.code(forMenuName: names[0], among: codes), "eng")
    }
}
