//
//  GlacierShareDataInterface.m
//  GlacierShare
//
//  Created by Andy Friedman on 12/15/20.
//  Copyright © 2020 Glacier. All rights reserved.
//

#import "GlacierShareDataInterface.h"
#import "OTRXMPPStream.h"
#import "GlacierShare-Swift.h"
@import XMPPFramework;

@interface GlacierShareDataInterface () <XMPPStreamDelegate, ShareMessageDelegate>

@property (nonatomic, strong, nullable) OTRXMPPStream *xmppStream;
@property (nonatomic, strong, nullable) OMEMOModule *omemoModule;
@property (nonatomic, strong, nullable) ShareOMEMOSignalCoordinator *omemoSignalCoordinator;
@property (nonatomic, strong) dispatch_queue_t workQueue;
//@property (nonatomic, strong, nullable) ChatAccountModel *acct;
@property (assign, nonatomic) BOOL readyToShare;
@property (nonatomic, weak, readonly) id<ShareExtensionDelegate> shareDelegate;
@property (nonatomic, strong, nullable) ShareMediaManager *shareMediaManager;

@end

@implementation GlacierShareDataInterface

- (instancetype)initWithDelegate:(id<ShareExtensionDelegate>)delegate
{
    if (self = [super init]) {
        //setup DB
        _shareDelegate = delegate;
    
        [self loginAndOpenStream];
    }
    
    return self;
}

- (void) setupMediaManager {
    //if (self.acct && self.xmppStream) {
        // File Transfer
        //NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        
        /*__block NSString *uploaddomain = [GlacierInfo defaultHost];
        
        [self.connections.read readWithBlock:^(YapDatabaseReadTransaction * _Nonnull transaction) {
            OTRXMPPAccount *xaccount = [OTRXMPPAccount accountForStream:self.xmppStream];
            uploaddomain = xaccount.domain;
        }];
        
        self.shareMediaManager = [[ShareMediaManager alloc] initWithConnection:self.connections.write sessionConfiguration:sessionConfiguration delegate:self xmppStream:self.xmppStream uploadDomain:uploaddomain];*/
    //}
}

- (void)dealloc
{
    //[_xmppStream disconnect];
    //[self teardownStream];
}

- (void)teardownStream
{
    if (_xmppStream) {
        [_xmppStream disconnect];
        [_xmppStream removeDelegate:self];
    }
    
    if (_omemoModule) {
        [_omemoModule removeDelegate:self.omemoSignalCoordinator];
        [_omemoModule deactivate];
    }
    
    if (self.shareMediaManager) {
        [self.shareMediaManager removeDelegates];
        [self.shareMediaManager teardownConnections];
        self.shareMediaManager = nil;
        
        //force wal write?
    }
    
    //[[DatabaseManager sharedInstance] teardownConnections];
    
    _omemoSignalCoordinator = nil;
    _omemoModule = nil;
    _xmppStream = nil;
    //_connections = nil;
}

- (NSArray<Conversation*>*) getAllConversations {
    NSMutableArray <Conversation *>*convArray = [[NSMutableArray alloc] init];
    
    return convArray;
}

- (void) loginAndOpenStream {
    
    //if (self.acct) {
        NSString * queueLabel = [NSString stringWithFormat:@"%@.work.%@",[self class],self];
        _workQueue = dispatch_queue_create([queueLabel UTF8String], 0);
        
        _xmppStream = [[OTRXMPPStream alloc] init];

        //Used to fetch correct account from XMPPStream in delegate methods especailly
        //self.xmppStream.tag = self.acct.uniqueId;
        self.xmppStream.startTLSPolicy = XMPPStreamStartTLSPolicyRequired;
        [self.xmppStream addDelegate:self delegateQueue:self.workQueue];
        
        /*
        OTRXMPPAccount *xacct = (OTRXMPPAccount *)self.acct;
        XMPPJID *jid = [XMPPJID jidWithString:self.acct.username resource:xacct.resource];
        self.xmppStream.myJID = jid;
        
        NSString * domainString = xacct.domain;
        if ([domainString length]) {
            [self.xmppStream setHostName:domainString];
        }
        [self.xmppStream setHostPort:xacct.port];
        
        if (!self.omemoSignalCoordinator) {
            self.omemoSignalCoordinator = [[ShareOMEMOSignalCoordinator alloc] initWithAccountYapKey:self.acct.uniqueId error:nil];
            self.omemoModule = [[OMEMOModule alloc] initWithOMEMOStorage:self.omemoSignalCoordinator xmlNamespace:OMEMOModuleNamespaceConversationsLegacy];
            [self.omemoModule addDelegate:self.omemoSignalCoordinator delegateQueue:self.workQueue];
            [self.omemoModule activate:self.xmppStream];
        }
        
        NSError *error = nil;
        if (![self.xmppStream connectWithTimeout:(NSTimeInterval)6 error:&error])
        {
            NSLog(@"Error connecting: %@", error);
        }*/
    //}
}

/*- (void) sendMessage:(OTROutgoingMessage*)message
{
    NSParameterAssert(message);
    NSString *text = message.text;
    if (!text.length) {
        return;
    }
    
    OTRXMPPBuddy *buddy = (OTRXMPPBuddy *)[message threadOwner];
    if (!buddy || ![buddy isKindOfClass:[OTRXMPPBuddy class]]) {
        return;
    }
    
    NSString * messageID = message.messageId;
    XMPPMessage * xmppMessage = [XMPPMessage messageWithType:@"chat" to:buddy.bareJID elementID:messageID];
    [xmppMessage addBody:text];
    
    //[xmppMessage addActiveChatState];
    
    [xmppMessage addMarkableChatMarker];
    
    [self.xmppStream sendElement:xmppMessage];
}*/

#pragma - mark XMPPStreamDelegate Methods
- (void)xmppStreamDidConnect:(XMPPStream *)sender
{
    NSError *error = nil;
    //[self.xmppStream authenticateWithPassword:self.acct.password error:&error];
}

- (void)xmppStreamDidAuthenticate:(XMPPStream *)sender {
    NSLog(@"GlacierShare authenticated");
    self.readyToShare = YES;
}

/*- (void) doShare:(NSString *)text withOwner:(id<OTRThreadOwner>)owner {
    if (!self.readyToShare) {
        [self finishedSharing:NO];
        return;
    }
    
    id<OTRMessageProtocol> message = [owner outgoingOMEMOMessageWithText:text];
    
    if (message == nil) {
        [self finishedSharing:NO];
        return;
    }
    
    message.messageSecurityInfo = [[OTRMessageEncryptionInfo alloc] initWithMessageSecurity:OTRMessageTransportSecurityOMEMO];
    message.messageSecurity = OTRMessageTransportSecurityOMEMO;
        
    NSArray<NSURL*>* msgurls = text.urls;
    if (msgurls.count > 0) {
        [self setupMediaManager];
        NSURL *htmlURL = msgurls.firstObject;
        [self.shareMediaManager sendWithHtmlURL:htmlURL thread:owner completion:^(BOOL success, NSError * _Nullable error) {
            if (!success) {
                [self finishedSharing:NO];
            }
        }];
        return;
    }
    
    [message save];
            
    if ([owner isKindOfClass:[OTRXMPPRoom class]]) {
        OTRXMPPRoom *roomie = (OTRXMPPRoom *)owner;
        [roomie saveThread];
    } else if ([owner isKindOfClass:[OTRBuddy class]]) {
        OTRBuddy *buddy = (OTRBuddy *)owner;
        [buddy saveThread];
    }
        
    [self doShare:message];
}

- (void) doShare:(NSURL *)url withOwner:(id<OTRThreadOwner>)owner withType:(NSInteger)mediaType {
    if (self.shareMediaManager && mediaType == MediaURLTypeImage) {
        
        //get image from new method
        CGSize newSize = CGSizeMake(1000, 1000); //CGSize(width: awidth, height: aheight)
        UIImage* image = [self.shareMediaManager compressImage:url to:newSize scale:0.5];
        
        //NSData *imageData = [NSData dataWithContentsOfURL:url];
        //UIImage* image = [[UIImage alloc] initWithData:imageData];
        [self.shareMediaManager sendWithImage:image thread:owner];
    } else {
        [self finishedSharing:NO];
    }
}

- (void) doShareData:(NSData *)data withOwner:(id<OTRThreadOwner>)owner withType:(NSInteger)mediaType {
    if (self.shareMediaManager && mediaType == MediaURLTypeImage) {
        
        //get image from new method
        CGSize newSize = CGSizeMake(1000, 1000); //CGSize(width: awidth, height: aheight)
        UIImage* image = [self.shareMediaManager compressImageData:data to:newSize scale:0.5];
        
        //NSData *imageData = [NSData dataWithContentsOfURL:url];
        //UIImage* image = [[UIImage alloc] initWithData:imageData];
        [self.shareMediaManager sendWithImage:image thread:owner];
    } else {
        [self finishedSharing:NO];
    }
}*/

//message: OTRMessageProtocol
/*- (void)doShare:(id<OTRMessageProtocol>)message {
    if (message == nil) {
        [self finishedSharing:NO];
    }
    
    if (self.readyToShare) {
        [self.omemoSignalCoordinator encryptAndSendMessage:message completion:^(BOOL success, NSError * error) {
            if (!success) {
                // plain text if OMEMO not available?
                //[self sendMessage:message];
                [self finishedSharing:success];
            } else {
                [self.connections.write asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
                    
                    id<OTRThreadOwner> thread = [message threadOwner];
                    if ([message isKindOfClass:[OTROutgoingMessage class]]) {
                        OTROutgoingMessage *msg = (OTROutgoingMessage *)message;
                        msg.dateSent = [NSDate date];
                        msg.readDate = [NSDate date];
                        [msg saveWithThread:thread];
                    } else if ([message isKindOfClass:[OTRXMPPRoomMessage class]]){
                        OTRXMPPRoomMessage *msg = (OTRXMPPRoomMessage *)message;
                        msg.state = RoomMessageStateSent;
                        [msg saveWithThread:thread];
                    }
                    
                    if (thread) {
                        thread.currentMessageText = nil;
                        thread.lastMessageIdentifier = message.uniqueId;
                        //thread.lastMessageIdentifier = message.messageKey;
                        [thread saveThread];
                    }
                } completionBlock:^{
                    [self finishedSharing:success];
                }];
            }
        }];
    } else {
        [self finishedSharing:NO];
    }
}*/

- (void) finishedSharing:(BOOL)success {
    //[self teardownStream];
    if (self.shareDelegate != nil) {
        [self.shareDelegate doneSending:success];
    }
}

- (void)xmppStream:(XMPPStream *)sender didReceiveMessage:(XMPPMessage *)xmppMessage
{
    //
}

- (void)xmppStream:(XMPPStream *)sender didReceiveError:(id)error
{
    NSLog(@"Glacier Share Stream Error: %@", error);
}

@end

