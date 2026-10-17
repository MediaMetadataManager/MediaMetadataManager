//
//  LibraryServerSourceTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//

import XCTest
import MP42Foundation
@testable import M3

/// A library server as a Source in the Library scan: the plugin's kind, the
/// items it lists, and the comparison of what the server holds with the tags
/// a file already has.
final class LibraryServerSourceTests: XCTestCase {

    // MARK: Kind

    func testOnlyTheLibraryServerWordMakesALibraryServer() {
        XCTAssertTrue(PluginSourceKind.isLibraryServer("libraryServer"))
        XCTAssertTrue(PluginSourceKind.isLibraryServer(" LibraryServer "))
        XCTAssertFalse(PluginSourceKind.isLibraryServer("online"))
        XCTAssertFalse(PluginSourceKind.isLibraryServer(""))
        XCTAssertFalse(PluginSourceKind.isLibraryServer("server"))
    }

    // MARK: The bridge to a loaded plugin

    private class OnlinePlugin: NSObject {
        @objc var pluginName: String { return "Online Sample" }
        @objc(searchMovieWithQuery:) func searchMovie(query: String) -> [[String: Any]] { return [] }
        @objc(loadMovieMetadataWithId:) func loadMovieMetadata(id: String) -> [String: Any] { return [:] }
    }

    private final class ServerPlugin: OnlinePlugin {
        @objc override var pluginName: String { return "Server Sample" }
        @objc(sourceKind) func sourceKind() -> String { return "libraryServer" }
        @objc(listLibraryItems) func listLibraryItems() -> [[String: Any]] {
            return [["id": "1", "title": "Sample Title", "path": "/Media/Sample Title.m4v"]]
        }
    }

    func testAPluginWithoutAKindIsOnlineAndListsNothing() throws {
        let bridge = try XCTUnwrap(PluginBridge(wrapping: OnlinePlugin()))
        XCTAssertEqual(bridge.sourceKind(), PluginSourceKind.online)
        XCTAssertTrue(bridge.listLibraryItems().isEmpty)
        XCTAssertFalse(PluginMetadataService(plugin: bridge).isLibraryServer)
    }

    func testALibraryServerPluginIsRecognisedAndListsItsItems() throws {
        let bridge = try XCTUnwrap(PluginBridge(wrapping: ServerPlugin()))
        XCTAssertEqual(bridge.sourceKind(), "libraryServer")

        let service = PluginMetadataService(plugin: bridge)
        XCTAssertTrue(service.isLibraryServer)
        let items = service.libraryItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "1")
        XCTAssertEqual(items.first?.path, "/Media/Sample Title.m4v")
    }

    // MARK: Reading a listed item

    func testAnItemNeedsAnIdAndATitle() {
        XCTAssertNil(LibraryServerItem(dictionary: ["title": "Sample Title"]))
        XCTAssertNil(LibraryServerItem(dictionary: ["id": "1"]))
        XCTAssertNil(LibraryServerItem(dictionary: ["id": "", "title": "Sample Title"]))
        XCTAssertNil(LibraryServerItem(dictionary: ["id": "1", "title": "   "]))
        XCTAssertNotNil(LibraryServerItem(dictionary: ["id": "1", "title": "Sample Title"]))
    }

    func testAnItemCarriesTheTextTheServerHoldsByTagKey() throws {
        let item = try XCTUnwrap(LibraryServerItem(dictionary: [
            "id": "abc", "title": "Sample Title", "path": "/Media/Sample Title.m4v",
            "releaseDate": "2015-12-07T00:00:00Z", "synopsis": "A sample story.",
            "studio": "Example Studio", "director": "Sample Director",
            "cast": ["Actor One", "Actor Two"], "genre": ["Drama", "Comedy"],
            "ratingName": "PG-13", "hasCover": true
        ]))
        XCTAssertEqual(item.values[MP42MetadataKeyName], "Sample Title")
        XCTAssertEqual(item.values[MP42MetadataKeyReleaseDate], "2015-12-07")
        XCTAssertEqual(item.values[MP42MetadataKeyLongDescription], "A sample story.")
        XCTAssertEqual(item.values[MP42MetadataKeyStudio], "Example Studio")
        XCTAssertEqual(item.values[MP42MetadataKeyDirector], "Sample Director")
        XCTAssertEqual(item.values[MP42MetadataKeyCast], "Actor One, Actor Two")
        XCTAssertEqual(item.values[MP42MetadataKeyUserGenre], "Drama, Comedy")
        XCTAssertEqual(item.values[MP42MetadataKeyRating], "PG-13")
        XCTAssertEqual(item.values[MP42MetadataKeyCoverArt], LibraryServerItem.coverText)
    }

    func testBlankValuesAndNoCoverLeaveNoEntry() throws {
        let item = try XCTUnwrap(LibraryServerItem(dictionary: [
            "id": "abc", "title": "Sample Title", "studio": "  ", "cast": [String](), "genre": [" "],
            "hasCover": false
        ]))
        XCTAssertNil(item.values[MP42MetadataKeyStudio])
        XCTAssertNil(item.values[MP42MetadataKeyCast])
        XCTAssertNil(item.values[MP42MetadataKeyUserGenre])
        XCTAssertNil(item.values[MP42MetadataKeyCoverArt])
        XCTAssertNil(item.values[MP42MetadataKeyReleaseDate])
    }

    func testAnItemWithoutAPathHasNone() throws {
        XCTAssertNil(try XCTUnwrap(LibraryServerItem(dictionary: ["id": "1", "title": "Sample Title"])).path)
        XCTAssertNil(try XCTUnwrap(LibraryServerItem(dictionary: ["id": "1", "title": "Sample Title", "path": "  "])).path)
    }

    // MARK: Comparing with the file

    private func item() throws -> LibraryServerItem {
        return try XCTUnwrap(LibraryServerItem(dictionary: [
            "id": "abc", "title": "Sample Title", "releaseDate": "2015-12-07", "studio": "Example Studio"
        ]))
    }

    private let checked = [MP42MetadataKeyName, MP42MetadataKeyReleaseDate, MP42MetadataKeyStudio, MP42MetadataKeyDirector]

    func testAGapIsATagTheFileLacksAndTheServerHas() throws {
        let gaps = try item().gaps(fileValues: [MP42MetadataKeyName: "Sample Title"], keys: checked)
        XCTAssertEqual(gaps, [MP42MetadataKeyReleaseDate, MP42MetadataKeyStudio])
    }

    func testATagBothLackIsNotAGap() throws {
        // The server has no director, so the missing director is not something it can fill.
        let gaps = try item().gaps(fileValues: [:], keys: [MP42MetadataKeyDirector])
        XCTAssertTrue(gaps.isEmpty)
    }

    func testAFileThatHasEverythingTheServerHasIsNotListed() throws {
        let file = [MP42MetadataKeyName: "Sample Title", MP42MetadataKeyReleaseDate: "2015-12-07", MP42MetadataKeyStudio: "Other Studio"]
        XCTAssertTrue(try item().gaps(fileValues: file, keys: checked).isEmpty)
    }

    func testOnlyTheCheckedTagsAreCompared() throws {
        // Studio is not among the checked tags, so its gap is not reported.
        let gaps = try item().gaps(fileValues: [:], keys: [MP42MetadataKeyReleaseDate])
        XCTAssertEqual(gaps, [MP42MetadataKeyReleaseDate])
    }

    // MARK: Accepting the server's values

    func testOnlyTypeableTagsCanBeAccepted() {
        let server = [
            MP42MetadataKeyName: "Sample Title",
            MP42MetadataKeyReleaseDate: "2015-12-07",
            MP42MetadataKeyStudio: "Example Studio",
            MP42MetadataKeyLongDescription: "A sample story.",
            MP42MetadataKeyUserGenre: "Drama",
            MP42MetadataKeyCast: "Actor One",
            MP42MetadataKeyRating: "PG-13",
            MP42MetadataKeyCoverArt: LibraryServerItem.coverText
        ]
        let keys = LibraryScanAccept.acceptable(server).map { $0.key }
        XCTAssertEqual(Set(keys), [MP42MetadataKeyName, MP42MetadataKeyReleaseDate, MP42MetadataKeyStudio,
                                   MP42MetadataKeyLongDescription, MP42MetadataKeyUserGenre])
    }

    func testAcceptableTagsComeInKeyOrder() {
        let keys = LibraryScanAccept.acceptable([MP42MetadataKeyStudio: "Example Studio", MP42MetadataKeyName: "Sample Title"]).map { $0.key }
        XCTAssertEqual(keys, keys.sorted())
    }

    func testAnUnreadableServerDateIsNotAccepted() {
        XCTAssertFalse(LibraryScanAccept.hasAcceptable([MP42MetadataKeyReleaseDate: "2015"]))
        XCTAssertTrue(LibraryScanAccept.hasAcceptable([MP42MetadataKeyReleaseDate: "2015-12-07"]))
    }

    func testNothingToAcceptWhenTheServerHasOnlyEditorTags() {
        XCTAssertFalse(LibraryScanAccept.hasAcceptable([MP42MetadataKeyCast: "Actor One", MP42MetadataKeyCoverArt: "Artwork"]))
        XCTAssertFalse(LibraryScanAccept.hasAcceptable([:]))
    }

    // MARK: The Queue's metadata action keeps the server's item

    private func makeAction(source: String?, id: String?) -> QueueMetadataAction {
        return QueueMetadataAction(movieLanguage: "en", tvShowLanguage: "en", movieProvider: "Movie Source", tvShowProvider: "TV Source",
                                   preferredArtwork: ArtworkType.poster.rawValue, preferredArtworkSize: ArtworkSize.standard.rawValue,
                                   knownSource: source, knownItemID: id)
    }

    private func roundTrip(_ action: QueueMetadataAction) throws -> QueueMetadataAction {
        let data = try NSKeyedArchiver.archivedData(withRootObject: action, requiringSecureCoding: true)
        return try XCTUnwrap(try NSKeyedUnarchiver.unarchivedObject(ofClass: QueueMetadataAction.self, from: data))
    }

    func testTheKnownItemSurvivesSavingTheQueue() throws {
        let back = try roundTrip(makeAction(source: "Server Sample", id: "abc"))
        XCTAssertEqual(back.knownSource, "Server Sample")
        XCTAssertEqual(back.knownItemID, "abc")
    }

    func testAnOrdinaryActionHasNoKnownItem() throws {
        let action = makeAction(source: nil, id: nil)
        XCTAssertNil(action.knownSource)
        let back = try roundTrip(action)
        XCTAssertNil(back.knownSource)
        XCTAssertNil(back.knownItemID)
    }

    // MARK: Online / Library Servers split

    func testEveryPluginIsEitherOnlineOrALibraryServer() {
        let online = Set(MetadataSearch.onlinePluginMovieProviders)
        let servers = Set(MetadataSearch.libraryServerProviderNames)
        XCTAssertTrue(online.isDisjoint(with: servers))
        XCTAssertEqual(online.union(servers), Set(MetadataSearch.pluginMovieProviders))
    }

    func testAnUnknownBundleCountsAsOnline() {
        XCTAssertFalse(MetadataSearch.isLibraryServerBundle(named: "NoSuchPlugin"))
    }

    // MARK: Text

    func testTheGapTextNamesWhatTheServerHolds() {
        let text = LibraryScanWindowController.serverHasText("A sample\nstory.")
        XCTAssertTrue(text.hasPrefix(LibraryScanCell.missingText))
        XCTAssertTrue(text.hasSuffix("A sample story."))
    }
}
