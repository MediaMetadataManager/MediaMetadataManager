//
//  ReleaseRescanStageTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// A folder row waiting for a merge order stops asking for one when the files
/// are taken out in Finder and a single file is left.
final class ReleaseRescanStageTests: XCTestCase {

    func testOneFileLeftNeedsNoMerge() {
        XCTAssertEqual(ReleaseRescanStage.stage(after: .pendingMergeSelection, fileCount: 1, hasMergedFile: false), .pendingMetadata)
    }

    func testFailedMergeWithOneFileLeftNeedsNoMerge() {
        XCTAssertEqual(ReleaseRescanStage.stage(after: .mergeFailed, fileCount: 1, hasMergedFile: false), .pendingMetadata)
    }

    func testSeveralFilesStillNeedAMergeOrder() {
        XCTAssertEqual(ReleaseRescanStage.stage(after: .pendingMergeSelection, fileCount: 4, hasMergedFile: false), .pendingMergeSelection)
    }

    func testNoFilesLeftChangesNothing() {
        XCTAssertEqual(ReleaseRescanStage.stage(after: .pendingMergeSelection, fileCount: 0, hasMergedFile: false), .pendingMergeSelection)
    }

    func testAMergedFileIsNotTouched() {
        XCTAssertEqual(ReleaseRescanStage.stage(after: .pendingMergeSelection, fileCount: 1, hasMergedFile: true), .pendingMergeSelection)
    }

    func testOtherStagesKeepTheirStage() {
        for stage: QueueRelease.Stage in [.pendingNaming, .namingRejected, .pendingMetadata, .merging, .alreadyMerged, .done] {
            XCTAssertEqual(ReleaseRescanStage.stage(after: stage, fileCount: 1, hasMergedFile: false), stage)
        }
    }
}
