//
//  GlacierProtocolManager.h
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

@import Foundation;
@import XMPPFramework;
#import "GlacierSettingsManager.h"
#import "GlacierProtocol.h"

@class OutgoingChatMessage, PushController, GlacierXMPPManager, ChatAccountModel, ChatBuddyModel;

NS_ASSUME_NONNULL_BEGIN
@interface GlacierProtocolManager : NSObject

@property (atomic, readonly) NSUInteger numberOfConnectedProtocols;
@property (atomic, readonly) NSUInteger numberOfConnectingProtocols;

- (BOOL)existsProtocolForAccount:(ChatAccountModel *)account;
- (BOOL)existsProtocolForAccountId:(NSString *)accountId;
- (nullable GlacierXMPPManager*)xmppManagerForChatAccount:(ChatAccountModel *)account;
- (void)removeProtocolForAccount:(ChatAccountModel *)account;

- (void) setLoggingOut:(BOOL)loggingOut; 
- (BOOL) isLoggingOut;

- (BOOL)isAccountIdConnected:(NSString *)accountId;

- (void)loginAccount:(ChatAccountModel *)account;
- (void)loginAccount:(ChatAccountModel *)account userInitiated:(BOOL)userInitiated;
- (void)loginAccounts:(NSArray<ChatAccountModel*> *)accounts;
- (void)goAwayForAllAccounts;
- (void)goOfflineForAllAccounts;
- (void)disconnectAllAccounts;
- (void)disconnectAllAccountsSocketOnly:(BOOL)socketOnly timeout:(NSTimeInterval)timeout completionBlock:(nullable void (^)())completionBlock;

- (void)sendMessage:(OutgoingChatMessage *)message;

+ (instancetype)sharedInstance; // Singleton method

/** Convenience for sharedInstance */
@property (class, nonatomic, readonly) GlacierProtocolManager *shared;

@end
NS_ASSUME_NONNULL_END
