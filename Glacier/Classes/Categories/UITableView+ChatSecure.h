//
//  UITableView+ChatSecure.h
//  ChatSecure
//
//  Created by Chris Ballinger on 4/24/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

@import UIKit;
@class ChatThreadModel;

NS_ASSUME_NONNULL_BEGIN
@interface UITableView (ChatSecure)

extern NSString *const ReloadDataNotificationName; 

+ (nullable UISwipeActionsConfiguration *)editActionsForThread:(ChatThreadModel *)thread;

@end
NS_ASSUME_NONNULL_END
