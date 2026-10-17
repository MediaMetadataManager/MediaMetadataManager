//
//  TitleCleaningTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
@testable import M3

/// Cutting promotion text off a title that a source printed with it.
final class TitleCleaningTests: XCTestCase {

    func testCutsAtLineBreaksAndLongBlankRuns() {
        let raw = "Sample Title: With Subtitle\n\t\t\t\t\t\t\n\t\t\t\t\t\t\t\t \n\t\t\t\t\t\t\t\t\t- On Sale! \n\t\t\t\t\t\t\t\t\t \n\t\t\t\t\t\t\t\t\t\tSeasonal Sale"
        XCTAssertEqual(raw.withoutPromotionText, "Sample Title: With Subtitle")
        XCTAssertEqual("Sample Title     - On Sale!".withoutPromotionText, "Sample Title")
    }

    func testLeavesOrdinaryTitlesAlone() {
        XCTAssertEqual("Sample Title".withoutPromotionText, "Sample Title")
        XCTAssertEqual("  Sample Title  ".withoutPromotionText, "Sample Title")
        XCTAssertEqual("Sample - Title  Two".withoutPromotionText, "Sample - Title  Two")
        XCTAssertEqual("Sample   Title".withoutPromotionText, "Sample   Title")
    }

    func testDropsTrailingDashLeftBehind() {
        XCTAssertEqual("Sample Title -\n  On Sale".withoutPromotionText, "Sample Title")
    }
}
