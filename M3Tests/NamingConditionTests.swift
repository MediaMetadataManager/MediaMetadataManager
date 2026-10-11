import XCTest
import MP42Foundation
@testable import M3

/// Conditions used by Filename and Media Locations rules.
final class NamingConditionTests: XCTestCase {

    private func metadata(mediaKind: Int? = nil, contentRating: Int? = nil, genre: String? = nil) -> MP42Metadata {
        let metadata = MP42Metadata()
        if let mediaKind = mediaKind {
            metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyMediaKind, value: NSNumber(value: mediaKind), dataType: .integer, extendedLanguageTag: nil))
        }
        if let contentRating = contentRating {
            metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyContentRating, value: NSNumber(value: contentRating), dataType: .integer, extendedLanguageTag: nil))
        }
        if let genre = genre {
            metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyUserGenre, value: genre as NSString, dataType: .string, extendedLanguageTag: nil))
        }
        return metadata
    }

    func testMediaKindValueListUsesTheMetadataTabNames() {
        let values = NamingCondition.fixedValues(for: MP42MetadataKeyMediaKind) ?? []
        XCTAssertTrue(values.contains("Movie"))
        XCTAssertTrue(values.contains("TV Show"))
    }

    func testContentRatingValueListExists() {
        XCTAssertEqual(NamingCondition.fixedValues(for: MP42MetadataKeyContentRating)?.contains("Explicit"), true)
    }

    func testOtherFieldsHaveNoFixedList() {
        XCTAssertNil(NamingCondition.fixedValues(for: MP42MetadataKeyUserGenre))
    }

    func testMediaKindMatchesByName() {
        let isMovie = NamingCondition(field: MP42MetadataKeyMediaKind, op: .equals, value: "Movie")
        let isTV = NamingCondition(field: MP42MetadataKeyMediaKind, op: .equals, value: "tv show")
        XCTAssertTrue(isMovie.matches(metadata: metadata(mediaKind: 9)))
        XCTAssertFalse(isMovie.matches(metadata: metadata(mediaKind: 10)))
        XCTAssertTrue(isTV.matches(metadata: metadata(mediaKind: 10)))
    }

    func testContentRatingMatchesByName() {
        let explicit = NamingCondition(field: MP42MetadataKeyContentRating, op: .equals, value: "Explicit")
        XCTAssertTrue(explicit.matches(metadata: metadata(contentRating: 4)))
        XCTAssertFalse(explicit.matches(metadata: metadata(contentRating: 2)))
    }

    func testIsSetAndIsNotSet() {
        let set = NamingCondition(field: MP42MetadataKeyUserGenre, op: .isSet, value: "")
        let notSet = NamingCondition(field: MP42MetadataKeyUserGenre, op: .isNotSet, value: "")
        XCTAssertTrue(set.matches(metadata: metadata(genre: "Drama")))
        XCTAssertFalse(set.matches(metadata: metadata()))
        XCTAssertTrue(notSet.matches(metadata: metadata()))
    }
}
