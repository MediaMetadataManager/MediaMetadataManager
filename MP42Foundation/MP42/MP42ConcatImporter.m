//
//  MP42ConcatImporter.m
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 09/21/2026.
//

#import "MP42ConcatImporter.h"
#import "MP42FileImporter+Private.h"
#import "MP42Mp4Importer.h"
#import "MP42Track.h"
#import "MP42Track+Private.h"
#import "MP42SampleBuffer.h"

#import "mp4v2.h"

#include <time.h>

NSString * const MP42ConcatImporterErrorDomain = @"org.galad.SublerX.MP42ConcatImporter";

@implementation MP42ConcatSource

- (instancetype)initWithURL:(NSURL *)URL trackID:(MP42TrackId)trackID
{
    self = [super init];
    if (self) {
        _URL = [URL copy];
        _trackID = trackID;
    }
    return self;
}

@end

@implementation MP42ConcatImporter {
    NSArray<MP42ConcatSource *> *_sources;

    // Wraps sources[0] only. Every codec-config query (magic cookie,
    // audio description, edit-list cleanup) is delegated to this instance
    // rather than re-implemented here -- see the header's doc comment for
    // why that's safe.
    MP42Mp4Importer *_primaryImporter;

    MP42TrackId _outputSourceId;

    // Sum of every source's raw MP4GetTrackDuration, in the shared
    // timescale MergeCompatibility already confirmed they all use (see
    // -demux). Lets -demux report a meaningful percentage through the
    // inherited `progress` property -- MP42Muxer averages every active
    // track's importer.progress while it writes (see MP42Muxer.m's
    // -work), and without this MP42ConcatImporter would just leave that
    // stuck at 0 for the whole merge, since nothing else here ever touches
    // `progress`.
    uint64_t _totalRawDuration;
}

+ (NSArray<NSString *> *)supportedFileFormats
{
    // Not file-extension driven -- this class is never constructed
    // through MP42FileImporter's normal +initWithURL:error: factory
    // dispatch, only through -initWithSources:mediaType:error: below.
    return @[];
}

- (nullable instancetype)initWithSources:(NSArray<MP42ConcatSource *> *)sources
                                mediaType:(MP42MediaType)mediaType
                                    error:(NSError * __autoreleasing *)error
{
    if (sources.count < 2) {
        if (error) {
            *error = [NSError errorWithDomain:MP42ConcatImporterErrorDomain
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey: @"At least two sources are required to merge."}];
        }
        return nil;
    }

    // MP42FileImporter's designated (private) -initWithURL: just stores
    // fileURL and sets up bookkeeping -- every MP42FileImporter subclass
    // calls it this way rather than the public +initWithURL:error:
    // factory, which is only for dispatching to the right subclass by
    // file extension (not applicable here, since we're never
    // constructed from a single URL).
    if ((self = [super initWithURL:sources.firstObject.URL])) {
        _sources = [sources copy];

        _primaryImporter = [[MP42Mp4Importer alloc] initWithURL:sources.firstObject.URL error:error];
        if (!_primaryImporter) {
            return nil;
        }

        // _primaryImporter.tracks are freshly parsed straight out of
        // sources.firstObject.URL and have never been adopted into any
        // destination MP42File -- their `sourceId` is still unset (0), so
        // the field that actually holds each track's raw mp4v2 ID at this
        // point is `trackId` (see the header's doc comment on
        // MP42ConcatSource for why).
        MP42Track *primaryTrack = nil;
        for (MP42Track *track in _primaryImporter.tracks) {
            if (track.mediaType == mediaType && track.trackId == sources.firstObject.trackID) {
                primaryTrack = track;
                break;
            }
        }

        if (!primaryTrack) {
            if (error) {
                *error = [NSError errorWithDomain:MP42ConcatImporterErrorDomain
                                              code:2
                                          userInfo:@{NSLocalizedDescriptionKey: @"Could not locate the source track to merge."}];
            }
            return nil;
        }

        // Cache the raw ID now, before adoption, rather than reading
        // primaryTrack.sourceId here -- it's still unset (0) at this point
        // for the same reason noted above. Once whoever constructed this
        // importer adds `tracks.firstObject` (== primaryTrack) to a real
        // destination MP42File, -addTrack: copies trackId into sourceId
        // verbatim (trackId itself gets reset to 0 for renumbering in the
        // new file), so this cached value is exactly what primaryTrack's
        // sourceId will read as by the time -demux actually runs -- which
        // is what every sample below needs to be stamped with so the
        // muxer's active-track routing (sourceId == sample->trackId) finds
        // it.
        _outputSourceId = primaryTrack.trackId;

        // Sum every source's duration, converted to milliseconds --
        // MP42Track.duration is always in MP4_MSECS_TIME_SCALE (see
        // MP42Track.m's -initWithSourceURL:trackID:fileHandle:), not the
        // track's own sample timescale.
        MP42Duration totalDuration = 0;
        uint64_t totalRawDuration = 0;
        for (MP42ConcatSource *source in sources) {
            MP42FileHandle handle = MP4Read(source.URL.fileSystemRepresentation);
            if (handle) {
                MP4Duration rawDuration = MP4GetTrackDuration(handle, source.trackID);
                totalDuration += MP4ConvertFromTrackDuration(handle, source.trackID, rawDuration, MP4_MSECS_TIME_SCALE);
                totalRawDuration += rawDuration;
                MP4Close(handle, 0);
            }
        }
        primaryTrack.duration = totalDuration;
        _totalRawDuration = totalRawDuration;

        // Repoint the adopted track at this importer -- it currently
        // points at _primaryImporter, since that's who parsed it.
        primaryTrack.importer = self;

        [self addTrack:primaryTrack];
    }

    return self;
}

#pragma mark - Delegated to the primary (first-source) importer

- (nullable NSData *)magicCookieForTrack:(MP42Track *)track
{
    return [_primaryImporter magicCookieForTrack:track];
}

- (AudioStreamBasicDescription)audioDescriptionForTrack:(MP42AudioTrack *)track
{
    return [_primaryImporter audioDescriptionForTrack:track];
}

- (BOOL)audioTrackUsesExplicitEncoderDelay:(MP42Track *)track
{
    return [_primaryImporter audioTrackUsesExplicitEncoderDelay:track];
}

- (void)cleanUp:(MP42Track *)track fileHandle:(MP42FileHandle)fileHandle
{
    // Deliberately NOT delegated to _primaryImporter, unlike every other
    // method in this section. -[MP42Mp4Importer cleanUp:fileHandle:] reads
    // its edit-list duration from _primaryImporter's OWN fileHandle -- i.e.
    // source #1's file alone -- via MP4GetTrackDuration(_fileHandle, ...).
    // For a normal, single-source import that's correct, but here it would
    // silently rebuild the B-frame rendering-offset edit capped at just
    // source #1's duration, even though every later source's samples have
    // already been demuxed into this destination track by this point. The
    // result: a merged file whose declared/playable duration is only as
    // long as the first source, with the rest of the merged content
    // present in mdat but outside the movie's edit list -- which is
    // exactly what made QuickTime refuse to open the first real multi-file
    // merge this shipped with (declared ~34 minutes, actual content
    // spanning 2.5+ hours), while more lenient tools that ignore edit
    // lists still read the file fine.
    //
    // Reimplemented here against the *destination* track/fileHandle
    // instead, whose duration already reflects every source by the time
    // -demux finishes. Only the single "first-frame rendering offset"
    // pseudo-edit mp4v2/Subler adds for B-frame decode-delay compensation
    // is handled -- if source #1 itself already carried a real, prior edit
    // list (unusual for the plain, untrimmed exports this feature
    // targets), it's intentionally not carried over, since a partial copy
    // of just source #1's edits would reproduce the same truncation bug
    // for sources after it.
    MP4TrackId dstTrackId = track.trackId;

    MP4Duration firstFrameOffset = MP4GetSampleRenderingOffset(fileHandle, dstTrackId, 1);
    if (firstFrameOffset) {
        MP4Duration fullTrackDuration = MP4GetTrackDuration(fileHandle, dstTrackId);
        MP4Duration editDuration = MP4ConvertFromTrackDuration(fileHandle, dstTrackId,
                                                                 fullTrackDuration,
                                                                 MP4GetTimeScale(fileHandle));

        MP4AddTrackEdit(fileHandle, dstTrackId, MP4_INVALID_EDIT_ID, firstFrameOffset,
                        editDuration, 0);
    }
}

#pragma mark - Sample streaming

- (NSQualityOfService)demuxerQualityOfService
{
    // Joining the sources is the whole job of this importer, and the user
    // is waiting on it -- not the low-priority (and, for disk access,
    // throttled) background work the default Utility class is meant for.
    return NSQualityOfServiceUserInitiated;
}

- (void)demux
{
    @autoreleasepool {
        MP4Duration cumulativeOffset = 0;
        NSUInteger sampleCounter = 0;

        uint64_t readNanos = 0, enqueueNanos = 0, bytesTotal = 0;

        for (MP42ConcatSource *source in _sources) {
            if (self.isCancelled) {
                break;
            }

            MP42FileHandle fileHandle = MP4Read(source.URL.fileSystemRepresentation);
            if (!fileHandle) {
                continue;
            }

            MP4TrackId trackID = source.trackID;
            uint32_t timeScale = MP4GetTrackTimeScale(fileHandle, trackID);
            uint64_t totalSamples = MP4GetTrackNumberOfSamples(fileHandle, trackID);

            for (MP4SampleId sampleId = 1; sampleId <= totalSamples; sampleId++) {
                if (self.isCancelled) {
                    break;
                }

                uint8_t *pBytes = NULL;
                uint32_t numBytes = 0;
                MP4Duration duration;
                MP4Duration renderingOffset;
                MP4Timestamp pStartTime;
                unsigned char isSyncSample;
                unsigned char hasDependencyFlags;
                uint32_t dependencyFlags;

                uint64_t readStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                if (!MP4ReadSampleSampleDependency(fileHandle, trackID, sampleId,
                                                    &pBytes, &numBytes,
                                                    &pStartTime, &duration, &renderingOffset,
                                                    &isSyncSample, &hasDependencyFlags, &dependencyFlags)) {
                    break;
                }
                readNanos += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - readStart;
                bytesTotal += numBytes;

                MP42SampleBuffer *sample = [[MP42SampleBuffer alloc] init];
                sample->data = pBytes;
                sample->size = numBytes;
                sample->timescale = timeScale;
                sample->duration = duration;
                sample->offset = renderingOffset;
                sample->decodeTimestamp = pStartTime + cumulativeOffset;
                sample->flags |= isSyncSample ? MP42SampleBufferFlagIsSync : 0;
                sample->trackId = _outputSourceId;
                if (hasDependencyFlags) {
                    sample->dependecyFlags = dependencyFlags;
                }

                uint64_t enqueueStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                [self enqueue:sample];
                enqueueNanos += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - enqueueStart;

                // Report progress periodically rather than every sample --
                // a source can easily have tens of thousands of samples,
                // and nothing downstream needs finer granularity than this.
                // `pStartTime + duration` is this sample's end position
                // within its OWN source; adding cumulativeOffset (this
                // source's start position within the whole merged output,
                // already in the same shared timescale -- see below)
                // gives overall progress through the merge.
                sampleCounter += 1;
                if (_totalRawDuration > 0 && sampleCounter % 200 == 0) {
                    MP4Duration processed = cumulativeOffset + pStartTime + duration;
                    self.progress = ((double)processed / (double)_totalRawDuration) * 100;
                }
            }

            // Next source's samples are offset by everything before it,
            // in that source's own timescale -- MergeCompatibility has
            // already confirmed every source shares the same timescale,
            // so no cross-timescale conversion is needed here.
            cumulativeOffset += MP4GetTrackDuration(fileHandle, trackID);

            // Always update at the source boundary too, not just every
            // 200th sample -- otherwise a short final source could finish
            // without ever landing on that modulo and progress would stall
            // short of 100% until -setDone below silently ends things.
            if (_totalRawDuration > 0) {
                self.progress = ((double)cumulativeOffset / (double)_totalRawDuration) * 100;
            }

            MP4Close(fileHandle, 0);
        }

        _readSeconds = (double)readNanos / 1e9;
        _enqueueWaitSeconds = (double)enqueueNanos / 1e9;
        _bytesRead = bytesTotal;
        _samplesRead = sampleCounter;

        [self setDone];
    }
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"MP42ConcatImporter <%p> %lu sources", self, (unsigned long)_sources.count];
}

@end
