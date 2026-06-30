//
//  GlacierSettingsManager.m
//  Off the Record
//
//  Created by Chris Ballinger on 4/10/12.
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

#import "GlacierSettingsManager.h"
#import "GlacierConstants.h"
#import "GlacierUtilities.h"
#import "Glacier-Swift.h"
#import "GlacierInfo.h"
#import "StringsTranslator.h"

@interface GlacierSettingsManager () <TimerPickerDelegate>
@property (nonatomic, strong) GlacierValueSetting *globalMessageTimerSetting;
@property (assign, nonatomic) BOOL trackingEnabled;
@end

@implementation GlacierSettingsManager

- (instancetype) init
{
    if (self = [super init])
    {
        [self populateSettings];
    }
    return self;
}

- (void) populateSettings
{
    NSMutableArray<GlacierSettingsGroup*> *settingsGroups = [NSMutableArray array];
    NSMutableDictionary *newSettingsDictionary = [NSMutableDictionary dictionary];
    self.trackingEnabled = NO;
    
    GlacierViewSetting *accountsViewSetting = [[GlacierViewSetting alloc] initWithTitle:ACCOUNTS_STRING() description:nil viewControllerClass:[ChatProfileViewController class]];
    accountsViewSetting.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    
    /*GlacierViewSetting *resetPasswordSetting = [[GlacierViewSetting alloc] initWithTitle:@"Reset Password" description:nil viewControllerClass:nil];
    resetPasswordSetting.actionBlock = ^void(id sender) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://console.glacier.chat/forget-password/"] options:@{} completionHandler:nil];
    };*/
    
    GlacierSettingsGroup *accountsGroup = [[GlacierSettingsGroup alloc] initWithTitle:@"Account" settings:@[accountsViewSetting]]; //,resetPasswordSetting]];
    [settingsGroups addObject:accountsGroup];
    
    GlacierBoolSetting *deletedDisconnectedConversations = [[GlacierBoolSetting alloc] initWithTitle:DELETE_CONVERSATIONS_ON_DISCONNECT_TITLE_STRING()
                                                                                 description:DELETE_CONVERSATIONS_ON_DISCONNECT_DESCRIPTION_STRING()
                                                                                 settingsKey:kGlacierSettingKeyDeleteOnDisconnect];
    
    [newSettingsDictionary setObject:deletedDisconnectedConversations forKey:kGlacierSettingKeyDeleteOnDisconnect];

    GlacierBoolSetting *backupKeySetting = [[GlacierBoolSetting alloc] initWithTitle:ALLOW_DB_PASSPHRASE_BACKUP_TITLE_STRING()
        description:ALLOW_DB_PASSPHRASE_BACKUP_DESCRIPTION_STRING()
        settingsKey:kGlacierSettingKeyAllowDBPassphraseBackup];
    [newSettingsDictionary setObject:backupKeySetting forKey:kGlacierSettingKeyAllowDBPassphraseBackup];

    GlacierViewSetting *clearHistorySetting = [[GlacierViewSetting alloc] initWithTitle:@"Clear all history"
                                                                    description:nil viewControllerClass:nil];
    clearHistorySetting.actionBlock = ^void(id sender) {
        [self handleClearMessages:sender];
    };
    [newSettingsDictionary setObject:clearHistorySetting forKey:@"kOTRSettingKeyClearHistory"];
    
    self.globalMessageTimerSetting = [[GlacierValueSetting alloc] initWithTitle:@"Global message timer (off)" description:nil settingsKey:@"globalTimer"];
    NSInteger selrow = [self currentGlobalTimeSelectedRow]; 
    [self timeSelected:selrow];
    __unsafe_unretained typeof(self) weakSelf = self;
    self.globalMessageTimerSetting.actionBlock = ^void(id sender) {
        [weakSelf handleGlobalMessageTimer:sender];
    };
    [newSettingsDictionary setObject:self.globalMessageTimerSetting forKey:@"kOTRSettingKeyGlobalTimer"];
    
    // added to chatSettings below
    GlacierViewSetting *coreConnectionViewSetting = [[GlacierViewSetting alloc] initWithTitle:@"Core Connection" description:nil viewControllerClass:[CoreConnectionViewController class]];
    coreConnectionViewSetting.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    [[WireGuardManager shared] setVpnIsActive];
    
    [PushController checkPushNotifications];
    
    GlacierBoolSetting *threatDetectionViewSetting = [[GlacierBoolSetting alloc] initWithTitle:@"Threat Detection" description:nil settingsKey:@"kThreatDetectionKey"];
    threatDetectionViewSetting.enabled = YES;
    [newSettingsDictionary setObject:threatDetectionViewSetting forKey:@"kThreatDetectionKey"];
    
    GlacierBoolSetting *linkPreviewSetting = [[GlacierBoolSetting alloc] initWithTitle:@"Link Preview" description:nil settingsKey:@"kLinkPreviewKey"];
    linkPreviewSetting.enabled = YES;
    
    GlacierBoolSetting *readReceiptsSetting = [[GlacierBoolSetting alloc] initWithTitle:@"Read Receipts" description:nil settingsKey:kReadReceiptsKey];
    readReceiptsSetting.enabled = YES;
    
    GlacierViewSetting *securityHubViewSetting = [[GlacierViewSetting alloc] initWithTitle:@"Security Hub" description:nil viewControllerClass:[SecurityCenterViewController class]];
    securityHubViewSetting.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    
    GlacierBoolSetting *rebootAlertViewSetting = [[GlacierBoolSetting alloc] initWithTitle:@"Reboot Reminder" description:nil settingsKey:@"kRebootReminderKey"];
    rebootAlertViewSetting.enabled = YES; //check against account
    
    GlacierBoolSetting *trackingEnabledViewSetting = [[GlacierBoolSetting alloc] initWithTitle:@"Live Tracking" description:nil settingsKey:@"kTrackingOnKey"];
    
    NSArray<ChatAccountModel*> *accounts = [ChatAccountModel allXMPPAccounts];
    if (accounts.count > 0) {
        ChatAccountModel *acct = accounts.firstObject;
        if (acct.disableLinkFetching) {
            [linkPreviewSetting setEnabled:NO];
            [ChatMessageModel setHTMLDownload:NO];
            [ChatRoomMessageModel setHTMLDownload:NO];
        }
        if (!acct.rebootReminderEnabled) {
            rebootAlertViewSetting.enabled = NO;
        }
        
        trackingEnabledViewSetting.enabled = acct.forceTracking || acct.trackingOn;
        readReceiptsSetting.enabled = (acct.isReadReceiptsOn);
    }
    [newSettingsDictionary setObject:linkPreviewSetting forKey:@"kLinkPreviewKey"];
    [newSettingsDictionary setObject:readReceiptsSetting forKey:kReadReceiptsKey];
    [newSettingsDictionary setObject:rebootAlertViewSetting forKey:@"kRebootReminderKey"];
    [newSettingsDictionary setObject:trackingEnabledViewSetting forKey:@"kTrackingOnKey"];
    
    NSArray *chatSettings = @[self.globalMessageTimerSetting, clearHistorySetting, coreConnectionViewSetting, threatDetectionViewSetting, linkPreviewSetting, readReceiptsSetting];
    GlacierSettingsGroup *chatSettingsGroup = [[GlacierSettingsGroup alloc] initWithTitle:@"Privacy" settings:chatSettings];
    [settingsGroups addObject:chatSettingsGroup];
    
    GlacierViewSetting *privacyInfoSetting = [[GlacierViewSetting alloc] initWithTitle:@"Privacy Policy" description:nil viewControllerClass:nil];
    privacyInfoSetting.actionBlock = ^void(id sender) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://glacier.chat/legal"] options:@{} completionHandler:nil];
    };
    
    GlacierViewSetting *supportSetting = [[GlacierViewSetting alloc] initWithTitle:@"Support" description:nil viewControllerClass:nil];
    supportSetting.actionBlock = ^void(id sender) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://glacier.chat/support"] options:@{} completionHandler:nil];
    };
    
    NSArray * otherSettings = nil;
    //if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ) {
        GlacierBoolSetting *enterToSendSetting = [[GlacierBoolSetting alloc] initWithTitle:@"Tap enter to send" description:nil settingsKey:@"kOTREnterToSendKey"];
        [newSettingsDictionary setObject:enterToSendSetting forKey:@"kOTREnterToSendKey"];
        //otherSettings = @[threatDetectionViewSetting, securityHubViewSetting, supportSetting, privacyInfoSetting, enterToSendSetting];
        otherSettings = @[rebootAlertViewSetting, enterToSendSetting, supportSetting, privacyInfoSetting];
        if (accounts.count > 0) {
            ChatAccountModel *acct = accounts.firstObject;
            if (acct.trackingEnabled) {
                self.trackingEnabled = YES;
                otherSettings = @[rebootAlertViewSetting, trackingEnabledViewSetting, enterToSendSetting, supportSetting, privacyInfoSetting];
            }
        }
    /*} else {
        //otherSettings = @[threatDetectionViewSetting, securityHubViewSetting, supportSetting, privacyInfoSetting];
        otherSettings = @[threatDetectionViewSetting, linkPreviewSetting, rebootAlertViewSetting, supportSetting, privacyInfoSetting];
        if (accounts.count > 0) {
            ChatAccountModel *acct = accounts.firstObject;
            if (acct.trackingEnabled) {
                self.trackingEnabled = YES;
                otherSettings = @[threatDetectionViewSetting, linkPreviewSetting, rebootAlertViewSetting, trackingEnabledViewSetting, supportSetting, privacyInfoSetting];
            }
        }
    }*/
    GlacierSettingsGroup *otherSettingsGroup = [[GlacierSettingsGroup alloc] initWithTitle:@"Other" settings:otherSettings];
    [settingsGroups addObject:otherSettingsGroup];
    
    GlacierSettingsGroup *advancedGroup = [[GlacierSettingsGroup alloc] initWithTitle:ADVANCED_STRING()];
    
    if (advancedGroup.settings.count > 0) {
        [settingsGroups addObject:advancedGroup];
    }
    
    _settingsDictionary = newSettingsDictionary;
    _settingsGroups = settingsGroups;
}

- (BOOL) maybeRepopulateSettings:(BOOL)enabled {
    if (self.trackingEnabled != enabled) {
        [self populateSettings];
        return YES;
    } else {
        ChatAccountModel *acct = [ChatAccountModel allXMPPAccounts].firstObject;
        if (acct) {
            GlacierBoolSetting *trackingEnabledSetting = (GlacierBoolSetting *)[self settingForSettingKey:kTrackingOnKey];
            BOOL effectiveTrackingOn = acct.forceTracking || acct.trackingOn;
            if (trackingEnabledSetting && trackingEnabledSetting.enabled != effectiveTrackingOn) {
                trackingEnabledSetting.enabled = effectiveTrackingOn;
            }
        }
    }
    return NO;
}

- (void) setBackupCancelled {
    GlacierBoolSetting *dbbackupSetting = (GlacierBoolSetting *)[self settingForSettingKey:kGlacierSettingKeyAllowDBPassphraseBackup];
    [dbbackupSetting toggle];
}

- (void) handleGlobalMessageTimer:(id)sender {
    SettingsViewController *sourceVC = sender;
    if (![sender isKindOfClass:[SettingsViewController class]]) {
        return;
    }
    if ([sourceVC respondsToSelector:@selector(showTimerSelector:withSelectedRow:)]) {
        NSInteger selrow = [self currentGlobalTimeSelectedRow];
        [sourceVC showTimerSelector:self withSelectedRow:selrow];
    }
}

- (NSInteger) currentGlobalTimeSelectedRow {
    if([GlacierSettingsManager stringForSettingKey:@"globalTimer"] != nil) {
        NSString *gtime = [GlacierSettingsManager stringForSettingKey:@"globalTimer"];
        if ([gtime isEqualToString:@"2419200"]) {
            return 6;
        } else if ([gtime isEqualToString:@"604800"]) {
            return 5;
        } else if ([gtime isEqualToString:@"86400"]) {
            return 4;
        } else if ([gtime isEqualToString:@"300"]) {
            return 3;
        } else if ([gtime isEqualToString:@"60"]) {
            return 2;
        } else if ([gtime isEqualToString:@"15"]) {
            return 1;
        } else  {
            return 0;
        }
    } else {
        return 0;
    }
}

- (void)timeSelected:(NSInteger)row {
    
    NSString *time = nil;
    switch (row)
    {
        case 1:
            [self.globalMessageTimerSetting setValue:@"15"];
            time = @"15 seconds";
            break;
        case 2:
            [self.globalMessageTimerSetting setValue:@"60"];
            time = @"1 minute";
            break;
        case 3:
            [self.globalMessageTimerSetting setValue:@"300"];
            time = @"5 minutes";
            break;
        case 4:
            [self.globalMessageTimerSetting setValue:@"86400"];
            time = @"1 day";
            break;
        case 5:
            [self.globalMessageTimerSetting setValue:@"604800"];
            time = @"1 week";
            break;
        case 6:
            [self.globalMessageTimerSetting setValue:@"2419200"];
            time = @"4 weeks";
            break;
        default:
            [self.globalMessageTimerSetting setValue:@"Off"];
            break;
    }
    
    if (time == nil) {
        self.globalMessageTimerSetting.title = @"Global message timer (off)";
    } else {
        NSString *gtitle = [NSString stringWithFormat:@"Global message timer - %@", time];
        self.globalMessageTimerSetting.title = gtitle;
    }
}

// delete all messages
- (void) handleClearMessages:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear all history" message:@"Are you sure you want to delete all your history and attachments? This cannot be reverted." preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *clear = [UIAlertAction actionWithTitle:@"Clear Now" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSArray<ChatAccountModel*> *accounts = [ChatAccountModel allXMPPAccounts];
        [accounts enumerateObjectsUsingBlock:^(ChatAccountModel * account, NSUInteger idx, BOOL *stop) {
            [[BackendHelper shared] clearChatHistory];
            [ChatMessageModel deleteAllMessagesFor: account.uniqueId];
            [ChatRoomMessageModel deleteAllMessagesFor: account.uniqueId];
            [GlacierImageCache removeImagesForAllMessagesFor: account.uniqueId];
            [[NSNotificationCenter defaultCenter] postNotificationName: kDidDeleteAllChatMessages object:nil];
        }];
        //[[MediaFileManager sharedInstance] vacuum:^() {}];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:clear];
    [alert addAction:cancel];
    
    UIViewController *sourceVC = sender;
    if (![sender isKindOfClass:[UIViewController class]]) {
        return;
    }
    [sourceVC presentViewController:alert animated:YES completion:nil];
}

- (void) handleChangeDisplayName:(id)sender currentDisplayName:(NSString*)displayName{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Change Display Name" message:nil preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Display Name";
        if (displayName) {
            textField.text = displayName;
        }
    }];
    
    UIAlertAction *change = [UIAlertAction actionWithTitle:@"Change" style:UIAlertActionStyleDefault        handler:^(UIAlertAction * _Nonnull action) {
        SettingsViewController *sourceVC = sender;
        if (![sender isKindOfClass:[SettingsViewController class]]) {
            return;
        }
        if ([sourceVC respondsToSelector:@selector(changeDisplayName:withNewName:)]) {
            NSString *newname = alert.textFields.firstObject.text;
            if (newname.length > 1) {
                [sourceVC changeDisplayName:self withNewName:newname];
            }
        }
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancel];
    [alert addAction:change];
    
    UIViewController *sourceVC = sender;
    if (![sender isKindOfClass:[UIViewController class]]) {
        return;
    } else {
        alert.popoverPresentationController.sourceView = sourceVC.view;
        alert.popoverPresentationController.sourceRect = sourceVC.view.bounds;
    }
    [sourceVC presentViewController:alert animated:YES completion:nil];
}

- (GlacierSetting*) settingAtIndexPath:(NSIndexPath*)indexPath
{
    GlacierSettingsGroup *settingsGroup = [self.settingsGroups objectAtIndex:indexPath.section];
    return [settingsGroup.settings objectAtIndex:indexPath.row];
}

- (NSString*) stringForGroupInSection:(NSUInteger)section
{
    GlacierSettingsGroup *settingsGroup = [self.settingsGroups objectAtIndex:section];
    return settingsGroup.title;
}

- (NSUInteger) numberOfSettingsInSection:(NSUInteger)section
{
    GlacierSettingsGroup *settingsGroup = [self.settingsGroups objectAtIndex:section];
    return [settingsGroup.settings count];
}

- (nullable NSIndexPath *)indexPathForSetting:(GlacierSetting *)setting
{
    __block NSIndexPath *indexPath = nil;
    [self.settingsGroups enumerateObjectsUsingBlock:^(GlacierSettingsGroup *group, NSUInteger idx, BOOL *stop) {
        NSUInteger row = [group.settings indexOfObject:setting];
        if (row != NSNotFound) {
            indexPath = [NSIndexPath indexPathForItem:row inSection:idx];
            *stop = YES;
        }
    }];
    return indexPath;
}

+ (BOOL) boolForSettingKey:(NSString*)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults boolForKey:key];
}

+ (double) doubleForSettingKey:(NSString*)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults doubleForKey:key];
}

+ (NSInteger) intForSettingKey:(NSString *)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults integerForKey:key];
}

+ (float) floatForSettingKey:(NSString *)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults floatForKey:key];
}

- (nullable GlacierSetting*) settingForSettingKey:(NSString*)key {
    return [self.settingsDictionary objectForKey:key];
}

// currently used for global expiration timer
+ (nullable NSString *) stringForSettingKey:(NSString *)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults stringForKey:key];
}

+ (BOOL) allowGroupOMEMO {
    return true;
}

@end
