//
//  ArtworkOrientationTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
import AppKit
@testable import M3

/// Telling portrait from landscape cover art by its real pixel size.
final class ArtworkOrientationTests: XCTestCase {

    private func pngData(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func artwork(_ name: String, service: String = "Apple TV", type: ArtworkType = .poster, size: ArtworkSize = .standard) -> Artwork {
        let url = URL(string: "https://example.com/\(name).jpg")!
        return Artwork(url: url, thumbURL: url, service: service, type: type, size: size)
    }

    func testClassifyByPixels() {
        XCTAssertEqual(ArtworkOrientation.classify(width: 1000, height: 1500), .portrait)
        XCTAssertEqual(ArtworkOrientation.classify(width: 1920, height: 1080), .landscape)
        XCTAssertEqual(ArtworkOrientation.classify(width: 1000, height: 1000), .square)
        XCTAssertEqual(ArtworkOrientation.classify(width: 1000, height: 1050), .square)
        XCTAssertEqual(ArtworkOrientation.classify(width: 0, height: 100), .unknown)
    }

    func testClassifyRealImageData() {
        XCTAssertEqual(ArtworkOrientation.of(data: pngData(width: 20, height: 30)), .portrait)
        XCTAssertEqual(ArtworkOrientation.of(data: pngData(width: 30, height: 20)), .landscape)
        XCTAssertEqual(ArtworkOrientation.of(data: Data([1, 2, 3])), .unknown)
    }

    func testCandidatesStartWithTheChosenPoster() {
        let chosen = artwork("chosen", size: .widescreen)
        let list = [artwork("a"), chosen, artwork("b")]
        XCTAssertEqual(list.portraitCandidates(preferred: chosen, service: "Apple TV").first, chosen)
    }

    func testCandidatesPreferStandardPostersFromTheServiceThenTheRest() {
        let wide = artwork("wide", size: .widescreen)
        let other = artwork("other", service: "iTunes Store")
        let std = artwork("std")
        let ordered = [wide, other, std].portraitCandidates(preferred: nil, service: "Apple TV")
        XCTAssertEqual(ordered, [std, other, wide])
    }

    func testCandidatesHaveNoDuplicatesAndAreLimited() {
        let many = (0..<20).map { artwork("p\($0)") }
        let ordered = (many + many).portraitCandidates(preferred: many[3], service: "Apple TV", limit: 6)
        XCTAssertEqual(ordered.count, 6)
        XCTAssertEqual(Set(ordered).count, 6)
        XCTAssertEqual(ordered.first, many[3])
    }

    func testCandidatesIgnoreNonPosters() {
        let backdrop = artwork("back", type: .backdrop)
        XCTAssertTrue([backdrop].portraitCandidates(preferred: nil, service: "Apple TV").isEmpty)
    }
}
