//
//  OTRAppDelegate.h
//  Off the Record
//
//  Created by Chris Ballinger on 8/11/11.
//  Copyright (c) 2011 Chris Ballinger. All rights reserved.
//
//  This file is part of ChatSecure.
//
//  ChatSecure is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ChatSecure is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ChatSecure.  If not, see <http://www.gnu.org/licenses/>.

@import UIKit;
#import "OTRProtocol.h"

@class OTRSplitViewCoordinator, ConversationViewController, ChatViewController, ChatRoomViewController, SMSViewController, SMSChatViewController, SMSSplitViewCoordinator, OTRSettingsViewController, SecurityCenterViewController, DialerViewController, ContactsViewController, HistoryViewController;
@protocol AppTheme;

NS_ASSUME_NONNULL_BEGIN

@interface OTRAppDelegate : UIResponder <UIApplicationDelegate>

@property (nonatomic, strong, readonly) ConversationViewController *conversationViewController;
@property (nonatomic, strong, readonly) ChatViewController *chatViewController;
@property (nonatomic, strong, readonly) ChatRoomViewController *chatRoomViewController;
//@property (nonatomic, strong, readonly) UIViewController *chatRoomViewController;
@property (nonatomic, strong, readonly) OTRSplitViewCoordinator *splitViewCoordinator;

@property (assign, nonatomic) BOOL smsEnabled;
@property (nonatomic, strong, readonly) SMSSplitViewCoordinator *smsSplitViewCoordinator;
@property (nonatomic, strong, readonly) SMSViewController *smsViewController;
@property (nonatomic, strong, readonly) SMSChatViewController *smsMessagesViewController;
@property (nonatomic, strong, readonly) OTRSettingsViewController *settingsViewController;

@property (nonatomic, strong, readonly) UINavigationController *securityHubViewController;
extern NSString *const SMSEnabledNotificationName; 
extern NSString *const NetworkStatusNotificationName;
extern NSString *const OldNetworkStatusKey;
extern NSString *const NewNetworkStatusKey;

@property (nonatomic, strong, readonly) UINavigationController *dialerViewController;
@property (nonatomic, strong, readonly) UINavigationController *contactsViewController;
@property (nonatomic, strong, readonly) UINavigationController *historyViewController;

// A window to show call screens
@property (nonatomic, strong, nullable) UIWindow *callWindow;

// timer flag to handle double notifications
@property (assign, nonatomic) BOOL doubleDone;
@property (assign, nonatomic) BOOL groupReadReady;
@property (assign, nonatomic) BOOL silentUpdate;
@property (assign, nonatomic) BOOL voipNotification;
@property (assign, nonatomic) BOOL amplifyIsConfigured;

@property (assign, nonatomic) BOOL isGroupChatController;

@property (assign, nonatomic) BOOL resortNeeded;
@property (nonatomic, strong) NSMutableSet<NSString *> *handledCallIDs;
//- (void) setResortHandler;

- (void) resetDoubleNotificationHandlerIfNeeded;

/** Only used from Database Unlock view. */
//- (void) showConversationViewController;
- (void)setDomain:(NSString *)address;
- (void)bypassNetworkCheck:(BOOL)bypass;
- (void) checkConnectionOrTryLogin;
- (void) doSettingsController; // (next 2)
- (void) setSMSEnabled:(BOOL)enabled;
- (void) resetSMS;
- (void) setSecurityHubEnabled:(BOOL)enabled;
// (OTRNetworkConnectionStatus) getCurrentNetworkStatus; // commented out
- (BOOL) tryOpenURL:(NSURL*)url;
- (void) goGlacierVoice;
- (void) enableRebootReminder:(BOOL)enable;
- (void)secInfoUpdated:(BOOL)success;
- (void)setProxyDetected:(BOOL)detected;
- (BOOL)isProxyDetected;
- (void)finishedConnecting;

@property (class, nonatomic, readonly) __kindof OTRAppDelegate *appDelegate;

@end


NS_ASSUME_NONNULL_END
