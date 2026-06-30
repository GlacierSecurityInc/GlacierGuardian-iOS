//
//  OTRSettingTableViewself.m
//  Off the Record
//
//  Created by Chris Ballinger on 4/24/12.
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

#import "SettingTableViewCell.h"
#import "Glacier-Swift.h"
#import "GlacierInfo.h"

@implementation SettingTableViewCell
@synthesize glacierSetting;

- (instancetype) initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        self.detailTextLabel.numberOfLines = 0;
    }
    return self;
}

- (void) setGlacierSetting:(GlacierSetting *)setting {
    self.textLabel.text = setting.title;
    self.detailTextLabel.text = setting.settingDescription;
    if(setting.imageName)
    {
        self.imageView.image = [UIImage imageNamed:setting.imageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
    }
    else
    {
        self.imageView.image = nil;
    }

    UIView *accessoryView = nil;
    if ([setting isKindOfClass:[GlacierBoolSetting class]]) {
        GlacierBoolSetting *boolSetting = (GlacierBoolSetting*)setting;
        UISwitch *boolSwitch = nil;
        BOOL animated;
        if (glacierSetting == setting) {
            boolSwitch = (UISwitch*)self.accessoryView;
            animated = YES;
        } else {
            boolSwitch = [[UISwitch alloc] init];
            [boolSwitch addTarget:boolSetting action:@selector(toggle) forControlEvents:UIControlEventValueChanged];
            animated = NO;
        }
        [boolSwitch setOn:[boolSetting enabled] animated:animated];
        accessoryView = boolSwitch;
        self.accessoryType = UITableViewCellAccessoryNone;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    else if ([setting isKindOfClass:[GlacierViewSetting class]])
    {
        self.accessoryType = ((GlacierViewSetting *)setting).accessoryType;
        self.selectionStyle = UITableViewCellSelectionStyleBlue;
    }

    self.accessoryView = accessoryView;
    glacierSetting = setting;
}

- (void) setOtrBoolSetting:(GlacierBoolSetting *)boolSetting boolSwitch:(UISwitch *)boolSwitch {
    self.textLabel.text = boolSetting.title;
    self.detailTextLabel.text = boolSetting.settingDescription;
    if(boolSetting.imageName) {
        self.imageView.image = [UIImage imageNamed:boolSetting.imageName inBundle:[GlacierInfo resourcesBundle] compatibleWithTraitCollection:nil];
    } else {
        self.imageView.image = nil;
    }
    
    [boolSwitch setOn:[boolSetting enabled] animated:YES];
    self.accessoryType = UITableViewCellAccessoryNone;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    
    self.accessoryView = boolSwitch;
    glacierSetting = boolSetting;
}

@end
