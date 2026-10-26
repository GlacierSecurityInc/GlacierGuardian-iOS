//
//  NotificationService.m
//  GlacierNotifications
//
//  Created by Andy Friedman on 9/21/20.
//  Copyright © 2020 Glacier. All rights reserved.
//

#import "NotificationService.h"
#import "GlacierProtocolManager.h"
#import "GlacierConstants.h"
#import "GlacierXMPPStream.h"
#import "GlacierNotifications-Swift.h"
@import XMPPFramework;
@import CocoaLumberjack;
@import SAMKeychain;
#import <stdio.h>
#import <os/log.h>

// Privacy-safe diagnostic log for the push-decrypt path. Visible in Console.app / `log stream`
// filtered by subsystem "com.glaciersec.push". Logs only non-sensitive facts (envelope
// present, alg, kid, booleans, fallback reason) — never JIDs, ciphertext, or plaintext.
static os_log_t GlacierPushLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.glaciersec.push", "Envelope"); });
    return log;
}

@interface NotificationService () <NotificationMessageDelegate, XMPPStreamDelegate>

@property (nonatomic, strong) void (^contentHandler)(UNNotificationContent *contentToDeliver);
@property (nonatomic, strong) UNMutableNotificationContent *bestAttemptContent;
@property (nonatomic, strong, nullable) GlacierXMPPStream *xmppStream;
@property (nonatomic, strong, nullable) OMEMOModule *omemoModule;
//@property (nonatomic, strong, nullable) XMPPMessageArchiveManagement *archiving;
@property (nonatomic, strong, nullable) NotificationOMEMOSignalCoordinator *omemoSignalCoordinator;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong, nullable) ChatAccountModel *acct;
@property (nonatomic, assign) BOOL msgDecrypted;
@property (nonatomic, strong) NSTimer *failTimer;
@property (nonatomic, assign) BOOL databaseReady;
@property (nonatomic, assign) BOOL attemptingPushPath; // OMEMO-over-push: decrypting from the payload

@end

@implementation NotificationService

- (instancetype)init
{
    if (self = [super init])
    {
        self.databaseReady = [self keychainIsAccessible];
        if (self.databaseReady) {
            [DBManager sharedDB];
        } else {
            DDLogWarn(@"Protected data unavailable in notification extension. Skipping database initialization.");
        }
    }
    return self;
}

- (BOOL)keychainIsAccessible
{
    NSError *error = nil;
    NSData *value = [SAMKeychain passwordDataForService:kGlacierKeySpec
                                                account:GlacierGRDBPassphraseAccountName
                                            accessGroup:kGlacierKeyGroup
                                                  error:&error];

    if (value != nil) {
        return YES;
    }

    // If it's nil, Keychain read failed. In a Notification Service Extension this is normal sometimes.
    // Treat as "not accessible" and fall back.
    if (error) {
        // Optional: only log in debug builds; don’t spam production logs
        // NSLog(@"Keychain unavailable: %@ (%ld)", error.domain, (long)error.code);
    }

    return NO;
}

- (void)dealloc
{
    [self teardownStream];
}

- (void)teardownStream
{
    if (self.failTimer) [self.failTimer invalidate];
    self.failTimer = nil;
    [_xmppStream disconnectAfterSending];
    [_xmppStream removeDelegate:self];
    [_omemoModule removeDelegate:self.omemoSignalCoordinator];
    [_omemoModule deactivate];
    
    _workQueue = nil;
    _omemoSignalCoordinator = nil;
    _omemoModule = nil;
    [_xmppStream predealloc];
    _xmppStream = nil;
}

- (void)didReceiveNotificationRequest:(UNNotificationRequest *)request withContentHandler:(void (^)(UNNotificationContent * _Nonnull))contentHandler {
    self.contentHandler = contentHandler;
    self.bestAttemptContent = [request.content mutableCopy];
    
    if (!self.databaseReady && [self keychainIsAccessible]) {
        self.databaseReady = YES;
        [DBManager sharedDB];
    }

    if (!self.databaseReady) {
        //NSLog(@"*****DBG NotificationService returning bestAttempt (database not ready)");
        self.contentHandler(self.bestAttemptContent);
        return;
    }
    
    NSDictionary *userInfo = request.content.userInfo;
    //NSLog(@"NotificationService didReceiveNotificationRequest with userInfo: %@", userInfo);
    NSString *smsType = userInfo[kNotificationTwilioType];
    if (smsType) {
        [self handleSMSContent];
        return;
    }

    if ([self shouldSkipXMPPConnectWhenAppActive]) {
        //NSLog(@"*****DBG NotificationService returning bestAttempt (app active)");
        self.contentHandler(self.bestAttemptContent);
        return;
    }

    // OMEMO-over-push: the message rides inside a sealed-box "ge" envelope. Open it locally
    // and skip the MAM round-trip. If the envelope is absent, wrong alg, or missing fields
    // (plaintext, feature off, or p2's size guard dropped the bundle), fall through to MAM.
    // Some push providers stringify nested custom objects, so accept either a dict or a JSON
    // string for "ge".
    NSDictionary *envelope = [self envelopeDictFromUserInfo:userInfo];
    if ([envelope isKindOfClass:[NSDictionary class]]) {
        NSString *alg = envelope[kGlacierPushEnvelopeAlgKey];
        NSString *kid = envelope[kGlacierPushEnvelopeKidKey];
        NSString *data = envelope[kGlacierPushEnvelopeDataKey];
        if ([alg isEqualToString:kGlacierPushSealedBoxAlg] && kid.length > 0 && data.length > 0) {
            os_log_info(GlacierPushLog(), "push: sealed envelope present alg=%{public}@ kid=%{public}@ dataLen=%lu",
                        alg, kid, (unsigned long)data.length);
            [self handleSealedEnvelopeWithKid:kid data:data];
            return;
        }
        os_log_info(GlacierPushLog(), "push: envelope present but unusable (alg=%{public}@ kidLen=%lu dataLen=%lu) -> MAM",
                    alg, (unsigned long)kid.length, (unsigned long)data.length);
    } else {
        // Diagnostic: dump the payload structure (KEYS ONLY, never values) so we can tell
        // whether the server omitted "ge", nested it, or sent a different shape.
        id rawGe = userInfo[kGlacierPushEnvelopeKey];
        NSDictionary *aps = [userInfo[@"aps"] isKindOfClass:[NSDictionary class]] ? userInfo[@"aps"] : nil;
        os_log_info(GlacierPushLog(),
                    "push: no sealed envelope -> MAM; topKeys=[%{public}@] apsKeys=[%{public}@] geClass=%{public}@",
                    [userInfo.allKeys componentsJoinedByString:@", "],
                    [aps.allKeys componentsJoinedByString:@", "],
                    rawGe ? NSStringFromClass([rawGe class]) : @"(absent)");
    }

    [self loginAndOpenStream];
}

// Accepts the "ge" envelope as either a dictionary or a JSON-encoded string (some push
// providers stringify nested custom objects). Returns nil if neither yields a dictionary.
- (NSDictionary *)envelopeDictFromUserInfo:(NSDictionary *)userInfo {
    id ge = userInfo[kGlacierPushEnvelopeKey];
    if ([ge isKindOfClass:[NSDictionary class]]) {
        return ge;
    }
    if ([ge isKindOfClass:[NSString class]]) {
        NSData *jsonData = [(NSString *)ge dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            return parsed;
        }
    }
    return nil;
}

// OMEMO-over-push: open the sealed-box envelope and decrypt locally (no network). On an
// unknown key, tampered/malformed envelope, hang, or decryption failure we fall back to the
// MAM path so nothing regresses.
- (void) handleSealedEnvelopeWithKid:(NSString *)kid data:(NSString *)base64Data {
    if (![self setupStreamAndCoordinator]) {
        os_log_info(GlacierPushLog(), "push: no XMPP account -> bestAttempt");
        self.contentHandler(self.bestAttemptContent);
        return;
    }

    self.msgDecrypted = NO;
    self.attemptingPushPath = YES;

    // Watchdog: the NSE has only a few seconds. Sealed-box open + OMEMO decrypt are local and
    // near-instant; if anything hangs, fall back to MAM while there's still time budget.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.failTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(pushPathTimedOut:) userInfo:nil repeats:NO];
    });

    dispatch_async(self.workQueue, ^{
        BOOL attempted = [self.omemoSignalCoordinator openSealedPushEnvelopeWithKid:kid base64Data:base64Data];
        os_log_info(GlacierPushLog(), "push: envelope open+decrypt attempted=%{public}d", attempted);
        if (!attempted) {
            // Unknown key / tampered / malformed — the delegate was never called. Fall back to MAM.
            [self fallBackToMAMFromPush];
        }
    });
}

- (void) pushPathTimedOut:(id)sender {
    os_log_info(GlacierPushLog(), "push: watchdog fired (decrypt not done in time)");
    [self fallBackToMAMFromPush];
}

// Funnel all push->MAM fallbacks through the main thread so the timer/flag stay consistent.
- (void) fallBackToMAMFromPush {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self fallBackToMAMFromPush]; });
        return;
    }
    if (!self.attemptingPushPath) { return; } // already resolved
    self.attemptingPushPath = NO;
    if (self.failTimer) { [self.failTimer invalidate]; self.failTimer = nil; }
    if (self.msgDecrypted) { return; }
    os_log_info(GlacierPushLog(), "push: falling back to MAM");
    [self loginAndOpenStream];
}

- (void) handleSMSContent {
    //NSLog(@"*****DBG NotificationService handleSMSContent returning bestAttempt");
    NSDictionary *userInfo = self.bestAttemptContent.userInfo;
    
    NSString *convSidKey = @"conversation_sid";
    NSString *convSid = userInfo[convSidKey];
    
    SMSChatConversationModel *conv = nil;
    if (convSid && self.databaseReady) {
        conv = [SMSChatConversationModel existingConversationWith:convSid];
    }
    
    if (conv) {
        NSDictionary *guserInfo = @{kGlacierNotificationThreadKey:conv.uniqueId,
                                   kGlacierNotificationThreadCollection:[SMSChatConversationModel collection],
                                   kGlacierNotificationType:kNotificationTwilioType};
        
        NSMutableDictionary *newInfo = [NSMutableDictionary dictionaryWithDictionary:userInfo];
        [newInfo addEntriesFromDictionary:guserInfo];
        self.bestAttemptContent.userInfo = newInfo;
        NSString *localNum = [conv getLocalAcct];
        
        NSString *msgAuthKey = @"author";
        NSString *msgAuth = userInfo[msgAuthKey];
        NSString *twilioIssue = @"${PARTICIPANT}";
        NSString *SMS = @"SMS";
        if (msgAuth && [conv getPreferredName]) {
            NSString *newbody = [self.bestAttemptContent.body stringByReplacingOccurrencesOfString:msgAuth withString:[conv getPreferredName]];
            if ([self.bestAttemptContent.body containsString:twilioIssue]) {
                newbody = [self.bestAttemptContent.body stringByReplacingOccurrencesOfString:twilioIssue withString:[conv getPreferredName]];
            }
            if (localNum) {
                NSString *smsTo = [@"SMS to " stringByAppendingString:localNum];
                newbody = [newbody stringByReplacingOccurrencesOfString:SMS withString:smsTo];
            }
            self.bestAttemptContent.body = newbody;
        } else if (msgAuth && [self.bestAttemptContent.body containsString:twilioIssue]) {
            NSString *newbody = [self.bestAttemptContent.body stringByReplacingOccurrencesOfString:twilioIssue withString:msgAuth];
            if (localNum) {
                NSString *smsTo = [@"SMS to " stringByAppendingString:localNum];
                newbody = [newbody stringByReplacingOccurrencesOfString:SMS withString:smsTo];
            }
            self.bestAttemptContent.body = newbody;
        }
    } else {
        //NSLog(@"NotificationService handleSMSContent auth no found conversation %@", userInfo);
        NSString *twilioIssue = @"${PARTICIPANT}";
        NSString *msgAuthKey = @"author";
        NSString *msgAuth = userInfo[msgAuthKey];
        if (msgAuth && [self.bestAttemptContent.body containsString:twilioIssue]) {
            NSString *newbody = [self.bestAttemptContent.body stringByReplacingOccurrencesOfString:twilioIssue withString:msgAuth];
            self.bestAttemptContent.body = newbody;
        }
    }
    
    self.contentHandler(self.bestAttemptContent);
}

// Builds the XMPP stream + OMEMO module/coordinator without connecting. Returns NO if there
// is no XMPP account. Idempotent: safe to call from both the push path and the MAM path
// (the push path uses the configured myJID for local decryption without ever connecting).
- (BOOL) setupStreamAndCoordinator {
    if (self.xmppStream) {
        return YES; // already configured
    }

    NSArray<ChatAccountModel*> *accounts = [ChatAccountModel allXMPPAccounts];
    if (accounts) {
        self.acct = accounts.firstObject;
    }

    if (!self.acct) {
        return NO;
    }

    NSString * queueLabel = [NSString stringWithFormat:@"%@.work.%@",[self class],self];
    _workQueue = dispatch_queue_create([queueLabel UTF8String], 0);

    _xmppStream = [[GlacierXMPPStream alloc] init];

    //Used to fetch correct account from XMPPStream in delegate methods especailly
    self.xmppStream.tag = self.acct.uniqueId;
    self.xmppStream.startTLSPolicy = XMPPStreamStartTLSPolicyRequired;
    [self.xmppStream addDelegate:self delegateQueue:self.workQueue];

    XMPPJID *jid = [XMPPJID jidWithString:self.acct.username resource:self.acct.resource];
    self.xmppStream.myJID = jid;

    NSString * domainString = self.acct.domain;
    if ([domainString length]) {
        [self.xmppStream setHostName:domainString];
    }
    [self.xmppStream setHostPort:self.acct.port];

    if (!self.omemoSignalCoordinator) {
        self.omemoSignalCoordinator = [[NotificationOMEMOSignalCoordinator alloc] initWithAccountKey:self.acct.uniqueId notificationDelegate:self error:nil];
        self.omemoModule = [[OMEMOModule alloc] initWithOMEMOStorage:self.omemoSignalCoordinator xmlNamespace:OMEMOModuleNamespaceConversationsLegacy];
        [self.omemoModule addDelegate:self.omemoSignalCoordinator delegateQueue:self.workQueue];
        //[self.omemoModule setIsExtension];
        [self.omemoModule activate:self.xmppStream];
    }

    return YES;
}

- (void) loginAndOpenStream {
    if (![self setupStreamAndCoordinator]) {
        //NSLog(@"*****DBG NotificationService returning bestAttempt (no account)");
        self.contentHandler(self.bestAttemptContent);
        return;
    }

    NSError *error = nil;
    if (![self.xmppStream connectWithTimeout:(NSTimeInterval)6 error:&error])
    {
        NSLog(@"Error connecting: %@", error);
        NotificationMessage *msg = [[NotificationMessage alloc] init];
        [self failedToDecryptMessage:msg];
    }
}

- (BOOL)shouldSkipXMPPConnectWhenAppActive
{
    NSUserDefaults *glacierDefaults = [[NSUserDefaults alloc] initWithSuiteName:kGlacierGroup];
    if (!glacierDefaults) {
        return NO;
    }
    return [glacierDefaults boolForKey:kGlacierAppIsActiveKey];
}

#pragma - mark XMPPStreamDelegate Methods
- (void)xmppStreamDidConnect:(XMPPStream *)sender
{
    NSError *error = nil;
    [self.xmppStream authenticateWithPassword:self.acct.password error:&error];
}

- (void)xmppStreamDidAuthenticate:(XMPPStream *)sender {
    //NSLog(@"NotificationService authenticated requesting archive");
    [self requestMostRecentArchive]; //requestArchive];
}

/*- (void) requestArchive{
    NSDate *dateToFetch = [[NSDate date] dateByAddingTimeInterval:-15]; //15 seconds
    NSXMLElement *startElement = [XMPPMessageArchiveManagement fieldWithVar:@"start" type:nil andValue:dateToFetch.xmppDateTimeString];
    NSArray *fields  = @[startElement];
    
    NSXMLElement *formElement = [NSXMLElement elementWithName:@"x" xmlns:@"jabber:x:data"];
    [formElement addAttributeWithName:@"type" stringValue:@"submit"];
    [formElement addChild:[XMPPMessageArchiveManagement fieldWithVar:@"FORM_TYPE" type:@"hidden" andValue:XMLNS_XMPP_MAM]];
    
    for (NSXMLElement *field in fields) {
        [formElement addChild:field];
    }
    
    XMPPIQ *iq = [XMPPIQ iqWithType:@"set"];
    [iq addAttributeWithName:@"id" stringValue:[XMPPStream generateUUID]];
    [iq addAttributeWithName:@"to" stringValue:self.xmppStream.myJID.bareJID.full];

    NSString *queryId = [XMPPStream generateUUID];
    NSXMLElement *queryElement = [NSXMLElement elementWithName:@"query" xmlns:XMLNS_XMPP_MAM];
    [queryElement addAttributeWithName:@"queryid" stringValue:queryId];
    [iq addChild:queryElement];

    [queryElement addChild:formElement];
    [queryElement addChild:[NSXMLElement elementWithName:@"flip-page"]];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.failTimer = [NSTimer scheduledTimerWithTimeInterval:1.2 target:self selector:@selector(handleFailureGracefully:) userInfo:nil repeats:NO];
    });
    
    self.msgDecrypted = NO;
    //[self.omemoModule resetAwaitingNotification];
    //omemoModule setWaiting
    //but what if it isn't encrypted like a group invite?
    [self.xmppStream sendElement:iq];
}*/

/**
 <iq type='set' id='mam1' to='yourdomain.com'>
   <query xmlns='urn:xmpp:mam:2' queryid='recent-mam'>
     <x xmlns='jabber:x:data' type='submit'>
       <field var='FORM_TYPE'><value>urn:xmpp:mam:2</value></field>
       <field var='with'><value>sender@domain/resource</value></field> <!-- optional -->
     </x>
     <set xmlns='http://jabber.org/protocol/rsm'>
       <max>1</max>
       <before/>
     </set>
   </query>
 </iq>
 */
- (void) requestMostRecentArchive{
    //NSDate *dateToFetch = [[NSDate date] dateByAddingTimeInterval:-15]; //15 seconds
    //NSXMLElement *startElement = [XMPPMessageArchiveManagement fieldWithVar:@"start" type:nil andValue:dateToFetch.xmppDateTimeString];
    //NSArray *fields  = @[startElement];
    
    NSXMLElement *formElement = [NSXMLElement elementWithName:@"x" xmlns:@"jabber:x:data"];
    [formElement addAttributeWithName:@"type" stringValue:@"submit"];
    [formElement addChild:[XMPPMessageArchiveManagement fieldWithVar:@"FORM_TYPE" type:@"hidden" andValue:XMLNS_XMPP_MAM]];
    
    //for (NSXMLElement *field in fields) {
        //[formElement addChild:field];
    //}
    
    NSXMLElement *setElement = [NSXMLElement elementWithName:@"set" xmlns:@"http://jabber.org/protocol/rsm"];
    NSXMLElement *maxElement = [NSXMLElement elementWithName:@"max" stringValue:@"1"];
    NSXMLElement *beforeElement = [NSXMLElement elementWithName:@"before"];
    [setElement addChild:maxElement];
    [setElement addChild:beforeElement];
    
    XMPPIQ *iq = [XMPPIQ iqWithType:@"set"];
    [iq addAttributeWithName:@"id" stringValue:[XMPPStream generateUUID]];
    [iq addAttributeWithName:@"to" stringValue:self.xmppStream.myJID.bareJID.full];

    NSString *queryId = [XMPPStream generateUUID];
    NSXMLElement *queryElement = [NSXMLElement elementWithName:@"query" xmlns:XMLNS_XMPP_MAM];
    [queryElement addAttributeWithName:@"queryid" stringValue:queryId];
    [iq addChild:queryElement];

    [queryElement addChild:formElement];
    [queryElement addChild:setElement];
    //[queryElement addChild:[NSXMLElement elementWithName:@"flip-page"]];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.failTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(handleFailureGracefully:) userInfo:nil repeats:NO];
    });
    
    self.msgDecrypted = NO;
    //[self.omemoModule resetAwaitingNotification];
    //omemoModule setWaiting
    //but what if it isn't encrypted like a group invite?
    [self.xmppStream sendElement:iq];
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)xmppMessage
{
    XMPPJID *myJID = sender.myJID;
    if (!myJID) { return; }
    NSXMLElement *mamResult = xmppMessage.mamResult;
    if (!mamResult) { return; }
    XMPPMessage *mam = mamResult.forwardedMessage;
    BOOL isIncoming = [mam.to isEqualToJID:myJID options:XMPPJIDCompareBare];
    XMPPJID *forJID = nil;
    if (isIncoming) {
        forJID = mam.from;
    } else {
        forJID = mam.to;
    }
    
    if (!forJID) {
        return;
    }
    
    NSXMLElement *offlinemsg = [mam omemo_offlineElement];
    if (offlinemsg) {
        XMPPMessage *offmsg = [XMPPMessage messageFromElement:offlinemsg];
        NSXMLElement *omemo = [offmsg omemo_encryptedElement:OMEMOModuleNamespaceConversationsLegacy];
        if (!omemo)
        {
            [self.omemoSignalCoordinator processUnencryptedData:isIncoming message:offmsg forJID:forJID];
        }
    } else {
        NSXMLElement *x1 = [mam elementForName:@"x" xmlns:XMPPMUCUserNamespace];
        if (!x1) {
            return;
        }
        
        NSXMLElement * invite = [x1 elementForName:@"invite"];
        if (!invite) {
            return;
        }
        
        NSXMLElement *x2 = [mam elementForName:@"x" xmlns:XMPPConferenceXmlns];
        if (!x2) {
            return;
        }
        
        NSString *groupjid = [x2 attributeStringValueForName:@"jid"];
        if (groupjid != nil) {
            NSString *groupname = [[groupjid componentsSeparatedByString:@"@"] firstObject];
            NSString *invitemsg = [@"Added to group: " stringByAppendingString:groupname];
            
            self.bestAttemptContent.title = invitemsg;
            //NSLog(@"*****DBG NotificationService returning bestAttempt (group invite)");
            self.contentHandler(self.bestAttemptContent);
        }
    }
}

- (void)xmppStream:(XMPPStream *)sender didReceiveError:(id)error
{
    NSLog(@"NotificationService Stream Error: %@", error);
}


#pragma - mark NotificationMessageDelegate method

// If the notification title is a full JID (e.g. group@domain or user@domain/resource),
// show only the user part (before the @). This lets older clients render a sensible
// title once the servers start delivering full JIDs for MUC/group messages.
- (NSString *)displayTitleForString:(NSString *)title {
    if (title == nil) { return title; }
    NSRange atRange = [title rangeOfString:@"@"];
    if (atRange.location == NSNotFound) { return title; }
    return [title substringToIndex:atRange.location];
}

- (void)decryptedMessage:(NotificationMessage *)message {
    //NSLog(@"NotificationService decryptedMessage %@", message);
    if (self.msgDecrypted) {return;}
    self.msgDecrypted = YES;
    // Log only whether this came from the push path and whether we have a thread id — no body/JIDs.
    os_log_info(GlacierPushLog(), "push: decrypted+displayed (viaPush=%{public}d hasThread=%{public}d)",
                self.attemptingPushPath, (message.threadId != nil));
    self.attemptingPushPath = NO; // push path succeeded; cancel any MAM fallback

    if (self.failTimer) [self.failTimer invalidate];
    self.failTimer = nil;
    
    if (message.threadId) {
        NSDictionary *userInfo = @{kGlacierNotificationThreadKey:message.threadId,
                                   kGlacierNotificationThreadCollection:message.threadCollection,
                                   kGlacierNotificationType:kGlacierNotificationTypeChatMessage};
        self.bestAttemptContent.userInfo = userInfo;
    }
    
    if (message.from != nil) {
        self.bestAttemptContent.title = [self displayTitleForString:message.from];
        self.bestAttemptContent.body = message.message;
    } else {
        self.bestAttemptContent.title = message.message;
    }
    
    self.contentHandler(self.bestAttemptContent);
}

// Nothing to add (e.g. a reaction that was cleared). Resolve the push path by delivering the
// server's original push content unchanged — do NOT fall back to MAM (nothing there for us).
// This does not hide the notification: an alert push always shows; we just don't modify it.
- (void)deliverOriginalContent {
    if (self.msgDecrypted) {return;}
    self.msgDecrypted = YES;
    self.attemptingPushPath = NO;
    if (self.failTimer) { [self.failTimer invalidate]; self.failTimer = nil; }
    os_log_info(GlacierPushLog(), "push: reaction has nothing to add -> deliver original content");
    self.contentHandler(self.bestAttemptContent);
}

- (void)failedToDecryptMessage:(NotificationMessage *)message {
    if (self.msgDecrypted) {return;}

    // If the push-supplied decrypt failed, fall back to the MAM path rather than surfacing a
    // failure — don't regress the case where the payload was present but undecryptable here.
    if (self.attemptingPushPath) {
        [self fallBackToMAMFromPush];
        return;
    }

    NSLog(@"NotificationService failedToDecryptMessage");

    if (message.threadId) {
        NSDictionary *userInfo = @{kGlacierNotificationThreadKey:message.threadId,
                                   kGlacierNotificationThreadCollection:message.threadCollection,
                                   kGlacierNotificationType:kGlacierNotificationTypeChatMessage};
        self.bestAttemptContent.userInfo = userInfo;
    }
    
    if (message != nil && message.from != nil) {
        self.bestAttemptContent.title = [self displayTitleForString:message.from];
    }
    
    /*dispatch_async(dispatch_get_main_queue(), ^{
        self.failTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(handleFailureGracefully:) userInfo:nil repeats:NO];
    });*/
}

- (void) handleFailureGracefully:(id)sender {
    if (!self.msgDecrypted) {
        self.bestAttemptContent.body = @"New message";
        // NSLog(@"*****DBG NotificationService returning bestAttempt (failure timeout)");
        self.contentHandler(self.bestAttemptContent);
    }
}

- (void)serviceExtensionTimeWillExpire {
    NSLog(@"NotificationService serviceExtensionTimeWillExpire %@", self.bestAttemptContent.body);
    // Called just before the extension will be terminated by the system.
    // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
    // NSLog(@"*****DBG NotificationService returning bestAttempt (time will expire)");
    self.contentHandler(self.bestAttemptContent);
}

@end
