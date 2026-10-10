//
//  FileMerger.swift
//  Subler
//
//  Part of the LosslessCut-inspired file-merge feature -- see the design
//  doc published to the Subler claude.ai project
//  (claude/sublerx-merge-feature-design.md) for the full rationale.
//

import Foundation
import MP42Foundation

/// Errors specific to actually building and writing the merged file, once
/// MergeCompatibility.check has already confirmed the inputs can be
/// spliced directly -- see MergeCompatibilityError for the "these files
/// don't match" case, which is checked and thrown before any of this
/// runs.
public enum FileMergerError: LocalizedError {
    case concatFailed(mediaType: String, underlying: Error)
    case writeFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case let .concatFailed(mediaType, underlying):
            return String(format: NSLocalizedString("Couldn\u{2019}t join the %@ track: %@", comment: "Merge error"), mediaType, underlying.localizedDescription)
        case let .writeFailed(underlying):
            return String(format: NSLocalizedString("Couldn\u{2019}t write the merged file: %@", comment: "Merge error"), underlying.localizedDescription)
        }
    }
}

/// Joins two or more MP4 files end-to-end into one, splicing already-
/// compressed samples with MP42ConcatImporter -- no decode or re-encode.
/// A chapter marker is dropped at the start of every file after the
/// first, named after that file, so the join points stay easy to find
/// even though nothing about the merge itself is visible in the media.
///
/// This is deliberately not a QueueActionProtocol action: unlike the
/// queue's actions, a merge combines several *inputs* into one output
/// rather than transforming a single item in place, so it doesn't fit
/// that protocol's one-item-in, same-item-out shape. See the design doc
/// for how this is expected to integrate alongside QueueAction.swift
/// instead.
public enum FileMerger {

    /// Merges `files`, in the given order, into a new file at
    /// `destination`. Throws a MergeCompatibilityError if the inputs
    /// can't be spliced directly (nothing is written in that case), or a
    /// FileMergerError if joining or writing fails after that check
    /// passes.
    ///
    /// `progressHandler`, if given, is called repeatedly while the merged
    /// file is being written, with a value from 0 to 100 -- driven by
    /// MP42ConcatImporter.progress (see its demux) via the same
    /// MP42File.progressHandler mechanism the Queue's own save progress
    /// sheet uses (see DocumentWindowController.startProgressReporting).
    /// Called on whatever background thread the muxer is running on, same
    /// as MP42File.progressHandler itself -- callers touching UI from it
    /// need to dispatch to the main queue themselves, exactly as that
    /// existing call site does.
    public static func merge(files: [URL], destination: URL, progressHandler: ((Double) -> Void)? = nil) throws {
        let startedAt = Date()
        let mergeableTracks = try MergeCompatibility.check(files: files)
        let checkedAt = Date()

        let output = MP42File()
        var concatImporters: [(name: String, importer: MP42ConcatImporter)] = []

        for mergeable in mergeableTracks {
            let importer: MP42ConcatImporter
            do {
                importer = try MP42ConcatImporter(sources: mergeable.sources, mediaType: mergeable.mediaType)
            } catch {
                throw FileMergerError.concatFailed(mediaType: MergeCompatibility.name(for: mergeable.mediaType), underlying: error)
            }

            concatImporters.append((name: MergeCompatibility.name(for: mergeable.mediaType), importer: importer))

            for track in importer.tracks {
                output.addTrack(track)
            }
        }

        addChapters(to: output, forFiles: files)
        let preparedAt = Date()

        var options: [String: Any] = [:]
        options[MP4264BitData] = Prefs.mp464bitOffset
        options[MP4264BitTime] = Prefs.mp464bitTimes

        output.progressHandler = progressHandler
        defer { output.progressHandler = nil }

        // Written under a hidden temporary name and renamed once complete,
        // so a half-written merge never shows up under the final name
        // (where it could be opened, scanned or tagged while still
        // incomplete).
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.deletingPathExtension().lastPathComponent).merging")
            .appendingPathExtension(destination.pathExtension)
        try? FileManager.default.removeItem(at: temporary)
        do {
            try output.write(to: temporary, options: options)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw FileMergerError.writeFailed(underlying: error)
        }

        logTimings(files: files, destination: destination, startedAt: startedAt, checkedAt: checkedAt,
                   preparedAt: preparedAt, finishedAt: Date(), importers: concatImporters)
    }

    /// Writes a short timing breakdown of a finished merge to the debug
    /// log, so a slow merge can be traced to the source drive, the
    /// destination write, or something else (e.g. both on one spinning
    /// drive) without guessing.
    private static func logTimings(files: [URL], destination: URL, startedAt: Date, checkedAt: Date,
                                   preparedAt: Date, finishedAt: Date, importers: [(name: String, importer: MP42ConcatImporter)]) {
        func seconds(_ value: TimeInterval) -> String { return String(format: "%.1f s", value) }

        func volume(_ url: URL) -> (summary: String, uuid: String?) {
            let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
            guard let values = try? probe.resourceValues(forKeys: [.volumeNameKey, .volumeIsInternalKey, .volumeUUIDStringKey]) else {
                return ("unknown", nil)
            }
            let kind = values.volumeIsInternal.map { $0 ? "internal" : "external" } ?? "unknown"
            return ("\(values.volumeName ?? "unknown") (\(kind))", values.volumeUUIDString)
        }

        let totalBytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let megabytes = Double(totalBytes) / 1_000_000
        let elapsed = finishedAt.timeIntervalSince(startedAt)
        let rate = elapsed > 0 ? megabytes / elapsed : 0

        let source: (summary: String, uuid: String?) = files.first.map(volume) ?? ("unknown", nil)
        let target = volume(destination)
        let sameDrive: String
        if let a = source.uuid, let b = target.uuid {
            sameDrive = a == b ? "yes" : "no"
        } else {
            sameDrive = "unknown"
        }

        var lines: [String] = []
        lines.append("[Merge] \(files.count) files, \(String(format: "%.0f", megabytes)) MB: \(seconds(elapsed)) total (\(String(format: "%.1f", rate)) MB/s) -- compatibility check \(seconds(checkedAt.timeIntervalSince(startedAt))), track setup \(seconds(preparedAt.timeIntervalSince(checkedAt))), mux + write \(seconds(finishedAt.timeIntervalSince(preparedAt)))")
        lines.append("[Merge] source drive: \(source.summary); destination drive: \(target.summary); same drive: \(sameDrive)")
        for entry in importers {
            let importer = entry.importer
            lines.append("[Merge] \(entry.name): \(importer.samplesRead) samples, \(String(format: "%.0f", Double(importer.bytesRead) / 1_000_000)) MB -- reading \(seconds(importer.readSeconds)), handing to the writer \(seconds(importer.enqueueWaitSeconds))")
        }
        lines.append("[Merge] Reading close to the total = the source drive is the limit; handing to the writer close to the total = the destination write is.")

        for line in lines {
            Logger.shared.write(toLog: line)
        }
    }

    /// The single shared parent folder of `files`, if they all live in the
    /// same folder (the common case for a multi-part release living
    /// together in one folder) -- nil if they're scattered across more
    /// than one. Backs both suggestedDestinationName below and
    /// suggestedDestinationDirectory(for:), so there's one place that
    /// decides what "the files' folder" means.
    private static func sharedParentFolder(of files: [URL]) -> URL? {
        let parentFolders = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
        return parentFolders.count == 1 ? parentFolders.first : nil
    }

    /// A release name discoverable from the files' shared parent folder,
    /// in priority order:
    ///
    /// 1. A .jpg/.jpeg sitting in that folder -- a download/scraper-
    ///    provided cover image is the single most reliable signal of the
    ///    real title, e.g. a "SMPL_____720_2026" download folder (a
    ///    garbled download-client name, useless as a title) containing
    ///    "Sample Movie [Example Films] (2026).jpeg".
    /// 2. Failing that, the folder's own name -- very often already
    ///    correct or close to it (e.g. "Sample Movie 29 [Studio Name]
    ///    (2023) HD 1080p Split Scenes", which
    ///    ReleaseFilenameParser.canonicalReleaseName(_:) below cleans up
    ///    to "Sample Movie 29 [Studio Name] (2023)").
    /// 3. Failing that, an .mp4 in the folder. Checked last, after the
    ///    folder's own name rather than before it: a per-file scene name
    ///    usually omits the studio the folder/jpg name carries (e.g.
    ///    "Sample Title (2016) 1.mp4" has no "[Example]"), so a
    ///    match here is *less* complete than the folder name in the
    ///    common case, and only worth using when the folder name itself
    ///    didn't parse. Also catches the odd case of a stray already-
    ///    correctly-named video sitting in the folder (a previous test/
    ///    merge's own output, say) when nothing else matched.
    ///
    /// Each candidate is run through
    /// ReleaseFilenameParser.canonicalReleaseName(_:), which both
    /// recognizes an already-correct "Title [Studio] (Year)" name and
    /// fixes a close-but-not-quite one -- a studio and year jammed into
    /// one bracket ("Sample Movie 8 [Example Films 2026]" -> "Sample
    /// Movie 8 [Example Films] (2026)"), or trailing junk after an
    /// otherwise-correct "[Studio] (Year)" as in the folder-name example
    /// above. All three checked against a real folder of similarly-named
    /// downloaded releases. Returns nil if nothing here parses at all (a
    /// folder/file named only by performer, say) -- callers should fall
    /// back further, same as ReleaseFilenameParser.parse(_:)'s other
    /// callers do.
    private static func formattedReleaseName(for files: [URL]) -> String? {
        guard let folder = sharedParentFolder(of: files) else { return nil }

        let siblings = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []

        func bestMatch(extensions: Set<String>) -> String? {
            siblings
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .map { $0.deletingPathExtension().lastPathComponent }
                .compactMap(ReleaseFilenameParser.canonicalReleaseName)
                .sorted()
                .first
        }

        return bestMatch(extensions: ["jpg", "jpeg"])
            ?? ReleaseFilenameParser.canonicalReleaseName(folder.lastPathComponent)
            ?? bestMatch(extensions: ["mp4"])
    }

    /// A reasonable default name for the merged output, in priority order:
    /// a correctly-formatted (or fixable-to-correct) release name
    /// discoverable in the files' shared folder -- see
    /// formattedReleaseName above; failing that, the shared containing
    /// folder's own raw name, unparsed (split-part recordings are usually
    /// siblings in a folder already named after the actual title, which is
    /// a far better default than the first part's own filename, even when
    /// it can't be cleaned up any further); failing that, the first file's
    /// own embedded metadata Name/Title, if it has one; failing that, the
    /// first file's name, as before. Returns a bare name with no
    /// extension -- callers append their own (see
    /// QueueController.mergeSelectedItems(_:)).
    public static func suggestedDestinationName(for files: [URL]) -> String {
        if let releaseName = formattedReleaseName(for: files) {
            return releaseName
        }

        // None of the candidates above parsed (no year/episode/quality
        // marker anywhere -- see ReleaseFilenameParser.parse(_:)), so
        // there's no cleaned-up release name to fall back on. Still run
        // the raw name through ReleaseFilenameParser.normalizedDelimiters
        // so a torrent-style "_"/"-" separated name at least reads as
        // words instead of showing the raw separator characters -- see
        // the project notes on generic multi-part filenames (e.g.
        // "Chapter_1", "Chapter-1") where this fallback is most likely
        // to be hit.
        if let folderName = sharedParentFolder(of: files)?.lastPathComponent,
           folderName.isEmpty == false {
            return ReleaseFilenameParser.normalizedDelimiters(folderName)
        }

        if let first = files.first,
           let metadata = try? MP42File(url: first).metadata,
           let name = metadata.metadataItemsFiltered(byIdentifier: MP42MetadataKeyName).first?.stringValue,
           name.isEmpty == false {
            return ReleaseFilenameParser.normalizedDelimiters(name)
        }

        return ReleaseFilenameParser.normalizedDelimiters(files[0].deletingPathExtension().lastPathComponent)
    }

    /// A reasonable default *location* for the merge's save panel: the
    /// files' shared parent folder, so the merged output lands right next
    /// to the sources it came from instead of wherever NSSavePanel last
    /// happened to be pointed (which, the first time it's ever shown,
    /// defaults to somewhere unhelpful like the top of the file system).
    /// Falls back to the first file's own parent folder if the inputs
    /// happen to be scattered across more than one folder -- still "next
    /// to a source file," just not one shared by all of them -- or nil if
    /// `files` is empty.
    public static func suggestedDestinationDirectory(for files: [URL]) -> URL? {
        sharedParentFolder(of: files) ?? files.first?.deletingLastPathComponent().standardizedFileURL
    }

    /// The outcome of attempting renameSourceFolderIfPossible(for:).
    public enum SourceFolderRenameOutcome {
        /// Renamed the shared folder from `from` to `to`.
        case renamed(from: URL, to: URL)
        /// The folder's current name already matches the discovered
        /// release name -- nothing to do.
        case alreadyNamed
        /// No correctly- or fixable-to-correctly-formatted release name
        /// could be found nearby (see formattedReleaseName(for:)) --
        /// nothing to rename to.
        case noReleaseNameFound
        /// A file or folder already exists at the computed destination
        /// path -- left untouched rather than overwriting or merging
        /// into it.
        case destinationExists(URL)
        /// The rename itself failed (permissions, the folder having
        /// moved or been deleted out from under us, etc.).
        case failed(Error)
    }

    /// Renames the files' shared parent folder (see
    /// sharedParentFolder(of:)) to match a correctly- or fixable-to-
    /// correctly-formatted release name discovered nearby -- see
    /// formattedReleaseName(for:) for where that name comes from and in
    /// what priority (a cover image, the folder's own name, or a video
    /// file already carrying it).
    ///
    /// This is a real filesystem rename of the user's actual download
    /// folder, not just a suggested string the user still confirms (as
    /// suggestedDestinationName above is) -- callers should gate this
    /// behind MediaIntakePrefs.renameSourceFolderAfterMerge (off by
    /// default) rather than calling it unconditionally. See that
    /// preference's doc comment and the merge design doc's "0h" section
    /// for why. Everything else in the folder (a cover image, an .nfo,
    /// and -- when this runs right after a merge -- the merge's own
    /// freshly-written output file) moves along with an ordinary
    /// directory rename; callers that already have a path pointing
    /// inside the old folder (e.g. QueueController's just-merged output)
    /// need to re-derive it under the new folder after a `.renamed`
    /// result, since the old path no longer exists.
    ///
    /// Never overwrites an existing file or folder at the destination
    /// name -- see `.destinationExists` -- and never touches anything
    /// when the folder is already correctly named (`.alreadyNamed`) or
    /// nothing parseable was found at all (`.noReleaseNameFound`).
    public static func renameSourceFolderIfPossible(for files: [URL]) -> SourceFolderRenameOutcome {
        guard let releaseName = formattedReleaseName(for: files) else { return .noReleaseNameFound }
        guard let folder = sharedParentFolder(of: files) else { return .noReleaseNameFound }

        guard folder.lastPathComponent != releaseName else { return .alreadyNamed }

        let destination = folder.deletingLastPathComponent().appendingPathComponent(releaseName)
        guard FileManager.default.fileExists(atPath: destination.path) == false else {
            return .destinationExists(destination)
        }

        do {
            try FileManager.default.moveItem(at: folder, to: destination)
            return .renamed(from: folder, to: destination)
        } catch {
            return .failed(error)
        }
    }

    /// Adds one chapter at the start of every file after the first, named
    /// after that file (its name without extension), at the cumulative
    /// duration of everything merged before it. No chapter is added for
    /// the very first file's own start, since that's just the merged
    /// file's start.
    ///
    /// Re-reads each file's own `.duration` (already in milliseconds --
    /// same unit MP42ChapterTrack.addChapter expects) rather than
    /// threading per-file durations through MergeCompatibility, keeping
    /// that type focused on compatibility alone. If a file can't be
    /// reopened at this point -- it was readable moments ago, during
    /// MergeCompatibility.check -- no further chapters are added, but the
    /// merge itself is left to continue rather than failing outright over
    /// a purely cosmetic feature.
    private static func addChapters(to output: MP42File, forFiles files: [URL]) {
        guard files.count > 1 else { return }

        let chapterTrack: MP42ChapterTrack = output.chapters ?? {
            let track = MP42ChapterTrack()
            output.addTrack(track)
            return track
        }()

        var cumulativeDuration: UInt64 = 0

        for (index, url) in files.enumerated() {
            if index > 0 {
                let title = url.deletingPathExtension().lastPathComponent
                chapterTrack.addChapter(title, timestamp: cumulativeDuration)
            }

            guard let mp4 = try? MP42File(url: url) else { break }
            cumulativeDuration += UInt64(mp4.duration)
        }
    }
}
