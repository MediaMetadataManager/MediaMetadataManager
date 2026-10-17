//
//  MetadataMergeTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
@testable import M3

/// The rules for combining the results several providers return for one title.
final class MetadataMergeTests: XCTestCase {

    private func result(_ values: [MetadataResult.Key: Any], kind: MediaKind = .movie) -> MetadataResult {
        let result = MetadataResult()
        result.mediaKind = kind
        for (key, value) in values { result[key] = value }
        return result
    }

    private func artwork(_ name: String, service: String) -> Artwork {
        let url = URL(string: "https://example.invalid/\(name).jpg")!
        return Artwork(url: url, thumbURL: url, service: service, type: .poster, size: .standard)
    }

    func testSingleResultIsReturnedAsIs() {
        let only = result([.name: "Sample Title"])
        XCTAssertTrue(MetadataResult.combine([only]) === only)
        XCTAssertNil(MetadataResult.combine([]))
    }

    func testPrimaryValueWinsAndBlanksAreFilled() {
        let primary = result([.name: "Sample Title", .releaseDate: "2020-01-01", .studio: ""])
        let other = result([.name: "SAMPLE TITLE!", .releaseDate: "2020-06-06", .studio: "Example Studio", .rating: "R"])
        let merged = MetadataResult.combine([primary, other])
        XCTAssertEqual(merged?[.name] as? String, "Sample Title")
        XCTAssertEqual(merged?[.releaseDate] as? String, "2020-01-01")
        XCTAssertEqual(merged?[.studio] as? String, "Example Studio")
        XCTAssertEqual(merged?[.rating] as? String, "R")
    }

    func testListsAreCombinedWithoutDuplicates() {
        let primary = result([.name: "Sample Title", .cast: "Alex Example, Sam Sample", .genre: "Drama"])
        let other = result([.name: "Sample Title", .cast: "sam sample, Pat Placeholder", .genre: "Comedy, Drama"])
        let merged = MetadataResult.combine([primary, other])
        XCTAssertEqual(merged?[.cast] as? String, "Alex Example, Sam Sample, Pat Placeholder")
        XCTAssertEqual(merged?[.genre] as? String, "Drama, Comedy")
    }

    func testLongestDescriptionWins() {
        let primary = result([.name: "Sample Title", .description: "Short.", .longDescription: "A much longer description of the title."])
        let other = result([.name: "Sample Title", .description: "A slightly longer short one.", .longDescription: "Brief."])
        let merged = MetadataResult.combine([primary, other])
        XCTAssertEqual(merged?[.description] as? String, "A slightly longer short one.")
        XCTAssertEqual(merged?[.longDescription] as? String, "A much longer description of the title.")
    }

    func testProviderIdentifiersAreNotCopied() {
        let primary = result([.name: "Sample Title"])
        let other = result([.name: "Sample Title", .serviceContentID: "999", .contentID: "123"])
        let merged = MetadataResult.combine([primary, other])
        XCTAssertNil(merged?[.serviceContentID])
        XCTAssertNil(merged?[.contentID])
    }

    func testArtworkIsPooledWithoutDuplicates() {
        let primary = result([.name: "Sample Title"])
        primary.remoteArtworks = [artwork("a", service: "One")]
        let other = result([.name: "Sample Title"])
        other.remoteArtworks = [artwork("a", service: "Two"), artwork("b", service: "Two")]
        let merged = MetadataResult.combine([primary, other])
        XCTAssertEqual(merged?.remoteArtworks.count, 2)
    }

    // MARK: Same title?

    func testSameTitleIgnoringCaseAndPunctuation() {
        let a = result([.name: "Sample Title: Part 2", .releaseDate: "2020-01-01"])
        let b = result([.name: "sample title part 2", .releaseDate: "2020-12-31"])
        XCTAssertTrue(a.describesSameTitle(as: b, searchTitle: nil))
    }

    func testDifferentTitleIsRejected() {
        let a = result([.name: "Sample Title", .releaseDate: "2020-01-01"])
        let b = result([.name: "Another Film", .releaseDate: "2020-01-01"])
        XCTAssertFalse(a.describesSameTitle(as: b, searchTitle: nil))
    }

    func testYearsMoreThanOneApartAreRejected() {
        let a = result([.name: "Sample Title", .releaseDate: "2020-01-01"])
        XCTAssertTrue(a.describesSameTitle(as: result([.name: "Sample Title", .releaseDate: "2021-01-01"]), searchTitle: nil))
        XCTAssertFalse(a.describesSameTitle(as: result([.name: "Sample Title", .releaseDate: "2015-01-01"]), searchTitle: nil))
    }

    func testMissingYearDoesNotReject() {
        let a = result([.name: "Sample Title", .releaseDate: "2020-01-01"])
        XCTAssertTrue(a.describesSameTitle(as: result([.name: "Sample Title"]), searchTitle: nil))
    }

    func testEpisodeMustMatch() {
        let a = result([.seriesName: "Sample Show", .season: 1, .episodeNumber: 2], kind: .tvShow)
        XCTAssertTrue(a.describesSameTitle(as: result([.seriesName: "Sample Show", .season: "1", .episodeNumber: "2"], kind: .tvShow), searchTitle: nil))
        XCTAssertFalse(a.describesSameTitle(as: result([.seriesName: "Sample Show", .season: 1, .episodeNumber: 3], kind: .tvShow), searchTitle: nil))
        XCTAssertFalse(a.describesSameTitle(as: result([.seriesName: "Other Show", .season: 1, .episodeNumber: 2], kind: .tvShow), searchTitle: nil))
    }
}

/// The search sheet's table asks a result for its fields by row number, so the
/// ordered list of fields must always match what the result holds right now.
final class MetadataResultOrderedKeysTests: XCTestCase {

    func testOrderedKeysFollowLaterChanges() {
        let result = MetadataResult()
        result[.name] = "Sample Title"
        XCTAssertEqual(result.orderedKeys.count, result.count)

        result[.studio] = "Example Studio"
        XCTAssertEqual(result.orderedKeys.count, result.count)
        XCTAssertTrue(result.orderedKeys.contains(.studio))

        let other = MetadataResult()
        other[.releaseDate] = "2020-01-01"
        result.merge(result: other)
        XCTAssertEqual(result.orderedKeys.count, result.count)

        result[.studio] = nil
        XCTAssertEqual(result.orderedKeys.count, result.count)
        XCTAssertFalse(result.orderedKeys.contains(.studio))
    }

    func testTVShowFieldsAreListedOnceInAFixedOrder() {
        let result = MetadataResult()
        result.mediaKind = .tvShow
        result[.serviceContentID] = 1
        result[.serviceAdditionalContentID] = 2
        result[.serviceEpisodeID] = 3
        result[.seriesName] = "Sample Show"
        result[.name] = "Sample Episode"
        result[.season] = 1
        result[.episodeNumber] = 2
        result[.episodeID] = "102"
        result[.network] = "Example Network"
        result[.seriesDescription] = "About the show"
        result[.longDescription] = "About the episode"
        result[.cast] = "Example Person"

        let keys = result.orderedKeys
        XCTAssertEqual(keys.count, result.count)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(keys, result.orderedKeys)
        XCTAssertEqual(keys.first, .name)
        // The provider's own ID fields come last, in the listed order.
        XCTAssertEqual(Array(keys.suffix(3)), [.serviceContentID, .serviceAdditionalContentID, .serviceEpisodeID])
    }
}
