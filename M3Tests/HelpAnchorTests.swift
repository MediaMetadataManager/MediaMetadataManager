//
//  HelpAnchorTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//

import XCTest
@testable import M3

/// The help pages inside the app, the places the app opens in them, and the help search.
/// The pages are built by Tools/docs/build-helpbook.py from the guides; if a heading is
/// renamed there, a "?" button would open the front page instead of its section. These
/// tests catch that before a release.
final class HelpAnchorTests: XCTestCase {

    // MARK: The pages shipped in the app

    func testEveryHelpAnchorExistsInTheHelpPages() {
        let index = HelpIndex.shared
        XCTAssertFalse(index.pages.isEmpty, "help-index.json is missing from the app; run Tools/docs/build-helpbook.py and rebuild")
        for anchor in HelpAnchor.allCases {
            XCTAssertNotNil(index.page(forAnchor: anchor.rawValue),
                            "Help anchor \"\(anchor.rawValue)\" is not in the help pages; a guide heading was renamed or the pages need rebuilding")
        }
    }

    func testEveryIndexedPageFileExistsInTheApp() throws {
        let folder = try XCTUnwrap(HelpIndex.resourcesFolder, "the help folder is missing from the app bundle")
        for page in HelpIndex.shared.pages {
            let path = folder.appendingPathComponent("en.lproj/\(page.file)").path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(page.file) is listed in help-index.json but not in the app")
        }
    }

    func testAnchorNamesAreUnique() {
        let names = HelpAnchor.allCases.map(\.rawValue)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testTheGuidesShippedAsPDFAreInTheBundle() {
        XCTAssertNotNil(Bundle(for: AppDelegate.self).url(forResource: "User-Guide", withExtension: "pdf"))
        XCTAssertNotNil(Bundle(for: AppDelegate.self).url(forResource: "Getting-Started", withExtension: "pdf"))
    }

    func testTheShippedIndexFindsTheMergeTopics() {
        XCTAssertFalse(HelpIndex.shared.search("merge").isEmpty)
    }

    // MARK: Search logic

    private func samplePages() -> HelpIndex {
        HelpIndex(pages: [
            HelpPage(file: "a.html", title: "Lossless merge", crumbs: ["Help", "User Guide"], level: 1,
                     text: "M3 joins files without re-encoding. Merging keeps quality.", anchors: ["lossless-merge"]),
            HelpPage(file: "b.html", title: "The Queue windows", crumbs: ["Help", "User Guide"], level: 1,
                     text: "The Merge button joins the selected items. Start runs the Queue.", anchors: ["the-queue-windows"]),
            HelpPage(file: "c.html", title: "Message log", crumbs: ["Help", "User Guide"], level: 1,
                     text: "A running log of what M3 did.", anchors: ["message-log"])
        ])
    }

    func testTermsAreLowerCaseWordsOnly() {
        XCTAssertEqual(HelpIndex.terms(in: "  Merge,  the QUEUE! "), ["merge", "the", "queue"])
        XCTAssertEqual(HelpIndex.terms(in: "   "), [])
    }

    func testAPageWithTheWordInItsTitleComesFirst() {
        let hits = samplePages().search("merge")
        XCTAssertEqual(hits.map { $0.page.file }, ["a.html", "b.html"])
    }

    func testAWordMatchesInsideLongerWords() {
        XCTAssertEqual(samplePages().search("merg").count, 2)
    }

    func testEveryWordMustMatch() {
        XCTAssertEqual(samplePages().search("merge queue").map { $0.page.file }, ["b.html"])
        XCTAssertTrue(samplePages().search("merge banana").isEmpty)
    }

    func testAnAccentedSearchFindsPlainText() {
        XCTAssertEqual(samplePages().search("m\u{00E9}rge").count, 2)
    }

    func testAnEmptySearchFindsNothing() {
        XCTAssertTrue(samplePages().search("").isEmpty)
    }

    func testTheLimitIsRespected() {
        XCTAssertEqual(samplePages().search("m3", limit: 1).count, 1)
    }

    func testTheSnippetSurroundsTheFirstMatch() {
        let text = String(repeating: "word ", count: 40) + "merge " + String(repeating: "tail ", count: 40)
        let snippet = HelpIndex.snippet(in: text, terms: ["merge"])
        XCTAssertTrue(snippet.contains("merge"))
        XCTAssertTrue(snippet.hasPrefix("\u{2026}") && snippet.hasSuffix("\u{2026}"))
        XCTAssertLessThan(snippet.count, 200)
    }

    func testAnAnchorIsFoundOnItsPage() {
        let index = samplePages()
        XCTAssertEqual(index.page(forAnchor: "message-log")?.file, "c.html")
        XCTAssertNil(index.page(forAnchor: "nope"))
    }
}
