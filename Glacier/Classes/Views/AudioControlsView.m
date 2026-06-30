//
//  AudioControlsView.m
//  ChatSecure
//
//  Created by David Chiles on 1/28/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

#import "AudioControlsView.h"
@import PureLayout;
#import "PlayPauseProgressView.h"

NSInteger const kOTRAudioControlsViewTag = 301;

@interface AudioControlsView ()

@property (nonatomic) BOOL addedConstraints;

@end

@implementation AudioControlsView

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        self.tag = kOTRAudioControlsViewTag;
        _timeLabel = [[UILabel alloc] initForAutoLayout];
        self.timeLabel.textColor = [UIColor whiteColor];
        self.timeLabel.textAlignment = NSTextAlignmentCenter;
        self.timeLabel.font = [UIFont fontWithName:@"HelveticaNeue-Light" size:14];
        [self setTime:0];
        
        _playPuaseProgressView = [[PlayPauseProgressView alloc] initForAutoLayout];
        self.playPuaseProgressView.opaque = NO;
        self.playPuaseProgressView.color = [UIColor whiteColor];
        self.playPuaseProgressView.status = GlacierPlayPauseProgressViewStatusPlay;
        
        [self addSubview:self.timeLabel];
        [self addSubview:self.playPuaseProgressView];
        
        self.addedConstraints = NO;
    }
    return self;
}

- (void)setTime:(NSTimeInterval)time
{
    time = round(time);
    NSUInteger minutes = (int)time / 60;
    NSUInteger seconds = (int)time % 60;
    
    self.timeLabel.text = [NSString stringWithFormat:@"%lu:%02ld",(unsigned long)minutes,(unsigned long)seconds];
}

- (void)updateConstraints{
    [super updateConstraints];
    if (!self.addedConstraints) {
        
        [self.playPuaseProgressView autoPinEdgesToSuperviewEdgesWithInsets:UIEdgeInsetsZero excludingEdge:ALEdgeTrailing];
        [self.playPuaseProgressView autoMatchDimension:ALDimensionWidth toDimension:ALDimensionHeight ofView:self.playPuaseProgressView];
        
        [self.timeLabel autoPinEdgesToSuperviewEdgesWithInsets:UIEdgeInsetsZero excludingEdge:ALEdgeLeading];
        [self.timeLabel autoPinEdge:ALEdgeLeading toEdge:ALEdgeTrailing ofView:self.playPuaseProgressView withOffset:0 relation:NSLayoutRelationEqual];
        
        self.addedConstraints = YES;
    }
}



@end
