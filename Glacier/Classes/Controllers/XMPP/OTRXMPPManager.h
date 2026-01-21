//
//  OTRXMPPManager.h
//  Off the Record
//
//  Created by Chris Ballinger on 9/7/11.
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

@import Foundation;
@import UIKit;
@import XMPPFramework;
#import "OTRProtocol.h"
#import "OTRConstants.h"
#import "OTRServerCapabilities.h"
#import "OTRXMPPRoomManager.h"
//#if !TARGET_IS_EXTENSION
//#import "Glacier-Swift.h"
@protocol MessageProtocol;
//#elif TARGET_IS_NOTIFICATION
//#import "GlacierNotifications-Swift.h"
//#endif

@class OTRXMPPStream;
@class OTROMEMOSignalCoordinator;
@class DatabaseConnections;
@class XMPPPushModule, ServerCheck, FileTransferManager, MessageStorage, CallManager;
@class MessageQueueHandler;
@class ChatAccountModel, IncomingChatMessage, ChatBuddyModel;

typedef NS_ENUM(NSInteger, ChatState);

NS_ASSUME_NONNULL_BEGIN
NS_SWIFT_NAME(XMPPManager)
@interface OTRXMPPManager : NSObject <XMPPRosterDelegate, XMPPStreamDelegate, NSFetchedResultsControllerDelegate, OTRProtocol>

//@property (nonatomic, strong, readonly) OTRXMPPStream *xmppStream;

@property (nonatomic, strong, readonly) ChatAccountModel *chatAccount;

@property (nonatomic, strong, readonly) XMPPRoster *xmppRoster;
@property (nonatomic, strong, readonly) OTRXMPPRoomManager *roomManager;
@property (nonatomic, strong, nullable) OTROMEMOSignalCoordinator *omemoSignalCoordinator;
@property (nonatomic, strong, readonly) XMPPPushModule *xmppPushModule;
@property (nonatomic, strong, readonly) ServerCheck *serverCheck;
@property (nonatomic, strong, readonly) FileTransferManager *fileTransferManager;
@property (nonatomic, strong, readonly) CallManager *callManager;
@property (nonatomic, strong, readonly) MessageStorage *messageStorage;
@property (nonatomic, readonly, nullable) MessageQueueHandler *messageQueueHandler;

@property (nonatomic, strong, readonly) dispatch_queue_t workQueue;

@property (atomic, readonly) OTRLoginStatus loginStatus;
/** Useful for showing error messages related to connection, like SSL certs. Only safe for access from main queue. */
@property (nonatomic, readonly, nullable) NSError *lastConnectionError;

- (instancetype) initWithChatAccount:(ChatAccountModel*)account;

- (NSDate * _Nullable) getLastConnected; //ALF IOSM-479

- (NSDate * _Nullable) getLastConnectAttempt; //IOSM-570

/** Call this if you want to register a new account on a compatible server */
- (BOOL)startRegisteringNewAccount;


//Chat State
//- (void)sendChatState:(ChatState)chatState withBuddyId:(NSString *)buddyUniqueId;
- (void)sendChatStateMessage:(XMPPMessage *)message;
- (void)restartPausedChatStateTimerForBuddyObjectID:(NSString *)buddyUniqueId;
- (void)restartInactiveChatStateTimerForBuddyObjectID:(NSString *)buddyUniqueId;
- (void)invalidatePausedChatStateTimerForBuddyUniqueId:(NSString *)buddyUniqueId;
- (void)sendPausedChatState:(NSTimer *)timer;
- (void)sendInactiveChatState:(NSTimer *)timer;
- (NSTimer *)inactiveChatStateTimerForBuddyObjectID:(NSString *)buddyUniqueId;
- (NSTimer *)pausedChatStateTimerForBuddyObjectID:(NSString *)buddyUniqueId;

// Delivery receipts
- (void) sendDeliveryReceiptForMessage:(IncomingChatMessage*)message;

//IOSM-443
- (void) sendReadReceipt:(id<MessageProtocol>)message;

- (void) sendAcknowledgments;

/**
 This updates the avatar for this managers account. It is async and will call the completion block immediately if newImage is nil.
 The best way to check for changes is to listen for Database changes on the account object. 
 The completion block is called once the image is uploaded and the server responds.
 */
- (void)setAvatar:(UIImage *)newImage completion:(void (^ _Nullable)(BOOL success))completion;

/** Force a vCard update (by manipulating pixel values in the avatar image)
 */
- (void)forcevCardUpdateWithCompletion:(void (^)(BOOL success))completion;

- (void)changePassword:(NSString *)newPassword completion:(void (^)(BOOL,NSError*))completion;

/** Will try to send a probe to fetch last seen. If buddy is still pendingApproval it will retry subscription request. */
- (void) sendPresenceProbeForBuddy:(ChatBuddyModel*)buddy;

/** Will send an away presence with your last idle timestamp */
- (void) goAway;

/** Will send an available presence */
- (void) goOnline;

/** Will send an unavailable presence */
- (void) goOffline;

- (void) updateNickname:(XMPPvCardTemp *)vCardTemp;

- (void) updateNetworkCheckBypass:(BOOL)bypass;
- (void) updateUseStageConsole:(BOOL)useStage;

- (void) clearMemory;

- (NSArray<NSString *> *)getTeams; //ALF IOSM-479

/** Enqueues a message to be sent by message queue */
- (void) enqueueMessage:(id<MessageProtocol>)message;

/** Enqueues an array of messages to be sent by message queue */
- (void) enqueueMessages:(NSArray<id<MessageProtocol>>*)messages;

@end


NS_ASSUME_NONNULL_END
