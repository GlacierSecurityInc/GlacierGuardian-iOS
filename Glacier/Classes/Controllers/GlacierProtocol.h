//
//  GlacierProtocol.h
//  Off the Record
//
//  Created by Chris Ballinger on 6/25/12.
//  Copyright (c) 2012 Chris Ballinger. All rights reserved.
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

@class OutgoingChatMessage, ChatAccountModel, XMPPMessage;

typedef NS_ENUM(int, GlacierProtocolType) {
    GlacierProtocolTypeNone        = 0,
    GlacierProtocolTypeXMPP        = 1,
    GlacierProtocolTypeOscar       = 2 // deprecated
};

typedef NS_ENUM(NSInteger, GlacierLoginStatus) {
    GlacierLoginStatusDisconnected = 0,
    GlacierLoginStatusDisconnecting,
    GlacierLoginStatusConnecting,
    GlacierLoginStatusConnected,
    GlacierLoginStatusSecuring,
    GlacierLoginStatusSecured,
    GlacierLoginStatusAuthenticating,
    GlacierLoginStatusAuthenticated
};

typedef NS_ENUM(NSInteger, GlacierNetworkConnectionStatus) {
    GlacierNetworkConnectionStatusDisconnected = 0,
    GlacierNetworkConnectionStatusUnknown,
    GlacierNetworkConnectionStatusConnecting,
    GlacierNetworkConnectionStatusConnected
};

NS_ASSUME_NONNULL_BEGIN
@protocol GlacierProtocol <NSObject>

/** Send a message immediately. Bypasses (and used by) the message queue. */
- (void) sendMessage:(OutgoingChatMessage*)message;

- (void) connect;
- (void) connectUserInitiated:(BOOL)userInitiated;
- (BOOL) connectFromBackground;

- (void) disconnect;
- (void) disconnectSocketOnly:(BOOL)socketOnly;
- (instancetype) initWithChatAccount:(ChatAccountModel*)account;

@end

@protocol GlacierXMPPProtocol <GlacierProtocol>
//- (void)sendChatState:(int)chatState withBuddyId:(NSString *)buddyId;
- (void)sendChatStateMessage:(XMPPMessage *)xMessage;
//- (void) setDisplayName:(NSString *) newDisplayName forBuddy:(OTRBuddy *)buddy;
@end
NS_ASSUME_NONNULL_END
