//
//  QueueAction.swift
//  Subler
//
//  Created by Damiano Galassi on 28/07/2017.
//

import Foundation
import MP42Foundation

@objc enum QueueActionType: Int {
    case pre
    case post
}

/**
 *  Queue actions protocol, actions can be run by
 *  the queue's items.
 */
@objc protocol QueueActionProtocol: NSSecureCoding {
    func runAction(_ item: QueueItem) -> Bool
    var localizedDescription: String { get }
    var type: QueueActionType { get }
}

/// An action to remove existing metadata.
class QueueClearExistingMetadataAction: NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Clearing Metadata", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Clear Metadata", comment: "Action description.") }

    override init() {}

    func runAction(_ item: QueueItem) -> Bool {
        if let metadata = item.mp4File?.metadata {
            let dataTypes: UInt = MP42MetadataItemDataType.string.rawValue | MP42MetadataItemDataType.stringArray.rawValue | MP42MetadataItemDataType.bool.rawValue | MP42MetadataItemDataType.integer.rawValue | MP42MetadataItemDataType.integerArray.rawValue | MP42MetadataItemDataType.date.rawValue | MP42MetadataItemDataType.image.rawValue

            metadata.removeItems(metadata.metadataItemsFiltered(by: MP42MetadataItemDataType(rawValue: dataTypes)))
            return true
        }
        return false
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }
}

/// An action that set a formatted file name.
class QueueSetOutputFilenameAction: NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Setting Name", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Set Name", comment: "Action description.") }

    override init() {}

    func runAction(_ item: QueueItem) -> Bool {
        // formattedFileName() (Classes/MP42FileAdditions.swift) is the
        // app's single naming function, driven entirely by the "Filename"
        // preferences tab: the Movie naming-rule list (see
        // NamingRules.swift) for a movie, or the plain TV Show token
        // template for a TV show. It also inserts a separator between two
        // back-to-back placeholder tokens with nothing else between them,
        // so a Movie template like {Name}{Studio}{Release Date} no longer
        // glues its values together with no space at all.
        guard let mp4File = item.mp4File, let formattedName = mp4File.formattedFileName() else { return false }

        let pathExtension = item.destURL.pathExtension
        var destDirectory = item.destURL.deletingLastPathComponent()

        // preferredOutputSubfolder() (Classes/MP42FileAdditions.swift) is
        // nil unless the matching "Filename" preferences tab toggle is on
        // (Prefs.syncMovieFolderNameOnSave for a Movie,
        // Prefs.useAppleTVStyleTVFolders for a TV Show) -- in every other
        // case this item's destination directory is left exactly as it
        // was. When it isn't nil, the queue is about to write a brand new
        // file at a path that may not exist yet (unlike Document's
        // rename-in-place, which only ever moves within a folder that's
        // already there), so the subfolder has to be created here before
        // the write happens.
        // A destination inside iTunes/Apple TV's own "Automatically Add
        // to..." folder gets ingested and organized by that app the
        // moment the file lands there -- creating a subfolder for it
        // first would just leave an empty folder behind once ingestion
        // moves the file out, so this is left as the one destination
        // that never gets a subfolder regardless of the preference above.
        // Automatic delivery to an Automatically Add folder: the file is
        // written straight into it, no folders of its own.
        if let delivery = mp4File.deliveryFolder, delivery.isAutomaticMediaIngestFolder {
            destDirectory = delivery
        }
        else if let subfolder = mp4File.preferredOutputSubfolder(), destDirectory.isAutomaticMediaIngestFolder == false {
            let components = subfolder.split(separator: "/").map(String.init)

            // Same Ready for Media Library redirect Document.swift's
            // ensureOwnFolder(fileURL:targetName:)/nestIntoSubfolders(fileURL:subfolderPath:)
            // apply to the Edit window's Save path -- a single file
            // processed straight through the Queue (no Edit window
            // involved at all) used to always land its new folder next to
            // wherever its own destination already was, even with a Ready
            // for Media Library folder configured.
            if let readyForLibraryFolder = mp4File.deliveryFolder {
                if components.count == 1 {
                    // Movie: a one-shot folder, so an existing folder with
                    // the exact same name is treated as an unrelated
                    // collision and Finder-style suffixed rather than
                    // reused.
                    let candidate = readyForLibraryFolder.appendingPathComponent(components[0])
                    destDirectory = QueueController.uniqueFolderDestination(for: candidate)
                } else {
                    // TV: "<Show>/Season NN" -- the show folder is meant to
                    // accumulate every episode over time, so it's reused by
                    // exact name (never collision-suffixed the way a
                    // Movie's folder is) and only the season subfolder
                    // beneath it is created as needed.
                    destDirectory = readyForLibraryFolder
                    for component in components {
                        destDirectory.appendPathComponent(component)
                    }
                }
            } else {
                for component in components {
                    destDirectory.appendPathComponent(component)
                }
            }
            // Remember the top-most folder this has to create, so
            // QueueItem.process() can remove it again if the write then
            // fails (e.g. out of disk space).
            var topCreated: URL?
            var probe = destDirectory
            while FileManager.default.fileExists(atPath: probe.path) == false, probe.path.count > 1 {
                topCreated = probe
                probe = probe.deletingLastPathComponent()
            }
            try? FileManager.default.createDirectory(at: destDirectory, withIntermediateDirectories: true)
            if let topCreated = topCreated, FileManager.default.fileExists(atPath: topCreated.path) {
                item.createdDestinationFolder = topCreated
            }
        }

        item.destURL = destDirectory.appendingPathComponent(formattedName).appendingPathExtension(pathExtension)
        return true
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }
}

/// An action that search in the item source directory for additionals srt subtitles.
class QueueSubtitlesAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Loading subtitles", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Load Subtitles", comment: "Action description.") }

    override init() {}

    private func loadExternalSubtitles(url: URL) -> [MP42FileImporter] {
        let movieFilename = url.deletingPathExtension().lastPathComponent
        var importers: [MP42FileImporter] = []
        if let contents = try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles, .skipsPackageDescendants]) {
            for url in contents {
                let ext = url.pathExtension.lowercased()
                if ext == "srt" || ext == "ass" || ext == "ssa" {
                    let subtitleFilename = url.deletingPathExtension().lastPathComponent
                    if movieFilename.count <= subtitleFilename.count &&
                        subtitleFilename.hasPrefix(movieFilename) {
                        if let importer = try? MP42FileImporter(url: url) {
                            importers.append(importer)
                        }
                    }
                }
            }
        }

        return importers
    }

    func runAction(_ item: QueueItem) -> Bool {
        let subtitlesImporters = loadExternalSubtitles(url: item.fileURL)

        for importer in subtitlesImporters {
            for track in importer.tracks {
                item.mp4File?.addTrack(track)
            }
        }

        return subtitlesImporters.isEmpty == false
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }

}

/// An action that applies a preset to the item.
class QueueSetAction : NSObject, QueueActionProtocol {

    private let preset: MetadataPreset

    init(preset: MetadataPreset) {
        self.preset = preset.copy() as! MetadataPreset
    }

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return String.localizedStringWithFormat(NSLocalizedString("Applying %@ preset", comment: "Action localized description."), preset.title) }
    override var description: String { return String.localizedStringWithFormat(NSLocalizedString("Apply %@ preset", comment: "Action description"), preset.title) }

    func runAction(_ item: QueueItem) -> Bool {
        guard let metadata = item.mp4File?.metadata else { return false }

        let dataTypes: UInt = MP42MetadataItemDataType.string.rawValue | MP42MetadataItemDataType.stringArray.rawValue | MP42MetadataItemDataType.bool.rawValue | MP42MetadataItemDataType.integer.rawValue |
            MP42MetadataItemDataType.integerArray.rawValue | MP42MetadataItemDataType.date.rawValue

        var items = preset.metadata.metadataItemsFiltered(by: MP42MetadataItemDataType(rawValue: dataTypes))

        // Preferences > Metadata > "Overwrite existing metadata" wins over
        // this Set's own replace-annotations/replace-artworks choice, when
        // turned off -- that's the user's explicit promise that applying a
        // Set via the Queue (e.g. right after "Search Metadata" just ran)
        // never erases a value that search already found, regardless of
        // how the Set itself was saved. Mirrors
        // MovieViewController.applySet(_:), the in-editor equivalent.
        let skipExisting = MetadataPrefs.overwriteExistingAnnotations == false

        if skipExisting {
            let existingNonEmptyIdentifiers = Set(metadata.metadataItemsFiltered(by: MP42MetadataItemDataType(rawValue: dataTypes))
                .filter { $0.isEffectivelyEmpty == false }
                .map { $0.identifier })
            items = items.filter { existingNonEmptyIdentifiers.contains($0.identifier) == false }
        } else if preset.replaceAnnotations {
            metadata.removeItems(metadata.metadataItemsFiltered(by: MP42MetadataItemDataType(rawValue: dataTypes)))
        }

        if items.isEmpty == false {
            let identifiers = items.map { $0.identifier }
            // items has already been filtered down to identifiers that are
            // safe to touch (empty or altogether absent), so the only
            // things this ever clears are blank placeholders -- never a
            // value the preference is meant to protect.
            let toRemove = skipExisting
                ? metadata.metadataItemsFiltered(byIdentifiers: identifiers).filter { $0.isEffectivelyEmpty }
                : metadata.metadataItemsFiltered(byIdentifiers: identifiers)
            metadata.removeItems(toRemove)
            metadata.addItems(items)
        }

        let artworks = preset.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt)
        let hasExistingArtwork = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt).isEmpty == false

        if skipExisting {
            // Never replace existing artwork -- only add the preset's
            // artwork when there currently isn't any.
            if hasExistingArtwork == false && artworks.isEmpty == false {
                metadata.addItems(artworks)
            }
        } else {
            if preset.replaceArtworks {
                metadata.removeItems(metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyCoverArt))
            }
            if artworks.isEmpty == false {
                metadata.addItems(artworks)
            }
        }

        return true
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(preset, forKey: "SBQueueActionSet")
    }

    required init?(coder aDecoder: NSCoder) {
        guard let preset = aDecoder.decodeObject(of: MetadataPreset.self, forKey: "SBQueueActionSet") else { return nil }
        self.preset = preset
    }

    static var supportsSecureCoding: Bool { return true }

}

/// An action that fetches metadata online.
class QueueMetadataAction : NSObject, QueueActionProtocol {

    private let movieLanguage: String
    private let movieProvider: String

    private let tvShowLanguage: String
    private let tvShowProvider: String

    private let preferredArtwork: ArtworkType
    private let preferredArtworkSize: ArtworkSize

    /// The name the user approved for this release. When set, the search
    /// uses it instead of the file's own name or tags: inside a release
    /// the file is often called something like "01.mp4", while the
    /// approved name is what identifies the movie.
    let searchName: String?

    /// Exact title to search for, typed or confirmed by the user on the
    /// Metadata Review sheet. Wins over searchName and is always a movie
    /// search (that sheet only searches movies).
    let searchTerm: String?

    /// Which of the search's results to apply (0 = the first). The Metadata
    /// Review sheet sets this to the result the user picked.
    let searchResultIndex: Int

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Searching metadata", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Search Metadata", comment: "Action description.") }

    init(movieLanguage: String, tvShowLanguage: String, movieProvider: String, tvShowProvider: String, preferredArtwork: Int, preferredArtworkSize: Int, searchName: String? = nil, searchTerm: String? = nil, searchResultIndex: Int = 0) {
        self.searchName = searchName
        self.searchTerm = searchTerm
        self.searchResultIndex = max(0, searchResultIndex)
        self.movieLanguage = movieLanguage;
        self.movieProvider = movieProvider;

        self.tvShowLanguage = tvShowLanguage;
        self.tvShowProvider = tvShowProvider

        self.preferredArtwork = ArtworkType(rawValue: preferredArtwork) ?? .poster
        self.preferredArtworkSize = ArtworkSize(rawValue: preferredArtworkSize) ?? .standard

    }

    private func load(artworkURL: URL) -> MP42Image? {
        guard let data = URLSession.data(from: artworkURL) else { return nil }
        return MP42Image(data: data, type: MP42_ART_JPEG)
    }

    private func searchMetadata(info: MetadataSearchTerms) -> MetadataResult? {
        var metadata: MetadataResult? = nil

        switch info {
        case let .movie(title):
            let service = MetadataSearch.service(name: self.movieProvider)
            let movieSearch = MetadataSearch.movieSeach(service: service, movie: title, language: self.movieLanguage)
            let index = self.searchResultIndex
            _ = movieSearch.search(completionHandler: {
                if let result = ($0.indices.contains(index) ? $0[index] : $0.first) {
                    _ = movieSearch.loadAdditionalMetadata(result, completionHandler: { metadata = $0 }).run()
                }
            }).run()
        case let .tvShow(seriesName, season, episode):
            let service = MetadataSearch.service(name: self.tvShowProvider)
            let tvSearch = MetadataSearch.tvSearch(service: service, tvShow: seriesName, season: season, episode: episode, language: tvShowLanguage)
            _ = tvSearch.search(completionHandler: {
                if let result = $0.first {
                    _ = tvSearch.loadAdditionalMetadata(result, completionHandler: { metadata = $0 }).run()
                }
            }).run()
        case .none:
            break
        }

        return metadata
    }

    private func searchMetadata(terms: MetadataSearchTerms) -> MP42Metadata? {

        guard let metadata = searchMetadata(info: terms) else { return nil }

        let artworks = metadata.remoteArtworks

        if preferredArtwork != .none && artworks.isEmpty == false {
            let artwork: Artwork? = {
                let provider = terms.isMovie ? self.movieProvider : self.tvShowProvider
                let type = terms.isMovie && preferredArtwork.isMovieType == false ? .poster : preferredArtwork

                // TV box art is conventionally square -- TheTVDB/TheMovieDB
                // both already fetch "Squared TV Art" season images tagged
                // .square (see loadSquareTVArtwork(_:) in TheTVDB.swift /
                // TheMovieDB.swift) specifically for this. preferredArtworkSize
                // is the Movie-oriented poster-size preference (portrait/
                // standard); reusing it here for a TV search meant the size
                // filter below never matched the square season art that had
                // just been fetched, so it always fell through to a generic
                // poster or whatever came first instead.
                let size = terms.isMovie ? preferredArtworkSize : .square

                if let artwork = artworks.first(by: type, size: size, service: provider) {
                    return artwork
                }
                else if let artwork = artworks.first(by: .season, size: size, service: provider) {
                    return artwork
                }
                else if let artwork = artworks.first(by: .poster, size: .standard, service: provider) {
                    return artwork
                }
                else {
                    return artworks.first
                }
            }()

            if let url = artwork?.url, let artwork = load(artworkURL: url) {
                metadata.artworks.append(artwork)
            }
        }

        let map = metadata.mediaKind == .movie ? MetadataPrefs.movieResultMap : MetadataPrefs.tvShowResultMap
        return metadata.mappedMetadata(to: map, keepEmptyKeys: false)
    }

    func runAction(_ item: QueueItem) -> Bool {
        if let file = item.mp4File {
            let searchTerms: MetadataSearchTerms
            if let term = searchTerm, term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                searchTerms = .movie(title: term.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let name = searchName, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                searchTerms = MetadataSearchTerms.fromReleaseName(name)
            } else {
                searchTerms = file.extractSearchTerms(fallbackURL: item.fileURL)
            }
            if let metadata = searchMetadata(terms: searchTerms) {

                for item in metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyHDVideo) {
                    metadata.removeItem(item)
                }
                if let type = file.hdType {
                    metadata.addItem(MP42MetadataItem(identifier: MP42MetadataKeyHDVideo,
                                                      value: NSNumber(value: type.rawValue),
                                                      dataType: MP42MetadataItemDataType.integer,
                                                      extendedLanguageTag: nil))
                }

                file.metadata.merge(metadata, overwrite: true)
                return true
            }
        }
        return false
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(movieLanguage, forKey: "_movieLanguage")
        aCoder.encode(tvShowLanguage, forKey: "_tvShowLanguage")
        aCoder.encode(movieProvider, forKey: "_movieProvider")
        aCoder.encode(tvShowProvider, forKey: "_tvShowProvider")
        aCoder.encode(Int32(preferredArtwork.rawValue), forKey: "_preferredArtwork")
        aCoder.encode(Int32(preferredArtworkSize.rawValue), forKey: "_preferredArtworkSize")
        aCoder.encode(searchName, forKey: "_searchName")
        aCoder.encode(searchTerm, forKey: "_searchTerm")
        aCoder.encode(Int32(searchResultIndex), forKey: "_searchResultIndex")
    }

    required init?(coder aDecoder: NSCoder) {
        guard let movieLanguage = aDecoder.decodeObject(of: NSString.self, forKey: "_movieLanguage") as String?,
            let tvShowLanguage = aDecoder.decodeObject(of: NSString.self, forKey: "_tvShowLanguage") as String?,
            let movieProvider = aDecoder.decodeObject(of: NSString.self, forKey: "_movieProvider") as String?,
            let tvShowProvider = aDecoder.decodeObject(of: NSString.self, forKey: "_tvShowProvider") as String?,
            let preferredArtwork = ArtworkType(rawValue: Int(aDecoder.decodeInt32(forKey: "_preferredArtwork"))),
            let preferredArtworkSize = ArtworkSize(rawValue: Int(aDecoder.decodeInt32(forKey: "_preferredArtworkSize")))
        else { return nil }

        self.movieLanguage = movieLanguage
        self.tvShowLanguage = tvShowLanguage
        self.movieProvider = movieProvider
        self.tvShowProvider = tvShowProvider
        self.preferredArtwork = preferredArtwork
        self.preferredArtworkSize = preferredArtworkSize
        self.searchName = aDecoder.decodeObject(of: NSString.self, forKey: "_searchName") as String?
        self.searchTerm = aDecoder.decodeObject(of: NSString.self, forKey: "_searchTerm") as String?
        self.searchResultIndex = Int(aDecoder.decodeInt32(forKey: "_searchResultIndex"))
    }

    static var supportsSecureCoding: Bool { return true }

}

/// An action that organize the item tracks' groups.
class QueueOrganizeGroupsAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Organizing groups", comment: "Organize Groups action local description") }
    override var description: String { return NSLocalizedString("Organize Groups", comment: "Organize Groups action description") }

    override init() {}

    func runAction(_ item: QueueItem) -> Bool {
        item.mp4File?.organizeAlternateGroups()
        item.mp4File?.inferTracksLanguages()
        item.mp4File?.inferMediaCharacteristics()
        return true
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }

}

/// An action that fix the item tracks' fallbacks.
class QueueFixFallbacksAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Fixing Fallbacks", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Fix Fallbacks", comment: "Action description.") }

    override init() {}

    func runAction(_ item: QueueItem) -> Bool {
        item.mp4File?.setAutoFallback()
        return true
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }

}

/// An action that set unknown language tracks to preferred one.
class QueueSetLanguageAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Setting tracks language", comment: "Set Language action local description") }
    override var description: String { return NSLocalizedString("Set tracks language", comment: "Set Language action description") }

    let language: String

    init(language: String) {
        self.language = language
    }

    func runAction(_ item: QueueItem) -> Bool {
        if let tracks = item.mp4File?.tracks {
            for track in tracks {
                if track.language == "und" {
                    track.language = language
                }
            }
        }
        return true
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(language, forKey: "SBQueueSetLanguageAction")
    }

    required init?(coder aDecoder: NSCoder) {
        guard let language = aDecoder.decodeObject(of: NSString.self, forKey: "SBQueueSetLanguageAction") as String?
            else { return nil }
        self.language = language
    }

    static var supportsSecureCoding: Bool { return true }

}

/// An action that remove the tracks names.
class QueueClearTrackNameAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Clearing tracks names", comment: "Action localized description") }
    override var description: String { return NSLocalizedString("Clear tracks names", comment: "Action description") }

    override init() {}

    func runAction(_ item: QueueItem) -> Bool {
        if let tracks = item.mp4File?.tracks {
            for track in tracks {
                track.name = ""
            }
        }
        return true
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }

}

/// An action that renames audio tracks.
class QueuePrettifyAudioTrackNameAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Prettifying audio track names", comment: "Action localized description") }
    override var description: String { return NSLocalizedString("Prettify audio track names", comment: "Action description") }

    override init() {}

    func runAction(_ item: QueueItem) -> Bool {
        if let tracks = item.mp4File?.tracks {

            for track in tracks.compactMap({ $0 as? MP42AudioTrack }) {
                track.name = track.prettyTrackName
            }

        }
        return true
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }

}

/// An action that renames all the chapters titles.
class QueueRenameChaptersAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Renaming chapter titles", comment: "Action localized description") }
    override var description: String { return NSLocalizedString("Rename chapter titles", comment: "Action description") }

    override init() {}

    func runAction(_ item: QueueItem) -> Bool {
        let chaptersTracks = item.mp4File?.tracks.compactMap { $0 as? MP42ChapterTrack } ?? []

        chaptersTracks.forEach {
            for (index, chapter) in $0.chapters.enumerated() {
                let title = "\(index + 1) - Chapter"
                $0.setTitle(title, forChapter: chapter)
            }
        }

        return true
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }

}

enum QueueColorSpaceActionTag: UInt16 {
    case None = 1
    case Rec601PAL
    case Rec601SMPTEC
    case Rec709
    case Rec2020
    case Rec2100PQ
    case Rec2100HLG
    case P3DCI
    case P3D65
    case sRGB

    func tagValues() -> (colorPrimaries: UInt16, transferCharacteristics: UInt16, matrixCoefficients: UInt16) {
        switch self {
        case .None:
            return (0, 0, 0)
        case .Rec601PAL:
            return (5, 1, 6)
        case .Rec601SMPTEC:
            return (6, 1, 6)
        case .Rec709:
            return (1, 1, 1)
        case .Rec2020:
            return (9, 1, 9)
        case .Rec2100PQ:
            return (9, 16, 9)
        case .Rec2100HLG:
            return (9, 18, 9)
        case .P3DCI:
            return (11, 17, 6)
        case .P3D65:
            return (12, 17, 6)
        case .sRGB:
            return (1, 13, 1)
        }
    }

}

/// An action that set the video track color space.
class QueueColorSpaceAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Setting color space", comment: "Set track color space action local description") }
    override var description: String { return NSLocalizedString("Set color space", comment: "Set track color space action description") }

    let tag: QueueColorSpaceActionTag;

    init(tag: QueueColorSpaceActionTag) {
        self.tag = tag
    }

    func runAction(_ item: QueueItem) -> Bool {
        if let tracks = item.mp4File?.tracks(withMediaType: kMP42MediaType_Video) as? [MP42VideoTrack] {
            for track in tracks {
                if track.format == kMP42VideoCodecType_H264 ||
                    track.format == kMP42VideoCodecType_HEVC ||
                    track.format == kMP42VideoCodecType_HEVC_PSinBitstream ||
                    track.format == kMP42VideoCodecType_VVC ||
                    track.format == kMP42VideoCodecType_VVC_PSinBitstream ||
                    track.format == kMP42VideoCodecType_MPEG4Video ||
                    track.format == kMP42VideoCodecType_AV1 {
                    let values = tag.tagValues()
                    track.colorPrimaries = values.colorPrimaries;
                    track.transferCharacteristics = values.transferCharacteristics;
                    track.matrixCoefficients = values.matrixCoefficients;
                }
            }
            return true
        }
        return false
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(Int32(tag.rawValue), forKey: "SBQueueColorSpaceActionTag")
    }

    required init?(coder aDecoder: NSCoder) {
        self.tag = QueueColorSpaceActionTag(rawValue: UInt16(aDecoder.decodeInt32(forKey: "SBQueueColorSpaceActionTag"))) ?? .Rec709
    }

    static var supportsSecureCoding: Bool { return true }

}

class QueueOptimizeAction: NSObject, QueueActionProtocol {

    var type: QueueActionType { return .post }
    var localizedDescription: String { return NSLocalizedString("Optimizing", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Optimize", comment: "Action description.") }

    override init() {}

    func runAction(_ item: QueueItem) -> Bool {
        return item.mp4File?.optimize() ?? false
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }
}

class QueueSendToiTunesAction: NSObject, QueueActionProtocol {

    var type: QueueActionType { return .post }
    var localizedDescription: String { return NSLocalizedString("Sending to iTunes", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Send to iTunes", comment: "Action description.") }

    override init() {}

    func runAction(_ item: QueueItem) -> Bool {
        return sendToFileExternalApp(fileURL: item.destURL)
    }

    func encode(with aCoder: NSCoder) {}
    required init?(coder aDecoder: NSCoder) {}
    static var supportsSecureCoding: Bool { return true }
}

/// An action that changes the 'enabled' audio track to the language preferred, if a track labeled with that language exists
class QueueChangeAudioLanguageAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Enabling audio track with selected language", comment: "Enable audio track local description") }
    override var description: String { return NSLocalizedString("Enabling audio track with selected language", comment: "Enable audio track action description") }

    let language: String

    init(language: String) {
        self.language = language
    }

    func runAction(_ item: QueueItem) -> Bool {
        if let tracks = item.mp4File?.tracks.filter({ $0.mediaType == kMP42MediaType_Audio}) {
            let groups = Dictionary(grouping: tracks, by: { $0.alternateGroup })
            for (_, group) in groups {
                if let track = group.first(where: { $0.language == language && $0.mediaCharacteristicTags.contains("public.main-program-content")}) ?? group.first(where: { $0.language == language }) {
                    tracks.forEach { $0.isEnabled = false }
                    track.isEnabled = true
                }
            }
        }
        return true
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(language, forKey: "SBQueueChangeAudioLanguageAction")
    }

    required init?(coder aDecoder: NSCoder) {
        guard let language = aDecoder.decodeObject(of: NSString.self, forKey: "SBQueueChangeAudioLanguageAction") as String?
            else { return nil }
        self.language = language
    }

    static var supportsSecureCoding: Bool { return true }

}
/// An action that moves a finished Intake/Queue-workflow release's folder
/// into the "Ready for Media Library" holding folder and marks the
/// release done -- see the release-model doc's section 6 and the parent
/// design doc's 4.7. Attached alongside QueueMetadataAction at the
/// moment a release resolves to a real QueueItem (QueueController's
/// resolveSingleFileRelease(_:)/resolveMergedRelease(_:mergedFileURL:)),
/// so the existing mux engine runs it automatically right after a
/// successful write -- exactly like QueueOptimizeAction/
/// QueueSendToiTunesAction above, with no new completion-observing
/// plumbing needed.
///
/// Stores only releaseID -- never a live QueueRelease reference --
/// because QueueActionProtocol actions are persisted independently as
/// part of QueueItem.actions and decoded on their own after a relaunch;
/// a live Swift reference wouldn't survive that archive/unarchive
/// round-trip (the release-model doc's section 6 calls this out as "the
/// persistence back-reference gotcha"). The actual QueueRelease is
/// instead resolved by ID, at runAction(_:) time, through the owning
/// Queue -- reached via QueueItem.delegate, which Queue.process(_:) sets
/// for the duration of muxing -- rather than through a new standalone
/// coordinator singleton, resolving checklist item t150.
class QueueMoveToLibraryAction: NSObject, QueueActionProtocol {

    private let releaseID: UUID
    private let destinationRoot: URL

    var type: QueueActionType { return .post }
    var localizedDescription: String { return NSLocalizedString("Moving to Ready for Media Library", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Move to Ready for Media Library", comment: "Action description.") }

    init(releaseID: UUID, destinationRoot: URL) {
        self.releaseID = releaseID
        self.destinationRoot = destinationRoot
    }

    /// Moves release.folderURL (the whole release folder, not just the
    /// muxed file) into destinationRoot, reusing
    /// QueueController.uniqueFolderDestination(for:)'s same Finder-style
    /// collision handling ("name", "name 2", \u{2026}) so this never
    /// silently overwrites something already sitting in the library
    /// holding folder. Returns false (leaving the release's stage
    /// unchanged, so nothing here silently reports success) if the
    /// owning release can no longer be found -- e.g. it was somehow
    /// removed from the Queue between mux completion and this running --
    /// or if the move itself fails.
    func runAction(_ item: QueueItem) -> Bool {
        guard let release = item.delegate?.release(withID: releaseID) else { return false }

        // Media Locations tab: the first matching delivery rule's folder, else
        // else the default (staging or Automatically Add) folder.
        let destinationRoot = item.mp4File?.deliveryFolder ?? self.destinationRoot

        let sourceFolder = release.folderURL

        // An Automatically Add to iTunes/TV folder takes the finished file
        // alone, not a folder: iTunes/the TV app ingest and organize it from
        // there. What is left of the release folder (the originals, which
        // "Clean up processed files" can trash) stays behind for the empty
        // folder cleanup.
        if destinationRoot.isAutomaticMediaIngestFolder {
            let finished = item.destURL
            guard FileManager.default.fileExists(atPath: finished.path) else { return false }
            let target = QueueController.uniqueFileDestination(for: destinationRoot.appendingPathComponent(finished.lastPathComponent))
            do {
                try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: finished, to: target)
            } catch {
                NSLog("[FolderSync] FAILED: Queue couldn't move \(finished.lastPathComponent) to \(destinationRoot.path): \(error.localizedDescription)")
                guard let recovered = FolderMoveRecovery.recover(error: error, itemURL: finished, folderName: finished.deletingPathExtension().lastPathComponent, movingWholeFolder: false, partialDestination: target) else {
                    return false
                }
                item.destURL = recovered.appendingPathComponent(finished.lastPathComponent)
                release.stage = .done
                return true
            }
            item.destURL = target

            var originals = release.mergeOrder ?? []
            originals.append(contentsOf: release.sourceFileURLs)
            ProcessedFileCleaner.trashOriginals(originals, oldFolder: sourceFolder, newFolder: sourceFolder, keeping: [])

            release.stage = .done
            return true
        }

        let candidate = destinationRoot.appendingPathComponent(sourceFolder.lastPathComponent)
        let destination = QueueController.uniqueFolderDestination(for: candidate)

        var finalFolder = destination
        do {
            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: sourceFolder, to: destination)
        } catch {
            NSLog("[FolderSync] FAILED: Queue couldn't move \(sourceFolder.lastPathComponent) to Ready for Media Library: \(error.localizedDescription)")
            // Out of space / volume offline: clean up the partial move and
            // let the user pick another location (same flow as Edit+Save).
            guard let recovered = FolderMoveRecovery.recover(error: error, itemURL: sourceFolder, folderName: sourceFolder.lastPathComponent, movingWholeFolder: true, partialDestination: destination) else {
                return false
            }
            finalFolder = recovered
        }

        // Originals that fed the finished file: the merged parts, or a
        // single file's source. The finished file keeps its name.
        var originals = release.mergeOrder ?? []
        originals.append(contentsOf: release.sourceFileURLs)
        let keep: Set<String> = [item.destURL.lastPathComponent]
        // Only once the finished file really exists, and never when a
        // source has the same name as it (an in-place edit).
        if FileManager.default.fileExists(atPath: item.destURL.path)
            || FileManager.default.fileExists(atPath: finalFolder.appendingPathComponent(item.destURL.lastPathComponent).path) {
            ProcessedFileCleaner.trashOriginals(originals, oldFolder: sourceFolder, newFolder: finalFolder, keeping: keep)
        }

        release.folderURL = finalFolder
        release.stage = .done
        return true
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(releaseID.uuidString, forKey: "_releaseID")
        aCoder.encode(destinationRoot, forKey: "_destinationRoot")
    }

    required init?(coder aDecoder: NSCoder) {
        guard let idString = aDecoder.decodeObject(of: [NSString.classForCoder()], forKey: "_releaseID") as? String,
            let id = UUID(uuidString: idString),
            let destinationRoot = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "_destinationRoot") as? URL
        else { return nil }

        self.releaseID = id
        self.destinationRoot = destinationRoot
    }

    static var supportsSecureCoding: Bool { return true }

}

/// Post action for a plain Queue item (one added directly, not through the
/// Intake release pipeline -- see QueueMoveToLibraryAction for those): once
/// the output is written, a movie file that isn't already inside Ready for
/// Media Library gets a new folder of its own there and is moved into it,
/// whether or not it had a parent folder to begin with. The folder is named
/// from the item's metadata when the Movie folder-sync preference gives one,
/// else from the output file's own name (minus the " (merged)" tag the
/// Merge button adds), and numbered Finder-style on a collision. TV shows
/// and files sitting in the iTunes/TV auto-add folder are left alone. Falls
/// back to FolderMoveRecovery (clean up, offer another location) if the move
/// fails, e.g. for lack of space.
class QueueMoveFileToLibraryAction: NSObject, QueueActionProtocol {

    private let destinationRoot: URL

    var type: QueueActionType { return .post }
    var localizedDescription: String { return NSLocalizedString("Moving to Ready for Media Library", comment: "Action localized description.") }
    override var description: String { return NSLocalizedString("Move to Ready for Media Library", comment: "Action description.") }

    init(destinationRoot: URL) {
        self.destinationRoot = destinationRoot
    }

    func runAction(_ item: QueueItem) -> Bool {
        let fileManager = FileManager.default
        let outputURL = item.destURL
        guard fileManager.fileExists(atPath: outputURL.path) else { return false }

        let destinationRoot = item.mp4File?.deliveryFolder ?? self.destinationRoot
        let outputFolder = outputURL.deletingLastPathComponent().standardizedFileURL
        let rootPath = destinationRoot.standardizedFileURL.path

        // Already in a folder of its own inside the destination.
        if outputFolder.path.hasPrefix(rootPath + "/") { return true }
        if outputFolder.isAutomaticMediaIngestFolder { return true }

        // Delivery to an Automatically Add folder: the file alone, no folder.
        if destinationRoot.isAutomaticMediaIngestFolder {
            let target = QueueController.uniqueFileDestination(for: destinationRoot.appendingPathComponent(outputURL.lastPathComponent))
            do {
                try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
                try fileManager.moveItem(at: outputURL, to: target)
                item.destURL = target
                return true
            } catch {
                NSLog("[FolderSync] FAILED: Queue couldn't move \(outputURL.lastPathComponent) to \(destinationRoot.path): \(error.localizedDescription)")
                guard let recovered = FolderMoveRecovery.recover(error: error, itemURL: outputURL, folderName: outputURL.deletingPathExtension().lastPathComponent, movingWholeFolder: false, partialDestination: target) else {
                    return false
                }
                item.destURL = recovered.appendingPathComponent(outputURL.lastPathComponent)
                return true
            }
        }

        if let kindValue = item.mp4File?.metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue,
           MediaKind(rawValue: kindValue) == .tvShow {
            return true
        }

        let stem = outputURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " (merged)", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = item.mp4File?.preferredOutputSubfolder() ?? stem
        guard folderName.isEmpty == false else { return true }

        let folder = QueueController.uniqueFolderDestination(for: destinationRoot.appendingPathComponent(folderName))
        let target = folder.appendingPathComponent(outputURL.lastPathComponent)

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.moveItem(at: outputURL, to: target)
            item.destURL = target
            NSLog("[FolderSync] Queue moved \(outputURL.lastPathComponent) into new Ready for Media Library folder \(folder.lastPathComponent)")
            return true
        } catch {
            NSLog("[FolderSync] FAILED: Queue couldn't move \(outputURL.lastPathComponent) to Ready for Media Library: \(error.localizedDescription)")
            guard let recovered = FolderMoveRecovery.recover(error: error, itemURL: outputURL, folderName: folderName, movingWholeFolder: false, partialDestination: folder) else {
                return false
            }
            item.destURL = recovered.appendingPathComponent(outputURL.lastPathComponent)
            return true
        }
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(destinationRoot, forKey: "_destinationRoot")
    }

    required init?(coder aDecoder: NSCoder) {
        guard let destinationRoot = aDecoder.decodeObject(of: [NSURL.classForCoder()], forKey: "_destinationRoot") as? URL
        else { return nil }
        self.destinationRoot = destinationRoot
    }

    static var supportsSecureCoding: Bool { return true }

}

/// An action that changes the 'enabled' subtitle  track to the language preferred, if a track labeled with that language exists
class QueueChangeSubtitleLanguageAction : NSObject, QueueActionProtocol {

    var type: QueueActionType { return .pre }
    var localizedDescription: String { return NSLocalizedString("Enabling subtitles track with selected language", comment: "Enable subtitles track local description") }
    override var description: String { return NSLocalizedString("Enabling subtitles track with selected language", comment: "Enable subtitles track action description") }

    let language: String

    init(language: String) {
        self.language = language
    }

    func runAction(_ item: QueueItem) -> Bool {
        if let tracks = item.mp4File?.tracks.filter({ $0.mediaType == kMP42MediaType_Subtitle || $0.mediaType == kMP42MediaType_ClosedCaption}) {
            let groups = Dictionary(grouping: tracks, by: { $0.alternateGroup })
            for (_, group) in groups {
                if let track = group.first(where: { $0.language == language && $0.mediaCharacteristicTags.contains("public.main-program-content")}) ?? group.first(where: { $0.language == language }) {
                    tracks.forEach { $0.isEnabled = false }
                    track.isEnabled = true
                }
            }
        }
        return true
    }

    func encode(with aCoder: NSCoder) {
        aCoder.encode(language, forKey: "SBQueueChangeSubtitleLanguageAction")
    }

    required init?(coder aDecoder: NSCoder) {
        guard let language = aDecoder.decodeObject(of: NSString.self, forKey: "SBQueueChangeSubtitleLanguageAction") as String?
            else { return nil }
        self.language = language
    }

    static var supportsSecureCoding: Bool { return true }
}
