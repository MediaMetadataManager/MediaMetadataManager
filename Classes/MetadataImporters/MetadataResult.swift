//
//  MetadataResult.swift
//  Subler
//
//  Created by Damiano Galassi on 08/08/2017.
//

import Foundation
import ImageIO
import MP42Foundation

// MARK: - Image

public enum ArtworkSize : Int, CustomStringConvertible {
    public var description: String {
        switch self {
        case .standard:
            return "standard"
        case .square:
            return "square"
        case .rectangle:
            return "rectangle"
        case .vertical:
            return "vertical"
        case .fullscreen:
            return "fullscreen"
        case .widescreen:
            return "widescreen"
        case .maxres:
            return "maxres"
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .`default`:
            return "default"
        }
    }

    case standard
    case square
    case rectangle
    case vertical
    case fullscreen
    case widescreen
    case maxres
    case low
    case medium
    case high
    case `default`
}

public enum ArtworkType : Int, CustomStringConvertible {
    public var description: String {
        switch self {
        case .poster:
            return "poster"
        case .season:
            return "season"
        case .episode:
            return "episode"
        case .backdrop:
            return "backdrop"
        case .person:
            return "person"

        case .none:
            return NSLocalizedString("None", comment: "Queue metadata search artwork type")
        }
    }

    public var isMovieType: Bool {
        switch self {
        case .poster, .backdrop:
            return true
        default:
            return false
        }
    }

    case poster
    case season
    case episode
    case backdrop
    case person = 5
    case none = 4
}

public struct Artwork: Equatable, Hashable {
    public let url: URL
    public let thumbURL: URL
    public let service: String
    public let type: ArtworkType
    public let size: ArtworkSize

    public static func == (lhs: Artwork, rhs: Artwork) -> Bool {
        return lhs.url == rhs.url
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    public static func unique(artworks: [Artwork]) -> [Artwork] {
        var uniques = [Artwork]()
        for artwork in artworks {
            if !uniques.contains(artwork) {
                uniques.append(artwork)
            }
        }
        return uniques
    }
}

// MARK: - Orientation

/// Orientation judged from the real pixel size of an image, never from the
/// label a provider gives it (Apple TV and the iTunes Store return both
/// portrait and landscape versions). Images are never rotated.
public enum ArtworkOrientation: Equatable {
    case portrait
    case landscape
    case square
    case unknown

    /// Taller than wide by more than 10% is portrait, wider than tall by more
    /// than 10% is landscape, anything in between is square.
    public static func classify(width: Int, height: Int) -> ArtworkOrientation {
        guard width > 0, height > 0 else { return .unknown }
        if Double(height) > Double(width) * 1.1 { return .portrait }
        if Double(width) > Double(height) * 1.1 { return .landscape }
        return .square
    }

    /// Reads only the image header, so it is cheap. An EXIF orientation that
    /// turns the image sideways (5 to 8) swaps width and height.
    public static func of(data: Data) -> ArtworkOrientation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return .unknown }

        if let exif = properties[kCGImagePropertyOrientation] as? Int, exif >= 5 {
            swap(&width, &height)
        }
        return classify(width: width, height: height)
    }
}

extension Array where Element == Artwork {

    /// The posters to try, best first, when the art must be portrait: the one
    /// already chosen, then the provider's own standard-size posters, then
    /// every other poster (a provider's size label can be wrong, so the pixel
    /// check decides). At most `limit` entries, no duplicates.
    func portraitCandidates(preferred: Artwork?, service: String, limit: Int = 6) -> [Artwork] {
        var result: [Artwork] = []
        func add(_ artwork: Artwork?) {
            if let artwork = artwork, result.contains(artwork) == false { result.append(artwork) }
        }
        add(preferred)
        let posters = filter { $0.type == .poster }
        for artwork in posters where artwork.size == .standard && artwork.service == service { add(artwork) }
        for artwork in posters where artwork.size == .standard { add(artwork) }
        for artwork in posters where artwork.service == service { add(artwork) }
        for artwork in posters { add(artwork) }
        return Array<Artwork>(result.prefix(limit))
    }
}

extension Array where Element == Artwork {

    func first(by type: ArtworkType, size: ArtworkSize, service: String) -> Artwork? {
        if type == .backdrop || type == .episode {
            let serviceArtwork = self.filter { $0.type == type && $0.service == service }.first
            let artwork = self.filter { $0.type == type }.first
            return serviceArtwork != nil ? serviceArtwork : artwork
        }
        else {
            let serviceArtwork = self.filter { $0.type == type && $0.size == size && $0.service == service }.first
            let artwork = self.filter { $0.type == type && $0.size == size}.first
            return serviceArtwork != nil ? serviceArtwork : artwork
        }
    }

    mutating func sortTopPicks(service: String) {
        let poster = first(by: .poster, size: .standard, service: service)
        let posterRect = first(by: .poster, size: .rectangle, service: AppleTV().name)
        let posterSquare = first(by: .poster, size: .square, service: AppleTV().name)
        let season = first(by: .season, size: .standard, service: service)
        let seasonRect = first(by: .season, size: .rectangle, service: AppleTV().name)
        let seasonSquare = first(by: .season, size: .square, service: AppleTV().name)
        let backdrop = first(by: .backdrop, size: .standard, service: service)
        let episode = first(by: .episode, size: .standard, service: service)

        let topPicks = [poster, posterRect, posterSquare,
                        season, seasonRect, seasonSquare,
                        backdrop, episode]

        for pick in topPicks {
            if let pick, let index = firstIndex(of: pick) {
                remove(at: index)
            }
        }

        for pick in topPicks.reversed() {
            if let pick {
                insert(pick, at: 0)
            }
        }
    }

    func sortedTopPicks(service: String) -> [Self.Element] {
        var sorted = self
        sorted.sortTopPicks(service: service)
        return sorted
    }
}

public enum MediaKind: Int {
    case tvShow = 10
    case movie = 9

    public var description: String {
        switch self {
        case .movie:
            return "Movie"
        case .tvShow:
            return "TV"
        }
    }
}

private let localizedKeys: [MetadataResult.Key: String] = [
    .name             : NSLocalizedString("Name", comment: "nil"),
    .composer         : NSLocalizedString("Composer", comment: "nil"),
    .genre            : NSLocalizedString("Genre", comment: "nil"),
    .releaseDate      : NSLocalizedString("Release Date", comment: "nil"),
    .description      : NSLocalizedString("Description", comment: "nil"),
    .longDescription  : NSLocalizedString("Long Description", comment: "nil"),
    .rating           : NSLocalizedString("Rating", comment: "nil"),
    .studio           : NSLocalizedString("Studio", comment: "nil"),
    .cast             : NSLocalizedString("Cast", comment: "nil"),
    .director         : NSLocalizedString("Director", comment: "nil"),
    .producers        : NSLocalizedString("Producers", comment: "nil"),
    .screenwriters    : NSLocalizedString("Screenwriters", comment: "nil"),
    .executiveProducer: NSLocalizedString("Executive Producer", comment: "nil"),
    .copyright        : NSLocalizedString("Copyright", comment: "nil"),

    .contentID        : NSLocalizedString("contentID", comment: "nil"),
    .artistID         : NSLocalizedString("artistID", comment: "nil"),
    .playlistID       : NSLocalizedString("playlistID", comment: "nil"),
    .iTunesCountry    : NSLocalizedString("iTunes Country", comment: "nil"),
    .iTunesURL        : NSLocalizedString("iTunes URL", comment: "nil"),

    .seriesName       : NSLocalizedString("Series Name", comment: "nil"),
    .seriesDescription: NSLocalizedString("Series Description", comment: "nil"),
    .trackNumber      : NSLocalizedString("Track #", comment: "nil"),
    .diskNumber       : NSLocalizedString("Disk #", comment: "nil"),
    .episodeNumber    : NSLocalizedString("Episode #", comment: "nil"),
    .episodeID        : NSLocalizedString("Episode ID", comment: "nil"),
    .season           : NSLocalizedString("Season", comment: "nil"),
    .network          : NSLocalizedString("Network", comment: "nil"),

    .serviceContentID  : NSLocalizedString("Service Content ID", comment: "nil"),
    .serviceAdditionalContentID : NSLocalizedString("Service Additional Content ID", comment: "nil"),
    .serviceEpisodeID : NSLocalizedString("Service Episode ID", comment: "nil")
]

public final class MetadataResult {

    public enum Key: String {
        // Common Keys
        case name               = "{Name}"
        case composer           = "{Composer}"
        case genre              = "{Genre}"
        case releaseDate        = "{Release Date}"
        case description        = "{Description}"
        case longDescription    = "{Long Description}"
        case rating             = "{Rating}"
        case studio             = "{Studio}"
        case cast               = "{Cast}"
        case director           = "{Director}"
        case producers          = "{Producers}"
        case screenwriters      = "{Screenwriters}"
        case executiveProducer  = "{Executive Producer}"
        case copyright          = "{Copyright}"

        case mediaKind          = "{MediaKind}"
        case contentRating      = "{ContentRating}"

        // iTunes Keys
        case contentID          = "{contentID}"
        case artistID           = "{artistID}"
        case playlistID         = "{playlistID}"
        case iTunesCountry      = "{iTunes Country}"
        case iTunesURL          = "{iTunes URL}"

        // TV Show Keys
        case seriesName         = "{Series Name}"
        case seriesDescription  = "{Series Description}"
        case trackNumber        = "{Track #}"
        case diskNumber         = "{Disk #}"
        case episodeNumber      = "{Episode #}"
        case episodeID          = "{Episode ID}"
        case season             = "{Season}"
        case network            = "{Network}"

        // Services internal IDs
        case serviceContentID             = "{ServiceSeriesID}"
        case serviceAdditionalContentID   = "{AdditionalServiceSeriesID}"
        case serviceEpisodeID             = "{ServiceEpisodeID}"

        fileprivate static var movieKeys: [Key] {
            return [.name,
                    .seriesName,
                    .composer,
                    .genre,
                    .releaseDate,
                    .description,
                    .longDescription,
                    .rating,
                    .studio,
                    .cast,
                    .director,
                    .producers,
                    .screenwriters,
                    .executiveProducer,
                    .copyright,
                    .contentID,
                    .artistID,
                    .iTunesCountry,

                    .serviceContentID,
                    .serviceAdditionalContentID,
                    .serviceEpisodeID]
        }

        fileprivate static var tvShowKeys: [Key] {
            return [.name,
                    .seriesName,
                    .composer,
                    .genre,
                    .releaseDate,

                    .trackNumber,
                    .diskNumber,
                    .episodeNumber,
                    .network,
                    .episodeID,
                    .season,

                    .description,
                    .longDescription,
                    .seriesDescription,

                    .rating,
                    .studio,
                    .cast,
                    .director,
                    .producers,
                    .screenwriters,
                    .executiveProducer,
                    .copyright,
                    .contentID,
                    .artistID,
                    .playlistID,
                    .iTunesCountry,

                    .serviceContentID,
                    .serviceAdditionalContentID,
                    .serviceEpisodeID
            ]
        }

        fileprivate static var sortedKeys: [Key] {
            return [.name,
                    .seriesName,
                    .composer,
                    .genre,
                    .releaseDate,

                    .trackNumber,
                    .diskNumber,
                    .episodeNumber,
                    .network,
                    .episodeID,
                    .season,

                    .description,
                    .longDescription,
                    .seriesDescription,

                    .rating,
                    .studio,
                    .cast,
                    .director,
                    .producers,
                    .screenwriters,
                    .executiveProducer,
                    .copyright,
                    .contentID,
                    .artistID,
                    .playlistID,

                    .iTunesURL,
                    .iTunesCountry,

                    .serviceContentID,
                    .serviceAdditionalContentID,
                    .serviceEpisodeID
            ]
        }


        public var localizedDisplayName: String {
            return localizedKeys[self] ?? "Null"
        }

        public var token: Token {
            return Token(text: self.rawValue)
        }

        public static var movieKeysStrings: [String] {
            return Key.movieKeys.map { $0.rawValue }
        }

        public static var tvShowKeysStrings: [String] {
            return Key.tvShowKeys.map { $0.rawValue }
        }

        public static func localizedDisplayName(key: String) -> String {
            return Key(rawValue: key)?.localizedDisplayName ?? key
        }

    }

    private var dictionary: [Key:Any]
    public var mediaKind: MediaKind
    public var contentRating: Int
    public var remoteArtworks: [Artwork]
    public var artworks: [MP42Image]
    /// Chapter/scene markers a metadata source supplied alongside the rest
    /// of this result -- currently only ever populated by a plugin-backed
    /// service whose plugin implements the optional
    /// M3MetadataPlugin.loadChapters(id:) requirement (see
    /// PluginMetadataService.loadMovieMetadata). Empty for every built-in
    /// provider, which have no chapter data to offer here. Reuses the same
    /// `Chapter` type as the (currently unwired) ChapterDB-backed chapter
    /// search, rather than introducing a second chapter representation.
    public var chapters: [Chapter]

    init() {
        self.dictionary = [:]
        self.remoteArtworks = []
        self.artworks = []
        self.mediaKind = .movie
        self.contentRating = 0
        self.chapters = []
    }

    subscript(key: Key) -> Any? {
        get {
            return dictionary[key]
        }
        set (newValue) {
            dictionary[key] = newValue
        }
    }

    lazy var orderedKeys: [Key] = {
        let sortedKeys = Key.sortedKeys
        return Array(dictionary.keys).sorted(by: { (key1: Key, key2: Key) -> Bool in
            if let index1 = sortedKeys.firstIndex(of: key1), let index2 = sortedKeys.firstIndex(of: key2) {
                return index1 < index2
            }
            return key1 != Key.serviceContentID && key1 != Key.serviceEpisodeID
        })
    }()

    public var count: Int {
        return dictionary.count
    }

    public func merge(result: MetadataResult) {
        dictionary.merge(result.dictionary) { (_, new) in new }
    }

    private func truncate(string: String, to index: Int) -> String {
        let words = string.split(separator: " ")
        var accumulatedCounts = words.map { $0.count + 1 }
        for index in 1..<accumulatedCounts.count {
            accumulatedCounts[index] += accumulatedCounts[index - 1]
        }
        let endIndex = accumulatedCounts.filter { $0 < index }.endIndex
        return words[0..<endIndex].joined(separator: " ") + "…"
    }

    public func mappedMetadata(to map: MetadataResultMap, keepEmptyKeys: Bool) -> MP42Metadata {
        let metadata = MP42Metadata()

        if dictionary[.description] == nil, let longDesc = dictionary[.longDescription] as? String {
            if longDesc.count > 254 {
                dictionary[.description] = truncate(string: longDesc, to: 254)
            } else {
                dictionary[.description] = longDesc
            }
        }

        metadata.addItems(map.items.compactMap {
            let value = $0.value.reduce("", {
                if let key = Key(rawValue: $1.text) {
                    if let value = dictionary[key] {
                        return $0 + $1.format(text: "\(value)")
                    }
                    return $0
                }
                else {
                    return $0 + $1.text
                }
            })
            return value.isEmpty == false || keepEmptyKeys ? MP42MetadataItem(identifier: $0.key,
                                                                              value: value as NSCopying & NSObjectProtocol,
                                                                              dataType: .unspecified, extendedLanguageTag: nil): nil
        })

        metadata.addItems(artworks.map {
            MP42MetadataItem(identifier: MP42MetadataKeyCoverArt,value: $0,
                             dataType: .image, extendedLanguageTag: nil)
        })

        let mediaKind = MP42MetadataItem(identifier: MP42MetadataKeyMediaKind,
                                         value: NSNumber(value: self.mediaKind.rawValue),
                                         dataType: .integer,
                                         extendedLanguageTag: nil)
        metadata.addItem(mediaKind)

        if contentRating > 0 || keepEmptyKeys {
            let contentRating = MP42MetadataItem(identifier: MP42MetadataKeyContentRating,
                                             value: NSNumber(value: self.contentRating),
                                             dataType: .integer,
                                             extendedLanguageTag: nil)
            metadata.addItem(contentRating)
        }

        return metadata
    }

}

// MARK: - Combining results from several providers

extension MetadataResult {

    /// Fields holding a comma separated list of names. Combined results
    /// keep every distinct name from every provider.
    private static let listKeys: Set<Key> = [.genre, .cast, .director, .producers, .screenwriters, .composer, .executiveProducer]

    /// Free-text descriptions. Combined results keep the longest one.
    private static let longTextKeys: Set<Key> = [.description, .longDescription, .seriesDescription]

    /// Identifiers that only mean something to the provider that issued
    /// them. Never copied from one provider's result into another's.
    private static let identifierKeys: Set<Key> = [.contentID, .artistID, .playlistID, .iTunesCountry, .iTunesURL,
                                                    .serviceContentID, .serviceAdditionalContentID, .serviceEpisodeID, .episodeID]

    private static func text(of value: Any?) -> String {
        guard let value = value else { return "" }
        let string = (value as? String) ?? "\(value)"
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func union(_ first: String, _ second: String) -> String {
        var seen = Set<String>()
        var names: [String] = []
        for part in (first + "," + second).split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty == false, seen.insert(name.lowercased()).inserted {
                names.append(name)
            }
        }
        return names.joined(separator: ", ")
    }

    /// Whether `candidate` (from another provider) describes the same title
    /// as `self`. Without this check a provider that found a different
    /// movie would contaminate the combined result.
    func describesSameTitle(as candidate: MetadataResult, searchTitle: String?) -> Bool {
        func normalized(_ value: Any?) -> String {
            return NamingReviewWindowController.normalizedForComparison(MetadataResult.text(of: value))
        }
        func similar(_ a: String, _ b: String) -> Bool {
            if a.isEmpty || b.isEmpty { return true }   // nothing to compare
            if a == b { return true }
            let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
            return shorter.count >= 6 && longer.contains(shorter)
        }

        if mediaKind == .tvShow {
            if similar(normalized(self[.seriesName]), normalized(candidate[.seriesName])) == false { return false }
            for key in [Key.season, Key.episodeNumber] {
                let a = MetadataResult.text(of: self[key]), b = MetadataResult.text(of: candidate[key])
                if a.isEmpty == false, b.isEmpty == false, a != b { return false }
            }
            return true
        }

        let mine = normalized(self[.name]), theirs = normalized(candidate[.name])
        let searched = NamingReviewWindowController.normalizedForComparison(searchTitle ?? "")
        let titleAgrees = similar(mine, theirs) || (searched.isEmpty == false && similar(searched, theirs))
        guard titleAgrees else { return false }

        let myYear = ParsedMediaName.firstFourDigitYear(in: MetadataResult.text(of: self[.releaseDate]))
        let theirYear = ParsedMediaName.firstFourDigitYear(in: MetadataResult.text(of: candidate[.releaseDate]))
        if let a = myYear.flatMap({ Int($0) }), let b = theirYear.flatMap({ Int($0) }) {
            return abs(a - b) <= 1
        }
        return true
    }

    /// Builds one result from several providers' results for the same
    /// title. The first result is the primary: its value is kept for
    /// single-value fields (title, release date, studio, rating...) and
    /// every blank field is filled from the others. Name lists (cast,
    /// genre, directors...) are combined, the longest description wins,
    /// and the artwork of every provider is pooled so the preferred
    /// artwork can be picked from all of it.
    static func combine(_ results: [MetadataResult]) -> MetadataResult? {
        guard let primary = results.first else { return nil }
        guard results.count > 1 else { return primary }

        let combined = MetadataResult()
        combined.dictionary = primary.dictionary
        combined.mediaKind = primary.mediaKind
        combined.contentRating = primary.contentRating
        combined.chapters = primary.chapters
        combined.remoteArtworks = primary.remoteArtworks
        combined.artworks = primary.artworks

        for other in results.dropFirst() {
            for (key, value) in other.dictionary {
                let incoming = text(of: value)
                if incoming.isEmpty || identifierKeys.contains(key) { continue }

                let existing = text(of: combined.dictionary[key])
                if existing.isEmpty {
                    combined.dictionary[key] = value
                } else if listKeys.contains(key) {
                    combined.dictionary[key] = union(existing, incoming)
                } else if longTextKeys.contains(key), incoming.count > existing.count {
                    combined.dictionary[key] = value
                }
            }

            if combined.contentRating == 0 { combined.contentRating = other.contentRating }
            if combined.chapters.isEmpty { combined.chapters = other.chapters }
            combined.remoteArtworks = Artwork.unique(artworks: combined.remoteArtworks + other.remoteArtworks)
            combined.artworks.append(contentsOf: other.artworks)
        }
        return combined
    }
}
