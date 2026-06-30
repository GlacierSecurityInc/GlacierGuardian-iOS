//
//  GlacierXMPPManager_Private.h
//  ChatSecure
//
//  Created by Chris Ballinger on 11/5/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

#import "GlacierXMPPManager.h"
#import "Glacier-Swift.h"
#import "GlacierXMPPRoomManager.h"
#import "GlacierXMPPBuddyTimers.h"
#import "GlacierXMPPStream.h"

NS_ASSUME_NONNULL_BEGIN
@interface GlacierXMPPManager() <GlacierCertificatePinningDelegate>

@property (nonatomic, strong, readonly) GlacierXMPPStream *xmppStream;
@property (nonatomic, strong, readonly) XMPPReconnect *xmppReconnect;
@property (nonatomic, strong, readonly) XMPPvCardTempModule *xmppvCardTempModule;
@property (nonatomic, strong, readonly) XMPPvCardAvatarModule *xmppvCardAvatarModule;
@property (nonatomic, strong, readonly) RosterStorage * xmppRosterStorage;
@property (nonatomic, strong) GlacierCertificatePinning * certificatePinningModule;

@property (nonatomic, strong, readonly) XMPPStreamManagement *streamManagement;

//@property (nonatomic, strong, readonly) OTRXMPPBuddyManager* xmppBuddyManager;
@property (nonatomic, strong, readonly) OMEMOModule *omemoModule;
@property (nonatomic, strong, nullable) XMPPChangePasswordManager *changePasswordManager;

@property (nonatomic, strong, readonly) XMPPMessageDeliveryReceipts *deliveryReceipts;
@property (nonatomic, strong, readonly) XMPPMessageStatusModule *messageStatusModule;
@property (nonatomic, strong, readonly) GlacierStreamManagementDelegate *streamManagementDelegate;
@property (nonatomic, strong, readonly) XMPPStanzaIdModule *stanzaIdModule;

//@property (nonatomic, strong, readonly) dispatch_queue_t workQueue;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSString*,GlacierXMPPBuddyTimers*> * buddyTimers;

@property (nonatomic, strong, nullable) XMPPChangeAvatar *changeAvatar;

@property (nonatomic, readwrite) BOOL isRegisteringNewAccount;
@property (nonatomic, readwrite) BOOL userInitiatedConnection;
@property (atomic, readwrite) GlacierLoginStatus loginStatus;

@property (nonatomic, strong) NSDate *lastDisconnect;
@property (nonatomic, strong) NSDate *lastConnectAttempt; 

- (void)setupStream;
- (void)teardownStream;

- (void)goOnline;
- (void)goOffline;
- (void)failedToConnect:(NSError *)error;

/** wtf. why isn't this being picked up by GlacierProtocol */
- (void) connectUserInitiated:(BOOL)userInitiated;
- (BOOL) connectFromBackground;

/** Return a newly allocated stream object.  */
- (GlacierXMPPStream*) newStream;

@end
NS_ASSUME_NONNULL_END
