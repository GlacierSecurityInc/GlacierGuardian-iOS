//
//  LockButton.m
//  Off the Record
//
//  Created by David Chiles on 2/10/14.
//  Copyright (c) 2014 Chris Ballinger. All rights reserved.
//

#import "LockButton.h"
#import "GlacierInfo.h"

static NSString *const kOTRLockImageName            = @"Lock_Locked";
static NSString *const kOTRLockAndVerifiedImageName = @"Lock_Locked_Verified";
static NSString *const kOTRLockedAndErrorImageName  = @"Lock_Locked_red";
static NSString *const kOTRLockedAndWarnImageName   = @"Lock_Locked_yellow";
static NSString *const kOTRUnlockImageName          = @"Lock_Unlocked";

typedef void (^ButtonBlock)(id sender);

@interface LockButton ()

@property (nonatomic, strong) ButtonBlock blockAction;

@end


@implementation LockButton

- (void)setLockStatus:(GlacierLockStatus)lockStatus
{
    UIImage * backgroundImage = nil;
    
    switch (lockStatus) {
        case GlacierLockStatusUnlocked:
            backgroundImage = [UIImage imageNamed:kOTRUnlockImageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
            break;
        case GlacierLockStatusLockedAndVerified:
            backgroundImage = [UIImage imageNamed:kOTRLockAndVerifiedImageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
            break;
        case GlacierLockStatusLockedAndError:
            backgroundImage = [UIImage imageNamed:kOTRLockedAndErrorImageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
            break;
        case GlacierLockStatusLockedAndWarn:
            backgroundImage = [UIImage imageNamed:kOTRLockedAndWarnImageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
            break;
        case GlacierLockStatusLocked:
            backgroundImage = [UIImage imageNamed:kOTRLockImageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
            break;
        default:
            backgroundImage = [UIImage imageNamed:kOTRUnlockImageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
            break;
    }
    
    CGRect buttonFrame = [self frame];
    
    buttonFrame.size.width = backgroundImage.size.width;
    buttonFrame.size.height = backgroundImage.size.height;
    [self setFrame:buttonFrame];
    
    [self setBackgroundImage:nil forState:UIControlStateNormal]; 
    
    [self willChangeValueForKey:NSStringFromSelector(@selector(lockStatus))];
    _lockStatus = lockStatus;
    [self didChangeValueForKey:NSStringFromSelector(@selector(lockStatus))];
}

#pragma - MARK block handler

-(void) handleControlEvent:(UIControlEvents)event
                 withBlock:(ButtonBlock) block
{
    self.blockAction = block;
    [self addTarget:self action:@selector(callBlock:) forControlEvents:event];
}

-(void) callBlock:(id)sender{
    if (self.blockAction) {
        self.blockAction(sender);
    }
}

+(instancetype)lockButtonWithInitailLockStatus:(GlacierLockStatus)lockStatus withBlock:(void(^)(GlacierLockStatus currentStatus))block
{
    LockButton * lockButton = [self buttonWithType:UIButtonTypeCustom];
    lockButton.lockStatus = lockStatus;
    
    [lockButton handleControlEvent:UIControlEventTouchUpInside withBlock:^(id sender) {
        if (block) {
            GlacierLockStatus status = GlacierLockStatusUnknown;
            if ([sender isKindOfClass:[LockButton class]]) {
                status = ((LockButton *)sender).lockStatus;
            }
            
            block(status);
        }
    }];
    return lockButton;
}
@end
