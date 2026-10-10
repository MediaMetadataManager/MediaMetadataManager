//
//  MergeCompatibility.swift
//  Subler
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
