//
//  DeliveryTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
import MP42Foundation
@testable import M3

/// Which files are edited where they sit, and which folder a finished file
/// goes to. The real settings are put back afterwards. Quit M3 before running
/// them: the tests run inside a second copy of the app.
final class DeliveryTests: XCTestCase {

    private var folder: URL!
    private var savedStaging: URL?
    private var savedIngest: [URL] = []
    private var savedFollows = false
    private var savedAutomatic = false
    private var savedMovieRules: [DeliveryRule] = []
    private var savedTVRules: [DeliveryRule] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("M3Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        savedStaging = MediaIntakePrefs.readyForLibraryFolder
        savedIngest = MediaIntakePrefs.automaticMediaIngestFolders
        savedFollows = MediaIntakePrefs.ingestListFollowsAppleTV
        savedAutomatic = MediaIntakePrefs.deliverAutomatically
        savedMovieRules = MediaIntakePrefs.movieDeliveryRules
        savedTVRules = MediaIntakePrefs.tvDeliveryRules

        MediaIntakePrefs.readyForLibraryFolder = folder.appendingPathComponent("staging")
        MediaIntakePrefs.automaticMediaIngestFolders = [folder.appendingPathComponent("default")]
        MediaIntakePrefs.ingestListFollowsAppleTV = false
        MediaIntakePrefs.deliverAutomatically = true
        MediaIntakePrefs.movieDeliveryRules = []
        MediaIntakePrefs.tvDeliveryRules = []
    }

    override func tearDownWithError() throws {
        MediaIntakePrefs.readyForLibraryFolder = savedStaging
        MediaIntakePrefs.automaticMediaIngestFolders = savedIngest
        MediaIntakePrefs.ingestListFollowsAppleTV = savedFollows
        MediaIntakePrefs.deliverAutomatically = savedAutomatic
        MediaIntakePrefs.movieDeliveryRules = savedMovieRules
        MediaIntakePrefs.tvDeliveryRules = savedTVRules
        try? FileManager.default.removeItem(at: folder)
    }

    private func metadata(mediaKind: Int?, genre: String? = nil) -> MP42Metadata {
        let metadata = MP42Metadata()
        if let mediaKind = mediaKind {
            metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyMediaKind, value: NSNumber(value: mediaKind), dataType: .integer, extendedLanguageTag: nil))
        }
        if let genre = genre {
            metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyUserGenre, value: genre as NSString, dataType: .string, extendedLanguageTag: nil))
        }
        return metadata
    }

    // MARK: Edit in place

    func testFilesInStagingAreEditedInPlace() {
        let staging = folder.appendingPathComponent("staging")
        XCTAssertTrue(MediaIntakePrefs.shouldEditInPlace(staging.appendingPathComponent("Sample Title (2020)/Sample Title (2020).mp4")))
        XCTAssertTrue(MediaIntakePrefs.shouldEditInPlace(staging.appendingPathComponent("Loose.m4v")))
        XCTAssertTrue(MediaIntakePrefs.shouldEditInPlace(staging.appendingPathComponent("Sample/Clip.MOV")))
    }

    func testOtherTypesAndOtherFoldersAreNotEditedInPlace() {
        let staging = folder.appendingPathComponent("staging")
        XCTAssertFalse(MediaIntakePrefs.shouldEditInPlace(staging.appendingPathComponent("Sample/Clip.mkv")))
        XCTAssertFalse(MediaIntakePrefs.shouldEditInPlace(folder.appendingPathComponent("elsewhere/Clip.mp4")))
        // A folder whose name merely starts with the staging folder's name.
        XCTAssertFalse(MediaIntakePrefs.shouldEditInPlace(folder.appendingPathComponent("staging-old/Clip.mp4")))
    }

    func testAutomaticallyAddFolderIsNotALibraryRoot() {
        // The TV app takes files out of these, so they are never edited in place.
        XCTAssertFalse(MediaIntakePrefs.shouldEditInPlace(folder.appendingPathComponent("default/Clip.mp4")))
    }

    // MARK: Delivery routing

    func testWithAutomaticDeliveryOffEverythingGoesToStaging() {
        MediaIntakePrefs.deliverAutomatically = false
        let staging = MediaIntakePrefs.readyForLibraryFolder?.standardizedFileURL
        XCTAssertEqual(MediaIntakePrefs.deliveryFolder(for: metadata(mediaKind: 9))?.standardizedFileURL, staging)
        XCTAssertEqual(MediaIntakePrefs.deliveryFolder(for: metadata(mediaKind: 10))?.standardizedFileURL, staging)
    }

    func testFilesWithNoRuleGoToTheDefaultDestination() {
        let defaultFolder = folder.appendingPathComponent("default").standardizedFileURL
        XCTAssertEqual(MediaIntakePrefs.deliveryFolder(for: metadata(mediaKind: 9))?.standardizedFileURL, defaultFolder)
        XCTAssertEqual(MediaIntakePrefs.deliveryFolder(for: nil)?.standardizedFileURL, defaultFolder)
    }

    func testTVRulesOnlyApplyToTVAndMovieRulesOnlyToMovies() {
        let tvFolder = folder.appendingPathComponent("tv").path
        let movieFolder = folder.appendingPathComponent("movies").path
        let anyGenre = [NamingCondition(field: MP42MetadataKeyUserGenre, op: .isSet, value: "")]
        MediaIntakePrefs.tvDeliveryRules = [DeliveryRule(conditions: anyGenre, folderPath: tvFolder)]
        MediaIntakePrefs.movieDeliveryRules = [DeliveryRule(conditions: anyGenre, folderPath: movieFolder)]

        XCTAssertEqual(MediaIntakePrefs.deliveryFolder(for: metadata(mediaKind: 10, genre: "Drama"))?.path, URL(fileURLWithPath: tvFolder).standardizedFileURL.path)
        XCTAssertEqual(MediaIntakePrefs.deliveryFolder(for: metadata(mediaKind: 9, genre: "Drama"))?.path, URL(fileURLWithPath: movieFolder).standardizedFileURL.path)
        // No Media Kind counts as a movie.
        XCTAssertEqual(MediaIntakePrefs.deliveryFolder(for: metadata(mediaKind: nil, genre: "Drama"))?.path, URL(fileURLWithPath: movieFolder).standardizedFileURL.path)
    }

    func testDisabledRuleIsSkipped() {
        let movieFolder = folder.appendingPathComponent("movies").path
        let anyGenre = [NamingCondition(field: MP42MetadataKeyUserGenre, op: .isSet, value: "")]
        MediaIntakePrefs.movieDeliveryRules = [DeliveryRule(conditions: anyGenre, folderPath: movieFolder, isEnabled: false)]
        let defaultFolder = folder.appendingPathComponent("default").standardizedFileURL
        XCTAssertEqual(MediaIntakePrefs.deliveryFolder(for: metadata(mediaKind: 9, genre: "Drama"))?.standardizedFileURL, defaultFolder)
    }
}
