//
//  ProfileManager.h
//  Glacier
//
//  Created by Andy Friedman on 11/5/20.
//  Copyright © 2020 Glacier. All rights reserved.
//

@import Foundation;
#import "GlacierConstants.h"

@class GlacierSetting;
@class GlacierSettingsGroup;
NS_ASSUME_NONNULL_BEGIN

@interface ProfileManager : NSObject

@property (nonatomic, strong, readonly) NSArray<GlacierSettingsGroup*> *settingsGroups;
@property (nonatomic, strong, readonly) NSDictionary<NSString*,GlacierSetting*> *settingsDictionary;

- (GlacierSetting*) settingAtIndexPath:(NSIndexPath*)indexPath;
- (GlacierSetting*) settingAtIndexPath:(NSIndexPath*)indexPath row:(NSUInteger)row;
- (NSString*) stringForGroupInSection:(NSUInteger)section;
- (NSUInteger) numberOfSettingsInSection:(NSUInteger)section;
- (nullable GlacierSetting*) settingForSettingKey:(NSString*)key;

- (nullable NSIndexPath *)indexPathForSetting:(GlacierSetting *)setting;

- (void) handleChangeDisplayName:(id)sender currentDisplayName:(nullable NSString*)displayName;

/** Recalculates current setting list */
- (void) populateSettings;

@end
NS_ASSUME_NONNULL_END
