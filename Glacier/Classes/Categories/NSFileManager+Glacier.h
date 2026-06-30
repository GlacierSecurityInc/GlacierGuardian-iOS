//
//  NSFileManager+Glacier.h
//  Glacier
//

@import Foundation;

@interface NSFileManager (Glacier)

- (BOOL)setFileProtection:(NSString *)fileProtection forFilesInDirectory:(NSString *)directory;
- (BOOL)excludeFromBackupFilesInDirectory:(NSString *)directory;
- (BOOL)setExcludeBackUpFilesInDirectory:(NSString *)directory shouldExclude:(BOOL)exclude;

@end
