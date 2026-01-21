//
//  OTRXMPPLoginHandler.h
//  ChatSecure
//
//  Created by David Chiles on 5/13/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import Foundation;
#import "OTRBaseLoginViewController.h"
#import "OTRLoginHandler.h"

@class XLFormViewController, OTRXMPPManager, ChatAccountModel;

@interface OTRXMPPLoginHandler : NSObject <OTRBaseLoginViewControllerHandlerProtocol>

@property (nonatomic, copy) void (^ _Nullable completion)(ChatAccountModel * _Nonnull account, NSError * _Nullable error);
@property (nonatomic, weak, readonly) OTRXMPPManager * _Nullable xmppManager;

- (ChatAccountModel *_Nullable)moveValues:(XLFormDescriptor *_Nonnull)form intoAccount:(ChatAccountModel *_Nonnull)account;

- (void)prepareForXMPPConnectionFrom:(XLFormDescriptor *_Nonnull)form account:(ChatAccountModel *_Nonnull)account;

- (void) finishConnectingWithAccount:(ChatAccountModel *_Nonnull)account completion:(void (^_Nonnull)(ChatAccountModel * _Nonnull account, NSError * _Nullable error))completion; // for single sign on funcationality

@end
