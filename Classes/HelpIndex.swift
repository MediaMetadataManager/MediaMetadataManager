//
//  HelpIndex.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/17/2026.
//
//  The searchable side of the app's help. Tools/docs/build-helpbook.py writes
//  help-index.json (one record per help page: title, outline level, plain text
//  and the anchors on the page) next to the pages inside the app. HelpIndex
//  reads it and answers searches from the Help window and from the Help menu's
//  search box. It has no UI so it can be tested on its own.
//

import Foundation

struct HelpPage: Decodable, Equatable {
    let file: String
    let title: String
    let crumbs: [String]
    let level: Int
    let text: String
    let anchors: [String]
}

/// One search result: a page, why it matched, and a snippet of text around the match.
final class HelpHit: NSObject {
    let page: HelpPage
    let snippet: String
    let score: Int

    init(page: HelpPage, snippet: String, score: Int) {
        self.page = page
        self.snippet = snippet
        self.score = score
    }
}

final class HelpIndex {

    private struct Payload: Decodable { let pages: [HelpPage] }

    let pages: [HelpPage]

    init(pages: [HelpPage]) {
        self.pages = pages
    }

    /// The folder inside the app that holds the help pages and their shared files.
    static var resourcesFolder: URL? {
        Bundle.main.url(forResource: "M3", withExtension: "help")?.appendingPathComponent("Contents/Resources")
    }

    /// The index shipped inside the app; empty if this build has no help folder.
    static let shared: HelpIndex = {
        guard let url = resourcesFolder?.appendingPathComponent("shrd/help-index.json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            NSLog("[Help] help-index.json not found in the app; Help will open the project page")
            return HelpIndex(pages: [])
        }
        return HelpIndex(pages: payload.pages)
    }()

    // MARK: Lookup

    func page(forAnchor anchor: String) -> HelpPage? {
        pages.first { $0.anchors.contains(anchor) }
    }

    func url(for page: HelpPage, anchor: String? = nil) -> URL? {
        guard let folder = HelpIndex.resourcesFolder?.appendingPathComponent("en.lproj/\(page.file)") else { return nil }
        guard let anchor = anchor, !anchor.isEmpty else { return folder }
        var parts = URLComponents(url: folder, resolvingAgainstBaseURL: false)
        parts?.fragment = anchor
        return parts?.url ?? folder
    }

    // MARK: Search

    /// The words of a search string: lower case, letters and digits only.
    static func terms(in query: String) -> [String] {
        query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Pages that contain every word of `query` (a word matches inside longer words, so "merg"
    /// finds "merging"), best first: a word in a page's title counts most, then in its
    /// chapter names, then how often it occurs in the text. Equal scores keep reading order.
    func search(_ query: String, limit: Int = 50) -> [HelpHit] {
        let terms = HelpIndex.terms(in: query)
        guard !terms.isEmpty else { return [] }
        var hits: [(order: Int, hit: HelpHit)] = []
        for (order, page) in pages.enumerated() {
            let title = page.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            let crumbs = page.crumbs.joined(separator: " ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            let text = page.text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            var score = 0
            var matchesAll = true
            for term in terms {
                let inTitle = title.contains(term)
                let inCrumbs = crumbs.contains(term)
                let count = text.components(separatedBy: term).count - 1
                if !inTitle && !inCrumbs && count == 0 {
                    matchesAll = false
                    break
                }
                score += (inTitle ? 20 : 0) + (inCrumbs ? 4 : 0) + min(count, 10)
            }
            if matchesAll {
                hits.append((order, HelpHit(page: page, snippet: HelpIndex.snippet(in: page.text, terms: terms), score: score)))
            }
        }
        hits.sort { $0.hit.score != $1.hit.score ? $0.hit.score > $1.hit.score : $0.order < $1.order }
        return hits.prefix(limit).map { $0.hit }
    }

    /// About 150 characters of `text` around the first occurrence of any search word.
    static func snippet(in text: String, terms: [String]) -> String {
        var best: Range<String.Index>?
        for term in terms {
            if let r = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]),
               best == nil || r.lowerBound < best!.lowerBound {
                best = r
            }
        }
        guard let match = best else { return String(text.prefix(150)) }
        let start = text.index(match.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        var out = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { out = "\u{2026}" + out }
        if end < text.endIndex { out += "\u{2026}" }
        return out
    }
}
