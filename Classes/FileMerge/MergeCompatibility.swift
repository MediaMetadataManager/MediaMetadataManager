//
//  MergeCompatibility.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/21/2026.
//
//  Part of the LosslessCut-inspired file-merge feature -- see the design
//  doc published to the Subler claude.ai project
//  (claude/sublerx-merge-feature-design.md) for the full rationale.
//

import Foundation
import MP42Foundation

/// Why a set of files can't be joined losslessly by MP42ConcatImporter.
/// Splicing already-compressed samples across files only works when every
/// file's corresponding track shares the same codec, timescale, and (for
/// video) pixel dimensions -- v1 rejects any mismatch outright rather than
/// falling back to a re-encode (see the design doc's reasoning for not
/// offering a re-encode fallback).
public enum MergeCompatibilityError: LocalizedError {
    case tooFewFiles
    case couldNotOpenFile(URL)
    case noMergeableTracks
    case trackCountMismatch(file: URL, expected: Int, found: Int, mediaType: String)
    case codecMismatch(file: URL, expected: MP42CodecType, found: MP42CodecType, mediaType: String)
    case timescaleMismatch(file: URL, expected: UInt32, found: UInt32, mediaType: String)
    case dimensionsMismatch(file: URL, expectedWidth: UInt64, expectedHeight: UInt64, foundWidth: UInt64, foundHeight: UInt64)

    public var errorDescription: String? {
        switch self {
        case .tooFewFiles:
            return NSLocalizedString("At least two files are needed to merge.", comment: "Merge compatibility error")
        case let .couldNotOpenFile(url):
            return String(format: NSLocalizedString("\u{201C}%@\u{201D} couldn\u{2019}t be opened.", comment: "Merge compatibility error"), url.lastPathComponent)
        case .noMergeableTracks:
            return NSLocalizedString("None of the selected files share a video or audio track to merge.", comment: "Merge compatibility error")
        case let .trackCountMismatch(file, expected, found, mediaType):
            return String(format: NSLocalizedString("\u{201C}%@\u{201D} has %ld %@ track(s), but the first file has %ld.", comment: "Merge compatibility error"), file.lastPathComponent, Int(found), mediaType, Int(expected))
        case let .codecMismatch(file, expected, found, mediaType):
            return String(format: NSLocalizedString("\u{201C}%@\u{201D}\u{2019}s %@ codec (%@) doesn\u{2019}t match the first file\u{2019}s (%@).", comment: "Merge compatibility error"), file.lastPathComponent, mediaType, MergeCompatibility.fourCCString(found), MergeCompatibility.fourCCString(expected))
        case let .timescaleMismatch(file, expected, found, mediaType):
            return String(format: NSLocalizedString("\u{201C}%@\u{201D}\u{2019}s %@ track uses a different timescale than the first file (%u vs %u).", comment: "Merge compatibility error"), file.lastPathComponent, mediaType, found, expected)
        case let .dimensionsMismatch(file, expectedWidth, expectedHeight, foundWidth, foundHeight):
            return String(format: NSLocalizedString("\u{201C}%@\u{201D} is %ld\u{00D7}%ld, but the first file is %ld\u{00D7}%ld.", comment: "Merge compatibility error"), file.lastPathComponent, Int(foundWidth), Int(foundHeight), Int(expectedWidth), Int(expectedHeight))
        }
    }
}

/// One track, matched by media type and position, across every input
/// file -- ready to hand to MP42ConcatImporter once MergeCompatibility.check
/// has confirmed every file's corresponding track is compatible. `sources`
/// is in the same order as the files passed to `check(files:)`.
public struct MergeableTrack {
    public let mediaType: MP42MediaType
    public let sources: [MP42ConcatSource]
}

public enum MergeCompatibility {

    /// Opens every file, matches up tracks of the same media type by
    /// their position within each file's own track list (first video
    /// track pairs with first video track, second audio track with second
    /// audio track, and so on), and confirms every file's corresponding
    /// track shares the codec, timescale, and (for video) pixel
    /// dimensions that MP42ConcatImporter needs in order to splice
    /// compressed samples directly, with no decode or re-encode. Throws
    /// on the first mismatch found -- v1 doesn't attempt a partial merge
    /// of only the tracks that happen to match.
    ///
    /// Subtitles, closed captions, chapters, and anything else outside
    /// video/audio are left out of the merge entirely for v1 -- see the
    /// design doc's scope section.
    public static func check(files: [URL]) throws -> [MergeableTrack] {
        guard files.count >= 2 else { throw MergeCompatibilityError.tooFewFiles }

        let mp4Files: [MP42File] = try files.map { url in
            do {
                return try MP42File(url: url)
            } catch {
                throw MergeCompatibilityError.couldNotOpenFile(url)
            }
        }

        let mediaTypesToMerge: [MP42MediaType] = [kMP42MediaType_Video, kMP42MediaType_Audio]

        var result: [MergeableTrack] = []

        for mediaType in mediaTypesToMerge {
            let referenceTracks = mp4Files[0].tracks(withMediaType: mediaType)
            guard !referenceTracks.isEmpty else { continue }

            let mediaTypeName = name(for: mediaType)
            var sourcesPerTrack: [[MP42ConcatSource]] = referenceTracks.map { _ in [] }

            for (fileIndex, mp4) in mp4Files.enumerated() {
                let url = files[fileIndex]
                let tracks = mp4.tracks(withMediaType: mediaType)

                guard tracks.count == referenceTracks.count else {
                    throw MergeCompatibilityError.trackCountMismatch(file: url, expected: referenceTracks.count, found: tracks.count, mediaType: mediaTypeName)
                }

                for (trackIndex, track) in tracks.enumerated() {
                    let referenceTrack = referenceTracks[trackIndex]

                    guard track.format == referenceTrack.format else {
                        throw MergeCompatibilityError.codecMismatch(file: url, expected: referenceTrack.format, found: track.format, mediaType: mediaTypeName)
                    }

                    guard track.timescale == referenceTrack.timescale else {
                        throw MergeCompatibilityError.timescaleMismatch(file: url, expected: referenceTrack.timescale, found: track.timescale, mediaType: mediaTypeName)
                    }

                    if mediaType == kMP42MediaType_Video,
                       let videoTrack = track as? MP42VideoTrack,
                       let referenceVideoTrack = referenceTrack as? MP42VideoTrack {
                        guard videoTrack.width == referenceVideoTrack.width, videoTrack.height == referenceVideoTrack.height else {
                            throw MergeCompatibilityError.dimensionsMismatch(file: url, expectedWidth: referenceVideoTrack.width, expectedHeight: referenceVideoTrack.height, foundWidth: videoTrack.width, foundHeight: videoTrack.height)
                        }
                    }

                    // track.trackId, not track.sourceId -- these tracks
                    // just came straight out of MP42File(url:) and were
                    // never adopted into any destination file, so trackId
                    // is the field that actually holds each track's raw
                    // mp4v2 ID within its own source file right now. See
                    // the doc comment on MP42ConcatSource for the full
                    // explanation.
                    sourcesPerTrack[trackIndex].append(MP42ConcatSource(url: url, trackID: track.trackId))
                }
            }

            for sources in sourcesPerTrack {
                result.append(MergeableTrack(mediaType: mediaType, sources: sources))
            }
        }

        guard !result.isEmpty else { throw MergeCompatibilityError.noMergeableTracks }

        return result
    }

    /// A short, user-facing name for a media type, for error messages.
    static func name(for mediaType: MP42MediaType) -> String {
        switch mediaType {
        case kMP42MediaType_Video:
            return NSLocalizedString("video", comment: "Media type name")
        case kMP42MediaType_Audio:
            return NSLocalizedString("audio", comment: "Media type name")
        default:
            return NSLocalizedString("track", comment: "Media type name")
        }
    }

    /// Renders a four-character-code codec type (e.g. avc1, hvc1) back to
    /// its readable string form for error messages.
    static func fourCCString(_ code: MP42CodecType) -> String {
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        guard let string = String(bytes: bytes, encoding: .ascii) else { return String(code) }
        return string.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Per-file report (odd file out)

/// What decides whether two files can be spliced: the ordered video and
/// audio tracks with their codec, timescale and (video) size. Two files are
/// compatible exactly when their signatures are equal, which is the same
/// rule `MergeCompatibility.check(files:)` enforces at merge time, and it
/// does not depend on the order of the files.
public struct MergeFileSignature: Equatable {
    public struct Track: Equatable {
        public let mediaType: String   // "video" or "audio"
        public let format: MP42CodecType
        public let timescale: UInt32
        public let width: UInt64
        public let height: UInt64

        public init(mediaType: String, format: MP42CodecType, timescale: UInt32, width: UInt64 = 0, height: UInt64 = 0) {
            self.mediaType = mediaType
            self.format = format
            self.timescale = timescale
            self.width = width
            self.height = height
        }
    }

    /// Video tracks first, then audio tracks, each in the file's own order.
    public let tracks: [Track]

    public init(tracks: [Track]) {
        self.tracks = tracks
    }

    /// Reads the signature of one file. Opens the file and inspects track
    /// metadata only, so it is cheap but should still run off the main thread.
    public static func read(from url: URL) throws -> MergeFileSignature {
        let file: MP42File
        do {
            file = try MP42File(url: url)
        } catch {
            throw MergeCompatibilityError.couldNotOpenFile(url)
        }

        var tracks: [Track] = []
        for mediaType in [kMP42MediaType_Video, kMP42MediaType_Audio] {
            let name = MergeCompatibility.name(for: mediaType)
            for track in file.tracks(withMediaType: mediaType) {
                let video = track as? MP42VideoTrack
                tracks.append(Track(mediaType: name,
                                    format: track.format,
                                    timescale: track.timescale,
                                    width: video?.width ?? 0,
                                    height: video?.height ?? 0))
            }
        }
        return MergeFileSignature(tracks: tracks)
    }

    /// A short, readable description of how this file differs from
    /// `reference`, or nil when they match.
    public func difference(from reference: MergeFileSignature) -> String? {
        for mediaType in ["video", "audio"] {
            let mine = tracks.filter { $0.mediaType == mediaType }
            let theirs = reference.tracks.filter { $0.mediaType == mediaType }

            if mine.count != theirs.count {
                return String(format: NSLocalizedString("%ld %@ track(s), the others have %ld", comment: "Merge compatibility difference"), mine.count, mediaType, theirs.count)
            }
            for (a, b) in zip(mine, theirs) {
                if a.format != b.format {
                    return String(format: NSLocalizedString("%@ codec %@, the others use %@", comment: "Merge compatibility difference"), mediaType, MergeCompatibility.fourCCString(a.format), MergeCompatibility.fourCCString(b.format))
                }
                if a.timescale != b.timescale {
                    return String(format: NSLocalizedString("%@ timescale %u, the others use %u", comment: "Merge compatibility difference"), mediaType, a.timescale, b.timescale)
                }
                if a.width != b.width || a.height != b.height {
                    return String(format: NSLocalizedString("%ld\u{00D7}%ld, the others are %ld\u{00D7}%ld", comment: "Merge compatibility difference"), Int(a.width), Int(a.height), Int(b.width), Int(b.height))
                }
            }
        }
        return nil
    }
}

/// Which files in a merge selection don't fit the rest, and why.
public struct MergeFitReport {
    /// One entry per file, in the order given: nil means it fits.
    public let problems: [String?]
    /// Set when the selection can't be judged per file at all (too few files,
    /// or nothing to merge).
    public let overallProblem: String?

    public var isCompatible: Bool {
        overallProblem == nil && problems.allSatisfy { $0 == nil }
    }

    public var oddFileCount: Int { problems.compactMap { $0 }.count }

    /// Compares each file with the signature most of the files share (ties
    /// go to the earliest file), so the odd one out is flagged even when it
    /// is the first file in the list. `signatures[i]` is nil when file i
    /// couldn't be opened.
    public static func make(signatures: [MergeFileSignature?]) -> MergeFitReport {
        guard signatures.count >= 2 else {
            return MergeFitReport(problems: signatures.map { _ in nil },
                                  overallProblem: NSLocalizedString("At least two files are needed to merge.", comment: "Merge compatibility error"))
        }

        var groups: [(signature: MergeFileSignature, count: Int)] = []
        for case let signature? in signatures {
            if let index = groups.firstIndex(where: { $0.signature == signature }) {
                groups[index].count += 1
            } else {
                groups.append((signature, 1))
            }
        }

        // The first group with the highest count wins, so a tie keeps the earliest.
        guard let best = groups.enumerated().max(by: { lhs, rhs in
            lhs.element.count != rhs.element.count ? lhs.element.count < rhs.element.count : lhs.offset > rhs.offset
        })?.element.signature else {
            return MergeFitReport(problems: signatures.map { _ in NSLocalizedString("couldn\u{2019}t be opened", comment: "Merge compatibility difference") },
                                  overallProblem: nil)
        }

        let problems: [String?] = signatures.map { signature in
            guard let signature = signature else {
                return NSLocalizedString("couldn\u{2019}t be opened", comment: "Merge compatibility difference")
            }
            return signature.difference(from: best)
        }

        let overall: String? = best.tracks.isEmpty
            ? NSLocalizedString("None of the selected files share a video or audio track to merge.", comment: "Merge compatibility error")
            : nil

        return MergeFitReport(problems: problems, overallProblem: overall)
    }

    /// Reads every file and builds the report. Blocking: call it off the
    /// main thread.
    public static func analyze(files: [URL]) -> MergeFitReport {
        make(signatures: files.map { try? MergeFileSignature.read(from: $0) })
    }
}
