//
//  AudioTrashView.h
//  ChatSecure
//
//  Created by David Chiles on 4/8/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import UIKit;
@import BButton;

@class CircleView;

@interface AudioTrashView : UIView

@property (nonatomic, strong, readonly) BButton *trashButton;
@property (nonatomic, strong, readonly) CircleView *animatingSoundView;
@property (nonatomic, strong, readonly) UILabel *trashLabel;
@property (nonatomic, strong, readonly) UILabel *trashIconLabel;
@property (nonatomic, strong, readonly) UILabel *microphoneIconLabel;


- (void)setAnimationChange:(double)change;

@end
