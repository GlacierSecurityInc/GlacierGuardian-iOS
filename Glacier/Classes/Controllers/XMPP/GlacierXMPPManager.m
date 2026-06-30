//
//  GlacierXMPPManager.m
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

#import "GlacierXMPPManager.h"

@import CocoaAsyncSocket;
@import XMPPFramework;

#import "GlacierLog.h"

#import <CFNetwork/CFNetwork.h>
#import <os/log.h>
#import <ifaddrs.h>
#import <net/if.h>

#import "GlacierSettingsManager.h"
#import "GlacierConstants.h"
#import "GlacierInfo.h"
#import "GlacierProtocolManager.h"
#include <stdlib.h>
#import "GlacierConstants.h"
#import "GlacierUtilities.h"

#import "GlacierXMPPRoomManager.h"
#import "GlacierXMPPBuddyTimers.h"
#import "GlacierXMPPError.h"
#import "GlacierXMPPManager_Private.h"
#import "UIImage+Glacier.h"
#import "XMPPPushModule.h"
#import "Glacier-Swift.h"
//@import Sentry;

@interface GlacierXMPPManager ()
@property (assign, nonatomic) BOOL enablingPush;
@property (assign, nonatomic) BOOL retriedRoster;
@property (assign, nonatomic) BOOL disconnectedBuddies;
/// YES when the most recent disconnect had no error (our connectWithTimeout timer fired).
/// Used by xmppReconnect:shouldAttemptAutoReconnect: to suppress XMPPReconnect's
/// immediate-retry when a clean timeout already fired; the status timer handles that case.
/// NO (default) lets XMPPReconnect reconnect fast after real network-error disconnects.
@property (assign, nonatomic) BOOL lastDisconnectWasClean;
/// Guards against launching two VPN warm-up probes concurrently.
@property (assign, nonatomic) BOOL vpnProbeInFlight;

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

@implementation GlacierXMPPManager

- (instancetype)init
{
    if (self = [super init]) {
        NSString * queueLabel = [NSString stringWithFormat:@"%@.work.%@",[self class],self];
        _workQueue = dispatch_queue_create([queueLabel UTF8String], 0);
        _buddyTimers = [NSMutableDictionary dictionary];
        _enablingPush = NO;
        _retriedRoster = NO;
        _disconnectedBuddies = NO;
        _teams = [[NSMutableSet alloc ]init];
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

- (GlacierXMPPStream*) newStream {
    return [[GlacierXMPPStream alloc] init];
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
    // XMPPReconnect auto-reconnect is controlled per-disconnect via the delegate
    // (xmppReconnect:shouldAttemptAutoReconnect:) based on _lastDisconnectWasClean.
    // See xmppStreamDidDisconnect:withError: for the flag that drives this.

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
    
    _serverCheck = [[ServerCheck alloc] initWithPush:GlacierProtocolManager.pushController pushModule:self.xmppPushModule dispatchQueue:nil];
    [self.serverCheck activate:self.xmppStream];
    
    _callManager = [CallManager sharedCallManager];
    [_callManager setAccount:_chatAccount];
    [self.callManager activate:self.xmppStream];
    
	// Activate xmpp modules
    
	[self.xmppReconnect         activate:self.xmppStream];
    [self.xmppReconnect         addDelegate:self delegateQueue:self.workQueue];
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
    /*_streamManagementDelegate = [[GlacierStreamManagementDelegate alloc] init];
    
    XMPPStreamManagementMemoryStorage *memoryStorage = [[XMPPStreamManagementMemoryStorage alloc] init];
    _streamManagement = [[XMPPStreamManagement alloc] initWithStorage:memoryStorage];
    [self.streamManagement addDelegate:self.streamManagementDelegate delegateQueue:self.workQueue];
    [self.streamManagement automaticallyRequestAcksAfterStanzaCount:10 orTimeout:5];
    [self.streamManagement automaticallySendAcksAfterStanzaCount:10 orTimeout:5];
    self.streamManagement.autoResume = YES;
    [self.streamManagement activate:self.xmppStream];*/
    
    //MUC
    _roomManager = self.messageStorage.roomManager;
    
    //Message Queue Module
    _messageStatusModule = [[XMPPMessageStatusModule alloc] initWithDelegate:self.messageQueueHandler];
    [self.messageStatusModule activate:self.xmppStream];
    
    //OMEMO
    if (GlacierInfo.allowOMEMO) {
        self.omemoSignalCoordinator = [[OMEMOSignalCoordinator alloc] initWithAccountKey:_chatAccount.uniqueId messageStorage:self.messageStorage roomManager:self.roomManager error:nil];
        _omemoModule = [[OMEMOModule alloc] initWithOMEMOStorage:self.omemoSignalCoordinator xmlNamespace:OMEMOModuleNamespaceConversationsLegacy];
        [self.omemoModule addDelegate:self.omemoSignalCoordinator delegateQueue:self.workQueue];
        [self.serverCheck.xmppCapabilities addDelegate:self.omemoModule delegateQueue:self.workQueue];
        [self.omemoModule activate:self.xmppStream];
        [self.omemoSignalCoordinator setJID:self.xmppStream.myJID];
        //self.messageStorage.roomManager.roomStorage.om
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pushAccountChanged:) name:GlacierPushAccountDeviceChanged object:GlacierProtocolManager.pushController];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pushAccountChanged:) name:GlacierPushAccountTokensChanged object:GlacierProtocolManager.pushController];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(buddyPendingApprovalStateChanged:) name:BuddyPendingApprovalDidChangeNotification object:self.xmppRosterStorage];
    
}

- (void)teardownStream
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:BuddyPendingApprovalDidChangeNotification object:self.xmppRosterStorage];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:GlacierPushAccountDeviceChanged object:GlacierProtocolManager.pushController];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:GlacierPushAccountTokensChanged object:GlacierProtocolManager.pushController];

    [_xmppStream removeDelegate:self];
    [_xmppRoster removeDelegate:self];
    [_xmppvCardTempModule removeDelegate:self];
    [_xmppPushModule removeDelegate:self];
    
    [_serverCheck.xmppCapabilities removeDelegate:self];
    [_serverCheck.xmppCapabilities removeDelegate:self.omemoModule];
    [_serverCheck.xmppCapabilities removeDelegate:self.roomManager];
    [_xmppRoster removeDelegate:self.xmppRosterStorage];
    //[_streamManagement removeDelegate:self.streamManagementDelegate];
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
    //[_streamManagement deactivate];
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
    //[_streamManagement sendAck];
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
    [self sendAcknowledgments]; // flush acks before iOS suspends us
    [GlacierAppDelegate getLastInteractionDate:^(NSDate * _Nullable date) {
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
                } else if ([_callManager isRinging]) {
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
    [GlacierAppDelegate getLastInteractionDate:^(NSDate * _Nullable date) {
        XMPPPresence *presence = [XMPPPresence presenceWithType:@"unavailable"];
        NSDate *idleDate = date;
        [self addIdleDate:idleDate toPresence:presence]; // I don't think this does anything
        
        [self.xmppStream sendElement:presence];
        [self updateClientState:XMPPClientStateInactive];
        
        /*dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), self.workQueue, ^{
                [self.xmppStream disconnectAfterSending];
        });*/
    } completionQueue:self.workQueue];
}

- (NSDate *) getLastConnected {
    return self.lastConnected;
}

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

/// Returns YES if any active VPN tunnel interface (utun*) with an assigned IPv4 address
/// is present on the device. Requiring AF_INET excludes the system utun0 interface which
/// is always present but only carries an IPv6 link-local address.
- (BOOL)isVPNTunnelActive {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) { return NO; }
    BOOL found = NO;
    for (struct ifaddrs *iface = interfaces; iface != NULL; iface = iface->ifa_next) {
        if (strncmp(iface->ifa_name, "utun", 4) == 0 &&
            (iface->ifa_flags & IFF_UP) &&
            (iface->ifa_flags & IFF_RUNNING) &&
            iface->ifa_addr != NULL &&
            iface->ifa_addr->sa_family == AF_INET) {
            found = YES;
            break;
        }
    }
    freeifaddrs(interfaces);
    return found;
}

/// Sends a short-lived HTTPS probe through the VPN tunnel to force the dormant
/// NEPacketTunnelProvider awake, then calls xmppStream connectWithTimeout:.
/// The probe result is irrelevant — the SYN/ACK round-trip is what wakes the extension.
- (void)warmVPNTunnelWithHostname:(NSString *)hostname thenConnectWithTimeout:(NSTimeInterval)timeout {
    self.vpnProbeInFlight = YES;
    NSString *probeURLString = [NSString stringWithFormat:@"https://%@/", hostname];
    NSLog(@"***** VPN tunnel probe start: %@", probeURLString);

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 4.0;
    NSURLSession *probeSession = [NSURLSession sessionWithConfiguration:cfg];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:probeURLString]];
    req.HTTPMethod = @"HEAD";

    __weak typeof(self) weakSelf = self;
    [[probeSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *probeError) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        NSLog(@"***** VPN tunnel probe done (status: %ld, error: %@) — proceeding with XMPP connect",
              (long)[(NSHTTPURLResponse *)response statusCode], probeError.localizedDescription);
        strongSelf.vpnProbeInFlight = NO;
        if (![strongSelf.xmppStream isDisconnected]) { return; }
        dispatch_async(strongSelf.workQueue, ^{
            if (![strongSelf.xmppStream isDisconnected]) { return; }
            NSError *connectError = nil;
            if (![strongSelf.xmppStream connectWithTimeout:timeout error:&connectError]) {
                [strongSelf failedToConnect:connectError];
                DDLogError(@"Error connecting after VPN probe: %@", connectError);
            }
        });
    }] resume];
    [probeSession finishTasksAndInvalidate];
}

- (BOOL)startConnection
{
    /*if ([GlacierAppDelegate isTestFlight]) {
        SentryBreadcrumb *crumb = [[SentryBreadcrumb alloc] init];
        crumb.level = kSentryLevelInfo;
        crumb.category = @"xmpp";
        crumb.message = @"startXMPPConnection";
        // NSLog(@"*****DBG %@", crumb.message);
        [SentrySDK addBreadcrumb:crumb];
    }*/
    
    NSLog(@"***** startConnection");

    [self setLoginStatus:GlacierLoginStatusConnecting];
    self.lastConnectAttempt = [NSDate date];

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
    // 8s fits within the 14s UI status timer so the status timer always fires after
    // a failed attempt, keeping the two retry systems in sync.
    // When VPN is active the probe below warms the tunnel first, so connectWithTimeout:
    // sees a ready path and the 8s is more than sufficient.
    NSTimeInterval connectTimeout = 8.0;
    BOOL vpnActive = [self isVPNTunnelActive];
    NSLog(@"***** connectWithTimeout: %.0fs (VPN active: %@)", connectTimeout, vpnActive ? @"YES" : @"NO");

    // After the phone is locked for an extended period iOS suspends the NEPacketTunnelProvider
    // to save power. The utun interface stays UP (isVPNTunnelActive returns YES) but no packets
    // are forwarded until the extension wakes. XMPP's SYN is dropped while it wakes, so the
    // connect times out every time. Sending a pre-flight probe forces the extension awake;
    // the probe result doesn't matter — the round-trip going through is enough.
    // Worst case: 4s probe timeout + 8s XMPP timeout = 12s, same as the old VPN-specific path.
    if (vpnActive && domainString.length > 0) {
        if (!self.vpnProbeInFlight) {
            [self warmVPNTunnelWithHostname:domainString thenConnectWithTimeout:connectTimeout];
        }
        // If probe is already in flight it will call connectWithTimeout when done.
        return YES;
    }

    if (![self.xmppStream connectWithTimeout:connectTimeout error:&error])
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
        if (self.loginStatus == GlacierLoginStatusAuthenticated) {
            self.loginStatus = GlacierLoginStatusDisconnecting;
            [self goAway];
        }
        return;
    }
    
    [self sendAcknowledgments];
    
    self.loginStatus = GlacierLoginStatusDisconnecting;
    __block NSDate *nowdate = [NSDate date];
    self.lastDisconnect = nowdate;
    
    //[self goOffline]; //tells the server no longer interested in receiving stanzas
    [self.xmppStream disconnect];
    
    //call method on account that does async stuff and handles completion block
    //all but removeAccountFromRooms are async already
    if (!self.disconnectedBuddies) {
        self.disconnectedBuddies = YES;
        [self disconnectBuddiesAndRooms:[self shouldDisconnectBuddies]];
    }
    //[ChatBuddyModel disconnectAllBuddiesWithAccountId:self.chatAccount.uniqueId queue:self.workQueue];
    [ChatRoomModel updateLastHistoryWithAccountId:self.chatAccount.uniqueId];
    if([GlacierSettingsManager boolForSettingKey:kGlacierSettingKeyDeleteOnDisconnect]) {
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
        error = [NSError errorWithDomain:GlacierXMPPErrorDomain code:GlacierXMPPErrorCodeUnsupportedAction userInfo:nil];
        [self failedToRegisterNewAccount:error];
        return NO;
    }
    return YES;
}

#pragma mark Public Methods

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
    
    XMPPIQ *lastActivity = [XMPPIQ lastActivityQueryTo:buddy.bareJID];
    [self.xmppStream sendElement:lastActivity];
}

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
        newImage = [UIImage prepareForAvatarUpload:newImage maxSize:120.0];
        //jpeg compression
        NSData *data = UIImageJPEGRepresentation(newImage, 0.6);
        
        //Save new avatar right away to update UI
        //should be asyncReadWrite
        ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId:self.chatAccount.uniqueId];
        [account setAvatarData:data];
        [account saveXMPPAccountAsync];
        
        self.changeAvatar = [[XMPPChangeAvatar alloc] initWithPhotoData:data
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
    
    self.changePasswordManager = [[XMPPChangePasswordManager alloc] initWithNewPassword:newPassword xmppStream:self.xmppStream completion:^(BOOL success, NSError * _Nullable error) {
        
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
    self.loginStatus = GlacierLoginStatusConnected;
}

- (void)xmppStream:(XMPPStream *)sender willSecureWithSettings:(NSMutableDictionary *)settings
{
	DDLogVerbose(@"%@", THIS_METHOD);
    
    settings[GCDAsyncSocketSSLProtocolVersionMin] = @(kTLSProtocol1);
    settings[GCDAsyncSocketSSLCipherSuites] = [GlacierUtilities cipherSuites];
    settings[GCDAsyncSocketManuallyEvaluateTrust] = @(YES);
    
    self.loginStatus = GlacierLoginStatusSecuring;
}

- (void)xmppStreamDidSecure:(XMPPStream *)sender
{
	DDLogVerbose(@"%@", THIS_METHOD);
    
    self.loginStatus = GlacierLoginStatusSecured;
}

- (void)xmppStreamDidConnect:(XMPPStream *)sender
{
    /*if ([GlacierAppDelegate isTestFlight]) {
        SentryBreadcrumb *crumb = [[SentryBreadcrumb alloc] init];
        crumb.level = kSentryLevelInfo;
        crumb.category = @"xmpp";
        crumb.message = @"xmppStreamDidConnect";
        // NSLog(@"*****DBG %@", crumb.message);
        [SentrySDK addBreadcrumb:crumb];
    }*/
	DDLogVerbose(@"%@", THIS_METHOD);
    //[self.chatAccount setWaitingForvCardTempFetch:NO];
    self.chatAccount.waitingForvCardTempFetch = NO;
    if (self.isRegisteringNewAccount) {
        [self continueRegisteringNewAccount];
    }
    else{
        [self authenticateWithStream:sender];
    }
    
    self.loginStatus = GlacierLoginStatusAuthenticating;
}

- (void)xmppStreamDidDisconnect:(XMPPStream *)sender withError:(NSError *)error
{
    DDLogWarn(@"%@: %@ %@", THIS_FILE, THIS_METHOD, error);
    
    //DDLogWarn(@"Login status: %ld ", (long)self.loginStatus);
    //DDLogWarn(@"Last Connected: %@ ", self.lastConnected);
    //DDLogWarn(@"Last Disconnecting: %@ ", self.lastDisconnect);
    
    /*if ([GlacierAppDelegate isTestFlight]) {
        SentryBreadcrumb *crumb = [[SentryBreadcrumb alloc] init];
        crumb.level = kSentryLevelInfo;
        crumb.category = @"xmpp";
        crumb.message = @"xmppStreamDidDisconnect";
        // NSLog(@"*****DBG %@", crumb.message);
        [SentrySDK addBreadcrumb:crumb];
    }*/
    
    self.loginStatus = GlacierLoginStatusDisconnected;

    if (error)
    {
        NSLog(@"***** xmppStreamDidDisconnect error: %@ %@", self.chatAccount.bareJID.domain, error);
        self.lastDisconnectWasClean = NO;  // real error → XMPPReconnect may fire fast
        [self failedToConnect:error];
    } else {
        NSLog(@"***** xmppStreamDidDisconnect (clean): %@", self.chatAccount.bareJID.domain);
        self.lastDisconnectWasClean = YES; // our timeout fired → status timer handles retry
    }

    if (!self.disconnectedBuddies) {
        self.disconnectedBuddies = YES;
        [self disconnectBuddiesAndRooms:[self shouldDisconnectBuddies]];
    }
}

/// XMPPReconnect delegate — controls whether XMPPReconnect fires an immediate reconnect.
///
/// Controls whether XMPPReconnect fires an immediate no-timeout reconnect.
///
/// XMPPReconnect is activated on the stream (line 222) before GlacierXMPPManager adds
/// itself as a stream delegate (line 233), so XMPPReconnect's xmppStreamDidDisconnect:
/// fires FIRST and calls this delegate method before our handler has set lastDisconnectWasClean.
/// The flag is therefore unreliable as a race guard.
///
/// Instead we use the lastConnectAttempt timestamp: a connectWithTimeout:12s always fires
/// within 12s of startConnection, so if we're called less than 15s after the last attempt
/// we know we're in the timeout-retry loop — the status timer owns those retries.
/// For mid-session drops (network switch, RST) lastConnectAttempt is minutes old and
/// lastDisconnectWasClean (set by our handler before XMPPReconnect calls its own next
/// shouldAttemptAutoReconnect: in a future cycle) provides the secondary filter.
- (BOOL)xmppReconnect:(XMPPReconnect *)sender shouldAttemptAutoReconnect:(SCNetworkConnectionFlags)connectionFlags {
    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:self.lastConnectAttempt ?: [NSDate distantPast]];
    if (age < 15.0) {
        NSLog(@"***** xmppReconnect:shouldAttemptAutoReconnect: NO (connect attempt was %.0fs ago, in retry loop)", age);
        return NO;
    }
    BOOL allow = !self.lastDisconnectWasClean;
    NSLog(@"***** xmppReconnect:shouldAttemptAutoReconnect: %@ (lastDisconnectWasClean=%@, %.0fs since last attempt)",
          allow ? @"YES" : @"NO",
          self.lastDisconnectWasClean ? @"YES" : @"NO",
          age);
    return allow;
}

- (void)xmppStreamDidAuthenticate:(XMPPStream *)sender
{
    /*if ([GlacierAppDelegate isTestFlight]) {
        SentryBreadcrumb *crumb = [[SentryBreadcrumb alloc] init];
        crumb.level = kSentryLevelInfo;
        crumb.category = @"xmpp";
        crumb.message = @"xmppStreamDidAuthenticate";
        // NSLog(@"*****DBG %@", crumb.message);
        [SentrySDK addBreadcrumb:crumb];
    }*/
    
	DDLogVerbose(@"%@", THIS_METHOD);
    self.disconnectedBuddies = NO;

    NSArray *ackedStanzaIds = nil;
    NSXMLElement *resumeResponse = nil;
    /*BOOL didResume = [self.streamManagement didResumeWithAckedStanzaIds:&ackedStanzaIds serverResponse:&resumeResponse];

    if (didResume) {
        // NSLog(@"*****DBG %@", @"stream management resumed session");
        if (resumeResponse) {
            // NSLog(@"*****DBG resume response: %@", [resumeResponse XMLString]);
        }
    }

    if ([sender supportsStreamManagement] && !didResume) {
        // NSLog(@"*****DBG %@", @"supports stream mgmt and resuming");
        [self.streamManagement enableStreamManagementWithResumption:YES maxTimeout:0];
    } else if (![sender supportsStreamManagement]) {
        // NSLog(@"*****DBG %@", @"DOESNT support stream mgmt");
    } else if (didResume) {
        // NSLog(@"*****DBG %@", @"supports stream mgmt and already resumed");
    }*/
    
    self.loginStatus = GlacierLoginStatusAuthenticated;
    self.lastConnected = [NSDate date];

    // Seed the OMEMO coordinator's JID now that the stream is authenticated and
    // myJID is available. At -setupStream time (activate:) myJID can still be nil,
    // which would leave the coordinator falling back to a synchronous
    // omemoModule.xmppStream read from inside GRDB write transactions and risk a
    // DB-writer/XMPP-queue deadlock (0xdead10cc).
    if (self.omemoSignalCoordinator && sender.myJID) {
        [self.omemoSignalCoordinator setJID:sender.myJID];
        // Re-publish bundle so contacts can establish fresh sessions after re-login.
        // Without this the first incoming message often fails to decrypt because
        // the server bundle may reference consumed or stale prekeys.
        [self.omemoSignalCoordinator publishBundleAfterAuthentication];
    }
    NSString *accountKey = self.chatAccount.uniqueId;
    NSString *accountCollection = [[self.chatAccount class] collection];
    NSDictionary *userInfo = nil;
    
    if(accountKey && accountCollection) {
        userInfo = @{kGlacierNotificationAccountUniqueIdKey:accountKey,kGlacierNotificationAccountCollectionKey:accountCollection};
    }
    [[NSNotificationCenter defaultCenter]
     postNotificationName:kGlacierProtocolLoginSuccess
     object:self userInfo:userInfo];
    
    [self.callManager handleAuthentication];
    if (self.callManager.waitingToAnswerCall) {
        //[self goActive];
        //[self.callManager handleAuthentication];
        return;
    }
    
    [self goOnline];
    //if (!didResume) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!([GlacierAppDelegate appDelegate].silentUpdate)) {
                //dispatch_async(self.workQueue, ^{
                [self.xmppvCardTempModule forceFetchvCardTempForJID:[sender myJID]];
                [self.fileTransferManager resumeDownloads];
                //[self.callManager handleAuthentication];
                //});
            }
        });
    //}
}

- (void)xmppStream:(XMPPStream *)sender didNotAuthenticate:(NSXMLElement *)error
{
    /*if ([GlacierAppDelegate isTestFlight]) {
        SentryBreadcrumb *crumb = [[SentryBreadcrumb alloc] init];
        crumb.level = kSentryLevelInfo;
        crumb.category = @"xmpp";
        crumb.message = @"didNotAuthenticate";
        // NSLog(@"*****DBG %@", crumb.message);
        [SentrySDK addBreadcrumb:crumb];
    }*/
	//DDLogWarn(@"%@: %@ %@", THIS_FILE, THIS_METHOD, error);
    NSError *err = [GlacierXMPPError errorForXMLElement:error];
    [self failedToConnect:err];
    [self disconnect];
}

- (BOOL)xmppStream:(XMPPStream *)sender didReceiveIQ:(XMPPIQ *)iq
{
	//DDLogVerbose(@"%@: %@ - %@", THIS_FILE, THIS_METHOD, iq);
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
    NSError * error = [GlacierXMPPError errorForXMLElement:xmlError];
    [self failedToRegisterNewAccount:error];
    [self disconnect];
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)xmppMessage
{
    [self sendAcknowledgments];
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
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
            return;
        }
        
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
    if (self.loginStatus == GlacierLoginStatusDisconnecting) {
        [self sendAcknowledgments]; // flush acks before dropping connection
        //[self.xmppStream disconnectAfterSending];
        [self.xmppStream disconnect];
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
        
        XMPPvCardTemp *realvCardTemp = [self.xmppvCardTempModule.xmppvCardTempModuleStorage vCardTempForJID:self.xmppStream.myJID.bareJID xmppStream:self.xmppStream];
        if (realvCardTemp != nil) {
            realvCardTemp.nickname = vCardTemp.nickname;
            [self.xmppvCardTempModule.xmppvCardTempModuleStorage setvCardTemp:realvCardTemp forJID:self.xmppStream.myJID.bareJID xmppStream:self.xmppStream];
            vCardTemp = realvCardTemp;
        }
        
        [self.xmppvCardTempModule updateMyvCardTemp:vCardTemp];
        
        XMPPPresence *presence = [XMPPPresence presence];
        NSXMLElement *xElement = [NSXMLElement elementWithName:@"x" xmlns:@"vcard-temp:x:update"];
        NSXMLElement *displayElement = [NSXMLElement elementWithName:@"displayname" stringValue:self.chatAccount.displayName];
        NSXMLElement *displayOnly = [NSXMLElement elementWithName:@"displayonly" stringValue:@"YES"];
        [xElement addChild:displayElement];
        [xElement addChild:displayOnly];
        [presence addChild:xElement];
        [self.xmppStream sendElement:presence];
        
        [self setRoomNicknames:vCardTemp.nickname];
    }
}

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
        BOOL updateDisplayName = NO;
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
- (void)xmppRosterDidBeginPopulating:(XMPPRoster *)sender withVersion:(NSString *)version {
    [self.teams removeAllObjects];
}

- (void)xmppRoster:(XMPPRoster *)sender didReceiveRosterItem:(NSXMLElement *)item {
    DDLogVerbose(@"%@ %@", THIS_METHOD, item);
    
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
    [self registerPushTokens];
}

- (void)registerPushTokens {
    NSString *token = [GlacierProtocolManager.pushController getPushToken];
    NSString *voiptoken = [GlacierProtocolManager.pushController getVoipToken];
    if (token != nil || voiptoken != nil) {
        XMPPJID *userjid = [XMPPJID jidWithString:self.chatAccount.username resource:self.chatAccount.resource];
        NSString *pushjid = [@"p2." stringByAppendingString:[GlacierInfo defaultHost]];

        // Generate/ensure the push-encryption keypair and register its public key in the same
        // enable IQ so p2 can sealed-box the metadata envelope to this device. Also advertise
        // our OMEMO device id (rid) so p2 keeps the <key rid=…> that's actually usable here.
        NSMutableDictionary *encryptFields = [[PushMetadataEnvelope ensureKeyPairForRegistration] mutableCopy];
        uint32_t rid = self.omemoSignalCoordinator.ownDeviceId;
        if (encryptFields != nil && rid > 0) {
            encryptFields[kGlacierPushOmemoRidField] = [NSString stringWithFormat:@"%u", rid];
        }
        self.xmppPushModule.extraPublishOptions = encryptFields;
        os_log_info(os_log_create("com.glaciersec.push", "Envelope"),
                    "register: push-encrypt kid=%{public}@ rid=%{public}u (registering=%{public}d)",
                    encryptFields[kGlacierPushEncryptKidField], rid, (encryptFields != nil));

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
#pragma mark GlacierProtocol
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
    
    if (message.isSystemUpdate) {
        NSXMLElement *updateElement = [NSXMLElement elementWithName:@"x" xmlns:@"jabber:x:systemupdate"];
        [xmppMessage addChild:updateElement];
    } else {
        [xmppMessage addMarkableChatMarker];
    }
    
    if (self.loginStatus == GlacierLoginStatusAuthenticated) {
        [self.xmppStream sendElement:xmppMessage];
    }
}

- (NSString*) type {
    return kGlacierProtocolTypeXMPP;
}

- (void) connectUserInitiated:(BOOL)userInitiated
{
    NSLog(@"***** connectUserInitiated: %d", userInitiated);
    self.userInitiatedConnection = userInitiated;
    // Don't issue a reconnect if we're already connected and authenticated
    if ([self.xmppStream isConnected] && [self.xmppStream isAuthenticated]) {
        if (self.loginStatus != GlacierLoginStatusAuthenticated) {
            [self xmppStreamDidAuthenticate:self.xmppStream];
        } else {
            [self goOnline];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (([GlacierAppDelegate appDelegate].voipNotification)) {
                [self.messageStorage fetchHistoryForVoip];
            }
        });
        
        return;
    } else if ([self.xmppStream isConnecting] || [self.xmppStream isAuthenticating]) {
        return;
    }
    [self startConnection];
}

-(void)connect
{
    [self connectUserInitiated:NO];
}

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
    
    if (!(self.loginStatus == GlacierLoginStatusAuthenticated)) {
        return;
    }
    
    dispatch_async(self.workQueue, ^{
        if(self.loginStatus == GlacierLoginStatusAuthenticated)
        {
            //[BuddyCache.shared setLastSentChatState:chatState buddy:buddy];
            [self.xmppStream sendElement:xMessage];
        }
    });
}

-(void)sendChatState:(ChatState)chatState withBuddyId:(NSString *)buddyUniqueId
{
    if (!(self.loginStatus == GlacierLoginStatusAuthenticated)) {
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
        
        if(shouldSend && self.loginStatus == GlacierLoginStatusAuthenticated)
        {
            [BuddyCache.shared setLastSentChatState:chatState buddy:buddy];
            [self.xmppStream sendElement:xMessage];
        }
    });
}

//Chat State

-(GlacierXMPPBuddyTimers *)buddyTimersForBuddyObjectID:(NSString *)
managedBuddyObjectID
{
    GlacierXMPPBuddyTimers * timers = [self.buddyTimers objectForKey:managedBuddyObjectID];
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
        GlacierXMPPBuddyTimers * timer = [self.buddyTimers objectForKey:managedBuddyObjectID];
        if(!timer)
        {
            timer = [[GlacierXMPPBuddyTimers alloc] init];
        }
        [timer.pausedChatStateTimer invalidate];
        timer.pausedChatStateTimer = [NSTimer scheduledTimerWithTimeInterval:kChatStatePausedTimeout target:self selector:@selector(sendPausedChatState:) userInfo:managedBuddyObjectID repeats:NO];
        [self.buddyTimers setObject:timer forKey:managedBuddyObjectID];
    });
    
}
-(void)restartInactiveChatStateTimerForBuddyObjectID:(NSString *)managedBuddyObjectID
{
    dispatch_async(dispatch_get_main_queue(), ^{
        GlacierXMPPBuddyTimers * timer = [self.buddyTimers objectForKey:managedBuddyObjectID];
        if(!timer)
        {
            timer = [[GlacierXMPPBuddyTimers alloc] init];
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
    
    if (self.loginStatus == GlacierLoginStatusAuthenticated) {
        XMPPMessage *xMessage = [self getPausedMessage:managedBuddyObjectID];
        if (xMessage && self.loginStatus == GlacierLoginStatusAuthenticated) {
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
    
    if (self.loginStatus == GlacierLoginStatusAuthenticated) {
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

- (GlacierCertificatePinning *)certificatePinningModule
{
    if(!_certificatePinningModule){
        _certificatePinningModule = [[GlacierCertificatePinning alloc] init];
        _certificatePinningModule.delegate = self;
    }
    return _certificatePinningModule;
}

- (void)didEncounterUntrustedCertificate:(SecTrustRef)trust
                             forHostname:(NSString *)hostname
                       systemTrustResult:(SecTrustResultType)systemTrustResult
{
    NSData *certificateData = [GlacierCertificatePinning dataForCertificate:[GlacierCertificatePinning certForTrust:trust]];

    DDLogVerbose(@"Untrusted certificate for %@, trustResult: %d, certLength: %d",
                 hostname, (int)systemTrustResult, (int)certificateData.length);

    [GlacierCertificatePinning addCertificateData:certificateData withHostName:hostname];
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
    if (self.loginStatus == GlacierLoginStatusAuthenticated) {
        [self.xmppStream sendElement:receiptMessage];
    }
}

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
    
    if (self.loginStatus == GlacierLoginStatusAuthenticated) {
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
