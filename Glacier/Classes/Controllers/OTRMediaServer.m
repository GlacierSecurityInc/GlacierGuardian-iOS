//
//  OTRMediaServer.m
//  ChatSecure
//
//  Created by David Chiles on 2/24/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

#import "OTRMediaServer.h"
@import GCDWebServer;
@import IOCipher;
#import "OTRMediaFileManager.h"

@interface OTRMediaServer ()

@property (nonatomic, strong) GCDWebServer *webServer;

@end

@implementation OTRMediaServer

- (instancetype)init{
    if (self = [super init]) {
        self.webServer = [[GCDWebServer alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reconnectWebServer:) name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (IOCipher *)ioCipher
{
    return [OTRMediaFileManager sharedInstance].ioCipher;
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error
{
    __weak typeof(self)weakSelf = self;
    [self.webServer addHandlerForMethod:@"GET"
                              pathRegex:[NSString stringWithFormat:@"/%@/.*",kOTRRootMediaDirectory]
                           requestClass:[GCDWebServerRequest class]
                      asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
                          __strong typeof(weakSelf)strongSelf = weakSelf;
                          [strongSelf handleMediaRequest:request completion:completionBlock];
                      }];
    return [self.webServer startWithOptions:@{GCDWebServerOption_BindToLocalhost: @(YES),GCDWebServerOption_AutomaticallySuspendInBackground: @(NO)}
                                      error:error];
    //ALF IOSM-328
    //return [self.webServer startWithOptionsForExtension:@{GCDWebServerOption_BindToLocalhost: @(YES)}
    //                                  error:error];
}

- (void) reconnectWebServer:(NSNotification *)notification
{
    if (![self.webServer isRunning]) {
        [self.webServer startWithOptions:@{GCDWebServerOption_BindToLocalhost: @(YES),GCDWebServerOption_AutomaticallySuspendInBackground: @(NO)}
                                          error:NULL];
    }
}

- (void) disconnectWebServer:(void (^)(void))completionHandler
{
    if ([self.webServer isRunning]) {
        //[self.webServer stop];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            [self.webServer stop]; // Your function to handle stop logic after waiting
            completionHandler();
        });
    }
}

- (BOOL) isRunning
{
    return [self.webServer isRunning];
}

- (BOOL) hasFileSystem
{
    if ([OTRMediaFileManager sharedInstance].ioCipher != nil) {
        return YES;
    }
    return NO;
}

- (void)handleMediaRequest:(GCDWebServerRequest *)request completion:(GCDWebServerCompletionBlock)completionBlock
{
    if (completionBlock) {
        GCDWebServerVirtualFileResponse *virtualFileResponse = [GCDWebServerVirtualFileResponse responseWithFile:request.path byteRange:request.byteRange isAttachment:NO ioCipher:[self ioCipher]];
        [virtualFileResponse setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
        completionBlock(virtualFileResponse);
    }
}

- (NSURL *)urlForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId {
    NSString *itemPath = [OTRMediaFileManager pathForChatMediaItem:mediaItem buddyUniqueId:buddyUniqueId withLeadingSlash:NO];
    NSURL *url = [self.webServer serverURL];
    url = [url URLByAppendingPathComponent:itemPath];
    return url;
}

- (NSURL *)urlForPath:(NSString *)path
{
    NSURL *url = [self.webServer serverURL];
    url = [url URLByAppendingPathComponent:path];
    return url;
}

#pragma - mark Class Methods

+ (instancetype)sharedInstance
{
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

@end
