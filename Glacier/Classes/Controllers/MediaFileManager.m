//
//  MediaFileManager.m
//  ChatSecure
//
//  Created by David Chiles on 2/19/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

#import "MediaFileManager.h"
@import IOCipher;
#import "GlacierConstants.h"
#import "Glacier-Swift.h"

NSString *const kOTRRootMediaDirectory = @"media";

@interface MediaFileManager () {
    void *IsOnInternalQueueKey;
}

@property (nonatomic) dispatch_queue_t concurrentQueue;

/** Uses dispatch_barrier_async. Will perform block asynchronously on the internalQueue, unless we're already on internalQueue */
- (void) performAsyncWrite:(dispatch_block_t)block;

/** Uses dispatch_sync. Will perform block synchronously on the internalQueue and block for result if called on another queue. */
- (void) performSyncRead:(dispatch_block_t)block;

/** Uses dispatch_barrier_sync. Drains the queue, runs the block with exclusive access,
    and blocks for the result, unless we're already on internalQueue. */
- (void) performBarrierSync:(dispatch_block_t)block;

@end

@implementation MediaFileManager

- (instancetype)init
{
    if (self = [super init]) {
        // We use dispatch_barrier_async with a concurrent queue to allow for multiple-read single-write.
        _concurrentQueue = dispatch_queue_create(NSStringFromClass(self.class).UTF8String, DISPATCH_QUEUE_CONCURRENT);
        
        // For safe usage of dispatch_sync
        IsOnInternalQueueKey = &IsOnInternalQueueKey;
        void *nonNullUnusedPointer = (__bridge void *)self;
        dispatch_queue_set_specific(_concurrentQueue, IsOnInternalQueueKey, nonNullUnusedPointer, NULL);
        
    }
    return self;
}

#pragma - mark Public Methods

- (BOOL)setupWithPath:(NSString *)path password:(NSString *)password salt:(NSString *)salt
{
    __block BOOL success = NO;
    // Release the previous volume *before* opening the new one, with the queue drained.
    // -[IOCipher dealloc] reaches sqlfs_close(), which mutates libsqlfs process-global
    // state -- the pthread key and cached password that every sqlfs_proc_* call depends
    // on, since IOCipher passes a NULL handle and lets libsqlfs resolve a per-thread one.
    // Letting the assignment release the old instance ran that teardown *after* the new
    // instance had initialized those globals, so subsequent reads and writes resolved a
    // NULL handle and faulted. The barrier additionally keeps any in-flight operation
    // from straddling the swap.
    [self performBarrierSync:^{
        self->_ioCipher = nil;
        IOCipher *cipher = [[IOCipher alloc] initWithPath:path password:password salt:salt];
        if (!cipher) {
            return;
        }
        self->_ioCipher = cipher;
        success = [cipher setCipherCompatibility:3];
    }];
    return success;
}

- (void)releaseDBConnection {
    [self performBarrierSync:^{
        self->_ioCipher = nil;
    }];
}

- (void)copyDataFromFilePath:(NSString *)filePath
             toEncryptedPath:(NSString *)path
                  completion:(void (^)(BOOL success, NSError * _Nullable error))completion
             completionQueue:(nullable dispatch_queue_t)completionQueue
{
    if (!completionQueue) {
        completionQueue = dispatch_get_main_queue();
    }
    __weak typeof(self)weakSelf = self;
    [self performAsyncWrite:^{
        __strong typeof(weakSelf)strongSelf = weakSelf;
        
        NSError *error = nil;
        BOOL result = [strongSelf.ioCipher copyItemAtFileSystemPath:filePath toEncryptedPath:path error:&error];
        
        if (completion) {
            dispatch_async(completionQueue, ^{
                completion(result, error);
            });
        }
    }];
}

- (void)setData:(NSData *)data
    forChatItem:(ChatMediaItemModel *)mediaItem
  buddyUniqueId:(NSString *)buddyUniqueId
     completion:(void (^)(NSInteger bytesWritten, NSError * _Nullable error))completion
completionQueue:(nullable dispatch_queue_t)completionQueue {
    NSString *path = [[self class] pathForChatMediaItem:mediaItem buddyUniqueId:buddyUniqueId];
    [self setData:data forPath:path completion:completion completionQueue:completionQueue];
}

- (void)setData:(NSData *)data
        forItem:(SMSChatMediaItemModel *)mediaItem
  smsUniqueId:(NSString *)smsConversationUniqueId
     completion:(void (^)(NSInteger bytesWritten, NSError * _Nullable error))completion
completionQueue:(nullable dispatch_queue_t)completionQueue {
    NSString *path = [[self class] pathForSmsMediaItem:mediaItem smsUniqueId:smsConversationUniqueId];
    [self setData:data forPath:path completion:completion completionQueue:completionQueue];
}

- (void)setData:(NSData *)data
        forPath:(NSString *)path
     completion:(void (^)(NSInteger bytesWritten, NSError * _Nullable error))completion
completionQueue:(nullable dispatch_queue_t)completionQueue {
    if (!completionQueue) {
        completionQueue = dispatch_get_main_queue();
    }
    [self performAsyncWrite:^{
        if (![path length]) {
            NSError *error = [NSError errorWithDomain:kGlacierErrorDomain code:150 userInfo:@{NSLocalizedDescriptionKey:@"Unable to create file path"}];
            dispatch_async(completionQueue, ^{
                completion(-1,error);
            });
            return;
        }
        
        BOOL fileExists = [self.ioCipher fileExistsAtPath:path isDirectory:NULL];
        
        if (fileExists) {
            NSError *error = nil;
            [self.ioCipher removeItemAtPath:path error:&error];
            if (error) {
                NSError *error = [NSError errorWithDomain:kGlacierErrorDomain code:151 userInfo:@{NSLocalizedDescriptionKey:@"Unable to remove existing file"}];
                dispatch_async(completionQueue, ^{
                    completion(-1,error);
                });
                return;
            }
        }
        
        NSError *error = nil;
        BOOL created = [self.ioCipher createFileAtPath:path error:&error];
        if (!created) {
            NSError *error = [NSError errorWithDomain:kGlacierErrorDomain code:152 userInfo:@{NSLocalizedDescriptionKey:@"Unable to create file"}];
            dispatch_async(completionQueue, ^{
                completion(-1,error);
            });
            return;
        }
        __block NSInteger written = [self.ioCipher writeDataToFileAtPath:path data:data offset:0 error:&error];
        
        dispatch_async(completionQueue, ^{
            completion(written, error);
        });

    }];
}

- (nullable NSData*)dataForFilePath:(NSString *)filePath
                              error:(NSError* __autoreleasing *)error
                             length:(NSNumber* __autoreleasing *)length {
    __block NSData *data = nil;
    __block NSNumber *dataLength = nil;
    [self performSyncRead:^{
        BOOL fileExists = [self.ioCipher fileExistsAtPath:filePath isDirectory:nil];
        if (!fileExists) {
            if (error) {
                *error = [NSError errorWithDomain:kGlacierErrorDomain code:151 userInfo:@{NSLocalizedDescriptionKey:@"File does not exist!"}];
            }
            return;
        }
        NSDictionary *fileAttributes = [self.ioCipher fileAttributesAtPath:filePath error:error];
        if (error && *error) {
            return;
        }
        if (length != nil) {
            dataLength = fileAttributes[NSFileSize];
        } else {
            NSNumber *length = fileAttributes[NSFileSize];
            data = [self.ioCipher readDataFromFileAtPath:filePath length:length.integerValue offset:0 error:error];
        }
    }];
    if (length != nil) {
        *length = dataLength;
    }
    return data;
}

- (BOOL) fileExistsForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId {
    __block BOOL fileExists = NO;
    NSString *filePath = [[self class] pathForChatMediaItem:mediaItem buddyUniqueId:buddyUniqueId];
    if (!filePath) {
        return fileExists;
    }
    
    [self performSyncRead:^{
        fileExists = [self.ioCipher fileExistsAtPath:filePath isDirectory:nil];
    }];
    
    return fileExists;
}

- (BOOL)exportChatItem:(ChatMediaItemModel *)mediaItem
         buddyUniqueId:(NSString *)buddyUniqueId
             toFileURL:(NSURL *)destinationURL
                 error:(NSError * __autoreleasing *)error {
    NSString *filePath = [[self class] pathForChatMediaItem:mediaItem buddyUniqueId:buddyUniqueId];
    if (!filePath) {
        if (error) {
            *error = [NSError errorWithDomain:kGlacierErrorDomain code:150 userInfo:@{NSLocalizedDescriptionKey:@"Unable to create file path"}];
        }
        return NO;
    }

    __block BOOL success = NO;
    __block NSError *blockError = nil;
    // ~4 MB chunks so large videos are never fully resident in memory.
    static const NSUInteger kChunkSize = 4 * 1024 * 1024;

    [self performSyncRead:^{
        if (![self.ioCipher fileExistsAtPath:filePath isDirectory:nil]) {
            blockError = [NSError errorWithDomain:kGlacierErrorDomain code:151 userInfo:@{NSLocalizedDescriptionKey:@"File does not exist!"}];
            return;
        }

        NSDictionary *fileAttributes = [self.ioCipher fileAttributesAtPath:filePath error:&blockError];
        if (blockError) {
            return;
        }
        NSUInteger totalLength = [fileAttributes[NSFileSize] unsignedIntegerValue];

        // Start from an empty destination file.
        [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
        if (![[NSFileManager defaultManager] createFileAtPath:destinationURL.path contents:nil attributes:nil]) {
            blockError = [NSError errorWithDomain:kGlacierErrorDomain code:152 userInfo:@{NSLocalizedDescriptionKey:@"Unable to create destination file"}];
            return;
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:destinationURL.path];
        if (!handle) {
            blockError = [NSError errorWithDomain:kGlacierErrorDomain code:153 userInfo:@{NSLocalizedDescriptionKey:@"Unable to open destination file"}];
            return;
        }

        NSUInteger offset = 0;
        while (offset < totalLength) {
            NSUInteger readLength = MIN(kChunkSize, totalLength - offset);
            NSData *chunk = [self.ioCipher readDataFromFileAtPath:filePath length:readLength offset:offset error:&blockError];
            if (blockError || chunk == nil) {
                break;
            }
            if (chunk.length == 0) {
                // Nothing more to read; avoid spinning if the reported size was stale.
                break;
            }
            @try {
                [handle writeData:chunk];
            } @catch (NSException *exception) {
                blockError = [NSError errorWithDomain:kGlacierErrorDomain code:154 userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Unable to write destination file"}];
                break;
            }
            offset += chunk.length;
        }
        [handle closeFile];

        if (blockError) {
            [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
            return;
        }
        success = YES;
    }];

    if (!success && error) {
        *error = blockError;
    }
    return success;
}

/* Internal. If "length" is set, only return the length of the data, otherwise the data ifself */
- (nullable NSData*)dataForChatItem:(ChatMediaItemModel *)mediaItem
                      buddyUniqueId:(NSString *)buddyUniqueId
                              error:(NSError* __autoreleasing *)error
                             length:(NSNumber* __autoreleasing *)length {
    NSString *filePath = [[self class] pathForChatMediaItem:mediaItem buddyUniqueId:buddyUniqueId];
    if (!filePath) {
        if (error) {
            *error = [NSError errorWithDomain:kGlacierErrorDomain code:150 userInfo:@{NSLocalizedDescriptionKey:@"Unable to create file path"}];
        }
        return nil;
    }
        
    return [self dataForFilePath:filePath error:error length:length];
}

- (nullable NSData*)dataForChatItem:(ChatMediaItemModel *)mediaItem
                      buddyUniqueId:(NSString *)buddyUniqueId
                             error:(NSError* __autoreleasing *)error {
    return [self dataForChatItem:mediaItem buddyUniqueId:buddyUniqueId error:error length:nil];
}

/* Internal. If "length" is set, only return the length of the data, otherwise the data ifself */
- (nullable NSData*)smsDataForItem:(SMSChatMediaItemModel *)mediaItem
                       smsUniqueId:(NSString *)smsUniqueId
                             error:(NSError* __autoreleasing *)error
                            length:(NSNumber* __autoreleasing *)length {
    NSString *filePath = [[self class] pathForSmsMediaItem:mediaItem smsUniqueId:smsUniqueId];
    if (!filePath) {
        if (error) {
            *error = [NSError errorWithDomain:kGlacierErrorDomain code:150 userInfo:@{NSLocalizedDescriptionKey:@"Unable to create file path"}];
        }
        return nil;
    }
        
    return [self dataForFilePath:filePath error:error length:length];
}

- (nullable NSData*)smsDataForItem:(SMSChatMediaItemModel *)mediaItem
                       smsUniqueId:(NSString *)smsUniqueId
                             error:(NSError* __autoreleasing *)error {
    return [self smsDataForItem:mediaItem smsUniqueId:smsUniqueId error:error length:nil];
}

#pragma - mark Class Methods

+ (MediaFileManager*) shared {
    return [self sharedInstance];
}

+ (instancetype)sharedInstance
{
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    
    return sharedInstance;
}

+ (nullable NSString *)pathForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId
{
    return [self pathForChatMediaItem:mediaItem buddyUniqueId:buddyUniqueId withLeadingSlash:YES];
}

+ (nullable NSString *)pathForChatMediaItem:(ChatMediaItemModel *)mediaItem buddyUniqueId:(NSString *)buddyUniqueId withLeadingSlash:(BOOL)includeLeadingSlash
{
    NSString *filename = [mediaItem getFilename];
    // ChatHTMLItem stores the link URL as its filename (e.g. "https://youtube.com/watch?v=abc").
    // Using a raw URL as a file path component creates an invalid nested directory structure
    // in IOCipher (the URL scheme/host become subdirs that are never created), causing
    // setData to fail silently and the local media server to return 500 for every render.
    // The uniqueId is already a unique path component, so we just need a safe filename here.
    if ([filename hasPrefix:@"http://"] || [filename hasPrefix:@"https://"]) {
        filename = @"preview.jpg";
    }
    if ([buddyUniqueId length] && [mediaItem.uniqueId length] && (filename != nil)) {
        NSString *path = [NSString pathWithComponents:@[kOTRRootMediaDirectory,buddyUniqueId,mediaItem.uniqueId,filename]];
        if (includeLeadingSlash) {
            return [NSString stringWithFormat:@"/%@",path];
        }
        return path;
    }
    return nil;
}

+ (nullable NSString *)pathForSmsMediaItem:(SMSChatMediaItemModel *)mediaItem smsUniqueId:(NSString *)smsUniqueId
{
    return [self pathForSmsMediaItem:mediaItem smsUniqueId:smsUniqueId withLeadingSlash:YES];
}

+ (nullable NSString *)pathForSmsMediaItem:(SMSChatMediaItemModel *)mediaItem smsUniqueId:(NSString *)smsUniqueId withLeadingSlash:(BOOL)includeLeadingSlash
{
    NSString *filename = [mediaItem getFilename];
    if ([smsUniqueId length] && [mediaItem.uniqueId length] && (filename != nil)) {
        NSString *path = [NSString pathWithComponents:@[kOTRRootMediaDirectory,smsUniqueId,mediaItem.uniqueId,filename]];
        if (includeLeadingSlash) {
            return [NSString stringWithFormat:@"/%@",path];
        }
        return path;
    }
    return nil;
}


#pragma mark Utility

/** Will perform block synchronously on the internalQueue and block for result if called on another queue. */
- (void) performSyncRead:(dispatch_block_t)block {
    NSParameterAssert(block != nil);
    if (!block) { return; }
    if (dispatch_get_specific(IsOnInternalQueueKey)) {
        block();
    } else {
        dispatch_sync(_concurrentQueue, block);
    }
}

/** Will drain the internalQueue and perform block with exclusive access, blocking for
    the result, unless we're already on internalQueue */
- (void) performBarrierSync:(dispatch_block_t)block {
    NSParameterAssert(block != nil);
    if (!block) { return; }
    if (dispatch_get_specific(IsOnInternalQueueKey)) {
        block();
    } else {
        dispatch_barrier_sync(_concurrentQueue, block);
    }
}

/** Will perform block asynchronously on the internalQueue, unless we're already on internalQueue */
- (void) performAsyncWrite:(dispatch_block_t)block {
    NSParameterAssert(block != nil);
    if (!block) { return; }
    if (dispatch_get_specific(IsOnInternalQueueKey)) {
        block();
    } else {
        dispatch_barrier_async(_concurrentQueue, block);
    }
}

- (void)vacuum:(dispatch_block_t)completion {
    [self performAsyncWrite:^{
        [self.ioCipher vacuum];
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    }];
}

@end
