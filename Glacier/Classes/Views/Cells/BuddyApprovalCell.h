//
//  BuddyApprovalCell.h
//  ChatSecure
//
//  Created by Chris Ballinger on 6/1/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

#import "BuddyInfoCell.h"
@import BButton;

@interface BuddyApprovalCell : BuddyInfoCell

@property (nonatomic, strong) BButton *approveButton;
@property (nonatomic, strong) BButton *denyButton;
@property (nonatomic, copy) void (^actionBlock)(BuddyApprovalCell *cell, BOOL approved);

@end
