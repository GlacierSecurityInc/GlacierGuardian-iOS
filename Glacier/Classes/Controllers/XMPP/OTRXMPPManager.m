//
//  OTRXMPPManager.m
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

#import "OTRXMPPManager.h"

@import CocoaAsyncSocket;
@import XMPPFramework;

#import "OTRLog.h"

#import <CFNetwork/CFNetwork.h>

#import "OTRSettingsManager.h"
#import "OTRConstants.h"
#import "GlacierInfo.h"
#import "OTRProtocolManager.h"
#include <stdlib.h>
#import "OTRConstants.h"
#import "OTRUtilities.h"

#import "OTRXMPPRoomManager.h"
#import "OTRXMPPBuddyTimers.h"
#import "OTRXMPPError.h"
#import "OTRXMPPManager_Private.h"
#import "UIImage+ChatSecure.h"
#import "XMPPPushModule.h"
#import "Glacier-Swift.h"

@interface OTRXMPPManager ()
@property (assign, nonatomic) BOOL enablingPush;
@property (assign, nonatomic) BOOL retriedRoster;
@property (assign, nonatomic) BOOL disconnectedBuddies;

//ALF IOSM-479
@property (strong, nonatomic) NSMutableSet *teams;
@property (strong, nonatomic, nullable) NSDate *lastConnected;

@property (strong, nonatomic) MessageQueueHandler *messageQueueHandler;

@end

NSTimeInterval const kChatStatePausedTimeout   = 5;
NSTimeInterval const kChatStateInactiveTimeout = 120;


/** For XEP-0352 CSI Client State Indication */
typedef NS_ENUM(NSInteger, XMPPClientState) {
    XMPPClientStateInactive,
    XMPPClientStateActive,
};

@implementation OTRXMPPManager

- (instancetype)init
{
    if (self = [super init]) {
        NSString * queueLabel = [NSString stringWithFormat:@"%@.work.%@",[self class],self];
        _workQueue = dispatch_queue_create([queueLabel UTF8String], 0);
        _buddyTimers = [NSMutableDictionary dictionary];
        _enablingPush = NO;
        _retriedRoster = NO;
        _disconnectedBuddies = NO;
        _teams = [[NSMutableSet alloc ]init]; //ALF IOSM-479
        _messageQueueHandler = [[MessageQueueHandler alloc] init];
    }
    return self;
}

- (instancetype) initWithChatAccount:(ChatAccountModel *)newAccount {
    if(self = [self init])
    {
        NSAssert([newAccount isKindOfClass:[ChatAccountModel class]], @"Must have XMPP account");
        self.isRegisteringNewAccount = NO;
        _chatAccount = newAccount;
        
        // Setup the XMPP stream
        [self setupStream];
    }
    
    return self;
}

- (void) clearMemory
{
    [self teardownStream];
}

- (void)dealloc
{
	[self teardownStream];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Private
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (OTRXMPPStream*) newStream {
    return [[OTRXMPPStream alloc] init];
}

- (void)setupStream
{
	NSAssert(_xmppStream == nil, @"Method setupStream invoked multiple times");
    
	_xmppStream = [self newStream];

    //Used to fetch correct account from XMPPStream in delegate methods especailly
    self.xmppStream.tag = self.chatAccount.uniqueId;
    self.xmppStream.startTLSPolicy = XMPPStreamStartTLSPolicyRequired;
    
    [self.certificatePinningModule activate:self.xmppStream];
    
    _deliveryReceipts = [[XMPPMessageDeliveryReceipts alloc] init];
    // We want to check if OTR messages can be decrypted
    self.deliveryReceipts.autoSendMessageDeliveryReceipts = NO;
    self.deliveryReceipts.autoSendMessageDeliveryRequests = YES;
    [self.deliveryReceipts activate:self.xmppStream];
	
	// Setup reconnect
	// 
	// The XMPPReconnect module monitors for "accidental disconnections" and
	// automatically reconnects the stream for you.
	// There's a bunch more information in the XMPPReconnect header file.
	
	_xmppReconnect = [[XMPPReconnect alloc] init];
	
	// Setup roster
	// 
	// The XMPPRoster handles the xmpp protocol stuff related to the roster.
	// The storage for the roster is abstracted.
	// So you can use any storage mechanism you want.
	// You can store it all in memory, or use core data and store it on disk, or use core data with an in-memory store,
	// or setup your own using raw SQLite, or create your own storage mechanism.
	// You can do it however you like! It's your application.
	// But you do need to provide the roster with some storage facility.
    
    //DDLogInfo(@"Unique Identifier: %@",chatAccount.uniqueIdentifier);
	
    _xmppRosterStorage = [[RosterStorage alloc] init];
	_xmppRoster = [[XMPPRoster alloc] initWithRosterStorage:self.xmppRosterStorage];
	
	self.xmppRoster.autoFetchRoster = YES;
    self.xmppRoster.autoClearAllUsersAndResources = NO;
	self.xmppRoster.autoAcceptKnownPresenceSubscriptionRequests = YES;
	
	// Setup vCard support
	// 
	// The vCard Avatar module works in conjuction with the standard vCard Temp module to download user avatars.
	// The XMPPRoster will automatically integrate with XMPPvCardAvatarModule to cache roster photos in the roster.
	
    VCardStorage * vCardStorage  = [[VCardStorage alloc] init];
	_xmppvCardTempModule = [[XMPPvCardTempModule alloc] initWithvCardStorage:vCardStorage];
	
	_xmppvCardAvatarModule = [[XMPPvCardAvatarModule alloc] initWithvCardTempModule:self.xmppvCardTempModule];
	
	// Setup capabilities
	// 
	// The XMPPCapabilities module handles all the complex hashing of the caps protocol (XEP-0115).
	// Basically, when other clients broadcast their presence on the network
	// they include information about what capabilities their client supports (audio, video, file transfer, etc).
	// But as you can imagine, this list starts to get pretty big.
	// This is where the hashing stuff comes into play.
	// Most people running the same version of the same client are going to have the same list of capabilities.
	// So the protocol defines a standardized way to hash the list of capabilities.
	// Clients then broadcast the tiny hash instead of the big list.
	// The XMPPCapabilities protocol automatically handles figuring out what these hashes mean,
	// and also persistently storing the hashes so lookups aren't needed in the future.
	// 
	// Similarly to the roster, the storage of the module is abstracted.
	// You are strongly encouraged to persist caps information across sessions.
	// 
	// The XMPPCapabilitiesCoreDataStorage is an ideal solution.
	// It can also be shared amongst multiple streams to further reduce hash lookups.

    
    // Add push registration module
    _xmppPushModule = [[XMPPPushModule alloc] init];
    [self.xmppPushModule activate:self.xmppStream];
    [self.xmppPushModule addDelegate:self delegateQueue:self.workQueue];
    
    _serverCheck = [[ServerCheck alloc] initWithPush:OTRProtocolManager.pushController pushModule:self.xmppPushModule dispatchQueue:nil];
    [self.serverCheck activate:self.xmppStream];
    
    _callManager = [CallManager sharedCallManager];
    [_callManager setAccount:_chatAccount];
    [self.callManager activate:self.xmppStream];
    
	// Activate xmpp modules
    
	[self.xmppReconnect         activate:self.xmppStream];
	[self.xmppRoster            activate:self.xmppStream];
	[self.xmppvCardTempModule   activate:self.xmppStream];
	[self.xmppvCardAvatarModule activate:self.xmppStream];
    
    _stanzaIdModule = [[XMPPStanzaIdModule alloc] init];
    [self.stanzaIdModule activate:self.xmppStream];
    
	// Add ourself as a delegate to anything we may be interested in
    
	[self.xmppStream addDelegate:self delegateQueue:self.workQueue];
    [self.xmppRoster addDelegate:self.xmppRosterStorage delegateQueue:self.workQueue];
    [self.xmppRoster addDelegate:self delegateQueue:self.workQueue];
    [self.serverCheck.xmppCapabilities addDelegate:self delegateQueue:self.workQueue];
    [self.xmppvCardTempModule addDelegate:self delegateQueue:self.workQueue];
    
    // File Transfer
    NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    
    BOOL allowselfsigned = NO;
    NSString *uploaddomain = [GlacierInfo defaultHost];
    if (_chatAccount != nil) {
        uploaddomain = _chatAccount.domain;
    }
    
    _fileTransferManager = [[FileTransferManager alloc] initWithServerCapabilities:self.serverCheck.serverCapabilities sessionConfiguration:sessionConfiguration allowSelfSigned:allowselfsigned uploadDomain:uploaddomain];
    
    // Message storage
    RoomStorage *roomStorage = [[RoomStorage alloc] initWithCapabilities:self.serverCheck.xmppCapabilities fileTransfer:self.fileTransferManager vCardModule:self.xmppvCardTempModule omemoModule:self.omemoModule];

    _messageStorage = [[MessageStorage alloc] initWithCapabilities:self.serverCheck.xmppCapabilities
                                                      fileTransfer:self.fileTransferManager
                                                       roomStorage:roomStorage dispatchQueue:nil];
    [self.messageStorage activate:self.xmppStream];
    
    //Stream Management
    _streamManagementDelegate = [[OTRStreamManagementDelegate alloc] init];
    
    XMPPStreamManagementMemoryStorage *memoryStorage = [[XMPPStreamManagementMemoryStorage alloc] init];
    _streamManagement = [[XMPPStreamManagement alloc] initWithStorage:memoryStorage];
    [self.streamManagement addDelegate:self.streamManagementDelegate delegateQueue:self.workQueue];
    [self.streamManagement automaticallyRequestAcksAfterStanzaCount:10 orTimeout:5];
    [self.streamManagement automaticallySendAcksAfterStanzaCount:30 orTimeout:5];
    self.streamManagement.autoResume = YES;
    [self.streamManagement activate:self.xmppStream];
    
    //MUC
    _roomManager = self.messageStorage.roomManager;
    
    //Message Queue Module
    _messageStatusModule = [[OTRXMPPMessageStatusModule alloc] initWithDelegate:self.messageQueueHandler];
    [self.messageStatusModule activate:self.xmppStream];
    
    //OMEMO
    if (GlacierInfo.allowOMEMO) {
        self.omemoSignalCoordinator = [[OTROMEMOSignalCoordinator alloc] initWithAccountKey:_chatAccount.uniqueId messageStorage:self.messageStorage roomManager:self.roomManager error:nil];
        _omemoModule = [[OMEMOModule alloc] initWithOMEMOStorage:self.omemoSignalCoordinator xmlNamespace:OMEMOModuleNamespaceConversationsLegacy];
        [self.omemoModule addDelegate:self.omemoSignalCoordinator delegateQueue:self.workQueue];
        [self.serverCheck.xmppCapabilities addDelegate:self.omemoModule delegateQueue:self.workQueue];
        [self.omemoModule activate:self.xmppStream];
        [self.omemoSignalCoordinator setJID:self.xmppStream.myJID];
        //self.messageStorage.roomManager.roomStorage.om
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pushAccountChanged:) name:OTRPushAccountDeviceChanged object:OTRProtocolManager.pushController];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pushAccountChanged:) name:OTRPushAccountTokensChanged object:OTRProtocolManager.pushController];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(buddyPendingApprovalStateChanged:) name:BuddyPendingApprovalDidChangeNotification object:self.xmppRosterStorage];
    
}

- (void)teardownStream
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:BuddyPendingApprovalDidChangeNotification object:self.xmppRosterStorage];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:OTRPushAccountDeviceChanged object:OTRProtocolManager.pushController];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:OTRPushAccountTokensChanged object:OTRProtocolManager.pushController];

    [_xmppStream removeDelegate:self];
    [_xmppRoster removeDelegate:self];
    [_xmppvCardTempModule removeDelegate:self];
    [_xmppPushModule removeDelegate:self];
    
    [_serverCheck.xmppCapabilities removeDelegate:self];
    [_serverCheck.xmppCapabilities removeDelegate:self.omemoModule];
    [_serverCheck.xmppCapabilities removeDelegate:self.roomManager];
    [_xmppRoster removeDelegate:self.xmppRosterStorage];
    [_streamManagement removeDelegate:self.streamManagementDelegate];
    [_omemoModule removeDelegate:self.omemoSignalCoordinator];
    [_fileTransferManager removeDelegates];

    [_xmppPushModule deactivate];
    [_xmppReconnect         deactivate];
    [_xmppRoster            deactivate];
    [_xmppvCardTempModule   deactivate];
    [_xmppvCardAvatarModule deactivate];
    [_messageStorage        deactivate];
    [_certificatePinningModule deactivate];
    [_deliveryReceipts deactivate];
    [_streamManagement deactivate];
    [_messageStatusModule deactivate];
    [_omemoModule deactivate];
    [_serverCheck deactivate];
    _serverCheck = nil;
    
    [_callManager deactivate];
    _callManager = nil;
    
    [_stanzaIdModule deactivate];
    //[_roomManager deactivate];  // done in message storage deactivate
    _xmppPushModule = nil;
    _fileTransferManager = nil;
    _messageStorage = nil;
    _roomManager = nil;
    _stanzaIdModule = nil;
    _messageStatusModule = nil;
    _omemoSignalCoordinator = nil;
    _omemoModule = nil;
    _xmppRoster = nil;
    _xmppRosterStorage = nil;
    _xmppvCardTempModule = nil;
    _xmppvCardAvatarModule = nil;

    [_xmppStream disconnect];
    _xmppStream = nil;
}

- (void) sendAcknowledgments {
    [_streamManagement sendAck];
}

- (void) addIdleDate:(NSDate*)date toPresence:(XMPPPresence*)presence {
    NSString *nowString = [date xmppDateTimeString];
    if (nowString) {
        /*
         <presence from='juliet@capulet.com/balcony'>
         <show>away</show>
         <idle xmlns='urn:xmpp:idle:1' since='1969-07-21T02:56:15Z'/>
         </presence>
         */
        // https://xmpp.org/extensions/xep-0319.html
        NSXMLElement *idle = [NSXMLElement elementWithName:@"idle" xmlns:@"urn:xmpp:idle:1"];
        [idle addAttributeWithName:@"since" stringValue:nowString];
        [presence addChild:idle];
    }
}

/** Sends "away" presence with last idle time */
- (void) goAway {
    [OTRAppDelegate getLastInteractionDate:^(NSDate * _Nullable date) {
        XMPPPresence *presence = [XMPPPresence presence];
        NSXMLElement *show = [NSXMLElement elementWithName:@"show" stringValue:@"away"];
        [presence addChild:show];
        NSDate *idleDate = date;
        [self addIdleDate:idleDate toPresence:presence];
        [self.xmppStream sendElement:presence];
        [self updateClientState:XMPPClientStateInactive];
    } completionQueue:self.workQueue];
}

- (void)goActive {
    //DDLogInfo(@"***** goActive");
    XMPPPresence *presence = [XMPPPresence presence]; // type="available" is implicit
    [self.xmppStream sendElement:presence];
    
    [self updateClientState:XMPPClientStateActive];
}

/** This will choose "active" or "away" based on UIApplication applicationState */
- (void)goOnline
{
    //DDLogInfo(@"***** goOnline");
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_lastConnectionError = nil;
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            [self goActive];
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                    [self goActive];
                } else if ([_callManager isRinging]) { //ALF IOSM-437
                    [self goActive];
                    //[self updateClientState:XMPPClientStateActive];
                } else {
                    DDLogError(@"Application state not active so presence online will not be sent and 1:1 messages will not be received.");
                }
            });
        }
    });
}

- (void)goOffline
{
    [OTRAppDelegate getLastInteractionDate:^(NSDate * _Nullable date) {
        XMPPPresence *presence = [XMPPPresence presenceWithType:@"unavailable"];
        NSDate *idleDate = date;
        [self addIdleDate:idleDate toPresence:presence]; // I don't think this does anything
        [self.xmppStream sendElement:presence];
        [self updateClientState:XMPPClientStateInactive];
        
        /*dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), self.workQueue, ^{
                [self.xmppStream disconnectAfterSending];
        });*/ //IOSM-570
    } completionQueue:self.workQueue];
}

//ALF IOSM-479
- (NSDate *) getLastConnected {
    return self.lastConnected;
}

//ALF IOSM-570
- (NSDate *) getLastConnectAttempt {
    return self.lastConnectAttempt;
}

/** XEP-0352 Client State Indication */
- (void) updateClientState:(XMPPClientState)clientState {
    NSXMLElement *csiFeature = [self.serverCheck.serverCapabilities.streamFeatures elementForName:@"csi" xmlns:@"urn:xmpp:csi:0"];
    if (!csiFeature) {
        return;
    }
    
    NSXMLElement *csi = nil;
    switch (clientState) {
        case XMPPClientStateActive:
            csi = [NSXMLElement indicateActiveElement];
            break;
        case XMPPClientStateInactive:
            csi = [NSXMLElement indicateInactiveElement];
            break;
    }
    [self.xmppStream sendElement:csi];
}

- (NSString *)accountDomainWithError:(id)error;
{
    return _chatAccount.domain;
}

- (void)didRegisterNewAccountWithStream:(XMPPStream *)stream
{
    self.isRegisteringNewAccount = NO;
    [self authenticateWithStream:stream];
}

- (void)failedToRegisterNewAccount:(NSError *)error
{
    DDLogError(@"Failed to register new account: %@", error);
    [self failedToConnect:error];
}

- (void)authenticateWithStream:(XMPPStream *)stream {
    NSError * error = nil;
    BOOL status = YES;
    if (self.chatAccount.password == nil) {
        //[GlacierLog glogWithLogMsg:@"authenticateWithStream nil password" detail:self.chatAccount.uniqueId];
    }
    status = [stream authenticateWithPassword:self.chatAccount.password error:&error];
}

///////////////////////////////
#pragma mark Capabilities Collected
////////////////////////////////////////////

- (NSArray *)myFeaturesForXMPPCapabilities:(XMPPCapabilities *)sender
{
    return @[
            @"http://jabber.org/protocol/chatstates",
            @"urn:xmpp:jingle:1",
            @"urn:xmpp:jingle:apps:rtp:1",
            @"urn:xmpp:jingle:apps:dtls:0",
            @"urn:xmpp:jingle:apps:rtp:audio",
            @"urn:xmpp:jingle:apps:rtp:video",
            @"urn:xmpp:jingle:transports:ice-udp:1",
            @"urn:xmpp:jingle-message:0"
    ];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Connect/disconnect
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (BOOL)startConnection
{
    DDLogInfo(@"***** startConnection");
    [self setLoginStatus:OTRLoginStatusConnecting];
    self.lastConnectAttempt = [NSDate date]; //IOSM-570
    
    XMPPJID *jid = [XMPPJID jidWithString:self.chatAccount.username resource:self.chatAccount.resource];
    
    if (![jid.domain isEqualToString:self.xmppStream.myJID.domain]) {
        [self.xmppStream disconnect];
    }
    self.xmppStream.myJID = jid;
	if (![self.xmppStream isDisconnected]) {
        [self authenticateWithStream:self.xmppStream];
		return YES;
	}
    
	//
	// If you don't want to use the Settings view to set the JID, 
	// uncomment the section below to hard code a JID and password.
	//
	// Replace me with the proper JID and password:
	//	myJID = @"user@gmail.com/xmppframework";
	//	myPassword = @"";
    
	
    
    
    NSError * error = nil;
    NSString * domainString = [self accountDomainWithError:error];
    if (error) {
        [self failedToConnect:error];
        return NO;
    }
    if ([domainString length]) {
        [self.xmppStream setHostName:domainString];
    }
    
    [self.xmppStream setHostPort:self.chatAccount.port];
	
    
	error = nil;
    if (![self.xmppStream connectWithTimeout:(NSTimeInterval)6 error:&error])
	{
		[self failedToConnect:error];
        
		DDLogError(@"Error connecting: %@", error);
        
		return NO;
	}
    
	return YES;
}

- (void) disconnectSocketOnly:(BOOL)socketOnly {
    DDLogVerbose(@"%@ %d", THIS_METHOD, socketOnly);
    if (socketOnly) {
        if (self.loginStatus == OTRLoginStatusAuthenticated) {
            self.loginStatus = OTRLoginStatusDisconnecting;
            [self goAway];
        }
        return;
    }
    
    //IOSM-570
    self.loginStatus = OTRLoginStatusDisconnecting;
    __block NSDate *nowdate = [NSDate date];
    self.lastDisconnect = nowdate;
    
    [self goOffline];
    
    //call method on account that does async stuff and handles completion block
    //all but removeAccountFromRooms are async already
    //ALF23
    if (!self.disconnectedBuddies) {
        self.disconnectedBuddies = YES;
        [self disconnectBuddiesAndRooms:[self shouldDisconnectBuddies]];
    }
    //[ChatBuddyModel disconnectAllBuddiesWithAccountId:self.chatAccount.uniqueId queue:self.workQueue];
    [ChatRoomModel updateLastHistoryWithAccountId:self.chatAccount.uniqueId];
    if([OTRSettingsManager boolForOTRSettingKey:kOTRSettingKeyDeleteOnDisconnect]) {
        [ChatMessageModel deleteAllMessagesFor:self.chatAccount.uniqueId];
        [ChatRoomModel removeAccountFromRoomsFor:self.chatAccount.uniqueId];
    }
}

- (BOOL)shouldDisconnectBuddies {
    if (self.lastDisconnect) {
        NSDate *now = [NSDate date];
        if (([now timeIntervalSinceDate:self.lastDisconnect]) < 1.0) {
            return NO;
        }
    }
    
    return YES;
}

- (void)disconnectBuddy:(ChatBuddyModel *)buddy
{
    ThreadStatus newStatus = ThreadStatusOffline;
    //ChatBuddyModel *newBuddy = [buddy copy];
    
    if (buddy) {
        newStatus = ThreadStatusOffline;
        [BuddyCache.shared setStatusMessage:OFFLINE_STRING() buddyId:buddy.uniqueId];
        [BuddyCache.shared setChatState:ChatStateGone buddyId:buddy.uniqueId];
    }
    
    [BuddyCache.shared setThreadStatus:newStatus buddyId: buddy.uniqueId resource:nil];
    [buddy touchBuddy];
}

- (void)disconnect
{
    [self disconnectSocketOnly:NO];
}

- (BOOL)startRegisteringNewAccount
{
    self.isRegisteringNewAccount = YES;
    if (self.xmppStream.isConnected) {
        [self.xmppStream disconnect];
        return NO;
    }
    
    return [self startConnection];
}

- (BOOL)continueRegisteringNewAccount
{
    NSError * error = nil;
    if ([self.xmppStream supportsInBandRegistration]) {
        [self.xmppStream registerWithPassword:self.chatAccount.password error:&error];
        if (error) {
            [self failedToRegisterNewAccount:error];
            return NO;
        }
    } else {
        error = [NSError errorWithDomain:OTRXMPPErrorDomain code:OTRXMPPErrorCodeUnsupportedAction userInfo:nil];
        [self failedToRegisterNewAccount:error];
        return NO;
    }
    return YES;
}

#pragma mark Public Methods

//ALF IOSM-479
- (NSArray<NSString *> *)getTeams {
    return [self.teams allObjects];
}

/** Will send a probe to fetch last seen */
- (void) sendPresenceProbeForBuddy:(ChatBuddyModel*)buddy {
    NSParameterAssert(buddy);
    if (!buddy) { return; }
    XMPPJID *jid = buddy.bareJID;
    if (!jid) { return; }
    
    /*if (![buddy subscribedTo]) {
        if (buddy.pendingApproval) {
            // We can't probe presence if we are still pending approval, so resend the request.
            [self.xmppRoster subscribePresenceToUser:jid];
        }
        return;
    }*/
    
    // https://xmpp.org/extensions/xep-0318.html
    // <presence from='juliet@capulet.com/balcony' to='romeo@montague.com' type='probe' />
    XMPPPresence *probe = [XMPPPresence presenceWithType:@"probe" to:jid];
    if (!probe) { return; }
    [self.xmppStream sendElement:probe];
    
    //IOSM-168 presence probe doesn't work unless they are online
    XMPPIQ *lastActivity = [XMPPIQ lastActivityQueryTo:buddy.bareJID];
    [self.xmppStream sendElement:lastActivity];
}

//IOSM-168
- (void) handleLastActivity:(NSString *)lastActivity fromJid:(XMPPJID *)jid {
    [ChatBuddyModel fetchBuddyAsyncWithJid:jid accountUniqueId:self.chatAccount.uniqueId queue:self.workQueue completion:^(ChatBuddyModel *buddy){
        if (!buddy) { return; }
        NSDate *lastdate = [NSDate dateWithTimeIntervalSinceNow:-[lastActivity doubleValue]];
        [BuddyCache.shared setLastSeenWithDate:lastdate buddyModel:buddy];
    }];
}

/** Enqueues a message to be sent by message queue */
- (void) enqueueMessage:(id<MessageProtocol>)message {
    NSParameterAssert(message);
    if (!message) { return; }
    [self enqueueMessages:@[message]];
}

/** Enqueues an array of messages to be sent by message queue */
- (void) enqueueMessages:(NSArray<id<MessageProtocol>>*)messages {
    NSParameterAssert(messages);
    if (!messages.count) {
        return;
    }
    
    [messages enumerateObjectsUsingBlock:^(id<MessageProtocol> _Nonnull message, NSUInteger idx, BOOL * _Nonnull stop) {
        if (message.isMessageIncoming) {
            // We cannot send incoming messages
            DDLogError(@"Cannot send incoming message: %@", message);
            return;
        }
        
        //save to database
        [message saveWithCompletion:^{
            [self.messageQueueHandler addMessage:message];
        }];
            
        //Update thread
        ChatThreadModel* thread = [message threadOwner];
        if (!thread) {
            return;
        }
        
        thread.lastMessageIdentifier = message.uid;
        thread.threadDate = message.messageDate;
        [thread saveThread];
        
        if ([thread isGroupThread]) {
            ChatRoomModel *room = [ChatRoomModel getXMPPRoomWithUniqueId:message.threadId];
            room.currentMessageText = nil;
            [room saveThread];
        } else {
            ChatBuddyModel *bud = [ChatBuddyModel getBuddyWithUniqueId:message.threadId];
            bud.currentMessageText = nil;
            [bud saveThread];
        }
    }];
}

- (void)setAvatar:(UIImage *)avatarImage completion:(void (^)(BOOL success))completion
{
    if (!avatarImage) {
        completion(NO);
        return;
    }
    
    __block UIImage *newImage = avatarImage;
    
    
    dispatch_async(self.workQueue, ^{
        
        //Square crop & Resize image
        newImage = [UIImage otr_prepareForAvatarUpload:newImage maxSize:120.0];
        //jpeg compression
        NSData *data = UIImageJPEGRepresentation(newImage, 0.6);
        
        //Save new avatar right away to update UI
        //should be asyncReadWrite
        ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:self.chatAccount.uniqueId];
        [account setAvatarData:data];
        [account saveXMPPAccountAsync];
        
        self.changeAvatar = [[OTRXMPPChangeAvatar alloc] initWithPhotoData:data
                                                       xmppvCardTempModule:self.xmppvCardTempModule];
        
        __weak typeof(self) weakSelf = self;
        [self.changeAvatar updatePhoto:^(BOOL success) {
            typeof(weakSelf) strongSelf = weakSelf;
            if (completion) {
                completion(success);
            }
            strongSelf.changeAvatar = nil;
        }];
    });
    
}

// Currently the only way to force a vCard update is to update the avatar. We want to do this in a non-destructive way, so that this method can be used many times without the avatar being distorted. The idea is to manipulate the bottom rightmost pixel value, setting it to the neighboring pixel value with the blue component alternating between +-1.
- (void)forcevCardUpdateWithCompletion:(void (^)(BOOL success))completion {
    UIImage *image = [self.chatAccount avatarImage];
    if (image != nil) {
        CGFloat width = image.size.width;
        CGFloat height = image.size.height;
        if (width <= 0 || height <= 0) {
            return;
        }
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        
        size_t bitsPerComponent = 8;
        size_t bytesPerPixel    = 4;
        size_t bytesPerRow      = (width * bitsPerComponent * bytesPerPixel + 7) / 8;
        size_t dataSize         = bytesPerRow * height;
        
        unsigned char *data = malloc(dataSize);
        memset(data, 0, dataSize);
        
        CGContextRef context = CGBitmapContextCreate(data, width, height,
                                                     bitsPerComponent,
                                                     bytesPerRow, colorSpace,
                                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Big);
        
        
        CGColorSpaceRelease(colorSpace);
        
        CGContextDrawImage(context, CGRectMake(0, 0, image.size.width, image.size.height), image.CGImage);
        
        // Get pixel color for neighboring pixel
        int offset = (width - 2) * bytesPerRow + (height - 1) * bytesPerPixel;
        int alpha =  data[offset];
        int red = data[offset+1];
        int green = data[offset+2];
        int blue = data[offset+3];

        // Manipulate the bottom right pixel
        offset = (width - 1) * bytesPerRow + (height - 1) * bytesPerPixel;
        int currentBlue = data[offset+3];

        data[offset] = alpha;
        data[offset+1] = red;
        data[offset+2] = green;
        if (currentBlue != blue) {
            // Not equal, just use the blue value for the neighboring pixel
            data[offset+3] = blue;
        } else {
            if (blue == 255) {
                data[offset+3] = blue - 1;
            } else {
                data[offset+3] = blue + 1;
            }
        }
        
        CGImageRef imgRef = CGBitmapContextCreateImage(context);
        UIImage* img = [UIImage imageWithCGImage:imgRef];
        CGImageRelease(imgRef);
        
        // When finished, release the context
        CGContextRelease(context);
        if (data) { free(data); }
        
        [self setAvatar:img completion:completion];
    }
}

- (void)changePassword:(NSString *)newPassword completion:(void (^)(BOOL,NSError*))completion {
    if (!completion) {
        return;
    }
    
    if (!self.xmppStream.isAuthenticated || [newPassword length] == 0) {
        completion(NO,nil);
    }
    
    self.changePasswordManager = [[OTRXMPPChangePasswordManager alloc] initWithNewPassword:newPassword xmppStream:self.xmppStream completion:^(BOOL success, NSError * _Nullable error) {
        
        if (success) {
            self.chatAccount.password = newPassword;
        }
        self.changePasswordManager = nil;
        completion(success,error);
    }];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-value"
    [self.changePasswordManager changePassword];
#pragma clang diagnostic pop
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark XMPPStream Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (XMPPMessage *)xmppStream:(XMPPStream *)sender willSendMessage:(XMPPMessage *)message {
    NSString *body = [message body];
    if (body.length && ![body containsString:@" "]) {
        NSURL *url = [NSURL URLWithString:body];
        NSString *extension = url.pathExtension;
        NSString *scheme = url.scheme;
        if (scheme.length &&
            extension.length &&
            ([scheme isEqualToString:@"https"])) {
            // this means we're probably sending a file so mark it as OOB data
            /*
             <x xmlns="jabber:x:oob">
               <url>https://xmpp.example.com/upload/6c44c22c-70c6-4375-8b2d-1992a0f9dc18/8CleEoqhTjiMcny0PqoZyg.jpg</url>
             </x>
             */
            NSXMLElement *oob = [NSXMLElement elementWithName:@"x" xmlns:@"jabber:x:oob"];
            NSXMLElement *urlElement = [NSXMLElement elementWithName:@"url" stringValue:body];
            [oob addChild:urlElement];
            [message addChild:oob];
        }
    }
    return message;
}

- (void)xmppStreamDidChangeMyJID:(XMPPStream *)stream
{
    if (![[stream.myJID bare] isEqualToString:self.chatAccount.username] || ![[stream.myJID resource] isEqualToString:self.chatAccount.resource])
    {
        self.chatAccount.username = [stream.myJID bare];
        self.chatAccount.resource = [stream.myJID resource];
        [self.chatAccount saveXMPPAccountAsync];
    }
}

- (void)xmppStream:(XMPPStream *)sender socketDidConnect:(GCDAsyncSocket *)socket 
{
	DDLogVerbose(@"%@", THIS_METHOD);
    self.loginStatus = OTRLoginStatusConnected;
}

- (void)xmppStream:(XMPPStream *)sender willSecureWithSettings:(NSMutableDictionary *)settings
{
	DDLogVerbose(@"%@", THIS_METHOD);
    
    settings[GCDAsyncSocketSSLProtocolVersionMin] = @(kTLSProtocol1);
    settings[GCDAsyncSocketSSLCipherSuites] = [OTRUtilities cipherSuites];
    settings[GCDAsyncSocketManuallyEvaluateTrust] = @(YES);
    
    self.loginStatus = OTRLoginStatusSecuring;
}

- (void)xmppStreamDidSecure:(XMPPStream *)sender
{
	DDLogVerbose(@"%@", THIS_METHOD);
    
    self.loginStatus = OTRLoginStatusSecured;
}

- (void)xmppStreamDidConnect:(XMPPStream *)sender
{
	DDLogVerbose(@"%@", THIS_METHOD);
    //[self.chatAccount setWaitingForvCardTempFetch:NO];
    self.chatAccount.waitingForvCardTempFetch = NO;
    if (self.isRegisteringNewAccount) {
        [self continueRegisteringNewAccount];
    }
    else{
        [self authenticateWithStream:sender];
    }
    
    self.loginStatus = OTRLoginStatusAuthenticating;
}

- (void)xmppStreamDidDisconnect:(XMPPStream *)sender withError:(NSError *)error
{
    //DDLogWarn(@"%@: %@ %@", THIS_FILE, THIS_METHOD, error);
    
    //DDLogWarn(@"Login status: %ld ", (long)self.loginStatus); //IOSM-570
    //DDLogWarn(@"Last Connected: %@ ", self.lastConnected);
    //DDLogWarn(@"Last Disconnecting: %@ ", self.lastDisconnect);
    
    self.loginStatus = OTRLoginStatusDisconnected;
    
    if (error)
    {
        DDLogError(@"Disconnected from server %@ with error: %@", self.chatAccount.bareJID.domain, error);
        [self failedToConnect:error];
    } else {
        DDLogError(@"Disconnected from server %@.", self.chatAccount.bareJID.domain);
    }
    
    if (!self.disconnectedBuddies) {
        self.disconnectedBuddies = YES;
        [self disconnectBuddiesAndRooms:[self shouldDisconnectBuddies]];
    }
}

- (void)xmppStreamDidAuthenticate:(XMPPStream *)sender
{
	DDLogVerbose(@"%@", THIS_METHOD);
    self.disconnectedBuddies = NO;
    if ([sender supportsStreamManagement] && ![self.streamManagement didResume]) {
        [self.streamManagement enableStreamManagementWithResumption:YES maxTimeout:0];
    }
    
    self.loginStatus = OTRLoginStatusAuthenticated;
    self.lastConnected = [NSDate date]; //ALF IOSM-479
    NSString *accountKey = self.chatAccount.uniqueId;
    NSString *accountCollection = [[self.chatAccount class] collection];
    NSDictionary *userInfo = nil;
    
    if(accountKey && accountCollection) {
        userInfo = @{kOTRNotificationAccountUniqueIdKey:accountKey,kOTRNotificationAccountCollectionKey:accountCollection};
    }
    [[NSNotificationCenter defaultCenter]
     postNotificationName:kOTRProtocolLoginSuccess
     object:self userInfo:userInfo];
    
    [self.callManager handleAuthentication];
    if (self.callManager.waitingToAnswerCall) {
        //[self goActive];
        //[self.callManager handleAuthentication];
        return;
    }
    
    [self goOnline];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!([OTRAppDelegate appDelegate].silentUpdate)) {
            //dispatch_async(self.workQueue, ^{
            [self.xmppvCardTempModule forceFetchvCardTempForJID:[sender myJID]];
            [self.fileTransferManager resumeDownloads];
            //[self.callManager handleAuthentication]; //IOSM#70
            //});
        }
    });
}

- (void)xmppStream:(XMPPStream *)sender didNotAuthenticate:(NSXMLElement *)error
{
	//DDLogWarn(@"%@: %@ %@", THIS_FILE, THIS_METHOD, error);
    NSError *err = [OTRXMPPError errorForXMLElement:error];
    [self failedToConnect:err];
    [self disconnect];
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	//DDLogVerbose(@"%@: %@ - %@", THIS_FILE, THIS_METHOD, iq);
    //IOSM-168
    NSString *type = [iq type];
    XMPPJID *fromjid = [iq from];
    
    if ([type isEqualToString:@"result"] && [iq elementForName:@"query"  xmlns:@"jabber:iq:last"]) {
        NSXMLElement *query = [iq elementForName:@"query"];
        NSString *lastActivity = [query attributeStringValueForName:@"seconds"];
        [self handleLastActivity:lastActivity fromJid:fromjid];
    }
    
	return NO; //response is irrelevant
}

- (void)xmppStreamDidRegister:(XMPPStream *)sender {
    [self didRegisterNewAccountWithStream:sender];
}

- (void)xmppStream:(XMPPStream *)sender didNotRegister:(NSXMLElement *)xmlError {
    
    self.isRegisteringNewAccount = NO;
    NSError * error = [OTRXMPPError errorForXMLElement:xmlError];
    [self failedToRegisterNewAccount:error];
    [self disconnect];
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)xmppMessage
{
	//DDLogVerbose(@"%@: %@ %@", THIS_FILE, THIS_METHOD, xmppMessage);
}

- (void)xmppStream:(XMPPStream *)sender didReceivePresence:(XMPPPresence *)presence
{
	//DDLogVerbose(@"%@: %@\n%@", THIS_FILE, THIS_METHOD, presence.prettyXMLString);
    
    
}

- (void)xmppStream:(XMPPStream *)sender didReceiveError:(id)error
{
	DDLogWarn(@"%@ %@", THIS_METHOD, error);
}

- (void)xmppStream:(XMPPStream *)sender didFailToSendIQ:(XMPPIQ *)iq error:(NSError *)error
{
    DDLogWarn(@"%@ %@ %@", THIS_METHOD, iq, error);
}

- (void)xmppStream:(XMPPStream *)sender didFailToSendMessage:(XMPPMessage *)message error:(NSError *)error
{
    //ALF IOSM-481 added Active check and main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            return;
        }
        
        //IOSM#70 ignore call related messages that arent stored in DB
        if ([message elementForName:@"x" xmlns:@"jabber:x:callupdate"] || ![message elementForName:@"body"]) {
            return;
        }
        
        ChatMessageModel *bmsg = [ChatMessageModel getMessageWithElementId:message.elementID originId:message.originId stanzaId:nil];
        if (bmsg != nil) {
            //bmsg.error = error;
            [bmsg save];
        }
        
        DDLogWarn(@"%@ %@ %@", THIS_METHOD, message, error);
    });
}
- (void)xmppStream:(XMPPStream *)sender didFailToSendPresence:(XMPPPresence *)presence error:(NSError *)error
{
    DDLogWarn(@"%@ %@ %@", THIS_METHOD, presence, error);
    [self finishDisconnectingIfNeeded];
}

- (void)xmppStream:(XMPPStream *)sender didSendPresence:(XMPPPresence *)presence
{
    [self finishDisconnectingIfNeeded];
}

- (void)finishDisconnectingIfNeeded {
    if (self.loginStatus == OTRLoginStatusDisconnecting) {
        //IOSM-570
        [self.xmppStream disconnectAfterSending];
        //[self.xmppStream disconnect];
    }
}

- (void) updateNickname:(XMPPvCardTemp *)vCardTemp {
    if (vCardTemp.nickname.length) {
        //NSString *collection = [self.chatAccount.class collection];
        NSString *key = self.chatAccount.uniqueId;
        ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:key];
        account.displayName = vCardTemp.nickname;
        [account saveXMPPAccountAsync];
        self.chatAccount.displayName = vCardTemp.nickname;
        
        //IOSM-606
        XMPPvCardTemp *realvCardTemp = [self.xmppvCardTempModule.xmppvCardTempModuleStorage vCardTempForJID:self.xmppStream.myJID.bareJID xmppStream:self.xmppStream];
        if (realvCardTemp != nil) {
            realvCardTemp.nickname = vCardTemp.nickname;
            [self.xmppvCardTempModule.xmppvCardTempModuleStorage setvCardTemp:realvCardTemp forJID:self.xmppStream.myJID.bareJID xmppStream:self.xmppStream];
            vCardTemp = realvCardTemp;
        }
        
        [self.xmppvCardTempModule updateMyvCardTemp:vCardTemp];
        
        //ALF IOSM-452
        XMPPPresence *presence = [XMPPPresence presence];
        NSXMLElement *xElement = [NSXMLElement elementWithName:@"x" xmlns:@"vcard-temp:x:update"];
        NSXMLElement *displayElement = [NSXMLElement elementWithName:@"displayname" stringValue:self.chatAccount.displayName];
        NSXMLElement *displayOnly = [NSXMLElement elementWithName:@"displayonly" stringValue:@"YES"];
        [xElement addChild:displayElement];
        [xElement addChild:displayOnly];
        [presence addChild:xElement];
        [self.xmppStream sendElement:presence];
        
        //IOSM-606
        [self setRoomNicknames:vCardTemp.nickname];
    }
}

//IOSM-606
- (void) setRoomNicknames:(NSString *)newnick {
    //__weak typeof(self)weakSelf = self;
    //async
    NSArray<ChatRoomModel*> *roomsArray = [ChatRoomModel allXMPPRoomsFor:self.chatAccount.uniqueId];
    [roomsArray enumerateObjectsUsingBlock:^(ChatRoomModel * _Nonnull room, NSUInteger idx, BOOL * _Nonnull stop) {
        XMPPRoom *xroom = [self.roomManager roomForJID:room.roomJID];
        [xroom changeNickname:newnick];
    }];
}

- (void) updateNetworkCheckBypass:(BOOL)bypass {
    //NSString *collection = [self.chatAccount.class collection];
    NSString *key = self.chatAccount.uniqueId;
    ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:key];
    account.bypassNetworkCheck = bypass;
    [account saveXMPPAccountAsync];
    self.chatAccount.bypassNetworkCheck = bypass;
}

- (void) updateUseStageConsole:(BOOL)useStage {
    //NSString *collection = [self.chatAccount.class collection];
    NSString *key = self.chatAccount.uniqueId;
    ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:key];
    account.useStageConsole = useStage;
    [account saveXMPPAccountAsync];
    [TwilioBackendManager sharedMgr].isStage = useStage;
    self.chatAccount.useStageConsole = useStage;
}

#pragma mark XMPPvCardTempModuleDelegate

- (void)xmppvCardTempModule:(XMPPvCardTempModule *)vCardTempModule
        didReceivevCardTemp:(XMPPvCardTemp *)vCardTemp
                     forJID:(XMPPJID *)jid {
    // DDLogVerbose(@"%@: %@ %@ %@ %@", THIS_FILE, THIS_METHOD, vCardTempModule, vCardTemp, jid);
    
    // update my vCard to local nickname setting
    // currently this will clobber whatever you have on the server
    if ([self.xmppStream.myJID isEqualToJID:jid options:XMPPJIDCompareBare]) {
        BOOL updateDisplayName = NO; //IOSM-606 and changes below
        if (self.chatAccount.displayName.length &&
            vCardTemp.nickname.length &&
            ![vCardTemp.nickname isEqualToString:self.chatAccount.displayName]) {
            //vCardTemp.nickname = self.chatAccount.displayName;
            //[vCardTempModule updateMyvCardTemp:vCardTemp];
            updateDisplayName = YES;
            [vCardTempModule.xmppvCardTempModuleStorage setvCardTemp:vCardTemp forJID:jid xmppStream:self.xmppStream];
            [self setRoomNicknames:vCardTemp.nickname];
        } else if (self.chatAccount.displayName.length &&
                   vCardTemp.nickname.length &&
                   [vCardTemp.nickname isEqualToString:self.chatAccount.displayName]) {
            DDLogInfo(@"updated vCard but no need to do anything %@ %@ %@ %@", THIS_METHOD, vCardTempModule, vCardTemp, jid);
        } else if (vCardTemp.nickname.length) {
            updateDisplayName = YES;
        }
        
        if (updateDisplayName) {
            //NSString *collection = [self.chatAccount.class collection];
            NSString *key = self.chatAccount.uniqueId;
            ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:key];
            account.displayName = vCardTemp.nickname;
            [account saveXMPPAccountAsync];
        }
    } else {
        // this is someone elses vCard
        DDLogVerbose(@"other's vCard %@ %@ %@ %@", THIS_METHOD, vCardTempModule, vCardTemp, jid);
    }
}

- (void)xmppvCardTempModule:(XMPPvCardTempModule *)vCardTempModule
   failedToFetchvCardForJID:(XMPPJID *)jid
                      error:(NSXMLElement*)error {
    DDLogWarn(@"%@ %@ %@ %@", THIS_METHOD, vCardTempModule, jid, error);
    
    // update my vCard to local nickname setting
    if ([self.xmppStream.myJID isEqualToJID:jid options:XMPPJIDCompareBare] &&
        self.chatAccount.displayName.length) {
        XMPPvCardTemp *vCardTemp = [XMPPvCardTemp vCardTemp];
        vCardTemp.nickname = self.chatAccount.displayName;
        [vCardTempModule updateMyvCardTemp:vCardTemp];
    }
}

- (void)xmppvCardTempModuleDidUpdateMyvCard:(XMPPvCardTempModule *)vCardTempModule {
    //DDLogVerbose(@"%@: %@ %@", THIS_FILE, THIS_METHOD, vCardTempModule);
}

- (void)xmppvCardTempModule:(XMPPvCardTempModule *)vCardTempModule failedToUpdateMyvCard:(NSXMLElement *)error {
    DDLogWarn(@"%@ %@ %@", THIS_METHOD, vCardTempModule, error);
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark XMPPRosterDelegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//ALF IOSM-479
- (void)xmppRosterDidBeginPopulating:(XMPPRoster *)sender withVersion:(NSString *)version {
    [self.teams removeAllObjects];
}

- (void)xmppRoster:(XMPPRoster *)sender didReceiveRosterItem:(NSXMLElement *)item {
    DDLogVerbose(@"%@ %@", THIS_METHOD, item);
    
    //ALF IOSM-479
    NSXMLElement *group = [item elementForName:@"group"];
    if (group != nil) {
        [self.teams addObject:group.stringValue];
    }
    
    // There's no way to know if a vCard has changed without fetching all of them again
    // To preserve user mobile data, just fetch each vCard once, only if it's never been fetched
    // Otherwise you'll only receive vCard updates if someone updates their avatar
    NSString *jidStr = [item attributeStringValueForName:@"jid"];
    XMPPJID *jid = [[XMPPJID jidWithString:jidStr] bareJID];
    
    //DDLogInfo(@"***** didReceiveRosterItem: %@",jidStr);
    [ChatBuddyModel fetchBuddyAsyncWithJid:jid accountUniqueId:self.chatAccount.uniqueId queue:self.workQueue completion:^(ChatBuddyModel *buddy){
        if (!buddy) {
            // in 3 seconds, try again on workQueue
            if (!self.retriedRoster) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), self.workQueue, ^{
                    self.retriedRoster = YES;
                    [self xmppRoster:sender didReceiveRosterItem:item];
                });
            }
            return;
        }
        XMPPvCardTemp *vCard = [self.xmppvCardTempModule vCardTempForJID:jid shouldFetch:YES];
        if (!vCard) {
            return;
        } else if ((buddy.avatarData == nil || buddy.displayName.length == 0) && vCard.photo == nil && buddy.waitingForvCardTempFetch == NO) {
            buddy.waitingForvCardTempFetch = YES;
            //DDLogInfo(@"***** didReceiveRosterItem, force fetching vcard: %@",jidStr);
            [self.xmppvCardTempModule forceFetchvCardTempForJID:jid];
        }
        
        
        //WHY ARE WE GETTIN BUDDY WHEN WE JUST GOT BUDDY?
        //buddy = [ChatBuddyModel getBuddyWithUniqueId:buddy.uniqueId];
        //if (!buddy) { return; }
            
        //IOSM-452
        NSString *nameStr = [item attributeStringValueForName:@"name"];
        if (![nameStr isEqualToString:vCard.nickname]) {
            vCard.nickname = nameStr;
            buddy.displayName = nameStr;
        }
            
        //buddy.vCardTemp = vCard;
        //[buddy saveThread];
        [buddy updateVCard:vCard];
    }];
}

-(void)xmppRoster:(XMPPRoster *)sender didReceivePresenceSubscriptionRequest:(XMPPPresence *)presence
{
    DDLogVerbose(@"%@ %@", THIS_METHOD, presence);
    
	NSString *jidStrBare = [presence fromStr];
    
    ChatBuddyModel *buddy = [ChatBuddyModel fetchBuddyModelWithJid:[[presence from] bareJID] accountUniqueId:self.chatAccount.uniqueId];
    if (!buddy) {
        buddy = [[ChatBuddyModel alloc] init];
        buddy.accountUniqueId = self.chatAccount.uniqueId;
        //buddy.trustLevel = BuddyTrustLevelRoster;
        buddy.displayName = [[presence from] user];
        buddy.username = jidStrBare;
    }
    //if (!buddy.askingForApproval) {
    //DDLogInfo(@"***** didReceivePresenceSubscriptionRequest: %@",jidStrBare);
        [buddy setAskingForApproval:YES];
        [buddy saveThread];
        [[UIApplication sharedApplication] showLocalNotificationForSubscriptionRequestFrom:jidStrBare];
    //}
}

- (void)xmppRoster:(XMPPRoster *)sender didReceiveRosterPush:(XMPPIQ *)iq
{
    DDLogVerbose(@"%@ %@", THIS_METHOD, iq);
    //verry unclear what this delegate call is supposed to do with jabber.ccc.de it seems to have all the subscription=both,none and jid
    /*
    if ([iq isSetIQ] && [[[[[[iq elementsForName:@"query"] firstObject] elementsForName:@"item"] firstObject] attributeStringValueForName:@"subscription"] isEqualToString:@"from"]) {
        NSString *jidString = [[[[[iq elementsForName:@"query"] firstObject] elementsForName:@"item"] firstObject] attributeStringValueForName:@"jid"];
        
        
            OTRXMPPPresenceSubscriptionRequest *request = [OTRXMPPPresenceSubscriptionRequest fetchPresenceSubscriptionRequestWithJID:jidString accontUniqueId:self.chatAccount.uniqueId];
            if (!request) {
                request = [[OTRXMPPPresenceSubscriptionRequest alloc] init];
            }
            
            request.jid = jidString;
            request.accountUniqueId = self.chatAccount.uniqueId;
     
            save...
    }
    else if ([iq isSetIQ] && [[[[[[iq elementsForName:@"query"] firstObject] elementsForName:@"item"] firstObject] attributeStringValueForName:@"subscription"] isEqualToString:@"none"])
    {
            NSString *jidString = [[[[[iq elementsForName:@"query"] firstObject] elementsForName:@"item"] firstObject] attributeStringValueForName:@"jid"];
            
     ChatBuddyModel *buddy = [[ChatBuddyModel fetchBuddyWithUsername:jidString withAccountUniqueId:self.chatAccount.uniqueId] copy];
            buddy.pendingApproval = YES;
            [buddy saveThread];
    }
    
    */
    
    
}

#pragma mark XMPPPushDelegate

- (void) pushAccountChanged:(NSNotification*)notif {
    //NSString *collection = [self.chatAccount.class collection];
    NSString *key = self.chatAccount.uniqueId;
    ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:key];
    
    if (!account.pushPubsubEndpoint) { return; }
    XMPPJID *serverJID = [XMPPJID jidWithUser:nil domain:account.pushPubsubEndpoint resource:nil];
    if (!serverJID) { return; }
    XMPPPushStatus status = [self.xmppPushModule registrationStatusForServerJID:serverJID];
    if (status != XMPPPushStatusRegistered &&
        status != XMPPPushStatusRegistering) {
        [self.xmppPushModule refresh];
    }
}

- (void)pushModule:(XMPPPushModule*)module readyWithCapabilities:(NSXMLElement *)caps jid:(XMPPJID *)jid {
    // Enable XEP-0357 push bridge if server supports it
    [self registerPushTokens]; //ALF IOSM-461
}

//ALF IOSM-461 make this public if needed. added || voiptoken
- (void)registerPushTokens {
    NSString *token = [OTRProtocolManager.pushController getPushToken];
    NSString *voiptoken = [OTRProtocolManager.pushController getVoipToken];
    if (token != nil || voiptoken != nil) { 
        XMPPJID *userjid = [XMPPJID jidWithString:self.chatAccount.username resource:self.chatAccount.resource];
        NSString *pushjid = [@"p2." stringByAppendingString:[GlacierInfo defaultHost]];
        
        [self.xmppPushModule handleDeviceTokenWithJID:userjid tojid:pushjid token:token voiptoken:voiptoken elementId:nil];
    }
}

- (void)pushModule:(XMPPPushModule*)module
didRegisterWithResponseIq:(XMPPIQ*)responseIq
        outgoingIq:(XMPPIQ*)outgoingIq {
    DDLogVerbose(@"%@ %@ %@", THIS_METHOD, responseIq, outgoingIq);
    
    // get node and server ID
    NSXMLElement *enable = [outgoingIq elementForName:@"enable" xmlns:XMPPPushXMLNS];
    if (enable == nil) {
        return;
    }
    
    NSString *serverjid = [enable attributeStringValueForName:@"jid"];
    NSString *node = [enable attributeStringValueForName:@"node"];
    
    //NSString *collection = [self.chatAccount.class collection];
    NSString *key = self.chatAccount.uniqueId;
    ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:key];
    if (account != nil) {
        account.pushPubsubEndpoint = serverjid;
        account.pushPubsubNode = node;
        [account saveXMPPAccountAsync];
    }
}

- (void)pushModule:(XMPPPushModule*)module
failedToRegisterWithErrorIq:(nullable XMPPIQ*)errorIq
        outgoingIq:(XMPPIQ*)outgoingIq {
    DDLogVerbose(@"%@ %@ %@", THIS_METHOD, errorIq, outgoingIq);
}

- (void)pushModule:(XMPPPushModule*)module
disabledPushForServerJID:(XMPPJID*)serverJID
              node:(nullable NSString*)node
        responseIq:(XMPPIQ*)responseIq
        outgoingIq:(XMPPIQ*)outgoingIq {
    DDLogVerbose(@"%@ %@ %@", THIS_METHOD, responseIq, outgoingIq);
}

- (void)pushModule:(XMPPPushModule*)module
failedToDisablePushWithErrorIq:(nullable XMPPIQ*)errorIq
         serverJID:(XMPPJID*)serverJID
              node:(nullable NSString*)node
        outgoingIq:(XMPPIQ*)outgoingIq {
    DDLogVerbose(@"%@ %@ %@", THIS_METHOD, errorIq, outgoingIq);
}


////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark OTRProtocol
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void) sendMessage:(OutgoingChatMessage*)message
{
    NSParameterAssert(message);
    NSString *text = message.messageText;
    if (!text.length) {
        return;
    }
    ChatBuddyModel *buddy = (ChatBuddyModel *)[message threadOwner];
    if (!buddy || ![buddy isKindOfClass:[ChatBuddyModel class]]) {
        return;
    }
    [self invalidatePausedChatStateTimerForBuddyUniqueId:buddy.uniqueId];
    
    NSString * messageID = message.remoteMessageId;
    XMPPMessage * xmppMessage = [XMPPMessage messageWithType:@"chat" to:buddy.bareJID elementID:messageID];
    [xmppMessage addBody:text];
    [xmppMessage addActiveChatState];
    
    if (message.messageExpires) {
        NSXMLElement *expiresElement = [NSXMLElement elementWithName:@"x" xmlns:@"jabber:x:msgexpire"];
        [expiresElement addAttributeWithName:@"seconds" stringValue:message.messageExpires];
        [xmppMessage addChild:expiresElement];
    }
    
    //ALF IOSM-442
    if (message.isSystemUpdate) {
        NSXMLElement *updateElement = [NSXMLElement elementWithName:@"x" xmlns:@"jabber:x:systemupdate"];
        [xmppMessage addChild:updateElement];
    } else { //ALF IOSM-443
        [xmppMessage addMarkableChatMarker];
    }
    
    if (self.loginStatus == OTRLoginStatusAuthenticated) { //IOSM#70
        [self.xmppStream sendElement:xmppMessage];
    }
}

- (NSString*) type {
    return kOTRProtocolTypeXMPP;
}

- (void) connectUserInitiated:(BOOL)userInitiated
{
    //DDLogInfo(@"***** connectUserInitiated");
    self.userInitiatedConnection = userInitiated;
    // Don't issue a reconnect if we're already connected and authenticated
    if ([self.xmppStream isConnected] && [self.xmppStream isAuthenticated]) {
        if (self.loginStatus != OTRLoginStatusAuthenticated) {
            [self xmppStreamDidAuthenticate:self.xmppStream];
        } else {
            [self goOnline];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (([OTRAppDelegate appDelegate].voipNotification)) {
                [self.messageStorage fetchHistoryForVoip];
            }
        });
        
        return;
    } else if ([self.xmppStream isConnecting] || [self.xmppStream isAuthenticating]) {
        //IOSM-570 bypass if connecting already
        return;
    }
    [self startConnection];
}

-(void)connect
{
    [self connectUserInitiated:NO];
}

//IOSM#80
-(BOOL)connectFromBackground
{
    if (([self.xmppStream isConnected] && [self.xmppStream isAuthenticated]) || [self.xmppStream isConnecting] || [self.xmppStream isAuthenticating]) {
        return NO;
    }
    
    //NSLog(@"***** connectFromBackground to get latest data on com.apple.pushLaunch");
    [self startConnection];
    return YES;
}

- (void)sendChatStateMessage:(XMPPMessage *)xMessage {
    if (!xMessage) {
        return;
    }
    
    //IOSM#43
    if (!(self.loginStatus == OTRLoginStatusAuthenticated)) {
        return;
    }
    
    dispatch_async(self.workQueue, ^{
        if(self.loginStatus == OTRLoginStatusAuthenticated)
        {
            //[BuddyCache.shared setLastSentChatState:chatState buddy:buddy];
            [self.xmppStream sendElement:xMessage];
        }
    });
}

-(void)sendChatState:(ChatState)chatState withBuddyId:(NSString *)buddyUniqueId
{
    //IOSM#43
    if (!(self.loginStatus == OTRLoginStatusAuthenticated)) {
        return;
    }
    
    dispatch_async(self.workQueue, ^{
        ChatBuddyModel *buddy = [ChatBuddyModel getBuddyWithUniqueId:buddyUniqueId];
        if (!buddy) { return; }
        
        if ([BuddyCache.shared lastSentChatStateWithBuddy:buddy] == chatState) {
            return;
        }
        
        XMPPMessage * xMessage = [[XMPPMessage alloc] initWithType:@"chat" to:[XMPPJID jidWithString:buddy.username]];
        BOOL shouldSend = YES;
        
        if (chatState == ChatStateActive) {
            //Timers
            dispatch_async(dispatch_get_main_queue(), ^{
                [[self pausedChatStateTimerForBuddyObjectID:buddyUniqueId] invalidate];
                [self restartInactiveChatStateTimerForBuddyObjectID:buddyUniqueId];
            });
            
            [xMessage addActiveChatState];
        }
        else if (chatState == ChatStateComposing)
        {
            if([BuddyCache.shared lastSentChatStateWithBuddy:buddy] !=ChatStateComposing)
                [xMessage addComposingChatState];
            else
                shouldSend = NO;
            
            //Timers
            dispatch_async(dispatch_get_main_queue(), ^{
                [self restartPausedChatStateTimerForBuddyObjectID:buddy.uniqueId];
                [[self inactiveChatStateTimerForBuddyObjectID:buddy.uniqueId] invalidate];
            });
        }
        else if(chatState == ChatStateInactive)
        {
            if([BuddyCache.shared lastSentChatStateWithBuddy:buddy] != ChatStateInactive)
                [xMessage addInactiveChatState];
            else
                shouldSend = NO;
        }
        else if (chatState == ChatStatePaused)
        {
            [xMessage addPausedChatState];
        }
        else if (chatState == ChatStateGone)
        {
            [xMessage addGoneChatState];
        }
        else
        {
            shouldSend = NO;
        }
        
        if(shouldSend && self.loginStatus == OTRLoginStatusAuthenticated)
        {
            [BuddyCache.shared setLastSentChatState:chatState buddy:buddy];
            [self.xmppStream sendElement:xMessage];
        }
    });
}

/*- (void) setDisplayName:(NSString *) newDisplayName forBuddy:(ChatBuddyModel *)buddy
{
    XMPPJID * jid = [XMPPJID jidWithString:buddy.username];
    [self.xmppRoster setNickname:newDisplayName forUser:jid];
    
}*/

//Chat State

-(OTRXMPPBuddyTimers *)buddyTimersForBuddyObjectID:(NSString *)
managedBuddyObjectID
{
    OTRXMPPBuddyTimers * timers = [self.buddyTimers objectForKey:managedBuddyObjectID];
    return timers;
}

-(NSTimer *)inactiveChatStateTimerForBuddyObjectID:(NSString *)
managedBuddyObjectID
{
   return [self buddyTimersForBuddyObjectID:managedBuddyObjectID].inactiveChatStateTimer;
    
}
-(NSTimer *)pausedChatStateTimerForBuddyObjectID:(NSString *)
managedBuddyObjectID
{
    return [self buddyTimersForBuddyObjectID:managedBuddyObjectID].pausedChatStateTimer;
}

-(void)restartPausedChatStateTimerForBuddyObjectID:(NSString *)managedBuddyObjectID
{
    dispatch_async(dispatch_get_main_queue(), ^{
        OTRXMPPBuddyTimers * timer = [self.buddyTimers objectForKey:managedBuddyObjectID];
        if(!timer)
        {
            timer = [[OTRXMPPBuddyTimers alloc] init];
        }
        [timer.pausedChatStateTimer invalidate];
        timer.pausedChatStateTimer = [NSTimer scheduledTimerWithTimeInterval:kChatStatePausedTimeout target:self selector:@selector(sendPausedChatState:) userInfo:managedBuddyObjectID repeats:NO];
        [self.buddyTimers setObject:timer forKey:managedBuddyObjectID];
    });
    
}
-(void)restartInactiveChatStateTimerForBuddyObjectID:(NSString *)managedBuddyObjectID
{
    dispatch_async(dispatch_get_main_queue(), ^{
        OTRXMPPBuddyTimers * timer = [self.buddyTimers objectForKey:managedBuddyObjectID];
        if(!timer)
        {
            timer = [[OTRXMPPBuddyTimers alloc] init];
        }
        [timer.inactiveChatStateTimer invalidate];
        timer.inactiveChatStateTimer = [NSTimer scheduledTimerWithTimeInterval:kChatStateInactiveTimeout target:self selector:@selector(sendInactiveChatState:) userInfo:managedBuddyObjectID repeats:NO];
        [self.buddyTimers setObject:timer forKey:managedBuddyObjectID];
    });
}
-(void)sendPausedChatState:(NSTimer *)timer
{
    NSString * managedBuddyObjectID= (NSString *)timer.userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [timer invalidate];
    });
    
    if (self.loginStatus == OTRLoginStatusAuthenticated) {
        XMPPMessage *xMessage = [self getPausedMessage:managedBuddyObjectID];
        if (xMessage && self.loginStatus == OTRLoginStatusAuthenticated) {
            [self sendChatStateMessage:xMessage];
        }
    }
    //[self sendChatStateMessage:ChatStatePaused buddyUniqueId:managedBuddyObjectID];
}

-(void)sendInactiveChatState:(NSTimer *)timer
{
    NSString *managedBuddyObjectID= (NSString *)timer.userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [timer invalidate];
    });
    
    if (self.loginStatus == OTRLoginStatusAuthenticated) {
        XMPPMessage *xMessage = [self getInactiveMessage:managedBuddyObjectID];
        if (xMessage) {
            [self sendChatStateMessage:xMessage];
        }
    }
    //[self sendChatState:ChatStateInactive buddyUniqueId:managedBuddyObjectID];
}

- (void)invalidatePausedChatStateTimerForBuddyUniqueId:(NSString *)buddyUniqueId
{
    [[self pausedChatStateTimerForBuddyObjectID:buddyUniqueId] invalidate];
}

- (void)failedToConnect:(NSError *)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_lastConnectionError = error;
        
        //Only user initiated on the first time any subsequent attempts will not be from user
        self.userInitiatedConnection = NO;
        
        if (error) {
            [UIApplication.sharedApplication showConnectionErrorNotificationWithAccount:self.chatAccount error:error];
        }
    });
}

- (OTRCertificatePinning *)certificatePinningModule
{
    if(!_certificatePinningModule){
        _certificatePinningModule = [[OTRCertificatePinning alloc] init];
        _certificatePinningModule.delegate = self;
    }
    return _certificatePinningModule;
}

- (void)newTrust:(SecTrustRef)trust withHostName:(NSString *)hostname systemTrustResult:(SecTrustResultType)trustResultType
{
    NSData * certifcateData = [OTRCertificatePinning dataForCertificate:[OTRCertificatePinning certForTrust:trust]];
    
    DDLogVerbose(@"New trustResultType: %d certLength: %d", (int)trustResultType, (int)certifcateData.length);
    
    [OTRCertificatePinning addCertificateData:certifcateData withHostName:hostname];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self startConnection];
    });
}

// Delivery receipts
- (void) sendDeliveryReceiptForMessage:(IncomingChatMessage*)message {
    ChatBuddyModel *buddy = [message xmppBuddy];//[ChatBuddyModel getBuddyWithUniqueId:message.threadId];
    XMPPMessage *tempMessage = [XMPPMessage messageWithType:@"chat" elementID:message.remoteMessageId];
    [tempMessage addAttributeWithName:@"from" stringValue:buddy.username];
    XMPPMessage *receiptMessage = [tempMessage generateReceiptResponse];
    if (self.loginStatus == OTRLoginStatusAuthenticated) { //IOSM#43
        [self.xmppStream sendElement:receiptMessage];
    }
}

//IOSM-443
-(void)sendReadReceipt:(id<MessageProtocol>)message {
    //if (!thread.isGroupThread) {
    //final boolean markable = packet.hasChild("markable", "urn:xmpp:chat-markers:0");
    
    XMPPMessage *receiptMessage = nil;
    if ([message.messageCollection isEqualToString:[ChatRoomMessageModel collection]]) {
        ChatRoomMessageModel *imessage = (ChatRoomMessageModel *)message;// copy];
        NSString * messageID = imessage.xmppId;
        receiptMessage = [XMPPMessage messageWithType:@"groupchat" to:[XMPPJID jidWithString:imessage.roomJID] elementID:messageID];
        if (imessage.senderJID != nil) {
            [receiptMessage addDisplayedChatMarkerWithID:[receiptMessage elementID] sender:imessage.senderJID];
        } else {
            [receiptMessage addDisplayedChatMarkerWithID:[receiptMessage elementID]];
        }
    } else {
        IncomingChatMessage *imessage = (IncomingChatMessage *)message; //) copy];
        NSString * messageID = imessage.remoteMessageId;
        ChatBuddyModel *buddy = [message xmppBuddy];
        if (!buddy || ![buddy isKindOfClass:[ChatBuddyModel class]]) {
            return;
        }
        receiptMessage = [XMPPMessage messageWithType:@"chat" to:buddy.bareJID elementID:messageID];
        [receiptMessage addDisplayedChatMarkerWithID:[receiptMessage elementID]];
    }
    
    XMPPJID *jid = [XMPPJID jidWithString:self.chatAccount.username resource:self.chatAccount.resource];
    [receiptMessage addAttributeWithName:@"from" stringValue:jid.full];
    [receiptMessage addStorageHint:XMPPMessageStorageStore];
    
    if (self.loginStatus == OTRLoginStatusAuthenticated) { //IOSM#70
        [self.xmppStream sendElement:receiptMessage];
    }
}

// A new buddy has approved us, show a local notification
- (void) buddyPendingApprovalStateChanged:(NSNotification*)notif {
    if (notif != nil && notif.userInfo != nil) {
        ChatBuddyModel *buddy = [notif.userInfo objectForKey:@"buddy"];
        if (buddy != nil) {
            [[UIApplication sharedApplication] showLocalNotificationForApprovedBuddy:buddy];
        }
    }
}

@end
