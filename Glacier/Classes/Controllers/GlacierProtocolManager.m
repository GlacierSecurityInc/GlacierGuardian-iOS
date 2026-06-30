//
//  GlacierProtocolManager.m
//  Off the Record
//
//  Created by Chris Ballinger on 9/4/11.
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

#import "GlacierProtocolManager.h"
#import "GlacierConstants.h"
#import "GlacierAppDelegate.h"
#import <BBlock/NSObject+BBlock.h>

@import KVOController;
#import "GlacierLog.h"
#import "Glacier-Swift.h"
//#import "OTRXMPPPresenceSubscriptionRequest.h"

@interface GlacierProtocolManager ()
@property (atomic, readwrite) NSUInteger numberOfConnectedProtocols;
@property (atomic, readwrite) NSUInteger numberOfConnectingProtocols;
@property (nonatomic, strong, readonly, nonnull) NSMutableDictionary<NSString*,id<GlacierProtocol>> *protocolManagers;

@property (assign, nonatomic) BOOL loggingOut;
@end

@implementation GlacierProtocolManager

-(instancetype)init
{
    self = [super init];
    if(self)
    {
        _protocolManagers = [[NSMutableDictionary alloc] init];
        
        _numberOfConnectedProtocols = 0;
        _numberOfConnectingProtocols = 0;
        _loggingOut = NO;
    }
    return self;
}

- (void)removeProtocolForAccount:(ChatAccountModel *)account
{
    NSParameterAssert(account);
    if (!account) { return; }
    id<GlacierProtocol> protocol = nil;
    @synchronized (self) {
        protocol =  [self.protocolManagers objectForKey:account.uniqueId];
    }
    if (protocol && [protocol respondsToSelector:@selector(disconnect)]) {
        [protocol disconnect];
    }
    [self.KVOController unobserve:protocol];
    @synchronized (self) {
        [self.protocolManagers removeObjectForKey:account.uniqueId];
    }
}

- (void) setLoggingOut:(BOOL)loggingOut {
    _loggingOut = loggingOut;
}

- (BOOL) isLoggingOut {
    return _loggingOut;
}

- (void)addProtocol:(id<GlacierProtocol>)protocol forAccount:(ChatAccountModel *)account
{
    @synchronized (self) {
        [self.protocolManagers setObject:protocol forKey:account.uniqueId];
    }
    [self.KVOController observe:protocol keyPath:NSStringFromSelector(@selector(loginStatus)) options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld action:@selector(protocolDidChange:)];
}

- (void)addProtocol:(id<GlacierProtocol>)protocol forAccountId:(NSString *)accountId
{
    @synchronized (self) {
        [self.protocolManagers setObject:protocol forKey:accountId];
    }
    [self.KVOController observe:protocol keyPath:NSStringFromSelector(@selector(loginStatus)) options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld action:@selector(protocolDidChange:)];
}

- (BOOL)existsProtocolForAccount:(ChatAccountModel *)account
{
    NSParameterAssert(account.uniqueId);
    if (!account.uniqueId) { return NO; }
    @synchronized (self) {
        return [self.protocolManagers objectForKey:account.uniqueId] != nil;
    }
}

- (BOOL)existsProtocolForAccountId:(NSString *)accountId
{
    NSParameterAssert(accountId);
    if (!accountId) { return NO; }
    @synchronized (self) {
        return [self.protocolManagers objectForKey:accountId] != nil;
    }
}

- (nullable GlacierXMPPManager*)xmppManagerForChatAccount:(ChatAccountModel *)account {
    NSParameterAssert(account.uniqueId);
    if (!account.uniqueId) { return nil; }
    GlacierXMPPManager* xmpp = nil;
    @synchronized (self) {
        xmpp = (GlacierXMPPManager*)[self.protocolManagers objectForKey:account.uniqueId];
        if(!xmpp)
        {
            xmpp = [[GlacierXMPPManager alloc] initWithChatAccount:account];
            if (xmpp) {
                [self addProtocol:xmpp forAccountId:account.uniqueId];
            }
        }
    }
    return xmpp;
}

- (void)loginAccount:(ChatAccountModel *)account userInitiated:(BOOL)userInitiated
{
    NSParameterAssert(account);
    if (!account) { return; }
    id <GlacierProtocol> protocol = [self xmppManagerForChatAccount:account];

    [protocol connectUserInitiated:userInitiated];
}

- (void)loginAccount:(ChatAccountModel *)account
{
    [self loginAccount:account userInitiated:NO];
}

- (void)loginAccounts:(NSArray *)accounts
{
    [accounts enumerateObjectsUsingBlock:^(ChatAccountModel * account, NSUInteger idx, BOOL *stop) {
        [self loginAccount:account];
    }];
}

- (void)goAwayForAllAccounts {
    @synchronized (self) {
        [self.protocolManagers enumerateKeysAndObjectsUsingBlock:^(id key, id <GlacierProtocol> protocol, BOOL *stop) {
            if ([protocol isKindOfClass:[GlacierXMPPManager class]]) {
                GlacierXMPPManager *xmpp = (GlacierXMPPManager*)protocol;
                [xmpp goAway];
            }
        }];
    }
}

- (void)goOfflineForAllAccounts {
    @synchronized (self) {
        [self.protocolManagers enumerateKeysAndObjectsUsingBlock:^(id key, id <GlacierProtocol> protocol, BOOL *stop) {
            if ([protocol isKindOfClass:[GlacierXMPPManager class]]) {
                GlacierXMPPManager *xmpp = (GlacierXMPPManager*)protocol;
                [xmpp goOffline];
            }
        }];
    }
}

- (void)disconnectAllAccountsSocketOnly:(BOOL)socketOnly timeout:(NSTimeInterval)timeout completionBlock:(nullable void (^)())completionBlock
{
    @synchronized (self) {
        dispatch_group_t group = dispatch_group_create();
        NSMutableDictionary<NSString*, NSObject<GlacierProtocol>*> *observingManagersForTokens = [NSMutableDictionary new];
        for (NSObject<GlacierProtocol> *manager in self.protocolManagers.allValues) {
            GlacierXMPPManager *xmpp = (GlacierXMPPManager*)manager;
            NSParameterAssert([xmpp isKindOfClass:GlacierXMPPManager.class]);
            if (![xmpp isKindOfClass:GlacierXMPPManager.class]) {
                DDLogError(@"Wrong protocol class for manager %@", manager);
                continue;
            }
            
            if (xmpp.loginStatus != GlacierLoginStatusDisconnected) {
                dispatch_group_enter(group);
                NSString *token = [xmpp addObserverForKeyPath:NSStringFromSelector(@selector(loginStatus))
                                                         options:0
                                                           block:^(NSString *keyPath, GlacierXMPPManager *mgr, NSDictionary *change) {
                                                               if (mgr.loginStatus == GlacierLoginStatusDisconnected) {
                                                                   dispatch_group_leave(group);
                                                               }
                                                           }];
                observingManagersForTokens[token] = manager;
                [manager disconnectSocketOnly:socketOnly];
            }
        }
        if (timeout > 0) {
            dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t) (timeout * NSEC_PER_SEC)));
        }
        for (NSString *token in observingManagersForTokens.allKeys) {
            [observingManagersForTokens[token] removeObserverForToken:token];
        }
        if (completionBlock != nil) {
            completionBlock();
        }
    }
}

- (void)disconnectAllAccounts
{
    [self disconnectAllAccountsSocketOnly:NO timeout:0 completionBlock:nil];
}

- (void)protocolDidChange:(NSDictionary *)change
{
    __block NSUInteger connected = 0;
    __block NSUInteger connecting = 0;
    @synchronized (self) {
        [self.protocolManagers enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, id<GlacierProtocol>  _Nonnull obj, BOOL * _Nonnull stop) {
            GlacierXMPPManager *xmpp = (GlacierXMPPManager*)obj;
            NSParameterAssert([xmpp isKindOfClass:GlacierXMPPManager.class]);
            if (![xmpp isKindOfClass:GlacierXMPPManager.class]) {
                DDLogError(@"Wrong protocol class for account %@", obj);
                return;
            }
            if (xmpp.loginStatus == GlacierLoginStatusAuthenticated) {
                connected++;
            } else if (xmpp.loginStatus == GlacierLoginStatusConnecting) {
                connecting++;
            }
        }];
    }
    self.numberOfConnectedProtocols = connected;
    self.numberOfConnectingProtocols = connecting;
}

-(BOOL)isAccountIdConnected:(NSString *)accountId
{
    BOOL connected = NO;
    id <GlacierProtocol> protocol = nil;
    @synchronized (self) {
        protocol = [self.protocolManagers objectForKey:accountId];
    }
    GlacierXMPPManager *xmpp = (GlacierXMPPManager*)protocol;
    if (xmpp) {
        connected = xmpp.loginStatus == GlacierLoginStatusAuthenticated;
    }
    return connected;
}

- (void)sendMessage:(OutgoingChatMessage *)message {
    //Dispatch global?
    ChatBuddyModel *buddy = [ChatBuddyModel getBuddyWithUniqueId:message.threadId];
    ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId: buddy.accountUniqueId];
    GlacierXMPPManager *xmppManager = [[GlacierProtocolManager sharedInstance] xmppManagerForChatAccount:account];
    [xmppManager sendMessage:message];
}

#pragma mark Singleton Object Methods

+ (GlacierProtocolManager*) shared {
    return [self sharedInstance];
}

+ (instancetype)sharedInstance
{
    static id sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

@end
