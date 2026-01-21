//
//  OTRSettingsManager.m
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

#import "OTRSettingsManager.h"
//#import "ProfileViewController.h"
#import "OTRViewSetting.h"
#import "OTRSetting.h"
#import "OTRBoolSetting.h"
#import "OTRViewSetting.h"
#import "OTRDoubleSetting.h"
#import "OTRConstants.h"
#import "OTRSettingsGroup.h"
#import "OTRIntSetting.h"
#import "OTRCertificateSetting.h"
#import "OTRUtilities.h"
#import "Glacier-Swift.h"
#import "GlacierInfo.h"
#import "OTRStrings.h"

@interface OTRSettingsManager () <TimerPickerDelegate>
@property (nonatomic, strong) OTRValueSetting *globalMessageTimerSetting;
@property (assign, nonatomic) BOOL trackingEnabled;
@end

@implementation OTRSettingsManager

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
    NSMutableArray<OTRSettingsGroup*> *settingsGroups = [NSMutableArray array];
    NSMutableDictionary *newSettingsDictionary = [NSMutableDictionary dictionary];
    
    OTRViewSetting *accountsViewSetting = [[OTRViewSetting alloc] initWithTitle:ACCOUNTS_STRING() description:nil viewControllerClass:[ChatProfileViewController class]];
    //IOSM-479 nil to ChatProfileViewController above, and accessory below
    accountsViewSetting.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    
    //ALF IOSM-479
    /*OTRViewSetting *resetPasswordSetting = [[OTRViewSetting alloc] initWithTitle:@"Reset Password" description:nil viewControllerClass:nil];
    resetPasswordSetting.actionBlock = ^void(id sender) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://console.glacier.chat/forget-password/"] options:@{} completionHandler:nil];
    };*/
    
    OTRSettingsGroup *accountsGroup = [[OTRSettingsGroup alloc] initWithTitle:@"Account" settings:@[accountsViewSetting]]; //,resetPasswordSetting]];
    [settingsGroups addObject:accountsGroup];
    
    OTRBoolSetting *deletedDisconnectedConversations = [[OTRBoolSetting alloc] initWithTitle:DELETE_CONVERSATIONS_ON_DISCONNECT_TITLE_STRING()
                                                                                 description:DELETE_CONVERSATIONS_ON_DISCONNECT_DESCRIPTION_STRING()
                                                                                 settingsKey:kOTRSettingKeyDeleteOnDisconnect];
    
    [newSettingsDictionary setObject:deletedDisconnectedConversations forKey:kOTRSettingKeyDeleteOnDisconnect];
    
    OTRCertificateSetting * certSetting = [[OTRCertificateSetting alloc] initWithTitle:PINNED_CERTIFICATES_STRING()
                                                                           description:PINNED_CERTIFICATES_DESCRIPTION_STRING()];
    
    certSetting.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    OTRBoolSetting *backupKeySetting = [[OTRBoolSetting alloc] initWithTitle:ALLOW_DB_PASSPHRASE_BACKUP_TITLE_STRING()
        description:ALLOW_DB_PASSPHRASE_BACKUP_DESCRIPTION_STRING()
        settingsKey:kOTRSettingKeyAllowDBPassphraseBackup];
    [newSettingsDictionary setObject:backupKeySetting forKey:kOTRSettingKeyAllowDBPassphraseBackup]; //ALF IOSM-499

    OTRViewSetting *clearHistorySetting = [[OTRViewSetting alloc] initWithTitle:@"Clear all history"
                                                                    description:nil viewControllerClass:nil];
    clearHistorySetting.actionBlock = ^void(id sender) {
        [self handleClearMessages:sender];
    };
    [newSettingsDictionary setObject:clearHistorySetting forKey:@"kOTRSettingKeyClearHistory"];
    
    self.globalMessageTimerSetting = [[OTRValueSetting alloc] initWithTitle:@"Global message timer (off)" description:nil settingsKey:@"globalTimer"];
    NSInteger selrow = [self currentGlobalTimeSelectedRow]; 
    [self timeSelected:selrow];
    __unsafe_unretained typeof(self) weakSelf = self;
    self.globalMessageTimerSetting.actionBlock = ^void(id sender) {
        [weakSelf handleGlobalMessageTimer:sender];
    };
    [newSettingsDictionary setObject:self.globalMessageTimerSetting forKey:@"kOTRSettingKeyGlobalTimer"];
    
    // added to chatSettings below
    OTRViewSetting *coreConnectionViewSetting = [[OTRViewSetting alloc] initWithTitle:@"Core Connection" description:nil viewControllerClass:[CoreConnectionViewController class]];
    coreConnectionViewSetting.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    [[WireGuardManager shared] setVpnIsActive];
    
    [PushController checkPushNotifications];
    
    //IOSM#58 also added below to other settings
    OTRBoolSetting *threatDetectionViewSetting = [[OTRBoolSetting alloc] initWithTitle:@"Threat Detection" description:nil settingsKey:@"kThreatDetectionKey"];
    threatDetectionViewSetting.enabled = YES;
    [newSettingsDictionary setObject:threatDetectionViewSetting forKey:@"kThreatDetectionKey"];
    
    OTRBoolSetting *linkPreviewSetting = [[OTRBoolSetting alloc] initWithTitle:@"Link Preview" description:nil settingsKey:@"kLinkPreviewKey"];
    linkPreviewSetting.enabled = YES;
    
    OTRBoolSetting *readReceiptsSetting = [[OTRBoolSetting alloc] initWithTitle:@"Read Receipts" description:nil settingsKey:kReadReceiptsKey];
    readReceiptsSetting.enabled = YES;
    
    //IOSM#19
    OTRViewSetting *securityHubViewSetting = [[OTRViewSetting alloc] initWithTitle:@"Security Hub" description:nil viewControllerClass:[SecurityCenterViewController class]];
    securityHubViewSetting.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    
    OTRBoolSetting *rebootAlertViewSetting = [[OTRBoolSetting alloc] initWithTitle:@"Reboot Reminder" description:nil settingsKey:@"kRebootReminderKey"];
    rebootAlertViewSetting.enabled = YES; //check against account
    
    OTRBoolSetting *trackingEnabledViewSetting = [[OTRBoolSetting alloc] initWithTitle:@"Live Tracking" description:nil settingsKey:@"kTrackingOnKey"];
    trackingEnabledViewSetting.enabled = NO; //check against account
    
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
        if (acct.trackingOn) {
            trackingEnabledViewSetting.enabled = YES;
        }
        readReceiptsSetting.enabled = (acct.isReadReceiptsOn);
    }
    [newSettingsDictionary setObject:linkPreviewSetting forKey:@"kLinkPreviewKey"];
    [newSettingsDictionary setObject:readReceiptsSetting forKey:kReadReceiptsKey];
    [newSettingsDictionary setObject:rebootAlertViewSetting forKey:@"kRebootReminderKey"];
    [newSettingsDictionary setObject:trackingEnabledViewSetting forKey:@"kTrackingOnKey"];
    
    //ALF IOSM-499 added backupKeySetting (removed again for now)
    NSArray *chatSettings = @[self.globalMessageTimerSetting, clearHistorySetting, coreConnectionViewSetting, threatDetectionViewSetting, linkPreviewSetting, readReceiptsSetting];
    OTRSettingsGroup *chatSettingsGroup = [[OTRSettingsGroup alloc] initWithTitle:@"Privacy" settings:chatSettings];
    [settingsGroups addObject:chatSettingsGroup];
    
    OTRViewSetting *privacyInfoSetting = [[OTRViewSetting alloc] initWithTitle:@"Privacy Policy" description:nil viewControllerClass:nil];
    privacyInfoSetting.actionBlock = ^void(id sender) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://glacier.chat/legal"] options:@{} completionHandler:nil];
    };
    
    OTRViewSetting *supportSetting = [[OTRViewSetting alloc] initWithTitle:@"Support" description:nil viewControllerClass:nil];
    supportSetting.actionBlock = ^void(id sender) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://glacier.chat/support"] options:@{} completionHandler:nil];
    };
    
    NSArray * otherSettings = nil;
    //if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ) {
        OTRBoolSetting *enterToSendSetting = [[OTRBoolSetting alloc] initWithTitle:@"Tap enter to send" description:nil settingsKey:@"kOTREnterToSendKey"];
        [newSettingsDictionary setObject:enterToSendSetting forKey:@"kOTREnterToSendKey"];
        //otherSettings = @[threatDetectionViewSetting, securityHubViewSetting, supportSetting, privacyInfoSetting, enterToSendSetting]; //IOSM#19
        otherSettings = @[rebootAlertViewSetting, enterToSendSetting, supportSetting, privacyInfoSetting]; //IOSM#90 (and below remove Hub)
        if (accounts.count > 0) {
            ChatAccountModel *acct = accounts.firstObject;
            if (acct.trackingEnabled) {
                self.trackingEnabled = YES;
                otherSettings = @[rebootAlertViewSetting, trackingEnabledViewSetting, enterToSendSetting, supportSetting, privacyInfoSetting]; //IOSM#90 (and below remove Hub)
            }
        }
    /*} else {
        //otherSettings = @[threatDetectionViewSetting, securityHubViewSetting, supportSetting, privacyInfoSetting];
        otherSettings = @[threatDetectionViewSetting, linkPreviewSetting, rebootAlertViewSetting, supportSetting, privacyInfoSetting];
        if (accounts.count > 0) {
            ChatAccountModel *acct = accounts.firstObject;
            if (acct.trackingEnabled) {
                self.trackingEnabled = YES;
                otherSettings = @[threatDetectionViewSetting, linkPreviewSetting, rebootAlertViewSetting, trackingEnabledViewSetting, supportSetting, privacyInfoSetting]; //IOSM#90 (and below remove Hub)
            }
        }
    }*/
    OTRSettingsGroup *otherSettingsGroup = [[OTRSettingsGroup alloc] initWithTitle:@"Other" settings:otherSettings];
    [settingsGroups addObject:otherSettingsGroup];
    
    OTRSettingsGroup *advancedGroup = [[OTRSettingsGroup alloc] initWithTitle:ADVANCED_STRING()];
    
    if (advancedGroup.settings.count > 0) {
        [settingsGroups addObject:advancedGroup];
    }
    
    _settingsDictionary = newSettingsDictionary;
    _settingsGroups = settingsGroups;
}

- (BOOL) maybeRepopulateSettings:(BOOL)enabled {
    if (!self.trackingEnabled == enabled) {
        [self populateSettings];
        return YES;
    } else {//else if should be turned on...
        ChatAccountModel *acct = [ChatAccountModel allXMPPAccounts].firstObject;
        if (acct && acct.trackingOn) {
            OTRBoolSetting *trackingEnabledSetting = (OTRBoolSetting *)[self settingForOTRSettingKey:kTrackingOnKey];
            if (trackingEnabledSetting.enabled == NO) {
                [trackingEnabledSetting toggle];
            }
        }
    }
    return NO;
}

//ALF IOSM-499
- (void) setBackupCancelled {
    OTRBoolSetting *dbbackupSetting = (OTRBoolSetting *)[self settingForOTRSettingKey:kOTRSettingKeyAllowDBPassphraseBackup];
    [dbbackupSetting toggle];
}

- (void) handleGlobalMessageTimer:(id)sender {
    OTRSettingsViewController *sourceVC = sender;
    if (![sender isKindOfClass:[OTRSettingsViewController class]]) {
        return;
    }
    if ([sourceVC respondsToSelector:@selector(showTimerSelector:withSelectedRow:)]) {
        NSInteger selrow = [self currentGlobalTimeSelectedRow];
        [sourceVC showTimerSelector:self withSelectedRow:selrow];
    }
}

- (NSInteger) currentGlobalTimeSelectedRow {
    if([OTRSettingsManager stringForOTRSettingKey:@"globalTimer"] != nil) {
        NSString *gtime = [OTRSettingsManager stringForOTRSettingKey:@"globalTimer"];
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
        case 6: //IOSM#6
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
            [ChatMessageModel deleteAllMessagesFor: account.uniqueId];
            [ChatRoomMessageModel deleteAllMessagesFor: account.uniqueId];
            [GlacierImageCache removeImagesForAllMessagesFor: account.uniqueId];
            [[NSNotificationCenter defaultCenter] postNotificationName: kDidDeleteAllChatMessages object:nil];
        }];
        //[[OTRMediaFileManager sharedInstance] vacuum:^() {}];
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
        OTRSettingsViewController *sourceVC = sender;
        if (![sender isKindOfClass:[OTRSettingsViewController class]]) {
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

- (OTRSetting*) settingAtIndexPath:(NSIndexPath*)indexPath
{
    OTRSettingsGroup *settingsGroup = [self.settingsGroups objectAtIndex:indexPath.section];
    return [settingsGroup.settings objectAtIndex:indexPath.row];
}

- (NSString*) stringForGroupInSection:(NSUInteger)section
{
    OTRSettingsGroup *settingsGroup = [self.settingsGroups objectAtIndex:section];
    return settingsGroup.title;
}

- (NSUInteger) numberOfSettingsInSection:(NSUInteger)section
{
    OTRSettingsGroup *settingsGroup = [self.settingsGroups objectAtIndex:section];
    return [settingsGroup.settings count];
}

- (nullable NSIndexPath *)indexPathForSetting:(OTRSetting *)setting
{
    __block NSIndexPath *indexPath = nil;
    [self.settingsGroups enumerateObjectsUsingBlock:^(OTRSettingsGroup *group, NSUInteger idx, BOOL *stop) {
        NSUInteger row = [group.settings indexOfObject:setting];
        if (row != NSNotFound) {
            indexPath = [NSIndexPath indexPathForItem:row inSection:idx];
            *stop = YES;
        }
    }];
    return indexPath;
}

+ (BOOL) boolForOTRSettingKey:(NSString*)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults boolForKey:key];
}

+ (double) doubleForOTRSettingKey:(NSString*)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults doubleForKey:key];
}

+ (NSInteger) intForOTRSettingKey:(NSString *)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults integerForKey:key];
}

+ (float) floatForOTRSettingKey:(NSString *)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults floatForKey:key];
}

- (nullable OTRSetting*) settingForOTRSettingKey:(NSString*)key {
    return [self.settingsDictionary objectForKey:key];
}

// currently used for global expiration timer
+ (nullable NSString *) stringForOTRSettingKey:(NSString *)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults stringForKey:key];
}

+ (BOOL) allowGroupOMEMO {
    return true;
}

@end
