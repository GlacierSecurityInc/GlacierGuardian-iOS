//
//  HoldToTalkView.m
//  ChatSecure
//
//  Created by David Chiles on 4/1/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

#import "HoldToTalkView.h"
@import PureLayout;
#import "TouchAndHoldGestureRecognizer.h"

@interface HoldToTalkView ()

@property (nonatomic) BOOL addedConstraints;
@property (nonatomic, strong) TouchAndHoldGestureRecognizer *gestureRecognizer;
@property (nonatomic, strong) UIPanGestureRecognizer *panGestureRecognizer;
@property (nonatomic) BOOL gestureRecognizerIsInTouch;

@end

@implementation HoldToTalkView

- (instancetype)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        _textLabel = [[UILabel alloc] initForAutoLayout];
        self.textLabel.textAlignment = NSTextAlignmentCenter;
        self.textLabel.backgroundColor = [UIColor clearColor];
        self.textLabel.userInteractionEnabled = NO;
        self.multipleTouchEnabled = NO;
        
        self.gestureRecognizer = [[TouchAndHoldGestureRecognizer alloc] initWithTarget:self action:@selector(gesture:)];
        [self addGestureRecognizer:self.gestureRecognizer];
        
        [self addSubview:self.textLabel];
    }
    return self;
}

- (CGSize)intrinsicContentSize
{
    return [self.textLabel intrinsicContentSize];
}

- (void)updateConstraints
{
    if (!self.addedConstraints) {
        [self.textLabel autoAlignAxisToSuperviewAxis:ALAxisVertical];
        [self.textLabel autoAlignAxisToSuperviewAxis:ALAxisHorizontal];
    }
    [super updateConstraints];
}

- (BOOL)isInTouch
{
    return self.gestureRecognizerIsInTouch;
}

#pragma - mark Touches

- (void)gesture:(TouchAndHoldGestureRecognizer *)sender
{
    switch (sender.state) {
        case UIGestureRecognizerStateBegan: {
            NSLog(@"Touch Began");
            self.gestureRecognizerIsInTouch = YES;
            [self.delegate didBeginTouch:self];
            break;
        }
        case UIGestureRecognizerStateChanged: {
             CGPoint pointInWindow = [self.gestureRecognizer locationInView:nil];
            [self.delegate view:self touchDidMoveToPointInWindow:pointInWindow];
            break;
        }
        case UIGestureRecognizerStateCancelled: {
           [self.delegate touchCancelled:self];
            self.gestureRecognizerIsInTouch = NO;
            break;
        }
        case UIGestureRecognizerStateEnded: {
            [self.delegate didReleaseTouch:self];
            self.gestureRecognizerIsInTouch = NO;
            break;
        }
        default:
            break;
    }
}


@end
