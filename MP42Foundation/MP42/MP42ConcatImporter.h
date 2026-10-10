//
//  MP42ConcatImporter.h
//  MP42Foundation
//
//  Part of the LosslessCut-inspired file-merge feature -- see the design
//  doc published to the Subler claude.ai project
//  (claude/sublerx-merge-feature-design.md) for the full rationale.
//

#import <Foundation/Foundation.h>
#import <MP42Foundation/MP42FileImporter.h>

NS_ASSUME_NONNULL_BEGIN

/// One source file's contribution to a track being joined: the file URL
/// plus the specific track ID *within that file* to pull samples from --
/// an MP42Track's `trackId`, the raw mp4v2 track ID assigned when that
/// track was parsed straight out of its own source file (MP42File's
/// -initWithURL:error: sets it directly and never routes a freshly-parsed
/// track through -addTrack:, so `trackId` is what stays populated; a
/// track's `sourceId` is a *different*, private field that only gets
/// filled in once that track is later adopted into some other MP42File
/// via -addTrack:, which is not yet the case for anything used to build
/// this value -- see MP42Track+Private.h and MP42File's -addTrack:).
@interface MP42ConcatSource : NSObject

@property (nonatomic, readonly, copy) NSURL *URL;
@property (nonatomic, readonly) MP42TrackId trackID;

- (instancetype)initWithURL:(NSURL *)URL trackID:(MP42TrackId)trackID;

@end

/// Joins one track (video, audio, ...) across two or more MP4 source files
/// end-to-end into a single continuous track, by reading each source's
/// compressed samples directly at the mp4v2 level -- same call surface as
/// MP42Mp4Importer's own -demux -- and offsetting every source after the
/// first by the cumulative duration of everything before it. No decode or
/// re-encode: a straight copy of already-compressed samples.
///
/// IMPORTANT: this class does not itself verify the sources are
/// compatible (same codec, profile, dimensions, timescale). Splicing
/// samples from mismatched sources will silently produce a broken or
/// unplayable track. Callers must run that check first -- see
/// MergeCompatibility.swift -- before constructing this importer.
///
/// Every codec-specific concern (the decoder config "magic cookie",
/// audio stream description, edit-list cleanup for things like B-frame
/// rendering offsets) is answered by delegating to a real
/// MP42Mp4Importer opened on the FIRST source only. That's safe *only*
/// because the caller has already confirmed every source shares those
/// same codec parameters -- this class leans entirely on that guarantee
/// rather than re-deriving anything from later sources.
@interface MP42ConcatImporter : MP42FileImporter

/// Builds the joined track. `sources` must have at least two entries, all
/// with the same media type (the caller picks which media type this
/// instance is for -- construct one MP42ConcatImporter per track being
/// joined, e.g. one for video, a separate one for audio).
///
/// On success, -tracks contains exactly one track: the first source's
/// MP42Track, adopted and repointed at this importer, with its duration
/// updated to the sum of every source's duration. Add that track to a
/// fresh MP42File and call -writeToUrl:options:error: as usual -- this
/// class only supplies the samples, it doesn't drive the write itself.
- (nullable instancetype)initWithSources:(NSArray<MP42ConcatSource *> *)sources
                                mediaType:(MP42MediaType)mediaType
                                    error:(NSError * __autoreleasing *)error;

/// Timing figures for the last -demux run, filled in when it finishes
/// (read them after the write completes). `readSeconds` is time spent
/// reading samples out of the source files; `enqueueWaitSeconds` is time
/// spent handing samples to the muxer, which includes waiting when it
/// can't keep up. If the first is close to the whole merge's duration the
/// source drive is the limit, if the second is the muxer/destination is.
@property (nonatomic, readonly) double readSeconds;
@property (nonatomic, readonly) double enqueueWaitSeconds;
@property (nonatomic, readonly) uint64_t bytesRead;
@property (nonatomic, readonly) NSUInteger samplesRead;

@end

NS_ASSUME_NONNULL_END
