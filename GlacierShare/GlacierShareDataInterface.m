//
//  GlacierShareDataInterface.m
//  GlacierShare
//
//  Created by Andy Friedman on 12/15/20.
//  Copyright © 2020 Glacier. All rights reserved.
//

#import "GlacierShareDataInterface.h"
#import "GlacierXMPPStream.h"
#import "GlacierShare-Swift.h"
@import XMPPFramework;

@interface GlacierShareDataInterface () <XMPPStreamDelegate, ShareMessageDelegate>

@property (nonatomic, strong, nullable) GlacierXMPPStream *xmppStream;
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
    NSString * queueLabel = [NSString stringWithFormat:@"%@.work.%@",[self class],self];
    _workQueue = dispatch_queue_create([queueLabel UTF8String], 0);

    _xmppStream = [[GlacierXMPPStream alloc] init];
    self.xmppStream.startTLSPolicy = XMPPStreamStartTLSPolicyRequired;
    [self.xmppStream addDelegate:self delegateQueue:self.workQueue];
}

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

