//
//  BuddyImageCell.h
//  Off the Record
//
//  Created by David Chiles on 3/3/14.
//  Copyright (c) 2014 Chris Ballinger. All rights reserved.
//

@import UIKit;
@class ChatRoomModel, ChatBuddyModel;

extern const CGFloat BuddyImageCellPadding;

@interface BuddyImageCell : UITableViewCell

@property (nonatomic, strong, readonly) UIImageView *avatarImageView;
@property (nonatomic, strong, readonly) UIImageView *unreadImageView;
@property (nonatomic, strong) UIColor *imageViewBorderColor;
@property (nonatomic, readonly) BOOL addedConstraints;

//- (void)setThread:(ChatThreadModel *)thread;
- (void)setRoomThread:(ChatRoomModel *)room;
- (void)setBuddyThread:(ChatBuddyModel *)buddy;
- (void)setConstraintsAdded;

- (void) markUnread;
- (void) markRead;

+ (NSString *)reuseIdentifier;

@end
