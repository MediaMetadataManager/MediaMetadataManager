//
//  SidecarSubtitlesTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// A subtitle file beside a video is not a second part to merge: it is
/// embedded in the finished file.
final class SidecarSubtitlesTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SidecarSubtitlesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    private func names(_ urls: [URL]) -> [String] { urls.map { $0.lastPathComponent } }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    // MARK: Splitting

    func testSubtitleExtensionsAreRecognised() {
        XCTAssertTrue(SidecarSubtitles.isSubtitle(url("Sample Movie.srt")))
        XCTAssertTrue(SidecarSubtitles.isSubtitle(url("Sample Movie.ASS")))
        XCTAssertTrue(SidecarSubtitles.isSubtitle(url("Sample Movie.ssa")))
        XCTAssertFalse(SidecarSubtitles.isSubtitle(url("Sample Movie.mp4")))
    }

    func testVideoAndSubtitleAreSeparated() {
        let split = SidecarSubtitles.partition([url("Sample Movie.mp4"), url("Sample Movie.srt")])
        XCTAssertEqual(names(split.media), ["Sample Movie.mp4"])
        XCTAssertEqual(names(split.subtitles), ["Sample Movie.srt"])
    }

    func testSeveralPartsKeepTheirOrderAndSubtitlesLeaveTheList() {
        let split = SidecarSubtitles.partition([url("Part 1.mp4"), url("Part 1.srt"), url("Part 2.mp4")])
        XCTAssertEqual(names(split.media), ["Part 1.mp4", "Part 2.mp4"])
        XCTAssertEqual(names(split.subtitles), ["Part 1.srt"])
    }

    func testSubtitlesAloneAreStillTreatedAsMedia() {
        let split = SidecarSubtitles.partition([url("Sample Movie.srt")])
        XCTAssertEqual(names(split.media), ["Sample Movie.srt"])
        XCTAssertTrue(split.subtitles.isEmpty)
    }

    func testSubtitlesForAVideoAreFoundByName() {
        let all = [url("Sample Movie.srt"), url("Sample Movie.en.srt"), url("Other Movie.srt"), url("Sample Movie.mp4")]
        XCTAssertEqual(names(SidecarSubtitles.subtitles(for: url("Sample Movie.mp4"), among: all)), ["Sample Movie.srt", "Sample Movie.en.srt"])
    }

    func testSubtitleFilesInAFolderAreListedInNameOrder() throws {
        try make("Release/Sample Movie.mp4")
        try make("Release/Sample Movie.10.srt")
        try make("Release/Sample Movie.2.srt")
        try make("Release/Extras/Sample Movie.srt")
        XCTAssertEqual(names(SidecarSubtitles.files(in: root.appendingPathComponent("Release"))), ["Sample Movie.2.srt", "Sample Movie.10.srt"])
    }

    // MARK: A release folder

    func testFolderWithOneVideoAndASubtitleIsOneFile() throws {
        try make("Sample Movie/Sample Movie.mp4")
        try make("Sample Movie/Sample Movie.srt")
        XCTAssertEqual(names(QueueController.mediaFiles(in: root.appendingPathComponent("Sample Movie"))), ["Sample Movie.mp4"])
    }

    func testFolderOfPartsStillListsEveryPart() throws {
        try make("Sample Movie/Sample Movie CD1.mp4")
        try make("Sample Movie/Sample Movie CD2.mp4")
        try make("Sample Movie/Sample Movie CD1.srt")
        XCTAssertEqual(names(QueueController.mediaFiles(in: root.appendingPathComponent("Sample Movie"))), ["Sample Movie CD1.mp4", "Sample Movie CD2.mp4"])
    }

    // MARK: The Incoming Folder scan

    func testDownloadFolderWithASubtitleIsOneFileCandidate() throws {
        try make("Sample Movie/Sample Movie.mp4")
        try make("Sample Movie/Sample Movie.srt")
        let found = IntakeScanner.candidates(in: [root], excluding: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(names(found[0].files), ["Sample Movie.mp4"])
    }

    func testLooseVideoTakesItsSubtitleAlong() throws {
        try make("Sample Movie.mp4")
        try make("Sample Movie.srt")
        let found = IntakeScanner.candidates(in: [root], excluding: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(names(found[0].files), ["Sample Movie.mp4"])
        XCTAssertEqual(names(found[0].companions), ["Sample Movie.srt"])
    }

    func testLooseSubtitleAloneIsStillACandidate() throws {
        try make("Sample Movie.srt")
        let found = IntakeScanner.candidates(in: [root], excluding: [])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(names(found[0].files), ["Sample Movie.srt"])
    }

    // MARK: The embed action

    func testSubtitleActionRemembersItsFilesWhenSaved() throws {
        let files = [url("Sample Movie.srt"), url("Sample Movie.en.srt")]
        let action = QueueSubtitlesAction(files: files)
        let data = try NSKeyedArchiver.archivedData(withRootObject: action, requiringSecureCoding: true)
        let restored = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [QueueSubtitlesAction.self], from: data) as? QueueSubtitlesAction
        XCTAssertNotNil(restored)
        let again = try NSKeyedArchiver.archivedData(withRootObject: restored!, requiringSecureCoding: true)
        XCTAssertEqual(again, data)
    }
}
