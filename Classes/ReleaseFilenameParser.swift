//
//  ReleaseFilenameParser.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/26/2026.
//
//  Parses scene-style release filenames (the naming convention widely
//  used by scene/release groups, regardless of how a given file actually
//  arrived) into a clean, human-readable name, using NSRegularExpression
//  against the standard scene naming conventions -- fields delimited by
//  periods or underscores, a 4-digit year and/or an SxxEyy episode
//  marker, then quality/source/codec tags and often a release-group tag,
//  all of which come after whichever of those markers appears first in
//  the name. Everything from that marker onward is discarded; everything
//  before it is treated as the title.
//
//  This is a heuristic, not a full reimplementation of something like
//  Python's PTN -- it's deliberately conservative: if nothing that looks
//  like a release marker is found, parse(_:) returns nil and the caller
//  is expected to leave the file's name untouched rather than guess.
//

import Foundation
import MP42Foundation

/// The result of parsing a scene-style release filename.
struct ParsedMediaName {
    /// The cleaned-up title, e.g. "The Matrix" or "Breaking Bad".
    let title: String
    /// The release year, if one was found in the filename (movies).
    let year: String?
    /// Season number, if an SxxEyy-style marker was found (TV).
    let season: Int?
    /// Episode number, if an SxxEyy-style marker was found (TV).
    let episode: Int?
    /// A per-file sequence/scene number, if one was found (see
    /// ReleaseFilenameParser.extractSequence(_:excluding:)) -- for a
    /// release that's split across several similarly-named files (e.g. a
    /// multi-scene release folder), this is what tells them apart once
    /// they're all renamed to the same title.
    let sequence: Int?
    /// A studio/site name, if one was found sharing a bracket or
    /// parenthesis group with the release year (e.g. "Studio Name" out of
    /// "[Studio.Name.2023]") -- see
    /// ReleaseFilenameParser.maskBracketsAndParens(in:). When present,
    /// cleanedFileName below follows the "Title Version [Studio] (Year)"
    /// convention instead of the plain "Title (Year)" one.
    let studio: String?
    /// The original file extension, preserved as-is.
    let fileExtension: String

    init(title: String, year: String? = nil, season: Int? = nil, episode: Int? = nil, sequence: Int? = nil, studio: String? = nil, fileExtension: String) {
        self.title = title
        self.year = year
        self.season = season
        self.episode = episode
        self.sequence = sequence
        self.studio = studio
        self.fileExtension = fileExtension
    }

    /// A copy with a different sequence number -- used when a file turns
    /// out to share its release folder with others and needs an explicit
    /// "1" instead of no number at all, so a multi-file release comes out
    /// consistently numbered 1, 2, 3, ... instead of one file with no
    /// number and the rest starting from 2. See
    /// MediaIntakeManagerViewController.assignImplicitFirstSequence.
    func withSequence(_ newSequence: Int?) -> ParsedMediaName {
        ParsedMediaName(title: title, year: year, season: season, episode: episode,
                         sequence: newSequence, studio: studio, fileExtension: fileExtension)
    }

    /// A clean, display-ready file name, with the original extension
    /// re-appended.
    var cleanedFileName: String {
        let name: String
        if let season = season, let episode = episode {
            name = String(format: "%@ S%02dE%02d", title, season, episode)
        } else if let studio = studio {
            // "Title Version [Studio] (Year)" -- Version is the per-file
            // sequence number when there is one, and the year is included
            // whenever known. Used whenever a studio name was found
            // alongside a year in a bracket or parenthesis group, see
            // ReleaseFilenameParser.maskBracketsAndParens(in:).
            var parts = [title]
            if let sequence = sequence {
                parts.append("\(sequence)")
            }
            parts.append("[\(studio)]")
            if let year = year {
                parts.append("(\(year))")
            }
            name = parts.joined(separator: " ")
        } else if let year = year {
            if let sequence = sequence {
                name = "\(title) (\(year)) \(sequence)"
            } else {
                name = "\(title) (\(year))"
            }
        } else if let sequence = sequence {
            name = "\(title) \(sequence)"
        } else {
            name = title
        }
        return fileExtension.isEmpty ? name : "\(name).\(fileExtension)"
    }

    /// The name of the folder a release's files should be consolidated
    /// into once approved -- title, studio (when one was found -- see
    /// ReleaseFilenameParser.maskBracketsAndParens(in:)), and year, with
    /// no sequence number (every file belonging to the same release
    /// shares this one folder). Matches cleanedFileName's convention:
    /// "Title [Studio] (Year)" when there's a studio, plain
    /// "Title (Year)" for a movie without one. See
    /// MediaIntakeManagerViewController.renameInPlace.
    var movieFolderName: String {
        if let studio = studio {
            if let year = year {
                return "\(title) [\(studio)] (\(year))"
            }
            return "\(title) [\(studio)]"
        }
        if let year = year {
            return "\(title) (\(year))"
        }
        return title
    }
}

enum ReleaseFilenameParser {

    private static let yearRegex = try! NSRegularExpression(pattern: "(?:19|20)\\d{2}")
    private static let episodeRegex = try! NSRegularExpression(pattern: "[Ss](\\d{1,2})[Ee](\\d{1,3})")
    private static let altEpisodeRegex = try! NSRegularExpression(pattern: "(\\d{1,2})[xX](\\d{1,3})")
    // Square brackets are always noise to strip. Parentheses are handled
    // separately (see parenthesizedRegex below) and more conservatively,
    // since a parenthesized number right after the title is almost
    // always the release year itself (e.g. "Mutiny (2026)") -- stripping
    // every parenthesized group unconditionally would delete the very
    // thing yearRegex is looking for.
    private static let bracketedRegex = try! NSRegularExpression(pattern: "\\[[^\\[\\]]*\\]")

    // A non-nested parenthesized group, e.g. "(2026)" or "(Studio Name
    // 2023)" -- see maskBracketsAndParens(in:) for how this is handled
    // differently from a bracketed one.
    private static let parenthesizedRegex = try! NSRegularExpression(pattern: "\\([^()]*\\)")

    // A day.month.year-style upload/scene date, e.g. "22.11.2025" --
    // never a sequence number, and its day/month components would
    // otherwise look exactly like one once periods are normalized to
    // spaces. Digit-bounded (not letter-bounded) since a date never
    // butts up against a digit on either side, but IS sometimes preceded
    // by a delimiter that already got normalized away by the time this
    // runs -- see extractSequence(_:excluding:).
    private static let dateRegex = try! NSRegularExpression(pattern: "(?<!\\d)\\d{1,2}[._-]\\d{1,2}[._-]\\d{2,4}(?!\\d)")

    // A leading "<date>_<uploader>_" stamp, e.g. "26.09.2026_Uploader_Sample
    // Title..." -- several release sources
    // tack the uploader's own handle on as a second field immediately
    // after the upload date, with nothing to tell it apart from the real
    // title except its position. dateRegex alone only ever stripped the
    // date itself, leaving the uploader handle sitting right at the front
    // of the extracted title ("Uploader Sample Title 393 ..." instead
    // of "Sample Title 393 ..."). Masked as a whole -- date AND the
    // single word right after it -- before dateRegex gets a chance to
    // run. Deliberately anchored to the very start of the name and to
    // exactly one bare word: a release's real title essentially never
    // opens with "<date>_<oneWord>_", so this only ever fires on the
    // upload-stamp convention it's meant for, and leaves an ordinary
    // leading date (with no single-word field after it) for dateRegex to
    // handle exactly as before.
    private static let leadingDateUploaderRegex = try! NSRegularExpression(pattern: "^\\d{1,2}[._-]\\d{1,2}[._-]\\d{2,4}[._-][A-Za-z][A-Za-z0-9]*[._-]")

    // The same upload stamp with only a year in place of the full date,
    // e.g. "2026_Uploader_Sample Title 29_Example Studio_480p".
    // Only ever used by stampedSceneFields(_:), whose other requirements
    // (a trailing quality tag, at least two fields in front of it, a
    // space inside a field) keep an ordinary "2001_A_Space_Odyssey_1080p"
    // style name from being read this way. Not used by the generic
    // masking, where a bare leading year is just a year.
    private static let leadingYearUploaderRegex = try! NSRegularExpression(pattern: "^(?:19|20)\\d{2}[._-][A-Za-z][A-Za-z0-9]*[._-]")

    // A decimal audio channel count, e.g. "5.1", "2.0", "7.1.4" -- these
    // are very often glued directly onto a codec name with no delimiter
    // (e.g. "AAC5.1", "DD5.1"), so only the digit side of the boundary is
    // checked, not the letter side.
    private static let channelSpecRegex = try! NSRegularExpression(pattern: "(?<!\\d)\\d\\.\\d(?:\\.\\d)?(?!\\d)")

    // A standalone 1-2 digit number for extractSequence(_:excluding:)
    // -- bounded against letters AND digits on both sides (not just \b,
    // which doesn't treat "_" as a boundary), so this never matches a
    // digit embedded in a stylized word (e.g. the "4" in "Sample4") or part
    // of an SxxEyy marker (e.g. the "01" in "S01E05").
    private static let bareNumberRegex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])\\d{1,2}(?![A-Za-z0-9])")

    // Common quality/source/codec release tags -- excluded from the
    // bracket-immediately-before-a-bare-year studio heuristic in
    // maskBracketsAndParens(in:), so a name like "Title [1080p] (2024)"
    // doesn't get "1080p" mistaken for a studio just because it happens
    // to sit next to the year. Not exhaustive by design -- this only
    // needs to catch tags that could plausibly land directly next to a
    // parenthesized year; anything else is still caught by that
    // heuristic requiring the two groups to be truly adjacent.
    private static let qualityTagRegex = try! NSRegularExpression(
        pattern: "^(?:\\d{3,4}[pk]|4k|8k|web[- ]?(?:dl|rip)?|hdtv|blu[- ]?ray|dvd(?:rip|scr)?|x26[45]|h26[45]|hevc|aac(?:\\d(?:\\.\\d)?)?|dts(?:-hd)?|ac3|remux|proper|repack|extended|unrated|limited|internal|retail)$",
        options: .caseInsensitive)

    private static func looksLikeQualityTag(_ candidate: String) -> Bool {
        let range = NSRange(candidate.startIndex..., in: candidate)
        return qualityTagRegex.firstMatch(in: candidate, range: range) != nil
    }

    // Same family of quality/source/codec tags as qualityTagRegex above,
    // but searched for ANYWHERE in the working string (with explicit
    // digit/letter boundaries instead of qualityTagRegex's whole-token
    // anchors) plus "XXX" -- a marketing tag found on some
    // releases. This is what lets parse(_:) still find a sensible title
    // cutoff for a scene-style release name that carries no year and no
    // SxxEyy marker at all (common for some releases, e.g.
    // "Sample.Movie.7.XXX.720p.WEBRip.x264-Group" has no
    // year anywhere in it) -- without this, such a name fell all the way
    // through to parse(_:) returning nil, leaving every quality/codec/
    // release-group tag (and the leading dots) in the title untouched.
    private static let releaseMarkerRegex = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])(?:XXX|\\d{3,4}[pk]|4[Kk]|8[Kk]|WEB[- ]?(?:DL|Rip)?|HDTV|Blu[- ]?Ray|BRRip|DVD(?:Rip|Scr)?|x26[45]|h26[45]|HEVC|AAC(?:\\d(?:\\.\\d)?)?|DTS(?:-HD)?|AC3|REMUX|PROPER|REPACK|EXTENDED|UNRATED|LIMITED|INTERNAL|RETAIL)(?![A-Za-z0-9])",
        options: .caseInsensitive)

    /// Every "." / "_" / "-" in a scene-release name is just a word
    /// separator, never meaningful punctuation -- shared by every entry
    /// point below (and by maskBracketsAndParens(in:)'s own studio-name
    /// cleanup) so there's one place to teach a new separator character
    /// to, instead of several copies that can quietly drift apart.
    ///
    /// Not private: also reused directly by the raw-name fallback
    /// branches in FileMerger.suggestedDestinationName(for:) and
    /// NamingReviewWindowController (localGuess/beginSearch) for when
    /// parse(_:) itself returns nil (nothing that looks like a release
    /// year/episode/quality marker at all) and those callers fall back
    /// to an untouched folder/file name -- that raw name should still
    /// never show a "_" or "-" to the user, even though it never goes
    /// through parse(_:)'s title-casing. Collapses any run of separators
    /// (e.g. "_-_", "--") down to a single space instead of leaving
    /// stray double spaces, and trims the ends.
    static func normalizedDelimiters(_ string: String) -> String {
        let collapsed = string
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return collapsed
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The shared first pass for both parse(_:) and
    /// extractSequence(_:excluding:): mask an audio-channel spec (e.g.
    /// "5.1", "7.1.4"), a leading "<date>_<uploader>_" stamp
    /// (leadingDateUploaderRegex above, e.g. "26.09.2026_Uploader_..."),
    /// and a plain date stamp (dateRegex above, e.g. "22-11-2025_WEBDL_..."
    /// -- any of the three separator styles), then normalize whatever
    /// delimiters are left. Channel-spec masking runs first specifically
    /// so a channel spec sitting directly in front of a real year (e.g.
    /// "Movie.Name.5.1.2023.1080p") can't be swallowed into a false
    /// three-part date match together with that year, and the
    /// leading-date-and-uploader mask runs before the plain date mask so
    /// it gets first claim on a date it recognizes as having an uploader
    /// handle attached, rather than leaving that handle for dateRegex's
    /// narrower match to skip over. Before dateRegex existed, a date
    /// stamp's own year read as the release year and cut the "title"
    /// down to just its leading day/month numbers -- see the live
    /// example that prompted this in the project notes ("25 09 (2026)"
    /// from "25.09.2026_Uploader_Sample Title..."); before
    /// leadingDateUploaderRegex existed, the uploader's own handle
    /// (e.g. "Uploader") was left sitting at the front of the title that
    /// masking produced. A filename that's nothing but a bare date stamp
    /// (e.g. a downloader-generated screenshot "25.09.2026.jpg") masks
    /// down to nothing and correctly falls through parse(_:) as "no
    /// title information here" rather than parsing into a fabricated
    /// one.
    private static func maskNoiseAndNormalizeDelimiters(_ string: String) -> String {
        var working = replaceMatches(channelSpecRegex, in: string, with: " ")
        working = replaceMatches(leadingDateUploaderRegex, in: working, with: " ")
        working = replaceMatches(dateRegex, in: working, with: " ")
        return normalizedDelimiters(working)
    }

    /// Parses a raw file name (with or without extension) into a
    /// ParsedMediaName. Returns nil if nothing that looks like a scene
    /// release pattern (a year or an SxxEyy/1x08-style marker) was found --
    /// callers should treat that as "doesn't need cleanup" and leave the
    /// name untouched.
    static func parse(_ filename: String) -> ParsedMediaName? {
        let ext = (filename as NSString).pathExtension
        let baseName = ext.isEmpty ? filename : (filename as NSString).deletingPathExtension

        // "<date>_<uploader>_<Title>_<Studio>_<quality>" upload names carry
        // the studio as their own "_"-delimited field, which the generic
        // path below can't see once it has turned every "_" into a space.
        if let stamped = stampedSceneFields(baseName) {
            return ParsedMediaName(title: cleanedTitle(stamped.title), year: nil, studio: stamped.studio, fileExtension: ext)
        }

        var working = maskNoiseAndNormalizeDelimiters(baseName)

        // Strip bracketed/parenthesized noise tags (release group,
        // quality, site name, etc.) -- except that some scene
        // releases fold a studio name AND the release year into one
        // bracket or parenthesis group (e.g. "[Studio.Name.2023]");
        // stripping that wholesale would silently throw both the year
        // and the studio name away, so a year found alongside other text
        // in such a group is kept in place, and the other text is
        // captured as the studio name (see ParsedMediaName.studio).
        let masked = maskBracketsAndParens(in: working)
        working = masked.text
        let studio = masked.studio

        let fullRange = NSRange(working.startIndex..., in: working)

        var season: Int?
        var episode: Int?
        var markerRange: NSRange?

        if let match = episodeRegex.firstMatch(in: working, range: fullRange),
           let seasonRange = Range(match.range(at: 1), in: working),
           let episodeRange = Range(match.range(at: 2), in: working) {
            season = Int(working[seasonRange])
            episode = Int(working[episodeRange])
            markerRange = match.range
        } else if let match = altEpisodeRegex.firstMatch(in: working, range: fullRange),
                  let seasonRange = Range(match.range(at: 1), in: working),
                  let episodeRange = Range(match.range(at: 2), in: working) {
            season = Int(working[seasonRange])
            episode = Int(working[episodeRange])
            markerRange = match.range
        }

        var year: String?
        var yearRange: NSRange?
        if let match = yearRegex.firstMatch(in: working, range: fullRange), let range = Range(match.range, in: working) {
            year = String(working[range])
            yearRange = match.range
        }

        // A quality/source/codec (or "XXX") release tag, used as a last-
        // resort cutoff when there's no year and no season/episode marker
        // at all -- see releaseMarkerRegex above.
        var releaseMarkerRange: NSRange?
        if let match = releaseMarkerRegex.firstMatch(in: working, range: fullRange) {
            releaseMarkerRange = match.range
        }

        // Nothing that looks like a scene release marker -- don't touch it.
        guard markerRange != nil || yearRange != nil || releaseMarkerRange != nil else { return nil }

        // The title is everything before whichever marker (season/
        // episode, year, or a quality/source/codec release tag) comes
        // first in the string.
        let cutRange = [markerRange, yearRange, releaseMarkerRange]
            .compactMap { $0 }
            .min { $0.location < $1.location }!

        guard let cutIndex = Range(cutRange, in: working)?.lowerBound else { return nil }
        let title = cleanedTitle(String(working[working.startIndex..<cutIndex]))

        guard title.isEmpty == false else { return nil }

        return ParsedMediaName(title: title, year: year, season: season, episode: episode, studio: studio, fileExtension: ext)
    }

    /// (The date may also be just a four-digit year, e.g.
    /// "2026_Uploader_<Title>_<Studio>_480p" -- see leadingYearUploaderRegex.)
    ///
    /// Splits the "<date>_<uploader>_<Title>_<Studio>_<quality>" upload
    /// convention (e.g. "03.10.2026_Uploader_Sample Title_Example
    /// Studio_720p") into a title and a studio, using the "_" characters
    /// as field delimiters -- which is exactly what the generic path in
    /// parse(_:) throws away, so without this the studio's words ended up
    /// glued onto the end of the title ("Sample Title Example Studio")
    /// and a metadata search on that title found nothing.
    ///
    /// Deliberately conservative, since plenty of scene names use "_" as
    /// a plain word separator ("Clemence_Audiard_Vol_6_1440p"): only fires
    /// when (1) the name starts with the leading date+uploader stamp
    /// (leadingDateUploaderRegex), (2) the fields after it end with at
    /// least one quality/source tag, (3) at least two fields remain in
    /// front of the quality tags, (4) at least one of the title/studio
    /// fields contains a literal space (the "spaces inside fields,
    /// underscores between fields" style), and (5) nothing in the title
    /// fields looks like a year or SxxEyy marker, which the generic path
    /// should keep handling. The upload date's own year is intentionally
    /// not used as the release year. Returns nil otherwise.
    private static func stampedSceneFields(_ baseName: String) -> (title: String, studio: String)? {
        let fullRange = NSRange(baseName.startIndex..., in: baseName)
        guard let stamp = leadingDateUploaderRegex.firstMatch(in: baseName, range: fullRange)
                ?? leadingYearUploaderRegex.firstMatch(in: baseName, range: fullRange),
              let stampRange = Range(stamp.range, in: baseName) else { return nil }

        var fields = baseName[stampRange.upperBound...]
            .components(separatedBy: "_")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }

        var sawQualityTag = false
        while let last = fields.last, looksLikeQualityTag(last) {
            fields.removeLast()
            sawQualityTag = true
        }
        guard sawQualityTag, fields.count >= 2 else { return nil }

        let studioField = fields[fields.count - 1]
        let titleFields = Array(fields.dropLast())

        guard studioField.contains(" ") || titleFields.contains(where: { $0.contains(" ") }) else { return nil }

        let titleRaw = titleFields.joined(separator: " ")
        let titleRange = NSRange(titleRaw.startIndex..., in: titleRaw)
        guard yearRegex.firstMatch(in: titleRaw, range: titleRange) == nil,
              episodeRegex.firstMatch(in: titleRaw, range: titleRange) == nil,
              altEpisodeRegex.firstMatch(in: titleRaw, range: titleRange) == nil else { return nil }

        let studio = normalizedDelimiters(studioField)
        let title = normalizedDelimiters(titleRaw)
        guard studio.isEmpty == false, title.isEmpty == false else { return nil }
        return (title, studio)
    }

    /// Looks for a standalone 1-2 digit number in a file's own name that
    /// most likely identifies its place in a multi-file release -- e.g.
    /// the "2" in "22.11.2025_WEBDL_Uploader_Sample 2_Example Studio_1080p.mp4",
    /// where a whole release is split across several similarly-named
    /// scene files sharing one release folder. Meant to be called on a
    /// FILE's own base name (no extension) once the release's title/year
    /// have already been established from its enclosing folder -- see
    /// MediaIntakeManagerViewController.parsedName(for:intakeRoot:).
    ///
    /// `excludedNumbers` should include any number already accounted for
    /// elsewhere in the parsed release -- in practice, the numbers
    /// already embedded in the folder-derived title (see
    /// numbersInTitle(_:)). Without this, a release like
    /// "Clemence.Audiard.Vol.6...", whose title ends up "Clemence
    /// Audiard Vol. 6", would re-extract that same "6" as a bogus
    /// "sequence" from a same-named file like
    /// "Clemence_Audiard_Vol_6_1440p.mp4", producing a duplicated
    /// "Vol. 6 6" instead of recognizing the file simply restates the
    /// release's own volume number rather than distinguishing it from
    /// sibling files.
    ///
    /// Returns nil if nothing qualifies -- callers should fall back to
    /// some other way of telling same-titled files apart
    /// (renameInPlace's uniqueDestination(for:) already does this)
    /// rather than guess.
    static func extractSequence(_ baseName: String, excluding excludedNumbers: Set<Int> = []) -> Int? {
        // Mask upload dates and audio channel specs, then normalize
        // delimiters (maskNoiseAndNormalizeDelimiters, shared with
        // parse(_:) above) before anything else gets a chance to chop
        // them into individually-innocent-looking bare numbers.
        var working = maskNoiseAndNormalizeDelimiters(baseName)
        working = maskBracketsAndParens(in: working).text

        let fullRange = NSRange(working.startIndex..., in: working)
        for match in bareNumberRegex.matches(in: working, range: fullRange) {
            guard let range = Range(match.range, in: working), let value = Int(working[range]) else { continue }
            if excludedNumbers.contains(value) { continue }
            return value
        }
        return nil
    }

    // A short letter prefix (1-2 letters) glued directly to 1-3 digits
    // with nothing else in the name around it, e.g. "e1", "p04", "pt12"
    // -- covers a real per-file scene-numbering convention (a bare
    // "e1.mp4"/"p1.mp4" sitting in a release's Split Scenes folder) that
    // extractSequence's stricter digit-boundary rule doesn't catch,
    // since that rule exists specifically to avoid false positives when
    // parsing a whole release title, not a short, standalone per-file
    // name. Anchored to the WHOLE base name so it only ever fires on
    // names this minimal, never as a side effect inside a longer,
    // descriptive filename.
    private static let looseSequenceRegex = try! NSRegularExpression(pattern: "^[A-Za-z]{1,2}0*(\\d{1,3})$")

    /// A narrower, purely pattern-based fallback for callers that
    /// already tried extractSequence(_:excluding:) and got nothing --
    /// currently just MergeReorderWindowController's default merge
    /// order (see its defaultOrder(for:)). Deliberately not folded into
    /// extractSequence itself, and deliberately not retrying
    /// extractSequence internally: a caller that already excluded some
    /// numbers (e.g. ones restated from a release title) did so for a
    /// reason, and this fallback should never re-surface one of those
    /// through a different code path. Only matches the letter+digit
    /// pattern described at looseSequenceRegex above.
    static func looseSequence(_ baseName: String) -> Int? {
        let range = NSRange(baseName.startIndex..., in: baseName)
        guard let match = looseSequenceRegex.firstMatch(in: baseName, range: range),
              let numberRange = Range(match.range(at: 1), in: baseName) else {
            return nil
        }
        return Int(baseName[numberRange])
    }

    /// A best-effort canonical release name for `name` (a file or
    /// folder's own base name), in the project's own "Title [Studio]
    /// (Year)" convention -- see ParsedMediaName.movieFolderName. Just
    /// parse(_:).movieFolderName, but named for what callers actually
    /// want it for: parse(_:) is idempotent on a name already in that
    /// convention, and it also *fixes* one that's close but not quite,
    /// e.g.:
    ///   - a studio and year jammed into the same bracket with no
    ///     separating parens ("Sample Movie 8 [Example Films 2026]"
    ///     -> "Sample Movie 8 [Example Films] (2026)");
    ///   - trailing junk after an otherwise-correct "[Studio] (Year)"
    ///     -- very common in a "... HD 1080p Split Scenes" download
    ///     folder name, e.g. "Sample Movie 29 [Studio Name] (2023)
    ///     HD 1080p Split Scenes" -> "Sample Movie 29 [Studio Name]
    ///     (2023)".
    /// Returns nil when parse(_:) itself does -- nothing that looks
    /// like a release year or SxxEyy-style marker at all (a plain
    /// "cover.jpg", a performer-only file name, a folder with no year
    /// in its name) -- callers should treat that as "nothing reliable
    /// to key off of here", exactly like parse(_:)'s other callers
    /// already do. See FileMerger.formattedReleaseName(for:).
    static func canonicalReleaseName(_ name: String) -> String? {
        parse(name)?.movieFolderName
    }

    /// Standalone 1-2 digit numbers already embedded in a cleaned title
    /// (e.g. the "6" in "Clemence Audiard Vol. 6", or the "27" in
    /// "Perfectly Natural 27") -- pass the result to
    /// extractSequence(_:excluding:) so a file's own name restating one
    /// of these isn't mistaken for a distinguishing per-file sequence
    /// number.
    static func numbersInTitle(_ title: String) -> Set<Int> {
        let fullRange = NSRange(title.startIndex..., in: title)
        var numbers = Set<Int>()
        for match in bareNumberRegex.matches(in: title, range: fullRange) {
            guard let range = Range(match.range, in: title), let value = Int(title[range]) else { continue }
            numbers.insert(value)
        }
        return numbers
    }

    /// Strips bracketed and parenthesized noise tags, with special
    /// handling when a group carries a release year:
    ///
    /// - A bracketed group ("[...]") is always removed. If it contains a
    ///   year, the year is kept in the group's place instead of being
    ///   discarded along with the rest of it, and any other text in the
    ///   group is returned as a candidate studio name (e.g.
    ///   "[Studio.Name.2023]" -> keeps "2023", studio "Studio Name").
    /// - A parenthesized group ("(...)") is only touched when it
    ///   contains BOTH a year AND other text -- treated the same as a
    ///   bracketed group in that case. A group that's nothing but a year
    ///   (e.g. "(2026)", the plain movie-year convention) or that has no
    ///   year at all is left completely untouched, since there's no
    ///   reliable way to tell a studio tag apart from an arbitrary noise
    ///   tag without a year to anchor it.
    ///
    /// Only the first group found to carry a studio name (scanning
    /// left to right) is returned as `studio` -- later ones are still
    /// masked/stripped as above, but their text is discarded.
    private static func maskBracketsAndParens(in string: String) -> (text: String, studio: String?) {
        let fullRange = NSRange(string.startIndex..., in: string)
        let bracketMatches = bracketedRegex.matches(in: string, range: fullRange)
        let parenMatches = parenthesizedRegex.matches(in: string, range: fullRange)
        let allMatches = (bracketMatches + parenMatches).sorted { $0.range.location < $1.range.location }
        guard allMatches.isEmpty == false else { return (string, nil) }

        var result = ""
        var lastEnd = string.startIndex
        var studio: String?

        for (index, match) in allMatches.enumerated() {
            guard let range = Range(match.range, in: string), range.lowerBound >= lastEnd else { continue }
            result += string[lastEnd..<range.lowerBound]

            let fullGroup = String(string[range])
            let isBracket = fullGroup.hasPrefix("[")
            let inner = String(fullGroup.dropFirst().dropLast())

            let innerRange = NSRange(inner.startIndex..., in: inner)
            var yearText: String?
            var leftover = inner
            if let yearMatch = yearRegex.firstMatch(in: inner, range: innerRange),
               let yearRangeInInner = Range(yearMatch.range, in: inner) {
                yearText = String(inner[yearRangeInInner])
                leftover.removeSubrange(yearRangeInInner)
            }

            let studioCandidate: String? = {
                let words = normalizedDelimiters(leftover)
                    .components(separatedBy: .whitespaces)
                    .filter { $0.isEmpty == false }
                return words.isEmpty ? nil : words.joined(separator: " ")
            }()

            // A studio name that's already in its own bracket, immediately
            // followed by a bare-year parenthesis -- e.g. "Sample
            // Title 2 [Example Studio] (2024)", the very
            // "Title Version [Studio] (Year)" convention cleanedFileName
            // and movieFolderName themselves produce. Without this, a
            // file that's already correctly formatted has its studio
            // bracket discarded as generic noise, since (unlike
            // "[Studio.Name.2023]") the year isn't inside the bracket with
            // it. Only whitespace is allowed between the two groups, so a
            // bracket that merely precedes an unrelated parenthesized
            // year elsewhere in the name is never mistaken for this.
            if isBracket, yearText == nil, let studioCandidate = studioCandidate, studio == nil,
               looksLikeQualityTag(studioCandidate) == false,
               index + 1 < allMatches.count,
               let nextRange = Range(allMatches[index + 1].range, in: string),
               string[range.upperBound..<nextRange.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty {
                let nextGroup = String(string[nextRange])
                if nextGroup.hasPrefix("("), nextGroup.hasSuffix(")") {
                    let nextInner = String(nextGroup.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    let nextInnerRange = NSRange(nextInner.startIndex..., in: nextInner)
                    if let nextYearMatch = yearRegex.firstMatch(in: nextInner, range: nextInnerRange),
                       Range(nextYearMatch.range, in: nextInner) == nextInner.startIndex..<nextInner.endIndex {
                        studio = studioCandidate
                    }
                }
            }

            if isBracket {
                if let yearText = yearText {
                    result += " \(yearText) "
                    if studio == nil { studio = studioCandidate }
                } else {
                    result += " "
                }
            } else if let yearText = yearText, let studioCandidate = studioCandidate {
                result += " \(yearText) "
                if studio == nil { studio = studioCandidate }
            } else {
                // Not a studio+year group -- leave it exactly as it was,
                // whether it's a bare year "(2026)" or an unrelated
                // parenthesized noise tag.
                result += fullGroup
            }

            lastEnd = range.upperBound
        }
        result += string[lastEnd...]
        return (result, studio)
    }

    /// Fallback title for a name parse(_:) gave up on because it has no
    /// year, episode or quality marker, but does carry a "[Studio]" group
    /// -- typically one of this app's own "Title [Studio] (Year)" names
    /// after the year was removed ("A Sample Title [Example Studio] ()").
    /// Returns just the title with every bracket group, any empty "()" and
    /// any bare "(Year)" taken out and its original capitalisation kept,
    /// or nil when the name has no bracket group at all (callers then use
    /// their existing fallback). Without this such a name went to the
    /// bundled Perl filename parser, which mangled it (dropped the leading
    /// "A", folded the studio into the title).
    static func titleWithoutBrackets(_ filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        let baseName = ext.isEmpty ? filename : (filename as NSString).deletingPathExtension

        let fullRange = NSRange(baseName.startIndex..., in: baseName)
        guard bracketedRegex.firstMatch(in: baseName, range: fullRange) != nil else { return nil }

        var working = replaceMatches(bracketedRegex, in: baseName, with: " ")

        // Parenthesis groups that are empty or hold only a year are noise
        // here; any other parenthesised text stays (it may be part of the
        // title).
        let parens = parenthesizedRegex.matches(in: working, range: NSRange(working.startIndex..., in: working))
        for match in parens.reversed() {
            guard let range = Range(match.range, in: working) else { continue }
            let inner = working[range].dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner.isEmpty || inner.range(of: "^(?:19|20)\\d{2}$", options: .regularExpression) != nil {
                working.replaceSubrange(range, with: " ")
            }
        }

        if working.contains(" ") == false {
            working = normalizedDelimiters(working)
        }
        let title = working
            .replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        return title.isEmpty ? nil : title
    }

    /// Runs a regex substitution over a string, replacing every match with
    /// `template`.
    private static func replaceMatches(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    /// Title-cases the remaining words and collapses whitespace, after the
    /// scene-tag/year/episode portion of the string has already been cut
    /// off by parse(_:). Note this is a simple heuristic (not proper AP
    /// title-casing), and splitting on "-" as a word separator means a
    /// hyphenated title like "Spider-Man" comes out as "Spider Man".
    private static func cleanedTitle(_ rawTitle: String) -> String {
        // Also split on stray parenthesis/bracket characters -- since
        // a bare year in parentheses is deliberately left in place by
        // maskBracketsAndParens(in:), the raw title can end with a lone
        // leftover open-paren right before the cut point, e.g. for a
        // source name of "Mutiny (2026)". Treating those as separators
        // too drops the leftover character instead of leaving it stuck to
        // the last word.
        let words = rawTitle
            .components(separatedBy: CharacterSet(charactersIn: " -()[]"))
            .filter { $0.isEmpty == false }

        let capitalized = words.map { word -> String in
            let titleCased = word.prefix(1).uppercased() + word.dropFirst().lowercased()
            // "Vol" is always the "Volume" abbreviation here, never a
            // standalone word -- its trailing period is a normal part of
            // the abbreviation, not scene-release delimiter noise, so put
            // it back even though parse(_:) already normalized the
            // original period away to a space before this ever ran.
            return titleCased == "Vol" ? "Vol." : titleCased
        }

        return capitalized.joined(separator: " ")
    }
}


extension ParsedMediaName {

    /// Pulls the first 4-digit run out of a raw metadata date string (e.g.
    /// "2019-04-12" -> "2019"). Shared by the naming-review search flow
    /// (which parses a MetadataResult's raw releaseDate string) and
    /// fromTaggedMetadata below (which reads it back out of an
    /// already-tagged file's MP42MetadataKeyReleaseDate).
    static func firstFourDigitYear(in dateString: String?) -> String? {
        guard let dateString = dateString,
              let range = dateString.range(of: "\\d{4}", options: .regularExpression) else { return nil }
        return String(dateString[range])
    }

    /// Builds the file name a just-tagged document should have, following
    /// the exact same "Title [Studio] (Year)" / "Title SxxEyy" / "Title
    /// (Year)" / "Title" convention cleanedFileName above already uses for
    /// the Queue's naming-review workflow -- see that property's doc
    /// comment. Returns nil when there's no usable title to name the file
    /// after (metadata not tagged, or Name left blank), so a caller knows
    /// to leave the existing file name alone rather than guess at one.
    static func fromTaggedMetadata(_ metadata: MP42Metadata, fileExtension: String) -> ParsedMediaName? {
        guard let title = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
              title.isEmpty == false else {
            return nil
        }

        let studio = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyStudio).first?.stringValue
            .flatMap { $0.isEmpty ? nil : $0 }
        let year = firstFourDigitYear(in: metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyReleaseDate).first?.stringValue)

        let mediaKind = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyMediaKind).first?.numberValue?.intValue
        if mediaKind == 10 {
            // TV Show: "Title SxxEyy" when season/episode are both known,
            // otherwise fall through to the movie-style convention below
            // rather than showing a half-formed "Title Sxx".
            let season = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVSeason).first?.numberValue?.intValue
            let episode = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyTVEpisodeNumber).first?.numberValue?.intValue
            if let season = season, let episode = episode {
                return ParsedMediaName(title: title, year: year, season: season, episode: episode, studio: studio, fileExtension: fileExtension)
            }
        }

        return ParsedMediaName(title: title, year: year, studio: studio, fileExtension: fileExtension)
    }

    /// A filesystem-safe version of cleanedFileName -- "/" and ":" are the
    /// two characters macOS won't allow (or will silently mangle) in a
    /// file name, replaced here with "-" rather than left to fail or
    /// surprise later at the Finder/APFS level.
    var safeFileName: String {
        cleanedFileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

/// A small heuristic for Document.fillSeriesDescriptionIfNeeded(originalFileURL:):
/// does a title (or, failing that, a filename) end in something that marks
/// it as one entry in a series -- a bare trailing number ("John Wick 2")
/// or a word like "Part"/"Chapter"/"Vol(ume)" followed by one
/// ("Mission: Impossible Part 3") -- and if so, what's the base series
/// name once that's stripped off.
///
/// This is deliberately conservative: it only strips a short (1-3 digit)
/// trailing number, so it won't mistake a 4-digit year someone left stuck
/// on the end of a Title for a sequel marker. It still can't tell a real
/// sequel number from a number that's just part of the title ("Ocean's
/// 11", "Se7en", "2 Fast 2 Furious", "9", "300", "21") -- there's no way
/// to know the difference from the text alone, so Prefs.fillSeriesDescriptionOnSave
/// is off by default and always overwrites Series Description outright
/// rather than trying to be clever about when to trust itself.
enum SeriesTitleDetector {

    private static let regex: NSRegularExpression = {
        // Whitespace, then an optional "Part"/"Pt"/"Chapter"/"Vol"/"Volume"
        // word (with its own trailing whitespace), then a 1-3 digit
        // number, anchored to the end of the string.
        let pattern = #"\s+(?:(?:Part|Pt\.?|Chapter|Vol\.?|Volume)\s+)?\d{1,3}$"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Returns the base series name if `text` ends in a sequel/part
    /// indicator (see the type's header comment above), or nil if it
    /// doesn't look like one does.
    static func baseSeriesTitle(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)

        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let matchRange = Range(match.range, in: trimmed) else {
            return nil
        }

        let base = String(trimmed[trimmed.startIndex..<matchRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return base.isEmpty ? nil : base
    }
}


/// Folders named for a TV season ("Season 1", "Series 02", "S03"), the way
/// store purchases and most libraries lay out a show. Their files often have
/// no episode marker in the name, so the folder name is the only clue.
enum SeasonFolderName {

    private static let regex = try! NSRegularExpression(
        pattern: "^(?:(?:season|series)[ ._-]*|s)0*([0-9]{1,3})(?:\\s*[\\(\\[].*)?$",
        options: [.caseInsensitive])

    /// The season number if `name` is a season folder name, otherwise nil.
    static func seasonNumber(in name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        return Int(trimmed[numberRange])
    }

    /// True when the file sits directly inside a season folder.
    static func isInsideSeasonFolder(_ fileURL: URL) -> Bool {
        return seasonNumber(in: fileURL.deletingLastPathComponent().lastPathComponent) != nil
    }

    /// What the Queue shows for a folder: a season folder is shown with the
    /// folder above it, so the show's name is visible ("Show - Season 1").
    static func displayName(forFolder folder: URL) -> String {
        let name = folder.lastPathComponent
        guard seasonNumber(in: name) != nil else { return name }
        let parent = folder.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty || parent == "/" || parent == name { return name }
        return parent + " \u{2013} " + name
    }
}
