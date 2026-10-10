//
//  MP42Metadata.h
//  Subler
//
//  Created by Damiano Galassi on 06/02/09.
//  Copyright 2022 Damiano Galassi. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <MP42Foundation/MP42MetadataItem.h>

NS_ASSUME_NONNULL_BEGIN

@interface MP42Metadata : NSObject <NSSecureCoding, NSCopying>

/**
 *  Initializes a new metadata instance by a given URL
 *
 *  @param URL An URL that identifies an xml file.
 *
 *  @return The receiver, initialized with the resource specified by URL.
 */
- (nullable instancetype)initWithURL:(NSURL *)URL;

/**
 *  Returns the complete list of available metadata.
 */
@property (nonatomic, class, readonly) NSArray<NSString *> *availableMetadata;

/**
 *  Returns the complete list of writable metadata.
 */
@property (nonatomic, class, readonly) NSArray<NSString *> *writableMetadata;

- (void)addMetadataItems:(NSArray<MP42MetadataItem *> *)items;
- (void)addMetadataItem:(MP42MetadataItem *)item;

- (void)removeMetadataItem:(MP42MetadataItem *)item;
- (void)removeMetadataItems:(NSArray<MP42MetadataItem *> *)items;

@property (nonatomic, readonly) NSArray<MP42MetadataItem *> *items;

/*!
	@abstract			Filters an array of MP42MetadataItems according to identifier.
	@param			identifier
	The identifier that must be matched for a metadata item to be copied to the output array. Items are considered a match not only when their identifiers are equal to the specified identifier, and also when their identifiers conform to the specified identifier.
	@result			An instance of NSArray containing the metadata items of the target NSArray that match the specified identifier.
 */
- (NSArray<MP42MetadataItem *> *)metadataItemsFilteredByIdentifier:(NSString *)identifier;

/*!
	@abstract			Filters an array of MP42MetadataItems according to a identifiers array.
	@param			identifiers
	The identifiers that must be matched for a metadata item to be copied to the output array. Items are considered a match not only when their identifiers are equal to the specified identifier, and also when their identifiers conform to the specified identifier.
	@result			An instance of NSArray containing the metadata items of the target NSArray that match the specified identifier.
 */
- (NSArray<MP42MetadataItem *> *)metadataItemsFilteredByIdentifiers:(NSArray<NSString *> *)identifiers;

/*!
	@abstract			Filters an array of MP42MetadataItems according a data type mask.
	@param			dataType
	The identifier that must be matched for a metadata item to be copied to the output array. Items are considered a match not only when their identifiers are equal to the specified identifier, and also when their identifiers conform to the specified identifier.
	@result			An instance of NSArray containing the metadata items of the target NSArray that match the specified identifier.
 */
- (NSArray<MP42MetadataItem *> *)metadataItemsFilteredByDataType:(MP42MetadataItemDataType)dataType;

/**
 Merges the tags of the passed MP42Metadata instance

 @param metadata the instance to merge.
 */
- (void)mergeMetadata:(MP42Metadata *)metadata overwrite:(BOOL)overwrite;

/**
 Merges the tags of the passed MP42Metadata instance, with an extra "append"
 mode scoped to cover art -- the only identifier that can legitimately hold
 more than one item at once. When overwrite is NO and append is YES, incoming
 cover art is always added alongside whatever cover art already exists
 (rather than being skipped because the identifier is already present);
 every other field still follows the ordinary skip-if-exists rule. When
 overwrite is YES, append has no effect (overwrite already replaces cover
 art wholesale, same as -mergeMetadata:overwrite:).

 @param metadata the instance to merge.
 @param overwrite whether existing items should be replaced.
 @param append whether new cover art should be added alongside existing cover art instead of being skipped (ignored when overwrite is YES).
 */
- (void)mergeMetadata:(MP42Metadata *)metadata overwrite:(BOOL)overwrite append:(BOOL)append;

@property (nonatomic, readwrite, nullable) NSUndoManager *undo;

@end

NS_ASSUME_NONNULL_END
