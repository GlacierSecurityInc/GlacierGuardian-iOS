//
//  LockButton.h
//  Off the Record
//
//  Created by David Chiles on 2/10/14.
//  Copyright (c) 2014 Chris Ballinger. All rights reserved.
//

@import UIKit;

typedef NS_ENUM(NSUInteger, GlacierLockStatus) {
    GlacierLockStatusUnknown,
    GlacierLockStatusLocked,
    GlacierLockStatusLockedAndVerified,
    GlacierLockStatusLockedAndWarn,
    GlacierLockStatusLockedAndError,
    GlacierLockStatusUnlocked,
    
};

@interface LockButton : UIButton

@property (nonatomic) GlacierLockStatus lockStatus;

+(instancetype)lockButtonWithInitailLockStatus:(GlacierLockStatus)lockStatus withBlock:(void(^)(GlacierLockStatus currentStatus))block;

@end
