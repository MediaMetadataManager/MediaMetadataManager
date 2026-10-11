import XCTest
@testable import M3

/// Names built from a template when some of the tags are not known.
final class FilenameCleanupTests: XCTestCase {

    func testEmptyBracketsAndParenthesesAreDropped() {
        XCTAssertEqual("Sample Title [] (2019)".removingEmptyBrackets(), "Sample Title (2019)")
        XCTAssertEqual("Sample Title [Studio] ()".removingEmptyBrackets(), "Sample Title [Studio]")
        XCTAssertEqual("Sample Title [] ()".removingEmptyBrackets(), "Sample Title")
        XCTAssertEqual("Sample Title [ ] (  )".removingEmptyBrackets(), "Sample Title")
    }

    func testFilledBracketsAreLeftAlone() {
        XCTAssertEqual("Sample Title [Studio] (2020)".removingEmptyBrackets(), "Sample Title [Studio] (2020)")
        XCTAssertEqual("Sample (Part 1)".removingEmptyBrackets(), "Sample (Part 1)")
    }

    func testNameWithNothingButEmptyBracketsBecomesEmpty() {
        XCTAssertEqual("[] ()".removingEmptyBrackets(), "")
    }
}
