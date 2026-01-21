//
//  UIActionSheet+ChatSecure.m
//  ChatSecure
//
//  Created by David Chiles on 10/24/14.
//  Copyright (c) 2014 Chris Ballinger. All rights reserved.
//

#import "UIActionSheet+ChatSecure.h"
#import "OTRAppDelegate.h"

@implementation UIActionSheet (ChatSecure)

- (void)otr_presentInView:(UIView *)view
{
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        [self showInView:view];
    } else if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        [self showInView:[OTRAppDelegate appDelegate].window];
    }
}

@end
