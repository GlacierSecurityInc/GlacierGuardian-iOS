//
//  XMPPLoginHandler.h
//  ChatSecure
//
//  Created by David Chiles on 5/13/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import Foundation;

@class XLFormViewController, GlacierXMPPManager, ChatAccountModel;

@interface XMPPLoginHandler : NSObject

@property (nonatomic, copy) void (^ _Nullable completion)(ChatAccountModel * _Nonnull account, NSError * _Nullable error);
@property (nonatomic, weak, readonly) GlacierXMPPManager * _Nullable xmppManager;

- (void) finishConnectingWithAccount:(ChatAccountModel *_Nonnull)account completion:(void (^_Nonnull)(ChatAccountModel * _Nonnull account, NSError * _Nullable error))completion; // for single sign on funcationality

@end
