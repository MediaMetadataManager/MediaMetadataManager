//
//  PluginMetadataService.swift
//  Subler
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
