//
//  UITableView+ChatSecure.m
//  ChatSecure
//
//  Created by Chris Ballinger on 4/24/17.
//  Copyright © 2017 Chris Ballinger. All rights reserved.
//

#import "UITableView+ChatSecure.h"
#import "Glacier-Swift.h"
#import "OTRXMPPManager_Private.h"
@import MBProgressHUD;

@implementation UITableView (ChatSecure)

NSString *const ReloadDataNotificationName = @"ReloadDataNotificationName";

/** Connection must be read-write */
// from UITableViewRowAction
+ (nullable UISwipeActionsConfiguration*)editActionsForThread:(ChatThreadModel *)thread {
    NSParameterAssert(thread);
    if (!thread) {
        return nil;
    }
    
    NSString *deleteTitle = DELETE_STRING();
    if ([thread isGroupThread]) {
        deleteTitle = LEAVE_GROUP_STRING();
    }
    
    // fixed deprecation and added action sheet confirmation
    __weak typeof(self)weakSelf = self;
    UIContextualAction *contextItem = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:deleteTitle handler:^ (UIContextualAction * _Nonnull action, __kindof UIView * _Nonnull sourceView, void (^ _Nonnull completionHandler)(BOOL)) {
        
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Are you sure you want to leave this chat?" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        UIAlertAction* leaveAction = [UIAlertAction actionWithTitle:deleteTitle style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
            __strong typeof(weakSelf)strongSelf = weakSelf;
            [strongSelf performDeleteAction:thread];
        }];
        UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        }];

        [alertController addAction:leaveAction];
        [alertController addAction:cancelAction];
        [OTRAppDelegate.appDelegate.window.rootViewController presentViewController:alertController animated:YES completion:nil];
        completionHandler(YES);
    }];
    contextItem.backgroundColor = [UIColor redColor];
    UISwipeActionsConfiguration *swipeConfig = [UISwipeActionsConfiguration configurationWithActions:@[contextItem]];
    swipeConfig.performsFirstActionWithFullSwipe = NO;
    return swipeConfig;
}

#if !TARGET_IS_EXTENSION
+ (void) performDeleteAction:(ChatThreadModel *)thread {
    if ([thread isGroupThread]) {
        
        MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[OTRAppDelegate appDelegate].window animated:YES];
        
        ChatRoomModel *room = [ChatRoomModel roomFromThread:thread];
        //Leave room
        int64_t accountKey = [thread threadAccountIdentifier];
        ChatAccountModel *account = [ChatAccountModel getChatAccount:accountKey];
        id<MessageProtocol> message;
        
        if (account) {
            NSString *left = [account.displayName stringByAppendingString:@" left the group"];
            message = [room outgoingMessageWithText:left];
        }
        OTRXMPPManager *xmppManager = (OTRXMPPManager *)[[OTRProtocolManager sharedInstance] xmppManagerForChatAccount:account];
        
        XMPPRoom *xroom = [xmppManager.roomManager roomForJID:room.roomJID];
        XMPPJID *jid = [XMPPJID jidWithString:account.username];
        [xroom unsubscribeFromRoom:jid];
        
        [xmppManager.roomManager removeRoomsFromBookmarks:@[room]];
        
        if (message != nil) { [xmppManager enqueueMessage:message]; }
        // wrapped in dispatch to give time for enqueued message
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (room.roomJID) {
                [xmppManager.roomManager leaveRoom:room.roomJID];
            }
            
            //Delete database items - ChatThread is also removed in room.remove, not accessible by ObjC
            [room removeRoom];//removeWithCompletionBlock:^{}];
            
            // reload table view to get screen events working
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:ReloadDataNotificationName object:self userInfo:nil];
                
                [hud removeFromSuperview];
            });
        });
    } else {
        ChatBuddyModel *buddy = [ChatBuddyModel buddyFromThread:thread];
        if (buddy) {
            [ChatMessageModel deleteAllMessagesForBuddy:buddy.uniqueId chatThreadId: buddy.chatThreadId];
        }
    }
}
#endif

@end
