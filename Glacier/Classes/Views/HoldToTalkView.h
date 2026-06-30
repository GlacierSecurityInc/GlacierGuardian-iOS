//
//  HoldToTalkView.h
//  ChatSecure
//
//  Created by David Chiles on 4/1/15.
//  Copyright (c) 2015 Chris Ballinger. All rights reserved.
//

@import UIKit;

@class HoldToTalkView;

@protocol HoldToTalkViewStateDelegate <NSObject>

@required
- (void)didBeginTouch:(HoldToTalkView *)view;
- (void)didReleaseTouch:(HoldToTalkView *)view;
- (void)view:(HoldToTalkView *)view touchDidMoveToPointInWindow:(CGPoint)point;
- (void)touchCancelled:(HoldToTalkView *)view;

@end

@interface HoldToTalkView : UIView

@property (nonatomic, strong, readonly) UILabel *textLabel;

@property (nonatomic, weak) id <HoldToTalkViewStateDelegate> delegate;
- (BOOL) isInTouch;

@end
