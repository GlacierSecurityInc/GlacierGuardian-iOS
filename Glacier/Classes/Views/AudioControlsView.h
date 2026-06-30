//
//  AudioControlsView.h
//  ChatSecure
//
//  Created by David Chiles on 1/28/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import UIKit;

@class  PlayPauseProgressView;

extern NSInteger const kOTRAudioControlsViewTag;

@interface AudioControlsView : UIView

@property (nonatomic, strong, readonly) PlayPauseProgressView *playPuaseProgressView;
@property (nonatomic, strong, readonly) UILabel *timeLabel;

- (void)setTime:(NSTimeInterval)time;

@end
