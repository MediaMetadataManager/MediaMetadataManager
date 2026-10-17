//
//  MP42FileImporter+Private.h
//  MP42Foundation
//
//  Created by Damiano Galassi on 05/09/15.
//  Copyright © 2022 Damiano Galassi. All rights reserved.
//
//  Modified for M3 (Media Metadata Manager) by
//  Hans Hoffmeister, 2026:
//  Importers can choose the quality of service of their demuxer thread.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

#import "MP42MediaFormat.h"

NS_ASSUME_NONNULL_BEGIN

@class MP42SampleBuffer;
@class MP42AudioTrack;
@class MP42VideoTrack;

@interface MP42FileImporter (Private)

- (instancetype)initWithURL:(NSURL *)fileURL;

- (void)addTrack:(MP42Track *)track;
- (void)addTracks:(NSArray<MP42Track *> *)tracks;

@property (nonatomic, copy) NSArray<MP42Track *> *inputTracks;
@property (nonatomic, copy) NSArray<MP42Track *> *outputsTracks;

- (void)setActiveTrack:(MP42Track *)track;

/// The quality-of-service class the demuxer thread starts at. Utility by
/// default (background-ish work that shouldn't compete with the UI);
/// subclasses whose demuxing is the whole job (MP42ConcatImporter) can
/// return a higher one.
- (NSQualityOfService)demuxerQualityOfService;

- (void)startReading;
- (void)cancelReading;

- (void)setDone;

@end

NS_ASSUME_NONNULL_END
