//
//  QueueExistingTagsTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
import MP42Foundation
@testable import M3

/// The Queue's "Existing tags" choice: what a metadata search does with tags a
/// file already has. Quit M3 before running these: the tests run inside a
/// second copy of the app and put the real settings back afterwards.
final class QueueExistingTagsTests: XCTestCase {

    private let keys = ["SBQueueExistingTags", "SBQueueKeepEmptyAnnotations", "SBQueueMetadata",
                        "SBMetadataOverwriteExistingAnnotations", "SBMetadataAppendExistingAnnotations",
                        "SBMetadataKeepEmptyAnnotations"]
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

    // MARK: Helpers

    private func action(_ mode: ExistingTagsMode, keepEmpty: Bool = false) -> QueueMetadataAction {
        return QueueMetadataAction(movieLanguage: "en", tvShowLanguage: "en",
                                   movieProvider: "TheMovieDB", tvShowProvider: "TheTVDB",
                                   preferredArtwork: 0, preferredArtworkSize: 0,
                                   existingTags: mode.rawValue, keepEmptyAnnotations: keepEmpty)
    }

    private func item(_ identifier: String, _ text: String) -> MP42MetadataItem {
        return MP42MetadataItem(identifier: identifier, value: text as NSString, dataType: .string, extendedLanguageTag: nil)
    }

    private func text(_ metadata: MP42Metadata, _ identifier: String) -> String? {
        return metadata.metadataItemsFiltered(byIdentifier: identifier).first?.stringValue
    }

    /// A file that already has a name, and a search result with another name and a genre.
    private func fileAndResult() -> (file: MP42Metadata, found: MP42Metadata) {
        let file = MP42Metadata()
        file.addItem(item(MP42MetadataKeyName, "Existing Title"))
        let found = MP42Metadata()
        found.addItem(item(MP42MetadataKeyName, "Found Title"))
        found.addItem(item(MP42MetadataKeyUserGenre, "Drama"))
        return (file, found)
    }

    // MARK: Mode rules

    private func flags(_ mode: ExistingTagsMode, overwrite: Bool, append: Bool) -> [Bool] {
        let result = mode.mergeFlags(preferencesOverwrite: overwrite, preferencesAppend: append)
        return [result.overwrite, result.append]
    }

    func testModeFlags() {
        XCTAssertEqual(flags(.usePreferences, overwrite: true, append: false), [true, false])
        XCTAssertEqual(flags(.usePreferences, overwrite: false, append: true), [false, true])
        XCTAssertEqual(flags(.fillMissing, overwrite: true, append: true), [false, false])
        XCTAssertEqual(flags(.append, overwrite: true, append: false), [false, true])
        XCTAssertEqual(flags(.overwrite, overwrite: false, append: true), [true, false])
    }

    func testKeepEmptyFollowsPreferencesOnlyInUsePreferences() {
        XCTAssertTrue(ExistingTagsMode.usePreferences.keepsEmpty(queueSetting: false, preferencesSetting: true))
        XCTAssertFalse(ExistingTagsMode.usePreferences.keepsEmpty(queueSetting: true, preferencesSetting: false))
        XCTAssertTrue(ExistingTagsMode.fillMissing.keepsEmpty(queueSetting: true, preferencesSetting: false))
        XCTAssertFalse(ExistingTagsMode.overwrite.keepsEmpty(queueSetting: false, preferencesSetting: true))
    }

    // MARK: Merging

    func testFillMissingOnlyAddsWhatTheFileLacks() {
        let (file, found) = fileAndResult()
        action(.fillMissing).merge(found, into: file)
        XCTAssertEqual(text(file, MP42MetadataKeyName), "Existing Title")
        XCTAssertEqual(text(file, MP42MetadataKeyUserGenre), "Drama")
    }

    func testOverwriteReplacesExistingTags() {
        let (file, found) = fileAndResult()
        action(.overwrite).merge(found, into: file)
        XCTAssertEqual(text(file, MP42MetadataKeyName), "Found Title")
        XCTAssertEqual(text(file, MP42MetadataKeyUserGenre), "Drama")
    }

    func testUsePreferencesFollowsTheOverwriteSetting() {
        MetadataPrefs.overwriteExistingAnnotations = false
        MetadataPrefs.appendExistingAnnotations = false
        var (file, found) = fileAndResult()
        action(.usePreferences).merge(found, into: file)
        XCTAssertEqual(text(file, MP42MetadataKeyName), "Existing Title")

        MetadataPrefs.overwriteExistingAnnotations = true
        (file, found) = fileAndResult()
        action(.usePreferences).merge(found, into: file)
        XCTAssertEqual(text(file, MP42MetadataKeyName), "Found Title")
    }

    func testChosenModeIgnoresThePreferences() {
        MetadataPrefs.overwriteExistingAnnotations = true
        let (file, found) = fileAndResult()
        action(.fillMissing).merge(found, into: file)
        XCTAssertEqual(text(file, MP42MetadataKeyName), "Existing Title")
    }

    // MARK: Saving

    func testQueueSettingsAreSavedAndLoaded() {
        let prefs = QueuePreferences()
        prefs.existingTags = ExistingTagsMode.overwrite.rawValue
        prefs.keepEmptyAnnotations = true
        prefs.saveUserDefaults()
        let loaded = QueuePreferences()
        XCTAssertEqual(loaded.existingTags, ExistingTagsMode.overwrite.rawValue)
        XCTAssertTrue(loaded.keepEmptyAnnotations)
    }

    func testKeepEmptyCheckboxNeedsSearchAndAChosenMode() {
        let prefs = QueuePreferences()
        prefs.searchMetadata = true
        prefs.existingTags = ExistingTagsMode.usePreferences.rawValue
        XCTAssertFalse(prefs.keepEmptyIsEditable)
        prefs.existingTags = ExistingTagsMode.fillMissing.rawValue
        XCTAssertTrue(prefs.keepEmptyIsEditable)
        prefs.searchMetadata = false
        XCTAssertFalse(prefs.keepEmptyIsEditable)
    }

    func testActionKeepsItsChoiceWhenTheQueueIsSavedAndRestored() throws {
        let original = action(.overwrite, keepEmpty: true)
        let data = try NSKeyedArchiver.archivedData(withRootObject: original, requiringSecureCoding: false)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        let restored = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? QueueMetadataAction
        XCTAssertEqual(restored?.existingTags, .overwrite)
        XCTAssertEqual(restored?.keepEmptyAnnotations, true)
    }

    func testQueueSavedBeforeTheSettingExistedUsesPreferences() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode("en", forKey: "_movieLanguage")
        archiver.encode("en", forKey: "_tvShowLanguage")
        archiver.encode("TheMovieDB", forKey: "_movieProvider")
        archiver.encode("TheTVDB", forKey: "_tvShowProvider")
        archiver.encode(Int32(0), forKey: "_preferredArtwork")
        archiver.encode(Int32(0), forKey: "_preferredArtworkSize")
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = false
        let restored = QueueMetadataAction(coder: unarchiver)
        XCTAssertEqual(restored?.existingTags, .usePreferences)
        XCTAssertEqual(restored?.keepEmptyAnnotations, false)
    }
}
