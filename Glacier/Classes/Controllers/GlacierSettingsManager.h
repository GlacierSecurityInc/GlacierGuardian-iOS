//
//  GlacierSettingsManager.h
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

@import Foundation;
#import "GlacierConstants.h"

@class GlacierSetting;
@class GlacierSettingsGroup;
NS_ASSUME_NONNULL_BEGIN

// for global expiration timer
@protocol TimerPickerDelegate <NSObject>
@required
- (void)timeSelected:(NSInteger)row;
@end

@interface GlacierSettingsManager : NSObject

@property (nonatomic, strong, readonly) NSArray<GlacierSettingsGroup*> *settingsGroups;
@property (nonatomic, strong, readonly) NSDictionary<NSString*,GlacierSetting*> *settingsDictionary;

- (GlacierSetting*) settingAtIndexPath:(NSIndexPath*)indexPath;
- (NSString*) stringForGroupInSection:(NSUInteger)section;
- (NSUInteger) numberOfSettingsInSection:(NSUInteger)section;
- (nullable GlacierSetting*) settingForSettingKey:(NSString*)key;

- (nullable NSIndexPath *)indexPathForSetting:(GlacierSetting *)setting;

- (void) handleChangeDisplayName:(id)sender currentDisplayName:(NSString*)displayName;

- (void) setBackupCancelled;

+ (BOOL) boolForSettingKey:(NSString*)key;
+ (double) doubleForSettingKey:(NSString*)key;
+ (NSInteger) intForSettingKey:(NSString *)key;
+ (float) floatForSettingKey:(NSString *)key;
+ (nullable NSString *) stringForSettingKey:(NSString *)key; // used for global expiration timer

/** Recalculates current setting list */
- (void) populateSettings;
- (BOOL) maybeRepopulateSettings:(BOOL)enabled;

/** If enabled, will show UI for enabling OMEMO group encryption. */
@property (nonatomic, class, readonly) BOOL allowGroupOMEMO;

@end
NS_ASSUME_NONNULL_END
