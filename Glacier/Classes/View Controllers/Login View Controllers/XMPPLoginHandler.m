//
//  XMPPLoginHandler.m
//  ChatSecure
//
//  Created by David Chiles on 5/13/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

#import "XMPPLoginHandler.h"
#import "GlacierXMPPManager.h"
@import XLForm;
#import "GlacierProtocolManager.h"
#import "PasswordGenerator.h"
#import "Glacier-Swift.h"
@import XMPPFramework;
#import "GlacierLog.h"
@import KVOController;

@interface XMPPLoginHandler()
@end

@implementation XMPPLoginHandler

// account should be fully created, used for single sign on
- (void) finishConnectingWithAccount:(ChatAccountModel *)account completion:(void (^)(ChatAccountModel * account, NSError *error))completion{
    
    //Refresh protocol manager for new account settings
    [[GlacierProtocolManager sharedInstance] removeProtocolForAccount:account];
    _xmppManager = (GlacierXMPPManager *)[[GlacierProtocolManager sharedInstance] xmppManagerForChatAccount:account];
    [self.KVOController observe:self.xmppManager keyPath:NSStringFromSelector(@selector(loginStatus)) options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld action:@selector(connectionStatusDidChange:)];
    
    self.completion = completion;
    [self.xmppManager connectUserInitiated:YES];
}

- (void)connectionStatusDidChange:(NSDictionary *)change
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = self.xmppManager.lastConnectionError;
        ChatAccountModel *account = self.xmppManager.chatAccount;
        GlacierLoginStatus status = self.xmppManager.loginStatus;
        
        if (status == GlacierLoginStatusAuthenticated) {
            if (self.completion) {
                self.completion(account,nil);
            }
        }
        else if (error) {
            if (self.completion) {
                self.completion(account,error);
            }
        }
    });
}

@end
