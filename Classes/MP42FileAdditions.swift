//
//  MP42FileAdditions.swift
//  Subler
//
//  Created by Damiano Galassi on 09/10/2017.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Naming and delivery-folder helpers for the Queue and Media Locations; no
//  rename for a file with no title tagged; ignores the merged-file tag.
//

import Foundation
import MP42Foundation

private extension String {
    func condensingWhitespace() -> String {
        return self.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension String {
    /// Drops a pair of brackets or parentheses with nothing inside, and
    /// the space before it, so a name built from a template whose Studio
    /// or Release Date is not known reads "Title (2020)" or "Title", not
    /// "Title [] (2020)" or "Title [] ()".
    func removingEmptyBrackets() -> String {
        var result = self
        while let range = result.range(of: #"\s*(\[\s*\]|\(\s*\))"#, options: .regularExpression) {
            result.replaceSubrange(range, with: "")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

extension MetadataSearchTerms {
    /// Search terms for an approved release name ("Title Vol N [Studio] (Year)"
    /// or a scene-style name): just the bare title, or series/season/episode.
    static func fromReleaseName(_ name: String) -> MetadataSearchTerms {
        if let parsed = ReleaseFilenameParser.parse(name) {
            if let season = parsed.season, let episode = parsed.episode {
                return .tvShow(seriesName: parsed.title, season: season, episode: episode)
            }
            return .movie(title: parsed.title)
        }
        if let title = ReleaseFilenameParser.titleWithoutBrackets(name) {
            return .movie(title: title)
        }
        return .movie(title: ReleaseFilenameParser.normalizedDelimiters(name))
    }
}

extension MP42File {

    enum TrackHDType : Int {
        case hd720p = 1
        case hd1080p = 2
        case hd4k = 3
    }

    var hdType: TrackHDType? {
        for track in tracks(withMediaType: kMP42MediaType_Video) as! [MP42VideoTrack] {
            if (track.width > 1920 && track.height > 1088) {
                return Prefs.set4KHDVideoMetadata ? .hd4k : nil
            } else if (track.width > 1280 || track.height > 720) && track.width <= 1920 && track.height <= 1088 {
                return .hd1080p
            } else if track.width >= 960 && track.height >= 720 || track.width >= 1280 {
                return .hd720p
            }
        }
        return nil
    }

    var firstSourceURL: URL? { tracks.lazy.compactMap { $0.url }.first }

    func extractSearchTerms(fallbackURL: URL?) -> MetadataSearchTerms {
        if let tvShow = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVShow).first?.stringValue,
            let season = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVSeason).first?.numberValue?.intValue,
            let number = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVEpisodeNumber).first?.numberValue?.intValue,
            let mediaKind = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue,
            mediaKind == MediaKind.tvShow.rawValue {
            return MetadataSearchTerms.tvShow(seriesName: tvShow, season: season, episode: number)
        }
        else if let title = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
            let _ = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyReleaseDate).first?.stringValue,
            let mediaKind = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue,
            mediaKind == MediaKind.movie.rawValue {
            return MetadataSearchTerms.movie(title: title)
        }
        else if let sourceURL = firstSourceURL ?? self.url ?? fallbackURL {
            // MP42File (and so its tracks) keep their URL as a file
            // *reference* URL ("file:///.file/id=..."), whose
            // lastPathComponent isn't the file's name -- rebuild a plain
            // path URL first so the name below is the real one. Matters
            // most for a freshly merged file opened via Queue > Edit,
            // which is an untitled document with no fileURL of its own.
            // Also drop the " (merged)" tag the Queue's Merge button
            // appends to its output's name -- it isn't part of the title.
            let mergedTag = " (merged)"
            let plainURL = URL(fileURLWithPath: sourceURL.path)
            let cleanedName = plainURL.lastPathComponent.replacingOccurrences(of: mergedTag, with: "", options: .caseInsensitive)
            let url = plainURL.deletingLastPathComponent().appendingPathComponent(cleanedName)
            // Try ReleaseFilenameParser first, ahead of the bundled Perl
            // parser (Video::Filename) below: it's built specifically
            // for this app's own "Title [Studio] (Year)" naming
            // convention -- both a scene-style release name and this
            // app's own merged/renamed output use it -- and it only ever
            // hands back the bare title (or series/season/episode),
            // never the studio or year, so the search field always ends
            // up with just the movie name to search on. The bundled
            // parser recognizes a bare "(Year)" group fine, but doesn't
            // know a "[Studio]" group next to it is a separate field, so
            // on a name like "Title [Studio] (Year)" (e.g. a freshly
            // merged file, still named after its release before any
            // metadata/search has run) it leaves the studio name sitting
            // right in the title it hands back.
            if let releaseParsed = ReleaseFilenameParser.parse(url.lastPathComponent) {
                if let season = releaseParsed.season, let episode = releaseParsed.episode {
                    return MetadataSearchTerms.tvShow(seriesName: releaseParsed.title, season: season, episode: episode)
                }
                return MetadataSearchTerms.movie(title: releaseParsed.title)
            }

            // No year/episode/quality marker, but a "[Studio]" group: use
            // just the title in front of it (see titleWithoutBrackets).
            if let bracketTitle = ReleaseFilenameParser.titleWithoutBrackets(url.lastPathComponent) {
                return MetadataSearchTerms.movie(title: bracketTitle)
            }

            let parsed = url.deletingPathExtension().lastPathComponent.parsedAsFilename()

            switch parsed {
            case .none:
                let title = url.deletingPathExtension().lastPathComponent
                return MetadataSearchTerms.movie(title: title)

            case .tvShow, .movie:
                return parsed
            }
        }
        return MetadataSearchTerms.none
    }

    // MARK: File name

    func preferredFileName() -> String? {
        if let mediaKindValue = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue,
            MediaKind(rawValue: mediaKindValue) != nil,
            let name = formattedFileName() {
            return name
        } else {
            return tracks.compactMap { $0.url }.first?.deletingPathExtension().lastPathComponent
        }
    }

    /// Builds a file name from the "Filename" preferences tab's settings --
    /// the first matching rule in MetadataPrefs.movieNamingRules or
    /// MetadataPrefs.tvShowNamingRules depending on this file's media kind
    /// (an ordered list of conditional Token templates, e.g. "if Rating is
    /// Explicit, use Title [Studio] (Year)", falling back to a Default rule
    /// -- see NamingRules.swift and the Filename preferences tab). This is
    /// the single naming function every output-naming call site shares:
    /// Save As's suggested name (via preferredFileName() above), the
    /// Queue's "Set output filename" action, and Document's own
    /// rename-after-save.
    func formattedFileName() -> String? {
        guard let mediaKindValue = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue,
              let mediaKind = MediaKind(rawValue: mediaKindValue)
            else { return nil }

        // A movie with no title tagged yet (e.g. saved before any
        // metadata search was run) would otherwise be named from an
        // all-blank template -- "[] ()" -- renaming the file and creating
        // a folder with that name. Leave the name alone instead.
        if mediaKind == .movie {
            let title = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue ?? ""
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("[NamingRules] formattedFileName: movie has no title tagged -- leaving filename and folder alone")
                return nil
            }
        }

        let rules: [NamingRule]
        switch mediaKind {
        case .tvShow:
            rules = MetadataPrefs.tvShowNamingRules
        case .movie:
            rules = MetadataPrefs.movieNamingRules
        }

        guard let tokens = rules.matchingTokens(for: metadata) else {
            // Every one of this media kind's conditional rules failed to
            // match, and the Default rule is either missing or disabled
            // -- see NamingRule.matchingTokens(for:). A rule that depends
            // on a field like Content Rating only matches once that
            // field is actually tagged to the expected value, so this is
            // the line to check in Console.app when a save isn't
            // renaming a file the way the Filename tab seems to say it
            // should.
            NSLog("[NamingRules] formattedFileName: no naming rule matched for mediaKind=\(mediaKind) -- leaving filename alone")
            return nil
        }
        let name = MP42File.formattedName(tokens: tokens, metadata: metadata)
        NSLog("[NamingRules] formattedFileName: mediaKind=\(mediaKind) formatted name = \(name ?? "nil")")
        return name
    }

    /// The relative subfolder path this file's output should be nested
    /// under, driven by the "Filename" preferences tab's own per-media-kind
    /// toggle -- nil whenever that toggle is off, there isn't enough tagged
    /// metadata to build the path, or this isn't a Movie/TV Show file at
    /// all, in which case the caller should leave its existing destination
    /// folder alone:
    ///
    /// - Movie (Prefs.syncMovieFolderNameOnSave): just the formatted
    ///   filename itself, e.g. "Title (Year)" -- a Plex/iTunes-style
    ///   one-folder-per-movie layout ("Title (Year)/Title (Year).mp4").
    /// - TV Show (Prefs.useAppleTVStyleTVFolders): "<TV Show>/Season NN",
    ///   matching the layout Apple's TV app and Plex both expect for a TV
    ///   library ("Breaking Bad/Season 01/Breaking Bad - s01e01 - Pilot.m4v").
    ///
    /// Path components are sanitized for "/" (the one character that can't
    /// appear in a single path component) since a tagged TV Show name is
    /// free text and could theoretically contain one.
    func preferredOutputSubfolder() -> String? {
        guard let mediaKindValue = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue,
              let mediaKind = MediaKind(rawValue: mediaKindValue)
            else {
                NSLog("[FolderSync] preferredOutputSubfolder: no Media Kind tagged -- skipping")
                return nil
            }

        func sanitized(_ component: String) -> String {
            return component.replacingOccurrences(of: "/", with: "-")
        }

        switch mediaKind {
        case .movie:
            guard Prefs.syncMovieFolderNameOnSave else {
                NSLog("[FolderSync] preferredOutputSubfolder: Movie folder sync preference is off -- skipping")
                return nil
            }
            guard let name = formattedFileName(), name.isEmpty == false else {
                NSLog("[FolderSync] preferredOutputSubfolder: formattedFileName() returned nil/empty -- skipping")
                return nil
            }
            NSLog("[FolderSync] preferredOutputSubfolder: Movie target folder name = \(sanitized(name))")
            return sanitized(name)

        case .tvShow:
            guard Prefs.useAppleTVStyleTVFolders else {
                NSLog("[FolderSync] preferredOutputSubfolder: TV folder sync preference is off -- skipping")
                return nil
            }
            guard let show = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVShow).first?.stringValue, show.isEmpty == false,
                  let season = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVSeason).first?.numberValue?.intValue
                else {
                    NSLog("[FolderSync] preferredOutputSubfolder: missing TV Show name or Season number -- skipping")
                    return nil
                }
            let seasonFolderName = String(format: NSLocalizedString("Season %02d", comment: "Apple TV-style TV season folder name"), season)
            let result = "\(sanitized(show))/\(seasonFolderName)"
            NSLog("[FolderSync] preferredOutputSubfolder: TV target subfolder = \(result)")
            return result
        }
    }

    /// Formats `tokens` against `metadata`, one value per placeholder token
    /// with everything else (literal tokens) inserted verbatim. A single
    /// space is inserted between two placeholder tokens that sit directly
    /// next to each other with no literal token in between -- e.g. a Movie
    /// template of {Name}{Studio}{Release Date} (three placeholders with no
    /// separating literal text at all) used to concatenate every value with
    /// nothing between them ("Sample Movie 7Example Studio2019"
    /// instead of "Sample Movie 7 Example Studio 2019") -- this only
    /// kicks in between two placeholders with nothing at all separating
    /// them, so a template that already inserts its own literal separator
    /// (the default TV Show template's " s"/"e" between {TV Season} and
    /// {TV Episode #}, or a Movie rule's own "[", "] (", ")" literals) is
    /// completely unaffected.
    static func formattedName(tokens: [Token], metadata: MP42Metadata) -> String? {
        let separators = CharacterSet(charactersIn: "{}")
        var name = ""
        var previousTokenWasPlaceholderValue = false

        for token in tokens {
            if token.isPlaceholder {
                let trimmedToken = token.text.trimmingCharacters(in: separators)
                let metadataItems = metadata.metadataItemsFiltered(byIdentifier: trimmedToken)

                if let item = metadataItems.first {
                    let value = token.format(metadataItem: item)
                    if value.isEmpty == false {
                        if previousTokenWasPlaceholderValue && name.hasSuffix(" ") == false {
                            name.append(" ")
                        }
                        name.append(value)
                        previousTokenWasPlaceholderValue = true
                    }
                }
            } else {
                name.append(token.text)
                previousTokenWasPlaceholderValue = false
            }
        }

        name = name.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "/", with: "-").condensingWhitespace().removingEmptyBrackets()

        return name.isEmpty ? nil : name
    }
}

extension MP42AudioTrack {

    var outputChannels: UInt32 {
        if let cs = conversionSettings as? MP42AudioConversionSettings {
            if cs.mixDown == kMP42AudioMixdown_Mono || channels == 1 {
                return 1
            } else if cs.mixDown == kMP42AudioMixdown_None {
                return channels
            } else {
                return 2
            }
        } else {
            return channels
        }
    }

    var prettyTrackName: String {
        let channelCount = outputChannels

        // Use channel count to determine track name
        if channelCount == 1 {
            return NSLocalizedString("Mono Audio", comment: "")
        } else if channelCount == 2 {
            return NSLocalizedString("Stereo Audio", comment: "")
        } else {
            return NSLocalizedString("Surround Audio", comment: "")
        }
    }
}

extension MP42MetadataItem {

    /// Whether this item should be treated as "not really set" for the
    /// purposes of the Append/Overwrite metadata preference -- used by
    /// both the in-editor Sets menu (MovieViewController.applySet(_:))
    /// and the Queue's "Apply Set" automation action (QueueSetAction)
    /// so the two stay in sync.
    ///
    /// Integer/Bool metadata items (Content Rating, Media Kind, HD
    /// Video, TV Season/Episode, Beats Per Minute, the various provider
    /// ID fields, Gapless, iTunes U, Podcast, ...) are auto-created at
    /// 0/false by MP42MetadataItem's own dataType resolution the moment
    /// an identifier is touched, even when nothing meaningful has ever
    /// been set -- so a plain "is stringValue empty" check sees them as
    /// already occupied and incorrectly blocks a Set's own value from
    /// ever applying. None of these fields have a meaningful "the user
    /// deliberately chose zero/false" case worth protecting the way a
    /// real non-zero number or a checked box would be.
    var isEffectivelyEmpty: Bool {
        switch dataType {
        case .integer, .bool:
            return (numberValue?.intValue ?? 0) == 0
        default:
            break
        }
        if let string = stringValue { return string.isEmpty }
        if let array = arrayValue { return array.isEmpty }
        return value == nil
    }
}
