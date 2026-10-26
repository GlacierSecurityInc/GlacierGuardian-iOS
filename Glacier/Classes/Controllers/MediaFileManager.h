//
//  MediaFileManager.h
//  ChatSecure
//
//  Created by David Chiles on 2/19/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import Foundation;

@class IOCipher, ChatMediaItemModel, SMSChatMediaItemModel;

NS_ASSUME_NONNULL_BEGIN
extern NSString *const kOTRRootMediaDirectory;

@interface MediaFileManager : NSObject

@property (nonatomic, strong, readonly) IOCipher *ioCipher;

- (BOOL)setupWithPath:(NSString *)path password:(NSString *)password salt:(NSString *)salt;

- (void)releaseDBConnection;

- (void)copyDataFromFilePath:(NSString *)filePath
             toEncryptedPath:(NSString *)path
                  completion:(void (^)(BOOL success, NSError * _Nullable error))completion
             completionQueue:(nullable dispatch_queue_t)completionQueue;

- (void)setData:(NSData *)data
    forChatItem:(ChatMediaItemModel *)mediaItem
  buddyUniqueId:(NSString *)buddyUniqueId
     completion:(void (^)(NSInteger bytesWritten, NSError * _Nullable error))completion
completionQueue:(nullable dispatch_queue_t)completionQueue;

- (void)setData:(NSData *)data
        forItem:(SMSChatMediaItemModel *)mediaItem
  smsUniqueId:(NSString *)buddyUniqueId
     completion:(void (^)(NSInteger bytesWritten, NSError * _Nullable error))completion
completionQueue:(nullable dispatch_queue_t)completionQueue;

- (nullable NSData*)dataForChatItem:(ChatMediaItemModel *)mediaItem
                      buddyUniqueId:(NSString *)buddyUniqueId
                             error:(NSError* __autoreleasing *)error;
- (nullable NSData*)smsDataForItem:(SMSChatMediaItemModel *)mediaItem
                       smsUniqueId:(NSString *)smsUniqueId
                             error:(NSError* __autoreleasing *)error;

- (BOOL) fileExistsForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId;

/**
 *  Streams the decrypted contents of a chat media item out to a plaintext file on
 *  the regular file system. Data is copied in chunks so large media (e.g. video)
 *  is never held in memory all at once. The caller is responsible for deleting the
 *  destination file when finished with it.
 *
 *  @param mediaItem     the media item to export
 *  @param buddyUniqueId the thread/buddy unique id used to resolve the media path
 *  @param destinationURL a file URL to write the decrypted bytes to
 *  @param error         populated on failure
 *
 *  @return YES on success, NO on failure
 */
- (BOOL)exportChatItem:(ChatMediaItemModel *)mediaItem
         buddyUniqueId:(NSString *)buddyUniqueId
             toFileURL:(NSURL *)destinationURL
                 error:(NSError * __autoreleasing *)error;

+ (nullable NSString *)pathForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId;
+ (nullable NSString *)pathForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId withLeadingSlash:(BOOL)includeLeadingSlash;

+ (nullable NSString *)pathForSmsMediaItem:(SMSChatMediaItemModel *)mediaItem smsUniqueId:(NSString *)smsUniqueId;
+ (nullable NSString *)pathForSmsMediaItem:(SMSChatMediaItemModel *)mediaItem smsUniqueId:(NSString *)smsUniqueId withLeadingSlash:(BOOL)includeLeadingSlash;

- (void)vacuum:(dispatch_block_t)completion;

@property (class, nonatomic, readonly) MediaFileManager *shared;

+ (instancetype)sharedInstance;

@end
NS_ASSUME_NONNULL_END
