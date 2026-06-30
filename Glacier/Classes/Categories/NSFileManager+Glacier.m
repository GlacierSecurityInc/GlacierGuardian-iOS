//
//  NSFileManager+Glacier.m
//  Glacier
//

#import "NSFileManager+Glacier.h"

@implementation NSFileManager (Glacier)

- (void)enumerateFilesInDirectory:(NSString *)directory block:(void (^)(NSString *fullPath, BOOL *stop))enumerateBlock
{
    BOOL isDirecotry = NO;
    BOOL exists = [self fileExistsAtPath:directory isDirectory:&isDirecotry];
    if (enumerateBlock && isDirecotry && exists) {
        NSDirectoryEnumerator *directoryEnumerator = [self enumeratorAtPath:directory];
        NSString *file = nil;
        BOOL stop = NO;
        while ((file = [directoryEnumerator nextObject]) && !stop) {
            NSString *path = [NSString pathWithComponents:@[directory, file]];
            enumerateBlock(path, &stop);
        }
    }
}

- (BOOL)setFileProtection:(NSString *)fileProtection forFilesInDirectory:(NSString *)directory
{
    __block BOOL success = YES;
    [self enumerateFilesInDirectory:directory block:^(NSString *fullPath, BOOL *stop) {
        success = [self setAttributes:@{NSFileProtectionKey: fileProtection}
                         ofItemAtPath:fullPath error:nil];
        *stop = !success;
    }];
    return success;
}

- (BOOL)excludeFromBackupFilesInDirectory:(NSString *)directory
{
    return [self setExcludeBackUpFilesInDirectory:directory shouldExclude:YES];
}

- (BOOL)setExcludeBackUpFilesInDirectory:(NSString *)directory shouldExclude:(BOOL)exclude
{
    __block BOOL success = YES;
    [self enumerateFilesInDirectory:directory block:^(NSString *fullPath, BOOL *stop) {
        success = [self setAttributes:@{NSURLIsExcludedFromBackupKey: @(exclude)} ofItemAtPath:fullPath error:nil];
        if (success) {
            success = [self addSkipBackupAttributeToItemAtURL:[NSURL fileURLWithPath:fullPath] shouldExclude:exclude];
        }
        *stop = !success;
    }];
    return success;
}

- (BOOL)addSkipBackupAttributeToItemAtURL:(NSURL *)URL shouldExclude:(BOOL)exclude
{
    assert([self fileExistsAtPath:[URL path]]);
    NSError *error = nil;
    BOOL success = [URL setResourceValue:[NSNumber numberWithBool:exclude]
                                  forKey:NSURLIsExcludedFromBackupKey error:&error];
    if (!success) {
        NSLog(@"Error excluding %@ from backup %@", [URL lastPathComponent], error);
    }
    return success;
}

@end
