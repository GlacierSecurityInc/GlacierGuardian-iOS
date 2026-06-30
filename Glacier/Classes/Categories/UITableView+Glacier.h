//
//  UITableView+Glacier.h
//  Glacier
//

@import UIKit;
@class ChatThreadModel;

NS_ASSUME_NONNULL_BEGIN
@interface UITableView (Glacier)

extern NSString *const ReloadDataNotificationName;

+ (nullable UISwipeActionsConfiguration *)editActionsForThread:(ChatThreadModel *)thread;

@end
NS_ASSUME_NONNULL_END
