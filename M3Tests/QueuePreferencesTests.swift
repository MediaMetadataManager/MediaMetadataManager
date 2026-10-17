//
//  QueuePreferencesTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
@testable import M3

/// QueuePreferences is shared by the Movies queue, the TV Shows queue, the
/// Queue options popover and General preferences, each with its own copy.
/// These tests put the real settings back afterwards. Quit M3 before running
/// them: the tests run inside a second copy of the app.
final class QueuePreferencesTests: XCTestCase {

    private let keys = ["SBQueueMovieProvider", "SBQueueTVShowProvider", "SBQueueProviderArtwork2", "SBQueueProviderArtworkSize"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in keys { if let value = defaults.object(forKey: key) { saved[key] = value } }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testSavingOneCopyDoesNotOverwriteAnotherCopysChange() {
        let movies = QueuePreferences()
        let tvShows = QueuePreferences()

        movies.movieProvider = "TheTVDB"
        movies.saveUserDefaults()
        // The TV queue never touched the provider; saving it must not put its old value back.
        tvShows.saveUserDefaults()

        XCTAssertEqual(UserDefaults.standard.string(forKey: "SBQueueMovieProvider"), "TheTVDB")
    }

    func testSettingIsSavedWhenChanged() {
        let prefs = QueuePreferences()
        prefs.tvShowProvider = "iTunes Store"
        prefs.saveUserDefaults()
        XCTAssertEqual(UserDefaults.standard.string(forKey: "SBQueueTVShowProvider"), "iTunes Store")
        XCTAssertEqual(QueuePreferences().tvShowProvider, "iTunes Store")
    }

    func testArtworkChoiceIsSavedAtOnce() {
        let general = QueuePreferences()
        general.providerArtwork = 3
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "SBQueueProviderArtwork2"), 3)
        XCTAssertEqual(QueuePreferences().providerArtwork, 3)
    }

    func testArtworkChoiceReachesOtherCopies() {
        let queue = QueuePreferences()
        let general = QueuePreferences()
        general.providerArtwork = 1
        general.providerArtworkSize = 2

        let updated = expectation(description: "the Queue's copy follows General")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if queue.providerArtwork == 1 && queue.providerArtworkSize == 2 { updated.fulfill() }
        }
        wait(for: [updated], timeout: 3)
    }
}
