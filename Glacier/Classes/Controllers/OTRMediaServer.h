//
//  OTRMediaServer.h
//  ChatSecure
//
//  Created by David Chiles on 2/24/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import Foundation;

@class ChatMediaItemModel;

@interface OTRMediaServer : NSObject

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error;

- (NSURL *)urlForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId;

- (NSURL *)urlForPath:(NSString *)path;

- (void) disconnectWebServer:(void (^)(void))completionHandler;

- (BOOL) isRunning;
- (BOOL) hasFileSystem;

+ (instancetype)sharedInstance;

@end
