#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface GlacierICEInterfacePolicy : NSObject
+ (void)startMonitoring;
+ (BOOL)install;
+ (uint64_t)enumerationCount;
@end
NS_ASSUME_NONNULL_END
