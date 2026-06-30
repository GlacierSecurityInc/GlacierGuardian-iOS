//
//  ProfileManager.m
//  Glacier
//
//  Created by Andy Friedman on 11/5/20.
//  Copyright © 2020 Glacier. All rights reserved.
//

#import "ProfileManager.h"
#import "GlacierConstants.h"
#import "GlacierUtilities.h"
#import "Glacier-Swift.h"
#import "GlacierInfo.h"
#import "StringsTranslator.h"

@implementation ProfileManager

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
    // Leave this in for now
    GlacierViewSetting *accountsViewSetting = [[GlacierViewSetting alloc] initWithTitle:ACCOUNTS_STRING() description:nil viewControllerClass:nil];
    
    GlacierViewSetting *resetPasswordSetting = [[GlacierViewSetting alloc] initWithTitle:@"Reset Password" description:nil viewControllerClass:nil];
    resetPasswordSetting.actionBlock = ^void(id sender) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://console.glacier.chat/forget-password/"] options:@{} completionHandler:nil];
    };
    
    GlacierViewSetting *resetSecureConnectionsSetting = [[GlacierViewSetting alloc] initWithTitle:@"Reset Secure Sessions" description:nil viewControllerClass:nil];
    resetSecureConnectionsSetting.actionBlock = ^void(id sender) {
        ChatProfileViewController *sourceVC = sender;
        if ([sender isKindOfClass:[ChatProfileViewController class]]) {
            [sourceVC resetSecureConnectionsButtonPressed];
        }
    };
    
    GlacierSettingsGroup *accountsGroup = [[GlacierSettingsGroup alloc] initWithTitle:@"Account" settings:@[accountsViewSetting,resetPasswordSetting,resetSecureConnectionsSetting]];
    [settingsGroups addObject:accountsGroup];
    
    //get teams
    GlacierSettingsGroup *teamsGroup = [[GlacierSettingsGroup alloc] initWithTitle:@"Teams" settings:@[]];
    [settingsGroups addObject:teamsGroup];
    
    GlacierViewSetting *noCurrentSessionSetting = [[GlacierViewSetting alloc] initWithTitle:@"No current session" description:nil viewControllerClass:nil];
    GlacierSettingsGroup *currentSessionGroup = [[GlacierSettingsGroup alloc] initWithTitle:@"Current Session" settings:@[noCurrentSessionSetting]];
    [settingsGroups addObject:currentSessionGroup];
    
    GlacierViewSetting *removeOtherDevicesSetting = [[GlacierViewSetting alloc] initWithTitle:@"Clear Devices" description:nil viewControllerClass:nil];
    removeOtherDevicesSetting.actionBlock = ^void(id sender) {
        ChatProfileViewController *sourceVC = sender;
        if ([sender isKindOfClass:[ChatProfileViewController class]]) {
            [sourceVC clearDevicesButtonPressed];
        }
    };
    GlacierViewSetting *noOtherDevicesSetting = [[GlacierViewSetting alloc] initWithTitle:@"No other devices" description:nil viewControllerClass:nil];
    GlacierSettingsGroup *otherDevicesGroup = [[GlacierSettingsGroup alloc] initWithTitle:@"Other Devices" settings:@[removeOtherDevicesSetting, noOtherDevicesSetting]];
    [settingsGroups addObject:otherDevicesGroup];
    
    _settingsDictionary = newSettingsDictionary;
    _settingsGroups = settingsGroups;
}

- (void) handleChangeDisplayName:(id)sender currentDisplayName:(NSString*)displayName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Change Display Name" message:nil preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Display Name";
        if (displayName) {
            textField.text = displayName;
        }
    }];
    
    UIAlertAction *change = [UIAlertAction actionWithTitle:@"Change" style:UIAlertActionStyleDefault        handler:^(UIAlertAction * _Nonnull action) {
        ChatProfileViewController *sourceVC = sender;
        if (![sender isKindOfClass:[ChatProfileViewController class]]) {
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

- (GlacierSetting*) settingAtIndexPath:(NSIndexPath*)indexPath row:(NSUInteger)row
{
    GlacierSettingsGroup *settingsGroup = [self.settingsGroups objectAtIndex:indexPath.section];
    return [settingsGroup.settings objectAtIndex:row];
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

@end

