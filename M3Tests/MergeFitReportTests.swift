//
//  MergeFitReportTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
@testable import M3

/// Finding the file that doesn't fit a merge selection.
final class MergeFitReportTests: XCTestCase {

    private func signature(codec: UInt32 = 0x61766331, width: UInt64 = 1920, height: UInt64 = 1080, audioCodec: UInt32 = 0x6D703461) -> MergeFileSignature {
        MergeFileSignature(tracks: [
            .init(mediaType: "video", format: codec, timescale: 24000, width: width, height: height),
            .init(mediaType: "audio", format: audioCodec, timescale: 48000)
        ])
    }

    func testMatchingFilesAreCompatible() {
        let report = MergeFitReport.make(signatures: [signature(), signature(), signature()])
        XCTAssertTrue(report.isCompatible)
        XCTAssertEqual(report.oddFileCount, 0)
    }

    func testOddFileInTheMiddleIsFlagged() {
        let report = MergeFitReport.make(signatures: [signature(), signature(width: 1280, height: 720), signature()])
        XCTAssertFalse(report.isCompatible)
        XCTAssertNil(report.problems[0])
        XCTAssertNotNil(report.problems[1])
        XCTAssertNil(report.problems[2])
        XCTAssertTrue(report.problems[1]?.contains("1280") ?? false)
    }

    func testOddFirstFileIsFlaggedNotTheOthers() {
        let report = MergeFitReport.make(signatures: [signature(codec: 0x68766331), signature(), signature()])
        XCTAssertNotNil(report.problems[0])
        XCTAssertNil(report.problems[1])
        XCTAssertNil(report.problems[2])
    }

    func testTwoFilesThatDifferFlagTheSecond() {
        let report = MergeFitReport.make(signatures: [signature(), signature(audioCodec: 0x61632D33)])
        XCTAssertNil(report.problems[0])
        XCTAssertNotNil(report.problems[1])
    }

    func testUnreadableFileIsFlagged() {
        let report = MergeFitReport.make(signatures: [signature(), nil, signature()])
        XCTAssertNil(report.problems[0])
        XCTAssertNotNil(report.problems[1])
        XCTAssertNil(report.problems[2])
        XCTAssertFalse(report.isCompatible)
    }

    func testTrackCountDifferenceIsDescribed() {
        let video = MergeFileSignature(tracks: [.init(mediaType: "video", format: 0x61766331, timescale: 24000, width: 1920, height: 1080)])
        let report = MergeFitReport.make(signatures: [signature(), signature(), video])
        XCTAssertNotNil(report.problems[2])
        XCTAssertFalse(report.isCompatible)
    }

    func testSingleFileIsNotMergeable() {
        let report = MergeFitReport.make(signatures: [signature()])
        XCTAssertNotNil(report.overallProblem)
        XCTAssertFalse(report.isCompatible)
    }

    func testSignatureOrderDoesNotMatter() {
        let a = [signature(), signature(width: 1280, height: 720), signature()]
        let b = [signature(width: 1280, height: 720), signature(), signature()]
        XCTAssertEqual(MergeFitReport.make(signatures: a).oddFileCount, 1)
        XCTAssertEqual(MergeFitReport.make(signatures: b).oddFileCount, 1)
    }
}
