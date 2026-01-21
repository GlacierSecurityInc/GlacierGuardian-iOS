//
//  LPMetadataProvider+Glacier.m
//  Glacier
//
//  Provides a defensive wrapper around LinkPresentation metadata fetching to avoid app crashes.
//

#import "LPMetadataProvider+Glacier.h"

@implementation LPMetadataProvider (Glacier)

- (void)glacier_startFetchingMetadataForURL:(NSURL *)url
                         completionHandler:(GLKLinkMetadataCompletion)completion
{
    @try {
        [self startFetchingMetadataForURL:url completionHandler:completion];
    } @catch (NSException *exception) {
        if (completion) {
            NSDictionary *userInfo = @{
                NSLocalizedDescriptionKey: @"Link metadata fetch failed",
                @"ExceptionName": exception.name ?: @"",
                @"ExceptionReason": exception.reason ?: @""
            };
            NSError *error = [NSError errorWithDomain:@"com.glacier.linkpreview" code:1 userInfo:userInfo];
            completion(nil, error);
        }
    }
}

@end

