//
//  PluginMetadataService.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/14/2026.
//
//  Wraps a loaded M3MetadataPlugin so it behaves exactly like a
//  built-in MetadataService everywhere Subler uses one -- the Search
//  Metadata dialog, the batch queue's provider popup, etc. Translates the
//  plugin's Foundation-only dictionaries (see M3MetadataPlugin) into
//  Subler's own MetadataResult type and back.
//

import Foundation
import MP42Foundation

public struct PluginMetadataService: MetadataService {

    let plugin: M3MetadataPlugin

    public var languages: [String] { return ["en"] }
    public var languageType: LanguageType { return .custom }
    public var defaultLanguage: String { return "en" }
    public var name: String { return plugin.pluginName }

    // MARK: - Library server

    /// True when the plugin declares itself a library server (see
    /// M3MetadataPlugin.sourceKind) and can list its items.
    var isLibraryServer: Bool {
        return PluginSourceKind.isLibraryServer(plugin.sourceKind?() ?? PluginSourceKind.online)
    }

    /// Everything the server lists, as the Library scan compares it. Slow
    /// (one or more web requests): call from a background thread.
    func libraryItems() -> [LibraryServerItem] {
        guard let listed = plugin.listLibraryItems?() else { return [] }
        return listed.compactMap { LibraryServerItem(dictionary: $0) }
    }

    // MARK: - Movie search

    public func search(movie: String, language: String) -> [MetadataResult] {
        // An empty query makes some sources return an
        // arbitrary movie instead of nothing.
        guard movie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return [] }
        return plugin.searchMovie(query: movie).map { metadataResult(from: $0) }
    }

    public func loadMovieMetadata(_ partialMetadata: MetadataResult, language: String) -> MetadataResult {
        guard let id = partialMetadata[.serviceContentID] as? String else { return partialMetadata }
        let dictionary = plugin.loadMovieMetadata(id: id)
        guard dictionary.isEmpty == false else { return partialMetadata }
        let result = metadataResult(from: dictionary)
        result.chapters = loadChapters(id: id)
        return result
    }

    /// M3MetadataPlugin.loadChapters(id:) is declared `optional` on the
    /// protocol, so accessing it through `plugin` (typed as the
    /// M3MetadataPlugin existential, not as PluginBridge concretely)
    /// always requires the `?`, regardless of whether the concrete
    /// instance backing it actually implements it -- that's true even
    /// though `plugin` is in practice always a PluginBridge (see
    /// MetadataPluginLoader.loadPlugins()), and PluginBridge itself always
    /// implements loadChapters(id:) unconditionally, returning [] rather
    /// than crashing when the underlying loaded bundle doesn't support it.
    ///
    /// Note this issues its own separate request to the plugin (one plugin's
    /// implementation re-fetches and re-parses the movie page) rather than
    /// reusing whatever loadMovieMetadata(id:) just fetched above -- a
    /// real inefficiency (two page fetches instead of one on every Add/
    /// preview), but not a correctness problem, and not worth a shared-
    /// cache mechanism until chapter import is more than a single plugin
    /// deep.
    private func loadChapters(id: String) -> [Chapter] {
        let dictionaries = plugin.loadChapters?(id: id) ?? []
        return dictionaries.compactMap { dictionary -> Chapter? in
            guard let name = dictionary["name"] as? String,
                let timestampNumber = dictionary["timestamp"] as? NSNumber
                else { return nil }
            return Chapter(name: name, timestamp: timestampNumber.uint64Value)
        }
    }

    /// Maps the documented dictionary keys (see M3MetadataPlugin) onto
    /// the corresponding MetadataResult fields. Every key is optional --
    /// a plugin only needs to supply what it actually has.
    private func metadataResult(from dictionary: [String: Any]) -> MetadataResult {
        let metadata = MetadataResult()
        metadata.mediaKind = .movie

        metadata[.serviceContentID] = dictionary["id"] as? String
        metadata[.name]             = (dictionary["title"] as? String)?.withoutPromotionText
        metadata[.releaseDate]      = dictionary["releaseDate"] as? String
        metadata[.longDescription]  = dictionary["synopsis"] as? String
        metadata[.studio]           = dictionary["studio"] as? String
        metadata[.director]         = dictionary["director"] as? String
        metadata[.seriesName]       = dictionary["series"] as? String

        if let cast = dictionary["cast"] as? [String], cast.isEmpty == false {
            metadata[.cast] = cast.joined(separator: ", ")
        }
        if let genre = dictionary["genre"] as? [String], genre.isEmpty == false {
            metadata[.genre] = genre.joined(separator: ", ")
        }

        if let artworkURLStrings = dictionary["artworkURLs"] as? [String] {
            metadata.remoteArtworks = artworkURLStrings.compactMap { string -> Artwork? in
                guard let url = URL(string: string) else { return nil }
                return Artwork(url: url, thumbURL: url, service: name, type: .poster, size: .standard)
            }
        }

        // "ratingCountry"/"ratingName" (both required together) look up a
        // real content-rating board entry via Subler's own ratings table --
        // the same table iTunes Store results use -- so a plugin can supply
        // a genuine rating without needing to know anything about
        // Subler's internal Ratings/MediaKind types itself.
        if let ratingCountry = dictionary["ratingCountry"] as? String,
           let ratingName = dictionary["ratingName"] as? String {
            metadata[.rating] = Ratings.shared.rating(countryCode: ratingCountry, mediaKind: .movie, name: ratingName)?.iTunesCode
        }

        if let contentRatingNumber = dictionary["contentRating"] as? NSNumber {
            metadata.contentRating = contentRatingNumber.intValue
        }

        return metadata
    }

    // MARK: - TV Show (not supported by plugins yet)

    public func search(tvShow: String, language: String) -> [String] {
        return []
    }

    public func search(tvShow: String, language: String, season: Int?, episode: Int?) -> [MetadataResult] {
        return []
    }

    public func loadTVMetadata(_ metadata: MetadataResult, language: String) -> MetadataResult {
        return metadata
    }
}

/// The two kinds of source (see M3MetadataPlugin.sourceKind).
enum PluginSourceKind {
    static let online = "online"
    static let libraryServer = "libraryServer"

    /// Only the exact word "libraryServer" (any letter case) makes a library
    /// server; anything else, including an empty string, is an online source.
    static func isLibraryServer(_ kind: String) -> Bool {
        return kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == libraryServer.lowercased()
    }
}

/// One item a library server lists: where its file is and the text the
/// server holds for each tag, by tag key (the keys the Library scan uses). A
/// tag the server has nothing for has no entry.
struct LibraryServerItem: Equatable {
    let id: String
    let title: String
    /// The file's path as the server knows it, nil when it did not say.
    let path: String?
    var values: [String: String]

    /// Builds an item from a plugin's dictionary (see
    /// M3MetadataPlugin.listLibraryItems). Nil without an id and a title.
    init?(dictionary: [String: Any]) {
        guard let id = dictionary["id"] as? String, id.isEmpty == false,
              let title = (dictionary["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), title.isEmpty == false
        else { return nil }
        self.id = id
        self.title = title
        let path = (dictionary["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = (path?.isEmpty ?? true) ? nil : path

        var values: [String: String] = [MP42MetadataKeyName: title]

        func text(_ key: String) -> String? {
            guard let string = (dictionary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), string.isEmpty == false else { return nil }
            return string
        }
        func list(_ key: String) -> String? {
            guard let strings = dictionary[key] as? [String] else { return nil }
            let joined = strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.isEmpty == false }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }

        // A release date is shown by the Library scan as year-month-day.
        if let date = text("releaseDate") { values[MP42MetadataKeyReleaseDate] = String(date.prefix(10)) }
        if let studio = text("studio") { values[MP42MetadataKeyStudio] = studio }
        if let director = text("director") { values[MP42MetadataKeyDirector] = director }
        if let synopsis = text("synopsis") { values[MP42MetadataKeyLongDescription] = synopsis }
        if let cast = list("cast") { values[MP42MetadataKeyCast] = cast }
        if let genre = list("genre") { values[MP42MetadataKeyUserGenre] = genre }
        if let rating = text("ratingName") { values[MP42MetadataKeyRating] = rating }
        if (dictionary["hasCover"] as? Bool) == true { values[MP42MetadataKeyCoverArt] = LibraryServerItem.coverText }
        self.values = values
    }

    /// What the Library scan shows for a cover picture (the same word it uses
    /// for a file's own cover, so the two read alike).
    static let coverText = NSLocalizedString("Artwork", comment: "Library scan -> shown for a tag that holds a picture")

    /// The checked tags (`keys`) that the file lacks (no entry in
    /// `fileValues`) but this item has: what the server could fill in. In
    /// the order of `keys`.
    func gaps(fileValues: [String: String], keys: [String]) -> [String] {
        return keys.filter { fileValues[$0] == nil && values[$0] != nil }
    }
}

extension String {

    /// Some sites print a promotion after the real title ("On Sale!" and the
    /// like), set apart by line breaks or a long run of blanks. The title
    /// ends at the first line break or the first run of four or more blank
    /// characters; everything after it, and any blanks or dashes left at the
    /// end, are dropped. A title without either is only trimmed.
    var withoutPromotionText: String {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        var cut: String.Index?
        var runStart: String.Index?
        var runLength = 0
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isNewline {
                cut = runStart ?? index
                break
            }
            if character.isWhitespace {
                if runLength == 0 { runStart = index }
                runLength += 1
                if runLength >= 4 {
                    cut = runStart
                    break
                }
            } else {
                runLength = 0
                runStart = nil
            }
            index = text.index(after: index)
        }
        guard let cut = cut else { return text }
        let dashes = CharacterSet(charactersIn: "-\u{2013}\u{2014}")
        return String(text[..<cut]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(dashes))
    }
}
