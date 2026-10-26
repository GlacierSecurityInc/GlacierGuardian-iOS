//
//  MediaServer.m
//  ChatSecure
//
//  Created by David Chiles on 2/24/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

#import "MediaServer.h"
@import GCDWebServer;
@import IOCipher;
#import "MediaFileManager.h"

@interface MediaServer ()

@property (nonatomic, strong) GCDWebServer *webServer;
// GCDWebServer refuses to add handlers while it is running, and handlers survive
// a stop/start cycle, so the request handler is installed exactly once.
@property (nonatomic, assign) BOOL handlerInstalled;

@end

@implementation MediaServer

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
    return [MediaFileManager sharedInstance].ioCipher;
}

- (NSDictionary *)serverOptions
{
    return @{GCDWebServerOption_BindToLocalhost: @(YES),
             GCDWebServerOption_AutomaticallySuspendInBackground: @(NO)};
}

- (void)installHandlerIfNeeded
{
    if (self.handlerInstalled) {
        return;
    }
    __weak typeof(self)weakSelf = self;
    [self.webServer addHandlerForMethod:@"GET"
                              pathRegex:[NSString stringWithFormat:@"/%@/.*",kOTRRootMediaDirectory]
                           requestClass:[GCDWebServerRequest class]
                      asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completionBlock) {
                          __strong typeof(weakSelf)strongSelf = weakSelf;
                          [strongSelf handleMediaRequest:request completion:completionBlock];
                      }];
    self.handlerInstalled = YES;
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error
{
    @synchronized (self) {
        [self installHandlerIfNeeded];
        return [self.webServer startWithOptions:[self serverOptions] error:error];
        //return [self.webServer startWithOptionsForExtension:@{GCDWebServerOption_BindToLocalhost: @(YES)}
        //                                  error:error];
    }
}

- (BOOL)ensureRunning
{
    @synchronized (self) {
        if ([self.webServer isRunning]) {
            return YES;
        }
        [self installHandlerIfNeeded];
        return [self.webServer startWithOptions:[self serverOptions] error:NULL];
    }
}

- (void) reconnectWebServer:(NSNotification *)notification
{
    [self ensureRunning];
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
    if ([MediaFileManager sharedInstance].ioCipher != nil) {
        return YES;
    }
    return NO;
}

- (void)handleMediaRequest:(GCDWebServerRequest *)request completion:(GCDWebServerCompletionBlock)completionBlock
{
    if (completionBlock) {
        // Return 404 if the file doesn't exist rather than passing nil to completionBlock,
        // which causes GCDWebServer to emit a 500 Internal Server Error.
        if (![[self ioCipher] fileExistsAtPath:request.path isDirectory:NULL]) {
            completionBlock([GCDWebServerResponse responseWithStatusCode:404]);
            return;
        }
        GCDWebServerVirtualFileResponse *virtualFileResponse = [GCDWebServerVirtualFileResponse responseWithFile:request.path byteRange:request.byteRange isAttachment:NO ioCipher:[self ioCipher]];
        [virtualFileResponse setValue:@"bytes" forAdditionalHeader:@"Accept-Ranges"];
        completionBlock(virtualFileResponse);
    }
}

- (NSURL *)urlForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId {
    NSString *itemPath = [MediaFileManager pathForChatMediaItem:mediaItem buddyUniqueId:buddyUniqueId withLeadingSlash:NO];
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
