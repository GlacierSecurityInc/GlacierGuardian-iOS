//
//  OTRColorFadingDotImageView.m
//  Off the Record
//
//  Created by David Chiles on 1/28/14.
//  Copyright (c) 2014 Chris Ballinger. All rights reserved.
//

#import "ColorFadingDotView.h"

@interface ColorFadingDotView ()

@property (nonatomic) CGFloat radius;
@property (nonatomic,strong) UIColor * originalColor;

@end

@implementation ColorFadingDotView

- (instancetype)initWithColor:(UIColor *)color radius:(CGFloat)radius
{
    
    if (self = [self initWithFrame:CGRectMake(0, 0, radius*2, radius*2)]) {
        self.backgroundColor = self.originalColor = color;
        self.radius = radius;
        CAShapeLayer *maskLayer = [CAShapeLayer layer];
        maskLayer.frame = self.bounds;
        maskLayer.path = [UIBezierPath bezierPathWithOvalInRect:self.bounds].CGPath;
        self.layer.mask = maskLayer;
    }
    return self;
}

- (void)startColorAnimationWithDelay:(NSTimeInterval)delay
{
    [UIView animateWithDuration:self.animationDuration
                          delay:delay
                        options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat | UIViewAnimationOptionBeginFromCurrentState
                     animations:^
    {
        self.backgroundColor = self.animateToColor;
    }
                     completion:nil
     ];
}

- (void)stopColorAnimation
{
    [self.layer removeAllAnimations];
    [UIView animateWithDuration:self.animationDuration
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^
     {
         self.backgroundColor = self.originalColor;
     }
                     completion:nil
     ];
}

-(void)updateConstraints
{
    [super updateConstraints];
    
    NSLayoutConstraint * constraint = [NSLayoutConstraint constraintWithItem:self
                                                                   attribute:NSLayoutAttributeWidth
                                                                   relatedBy:NSLayoutRelationEqual
                                                                      toItem:nil
                                                                   attribute:NSLayoutAttributeNotAnAttribute
                                                                  multiplier:1.0
                                                                    constant:self.radius*2];
    [self addConstraint:constraint];
    
    constraint = [NSLayoutConstraint constraintWithItem:self
                                              attribute:NSLayoutAttributeHeight
                                              relatedBy:NSLayoutRelationEqual
                                                 toItem:nil
                                              attribute:NSLayoutAttributeNotAnAttribute
                                             multiplier:1.0
                                               constant:self.radius*2];
    [self addConstraint:constraint];
}

@end
