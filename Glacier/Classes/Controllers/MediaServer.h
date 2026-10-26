//
//  MediaServer.h
//  ChatSecure
//
//  Created by David Chiles on 2/24/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import Foundation;

@class ChatMediaItemModel;

@interface MediaServer : NSObject

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error;

/// Starts the web server if it isn't already running, and returns whether it is
/// running once it returns. Safe to call from any thread, any number of times.
/// Callers that need a URL should use this before asking for one: with the server
/// stopped, -urlForPath: and -urlForChatMediaItem: can only return nil.
- (BOOL)ensureRunning;

- (NSURL *)urlForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId;

- (NSURL *)urlForPath:(NSString *)path;

- (void) disconnectWebServer:(void (^)(void))completionHandler;

- (BOOL) isRunning;
- (BOOL) hasFileSystem;

+ (instancetype)sharedInstance;

@end
