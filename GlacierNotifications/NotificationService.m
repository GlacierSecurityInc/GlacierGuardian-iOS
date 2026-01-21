//
//  NotificationService.m
//  GlacierNotifications
//
//  Created by Andy Friedman on 9/21/20.
//  Copyright © 2020 Glacier. All rights reserved.
//

#import "NotificationService.h"
#import "OTRProtocolManager.h"
#import "OTRConstants.h"
#import "OTRXMPPStream.h"
#import "GlacierNotifications-Swift.h"
@import XMPPFramework;
@import CocoaLumberjack;
@import SAMKeychain;

@interface NotificationService () <NotificationMessageDelegate, XMPPStreamDelegate>

@property (nonatomic, strong) void (^contentHandler)(UNNotificationContent *contentToDeliver);
@property (nonatomic, strong) UNMutableNotificationContent *bestAttemptContent;
@property (nonatomic, strong, nullable) OTRXMPPStream *xmppStream;
@property (nonatomic, strong, nullable) OMEMOModule *omemoModule;
//@property (nonatomic, strong, nullable) XMPPMessageArchiveManagement *archiving;
@property (nonatomic, strong, nullable) NotificationOMEMOSignalCoordinator *omemoSignalCoordinator;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong, nullable) ChatAccountModel *acct;
@property (nonatomic, assign) BOOL msgDecrypted;
@property (nonatomic, strong) NSTimer *failTimer; //IOSM#23, IOSM#24
@property (nonatomic, assign) BOOL databaseReady;

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
    if (self.failTimer) [self.failTimer invalidate]; //IOSM#23, IOSM#24
    self.failTimer = nil;
    [_xmppStream disconnect];
    [_xmppStream removeDelegate:self];
    [_omemoModule removeDelegate:self.omemoSignalCoordinator];
    [_omemoModule deactivate];
    
    _workQueue = nil; //IOSM#70
    _omemoSignalCoordinator = nil;
    _omemoModule = nil;
    [_xmppStream predealloc]; //IOSM#23, IOSM#24
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
        self.contentHandler(self.bestAttemptContent);
        return;
    }
    
    NSDictionary *userInfo = request.content.userInfo;
    //NSLog(@"NotificationService didReceiveNotificationRequest with userInfo: %@", userInfo);
    NSString *smsType = userInfo[kNotificationTwilioType];
    if (smsType) {
        //IOSM#103
        [self handleSMSContent];
        return;
    }

    if ([self shouldSkipXMPPConnectWhenAppActive]) {
        self.contentHandler(self.bestAttemptContent);
        return;
    }
    
    [self loginAndOpenStream];
}

- (void) handleSMSContent {
    NSDictionary *userInfo = self.bestAttemptContent.userInfo;
    
    NSString *convSidKey = @"conversation_sid";
    NSString *convSid = userInfo[convSidKey];
    
    SMSChatConversationModel *conv = nil;
    if (convSid && self.databaseReady) {
        conv = [SMSChatConversationModel existingConversationWith:convSid];
    }
    
    if (conv) {
        NSDictionary *guserInfo = @{kOTRNotificationThreadKey:conv.uniqueId,
                                   kOTRNotificationThreadCollection:[SMSChatConversationModel collection],
                                   kOTRNotificationType:kNotificationTwilioType};
        
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

- (void) loginAndOpenStream {
    NSArray<ChatAccountModel*> *accounts = [ChatAccountModel allXMPPAccounts];
    if (accounts) {
        self.acct = accounts.firstObject;
    }
    
    if (self.acct) {
        NSString * queueLabel = [NSString stringWithFormat:@"%@.work.%@",[self class],self];
        _workQueue = dispatch_queue_create([queueLabel UTF8String], 0);
        
        _xmppStream = [[OTRXMPPStream alloc] init];

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
        
        NSError *error = nil;
        if (![self.xmppStream connectWithTimeout:(NSTimeInterval)6 error:&error])
        {
            NSLog(@"Error connecting: %@", error);
            NotificationMessage *msg = [[NotificationMessage alloc] init];
            [self failedToDecryptMessage:msg];
        }
    } else {
        self.contentHandler(self.bestAttemptContent);
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
        self.failTimer = [NSTimer scheduledTimerWithTimeInterval:1.2 target:self selector:@selector(handleFailureGracefully:) userInfo:nil repeats:NO]; //IOSM#70
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
        self.failTimer = [NSTimer scheduledTimerWithTimeInterval:1.2 target:self selector:@selector(handleFailureGracefully:) userInfo:nil repeats:NO]; //IOSM#70
    });
    
    self.msgDecrypted = NO;
    //[self.omemoModule resetAwaitingNotification];
    //omemoModule setWaiting
    //but what if it isn't encrypted like a group invite?
    [self.xmppStream sendElement:iq];
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)xmppMessage
{
    //IOSM-483
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
    } else { //IOSM-544 check for invite
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
            self.contentHandler(self.bestAttemptContent);
        }
    }
}

- (void)xmppStream:(XMPPStream *)sender didReceiveError:(id)error
{
    NSLog(@"NotificationService Stream Error: %@", error);
}


#pragma - mark NotificationMessageDelegate method
- (void)decryptedMessage:(NotificationMessage *)message {
    //NSLog(@"NotificationService decryptedMessage %@", message);
    if (self.msgDecrypted) {return;}
    self.msgDecrypted = YES;
    
    if (self.failTimer) [self.failTimer invalidate]; //IOSM#70
    self.failTimer = nil;
    
    if (message.threadId) { //IOSM#16
        NSDictionary *userInfo = @{kOTRNotificationThreadKey:message.threadId,
                                   kOTRNotificationThreadCollection:message.threadCollection,
                                   kOTRNotificationType:kOTRNotificationTypeChatMessage};
        self.bestAttemptContent.userInfo = userInfo;
    }
    
    if (message.from != nil) {
        self.bestAttemptContent.title = message.from;
        self.bestAttemptContent.body = message.message;
    } else {
        self.bestAttemptContent.title = message.message;
    }
    
    self.contentHandler(self.bestAttemptContent);
}

- (void)failedToDecryptMessage:(NotificationMessage *)message {
    if (self.msgDecrypted) {return;}
    NSLog(@"NotificationService failedToDecryptMessage");
    
    if (message.threadId) { //IOSM#16
        NSDictionary *userInfo = @{kOTRNotificationThreadKey:message.threadId,
                                   kOTRNotificationThreadCollection:message.threadCollection,
                                   kOTRNotificationType:kOTRNotificationTypeChatMessage};
        self.bestAttemptContent.userInfo = userInfo;
    }
    
    if (message != nil && message.from != nil) {
        self.bestAttemptContent.title = message.from;
    }
    
    /*dispatch_async(dispatch_get_main_queue(), ^{
        self.failTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(handleFailureGracefully:) userInfo:nil repeats:NO]; //IOSM#23, IOSM#24
    });*/
}

- (void) handleFailureGracefully:(id)sender {
    if (!self.msgDecrypted) {
        self.bestAttemptContent.body = @"New message";
        self.contentHandler(self.bestAttemptContent);
    }
}

- (void)serviceExtensionTimeWillExpire {
    NSLog(@"NotificationService serviceExtensionTimeWillExpire %@", self.bestAttemptContent.body);
    // Called just before the extension will be terminated by the system.
    // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
    self.contentHandler(self.bestAttemptContent);
}

@end
