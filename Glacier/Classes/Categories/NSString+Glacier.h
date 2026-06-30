//
//  NSString+Glacier.h
//  Glacier
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN
@interface NSString (Glacier)

- (nullable NSString *)stringInitialsWithMaxCharacters:(NSUInteger)maxCharacters;
- (NSString *)stringByRemovingNonEnglishCharacters;
/** Cleans up a JID from "user@example.com" -> "User" */
- (nullable NSString *)glacierDisplayName;

@end
NS_ASSUME_NONNULL_END
