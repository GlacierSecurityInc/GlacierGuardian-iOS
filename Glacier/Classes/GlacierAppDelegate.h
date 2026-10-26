//
//  GlacierAppDelegate.h
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
#import "GlacierProtocol.h"

@class GlacierSplitViewCoordinator, ConversationViewController, ChatViewController, ChatRoomViewController, SMSViewController, SMSChatViewController, SMSSplitViewCoordinator, SettingsViewController, SecurityCenterViewController, DialerViewController, ContactsViewController, HistoryViewController;
@protocol AppTheme;

NS_ASSUME_NONNULL_BEGIN

@interface GlacierAppDelegate : UIResponder <UIApplicationDelegate>

@property (nonatomic, strong, readonly) ConversationViewController *conversationViewController;
@property (nonatomic, strong, readonly) ChatViewController *chatViewController;
@property (nonatomic, strong, readonly) ChatRoomViewController *chatRoomViewController;
//@property (nonatomic, strong, readonly) UIViewController *chatRoomViewController;
@property (nonatomic, strong, readonly) GlacierSplitViewCoordinator *splitViewCoordinator;

@property (assign, nonatomic) BOOL smsEnabled;
@property (nonatomic, strong, readonly) SMSSplitViewCoordinator *smsSplitViewCoordinator;
@property (nonatomic, strong, readonly) SMSViewController *smsViewController;
@property (nonatomic, strong, readonly) SMSChatViewController *smsMessagesViewController;
@property (nonatomic, strong, readonly) SettingsViewController *settingsViewController;

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

// Amplify bring-up gating. A background launch on a locked phone has neither the
// keychain (protected data) nor an open database at didFinishLaunching, and the
// Cognito session check needs both. See -setupAmplify.
@property (assign, nonatomic) BOOL amplifyProtectedDataReady;
@property (assign, nonatomic) BOOL amplifyDatabaseReady;
@property (assign, nonatomic) BOOL amplifySessionChecked;
@property (assign, nonatomic) BOOL reauthPromptPending;
// YES when the deferred prompt should explain itself first (see -setExplainedReauthController).
@property (assign, nonatomic) BOOL reauthPromptExplains;
// YES when the deferred prompt is for a dead XMPP login and must not be dismissable.
@property (assign, nonatomic) BOOL reauthPromptRequired;
@property (nonatomic, strong, nullable) id protectedDataObserver;

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
- (void) doSettingsController;
- (void) setSMSEnabled:(BOOL)enabled;
- (void) resetSMS;
- (void) setSecurityHubEnabled:(BOOL)enabled;
//- (GlacierNetworkConnectionStatus) getCurrentNetworkStatus;
- (BOOL) tryOpenURL:(NSURL*)url;
- (void) enableRebootReminder:(BOOL)enable;
- (void)secInfoUpdated:(BOOL)success;
- (void)setProxyDetected:(BOOL)detected;
- (BOOL)isProxyDetected;
- (void)finishedConnecting;
- (BOOL)isMainInterfaceReady;
- (void)suspendBackgroundUpdateTimerForCall;
- (void)resumeBackgroundUpdateTimerAfterCallIfNeeded;

@property (class, nonatomic, readonly) __kindof GlacierAppDelegate *appDelegate;

@end


NS_ASSUME_NONNULL_END
