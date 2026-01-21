//
//  OTRXMPPLoginHandler.m
//  ChatSecure
//
//  Created by David Chiles on 5/13/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

#import "OTRXMPPLoginHandler.h"
#import "OTRXMPPManager.h"
@import XLForm;
#import "OTRXLFormCreator.h"
#import "OTRProtocolManager.h"
#import "OTRPasswordGenerator.h"
#import "Glacier-Swift.h"
@import XMPPFramework;
#import "OTRLog.h"
@import KVOController;

@interface OTRXMPPLoginHandler()
@end

@implementation OTRXMPPLoginHandler


- (void)moveAccountValues:(ChatAccountModel *)account intoForm:(XLFormDescriptor *)form
{
    if (!account) {
        return;
    }
    XLFormRowDescriptor *usernameRow = [form formRowWithTag:kOTRXLFormUsernameTextFieldTag];
    if (!usernameRow.value) {
        usernameRow.value = account.username;
    }
    [[form formRowWithTag:kOTRXLFormPasswordTextFieldTag] setValue:account.password];
    [[form formRowWithTag:kOTRXLFormRememberPasswordSwitchTag] setValue:@(YES)];
    [[form formRowWithTag:kOTRXLFormLoginAutomaticallySwitchTag] setValue:@(YES)];
    [[form formRowWithTag:kOTRXLFormBypassNetworkSwitchTag] setValue:@(account.bypassNetworkCheck)];
    [[form formRowWithTag:kOTRXLFormStageConsoleSwitchTag] setValue:@(account.useStageConsole)];
    [[form formRowWithTag:kOTRXLFormHostnameTextFieldTag] setValue:account.domain];
    
    if (account.port != [ChatAccountModel defaultPort]) {
        [[form formRowWithTag:kOTRXLFormPortTextFieldTag] setValue:@(account.port)];
    } else {
        [[form formRowWithTag:kOTRXLFormPortTextFieldTag] setValue:nil];
    }
    
    XLFormRowDescriptor *autofetch = [form formRowWithTag:kOTRXLFormAutomaticURLFetchTag];
    autofetch.value = @(YES);
    
    [[form formRowWithTag:kOTRXLFormResourceTextFieldTag] setValue:account.resource];
}

- (ChatAccountModel *)moveValues:(XLFormDescriptor *)form intoAccount:(ChatAccountModel *)intoAccount
{
    ChatAccountModel *account = nil;
    if (!intoAccount) {
        ChatAccountType accountType = ChatAccountTypeJabber;
        account = [[ChatAccountModel alloc] initWithUsername:@""];
        if (!account) {
            return nil;
        }
    } else {
        account = [intoAccount copy];
    }
    NSString *nickname = [[form formRowWithTag:kOTRXLFormNicknameTextFieldTag] value];
    
    XLFormRowDescriptor *usernameRow = [form formRowWithTag:kOTRXLFormUsernameTextFieldTag];
    
    NSString *jidNode = nil; // aka 'username' from username@example.com
    NSString *jidDomain = nil;

    if (![usernameRow isHidden]) {
        NSArray *components = [usernameRow.value componentsSeparatedByString:@"@"];
        if (components.count == 2) {
            jidNode = [components firstObject];
            jidDomain = [components lastObject];
        } else {
            jidNode = usernameRow.value;
        }
    }

    if (!jidNode.length) {
        // strip whitespace and make nickname lowercase
        jidNode = [nickname stringByReplacingOccurrencesOfString:@" " withString:@""];
        jidNode = [jidNode lowercaseString];
    }
    
    /*NSNumber *rememberPassword = [[form formRowWithTag:kOTRXLFormRememberPasswordSwitchTag] value];
    if (rememberPassword) {
        account.rememberPassword = [rememberPassword boolValue];
    } else {
        account.rememberPassword = YES;
    }*/
    
    NSNumber *bypassNetwork = [[form formRowWithTag:kOTRXLFormBypassNetworkSwitchTag] value];
    if (bypassNetwork) {
        account.bypassNetworkCheck = [bypassNetwork boolValue];
    } else {
        account.bypassNetworkCheck = NO;
    }
    
    NSNumber *useStageConsole = [[form formRowWithTag:kOTRXLFormStageConsoleSwitchTag] value];
    if (useStageConsole) {
        account.useStageConsole = [useStageConsole boolValue];
    } else {
        account.useStageConsole = NO;
    }
    
    NSString *password = [[form formRowWithTag:kOTRXLFormPasswordTextFieldTag] value];
    
    if (password && password.length > 0) {
        account.password = password;
    } else if (account.password.length == 0) {
        // No password in field, generate strong password for user
        account.password = [OTRPasswordGenerator passwordWithLength:20];
    }
    
    /*NSNumber *autologin = [[form formRowWithTag:kOTRXLFormLoginAutomaticallySwitchTag] value];
    if (autologin) {
        account.autologin = [autologin boolValue];
    } else {
        account.autologin = YES;
    }*/
    
    NSString *hostname = [[form formRowWithTag:kOTRXLFormHostnameTextFieldTag] value];
    NSNumber *port = [[form formRowWithTag:kOTRXLFormPortTextFieldTag] value];
    NSString *resource = [[form formRowWithTag:kOTRXLFormResourceTextFieldTag] value];
    
    account.domain = hostname;

    
    if (port) {
        account.port = [port intValue];
    }
    
    if ([resource length]) {
        account.resource = resource;
    }
    /*NSNumber *autofetch = [form formRowWithTag:kOTRXLFormAutomaticURLFetchTag].value;
    if (autofetch) {
        account.disableAutomaticURLFetching = !autofetch.boolValue;
    }*/
    
    // Post-process values via XMPPJID for stringprep
    
    if (!jidDomain.length) {
        //jidDomain = account.domain;
        jidDomain = GlacierInfo.defaultHost;
    }
    
    XMPPJID *jid = [XMPPJID jidWithUser:jidNode domain:jidDomain resource:account.resource];
    if (!jid) {
        NSParameterAssert(jid != nil);
        DDLogError(@"Error creating JID from account values!");
    }
    account.username = jid.bare;
    account.resource = jid.resource;
    account.displayName = nickname;
    
    // set display name if nickname was not entered
    if (account.displayName == nil) {
        account.displayName = jidNode;
    }
    
    return account;
}

#pragma - mark OTRBaseLoginViewController

- (void)prepareForXMPPConnectionFrom:(XLFormDescriptor *)form account:(ChatAccountModel *)account
{
    if (form) {
        account = (ChatAccountModel *)[self moveValues:form intoAccount:account];
    }
    
    //Reffresh protocol manager for new account settings
    [[OTRProtocolManager sharedInstance] removeProtocolForAccount:account];
    _xmppManager = (OTRXMPPManager *)[[OTRProtocolManager sharedInstance] xmppManagerForChatAccount:account];
    
    [self.KVOController observe:self.xmppManager keyPath:NSStringFromSelector(@selector(loginStatus)) options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld action:@selector(connectionStatusDidChange:)];
}

- (void)performActionWithValidForm:(XLFormDescriptor *)form account:(ChatAccountModel *)account progress:(void (^)(NSInteger progress, NSString *summaryString))progress completion:(void (^)(ChatAccountModel * account, NSError *error))completion
{
    if (form) {
        account = (ChatAccountModel *)[self moveValues:form intoAccount:(ChatAccountModel*)account];
    }
    self.completion = completion;
    
    [self finishConnectingWithForm:form account:account];
}

- (void) finishConnectingWithForm:(XLFormDescriptor *)form account:(ChatAccountModel *)account {
    [self prepareForXMPPConnectionFrom:form account:account];
    NSString *password = [[form formRowWithTag:kOTRXLFormPasswordTextFieldTag] value];
    if (password.length > 0) {
        account.password = password;
    }
    [self.xmppManager connectUserInitiated:YES];
}

// account should be fully created, used for single sign on
- (void) finishConnectingWithAccount:(ChatAccountModel *)account completion:(void (^)(ChatAccountModel * account, NSError *error))completion{
    
    //Refresh protocol manager for new account settings
    [[OTRProtocolManager sharedInstance] removeProtocolForAccount:account];
    _xmppManager = (OTRXMPPManager *)[[OTRProtocolManager sharedInstance] xmppManagerForChatAccount:account];
    [self.KVOController observe:self.xmppManager keyPath:NSStringFromSelector(@selector(loginStatus)) options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld action:@selector(connectionStatusDidChange:)];
    
    self.completion = completion;
    [self.xmppManager connectUserInitiated:YES];
}

- (void)connectionStatusDidChange:(NSDictionary *)change
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = self.xmppManager.lastConnectionError;
        ChatAccountModel *account = self.xmppManager.chatAccount;
        OTRLoginStatus status = self.xmppManager.loginStatus;
        
        if (status == OTRLoginStatusAuthenticated) {
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
