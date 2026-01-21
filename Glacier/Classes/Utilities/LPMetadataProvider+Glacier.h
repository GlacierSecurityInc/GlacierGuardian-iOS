//
//  LPMetadataProvider+Glacier.h
//  Glacier
//
//  Created to safely fetch link metadata without crashing when LinkPresentation throws exceptions.
//

#import <Foundation/Foundation.h>
#import <LinkPresentation/LinkPresentation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^GLKLinkMetadataCompletion)(LPLinkMetadata *_Nullable metadata, NSError *_Nullable error);

@interface LPMetadataProvider (Glacier)
/// Starts metadata fetching but swallows Objective-C exceptions and forwards them as errors instead of crashing.
- (void)glacier_startFetchingMetadataForURL:(NSURL *)url
                         completionHandler:(GLKLinkMetadataCompletion)completion;
@end

NS_ASSUME_NONNULL_END
