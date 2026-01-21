//
//  OTRProtocolManager.m
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

#import "OTRProtocolManager.h"
#import "OTRConstants.h"
#import "OTRAppDelegate.h"
#import <BBlock/NSObject+BBlock.h>

@import KVOController;
#import "OTRLog.h"
#import "Glacier-Swift.h"
//#import "OTRXMPPPresenceSubscriptionRequest.h"

@interface OTRProtocolManager ()
@property (atomic, readwrite) NSUInteger numberOfConnectedProtocols;
@property (atomic, readwrite) NSUInteger numberOfConnectingProtocols;
@property (nonatomic, strong, readonly, nonnull) NSMutableDictionary<NSString*,id<OTRProtocol>> *protocolManagers;

@property (assign, nonatomic) BOOL loggingOut;
@end

@implementation OTRProtocolManager

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
    id<OTRProtocol> protocol = nil;
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

- (void)addProtocol:(id<OTRProtocol>)protocol forAccount:(ChatAccountModel *)account
{
    @synchronized (self) {
        [self.protocolManagers setObject:protocol forKey:account.uniqueId];
    }
    [self.KVOController observe:protocol keyPath:NSStringFromSelector(@selector(loginStatus)) options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld action:@selector(protocolDidChange:)];
}

- (void)addProtocol:(id<OTRProtocol>)protocol forAccountId:(NSString *)accountId
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

- (nullable OTRXMPPManager*)xmppManagerForChatAccount:(ChatAccountModel *)account {
    NSParameterAssert(account.uniqueId);
    if (!account.uniqueId) { return nil; }
    OTRXMPPManager* xmpp = nil;
    @synchronized (self) {
        xmpp = (OTRXMPPManager*)[self.protocolManagers objectForKey:account.uniqueId];
        if(!xmpp)
        {
            xmpp = [[OTRXMPPManager alloc] initWithChatAccount:account];
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
    id <OTRProtocol> protocol = [self xmppManagerForChatAccount:account];

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
        [self.protocolManagers enumerateKeysAndObjectsUsingBlock:^(id key, id <OTRProtocol> protocol, BOOL *stop) {
            if ([protocol isKindOfClass:[OTRXMPPManager class]]) {
                OTRXMPPManager *xmpp = (OTRXMPPManager*)protocol;
                [xmpp goAway];
            }
        }];
    }
}

- (void)goOfflineForAllAccounts {
    @synchronized (self) {
        [self.protocolManagers enumerateKeysAndObjectsUsingBlock:^(id key, id <OTRProtocol> protocol, BOOL *stop) {
            if ([protocol isKindOfClass:[OTRXMPPManager class]]) {
                OTRXMPPManager *xmpp = (OTRXMPPManager*)protocol;
                [xmpp goOffline];
            }
        }];
    }
}

- (void)disconnectAllAccountsSocketOnly:(BOOL)socketOnly timeout:(NSTimeInterval)timeout completionBlock:(nullable void (^)())completionBlock
{
    @synchronized (self) {
        dispatch_group_t group = dispatch_group_create();
        NSMutableDictionary<NSString*, NSObject<OTRProtocol>*> *observingManagersForTokens = [NSMutableDictionary new];
        for (NSObject<OTRProtocol> *manager in self.protocolManagers.allValues) {
            OTRXMPPManager *xmpp = (OTRXMPPManager*)manager;
            NSParameterAssert([xmpp isKindOfClass:OTRXMPPManager.class]);
            if (![xmpp isKindOfClass:OTRXMPPManager.class]) {
                DDLogError(@"Wrong protocol class for manager %@", manager);
                continue;
            }
            
            if (xmpp.loginStatus != OTRLoginStatusDisconnected) {
                dispatch_group_enter(group);
                NSString *token = [xmpp addObserverForKeyPath:NSStringFromSelector(@selector(loginStatus))
                                                         options:0
                                                           block:^(NSString *keyPath, OTRXMPPManager *mgr, NSDictionary *change) {
                                                               if (mgr.loginStatus == OTRLoginStatusDisconnected) {
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
        [self.protocolManagers enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, id<OTRProtocol>  _Nonnull obj, BOOL * _Nonnull stop) {
            OTRXMPPManager *xmpp = (OTRXMPPManager*)obj;
            NSParameterAssert([xmpp isKindOfClass:OTRXMPPManager.class]);
            if (![xmpp isKindOfClass:OTRXMPPManager.class]) {
                DDLogError(@"Wrong protocol class for account %@", obj);
                return;
            }
            if (xmpp.loginStatus == OTRLoginStatusAuthenticated) {
                connected++;
            } else if (xmpp.loginStatus == OTRLoginStatusConnecting) {
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
    id <OTRProtocol> protocol = nil;
    @synchronized (self) {
        protocol = [self.protocolManagers objectForKey:accountId];
    }
    OTRXMPPManager *xmpp = (OTRXMPPManager*)protocol;
    NSParameterAssert([xmpp isKindOfClass:OTRXMPPManager.class]);
    if (![xmpp isKindOfClass:OTRXMPPManager.class]) {
        DDLogError(@"Wrong protocol class %@", protocol);
        return NO;
    }
    if (xmpp) {
        connected = xmpp.loginStatus == OTRLoginStatusAuthenticated;
    }
    return connected;
}

- (void)sendMessage:(OutgoingChatMessage *)message {
    //Dispatch global?
    ChatBuddyModel *buddy = [ChatBuddyModel getBuddyWithUniqueId:message.threadId];
    ChatAccountModel *account = [ChatAccountModel getXMPPAccountWithUniqueId: buddy.accountUniqueId];
    OTRXMPPManager *xmppManager = [[OTRProtocolManager sharedInstance] xmppManagerForChatAccount:account];
    [xmppManager sendMessage:message];
}

#pragma mark Singleton Object Methods

+ (OTRProtocolManager*) shared {
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
